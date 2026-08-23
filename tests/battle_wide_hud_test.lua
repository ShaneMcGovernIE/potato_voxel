-- Regression coverage for the WIDE staged-battle HUD seam.
local function check(condition, message)
  if not condition then error(message, 2) end
end

local graphics = { rectangles = 0 }
graphics.setColor = function() end
graphics.rectangle = function()
  graphics.rectangles = graphics.rectangles + 1
end
_G.love = { graphics = graphics }

local setting = {
  get = function() return false end,
  setIndex = function() end,
  setValue = function() end,
}
local V = {
  require = function(name)
    if name == "ModSetting" then return { new = function() return setting end } end
    if name == "BattleScene" then
      return {
        GB_W = 160,
        layoutMetrics = function()
          return {
            surfaceW = 304,
            hud = {
              enemy = { 0, 0, 128, 32 },
              player = { 184, 56, 120, 40 },
            },
          }
        end,
      }
    end
    if name == "Voxel3D" then return { available = function() return false end } end
    return {}
  end,
}

local OverworldBattle = assert(loadfile("lib/OverworldBattle.lua"))(V)
local battle = {
  dramaticShapeShot = {
    layout = {
      surfaceW = 304,
      hud = {
        enemy = { 0, 0, 128, 32 },
        player = { 184, 56, 120, 40 },
      },
    },
  },
  introSlide = 0,
  statusHUDVisible = function() return true end,
  enemy = { fainted = false },
  player = {},
  showEnemyTrainer = false,
  enemySendingOut = false,
  showPlayerBack = false,
  safari = false,
  demo = false,
  introBalls = false,
  growInScale = function() return nil end,
}

OverworldBattle.drawHudPanels(battle)
check(graphics.rectangles == 0,
      "WIDE staged battles do not draw leftover translucent HUD panels")

print("battle_wide_hud_test: ok")
