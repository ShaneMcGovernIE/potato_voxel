-- Gen 2 tileset atlas with per-tile palettes baked in for voxel meshing.
local V = ...

local Assets = require("src.render.Assets")
local GbcPalette = require("src.render.GbcPalette")
local Palettes = require("src.world.gen2.Palettes")

local GoldAtlas = {}
local cache = {}

local function sourcePixels(atlas, tileset)
  local path = tileset and tileset.image
  if path then
    local ok, data = pcall(Assets.imageData, path)
    if ok and data then return data end
  end
  if not (atlas and love.graphics and love.graphics.newCanvas) then return nil end
  local ok, data = pcall(function()
    local w, h = atlas:getDimensions()
    local previous = love.graphics.getCanvas()
    local canvas = love.graphics.newCanvas(w, h, { dpiscale = 1 })
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    love.graphics.setBlendMode("replace", "premultiplied")
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(atlas, 0, 0)
    love.graphics.setCanvas(previous)
    love.graphics.setBlendMode("alpha", "alphamultiply")
    local out = canvas:newImageData()
    canvas:release()
    return out
  end)
  return ok and data or nil
end

local function shadeOf(red)
  return math.max(1, math.min(4, math.floor((1 - (red or 0)) * 3 + 0.5) + 1))
end

local function paletteSlot(tilePalettes, tile)
  local slot = tonumber(tilePalettes and tilePalettes[tile + 1]) or 1
  if slot >= 1 and slot <= 8 then return slot end
  if slot >= 0 and slot <= 7 then return slot + 1 end
  return 1
end

local function keyFor(world, map)
  local hour = type(world.hour) == "function" and world:hour() or world.clockHour
  local daytime = Palettes.daytimeFor(map.def, hour, world.flashUsed)
  return table.concat({ tostring(map.id), tostring(daytime),
    tostring(GbcPalette.mode), tostring(map.tileset.image) }, "#"), daytime
end

function GoldAtlas.forMap(world, map, rawAtlas)
  if not (world and map and map.tileset and rawAtlas
      and love.image and love.image.newImageData and love.graphics) then
    return rawAtlas, false
  end
  local key, daytime = keyFor(world, map)
  if cache[key] ~= nil then return cache[key] or rawAtlas, cache[key] ~= false end

  local data = world.game and world.game.data and world.game.data.gen2Palettes
  local palettes = data and Palettes.bgSet(data, map.def, daytime)
  local source = palettes and sourcePixels(rawAtlas, map.tileset)
  if not source then cache[key] = false; return rawAtlas, false end

  local ok, image = pcall(function()
    local w, h = source:getDimensions()
    local out = love.image.newImageData(w, h)
    local perRow = math.max(1, math.floor(w / 8))
    local resolved = {}
    for y = 0, h - 1 do
      local tileY = math.floor(y / 8)
      for x = 0, w - 1 do
        local tile = tileY * perRow + math.floor(x / 8)
        local slot = paletteSlot(map.tileset.tilePalettes, tile)
        local colors = resolved[slot]
        if colors == nil then
          colors = GbcPalette.resolve(palettes[slot] or palettes[1]) or false
          resolved[slot] = colors
        end
        local r, g, b, a = source:getPixel(x, y)
        local color = colors and colors[shadeOf(r)]
        if color and a > 0 then
          r, g, b = color[1] / 255, color[2] / 255, color[3] / 255
        end
        out:setPixel(x, y, r, g, b, a)
      end
    end
    local atlas = love.graphics.newImage(out)
    atlas:setFilter("nearest", "nearest")
    return atlas
  end)
  cache[key] = ok and image or false
  return cache[key] or rawAtlas, cache[key] ~= false
end

function GoldAtlas.invalidate()
  for _, image in pairs(cache) do
    if image and image ~= false and image.release then pcall(image.release, image) end
  end
  cache = {}
end

if Assets.register then Assets.register(GoldAtlas.invalidate) end

return GoldAtlas
