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

local function generation()
  local ok, GV = pcall(require, "src.core.GameVersion")
  if ok and GV and type(GV.generation) == "function" then
    return tonumber(GV.generation())
  end
  return nil
end

-- Gen 1's Map module answers tileset == "OVERWORLD"; Gold's answers
-- environment TOWN/ROUTE. Callers that hard-require src.world.Map treat
-- every Johto map as indoor.
function RuntimeHooks.worldMapOwner()
  if generation() == 2 then
    local ok, Map = pcall(require, "src.world.gen2.Map")
    if ok and type(Map) == "table" and type(Map.isOutdoor) == "function" then
      return Map
    end
  end
  return require("src.world.Map")
end

function RuntimeHooks.isOutdoor(def)
  if not def then return false end
  local Map = RuntimeHooks.worldMapOwner()
  if type(Map.isOutdoor) ~= "function" then return false end
  return Map.isOutdoor(def) and true or false
end

-- Ring fill: Gen 1 TileRenderer special-cases OVERWORLD trees/water/black;
-- Gold's fills live on BorderFill (TILESET_JOHTO trees $05, water $35).
function RuntimeHooks.borderBlockFor(map)
  if not map then return nil end
  if generation() == 2 then
    local ok, BorderFill = pcall(require, "src.world.gen2.BorderFill")
    if ok and type(BorderFill) == "table"
       and type(BorderFill.fillBlock) == "function" then
      return BorderFill.fillBlock(map.def)
    end
  end
  local TileRenderer = require("src.render.TileRenderer")
  return TileRenderer.borderBlockFor(map)
end

-- Tree hulls only occupy ROUND_RING; the far ring stays empty so a tree
-- wall does not read as a plateau. Gold's default void fill is FADE, so
-- this is trees-mode only, and only outdoors.
function RuntimeHooks.treeVoidFill(map)
  if not (map and map.def) then return false end
  if not RuntimeHooks.isOutdoor(map.def) then return false end
  if generation() == 2 then
    local ok, BorderFill = pcall(require, "src.world.gen2.BorderFill")
    local mode = ok and BorderFill and BorderFill.voidFill or "fade"
    return mode == "trees"
  end
  local TileRenderer = require("src.render.TileRenderer")
  return map.def.tileset == "OVERWORLD"
     and (TileRenderer.voidFill or "trees") == "trees"
end

return RuntimeHooks
