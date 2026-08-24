local V = ...

local Budget = V.require("BuildBudget")
local GridKey = V.require("GridKey")
local VoxLoader = V.require("VoxLoader")
local StructureMatcher = V.require("StructureMatcher")

local VoxProps = {}

local SHADE = { top = 0.95, south = 1.0, north = 0.68,
                side = 0.78, bottom = 0.5 }

local CELL = 8

local sources = {}
local models = {}
local authored = nil
local stats = { models = 0, placements = 0, quads = 0 }

local function runCap(a)
  return CELL - a % CELL
end

local function classOf(v)
  if v <= 0.25 then return 1 end
  if v <= 0.55 then return 2 end
  if v <= 0.85 then return 3 end
  return 4
end

local function swatches(data, tiles, perRow, atlasW, atlasH)
  local best = {}
  local seen = {}
  for r = 1, #tiles do
    for c = 1, #tiles[r] do
      local tile = tiles[r][c]
      local ox, oy = (tile % perRow) * 8, math.floor(tile / perRow) * 8
      for py = 0, 7 do
        for px = 0, 7 do
          local x, y = ox + px, oy + py
          if x < atlasW and y < atlasH then
            local rr, gg, bb, aa = data:getPixel(x, y)
            if aa > 0 then
              local k = classOf(math.min(rr, gg, bb))
              local key = k * 0x100000 + y * 4096 + x
              local n = (seen[key] or 0) + 1
              seen[key] = n
              local hit = best[k]
              if not hit or n > hit.n then
                best[k] = { x = x, y = y, n = n }
              end
            end
          end
        end
      end
    end
  end

  local any = best[1] or best[2] or best[3] or best[4]
  if not any then return nil end
  local out = {}
  for k = 1, 4 do
    local hit = best[k]
    if not hit then
      for d = 1, 3 do
        hit = best[k - d] or best[k + d]
        if hit then break end
      end
    end
    hit = hit or any
    out[k] = { u = (hit.x + 0.5) / atlasW, v = (hit.y + 0.5) / atlasH }
  end
  return out
end

