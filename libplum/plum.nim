# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/atomics
import chronos
import chronos/threadsync
import results
import ./libplum

# libplum declares some parameters as `const T*` in C (read-only pointer).
# Nim has no equivalent, so the generated C code drops the `const`, causing
# a type mismatch warning in GCC 15+. This pragma suppresses that warning
# only in this translation unit and is valid for both C and C++.
{.
  emit: """
#ifdef __GNUC__
#pragma GCC diagnostic ignored "-Wincompatible-pointer-types"
#endif
"""
.}

export results

{.pragma: callback, cdecl, raises: [], gcsafe.}

{.push raises: [].}

type
  PlumProtocol* = enum
    TCP = PLUM_IP_PROTOCOL_TCP.int
    UDP = PLUM_IP_PROTOCOL_UDP.int

  PlumLogLevel* {.pure.} = enum
    Verbose = PLUM_LOG_LEVEL_VERBOSE.int
    Debug = PLUM_LOG_LEVEL_DEBUG.int
    Info = PLUM_LOG_LEVEL_INFO.int
    Warn = PLUM_LOG_LEVEL_WARN.int
    Error = PLUM_LOG_LEVEL_ERROR.int
    Fatal = PLUM_LOG_LEVEL_FATAL.int
    None = PLUM_LOG_LEVEL_NONE.int

  PlumState* = enum
    Destroyed = PLUM_STATE_DESTROYED.int
    Pending = PLUM_STATE_PENDING.int
    Success = PLUM_STATE_SUCCESS.int
    Failure = PLUM_STATE_FAILURE.int
    Destroying = PLUM_STATE_DESTROYING.int

  MappingProtocol* = enum
    Unknown = PLUM_MAPPING_PROTOCOL_UNKNOWN.int
    PCP = PLUM_MAPPING_PROTOCOL_PCP.int
    NatPmp = PLUM_MAPPING_PROTOCOL_NATPMP.int
    UPnP = PLUM_MAPPING_PROTOCOL_UPNP.int
    Direct = PLUM_MAPPING_PROTOCOL_DIRECT.int

  PlumMapping* = object
    protocol*: PlumProtocol
    mappingProtocol*: MappingProtocol
    internalPort*: uint16
    externalPort*: uint16
    externalHost*: string

  MappingResult* = object
    id*: cint
    mapping*: PlumMapping

  PlumStateCallback* = proc(state: PlumState, mapping: PlumMapping) {.callback.}
    ## Invoked on mapping state changes after the initial result. Runs on
    ## libplum's internal C thread, not the chronos loop: only touch
    ## thread-safe state from it (e.g. Atomic), never chronos APIs.

  MappingHandle = ref object
    signal: ThreadSignalPtr
    # Indicate that the first call of the mapping handle is
    # done. In that case, resolved* variables
    # will contain the result.
    # MappingHandle can be called multiple times after that,
    # but the result will be passed through the callback.
    resolved: Atomic[bool]
    resolvedState: PlumState
    resolvedProtocol: PlumProtocol
    resolvedMappingProtocol: MappingProtocol
    resolvedInternalPort: uint16
    resolvedExternalPort: uint16
    resolvedExternalHost: array[PLUM_MAX_HOST_LEN, char]
    onStateChange: PlumStateCallback

# libplum calls mappingCallback from its own C thread. Under refc, any thread
# that touches Nim objects must register with the GC first.
template foreignThreadGc(body: untyped) =
  when declared(setupForeignThreadGc):
    setupForeignThreadGc()
  try:
    body
  finally:
    when declared(tearDownForeignThreadGc):
      tearDownForeignThreadGc()

# Keep a counter for convenience for testing
# and exposed as an API over activeMappingCount()
var activeMappings: Atomic[int]

proc mappingCallback(id: cint, state: plum_state_t, raw: ptr plum_mapping_t) {.cdecl.} =
  ## Called from libplum's internal C thread on SUCCESS, FAILURE, and DESTROYED.

  foreignThreadGc:
    let handle = cast[MappingHandle](raw[].user_ptr)
    if handle.isNil:
      return

    let plumState = PlumState(state.int)
    if plumState == Destroyed:
      discard activeMappings.fetchSub(1)

      if not handle.resolved.exchange(true):
        # Set Destroyed state and fire the signal to notify any waiting threads.
        handle.resolvedState = Destroyed
        discard handle.signal.fireSync()

      # Release the pin set in createMapping: the C library is done with the
      # raw pointer and will never call this callback again for this mapping.
      GC_unref(handle)
      return

    # Skip states other than Success and Failure
    if plumState notin {Success, Failure}:
      return

    if not handle.resolved.exchange(true):
      # If this is the first time the handle mapping
      # is called, let's set the result in the handle values,
      # and fire the signal.
      handle.resolvedState = plumState
      handle.resolvedProtocol = PlumProtocol(raw[].protocol.int)
      handle.resolvedMappingProtocol = MappingProtocol(raw[].mapping_protocol.int)
      handle.resolvedInternalPort = raw[].internal_port
      handle.resolvedExternalPort = raw[].external_port
      handle.resolvedExternalHost = raw[].external_host
      discard handle.signal.fireSync()
    else:
      # Otherwise, just call the callback
      if not handle.onStateChange.isNil:
        let mapping = PlumMapping(
          protocol: PlumProtocol(raw[].protocol.int),
          mappingProtocol: MappingProtocol(raw[].mapping_protocol.int),
          internalPort: raw[].internal_port,
          externalPort: raw[].external_port,
          externalHost: $cast[cstring](addr raw[].external_host),
        )
        handle.onStateChange(plumState, mapping)

