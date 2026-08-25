-- Cache readiness, prebuild actions, and the dedicated settings rows.
-- Cache format and mesh persistence remain in MeshCache; this module owns
-- the player-facing gate and keeps those UI transitions out of main.lua.
local V = ...

local RuntimeHooks = V.require("RuntimeHooks")
local CacheFeature = {}

function CacheFeature.new(ctx)
  local feature = { pending = false }

  local function cacheReadyLabel(status)
    if status ~= "READY" then return status end
    local codec = ctx.MeshCache.codec()
    if codec then return "READY " .. codec:upper() end
    local mode = ctx.MeshCache.compressionStatus()
    if mode == "mixed" then return "READY MIX" end
    if mode == "raw" then return "READY RAW" end
    return "READY"
  end

  local function showCacheStatus(game)
    local TextBox = require("src.render.TextBox")
    local status = ctx.CachePrebuild.status()
    local label = status
    if status == "READY" then
      local codec = ctx.MeshCache.codec()
      if codec then
        label = "READY (" .. codec:upper() .. ")"
      else
        local mode = ctx.MeshCache.compressionStatus()
        label = mode == "mixed" and "READY (MIXED)"
                or mode == "raw" and "READY (RAW)"
                or "READY"
      end
    end
    -- The cache lives in the mod's scoped storage (no raw dir exists to
    -- name), so a support report names the store it lives in.
    local backendLabel = ctx.MeshCache.dir() and "STORAGE" or "NONE"
    game.stack:push(TextBox.new(game,
      ("%s\fGEOMETRY %d\fDIR: %s"):format(label,
        ctx.MeshCache.GEOMETRY_VERSION, backendLabel)))
  end

  local function confirmCacheWipe(game)
    local _, _, running = ctx.CachePrebuild.progress()
    local TextBox = require("src.render.TextBox")
    if running then
      game.stack:push(TextBox.new(game, "CANCEL BUILD\nBEFORE WIPING."))
      return
    end
    game.stack:push(TextBox.new(game, "WIPE CACHE?", nil, {
      defaultNo = true,
      choice = function(yes)
        if yes then ctx.CachePrebuild.wipe(game) end
      end,
    }))
  end

  local function atTitle(game)
    if not game then return true end
    -- When the world/overworld is active (Gen 1 or Gen 2), we are in-game
    if (game.world and game.world.map) or (game.overworld and game.overworld.map) then
      return false
    end
    local stack = game.stack
    if not stack then return true end
    local top = stack.top and stack:top()
    if top and type(top) == "table" then
      local id = top.screenId
      if id == "TitleState" or id == "Gen2TitleState"
         or id == "Gen2MainMenu" or id == "MainMenuState" then
        return true
      end
    end
    local states = stack.states
    if type(states) == "table" and #states > 0 then
      local topState = states[#states]
      if topState and type(topState) == "table" then
        local id = topState.screenId
        if id == "TitleState" or id == "Gen2TitleState"
           or id == "Gen2MainMenu" or id == "MainMenuState" then
          return true
        end
      end
    end
    return not (game.world or game.overworld or (game.save and game.save.player))
  end

  function feature.isGatePending()
    return feature.pending
  end

  function feature.gate(game)
    ctx.CachePrebuild.refresh(game)
    -- NEW GAME enters the Gen 2 intro before the world/map instance exists.
    -- Defer the gate until the live world is standing so Crystal can provide
    -- its own map class through the active map rather than a Gold private
    -- require. The per-frame auto-start will pick it up after world creation.
    local world = game and (game.world or game.overworld)
    if not (world and world.map) then return end
    if ctx.CachePrebuild.isReady() or not ctx.CachePrebuild.available() then
      return
    end
    local TextBox = require("src.render.TextBox")
    feature.pending = true
    game.stack:push(TextBox.new(game, "MAP CACHE\nNOT READY.\fBUILD NOW?", nil, {
      defaultNo = true,
      choice = function(yes)
        feature.pending = false
        if yes then
          if ctx.CachePrebuild.start(game) then
            local Progress = V.require("CachePrebuildScreen")
            game.stack:push(Progress.new(game))
          end
        else
          ctx.CachePrebuild.decline()
        end
      end,
    }))
  end

  function feature.installLifecycle()
    local Game = RuntimeHooks.gameOwner()
    if type(Game.continueGame) == "function" then
      RuntimeHooks.wrapOnce(Game, "continueGame", "dramaticShapeCacheGateContinueHook",
        function(inner)
          return function(self, ...)
            inner(self, ...)
            feature.gate(self)
          end
        end)
    end
    if type(Game.newGame) == "function" then
      RuntimeHooks.wrapOnce(Game, "newGame", "dramaticShapeCacheGateNewGameHook",
        function(inner)
          return function(self, ...)
            inner(self, ...)
            feature.gate(self)
          end
        end)
    end
    RuntimeHooks.wrapOnce(Game, "restoreSave", "dramaticShapeCacheGateHook",
      function(restoreSave)
        RuntimeHooks.wrapOnce(Game, "makeTitleState",
          "dramaticShapeCacheGateTitleHook", function(makeTitleState)
            return function(self)
              local title = makeTitleState(self)
              local onNewGame = title.onNewGame
              title.onNewGame = function()
                onNewGame()
                feature.gate(self)
              end
              return title
            end
          end)
        return function(self, loaded, recovered)
          restoreSave(self, loaded, recovered)
          feature.gate(self)
        end
      end)
  end

  function feature.rows(game)
    local Pipelines = require("src.render.Pipelines")
    local rows = {}
    for _, row in ipairs(Pipelines.rows(game)) do rows[#rows + 1] = row end
    for _, entry in ipairs(ctx.settingsEntries) do
      if not entry.when or entry.when() then
        rows[#rows + 1] = entry[1]:row()
      end
    end
    -- The prebuild row is an in-game action: it builds against the save's
    -- live options and needs a playthrough's storage. The title screen's
    -- OPTIONS menu has neither, so the row is not offered there.
    if not atTitle(game) then
      rows[#rows + 1] = {
        id = "potato_voxel:prebuild",
        label = "PREBUILD CACHE",
        value = function() return ctx.CachePrebuild.status() end,
        activate = function(g)
          local status = ctx.CachePrebuild.status()
          local _, _, running = ctx.CachePrebuild.progress()
          local decision = ctx.CachePrebuild.activationDecision(status, running)
          if decision == "cancel" then
            ctx.CachePrebuild.cancel()
          elseif decision == "start" then
            if ctx.CachePrebuild.start(g) then
              local Progress = V.require("CachePrebuildScreen")
              g.stack:push(Progress.new(g))
            end
          elseif decision == "confirm_rebuild" then
            local TextBox = require("src.render.TextBox")
            local ChoiceBox = require("src.ui.ChoiceBox")
            g.stack:push(TextBox.new(g, "REBUILD CACHE?", function()
              g.stack:push(ChoiceBox.new(g, function(yes)
                if yes then
                  if ctx.CachePrebuild.rebuild(g) then
                    local Progress = V.require("CachePrebuildScreen")
                    g.stack:push(Progress.new(g))
                  end
                end
              end, { defaultNo = true }))
            end))
          end
        end,
      }
    end
    rows[#rows + 1] = {
      id = "potato_voxel:player_id",
      label = "PLAYER ID",
      value = function() return ctx.PlayerId.get() or "--------" end,
      activate = function() end,
    }
    rows[#rows + 1] = {
      id = "potato_voxel:cache_status",
      label = "CACHE STATUS",
      value = function()
        local status = ctx.CachePrebuild.status()
        return status == "READY"
               and cacheReadyLabel(status)
               or ("GEO %d"):format(ctx.MeshCache.GEOMETRY_VERSION)
      end,
      activate = showCacheStatus,
    }
    rows[#rows + 1] = {
      id = "potato_voxel:wipe_cache",
      label = "WIPE CACHE",
      value = function() return "DELETE" end,
      activate = confirmCacheWipe,
    }
    rows[#rows + 1] = {
      id = "potato_voxel:send_logs",
      label = "SEND LOGS",
      value = function() return "SEND" end,
      activate = function(g)
        ctx.DebugOverlay.export(g)
      end,
    }
    return rows
  end

  return feature
end

return CacheFeature
