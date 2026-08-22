-- Voxel world mode: the class-map debug view -- the authoring tool the
-- shape profile begs for.
--
-- F6 toggles a tinted map of the CURRENT overworld: every 8x8 tile is
-- one pixel in the colour of the shape class it resolved to, volume runs
-- are pulled toward white, and cells a specialist builder claimed
-- (S.skip -- buildings, props, hulls, stairs) toward magenta. When a
-- tile renders wrong in the diorama, this answers the first question a
-- profile author has: what did the detector think it was. Resolution,
-- classification and the whole walkability ladder run exactly as the
-- diorama sees them -- the image is built from the same Structures
-- record the mesher reads.
--
-- Debug-only, like F9/F10/F8: nothing persists, nothing reaches a saved
-- game, and an unloaded view costs one boolean test a frame.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...
local GridKey = V.require("GridKey")

local ShapeDebug = {}

ShapeDebug.visible = false

-- one class -> one colour, chosen so neighbours read apart at a glance.
-- Ground/water read blue/green like the world they are; the standee and
-- hull pools get their own warm colours; furniture its own band.
local CLASS_COLORS = {
  ground = { 0.36, 0.68, 0.36 },
  water = { 0.25, 0.50, 0.95 },
  void = { 0.05, 0.05, 0.07 },
  ledge = { 0.95, 0.85, 0.40 },
  roof = { 0.85, 0.45, 0.35 },
  wall = { 0.80, 0.30, 0.30 },
  cliff = { 0.55, 0.25, 0.20 },
  tree = { 0.35, 0.55, 0.30 },
  fence = { 0.55, 0.50, 0.25 },
  sign = { 0.95, 0.70, 0.30 },
  cylinder = { 0.25, 0.60, 0.35 },
  canopy = { 0.20, 0.55, 0.30 },
  stump = { 0.55, 0.40, 0.25 },
  can = { 0.60, 0.60, 0.65 },
  planter = { 0.30, 0.65, 0.40 },
  billboard = { 0.95, 0.55, 0.20 },
  signpost = { 0.90, 0.65, 0.15 },
  post = { 0.70, 0.60, 0.20 },
  grass = { 0.30, 0.75, 0.45 },
  flower = { 0.95, 0.40, 0.75 },
  bed = { 0.90, 0.55, 0.55 },
  stool = { 0.85, 0.75, 0.55 },
  counter = { 0.95, 0.60, 0.45 },
  backrest = { 0.85, 0.55, 0.50 },
  table = { 0.95, 0.55, 0.40 },
  desk = { 0.80, 0.45, 0.40 },
  prop = { 0.90, 0.60, 0.30 },
  cutout = { 0.95, 0.45, 0.35 },
  bike = { 0.60, 0.80, 0.90 },
  console = { 0.70, 0.55, 0.85 },
  relief = { 0.55, 0.70, 0.90 },
  bookcase = { 0.65, 0.45, 0.60 },
  stair_e = { 0.85, 0.80, 0.45 },
  stair_w = { 0.85, 0.80, 0.45 },
  stair_down_e = { 0.65, 0.60, 0.35 },
  stair_down_w = { 0.65, 0.60, 0.35 },
  building = { 0.95, 0.85, 0.60 },
}

local DEFAULT = { 0.5, 0.5, 0.5 }

-- The class colour for a shape, or nil for no shape.
function ShapeDebug.colorFor(s)
  if not s then return nil end
  return CLASS_COLORS[s.class]
end

-- The pixel a tile draws, as {r, g, b} in 0..1: the class colour, then
-- the two overlays -- a volume run toward white (the detector is
-- extruding it), a claimed cell toward magenta (a specialist builder
-- took it and the mesher paints ground under it).
function ShapeDebug.pixelFor(S, k)
  local s = S.shapeAt and S.shapeAt[k]
  local c = CLASS_COLORS[s and s.class] or DEFAULT
  local r, g, b = c[1], c[2], c[3]
  if S.runs and S.runs[k] then
    r = r + (1 - r) * 0.30
    g = g + (1 - g) * 0.30
    b = b + (1 - b) * 0.30
  end
  if S.skip and S.skip[k] then
    r = r + (1 - r) * 0.45
    g = g + (0.25 - g) * 0.45
    b = b + (1 - b) * 0.45
  end
  return { r, g, b }
