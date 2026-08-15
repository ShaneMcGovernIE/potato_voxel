-- Opaque first-build cover for the asynchronous voxel world.
-- Reuses Gen1Recomp's Town Map as a passive, ROM-backed illustration.

local V = ...
local Voxel = V.require("VoxelState")
local Loading = {}

local canvas, canvasW, canvasH = nil, 0, 0
local townMapView, townMapFont, townMapGame = nil, nil, nil
local townMapMapId, townMapFailed = nil, nil

local clock = (love and love.timer and love.timer.getTime) or os.clock

local function releaseObject(obj)
  if obj and obj.release then pcall(obj.release, obj) end
end

local function releaseTownMap()
  local bg = townMapView and townMapView.bg
  if bg then
    releaseObject(bg.img)
    releaseObject(bg.cursor)
    for _, quad in pairs(bg.quads or {}) do releaseObject(quad) end
  end
  releaseObject(townMapView and townMapView.nestIcon)
  townMapView, townMapFont, townMapGame = nil, nil, nil
  townMapMapId, townMapFailed = nil, nil
end

local function townMapForLoading()
  local mapId = Voxel.loadingMap
  if not mapId or townMapFailed == mapId then return nil end

  local okG, Game = pcall(require, "src.core.Game")
  if not (okG and Game and Game.data) then
    townMapFailed = mapId
    return nil
  end
  if not townMapView or townMapGame ~= Game then
    releaseTownMap()
    local okT, TownMap = pcall(require, "src.ui.TownMap")
    local okF, Font = pcall(require, "src.render.Font")
    local okV, view = false, nil
    if okT then okV, view = pcall(TownMap.new, Game) end
    if not (okV and view and view.mode == "grid" and view.bg
            and okF and Font) then
      townMapView = view
      releaseTownMap()
      townMapFailed = mapId
      return nil
    end
    townMapView, townMapFont, townMapGame = view, Font, Game
  end

  local loc = townMapView.byMap and townMapView.byMap[mapId]
  if not loc then
    townMapFailed = mapId
    return nil
  end
  townMapView.playerLoc = loc
  for i, candidate in ipairs(townMapView.locs or {}) do
    if candidate == loc then
      townMapView.sel = i
      break
    end
  end
  townMapMapId = mapId
  return townMapView, townMapFont
end

local function ensure(w, h)
  if canvas and canvasW == w and canvasH == h then return true end
  local ok, c = pcall(love.graphics.newCanvas, w, h)
  if not (ok and c) then return false end
  c:setFilter("nearest", "nearest")
  releaseObject(canvas)
  canvas, canvasW, canvasH = c, w, h
  return true
end

local function drawTownMap(g, w, h, pending, elapsed)
  local view, Font = townMapForLoading()
  if not (view and Font) then return false end

  local logicalW, logicalH = 160, 168
  local scale = math.max(1, math.floor(
    math.min((w - 8) / logicalW, (h - 8) / logicalH)))
  local x = math.floor((w - logicalW * scale) * 0.5)
  local y = math.floor((h - logicalH * scale) * 0.5)

  g.push()
  g.translate(x, y)
  g.scale(scale, scale)
  g.setLineWidth(1)
  view.blink = math.floor(elapsed * 60) % 32
  local ok = pcall(view.draw, view)
  if ok then
    Font.drawBox(0, 18, 20, 3)
    g.setColor(0, 0, 0, 1)
    local text = "BUILDING VOXELS"
    if pending and pending > 1 and math.floor(elapsed / 2) % 2 == 1 then
      text = tostring(pending) .. " AREAS LEFT"
    end
    Font.draw(text, math.floor((logicalW - Font.width(text)) * 0.5), 152)
  end
  g.pop()
  g.setColor(1, 1, 1, 1)

  if not ok then
    local failed = townMapMapId or Voxel.loadingMap
    releaseTownMap()
    townMapFailed = failed
    return false
  end
  return true
end

function Loading.draw(w, h, pending)
  if not (love.graphics and love.graphics.newCanvas) then return nil end
  if not ensure(w, h) then return nil end

  local g = love.graphics
  g.setCanvas(canvas)
  g.setShader()
  g.setBlendMode("alpha")
  g.origin()
  g.clear(0, 0, 0, 1)

  local elapsed = clock() - (Voxel.loadingSince or clock())
  if drawTownMap(g, w, h, pending, elapsed) then
    g.setColor(1, 1, 1, 1)
    g.setCanvas()
    return canvas
  end

  g.setColor(1, 1, 1, 1)
  local font = g.getFont()
  local text = "BUILDING VOXELS"
  g.print(text, math.floor((w - font:getWidth(text)) * 0.5),
          math.floor(h * 0.5))
  g.setCanvas()
  return canvas
end

function Loading.invalidate()
  releaseObject(canvas)
  releaseTownMap()
  canvas, canvasW, canvasH = nil, 0, 0
end

return Loading
