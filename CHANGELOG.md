# Changelog

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
