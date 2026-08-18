-- Voxel world mode: the shared sun-pass drawing sequences.
--
-- The overworld and the battle arena both fill the shadow map's WORLD layer
-- with the same terrain/water/flowers run. Keeping one copy here is the
-- whole of it: the two scenes had already drifted (the overworld drew the
-- Stadium models inside the sprite flag that the battle kept them outside,
-- and water receives the arena's models but declined the overworld's), and
-- any future caster added to the world layer belongs in exactly one place.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Mat4 = V.require("Mat4")

local ShadowCast = {}

-- The terrain/water/flowers half of the WORLD layer, byte-identical in both
-- scenes: terrain and neighbour bodies, the water surfaces the sun has to
-- see through to the lake beds, then the flower cards snugged toward the
-- sun (thin casters keep contact with their feet). `scene` provides:
--   map          : the host map (flowers/textures resolve from it)
--   atlasFor(map): texture for a map's mesh
--   terrain, ring, water, ringWater: host body/delta meshes
--   neighbors    : { map, ox, oy } list
--   nbMesh, nbWater: per-neighbour meshes
function ShadowCast.terrainAndWater(ShadowMap, ChunkMesher, scene)
  local atlasFor = scene.atlasFor
  ShadowMap.draw(scene.terrain, atlasFor(scene.map), nil)
  ShadowMap.draw(scene.ring, atlasFor(scene.map), nil)
  for i, nb in ipairs(scene.neighbors or {}) do
    ShadowMap.draw(scene.nbMesh and scene.nbMesh[i], atlasFor(nb.map),
                   Mat4.translate(nb.ox, 0, nb.oy))
  end
  ShadowMap.draw(scene.water, atlasFor(scene.map), nil)
  ShadowMap.draw(scene.ringWater, atlasFor(scene.map), nil)
  for i, nb in ipairs(scene.neighbors or {}) do
    ShadowMap.draw(scene.nbWater and scene.nbWater[i], atlasFor(nb.map),
                   Mat4.translate(nb.ox, 0, nb.oy))
  end
  ShadowMap.draw(ChunkMesher.flowers(scene.map), atlasFor(scene.map),
                 ShadowMap.snug(nil))
  for _, nb in ipairs(scene.neighbors or {}) do
    ShadowMap.draw(ChunkMesher.flowers(nb.map), atlasFor(nb.map),
                   ShadowMap.snug(Mat4.translate(nb.ox, 0, nb.oy)))
  end
end

return ShadowCast
