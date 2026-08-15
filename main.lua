-- PotatoVoxel (fork of Dramatic Shape Voxel Mod): a full 3D diorama
-- overworld, shipped as a rendering pipeline mod.
--
-- The engine's render_pipelines registry (src/mods/Schemas.lua) lets a mod
-- own part of the frame.  This mod registers one:
--
--   voxel      a drawWorld pipeline.  Instead of the flat tile blit, the
--              overworld's terrain is extruded into real geometry, walked
--              by a depth-buffered 3D camera, with characters as leaning
--              sprite slabs and a shadow map throwing real cast shadows
--              across whatever they land on.  Occlusion is the depth
--              buffer, not a y-sort: walk behind a building and the
--              building is simply in front.
--
-- Everything a display mode needs beyond the draw function -- the
-- OFF/HIGH/MEDIUM/LOW/POTATO/CUSTOM quality ladder, the options rows, the
-- hotkey, persistence in save.options.pipelines, the mutual exclusion
-- with the engine's TILT mode -- is engine plumbing driven by the records
-- below.  This file declares; lib/ draws.
--
-- Voxel mode is presentational: it changes what the world LOOKS like and
-- nothing about what it IS. The free-roam camera rigs (lib/FirstPerson,
-- lib/ThirdPerson, lib/FreeMove) are retained for the VR restore path and
-- are inert on this build, where no rung selects them.

local mod = ...

-- ------- the mod namespace
--
-- lib/ modules require each other through V rather than package.path: a
-- mod directory is not on it, and may live inside a mounted .love archive
-- that plain require cannot reach.  Each module is loaded once, with V
-- passed in as its vararg (`local V = ...`).

local V = { mod = mod, path = mod.path }

local function chunkFor(rel)
  local source = mod:read(rel)
  if not source then
    error(("potato_voxel: %s is missing -- reinstall the mod"):format(rel), 0)
  end
  local chunk, err = load(source, "@" .. mod.path .. "/" .. rel)
  if not chunk then
    error(("potato_voxel: %s did not compile: %s"):format(rel, tostring(err)), 0)
  end
  return chunk
end

local modules = {}
function V.require(name)
  local hit = modules[name]
  if hit ~= nil then return hit end
  local value = chunkFor("lib/" .. name .. ".lua")(V)
  modules[name] = value
  return value
end

local dataFiles = {}
function V.data(name)
  local hit = dataFiles[name]
  if hit ~= nil then return hit end
  local value = chunkFor("data/" .. name .. ".lua")(V)
  dataFiles[name] = value
  return value
end

-- ------- pipelines

local Voxel = V.require("VoxelState")
local Voxel3D = V.require("Voxel3D")
local VoxelScene = V.require("VoxelScene")
local ChunkMesher = V.require("ChunkMesher")
local OverworldBattle = V.require("OverworldBattle")
local StadiumBattleFxProvider = V.require("StadiumBattleFxProvider")
local BattleExit = V.require("BattleExit")
local DayNight = V.require("DayNight")
local DayTint = V.require("DayTint")
local ForestAtmos = V.require("ForestAtmos")
local AntiAlias = V.require("AntiAlias")
local QualityMode = V.require("QualityMode")
local Upscale = V.require("Upscale")
local FirstPerson = V.require("FirstPerson")
local FreeMove = V.require("FreeMove")
local CamControl = V.require("CamControl")
local VR = V.require("VR")
-- the realtime diagnostics panel; see the module for how it arms Perf and
-- what it draws. Benchmark drivers can arm it through the module API.
local DebugHud = V.require("DebugHud")
local CachePrebuild = V.require("CachePrebuild")
local VoxelLoading = V.require("VoxelLoading")
local publishedLoading

mod.events:on("mods.loaded", function()
  StadiumBattleFxProvider.register()
end)

local function publishLoading()
  local loading = Voxel.loading == true
  if publishedLoading == loading then return end
  publishedLoading = loading
  mod.events:emit("mod.potato_voxel.loading_changed", {
    loading = loading,
    mapId = Voxel.loadingMap,
  })
end

mod.exports.isLoading = function()
  return Voxel.loading == true, Voxel.loadingMap
end

-- The runtime tuner (lib/BrickProfile.lua): the low-end tuning this build
-- ships with, applied unconditionally on every device -- there is one build
-- and this is it. Its apply() must run before the pipeline registrations
-- below -- the voxel pipeline and the rows hook capture the ladders by
-- reference, and apply mutates those tables in place.
local BrickProfile = V.require("BrickProfile")
BrickProfile.apply(V)

-- The settings surface (lib/VoxelSettings.lua): the manager-page schema,
-- the VOXEL SETTINGS submenu's rows, the OPTIONS rows hook and the
-- options_changed follow-up. Required after apply() so the row table
-- captures the pinned ladders.
local VoxelSettings = V.require("VoxelSettings")

-- Forward declaration: the voxel pipeline's update hook (registered below)
-- calls this, and it is defined further down with the settings it drives.
-- Declared rather than left global -- a mod writing to _G would leak into
-- every other mod's namespace.
local applyFull

