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
when miniupnp_protocol != "":
  suite "plum - " & miniupnp_protocol & " using miniupnp":
    test "createMapping TCP and destroyMapping":
      check init(discoverTimeout = 15000).isOk()

      let r = waitFor createMapping(TCP, 8101, timeout = seconds(40))
      check r.isOk()
      if r.isOk():
        let res = r.value
        check res.mapping.externalPort > 0
        check res.mapping.externalHost.len > 0
        check hasMapping(res.id)
        if getEnv("TEST_VERBOSE") == "1":
          echo miniupnp_protocol & " TCP: " & res.mapping.externalHost & ":" & $res.mapping.externalPort
        destroyMapping(res.id)

      discard cleanup()

    test "createMapping UDP and destroying":
      check init(discoverTimeout = 2000).isOk()

      let r = waitFor createMapping(UDP, 8090, timeout = seconds(40))
      check r.isOk()
      if r.isOk():
        let res = r.value
        check res.mapping.externalPort > 0
        if getEnv("TEST_VERBOSE") == "1":
          echo miniupnp_protocol & " UDP: " & res.mapping.externalHost & ":" & $res.mapping.externalPort
        destroyMapping(res.id)

      discard cleanup()
