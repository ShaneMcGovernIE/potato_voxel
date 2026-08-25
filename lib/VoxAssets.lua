-- MagicaVoxel asset cache: load assets/vox/<name>.vox, mesh to quads,
-- and (on the GPU thread) a stacked 16x16 palette atlas.
--
-- A missing or broken file is nil. Buildings stamps the mesh when the
-- file is present; a vox-named template with no file is skipped so later
-- passes (cylinders) still run. Palette atlas rows are assigned in load
-- order so UVs stay stable for a session once preload() has seen every
-- profile name.

local V = ...

local MagicaVoxel = V.require("MagicaVoxel")
local Voxel3D = V.require("Voxel3D")

local VoxAssets = {}

local DIR = "assets/vox/"
local models = {}
local palettes = {}
local paletteIndex = {}
local paletteUses = {}
local paletteShades = {}
local texture = false
local coloredTextures = {}
local revision = nil
local spriteMap = nil

local function readFile(name)
  if type(name) ~= "string" or name == "" then return nil end
  name = name:gsub("%.vox$", "")
  local rel = DIR .. name .. ".vox"
  if V.read then
    local buf = V.read(rel)
    if type(buf) == "string" and #buf > 0 then return buf, name end
  end
  if V.mod and V.mod.read then
    local buf = V.mod:read(rel)
    if type(buf) == "string" and #buf > 0 then return buf, name end
  end
  return nil
end