-- The last VOID FILL the terrain was meshed under; see the update hook.
-- The scene canvas's size, in FRAMEBUFFER PIXELS.
--
-- `ctx.width/height` are the window measured in LOVE UNITS
-- (love.graphics.getDimensions), but the engine composites a pipeline's
-- returned canvas with `draw(canvas, 0, 0, 0, 1/dpiX, 1/dpiY)` -- a scale
-- that only covers the window when the canvas is at PIXEL resolution.
-- Sizing it in units costs the DPI scale TWICE: the canvas is that much
-- smaller, then it is drawn that much smaller again, so the diorama lands
-- in the top-left corner at 1/dpi of the screen.  Desktop never sees it --
-- units and pixels are the same thing there -- but on Android the DPI scale
-- is the display density (2.625 on a 420dpi panel), and the world came out
-- a third of the size in each direction.
--
-- So ask for the pixel dimensions rather than trusting the ctx.  That is
-- the number a fixed engine would hand over, so this keeps working either
-- way instead of double-correcting.  It also squares the FX pass: ctx.scale
-- is ALREADY in pixels per world pixel (Zoom.scale over Renderer:fitScale,
-- which measures the drawable), so the closures ctx.drawFx runs were being
-- scaled for a canvas 2.6x bigger than the one they drew into.
local function sceneSize(ctx)
  if love.graphics and love.graphics.getPixelDimensions then
    local pw, ph = love.graphics.getPixelDimensions()
    if pw and ph and pw > 0 and ph > 0 then return pw, ph end
  end
  return ctx.width, ctx.height
end

local voidFill = { last = nil }
-- Called after the engine applies a save's options (Game:applyOptions):
-- the fill that just landed IS the save's declared value, so the change
-- detector is re-seeded instead of treating the boot/load transition as
-- a user edit. The game.ready-time cache check runs under the skeleton
-- save's defaults, and CONTINUE then applies the real slot options -- the
-- old code read that as a VOID FILL change and invalidated the manifest,
-- which is why the title gate asked to rebuild on every single launch
-- even though the cache matched the save exactly (F1). A real change
-- still invalidates: the OPTIONS row calls setVoidFill directly, never
-- applyOptions, so check() catches it on the next tick.
function voidFill.reseed()
  local TileRenderer = require("src.render.TileRenderer")
  voidFill.last = TileRenderer.voidFill
end
function voidFill.check()
  local TileRenderer = require("src.render.TileRenderer")
  local now = TileRenderer.voidFill
  if voidFill.last ~= nil and now ~= voidFill.last then
    ChunkMesher.invalidate()   -- no map id: every ring on every map is stale
  end
  voidFill.last = now
end

do
  local Game = require("src.core.Game")
  if not Game.dramaticShapeApplyOptionsHook then
    local applyOptions = Game.applyOptions
    function Game:applyOptions(opts)
      applyOptions(self, opts)
      voidFill.reseed()
    end
    Game.dramaticShapeApplyOptionsHook = true
  end
end

