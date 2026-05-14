# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/envvars
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

  test "createMapping fails without router":
    # In CI with no NAT device, expect Failure or timeout — both return err.
    discard init()
    let r = waitFor createMapping(UDP, 12345)
    check r.isErr()
    discard cleanup()

suite "plum - NAT port mapping (requires NAT_TEST_PLUM=1)":
  test "createMapping TCP and destroyMapping":
    if getEnv("NAT_TEST_PLUM") != "1":
      skip()
      return

    check init().isOk()

    let r = waitFor createMapping(TCP, 8101)
    check r.isOk()

    let res = r.value
    check res.mapping.externalPort > 0
    check res.mapping.externalHost.len > 0

    destroyMapping(res.id)
    check cleanup().isOk()

  test "createMapping UDP":
    if getEnv("NAT_TEST_PLUM") != "1":
      skip()
      return

    check init().isOk()

    let r = waitFor createMapping(UDP, 8090)
    check r.isOk()

    let res = r.value
    check res.mapping.externalPort > 0

    destroyMapping(res.id)
    check cleanup().isOk()
