-- Profile-pinned stair geometry.
--
-- This specialist owns only stair detection output: it emits the step,
-- riser, tread, and stairwell faces and claims the covered cells. Structures
-- keeps the public buildStairs façade and supplies the atlas pixels.
local V = ...

local Budget = V.require("BuildBudget")
local GridKey = V.require("GridKey")

local StairBuilder = {}
local STAIR_STEPS = 4
local STAIR_SHADE = { south = 1.0, north = 0.68, tread = 1.0,
                      riser = 0.82, cap = 0.78,
                      wellN = 0.9, wellS = 0.55, wellEnd = 0.15,
                      wellTread = 0.8 }

local function stairCell(S, map, cx, cy, s)
  local perRow = map.tileset.tilesPerRow or 16
  local atlasW = map.tileset.imageWidth or 128
  local atlasH = map.tileset.imageHeight or 48
  local quads = S.objectQuads
  local down = s.class == "stair_down_e" or s.class == "stair_down_w"
  local east = s.class == "stair_e" or s.class == "stair_down_e"
  local mx, mz = cx * 16, cy * 16
  local h = s.h or 16
  local rise = h / STAIR_STEPS
  local runW = 16 / STAIR_STEPS
  local z0, z1 = mz, mz + 16

  local function uv(px, py)
    px = math.max(0.05, math.min(15.95, px))
    py = math.max(0.05, math.min(15.95, py))
    local tile = S.tileAt[GridKey.of(cx * 2 + (px >= 8 and 1 or 0),
                                     cy * 2 + (py >= 8 and 1 or 0))]
    return ((tile % perRow) * 8 + px % 8) / atlasW,
           (math.floor(tile / perRow) * 8 + py % 8) / atlasH
  end

  local function face(c1, c2, c3, c4, ax0, ay0, ax1, ay1, shade)
    local u0, v0 = uv(ax0, ay0)
    local u1, v1 = uv(ax1, ay1)
    quads[#quads + 1] = { c1, c2, c3, c4,
      uv = { { u0, v1 }, { u1, v1 }, { u1, v0 }, { u0, v0 } },
      shade = shade }
  end

  local function banded(z, ax0, ax1, fy0, fy1, ay0, ay1, shade, flip)
    local scale = (fy1 - fy0) / math.max(ay1 - ay0, 0.001)
    for _, band in ipairs({ { ay0, math.min(8, ay1) },
                            { math.max(ay0, 8), ay1 } }) do
      local a0, a1 = band[1], band[2]
      if a1 > a0 then
        local by1 = fy1 - (a0 - ay0) * scale
        local by0 = fy1 - (a1 - ay0) * scale
        local xa, xb = mx + ax0, mx + ax1
        if flip then
          face({ xb, by0, z }, { xa, by0, z }, { xa, by1, z },
               { xb, by1, z }, ax0, a0, ax1, a1, shade)
        else
          face({ xa, by0, z }, { xb, by0, z }, { xb, by1, z },
               { xa, by1, z }, ax0, a0, ax1, a1, shade)
        end
      end
    end
  end

  for i = 0, STAIR_STEPS - 1 do
    local sx0 = east and (i * runW) or (16 - (i + 1) * runW)
    local sx1 = sx0 + runW
    local x0, x1 = mx + sx0, mx + sx1

    if down then
      local yTop = -(i + 1) * rise
      local dep = (i + 1) * rise
      face({ x0, yTop, z0 }, { x1, yTop, z0 },
           { x1, yTop, z1 }, { x0, yTop, z1 },
           sx0, dep - 1.4, sx1, dep, STAIR_SHADE.wellTread)
      banded(z0, sx0, sx1, yTop, 0, 0, dep, STAIR_SHADE.wellN)
      banded(z1, sx0, sx1, yTop, 0, 0, dep, STAIR_SHADE.wellS, true)
      local rx = east and x0 or x1
      local ry1 = -i * rise
      local rax = east and (sx0 + 0.1) or (sx1 - 1.3)
      if east then
        face({ rx, yTop, z0 }, { rx, yTop, z1 },
             { rx, ry1, z1 }, { rx, ry1, z0 },
             rax, i * rise, rax + 1.2, dep, STAIR_SHADE.riser)
      else
        face({ rx, yTop, z1 }, { rx, yTop, z0 },
             { rx, ry1, z0 }, { rx, ry1, z1 },
             rax, i * rise, rax + 1.2, dep, STAIR_SHADE.riser)
      end
      if i == STAIR_STEPS - 1 then
        local px = east and (mx + 16) or mx
        local cax = east and 14.7 or 0.1
        if east then
          face({ px, -h, z1 }, { px, -h, z0 }, { px, 0, z0 },
               { px, 0, z1 }, cax, 0, cax + 1.2, 16, STAIR_SHADE.wellEnd)
        else
          face({ px, -h, z0 }, { px, -h, z1 }, { px, 0, z1 },
               { px, 0, z0 }, cax, 0, cax + 1.2, 16, STAIR_SHADE.wellEnd)
        end
      end
    else
      local yTop = (i + 1) * rise
      local py0 = 16 - yTop
      banded(z1, sx0, sx1, 0, yTop, py0, 16, STAIR_SHADE.south)
      banded(z0, sx0, sx1, 0, yTop, py0, 16, STAIR_SHADE.north, true)
      face({ x0, yTop, z0 }, { x1, yTop, z0 },
           { x1, yTop, z1 }, { x0, yTop, z1 },
           sx0, py0, sx1, py0 + 1.4, STAIR_SHADE.tread)
      local rx = east and x0 or x1
      local ry0 = i * rise
      local rax = east and (sx0 + 0.1) or (sx1 - 1.3)
      if east then
        face({ rx, ry0, z0 }, { rx, ry0, z1 },
             { rx, yTop, z1 }, { rx, yTop, z0 },
             rax, 16 - yTop, rax + 1.2, 16 - ry0, STAIR_SHADE.riser)
      else
        face({ rx, ry0, z1 }, { rx, ry0, z0 },
             { rx, yTop, z0 }, { rx, yTop, z1 },
             rax, 16 - yTop, rax + 1.2, 16 - ry0, STAIR_SHADE.riser)
      end
      if i == STAIR_STEPS - 1 then
        local px = east and (mx + 16) or mx
        local cax = east and 14.7 or 0.1
        if east then
          face({ px, 0, z1 }, { px, 0, z0 }, { px, h, z0 },
               { px, h, z1 }, cax, 0, cax + 1.2, 16, STAIR_SHADE.cap)
        else
          face({ px, 0, z0 }, { px, 0, z1 }, { px, h, z1 },
               { px, h, z0 }, cax, 0, cax + 1.2, 16, STAIR_SHADE.cap)
        end
      end
    end
  end
end

function StairBuilder.build(S, map, x0, x1, y0, y1, data)
  for cy = math.floor(y0 / 2), math.floor(y1 / 2) do
    for cx = math.floor(x0 / 2), math.floor(x1 / 2) do
      local s = S.shapeAt[GridKey.of(cx * 2, cy * 2)]
      if s and s.art == "stair" then
        local down = s.class == "stair_down_e" or s.class == "stair_down_w"
        for dy = 0, 1 do
          for dx = 0, 1 do
            local tk = GridKey.of(cx * 2 + dx, cy * 2 + dy)
            S.skip[tk] = true
            if not down then S.ground[tk] = false end
          end
        end
        if data then stairCell(S, map, cx, cy, s) end
      end
    end
  end
end

return StairBuilder
