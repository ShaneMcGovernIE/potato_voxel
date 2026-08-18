# PotatoVoxel Modularization, Legacy Reduction, and Bounded Cache Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce duplicated and unreachable mod code, then replace whole-map precaching with a bounded streaming cache pipeline that preserves runtime behavior while preventing memory spikes, long main-thread stalls, stale cache commits, and worker-specific geometry regressions.

**Architecture:** Keep `main.lua` as the composition root. Move shared contracts and cohesive feature ownership behind small modules loaded through the existing `V.require` boundary. Preserve current public module names as facades while internals are split. Replace whole-map cache jobs with compact snapshots, bounded geometry chunks, worker-side packing, per-map commit records, body-plus-ring artifacts, and asynchronous load/decode paths.

**Tech Stack:** Lua/LuaJIT, LÖVE, PotatoVoxel's sandbox loader, existing headless Lua test suites, mod lint/pack tooling.

## Global Constraints

- Preserve observable rendering behavior, fingerprints, settings keys, hook order, fallback behavior, and engine-facing exports. Cache bytes may change only through an explicit versioned migration.
- Use test-first characterization for each behavior boundary before changing ownership.
- Do not change hand-authored profile data or add rendering features.
- Do not delete VR or other dormant paths until reachability, exports, string-based loaders, hooks, and tests are characterized.
- Keep `V.require` as the sandbox boundary; do not introduce a service locator or dependency framework.
- Runtime cache remains scoped storage only. Do not ship ROMs, tileset images, extracted sprites, map dumps, generated geometry, or generated cache artifacts in the mod package or repository.
- New cache format is `PVMC2`; old `PVMC1` records are rejected safely and rebuilt locally. No partial `PVMC2` artifact may report `READY`.
- Worker memory is bounded by an explicit in-flight chunk limit. No whole-map nested vertex tables may cross a worker channel.
- Run focused tests after each task, then the complete verification suite and real thread/device validation before claiming the rewrite complete.

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
- [x] Remove only proven-dead compatibility code, with a focused regression test for every deleted public seam. The VR-only Pokedex branch had no public export or caller and was removed; the VR façade itself remains characterized and intact.

## Task 3: Extract lifecycle and settings ownership from `main.lua`

**Files:** `main.lua`, new `lib/RuntimeHooks.lua`, new `lib/SettingsFeature.lua`, tests covering settings and runtime loading

- [x] Characterize current hook registration order and the exact settings row/preset/hotkey behavior.
- [x] Add `RuntimeHooks.wrapOnce` and use it for the apply-options and map-block wrappers without changing callback order or error handling.
- [x] Move feature-owned engine wrappers and hook registrations behind explicit feature boundaries after preserving their order. Cross-feature save/time callbacks remain in `main.lua` as intentional composition-root seams.
- [x] Extract settings schema, live settings summary, and settings-row ownership into `SettingsFeature`.
- [x] Pass an explicit context table from `main.lua`; keep module loading and exports unchanged.
- [x] Extract world loading, fallback, render-scale, overlay, and VR-mirror policy into `WorldFeature` while preserving the pipeline callback boundary.
- [x] Verify settings, loading, runtime seam, and shadow suites before and after extraction.

Implementation result: `InputFeature`, `BattleFeature`, `WorldFeature`,
`CacheFeature`, and `SettingsFeature` now own the extracted boundaries. The
composition root keeps only registrations that coordinate multiple independent
features (`game.ready`, save events, and `world.tod`) plus the small
`applyOptions` compatibility wrapper.

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

