# Changelog

## [1.9.4] - 2026-08-26

### Gen 1

- Added new 3D wooden fences.
- Added new stone bollards for Pewter City and other routes.
- Added new large trees for Viridian Forest.
- Added new smaller trees for towns and routes.
- Added new 3D jump ledges, including their end pieces.
- Corrected colours for fences, ledges, and other scenery.
- Fixed trees appearing incorrectly between connected maps.
- Fixed a problem that caused Gen 1 precaching to fail.

### Gen 2

- Improved precaching for Gold, Silver, and Crystal.
- Improved support for each game's maps and graphics.
- Added a new 3D cave entrance model.
- Improved colours for Gen 2 scenery.
- Corrected some Violet City building behaviour.

### Both generations

- Improved support for coloured 3D models.
- Added better model rotation and positioning.
- Improved cache rebuilding when models or colours change.
- Added extra checks to detect problems before they affect the game.

## [1.9.0] - 2026-08-24

### Fixed: Gen 2 ledges and Cut trees

- Kanto jumping ledges now honor their authored two-row height instead of
  collapsing to a one-row terrace.
- Kanto Cut-tree tiles now use transparent per-pixel props, so they keep the
  tree silhouette instead of rendering as faceted hulls.
- Kanto tall grass now keeps its collision quads in worker snapshots, so its
  voxel tuft mesh survives threaded builds and cache reloads.
- Cache geometry version 29 forces one rebuild for the corrected terrain and
  vegetation geometry.

### Added: Gen 2 beta

- Beta support for Gen 2 (Gold/Silver) via a dedicated `gen2/main.lua` renderer entry and `gen2compat` manifest flag.
- New `GoldAtlas.lua` for Gen 2 sprite atlas handling and expanded `TileShape.lua` for Gen 2 tile shapes.
- Voxel workbench: `VoxelWorkbench.lua` + `WorkbenchJson.lua` with a bundled web tool (`tools/workbench`) for editing building, cutout, and override data.
- New datasets: `workbench_buildings.json`, `workbench_cutouts.json`, `workbench_overrides.json`, and a large expansion of `voxel_heights.lua`.
- Manifest now declares both `gen1` and `gen2` game support.

## [1.8.4] - 2026-08-23

### Fixed: staged battle layout and UI

- BATTLE LAYOUT is no longer forced to OG or removed while staged battles are enabled; OG and WIDE are preserved through battle entry and map changes.
- Unified battle layout metrics now keep rendering, captured battle textures, camera framing, HUD anchors, and coordinate conversion aligned for OG/WIDE, FIXED/FILL, DPI scaling, and offset screen positions.
- Removed the translucent WIDE-mode HUD panels that could remain over the battle scene.
- Removed isolated one-pixel islands from decoded battle art so a corrupt sprite texel cannot render as a detached black dash in the arena.

## [1.8.2] - 2026-08-19

### Fixed: voxel mode flickering between 2D and 3D (BUG-3)

- Fixed stallSkip oscillation loop in `WorldFeature.lua`: consecutive GPU hitches (>250ms) no longer cause rapid 2D/3D render flapping because the skip state is now preserved until the 4-frame skip window fully elapses.
- Removed OFF (level 0) from `Voxel.HOTKEY_ORDER` in `VoxelState.lua`: pressing Shift/8 no longer cycles into 2D mode, preventing desktop players who use Shift to sprint from inadvertently toggling voxel mode off.
- Allowed camera tween to progress behind loading cover in `VoxelState.lua`: eliminates the 1-2 frame flat camera flash on map warp transitions.
- Added post-backgrounding drawWorld watchdog in `main.lua`: detects when the engine stops issuing draw calls while overworld voxel rendering is active on Android and forces a pipeline invalidation to re-engage rendering.

## [1.7.12] - 2026-08-17

### Fixed: precache memory growth and sprite regression

- Tree canopies and grey gym bollards now use their authored round/can
  geometry again.
- Worker threads now receive the live Brick geometry profile before meshing.
  Precached trees therefore keep their sprite-cross stacks after rapid map
  changes evict and reload meshes instead of reverting to carved voxel hulls.
- Body and border-ring cache views now share one worker analysis per map.
  The ring is a disjoint delta, so the body is no longer stored, decoded, or
  uploaded twice for the current map.
- Worker map analyses and serialized map sources are released as soon as
  their flat output is handed off, preventing long builds from retaining the
  whole world and exhausting memory.
- Workers load tileset pixels themselves and fail closed to the serial asset
  resolver when unavailable. Trees, posts, and grey bollards cannot silently
  degrade into voxel volumes.
- Cache geometry version 27 forces one clean rebuild so stale prop-slab,
  default-profile, v26 quantized, and duplicate-full payloads cannot survive.
- Terrain and water use native GPU-ready records again. This removes v26's
  whole-map quantization during precaching and expansion during map loads;
  normal LZ4 compression still keeps storage bounded.
- Android and iOS keep geometry workers disabled. Device logs measured one
  worker at 1.15 jobs/s versus 2.90 jobs/s serial because map serialization
  and channel copies outweighed one worker's CPU gain.
- Mobile serial precaching now builds packed body and ring streams together
  in one cooperative CPU coroutine. It shares one map analysis and commits
  cache bytes directly, without creating throwaway GPU meshes.
- Mobile cache decompression runs on one dedicated worker while storage reads
  and GPU uploads remain on the main thread. Route transitions no longer pay
  a one-shot 15-53ms LZ4 decode stall; cancelled map jobs drop worker results.
- Ring geometry now visits only the outer ring spans instead of scanning every
  body cell and discarding it, reducing the tail cost of each border pass.
- Cache hits now hydrate through the same cooperative queue as fresh builds:
  entering a large cached route cannot synchronously decode terrain, water,
  and decorations on the map-entry frame.
- All indexed cached meshes upload their raw uint32 map through LÖVE
  ByteData, avoiding a second giant Lua index table at runtime.
- Map-entry work is scheduled current body first, direct destination bodies
  second, the current border ring third, and distant visible neighbours last.
  A large ring can no longer hold the next route behind it. Route changes
  cancel off-screen jobs and re-rank retained work.
- Only the destination terrain atlas prewarms during a transition. Neighbour
  atlases resolve when their body becomes drawable, removing unnecessary
  two-hop image work from map entry; static atlas entries no longer inflate
  fallback diagnostics.
- Confirming REBUILD CACHE now wipes committed payloads before starting,
  instead of scanning and reusing a READY cache while claiming to rebuild it.
- Raw cache payloads are no longer recompressed and rewritten during normal
  loads. Stage timings now separate queue, storage read, decompression,
  decoding, and GPU upload delays in test logs.

## [1.7.11] - 2026-08-17

### Fixed: threaded precache failed while saving every worker result

- 1.7.10's threaded completion path passed `MeshCache` as an extra receiver
  to the dot-defined `saveTerrain(map, slot, ...)` function. That shifted the
  worker streams and made `n` a table on Android, Linux, macOS, and desktop
  builds alike. The call now uses the correct dot-call shape, and the cache
  suite locks the regression down with a healthy worker-result test.
- Malformed worker payloads now discard stale in-flight work, preserve already
  completed jobs, and resume the remainder through the serial pump without
  double-counting or replaying completed cache entries.

## [1.7.10] - 2026-08-17

### Fixed: threaded prebuild aborts on every map ("map serialization too deep (cycle?)")

- 1.7.9's compute permission finally engaged the threaded workers, and
  the very first map dump exposed a cycle the headless fake map never
  had: the engine's Map carries a live TileRenderer that back-references
  the map (`map.renderer.map == map`) and holds `Game.data`. The naive
  data dump recursed forever, hit its 40-deep guard, and threw
  `prebuild-tick: map serialization too deep (cycle?)` every frame -- the
  prebuild re-loaded the same map and re-errored forever, never advancing.
