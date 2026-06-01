# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/os
import std/osproc
import std/strutils
import posix
import unittest2
import std/atomics
import chronos
import libplum/plum
import libplum/libplum

const miniupnp_protocol {.strdefine.} = ""

suite "plum":
  test "init and cleanup":
    let r = init()
    check r.isOk()
    let c = cleanup()
    check c.isOk()

  test "double cleanup returns error":
    discard init()
    discard cleanup()
    let c = cleanup()
    check c.isErr()

  test "getLocalAddress after init":
    discard init()
    let r = getLocalAddress()
    check r.isOk()
    check r.value.len > 0
    discard cleanup()

  test "hasMapping returns false for unknown id":
    check not hasMapping(999)

  # Only valid where no NAT device answers; the integration container runs
  # miniupnpd, which would make the mapping succeed before the timeout.
  when miniupnp_protocol == "":
    test "createMapping times out without a NAT device":
      require init().isOk()
      defer:
        discard cleanup()

      let r = waitFor createMapping(TCP, 8101, timeout = milliseconds(50))
      check r.isErr()

  test "destroyMapping is a no-op on an unknown id":
    require init().isOk()
    defer:
      discard cleanup()

    destroyMapping(999.cint)
    check not hasMapping(999)

# The flag is passed by the Docker / Podman container.
when miniupnp_protocol != "":
  const
    discoverMs = 2000
    recheckMs = 500
    upnpRestartMs = discoverMs + 2000
    natpmpEpochMs = 3000
    renewalPollMs = 100
    renewalTimeoutMs = 10_000

  let mappingTimeout = seconds(40)

  let logLevel =
    if getEnv("LIBPLUM_VERBOSE") == "1": PlumLogLevel.Verbose else: PlumLogLevel.None

  var gRenewed: Atomic[bool]

  proc onMappingRenewal(
      state: PlumState, mapping: PlumMapping
  ) {.cdecl, raises: [], gcsafe.} =
    if state == Success:
      gRenewed.store(true)

  proc stopMiniupnpd(proto: string) =
    let pidFile = "/tmp/plum-test/miniupnpd-" & proto & ".pid"
    let pid = readFile(pidFile).strip().parseInt()

    discard posix.kill(pid.Pid, SIGKILL)

  proc waitRenewal(): bool =
    for _ in 0 ..< (renewalTimeoutMs div renewalPollMs):
      if gRenewed.load():
        return true
      sleep(renewalPollMs)
    false

  proc startMiniupnpd(proto: string) =
    let pidFile = "/tmp/plum-test/miniupnpd-" & proto & ".pid"
    let confFile = "/tmp/plum-test/miniupnpd-" & proto & ".conf"
    let logFile = "/tmp/plum-test/miniupnpd-" & proto & ".log"
    let binary = if proto == "natpmp": "miniupnpd-natpmponly" else: "miniupnpd"

    discard execShellCmd(
      binary & " -d -f " & confFile & " >> " & logFile & " 2>&1 & echo $! > " & pidFile
    )

  suite "plum - " & miniupnp_protocol & " using miniupnp":
    test "createMapping TCP and destroyMapping":
      require init(discoverTimeout = discoverMs.int32, logLevel = logLevel).isOk()
      defer:
        discard cleanup()

      let r = waitFor createMapping(TCP, 8101, timeout = mappingTimeout)
      require r.isOk()
      let res = r.value

      checkpoint miniupnp_protocol & " TCP: " & res.mapping.externalHost & ":" &
        $res.mapping.externalPort
      check res.mapping.externalPort > 0
      check res.mapping.externalHost.len > 0
      check hasMapping(res.id)

      when miniupnp_protocol == "upnp":
        check res.mapping.mappingProtocol == UPnP
      elif miniupnp_protocol == "natpmp":
        check res.mapping.mappingProtocol == NatPmp
      else:
        check res.mapping.mappingProtocol == PCP

      destroyMapping(res.id)
      check not hasMapping(res.id)
      # second destroy on a real id must be a safe no-op
      destroyMapping(res.id)

    test "createMapping UDP and destroying":
      require init(discoverTimeout = discoverMs.int32, logLevel = logLevel).isOk()
      defer:
        discard cleanup()

      let r = waitFor createMapping(UDP, 8090, timeout = mappingTimeout)
      require r.isOk()

      let res = r.value
      defer:
        destroyMapping(res.id)

      checkpoint miniupnp_protocol & " UDP: " & res.mapping.externalHost & ":" &
        $res.mapping.externalPort
      check res.mapping.externalPort > 0

      when miniupnp_protocol == "upnp":
        check res.mapping.mappingProtocol == UPnP
      elif miniupnp_protocol == "natpmp":
        check res.mapping.mappingProtocol == NatPmp
      else:
        check res.mapping.mappingProtocol == PCP

    test "mapping is renewed after miniupnpd restart":
      require init(
        discoverTimeout = discoverMs.int32,
        logLevel = logLevel,
        recheckPeriod = recheckMs.int32,
      )
        .isOk()
      defer:
        discard cleanup()

      gRenewed.store(false)

      let r = waitFor createMapping(
        TCP, 8301, timeout = mappingTimeout, onStateChange = onMappingRenewal
      )
      require r.isOk()
      let res = r.value
      defer:
        destroyMapping(res.id)

      when miniupnp_protocol == "natpmp":
        # Let the server epoch advance so the restart is detectable
        sleep(natpmpEpochMs)

      stopMiniupnpd(miniupnp_protocol)

      when miniupnp_protocol == "upnp":
        sleep(upnpRestartMs)

      startMiniupnpd(miniupnp_protocol)

      check waitRenewal()

    test "cleanup releases active mappings":
      require init(discoverTimeout = discoverMs.int32, logLevel = logLevel).isOk()

      let r = waitFor createMapping(TCP, 8401, timeout = mappingTimeout)
      require r.isOk()

      # no destroyMapping on purpose: cleanup must release everything
      check cleanup().isOk()
      check activeMappingCount() == 0