- [x] Characterize stream counts, fingerprints, job ordering, budget slicing, worker messages, and runtime mesh eviction.
- [x] Move map-to-stream construction into `GeometryBuilder` with no GPU or queue dependencies.
- [x] Move queue state, deduplication, completion, and cancellation into `MeshQueue`.
- [x] Move budget-slice orchestration into `MeshQueue`; retain worker dispatch in `CachePrebuild`/`WorkerPool`, where map loading and protocol handoff are owned.
- [x] Move GPU mesh upload, cache-entry release/swap rules, and live-set eviction into `MeshRuntime`.
- [x] Consolidate auxiliary stream decode and figure/mesh release across sliced, cached, and synchronous paths.
- [x] Keep the worker protocol and `ChunkMesher` public calls stable; verify serial/threaded equivalence.

## Task 7: Split diagnostics data, transport, and presentation

**Files:** `lib/DebugOverlay.lua`, new diagnostics modules, `main.lua`, diagnostics tests

- [x] Characterize ring-buffer retention, counters, status snapshots, network send timing, settings rows, and HUD output.
- [x] Extract a data-only diagnostics store and preserve current logging calls.
- [x] Extract capability/environment collection from HUD rendering behind `DiagnosticsEnvironment`.
- [x] Keep overlay registration optional and prevent cache/meshing modules from depending on presentation code.
- [x] Move schema-3 payload construction and postLog polling behind `DiagnosticsTransport`.
- [x] Verify diagnostics behavior and sandbox API compliance.

## Task 8: Decompose Structures and complete verification

**Files:** `lib/Structures.lua`, `lib/Buildings.lua`, new specialist modules, docs and tests

- [x] Characterize `Structures.forMap()` result shape, template cache identity, object/relief/vegetation ordering, and `Buildings` integration.
- [x] Characterize the resolved grids, separated geometry streams, per-map cache identity, and `Buildings` model boundary.
- [x] Move analysis and specialist builders behind the existing Structures façade one boundary at a time.
- [x] Move grass and flower specialist builders behind the existing Structures façade.
- [x] Centralize the shared authored-pattern scan used by figure and mounted-object specialists.
- [x] Move profile-pinned stair geometry behind the existing Structures façade.
- [x] Move bookcase detection and relief emission behind the existing Structures façade.
- [x] Preserve result ordering, cache keys, and all extension points.
- [x] Run the complete suite, syntax checks, sandbox scan, mod lint, mod pack, and a final static reachability scan.
- [x] Update the design spec and ADR notes with completed boundaries, retained compatibility seams, and known residual risks.

## Modularization completion checklist

- [x] All focused and complete suites pass with exit status zero.
- [x] No unreviewed `keyOf` duplicates, disabled instrumentation shims, or new cross-feature imports remain.
- [x] Cache and worker protocols remained compatible with the baseline during modularization; bounded-cache protocol migration is tracked in Tasks 10–15.
- [x] `git diff --check` and project lint/pack checks pass.
- [x] Final review identifies any remaining legacy code explicitly instead of implying total removal.

## Task 9: Remove the Horde minigame

**Files:** `main.lua`, `lib/Horde*.lua`, input/world/scene dependents, `mod.card`, tests and docs

- [x] Characterize every Horde module, dynamic screen, hook, render branch, and metadata reference.
- [x] Add a failing absence test for the seven Horde modules.
- [x] Remove the Horde state machine, gun, crowd AI, HUD, synthesized SFX, exit prompt, and game-over screen.
- [x] Remove Horde branches from free movement, first-person pointer/touch input, world overlays, and voxel scene rendering.
- [x] Remove current community-card and frame-render documentation references while preserving historical changelog notes.
- [x] Verify the normal mod load and feature suites after removal.

## Cache Rewrite Evidence — Android 1.7.12

The [attached Android run](</Users/shanemcgovern/dev/loghook/logs/android/0_02_01/1_07_12/android-0_02_01-1_07_12-17_08_2026.json>) changes cache work from a tuning problem into an
architecture problem:

- `prebuild start: 0/444 done, 444 jobs` at 20:21:32.184.
- Worker atlas failure at 20:21:33.057:
  `Buildings.lua:180: Attempt to get out-of-range pixel!`
- Only four jobs completed through workers; the pool then fell back to serial
  work for the remaining maps.
