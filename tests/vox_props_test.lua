-- Authored .vox props: the MagicaVoxel reader, the shade snap onto the
-- map's own four colours, and the stamp into a map's object stream.
local script = debug.getinfo(1, "S").source:gsub("^@", "")
local root = script:match("^(.*)[/\\]tests[/\\][^/\\]+$") or "."

local checks, failures = 0, 0
local function check(cond, name)
  checks = checks + 1
  if not cond then
    failures = failures + 1
    print("FAIL " .. name)
  end
end
local function eq(got, want, name)
  check(got == want, name .. " (got " .. tostring(got)
        .. ", want " .. tostring(want) .. ")")
end

local libs = {}
local V = {
  path = root,
  mod = {
    read = function(_, rel)
      local f = io.open(root .. "/" .. rel, "rb")
      if not f then return nil end
      local body = f:read("*a")
      f:close()
      return body
    end,
  },
}
function V.require(name)
  if libs[name] then return libs[name] end
  libs[name] = assert(loadfile(root .. "/lib/" .. name .. ".lua"))(V)
  return libs[name]
end
local dataFiles = {}
function V.data(name)
  if dataFiles[name] == nil then
    dataFiles[name] = assert(loadfile(root .. "/data/" .. name .. ".lua"))(V)
  end
  return dataFiles[name]
end

local VoxLoader = V.require("VoxLoader")
local VoxProps = V.require("VoxProps")
local GridKey = V.require("GridKey")

-- ---- reader

check(VoxLoader.parse("not a vox file at all") == nil, "rejects non-vox input")
check(VoxLoader.parse("") == nil, "rejects empty input")
check(VoxLoader.parse("VOX ") == nil, "rejects a header with no model")

