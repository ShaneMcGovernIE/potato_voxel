-- Gen 2 cache/runtime ownership contracts.
-- This test is deliberately independent of a LÖVE window: the engine injects
-- the live game through mod.game while the metatable remains the hook owner.

local function check(condition, message)
  if not condition then error(message or "assertion failed", 2) end
end

local versions = { "gold", "silver", "crystal" }
local live = {}
local owner = { update = function() end }
owner.__index = owner
setmetatable(live, owner)

package.loaded["src.core.GameVersion"] = {
  generation = function() return 2 end,
  get = function() return "gold" end,
}

local V = {
  mod = { game = live },
  require = function(name)
    error("unexpected mod dependency: " .. tostring(name))
  end,
}

local RuntimeHooks = assert(loadfile("lib/RuntimeHooks.lua"))(V)
check(RuntimeHooks.liveGame() == live,
      "Gen 2 liveGame must return mod.game, not the Game2 class")
check(RuntimeHooks.gameOwner() == owner,
      "gameOwner must remain the class/metatable used for method wrapping")

for _, version in ipairs(versions) do
  package.loaded["src.core.GameVersion"].get = function() return version end
  check(RuntimeHooks.liveGame() == live,
        version .. " must resolve the injected live game")
end

-- Older boot order: before API 2 injects mod.game, the hook owner may still
-- be available as the class module. This must never be used as live state.
local fallbackOwner = { update = function() end }
package.loaded["src.core.Game2"] = fallbackOwner
V.mod.game = nil
check(RuntimeHooks.liveGame() == nil,
      "Gen 2 must not expose the Game2 class as live state")
check(RuntimeHooks.gameOwner() == fallbackOwner,
      "Gen 2 bootstrap fallback must still find the Game2 hook owner")

print("gen2 runtime owner tests: PASS")
