-- Cache readiness, prebuild actions, and the dedicated settings rows.
-- Cache format and mesh persistence remain in MeshCache; this module owns
-- the player-facing gate and keeps those UI transitions out of main.lua.
local V = ...

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
    local stack = game and game.stack
    local states = stack and stack.states
    if type(states) ~= "table" then return false end
    for _, state in ipairs(states) do
      if type(state) == "table" and state.screenId == "TitleState" then
        return true
      end
    end
    return false
  end

  function feature.isGatePending()
    return feature.pending
  end

  function feature.gate(game)
    ctx.CachePrebuild.refresh(game)
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
          if decision == "cancel" then ctx.CachePrebuild.cancel()
          elseif decision == "start" then ctx.CachePrebuild.start(g)
          elseif decision == "confirm_rebuild" then
            local TextBox = require("src.render.TextBox")
            local ChoiceBox = require("src.ui.ChoiceBox")
            g.stack:push(TextBox.new(g, "REBUILD CACHE?", function()
              g.stack:push(ChoiceBox.new(g, function(yes)
                if yes then ctx.CachePrebuild.start(g) end
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
