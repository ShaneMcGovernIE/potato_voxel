-- PotatoVoxel: native canvas fold for sub-native VOXEL rungs.
--
-- The scene may render below the window resolution to preserve the quality
-- ladder frame-budget behavior. The fold back to the display is an ordinary
-- canvas draw with linear texture filtering: no dedicated upscaling shader
-- or post-process pass is used in any mode.

local Upscale = {}

function Upscale.kind()
  return "none"
end

local targets = {}

local function targetFor(slot, w, h)
  local t = targets[slot]
  if not (t and t.w == w and t.h == h) then
    local ok, canvas = pcall(love.graphics.newCanvas, w, h)
    if not (ok and canvas) then return nil end
    if t and t.canvas and t.canvas.release then
      pcall(t.canvas.release, t.canvas)
    end
    t = { canvas = canvas, w = w, h = h }
    targets[slot] = t
  end
  return t.canvas
end

function Upscale.apply(canvas, w, h, slot)
  if not canvas then return canvas end
  local ok, cw, ch = pcall(canvas.getDimensions, canvas)
  if not ok or (cw == w and ch == h) or cw > w or ch > h then
    return canvas
  end
  local target = targetFor(slot or "world", w, h)
  if not target then return canvas end
  local prevBlend, prevAlpha = love.graphics.getBlendMode()
  pcall(canvas.setFilter, canvas, "linear", "linear")
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setBlendMode("replace", "premultiplied")
  local drew = pcall(function()
    love.graphics.setCanvas(target)
    love.graphics.clear(0, 0, 0, 0)
    love.graphics.draw(canvas, 0, 0, 0, w / math.max(1, cw), h / math.max(1, ch))
  end)
  love.graphics.setCanvas()
  love.graphics.setBlendMode(prevBlend or "alpha", prevAlpha)
  pcall(canvas.setFilter, canvas, "nearest", "nearest")
  return drew and target or canvas
end

function Upscale.invalidate()
  for slot, t in pairs(targets) do
    if t.canvas and t.canvas.release then pcall(t.canvas.release, t.canvas) end
    targets[slot] = nil
  end
end

return Upscale
