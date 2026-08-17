# 01 — World Model: Coordinates, Data Sources, and the Shape Vocabulary

## Coordinate system (Voxel3D.lua:3-12)

```
+X  map east   (world-pixel x)
+Y  up         (0 is the ground plane)
+Z  map south  (world-pixel y)
```

- World space IS world pixels. Every coordinate the 2D paths compute
  drops straight in; a connected neighbour map translates by the same
  `(ox, oy)` the flat renderer uses (VoxelScene.lua:3-6).
- A character at rest faces +Z ("facing down" in the 2D game).
- A **map cell is 16x16 px**, a **tile is 8x8 px**, a block is 2x2
  tiles. `def.width * 4` = map size in tiles (ChunkMesher.lua:428).
- 1 voxel = 1 world pixel = 1 model unit. This is load-bearing for the
  wireframe shader (see README invariant 2).

## Map data sources

The mod reads four things from the engine, all already in memory:

| Source | What it gives | Used by |
|---|---|---|
| `map:tileAt(tx, ty)` | tile id at tile coords (border-*extends* off the map) | shape resolution, meshing |
| `map:cellTile(cx, cy)` | the bottom-left tile of a cell | collision tests |
| `map:isWalkableCell / isWaterCell / isGrassCell` | cell-level collision | shape resolution (TileShape.at) |
| `map.tileset` | tileset record: `image` path, `tilesPerRow` (16), `imageWidth/Height` (128x48), `blocks`, `animatedTiles`, `grassTile`, `doorTiles` | pixel access, UV math, derived pins |
| `TileRenderer.borderBlockFor(map)` | what the ring outside the body is made of (tree wall for overworlds) | ring resolution (Structures.lua:187-189) |
| `Assets.imageData(tileset.image)` | the atlas pixels (8-shade grayscale or recolored) | everything that voxelizes per pixel |

Two granularities, deliberately mixed:

- **Tile level (8x8):** which *drawing* is here. The detector and the
  mesher reason in tiles.
- **Cell level (16x16):** what it *means* for walking. Collision in this
  engine (like the GB original) is judged per cell by the cell's
  bottom-left tile alone. The other three tiles carry no collision
  meaning (TileShape.lua:13-21).

## The shape model: classes, heights, art modes

Every tile resolves to a **shape record** (TileShape.lua:312-321):

```lua
{ class = "wall",     -- one of the vocabulary below
  h = 16,             -- height in world pixels (a cell is 16)
  art = "upright",    -- how the mesher draws it (see below)
  flat = false,       -- draws a flat ground quad (ground/water/void/grass/flower)
  authored = true }   -- true when the profile pinned it (bypasses detection)
```

### Class → height fallbacks (TileShape.lua:48-120)

| class | h | meaning |
|---|---|---|
| ground / void | 0 | flat; water recesses (-2) so shorelines show a lip |
| water | -2 | recessed flat sheet (drawn as its own pass) |
| ledge | 6 | box, art on TOP face |
| roof / bed / backrest | 28 / 7 / 12 | top-face boxes |
| wall / tree / fence / sign | 16 | box whose SOUTH face folds the art upright |
| cliff | 32 | masonry two courses tall (Indigo Plateau rim) |
| cylinder / stump / planter / can | 16 / 16 / 32 / 9 | round hull archetypes (see 05) |
| canopy | 32 | anchor tile of a 2x2-cell tree group |
| billboard / signpost / post / prop / cutout / bike / console / stool | 16 / 16 / 16 / 16 / 16 / 16 / 16 / 8 | per-pixel standees, differing depths |
| grass / flower | 0 | flat ground + standing tufts/cutouts (additive) |
| table / desk / counter | 12 / 24 / 8 | furniture boxes |
| relief | 3 | top-down prop extruded a few voxels |
| bookcase | 32 | shelf ranks collapsed to one cell of depth |
| stair_e / stair_w / stair_down_* | 16 | real steps (rising / excavated) |

Heights are overridable per tileset (`tilesets[<id>].heights` — the DOJO
lab tables are 6 px), and the sprite-riding height `groundAt` reads the
same resolved table (TileShape.lua:334-352, VoxelScene.lua:178-197).

### Art modes (TileShape.lua:135-209)

| art | rendered as |
|---|---|
| `flat` | a single quad at height h (ground, water, void) |
| `top` | a box with the art on its TOP face — art drawn as seen from above (ledges, roofs, beds, backrests) |
| `upright` | a box whose SOUTH face reconstructs the 2D art standing up — art drawn face-on (most of Gen 1: walls, facades, furniture) |
| `cylinder` | round scenery carved as a voxel hull from the art's darkest outline |
| `canopy` | the anchor of a 2x2-cell hull group |
| `planter` | a 16x32x16 hull standing in the SOUTH of its two cells |
| `billboard` | a thin per-pixel voxel slab, transparency respected (signs, props) |
| `post` | per-CELL standee slabs (fence posts march separately) |
| `grass` | flat ground + two standing tuft rows per tile |
| `flower` | flat ground + a 1-voxel standing cutout of the darkest tones |
| `relief` | top-down drawing extruded a few voxels, art on top |
| `bookcase` | shelf ranks collapsed to a one-cell-deep box, pane relief |
| `stair` | real stepped geometry (4 steps per cell), rising or excavated |

## The map-scene record `S` (Structures.forMap's output)

Everything downstream reads one record per map (Structures.lua:249-253):

```lua
S = {
  shapeAt   -- GridKey.of(tx,ty) -> shape record (resolved, post-overrides)
  tileAt    -- GridKey.of(tx,ty) -> tile id (post-repaint: figures/mounted/doors)
  runs      -- key -> volume run record {front, north, extent, unit,
            --        fromRepeat, door, roofRows, rise, peak, h}
  skip      -- key -> true: claimed by a special builder (object/hull/
            --        building/stairs); the mesher paints ground under it
  ground    -- key -> tile id of synthesized ground under a claimed cell
  doorFold  -- key -> true: a folded doorway column (adopts region height)
  objectQuads  -- prebuilt per-pixel prop quads (world space)
  grassQuads   -- tuft quads, drawn AFTER characters (own mesh)
  flowerQuads  -- flower cutout quads, own mesh, after characters
  roundStamps  -- {quads, mx, mz, r} tree hull placements (expanded by mesher)
  figures      -- authored figures {quads, wx, wz, y} (local-space cards)
  outdoor      -- Map.isOutdoor(def)
  hideBareRing -- hullRingOnly (tree ring is modelled or it is not there)
}
```

`GridKey.of(tx, ty) = (ty + 64) * 4096 + (tx + 64)` — a packed key, fine
within a ±64-tile range. The contract lives in `lib/GridKey.lua` and is
shared by Structures, Buildings, ShapeDebug, and ChunkMesher.
