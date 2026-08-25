package.path = "./?.lua;./?/init.lua;" .. package.path

local chunk, err = loadfile("lib/Gen2BattleFeature.lua")
assert(chunk, err)
local Feature = chunk({})
assert(type(Feature.new) == "function", "Gen2 feature exposes new")

package.preload["src.core.GameVersion"] = function()
  return { generation = function() return 2 end }
end

local events = {}
local spriteHooks = 0
local mod = {
  events = {
    on = function(_, name, fn) events[name] = fn end,
  },
  hooks = {
    wrap = function() spriteHooks = spriteHooks + 1 end,
  },
  content = {
    screens = {
      register = function(_, id, record)
        events.screenId, events.screen = id, record
      end,
    },
  },
}

local calls = { ensure = 0, finish = 0, update = 0, native = 0,
                setProvider = 0, pics = {}, background = 0,
                clear = 0, rectangle = 0, nativePics = 0 }
local battle = { id = "GEN2_TEST_BATTLE" }
local owner = {
  update = function(_, dt)
    calls.native = calls.native + 1
    return "native", dt
  end,
}
local runtimeHooks = {
  gameOwner = function() return owner end,
  wrapOnce = function(target, method, marker, build)
    assert(not target[marker], "update wrapper installs once")
    target[method] = build(target[method])
    target[marker] = true
    return true
  end,
}
local feature = Feature.new({
  mod = mod,
  OverworldBattle = {
    ensure = function(value)
      calls.ensure = calls.ensure + 1
      assert(value == battle, "battle.started passes the battle")
    end,
    finish = function()
      calls.finish = calls.finish + 1
    end,
    update = function()
      calls.update = calls.update + 1
    end,
    shot = function() return calls.shot end,
    setTextureProvider = function(provider)
      calls.setProvider = calls.setProvider + 1
      calls.provider = provider
    end,
  },
  RuntimeHooks = runtimeHooks,
  DebugOverlay = { trace = function() end },
})

assert(type(feature.installEvents) == "function", "feature installs events")
assert(type(feature.installUpdate) == "function", "feature installs update")
assert(type(feature.installScreen) == "function", "feature installs screen")
assert(type(feature.wrapBattleState) == "function", "feature wraps battle state")
feature.installEvents()
assert(spriteHooks == 0, "Gen2 keeps native pokemon sprite paths authoritative")
assert(type(events["battle.started"]) == "function", "started handler registered")
assert(type(events["battle.ended"]) == "function", "ended handler registered")
events["battle.started"]({ battle = battle })
events["battle.ended"]({ battle = battle })
assert(calls.ensure == 1, "started handler stages one battle")
assert(calls.finish == 1, "ended handler finishes one battle")

feature.installUpdate()
local result, dt = owner:update(0.25)
assert(result == "native" and dt == 0.25, "update return values survive wrapping")
assert(calls.native == 1 and calls.update == 1,
       "native update and staged battle update each run once")

package.preload["src.ui.gen2.BattleState"] = function()
  return {
      new = function()
        return {
          drawPic = function() calls.nativePics = calls.nativePics + 1 end,
          drawWidescreen = function(self, w, h)
            calls.native = calls.native + 1
            if love then
              local Chrome = require("src.ui.gen2.Chrome")
              Chrome.clear()
              love.graphics.rectangle("fill", 0, 0, w, h)
              self:drawPic(nil, false)
            end
          return self
        end,
      }
    end,
  }
end
local canvas = {
  getDimensions = function() return 160, 144 end,
  setFilter = function() end,
}
package.preload["src.ui.gen2.Chrome"] = function()
  return { clear = function() calls.clear = calls.clear + 1 end }
end
feature.installScreen()
assert(events.screenId == "Gen2BattleState", "Gen2 screen is registered")
local screen = events.screen.new({}, {})

feature.installTextures()
assert(calls.setProvider == 1 and type(calls.provider) == "function",
       "Gen2 texture provider is installed")

local g = {
  newCanvas = function() return canvas end,
  getCanvas = function() return nil end,
  setCanvas = function() end,
  push = function() end,
  pop = function() end,
  origin = function() end,
  clear = function() end,
  setBlendMode = function() end,
  setColor = function() end,
  getColor = function() return 1, 1, 1, 1 end,
  draw = function() calls.background = calls.background + 1 end,
  rectangle = function() calls.rectangle = calls.rectangle + 1 end,
}
_G.love = { graphics = g }
calls.shot = { canvas = canvas }
assert(screen:drawWidescreen(160, 144) == screen,
       "screen wrapper preserves native draw")
assert(calls.background == 1 and calls.clear == 0 and calls.rectangle == 0,
       "staged canvas replaces only the native opaque background")
assert(calls.nativePics == 0,
       "staged Gen2 screen does not draw a duplicate flat pic layer")
local state = {
  battle = { player = { species = "P" }, enemy = { species = "E" } },
  activeMon = function(self, side) return self.battle[side] end,
  drawPic = function(_, mon, back)
    calls.pics[#calls.pics + 1] = { mon = mon, back = back }
  end,
}
local playerTexture = feature.textureForSide(state, "player")
local enemyTexture = feature.textureForSide(state, "enemy")
assert(playerTexture.ax == 40 and playerTexture.ay == 96,
       "player texture uses the Gen2 back-pic anchor")
assert(playerTexture.mirror == false,
       "native Gen2 back art is not mirrored in the 3D scene")
assert(enemyTexture.ax == 124 and enemyTexture.ay == 56,
       "enemy texture uses the Gen2 front-pic anchor")
assert(calls.pics[1].back == true and calls.pics[2].back == false,
       "native Gen2 drawPic receives side orientation")

local playerState = {
  battle = { player = { species = "P" } },
  playerBackImage = {},
  showPlayerTrainer = false,
  picHidden = { player = true },
  drawPic = state.drawPic,
}
assert(feature.textureForSide(playerState, "player") == nil,
       "hidden native Gen2 pics do not create billboard descriptors")

local fallbackCanvas = {
  getDimensions = function() error("canvas failed") end,
}
calls.shot = { canvas = fallbackCanvas }
local beforeNative = calls.native
assert(screen:drawWidescreen(160, 144) == screen,
       "screen wrapper falls back to native draw when staging fails")
assert(calls.native == beforeNative + 1,
       "native draw runs after a staging failure")
assert(calls.nativePics == 1,
       "native pic layer returns when staging falls back")

print("gen2_battle_feature_test: ok")