- `serializeMap` now drops the `renderer` key entirely (the geometry
  worker rebuilds fresh map data and never reads it -- the dump was also
  dragging the whole game database into every job payload), and a
  visited-set backstop cuts any other cyclic engine field at the repeat
  instead of erroring.
- If a map dump ever fails again, the prebuild reports it and falls back
  to the serial pump for the remainder instead of erroring every tick.

## [1.7.9] - 2026-08-17

### Changed: the threaded workers can finally run on the new engine

- The engine helper merged upstream (engine PR #1454) only hands a mod
  `love.thread` when the manifest declares the `compute` permission.
  1.7.8 shipped without it, so every engine ran the serial sliced pump
  and the worker pool never engaged. The manifest now declares
  `compute`, and on engine builds with the permission the prebuilder
  dispatches geometry jobs to the background threads (Switch/Android and
  the brick profile still stay serial by design). Older engines ignore
  the permission and keep the fallback pump.

## [1.7.8] - 2026-08-17

### Fixed: the ~34s GPU crawl after the first voxel render (field logs)

- The first full scene triggered a driver upload burst that pinned every
  frame at 3-4s for ~34s (Steam Deck/vangogh 1.7.7 session 20260816-202329;
  the same signature as the Raspberry Pi in the previous review). The
  current map's body mesh now primes into the runtime cache before the
  first render (`CachePrebuild.primeFirst`), so the upload spike lands on
  a small scene instead of the full one; if a stall still starts, the
  voxel pass drops for up to 4 frames so input stays responsive. STALL
  lines now carry the driver identity and shader-switch count so the next
  review can confirm the root cause.
- Main-thread freezes at save/map-enter: the cooperative prebuild budget
  is tightened (3ms idle / 25ms covered) with a one-tick yield after an
  overshoot and one threaded dispatch per tick; the cold-flash survivor
  scan runs chunked off the entry frame; options/save writes defer off
  the entry frame.
- `writeManifest` no longer warns `storage read "nil": invalid_key` when
  a job's optional aux record is absent -- nil keys never reach storage,
  so full prebuilds stop flooding the triage stream with ~70 warns each.

### Changed: threaded geometry workers, idle-send backoff

- Mesh builds dispatch to the worker pool when the engine provides one
  (engine PR #1454), falling back to the serial sliced pump.
- Auto-send backs off: an idle ring (no new lines since the last acked
  send) skips the 90s deadline and ships at most a 300s liveness
  heartbeat, cutting idle POSTs ~3x on mobile. The watermark now advances
  when a send settles, so the send's own log lines never re-ship.
- loghook server: idle sessions are evicted from memory after the
  retention window (files are kept), and a resumed session re-attaches
  to its merged file from disk.

## [1.7.7] - 2026-08-17

### Fixed: the player support ID was minted anew on every boot

- The engine's options API has no `set` (only `define`/`get`), so the
  token's persist call silently no-op'd under pcall: every boot minted a
  fresh 8-digit id, and a player's logs fragmented across ids from the
  first reboot onwards. The token now persists the same way the settings
  rows do -- through the game handle at game.ready (live save options,
  the loader copy `options:get` reads, then the options file) -- so a
  reboot re-reads the id it stored. The suite's options mock also carried
  a fake `set` the real API never had, which is why no test caught it:
  the mock now matches the engine's API shape and the suite asserts a
  fresh session re-reads the persisted token.

## [1.7.6] - 2026-08-17

### Changed: support logs carry the fix-evidence for the field issues

- Startup capability snapshot: the voxel pipeline's readiness
  (`available` / `reason`, plus the shader or depth error text when a
  driver refuses it) is now recorded at game.ready, not only when the
  engine first asks the pipeline. A device where voxel silently falls
  back to flat 2D (field log: macOS M5 Pro ran the whole session with
  the pipeline never asked) now names the gate in the very first send.
- The `save.writing` trace line carries `texMB` (GPU texture memory at
  save time). Field logs show autosave freezes of 18-36s that track the
  atlas growing past ~170MB, so every save line now states the memory
  pressure it froze under.
- New `cacheMisses` counter in the session summary and JSON payload:
  a cold cache fill shows `0 hits (N misses)` per job, and a platform
  that silently fails to read its cache (Android sessions logged 0-26
  hits out of ~470 jobs while Windows resumed warm) can no longer hide
  the miss ratio.

## [1.7.8] - TBD (threaded geometry workers, needs engine PR #1454)

### Added: threaded geometry workers for the prebuilder (multi-core fills)

- The pure CPU phase of a cache job (Structures analysis, geometry
  streams, aux flattening) now runs on up to two love.thread workers,
  so a cold-cache fill on a multi-core desktop/linux/windows machine
  builds several maps at once instead of one serial coroutine. The main
  thread keeps map loads, storage writes and mesh uploads; the workers
  exchange only data tables plus the shared tileset image, and the
  saved payloads are byte-identical to a serial build (the manifest,
  resume and verify machinery is untouched). Design:
  docs/threaded-geometry-design.md.
- The engine must grant the new `compute` permission (src/mods/Sandbox.lua
  in the engine) for threads to spawn; engines without it -- Switch,
  Android, the brick profile, and any engine that has not shipped the
  grant -- run the serial pump exactly as before, with zero behaviour
  change (a 60s worker stall also falls back to serial mid-build).
- Dev tooling: `tools/thread_smoke` runs the real threaded round trip
  under the desktop love binary (`love tools/thread_smoke`).


## [1.7.5] - 2026-08-16

### Added: player support ID (8-digit token)

- Each install mints a random 8-digit token (stored in the per-install
  OPTIONS store, shown on the debugger panel's top line and as a
  read-only PLAYER ID row in VOXEL SETTINGS) and ships it inside
  consented log payloads (`playerId`). Privacy contract: the token has
  no link to any personal data and only identifies a player once they
  volunteer it in a support chat -- the playthroughId is deliberately
  never uploaded, so no log can be matched to a save without the
  player's involvement. The loghook server stores it per session, and
  the tracker workbook gains a PlayerId column for filtering.

## [1.7.4] - 2026-08-16

### Fixed: Windows could never cache aux meshes (reserved filename)

- On Windows, `aux` is a reserved device name (like `CON`, `PRN`, `NUL`):
  the engine's storage writes `<key>.bin` / `<key>.lua`, and a key ending
  in `/aux` made every aux payload write fail `write_failed` while
  terrain and water in the SAME directory succeeded (field logs: 180+
  failures per session, all aux; the doc in docs/engine-storage-windows-enoent.md
  chased this as a path/ENOENT problem). The on-disk segment is now
  `deco`; the internal kind, traces and status stay `aux`. Old payloads
  are fingerprint-protected and simply stop matching -- one aux rebuild,
  no migration.

### Fixed: storage failure lines name the offending key

- `storage read/write: <code> (<message>)` now includes the key, so a
  support log points at the record. Legacy keys an older build wrote
  unsanitised (the boot `invalid_key` reads on Android) are treated as
  absent and logged once at warning instead of erroring the session.

### Fixed: the stuck-loading alarm false-positives on slow devices

- `drawWorld: stuck loading` fired whenever the loading canvas stayed up
  over 10s, but a 10s+ canvas is legitimate on a low-end phone with a
  multi-hundred-MB texture load at save.loaded. The alarm now reports
  only when pending builds make NO progress for 10 seconds.

### Changed: cold-cache fills run ~1.6x faster

- The covered-phase prebuild slice widens from 30ms to 50ms per frame
  (nothing visible can hitch during menus, warps, the title screen or
  the loading canvas), and the per-job manifest write is throttled to
  every 8 jobs or every 5s instead of once per job -- the manifest grew
  O(n^2) on slow flash and was the prebuild's biggest fixed overhead.
  F3 resume granularity is still 8 jobs; finish always writes the full
  manifest.

## [1.7.3] - 2026-08-16

### Fixed: mesh builds froze frames for seconds at a time

- Field logs (Deck, Android 830/740, Windows): cache fills froze the
  game in 590-1083ms hitches, with a 20.3s single frame and a 37.9s
  CELADON_CITY build on an Adreno 830. The pump now times every build
  resume and warns when one runs past 4x its slice, naming the job and
  phase; the prebuilder's engine map load moved inside the pumped job
  coroutine (it used to run unmeasured on the update tick); and every
  finished job reports slices taken, the worst resume gap and overshoot
  count into the status snapshot's new `build` section -- so a support
  log says exactly which step needs slicing.

### Changed: prebuild fills run 3-6x faster while hidden

- The prebuild pump now receives the covered flag (menus, warps, the
  title screen): fills use the wider 30ms slice when nothing visible
  can hitch instead of always creeping at the 5ms idle slice. A full
  446-job fill measured 709s at 0.6 jobs/s on an Adreno 740; hidden
  phases now run several times faster.

### Fixed: boot-time cache handoffs dropped the manifest on every launch

- The engine's Assets boot handoff fires twice on desktop too (Steam
  Deck log: "cache invalidate ALL" twice, 0.2s apart), dropping the
  manifest and forcing a cold refill per boot. Boot-time handoffs are
  now skipped on every platform until the first mesh entry exists; dev
  hot-reload still lands.

### Fixed: void-fill churn dropped the cache once per change

- trees -> water -> trees in 0.7s invalidated the whole cache twice.
  Changes now debounce: one invalidation after a one-second settle, or
  none at all if the value settles back where it started.

### Fixed: SLOW cache loads now say where they hitched

- A 250ms+ cache load inside the budgeted build coroutine is sliced,
  not a freeze; the same load on the entry frame is the freeze. The
  SLOW load warning now tags each case (sync / in-build).

### Fixed: the status snapshot lied about storage health

- A successful write now clears the boot's expected failure state: the
  not_in_playthrough entries from before the playthrough existed no
  longer poison every later snapshot's storage fields.

### Changed: sample lines drop the dead draws/sw fields

- love.graphics.getStats().drawcalls / canvasswitches are unpopulated
  on the engine's LOVE builds (draws=0 on every platform while
  rendering thousands of frames), so the per-sample line reports
  texture memory only.

