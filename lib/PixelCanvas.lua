local V = ...

local PixelCanvas = {}

-- `format` is optional because most scene canvases should keep the engine's
-- normal color format. Packed numeric render targets (shadow depth, for
-- example) must opt into a non-sRGB format so gamma conversion cannot change
-- the values written by a shader and later sampled as data.
function PixelCanvas.new(w, h, format)
  local settings = { dpiscale = 1 }
  if format then settings.format = format end
  local ok, canvas = pcall(love.graphics.newCanvas, w, h,
                           settings)
  if ok then return canvas ~= nil, canvas, canvas and nil or "newCanvas returned nil" end
  return false, nil, tostring(canvas)
end

return PixelCanvas
