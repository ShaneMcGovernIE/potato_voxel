-- Authored bookcase geometry specialist used by Structures.
--
-- The builder receives the Structures claim state and only owns bookcase
-- detection, pane analysis, and relief emission. Structures keeps the public
-- compatibility method and the claim-order coordinator.
local V = ...

local GridKey = V.require("GridKey")
local TileShape = V.require("TileShape")

local BookcaseBuilder = {}
local DIRS4 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local BOOK_SHADE = { south = 1.0, north = 0.68, flank = 0.8, top = 0.85,
                     sill = 0.85, lintel = 0.5 }
local BOOK_RECESS_MAX = 24

local function bookcasePanes(map, data, perRow, run, i, j, shadeClass)
  if not data then return nil end
  local bands = run[i].bands
  local size = run[i].front - run[i].top + 1
  local W, H = (j - i + 1) * 8, bands * 8
  local light, srcU, srcV = {}, {}, {}
  for fy = 0, H - 1 do
    local band = bands - 1 - math.floor(fy / 8)
    local row = fy % 8
    for fx = 0, W - 1 do
      local col = run[i + math.floor(fx / 8)]
      local tile = band < size and map:tileAt(col.tx, col.front - band)
                   or col.cap
      if tile then
        local k = fy * W + fx
        local ax = (tile % perRow) * 8 + fx % 8
        local ay = math.floor(tile / perRow) * 8 + row
        srcU[k], srcV[k] = ax, ay
        local r, g, b, a = data:getPixel(ax, ay)
        light[k] = a ~= 0 and shadeClass(math.min(r, g, b)) ~= "black"
      end
    end
  end

  local pane, seen = {}, {}
  for k0 = 0, W * H - 1 do
    if light[k0] and not seen[k0] then
      local cells, stack = {}, { k0 }
      seen[k0] = true
      local ax0, ax1 = k0 % W, k0 % W
      local ay0, ay1 = math.floor(k0 / W), math.floor(k0 / W)
      local edge = false
      while #stack > 0 do
        local k = table.remove(stack)
        cells[#cells + 1] = k
        local cx, cy = k % W, math.floor(k / W)
        if cx < ax0 then ax0 = cx end
        if cx > ax1 then ax1 = cx end
        if cy < ay0 then ay0 = cy end
        if cy > ay1 then ay1 = cy end
        if cx == 0 or cx == W - 1 or cy == 0 or cy == H - 1 then edge = true end
        for _, d in ipairs(DIRS4) do
          local nx, ny = cx + d[1], cy + d[2]
          if nx >= 0 and nx < W and ny >= 0 and ny < H then
            local nk = ny * W + nx
            if light[nk] and not seen[nk] then
              seen[nk] = true
              stack[#stack + 1] = nk
            end
          end
        end
      end
      if not edge and ax1 - ax0 < BOOK_RECESS_MAX
         and ay1 - ay0 < BOOK_RECESS_MAX then
        for _, k in ipairs(cells) do pane[k] = true end
      end
    end
  end
  return pane, srcU, srcV, W, H
end

local function bookcaseRank(S, map, perRow, run, i, j, k, pane, srcU, srcV,
                            bankW, bankH)
  local r = run[k]
  local tx, northTy, frontTy, capTile = r.tx, r.top, r.front, r.cap
  local quads = S.objectQuads
  local atlasW = map.tileset.imageWidth or 128
  local atlasH = map.tileset.imageHeight or 48
  local function uvRect(tile)
    local ax = (tile % perRow) * 8
    local ay = math.floor(tile / perRow) * 8
    return (ax + 0.5) / atlasW, (ax + 7.5) / atlasW,
           (ay + 0.5) / atlasH, (ay + 7.5) / atlasH
  end

  local size = frontTy - northTy + 1
  local bands = r.bands
  local h = bands * 8
  local depth = math.min(2, size) * 8
  local x0, x1 = tx * 8, tx * 8 + 8
  local z1 = frontTy * 8 + 8
  local z0 = z1 - depth
  local fx0 = (k - i) * 8

  local function joined(nx)
    local ns = S.shapeAt[GridKey.of(nx, frontTy)]
    return ns ~= nil and ns.art == "bookcase"
  end

  local function sunk(fx, fy)
    if not pane or fx < 0 or fx >= bankW or fy < 0 or fy >= bankH then
      return false
    end
    return pane[fy * bankW + fx] == true
  end

  for band = 0, bands - 1 do
    local tile = band < size and map:tileAt(tx, frontTy - band) or capTile
    local u0, u1, v0, v1 = uvRect(tile)
    local y0, y1 = band * 8, band * 8 + 8
    local fyTop = (bands - 1 - band) * 8
    local relief = false
    if pane then
      for row = 0, 7 do
        for c = 0, 7 do
          if sunk(fx0 + c, fyTop + row) then relief = true break end
        end
        if relief then break end
      end
    end
    if not relief then
      quads[#quads + 1] = { { x0, y0, z1 }, { x1, y0, z1 },
        { x1, y1, z1 }, { x0, y1, z1 },
        uv = { { u0, v1 }, { u1, v1 }, { u1, v0 }, { u0, v0 } },
        shade = BOOK_SHADE.south }
    else
      local ax = (tile % perRow) * 8
      local ay = math.floor(tile / perRow) * 8
      for row = 0, 7 do
        local fy = fyTop + row
        local wy = y0 + 7 - row
        local c = 0
        while c < 8 do
          local s = sunk(fx0 + c, fy)
          local n = 1
          while c + n < 8 and sunk(fx0 + c + n, fy) == s do n = n + 1 end
          local pz = s and z1 - 1 or z1
          local qu0 = (ax + c + 0.05) / atlasW
          local qu1 = (ax + c + n - 0.05) / atlasW
          local qv0 = (ay + row + 0.05) / atlasH
          local qv1 = (ay + row + 1 - 0.05) / atlasH
          quads[#quads + 1] = {
            { x0 + c, wy, pz }, { x0 + c + n, wy, pz },
            { x0 + c + n, wy + 1, pz }, { x0 + c, wy + 1, pz },
            uv = { { qu0, qv1 }, { qu1, qv1 }, { qu1, qv0 }, { qu0, qv0 } },
            shade = BOOK_SHADE.south,
          }
          c = c + n
        end
      end
      for row = 0, 7 do
        local fy = fyTop + row
        local wy = y0 + 7 - row
        for c = 0, 7 do
          if sunk(fx0 + c, fy) then
            local X = x0 + c
            local function reveal(nfx, nfy, verts, shade)
              if nfx < 0 or nfx >= bankW or nfy < 0 or nfy >= bankH then return end
              if sunk(nfx, nfy) then return end
              local nk = nfy * bankW + nfx
              if not srcU[nk] then return end
              quads[#quads + 1] = { verts[1], verts[2], verts[3], verts[4],
                u = (srcU[nk] + 0.5) / atlasW,
                v = (srcV[nk] + 0.5) / atlasH, shade = shade }
            end
            reveal(fx0 + c - 1, fy, {
              { X, wy, z1 }, { X, wy, z1 - 1 },
              { X, wy + 1, z1 - 1 }, { X, wy + 1, z1 } }, BOOK_SHADE.flank)
            reveal(fx0 + c + 1, fy, {
              { X + 1, wy, z1 - 1 }, { X + 1, wy, z1 },
              { X + 1, wy + 1, z1 }, { X + 1, wy + 1, z1 - 1 } },
              BOOK_SHADE.flank)
            reveal(fx0 + c, fy + 1, {
              { X, wy, z1 - 1 }, { X + 1, wy, z1 - 1 },
              { X + 1, wy, z1 }, { X, wy, z1 } }, BOOK_SHADE.sill)
            reveal(fx0 + c, fy - 1, {
              { X, wy + 1, z1 }, { X + 1, wy + 1, z1 },
              { X + 1, wy + 1, z1 - 1 }, { X, wy + 1, z1 - 1 } },
              BOOK_SHADE.lintel)
          end
        end
      end
    end

    quads[#quads + 1] = { { x1, y0, z0 }, { x0, y0, z0 },
      { x0, y1, z0 }, { x1, y1, z0 },
      uv = { { u0, v1 }, { u1, v1 }, { u1, v0 }, { u0, v0 } },
      shade = BOOK_SHADE.north }
    if not joined(tx - 1) then
      quads[#quads + 1] = { { x0, y0, z0 }, { x0, y0, z1 },
        { x0, y1, z1 }, { x0, y1, z0 },
        uv = { { u0, v1 }, { u1, v1 }, { u1, v0 }, { u0, v0 } },
        shade = BOOK_SHADE.flank }
    end
    if not joined(tx + 1) then
      quads[#quads + 1] = { { x1, y0, z1 }, { x1, y0, z0 },
        { x1, y1, z0 }, { x1, y1, z1 },
        uv = { { u0, v1 }, { u1, v1 }, { u1, v0 }, { u0, v0 } },
        shade = BOOK_SHADE.flank }
    end
  end

  local topTile = capTile or map:tileAt(tx, northTy)
  local u0, u1, v0, v1 = uvRect(topTile)
  for seg = 0, depth / 8 - 1 do
    local sz0 = z0 + seg * 8
    quads[#quads + 1] = { { x0, h, sz0 }, { x1, h, sz0 },
      { x1, h, sz0 + 8 }, { x0, h, sz0 + 8 },
      uv = { { u0, v0 }, { u1, v0 }, { u1, v1 }, { u0, v1 } },
      shade = BOOK_SHADE.top }
  end
end

function BookcaseBuilder.build(S, map, x0, x1, y0, y1, data, perRow, shadeClass)
  perRow = perRow or map.tileset.tilesPerRow or 16
  local backfill = TileShape.bookcaseBackfill(map.tileset.id)
  if not TileShape.bookcaseRelief(map.tileset.id) then data = nil end
  local order, banks = {}, {}
  for tx = x0, x1 do
    local ty = y1
    while ty >= y0 do
      local s = S.shapeAt[GridKey.of(tx, ty)]
      if s and s.art == "bookcase" then
        local north = ty
        while north > y0 do
          local ns = S.shapeAt[GridKey.of(tx, north - 1)]
          if ns and ns.art == "bookcase" then north = north - 1 else break end
        end
        local front = ty
        while front >= north do
          local top = math.max(north, front - 3)
          local capTile = nil
          if top == north then
            local ck = GridKey.of(tx, north - 1)
            local cs = S.shapeAt[ck]
            if cs and not cs.flat and not S.skip[ck] and not S.runs[ck]
               and (not cs.authored or cs.class == "table") then
              capTile = S.tileAt[ck]
            end
          end
          local covered = math.min(2, front - top + 1)
          local srcK = GridKey.of(tx, top - 1)
          local src = backfill == "above" and S.shapeAt[srcK] or nil
          for cy = top, front do
            local tk = GridKey.of(tx, cy)
            if src and cy <= front - covered then
              S.shapeAt[tk] = src
              S.tileAt[tk] = S.tileAt[srcK]
            else
              S.skip[tk] = true
              S.ground[tk] = false
            end
          end
          local bands = (front - top + 1) + (capTile and 1 or 0)
          local key = top .. ":" .. front .. ":" .. bands
          local bank = banks[key]
          if not bank then
            bank = {}
            banks[key] = bank
            order[#order + 1] = key
          end
          bank[#bank + 1] = { tx = tx, top = top, front = front,
                              cap = capTile, bands = bands }
          front = top - 1
        end
        ty = north - 1
      else
        ty = ty - 1
      end
    end
  end

  for _, key in ipairs(order) do
    local run = banks[key]
    local i = 1
    while i <= #run do
      local j = i
      while j < #run and run[j + 1].tx == run[j].tx + 1 do j = j + 1 end
      local pane, srcU, srcV, bankW, bankH =
        bookcasePanes(map, data, perRow, run, i, j, shadeClass)
      for k = i, j do
        bookcaseRank(S, map, perRow, run, i, j, k,
                     pane, srcU, srcV, bankW, bankH)
      end
      i = j + 1
    end
  end
end

return BookcaseBuilder