### Changed: the cold-cache boot rescan is deferred off the first frame

- The resume-set scan reads ~2 storage records per job (444 jobs =
  seconds of cold-flash reads on the game.ready frame, the NX boot's
  3.0s first frame). The scan now runs once, when a build actually
  starts, never on the boot frame.

### Fixed: support log hitches every 5 seconds on slow flash (Switch)

- The debugger's 5-second sample line forced a storage persist per
  window, and on Switch flash each write measured ~100ms -- a visible
  hitch every 5 seconds even with nothing rendering. Persists now
  measure their own write time and back off the non-forced cadence to
  30-300s after a slow write. Errors and exports still force through,
  so crash evidence and manual exports are unchanged; fast storage
  (desktop) never trips the backoff.

### Added: incomplete mesh cache auto-fills with no user action

- On a fresh device the cache used to stay empty until the player found
  OPTIONS > PREBUILD CACHE or answered the MAP CACHE prompt -- a
  controller user could tap the prompt away and never get the fill.
  Now, once the overworld is up (in-game storage and the save's live
  options exist), an incomplete cache starts building itself in the
  background with the same cooperative pump slices as a menu-started
  build. An explicit cancel, a declined prompt, a FAILED build, a READY
  cache or a running build all block the auto-start, and the boot
  scan's survivors are resumed rather than rebuilt.

### Fixed: declining the MAP CACHE prompt no longer starts the fill anyway

- The field log caught the auto-start firing 8 seconds after the player
  answered NO to the boot gate's "MAP CACHE NOT READY. BUILD NOW?"
  prompt -- the hands-off fill overrode an explicit decline. A NO now
  blocks the auto-start for the whole session (sticky through a cache
  wipe), and a boot whose gate ran at all -- prompt answered or cache
  ready -- never auto-starts: the fill starts only on a YES, an OPTIONS
  row press, or a boot where no gate existed. A fresh boot re-arms
  everything.

### Known issue: Android runs flat water for now

- The reflective water pass renders with hard banded stripes on
  Mali-family GPUs (the field log's "shadow stripes all the way down"
  survived every toggle: shadows off, march off, sky only). The
  lowp-sampler precision fix reduced but did not remove them, so until
  the shader work lands, Android hides the WATER row and forces the
  flat water fallback -- a save with WATER set to FULL is ignored there,
  and the pond looks like the 2D tileset art with no reflections.

## [1.7.2] - 2026-08-16

### Changed: logs send every 90 seconds

- The automatic log send drops from every 15 minutes to every 90
  seconds of game time. The LOGS TO DEV row still gates every send.

### Fixed: GPU identity field order

- LÖVE 11's getRendererInfo returns (name, version, vendor, device) but
  the capture stored them scrambled, so a Deck log's gpu line degraded
  to "OpenGL AMD" -- and the L4T slug rule could miss a real Tegra
  chip string landing in the version slot. The mapping is corrected and
  the Tegra matcher now reads all four fields.

### Fixed: debug panel state leaks

- The F9 panel and F6 class map drew in the hud pass without saving or
  restoring scissor and blend state -- a text-box scissor clipped the
  panel (read as broken) and leaked into whatever drew next. Both views
  now capture, clear and restore it.

### Changed: the Steam Deck rides the low-end compression class

- Platform.isSteamDeck() detects the vangogh / neptune renderer
  signature and joins the lz4-first compression class -- the Deck's
  zlib compress stalls measured 500-680 ms in the field, the same class
  the Raspberry Pi had in 1.6.11.

## [1.7.1] - 2026-08-16

### Fixed: Switch-under-L4T sessions tag as switch

