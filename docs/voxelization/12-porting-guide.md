# 12 — Porting Guide: Rebuilding the Pipeline in Another Engine

Target readership: someone reimplementing PotatoVoxel-style voxelization
in a different engine (another LÖVE fork, Godot, Unity, a custom
renderer). The Lua code is portable — the mod has no build step, no
native code, and (post-sandbox) no ffi — but it's written against the
Gen1Recomp engine's data model and LÖVE 11 API.

## What to take verbatim

The geometry algorithms are engine-agnostic:

- **`lib/Structures.lua`** — detection, segmentation, per-pixel
  voxelization. Depends only on: a `map` object exposing
  `tileAt(tx,ty)`, `cellTile`, `isWalkableCell/WaterCell/GrassCell`,
  `def.width/height`, `tileset` record, `id`; and an `ImageData`-like
  pixel accessor. It already degrades headless (no pixels → regions stay
  volumes).
- **`lib/TileShape.lua`** — the resolution ladder. Same map/tileset
  surface.
- **`lib/Buildings.lua`** — the band pipeline. Depends on `S` (the
  Structures record) and the atlas pixels.
- **`lib/ChunkMesher.lua` geometry core** (`runGeometry` + sinks) — the
  vertex emission. Keep it GPU-free; plug in your own mesh upload.
- **`data/voxel_heights.lua`** — the entire profile (class pins,
  heights, conditional rules, figures, mounted masks, building
  templates). This is ~4,500 lines of hand-tuned content that took
  thousands of hours to author; porting without it loses the whole
  curated world (ledges, furniture, trees, buildings).
- **`lib/Mat4.lua`**, **`lib/BuildBudget.lua`** — small, self-contained.

## The data model contract to reproduce

```lua
-- your engine must provide, per map:
map.id                       -- string, unique, stable
map.def.width * 4            -- map width in tiles (height likewise)
map:tileAt(tx, ty)           -- tile id; border-EXTENDS off the map
map:cellTile(cx, cy)         -- bottom-left tile of a cell
map:isWalkableCell(cx, cy)   -- cell-level collision
map:isWaterCell(cx, cy)
map:isGrassCell(cx, cy)
map.tileset.id               -- "OVERWORLD", "HOUSE", ...
map.tileset.image            -- atlas path
map.tileset.tilesPerRow      -- 16
map.tileset.imageWidth/Height -- 128x48
map.tileset.blocks           -- for border ring resolution
map.tileset.grassTile        -- tall-grass tile id
map.tileset.animatedTiles    -- frame/hshift animation specs
map.tileset.doorTiles        -- door tiles (facade fold)
map.waterTiles / map.walkable  -- tile-level fallback sets
TileRenderer.borderBlockFor(map) -- what the ring is made of (trees)
Assets.imageData(path)       -- atlas pixels
```

The tile/block model itself is Gen 1: 8x8 tiles, 16x16 blocks/cells,
tileset atlases of 8x8 tiles. **A port to a different tileset engine
(e.g. Pokémon Emerald's 8x8 tiles on 16x16 metatiles) needs the map
adapters, not the algorithms.**

## Porting steps

1. **Adapters** — write the map/tileset/atlas shim above. Keep the
   `GridKey.of` coordinate contract in one shared module; widen that module
   before porting maps beyond the supported ±64-tile range.
2. **TileShape** — point `V.data` at your profile loader; keep the
   fallback heights table as the no-profile floor.
3. **Structures** — run `forMap` per map; cache by map id. The
   `Budget` calls can be no-ops initially (or kept, they're cheap
   clock checks).
4. **ChunkMesher geometry** — emit `runGeometry` output into your
   engine's vertex/index buffers. The table sink already produces
   flat 6-float rows + u32 indices for direct upload.
5. **Texturing** — you must be able to: sample atlas pixels for UVs,
   and bind the atlas (or a recolored copy) as the mesh texture. The
   INSET (0.02) matters; nearest filtering throughout.
6. **Rendering** — you need: a depth-tested 3D pass, a camera that
   orbits at a pitch with world-pixel framing, the per-vertex shade
   vertex attribute, and an atlas-sampling shader. The scene shader
   (Voxel3D.lua:72-322) ports almost line-for-line to GLSL/HLSL.
7. **Optional tiers** — shadows (two-layer orthographic map), water
   (mirror + depth readback), wireframe (fwidth), async builds
   (coroutines + frame budgets), disk cache (serialized vertex
   streams — the "DSM" format is documented in MeshCache).

## LÖVE-isms to translate

| LÖVE API | role | replacement target |
|---|---|---|
| `love.graphics.newMesh(format, verts, "triangles", "static")` | mesh upload | any static vertex/index buffer |
| `mesh:setVertexMap` | indexed draws | index buffer |
| `love.graphics.setCanvas({color, depthstencil=depth})` | depth+colour target | FBO/render target |
| `love.graphics.newCanvas(w,h,{format=..., readable=true})` | readable depth | depth texture (the mod avoids it for portability; you can use one) |
| `love.graphics.setDepthMode("lequal", true)` | depth test/write | `glDepthFunc/glDepthMask` |
| `love.image.newImageData` + `getPixel` | atlas pixels | `glGetTexImage` / preloaded data |
| `Image:replacePixels` | animated atlas slots | `glTexSubImage2D` |
| shader with `varying`/`attribute` (GLSL1 style) | scene shader | any shading language; the header comments map to modern GLSL easily |

Notes:

- The mod's vertex shader bypasses LOVE's transform and does its own
  projection with a clip-space Y flip (canvas Y-down). In a normal
  engine, use your standard MVP — the flip is LÖVE-specific.
- Matrices are row-major; LÖVE defaults to column-major uniform upload
  (`send(..., "row")`). In most engines this is the default convention.
- The `pull` (camera-ward depth bias) and world curve live in the vertex
  shader — port them or drop them; nothing else depends on them.

## Behaviours to preserve (or deliberately drop)

1. **Collision is untouched.** The 3D layer is purely presentational —
   never let geometry write into the collision system. A port that
   builds collision FROM the voxels changes the game.
2. **Degrade, don't error.** Every GPU object guarded; a driver without
   a capability falls back (flat path, decal shadows, no wireframe).
3. **One unit per voxel.** If your engine's world units differ, scale
   the whole scene, not individual meshes — the wireframe shader (if
   ported) and the baked AO depend on the consistent lattice.
4. **The atlas is the texture.** Do not render the map to a texture;
   sample the tileset. It's 200x cheaper and palette-bake friendly.
5. **Asynchronous builds with visible-when-ready.** The 2D world is the
   fallback while meshes cook; never block a frame on meshing.

## The Brick economics (why the fork looks the way it does)

The shipped build targets a ~1 GB handheld (PowerVR GE8300). The
decisions that keep it there:

- RENDER SCALE 33-75 % (fill rate).
- Billboard hulls instead of carved trees (geometry count ÷ 80).
- Border ring as flat cards; eviction to two neighbourhoods.
- Indexed meshes, quantized cache payloads, sliced uploads.
- Everything expensive defaults off; the quality ladder is presets over
  one shared 35° camera.

A desktop port can re-enable the full carve (`HULL_BILLBOARDS = false`),
the full shadow ladder, and 100 % render scale — the code is all still
there behind the BrickProfile switches.
