# Changelog

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
