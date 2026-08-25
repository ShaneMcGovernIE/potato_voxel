-- Headless MagicaVoxel parse / mesh / replace-degrade tests.
local function check(condition, message)
  if not condition then error(message, 0) end
end

local MagicaVoxel = assert(loadfile("lib/MagicaVoxel.lua"))()

local palette = {}
for i = 1, 256 do palette[i] = { 1, 0, 0, 1 } end
palette[2] = { 0, 1, 0, 1 }

local buf = MagicaVoxel.encode({
  sx = 2, sy = 2, sz = 2,
  voxels = {
    { x = 0, y = 0, z = 0, c = 1 },
    { x = 1, y = 0, z = 0, c = 2 },
  },
  palette = palette,
})
check(type(buf) == "string" and buf:sub(1, 4) == "VOX ",
      "encoder writes a VOX file")

local model = MagicaVoxel.parse(buf)
check(model and model.sx == 2 and model.sy == 2 and model.sz == 2,
      "parser reads SIZE")
check(#model.voxels == 2, "parser reads both voxels")
check(model.palette[1][1] > 0.9 and model.palette[2][2] > 0.9,
      "parser reads RGBA palette")

local shades = { [1] = 0.8, [2] = 0.7, [3] = 1, [4] = 0.5, [5] = 0.9, [6] = 0.6 }
local quads = MagicaVoxel.quads(model, shades, 0, 1)
check(#quads > 0, "visible faces emit quads")
local hasTop = false
local sampledEmpty = false
local sampledC1, sampledC2 = 0, 0
for _, q in ipairs(quads) do
  check(q.uv and q.shade, "each MagicaVoxel quad has uv and shade")
  if q.shade == 1 then hasTop = true end
  local u = q.uv[1][1]
  if math.abs(u - 0.5 / 16) < 0.001 then sampledEmpty = true end
  if math.abs(u - 1.5 / 16) < 0.001 then sampledC1 = sampledC1 + 1 end
  if math.abs(u - 2.5 / 16) < 0.001 then sampledC2 = sampledC2 + 1 end
end
check(hasTop, "top faces use +Y shade")
check(not sampledEmpty,
      "MagicaVoxel colour 1 must not sample the empty palette texel")
check(sampledC1 > 0 and sampledC2 > 0,
      "each MagicaVoxel colour samples its own palette texel")

check(MagicaVoxel.parse("") == nil, "empty buffer degrades")
check(MagicaVoxel.parse("not a vox") == nil, "garbage buffer degrades")

do
  local solidVoxels = {}
  for x = 0, 1 do
    for y = 0, 1 do
      for z = 0, 1 do
        solidVoxels[#solidVoxels + 1] = { x = x, y = y, z = z, c = 1 }
      end
    end
  end
  local solid = MagicaVoxel.parse(MagicaVoxel.encode({
    sx = 2, sy = 2, sz = 2, voxels = solidVoxels, palette = palette,
  }))
  local merged = MagicaVoxel.quads(solid, shades, 0, 1)
  check(#merged == 6, "a solid 2x2x2 greedy-meshes to 6 faces, got "
        .. tostring(#merged))
  local noFloor = MagicaVoxel.quads(solid, shades, 0, 1, { skipFloor = true })
  check(#noFloor == 5, "skipFloor drops the ground-plane underside")
end

local function readVox(name)
  for _, p in ipairs({
    "assets/vox/" .. name,
    "mods/potato_voxel/assets/vox/" .. name,
  }) do
    local f = io.open(p, "rb")
    if f then
      local buf = f:read("*a")
      f:close()
      return buf
    end
  end
end

local tall = MagicaVoxel.parse(readVox("crystal_pine_tall.vox"))
check(tall and tall.sx == 16 and tall.sy == 16 and tall.sz == 32
      and #tall.voxels > 1000,
      "Crystal tall pine is a 16x16x32 MagicaVoxel model")
check(tall.palette[1][4] > 0.9 and tall.palette[2][2] > tall.palette[2][1],
      "Crystal pine foliage palette is opaque green, not grayscale")
local at = {}
for _, v in ipairs(tall.voxels) do
  at[(v.z * 16 + v.y) * 16 + v.x] = true
end
local midHoles = 0
for y = 1, 14 do
  for x = 1, 14 do
    local i = (20 * 16 + y) * 16 + x
    if not at[i] then
      local n = 0
      if at[i - 1] then n = n + 1 end
      if at[i + 1] then n = n + 1 end
      if at[i - 16] then n = n + 1 end
      if at[i + 16] then n = n + 1 end
      if n >= 3 then midHoles = midHoles + 1 end
    end
  end
end
check(midHoles == 0, "Crystal tall pine mid-canopy is a filled disc")
local tallQuads = MagicaVoxel.quads(tall, shades, 0, 1, { skipFloor = true })
check(#tallQuads < 1600 and #tallQuads < #tall.voxels,
      "greedy tall pine is far smaller than per-voxel faces, got "
      .. tostring(#tallQuads))
local short = MagicaVoxel.parse(readVox("crystal_pine_short.vox"))
check(short and short.sx == 16 and short.sy == 16 and short.sz == 16
      and #short.voxels > 200,
      "Crystal short pine is a 16x16x16 MagicaVoxel model")

local berry = MagicaVoxel.parse(readVox("crystal_berry_tree.vox"))
check(berry and berry.sx == 16 and berry.sy == 16 and berry.sz == 16
      and #berry.voxels > 400,
      "Crystal berry tree is a 16x16x16 MagicaVoxel model")
check(berry.palette[5][1] > berry.palette[5][3],
      "Crystal berry tree fruit palette is gold, not grayscale")
local exposed = {}
for _, voxel in ipairs(berry.voxels) do
  local key = voxel.x .. ":" .. voxel.z
  if not exposed[key] or voxel.y > exposed[key].y then
    exposed[key] = voxel
  end
end
local visibleBerries = 0
for _, voxel in pairs(exposed) do
  if voxel.c == 5 then visibleBerries = visibleBerries + 1 end
end
check(visibleBerries >= 5,
      "Crystal berry tree keeps visible berries on its outer canopy")

local cutTree = MagicaVoxel.parse(readVox("crystal_cut_tree.vox"))
check(cutTree and cutTree.sx == 16 and cutTree.sy == 16
      and cutTree.sz == 16 and #cutTree.voxels > 300,
      "Crystal CUT tree is a 16x16x16 MagicaVoxel model")
check(cutTree.palette[94][2] > cutTree.palette[94][1]
      and cutTree.palette[95][2] > cutTree.palette[95][1],
      "Crystal CUT tree keeps its green palette")

local VoxAssets = assert(loadfile("lib/VoxAssets.lua"))({
  read = function(rel)
    return readVox(rel:match("([^/]+)$"))
  end,
  data = function()
    return { sprites = { fruit_tree = "crystal_berry_tree" } }
  end,
  require = function(name)
    if name == "MagicaVoxel" then return MagicaVoxel end
    if name == "Voxel3D" then return {} end
    error("unexpected module: " .. tostring(name))
  end,
})
local worldColors = {
  { 248, 248, 248 }, { 168, 168, 168 }, { 85, 85, 85 }, { 0, 0, 0 },
}
local recolored = VoxAssets.recolorPalette({
  [1] = { 0.05, 0.10, 0.02, 1 },
  [2] = { 0.30, 0.40, 0.08, 1 },
  [3] = { 0.55, 0.65, 0.20, 1 },
  [4] = { 0.90, 0.95, 0.50, 1 },
}, { 1, 2, 3, 4 }, worldColors)
check(recolored[1][1] == 0 and recolored[1][2] == 0,
      "voxel model darkest palette shade follows the world palette")
check(recolored[4][1] == 248 / 255 and recolored[4][2] == 248 / 255,
      "voxel model lightest palette shade follows the world palette")

do
  local oldLove = _G.love
  local bakedData
  _G.love = { image = {}, graphics = {} }
  function love.image.newImageData(w, h)
    local data = { w = w, h = h, pixels = {} }
    function data.setPixel(self, x, y, r, g, b, a)
      self.pixels[x .. ":" .. y] = { r, g, b, a }
    end
    return data
  end
  function love.graphics.newImage(data)
    bakedData = data
    return { setFilter = function() end }
  end
  VoxAssets._resetForTests()
  VoxAssets.load("crystal_pine_short")
  check(VoxAssets.texture(worldColors) ~= nil,
        "voxel model texture can be baked under a world palette")
  check(bakedData.pixels["1:0"][1] == 0
        and bakedData.pixels["1:0"][2] == 0,
        "voxel model texture bakes its darkest shade")
  check(bakedData.pixels["4:0"][1] == 248 / 255
        and bakedData.pixels["4:0"][2] == 248 / 255,
        "voxel model texture bakes its lightest shade")
  _G.love = oldLove
end

local treeOx, treeOz = VoxAssets.spriteOrigin("crystal_berry_tree", 32, 48)
check(treeOx == 32 and treeOz == 48,
      "VOX sprite replacement keeps the 16x16 sprite centred on its cell")

for _, name in ipairs({
  "crystal_ledge_nw", "crystal_ledge_n", "crystal_ledge_ne",
  "crystal_ledge_w", "crystal_ledge_c", "crystal_ledge_e",
  "crystal_ledge_sw", "crystal_ledge_s", "crystal_ledge_se",
}) do
  local bank = MagicaVoxel.parse(readVox(name .. ".vox"))
  check(bank and bank.sx == 8 and bank.sy == 8 and bank.sz == 8
        and #bank.voxels > 100,
        name .. " is an 8x8x8 dirt-bank piece")
  check(bank.palette[3][1] > bank.palette[3][3]
        and bank.palette[3][4] > 0.9,
        name .. " uses opaque dirt colours")
end

print("magicavoxel tests: PASS")