- A Linux session whose GPU renderer names a Tegra (`tegra` / `nv13` /
  `gm20`) now slugs as `switch` -- under L4T the OS reports Linux, so
  the renderer is the only sandbox-safe hardware witness. Non-Tegra
  Linux handhelds (the Brick's GE8300) keep their honest `linux` slug.

## [1.7.0] - 2026-08-16

### Changed: log sending is opt-out

- Diagnostics now go to the developer automatically every 15 minutes of
  game time (and on demand via F8 / SEND LOGS / the START chord), with
  no prompt. The one-time consent prompt is gone; the new LOGS TO DEV
  row (ON by default) in VOXEL SETTINGS and on the mod manager's page
  turns all sending off permanently.

### Changed: mesh uploads are budget-sliced, and upload failures are loud

- Fresh builds slice their upload through the same 8k-vertex budget
  path as the rest of the job instead of one-shotting the whole mesh
  inside a pumped frame. Every upload call now checks its result and
  drops the mesh on failure -- a failed upload fails the job loudly
  (logged, flat-2D fallback) instead of leaving a silently zeroed
  mesh. (A flat-array upload variant was tried and reverted: this
  engine's LOVE 11.5 rejects flat vertex arrays on a vertex-count
  mesh, counting elements as vertices -- and the old unchecked pcall
  turned that rejection into zeroed terrain meshes on every cache
  load.)

### Changed: character shadow-caster matrices built in place

- `Voxel3D.casterMatrix` no longer allocates -- it builds into shared
  scratch matrices, removing the cast pass's biggest per-frame GC
  source (runs once per character per frame, twice under water).

### Added: ATMOS row -- per-map haze

- `data/voxel_atmos.lua` names per-map fog records (forest haze, cave
  gloom); the ATMOS row (OFF by default) turns them on. The scene
  shader's fog path -- unused since the 1.6.1 removals -- is fed
  again, and the water surface reads the same air its banks do.

### Added: WEATHER row -- rain and snow

- `data/voxel_weather.lua` names per-map entries; drops fall in world
  space through the FX overlay (parallax, no depth writes), drawn as
  one stream mesh. Rain ships for Viridian Forest; snow is implemented
  for total conversions.

### Added: WATER HALF rung

- The WATER row is OFF / SKY / HALF / FULL: HALF is the reflective
  pass at a reduced ray budget (RAY_STEPS 16 / RAY_REFINE 4), a second
  shader compilation -- FULL is unchanged.

### Changed: per-tileset water wave profiles

- Wave trains, swell and bend are per-pass uniforms now;
  `Water.WAVE_PROFILES` keys them by tileset id, with a calm GYM pool
  shipped. The phase rate derives from the active profile's dominant
  train.

### Added: F6 class-map debug view

- F6 tints every tile of the current overworld by its resolved shape
  class (volume runs toward white, claimed cells toward magenta) --
  the authoring aid for the shape profile.

## [1.6.11] - 2026-08-16

### Added: structured JSON log payloads + delta sends

- Sent logs are now ONE organized JSON document (schema 3) instead of a
  flat text block: identity fields at the top (platform slug, engine, mod,
  love, gpu, DD_MM_YYYY date) that the loghook server uses to name and
  sort files, boot evidence once per session, a ring DELTA (only lines
  newer than the last acked send -- a long session no longer re-ships its
  whole history every 5s), and the structured status snapshot.
- Platform slugs are folder-safe and stable (`linux`, `ios`, `switch`,
  `android`, `windows`, `macos`, `web`, `unknown`); the engine names
  macOS both "OS X" and "macOS", and both now resolve to `macos`.

### Fixed: log-send cadence (the 5s retrigger)

- The START hold-chord re-fired its export every 5 seconds while the
  button stayed held (the accumulator reset on fire but re-armed
  immediately), so an unattended held START produced a send every 5s for
  the whole session. The chord is now a true one-shot: one press = one
  fire; a release is required before it re-arms.

### Fixed: storage `invalid_key` failures

- Persistence wrote through the `Storage:selected` facade with the
  raw-module call shape, shifting the game object into the KEY slot so
  every write failed `validKey` -> `invalid_key` (seen at boot on iOS
  and on the Raspberry Pi). Writes now go through the mod's own storage
  wrapper, and a storage failure line names the key that failed.

### Fixed: errors counter vs slow loads

- A slow-but-successful cache load was reported through `Overlay.error`,
  which inflated `counters.errors` to equal `slowLoads` in every session.
  Slow loads now use a warning level: the ring line and the `slowLoads`
  counter stay, but `errors` means real failures.

### Fixed: prebuild stalls on low-end devices

- Mesh payload compression preferred zlib over lz4 everywhere except
  Switch; on the Raspberry Pi a single mesh's zlib compress took seconds.
  The low-end class (Switch, iOS) now prefers lz4 before zlib -- the
  quantized payloads lose little ratio and compress ~2x faster.

### Added: stall markers in frame stats

- Frames over 500ms now carry a `[STALL>500ms ...]` tag with the pipeline
  state, path, level, last event and texture memory, so a future log
  states the cause of a long freeze (the Pi's ~55s 1fps crawl started
  right after texMB dropped 85.8 -> 25.4).

## [1.6.9] - 2026-08-16

### Fixed: shadows on iOS / highdpi devices (Metal)

- The shadow map's explicit depth canvas was created without
  `dpiscale = 1`. On a highdpi surface (iOS/Android) `newCanvas`
  defaults to the surface scale, so a 1024 depth attachment came out
  2048 physical pixels while the packed colour map stayed 1024 -- a
  mismatched attachment pair that Metal rejects, silently dropping the
  pass to the internal depth buffer and leaving the fill with an
  uncleared depth test. Result: wrong shadow regions ("shadows across
  half the screen"), detached shadows, and broken character shadow
  decals on iOS. The depth canvas now matches the colour canvas (the
  same `dpiscale = 1` PixelCanvas/TerrainAtlas/BattlePics fix, applied
  to the one creation site that had missed it), in ShadowMap and in the
  scene's own depth canvas.
- The shadow fill now clears its depth buffer explicitly (the clear
  call had left the depth buffer untouched, relying on the driver).
- Sent logs now carry `shadowDepthFail:` -- the per-format depth-canvas
  creation errors -- whenever the pass is on the internal depth
  fallback, so a future regression states its cause in the log.

## [1.6.8] - 2026-08-16

### Cache (Switch)

- Platform detection: the mod now answers "is this the Switch port?"
  through a small wrapper (`lib/Platform.lua`) over the engine's own
  Platform module (the NX flag -- the sandbox forbids the mod touching
  love.system itself). Every Switch-only cache change below gates on it;
  desktop and other platforms run exactly as before.
- Compression codec: on Switch, `packPayload` now prefers lz4 over zlib
  when zstd is absent. zlib's compress is a multi-hundred-ms main-thread
  stall per big payload, and the Switch-port logs showed the same
  prebuild tail running ~2x faster with lz4 than with zlib (zlib vs lz4
  manifests). The quantized payloads lose little ratio, so the faster
  codec wins on the console; elsewhere the chain stays zstd -> zlib ->
  lz4.
- WIPE CACHE now verifies on Switch: after deleting, the wipe read-backs
  the manifest/buildinfo and re-lists both payload namespaces, counts
  every survivor as a storage failure, and reports false instead of
  claiming success. The Switch storage has been observed to no-op
  deletes while reporting success -- after a wipe the prebuild restarted
  from zero (manifest/metas gone) while the old payloads kept serving
  cache hits.
- Boot invalidation: on Switch, the engine's Assets.installLoader ->
  Assets.invalidate handoff has been observed to fire twice at boot; the
  second call dropped the manifest and forced a cold 444-job prebuild on
  every launch. Handoff invalidations are now ignored until the first
  mesh entry exists (which a boot-time handoff can never be), so Switch
  restarts stay warm; real invalidations still land the moment any mesh
  work starts.
- `deleteKey` now returns the storage call's real result instead of
  swallowing it; no caller's behavior changes off-Switch.

## [1.6.7] - 2026-08-16

### Diagnostics

- Sent logs now identify the GPU behind every render and shadow report:
  the header carries `gpu:` (backend + device), and the status excerpt
  carries the full renderer identity (name/vendor/device/version), the
  DPI scale (a fractional scale is where canvas and scissor bugs come
  from), and the complete shadow-system state -- shader precision,
  depth-attachment binding, sprite layer, pass aborts -- plus the
  retained failure text when the shadow or voxel pass is unavailable
  (which shader would not compile, which canvas could not be allocated,
  what the driver said). Renderer capture now accepts both LÖVE 12's
  table `getRendererInfo` and LÖVE 11's four-value form, so desktop
  sends carry it too.
- The status excerpt now carries the session's VOXEL SETTINGS as one
  `settings:` line -- the voxel rung plus every live setting row as
  `key=label` (WATER, AA, V-CURVE, V-GRID, 3D-BTL, DAY/NIGHT, SHADOWS,
  SHADOW QUALITY, RENDER SCALE, DEBUGGER) -- read live through the same
  paths the menu rows use, so a received log shows exactly what the
  session ran with. Gated rows are omitted exactly as the menu omits
  them.

## [1.6.6] - 2026-08-16

### Diagnostics

- Sent logs and status records now identify the platform they came from
  (Windows, OS X, Linux, Android, iOS, consoles), answered through the
  engine's Platform module, with the device class appended where it is
  not obvious (Android (mobile), NX (console)).

## [1.6.5] - 2026-08-16

### Diagnostics / privacy

- F8 / SEND LOGS ask before the first upload: the first export that
  would send shows a one-time prompt (the log goes to the mod's
  developer over the internet), defaults to NO, and a YES is stored in
  the mod's options so it is never asked again. A NO ships nothing and
  asks again next time; engines with no log_url never prompt.

## [1.6.4] - 2026-08-16

The map-corruption and cold-cache release: the two most-reported issues
on 15-16 August are fixed here, plus the F8 pipeline now tells us why.

### Fixed: broken/black terrain meshes

- The budgeted index-map upload called Mesh:setVertexMap with a start
  index LOVEs API does not have, and the error was swallowed -- every
  slice replaced the whole map, so meshes kept only the final chunk's
  indices ("giant cross-quad triangles", black ground with the map
  visible in slivers, MT MOON/Cerulean reports). Indices now upload in
  one call; vertices stay budget-sliced.

### Fixed: cache rebuilt on every launch

- The engine's boot asset handoff invalidated the whole mesh cache
  (manifest dropped, cache marked dirty), forcing a full 444-job
  prebuild every boot -- the "choppy boot loads" and "fails the
  prebuild every time" reports. The first asset invalidation after boot
  is now a no-op; restarts stay warm, and fingerprint protection still
  covers real changes.

### Debugger / support

- F8 payload now carries an identity header (mod, engine, love, session,
  frame) and a status excerpt (counters, pipeline, voxel, shadows,
  cache, prebuild, worst frame, storage) so a received log is
  attributable and self-diagnosing.
- Send results are recorded: "log send confirmed" or "log send failed:
  <engine error>" -- the engine's rejection reason is shown instead of a
  bare failure.
- Payloads are trimmed to the engine ceiling (newest lines kept), with a
  conservative retry for engines that still cap at 64 KiB.
- Blank-world reports name the exit path; a loading canvas stuck over
  10s escalates to a durable error; pipeline availability carries the
  reason.
- Hold chords: five seconds of SELECT toggles the debug panel, five
  seconds of START exports the log (touch/pad F9/F8). The SELECT chord
  is gated off mobile so gameplay cannot summon the panel.
- VOXEL SETTINGS gains a DEBUGGER toggle and a SEND LOGS action row.

### Cache/prebuild

- zlib joins the codec ladder (zstd -> zlib -> lz4): 3-4x smaller
  payloads on runtimes without zstd, shorter writes and loads.
- Payload verification is header-only (no full decode stall).
- A single failed prebuild job no longer aborts the build; the next
  boot resumes exactly the missing jobs (scan-based resume).
- The slow-load counter is wired (it was declared but never counted).

### Shadows / rendering

- Shadow and voxel shaders pin effect parameters to mediump first with
  a bare-precision retry for mobile compilers; shader errors and the
  precision chosen are retained for diagnostics.
- A failed shadow sprite pass can no longer erase an already-finished
  world map.

## [1.6.3] - 2026-08-15

- Add opt-in F8 debug log uploads: pressing F8 sends the diagnostic log
  to the PotatoVoxel log service (desktop, engine v0.1.95+). Nothing is
  uploaded automatically.


## [1.6.2] - 2026-08-15

Prebuild and diagnostics hardening: one bad job no longer fails the whole
build (and a failed job no longer forces every boot to re-encode every
payload), the prebuild's multi-second main-thread stalls are gone, and a
blank-world report now names which path fired instead of freezing on a
stale render time.

### Cache prebuild (#5, #7)

- A single failed job no longer aborts the build: it is counted, logged
  with the failure reason, and skipped; the next boot retries exactly
  that job while its neighbors stay cached. Only an epidemic (more than
  4, or a tenth, of the jobs failing) aborts, reporting FAILED.
- The verify step no longer decompresses and fully decodes each finished
  job's terrain/water. The header (magic, format, fingerprint, bounded
  lengths) plus the meta commit record is the check; payloads are
  re-validated when the map actually loads. This removes an un-yieldable
  multi-second main-thread stall per job.
- New deflate (zlib) codec. The brick's LÖVE ships only lz4 + zlib, so
  payloads fell back to lz4 and the engine's table-serialized write then
  escaped ~2MB of binary per payload. The fallback chain -- zstd where
  the runtime has it, zlib elsewhere, lz4 last -- writes 3-4x smaller
  payloads, so the write + verify stall scales down with them.
- The mesh flatten into the cache wire format is budget-sliced, so the
  pump coroutine can yield mid-flatten on the biggest maps.
- Codec byte 3 (zlib) is understood by this release; caches written by
  1.6.1 (lz4) stay READY and load fine. (The aux payload is optional: a
  cache with no grass/flowers/figures is valid -- the voxelizer builds
  them live on load.)

### Diagnostics (#6, #8)

- 1.6.2 — F8 export can send the debug log to the mod's `log_url` (opt-in
  via manifest; no-ops without the engine feature).
