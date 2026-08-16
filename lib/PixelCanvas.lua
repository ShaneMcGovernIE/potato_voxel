local V = ...

local PixelCanvas = {}

function PixelCanvas.new(w, h)
  local ok, canvas = pcall(love.graphics.newCanvas, w, h,
                           { dpiscale = 1 })
  if ok then return canvas ~= nil, canvas, canvas and nil or "newCanvas returned nil" end
  return false, nil, tostring(canvas)
end

return PixelCanvas
