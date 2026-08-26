-- MagicaVoxel .vox reader (VOX 150) and greedy face mesher.
--
-- MagicaVoxel: +X right, +Y depth, +Z up. PotatoVoxel world: +X east,
-- +Y up, +Z south. One MagicaVoxel voxel is one world pixel. Missing
-- files and truncated buffers return nil -- the caller keeps the
-- procedural model (degrade, never error).

local MagicaVoxel = {}

local function u8(buf, i)
  return buf:byte(i) or 0
end

local function i32(buf, i)
  local a, b, c, d = buf:byte(i, i + 3)
  if not d then return 0 end
  local n = a + b * 256 + c * 65536 + d * 16777216
  if n >= 2147483648 then n = n - 4294967296 end
  return n
end

-- MagicaVoxel's built-in palette when a file has no RGBA chunk (old
-- MagicaVoxel). Modern MagicaVoxel always writes RGBA.
local function defaultPalette()
  local p = {}
  for i = 0, 255 do
    local v = i / 255
    p[i] = { v, v, v, 1 }
  end
  p[0] = { 0, 0, 0, 0 }
  p[1] = { 1, 1, 1, 1 }
  return p
end

function MagicaVoxel.parse(buf)
  if type(buf) ~= "string" or #buf < 20 then return nil end
  if buf:sub(1, 4) ~= "VOX " then return nil end
  local pos = 9
  if buf:sub(pos, pos + 3) ~= "MAIN" then return nil end
  local mainContent = i32(buf, pos + 4)
  pos = pos + 12 + mainContent

  local sx, sy, sz = 0, 0, 0
  local voxels = {}
  local palette = nil

  while pos + 11 <= #buf do
    local id = buf:sub(pos, pos + 3)
    local content = i32(buf, pos + 4)
    local children = i32(buf, pos + 8)
    local body = pos + 12
    if body + content - 1 > #buf then break end
    if id == "SIZE" and content >= 12 then
      sx = i32(buf, body)
      sy = i32(buf, body + 4)
      sz = i32(buf, body + 8)
    elseif id == "XYZI" and content >= 4 then
      local n = i32(buf, body)
      local p = body + 4
      for _ = 1, n do
        if p + 3 > #buf then break end
        local x, y, z, c = u8(buf, p), u8(buf, p + 1), u8(buf, p + 2),
                           u8(buf, p + 3)
        if c > 0 then
          voxels[#voxels + 1] = { x = x, y = y, z = z, c = c }
        end
        p = p + 4
      end
    elseif id == "RGBA" and content >= 1024 then
      palette = {}
      palette[0] = { 0, 0, 0, 0 }
      for i = 1, 256 do
        local o = body + (i - 1) * 4
        palette[i] = {
          u8(buf, o) / 255,
          u8(buf, o + 1) / 255,
          u8(buf, o + 2) / 255,
          u8(buf, o + 3) / 255,
        }
      end
    end
    pos = body + content + children
  end

  if sx < 1 or sy < 1 or sz < 1 or #voxels == 0 then return nil end
  return {
    sx = sx, sy = sy, sz = sz,
    voxels = voxels,
    palette = palette or defaultPalette(),
  }
end

-- Encode a tiny model (tests). palette is optional 1..255 {r,g,b,a} 0-1.
function MagicaVoxel.encode(model)
  local sx = model.sx or 1
  local sy = model.sy or 1
  local sz = model.sz or 1
  local voxels = model.voxels or {}
  local function put32(n)
    if n < 0 then n = n + 4294967296 end
    local a = n % 256
    n = math.floor(n / 256)
    local b = n % 256
    n = math.floor(n / 256)
    local c = n % 256
    n = math.floor(n / 256)
    return string.char(a, b, c, n % 256)
  end
  local function chunk(id, content)
    return id .. put32(#content) .. put32(0) .. content
  end
  local size = chunk("SIZE", put32(sx) .. put32(sy) .. put32(sz))
  local xyzi = put32(#voxels)
  for _, v in ipairs(voxels) do
    xyzi = xyzi .. string.char(v.x or 0, v.y or 0, v.z or 0, v.c or 1)
  end
  xyzi = chunk("XYZI", xyzi)
  local extra = ""
  if model.palette then
    local rgba = {}
    for i = 1, 256 do
      local c = model.palette[i] or { 0, 0, 0, 1 }
      rgba[#rgba + 1] = string.char(
        math.floor((c[1] or 0) * 255 + 0.5),
        math.floor((c[2] or 0) * 255 + 0.5),
        math.floor((c[3] or 0) * 255 + 0.5),
        math.floor((c[4] or 1) * 255 + 0.5))
    end
    extra = chunk("RGBA", table.concat(rgba))
  end
  local children = size .. xyzi .. extra
  return "VOX " .. put32(150) .. "MAIN" .. put32(0) .. put32(#children)
         .. children
end

-- MagicaVoxel (x, y-depth, z-up) -> world (x, y-up, z-south).
local function worldCorner(x, y, z)
  return x, z, y
end

-- MagicaVoxel colour 1..255 maps onto palette[1]..palette[255] in the
-- 16x16 atlas (pixel 0 is the empty index). Off-by-one here samples
-- alpha-0 and the voxel shader discards the face -- a filled tree
-- reads as a hollow shell. Palette colours are a single texel, so a
-- merged run reuses one UV.
local uvCache = {}
local function paletteUV(index, row, rows)
  local key = (index or 1) * 4096 + (row or 0) * 16 + (rows or 1)
  local uv = uvCache[key]
  if uv then return uv end
  local i = (tonumber(index) or 1) % 256
  local ix, iy = i % 16, math.floor(i / 16)
  local u = (ix + 0.5) / 16
  local v = ((row or 0) * 16 + iy + 0.5) / ((rows or 1) * 16)
  local p = { u, v }
  uv = { p, p, p, p }
  uvCache[key] = uv
  return uv
end

-- Merge coplanar same-colour unit faces into rectangles. Forests of
-- MagicaVoxel stamps are otherwise one quad per voxel face.
local function greedyRects(U, V, sample, emit)
  local used = {}
  for v = 0, V - 1 do
    for u = 0, U - 1 do
      local i0 = v * U + u
      if not used[i0] then
        local c = sample(u, v)
        if c then
          local du = 1
          while u + du < U and not used[v * U + (u + du)]
            and sample(u + du, v) == c do
            du = du + 1
          end
          local dv = 1
          while v + dv < V do
            local ok = true
            local row = (v + dv) * U + u
            for k = 0, du - 1 do
              if used[row + k] or sample(u + k, v + dv) ~= c then
                ok = false
                break
              end
            end
            if not ok then break end
            dv = dv + 1
          end
          for vv = 0, dv - 1 do
            local row = (v + vv) * U + u
            for k = 0, du - 1 do
              used[row + k] = true
            end
          end
          emit(u, v, du, dv, c)
        end
      end
    end
  end
end

-- opts.skipFloor: drop underside faces of voxels at z = 0 (the model
-- sits on the ground; those faces z-fight the terrain).
function MagicaVoxel.quads(model, shades, paletteRow, paletteRows, opts)
  if not (model and model.voxels) then return {} end
  local sx, sy, sz = model.sx, model.sy, model.sz
  local at = {}
  for _, v in ipairs(model.voxels) do
    if v.x >= 0 and v.x < sx and v.y >= 0 and v.y < sy
       and v.z >= 0 and v.z < sz then
      at[(v.z * sy + v.y) * sx + v.x] = v.c
    end
  end
  local function occ(x, y, z)
    if x < 0 or y < 0 or z < 0 or x >= sx or y >= sy or z >= sz then
      return nil
    end
    return at[(z * sy + y) * sx + x]
  end
  paletteRow = paletteRow or 0
  paletteRows = paletteRows or 1
  local skipFloor = opts and opts.skipFloor
  local shadeOf = shades or {}
  local quads = {}
  local function put(x0, y0, z0, x1, y1, z1, x2, y2, z2, x3, y3, z3, c, dir)
    local a = { worldCorner(x0, y0, z0) }
    local b = { worldCorner(x1, y1, z1) }
    local d = { worldCorner(x2, y2, z2) }
    local e = { worldCorner(x3, y3, z3) }
    quads[#quads + 1] = {
      a, b, d, e,
      uv = paletteUV(c, paletteRow, paletteRows),
      shade = shadeOf[dir] or 1,
    }
  end

  -- +X
  for x = 0, sx - 1 do
    greedyRects(sy, sz, function(y, z)
      local c = occ(x, y, z)
      if c and not occ(x + 1, y, z) then return c end
    end, function(y, z, dy, dz, c)
      put(x + 1, y, z, x + 1, y + dy, z, x + 1, y + dy, z + dz,
          x + 1, y, z + dz, c, 1)
    end)
  end
  -- -X
  for x = 0, sx - 1 do
    greedyRects(sy, sz, function(y, z)
      local c = occ(x, y, z)
      if c and not occ(x - 1, y, z) then return c end
    end, function(y, z, dy, dz, c)
      put(x, y + dy, z, x, y, z, x, y, z + dz, x, y + dy, z + dz, c, 2)
    end)
  end
  -- +Y world / +Z magica (top)
  for z = 0, sz - 1 do
    greedyRects(sx, sy, function(x, y)
      local c = occ(x, y, z)
      if c and not occ(x, y, z + 1) then return c end
    end, function(x, y, dx, dy, c)
      put(x, y, z + 1, x + dx, y, z + 1, x + dx, y + dy, z + 1,
          x, y + dy, z + 1, c, 3)
    end)
  end
  -- -Y world / -Z magica (bottom)
  for z = skipFloor and 1 or 0, sz - 1 do
    greedyRects(sx, sy, function(x, y)
      local c = occ(x, y, z)
      if c and not occ(x, y, z - 1) then return c end
    end, function(x, y, dx, dy, c)
      put(x, y + dy, z, x + dx, y + dy, z, x + dx, y, z, x, y, z, c, 4)
    end)
  end
  -- +Z world / +Y magica (south)
  for y = 0, sy - 1 do
    greedyRects(sx, sz, function(x, z)
      local c = occ(x, y, z)
      if c and not occ(x, y + 1, z) then return c end
    end, function(x, z, dx, dz, c)
      put(x, y + 1, z, x + dx, y + 1, z, x + dx, y + 1, z + dz,
          x, y + 1, z + dz, c, 5)
    end)
  end
  -- -Z world / -Y magica (north)
  for y = 0, sy - 1 do
    greedyRects(sx, sz, function(x, z)
      local c = occ(x, y, z)
      if c and not occ(x, y - 1, z) then return c end
    end, function(x, z, dx, dz, c)
      put(x + dx, y, z, x, y, z, x, y, z + dz, x + dx, y, z + dz, c, 6)
    end)
  end
  return quads
end

return MagicaVoxel
