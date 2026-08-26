-- Headless regression tests for the palette atlas and the asset revision.
--
-- Both cases below are cache-HIT behaviour: the session that loads a finished
-- cache never meshes a map, so nothing on that path had ever loaded a .vox.
local function check(condition, message)
  if not condition then error(message, 0) end
end

local MagicaVoxel = assert(loadfile("lib/MagicaVoxel.lua"))()

local palette = {}
for i = 1, 256 do palette[i] = { 1, 0, 0, 1 } end
local voxBuffer = MagicaVoxel.encode({
  sx = 1, sy = 1, sz = 1,
  voxels = { { x = 0, y = 0, z = 0, c = 1 } },
  palette = palette,
})

-- One tileset whose canopy art is the same either side of the clock (what
-- every shipped profile does today) and one whose art genuinely differs.
local function profile(nightCanopy)
  return {
    vox = { some_building = "model_a" },
    tilesets = {
      forest = { canopy_vox = { day = "tree_day", night = nightCanopy } },
    },
  }
end

local period = "day"
local reads
local function newVoxAssets(prof)
  reads = 0
  return assert(loadfile("lib/VoxAssets.lua"))({
    require = function(name)
      if name == "MagicaVoxel" then return MagicaVoxel end
      if name == "Voxel3D" then return { FACE_SHADE = {} } end
      if name == "DayNight" then
        return { voxelPeriod = function() return period end }
      end
      error("unexpected VoxAssets dependency: " .. tostring(name))
    end,
    data = function(name)
      check(name == "voxel_heights", "profile is read from voxel_heights")
      return prof
    end,
    read = function()
      reads = reads + 1
      return voxBuffer
    end,
  })
end

-- 1. The atlas populates itself when the cache did the meshing.
do
  local VoxAssets = newVoxAssets(profile("tree_day"))
  check(reads == 0, "a fresh module has read no assets")
  VoxAssets.texture()
  check(reads > 0,
        "texture() loads the profile's assets when nothing has meshed; "
        .. "an empty atlas leaves every authored model untextured (white)")
  check(VoxAssets.paletteRows() >= 1,
        "texture() assigns palette rows without a map ever being meshed")
end

-- 2. The revision follows the art the clock selects, not the clock.
do
  local same = newVoxAssets(profile("tree_day"))
  period = "day"
  local day = same.revision()
  period = "night"
  local night = same.revision()
  check(day == night,
        "day and night that resolve to the same canopy art share a revision")

  local differs = newVoxAssets(profile("tree_night"))
  period = "day"
  local dayArt = differs.revision()
  period = "night"
  local nightArt = differs.revision()
  check(dayArt ~= nightArt,
        "a profile with distinct night canopy art still moves the revision")
end

-- 4. Row assignment survives a profile table rebuilt in another order.
-- The geometry workers do not share the main VM's profile table: it reaches
-- them serialized and re-parsed, which inserts the same keys in a different
-- order. LuaJIT's pairs() follows insertion history, so the sweep walked the
-- names differently in each VM and the same model landed on a different row --
-- the UVs baked into a cached mesh then addressed another model's palette.
--
-- Run against the shipped profile and the shipped assets, because whether two
-- insertion orders actually diverge depends on the real key set.
do
  local shipped = assert(loadfile("data/voxel_heights.lua"))()

  local function iterOrder(t)
    local out = {}
    for key in pairs(t) do out[#out + 1] = key end
    return out
  end

  local function rebuild(vox, order)
    local out = {}
    for _, key in ipairs(order) do out[key] = vox[key] end
    return { vox = out, sprites = shipped.sprites, tilesets = shipped.tilesets,
             buildings = shipped.buildings }
  end

  local walked = iterOrder(shipped.vox)
  local candidates = {}
  local reversed = {}
  for i = #walked, 1, -1 do reversed[#reversed + 1] = walked[i] end
  candidates[#candidates + 1] = reversed
  for shift = 1, #walked - 1 do
    local rotated = {}
    for i = 1, #walked do
      rotated[i] = walked[(i + shift - 1) % #walked + 1]
    end
    candidates[#candidates + 1] = rotated
  end

  local divergent = nil
  local baseline = table.concat(walked, ",")
  for _, order in ipairs(candidates) do
    if table.concat(iterOrder(rebuild(shipped.vox, order).vox), ",")
       ~= baseline then
      divergent = order
      break
    end
  end
  check(divergent ~= nil,
        "no insertion order iterates differently from the shipped profile; "
        .. "this case cannot test what it exists to test")

  local realAssets = {
    read = function(rel)
      local file = io.open(rel, "rb")
      if not file then return nil end
      local buf = file:read("*a")
      file:close()
      return buf
    end,
  }

  local function rowsFor(prof)
    local VoxAssets = assert(loadfile("lib/VoxAssets.lua"))({
      require = function(name)
        if name == "MagicaVoxel" then return MagicaVoxel end
        if name == "Voxel3D" then return { FACE_SHADE = {} } end
        if name == "DayNight" then
          return { voxelPeriod = function() return "day" end }
        end
        error("unexpected VoxAssets dependency: " .. tostring(name))
      end,
      data = function() return prof end,
      read = realAssets.read,
    })
    VoxAssets.preloadProfile()
    local out = {}
    for _, key in ipairs(walked) do
      local model = VoxAssets.load(shipped.vox[key])
      if model then out[shipped.vox[key]] = model.row end
    end
    return out
  end

  local a = rowsFor(shipped)
  local b = rowsFor(rebuild(shipped.vox, divergent))
  local compared = 0
  for name, row in pairs(a) do
    compared = compared + 1
    check(b[name] == row,
          name .. " must land on the same palette row whichever order the "
          .. "profile table was built in: " .. tostring(row) .. " vs "
          .. tostring(b[name]))
  end
  check(compared > 0, "the shipped profile must name at least one asset")
end

-- 3. A model lands on the same palette row however the session reaches it.
-- The geometry workers assign rows through Buildings.build -> preloadProfile()
-- and bake the result into a mesh's UVs. The main VM on a cache hit meshes
-- nothing, so before this fix the first row went to whatever drew first --
-- an overworld sprite replacement, say -- and the cached mesh then read a
-- different model's colours.
do
  local prof = {
    vox = { poles_wood_vertical = "poles_wood_vertical",
            poles_wood_horizontal = "poles_wood_horizontal",
            kanto_tree_small = "kanto_tree_small" },
    sprites = { fruit_tree = "crystal_berry_tree" },
  }

  -- the build path: the profile sweep runs first, as Buildings.build does it
  local swept = newVoxAssets(prof)
  swept.preloadProfile()
  local expected = {}
  for _, name in ipairs({ "poles_wood_vertical", "poles_wood_horizontal",
                          "kanto_tree_small", "crystal_berry_tree" }) do
    expected[name] = assert(swept.load(name)).row
  end

  -- the cache-hit path: a sprite replacement is the first thing to ask
  local drawn = newVoxAssets(prof)
  local first = assert(drawn.load("crystal_berry_tree")).row
  check(first == expected.crystal_berry_tree,
        "a sprite drawn before anything meshes must not claim another "
        .. "model's row (got " .. tostring(first) .. ", cached meshes address "
        .. tostring(expected.crystal_berry_tree) .. ")")
  for name, row in pairs(expected) do
    local got = assert(drawn.load(name)).row
    check(got == row,
          name .. " must land on row " .. tostring(row)
          .. " on the cache-hit path too, got " .. tostring(got))
  end
end

period = "day"
print("vox atlas tests: PASS")
