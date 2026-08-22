-- Voxel world mode: the map haze -- the ATMOS row and the per-map lookup
-- over data/voxel_atmos.lua.
--
-- The scene shader's fog path never went away (Voxel3D computes vFog per
-- vertex and mixes toward fogColor); the 1.6.1 removals only pinned the
-- uniform to nil (see the removals ADR). This module answers the one
-- question that pin left open -- does THIS map want a haze, and what is
-- it made of -- so VoxelScene can hand the pass a real record instead.
--
-- Purely presentational, like the profile: an entry changes how a map
-- LOOKS and nothing else.

-- the mod namespace (see main.lua): V.data loads a shipped data file
local V = ...

local ModSetting = V.require("ModSetting")

local MapAtmos = {}

MapAtmos.KEY = "atmos"
MapAtmos.LABEL = "ATMOS"

-- OFF by default, like every costly look-knob this build ships with.
MapAtmos.setting = ModSetting.new(MapAtmos.KEY, MapAtmos.LABEL,
                                   { false, true }, { "OFF", "ON" })

local spec = nil

local function load()
  if spec == nil then
    local ok, s = pcall(V.data, "voxel_atmos")
    spec = (ok and type(s) == "table") and s or false
  end
  return spec or nil
end

-- The fog record VoxelScene should hand the pass for `map`, or nil for
-- clear air: the row off, no profile entry, or a malformed entry (a typo
-- in the data file degrades to no haze, never to a broken uniform).
function MapAtmos.fogFor(map)
  if not MapAtmos.setting:get() then return nil end
  local s = load()
  local entry = s and map and map.id and s[map.id]
  if type(entry) ~= "table" then return nil end
  local color = type(entry.color) == "table" and entry.color or {}
  local function clamp(v, dflt)
    local n = tonumber(v)
    return n and math.max(0, n) or dflt
  end
  return {
    color = { clamp(color[1], 1), clamp(color[2], 1), clamp(color[3], 1) },
    density = clamp(entry.density, 0),
    start = clamp(entry.start, 0),
    heightK = clamp(entry.heightK, 0),
  }
end

-- Drop the cached profile (hot reload, a mod shadowing the data file).
function MapAtmos.invalidate()
  spec = nil
end

return MapAtmos