- `prebuild 444/444 done` appeared, but no `manifest written` event appeared.
- Final diagnostic state was `FAILED` with `jobFails=0`, `errors=0`, and
  `storageFails=0`, proving payload generation and cache readiness were not
  the same transaction.
- Build took about 283 seconds. Worst frame was 2250.3ms, worst resume was
  2208ms, and the run recorded 196 mesh overshoots.

The [M5 Pro run](</Users/shanemcgovern/dev/loghook/logs/macos/0_02_00/1_07_11/macos-0_02_00-1_07_11-17_08_2026.json:73>) adds the memory and cross-platform evidence: two workers still
left a 264-second build, repeated multi-second hitches, duplicate completion
messages, and enough whole-map allocations to make peak-memory failure
credible. Headless tests pass, but real thread smoke validation remains open
because LÖVE could not create an OpenGL window in this environment.

## Task 10: Characterize and lock bounded-cache contracts

**Files:**
- Create: `docs/superpowers/specs/2026-08-17-bounded-cache-design.md`
- Create: `tests/cache_stream_contract_test.lua`
- Modify: `lib/CachePrebuild.lua`, `lib/WorkerPool.lua`, `lib/MeshCache.lua`, `lib/CacheStorage.lua`, `lib/CacheIdentity.lua`, `lib/CacheManifest.lua`, `workers/geometry_worker.lua`, `lib/DiagnosticsStore.lua`
- Test: `tests/potato_voxel_cache_test.lua`, `tools/thread_smoke/main.lua`

**Interfaces:**
- `GeometrySnapshot.fromMap(map, masks, voidFill)` produces a data-only
  snapshot containing map dimensions, block IDs, border/outdoor flags,
  tileset ID/path/tiling/dimensions, walkable/water/door tables, masks,
  `voidFill`, and authored profile revision. It contains no renderer,
  userdata, functions, or unbounded object graph.
- `GeometryStream.Writer.new(kind, maxVertices, maxIndices)` accepts scalar
  vertices and indices and returns bounded packed chunks through
  `Writer:flush()`.
- `CacheArtifact.commit(mapId, artifact)` writes chunk records first and one
  commit record last. Readers accept an artifact only when every declared
  chunk, checksum, identity, and required aux stream validates.
- `WorkerPool.submit(snapshot, request)` returns a generation ID;
  `WorkerPool.cancel(generation)` requests cancellation;
  `WorkerPool.poll()` returns chunk, heartbeat, commit, cancellation, and
  error events.

  - [x] **Step 1: Write failing contract tests.** Focused contracts now cover
    atlas reuse/dimensions, bounded packed chunks, snapshots, PVMC2 artifact
    atomicity, aux-once semantics, failed deletes, and identity changes.

  Cover sequential different-tileset jobs, bounded chunk counts, body/ring
  parity, aux-once semantics, PVMC1 rejection, partial commit rejection,
  deletion result propagation, identity changes, cancellation, heartbeat
  timeout, and duplicate completion suppression.

  - [x] **Step 2: Run focused tests and capture baseline failure.** The focused
    suite passes after the red/green fixes; engine-backed cache coverage also
    passes 204/204 checks.

  Run:

  ```bash
  luajit tests/cache_stream_contract_test.lua
  luajit tests/potato_voxel_cache_test.lua
  ```

  Expected: current worker atlas, whole-map allocation, old-format, and
  partial-commit contracts fail or remain unmeasured. Preserve output in the
  design spec as rewrite baseline.

  - [x] **Step 3: Define hard bounds and telemetry.** Bounds and the
    `CachePrebuild.metrics()` surface are present; real device measurements
    remain open.

  Set initial constants to `MAX_CHUNK_VERTICES = 16384`,
  `MAX_CHUNK_INDICES = 24576`, and `MAX_IN_FLIGHT_CHUNKS = 4`. Expose
  `CachePrebuild.metrics()` with `peakInFlightBytes`, `workerFallbacks`,
  `mainThreadMapLoadMs`, `mainThreadEncodeMs`, `mainThreadStorageMs`,
  `commits`, `commitFailures`, `cancelledJobs`, `duplicateResults`, and
  `worstFrameMs`.

  - [ ] **Step 4: Record acceptance thresholds.** Runtime memory and frame
    thresholds still require real threaded/device runs.

  Reject a build if any prebuild operation creates a whole-map nested vertex
  table, if more than four chunks remain unacknowledged, if a cancelled
  generation commits data, or if `444/444` is reported without a valid READY
  commit. Performance target: at least 50% lower wall-clock time than the
  264–283 second baseline on M5 Pro, with no prebuild operation blocking the
  main thread for more than 50ms in instrumented runs.

