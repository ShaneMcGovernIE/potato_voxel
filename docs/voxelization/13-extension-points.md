# 13 — Extension Points: Where This Mod Can Be Improved

Read this after the rest: the seams where the pipeline is designed to be
extended, and the known rough edges a contributor would attack first.

## Designed extension points

### 1. The profile: `data/voxel_heights.lua`

The single biggest lever. Everything it can do:

- Pin any tile to any class (`tilesets.<id>.<class> = {tile ids}`).
- Per-tileset height overrides, conditional pins (`when_above` /
  `when_below`), `prop_bg` / `prop_ground`, `bookcase_backfill` /
  `bookcase_relief`, `stump_cap` / `can_*`.
- Authored pixel masks: `figures` (people in furniture), `mounted`
  (things on walls) — both build headless.
- Building templates (`buildings`) with bands, parts, trays, desks,
  scrubs, keeps, supports, topRows, claimOnly.
- Any other mod can SHADOW this file (mods load order) to pin its own
  tiles' shapes — `mod.exports.lib` is the public seam
  (main.lua:1655-1658).

New classes need: a height in `FALLBACK_HEIGHTS`, an art mode in `ART`,
and (usually) a builder in Structures. The class vocabulary is global;
the per-tileset height override is the per-tileset dial.

### 2. The BrickProfile switches

`Structures.HULL_BILLBOARDS`, `BILLBOARD_CROSS`, `ROUND_RING`,
`ChunkMesher.*_SLICE`, `ShadowMap.SIZES/BRICK_HIGH_RES` are all plain
fields a variant build can retune — the "desktop mode" they were carved
out of is still present behind them.

### 3. Conditional pins and the region machinery

`when_above`/`when_below` prove the per-position resolution works; the
same mechanism can grow new conditions (e.g. `when_left/right`, or a
rule keyed on the map id).

### 4. Events and hooks the mod already subscribes to

`world.block_replaced`, `map.reloaded` (skips reason `"colors"`),
`battle.started/ended`, `save.writing/loaded/created`, `game.ready`.
A companion mod can rebuild/refresh meshes off the same events, or read
`mod.exports.debug` for capability/status data.

## Known rough edges (from the code's own comments)

1. **The detector is conservative by design.** Failed object clusters
   fall back to volumes; the profile fixes the art the detector reads
   wrong. Improvement = better segmentation (more shade-aware floods,
   texture continuity), less authoring per tileset.
2. **Key collisions**: `GridKey.of` is a packed int with a ±64-tile
   assumption (fine for Gen 1 maps); a port with bigger maps needs a
   real hash. The coordinate contract now lives in `lib/GridKey.lua`, so
   Structures, Buildings, ShapeDebug, and ChunkMesher cannot drift apart.
3. **`roundCache` is global and never LRU'd** — bounded in practice by
   tileset art variety, but a tileset-heavy session grows it. A cap or
   per-neighbourhood eviction would harden it.
4. **The `Assets.register` boot handoff** is a delicate dance (skip the
   first callback; skip on Switch until `builtAnything`). Any engine
   change to asset invalidation ordering needs re-verification.
5. **`TileRenderer.animFrame` fallback chain** reaches into `tick`'s
   upvalues via `debug.getupvalue` — an engine refactor of that module
   silently loses the shared clock (falls back to wall time).
6. **The map's `doorTiles` fold** assumes door graphics; a tileset that
   reuses a door tile for something else needs the profile pin to win
   (it does — pins override the fold, Structures.lua:264-294).
7. **Border-extension surprises**: `tileAt` border-extends and
   `borderBlockFor` answers `false` for BLACK void fill — both have
   caused regressions (whole files note them). Ports must reproduce the
   exact extension semantics.
8. **Water under the curve** needed a flat prepass because the 
   reflective pass can't depth-test against itself; a depth-capable
   renderer can do better.
9. **The flower union-mask mesh** (one slab per pixel, all six faces)
   is the most quad-dense aux mesh; the animation-in-texture-space
   trick is clever but a per-frame vertex update would be cheaper on
   GPUs that support it.

## Improvement candidates by cost

| Idea | Where | Cost |
|---|---|---|
| New shape classes via the profile (zero Lua) | data file | trivial |
| Conditional pins for more sides | TileShape authoredConditions | small |
| Re-enable the full carve + full shadow ladder on desktop | BrickProfile | trivial (switches exist) |
| A real texture atlas merging multiple tilesets (saves draw calls) | ChunkMesher/MeshCache | medium — touches UV math everywhere |
| Greedy quad merging across tiles (same texel runs already exist per tile; cross-tile merging needs atlas-adjacency) | ChunkMesher | medium |
| LOD: distance-based mesh decimation (ring vs body already exists as a concept) | Structures/ChunkMesher | medium |
| Instancing for repeated stamps (trees, grass) | ChunkMesher draw | medium |
| Per-frame animated grass/flowers via vertex data instead of texture rewrites | Structures/Water | medium-high |
| Collision from geometry (opt-in) | new module | high — changes gameplay contract |
| Multi-material: emissive tiles (lamps at night) | shader + atlas metadata | small-medium |

## Testing and verification (so improvements stay safe)

- Headless geometry suite: `ChunkMesher.geometry(map)` runs GPU-free —
  the invariants (water split, mask culling, keep-rules) are all
  asserted in `tests/potato_voxel_test.lua`.
- `Buildings.stats()` vs `tools/building_voxels.py` (reference
  implementation of the band pipeline).
- `tests/voxel_loading_test.lua`, `potato_voxel_cache_test.lua` run the
  cache against a fake storage box.
- Run from the engine root with
  `POKEPORT_DATA_DIR="$PWD/tests/fixture_data" luajit mods/potato_voxel/tests/potato_voxel_test.lua`
  — the fixture data dir is MANDATORY for suites that call `Data:load()`.
- Gates: `python3 tools/modkit.py lint/pack mods/potato_voxel`.
- Bump `MeshCache.GEOMETRY_VERSION` when geometry output changes, and
  the CHANGELOG + manifest version for a release.