- Pressing F8 sends that diagnostic log over the internet to the PotatoVoxel
  maintainer through the project's log service, so I can review it directly
  and help troubleshoot your game. Nothing is uploaded automatically: if you
  do not press F8, the log stays local to the game.
- The debugger now records from boot in the background; F9 only shows or
  hides the panel, so support logs include failures that happen before the
  first manual toggle.
- Exports now preserve the first boot evidence alongside the recent ring and
  write a data-only `debug/status` snapshot with renderer, storage, session,
  pipeline heartbeat, capability reasons and world-render path counters.
- Scene and shadow shader/canvas gates retain their compiler or allocation
  reason, and F8 runs a guarded capability probe before exporting.
- The pipeline heartbeat distinguishes update-only, unavailable, loading,
  fallback and successful world-render paths, so a silent 2D fallback is
  immediately identifiable.
- drawWorld stamps its loading-canvas entry with the pending count,
  escalates to a durable error when the canvas is stuck past 10 seconds,
  and stamps the first real scene render; periods where the voxel
  pipeline is inactive are noted once.
- Error lines force a throttled storage persist so a support log
  survives an abrupt exit, and the error counter counts every occurrence
  including on-screen repeats.
- The F9/F8 keyboard toggles are mirrored by five-second SELECT/START
  hold chords for touch-only devices.

## [1.6.1] - 2026-08-15

This is the sandbox release: PotatoVoxel now runs entirely inside the
engine's mod sandbox -- no raw file access, no OS checks, no native
interop. A few features that needed those things are gone (listed below),
the mesh cache moved into the game's own scoped storage, and the build
is one code path for every device.

### What players need to know

- **Build the cache once, in-game, then SAVE.** The mesh cache is stored
  per save file now (the sandbox scopes storage per playthrough), and the
  save has to be written once for the game to remember the link. When the
  game offers BUILD NOW after CONTINUE, accept it, let it finish, then
  save the game. From then on, that save loads its prebuilt maps without
  asking again. Other save files get their own cache and ask once each.
- **Stadium models are gone.** Importing a Pokemon Stadium ROM needs to
  read files the sandbox forbids, so 3D-BTL is now 2D-3D A / 2D-3D B /
  OFF. Stored STADIUM choices from older saves fall back to 2D-3D A.
- **FOREST FX is gone** (the Viridian Forest haze and light beams), and
  battle HUDs draw on plain panels instead of frosted glass.
- **VR is gone.** The OpenXR loader needed native access the sandbox
  removed.
- **Shadows now run on every device** that can do them -- the old
  iPhone/iPad blanket ban is removed, and when shadows genuinely cannot
  run the game says why in its log.
- **Old cache folders are obsolete.** The previous `mod-derived/`
  cache folder is no longer used or touched; it can be deleted by hand.