- [ ] **Step 5: Commit characterization and design contract.**

  ```bash
  git add docs/superpowers/specs/2026-08-17-bounded-cache-design.md tests/cache_stream_contract_test.lua
  git commit -m "test: characterize bounded cache contracts"
  ```

## Task 11: Fix worker atlas correctness and lifecycle

**Files:**
- Modify: `workers/geometry_worker.lua`, `lib/WorkerPool.lua`, `lib/CachePrebuild.lua`, `lib/Buildings.lua`
- Test: `tests/cache_stream_contract_test.lua`, `tools/thread_smoke/main.lua`

**Interfaces:**
- Worker atlas resolver keeps `imageCache[path]` keyed by normalized path and
  never replaces resolver function with one previous job's image.
- Worker validates `getWidth()` and `getHeight()` against snapshot dimensions
  before geometry work. Pixel reads outside bounds return structured error
  containing generation, map ID, path, tile index, and coordinates.
- Worker cancellation checks generation token at every emitted chunk and
  returns `{ kind = "cancelled", gen = generation }`.
- Shutdown sends cancellation and quit commands, returns immediately, and
  lets `poll()` drain terminal events before joining stopped threads.

  - [ ] **Step 1: Add sequential atlas regression test.** The headless atlas
    contract is covered; the real single-worker sequential sampling test is
    still pending.

  Submit two maps with different image paths and dimensions to one worker.
  Assert each job samples its own image and no `out-of-range pixel` fallback
  occurs.

- [ ] **Step 2: Add cancellation and heartbeat tests.**

  Start a deliberately slow geometry job, cancel its generation, assert no
  payload or commit event follows cancellation, and assert heartbeat timeout
  produces a structured worker error rather than a silent stranded job.

  - [x] **Step 3: Implement per-path atlas cache.** Resolver caching is keyed
    by worker root and image path, with dimension validation and root resets.

  Keep a loader function stable for worker lifetime. Cache successful and
  failed loads by path, clear cache when worker root changes, and preserve
  main-thread resolver behavior during serial fallback.

- [ ] **Step 4: Implement generation cancellation.**

  Add command-channel cancellation tokens, chunk-boundary checks, heartbeat
  events, and terminal result states. Do not call synchronous `join()` from
  the frame update path.

- [ ] **Step 5: Keep fallback local to failed generation.**

  Requeue only failed map work through serial resolver. Keep healthy workers
  alive unless thread death or protocol corruption is confirmed. Guard result
  application by generation and map/slot identity.

- [ ] **Step 6: Run focused verification and commit.**

  ```bash
  luajit tests/cache_stream_contract_test.lua
  luajit tests/potato_voxel_cache_test.lua
  git diff --check
  git commit -m "fix: make geometry workers atlas-safe and cancellable"
  ```

## Task 12: Replace whole-map geometry with bounded streaming

**Files:**
- Create: `lib/GeometrySnapshot.lua`, `lib/GeometryStream.lua`
- Modify: `lib/GeometryBuilder.lua`, `lib/ChunkMesher.lua`, `lib/Structures.lua`, `lib/Buildings.lua`, `lib/WorkerPool.lua`, `workers/geometry_worker.lua`
- Test: `tests/cache_stream_contract_test.lua`, `tests/potato_voxel_cache_test.lua`

