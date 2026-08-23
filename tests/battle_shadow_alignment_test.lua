-- Regression coverage for the ordinary staged-battle shadow controls.
local function check(condition, message)
  if not condition then error(message, 2) end
end

local file = assert(io.open("lib/BattleScene.lua", "r"))
local source = file:read("*a")
file:close()

check(source:find("BrickProfile.battleActorShadowMap%(VoxelState.level%)"),
      "staged battles retain the selected actor-shadow profile")
check(source:find("local battleShadows = ShadowSettings.enabled%(%)"),
      "staged battles retain the selected shadow setting")
check(not source:find("battleActorShadowMode"),
      "no forced actor-shadow override remains")
check(not source:find("battleShadowsEnabled"),
      "no forced global shadow override remains")

print("battle_shadow_alignment_test: ok")
