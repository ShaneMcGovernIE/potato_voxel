# PotatoVoxel Modularization and Legacy Reduction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce duplicated and unreachable mod code while preserving runtime behavior, cache compatibility, hook order, settings keys, and engine-facing exports.

**Architecture:** Keep `main.lua` as the composition root. Move shared contracts and cohesive feature ownership behind small modules loaded through the existing `V.require` boundary. Preserve the current public module names as facades while internals are split. Separate pure geometry, scheduling, persistence, runtime GPU ownership, and diagnostics data from their policies and adapters.

**Tech Stack:** Lua/LuaJIT, LÖVE, PotatoVoxel's sandbox loader, existing headless Lua test suites, mod lint/pack tooling.

## Global Constraints

- Preserve observable behavior, cache bytes, fingerprints, manifest records, settings keys, hook order, fallback behavior, and worker protocol.
- Use test-first characterization for each behavior boundary before changing ownership.
- Do not change hand-authored profile data or add rendering features.
- Do not delete VR or other dormant paths until reachability, exports, string-based loaders, hooks, and tests are characterized.
- Keep `V.require` as the sandbox boundary; do not introduce a service locator or dependency framework.
- Run focused tests after each task, then the complete verification suite before claiming a phase complete.

---

## Task 1: Centralize shared coordinate keys and remove the dead Perf seam

**Files:** `lib/GridKey.lua`, `lib/Structures.lua`, `lib/Buildings.lua`, `lib/ShapeDebug.lua`, `lib/ChunkMesher.lua`, `tests/potato_voxel_test.lua`, `docs/voxelization/01-world-model.md`, `docs/voxelization/12-porting-guide.md`, `docs/voxelization/13-extension-points.md`

- [x] Add `GridKey.of(tx, ty)` with the existing packed-coordinate contract and a documented Gen 1 coordinate window.
- [x] Replace local `keyOf` implementations and call sites in all four geometry-related modules.
- [x] Remove Buildings' disabled `Perf` shim and its no-op instrumentation counters.
- [x] Add boundary tests for the shared key contract.
- [x] Update the extension-point risk note to name the centralized contract.
- [x] Update world-model and porting docs so they no longer describe duplicated key helpers.
- [x] Run syntax checks, sandbox API scan, focused suites, and `git diff --check`.

## Task 2: Characterize dormant compatibility surfaces before deletion

**Files:** `lib/VR.lua`, `main.lua`, `lib/VoxelScene.lua`, `lib/BattleScene.lua`, `lib/Pokedex.lua`, `tests/potato_voxel_test.lua`, `docs/adr/0004-feature-removals.md`

- [x] Add characterization tests for `VR.supported()`, `VR.enabled()`, `VR.active()`, and its no-op lifecycle methods.
- [x] Enumerate all VR references, settings keys, exports, hook registrations, and dynamic loader strings.
- [x] Trace the remaining Perf references and confirm the diagnostics surface is absent from runtime exports.
- [x] Record which dormant branches are safe to remove and which must remain as compatibility guards.
- [ ] Remove only proven-dead compatibility code, with a focused regression test for every deleted public seam.

## Task 3: Extract lifecycle and settings ownership from `main.lua`

**Files:** `main.lua`, new `lib/RuntimeHooks.lua`, new `lib/SettingsFeature.lua`, tests covering settings and runtime loading

- [ ] Characterize current hook registration order and the exact settings row/preset/hotkey behavior.
- [x] Add `RuntimeHooks.wrapOnce` and use it for the apply-options and map-block wrappers without changing callback order or error handling.
- [ ] Move the remaining engine wrappers and hook registrations into `RuntimeHooks` after their order is characterized.
- [x] Extract settings schema, live settings summary, and settings-row ownership into `SettingsFeature`.
- [x] Pass an explicit context table from `main.lua`; keep module loading and exports unchanged.
- [ ] Verify settings, loading, runtime seam, and shadow suites before and after extraction.

## Task 4: Extract cache readiness and prebuild gating

**Files:** `main.lua`, `lib/MeshCache.lua`, new `lib/CacheFeature.lua`, relevant cache/prebuild tests

- [x] Characterize cache readiness states, consent/prebuild screen transitions, and fallback paths.
- [x] Move the cache gate and prebuild UI wiring into `CacheFeature` while preserving state transitions and messages.
- [x] Keep `MeshCache`'s current public API as a compatibility facade.
- [x] Verify cache payloads, manifest/resume behavior, and prebuild status under serial and worker paths.

## Task 5: Split cache storage, identity, and manifest services behind `MeshCache`

**Files:** `lib/MeshCache.lua`, new `lib/CacheStorage.lua`, new `lib/CacheIdentity.lua`, new `lib/CacheManifest.lua`, cache tests

- [x] Characterize cache file names, metadata, compression, validation, fingerprints, and incomplete-build resume records.
- [x] Move scoped-storage and byte/table fallback operations into `CacheStorage`.
- [x] Move build identity and invalidation rules into `CacheIdentity`.
- [x] Move manifest and resume-record handling into `CacheManifest`.
- [x] Keep `MeshCache` as the stable façade and compare serialized outputs against the baseline fixtures.

## Task 6: Split geometry, queue policy, and GPU ownership behind `ChunkMesher`

**Files:** `lib/ChunkMesher.lua`, new `lib/GeometryBuilder.lua`, new `lib/MeshQueue.lua`, new `lib/MeshRuntime.lua`, worker/thread tests

- [ ] Characterize stream counts, fingerprints, job ordering, budget slicing, worker messages, and runtime mesh eviction.
- [ ] Move map-to-stream construction into `GeometryBuilder` with no engine or queue dependencies.
- [ ] Move sliced scheduling and job state into `MeshQueue`.
- [ ] Move GPU mesh creation, live-set ownership, and eviction into `MeshRuntime`.
- [ ] Keep the worker protocol and `ChunkMesher` public calls stable; verify serial/threaded equivalence.

## Task 7: Split diagnostics data, transport, and presentation

**Files:** `lib/DebugOverlay.lua`, new diagnostics modules, `main.lua`, diagnostics tests

- [ ] Characterize ring-buffer retention, counters, status snapshots, network send timing, settings rows, and HUD output.
- [ ] Extract a data-only diagnostics store and preserve current logging calls.
- [ ] Extract transport scheduling and capability/status collection from HUD rendering.
- [ ] Keep overlay registration optional and prevent cache/meshing modules from depending on presentation code.
- [ ] Verify diagnostics behavior and sandbox API compliance.

## Task 8: Decompose Structures and complete verification

**Files:** `lib/Structures.lua`, `lib/Buildings.lua`, new specialist modules, docs and tests

- [ ] Characterize `Structures.forMap()` result shape, template cache identity, object/relief/vegetation ordering, and `Buildings` integration.
- [ ] Move analysis and specialist builders behind the existing Structures façade one boundary at a time.
- [ ] Preserve result ordering, cache keys, and all extension points.
- [ ] Run the complete suite, syntax checks, sandbox scan, mod lint, mod pack, and a final static reachability scan.
- [ ] Update the design spec and ADR notes with completed boundaries, retained compatibility seams, and known residual risks.

## Completion checklist

- [ ] All focused and complete suites pass with exit status zero.
- [ ] No unreviewed `keyOf` duplicates, disabled instrumentation shims, or new cross-feature imports remain.
- [ ] Cache and worker protocols remain compatible with the baseline.
- [ ] `git diff --check` and project lint/pack checks pass.
- [ ] Final review identifies any remaining legacy code explicitly instead of implying total removal.
