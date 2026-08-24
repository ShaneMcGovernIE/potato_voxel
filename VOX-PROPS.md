# Authored voxel props (`.vox`)

Almost everything PotatoVoxel draws is *derived*: `Structures.lua` floods
regions of tiles, `Buildings.lua` measures a house off its own sprite pixels,
`VegetationBuilder` and friends synthesize props from the artwork. Nothing is
modelled by hand.

An **authored prop** is the exception. You draw a model in MagicaVoxel, name
the tile drawing it replaces, and the build stamps your model wherever that
drawing occurs. The dock truck on `VERMILION_DOCK` is the worked example.

- `lib/VoxLoader.lua` reads the `.vox` file
- `lib/VoxProps.lua` snaps its colours, meshes it, finds its placements
- `data/vox_props.lua` is the authored list
- `models/*.vox` are the models themselves

## The short version

1. Model it in MagicaVoxel at **1 voxel = 1 world pixel**, sized to the
   drawing it replaces (a 4x2 tile drawing is 32x16 voxels of footprint).
2. Save it into `models/`.
3. Find the tile ids of the drawing you are replacing.
4. Add a row to `data/vox_props.lua`.
5. Bump `MeshCache.GEOMETRY_VERSION` and its pin in
   `tests/potato_voxel_cache_test.lua`.
6. Look at it: `tests/drivers/voxel_truck_test.lua` in the engine repo is a
   copyable driver.

## Scale and orientation

The world is in Game Boy pixels. A tile is 8px, a walk cell is 16px (2x2
tiles), and one voxel is one world pixel. So:

| Drawing | Footprint you have to fill |
|---|---|
| 1 tile (8x8) | 8 x 8 voxels |
| 1 cell (2x2 tiles) | 16 x 16 voxels |
| the dock truck (4x2 tiles) | 32 x 16 voxels |

Height is free — the model rises as tall as you built it, and nothing clips
it.

MagicaVoxel is z-up; the engine is y-up. The loader swaps the axes for you:

```
MagicaVoxel  ->  world
    +X            +X   east
    +Z            +Y   up
    +Y            -Z   north
```

