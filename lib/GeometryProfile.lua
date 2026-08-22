-- Geometry switches that must be identical in the live VM and worker VMs.
-- main.lua applies BrickProfile only on the main thread, so workers receive
-- this small data snapshot instead of trying to replay the full runtime tune.
local GeometryProfile = {}

local FIELDS = { "ROUND_RING", "HULL_BILLBOARDS", "BILLBOARD_CROSS" }

local function valid(profile)
  return type(profile) == "table"
     and type(profile.ROUND_RING) == "number"
     and profile.ROUND_RING >= 0
     and profile.ROUND_RING % 1 == 0
     and type(profile.HULL_BILLBOARDS) == "boolean"
     and type(profile.BILLBOARD_CROSS) == "boolean"
end

function GeometryProfile.capture(structures)
  local profile = {}
  for _, field in ipairs(FIELDS) do profile[field] = structures[field] end
  assert(valid(profile), "invalid live geometry profile")
  return profile
end

function GeometryProfile.apply(structures, profile)
  if not valid(profile) then return false, "invalid geometry profile" end
  local changed = false
  for _, field in ipairs(FIELDS) do
    if structures[field] ~= profile[field] then changed = true end
    structures[field] = profile[field]
  end
  -- Templates include profile-dependent geometry. A worker normally sees one
  -- profile for its lifetime, but clear all derived state if that ever changes.
  if changed and structures.invalidate then structures.invalidate() end
  return true
end

return GeometryProfile
