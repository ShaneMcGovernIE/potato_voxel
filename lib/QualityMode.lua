-- Voxel world mode: the quality-mode preset system.
--
-- The VOXEL rung is a MODE, not just a camera angle. Selecting HIGH, MEDIUM,
-- LOW or POTATO applies that mode's tuned defaults to every quality knob in
-- the VOXEL SETTINGS menu -- WATER, FOREST FX, AA, V-CURVE, V-GRID, 3D-BTL,
-- SHADOWS, SHADOW QUALITY and the new RENDER SCALE -- so a mode is a
-- one-stop tuning instead of a list of knobs to assemble by hand.
--
-- Touch any of those knobs afterwards and the mode is no longer that
-- preset: the VOXEL row reads CUSTOM, and it stays there until the player
-- picks a named mode again (which re-applies that mode's defaults). OFF and
-- CUSTOM never apply anything -- CUSTOM is the player's own combination.
--
-- RENDER SCALE is its own knob precisely because it is the single biggest
-- frame-budget lever: the presets write it, the player can move it on its
-- own (flipping the mode to CUSTOM), and the scene and battle passes read
-- it directly instead of deriving it from the VOXEL rung.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local ModSetting = V.require("ModSetting")
local Water = V.require("Water")
local AntiAlias = V.require("AntiAlias")
local WorldCurve = V.require("WorldCurve")
local VoxelGrid = V.require("VoxelGrid")
local OverworldBattle = V.require("OverworldBattle")
local ShadowSettings = V.require("ShadowSettings")

local QualityMode = {}

-- the key under options.modOptions.DRAMATIC_SHAPE, shared by the row in
-- OPTIONS and the mod manager's own settings page for this mod
QualityMode.KEY = "renderScale"
QualityMode.LABEL = "RENDER SCALE"

-- The fraction of the window resolution the voxel scene renders at, as a
-- percent ladder. 100% is the default -- the same "renders at the window's
-- own resolution" HIGH shipped with -- so a fresh install behaves exactly
-- as the plain build did.
QualityMode.renderSetting = ModSetting.new(
  QualityMode.KEY, QualityMode.LABEL,
  { 100, 75, 50, 33 }, { "100%", "75%", "50%", "33%" })

-- The VOXEL rung that means "the player's own combination". It is the last
-- rung of the ladder BrickProfile builds (OFF / HIGH / MEDIUM / LOW /
-- POTATO / CUSTOM); kept here rather than derived so a future ladder change
-- is a one-line fix instead of a hunt.
QualityMode.CUSTOM_LEVEL = 5

-- Per-mode tuned defaults, keyed by VOXEL level (1=HIGH .. 4=POTATO). Each
-- value is what the row's stored value should be. A value the platform
-- cannot offer (FOREST FX FULL on Android, say) falls back to the ladder's
-- first rung at apply time and still counts as "matching" -- see
-- valueMatches -- so the mode never flips to CUSTOM over a knob the device
-- physically cannot raise.
QualityMode.PRESETS = {
  [1] = { render = 100, water = "full", aa = 2,
          curve = 1, grid = true, btl = true,
          shadows = true, shadowQuality = 0 },
  [2] = { render = 75, water = "sky", aa = 0,
          curve = 0, grid = false, btl = true,
          shadows = true, shadowQuality = 0 },
  [3] = { render = 50, water = "off", aa = 0,
          curve = 0, grid = false, btl = false,
          shadows = true, shadowQuality = 512 },
  [4] = { render = 33, water = "off", aa = 0,
          curve = 0, grid = false, btl = false,
          shadows = true, shadowQuality = 512 },
}

-- The fraction the scene and battle passes should render at: the RENDER
-- SCALE knob, as a multiplier.
function QualityMode.renderFraction()
  return (QualityMode.renderSetting:get() or 100) / 100
end

-- Apply a named mode's preset to every quality knob. `game` is optional --
-- nil updates only the live values (tests, boot); a game persists each.
function QualityMode.applyMode(level, game)
  local p = QualityMode.PRESETS[level]
  if not p then return end
  QualityMode.renderSetting:setValue(p.render, game)
  Water.setting:setValue(p.water, game)
  AntiAlias.setting:setValue(p.aa, game)
  WorldCurve.setting:setValue(p.curve, game)
  VoxelGrid.setting:setValue(p.grid, game)
  OverworldBattle.setting:setValue(p.btl, game)
  ShadowSettings.enabledSetting:setValue(p.shadows, game)
  ShadowSettings.qualitySetting:setValue(p.shadowQuality, game)
end

-- Whether `got` is the preset value `want`. A want the ladder cannot
-- offer is satisfied by the ladder's fallback -- that first rung IS the
-- preset's best offer on this device -- while a want the ladder CAN offer
-- is a real mismatch whenever `got` differs.
local function valueMatches(setting, want)
  local got = setting:get()
  if got == want then return true end
  for _, opt in ipairs(setting.values) do
    if opt == want then return false end
  end
  return got == setting.values[1]
end

-- Whether the current settings are exactly a named mode's preset. Only
-- ever asked of levels that HAVE a preset (1..4); anything else matches.
function QualityMode.matches(level)
  local p = QualityMode.PRESETS[level]
  if not p then return true end
  return valueMatches(QualityMode.renderSetting, p.render)
     and valueMatches(Water.setting, p.water)
     and valueMatches(AntiAlias.setting, p.aa)
     and valueMatches(WorldCurve.setting, p.curve)
     and valueMatches(VoxelGrid.setting, p.grid)
     and valueMatches(OverworldBattle.setting, p.btl)
     and valueMatches(ShadowSettings.enabledSetting, p.shadows)
     and valueMatches(ShadowSettings.qualitySetting, p.shadowQuality)
end

-- Called from the voxel pipeline's update on the live VOXEL level. Applies
-- the preset when the player LANDS on a named mode; OFF and CUSTOM apply
-- nothing. The first call just records the boot level -- a persisted mode
-- must not re-apply its defaults over whatever the player left them as.
local lastLevel
function QualityMode.onLevel(level)
  if lastLevel == nil then
    lastLevel = level
    return
  end
  if level == lastLevel then return end
  lastLevel = level
  if level >= 1 and level <= 4 then
    QualityMode.applyMode(level, require("src.core.Game"))
  end
end

-- Called from the voxel pipeline's update, after onLevel. A named mode
-- whose settings no longer match its preset is no longer that mode: the
-- VOXEL rung becomes CUSTOM. The check runs every frame and catches every
-- source of a knob change (menu rows, the manager page, a hotkey), so it
-- is the one enforcement point.
function QualityMode.enforce(level)
  if level < 1 or level > 4 then return end
  if QualityMode.matches(level) then return end
  local Pipelines = require("src.render.Pipelines")
  Pipelines.setLevel("voxel", QualityMode.CUSTOM_LEVEL)
  local Game = require("src.core.Game")
  if Game and Game.save and Game.save.options then
    Pipelines.syncOptions(Game.save.options)
  end
  if Game and Game.writeOptions then pcall(Game.writeOptions, Game) end
end

return QualityMode