proc init*(
    logLevel: PlumLogLevel = PlumLogLevel.None,
    discoverTimeout: int32 = 0,
    mappingTimeout: int32 = 0,
    recheckPeriod: int32 = 0,
): Result[void, string] =
  ## init MUST be called to setup internal plum thread (plum_init).

  var config = plum_config_t(
    log_level: plum_log_level_t(logLevel.int),
    log_callback: nil,
    dummytls_domain: nil,
    discover_timeout: discoverTimeout.cint,
    mapping_timeout: mappingTimeout.cint,
    recheck_period: recheckPeriod.cint,
  )

  let res = plum_init(addr config)
  if res == PLUM_ERR_SUCCESS:
    ok()
  else:
    err("plum_init failed: " & $res)

proc cleanup*(): Result[void, string] =
  ## cleanup MUST be called to stop the thread and clean the setup.

  let res = plum_cleanup()
  if res == PLUM_ERR_SUCCESS:
    ok()
  else:
    err("plum_cleanup failed: " & $res)

const destroyConfirmTimeout = seconds(5)

proc destroyAndReclaim(id: cint, signal: ThreadSignalPtr) {.async: (raises: []).} =
  ## Tear the mapping down and close its signal once DESTROYED confirms
  ## (the signal fires exactly once, see mappingCallback). If libplum never
  ## confirms in time, leak the signal rather than closing it while the C
  ## thread may still fire it.
  discard plum_destroy_mapping(id)
  if await noCancel withTimeout(signal.wait(), destroyConfirmTimeout):
    discard signal.close()

proc createMapping*(
    protocol: PlumProtocol,
    internalPort: uint16,
    externalPort: uint16 = 0,
    timeout: Duration = seconds(30),
    onStateChange: PlumStateCallback = nil,
): Future[Result[MappingResult, string]] {.async: (raises: [CancelledError]).} =
  let signal = ThreadSignalPtr.new().valueOr:
    return err("plum: cannot create signal: " & $error)

  let handle = MappingHandle(signal: signal, onStateChange: onStateChange)

  var req = plum_mapping_t(
    protocol: plum_ip_protocol_t(protocol.int),
    internal_port: internalPort,
    external_port: externalPort,
    user_ptr: cast[pointer](handle),
  )

  # Pin the handle to prevent GC: the C library holds a raw pointer to
  # it (user_ptr) and might use it until DESTROYED fires.
  GC_ref(handle)

  let id = plum_create_mapping(addr req, mappingCallback)
  if id < 0:
    GC_unref(handle)
    discard signal.close()
    return err("plum_create_mapping failed: " & $id)

  discard activeMappings.fetchAdd(1)

  var completed = false
  try:
    # Wait for the signal's single fire (in mappingCallback)
    completed = await withTimeout(signal.wait(), timeout)
  except CancelledError:
    # The signal was cancelled so it is safe to destroy and reclaim.
    await destroyAndReclaim(id, signal)
    raise

  if not completed:
    # The signal was not fired so it is safe to destroy and reclaim.
    await destroyAndReclaim(id, signal)
    return err("plum: mapping " & $id & " timed out")

  # The signal fired and was consumed: nobody will touch it again,
  # safe to close here.
  discard signal.close()

  let resolvedState = handle.resolvedState
  let resolvedMapping = PlumMapping(
    protocol: handle.resolvedProtocol,
    mappingProtocol: handle.resolvedMappingProtocol,
    internalPort: handle.resolvedInternalPort,
    externalPort: handle.resolvedExternalPort,
    externalHost: $cast[cstring](unsafeAddr handle.resolvedExternalHost),
  )

  if resolvedState == Success:
    return ok(MappingResult(id: id, mapping: resolvedMapping))
  elif resolvedState == Destroyed:
    return err("plum: mapping " & $id & " destroyed before completion")
  else:
    discard plum_destroy_mapping(id)
    return err("plum: mapping " & $id & " failed")

proc destroyMapping*(id: cint) =
  ## Releases a mapping created by createMapping. Safe to call again or
  ## with an unknown id.
  # libplum locks internally and ignores unknown ids: no wrapper-side
  # bookkeeping needed.
  discard plum_destroy_mapping(id)

proc hasMapping*(id: cint): bool =
  ## Returns true if the mapping exists and is not being destroyed.
  var st: plum_state_t
  if plum_query_mapping(id, addr st, nil) == PLUM_ERR_SUCCESS:
    PlumState(st.int) notin {Destroying, Destroyed}
  else:
    false

proc activeMappingCount*(): int =
  ## Number of mappings the wrapper still tracks. Drops to 0 once every
  ## mapping has fired DESTROYED.
  activeMappings.load()

proc getLocalAddress*(): Result[string, string] =
  var buf = newString(PLUM_MAX_ADDRESS_LEN)
  let res = plum_get_local_address(buf.cstring, buf.len.csize_t)
  if res >= 0:
    buf.setLen(min(res.int, PLUM_MAX_ADDRESS_LEN))
    ok(buf)
  else:
    err("plum_get_local_address failed: " & $res)

{.pop.}