**Interfaces:**
- `GeometrySnapshot.fromMap()` returns compact scalar/packed data only.
- `GeometryBuilder.buildMapStream(snapshot, masks, emit)` analyses each map
  once and emits `body`, `ring`, and `aux` chunks through `emit(chunk)`.
- `GeometryStream.Writer:flush()` returns a packed string with stream kind,
  sequence, vertex count, index count, byte length, and checksum. It never
  returns nested per-vertex Lua tables.
- `ChunkMesher.buildGeometryPairData()` remains as compatibility façade for
  existing tests, implemented by assembling streamed body and ring output.
- Full geometry becomes `body + ring delta`; body is not generated twice.

  - [x] **Step 1: Add bounded writer tests.** Flat scalar buffers, fixed bounds,
    sequence numbers, and stable checksums are covered headlessly.

  Feed more than `MAX_CHUNK_VERTICES` vertices and assert multiple chunks,
  fixed counts, monotonic sequence numbers, stable checksums, and bounded
  peak writer memory.

- [ ] **Step 2: Add serial parity tests.**

  Build existing fixtures through old façade and new stream path. Assemble
  body plus ring and assert stream counts, UVs, indices, aux contents, and
  sprite-stacked tree/bollard geometry match.

  - [x] **Step 3: Implement compact snapshot serialization.** Valid map jobs
    now use the geometry-only projection; the legacy dumper remains only for
    intentionally incomplete compatibility probes.

  Replace `WorkerPool.serializeMap()` whole-map Lua dumping with an explicit
  snapshot encoder. Reject renderer references, functions, userdata, unknown
  fields, and snapshots exceeding configured byte bounds.

- [ ] **Step 4: Implement chunked geometry emission.**

  Refactor geometry emitters to write directly into `GeometryStream.Writer`.
  Flush at vertex/index bounds and at cancellation checkpoints. Share one
  Structures analysis between body and ring output, then release analysis
  immediately after final aux chunk.

- [ ] **Step 5: Implement packed worker protocol.**

  Send one bounded packed chunk per channel message. Include only generation,
  map ID, stream kind, sequence, counts, checksum, and packed bytes. Main
  thread must not receive nested vertex/index tables.

- [ ] **Step 6: Run parity and memory checks, then commit.**

  ```bash
  luajit tests/cache_stream_contract_test.lua
  luajit tests/potato_voxel_cache_test.lua
  git diff --check
  git commit -m "refactor: stream bounded geometry chunks"
  ```

## Task 13: Add atomic PVMC2 artifacts and complete cache identity

**Files:**
- Create: `lib/CacheArtifact.lua`
- Modify: `lib/MeshCache.lua`, `lib/CacheStorage.lua`, `lib/CacheIdentity.lua`, `lib/CacheManifest.lua`, `lib/CachePrebuild.lua`
- Test: `tests/cache_stream_contract_test.lua`, `tests/potato_voxel_cache_test.lua`

**Interfaces:**
- `CacheArtifact.begin(mapId, identity)` starts one map artifact.
- `CacheArtifact.append(artifact, stream, chunk)` stores bounded chunks and
  returns `{ sequence, checksum, bytes }`.
- `CacheArtifact.commit(artifact)` writes one final commit record after all
  body, ring, and aux chunks succeed.
- `CacheArtifact.open(mapId, identity)` returns only committed, fully
  validated artifacts; incomplete artifacts return `nil, reason`.
