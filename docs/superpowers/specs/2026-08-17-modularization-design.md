# PotatoVoxel Modularization and Legacy Reduction Design

**Status:** behavior-preserving refactor plan

**Goal:** reduce duplicated and unreachable code while giving each major
feature a focused boundary that can be edited and tested without changing the
runtime composition root or unrelated features.

## Current evidence

The audit covered the shipped Lua modules, data files, tests, architecture
documents, and recent release history. The main structural risks are:

- `main.lua` is the composition root, hook installer, render-pipeline owner,
  settings schema, input adapter, cache gate, and diagnostics coordinator in
  one 1,842-line file.
- `Structures.lua` combines map analysis, object detection, building/relief
  construction, figure extraction, vegetation, and global template caches in
  3,892 lines.
- `ChunkMesher.lua` combines pure geometry generation, queue scheduling,
  sliced execution, GPU upload, runtime mesh lifetime, and cache handoff.
- `MeshCache.lua` combines storage access, compression, identity, manifests,
  validation, and payload serialization.
- `DebugOverlay.lua` combines the diagnostic ring buffer, counters, status
  snapshots, network transport, settings rows, and HUD rendering.
- The same packed coordinate key was implemented independently in Structures,
  Buildings, ShapeDebug, and ChunkMesher. The first refactor slice moves this
  contract into `lib/GridKey.lua`.
- VR is explicitly removed and `VR.supported()` is permanently false, while
  dormant VR camera, battle, scene, input, and Pokedex paths remain in the
  shipped code. These paths require characterization before deletion.
- Buildings still carries a disabled `Perf` object after the diagnostics Perf
  surface was removed.

## Design principles

1. Preserve observable behavior, cache bytes, hook ordering, settings keys,
   engine-facing exports, and fallback behavior.
2. Move one ownership boundary at a time; every move must leave the mod
   loadable and the headless suites green.
3. Keep `main.lua` as a thin composition root. Feature modules receive a
   narrow context and expose explicit `install`, `update`, `draw`, or service
   methods instead of reaching through unrelated module internals.
4. Keep pure geometry and policy code independent from engine storage,
   graphics, and hook registration wherever the existing behavior permits.
5. Use compatibility facades during migration. Consumers keep their existing
   module names while internals move behind them; facade removal is a later,
   separately verified step.
6. Do not introduce a generic service locator or a new dependency framework.
   The existing `V.require` loader remains the sandbox boundary.

## Target architecture

```text
main.lua (composition root)
  ├── RuntimeHooks      lifecycle and engine hook registration
  ├── SettingsFeature   rows, presets, hotkeys, and option synchronization
  ├── CacheFeature       cache readiness gate and prebuild screen wiring
  ├── WorldFeature       voxel pipeline update/draw coordination
  ├── BattleFeature      staged battle and battle-exit hooks
  └── DiagnosticsFeature overlay lifecycle and log export hooks

domain / services
  ├── GridKey            shared coordinate-key contract
  ├── GeometryBuilder    pure map-to-stream geometry
  ├── MeshQueue          sliced scheduling and job state
  ├── MeshRuntime        GPU mesh ownership and live-set eviction
  ├── CacheStorage       storage and codec boundary
  ├── CacheIdentity      build identity and invalidation policy
  ├── CacheManifest      completion records and resume scans
  └── Diagnostics        ring, counters, status, transport, and panel
```

The existing `ChunkMesher`, `MeshCache`, and `DebugOverlay` names remain as
facades until their consumers have moved. This keeps changes localized: a
cache format edit stays inside cache services, a queue-budget edit stays in
mesh scheduling, and a diagnostic-panel edit stays outside geometry code.

## Refactor sequence

### Phase 1: shared primitives and dead seams

- Centralize packed coordinate keys in `GridKey`.
- Remove the disabled `Perf` compatibility object after confirming no runtime
  exporter or test consumes it.
- Add characterization checks for the permanently disabled VR surface before
  deciding whether to delete the façade and dormant branches.

Phase 1 characterization result: the VR façade loads through `main.lua`, which
still assigns the shared `cycleVoxel` callback; `OverworldBattle` and
`ThirdPerson` also retain guarded lazy reads. The public `supported`, `enabled`,
`active`, mirror, update, and invalidate behavior is permanently inert, but
the façade and the compatibility callback are still reachable. Keep them for
now. A source scan after the Perf removal finds no remaining `Perf` symbol or
diagnostic counter name in the shipped Lua/tests.

### Phase 2: composition-root extraction

Extract cohesive modules from `main.lua` while preserving registration order:

- lifecycle and engine wrappers;
- settings schema, rows, presets, and hotkeys;
- cache readiness/consent gate;
- diagnostics and log-send hooks.

Each extracted module receives the existing `V` namespace and a small context
record containing only the engine objects it currently uses. The composition
root continues to install features in the current order and keeps the same
exports.

### Phase 3: cache and meshing boundaries

Split services behind the current facades:

- `MeshCache` → storage/codec, identity, manifest/resume, and payload API;
- `ChunkMesher` → pure geometry builder, queue/budget scheduler, and runtime
  mesh/GPU ownership.

The worker protocol remains unchanged. Serial and threaded builds must produce
the same stream counts, fingerprints, manifest records, and fallback results.

### Phase 4: diagnostics boundary

Split `DebugOverlay` into a data-only diagnostic store, transport scheduler,
capability/status snapshot, and optional HUD panel. The public logging calls
remain compatible while the panel and network code stop being dependencies of
cache and rendering internals.

### Phase 5: geometry decomposition

Only after characterization coverage is strong, split `Structures` into map
analysis, specialist builders, and reusable template caches. `Buildings` is
the first specialist boundary because it already has a distinct profile and
reference implementation. The public `Structures.forMap()` result remains
stable while internals move.

## Verification contract

Before each phase, run the current baseline suites. After each extraction,
run the affected focused suite and then the complete suite:

- `potato_voxel_cache_test.lua` for cache, geometry, and prebuild behavior;
- `potato_voxel_test.lua` for settings, rendering policy, diagnostics, and
  feature behavior;
- `voxel_loading_test.lua` and `shadow_runtime_test.lua` for runtime seams;
- sandbox API scan, Lua syntax checks, mod lint, and mod pack checks.

For cache/geometry moves, compare job records and stream counts before and
after on the same fixtures. For deleted or dormant-code moves, prove there
are no string-based loader references, exports, hooks, or test seams before
removing the code.

## Explicit non-goals

- No new rendering features, cache format changes, or performance claims.
- No behavior changes to quality modes, battle staging, VR settings keys, or
  fallback paths during the structural migration.
- No broad rewrite of the hand-authored voxel profile data.
- No deletion of historical documentation until current behavior and public
  extension points are updated to match.
