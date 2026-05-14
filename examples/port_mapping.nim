# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

# This example creates a TCP port mapping via PCP, NAT-PMP, or UPnP-IGD,
# prints the external address, and destroys the mapping before exiting.

import chronos
import libplum/plum

proc main() {.async.} =
  let initRes = init()
  if initRes.isErr():
    echo "init failed: ", initRes.error
    return

  echo "Local address: ", getLocalAddress().valueOr("<unknown>")

  let r = await createMapping(TCP, 8080)
  if r.isErr():
    echo "createMapping failed: ", r.error
    discard cleanup()
    return

  let res = r.value
  echo "Mapping created:"
  echo "  external host: ", res.mapping.externalHost
  echo "  external port: ", res.mapping.externalPort
  echo "  internal port: ", res.mapping.internalPort

  destroyMapping(res.id)

  let cleanupRes = cleanup()
  if cleanupRes.isErr():
    echo "cleanup failed: ", cleanupRes.error

waitFor main()
