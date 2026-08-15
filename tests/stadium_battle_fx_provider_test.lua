-- Standalone contract test for optional StadiumBattleFX arena registration.
local expectedOwner = "potato_voxel"
local fallback = {}
local registered
local calls = {}
local OverworldBattle = {
  providerAvailable = function(battle)
    calls.available = battle
    return battle == "battle"
  end,
  arena = function() return { id = "map-arena" } end,
  providerBegin = function(battle)
    calls.begin = battle
    return battle == "battle"
  end,
  providerRender = function(battle, drawActors)
    calls.render = battle
    drawActors({ vp = {}, groundY = 7, width = 160, height = 144 })
    return "canvas"
  end,
  providerFinish = function() calls.finished = true end,
}
local api = {
  version = 1,
  FALLBACK = fallback,
  registerComponent = function(_, owner, slot, id, definition)
    registered = { owner, slot, id, definition }
    return owner .. ":" .. id
  end,
}
local V = {
  mod = {
    id = expectedOwner,
    find = function(id)
      if id == "STADIUM_BATTLE_FX" then
        return { exports = { battles = api } }
      end
    end,
    log = { warn = function() error("registration should not warn") end },
  },
  require = function(name)
    assert(name == "OverworldBattle")
    return OverworldBattle
  end,
}

for _, path in ipairs({
  "lib/BattleScene.lua",
  "lib/OverworldBattle.lua",
  "lib/StadiumBattleFxProvider.lua",
  "main.lua",
}) do
  assert(loadfile(path), path .. " must compile")
end

local Provider = assert(loadfile("lib/StadiumBattleFxProvider.lua"))(V)
assert(Provider.register() == true)
assert(Provider.register() == true, "registration must be idempotent")
assert(registered[1] == expectedOwner and registered[2] == "arena"
  and registered[3] == "voxel-map")
local definition = registered[4]
assert(definition.available({ battle = "battle" }) == true)
assert(definition.available({ battle = "other" }) == false)
assert(definition.provider == Provider)
assert(Provider:arena({ battle = "other" }) == fallback)
assert(Provider:arena({ battle = "battle" }).id == "map-arena")
assert(Provider:begin({ battle = "battle" }) == true)
local drew
assert(Provider:render({ battle = "battle" }, {}, function(world)
  drew = world.groundY == 7 and world.width == 160 and world.height == 144
end) == "canvas")
assert(drew == true and calls.render == "battle")
Provider:finish()
assert(calls.finished == true)
print("ok StadiumBattleFX voxel-map arena provider " .. expectedOwner)
