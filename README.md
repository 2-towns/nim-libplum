# nim-libplum

Nim binding for [libplum](https://github.com/paullouisageneau/libplum), a portable C library for NAT port mapping via PCP, NAT-PMP, and UPnP-IGD.

libplum tries each protocol in order (PCP → NAT-PMP → UPnP-IGD) and falls back automatically. If the local address is already public, it uses it directly.

## Installation

Clone with submodules:

```bash
git clone --recurse-submodules <REPO_URL>
```

Or after cloning:

```bash
git submodule update --init --recursive
```

Install via Nimble:

```bash
nimble install
```

## Usage

```nim
import chronos
import libplum/plum

proc main() {.async.} =
  check init().isOk()

  let r = await createMapping(TCP, 8080)
  if r.isErr():
    echo "failed: ", r.error
    return

  let res = r.value
  echo "external: ", res.mapping.externalHost, ":", res.mapping.externalPort

  destroyMapping(res.id)
  discard cleanup()

waitFor main()
```

See the [examples](examples) directory for a complete example.

### Ongoing state changes

Pass an `onStateChange` callback to `createMapping` to be notified when the mapping is renewed or lost:

```nim
proc onStateChange(state: PlumState, mapping: PlumMapping) {.cdecl, raises: [], gcsafe.} =
  echo "state changed: ", state, " external: ", mapping.externalHost, ":", mapping.externalPort

let r = await createMapping(TCP, 8080, onStateChange = onStateChange)
```

### Configurable timeouts

The discovery and mapping timeouts can be configured via `init`:

```nim
discard init(
  discoverTimeout = 5000,  # ms, default 10000
  mappingTimeout  = 5000,  # ms, default 10000
  recheckPeriod   = 60000, # ms, default 300000
)
```

## License

Licensed and distributed under either of

* MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT
* Apache License, Version 2.0: [LICENSE-APACHEv2](LICENSE-APACHEv2) or http://www.apache.org/licenses/LICENSE-2.0

at your option.
