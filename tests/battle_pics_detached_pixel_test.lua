local function check(condition, message)
  if not condition then error(message, 2) end
end

local BattlePics = assert(loadfile("lib/BattlePics.lua"))({})

local pixels = {
  [0] = { [0] = { 0, 0, 0, 1 }, [1] = { 0, 0, 0, 1 } },
  [1] = { [0] = { 0, 0, 0, 1 } },
  [3] = { [5] = { 0, 0, 0, 1 } },
}
local data = {
  getPixel = function(_, x, y)
    local p = pixels[y] and pixels[y][x]
    if p then return p[1], p[2], p[3], p[4] end
    return 0, 0, 0, 0
  end,
  setPixel = function(_, x, y, r, g, b, a)
    pixels[y] = pixels[y] or {}
    pixels[y][x] = { r, g, b, a }
  end,
}

check(BattlePics.removeDetachedPixels(data, 6, 4) == 1,
      "one disconnected opaque sprite pixel is removed")
check(select(4, data:getPixel(5, 3)) == 0,
      "the removed detached pixel is transparent")
check(select(4, data:getPixel(0, 0)) == 1,
      "the sprite's connected body is retained")

print("battle_pics_detached_pixel_test: ok")
