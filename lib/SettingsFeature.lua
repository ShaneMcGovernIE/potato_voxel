-- Owns PotatoVoxel's settings schema and the rows used by its settings menu.
-- The composition root supplies the feature modules and the one dynamic gate;
-- this keeps option policy out of hook registration and rendering setup.
local V = ...

local SettingsFeature = {}

function SettingsFeature.new(ctx)
  local settings = {
    { ctx.QualityMode.renderSetting,
      { "Draws 3D world",
        "small, scales up.",
        "Biggest framerate",
        "lever. The modes",
        "set it; moving",
        "it makes the mode",
        "CUSTOM." },
      full = true },
    { ctx.VoxelGrid.setting,
      { "Wireframe along",
        "every voxel edge." } },
    { ctx.WorldCurve.setting,
      { "Bends the world",
        "down over the",
        "horizon." } },
    { ctx.Water.setting,
      { "Reflects the world",
        "on water. FULL",
        "adds the shore;",
        "SKY is sun and",
        "moon alone." },
      -- Off on Android: the reflective pass's stripes on Mali GPUs are
      -- unresolved, so the row is hidden rather than offered broken.
      when = function() return not ctx.Water.onAndroid() end },
    -- `full` marks a row FULL does not take away. FULL owns the diorama's
    -- own knobs; battle presentation remains independently selectable.
    { ctx.OverworldBattle.setting,
      { "Battles in 3D,",
        "shot over the",
        "shoulder. A stages",
        "on the map, B on",
        "discs in the sky." },
      when = function() return not ctx.VR.enabled() end, full = true },
    { ctx.OverworldBattle.backSetting,
      { "Keep your own mon",
        "on the battle",
        "menu, seen from",
        "behind." },
      when = function()
        return ctx.stagedBattles() and not ctx.VR.enabled()
      end,
      full = true },
    { ctx.DayNight.setting,
      { "Pin the sky to",
        "DAY, NIGHT, DUSK",
        "or DAWN, run it",
        "on CYCLE, or SYNC",
        "to the wall clock." } },
    { ctx.MapAtmos.setting,
      { "Map haze on the",
        "weather maps (the",
        "forest, the caves).",
        "OFF keeps clear",
        "air everywhere." } },
    { ctx.Weather.setting,
      { "Falling rain and",
        "snow on the maps",
        "that have them.",
        "OFF keeps clear",
        "skies everywhere." } },
    -- Hardware-cost controls remain visible under FULL.
    { ctx.AntiAlias.setting,
      { "Smooths 3D edges",
        "by rendering big",
        "and folding down.",
        "2X/4X cost real",
        "fill rate." },
      full = true },
    { ctx.VR.setting,
      { "PCVR through",
        "OpenXR: the map",
        "as a tabletop",
        "model. Windows",
        "runtime needed." },
      when = function() return ctx.VR.supported() end, full = true },
    { ctx.VR.smoothTurn,
      { "Turn smoothly in",
        "VR instead of",
        "45-degree snaps.",
        "OFF until you",
        "have your sea",
        "legs." },
      when = function() return ctx.VR.enabled() end, full = true },
    { ctx.ShadowSettings.enabledSetting,
      { "Real cast shadows",
        "across the map.",
        "OFF is the flat",
        "lit model." },
      full = true },
    { ctx.ShadowSettings.qualitySetting,
      { "Shadow map size",
        "in texels. AUTO",
        "fits the view; a",
        "fixed rung costs",
        "fill rate and RAM." },
      full = true },
    { ctx.DebugOverlay.setting,
      { "Show the debug",
        "panel. OFF hides",
        "it; the background",
        "log still records." } },
    { ctx.DebugOverlay.sendSetting,
      { "Send logs to the",
        "developer over the",
        "internet. OFF stops",
        "all sends." } },
  }

  local feature = { entries = settings }

  -- The mod manager's page uses this same schema. VR rows are omitted when
  -- the permanently removed capability reports unsupported.
  function feature.defineSchema()
    local schema = {}
    for _, entry in ipairs(settings) do
      local vrOnly = entry[1] == ctx.VR.setting
                    or entry[1] == ctx.VR.smoothTurn
      if not vrOnly or ctx.VR.supported() then
        schema[#schema + 1] = entry[1]:schema(entry[2])
      end
    end
    ctx.mod.options:define(schema)
  end

  -- Read live values at send time, matching the rows the menu currently
  -- offers instead of copying values once at boot.
  function feature.settingsSummary()
    local Pipelines = require("src.render.Pipelines")
    local out = { "voxel=" .. tostring(Pipelines.levelLabel("voxel")) }
    for _, entry in ipairs(settings) do
      if not entry.when or entry.when() then
        local setting = entry[1]
        local i = setting:read()
        if not setting:allows(i) then i = 1 end
        out[#out + 1] = tostring(setting.key) .. "="
                        .. tostring(setting.labels[i] or "?")
      end
    end
    return table.concat(out, " ")
  end

  return feature
end

return SettingsFeature
