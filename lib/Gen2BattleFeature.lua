-- Gold/Silver/Crystal battle bridge.
--
-- Gen 2 owns its battle screen in src/ui/gen2/BattleState.  Keep that state
-- authoritative and put the staged voxel canvas behind its native widescreen
-- draw instead of borrowing the Gen 1 BattleState methods.
local V = ...

local Gen2BattleFeature = {}

local SCREEN_ID = "Gen2BattleState"
local SCREEN_MARKER = "potatoVoxelGen2BattleScreen"
local NATIVE_DRAW_PIC = "potatoVoxelGen2NativeDrawPic"
local UPDATE_MARKER = "potatoVoxelGen2BattleUpdate"
local TEXTURE_W, TEXTURE_H = 160, 144
local unpackValues = table.unpack or unpack

local function pack(...)
  local out = { n = select("#", ...) }
  for i = 1, out.n do out[i] = select(i, ...) end
  return out
end

local function callTrace(overlay, message)
  if overlay and type(overlay.trace) == "function" then overlay.trace(message) end
end

local function sideMetrics(side)
  if side == "player" then
    return 40, 96
  end
  return 124, 56
end

function Gen2BattleFeature.new(ctx)
  ctx = ctx or {}
  local mod = ctx.mod
  local OverworldBattle = ctx.OverworldBattle
  local RuntimeHooks = ctx.RuntimeHooks
  local DebugOverlay = ctx.DebugOverlay
  local installed = {}
  local canvases = setmetatable({}, { __mode = "k" })
  local Chrome = nil

  local feature = {}

  function feature.installEvents()
    if installed.events or not (mod and mod.events and mod.events.on) then
      return false
    end
    mod.events:on("battle.started", function(payload)
      callTrace(DebugOverlay, "event gen2 battle.started")
      if OverworldBattle and OverworldBattle.ensure then
        OverworldBattle.ensure(payload and payload.battle)
      end
    end)
    mod.events:on("battle.ended", function(payload)
      callTrace(DebugOverlay, "event gen2 battle.ended")
      if OverworldBattle and OverworldBattle.finish then
        OverworldBattle.finish(payload and payload.battle)
      end
    end)
    installed.events = true
    return true
  end

  local function activeBattleState(game)
    local stack = game and game.stack
    local top = stack and stack.top and stack:top()
    if top and type(top.drawPic) == "function"
       and type(top.drawWidescreen) == "function" then
      return top
    end
    return nil
  end

  local function updateWrapper(inner)
    return function(self, dt)
      local results = pack(inner(self, dt))
      local state = activeBattleState(self)
      if OverworldBattle and OverworldBattle.update then
        pcall(OverworldBattle.update, dt, state)
      end
      return unpackValues(results, 1, results.n)
    end
  end

  function feature.installUpdate()
    if installed.update or not RuntimeHooks then return false end
    local owner = RuntimeHooks.gameOwner()
    local ok = RuntimeHooks.wrapOnce(owner, "update", UPDATE_MARKER,
      updateWrapper)
    installed.update = ok and true or false
    return ok
  end

  local function canvasFor(state, side)
    if not (love and love.graphics and love.graphics.newCanvas) then
      return nil
    end
    local stateCanvases = canvases[state]
    if not stateCanvases then
      stateCanvases = {}
      canvases[state] = stateCanvases
    end
    if stateCanvases[side] then return stateCanvases[side] end
    local ok, canvas = pcall(love.graphics.newCanvas, TEXTURE_W, TEXTURE_H,
                             { dpiscale = 1 })
    if not ok or not canvas then
      ok, canvas = pcall(love.graphics.newCanvas, TEXTURE_W, TEXTURE_H)
    end
    if not ok or not canvas then return nil end
    if canvas.setFilter then pcall(canvas.setFilter, canvas, "nearest", "nearest") end
    stateCanvases[side] = canvas
    return canvas
  end

  function feature.textureForSide(state, side)
    if not (state and type(state.drawPic) == "function") then return nil end
    local canvas = canvasFor(state, side)
    if not canvas then return nil end
    local back = side == "player"
    local mon = state.battle and state.battle[back and "player" or "enemy"]
    if type(state.activeMon) == "function" then
      local ok, active = pcall(state.activeMon, state, back and "player" or "enemy")
      if ok then mon = active end
    end
    local trainer = (back and state.showPlayerTrainer)
                 or ((not back) and state.showEnemyTrainer)
    local image = (back and state.playerBackImage)
               or ((not back) and state.enemyTrainerImage)
    if not trainer and not mon then return nil end
    if trainer and not image then return nil end
    if back and state.slidingBackpic then return nil end
    if state.picHidden and state.picHidden[back and "player" or "enemy"] then
      return nil
    end
    if type(state.animPicState) == "function" then
      local ok, anim = pcall(state.animPicState, state,
                             back and "player" or "enemy")
      if ok and anim and anim.hidden then return nil end
    end
    if not trainer and mon and type(state.isVanished) == "function"
       and not (state.vanishAnim and state.vanishAnim == state.anim) then
      local ok, vanished = pcall(state.isVanished, mon)
      if ok and vanished then return nil end
    end
    local g = love.graphics
    local drawPic = state[NATIVE_DRAW_PIC] or state.drawPic
    local previous = g.getCanvas and g.getCanvas() or nil
    local ok, err = pcall(function()
      g.push("all")
      g.origin()
      g.setCanvas(canvas)
      g.clear(0, 0, 0, 0)
      g.setBlendMode("alpha")
      g.setColor(1, 1, 1, 1)
      drawPic(state, mon, back)
      g.pop()
    end)
    if not ok then pcall(g.pop) end
    if previous then pcall(g.setCanvas, previous) else pcall(g.setCanvas) end
    if not ok then
      if V.mod and V.mod.log and V.mod.log.warn then
        V.mod.log:warn("Gen2 battle pic capture failed: %s", tostring(err))
      end
      return nil
    end
    local ax, ay = sideMetrics(side)
    return {
      canvas = canvas, ax = ax, ay = ay,
      trainer = trainer and true or false,
      mirror = false,
      captureW = TEXTURE_W, captureH = TEXTURE_H,
    }
  end

  function feature.wrapBattleState(state, nativeDrawWidescreen)
    if not state then return state end
    if state[SCREEN_MARKER] then return state end
    local native = nativeDrawWidescreen or state.drawWidescreen
    if type(native) ~= "function" then return state end
    local suppressNativePics = false
    local nativeDrawPic = state.drawPic
    if type(nativeDrawPic) == "function" then
      state[NATIVE_DRAW_PIC] = nativeDrawPic
      state.drawPic = function(self, mon, back)
        if suppressNativePics then return end
        return nativeDrawPic(self, mon, back)
      end
    end
    state.drawWidescreen = function(self, w, h)
      local shot = OverworldBattle and OverworldBattle.shot
                    and OverworldBattle.shot()
      local canvas = shot and shot.canvas
      if not canvas or not love or not love.graphics then
        return native(self, w, h)
      end
      local g = love.graphics
      local staged = pack(pcall(function()
        local cw, ch = canvas:getDimensions()
        if not (cw and ch and cw > 0 and ch > 0) then
          error("invalid staged battle canvas dimensions", 0)
        end
        g.setColor(1, 1, 1, 1)
        g.draw(canvas, 0, 0, 0, w / cw, h / ch)
      end))
      if not staged[1] then return native(self, w, h) end

      local chromeOk, chrome = pcall(function()
        return Chrome or require("src.ui.gen2.Chrome")
      end)
      if not chromeOk or not chrome then return native(self, w, h) end
      Chrome = chrome
      local oldClear = Chrome.clear
      local oldRectangle = g.rectangle
      Chrome.clear = function() end
      g.rectangle = function(mode, x, y, rw, rh, ...)
        if mode == "fill" and x == 0 and y == 0
           and rw == w and rh == h then
          local r, gr, b, a = g.getColor()
          if r > 0.99 and gr > 0.99 and b > 0.99 and a > 0.99 then
            return
          end
        end
        return oldRectangle(mode, x, y, rw, rh, ...)
      end
      suppressNativePics = true
      local results = pack(pcall(native, self, w, h))
      suppressNativePics = false
      Chrome.clear = oldClear
      g.rectangle = oldRectangle
      if not results[1] then error(results[2], 0) end
      return unpackValues(results, 2, results.n)
    end
    state[SCREEN_MARKER] = true
    return state
  end

  function feature.installScreen()
    if installed.screen or not (mod and mod.content and mod.content.screens
                                and mod.content.screens.register) then
      return false
    end
    local NativeBattleState = require("src.ui.gen2.BattleState")
    mod.content.screens:register(SCREEN_ID, {
      new = function(game, opts)
        local state = NativeBattleState.new(game, opts)
        return feature.wrapBattleState(state, state.drawWidescreen)
      end,
    })
    installed.screen = true
    return true
  end

  function feature.installTextures()
    if installed.textures or not (OverworldBattle
                                  and OverworldBattle.setTextureProvider) then
      return false
    end
    OverworldBattle.setTextureProvider(function(state, side)
      return feature.textureForSide(state, side)
    end)
    installed.textures = true
    return true
  end

  function feature.install()
    feature.installEvents()
    feature.installUpdate()
    feature.installScreen()
    feature.installTextures()
    return feature
  end

  return feature
end

return Gen2BattleFeature