- `CacheIdentity` includes `def.outdoor`, tileset image dimensions,
  tileset/path revision, authored profile revision, geometry version, and
  `voidFill`.

  - [x] **Step 1: Add atomicity and deletion tests.** PVMC2 partial commits,
    missing streams, checksum failures, and failed storage deletion are
    covered.

  Simulate terrain success plus aux failure, missing chunk, checksum mismatch,
  stale identity, failed delete, and interrupted commit. Assert none report
  READY and valid previous artifacts remain usable.

  - [x] **Step 2: Fix deletion result propagation.** `deleteKey()` now returns
    the storage API result and logs failed operations.

  Change `CacheStorage.deleteKey()` to return underlying storage result, not
  `pcall` success. Log operation/code/message on false results. Invalidation
  must verify no targeted key survives.

- [ ] **Step 3: Implement PVMC2 commit ordering.**

  Write body/ring/aux chunk payloads first, metadata second, per-map commit
  record last, and session READY record only after every map commit validates.
  Remove separate terrain/water/aux READY decisions.

  - [x] **Step 4: Implement identity expansion and migration.** PVMC2 rejects
    PVMC1; identity includes outdoor mode, atlas dimensions, profile revisions,
    geometry version, and void fill.

  Reject PVMC1 manifests and stale PVMC2 records with explicit reason. Never
  reuse old data when outdoor mode, image dimensions, profile revision,
  `voidFill`, or geometry version differs.

- [ ] **Step 5: Verify final commit diagnostics.**

  On `444/444`, log `completedRecords`, `expectedRecords`, commit result,
  first failed map, and storage return code. `FAILED` must include reason;
  successful final commit must emit `manifest written` or its PVMC2 equivalent.

- [ ] **Step 6: Run focused tests and commit.**

  ```bash
  luajit tests/cache_stream_contract_test.lua
  luajit tests/potato_voxel_cache_test.lua
  git diff --check
  git commit -m "feat: add atomic PVMC2 cache artifacts"
  ```

## Task 14: Rewrite prebuild scheduling and asynchronous load path

**Files:**
- Modify: `lib/CachePrebuild.lua`, `lib/CacheFeature.lua`, `lib/WorkerPool.lua`, `lib/ChunkMesher.lua`, `lib/MeshRuntime.lua`, `lib/MeshCache.lua`
- Test: `tests/cache_stream_contract_test.lua`, `tests/potato_voxel_cache_test.lua`, `tests/voxel_loading_test.lua`

**Interfaces:**
- `CachePrebuild` schedules current map body first, current ring second,
  nearby maps next, and all-map fill last.
- `CachePrebuild.cancel()` returns immediately and prevents new dispatches;
  `CachePrebuild.update()` drains cancellation and worker terminal events.
- `MeshCache.loadArtifactAsync(mapId, priority, callback)` loads and decodes
  committed chunks before map entry without synchronous whole-payload decode.
- `MeshRuntime` receives assembled body/ring data only after callback success;
  failed loads fall back to serial live generation.

  - [ ] **Step 1: Add scheduler tests.** Priority scheduling and asynchronous
    artifact loading remain pending.

  Assert priority ordering, one artifact per map, body/ring reuse, cancellation
  without post-cancel commit, resume after interruption, and no duplicate
  completion when worker and serial paths race.

- [ ] **Step 2: Remove main-thread whole-map operations.**

  Delete prebuild calls that synchronously perform whole-map serialization,
  quantization, compression, full decode verification, or body/full duplicate
  generation. Main thread may schedule bounded storage commits and apply
  completed runtime meshes only.

- [ ] **Step 3: Add bounded in-flight accounting.**

  Enforce `MAX_IN_FLIGHT_CHUNKS = 4` across all workers. Require channel ACK
  before dispatching next chunk. Release packed bytes after successful commit
  or explicit retry discard.

- [ ] **Step 4: Add asynchronous map-entry loading.**

  Request body and ring artifacts ahead of entry, decode in worker or sliced
  queue, and upload only after readiness. Preserve vanilla fallback while
  artifact is pending.

- [ ] **Step 5: Add Android safety policy.**

  Disable automatic all-map fill while visible gameplay is active on Android;
  continue current-map and nearby-map priority work, then resume low-priority
  fill from title/menu/background state. Keep explicit user-started full fill.