mod.content.render_pipelines:register("voxel", {
  label = "VOXEL",
  levels = Voxel.ANGLE_LABELS,
  -- 3 is the engine's TILT key, which this mode supersedes -- see the
  -- hotkey block near the bottom of this file for how it is claimed
  hotkey = "8",
  priority = 20,

  -- Headless runs and drivers without a depth canvas or shader support
  -- answer false here, and the engine keeps the vanilla 2D path -- which
  -- is why no caller ever has to guard for a missing 3D pass.
  available = function()
    return Voxel3D.available()
  end,

  -- the engine hands over the live level; we ease the camera toward it.
  -- pump() advances queued mesh builds inside a few-millisecond budget,
  -- so entering voxel mode (and streaming neighbours while walking)
  -- costs frames nothing visible -- the old synchronous build froze the
  -- first frame for seconds. prefetch() runs here as well as in the
  -- draw, because update ticks even while a warp's Transition covers
  -- the screen: the destination's meshes start building the moment the
  -- map swaps behind the fade, and the fade-covered frames get a wider
  -- pump slice -- so stepping out of a door lands on terrain that is
  -- already there instead of a flat flash.
  update = function(dt, level)
    -- the arrival fit is applied ON THE STEP rather than held every frame,
    -- so the zoom keys and the wheel stay live while a mode is on
    applyFull(level)
    -- And every VOXEL rung is a MODE preset now: landing on HIGH/MEDIUM/LOW/
    -- POTATO applies that mode's defaults to the quality knobs, and a knob
    -- moved off its mode's preset flips the rung to CUSTOM (QualityMode).
    QualityMode.onLevel(level)
    QualityMode.enforce(level)
    Voxel.update(dt, level)
    -- the first-person head, on the same tick: its blend in and out of the
    -- orbit, the mouse capture lifecycle, and the frame's stick-rate look.
    -- Unconditional like Voxel.update, because the blend has to keep easing
    -- OUT after the rung is left
    FirstPerson.update(dt)
    -- the day/night clock, on the same always-running tick: Pipelines.update
    -- runs whatever the level, so time passes with the mode off, through
    -- battles and menus, and a CYCLE evening falls mid-fight exactly as it
    -- would mid-walk
    DayNight.update(dt)
    -- the atmosphere's own clock (shaft shimmer, drifting motes), on the
    -- same tick so the beams keep breathing through a dialog box
    ForestAtmos.update(dt)
    -- The overworld battle rides this hook rather than owning a pipeline of
    -- its own, because it owns no pass of the FRAME: it draws under a battle
    -- screen the engine composites, which is not a stage the registry has.
    -- What it needs is a tick that keeps running once the overworld stops
    -- being the top state, and this is one -- Game:update calls
    -- Pipelines.update unconditionally, so it survives the transition wipe
    -- and the whole battle. Ahead of the active() gate below, because a 3D
    -- a battle does not require a free camera rung to be switched on.
    OverworldBattle.update(dt)
    -- Check once whether bundled Pokemon Stadium battle models are available.
    -- Runtime ROM import is intentionally unavailable in the sandbox.
    pcall(function() V.require("StadiumScreen").maybePush() end)
    pcall(function()
      V.require("StadiumRomPick").poll(require("src.core.Game"))
    end)
    -- VOID FILL picks the block the border ring is made of, and in this
    -- mode that ring is BAKED INTO THE MESH rather than drawn each frame.
    -- So the option has to reach the cache or nothing happens on screen
    -- until the meshes are dropped for some other reason -- which reads
    -- exactly like the option doing nothing at all. Polled rather than
    -- hooked because the engine changes it from three places (the options
    -- row, applyOptions on load, TileRenderer.setVoidFill) and none of
    -- them announces it. Ahead of the active() gate, so switching it
    -- while voxel mode is OFF still invalidates what is cached.
    voidFill.check()
    -- The whole VR frame -- session lifecycle, xrWaitFrame's pacing, both
    -- eye renders, the layer submit -- rides this hook, because it is the
    -- one tick that runs through menus, dialogs and battles, which is
    -- what a headset needs the world (or at least the UI panel) to do.
    -- Ahead of the active() gate: with the mode off, the headset still
    -- shows the flat screen on the floating panel.
    VR.update(dt)
    if not Voxel.active() then
      publishLoading()
      return
    end
    local Game = require("src.core.Game")
    local ow = Game and Game.overworld
    if ow and ow.map and ow.camera then
      pcall(VoxelScene.prefetch, ow)
    end
    local covered = Game and Game.stack and Game.stack:top() ~= ow
    ChunkMesher.pump(covered or Voxel.loading)
    -- The covered slice may have completed the current terrain. Re-read now
    -- so the loading canvas does not survive for one empty extra frame.
    if Voxel.loading and ow and ow.map and ow.camera then
      pcall(VoxelScene.prefetch, ow)
    end
    publishLoading()
  end,

  drawWorld = function(ctx)
    -- the palette closure, stashed for the VR frame: it renders from the
    -- update hook, where no ctx exists to carry one
    VR.paletteFor = ctx.paletteFor
    -- With a headset running, the window's world pass becomes the MIRROR
    -- -- the left eye, fitted to the window -- rather than a third full
    -- render of the scene. Everything else about the frame (the UI the
    -- engine composites over this) is unchanged, which is exactly what
    -- the headset's floating panel photographs.
    if VR.active() then
      local sw, sh = sceneSize(ctx)
      local m = VR.mirror(sw, sh)
      if m then return m end
    end
    -- Terrain and characters are geometry; the field FX stay ordinary 2D
    -- draws composited on top, anchored through the same camera the 3D
    -- pass used (ctx.drawFx below).  The scene renders at the window's
    -- PIXEL resolution (see sceneSize) so the 3D pass is crisp rather than
    -- a magnified low-res image, while the FX closures keep drawing in
    -- world-pixel units.
    local sw, sh = sceneSize(ctx)
    if Voxel.loading then
      return VoxelLoading.draw(sw, sh, ChunkMesher.pending())
    end
    -- With AA on, the whole pass runs into a canvas BIGGER than the window
    -- and is folded back down at the end (see AntiAlias).  Nothing between
    -- these two lines knows: every pass in the frame measures itself in the
    -- canvas it was handed, so the sky's dither, the water's march and the
    -- camera itself all come out the same picture at a higher sample rate.
    local rw, rh = AntiAlias.expand(sw, sh)
    -- The scene renders SMALLER than the window at the RENDER SCALE the
    -- quality modes set (100% / 75% / 50% / 33%) -- BrickProfile.renderScale
    -- reads that knob -- and the same resolve() fold at the end brings it
    -- back up. Same machinery as AA, opposite direction: the GE8300
    -- fills a fraction of the pixels for every scene pass and the voxel
    -- diorama keeps its frame budget without spending the full fill rate.
    -- The composite is the only place that knows; everything inside
    -- measures itself in the canvas it was handed.
    local rs = BrickProfile.renderScale()
    local crw = math.max(1, math.floor(rw * rs + 0.5))
    local crh = math.max(1, math.floor(rh * rs + 0.5))
    local canvas = VoxelScene.render(ctx.state, crw, crh,
                                     ctx.vw, ctx.vh, ctx.paletteFor)
    if not canvas then return nil end   -- fall back to the 2D path
    if Voxel3D.beginOverlay() then
      -- the FX closures are ordinary 2D draws sized in DISPLAY pixels, and
      -- they are drawing into the supersampled canvas alongside everything
      -- else -- so the scale goes up with it, or the "!" bubble lands the
      -- right place at half the size.  project() already answers in canvas
      -- pixels, so only the scale needs saying.
      ctx.drawFx(function(wx, wy) return Voxel3D.project(wx, 0, wy) end,
                 ctx.scale * AntiAlias.factor() * rs)
      Voxel3D.endOverlay()
    end
    -- and back to the window's own size, which is what the engine composites
    -- one canvas pixel to one display pixel.  A pass-through when AA is off.
    if rs < 1 and canvas then
      -- LOW / MEDIUM / POTATO fold back with the canvas' ordinary texture
      -- filtering only. No dedicated upscaling shader or post-process pass is
      -- used on any VOXEL rung.
      canvas = Upscale.apply(canvas, sw, sh, "world")
    else
      -- no scaling to fold back: the AA fold only.
      canvas = AntiAlias.resolve(canvas, sw, sh, "world")
    end
    return canvas
  end,

  invalidate = function()
    Voxel3D.invalidate()
    OverworldBattle.invalidate()
    AntiAlias.invalidate()
    Upscale.invalidate()
    VoxelLoading.invalidate()
    ChunkMesher.invalidate()   -- no map id = every cached mesh
    ForestAtmos.invalidate()   -- shaft/particle meshes and shader sentinels
    VR.invalidate()            -- the mirror, and FBO ids of dead canvases
  end,
})

