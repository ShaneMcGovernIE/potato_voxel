-- Owns PotatoVoxel's settings schema and the rows used by its settings menu.
-- The composition root supplies the feature modules and the one dynamic gate;
-- this keeps option policy out of hook registration and rendering setup.
local V = ...

local RuntimeHooks = V.require("RuntimeHooks")
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
      { "Capture and show",
        "the debug panel.",
        "OFF disables the",
        "background log." } },
    { ctx.DebugOverlay.sendSetting,
      { "Send logs to the",
        "developer over the",
        "internet. OFF blocks",
        "manual sends." } },
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

  function feature.installMenuRefresh()
    local OptionsMenu = require("src.ui.OptionsMenu")
    local Pipelines = require("src.render.Pipelines")
    RuntimeHooks.wrapOnce(OptionsMenu, "update", "dramaticShapeFullHook",
      function(inner)
        local function idAt(menu, index)
          local row = menu.rows and menu.rows[index or 1]
          return type(row) == "table" and row.id or nil
        end

        return function(self, dt)
          local before = Pipelines.level("voxel")
          local hadBattles = ctx.OverworldBattle.enabled()
          local hadVR = ctx.VR.enabled()
          local wasOn = idAt(self, self.index)
          inner(self, dt)
          local after = Pipelines.level("voxel")
          local crossedFull = after ~= before
                              and (ctx.Voxel.isFull(before)
                                   or ctx.Voxel.isFull(after))
          if crossedFull
             or ctx.OverworldBattle.enabled() ~= hadBattles
             or ctx.VR.enabled() ~= hadVR then
            local rebuilt = OptionsMenu.new(self.game)
            self.rows = rebuilt.rows
            for i = 1, #self.rows do
              if wasOn and idAt(self, i) == wasOn then
                self.index = i
                break
              end
            end
            local cancel = #self.rows + 1
            if (self.index or 1) > cancel then self.index = cancel end
          end
        end
      end)
  end

  function feature.installRowsHook(options)
    local Cache = options.Cache
    local deferToNextTick = options.deferToNextTick
    local OverworldBattle = ctx.OverworldBattle
    local DebugOverlay = ctx.DebugOverlay

    local function dropRow(rows, id)
      for i = #rows, 1, -1 do
        if type(rows[i]) == "table" and rows[i].id == id then
          table.remove(rows, i)
        end
      end
      return rows
    end

    function feature.pinEngineFx(game)
      game = game or require("src.core.Game")
      local opts = game and game.save and game.save.options
      local Tilt = require("src.render.Tilt")
      local GBCFX = require("src.render.GBCFX")
      local changed = false
      if opts then
        changed = (opts.tilt or 0) ~= 0
                    or (opts.gbcfx or 0) ~= 0
                    or (opts.battleBg or "white") ~= "white"
        opts.tilt, opts.gbcfx = 0, 0
        opts.battleBg = "white"
      end
      pcall(Tilt.setLevel, 0)
      pcall(GBCFX.setLevel, 0)
      if changed and game.writeOptions then
        deferToNextTick(function() pcall(game.writeOptions, game) end)
      end
    end

    local function voxelSettingsRows(game)
      return Cache.rows(game)
    end

    ctx.mod.hooks:wrap("ui.options.rows", function(next, game, rows)
      local out = next(game, rows)
      if type(out) ~= "table" then return out end
      feature.pinEngineFx(game)
      dropRow(out, "tilt")
      dropRow(out, "gbcfx")
      dropRow(out, "battleBg")
      if ctx.stagedBattles() then
        OverworldBattle.forceOG(game)
        dropRow(out, "battleLayout")
      end
      for i = #out, 1, -1 do
        local id = type(out[i]) == "table" and out[i].id or ""
        id = id or ""
        if id == "pipeline:voxel"
           or id:find("^potato_voxel:") then table.remove(out, i) end
      end
      out[#out + 1] = {
        id = "potato_voxel:settings", label = "VOXEL SETTINGS",
        value = function() return "OPEN" end,
        activate = function(g)
          require("src.ui.Screens").push(g, "PotatoVoxelSettings")
        end,
      }
      return out
    end)

    ctx.mod.content.screens:register("PotatoVoxelSettings", {
      new = function(game)
        return V.require("VoxelSettingsMenu").new(game, voxelSettingsRows)
      end,
    })
  end

  return feature
end

return SettingsFeature
