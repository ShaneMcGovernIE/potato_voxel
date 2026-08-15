-- PotatoVoxel's dedicated settings submenu.
-- Use the engine's standard four-box OptionRows presentation so this screen
-- matches the main OPTIONS and mod-manager option lists exactly.
local V = ...
local OptionRows = require("src.ui.OptionRows")

local VoxelSettingsMenu = {}
VoxelSettingsMenu.__index = VoxelSettingsMenu
-- This is a dedicated opaque screen, like OptionsMenu/ListMenu: stop drawing
-- the start menu/world beneath it while the submenu is open.
VoxelSettingsMenu.isOpaque = true

local function syncScroll(self)
  self.scroll = OptionRows.clampScroll(self.index, self.scroll or 0,
                                       #self.rows, #self.rows + 1)
end

function VoxelSettingsMenu.new(game, rowsFactory)
  local self = setmetatable({ game = game, rowsFactory = rowsFactory,
                              rows = {}, index = 1, scroll = 0,
                              title = "VOXEL SETTINGS" }, VoxelSettingsMenu)
  self:refresh()
  return self
end

function VoxelSettingsMenu:refresh()
  local previous = self.rows[self.index]
  local previousId = previous and previous.id
  local rows = self.rowsFactory(self.game)
  self.rowDescriptors = rows
  self.rows = rows
  self.index = 1
  if previousId then
    for i, row in ipairs(rows) do
      if row.id == previousId then self.index = i break end
    end
  end
  syncScroll(self)
end

function VoxelSettingsMenu:update(dt)
  local input = self.game.input
  local cancelRow = #self.rows + 1
  if input:wasPressed("up") then
    self.index = self.index > 1 and self.index - 1 or cancelRow
  elseif input:wasPressed("down") then
    self.index = self.index < cancelRow and self.index + 1 or 1
  elseif input:wasPressed("b") or input:wasPressed("start") then
    if self.game.data then
      require("src.core.Sound").play(self.game.data, "Press_AB")
    end
    self.game.stack:pop()
    return
  else
    local row = self.rows[self.index]
    local changed = false
    if input:wasPressed("a") and self.index == cancelRow then
      if self.game.data then
        require("src.core.Sound").play(self.game.data, "Press_AB")
      end
      self.game.stack:pop()
      return
    elseif row and input:wasPressed("a") and row.activate then
      row.activate(self.game)
      changed = true
    elseif row and input:wasPressed("left") and row.step then
      changed = row.step(self.game, -1) and true or false
    elseif row and (input:wasPressed("right") or input:wasPressed("a"))
        and row.step then
      changed = row.step(self.game, 1) and true or false
    end
    if changed and self.game.writeOptions then self.game:writeOptions() end
    if changed then self:refresh() end
  end
  syncScroll(self)
end

function VoxelSettingsMenu:draw()
  OptionRows.draw(self.game, self.rows, self.index, self.scroll or 0,
                  "CANCEL", #self.rows + 1)
end

return VoxelSettingsMenu