The practical version: **build the model as you want it seen from the south**
(the camera's default facing), with +Z as up. If it comes out mirrored or
back-to-front, do not re-export — set `flipX` or `flipZ` on the prop record.

The model is anchored at the **north-west corner** of the tile pattern it
replaces. A model larger than its pattern overhangs east and south; that is
allowed (the quads are marked `own`, so the chunk mesher's edge rules will not
eat them), but only the pattern's own tiles are claimed, so an overhang can
collide with whatever the detector built next door. Match the footprint unless
you have a reason not to.

## Colour: everything snaps to the map's four shades

An authored model does **not** carry its own texture. That is deliberate, and
it is the part worth understanding before you spend time on a paint job.

`VoxProps.swatches` scans the pixels of the drawing you are replacing, picks
the most common atlas texel of each of the four GB shades, and every face of
your model samples one of those four texels. Because the model reads through
the same atlas as everything else, it inherits the whole colour pipeline for
free: SGB palette bakes, RED++ per-map GBC atlases, true-colour mod atlases,
animated tiles, day tint, the shadow pass.

Your palette decides only *which of the four shades* a voxel lands on:

- the used palette entries are ranked by luminance,
- and spread across black / dark / light / white over the range the model
  actually covers.

So a model painted in four flat colours maps 1:1 (the truck does), and a
model painted in fifty shades of grey still comes out with full contrast
rather than collapsing into one shade. Hue is discarded entirely — a red truck
and a blue truck of the same brightness are the same truck. Paint for
**value**, not colour.

Two consequences worth planning around:

- Detail smaller than a value step disappears. Four shades is four shades.
- If the drawing you are replacing only contains, say, black and white, your
  model only gets black and white. The swatch table fills missing shades from
  the nearest present one.

## Finding the tile ids

A prop is matched by the exact grid of tile ids it replaces, so a shared tile
id elsewhere on the map cannot accidentally become your model.

**Gold:** use the workbench (`tools/workbench/README.md`). Select the object's
top-left and bottom-right cells and capture the rectangle; it prints the tile
grid.

**Gen 1, or offline:** read the generated data in the engine repo. Maps store
block ids; a tileset's blocks are 4x4 tiles, row-major:

```python
# tile at map tile (tx, ty)
block = map.blocks[(ty // 4) * map.width + (tx // 4)]
tile  = tileset.blocks[block][(ty % 4) * 4 + (tx % 4)]
```

The fastest way to be sure is to render the map to a PNG and look at it —
paste the tileset atlas (`assets/generated/tilesets/<id>.png`, 16 tiles per
row, 8px each) tile by tile through the expression above, then read the tile
ids straight off the drawing you can see.

The dock truck came out of `VERMILION_DOCK` block 3 at map tile (40, 0):

```
72 73 74 75
88 89 60 76
```

## The prop record

`data/vox_props.lua` is keyed by tileset id, then a list of props:

```lua
return {
  SHIP_PORT = {
    {
      model = "HarborTruck",     -- models/HarborTruck.vox
      flipX = true,              -- optional
      tiles = {                  -- the drawing this replaces
        { 72, 73, 74, 75 },
        { 88, 89, 60, 76 },
      },
    },
  },
}
```

| Field | Meaning |
|---|---|
| `model` | file stem under `models/`, no extension |
| `tiles` | rows of tile ids; row 1 is the north row, all rows the same length |
| `flipX` | mirror east/west |
| `flipZ` | mirror north/south |

Every occurrence of the pattern on the map **body** is stamped (the border
ring is never scanned). List order is priority order: a prop never stamps into
cells an earlier prop or a `Buildings` template already claimed.

One model is meshed once per tileset and reused at every placement, so a prop
that occurs forty times costs one mesh.

## Rebuilding the cache

Geometry is cached per map on disk. A cache written before your prop existed
has an object stream with your model missing from it, and nothing about
editing `data/vox_props.lua` invalidates it.

So whenever you add, remove, or move a prop, bump the geometry version in
`lib/MeshCache.lua`:

```lua
MeshCache.GEOMETRY_VERSION = 28
```

and update the pin in `tests/potato_voxel_cache_test.lua`, which asserts the
number so this cannot be forgotten quietly. Add a one-line note to the version
history above the constant, matching the entries already there.

During development you can also delete the cache from the mod's settings page
instead of bumping, but the bump is what ships — players have warm caches.

## Checking your work

`tests/vox_props_test.lua` covers the reader, the shade snap, the stamp, the
claim, and the flips against the shipped truck, with no LÖVE and no ROM:

```sh
luajit tests/vox_props_test.lua
```

To actually look at the thing, run a driver from the engine repo. Copy
`tests/drivers/voxel_truck_test.lua`, change the map and position, and:

```sh
SHOT_DIR=/tmp/shots POKEPORT_DRIVER=tests/drivers/my_prop_test.lua \
  POKEPORT_IDENTITY=proptest love .
```

`POKEPORT_IDENTITY` sandboxes the save directory. A fresh identity has no
imported cache and will hang on the launcher, so copy one in first:

```sh
cd ~/Library/Application\ Support/LOVE
cp -R pokemon-love2d/red proptest/red
```

## Constraints to keep in mind

**The sandbox.** `lib/` and `data/` run under the mod sandbox: no
`love.filesystem`, no `io`, no `os.getenv`, no `ffi`. Models are read through
`V.mod:read`, which returns the file as a binary string; `VoxLoader` parses it
with `string.byte`. `tests/sandbox_api_test.lua` enforces this.

**The geometry worker.** Map analysis also runs off the main thread in
`workers/geometry_worker.lua`, which builds its own `V` table. It has a
`V.mod:read` shim backed by `love.filesystem` for exactly this reason. If you
add another lib that reads a shipped asset, it will work in both VMs; if you
add a new *kind* of engine dependency, the worker needs a shim for it too.

**Meshing.** Faces are greedy-merged along one axis and every run stops at the
next 8px lattice line, so the world curve bends a prop's quads together with
the terrain around it. Do not lift that cap. The truck is 3420 voxels and
ships as 984 quads; that ratio is normal.

**`.vox` support.** The loader takes the first `SIZE`/`XYZI` pair and the
`RGBA` palette, and skips everything else — scene graph (`nTRN`/`nGRP`/`nSHP`),
layers, materials, cameras, notes. So a multi-model scene loads as its first
model only, and material effects (emissive, glass, metal) are ignored. One
model per file. A file with no `RGBA` chunk falls back to a brightness ramp by
index, which is a guess; export with a palette.

**Packaging.** `models/` ships in the mod zip. Keep models small — they are
uncompressed voxel records, and the whole point is a prop, not a set piece.
