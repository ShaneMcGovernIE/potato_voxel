-- Voxel world mode: characters as flat forward-facing sprite billboards.
--
-- Every character -- the player, NPCs, the ghosts standing on a neighbour
-- map -- is its CURRENT 2D sprite frame on a single flat quad. The sheets
-- carry real alpha and the shader discards it, so the quad cuts the
-- sprite's exact silhouette out of itself; no geometry is built from the
-- pixels and nothing about a sprite is voxelized.
--
-- That is deliberate. A sprite is a DRAWING, not an object seen from one
-- side: Gen 1's overworld figures are 16x16 icons with a fixed front-on
-- reading, and turning one into a solid -- whether a contoured slab or a
-- carved visual hull -- reconstructs a body the artist never drew and the
-- game never implied. It also had the mod ship a description of the ROM
-- art. One quad wearing the real frame is both more faithful and cheaper:
-- it needs no pixel access at all, only the sheet's dimensions.
--
-- Vanilla figures all read that dimension as a fixed 16, but a mod's
-- registered sprite (furniture, decor placed as an overworld entity) can
-- carry its own frameWidth/frameHeight the 2D path already honours -- see
-- buildCard below. The card stays a flat drawing either way; only its
-- size changes.
--
-- The card always faces SOUTH -- the direction the 2D game implies -- and
-- only LEANS BACK, pivoting at its feet, by exactly the camera's pitch
-- (VoxelScene's billboardMatrix), so at every tilt level it reads face-on
-- like the flat game. Right-facing and the alternating walk step are
-- matrix mirrors, not extra meshes. UVs point into the live sheet image,
-- so RED++ OBP bakes, SGB palette bakes and sprite-replacing mods all
-- texture it with no rebuild.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Assets = require("src.render.Assets")
local Voxel3D = V.require("Voxel3D")

local SpriteBillboards = {}

local meshes = {}

-- One flat quad -- 16x16 for every vanilla figure, or the def's own
-- frameWidth x frameHeight for a mod sprite registered bigger than that --
-- UV-mapped to a whole frame. A hair of inset keeps the sampler inside
-- this frame rather than picking up the neighbouring one along the shared
-- edge.
--
-- billboardMatrix and Voxel3D.casterMatrix both pivot the finished card at
-- its feet by translating to the entity's tile centre and then shifting
-- -8 (half of the vanilla 16px width) so the card ends up centred over the
-- tile. That shift is fixed and shared by every entity, so a wider card
-- bakes its OWN half-width in here (x0 = 8 - fw / 2) rather than asking
-- the shared matrices to know each sprite's size -- for fw == 16 that is
-- x0 = 0, the original quad, unchanged.
local function buildCard(def, frame)
  local ok, img = pcall(Assets.image, def.image)
  if not (ok and img) then return nil end
  local iw, ih = img:getDimensions()
  local fw = def.frameWidth or 16
  local fh = def.frameHeight or 16
  local fy = frame * fh
  if fy + fh > ih then fy = 0 end
  local u0, u1 = 0.02 / iw, (fw - 0.02) / iw
  local v0, v1 = (fy + 0.05) / ih, (fy + fh - 0.05) / ih
  local x0, x1 = 8 - fw / 2, 8 + fw / 2
  local verts = {
    { x0, 0, 0, u0, v1, 1 }, { x1, 0, 0, u1, v1, 1 },
    { x1, fh, 0, u1, v0, 1 }, { x0, fh, 0, u0, v0, 1 },
  }
  local indices = {}
  Voxel3D.pushQuad(indices, 0)
  return Voxel3D.newMesh(verts, indices)
end

-- The card for one (sprite def, frame index), or nil (headless / no
-- image), cached like every other derived GPU object.
--
-- The solid draw, the sun pass and the player's occlusion silhouette all
-- take THIS mesh. That the three agree is load-bearing, not tidiness: the
-- silhouette is drawn with the depth test INVERTED, so any self-overlap in
-- the mesh would read as "behind something" and repaint the figure on open
-- ground whether or not anything hides it; and the sun must see the same
-- outline the camera does, or a shadow stops matching what casts it.
function SpriteBillboards.mesh(def, frame)
  -- Size is part of the key too: two defs can point at the same sheet
  -- with different frameWidth/frameHeight (a mod's derived variant of a
  -- shared asset), and previously that could only alias because every
  -- card was implicitly 16x16.
  local key = def.image .. "#" .. frame .. "#"
              .. (def.frameWidth or 16) .. "x" .. (def.frameHeight or 16)
  if meshes[key] == nil then
    local ok, m = pcall(buildCard, def, frame)
    meshes[key] = (ok and m) or false
  end
  return meshes[key] or nil
end

-- Kept as its own name because the shadow and ghost passes read as their
-- own thing at the call sites; it once carried a different mesh from the
-- solid draw, and now deliberately does not.
SpriteBillboards.shadowQuad = SpriteBillboards.mesh

-- A low-end contact shadow deliberately does not reuse the animated sprite
-- silhouette.  The old alias made a walking frame (and its mirror) part of
-- the shadow geometry, so every leg step and camera-relative frame choice
-- changed the projected outline.  Keep this footprint fixed and let the
-- scene transform provide only placement.
local shadowBlob
local shadowBlobTexture

local function buildShadowBlob()
  local verts = {
    { 0, 0, 0, 0, 0, 1 },
    { -6, 0, -2, 0, 0, 1 }, { -3, 0, -3, 0, 0, 1 },
    {  3, 0, -3, 0, 0, 1 }, {  6, 0, -2, 0, 0, 1 },
    {  6, 0,  2, 0, 0, 1 }, {  3, 0,  3, 0, 0, 1 },
    { -3, 0,  3, 0, 0, 1 }, { -6, 0,  2, 0, 0, 1 },
  }
  local indices = {}
  for i = 1, 7 do
    indices[#indices + 1] = 0
    indices[#indices + 1] = i
    indices[#indices + 1] = i + 1
  end
  indices[#indices + 1] = 0
  indices[#indices + 1] = 8
  indices[#indices + 1] = 1
  return Voxel3D.newMesh(verts, indices)
end

function SpriteBillboards.shadowBlob()
  if shadowBlob == nil then
    local ok, mesh = pcall(buildShadowBlob)
    shadowBlob = (ok and mesh) or false
  end
  if shadowBlob == false then return nil end
  -- The scene shader samples an Image even for untextured geometry.  A single
  -- opaque texel keeps the blob solid without consulting a sprite sheet.
  if shadowBlobTexture == nil and love and love.graphics and love.image then
    local ok, tex = pcall(function()
      local data = love.image.newImageData(1, 1)
      data:setPixel(0, 0, 1, 1, 1, 1)
      return love.graphics.newImage(data)
    end)
    shadowBlobTexture = (ok and tex) or false
  end
  return shadowBlob, shadowBlobTexture ~= false and shadowBlobTexture or nil
end

function SpriteBillboards.invalidate()
  meshes = {}
  shadowBlob = nil
  shadowBlobTexture = nil
  meshes = {}
end

Assets.register(SpriteBillboards.invalidate)

return SpriteBillboards