-- CachePrebuildScreen owns the cooperative build loop while its blocking
-- screen is active.  That keeps progress independent of the voxel render
-- path and makes the screen the single source of cancellation/failure state.
do
  local OverworldController = require("src.world.OverworldController")
  if not OverworldController.potatoVoxelLoadingHook then
    local inner = OverworldController.update
    function OverworldController:update(dt)
      if Voxel.loading then return end
      return inner(self, dt)
    end
    OverworldController.potatoVoxelLoadingHook = true
  end
end

-- ------- this mod's own settings
--
-- None of these is a pipeline: they own no pass of the frame, they
-- PARAMETERISE the voxel one, so they have nothing to put in drawWorld or
-- present and the registry would rightly reject them.  Plain mod settings
-- instead -- see ModSetting for where they persist, and lib/VoxelSettings
-- for the rows and the schema. Installed once, below.

-- ------- arrival on an active rung
--
-- The one-shot fit: when the VOXEL row ARRIVES on an active rung (HIGH /
-- MEDIUM / LOW / POTATO), the diorama is fitted to the window (zoom 0) --
-- a starting point, not a lock, so the player can still move the camera or
-- the zoom afterwards.
--
-- Leaving the rungs deliberately does NOT undo it. A preset that reverted
-- would throw away whatever the player had changed since, and "put it back
-- how it was" is not a thing this can know.
local fullWas = nil

applyFull = function(level)
  local on = level > 0
  local was = fullWas
  fullWas = on
  if not on or was == true or was == nil then return end

  local Game = require("src.core.Game")
  local opts = Game.save and Game.save.options
  if opts and opts.zoom ~= 0 then
    opts.zoom = 0
    require("src.render.Zoom").applyOptions(opts)
    if Game.writeOptions then pcall(Game.writeOptions, Game) end
  end
end

VoxelSettings.install()

-- ------- this mod's hotkeys
--
--   8 / SHIFT   VOXEL   cycle the quality ladder
--                       (OFF -> HIGH -> MEDIUM -> LOW -> POTATO)
--
-- Game:keypressed answers the engine's own display keys FIRST and returns
-- -- 2 COLORS, 3 TILT, 4 ZOOM, 5 GBC FX -- and only then offers the key to
-- Pipelines.hotkey. So this wraps Game:keypressed. It is the invasive
-- option and it is the only one: polling the keyboard in update() would
-- fire alongside the engine's handler rather than instead of it, so 8
-- would cycle this mode AND the engine's own handling on the same press.
--
-- The work is DELEGATED rather than reimplemented: cycleVoxel below uses
-- the registry's own gate and ladder and then does the engine's own
-- follow-up (syncOptions, the tilt/GBC FX exclusion, writeOptions).
--
-- TILT (3) and GBC FX (5) keep their keys: while this mod is enabled the
-- registry already forces TILT off whenever a world pipeline takes the
-- pass, GBC FX is a full-screen present pass over the top of the diorama,
-- and both rows are taken off the OPTIONS menu and held at zero (see
-- pinEngineFx). Uninstalling puts both back.
local HOTKEYS = {
  ["8"] = "pipeline",
  ["lshift"] = "pipeline",
  ["rshift"] = "pipeline",
}

