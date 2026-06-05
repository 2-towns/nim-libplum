# nim-libplum

Nim binding for libplum (PCP / NAT-PMP / UPnP-IGD port mapping), with a
chronos-based async wrapper.

## Commands

```bash
git submodule update --init   # vendor/libplum is required for everything
nimble test                   # builds vendor/libplum.a via cmake, then runs unit tests
nimble testIntegration        # miniupnpd integration tests in Docker/Podman (NET_ADMIN)
nimble format                 # nph on libplum/ and tests/
```

Debug env vars: `LIBPLUM_VERBOSE=1`, `TEST_VERBOSE=1`, `MINIUPNPD_VERBOSE=1`.

## Architecture

- `libplum/libplum.nim` — raw C bindings (importc), no logic
- `libplum/plum.nim` — public API: bridges libplum's C callback thread to chronos
- `tests/test_plum.nim` — unit suite + integration suites gated by `-d:miniupnp_protocol`
- `api.md` — user-facing API doc, keep in sync with plum.nim
- `vendor/libplum` — git submodule, built statically by nimble tasks

## Threading invariants (critical)

- `mappingCallback` runs on libplum's internal C thread, wrapped in
  `foreignThreadGc`; it must stay `raises: []` and only touch thread-safe state
- The mapping signal fires exactly once (first of SUCCESS/FAILURE/DESTROYED
  via `resolved.exchange`); `createMapping` owns it and closes it on the
  chronos loop thread after consuming that fire. Never call
  `ThreadSignalPtr.close()` from the C thread: close() unregisters the fd
  from the *calling* thread's dispatcher
- `MappingHandle` is pinned with `GC_ref` while libplum holds `user_ptr`;
  unpinned only in the DESTROYED callback
- `activeMappings` is an `Atomic[int]` counting pinned handles; libplum is the source of truth for mapping state
  (`hasMapping`)
- The wrapper relies on a libplum guarantee: DESTROYED fires exactly once for
  every created mapping (explicit destroy, or `destroy_all_mappings` during
  `plum_cleanup`, synchronously before it returns), verified in
  `vendor/libplum/src/client.c`. Re-verify this when bumping the submodule
