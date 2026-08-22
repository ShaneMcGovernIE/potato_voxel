-- VR: removed from this release.
--
-- The OpenXR loader, the GL interop and the headset rig all rode the
-- native-interop and filesystem surfaces the mod sandbox removed -- and
-- the loader was never shipped in this build (see the README). What remains is the stub the rest of the mod already knows
-- how to talk to: supported() answers false, so the VR row and the
-- SMOOTH TURN row never appear on any menu, every `when` gate that
-- reads VR.enabled() is always false, and the flat screen behaves
-- exactly as it did before VR existed. The pipeline's update hook keeps
-- calling the same no-op methods, so nothing else in main.lua changes.
-- Reinstating VR needs an engine-sanctioned path to native interop --
-- see docs/adr/0004-feature-removals.md.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local ModSetting = V.require("ModSetting")

local VR = {}

-- the row: plain OFF/ON. Kept as a row even though supported() is false,
-- because main.lua's schema and hotkey tables reference it and because a
-- save that stored vr=true must read back cleanly (the row simply never
-- shows anywhere).
VR.setting = ModSetting.new("vr", "VR", { false, true }, { "OFF", "ON" })

VR.smoothTurn = ModSetting.new("smoothturn", "SMOOTH TURN",
                               { false, true }, { "OFF", "ON" })

VR.SMOOTH_TURN_RATE = 2.2

-- Whether this platform can do VR AT ALL. Always false here: the loader
-- and interop are gone (see the header). Every menu gate in main.lua
-- keys on this, so the VR rows do not exist anywhere.
function VR.supported()
  return false
end

function VR.enabled()
  return false
end

function VR.active()
  return false
end

-- The pipeline's update hook calls these unconditionally; each is a
-- no-op while no session can exist.
function VR.update(dt)
end

-- drawWorld asks for the window mirror when a headset is live; never
-- is, so this never answers.
function VR.mirror(sw, sh)
  return nil
end

function VR.invalidate()
end

-- main.lua assigns these fields; nothing here reads them.
VR.paletteFor = nil
VR.cycleVoxel = nil

return VR