-- One step of the VOXEL angle ladder: everything an "8" press does, named
-- so VR view control can make exactly the same step. The
-- gate is the registry's own; the tilt/GBC FX clearing is the engine work
-- the key has always delegated (see the wrap below for why).
local function cycleVoxel(game)
  local Pipelines = require("src.render.Pipelines")
  local top = game.stack and game.stack:top()
  if not Pipelines.canToggle("voxel", top, game.overworld) then return false end
  Pipelines.setLevel("voxel", Voxel.nextHotkeyLevel(Pipelines.level("voxel")))
  Pipelines.syncOptions(game.save.options)
  -- 8 is the key that used to turn TILT on and sits next to the one that
  -- used to turn GBC FX on, and this mod has taken both away. A player who
  -- left either running before enabling the mod would otherwise have no
  -- way back to off, and both fight the diorama -- so the VOXEL step
  -- clears them on EVERY press, not just the press that switches on.
  game.save.options.tilt = 0
  game.save.options.gbcfx = 0
  require("src.render.GBCFX").setLevel(0)
  require("src.render.Tilt").setLevel(game.save.options.tilt or 0)
  game:writeOptions()
  return true
end

-- The VR stick click makes this same step (VR.stepView): the function is
-- a local of this file, so the handoff is explicit rather than a
-- reimplementation drifting out of date in lib/VR.lua.
VR.cycleVoxel = cycleVoxel

do
  local Game = require("src.core.Game")
  local Pipelines = require("src.render.Pipelines")
  local inner = Game.keypressed

  function Game:keypressed(key)
    local claim = HOTKEYS[key]
    local top = self.stack and self.stack:top()
    -- Q and E work whichever camera is in front of the player -- the
    -- battle's lens, the third-person boom, or the engine's own survey
    -- zoom on an orbit rung. CamControl answers which, and answers "none"
    -- for the first-person rig and for every screen with no camera of
    -- ours behind it, in which case the key falls through untouched.
    -- Ahead of the hotkey table because a staged battle is exactly where
    -- the zoom is most wanted.
    if (key == "q" or key == "e")
       and not (top and top.onKeyPressed) then
      if CamControl.zoomBy(key == "q" and 1 or -1) then return end
    end
    -- A screen with its own key handler gets the key first, exactly as the
    -- engine's first branch does: typing a nickname must not toggle a
    -- render mode.
    if claim == "pipeline" and not (top and top.onKeyPressed) then
      -- 8 walks the quality ladder (Voxel.HOTKEY_ORDER). The whole of the
      -- step lives in cycleVoxel, so keyboard and VR controls share one
      -- guarded implementation; the gate is the registry's own.
      if cycleVoxel(self) then return end
    end
    return inner(self, key)
  end
end

