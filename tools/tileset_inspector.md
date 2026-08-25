# Tileset inspector

`inspect_tilesets.lua` exposes the identifiers the voxelizer actually uses:
tileset IDs, 8×8 tile IDs, 4×4 block layouts, and 2×2 collision quads.

Run it from the mod root with LuaJIT:

```sh
luajit tools/inspect_tilesets.lua --list
luajit tools/inspect_tilesets.lua --tileset TILESET_JOHTO --block 0x5b
luajit tools/inspect_tilesets.lua --tileset TILESET_JOHTO --cut
luajit tools/inspect_tilesets.lua --tileset TILESET_JOHTO --tile 19
luajit tools/inspect_tilesets.lua --tileset TILESET_JOHTO \
  --html /tmp/johto-tileset.html
```

The HTML report labels every atlas tile and makes every block expandable.
Use `--data PATH` when the generated data is not in the default Crystal
location or `POKEPORT_DATA_DIR`.

When describing a replacement, include the tileset identifier, block ID,
tile IDs, and—when relevant—the collision identifier. For example:

```text
TILESET_JOHTO, block 0x5B, CUT collision 0x12,
graphic tiles 19/21 over 69/29 at local block position (2,0)
```
