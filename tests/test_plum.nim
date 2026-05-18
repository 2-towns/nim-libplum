# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/os
import unittest2
import chronos
import libplum/plum
import libplum/libplum

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

const miniupnp_protocol {.strdefine.} = ""
# The flag is passed by the Docker / Podman container
when miniupnp_protocol == "natpmp":
  # miniupnpd is compiled without PCP: PCP probes time out and libplum must
  # fall back to NAT-PMP on its own.
  suite "plum - natpmp fallback (PCP timeout)":
    test "createMapping TCP via NAT-PMP fallback":
      let logLevel = if getEnv("LIBPLUM_VERBOSE") == "1": PLUM_LOG_LEVEL_VERBOSE
                     else: PLUM_LOG_LEVEL_NONE
      check init(discoverTimeout = 15000, logLevel = logLevel).isOk()

      let r = waitFor createMapping(TCP, 8101, timeout = seconds(40))
      check r.isOk()
      if r.isOk():
        let res = r.value
        check res.mapping.externalPort > 0
        check res.mapping.externalHost.len > 0
        check res.mapping.mappingProtocol == NatPmp
        check hasMapping(res.id)
        if getEnv("TEST_VERBOSE") == "1":
          echo "NAT-PMP TCP: " & res.mapping.externalHost & ":" & $res.mapping.externalPort
        destroyMapping(res.id)

      discard cleanup()

elif miniupnp_protocol != "":
  suite "plum - " & miniupnp_protocol & " using miniupnp":
    test "createMapping TCP and destroyMapping":
      let logLevel = if getEnv("LIBPLUM_VERBOSE") == "1": PLUM_LOG_LEVEL_VERBOSE
                     else: PLUM_LOG_LEVEL_NONE
      check init(discoverTimeout = 15000, logLevel = logLevel).isOk()

      let r = waitFor createMapping(TCP, 8101, timeout = seconds(40))
      check r.isOk()
      if r.isOk():
        let res = r.value
        check res.mapping.externalPort > 0
        check res.mapping.externalHost.len > 0
        check res.mapping.mappingProtocol == (if miniupnp_protocol == "pcp": PCP else: UPnP)
        check hasMapping(res.id)
        if getEnv("TEST_VERBOSE") == "1":
          echo miniupnp_protocol & " TCP: " & res.mapping.externalHost & ":" & $res.mapping.externalPort
        destroyMapping(res.id)

      discard cleanup()

    test "createMapping UDP and destroying":
      let logLevel = if getEnv("LIBPLUM_VERBOSE") == "1": PLUM_LOG_LEVEL_VERBOSE
                     else: PLUM_LOG_LEVEL_NONE
      check init(discoverTimeout = 2000, logLevel = logLevel).isOk()

      let r = waitFor createMapping(UDP, 8090, timeout = seconds(40))
      check r.isOk()
      if r.isOk():
        let res = r.value
        check res.mapping.externalPort > 0
        check res.mapping.mappingProtocol == (if miniupnp_protocol == "pcp": PCP else: UPnP)
        if getEnv("TEST_VERBOSE") == "1":
          echo miniupnp_protocol & " UDP: " & res.mapping.externalHost & ":" & $res.mapping.externalPort
        destroyMapping(res.id)

      discard cleanup()
