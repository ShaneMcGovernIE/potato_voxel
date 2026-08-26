# MagicaVoxel building replacements

Drop MagicaVoxel `.vox` files here and point a building template at them.
A template with a `vox` name skips the placement when the file is missing
or unreadable, so later passes (cylinders, volumes) still run. Templates
with no `vox` assignment keep the procedural sprite-building model.

## How to replace a building

In `data/voxel_heights.lua`:

```lua
vox = {
  gen2_players_house_table = "elm_table",
}
```

or on the template itself:

```lua
{
  id = "gen2_players_house_table",
  vox = "elm_table",
  tiles = { ... },
}
```

Either form loads `assets/vox/elm_table.vox`. Optional on the template:

- `voxOffset = { x, y, z }` — world-pixel shift of the MagicaVoxel origin
  (default `{0,0,0}`, origin at the north-west tile, on the ground)
- `voxScale = 1` — MagicaVoxel voxels per world pixel (default 1)

## Coordinates

MagicaVoxel +X is east, +Z is up, +Y is south. One MagicaVoxel voxel is one
world pixel (one Game Boy pixel). A 32×32×16 model covers a 4×4 tile
footprint, 16 px tall.

Export from MagicaVoxel as `.vox` (version 150). Custom palettes in the
RGBA chunk are used; files without one fall back to a grey ramp.

After adding or changing a `.vox` file, rebuild the mesh cache
(OPTIONS → VOXEL SETTINGS → PREBUILD CACHE).

Shipped test models:

- `poles_wood_horizontal.vox` — poles arranged east-west; used for north-south fence runs
- `poles_wood_vertical.vox` — poles arranged north-south; used for east-west fence runs
- `pole_stone.vox` — Gen1 OVERWORLD grey bollard replacement
  (42/43 over 58/59, including Pewter City)
- `tree_large_kanto_day.vox` — Gen1 Viridian Forest large-tree canopy for the
  fixed Gen1 daytime palette (used in both periods; the 2x2-cell `$04` canopy
  group)
- `tree_large_kanto_night.vox` — Gen1 Viridian Forest large-tree canopy for the
  alternate moonlit palette, retained as an authored asset but not selected by
  the current Gen1 profile
- `kanto_tree_small.vox` — Gen1 town/route tree using the same compact bush
  geometry as Violet City and Route 30, with a Gen1 Advanced palette profile
- `kanto_ledge_{13,29,39,52,54,55}.vox` — directional Gen1 jump-lip models;
  separate names retain each source tile's Advanced palette group
- `crystal_pine_tall.vox` — Johto 4-row pine (tiles 30/31, 46/47, 46/47, 62/63)
- `crystal_pine_short.vox` — Johto 2-row pine (tiles 30/31 over 62/63)
- `crystal_cut_tree.vox` — Kanto and Johto CUT-tree replacement (the supplied
  model; Kanto uses tiles 45/46 over 61/62, Johto uses the four rotated
  19/21-over-69/29 CUT-block quadrants)
- `crystal_ledge_{nw,n,ne,w,c,e,sw,s,se}.vox` — Johto hop-bank autotile
  (tiles 43–45 / 59–61 / 75–77). Exposed edges are beveled dirt; a
  template with `requireClass = "ledge"` leaves pond shores on the water
  sheet.
- `crystal_cave_entrance.vox` — Johto block `$73` cave mouth (70/71 over
  86/87), a three-layer tapered rock arch with a shallow dark opening. Its
  surface uses the warm rock shades from BG palette slot 6 rather than the
  pale highlight used by the surrounding grass.
- `crystal_berry_tree.vox` — Crystal fruit-tree overworld sprite
  (`sprites/fruit_tree.png`). Drawn in place of the billboard.

The berry model can be regenerated from the extracted Crystal sprite with:

```sh
python3 tools/build_berry_tree_vox.py \
  "/path/to/crystal/assets/generated/sprites/fruit_tree.png" \
  assets/vox/crystal_berry_tree.vox
```
