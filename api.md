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
type PlumMapping* = object
  protocol*: PlumProtocol
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
    recheckPeriod: int = 0
): Result[void, string]
```

Initializes the library and starts the internal thread. Must be called before any other proc.

- `logLevel`: verbosity of internal logs (default: none)
- `discoverTimeout`: how long to probe for a NAT device, in ms (default: 10000)
- `mappingTimeout`: how long to wait for a mapping response, in ms (default: 10000)
- `recheckPeriod`: interval between periodic mapping rechecks, in ms (default: 300000)

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

Returns a `MappingResult` containing the mapping `id` (needed for `destroyMapping`) and the `PlumMapping` with the external address and port.

Returns an error if no NAT device is found, the mapping fails, or the timeout expires.

### destroyMapping

```nim
proc destroyMapping*(id: cint)
```

Removes a mapping. Must be called exactly once after a successful `createMapping`.

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
