-- Headless MagicaVoxel parse / mesh / replace-degrade tests.
local function check(condition, message)
  if not condition then error(message, 0) end
end

local MagicaVoxel = assert(loadfile("lib/MagicaVoxel.lua"))()
local VoxAssets = assert(loadfile("lib/VoxAssets.lua"))({
  require = function(name)
    if name == "MagicaVoxel" then return MagicaVoxel end
    if name == "Voxel3D" then return {} end
    error("unexpected VoxAssets dependency: " .. tostring(name))
  end,
})

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

local kantoTree = MagicaVoxel.parse(readVox("kanto_tree_small.vox"))
check(kantoTree and kantoTree.sx == 16 and kantoTree.sy == 16
      and kantoTree.sz == 16 and #kantoTree.voxels > 200,
      "Gen1 ordinary Kanto tree uses the Violet/Route 30 short bush model")

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

local verticalFence = MagicaVoxel.parse(readVox("poles_wood_vertical.vox"))
check(verticalFence and verticalFence.sx == 16 and verticalFence.sy == 16
      and verticalFence.sz == 16 and #verticalFence.voxels == 480,
      "Gen1 vertical wooden fence is a 16x16x16 MagicaVoxel model")
local horizontalFence = MagicaVoxel.parse(readVox("poles_wood_horizontal.vox"))
check(horizontalFence and horizontalFence.sx == 16
      and horizontalFence.sy == 16 and horizontalFence.sz == 16
      and #horizontalFence.voxels == 480,
      "Gen1 horizontal wooden fence is a 16x16x16 MagicaVoxel model")
local stonePole = MagicaVoxel.parse(readVox("pole_stone.vox"))
check(stonePole and stonePole.sx == 16 and stonePole.sy == 16
      and stonePole.sz == 16 and #stonePole.voxels == 696,
      "Gen1 stone bollard is a 16x16x16 MagicaVoxel model")
local dayTree = MagicaVoxel.parse(readVox("tree_large_kanto_day.vox"))
check(dayTree and dayTree.sx == 32 and dayTree.sy == 32
      and dayTree.sz == 32 and #dayTree.voxels == 11808,
      "Gen1 Viridian day tree is a 32x32x32 MagicaVoxel model")
local nightTree = MagicaVoxel.parse(readVox("tree_large_kanto_night.vox"))
check(nightTree and nightTree.sx == 32 and nightTree.sy == 32
      and nightTree.sz == 32 and #nightTree.voxels == 11808,
      "Gen1 Viridian night tree is a 32x32x32 MagicaVoxel model")
local dayShape, nightShape = {}, {}
for _, voxel in ipairs(dayTree.voxels) do
  dayShape[voxel.x .. ":" .. voxel.y .. ":" .. voxel.z] = true
end
for _, voxel in ipairs(nightTree.voxels) do
  nightShape[voxel.x .. ":" .. voxel.y .. ":" .. voxel.z] = true
end
for key in pairs(dayShape) do
  check(nightShape[key], "Gen1 Viridian day/night tree geometry matches")
end
for key in pairs(nightShape) do
  check(dayShape[key], "Gen1 Viridian night/day tree geometry matches")
end

local profile = assert(loadfile("data/voxel_heights.lua"))()
local TileShape = assert(loadfile("lib/TileShape.lua"))({
  data = function(name)
    return name == "voxel_heights" and profile or nil
  end,
})
check(type(TileShape.voxAsset) == "function"
  and TileShape.voxAsset("OVERWORLD", "vertical")
          == "poles_wood_horizontal"
      and TileShape.voxAsset("OVERWORLD", "horizontal")
          == "poles_wood_vertical"
      and TileShape.voxTiles("OVERWORLD", "horizontal")
      and TileShape.voxTiles("OVERWORLD", "horizontal")[1] == 57,
      "Gen1 OVERWORLD fence pins select the authored wooden models")