local raw = V.mod:read("models/HarborTruck.vox")
check(raw ~= nil, "the shipped model is readable")
local vox = assert(VoxLoader.parse(raw))
eq(vox.w, 32, "model width")
eq(vox.d, 16, "model depth")
eq(vox.h, 16, "model height")
eq(#vox.voxels % 4, 0, "voxel records are 4 bytes")
eq(#vox.voxels / 4, 3420, "voxel count")
check(vox.palette and vox.palette[1] and #vox.palette[1] == 4,
      "palette entries are rgba")

local seen = {}
for i = 4, #vox.voxels, 4 do seen[vox.voxels[i]] = true end
local used = 0
for _ in pairs(seen) do used = used + 1 end
check(used > 0 and used <= 256, "voxels reference real palette indices")

-- ---- placement

-- Four shade bands across the atlas, so every GB shade has a texel to
-- claim and a snapped model can find all four.
local atlas = { getPixel = function(_, _, y)
  local v = ({ 0.0, 0.35, 0.7, 1.0 })[(math.floor(y / 2) % 4) + 1]
  return v, v, v, 1
end }

local function dockMap()
  return { tileset = { id = "SHIP_PORT", imageWidth = 128, imageHeight = 48,
                       tilesPerRow = 16 },
           def = { width = 14, height = 6 } }
end

local function plant(S, rows, tx, ty)
  for r = 1, #rows do
    for c = 1, #rows[r] do
      S.tileAt[GridKey.of(tx + c - 1, ty + r - 1)] = rows[r][c]
    end
  end
end

local props = V.data("vox_props")
local truck = props.SHIP_PORT[1]
check(truck and truck.model == "HarborTruck", "the dock truck is authored")

local function build(tx, ty)
  VoxProps.invalidate()
  local S = { shapeAt = {}, tileAt = {}, skip = {}, ground = {},
              objectQuads = {} }
  plant(S, truck.tiles, tx, ty)
  VoxProps.build(S, dockMap(), atlas, 16)
  return S
end

local S = build(40, 0)
local stats = VoxProps.stats()
eq(stats.models, 1, "one model built")
eq(stats.placements, 1, "one placement stamped")
check(stats.quads > 0 and stats.quads < #vox.voxels,
      "merged runs cost fewer quads than voxels")

local claimed = 0
for _ in pairs(S.skip) do claimed = claimed + 1 end
eq(claimed, 8, "the drawing's own tiles are claimed")
for r = 0, 1 do
  for c = 0, 3 do
    local shape = S.shapeAt[GridKey.of(40 + c, r)]
    check(shape and shape.authored, "claimed tiles carry an authored shape")
  end
end

local x0, x1, y0, y1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge,
                               math.huge, -math.huge
for _, q in ipairs(S.objectQuads) do
  check(q.own == true, "prop quads are body-anchored")
  check(q.u and q.v and q.shade, "prop quads carry an atlas texel and a shade")
  for i = 1, 4 do
    x0 = math.min(x0, q[i][1]) x1 = math.max(x1, q[i][1])
    y0 = math.min(y0, q[i][2]) y1 = math.max(y1, q[i][2])
    z0 = math.min(z0, q[i][3]) z1 = math.max(z1, q[i][3])
  end
end
eq(x0, 320, "model starts at the anchor tile")
eq(x1 - x0, 32, "model spans its own width")
eq(z0, 0, "model starts at the anchor row")
check(z1 - z0 <= 16, "model stays inside its footprint depth")
eq(y0, 0, "model stands on the ground")
check(y1 > 0 and y1 <= 16, "model rises to its own height")

-- Every quad samples one of the four swatches the drawing supplied.
local swatchU = {}
for _, q in ipairs(S.objectQuads) do swatchU[q.u .. ":" .. q.v] = true end
local distinct = 0
for _ in pairs(swatchU) do distinct = distinct + 1 end
check(distinct >= 2 and distinct <= 4,
      "snapped colour lands on the GB shades (got " .. distinct .. ")")

-- A model is meshed once and reused wherever its drawing occurs.
VoxProps.invalidate()
local twice = { shapeAt = {}, tileAt = {}, skip = {}, ground = {},
                objectQuads = {} }
plant(twice, truck.tiles, 40, 0)
plant(twice, truck.tiles, 8, 8)
VoxProps.build(twice, dockMap(), atlas, 16)
local two = VoxProps.stats()
eq(two.models, 1, "one mesh for both placements")
eq(two.placements, 2, "both placements stamped")

-- An already-claimed cell is never stamped over.
VoxProps.invalidate()
local taken = { shapeAt = {}, tileAt = {}, skip = {}, ground = {},
                objectQuads = {} }
plant(taken, truck.tiles, 40, 0)
taken.skip[GridKey.of(41, 0)] = true
VoxProps.build(taken, dockMap(), atlas, 16)
eq(VoxProps.stats().placements, 0, "a claimed cell blocks the stamp")
eq(#taken.objectQuads, 0, "nothing is emitted over a claim")

-- flipX mirrors the model across its own footprint.
local function profile(prop)
  VoxProps.invalidate()
  local st = { shapeAt = {}, tileAt = {}, skip = {}, ground = {},
               objectQuads = {} }
  plant(st, truck.tiles, 40, 0)
  local map = dockMap()
  local saved = props.SHIP_PORT[1]
  props.SHIP_PORT[1] = prop
  VoxProps.build(st, map, atlas, 16)
  props.SHIP_PORT[1] = saved
  local low, high = 0, 0
  for _, q in ipairs(st.objectQuads) do
    for i = 1, 4 do
      if q[i][1] < 336 then low = low + 1 else high = high + 1 end
    end
  end
  return low, high
end

local plainLow = profile({ model = truck.model, tiles = truck.tiles })
local flipLow = profile({ model = truck.model, tiles = truck.tiles,
                          flipX = true })
check(plainLow ~= flipLow, "flipX mirrors the model")

-- A model the mod does not ship is skipped, not fatal.
VoxProps.invalidate()
local missing = { shapeAt = {}, tileAt = {}, skip = {}, ground = {},
                  objectQuads = {} }
plant(missing, truck.tiles, 40, 0)
local saved = props.SHIP_PORT[1]
props.SHIP_PORT[1] = { model = "NoSuchModel", tiles = truck.tiles }
local ok = pcall(VoxProps.build, missing, dockMap(), atlas, 16)
props.SHIP_PORT[1] = saved
check(ok, "a missing model does not throw")
eq(#missing.objectQuads, 0, "a missing model emits nothing")

print(string.format("%d/%d checks passed, %d FAILURES  (vox props)",
                    checks - failures, checks, failures))
os.exit(failures == 0 and 0 or 1)
