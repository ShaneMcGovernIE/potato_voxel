-- Small install-once primitive for engine method wrappers.
-- Marker ownership stays with the engine object, matching the existing
-- compatibility guards while keeping wrapper setup out of feature modules.
local RuntimeHooks = {}

function RuntimeHooks.gameOwner()
  local ok, GV = pcall(require, "src.core.GameVersion")
  if ok and GV and GV.generation and GV.generation() == 2 then
    local ok2, Game2 = pcall(require, "src.core.Game2")
    if ok2 and type(Game2) == "table" then return Game2 end
  end
  return require("src.core.Game")
end

function RuntimeHooks.optionsMenuOwner()
  local ok, GV = pcall(require, "src.core.GameVersion")
  if ok and GV and GV.generation and GV.generation() == 2 then
    local ok2, Menu = pcall(require, "src.ui.gen2.OptionsMenu")
    if ok2 and type(Menu) == "table" then return Menu end
  end
  return require("src.ui.OptionsMenu")
end

function RuntimeHooks.wrapOnce(owner, method, marker, build)
  if owner[marker] then return false end
  local inner = owner[method]
  if type(inner) ~= "function" then return false end
  owner[method] = build(inner)
  owner[marker] = true
  return true
end

return RuntimeHooks
