-- Pure regression coverage for the staged battle layout contract.
local function check(condition, message)
  if not condition then error(message, 2) end
end

local function eq(actual, expected, message)
  if actual ~= expected then
    error(('%s (expected %s, got %s)'):format(message, tostring(expected),
                                             tostring(actual)), 2)
  end
end

package.preload["src.render.PaletteFX"] = function()
  return { pal = function(_, name) return "gen1:" .. tostring(name) end }
end
package.preload["src.world.Map"] = function() return {} end

local empty = {}
local V = {
  require = function(name)
    if name == "RuntimeHooks" then
      return { gameOwner = function() return require("src.core.Game") end }
    end
    return empty
  end,
}

local BattleScene = assert(loadfile("lib/BattleScene.lua"))(V)

local function battle(wide, fill, position)
  return {
    uiSize = function()
      return wide and 304 or 160, 144
    end,
    wantsFillScale = function()
      return fill
    end,
    screenPosition = function()
      return position
    end,
  }
end

local og = BattleScene.layoutMetrics(battle(false, false), {
  pw = 1280, ph = 720, dpiX = 1, dpiY = 1,
})
eq(og.surfaceW, 160, "OG layout keeps the classic width")
eq(og.surfaceH, 144, "OG layout keeps the classic height")
eq(og.scale, 5, "OG FIXED uses the largest integer scale")
eq(og.viewportX, 240, "OG FIXED centers horizontally")
eq(og.viewportY, 0, "OG FIXED centers vertically")

local ogOffset = BattleScene.layoutMetrics(battle(false, false, { x = -16, y = 8 }), {
  pw = 1280, ph = 720, dpiX = 1, dpiY = 1,
})
eq(ogOffset.viewportX, 160, "OG offset moves the viewport horizontally")
eq(ogOffset.viewportY, 40, "OG offset moves the viewport vertically")

local wide = BattleScene.layoutMetrics(battle(true, false), {
  pw = 1280, ph = 720, dpiX = 1, dpiY = 1,
})
eq(wide.surfaceW, 304, "WIDE layout uses the widescreen surface")
eq(wide.scale, 4, "WIDE FIXED uses the largest integer scale")
eq(wide.viewportX, 32, "WIDE FIXED centers horizontally")
eq(wide.viewportY, 72, "WIDE FIXED centers vertically")
eq(wide.anchors.player[1], 46, "WIDE player anchor follows the wide field")
eq(wide.anchors.player[2], 104, "WIDE player anchor follows the wide field")
eq(wide.anchors.enemy[1], 260, "WIDE enemy anchor follows the wide field")
eq(wide.anchors.enemy[2], 56, "WIDE enemy anchor follows the wide field")
eq(wide.captureW, 160, "side captures retain their logical width")
eq(wide.captureH, 144, "side captures retain their logical height")
eq(wide.hud.enemy[1], 0, "WIDE enemy HUD follows the wide viewport")
eq(wide.hud.player[1], 184, "WIDE player HUD follows the wide viewport")
eq(wide.scaleMode, "fixed", "FIXED exposes its scale mode")

package.preload["src.core.GameVersion"] = function()
  return { generation = function() return 2 end }
end
local gen2 = BattleScene.layoutMetrics(battle(false, false), {
  pw = 1280, ph = 720, dpiX = 1, dpiY = 1,
})
eq(gen2.anchors.player[1], 40,
   "Gen2 keeps the native 6x6 player-pic anchor")
eq(gen2.anchors.player[2], 96,
   "Gen2 keeps the native player-pic baseline")
eq(gen2.anchors.enemy[1], 124,
   "Gen2 keeps the native 7x7 enemy-pic anchor")
eq(gen2.anchors.enemy[2], 56,
   "Gen2 keeps the native enemy-pic baseline")
package.loaded["src.core.GameVersion"] = nil
package.preload["src.core.GameVersion"] = nil

package.preload["src.core.GameVersion"] = function()
  return { generation = function() return 2 end }
end
package.preload["src.world.gen2.Palettes"] = function()
  return {
    daytimeFor = function(_, hour, flashUsed)
      return flashUsed and "DARK" or (hour >= 18 and "NITE" or "DAY")
    end,
    bgSet = function(_, _, daytime)
      return { { "gen2:" .. daytime } }
    end,
  }
end
package.preload["src.core.Game"] = function()
  return { data = { gen2Palettes = "world-palettes" } }
end
local gen2PaletteState = {
  palettes = "state-palettes",
  daytime = nil,
  tod = "MORN",
  hour = function() return 22 end,
  flashUsed = false,
}
local gen2Palette = BattleScene.paletteFor(gen2PaletteState, { def = "CAVE" })
eq(gen2Palette({ def = "CAVE" })[1], "gen2:MORN",
   "Gen2 battle palette prefers the World daytime/tod state")
