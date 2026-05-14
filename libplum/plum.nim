# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/[atomics, locks, tables]
import chronos
import chronos/threadsync
import results
import ./libplum

export results

{.pragma: callback, cdecl, raises: [], gcsafe.}

type
  PlumProtocol* = enum
    TCP = PLUM_IP_PROTOCOL_TCP.int
    UDP = PLUM_IP_PROTOCOL_UDP.int

  PlumState* = enum
    Destroyed  = PLUM_STATE_DESTROYED.int
    Pending    = PLUM_STATE_PENDING.int
    Success    = PLUM_STATE_SUCCESS.int
    Failure    = PLUM_STATE_FAILURE.int
    Destroying = PLUM_STATE_DESTROYING.int

  PlumMapping* = object
    protocol*: PlumProtocol
    internalPort*: uint16
    externalPort*: uint16
    externalHost*: string

  MappingResult* = object
    id*: cint
    mapping*: PlumMapping

  PlumStateCallback* =
    proc(state: PlumState, mapping: PlumMapping) {.callback.}

  MappingHandle = ref object
    signal: ThreadSignalPtr
    # Indicate that the first call of the mapping handle is
    # done. In that case, resolvedState and resolvedMapping
    # will contain the result.
    # MappingHandle can be called multiple times after that,
    # but the result will be passed through the callback.
    resolved: Atomic[bool]
    resolvedState: PlumState
    resolvedMapping: PlumMapping
    # Use abandoned pattern for memory freeing
    abandoned: Atomic[bool]
    onStateChange: PlumStateCallback

# libplum calls mappingCallback from its own C thread. Under refc, any thread
# that touches Nim objects must register with the GC first.
template foreignThreadGc(body: untyped) =
  when declared(setupForeignThreadGc): setupForeignThreadGc()
  body
  when declared(tearDownForeignThreadGc): tearDownForeignThreadGc()

var activeMappingsLock: Lock
var activeMappings {.guard: activeMappingsLock.}: Table[cint, MappingHandle]

initLock(activeMappingsLock)

# We can be confident that the pattern is GC Safe using
# a lock.
template withSafeLock(body: untyped) =
  {.cast(gcsafe).}:
    withLock activeMappingsLock:
      body

proc mappingCallback(id: cint, state: plum_state_t,
                     raw: ptr plum_mapping_t) {.cdecl, raises: [].} =
  ## Called from libplum's internal C thread on SUCCESS, FAILURE, and DESTROYED.

  foreignThreadGc:
    let handle = cast[MappingHandle](raw[].user_ptr)
    if handle.isNil:
      return

    let plumState = PlumState(state.int)
    if plumState == Destroyed:
      withSafeLock:
        activeMappings.del(id)
      # The handle can be abandoned after a timeout during a
      # mapping creation.
      # In that case, destroy is called internally and the
      # signal pointer can be closed.
      if handle.abandoned.load():
        discard handle.signal.close()
      return

    # Skip states other than Success and Failure
    if plumState notin {Success, Failure}:
      return

    let mapping = PlumMapping(
      protocol: PlumProtocol(raw[].protocol.int),
      internalPort: raw[].internal_port,
      externalPort: raw[].external_port,
      externalHost: $cast[cstring](unsafeAddr raw[].external_host[0])
    )

    if not handle.resolved.exchange(true):
      # If this is the first time the handle mapping
      # is called, let's set the result in the handle values,
      # and fire the signal.
      handle.resolvedState = plumState
      handle.resolvedMapping = mapping
      discard handle.signal.fireSync()
    else:
      # Otherwise, just call the callback
      if not handle.onStateChange.isNil:
        handle.onStateChange(plumState, mapping)

proc init*(logLevel = PLUM_LOG_LEVEL_NONE): Result[void, string] {.raises: [].} =
  ## init MUST be called to setup internal plum thread (plum_init).

  var config = plum_config_t(
    log_level: logLevel,
    log_callback: nil,
    dummytls_domain: nil
  )

  let res = plum_init(addr config)
  if res == PLUM_ERR_SUCCESS:
    ok()
  else:
    err("plum_init failed: " & $res)

proc cleanup*(): Result[void, string] {.raises: [].} =
  ## cleanup MUST be called to stop the thread and clean the setup.

  let res = plum_cleanup()
  if res == PLUM_ERR_SUCCESS:
    ok()
  else:
    err("plum_cleanup failed: " & $res)

proc createMapping*(
    protocol: PlumProtocol,
    internalPort: uint16,
    externalPort: uint16 = 0,
    onStateChange: PlumStateCallback = nil
): Future[Result[MappingResult, string]] {.async: (raises: [CancelledError]).} =
  let signal = ThreadSignalPtr.new().valueOr:
    return err("plum: cannot create signal: " & $error)

  let handle = MappingHandle(
    signal: signal,
    onStateChange: onStateChange
  )

  var req = plum_mapping_t(
    protocol: plum_ip_protocol_t(protocol.int),
    internal_port: internalPort,
    external_port: externalPort,
    user_ptr: cast[pointer](handle)
  )

  let id = plum_create_mapping(addr req, mappingCallback)
  if id < 0:
    discard signal.close()
    return err("plum_create_mapping failed: " & $id)

  withSafeLock:
    activeMappings[id] = handle

  var completed = false
  try:
    # Wait for the callback to fireSync
    completed = await withTimeout(signal.wait(), seconds(30))
  except CancelledError:
    raise
  finally:
    if not completed:
      # The signal reached timeout or was cancelled,
      # we cannot close it now otherwise the pending operation
      # might trigger a memory issue.
      # When entering into DESTROYING state, libplum will ignore
      # the pending operation so closing the signal in the DESTROYED
      # callback is safe.
      handle.abandoned.store(true)
      discard plum_destroy_mapping(id)
    else:
      # The signal is completed, we can close it
      discard signal.close()
      
  if not completed:  
    return err("plum: mapping " & $id & " timed out")

  if handle.resolvedState == Success:
    return ok(MappingResult(id: id, mapping: handle.resolvedMapping))
  else:
    discard plum_destroy_mapping(id)
    return err("plum: mapping " & $id & " failed")

proc destroyMapping*(id: cint) {.raises: [].} =
  ## Must be called exactly once after a successful createMapping.
  discard plum_destroy_mapping(id)

proc getLocalAddress*(): Result[string, string] {.raises: [].} =
  var buf = newString(PLUM_MAX_ADDRESS_LEN)
  let res = plum_get_local_address(buf.cstring, buf.len.csize_t)
  if res >= 0:
    buf.setLen(min(res, PLUM_MAX_ADDRESS_LEN))
    ok(buf)
  else:
    err("plum_get_local_address failed: " & $res)
