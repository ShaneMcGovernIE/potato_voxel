-- Voxel world mode: the player's knobs on the shadow map -- whether shadows
-- are on at all, and how fine a shadow map to spend on them.
--
-- The shadow pass (ShadowMap) parameterises the voxel pass: it owns no pass
-- of the frame itself, so the engine's render-pipeline registry would
-- rightly reject it and the knobs are plain mod settings instead (see
-- ModSetting). Both rows -- the one on the OPTIONS menu's VOXEL SETTINGS
-- submenu and the one on the mod manager's page -- read and write the one
-- stored value, so they cannot disagree.
--
--   SHADOWS        ON / OFF. OFF is the flat-lit diorama: no shadow map is
--                  drawn, the main pass is sent sunDark=0, and the contact
--                  blobs under the characters go with it -- nobody is
--                  pasted on, there is simply no sun.
--
--   SHADOW QUALITY AUTO / 512 / 1024 / 2048. The edge of the square shadow
--                  map, in texels. AUTO is the ladder the pass always ran
--                  (ShadowMap.SIZES): the smallest size whose texel stays
--                  under a target slice of a world pixel, capped at 2048. A
--                  fixed rung forces the map's edge whatever the view, which
--                  is the one knob a player can actually see -- bigger maps
--                  resolve finer shadow edges and cost fill rate and RAM (a
--                  2048 edge is a 16MB depth pass, re-rasterised whenever
--                  the shadow signature moves), which is the whole of why
--                  this is a row and not something that is simply on.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local ModSetting = V.require("ModSetting")

local ShadowSettings = {}

-- the keys under options.modOptions.DRAMATIC_SHAPE, shared by the row in
-- OPTIONS and the mod manager's own settings page for this mod
ShadowSettings.KEY = "shadows"
ShadowSettings.LABEL = "SHADOWS"
ShadowSettings.QUALITY_KEY = "shadowQuality"
ShadowSettings.QUALITY_LABEL = "SHADOW QUALITY"

-- ON is the default and the fallback: the mod ships with shadows on, and a
-- fresh or unreadable save reads as ON rather than as a mode with nothing
-- under anybody.
ShadowSettings.enabledSetting = ModSetting.new(
  ShadowSettings.KEY, ShadowSettings.LABEL, { true, false }, { "ON", "OFF" })

-- AUTO (0) is the default and the fallback: the adaptive ladder is what the
-- pass always did, so an unreadable save reads as the behaviour it shipped
-- with rather than as a resolution somebody picked.
ShadowSettings.qualitySetting = ModSetting.new(
  ShadowSettings.QUALITY_KEY, ShadowSettings.QUALITY_LABEL,
  { 0, 512, 1024, 2048 }, { "AUTO", "512", "1024", "2048" })

function ShadowSettings.enabled()
  return ShadowSettings.enabledSetting:get() and true or false
end

-- The fixed edge to force, in texels, or nil for the adaptive ladder.
function ShadowSettings.quality()
  local q = tonumber(ShadowSettings.qualitySetting:get()) or 0
  if q <= 0 then return nil end
  return q
end

return ShadowSettings
