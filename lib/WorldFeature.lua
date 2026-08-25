-- World render feature owned by the voxel pipeline.
--
-- The composition root still registers the engine pipeline and owns update
-- order. This module owns drawWorld's scene-size, loading, fallback, scale,
-- overlay, and presentation policy so render edits do not spread through
-- settings, cache, or input wiring.
local V = ...

local Voxel3D = V.require("Voxel3D")
local Stereoscopic3D = V.require("Stereoscopic3D")
local VoxelState = V.require("VoxelState")
local VR = V.require("VR")
local VoxelScene = V.require("VoxelScene")
local ChunkMesher = V.require("ChunkMesher")
local VoxelLoading = V.require("VoxelLoading")
local RuntimeHooks = V.require("RuntimeHooks")
local BrickProfile = V.require("BrickProfile")
local AntiAlias = V.require("AntiAlias")
local Upscale = V.require("Upscale")
local Weather = V.require("Weather")
local Diagnostics = V.require("DiagnosticsBridge")

local WorldFeature = {}
WorldFeature.STALL_FRAME = 0.25
WorldFeature.STALL_TRIGGER = 2
WorldFeature.STALL_MAX_FRAMES = 4
WorldFeature.LOADING_TIMEOUT = 25

local pendingRefresh = {}

function WorldFeature.queueBlockRefresh(mapId)
  if not mapId then return end
  pendingRefresh[mapId] = true
end

function WorldFeature.flushBlockRefresh()
  if not next(pendingRefresh) then return end
  local batch = pendingRefresh
  pendingRefresh = {}
  for mapId in pairs(batch) do
    ChunkMesher.refresh(mapId)
  end
end

function WorldFeature.updateStall(dt, stallSkip)
  -- While actively skipping frames, preserve the armed state so the
  -- full skip window completes before voxel re-engages.  The fast 2D
  -- fallback frames during a skip are not evidence of GPU recovery --
  -- resetting here caused a single-frame oscillation loop (BUG-3).
  if stallSkip.frames > 0 then return end
  stallSkip.count = dt > WorldFeature.STALL_FRAME
    and (stallSkip.count + 1) or 0
  if stallSkip.count == 0 then stallSkip.frames = 0 end
end

function WorldFeature.installLoadingGuard()
  local OverworldController = require("src.world.OverworldController")
  RuntimeHooks.wrapOnce(OverworldController, "update",
    "potatoVoxelLoadingHook", function(inner)
      return function(self, dt)
        if VoxelState.loading then return end
        return inner(self, dt)
      end
    end)
end

function WorldFeature.installMapHooks(ctx)
  local mod = ctx.mod
  local DebugOverlay = ctx.DebugOverlay

  mod.events:on("world.block_replaced", function(payload)
    local mapId = payload and (payload.mapId
                  or (payload.map and payload.map.id))
    DebugOverlay.trace("event block_replaced %s", tostring(mapId))
    if mapId then WorldFeature.queueBlockRefresh(mapId) end
  end)

  local Map = RuntimeHooks.worldMapOwner()
  RuntimeHooks.wrapOnce(Map, "setBlock", "dramaticShapeBlockHook",
    function(setBlock)
      return function(self, bx, by, block)
        local before = self:blockAt(bx, by)
        setBlock(self, bx, by, block)
        if self.id and self:blockAt(bx, by) ~= before then
          WorldFeature.queueBlockRefresh(self.id)
        end
      end
    end)

  mod.events:on("map.reloaded", function(payload)
    DebugOverlay.event("map.reloaded", {
      mapId = payload and payload.mapId,
      reason = payload and payload.reason,
    })
    DebugOverlay.trace("event map.reloaded %s (%s)",
                       tostring(payload and payload.mapId),
                       tostring(payload and payload.reason))
    if payload and payload.reason == "colors" then return end
    local mapId = payload and (payload.mapId
                  or (payload.map and payload.map.id))
    if mapId then ChunkMesher.invalidate(mapId) end
  end)

  mod.events:on("map.entered", function(payload)
    DebugOverlay.event("map.entered", {
      mapId = payload and (payload.mapId or payload.id),
    })
    DebugOverlay.trace("event map.entered %s",
                       tostring(payload and (payload.mapId or payload.id)))
  end)
end

local function sceneSize(ctx)
  if love.graphics and love.graphics.getPixelDimensions then
    local pw, ph = love.graphics.getPixelDimensions()
    if pw and ph and pw > 0 and ph > 0 then return pw, ph end
  end
  return ctx.width, ctx.height
end