- **A hidden diagnostic is included**: press F9 in-game to show the
  debug overlay (F10 switches detail level, F8 exports its log). It is
  off until you press F9.

### What changed under the hood

- The mod loads under the engine's mod sandbox: no `io`, no
  `love.filesystem`, no `os.getenv`, no `ffi`, no `love.system`, no
  `package` -- every banned surface was replaced with the sanctioned
  one (`mod.storage`, `mod:read`, `mod.hooks`/`mod.events`, plain Lua).
- The mesh cache now lives in `mod.storage` -- the game's own crash-safe,
  per-save-file storage -- with small summary records per payload so the
  boot-time READY check stays fast. Payloads store as byte records when
  the engine supports them and fall back to table records when it does
  not, and caches written by one shape read fine on the other.
- The float number handling moved to pure Lua (this engine's data API
  has no float helpers inside the sandbox). The saved file format is
  unchanged, so old geometry knowledge still applies.
- **Performance regression fixes:** the first sandbox builds spiked
  frames because big chunks of pure-Lua packing ran in one go; the work
  is now sliced finely across frames, and map meshes upload to the GPU
  in budgeted pieces instead of one giant upload -- the 100-500 ms
  freezes on big maps are gone.
- Mod options were updated for the current engine (the manager page
  shows toggles and choices again), and a "rebuild?" prompt that
  appeared on every launch is fixed.

### Removed

FOREST FX, the frosted battle-HUD glass, STADIUM models (rung, import
screen and readers), VR, and the DEBUG diagnostics panel -- see
docs/adr/0004-feature-removals.md for the reasoning.

## [1.5.2] - 2026-08-14

### Fixed

- The pinned DUSK and DAWN settings now have shadows. Both pins parked the
  clock exactly ON the horizon, where the designed shadow fade (the last
  12 degrees of elevation) had already taken the shadow strength to zero --
  so a dusk or dawn look rendered the long clamped shadows at zero opacity:
  a completely flat-lit world. The pins now stop at the last fully-lit
  moment -- the edge of the fade, where strength is exactly full and the
  shear is clamped to the 1.5x stretch cap -- so dusk and dawn read as the
  long-shadow golden hour they are. The RUNNING cycle keeps its soft
  shadowless handoff gap at the true horizon, and the sky palettes are
  unchanged (the pins land inside the golden/dawn blends).

## [1.5.1] - 2026-08-14

### Fixed

- Sunset and moonrise shadows now appear on the far side of view. The sun
  frustum's caster margin was only paid on the noon-sun side, so once the
  day/night rig swung the sun past its noon bearing, the tall casters that
  throw INTO view from off-screen (border trees past the horizon) were
  never drawn into the map -- a hard shadowless band every evening. The
  margin is now symmetric in both axes (the box grows a little and the
  adaptive ladder absorbs it), verified by the new cycle sweep.
- The overworld's Stadium arena no longer loses its shadow on water: the
  arena was drawn inside the sprite flag in the overworld (water declines
  sprite casters) but outside it in battles, so a lakeside fight only
  shaded the water in the battle pass. Both scenes now share ONE
  world-layer draw (lib/ShadowCast.lua) and draw the arena outside the
  flag, exactly as battles always did.
- Dawn/dusk shadows are capped at 1.5x a caster's height instead of 2x
  (DayNight.K_MAX), which is what the "stretching" reports were seeing.

### Added

- tests/shadow_golden.lua: a deterministic golden over the shadow pass's
  real fit/snap/slack/bias/snug numbers across the sun cycle, every rung
  and two view sizes (64 digests). It is the capture half of the shadow
  screenshot pipeline minus the GPU -- the engine has no headless capture
  path -- and CI runs it. `--bless` re-blesses deliberately.
- The shadow cadence probe now sweeps the full sun cycle (9 bearings x 4
  shear magnitudes x 4 rungs x 2 views, 7200 coverage samples) asserting
  the frustum covers every caster whose shadow lands on visible ground,
  the snap matches the real fit, and the fit never produces NaN.
- The suite now lints every shipped module for the forward-local bug
  class (a function touching a name before its `local` declaration reads
  a nil GLOBAL -- the BrickProfile Mali exception shipped exactly that
  once). Zero false positives across main.lua, lib/ and data/.

## [1.5.0] - 2026-08-14

### Fixed

- The player and NPCs now cast real sunlight shadows on EVERY voxel rung.
  The sprite-layer actor map used to be a HIGH-only feature, so MEDIUM, LOW
  and POTATO -- the rungs most of this potato build actually runs -- showed
  fixed contact blobs under the characters while the world around them
  carried sun shadows. The layer's canvas was already allocated on every
  rung and the cast pass is a handful of quads, so the gate was saving
  almost nothing; the blob decal now survives only as the no-shadow-map
  fallback. Battles keep the blob decal below HIGH except on Mali, where
  the decal path is the broken one and the actor map already proved itself
  on every rung.
- The shadow comparison's depth slack now tracks how low the sun sits.
  The slope term was calibrated at the noon sun; under a dawn/dusk or
  moonlit shear the lit-surface depth ramps grow and the old constant let
  the acne bands through (the "stretching" streaks at golden hour). The
  slack scales with the shear's magnitude -- doubled at the dawn/dusk
  clamp, unchanged at noon -- and the snugged caster root rides the same
  number, so shadows still start at the feet.
- When the sun pass cannot run, the game now says WHY instead of quietly
  dropping to flat lighting: the session log names the exact gate (no
  canvas/depth API, shader failed to compile, canvas could not be
  allocated or bound, degenerate frustum), and the reason is available to
  the DEBUG HUD. "Shadows not appearing" reports can now carry the reason
  straight into the issue tracker.

## [1.4.9] - 2026-08-14

### Fixed

- Entering a map whose meshes were already prebuilt no longer flashes the
  BUILDING VOXELS cover. A cache hit used to ride the same asynchronous job
  queue as a fresh build: on large maps the queued load sliced through
  several 12ms pump budgets, outlived the warp fade, and showed the cover
  over terrain the disk cache had all along. A cold destination now loads
  its prebuilt payload synchronously on the entry frame -- bounded
  read/decompress/decode work the fade already covers -- so the world is
  there when the fade lifts. Real builds, seam crossings and the
  prebuilder keep the asynchronous path.

## [1.4.8] - 2026-08-13

### Fixed

- The anti-aliasing fold reset the draw colour with a bare
  `love.graphics.setColor()` call, and LÖVE 11.5 has no zero-argument form of
  `setColor` -- it throws `bad argument #1 to 'setColor' (number expected,
  got no value)`. The throw rode the voxel pipeline's draw path back up, and
  the error handling disabled the whole voxel mode for the session: the game
  kept running but the overworld drew flat. The fold now resets to explicit
  white `setColor(1, 1, 1, 1)` -- the v1.4.4 behaviour -- so the
  supersampling pass can no longer take the mode down with it.

## [1.4.7] - 2026-08-13

### Fixed

- The mesh cache folder is now created correctly on a fresh install. The
  shell-free directory creation only made the cache's own subfolders, so
  when the save directory itself was brand new the cache was disabled for
  the whole session (it read as "UNAVAILABLE" until a restart). It now
  creates every missing level, from the root down, before writing.

## [1.4.6] - 2026-08-13

### Performance

- Terrain and water meshes are now stored quantized: 11 bytes a vertex
  (16-bit position, 16-bit texture coordinates, 8-bit shade) instead of the
  24-byte six-float stream -- about 54% smaller before compression. Cache
  files shrink and a cold map load reads and decompresses far less from
  storage. Positions are integer pixels and come back exactly; texture
  coordinates and shade round to 1/65535 and 1/255, both far finer than the
  voxel grid or the baked ambient-occlusion steps can show. The mesh that
  reaches the GPU is unchanged, so there is no visual difference and no
  steady-state draw cost.

