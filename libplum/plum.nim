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
import libplum

{.localPassC: libplum.flags.}

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
    TCP = ord(PLUM_IP_PROTOCOL_TCP)
    UDP = ord(PLUM_IP_PROTOCOL_UDP)

  ProtocolFilter* {.pure.} = enum
    Any = ord(PLUM_PROTOCOL_ANY)
    PCP = ord(PLUM_PROTOCOL_PCP)
    UPnP = ord(PLUM_PROTOCOL_UPNP)

  PlumLogLevel* {.pure.} = enum
    Verbose = ord(PLUM_LOG_LEVEL_VERBOSE)
    Debug = ord(PLUM_LOG_LEVEL_DEBUG)
    Info = ord(PLUM_LOG_LEVEL_INFO)
    Warn = ord(PLUM_LOG_LEVEL_WARN)
    Error = ord(PLUM_LOG_LEVEL_ERROR)
    Fatal = ord(PLUM_LOG_LEVEL_FATAL)
    None = ord(PLUM_LOG_LEVEL_NONE)

  PlumState* = enum
    Destroyed = ord(PLUM_STATE_DESTROYED)
    Pending = ord(PLUM_STATE_PENDING)
    Success = ord(PLUM_STATE_SUCCESS)
    Failure = ord(PLUM_STATE_FAILURE)
    Destroying = ord(PLUM_STATE_DESTROYING)

  MappingProtocol* = enum
    Unknown = ord(PLUM_MAPPING_PROTOCOL_UNKNOWN)
    PCP = ord(PLUM_MAPPING_PROTOCOL_PCP)
    NatPmp = ord(PLUM_MAPPING_PROTOCOL_NATPMP)
    UPnP = ord(PLUM_MAPPING_PROTOCOL_UPNP)
    Direct = ord(PLUM_MAPPING_PROTOCOL_DIRECT)

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

  MappingHandleObj = object
    signal: ThreadSignalPtr
    # Define a release pattern.
    # The handle object can be manipulated by 2 threads:
    # 1. The chronos thread that calls createMapping and waits for the result.
    # 2. The libplum thread that calls mappingCallback.
    # When the handle is released by both, the handle can be deallocated.
    released: Atomic[bool]
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

  MappingHandle = ptr MappingHandleObj