local treeVox, treeOffset = TileShape.cylinderVox("OVERWORLD", 64)
check(type(TileShape.cylinderVox) == "function"
      and TileShape.cylinderVox("OVERWORLD", 42) == "pole_stone"
      and treeVox == "kanto_tree_small"
      and treeOffset == nil
      and profile.tilesets.GYM.can_vox == nil,
      "Gen1 OVERWORLD trees use the short bush VOX without an offset")
check(type(TileShape.canopyVox) == "function"
      and TileShape.canopyVox("FOREST", "day") == "tree_large_kanto_day"
      and TileShape.canopyVox("FOREST", "night") == "tree_large_kanto_day"
      and TileShape.canopyVox("OVERWORLD", "day") == nil,
      "Gen1 FOREST canopy always selects the day tree model")
check(type(TileShape.canopyVoxRotation) == "function"
      and TileShape.canopyVoxRotation("FOREST") == 0,
      "Gen1 FOREST canopy does not yaw in the horizontal plane")
check(type(TileShape.canopyVoxPitch) == "function"
      and TileShape.canopyVoxPitch("FOREST") == -1,
      "Gen1 FOREST canopy pitches its trunk onto the floor")

local pitchedTreeQuad = VoxAssets.place({ {
  { 16, 12, 0 }, { 17, 12, 0 }, { 17, 13, 0 }, { 16, 13, 0 },
} }, 0, 0, 0, 1, 0, 32, 32, -1, 32)
check(pitchedTreeQuad[1][1][2] == 0 and pitchedTreeQuad[1][1][3] == 20,
      "Gen1 Viridian tree vertical rotation puts its trunk on the floor")

local caveEntrance = MagicaVoxel.parse(readVox("crystal_cave_entrance.vox"))
check(caveEntrance and caveEntrance.sx == 16 and caveEntrance.sy == 16
      and caveEntrance.sz == 16 and #caveEntrance.voxels > 500,
      "Crystal cave entrance is a 16x16x16 MagicaVoxel model")
local caveAt = {}
for _, voxel in ipairs(caveEntrance.voxels) do
  caveAt[(voxel.z * 16 + voxel.y) * 16 + voxel.x] = voxel.c
end
local mouthOpen, darkBack = 0, 0
for z = 3, 10 do
  for x = 4, 11 do
    if not caveAt[(z * 16 + 3) * 16 + x] then mouthOpen = mouthOpen + 1 end
    if caveAt[(z * 16 + 0) * 16 + x] == 4 then darkBack = darkBack + 1 end
  end
end
check(mouthOpen >= 48 and darkBack >= 40,
      "Crystal cave entrance has a recessed dark mouth, not a solid cube")
local brightRock = 0
for _, voxel in ipairs(caveEntrance.voxels) do
  if voxel.c == 1 then brightRock = brightRock + 1 end
end
check(brightRock == 0,
      "Crystal cave entrance avoids the pale highlight shade used by grass")

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

local gen2Palettes = {
  bg = {
    [3] = { { 240, 240, 240 }, { 120, 150, 80 }, { 45, 80, 35 }, { 8, 20, 8 } },
    [6] = { { 240, 240, 240 }, { 180, 150, 100 }, { 100, 70, 45 }, { 20, 12, 8 } },
  },
  obj = {
    [7] = { { 240, 240, 240 }, { 90, 160, 70 }, { 35, 90, 25 }, { 8, 20, 8 } },
  },
}
check(VoxAssets.paletteFor(gen2Palettes, "crystal_pine_short")
      == gen2Palettes.bg[3],
      "Gen 2 pine voxels use their Johto BG palette slot")
check(VoxAssets.paletteFor(gen2Palettes, "crystal_cut_tree")
      == gen2Palettes.bg[3],
      "Gen 2 CUT voxels use their Johto BG palette slot")
check(VoxAssets.paletteFor(gen2Palettes, "crystal_ledge_n")
      == gen2Palettes.bg[6],
      "Gen 2 ledge voxels use their BG palette slot")
