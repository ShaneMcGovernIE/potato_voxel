# PotatoVoxel

A performance-first 3D voxel diorama for the Pokémon Gen 1 Recompilation.

PotatoVoxel is a fork of [Dramatic Shape Voxel Mod](https://github.com/DramaticShape/DramaticShapeVoxelMod) v1.6.2. It keeps the original mod's defining features—extruded terrain, a depth-buffered camera, billboard characters, shadows, and optional 3D battles—but tunes the experience for low-power handhelds and other constrained devices.

## What players get

Compared with the original mod, PotatoVoxel is designed to provide:

- **Smoother gameplay:** mesh generation is spread across frames instead of blocking gameplay with large work spikes.
- **Lower GPU load:** MEDIUM, LOW, and POTATO render the 3D scene at 75%, 50%, and 33% of window resolution, then scale it back to the display.
- **Lower geometry cost:** distant border forests use crossed billboard cards instead of expensive carved voxel hulls.
- **Predictable defaults:** water, forest effects, anti-aliasing, staged 3D battles, and other costly effects are disabled by default.
- **Faster revisits:** terrain meshes can be stored on disk and prebuilt from the OPTIONS menu.
- **Useful diagnostics:** the DEBUG option shows frame-time and mesh-build statistics while tuning.

These changes target frame-time spikes, fill rate, and memory pressure. They are optimizations rather than a promise of a specific FPS on every device.

## Quality modes

The **VOXEL** option is a mode ladder. Picking a mode applies that mode's
tuned defaults to every quality knob in the VOXEL SETTINGS menu; changing
any knob individually flips the mode to **CUSTOM**, which keeps your own
combination until you pick a named mode again:

- **OFF** — use the normal 2D overworld.
- **HIGH** — 100% render scale, full water and forest effects, 2X AA.
- **MEDIUM** — 75% render scale, sky reflections, low forest effects.
- **LOW** — 50% render scale, cheaper shadows, water and forest off.
- **POTATO** — 33% render scale, the lowest GPU workload.
- **CUSTOM** — the VOXEL row reads this the moment any knob leaves its
  mode's preset.

**RENDER SCALE** (100% / 75% / 50% / 33%) is its own row in the VOXEL
SETTINGS menu: the modes set it, and moving it on its own also flips the
mode to CUSTOM.

The potato profile is the build. Every device runs the same tuned diorama —
there is no environment switch to a full desktop path, so behaviour is
identical everywhere. **3D-BTL** defaults OFF, follows the VOXEL quality
scale when enabled, and keeps the map mesh cache; legacy staged and Stadium
selections remain compatible internally when ON.

VR support and its OpenXR loader are not included in this release. If you need VR, use the upstream mod or restore the loader from it.

## Install

Import the .zip in-game (MODS > Import mod .zip), or copy the folder to
the game's `mods/` directory and restart — mods load at boot. The mod
conflicts with `DRAMATIC_SHAPE`, `ds_fp_ceiling` and the pre-rename
`dramatic_shape_brick`; only one may run at a time. Remove the old
`dramatic_shape_brick` from the mod manager after installing.

## Develop & test

From the engine checkout root:

```sh
POKEPORT_DATA_DIR="$PWD/tests/fixture_data" \
  luajit mods/potato_voxel/tests/potato_voxel_test.lua
```

The suite asserts the single potato build (the collapse is exercised
in-process by `BrickProfile.apply()`). Gates:

```sh
python3 tools/modkit.py lint mods/potato_voxel
python3 tools/modkit.py pack mods/potato_voxel
```

## Data & cache

- Settings persist under `options.modOptions.potato_voxel` (row ids
  `potato_voxel:*`).
- The terrain mesh cache lives at `mod-derived/potato_voxel/meshes` under
  the save dir; delete it (or the whole `mod-derived` tree) to force a
  rebuild. `MeshCache.GEOMETRY_VERSION` must be bumped whenever geometry
  output changes — the cache fingerprint does not cover every geometry
  knob. Large payloads use LZ4 compression when the runtime supports it;
  raw payloads remain readable as a fallback. This reduces storage and cache
  read cost, not steady-state GPU draw cost. Existing raw entries are repacked
  lazily as they are loaded; running PREBUILD CACHE migrates the full set.
  Boot-time READY checks read only bounded headers and file sizes; full
  decompression and checksum validation are deferred until a map is used.
- **OPTIONS → PREBUILD CACHE** cooperatively builds every map's body and full
  terrain variant, including water and auxiliary meshes. The game checks the
  complete cache at boot and shows **READY** when every current job is present.
  When the cache is incomplete, selecting **CONTINUE** or **NEW GAME** offers
  to build it first; choosing NO starts normally. The progress screen can be
  cancelled, and runtime GPU meshes are released after each map while the disk
  cache remains. The action is available on both desktop and the potato
  profile.
- **CACHE STATUS** shows the active geometry-cache version. **WIPE CACHE**
  removes the precalculated terrain files and clears the completion marker;
  the next voxel visit rebuilds maps on demand.
- **3D-BTL** reuses the same cached map terrain as the overworld. The battle
  cards and effects stay dynamic because they follow the live battle state;
  only the static map geometry belongs in the disk cache.

## Credits

- **DramaticShape** — the upstream Dramatic Shape Voxel Mod this is a fork
  of (v1.6.2, github.com/DramaticShape/DramaticShapeVoxelMod). Its own
  code carries no license; PotatoVoxel is a derived work.
- **pret/pokered** — the tile and sprite data the geometry is derived from.
- **pret/pokestadium** — the decompilation the STADIUM extractor was
  written against (no code or data from it is included or redistributed).
- **AverageConsumer** — battle UI/sprite interoperability improvements and
  the cold mesh-build loading cover.

Version history (including the 1.6.2-brick.\* lineage under the old name)
is in [CHANGELOG.md](CHANGELOG.md).