function WorldFeature.render(ctx, worldDiag, stallSkip)
  WorldFeature.flushBlockRefresh()
  Diagnostics.pipelinePath("entered")
  if not ctx.state then
    Diagnostics.pipelinePath("no_state")
    Diagnostics.error("drawWorld: no world state to draw")
    return nil
  end
  if not Voxel3D.available() then
    local caps = Voxel3D.diagnostics()
    Diagnostics.pipelinePath("unavailable", caps)
    Diagnostics.error("drawWorld: 3D unavailable (%s): %s",
                       tostring(caps.reason), tostring(caps.error or ""))
    return nil
  end

  -- The palette closure is stashed for the optional VR frame, which renders
  -- from the update hook where no pipeline context exists.
  VR.paletteFor = ctx.paletteFor
  if VR.active() then
    local sw, sh = sceneSize(ctx)
    local mirror = VR.mirror(sw, sh)
    if mirror then
      Diagnostics.pipelinePath("rendered", { path = "vr_mirror" })
      return mirror
    end
  end

  local sw, sh = sceneSize(ctx)
  if VoxelState.loading then
    local now = love and love.timer and love.timer.getTime
               and love.timer.getTime() or 0
    local pendingNow = ChunkMesher.pending()
    if worldDiag.loadingEntered == 0 then
      worldDiag.loadingEntered = now
      worldDiag.loadingReported = false
      worldDiag.loadingPending = pendingNow
      Diagnostics.note("drawWorld: loading canvas (%d pending)", pendingNow)
    elseif not worldDiag.loadingReported and now > 0
           and now - worldDiag.loadingEntered > WorldFeature.LOADING_TIMEOUT then
      if pendingNow >= worldDiag.loadingPending then
        worldDiag.loadingReported = true
        Diagnostics.error("drawWorld: stuck loading %.0fs (%d pending)",
                          now - worldDiag.loadingEntered, pendingNow)
      else
        worldDiag.loadingEntered = now
        worldDiag.loadingPending = pendingNow
      end
    end
    Diagnostics.pipelinePath("loading", { pending = ChunkMesher.pending() })
    return VoxelLoading.draw(sw, sh, ChunkMesher.pending())
  end

  worldDiag.loadingEntered = 0
  worldDiag.loadingReported = false
  if worldDiag.firstRender and stallSkip.count >= WorldFeature.STALL_TRIGGER then
    if stallSkip.frames < WorldFeature.STALL_MAX_FRAMES then
      stallSkip.frames = stallSkip.frames + 1
      Diagnostics.pipelinePath("stall_skip", { frames = stallSkip.frames })
      return nil
    end
    stallSkip.frames, stallSkip.count = 0, 0
  end

  local rw, rh = AntiAlias.expand(sw, sh)
  local rs = BrickProfile.renderScale()
  local crw = math.max(1, math.floor(rw * rs + 0.5))
  local crh = math.max(1, math.floor(rh * rs + 0.5))
  local wcam = ctx.state and ctx.state.camera
  if wcam then
    Weather.update(ctx.state.map, wcam.x + ctx.vw / 2,
                   wcam.y + ctx.vh / 2, ctx.vw, ctx.vh)
  end
  local stereo = Stereoscopic3D.enabled()
  local eyeSpec
  if stereo then
    eyeSpec = Stereoscopic3D.spec("world")
    eyeSpec.overlay = function()
      if Voxel3D.beginOverlay(true) then
        ctx.drawFx(function(wx, wy) return Voxel3D.project(wx, 0, wy) end,
                   ctx.scale * AntiAlias.factor() * rs)
        Weather.draw(ctx.scale * AntiAlias.factor() * rs, Voxel3D.project)
        Voxel3D.endOverlay(true)
      end
    end
  end
  local t0 = love and love.timer and love.timer.getTime
            and love.timer.getTime() or 0
  local rendered = VoxelScene.render(ctx.state, crw, crh,
                                     ctx.vw, ctx.vh, ctx.paletteFor,
                                     eyeSpec)
  local renderMs = nil
  if love and love.timer and love.timer.getTime then
    renderMs = (love.timer.getTime() - t0) * 1000
  end
  if not rendered then
    local reason = Voxel3D.beginFailure or "scene returned no canvas"
    Diagnostics.pipelinePath("fallback", { reason = reason })
    Diagnostics.error("drawWorld: scene returned no canvas (2D fallback): %s",
                      reason)
  end
  if not worldDiag.firstRender and rendered then
    worldDiag.firstRender = true
    Diagnostics.note("drawWorld: first scene render (%.0fms)", renderMs or 0)
  end
  if not rendered then return nil end

  local canvas
  if stereo and type(rendered) == "table" and rendered[1] and rendered[2] then
    local left, right = rendered[1], rendered[2]
    if rs < 1 then
      left = Upscale.apply(left, sw, sh, "stereo-world-left")
      right = Upscale.apply(right, sw, sh, "stereo-world-right")
    else
      left = AntiAlias.resolve(left, sw, sh, "stereo-world-left")
      right = AntiAlias.resolve(right, sw, sh, "stereo-world-right")
    end
    canvas = Stereoscopic3D.composite(left, right, sw, sh)
    if not canvas then
      local stereoDiag = Stereoscopic3D.diagnostics()
      Diagnostics.note("stereo compositor fallback: %s",
                       tostring(stereoDiag.reason or "unavailable"))
      canvas = left
    end
  else
    canvas = rendered
    if Voxel3D.beginOverlay() then
      ctx.drawFx(function(wx, wy) return Voxel3D.project(wx, 0, wy) end,
                 ctx.scale * AntiAlias.factor() * rs)
      Weather.draw(ctx.scale * AntiAlias.factor() * rs, Voxel3D.project)
      Voxel3D.endOverlay()
    end
    if rs < 1 then
      canvas = Upscale.apply(canvas, sw, sh, "world")
    else
      canvas = AntiAlias.resolve(canvas, sw, sh, "world")
    end
  end
  Diagnostics.pipelinePath("rendered", {
    width = crw, height = crh, renderMs = renderMs,
  })
  return canvas, renderMs
end

return WorldFeature