### Changed

- The mesh cache no longer uses shell commands to set itself up. The cache
  folder is created through LÖVE's filesystem where it can reach it, and
  through a direct library call on portable (SD-card) installs, with a real
  write test before use -- so the cache works where shell access is
  restricted or unavailable. WIPE CACHE lists files through the filesystem
  API instead of a shell listing.

- **CACHE STATUS** now names the compression method: **READY (LZ4)**,
  **READY (ZSTD)**, **READY (RAW)**, or **READY (MIXED)**. The cache tries
  zstd first when the runtime provides it, and reports whichever codec it
  actually used.

### Added

- The cache format now records its compression codec per file, so a cache
  written by one build stays readable by another and the status can name the
  real method. Updating to 1.4.6 refreshes the cache once (the geometry
  version moved to 18), in the background or on demand.

## [1.4.5] - 2026-08-13

### Fixed

- Stadium models no longer play a hurt/faint-looking animation when sent
  out. Two causes, both in the send-out entrance. The anchor that pins a
  Pokemon to its tile over-corrected when an entrance hopped: the lagged
  offset outlived the hop and dragged the body below the tile on the way
  back down, which is a collapse no matter what the animation said. It is
  clamped to the excursion that caused it, so a returned hop is not
  dragged past the tile it came back to. And species whose entrance is a
  genuine drop to well under standing height (Squirtle into its shell,
  Goldeen flat on the ground -- 48 of the 151) no longer play it at all:
  the entrance is measured once at load, through the anchor the player
  actually sees, and a species that reads as hurt on arrival now arrives
  on its standby loop instead. The standbys and the entrances that still
  read as entrances are untouched.

## [1.4.4] - 2026-08-12

### Fixed

- Mediatek/Mali devices: every voxel rung now uses the HIGH shadow path
  (the sprite-layer map) instead of the flat contact-blob fallback. The
  fallback path is what froze the screen on the last frame (the game kept
  running behind it) and dropped the player's shadow on MEDIUM/LOW/POTATO/
  CUSTOM -- the exact rungs that break are the ones HIGH's configuration
  never touches, and users confirmed HIGH works. The decal pass is also
  now crash-proofed so a failing decal can no longer freeze a frame on any
  device.

## [1.4.3] - 2026-08-12

### Fixed

- Black screen with shadows enabled on Mediatek/Mali Android devices. Two
  failure paths are closed: a shadow pass that dies mid-draw can no longer
  leave its offscreen canvas bound (the world was rendering into the shadow
  map, which is the black frame), and NaN values from a degenerate light
  fit can no longer poison the shadow math (NaN comparisons silently pass
  GLSL bounds checks, then black out every fragment they touch). Both now
  fall back to a flat-lit frame for that moment instead of a black screen.

## [1.4.2] - 2026-08-12

### Fixed

- The map cache no longer asks to rebuild on every launch. The game was
  checking the cache with default settings before your save loaded, so a
  save that used a different VOID FILL looked "stale" every time -- even
  when the cache matched your settings perfectly. The check now runs after
  your save (and its options) are loaded, and the BUILD NOW? prompt appears
  over the world instead of the title screen.
- Interrupted builds now resume. If a build is cut short (the app was
  backgrounded, the battery died, a crash), the next launch continues from
  where it stopped instead of starting over or prompting forever.
- The map cache now refreshes itself once when you update to 1.4.2 (the
  cache now remembers more detail about your game data, so old files are
  rebuilt a single time, in the background or on demand).
- Windows: updating the cache info file no longer fails silently, which
  could leave the game asking for a rebuild every launch.
- When a build fails, the game now tells you WHY (a full SD card, a
  read-only folder) instead of a generic "verification failed".
- The cache folder is created more reliably: the game tries the normal
  save-system folder first, then falls back to system commands, and
  double-checks the folder can actually be written to before using it.
  **CACHE STATUS** now shows which method was used (LOVE FS / MKDIR / NONE).
- If the cache folder can't be set up, the game now retries instead of
  quietly disabling the cache for the whole session.
- Boot logging: when the cache is rejected, the game log now explains
  exactly why, which makes "it rebuilds every time" reports much easier to
  diagnose.

## [1.4.1] - 2026-08-12

### Fixed

- The map-cache build now starts on Windows: the cache folder is created with
  Windows-native commands (`if not exist ... mkdir ...` for each level instead
  of the POSIX-only `mkdir -p`, which cmd.exe rejected by treating `-p` as a
  folder name and choking on the `/dev/null` redirect). The build used to fail
  the instant it began after a cache wipe, on every Windows release back to
  1.3.3.

## [1.4.0] - 2026-08-12

### Added

- One build for every device: the DS_BRICK environment switch is gone, so the
  tuned diorama runs identically on everything -- no more desktop/potato
  split.
- The VOXEL ladder is now a set of quality MODES (OFF / HIGH / MEDIUM / LOW /
  POTATO / CUSTOM). Picking a mode applies its tuned preset to every quality
  knob -- WATER, FOREST FX, AA, V-CURVE, V-GRID, 3D-BTL, SHADOWS, SHADOW
  QUALITY and RENDER SCALE -- and changing any knob on its own flips the mode
  to CUSTOM until a named mode is picked again.
- Added a RENDER SCALE row (100% / 75% / 50% / 33%), the single biggest
  frame-budget lever: the modes set it, and moving it on its own also flips
  the mode to CUSTOM.
- The quality knobs (WATER, FOREST FX, AA, V-CURVE, V-GRID, BACK SPRITES) are
  no longer pinned off on every device: each is a switchable row on the VOXEL
  SETTINGS submenu.
- Added a STADIUM SPRITES row (OFF / ON): staged fights use the Pokemon
  Stadium battle models -- skinned and animated -- instead of the flat battle
  pics. It shows while 3D-BTL is on and needs the models built from the
  player's own Pokemon Stadium (US) 1.0 ROM.
- Stadium packs are now compressed with LZ4 -- the same codec as the terrain
  mesh cache -- so the set is roughly 40% smaller on disk and reads back
  faster. Old raw packs and new compressed ones load through the same path.

### Changed

- Stadium models and their discs are lit by a real sun-directional diffuse
  term (an ambient floor plus a diffuse against the actual sun direction)
  instead of a flat axis-aligned guess, so a Pokemon reads as properly
  shaded in the same light the shadow map throws.
- V-GRID now follows the player's setting inside 3D battles (it used to be
  forced on).
- The anti-aliasing fold gains a light crispness (unsharp) term, so
  supersampling no longer washes out the tileset (AntiAlias.SHARP, tunable).

### Fixed

- Stadium models no longer read their own stale shadow: they are cast-only,
  like the flat battle cards, so the glitchy moire that crawled over their
  bodies is gone.

## [1.3.10] - 2026-08-11

### Added

- Added a SHADOWS row (ON / OFF). OFF is the flat-lit diorama: no shadow map
  is drawn, the main pass is sent sunDark=0, and the contact blobs under the
  characters go with it -- in free-roam and staged battles alike, so a device
  that cannot carry the shadow pass can turn it off wholesale rather than
  only dropping the expensive animated-actor layer.
- Added a SHADOW QUALITY row (AUTO / 512 / 1024 / 2048). AUTO is the adaptive
  ladder the pass always ran (the smallest size whose texel stays under a
  target slice of a world pixel, capped at 2048); a fixed rung forces the
  square shadow map's edge in texels whatever the view, so a player can trade
  fill rate and RAM (a 2048 edge is a 16 MB depth pass, re-rasterised
  whenever the shadow signature moves) for finer shadow edges.