local function shadeMap(vox)
  local used = {}
  for i = 4, #vox.voxels, 4 do
    local c = vox.voxels[i]
    if c and not used[c] then used[c] = VoxLoader.luma(vox, c) end
  end
  local order = {}
  for c in pairs(used) do order[#order + 1] = c end
  table.sort(order, function(a, b) return used[a] < used[b] end)

  local out = {}
  local n = #order
  if n == 0 then return out end
  if n <= 4 then
    for i = 1, n do out[order[i]] = 5 - n + i - 1 end
    if n == 1 then out[order[1]] = 3 end
    return out
  end
  local lo, hi = used[order[1]], used[order[n]]
  local span = hi - lo
  for _, c in ipairs(order) do
    if span <= 0 then
      out[c] = 3
    else
      local t = (used[c] - lo) / span
      local k = math.floor(t * 4) + 1
      out[c] = k > 4 and 4 or k
    end
  end
  return out
end

local function mesh(vox, sw, prop)
  local W, D, H = vox.w, vox.d, vox.h
  local shade = shadeMap(vox)
  local flipX, flipZ = prop.flipX, prop.flipZ
  local cell = {}
  local function key(x, y, z) return (y * D + z) * W + x end
  for i = 1, #vox.voxels, 4 do
    local vx, vy, vz = vox.voxels[i], vox.voxels[i + 1], vox.voxels[i + 2]
    local c = vox.voxels[i + 3]
    local x = flipX and (W - 1 - vx) or vx
    local z = flipZ and vy or (D - 1 - vy)
    cell[key(x, vz, z)] = shade[c] or 3
  end

  local quads = {}
  local function put(a, b, c, d, k, face)
    local s = sw[k] or sw[3]
    quads[#quads + 1] = { a, b, c, d, u = s.u, v = s.v, shade = face }
  end

  for _, d in ipairs({ 1, -1 }) do
    local face = d == 1 and SHADE.top or SHADE.bottom
    for y = d == 1 and 0 or 1, H - 1 do
      for z = 0, D - 1 do
        local x = 0
        while x < W do
          Budget.tick()
          local i = cell[key(x, y, z)]
          if i and not cell[key(x, y + d, z)] then
            local n, cap = 1, runCap(x)
            while n < cap and x + n < W do
              local j = cell[key(x + n, y, z)]
              if j ~= i or cell[key(x + n, y + d, z)] then break end
              n = n + 1
            end
            local yf = d == 1 and (y + 1) or y
            if d == 1 then
              put({ x, yf, z }, { x + n, yf, z },
                  { x + n, yf, z + 1 }, { x, yf, z + 1 }, i, face)
            else
              put({ x, yf, z + 1 }, { x + n, yf, z + 1 },
                  { x + n, yf, z }, { x, yf, z }, i, face)
            end
            x = x + n
          else
            x = x + 1
          end
        end
      end
    end
  end

  for _, d in ipairs({ 1, -1 }) do
    local face = d == 1 and SHADE.south or SHADE.north
    for y = 0, H - 1 do
      for z = 0, D - 1 do
        local x = 0
        while x < W do
          Budget.tick()
          local i = cell[key(x, y, z)]
          if i and not cell[key(x, y, z + d)] then
            local n, cap = 1, runCap(x)
            while n < cap and x + n < W do
              local j = cell[key(x + n, y, z)]
              if j ~= i or cell[key(x + n, y, z + d)] then break end
              n = n + 1
            end
            local zf = d == 1 and (z + 1) or z
            if d == 1 then
              put({ x, y, zf }, { x + n, y, zf },
                  { x + n, y + 1, zf }, { x, y + 1, zf }, i, face)
            else
              put({ x + n, y, zf }, { x, y, zf },
                  { x, y + 1, zf }, { x + n, y + 1, zf }, i, face)
            end
            x = x + n
          else
            x = x + 1
          end
        end
      end
    end
  end

  for _, d in ipairs({ 1, -1 }) do
    for y = 0, H - 1 do
      for x = 0, W - 1 do
        local z = 0
        while z < D do
          Budget.tick()
          local i = cell[key(x, y, z)]
          if i and not cell[key(x + d, y, z)] then
            local n, cap = 1, runCap(z)
            while n < cap and z + n < D do
              local j = cell[key(x, y, z + n)]
              if j ~= i or cell[key(x + d, y, z + n)] then break end
              n = n + 1
            end
            local xf = d == 1 and (x + 1) or x
            if d == 1 then
              put({ xf, y, z + n }, { xf, y, z },
                  { xf, y + 1, z }, { xf, y + 1, z + n }, i, SHADE.side)
            else
              put({ xf, y, z }, { xf, y, z + n },
                  { xf, y + 1, z + n }, { xf, y + 1, z }, i, SHADE.side)
            end
            z = z + n
          else
            z = z + 1
          end
        end
      end
    end
  end

  return quads
end

local function source(name)
  local hit = sources[name]
  if hit ~= nil then return hit or nil end
  local raw = V.mod and V.mod.read and V.mod:read("models/" .. name .. ".vox")
  local vox = raw and VoxLoader.parse(raw) or nil
  sources[name] = vox or false
  return vox
end

local function groundVote(S, tx, ty, bw, bh)
  local votes, best, bestN = {}, nil, 0
  local function vote(x, y)
    local k = GridKey.of(x, y)
    local s = S.shapeAt[k]
    if s and s.flat and s.class ~= "void" then
      local tile = S.tileAt[k]
      votes[tile] = (votes[tile] or 0) + 1
      if votes[tile] > bestN then best, bestN = tile, votes[tile] end
    end
  end
  for c = 0, bw - 1 do
    vote(tx + c, ty - 1)
    vote(tx + c, ty + bh)
  end
  for r = 0, bh - 1 do
    vote(tx - 1, ty + r)
    vote(tx + bw, ty + r)
  end
  return best
end

function VoxProps.stamp(S, map, quads, tx, ty, bw, bh)
  local shape = { class = "building", h = 0, art = "building",
                  flat = false, authored = true }
  local ground = groundVote(S, tx, ty, bw, bh)
  for r = 0, bh - 1 do
    for c = 0, bw - 1 do
      local k = GridKey.of(tx + c, ty + r)
      S.shapeAt[k] = shape
      S.skip[k] = true
      S.ground[k] = ground or false
    end
  end

  local mx, mz = tx * 8, ty * 8
  local out = S.objectQuads
  for _, q in ipairs(quads) do
    Budget.tick()
    out[#out + 1] = {
      { q[1][1] + mx, q[1][2], q[1][3] + mz },
      { q[2][1] + mx, q[2][2], q[2][3] + mz },
      { q[3][1] + mx, q[3][2], q[3][3] + mz },
      { q[4][1] + mx, q[4][2], q[4][3] + mz },
      u = q.u, v = q.v, shade = q.shade, own = true,
    }
  end
  stats.placements = stats.placements + 1
  stats.quads = stats.quads + #quads
end

function VoxProps.build(S, map, data, perRow)
  if not data then return end
  local tileset = map.tileset
  if authored == nil then authored = V.data("vox_props") or false end
  local list = authored and authored[tileset.id]
  if not list then return end

  local atlasW = tileset.imageWidth or 128
  local atlasH = tileset.imageHeight or 48
  local tw, th = map.def.width * 4, map.def.height * 4

  local patterns = {}
  for index, prop in ipairs(list) do
    local rows = prop.tiles
    if type(rows) == "table" and #rows > 0 then
      local flat = {}
      for r = 1, #rows do
        for c = 1, #rows[r] do flat[#flat + 1] = rows[r][c] end
      end
      patterns[#patterns + 1] = { tiles = flat, w = #rows[1], h = #rows,
                                  prop = prop, index = index }
    end
  end
  if #patterns == 0 then return end

  StructureMatcher.each(patterns, S.tileAt, 0, tw - 1, 0, th - 1,
    function(pattern, tx, ty)
      local prop = pattern.prop
      for r = 0, pattern.h - 1 do
        for c = 0, pattern.w - 1 do
          if S.skip[GridKey.of(tx + c, ty + r)] then return end
        end
      end

      local key = tileset.id .. ":" .. pattern.index
      local built = models[key]
      if built == nil then
        local vox = source(prop.model)
        local sw = vox and swatches(data, prop.tiles, perRow, atlasW, atlasH)
        built = (vox and sw) and mesh(vox, sw, prop) or false
        models[key] = built
        if built then stats.models = stats.models + 1 end
      end
      if built then
        VoxProps.stamp(S, map, built, tx, ty, pattern.w, pattern.h)
      end
    end)
end

function VoxProps.stats()
  return { models = stats.models, placements = stats.placements,
           quads = stats.quads }
end

function VoxProps.invalidate()
  models = {}
  sources = {}
  authored = nil
  stats = { models = 0, placements = 0, quads = 0 }
end

return VoxProps
