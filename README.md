# PotatoVoxel

A performance-first 3D voxel diorama for the Pokémon Gen 1 Recompilation.

PotatoVoxel is a fork of [Dramatic Shape Voxel Mod](https://github.com/DramaticShape/DramaticShapeVoxelMod) v1.6.2. It keeps the original mod's defining features—extruded terrain, a depth-buffered camera, billboard characters, shadows, and optional 3D battles—but tunes the experience for low-power handhelds and other constrained devices.

## What players get

Compared with the original mod, PotatoVoxel is designed to provide:

- **Smoother gameplay:** mesh generation is spread across frames instead of blocking gameplay with large work spikes.
- **Lower GPU load:** MEDIUM, LOW, and POTATO render the 3D scene at 75%, 50%, and 33% of window resolution, then scale it back to the display.
- **Lower geometry cost:** distant border forests use crossed billboard cards instead of expensive carved voxel hulls.
- **Predictable defaults:** water, anti-aliasing, staged 3D battles, and other costly effects are disabled by default.
- **Faster revisits:** terrain meshes are stored in the mod's scoped storage and prebuilt from the OPTIONS menu.

These changes target frame-time spikes, fill rate, and memory pressure. They are optimizations rather than a promise of a specific FPS on every device.

## Quality modes

The **VOXEL** option is a mode ladder. Picking a mode applies that mode's
tuned defaults to every quality knob in the VOXEL SETTINGS menu; changing
any knob individually flips the mode to **CUSTOM**, which keeps your own
combination until you pick a named mode again:

- **OFF** — use the normal 2D overworld.
- **HIGH** — 100% render scale, full water effects, 2X AA.
- **MEDIUM** — 75% render scale, sky reflections, cheaper shadows.
- **LOW** — 50% render scale, water off.
- **POTATO** — 33% render scale, the lowest GPU workload.
- **CUSTOM** — the VOXEL row reads this the moment any knob leaves its
  mode's preset.

**RENDER SCALE** (100% / 75% / 50% / 33%) is its own row in the VOXEL
SETTINGS menu: the modes set it, and moving it on its own also flips the
mode to CUSTOM.

The potato profile is the build. Every device runs the same tuned diorama —
there is no environment switch to a full desktop path, so behaviour is
identical everywhere. **3D-BTL** defaults OFF, follows the VOXEL quality
scale when enabled, and keeps the map mesh cache.

Shadows are enabled on every device that can run the shadow pass; when a
device genuinely cannot, the game says why in the session log instead of
failing silently.

## Removed in 1.6.1 (the sandbox release)

The engine's mod sandbox removed raw file access, native interop and OS
queries. The features that depended on those are gone — see
[docs/adr/0004-feature-removals.md](docs/adr/0004-feature-removals.md) for
the reasoning:

- **FOREST FX** (the Viridian Forest haze and light beams)
- the **frosted battle-HUD glass** (battle HUDs draw on plain panels)
- **STADIUM models** (importing a player-supplied Pokémon Stadium ROM is
  impossible without raw file reads) — the 3D-BTL ladder is now
  2D-3D A / 2D-3D B / OFF
- **VR** (the OpenXR loader and its rigs)
- the **DEBUG diagnostics panel** and its instrumentation

## Install

Import the .zip in-game (MODS > Import mod .zip), or copy the folder to
the game's `mods/` directory and restart — mods load at boot. The mod
conflicts with `DRAMATIC_SHAPE`, `ds_fp_ceiling`, the pre-rename
`dramatic_shape_brick`, `BATTLE_ART_VOXEL_FORK` and `DRAMALESS_SHAPE`;
only one may run at a time.

## Diagnostics (hidden)

F9 toggles a debug overlay (off by default), F10 switches its detail
level, F8 exports its log. It exists for support reports and is silent
unless turned on.

## Develop & test

From the engine checkout root:

```sh
POKEPORT_DATA_DIR="$PWD/tests/fixture_data" \
  luajit mods/potato_voxel/tests/potato_voxel_test.lua
```

The suite asserts the single potato build (the collapse is exercised
in-process by `BrickProfile.apply()`), and the cache suites run against a
fake `mod.storage` box so they stay headless. Gates:

```sh
python3 tools/modkit.py lint mods/potato_voxel
python3 tools/modkit.py pack mods/potato_voxel
```

## Data & cache

- **The cache is per save file.** It lives in the mod sandbox's scoped
  storage (game version x playthrough x mod). Build it once IN-GAME --
  accept the BUILD NOW prompt after CONTINUE, or run OPTIONS > VOXEL
  SETTINGS > PREBUILD CACHE -- let it finish, then **save the game**.
  The save write is what binds the cache to that save file, so a later
  launch reuses it instead of asking again. Each other save file gets
  its own cache and asks once.
- Settings persist under `options.modOptions.potato_voxel` (row ids
  `potato_voxel:*`).
- The terrain mesh cache lives in the mod sandbox's **scoped storage**
  (no longer a folder on disk — WIPE CACHE empties the storage keys).
  Each payload carries a small summary record (fingerprint, codec,
  lengths) so the boot-time READY check reads summaries, not whole
  payloads. `MeshCache.GEOMETRY_VERSION` must be bumped whenever
  geometry output changes. Old raw cache folders under `mod-derived/`
  from previous releases are not used — they can be deleted by hand.
- **OPTIONS → PREBUILD CACHE** cooperatively builds every map's body and full
  terrain variant, including water and auxiliary meshes. The game checks the
  complete cache at boot and shows **READY** when every current job is present.
  When the cache is incomplete, **CONTINUE** or **NEW GAME** offers to build it
  after the save loads (the check runs against the save's actual options, so a
  matching cache never prompts); choosing NO starts normally. An interrupted
  build resumes from the jobs it already finished. The progress screen can be
  cancelled, and runtime GPU meshes are released after each map while the
  stored cache remains.
- **CACHE STATUS** shows the active geometry-cache version and the
  compression codec. **WIPE CACHE** removes the precalculated payloads and
  clears the completion marker; the next voxel visit rebuilds maps on demand.
- **3D-BTL** reuses the same cached map terrain as the overworld. The battle
  cards and effects stay dynamic because they follow the live battle state;
  only the static map geometry belongs in the cache.

## Credits

- **DramaticShape** — the upstream Dramatic Shape Voxel Mod this is a fork
  of (v1.6.2, github.com/DramaticShape/DramaticShapeVoxelMod). Its own
  code carries no license; PotatoVoxel is a derived work.
- **pret/pokered** — the tile and sprite data the geometry is derived from.
- **AverageConsumer** — battle UI/sprite interoperability improvements and
  the cold mesh-build loading cover.

Version history (including the 1.6.2-brick.\* lineage under the old name)
is in [CHANGELOG.md](CHANGELOG.md).
