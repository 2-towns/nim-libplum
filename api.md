# API Reference

## Types

```nim
type PlumProtocol* = enum
  TCP
  UDP
```

```nim
type PlumState* = enum
  Destroyed
  Pending
  Success
  Failure
  Destroying
```

```nim
type MappingProtocol* = enum
  Unknown  ## not yet determined (mapping pending)
  PCP      ## Port Control Protocol
  NatPmp   ## NAT Port Mapping Protocol
  UPnP     ## UPnP-IGD
  Direct   ## no mapping needed, local address is already public
```

```nim
type ProtocolFilter* {.pure.} = enum
  Any   ## try all protocols (default)
  PCP   ## PCP/NAT-PMP only
  UPnP  ## UPnP only
```

```nim
type PlumMapping* = object
  protocol*: PlumProtocol        ## IP protocol (TCP/UDP)
  mappingProtocol*: MappingProtocol  ## NAT traversal protocol used
  internalPort*: uint16
  externalPort*: uint16
  externalHost*: string
```

```nim
type MappingResult* = object
  id*: cint
  mapping*: PlumMapping
```

```nim
type PlumStateCallback* =
  proc(state: PlumState, mapping: PlumMapping) {.cdecl, raises: [], gcsafe.}
```

## Procedures

### init

```nim
proc init*(
    logLevel: plum_log_level_t = PLUM_LOG_LEVEL_NONE,
    discoverTimeout: int = 0,
    mappingTimeout: int = 0,
    recheckPeriod: int = 0,
    protocol: ProtocolFilter = ProtocolFilter.Any
): Result[void, string]
```

Initializes the library and starts the internal thread. Must be called before any other proc.

- `logLevel`: verbosity of internal logs, from `PLUM_LOG_LEVEL_VERBOSE` to `PLUM_LOG_LEVEL_NONE` (default: none); import `libplum/libplum` to access these constants
- `discoverTimeout`: how long to probe for a NAT device, in ms (default: 10000)
- `mappingTimeout`: how long to wait for a mapping response, in ms (default: 10000)
- `recheckPeriod`: interval between periodic mapping rechecks, in ms (default: 300000)
- `protocol`: restrict discovery to a single family (`ProtocolFilter.PCP` for PCP/NAT-PMP, `ProtocolFilter.UPnP` for UPnP); `ProtocolFilter.Any` tries all (default)

### cleanup

```nim
proc cleanup*(): Result[void, string]
```

Stops the internal thread and releases all resources. Returns an error if called more than once or before `init`.

### createMapping

```nim
proc createMapping*(
    protocol: PlumProtocol,
    internalPort: uint16,
    externalPort: uint16 = 0,
    timeout: Duration = seconds(30),
    onStateChange: PlumStateCallback = nil
): Future[Result[MappingResult, string]]
```

Requests a port mapping from the NAT device. Tries PCP, then NAT-PMP, then UPnP-IGD in order.

- `protocol`: `TCP` or `UDP`
- `internalPort`: the local port to map
- `externalPort`: preferred external port, or 0 to let the router choose
- `timeout`: how long to wait for the mapping to be established (default: 30s)
- `onStateChange`: optional callback invoked when the mapping state changes after the initial result

Returns a `MappingResult` containing the mapping `id` (needed for `destroyMapping`) and the `PlumMapping` with the external address, port, and `mappingProtocol` indicating which protocol was used (`PCP`, `NatPmp`, or `UPnP`).

Returns an error if no NAT device is found, the mapping fails, or the timeout expires.

> **Warning:** `onStateChange` runs on libplum's internal C thread, not the
> chronos event loop. Do not call chronos APIs or touch non-thread-safe state
> from it; restrict it to thread-safe operations (e.g. `Atomic`, a channel).

### destroyMapping

```nim
proc destroyMapping*(id: cint)
```

Removes a mapping. Call it after a successful `createMapping`, otherwise the
mapping's internal handle is leaked for the lifetime of the process. Calling it
again, or with an unknown `id`, is a safe no-op. `cleanup` also releases any
mappings still active.

### hasMapping

```nim
proc hasMapping*(id: cint): bool
```

Returns true if the mapping exists and has not been destroyed yet.

### getLocalAddress

```nim
proc getLocalAddress*(): Result[string, string]
```

Returns the local IP address as seen from the network interface. Useful to check whether the machine already has a public IP (in which case no NAT mapping is needed).