-- The cache build gate, moved OFF the title menu (F1). The game.ready-time
-- readiness check runs under the skeleton save's DEFAULT options, so a
-- player whose save chose another VOID FILL read as "cache stale" on every
-- launch even when the cache matched the save exactly. The READY re-check
-- and the one-time prompt now run AFTER the engine applies the save's own
-- options: CONTINUE lands here from restoreSave, NEW GAME from
-- makeTitleState's onNewGame callback. The prompt is a modal over whatever
-- the save left on top (the overworld, Oak's speech), and an accepted
-- build enters the blocking progress screen used by the OPTIONS-menu
-- prebuild.
local function gateCacheBuild(game)
  CachePrebuild.refresh(game)
  if CachePrebuild.isReady() or not CachePrebuild.available() then return end
  local TextBox = require("src.render.TextBox")
  game.stack:push(TextBox.new(game, "MAP CACHE\nNOT READY.\fBUILD NOW?", nil, {
    defaultNo = true,
    choice = function(yes)
      if yes and CachePrebuild.start(game) then
        local Progress = V.require("CachePrebuildScreen")
        game.stack:push(Progress.new(game))
      end
    end,
  }))
end

do
  local Game = require("src.core.Game")
  if not Game.dramaticShapeCacheGateHook then
    local restoreSave = Game.restoreSave
    function Game:restoreSave(loaded, recovered)
      restoreSave(self, loaded, recovered)
      gateCacheBuild(self)
    end
    local makeTitleState = Game.makeTitleState
    function Game:makeTitleState()
      local title = makeTitleState(self)
      local onNewGame = title.onNewGame
      title.onNewGame = function()
        onNewGame()
        gateCacheBuild(self)
      end
      return title
    end
    Game.dramaticShapeCacheGateHook = true
  end
end

-- The realtime diagnostics panel: when enabled by benchmark instrumentation,
-- the mod owns a screen-space overlay over the finished frame. render.hud fires once per
-- rendered frame after the composite (Game.lua), which is also exactly
-- where Perf.frame() belongs -- so the hook does the frame stamping too,
-- and the panel shows live frame stats and mesh-build spans. The whole
-- thing is a no-op while the row is off (frameHook returns before
-- touching Perf's clock, and draw guards its own state).
mod.hooks:wrap("render.hud", function(nextFn, game, viewport)
  nextFn(game, viewport)
  DebugHud.disable(game)
  DebugHud.frameHook()
  DebugHud.draw(viewport)
end)

-- ------- keeping the geometry in step with the world
--
-- Terrain meshes are derived from a map's block layer, so anything that
-- rewrites a block (a cut tree, a smashed rock, a script's replaceBlock)
-- has to drop that map's cached mesh or the 3D world keeps showing the
-- tree that is no longer there.  The 2D tile renderer invalidates its own
-- caches off the same edit.

-- refresh, not invalidate: the stale mesh keeps drawing while the
-- replacement builds in the background, so a one-block edit (Cut, a
-- door stamp, the tree regrowing on re-entry) repopulates in place
-- instead of blinking the whole scene down to the flat 2D path
mod.events:on("world.block_replaced", function(payload)
  local mapId = payload and (payload.mapId or (payload.map and payload.map.id))
  if mapId then ChunkMesher.refresh(mapId) end
end)

-- The event above is the ANNOUNCED edit -- OverworldState:replaceBlock
-- emits it, which is the path Victory Road's barriers and a script's
-- replaceBlock take. Several edits do not go through it:
--
--   Cut          swaps the tree block and rebuilds the 2D renderer
--   the regrowth restores those blocks when the map is re-entered
--   card-key doors are stamped closed on floor load
--
-- all of them writing the block layer directly. Meshes derived from that
-- layer went stale with no announcement -- the cut tree stayed standing,
-- and after a round trip through a door the stump stayed cut because this
-- map's mesh survives in the cache (that is what prevLive is for).
--
-- The engine could announce each of those, and an earlier cut of this
-- work changed it to. That is the wrong place: it edits the game for one
-- mod's benefit, and every future path that writes a block has to
-- remember to do the same. They all funnel through ONE choke point --
-- Map:setBlock -- so wrap that from here instead. Map is a plain
-- metatable shared by every map instance, so this covers all of them,
-- including paths written after this mod.
--
-- Read back rather than trust the argument: setBlock silently ignores an
-- out-of-bounds write, and a stamp that rewrites a block with the value
-- it already held (the door code guards for this, the regrowth does not)
-- is not a change and must not throw the mesh away.
do
  local Map = require("src.world.Map")
  if not Map.dramaticShapeBlockHook then
    local setBlock = Map.setBlock
    Map.setBlock = function(self, bx, by, block)
      local before = self:blockAt(bx, by)
      setBlock(self, bx, by, block)
      if self.id and self:blockAt(bx, by) ~= before then
        ChunkMesher.refresh(self.id)
      end
    end
    Map.dramaticShapeBlockHook = true
  end
end

-- A reloaded map is rebuilt from scratch (warps that re-enter the same map,
-- hot reload), so its mesh is stale for the same reason -- with one
-- exception, and it is the common one.
--
-- A palette switch reloads the map ONLY to rebuild its atlas
-- (PaletteFX.setMode -> reloadMap(id, "colors")). The geometry that comes
-- back is identical: this mesher reads block layout and tile ids and never
-- reads colour, and the palette lives entirely in the texture TerrainAtlas
-- hands back per frame -- which is keyed BY palette, so the new colours are
-- already built by the time the next frame draws.
--
-- Dropping the mesh anyway cost a visible flash of the flat 2D world on
-- every palette toggle. Mesh builds are asynchronous, so the frames between
-- the drop and the first finished mesh have no terrain to draw, and
-- drawWorld returning nil IS the 2D fallback. Keeping the geometry lets the
-- new colours land on the diorama already on screen, in one frame, which is
-- what a palette toggle should look like from inside voxel mode.
mod.events:on("map.reloaded", function(payload)
  if payload and payload.reason == "colors" then return end
  local mapId = payload and (payload.mapId or (payload.map and payload.map.id))
  if mapId then ChunkMesher.invalidate(mapId) end
  -- the atmosphere's layout stands on the same carved stamps the meshes
  -- do, so it goes stale on exactly the same event
  if mapId then ForestAtmos.invalidate(mapId) end
end)

-- ------- rows come and go, so the menu has to notice
--
-- OptionsMenu builds its row list ONCE, when it is opened, and then reads
-- that list every frame. So any step that changes the LIST -- toggling
-- 3D-BTL (which owns BATTLE LAYOUT), or the VR row (which hides the battle
-- rows) -- is rebuilt in place, and crossing HIGH is kept in the same
-- guard so the level step still gets its one place to notice. Rebuilding
-- on every rung would rerun every mod's ui.options.rows hook once per
-- keypress for a list that did not move. The cursor is clamped rather
-- than reset, so it stays on the row it was just used on instead of
-- jumping to the top when the list below it shortens.
do
  local OptionsMenu = require("src.ui.OptionsMenu")
  if not OptionsMenu.dramaticShapeFullHook then
    local Pipelines = require("src.render.Pipelines")
    local inner = OptionsMenu.update

    local function idAt(menu, index)
      local row = menu.rows and menu.rows[index or 1]
      return type(row) == "table" and row.id or nil
    end

    function OptionsMenu:update(dt)
      local before = Pipelines.level("voxel")
      local hadBattles = OverworldBattle.enabled()
      -- the VR row hides the two battle rows while it is on, so stepping
      -- it changes the LIST exactly the way 3D-BTL does
      local hadVR = VR.enabled()
      local wasOn = idAt(self, self.index)
      inner(self, dt)
      local after = Pipelines.level("voxel")
      local crossedFull = after ~= before
                          and (Voxel.isFull(before) or Voxel.isFull(after))
      if crossedFull or OverworldBattle.enabled() ~= hadBattles
         or VR.enabled() ~= hadVR then
        local rebuilt = OptionsMenu.new(self.game)
        self.rows = rebuilt.rows
        -- Follow the row the cursor was ON rather than the slot it was in:
        -- 3D-BTL takes BATTLE LAYOUT off the list ABOVE itself, which would
        -- otherwise slide the cursor onto the row under the one just used.
        for i = 1, #self.rows do
          if wasOn and idAt(self, i) == wasOn then self.index = i; break end
        end
        local cancel = #self.rows + 1
        if (self.index or 1) > cancel then self.index = cancel end
      end
    end

    OptionsMenu.dramaticShapeFullHook = true
  end
end

-- ------- battles on the map
--
-- The wraps this needs -- OverworldState:pushBattle, BattleState:draw and
-- BattleState:drawHUDs -- all live in lib/OverworldBattle.lua, which is
-- where the reasoning for each one is written down. Installed once, here,
-- so this file keeps naming every engine seam the mod touches.
OverworldBattle.install()

-- ------- the free-roam rigs' inputs and their walk
--
-- The first-person rig (lib/FirstPerson.lua) and its free camera-relative
-- walk (lib/FreeMove.lua) are retained for the VR restore path -- no rung
-- on this build's ladder selects them, so every wrap below forwards
-- everything it does not claim and claims nothing here. The boom behind
-- the shoulder is a number inside the same rig (lib/ThirdPerson.lua).
--
-- FirstPerson.install claims the LOOK inputs the engine ignores: the right
-- stick's axes (Game:gamepadaxis passes them to Input, which returns early
-- on anything but the left pair), relative mouse motion (love.mousemoved --
-- there is no Game handler to wrap; the engine's own callback only feeds
-- the mouse-as-touch debug path, which stays untouched), the mouse buttons
-- while the cursor is captured (A and B -- there is no cursor to click UI
-- with), and any touch that lands off the overlay's controls (a drag on
-- open screen is the look; the d-pad and buttons still go to
-- TouchControls, whose own d-pad finger is also read back analog as the
-- move vector).
--
-- FreeMove.install wraps OverworldState:handleInput -- the one choke point
-- where the grid walk reads the pad, and the same seam the engine's own
-- Cycling Road pull lives behind. While a free rig drives, the walk is
-- continuous and camera-relative; the player's logical cell stays synced
-- and every per-cell consequence still runs through the engine's own
-- machinery (onStepComplete, checkEdgeExit, checkLedgeHop,
-- checkBoulderPush). The file argues the whole arrangement.
FirstPerson.install()
FreeMove.install()

-- ------- the zooms, and the battle camera the player can steer
--
-- CamControl claims the wheel, Q/E, the mouse and the touch screen for
-- whichever camera is actually in front of the player -- the staged
-- battle's, the third-person boom, or the engine's own survey zoom -- and
-- forwards everything else. Installed AFTER the two above deliberately: a
-- wrap installed later is the OUTER one, so a fight gets first refusal on
-- the mouse and the fingers, which is right, because while one is staged
-- the free-roam look is not driving.
CamControl.install()

-- ------- edge-anchored menus stay in the GB frame while a headset is live
--
-- The engine's zoom-aware anchoring (Renderer:setUIAnchor) docks the START
-- menu to the WINDOW's top-right edge. Both VR screens -- the floating
-- panel and the Pokedex -- crop the window to the GB frame, so a menu at
-- the window's edge is cropped away with the border it docked to. The
-- engine's own answer to "a state composes its screen, keep every element
-- inside it" is uiAnchorHold, computed per frame from this predicate; a
-- live headset is exactly that situation for the WHOLE window, so the
-- predicate answers yes for as long as one is. Held menus blit where they
-- were drawn in the 160x144 canvas -- the START menu's 9,0 x 11 slot is
-- already flush with the frame's right edge, which is the right edge of
-- what the headset sees. Off-headset frames fall through untouched.
do
  local Game = require("src.core.Game")
  if not Game.dramaticShapeAnchorHold then
    local inner = Game.uiAnchorsHeldInStack
    function Game.uiAnchorsHeldInStack(stack)
      if VR.active() then return true end
      return inner(stack)
    end
    Game.dramaticShapeAnchorHold = true
  end
end

-- The overworld's own pushBattle is the choke point for a wild encounter or
-- a trainer, and it is wrapped. A battle that arrives some other way -- a
-- link battle, a script pushing a BattleState directly -- reaches this
-- instead, which stages the arena from wherever the player is standing.
-- Nothing visible is lost by being late: the cull only has to beat the
-- battle screen, and the wipe those battles skip is where it would have
-- shown.
mod.events:on("battle.started", function(payload)
  OverworldBattle.ensure(payload and payload.battle)
end)

-- Both mons face the camera, so the player's side wants its FRONT pic where
-- the battle screen would have used the back one. The engine's own
-- pokemon.sprite hook is the seam for exactly this: it is asked for every
-- battle pic with the side it is resolving, so swapping one side's answer
-- needs no battle code at all -- and every path that builds a battler goes
-- through it, including a Transform mid-fight.
--
-- Ask downstream art mods for their FRONT variant. This hook has to run before
-- them: a complete front pic is what stands on the map, while many back pics
-- end at the text-box edge baked into their artwork.
mod.hooks:wrap("pokemon.sprite", function(next, path, ctx)
  if not (ctx and ctx.kind == "battle" and ctx.side == "back") then
    return next(path, ctx)
  end
  -- `battles` is stored in modOptions as the selected ladder value, not a
  -- boolean. The old truthy check enabled the alternate front-art path even
  -- when the player had selected OFF, and with the default 2D-3D-A path it
  -- made the lower-left player battler use the wrong-facing asset. Only the
  -- explicit staged-map path needs front art; the flat/normal battle keeps the
  -- engine's canonical back sprite.
  if not OverworldBattle.wantsFront() then return next(path, ctx) end
  local def = ctx.data and ctx.data.pokemon and ctx.data.pokemon[ctx.species]
  local front = {}
  for key, value in pairs(ctx) do front[key] = value end
  front.side = "front"
  local out = next((def and def.spriteFront) or path, front)
  ctx.trueColor = front.trueColor
  return out
end, 1000)

-- Every ending path emits this, including a battle skipped before it drew,
-- so this is where the map's cast comes back.
mod.events:on("battle.ended", function()
  OverworldBattle.finish()
end)

-- ------- and the way back out
--
-- The engine wipes INTO a battle with one of the original's eight transitions
-- and cuts straight OUT of it. That cut is between two very different cameras
-- in this mode, so while voxel mode is on the battle fades out, closes behind
-- the black, and the map fades up. The two seams it needs -- BattleState:finish
-- and Renderer:endFrame -- and the reasoning for each live in lib/BattleExit.lua.
--
-- Declared as a transitions record rather than a constant in that file, so the
-- fade is retunable in data exactly like the eight wipes it answers, and a total
-- conversion can make it as long or as short as its own pacing wants.
mod.content.transitions:register(BattleExit.ID, {
  frames = BattleExit.FRAMES,
})

BattleExit.install()

-- ------- and the hour on the flat world
--
-- The clock reaches the diorama through the voxel shader's own tint uniform,
-- which the 2D tile path never runs -- so with the mode off, the same evening
-- that fell on the diorama left the flat world at permanent noon. One clock,
-- two worlds, one of them ignoring it. DayTint paints the same multiply over
-- the composited flat world, between the world blit and the UI blit; the
-- reasoning for that exact instant is in the file.
DayTint.install()

-- ------- what time it is
--
-- The cycle's clock rides the SAVE SLOT (save.modData, via mod.save): what
-- time it is in Kanto is a fact about that journey, like where the player is
-- standing. Written on the engine's save.writing event -- the moment before
-- the bytes hit disk -- and read back whenever a save is opened or begun. A
-- save with no clock in it starts at day; that is DayNight.restore's
-- fallback, and also the DAYTIME row's own default.
mod.events:on("game.ready", function(payload)
  if payload and payload.game then
    V.require("Perf").setGame(payload.game)
    CachePrebuild.bootstrap(payload.game)
  end
end)

mod.events:on("save.writing", function()
  DayNight.store()
end)

mod.events:on("save.loaded", function()
  DayNight.restore()
  -- a save written before this mod was installed can carry TILT or GBC FX
  -- switched on, and their rows are not there to switch them back off (see
  -- VoxelSettings.pinEngineFx). Answered here rather than only when the
  -- menu opens, so a player who never opens it is not left playing under
  -- one.
  VoxelSettings.pinEngineFx()
end)

mod.events:on("save.created", function()
  DayNight.restore()
  VoxelSettings.pinEngineFx()
end)

-- The engine's own time-of-day seam. OverworldState:timeOfDay() is an
-- eternal "DAY" until a mod answers here; answering it hands the period to
-- the map.palette hook (ctx.tod) and music.select, so a palette or music
-- pack keyed to night works with this mod's clock for free. next() first: a
-- mod loaded before this one that already moved the time keeps its answer.
mod.hooks:wrap("world.tod", function(next, tod, ctx)
  local out = next(tod, ctx)
  if out ~= tod then return out end
  return DayNight.tod()
end)

-- exposed so a companion mod can pin its own tiles' shapes or read the
-- camera without reaching into this mod's file layout
mod.exports.lib = V
-- the Brick tuner, exposed so tests and tooling can probe isBrick() and
-- the pinned ladders without a device
mod.exports.brick = BrickProfile
