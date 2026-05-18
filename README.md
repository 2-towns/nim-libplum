# nim-libplum

Nim binding for [libplum](https://github.com/paullouisageneau/libplum), a portable C library for NAT port mapping via PCP, NAT-PMP, and UPnP-IGD.

libplum tries each protocol in order (PCP → NAT-PMP → UPnP-IGD) and falls back automatically. If the local address is already public, it uses it directly.

## Installation

```bash
git submodule update --init
nimble install
```

## Usage

```nim
import chronos
import libplum/plum

proc main() {.async.} =
  let initRes = init()
  if initRes.isErr():
    echo "init failed: ", initRes.error
    return

  let r = await createMapping(TCP, 8080)
  if r.isErr():
    echo "failed: ", r.error
    discard cleanup()
    return

  let res = r.value
  echo "external: ", res.mapping.externalHost, ":", res.mapping.externalPort
  echo "protocol: ", res.mapping.mappingProtocol  # PCP, NatPmp, UPnP, or Direct

  destroyMapping(res.id)
  discard cleanup()

waitFor main()
```

See [examples/port_mapping.nim](examples/port_mapping.nim) for a complete example that pauses between add and remove so you can verify the mapping on your router:

```bash
nim c -r examples/port_mapping.nim
```

### Timeouts

Pass timeout options to `init` to control how long discovery and mapping wait:

```nim
discard init(discoverTimeout = 5000, mappingTimeout = 10000)
```

Pass a `timeout` to `createMapping` to control the overall wait:

```nim
let r = await createMapping(TCP, 8080, timeout = seconds(15))
```

### Ongoing state changes

Pass an `onStateChange` callback to `createMapping` to be notified when the mapping is renewed or lost:

```nim
proc onStateChange(state: PlumState, mapping: PlumMapping) {.cdecl, raises: [], gcsafe.} =
  echo "state changed: ", state, " external: ", mapping.externalHost, ":", mapping.externalPort

let r = await createMapping(TCP, 8080, onStateChange = onStateChange)
```

### Checking mapping state

```nim
if hasMapping(id):
  echo "mapping is still active"
```

## API

See [api.md](api.md) for the full API reference.

## Testing

Basic tests run without a router:

```bash
nimble test
```

Integration tests run miniupnpd inside a Docker/Podman container and exercise the PCP and UPnP-IGD flows.
Podman or Docker as fallback will be used for testing with `NET_ADMIN` capability:

```bash
nimble testIntegration
```

This builds the image and runs three containers: PCP, UPnP, and a NAT-PMP fallback scenario
(miniupnpd compiled without PCP so libplum must fall back from PCP timeout to NAT-PMP).
Each protocol is tested under both `orc` and `refc` memory managers.
miniupnpd is built with a stub firewall backend (`tests/miniupnpd_stub_rdr.c`) so it accepts mapping requests without requiring iptables or nftables in the container.

Three env vars control verbosity:

- `TEST_VERBOSE=1`: print resolved external addresses
- `MINIUPNPD_VERBOSE=1`: print miniupnpd logs
- `LIBPLUM_VERBOSE=1`: enable verbose libplum internal logs

```bash
TEST_VERBOSE=1 MINIUPNPD_VERBOSE=1 LIBPLUM_VERBOSE=1 nimble testIntegration
```

## License

Licensed and distributed under either of

* MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT
* Apache License, Version 2.0: [LICENSE-APACHEv2](LICENSE-APACHEv2) or http://www.apache.org/licenses/LICENSE-2.0

at your option.
