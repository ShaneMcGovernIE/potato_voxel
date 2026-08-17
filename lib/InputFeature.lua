-- Keyboard and controller-facing display/input policy for PotatoVoxel.
--
-- The composition root supplies the feature modules and the dynamic battle
-- gate. This module owns the hotkey table, the shared VOXEL ladder step, and
-- the engine keypressed wrapper so input changes stay separate from render,
-- cache, and settings composition.
local V = ...

local RuntimeHooks = V.require("RuntimeHooks")

local InputFeature = {}

function InputFeature.new(ctx)
  local BrickProfile = ctx.BrickProfile
  local Voxel = ctx.Voxel
  local VoxelGrid = ctx.VoxelGrid
  local WorldCurve = ctx.WorldCurve
  local Water = ctx.Water
  local OverworldBattle = ctx.OverworldBattle
  local Horde = ctx.Horde
  local HordeGun = ctx.HordeGun
  local CamControl = ctx.CamControl
  local DebugOverlay = ctx.DebugOverlay
  local ShapeDebug = ctx.ShapeDebug
  local VR = ctx.VR

  -- The build is a single quality ladder, so the keys that cycled the
  -- removed rungs are left alone: 5/7/9 fall through to the engine. Only
  -- 8 stays, stepping OFF -> HIGH -> MEDIUM -> LOW -> POTATO.
  local hotkeys = BrickProfile.isBrick()
    and { ["8"] = "pipeline", ["lshift"] = "pipeline",
          ["rshift"] = "pipeline" }
    or {
      ["8"] = "pipeline",
      ["lshift"] = "pipeline",
      ["rshift"] = "pipeline",
      ["5"] = VoxelGrid.setting,
      ["7"] = WorldCurve.setting,
      ["3"] = OverworldBattle.setting,
      ["9"] = Water.setting,
    }

  -- One step of the VOXEL angle ladder: everything an "8" press does,
  -- named so VR view control can make exactly the same step. The gate is
  -- the registry's own; the tilt/GBC FX clearing is engine work delegated
  -- to the same path as the original wrapper.
  local function cycleVoxel(game)
    local Pipelines = require("src.render.Pipelines")
    if Horde.viewLocked() then return false end
    local top = game.stack and game.stack:top()
    if not Pipelines.canToggle("voxel", top, game.overworld) then
      return false
    end
    Pipelines.setLevel("voxel", Voxel.nextHotkeyLevel(
      Pipelines.level("voxel")))
    Pipelines.syncOptions(game.save.options)
    game.save.options.tilt = 0
    game.save.options.gbcfx = 0
    require("src.render.GBCFX").setLevel(0)
    require("src.render.Tilt").setLevel(game.save.options.tilt or 0)
    game:writeOptions()
    DebugOverlay.trace("voxel level -> %s",
                       tostring(Pipelines.level("voxel")))
    return true
  end

  local feature = {
    hotkeys = hotkeys,
    cycleVoxel = cycleVoxel,
  }

  -- VR's optional view-control path uses the same guarded step as keyboard
  -- input. The façade remains inert in this release, but the public callback
  -- assignment stays where the compatibility contract expects it.
  VR.cycleVoxel = cycleVoxel

  function feature.install()
    local Game = require("src.core.Game")
    local Pipelines = require("src.render.Pipelines")
    RuntimeHooks.wrapOnce(Game, "keypressed",
      "dramaticShapeKeypressedHook", function(inner)
        return function(self, key)
          if Horde.active then
            if key == "r" then
              HordeGun.reload()
              return
            end
            if hotkeys[key] then return end
          end
          local claim = hotkeys[key]
          local top = self.stack and self.stack:top()
          if (key == "q" or key == "e")
             and not (top and top.onKeyPressed) then
            if CamControl.zoomBy(key == "q" and 1 or -1) then return end
          end
          if key == "f9" and not (top and top.onKeyPressed) then
            DebugOverlay.toggle()
            return
          end
          if key == "f10" and not (top and top.onKeyPressed) then
            DebugOverlay.toggleVerbose()
            return
          end
          if key == "f8" and not (top and top.onKeyPressed) then
            DebugOverlay.export(self)
            return
          end
          if key == "f6" and not (top and top.onKeyPressed) then
            ShapeDebug.toggle()
            return
          end
          if claim and not (top and top.onKeyPressed) then
            if claim == "pipeline" then
              if key == "8" or key == "lshift" or key == "rshift" then
                if cycleVoxel(self) then return end
              elseif Pipelines.hotkey(key, top, self.overworld) then
                if cycleVoxel(self) then return end
              end
            elseif Pipelines.canToggle("voxel", top, self.overworld) then
              claim:cycle(self)
              if ctx.stagedBattles() then OverworldBattle.forceOG(self) end
              return
            end
          end
          return inner(self, key)
        end
      end)
  end

  return feature
end

return InputFeature