- [ ] **Step 6: Run focused suites and commit.**

  ```bash
  luajit tests/cache_stream_contract_test.lua
  luajit tests/potato_voxel_cache_test.lua
  luajit tests/voxel_loading_test.lua
  git diff --check
  git commit -m "refactor: schedule bounded asynchronous cache builds"
  ```

## Task 15: Validate real threads, devices, and release packaging

**Files:**
- Modify: `tools/thread_smoke/main.lua`, `docs/threaded-geometry-design.md`, `CHANGELOG.md`
- Test: all existing Lua suites, real LÖVE thread smoke, Android and macOS field logs

  - [x] **Step 1: Run headless verification.** Contract, cache, main feature,
    loading, shadow, and sandbox suites pass with the available fixture data.

  ```bash
  luajit tests/potato_voxel_test.lua
  luajit tests/potato_voxel_cache_test.lua
  luajit tests/voxel_loading_test.lua
  luajit tests/shadow_runtime_test.lua
  luajit tests/sandbox_api_test.lua
  ```

  Expected: all exit zero; cache tests report PVMC2 commit, cancellation,
  identity, bounded-memory, and sprite-stacked parity coverage.

  - [x] **Step 2: Extend thread smoke test.** The smoke harness now exercises
    sequential atlas paths and cancellation; actual LÖVE execution remains
    environment-dependent.

  Run sequential different-atlas jobs, body/ring/aux chunk commit, worker
  cancellation, heartbeat timeout, result deduplication, and memory bound.
  Record exact engine/platform limitation if OpenGL window creation still
  blocks the test.

- [ ] **Step 3: Run macOS M5 Pro validation.**

  Compare against the 264-second baseline. Require no duplicate completion
  messages, no worker atlas error, no cache-entry freeze above 50ms, valid
  PVMC2 READY state, and measured peak bytes below configured limit. Reject
  rewrite if wall time fails to improve by 50% or peak memory remains
  unbounded.

- [ ] **Step 4: Run Android validation.**

  Reproduce attached 1.7.12 scenario after cache wipe. Require no
  `out-of-range pixel`, no `FAILED` after all map commits, no repeated full
  rebuild on relaunch, no process termination, and stable current-map entry
  while background fill is paused or resumed safely.

- [ ] **Step 5: Audit release package.**

  Build mod ZIP from an allowlist. Fail package check if it contains ROMs,
  tileset images, extracted sprites, map dumps, generated geometry, cache
  payloads, logs, `.git`, or test artifacts. Runtime cache must remain in
  scoped storage and outside packaged mod files.

- [ ] **Step 6: Update docs and commit release validation.**

  Document PVMC2 migration, worker cancellation, Android scheduling policy,
  cache troubleshooting, and asset-free distribution boundary. Then run mod
  lint, mod pack, syntax checks, `git diff --check`, and commit:

  ```bash
  git commit -m "test: validate bounded cache rewrite on real runtimes"
  ```

## Cache Rewrite Completion Checklist

- [ ] Worker atlas resolver is path-correct across sequential jobs.
- [ ] Sprite-stacked tree, bollard, and building geometry matches serial path.
- [ ] No whole-map nested vertex tables cross worker channels.
- [ ] In-flight chunk bytes remain under configured bound.
- [ ] Cancellation prevents post-cancel writes and worker joins never block a frame.
- [ ] Body, ring, and aux commit as one validated PVMC2 artifact.
- [ ] Delete/invalidate reports actual storage result and verifies survivors are absent.
- [ ] Identity covers outdoor mode, atlas dimensions, profile revision, and geometry version.
- [ ] `444/444` cannot report READY without all commit records.
- [ ] Android and M5 Pro runs show no duplicate completion, stale atlas, cache-entry freeze, or repeated rebuild.
- [ ] Release ZIP contains no ROM-derived assets or generated cache artifacts.
