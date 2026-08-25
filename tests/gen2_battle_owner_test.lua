-- Gen2 battle staging must resolve Game2.world, not the Gen1 Game.overworld.
local calls = { owner = 0, reset = 0 }
local game2 = {}
local world = {
  map = { id = "NEW_BARK_TOWN" },
  player = { cellX = 4, cellY = 4 },
  entities = { "npc" },
  ghosts = { "ghost" },
}
game2.world = world

local arena = {
  map = world.map,
  mid = { 4, 4 },
  player = { 4, 6 },
  enemy = { 4, 2 },
}

local setting = { get = function() return true end }
local V = {
  mod = { log = { warn = function() end } },
  require = function(name)
    if name == "ModSetting" then
      return { new = function() return setting end }
    elseif name == "BattleArena" then
      return { find = function() return arena end }
    elseif name == "BattleCam" then
      return { reset = function() calls.reset = calls.reset + 1 end }
    elseif name == "Voxel3D" then
      return { available = function() return true end }
    elseif name == "RuntimeHooks" then
      return {
        gameOwner = function()
          calls.owner = calls.owner + 1
          return game2
        end,
      }
    end
    return {}
  end,
}

local OverworldBattle = assert(loadfile("lib/OverworldBattle.lua"))(V)
OverworldBattle.ensure({ id = "GEN2_BATTLE" })

assert(calls.owner == 1, "Gen2 staging resolves the active game owner")
assert(calls.reset == 1, "Gen2 staging resets the battle camera")
assert(world.entities[1] == world.player and #world.entities == 1,
       "Gen2 staging culls world entities")
assert(#world.ghosts == 0, "Gen2 staging culls world ghosts")
assert(OverworldBattle.arena() == arena,
       "Gen2 staging records an arena from Game2.world")

print("gen2_battle_owner_test: ok")