- Both rows are visible in every profile: they appear on the VOXEL SETTINGS
  submenu and the mod manager's page whether the device runs the Brick
  profile (which pins every other knob) or the full desktop mod, and stay on
  the menu under the FULL preset.

### Fixed

- The shadow map canvas is now allocated at the fitted resolution rung
  instead of staying pinned to the ladder's smallest size. The 1536 and 2048
  rungs used to render into a 1024 (or 512 on the Brick) map whose fit, depth
  bias and filter were computed for the finer rung; a fixed SHADOW QUALITY
  rung now produces a map of exactly that size, and the Brick HIGH rung's
  documented 1536 edge is real.

## [1.3.9] - 2026-08-11

### Fixed

- The enemy HUD panel is hidden while a wild battle's intro plays its ball
  animation, instead of showing an empty status box over the arena.

### Contributors

- **AverageConsumer** — the wild-intro HUD fix.

## [1.3.7] - 2026-08-11

### Added

- Added a `github` field to the manifest (`ShaneMcGovernIE/potato_voxel`) so the
  launcher enables the Check for updates / Versions / Update flow for
  PotatoVoxel.

### Fixed

- Removed the per-byte Lua checksum pass that ran over every decompressed
  cache payload on load, eliminating a slight hitch when moving between maps
  with the compressed mesh cache enabled. Truncation is still caught by the
  packed-length and raw-length checks.

## [1.3.6] - 2026-08-11

### Added

- Added an opaque Town Map loading cover for cold asynchronous voxel builds. On
  a cold cache the cover stays up until the current map's first terrain mesh is
  ready, so the vanilla 2D world never flashes before the diorama appears. The
  mesh queue keeps pumping behind it, and invisible overworld updates pause
  until the build finishes, failing open if a build ends without terrain or
  voxel mode is turned off. Loading state is exposed through
  `mod.potato_voxel.loading_changed` and `mod.exports.isLoading`.

### Fixed

- Staged battles now honour the engine's `bottomUIVisible()` and
  `statusHUDVisible()` seams before drawing PotatoVoxel's battle backings, so a
  mod hiding the battle UI no longer leaves frosted panels behind.
- The staged-battle front-sprite wrapper now runs before downstream
  `pokemon.sprite` wrappers, asks them for the FRONT variant with a copied
  side context, and propagates `trueColor` back to the caller, so compatible
  sprite-replacing mods apply inside staged battles instead of being bypassed.

### Contributors

- **AverageConsumer** — interoperability with battle UI and sprite mods, and
  the cold mesh-build loading cover.

## [1.3.5] - 2026-08-11

### Fixed

- Fixed long launcher stalls when booting with a complete compressed mesh cache.
- Boot-time cache readiness now validates bounded file headers, fingerprints,
  codecs, packed lengths, and file sizes without reading or decompressing every
  terrain, water, and auxiliary payload.
- Rebuilding a missing cache manifest now uses the same bounded header scan
  instead of decoding the full cache before the title screen.

### Performance

- Full LZ4 decompression, checksum validation, and mesh decoding remain
  deferred until a map actually loads its mesh or an explicit cache
  verification runs, reducing startup I/O and peak memory use.

## [1.3.4] - 2026-08-10

### Added

- Added optional LZ4 compression for large terrain, water, and auxiliary mesh-cache payloads when the runtime supports it and the compressed result is smaller.
- Compressed entries store their codec, raw and packed lengths, and a checksum so damaged or truncated cache files are rejected safely.
- Existing raw cache files remain readable and are repacked lazily when loaded; **PREBUILD CACHE** migrates the complete cache in one pass.
- Added compression-aware cache status labels: **READY CMP**, **READY MIX**, and **READY RAW**, with the detailed **CACHE STATUS** view showing the same state.

### Performance

- Reduces on-disk cache size and the amount of data read from storage during cache loads, especially for large terrain meshes.
- Keeps raw fallback for unsupported runtimes, tiny payloads, or cases where LZ4 would not reduce the size.
- Does not change mesh vertices, UVs, rendering quality, GPU memory use, or steady-state draw cost.

## [1.3.3] - 2026-08-10

### Added

- Added optional optimized 3D battles to the Brick profile, following the VOXEL render-quality scale.
- Reused the existing cached map terrain for staged battle scenes.

### Fixed

- Split battle terrain and Pokemon cards into separate shadow layers to prevent camera-dependent triangle artifacts.
- Battle cards no longer receive their own sun-shadow depth test while continuing to cast shadows onto the arena.
- Lower Brick battle tiers use contact shadows instead of the actor shadow map.

## [1.3.2] - 2026-08-10

### Added

- Added boot-time mesh-cache readiness detection with automatic migration for complete current caches.
- Added **CACHE STATUS** and confirmed **WIPE CACHE** actions under VOXEL SETTINGS.
- Added a cancellable cache-prebuild prompt before CONTINUE and NEW GAME when the cache is incomplete.

### Fixed

- Prebuilds now validate durable terrain, water, and auxiliary files before reporting READY.
- Cache identities now include the active ROM/data revision, preventing stale geometry from being reused across versions.
- Cache completion is finalized immediately after the last job instead of waiting for another frame.

## [1.3.1] - 2026-08-10

### Changed

- Added conflict detection for `BATTLE_ART_VOXEL_FORK` and `DRAMALESS_SHAPE`, showing a clearer warning that two voxel mods should not be installed at the same time.

## [1.3.0] - 2026-08-10

### Performance

- Reduced Building voxel placement cost with anchor-tile candidate indexing while preserving row-major matching and first-claim behavior.
- Reduced Building voxel model-generation cost with cached atlas shade sampling, lower index arithmetic overhead, and dense voxel storage.
- Preserved building geometry, shading, UVs, shadows, seams, and BuildBudget coroutine behavior.

### Fixed

- SELECT no longer changes the Voxel graphics quality ladder; quality remains controlled by the Voxel option and its supported hotkeys.

## [1.2.4] - 2026-08-10

### Fixed

- Fixed performance regressions in POTATO Mode.
- Removed the DEBUG option from the in-game OPTIONS menu; diagnostics remain available only through benchmark instrumentation.

## [1.2.3] - 2026-08-09

### Fixed

- Fixed stretched, screen-spanning overworld NPC shadows on Android by guarding zero-length camera-ray normalization in the mobile shader.
- Kept NPC contact shadows grounded and stable with camera-ward depth bias and pixel-quantized placement.
- Replaced animated NPC shadow silhouettes with fixed contact-shadow blobs so animation frames, mirroring, and jump lift cannot stretch or shimmer shadows.
- Removed the DEBUG option from the in-game options menu.

[1.3.7]: https://github.com/ShaneMcGovernIE/potato_voxel/releases/tag/v1.3.7
[1.3.6]: https://github.com/ShaneMcGovernIE/potato_voxel/releases/tag/v1.3.6
[1.3.5]: https://github.com/ShaneMcGovernIE/potato_voxel/releases/tag/v1.3.5
[1.3.4]: https://github.com/ShaneMcGovernIE/potato_voxel/releases/tag/v1.3.4
[1.3.3]: https://github.com/ShaneMcGovernIE/potato_voxel/releases/tag/v1.3.3
[1.3.2]: https://github.com/ShaneMcGovernIE/potato_voxel/releases/tag/v1.3.2
[1.3.1]: https://github.com/ShaneMcGovernIE/potato_voxel/releases/tag/v1.3.1
[1.3.0]: https://github.com/ShaneMcGovernIE/potato_voxel/releases/tag/v1.3.0
[1.2.4]: https://github.com/ShaneMcGovernIE/potato_voxel/releases/tag/v1.2.4
[1.2.3]: https://github.com/ShaneMcGovernIE/potato_voxel/releases/tag/v1.2.3