proc release(handle: MappingHandle) =
  ## release will deallocate the handle if the handle is released
  ## by both the chronos thread and the libplum thread.
  if handle.released.exchange(true):
    deallocShared(handle)

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

    # We can be in a Destroyed state if:
    # 1. destroyMapping or cleanup is called.
    # 2. The mapping is destroyed by destroyAndReclaim after a timeout or a cancellation.
    # A waiter may still be there in either case, since cleanup can land while
    # createMapping is suspended, so the gate below decides and not the case.
    if plumState == Destroyed:
      discard activeMappings.fetchSub(1)

      # Fire only if nobody claimed the signal's single fire yet. If it was
      # already claimed, createMapping has closed the signal and firing here
      # would be a use-after-free.
      if not handle.resolved.exchange(true):
        handle.resolvedState = Destroyed
        discard handle.signal.fireSync()

      # Release the handle: the mapping is destroyed and libplum will never call
      # this callback again. If the chronos thread released it already, this
      # deallocates it. Otherwise the chronos thread will.
      handle.release()
      return

    # Skip states other than Success and Failure (not expected)
    if plumState notin {Success, Failure}:
      return

    # Again, only the first to claim the fire records the result.
    if not handle.resolved.exchange(true):
      handle.resolvedState = plumState
      handle.resolvedProtocol = PlumProtocol(raw[].protocol.int)
      handle.resolvedMappingProtocol = MappingProtocol(raw[].mapping_protocol.int)
      handle.resolvedInternalPort = raw[].internal_port
      handle.resolvedExternalPort = raw[].external_port
      handle.resolvedExternalHost = raw[].external_host

      # Fire the signal to notify the chronos thread that the mapping is resolved.
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
    protocol: ProtocolFilter = ProtocolFilter.Any,
): Result[void, string] =
  ## init MUST be called to setup internal plum thread (plum_init).
  ## protocol restricts discovery to a single family (PCP/NAT-PMP or UPnP);
  ## ProtocolFilter.Any tries all.

  var config = plum_config_t(
    log_level: plum_log_level_t(logLevel.int),
    log_callback: nil,
    dummytls_domain: nil,
    discover_timeout: discoverTimeout.cint,
    mapping_timeout: mappingTimeout.cint,
    recheck_period: recheckPeriod.cint,
    protocol: plum_protocol_t(protocol.int),
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

proc destroyAndReclaim(id: cint, handle: MappingHandle) {.async: (raises: []).} =
  ## destroyAndReclaim is called when createMapping gives up on a mapping it
  ## created, on timeout or on cancellation.
  ## In that case we destroy the mapping created and then we release the handle.

  discard plum_destroy_mapping(id)

  # Wait for the libplum thread to fire the destroy signal.
  if await noCancel withTimeout(handle.signal.wait(), destroyConfirmTimeout):
    # Receiving the single fire proves the callback is past, so closing is safe.
    # Otherwise we never close it: the libplum thread may still fire.
    discard handle.signal.close()

  # If the libplum thread is stuck, this release is the first one and frees
  # nothing: the libplum thread will deallocate when DESTROYED finally fires.
  # This is expected! We do not want to deallocate it while the libplum thread
  # could still use it.
  handle.release()

proc createMapping*(
    protocol: PlumProtocol,
    internalPort: uint16,
    externalPort: uint16 = 0,
    timeout: Duration = seconds(30),
    onStateChange: PlumStateCallback = nil,
): Future[Result[MappingResult, string]] {.async: (raises: [CancelledError]).} =
  let signal = ThreadSignalPtr.new().valueOr:
    return err("plum: cannot create signal: " & $error)

  # Create a shared handle to be used by both the chronos thread and the libplum thread.
  let handle = createShared(MappingHandleObj)
  handle.signal = signal
  handle.onStateChange = onStateChange

  var req = plum_mapping_t(
    protocol: plum_ip_protocol_t(protocol.int),
    internal_port: internalPort,
    external_port: externalPort,
    user_ptr: cast[pointer](handle),
  )

  let id = plum_create_mapping(addr req, mappingCallback)
  if id < 0:
    # The callback might still be called even when creation reports failure.
    # So we use release instead of deallocShared to avoid a use-after-free.
    handle.release()
    return err("plum_create_mapping failed: " & $id)

  discard activeMappings.fetchAdd(1)

  var completed = false
  try:
    # Wait for the signal's single fire (in mappingCallback)
    completed = await withTimeout(signal.wait(), timeout)
  except CancelledError:
    # The chronos thread was cancelled.
    # Here we have 2 situations:
    # 1. DESTROYED already fired, so libplum released the handle and our own
    # release deallocates it.
    # 2. DESTROYED has not fired yet, so we only mark the handle as released
    # and let the libplum thread deallocate it from the callback.
    await destroyAndReclaim(id, handle)
    raise

  if not completed:
    # The mapping timed out.
    # Same as previously.
    await destroyAndReclaim(id, handle)
    return err("plum: mapping " & $id & " timed out")

  # We are done with the signal, we can just close it because we will not use it anymore.
  discard signal.close()

  let resolvedState = handle.resolvedState
  let resolvedMapping = PlumMapping(
    protocol: handle.resolvedProtocol,
    mappingProtocol: handle.resolvedMappingProtocol,
    internalPort: handle.resolvedInternalPort,
    externalPort: handle.resolvedExternalPort,
    externalHost: $cast[cstring](unsafeAddr handle.resolvedExternalHost),
  )

  # Release the handle. On a live mapping libplum still holds it, so this only
  # marks it: the DESTROYED callback is the one that deallocates, later.
  handle.release()

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
