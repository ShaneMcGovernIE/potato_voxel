-- A map CONNECTION is not a wall: the seam must not shade itself.
--
-- The corner AO probe in GeometryBuilder reads the cells crowding a top
-- face out of Structures' analysis, and that analysis covers the RING as
-- well as the body -- ring cells carrying the map's border block, which
-- outdoors is the solid tree wall. So one tile past the body edge always
-- reads as a raised neighbour: every edge tile counts two crowders on its
-- outer corners and comes out at 1 - 2*AO_STEP.
--
-- Where the map ENDS that is right. Where it CONNECTS it is not. The ring
-- there is not drawn at all -- GeometryBuilder.emit's `masks` suppress it
-- under the neighbour's body, and a body-only build (which is how every
-- neighbour is meshed) never emits a ring -- and the neighbour's own
-- ground runs flush with the seam. Shading against a wall nobody can see
-- lays a dark line down every connection, and both sides do it, each
-- against its own ring, so it comes out symmetric: a tile of linear
-- falloff either side of the seam bottoming out at 1 - 2*AO_STEP, which is
-- 0.568.
--
-- On land the tile art mostly swallows it. On the one surface in the game
-- with no art to hide behind -- open water spanning a connection -- it
-- reads as a shadow floating on the sea.
--
--   luajit tests/voxel_seam_ao_test.lua      (from the game root)

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Data = require("src.core.Data")
Data:load()

local run = T.sdk.loadMod("mods/potato_voxel", { data = Data })
T.eq(#run.errors, 0, "potato_voxel loads clean: "
                     .. table.concat(run.errors, "; "))

local lib = run.loader.exports.potato_voxel.lib
local ChunkMesher = lib.require("ChunkMesher")
local Structures = lib.require("Structures")
local Shapes = lib.require("TileShape")

-- Open sea, two blocks square, connected EASTWARD and walled on the other
-- three sides -- so one fixture states both halves of the invariant. No
-- atlas, no GPU and no fixture map: geometry() is pure arithmetic.
local SEA_TILE = 20
local seaMap = {
  id = "SEAM_AO_TEST",
  tileset = { id = "SEAM_AO_SET", image = "gfx/tilesets/seam_ao.png",
              tilesPerRow = 16, imageWidth = 128, imageHeight = 48,
              blocks = {}, grassTile = -1 },
  def = { width = 2, height = 2, tileset = "SEAM_AO_SET",
          connections = { east = { map = "SEAM_AO_TEST_EAST", offset = 0 } } },
  walkable = {},
  waterTiles = { [SEA_TILE] = true },
  doorTiles = {},
  tileAt = function() return SEA_TILE end,
  cellTile = function() return SEA_TILE end,
  isWaterCell = function() return true end,
  isWalkableCell = function() return false end,
  inBounds = function(_, cx, cy)
    return cx >= 0 and cy >= 0 and cx < 4 and cy < 4
  end,
}

Structures.invalidate(seaMap.id)
local _, _, _, seaVerts = ChunkMesher.geometry(seaMap, true, nil, true)

-- The body is 8 tiles square, so its west face stands at x=0 and its east
-- face at x=64. The corners at z=0 and z=64 are the map's own north and
-- south edges, ringed for real, and are left out: what is under test is
-- the seam, not the corners it runs between.
local EAST, WEST, SPAN = 64, 0, 64
local eastLit, eastDark, westDark, worst = 0, 0, 0, 1
for _, v in ipairs(seaVerts) do
  local x, z, shade = v[1], v[3], v[6]
  if z > 0 and z < SPAN then
    if x == EAST then
      if shade < 1 then
        eastDark = eastDark + 1
        worst = math.min(worst, shade)
      else
        eastLit = eastLit + 1
      end
    elseif x == WEST and shade < 1 then
      westDark = westDark + 1
      worst = math.min(worst, shade)
    end
  end
end

T.check(eastLit > 0, "the connected edge carries water corners at all")
T.eq(eastDark, 0,
  "no water corner on a CONNECTED edge is occlusion-shaded: the border "
  .. "ring it would shade against is suppressed under the neighbour's "
  .. "body, and the neighbour's own water runs flush to the seam")
T.check(westDark > 0,
  "while the WALLED edge still is -- the fix is the connection, not a "
  .. "blanket amnesty for every cell that happens to sit on a map edge")
T.check(worst > 0.56 and worst < 0.58,
  "and the shade a real wall lays is the two-crowder step, 1 - 2*AO_STEP "
  .. "= 0.568 -- the value measured off the seam band this fixes")

Structures.invalidate(seaMap.id)
ChunkMesher.invalidate(seaMap.id)
Shapes.invalidate()

run.release()
T.finish("potato_voxel")