check(VoxAssets.paletteFor(gen2Palettes, "crystal_berry_tree")
      == gen2Palettes.obj[7],
      "Gen 2 berry voxels use their OBJ palette slot")
local advancedPalettes = {
  world = {
    [1] = { { 240, 240, 240 }, { 180, 180, 180 }, { 90, 90, 90 }, { 20, 20, 20 } },
    [3] = { { 240, 240, 240 }, { 120, 190, 70 }, { 45, 105, 30 }, { 15, 35, 12 } },
    [6] = { { 240, 240, 240 }, { 190, 145, 60 }, { 120, 80, 25 }, { 20, 12, 8 } },
  },
}
check(VoxAssets.paletteFor(advancedPalettes, "poles_wood_vertical")
      == advancedPalettes.world[1],
      "Advanced horizontal fence model uses its tile palette group")
check(VoxAssets.paletteFor(advancedPalettes, "poles_wood_horizontal")
      == advancedPalettes.world[6],
      "Advanced vertical fence model uses its tile palette group")
check(VoxAssets.paletteFor(advancedPalettes, "pole_stone")
      == advancedPalettes.world[1],
      "Advanced stone bollard uses the OVERWORLD tile palette group")
check(VoxAssets.paletteFor(advancedPalettes, "kanto_tree_small")
      == advancedPalettes.world[3],
      "Advanced Kanto tree uses the OVERWORLD tree palette group")
check(VoxAssets.paletteFor(advancedPalettes, "kanto_ledge_13")
      == advancedPalettes.world[1]
      and VoxAssets.paletteFor(advancedPalettes, "kanto_ledge_52")
          == advancedPalettes.world[6]
      and VoxAssets.paletteFor(advancedPalettes, "kanto_ledge_29")
          == advancedPalettes.world[3]
      and VoxAssets.paletteFor(advancedPalettes, "kanto_ledge_39")
          == advancedPalettes.world[6]
      and VoxAssets.paletteFor(advancedPalettes, "kanto_ledge_54")
          == advancedPalettes.world[6]
      and VoxAssets.paletteFor(advancedPalettes, "kanto_ledge_55")
          == advancedPalettes.world[6],
      "Advanced Gen1 ledges follow each source tile palette group")
VoxAssets._resetForTests()
local advancedHorizontal = VoxAssets.load("poles_wood_horizontal")
local advancedVertical = VoxAssets.load("poles_wood_vertical")
local advancedStone = VoxAssets.load("pole_stone")
check(advancedHorizontal and advancedVertical
      and advancedStone
      and advancedHorizontal.row ~= advancedVertical.row
      and advancedStone.row ~= advancedHorizontal.row
      and advancedStone.row ~= advancedVertical.row,
      "Advanced fence models keep separate atlas rows for separate tile groups")
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
  VoxAssets._resetForTests()
  VoxAssets.load("crystal_pine_short")
  check(VoxAssets.texture(gen2Palettes) ~= nil,
        "voxel model texture accepts the live Gen 2 palette bundle")
  check(bakedData.pixels["1:0"][1] == gen2Palettes.bg[3][4][1] / 255
        and bakedData.pixels["1:0"][2] == gen2Palettes.bg[3][4][2] / 255,
        "voxel model texture uses the tree's active Gen 2 palette slot")
  VoxAssets._resetForTests()
  VoxAssets.load("poles_wood_horizontal")
  VoxAssets.load("poles_wood_vertical")
  VoxAssets.load("pole_stone")
  check(VoxAssets.texture(advancedPalettes) ~= nil,
        "voxel model textures accept the Advanced world palette bundle")
  check(bakedData.pixels["9:2"][1] == advancedPalettes.world[6][4][1] / 255
        and bakedData.pixels["9:2"][2] == advancedPalettes.world[6][4][2] / 255
        and bakedData.pixels["9:18"][1] == advancedPalettes.world[1][4][1] / 255,
        "the two fence models bake their distinct Advanced palette groups")
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
