-- Small blocking progress screen used before Continue/New Game.
local V = ...
local Font = require("src.render.Font")
local PaletteFX = require("src.render.PaletteFX")
local Prebuild = V.require("CachePrebuild")

local Screen = {}
Screen.__index = Screen
Screen.isOpaque = true

function Screen.new(game, onDone, onCancel)
  return setmetatable({ game = game, onDone = onDone, onCancel = onCancel }, Screen)
end

function Screen:sgbPalettes(game)
  return PaletteFX.wholeNamed(game.data, "MEWMON")
end

function Screen:back()
  self.game.stack:pop()
  if self.onCancel then self.onCancel() end
end

function Screen:update()
  local input = self.game.input
  local _, _, running = Prebuild.progress()
  if running then
    if input:wasPressed("a") or input:wasPressed("b") then
      Prebuild.cancel()
      self:back()
    end
    return
  end

  if input:wasPressed("a") then
    if Prebuild.isReady() then
      self.game.stack:pop()
      if self.onDone then self.onDone() end
    else
      self:back()
    end
  elseif input:wasPressed("b") or input:wasPressed("start") then
    self:back()
  end
end

function Screen:draw()
  local done, total, running = Prebuild.progress()
  local status = Prebuild.status()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  Font.drawBox(1, 3, 18, 10)
  love.graphics.setColor(0, 0, 0, 1)
  Font.draw("MAP CACHE", 16, 40)
  if running then
    Font.draw(("BUILD %d/%d"):format(done, total), 16, 64)
    Font.draw("A/B: CANCEL", 16, 88)
  elseif status == "READY" then
    Font.draw("CACHE READY", 16, 64)
    Font.draw("A: CONTINUE", 16, 88)
  else
    Font.draw(status, 16, 64)
    Font.draw("A/B: BACK", 16, 88)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return Screen
