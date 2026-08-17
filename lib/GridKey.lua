-- Packed map-cell keys shared by structure, building, and mesh caches.
-- The supported Gen 1 coordinate window is [-64, 63] on each axis; keeping
-- this contract in one module prevents the three geometry paths drifting.
local GridKey = {}

local OFFSET = 64
local WIDTH = 4096

function GridKey.of(tx, ty)
  return (ty + OFFSET) * WIDTH + (tx + OFFSET)
end

return GridKey