end

-- map id -> { image, w, h } or false. Built lazily on first draw of the
-- map; dropped on the same events that stale the mesh cache, because the
-- analysis behind it goes stale on exactly those.
local cache = {}

local function build(map)
  if not (love and love.image and love.image.newImageData
          and love.graphics and love.graphics.newImage) then
    return false
  end
  local Structures = V.require("Structures")
  local S = Structures.forMap(map)
  local def = map.def
  local tw, th = def.width * 4, def.height * 4
  local ok, img = pcall(function()
    local data = love.image.newImageData(tw, th)
    for ty = 0, th - 1 do
      for tx = 0, tw - 1 do
        local c = ShapeDebug.pixelFor(S, GridKey.of(tx, ty))
        data:setPixel(tx, ty, c[1], c[2], c[3], 1)
      end
    end
    local image = love.graphics.newImage(data)
    image:setFilter("nearest", "nearest")
    return image
  end)
  if not (ok and img) then return false end
  return { image = img, w = tw, h = th }
end

-- Draw the view in the window's top-right, alongside the text panel's
-- top-left. Scale keeps the map readable at any window size (never under
-- one screen pixel per tile).
function ShapeDebug.draw(game)
  if not ShapeDebug.visible then return end
  local lg = love and love.graphics
  if not (lg and lg.getDimensions) then return end
  local ow = game and game.overworld
  local map = ow and ow.map
  if not (map and map.def and map.tileset and map.id) then return end

  local entry = cache[map.id]
  if entry == nil then
    entry = build(map)
    cache[map.id] = entry
  end
  if not entry then return end

  local ok, w, h = pcall(lg.getDimensions)
  if not (ok and w and h and w > 0 and h > 0) then return end
  local scale = math.max(1, math.min(math.floor(h * 0.4 / entry.h),
                                     math.floor((w - 540) / entry.w)))
  local x = w - entry.w * scale - 4
  local y = 4

  local prevColor = { lg.getColor() }
  local okSc, sx, sy, sw, sh = pcall(lg.getScissor)
  local prevScissor = okSc and sx and { sx, sy, sw, sh } or nil
  local okBl, prevBlend, prevBlendAlpha = pcall(lg.getBlendMode)
  pcall(lg.setScissor)
  pcall(lg.setBlendMode, "alpha", "alphamultiply")
  lg.setColor(0, 0, 0, 0.62)
  lg.rectangle("fill", x - 2, y - 2, entry.w * scale + 4, entry.h * scale + 4)
  lg.setColor(1, 1, 1, 1)
  lg.draw(entry.image, x, y, 0, scale, scale)

  local p = ow.player
  if p and p.px and p.py then
    local tx, ty = math.floor(p.px / 8), math.floor(p.py / 8)
    lg.setLineWidth(1)
    lg.setColor(1, 1, 1, 0.9)
    lg.rectangle("line", x + tx * scale, y + ty * scale,
                 2 * scale, 2 * scale)
  end
  lg.setColor(prevColor[1], prevColor[2], prevColor[3], prevColor[4])
  pcall(lg.setScissor, prevScissor)
  pcall(lg.setBlendMode, prevBlend, prevBlendAlpha)
end

function ShapeDebug.toggle()
  ShapeDebug.visible = not ShapeDebug.visible
end

function ShapeDebug.install()
  if ShapeDebug.installed then return end
  ShapeDebug.installed = true
  local mod = V.mod
  if not (mod and mod.hooks) then return end
  mod.hooks:wrap("render.hud", function(next, game, viewport)
    next(game, viewport)
    ShapeDebug.draw(game)
  end)
  -- the analysis behind the image is the same one the meshes are derived
  -- from, so the same events drop the cache
  mod.events:on("world.block_replaced", function() cache = {} end)
  mod.events:on("map.reloaded", function() cache = {} end)
end

return ShapeDebug