gen2PaletteState.daytime = "NITE"
eq(BattleScene.paletteFor(gen2PaletteState, { def = "CAVE" })({ def = "CAVE" })[1],
   "gen2:NITE", "Gen2 battle palette prefers resolved daytime")
package.loaded["src.core.GameVersion"] = nil
package.loaded["src.world.gen2.Palettes"] = nil
package.loaded["src.core.Game"] = nil
package.preload["src.core.GameVersion"] = nil
package.preload["src.world.gen2.Palettes"] = nil
package.preload["src.core.Game"] = function()
  return { data = {} }
end
local gen1PaletteState = {
  paletteNameFor = function() return "ROUTE" end,
}
local gen1Palette = BattleScene.paletteFor(gen1PaletteState, {})
eq(gen1Palette({}), "gen1:ROUTE",
   "Gen1 battle palette keeps the native palette-name path")
package.loaded["src.core.Game"] = nil
package.preload["src.core.Game"] = nil

local fill = BattleScene.layoutMetrics(battle(true, true), {
  pw = 1280, ph = 720, dpiX = 1, dpiY = 1,
})
check(fill.scale > 4 and fill.scale < 5,
      "FILL uses a fractional scale when the window requires it")
eq(fill.scaleMode, "fill", "FILL exposes its scale mode")
eq(fill.fillScale, fill.scale, "FILL exposes its selected scale")
eq(fill.viewportX, 0, "FILL has no horizontal bar when width is limiting")
eq(fill.viewportY, 56, "FILL reports the centered vertical viewport origin")

local offset = BattleScene.layoutMetrics(battle(true, false, { x = 8, y = -4 }), {
  pw = 1280, ph = 720, dpiX = 1, dpiY = 1,
})
eq(offset.viewportX, 64, "screen-position X offset moves the WIDE viewport")
eq(offset.viewportY, 56, "screen-position Y offset moves the WIDE viewport")
eq(offset.offsetX, 8, "layout metrics retain logical X offset")
eq(offset.offsetY, -4, "layout metrics retain logical Y offset")
local mapChanged = battle(true, false, { x = 8, y = -4 })
local beforeMap = BattleScene.layoutMetrics(mapChanged, {
  pw = 1280, ph = 720, dpiX = 1, dpiY = 1,
})
mapChanged.map = { id = "ROUTE_2" }
local afterMap = BattleScene.layoutMetrics(mapChanged, {
  pw = 1280, ph = 720, dpiX = 1, dpiY = 1,
})
eq(afterMap.viewportX, beforeMap.viewportX,
   "map changes do not reset the selected X layout")
eq(afterMap.viewportY, beforeMap.viewportY,
   "map changes do not reset the selected Y layout")

local dpi = BattleScene.layoutMetrics(battle(false, false), {
  pw = 1920, ph = 1080, dpiX = 2, dpiY = 1.5,
})
eq(dpi.dpiX, 2, "layout metrics retain horizontal DPI")
eq(dpi.dpiY, 1.5, "layout metrics retain vertical DPI")
eq(dpi.drawScaleX, dpi.scale / dpi.dpiX,
   "logical X scale is derived from physical scale and DPI")
eq(dpi.drawScaleY, dpi.scale / dpi.dpiY,
   "logical Y scale is derived from physical scale and DPI")

local identity = {
  1, 0, 0, 0,
  0, 1, 0, 0,
  0, 0, 1, 0,
  0, 0, 0, 1,
}
local dx, dy = BattleScene.toGB(identity, 0, 0, 0, dpi)
eq(dx, (0.5 * dpi.pw - dpi.viewportX) / dpi.scale,
   "DPI-aware conversion uses physical X pixels")
eq(dy, (0.5 * dpi.ph - dpi.viewportY) / dpi.scale,
   "DPI-aware conversion uses physical Y pixels")
local x, y = BattleScene.toGB(identity, 0, 0, 0, offset)
eq(x, (0.5 * offset.pw - offset.viewportX) / offset.scale,
   "coordinate conversion uses the selected viewport X")
eq(y, (0.5 * offset.ph - offset.viewportY) / offset.scale,
   "coordinate conversion uses the selected viewport Y")

check(BattleScene.forceOG == nil, "BattleScene does not own a layout override")

local function source(path)
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return text
end

check(not source("lib/SettingsFeature.lua"):find("battleLayout"),
      "settings hook does not remove the engine Battle Layout row")
check(not source("lib/OverworldBattle.lua"):find("forceOG"),
      "staged battle entry has no forced-OG path")
check(not source("main.lua"):find("forceOG"),
      "pipeline updates and presets have no forced-OG path")

print("battle_layout_test: ok")