local function paletteKey(palette)
  local parts = {}
  for i = 1, 16 do
    local c = palette[i] or { 0, 0, 0, 1 }
    parts[#parts + 1] = string.format("%.3f%.3f%.3f", c[1], c[2], c[3])
  end
  return table.concat(parts)
end

local function colorsKey(colors)
  local parts = {}
  for i = 1, 4 do
    local c = colors[i] or { 0, 0, 0 }
    parts[#parts + 1] = table.concat({ c[1] or 0, c[2] or 0, c[3] or 0 }, ",")
  end
  return table.concat(parts, ";")
end

local function luminance(c)
  return (c[1] or 0) * 0.299 + (c[2] or 0) * 0.587
       + (c[3] or 0) * 0.114
end

-- Map only the model's authored colours from darkest to lightest onto the
-- four colours of the active world palette. Unused MagicaVoxel palette
-- entries must not influence the shade ranking.
local function shadeMap(palette, used)
  local ranked = {}
  for index in pairs(used or {}) do
    local c = palette[index]
    if c and (c[4] or 1) > 0 then
      ranked[#ranked + 1] = { index = index, value = luminance(c) }
    end
  end
  table.sort(ranked, function(a, b)
    if a.value == b.value then return a.index < b.index end
    return a.value < b.value
  end)
  local out = {}
  local n = #ranked
  for rank, item in ipairs(ranked) do
    local bucket = math.floor((rank - 1) * 4 / math.max(1, n))
    out[item.index] = 4 - bucket
  end
  return out
end

local function remapPalette(palette, shades, colors)
  if not colors then return palette end
  local out = {}
  for index, c in pairs(palette or {}) do
    local target = shades and colors[shades[index]]
    if target then
      out[index] = { (target[1] or 0) / 255,
                     (target[2] or 0) / 255,
                     (target[3] or 0) / 255,
                     c[4] or 1 }
    else
      out[index] = { c[1] or 0, c[2] or 0, c[3] or 0, c[4] or 1 }
    end
  end
  return out
end

-- Public data seam for palette-aware model textures and the headless
-- regression test. `used` may be an index set or an array of indices.
function VoxAssets.recolorPalette(palette, used, colors)
  local set = {}
  for index, value in pairs(used or {}) do
    if type(index) == "number" and type(value) == "boolean" then
      if value then set[index] = true end
    elseif type(value) == "number" then
      set[value] = true
    end
  end
  return remapPalette(palette, shadeMap(palette, set), colors)
end

function VoxAssets.load(name)
  name = tostring(name or ""):gsub("%.vox$", "")
  if name == "" then return nil end
  if models[name] ~= nil then return models[name] or nil end
  local buf = readFile(name)
  if not buf then
    models[name] = false
    return nil
  end
  local model = MagicaVoxel.parse(buf)
  if not model then
    models[name] = false
    return nil
  end
  local key = paletteKey(model.palette)
  local row = paletteIndex[key]
  if not row then
    palettes[#palettes + 1] = model.palette
    row = #palettes - 1
    paletteIndex[key] = row
    paletteUses[row + 1] = {}
    texture = false
    revision = nil
  end
  local uses = paletteUses[row + 1]
  for _, voxel in ipairs(model.voxels) do
    uses[voxel.c] = true
  end
  paletteShades[row + 1] = shadeMap(model.palette, uses)
  coloredTextures = {}
  model.row = row
  model.name = name
  models[name] = model
  return model
end

function VoxAssets.quads(name)
  local model = VoxAssets.load(name)
  if not model then return nil end
  local rows = math.max(1, #palettes)
  local cache = model.quadsCache
  if cache and cache.rows == rows then
    return cache.quads, model
  end
  local quads = MagicaVoxel.quads(model, Voxel3D.FACE_SHADE, model.row, rows,
                                  { skipFloor = true })
  model.quadsCache = { rows = rows, quads = quads }
  return quads, model
end

function VoxAssets.revision()
  if revision then return revision end
  local names, seen = {}, {}
  local function add(n)
    if type(n) ~= "string" or n == "" then return end
    n = n:gsub("%.vox$", "")
    if not seen[n] then
      seen[n] = true
      names[#names + 1] = n
    end
  end
  local ok, prof = pcall(V.data, "voxel_heights")
  if ok and type(prof) == "table" then
    for _, n in pairs(prof.vox or {}) do add(n) end
    for _, n in pairs(prof.sprites or {}) do add(n) end
    for _, list in pairs(prof.buildings or {}) do
      if type(list) == "table" then
        for _, t in ipairs(list) do add(t.vox) end
      end
    end
  end
  for name in pairs(models) do add(name) end
  table.sort(names)
  local hash = 17
  for _, name in ipairs(names) do
    hash = (hash * 31 + #name) % 2147483647
    local buf = readFile(name)
    if buf then
      hash = (hash * 31 + #buf) % 2147483647
      for i = 1, #buf, 97 do
        hash = (hash * 31 + buf:byte(i)) % 2147483647
      end
    end
  end
  revision = tostring(hash)
  return revision
end

function VoxAssets.paletteRows()
  return math.max(1, #palettes)
end

function VoxAssets.texture(colors)
  local key = colors and colorsKey(colors) or nil
  if key then
    local cached = coloredTextures[key]
    if cached ~= nil then return cached or nil end
  elseif texture then
    return texture ~= false and texture or nil
  end
  if #palettes == 0 then return nil end
  if not (love and love.image and love.image.newImageData) then return nil end
  local rows = #palettes
  local ok, data = pcall(love.image.newImageData, 16, 16 * rows)
  if not ok or not data then return nil end
  for row, palette in ipairs(palettes) do
    local baked = colors and remapPalette(palette, paletteShades[row], colors)
                  or palette
    for i = 0, 255 do
      local c = baked[i] or { 0, 0, 0, 1 }
      local x, y = i % 16, math.floor(i / 16) + (row - 1) * 16
      pcall(data.setPixel, data, x, y, c[1] or 0, c[2] or 0, c[3] or 0,
            c[4] or 1)
    end
  end
  if not (love.graphics and love.graphics.newImage) then
    if key then coloredTextures[key] = false else texture = false end
    return nil
  end
  local okImg, img = pcall(love.graphics.newImage, data)
  if not okImg or not img then
    if key then coloredTextures[key] = false else texture = false end
    return nil
  end
  pcall(img.setFilter, img, "nearest", "nearest")
  if key then coloredTextures[key] = img else texture = img end
  return img
end

function VoxAssets.preload(names)
  -- Load every asset first so palette rows are assigned, then mesh
  -- once with the final row count. Stamps then only translate.
  for _, name in ipairs(names or {}) do
    VoxAssets.load(name)
  end
  for _, name in ipairs(names or {}) do
    VoxAssets.quads(name)
  end
end

-- Load every profile-named .vox (buildings, sprite replacements) so
-- palette-atlas rows are fixed before any map mesh bakes UVs.
function VoxAssets.preloadProfile()
  local names = {}
  local ok, prof = pcall(V.data, "voxel_heights")
  if ok and type(prof) == "table" then
    for _, n in pairs(prof.vox or {}) do names[#names + 1] = n end
    for _, n in pairs(prof.sprites or {}) do names[#names + 1] = n end
    for _, list in pairs(prof.buildings or {}) do
      if type(list) == "table" then
        for _, t in ipairs(list) do
          if t.vox then names[#names + 1] = t.vox end
        end
      end
    end
  end
  VoxAssets.preload(names)
end

-- Overworld sprite image (".../fruit_tree.png") -> MagicaVoxel asset name.
function VoxAssets.forSprite(image)
  if spriteMap == nil then
    spriteMap = false
    local ok, prof = pcall(V.data, "voxel_heights")
    if ok and type(prof) == "table" and type(prof.sprites) == "table" then
      spriteMap = prof.sprites
    end
  end
  if not spriteMap or type(image) ~= "string" then return nil end
  local key = image:match("([^/\\]+)%.png$") or image
  return spriteMap[key]
end

-- SpriteRenderer passes a 16x16 still sprite's top-left corner; its visible
-- card is centred on (px + 8, pz + 8) and rests on the ground.  MagicaVoxel
-- models use their minimum corner as the origin, so centre a replacement's
-- footprint around that same world anchor.  The vertical model origin
-- remains the ground plane.
function VoxAssets.spriteOrigin(name, px, pz)
  local model = VoxAssets.load(name)
  if not model then return px or 0, pz or 0 end
  return (px or 0) + 8 - (model.sx or 16) * 0.5,
         (pz or 0) + 8 - (model.sy or 16) * 0.5
end

-- GPU mesh for a named asset, in model space (origin at MagicaVoxel min).
-- Nil headless. Rebuilt if the palette atlas gains a row.
function VoxAssets.mesh(name)
  local quads, model = VoxAssets.quads(name)
  if not (quads and model and #quads > 0) then return nil end
  local rows = math.max(1, #palettes)
  if model.gpuMesh and model.gpuMeshRows == rows then
    return model.gpuMesh ~= false and model.gpuMesh or nil
  end
  if not (Voxel3D and Voxel3D.newMesh) then return nil end
  local verts, indices, n = {}, {}, 0
  for _, q in ipairs(quads) do
    for i = 1, 4 do
      local c = q[i]
      local uv = q.uv and q.uv[i] or { 0, 0 }
      verts[#verts + 1] = { c[1], c[2], c[3], uv[1], uv[2], q.shade }
    end
    Voxel3D.pushQuad(indices, n)
    n = n + 1
  end
  local mesh = Voxel3D.newMesh(verts, indices)
  model.gpuMesh = mesh or false
  model.gpuMeshRows = rows
  return mesh
end

-- Translate model-space quads (origin at MagicaVoxel min, Y up) into
-- world pixels. `ox, oy, oz` is the world origin of the MagicaVoxel (0,0,0)
-- corner -- typically the north-west tile of the stamp, ground plane.
function VoxAssets.place(quads, ox, oy, oz, scale)
  scale = scale or 1
  ox, oy, oz = ox or 0, oy or 0, oz or 0
  local n = quads and #quads or 0
  local out = {}
  if scale == 1 then
    for i = 1, n do
      local q = quads[i]
      local dst = { uv = q.uv, shade = q.shade, own = true }
      for k = 1, 4 do
        local c = q[k]
        dst[k] = { ox + c[1], oy + c[2], oz + c[3] }
      end
      out[i] = dst
    end
    return out
  end
  for i = 1, n do
    local q = quads[i]
    local dst = { uv = q.uv, shade = q.shade, own = true }
    for k = 1, 4 do
      local c = q[k]
      dst[k] = { ox + c[1] * scale, oy + c[2] * scale, oz + c[3] * scale }
    end
    out[i] = dst
  end
  return out
end

function VoxAssets._resetForTests()
  models, palettes, paletteIndex = {}, {}, {}
  paletteUses, paletteShades, coloredTextures = {}, {}, {}
  texture, revision, spriteMap = false, nil, nil
end

return VoxAssets
