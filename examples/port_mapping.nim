# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

# This example creates a TCP port mapping via PCP, NAT-PMP, or UPnP-IGD,
# prints the external address so you can verify it on the router,
# then waits for Enter before removing the mapping.

import chronos
import libplum/plum

proc main() {.async.} =
  let initRes = init()
  if initRes.isErr():
    echo "init failed: ", initRes.error
    return

  echo "Local address: ", getLocalAddress().valueOr("<unknown>")

  # --- Add mapping ---
  let r = await createMapping(TCP, 8080)
  if r.isErr():
    echo "createMapping failed: ", r.error
    discard cleanup()
    return

  let res = r.value
  echo "Mapping created:"
  echo "  external: ", res.mapping.externalHost, ":", res.mapping.externalPort
  echo "  internal port: ", res.mapping.internalPort
  echo ""
  echo "Verify the mapping on your router, then press Enter to remove it."
  try: discard readLine(stdin)
  except IOError: discard

  # --- Remove mapping ---
  destroyMapping(res.id)
  echo "Mapping removed."

  let cleanupRes = cleanup()
  if cleanupRes.isErr():
    echo "cleanup failed: ", cleanupRes.error

waitFor main()
