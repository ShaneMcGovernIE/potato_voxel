# PotatoVoxel Workbench

The live-area squares show the game’s actual 16×16 artwork, including Gold’s
town-specific roof overlays. To repair a house, do not stamp its individual
tiles as `roof` or `wall`: select the house’s top-left cell, select its
bottom-right cell, capture the rectangle, then save and hot reload the recipe.
The recipe records the entire 8×8 tile grid, so the building mesher recognizes
that exact house drawing anywhere it occurs in the selected tileset.

For signs, plaques, props, and tall trees, use **Object voxelizer**. Select
the object's top-left and bottom-right map cells (the rectangle can be larger
than one cell), capture it, then build its editable pixel mask. Its first pass
floods background in from the captured rectangle's edge while the black outline
holds the object artwork in place—the same thin, per-pixel slab treatment used
by the Gen 1 trail signs. Red preview pixels are cut away; click to toggle any
mistaken pixel, save, and hot reload. A cutout is matched by the full captured
tile rectangle, so a shared tile id elsewhere is not accidentally turned into
the same object.

This is a local, browser-based field editor for PotatoVoxel on **Pokémon
Gold**. It borrows the useful part of the survey tools: inspect a live map,
walk the nearby 16px cells and their four 8px graphic tiles, pin a tile to a
voxel shape, then reload the renderer immediately. Its Gen 2 building brush
also gives a schematic live voxel preview and stamps a set of selected cells
as roof, façade wall, ledge, or porch/ground. It intentionally does not
include battle tooling, sprite importers, or packaging/zip steps.

## Run it

Start Gold in developer mode so the game accepts hot reloads, then start this
server in another terminal:

```sh
POKEPORT_DEV=1 POKEPORT_GAME=gold love .
node mods/potato_voxel/tools/workbench/server.mjs
```

Open <http://127.0.0.1:8787>. The server listens only on `127.0.0.1`.

The default bridge directory is the normal macOS LOVE save directory:

```text
~/Library/Application Support/LOVE/pokemon-love2d/voxel-workbench
```

If this project uses a different LOVE identity or platform save directory,
read the bridge directory shown in the page after Gold starts and pass it to
the server explicitly:

```sh
node mods/potato_voxel/tools/workbench/server.mjs \
  --bridge-dir "/exact/path/shown/by-the-game"
```

## What gets written

Edits go only to `data/workbench_overrides.json`, keyed by tileset and graphic
tile id. That overlay takes precedence over `data/voxel_heights.lua` after a
hot reload. Selecting `auto` removes a local pin and returns to the shipped
profile/normal tile heuristics. This never changes Gold's collision, map
events, saves, or ROM-derived data.

The building brush does not invent new map art. Select the existing Gold roof
or façade artwork on the live map, add those cells to the build set, choose a
matching brush, and apply it. The browser preview is deliberately schematic;
the hot-reloaded Gold scene is the authoritative textured/meshed result.

The game and server exchange `command.json` and `status.json` in the bridge
directory. The browser never needs an exposed game port, and no process
accepts connections from the LAN.
