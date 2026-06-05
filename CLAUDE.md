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
- Never call `ThreadSignalPtr.close()` from the C thread: close() unregisters
  the fd from the *calling* thread's dispatcher; only the chronos loop thread
  may close a signal
- `MappingHandle` is pinned with `GC_ref` while libplum holds `user_ptr`;
  unpinned only in the DESTROYED callback
- `activeMappings` is guarded by `activeMappingsLock` (`withSafeLock`)
