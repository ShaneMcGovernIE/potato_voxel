# Codebase Review — 2026-08-17

This review records the current modularization state of PotatoVoxel and the
remaining seams worth touching. It is an engineering map, not runtime
configuration: the mod's load order, cache identity, and authored geometry
claim order remain behaviorally significant.

## Project at a glance

- **Purpose:** a performance-first 3D voxel diorama mod for the Pokémon Gen 1
  Recompilation. It is presentational; collision, warps, and scripts remain
  owned by the engine.
- **Version:** 1.7.11 (`manifest.json`).
- **Load model:** `main.lua` is the composition root. Runtime modules load
  through `V.require`, which keeps the code inside the mod sandbox and works
  when the mod is mounted from an archive.
- **Data path:** authored tile/profile data feeds `Structures`, then
  `GeometryBuilder`/`ChunkMesher`, then `VoxelScene` and the render passes.
- **Cache path:** `MeshCache` owns scoped-storage persistence and identity;
  `MeshRuntime` owns live GPU resources; `MeshQueue` owns queue state and
  budgeted pumping.

## Load-bearing pipeline

```
map blocks → TileShape
  → Structures.forMap (profile-pinned analysis and tile claims)
      buildings → cylinders → stairs → bookcases → figures → mounted
      → region flood → object extraction → volumes → grass → flowers
  → GeometryBuilder / ChunkMesher
  → VoxelScene (shadow → terrain → water → characters → grass)
```

The order is part of the geometry contract. Each specialist claims cells so
later passes cannot reinterpret them. The current refactors therefore leave
`Structures.forMap`, result ordering, cache keys, and compatibility entry
points intact while moving isolated algorithms behind narrow boundaries.

## Current module map

| Module | Lines | Responsibility |
|---|---:|---|
| `main.lua` | 1,517 | Composition root, hooks, settings schema, cache gate |
| `lib/Structures.lua` | 2,959 | Map analysis, claims, remaining authored geometry |
| `lib/ChunkMesher.lua` | 955 | Mesh orchestration, GPU upload, cache handoff |
| `lib/MeshCache.lua` | 1,246 | Scoped storage, identity, manifest, payload validation |
| `lib/Voxel3D.lua` | 1,655 | Camera, shading, fog, wireframe, world draw |
| `lib/VoxelScene.lua` | 1,343 | Render-pass composition |
| `lib/Water.lua` | 1,503 | Water planes, waves, reflections |
| `lib/DebugOverlay.lua` | 882 | Public diagnostics façade and optional HUD |
| `lib/DiagnosticsStore.lua` | 154 | Bounded diagnostic state and snapshots |
| `lib/DiagnosticsEnvironment.lua` | 123 | Platform, renderer, and identity capture |
| `lib/DiagnosticsTransport.lua` | 144 | Schema-3 payload, postLog lifecycle, retry/timeout |
| `lib/DiagnosticsBridge.lua` | 55 | Optional feature-to-diagnostics boundary |
| `lib/GeometryBuilder.lua` | 636 | Pure map-to-stream geometry emission |
| `lib/MeshQueue.lua` | 124 | Queue state, deduplication, budget pump, completion |
| `lib/MeshRuntime.lua` | 472 | GPU ownership and auxiliary stream lifecycle |
| `lib/VegetationBuilder.lua` | 415 | Grass and flower specialists |
| `lib/StairBuilder.lua` | 158 | Stair/riser/tread geometry specialist |
| `lib/BookcaseBuilder.lua` | 296 | Authored bookcase detection and relief |
| `lib/StructureMatcher.lua` | 34 | Shared authored-pattern matching |

## Refactoring completed

- Centralized cache identity, manifest, storage, feature orchestration, and
  runtime hooks without changing public mod exports.
- Extracted pure geometry emission from `ChunkMesher`; kept GPU upload and
  engine interaction at the orchestration boundary.
- Moved mesh eviction, auxiliary decode/release/swap, queue deduplication,
  completion, cancellation, and budget-slice policy into focused modules.
- Extracted diagnostics state, environment capture, optional feature logging,
  and remote transport from `DebugOverlay`. The overlay still exposes the
  existing `export`, `sendLogs`, `frame`, and status behavior.
- Extracted vegetation, stairs, and shared authored-pattern matching from
  `Structures`; compatibility wrappers preserve its existing call surface.
- Extracted bookcase detection and relief emission from `Structures`; the
  façade supplies claim state and the shared shade classifier.
- Removed the old `debug.getupvalue` animation fallback from `TerrainAtlas`.
  The sandbox-safe path now uses the exported engine animation counter when
  available, otherwise wall-clock animation.

## Deliberately retained seams

- `main.lua` remains a large composition root because hook registration,
  settings schema, and engine-facing callbacks are easier to audit together.
- `Structures.lua` still owns cylinders/round hulls, bookcases, relief,
  volume fill, region/object extraction, and the claim-order coordinator.
  These passes share mutable claim state and are not safe copy-and-paste
  candidates; extracting them without stronger characterization would risk
  geometry or cache regressions.
- `DebugOverlay` remains the public compatibility façade. `main.lua`, cache
  UI, and settings UI intentionally call it at the composition boundary;
  feature modules use `DiagnosticsBridge` instead.
- The threaded worker path remains separate from the sandbox-safe runtime
  path. `compute` is declared and worker/thread access is guarded so engines
  without worker support fall back to serial builds.
- VR and other dormant compatibility guards remain until their public callers
  are removed and the supported engine matrix is intentionally narrowed.

## Sandbox constraints

Runtime code does not use raw filesystem APIs, native interop, OS queries,
`debug`, or the removed LÖVE filesystem/system/event APIs. Scoped mod storage
and the declared engine services are the supported boundaries. The worker
implementation is the one special engine-managed path and is kept behind the
existing compute capability checks.

## Verification

The current source was tested through a temporary engine-root mount so the
tests load the repository copy without modifying the engine checkout:

| Gate | Result |
|---|---|
| Main headless suite | 351/351 checks |
| Cache suite | 194/194 checks |
| Sandbox API scan | clean |
| Shadow runtime | 16 passed, 0 failed |
| Shadow golden | 64 lines checked, 0 mismatches; 66 passed |
| Shadow cadence probe | passed |
| Voxel loading | passed |
| LuaJIT bytecode compilation | all `main.lua`, `lib/`, `data/`, and `workers/` files passed |

`modkit validate`, `modkit lint`, and `modkit pack` also passed; the release
package was written to `/private/tmp/potato-voxel-1.7.11.modpkg`. No
engine-mount or game-copy sync is assumed by this document; those are separate
deployment actions.
