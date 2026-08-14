-- PotatoVoxel (fork of Dramatic Shape Voxel Mod): a full 3D diorama
-- overworld, shipped as a rendering pipeline mod.
--
-- The engine's render_pipelines registry (src/mods/Schemas.lua) lets a mod
-- own part of the frame.  This mod registers two:
--
--   voxel      a drawWorld pipeline.  Instead of the flat tile blit, the
--              overworld's terrain is extruded into real geometry, walked
--              by a depth-buffered 3D camera, with characters as leaning
--              sprite slabs and a shadow map throwing real cast shadows
--              across whatever they land on.  Occlusion is the depth
--              buffer, not a y-sort: walk behind a building and the
--              building is simply in front.
--
-- Everything a display mode needs beyond the two draw functions -- the
-- OFF/15/35/50 ladder, the options rows, the hotkeys, persistence in
-- save.options.pipelines, the free-roam gate, the mutual exclusion with
-- the engine's TILT mode -- is engine plumbing driven by the records
-- below.  This file declares; lib/ draws.
--
-- Voxel mode is presentational: it changes what the world LOOKS like and
-- nothing about what it IS.  TWO rungs are the deliberate exception. 1ST
-- (the camera in the player's own eyes) and 3RD (the same rig, boomed back
-- behind their shoulder) replace the grid WALK with a free,
-- camera-relative one while either is selected (lib/FreeMove.lua), because
-- a camera you can steer with a mouse demands feet that go where it looks.
-- Even there the game is untouched: the walk asks the engine's own
-- collision the same questions a grid step asks, keeps the player's
-- logical cell synced, and fires the engine's own landing pipeline per
-- cell crossed -- warps, encounters, ledges, gates and scripts all run
-- exactly as themselves. Step off the rung and the grid walk is back.

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
local VoxelGrid = V.require("VoxelGrid")
local WorldCurve = V.require("WorldCurve")
local OverworldBattle = V.require("OverworldBattle")
local StadiumBattleFxProvider = V.require("StadiumBattleFxProvider")
local BattleExit = V.require("BattleExit")
local DayNight = V.require("DayNight")
local DayTint = V.require("DayTint")
local Water = V.require("Water")
local ForestAtmos = V.require("ForestAtmos")
local AntiAlias = V.require("AntiAlias")
local ShadowSettings = V.require("ShadowSettings")
local QualityMode = V.require("QualityMode")
local Upscale = V.require("Upscale")
local FirstPerson = V.require("FirstPerson")
local FreeMove = V.require("FreeMove")
local CamControl = V.require("CamControl")
local VR = V.require("VR")
-- HORDE MODE: the konami code's minigame. Horde owns the state machine and
-- every hook; the other four are the gun, the crowd, the readout and the
-- chip-synthesized sounds it fires. See lib/Horde.lua for the whole design.
local Horde = V.require("Horde")
local HordeGun = V.require("HordeGun")
local HordeHud = V.require("HordeHud")
-- the realtime diagnostics panel; see the module for how it arms Perf and
-- what it draws. The player-facing DEBUG option has been removed.
local DebugHud = V.require("DebugHud")
local CachePrebuild = V.require("CachePrebuild")
local MeshCache = V.require("MeshCache")
local HordeSfx = V.require("HordeSfx")
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
    -- FULL is a preset, so it is applied ON THE PRESS rather than held every
    -- frame: it SETS the other rows and then leaves them alone. Holding them
    -- would make the zoom keys and the wheel dead while the mode was on, and
    -- would fight anyone who changed one deliberately.
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
    -- battle does not require the free-roam mode to be switched on.
    OverworldBattle.update(dt)
    -- The one-time build of the Pokemon Stadium battle models out of the
    -- player's own ROM, if there is one to build from and it has not been
    -- done (see StadiumInstall). Rides this hook for the same reason the
    -- battle does -- it is the tick that runs whatever is on the stack -- and
    -- asks exactly once, on the first frame the player is actually in the
    -- world, so it is never fighting the engine's own launcher for the
    -- screen.
    pcall(function() V.require("StadiumScreen").maybePush() end)
    -- and a ROM the system file picker dropped in the save directory while
    -- we were not the top activity (Android; see StadiumRomPick.poll)
    pcall(function()
      V.require("StadiumRomPick").poll(require("src.core.Game"))
    end)
    -- The horde, on the same always-running tick and for the same reason:
    -- it owns no pass of the frame, it is a MODE over the overworld, and
    -- it has to keep thinking while a warp's wipe covers the screen (the
    -- crowd follows the player through the door) and under the GAME OVER
    -- card, which is a pushed state that stops everything below it.
    Horde.update(dt)
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
    -- The cache prebuilder is deliberately independent of the active display
    -- mode: an Options-menu press must keep progressing while VOXEL is OFF.
    CachePrebuild.update()
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
    -- diorama keeps its frame budget without the desktop's fill rate.
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
      -- the horde's readout rides the same overlay, over the FX: health,
      -- ammunition, the crosshair and the banners, sized in the same
      -- supersampled canvas pixels everything else here is drawn in. A
      -- headset never reaches this line (drawWorld returns the mirror
      -- above) -- lib/VR draws the same HUD onto each eye instead.
      HordeHud.drawFlat(crw, crh, ctx.scale * AntiAlias.factor() * rs)
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
      -- HIGH (or the desktop path): the AA fold only.
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

-- The loading cover hides gameplay, not time: the pipeline update above keeps
-- pumping mesh jobs while scripts, encounters and invisible movement pause.
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
-- Neither of these is a pipeline: they own no pass of the frame, they
-- PARAMETERISE the voxel one, so they have nothing to put in drawWorld or
-- present and the registry would rightly reject them.  Plain mod settings
-- instead -- see ModSetting for where they persist and how the two rows
-- each ends up on stay in step.

-- ------- the FULL preset
--
-- Everything the mode wants switched to at once. Applied when the VOXEL row
-- ARRIVES at FULL and not again, so the player can still move the camera or
-- the zoom afterwards -- it is a starting point, not a lock.
--
-- Leaving FULL deliberately does NOT undo any of it. A preset that reverted
-- would throw away whatever the player had changed since, and "put it back
-- how it was" is not a thing this can know.
local fullWas = nil

applyFull = function(level)
  -- On the Brick every on-rung is the same diorama framing, so the fit
  -- (the only thing the preset does there) fires for HIGH/MEDIUM/LOW
  -- alike; off the Brick only the FULL rung is the preset.
  local isFull = (BrickProfile.isBrick() and level > 0) or Voxel.isFull(level)
  local was = fullWas
  fullWas = isFull
  if not isFull or was == true or was == nil then return end

  if BrickProfile.isBrick() then
    -- Brick: every quality knob is pinned by BrickProfile, and the preset's
    -- setIndex calls below would re-enable the expensive rungs. The one
    -- thing wanted from the preset here is the fit -- the diorama filling
    -- the window (zoom 0).
    local Game = require("src.core.Game")
    local opts = Game.save and Game.save.options
    if opts and opts.zoom ~= 0 then
      opts.zoom = 0
      require("src.render.Zoom").applyOptions(opts)
      if Game.writeOptions then pcall(Game.writeOptions, Game) end
    end
    return
  end

  local Game = require("src.core.Game")
  local Pipelines = require("src.render.Pipelines")
  local Zoom = require("src.render.Zoom")
  local opts = Game.save and Game.save.options
  if not opts then return end

  Pipelines.syncOptions(opts)
  -- the horizon flat. The curve bends the world away from a walking player,
  -- which fights a fixed diorama framing
  WorldCurve.setting:setIndex(1, Game)
  -- and the water reflecting everything it can: FULL is the diorama at its
  -- most photographed, and a lake with the sky and the shoreline in it is
  -- most of what makes the model read as being outdoors
  Water.setting:setIndex(1, Game)
  -- and the view fitted to the window
  opts.zoom = 0
  Zoom.applyOptions(opts)
  -- battles on the map too: FULL means the whole mode, and a fight is where
  -- half of it is spent. Set and then LET GO of -- unlike the rows above, both
  -- battle rows stay on the menu under FULL (see the rows hook), so this is
  -- where the preset puts them and not where they are held.
  OverworldBattle.setting:setIndex(1, Game)
  -- with both mons out there on it: BACK SPRITES keeps the player's own on the
  -- menu, which is the one part of the old screen FULL is least about. Set the
  -- same way, and changed back on the same row a keypress later.
  OverworldBattle.backSetting:setIndex(1, Game)
  -- and the battle screen the staged fight is composed for. WIDE re-lays that
  -- screen out on a 304x144 surface, which moves every anchor the arena camera
  -- is solved against (OverworldBattle.forceOG); FULL has just switched staged
  -- fights on, so the layout follows them.
  OverworldBattle.forceOG(Game)
  -- and the sky on the clock on the wall: FULL pins DAYTIME to SYNC. Unlike
  -- the rest of the preset this one IS held, not just set -- the row is off
  -- the menu while FULL owns it (the rows hook below), so a value changed
  -- under it could never be seen or changed back.
  DayNight.forceSync(Game)
  if Game.writeOptions then pcall(Game.writeOptions, Game) end
end

-- Whether a fight can be staged on the map, as far as the OPTIONS menu is
-- concerned: the 3D-BTL row, and nothing else.
--
-- It used to answer yes under FULL as well, on the grounds that FULL owned
-- that row and switched it on. FULL no longer owns it -- the row stays on the
-- menu under FULL and can be switched off there (see the rows hook) -- so that
-- clause would now claim staged battles for a preset the player had just
-- turned them off inside, pinning BATTLE LAYOUT to OG for a fight that is
-- never staged. The row is the only thing that decides, which is what every
-- other reader of this setting already believed: OverworldBattle.begin and
-- wantsFront both gate on enabled() alone.
--
-- Deliberately NOT gated on Voxel3D.available(): the engine offers a
-- pipeline's row whether or not the hardware can run it (Pipelines.rows), so
-- this mode's rows say ON on a machine without a depth buffer too, and a menu
-- that claims 3D battles are on must not also offer the layout they cannot be
-- drawn in.
local function stagedBattles()
  return OverworldBattle.enabled()
end

local SETTINGS = {
  { QualityMode.renderSetting,
    "Render the 3D scene at a fraction of the window resolution and fold "
    .. "it back up -- the single biggest frame-budget lever. Each quality "
    .. "mode (HIGH / MEDIUM / LOW / POTATO) sets this; moving it on its own "
    .. "switches the mode to CUSTOM.",
    full = true },
  { VoxelGrid.setting, "One-pixel wireframe along every voxel edge." },
  { WorldCurve.setting,
    "Bend the world down over the horizon, Animal Crossing style." },
  { Water.setting,
    "Reflections on water. FULL adds screen-space reflections of the "
    .. "shoreline, the trees and the buildings behind it; SKY is the sky, "
    .. "the sun and the moon alone, which is most of the look for a "
    .. "fraction of the cost." },
  -- `full` for the AA reason: additive shafts are fill rate, and under 4X
  -- supersampling that is a question about the hardware, not the look.
  { ForestAtmos.setting,
    "The air of the deep woods (Viridian Forest): a ground haze, and "
    .. "volumetric light let down through the unseen canopy overhead -- "
    .. "gold spears of sun by day, silver moon rays at night, pollen "
    .. "drifting through the beams and fireflies once they cool. LOW "
    .. "keeps the haze, halves the beam march and stands the particles "
    .. "down. On a phone the row offers LOW alone: the beams need a "
    .. "depth texture the pass can read back, and no mobile driver here "
    .. "grants one.",
    full = true },
  -- `full` marks a row FULL does not take away. FULL owns the diorama's own
  -- knobs; what a battle is drawn over, and how it is framed, are not that.
  -- Off the OPTIONS menu while VR is on: the headset REQUIRES staged
  -- battles (OverworldBattle.enabled answers true regardless of this row)
  -- and forbids back sprites (backPinned answers false), so both rows
  -- decide nothing there and a dead switch on the menu reads as broken.
  { OverworldBattle.setting,
    "Fight in three dimensions, shot over the shoulder with a slow parallax "
    .. "drift. 2D-3D stands the game's own battle pics up as cards; STADIUM "
    .. "replaces them with the Pokemon Stadium battle models, animated, "
    .. "playing the animation the move being used actually calls for. A "
    .. "stages the fight on the MAP -- the nearest clear ground, in that "
    .. "place's own weather and light; B stands it on two discs against the "
    .. "sky instead, which works everywhere, including the caves and shop "
    .. "floors that have nowhere to stage a fight. The STADIUM rungs only "
    .. "appear once the models have been built, and building them needs a "
    .. "Pokemon Stadium (US) 1.0 ROM of your own -- import it from the "
    .. "STADIUM ROM row, or drop it in the baseroms folder and restart. No "
    .. "other version works: the reader is keyed to that one cartridge.",
    when = function() return not VR.enabled() end, full = true },
  -- Only offered while a fight can actually be staged on the map: with 3D-BTL
  -- off the engine draws the classic screen, which is this row's ON already,
  -- and a row that no longer decides anything is worse than no row.
  { OverworldBattle.backSetting,
    "Keep your own Pokemon on the battle menu, seen from behind in its "
    .. "original slot, instead of standing it on the map facing the foe. "
    .. "The foe is still out there on its own tile.",
    when = function() return stagedBattles() and not VR.enabled() end,
    full = true },
  -- Shows only while a fight can actually be staged, like BACK SPRITES
  -- above: the switch decides how a STAGED fight is drawn, so without a
  -- staged fight it decides nothing.
  { OverworldBattle.stadiumSetting,
    "Fight with the Pokemon Stadium battle models -- skinned and animated, "
    .. "playing the animation the move actually calls for -- instead of the "
    .. "flat battle pics. Needs the models built from your own Pokemon "
    .. "Stadium (US) 1.0 ROM: import it from the STADIUM ROM row, or drop "
    .. "it in the baseroms folder and restart.",
    when = function() return stagedBattles() end,
    full = true },
  { DayNight.setting,
    "What time it is outdoors: pin the sky to DAY, NIGHT, DUSK or DAWN, "
    .. "let CYCLE run it -- ten minutes of sun, ten of moon, with the "
    .. "shadows, the sky and the light following -- or SYNC it to the "
    .. "clock on the wall, so Kanto's evening falls when yours does." },
  -- Marked `full` for the opposite reason the battle rows are: this is not a
  -- knob on the look at all, it is what the look COSTS. FULL is a preset for
  -- the diorama, not a licence to spend four times the fill rate on the
  -- machine it happens to be running on, so it neither sets this nor takes
  -- the row away -- the player decides what their hardware can carry, from
  -- inside FULL like anywhere else.
  { AntiAlias.setting,
    "Smooth the stair-stepped edges of the 3D world -- roof ridges, ledge "
    .. "lips, a tree against the sky -- by rendering the diorama larger than "
    .. "the window and folding it back down. Every edge in the picture "
    .. "softens with them, the tileset's own texels included, so the diorama "
    .. "reads smoother rather than sharper. 2X costs half again as many "
    .. "pixels in each direction and 4X twice, which makes this the most "
    .. "expensive row in the mod.",
    full = true },
  -- `full` for the same reason as AA: not a knob on the look, a question
  -- about the hardware on the desk.
  { VR.setting,
    "PCVR through OpenXR (SteamVR, Oculus, WMR). The diorama becomes a "
    .. "tabletop model your head moves around; the 1ST rung stands you "
    .. "inside the world at life size, looking where the headset looks. "
    .. "Menus and dialogs float on a panel. Needs a Windows OpenXR runtime "
    .. "and the mod running from a real folder; without them the row stays "
    .. "and the game stays flat, with the reason on the console.",
    -- on Windows the row stays even when a runtime is missing (the console
    -- says why); off Windows -- mobile above all -- there is no VR to have
    -- and the row does not exist
    when = function() return VR.supported() end, full = true },
  -- Under the VR row and only while it is ON: a comfort setting for a
  -- device that is not plugged in decides nothing, and this one is read
  -- exclusively by the headset's right stick.
  { VR.smoothTurn,
    "Turn smoothly with the right stick instead of snapping 45 degrees a "
    .. "flick. OFF by default, and deliberately: a software turn moves the "
    .. "world past a head that did not move, which is the most reliable way "
    .. "to make somebody ill in a headset. Turn it on if you have your sea "
    .. "legs and want the continuity.",
    when = function() return VR.enabled() end, full = true },
  -- Marked `full` for the same reason as AA: not knobs on the look, what the
  -- look COSTS, so FULL neither sets them nor takes the rows away -- the
  -- player decides what their hardware can carry, from inside FULL like
  -- anywhere else.
  { ShadowSettings.enabledSetting,
    "Cast real shadows across the diorama -- a shadow climbs a wall, drapes "
    .. "over a roof and slides across a passing NPC. OFF is the flat-lit "
    .. "model: no shadow map is drawn, no contact blobs sit under the "
    .. "characters, and nothing reads as pasted on -- there just is no sun.",
    full = true },
  { ShadowSettings.qualitySetting,
    "How fine a shadow map to spend on the pass, as the edge of the square "
    .. "map in texels. AUTO is what the pass already does -- the smallest "
    .. "size whose texel stays under a target slice of a world pixel, up to "
    .. "2048. A fixed rung forces the map's edge whatever the view: bigger "
    .. "maps resolve finer shadow edges and cost fill rate and RAM (2048 is "
    .. "a 16MB depth pass), which is the whole of why this is a row.",
    full = true },
}

-- The mod manager's page offers the same settings the VOXEL SETTINGS menu
-- does: every knob is configurable now, so the page is a real form rather
-- than the old empty card. The VR rows are the one omission -- they are
-- absent from the manager's page wherever the platform cannot do VR at all
-- (the OPTIONS menu's `when` gates are situational, a row hidden for now;
-- this one is existential). The VOXEL row still lives on the OPTIONS menu,
-- through the render-pipelines registry, as the quality ladder (OFF / HIGH
-- / MEDIUM / LOW / POTATO).
local schema = {}
for _, entry in ipairs(SETTINGS) do
  local vrOnly = entry[1] == VR.setting or entry[1] == VR.smoothTurn
  if not vrOnly or VR.supported() then
    schema[#schema + 1] = entry[1]:schema(entry[2])
  end
end
mod.options:define(schema)

-- ------- this mod's hotkeys
--
--   3  VOXEL    cycle the camera ladder      (was 6; skips FULL)
--   5  V-GRID   toggle the wireframe         (new)
--   7  V-CURVE  cycle the horizon bend       (new)
--   8  3D-BTL   cycle overworld battles      (new)
--   9  WATER    cycle the water reflections  (new)
--
-- Game:keypressed answers the engine's own display keys FIRST and returns
-- -- 2 COLORS, 3 TILT, 4 ZOOM, 5 GBC FX -- and only then offers the key to
-- Pipelines.hotkey. 3 and 5 are two of those, and 7, 8 and 9 belong to
-- plain mod settings that own no pass and so have no registry to claim a
-- key from at all.
--
-- So this wraps Game:keypressed. It is the invasive option and it is the
-- only one: polling the keyboard in update() would fire alongside the
-- engine's handler rather than instead of it, so 3 would cycle this mode
-- AND the engine's TILT on the same press.
--
-- Consequences worth being explicit about: while this mod is enabled, TILT
-- (3) and GBC FX (5) are unreachable by key -- and unreachable on the OPTIONS
-- menu too, where both rows are taken away and both values held at zero (see
-- pinEngineFx). Nothing is being hidden that still does something: TILT is the
-- flat fake of what this mode does for real, the registry already forces it
-- off whenever a world pipeline takes the pass, and GBC FX is a full-screen
-- present pass over the top of the diorama. Uninstalling puts both back.
--
-- Everything the engine does around a pipeline hotkey has to happen here
-- too, so the work is DELEGATED rather than reimplemented: Pipelines.hotkey
-- applies its own gate and ladder, and the three lines after it are the
-- engine's own (syncOptions, the tilt exclusion, writeOptions).

-- The build is a single quality ladder, so the keys that cycled the removed
-- rungs are left alone: 5/7/9 fall through to the engine. Only "8" stays,
-- stepping OFF -> HIGH -> MEDIUM -> LOW -> POTATO.
local HOTKEYS = BrickProfile.isBrick()
  and { ["8"] = "pipeline", ["lshift"] = "pipeline", ["rshift"] = "pipeline" }
  or {
  ["8"] = "pipeline",           -- voxel, by its declared hotkey
  ["lshift"] = "pipeline",
  ["rshift"] = "pipeline",
  ["5"] = VoxelGrid.setting,
  ["7"] = WorldCurve.setting,
  ["3"] = OverworldBattle.setting,
  ["9"] = Water.setting,
}

-- One step of the VOXEL angle ladder: everything an "8" press does, named
-- so VR view control can make exactly the same step. The
-- gate is the registry's own; the tilt/GBC FX clearing is the engine work
-- the key has always delegated (see the wrap below for why).
local function cycleVoxel(game)
  local Pipelines = require("src.render.Pipelines")
  -- HORDE MODE holds the rung at 1ST for as long as it runs. Refused HERE
  -- rather than at each caller because this one function IS every way a
  -- player can step the ladder: the "8" key and the VR left-stick click
  -- both come through it.
  if Horde.viewLocked() then return false end
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
    -- HORDE MODE owns the keyboard's spare keys while it runs: R reloads,
    -- and the mode keys are swallowed rather than left to change the rung
    -- or the post-processing out from under a locked camera.
    if Horde.active then
      if key == "r" then
        HordeGun.reload()
        return
      end
      if HOTKEYS[key] then return end
    end
    local claim = HOTKEYS[key]
    local top = self.stack and self.stack:top()
    -- Q and E work whichever camera is in front of the player -- the
    -- battle's lens, the third-person boom, or the engine's own survey
    -- zoom on an orbit rung. CamControl answers which, and answers "none"
    -- for 1ST and for every screen with no camera of ours behind it, in
    -- which case the key falls through untouched. Ahead of the hotkey
    -- table because unlike those it is NOT free-roam only: a staged battle
    -- is exactly where the zoom is most wanted.
    if (key == "q" or key == "e")
       and not (top and top.onKeyPressed) then
      if CamControl.zoomBy(key == "q" and 1 or -1) then return end
    end
    -- A screen with its own key handler gets the key first, exactly as the
    -- engine's first branch does: typing a nickname must not toggle a
    -- render mode. Only free-roam presses are ours to take.
    if claim and not (top and top.onKeyPressed) then
      if claim == "pipeline" then
        -- 8 walks the ANGLE rungs and steps over FULL (Voxel.HOTKEY_ORDER),
        -- so the registry's plain "advance one and wrap" is not what it
        -- wants; 6 still is. The gate is the registry's own either way.
        -- The whole of 8's step lives in cycleVoxel, so keyboard and VR
        -- controls share one guarded implementation.
        if key == "8" or key == "lshift" or key == "rshift" then
          if cycleVoxel(self) then return end
        elseif Pipelines.hotkey(key, top, self.overworld) then
          if cycleVoxel(self) then return end
        elseif Pipelines.hotkey(key, top, self.overworld) then
          Pipelines.syncOptions(self.save.options)
          require("src.render.Tilt").setLevel(self.save.options.tilt or 0)
          self:writeOptions()
          return
        end
      elseif Pipelines.canToggle("voxel", top, self.overworld) then
        -- All four answer to the voxel pass's own free-roam gate --
        -- borrowed from the registry rather than restated, so a press
        -- mid-warp or mid-cutscene is refused for the wireframe exactly when
        -- it would be for the mode itself. Three of them parameterise that
        -- pass; the fourth (3D-BTL) decides what a battle is drawn over, and
        -- wants the same gate for a different reason: the answer is read
        -- when the fight starts, so flipping it from inside one would be a
        -- switch that appeared to do nothing.
        claim:cycle(self)
        -- 8 is one of the two ways staged battles get switched on, and they
        -- pin BATTLE LAYOUT to OG (see the rows hook). The other keys
        -- parameterise the pass and leave the layout alone; the guard answers
        -- for all of them, so nothing here has to know which key it was.
        if stagedBattles() then OverworldBattle.forceOG(self) end
        return
      end
    end
    return inner(self, key)
  end
end

-- ------- the mode's rows, kept together
--
-- The engine splices a pipeline's row in beside TILT, because a display mode
-- belongs with the other display modes; a mod's own ui.options.rows
-- additions land at the END of the list. That left this mod's four rows in
-- two places with unrelated engine rows between them, which reads as two
-- unrelated features rather than one mode with settings.
--
-- So the plain settings are inserted directly after the last of this mod's
-- PIPELINE rows instead of appended. Nothing else moves: the block lands
-- where the engine already decided display modes go.
local function insertGrouped(out, extra)
  local anchor = nil
  for i, row in ipairs(out) do
    local id = type(row) == "table" and row.id
    if id == "pipeline:voxel" then anchor = i end
  end
  if not anchor then
    for _, row in ipairs(extra) do out[#out + 1] = row end
    return out
  end
  for i, row in ipairs(extra) do table.insert(out, anchor + i, row) end
  return out
end

-- FULL owns the settings that describe the LOOK, so while it is selected those
-- are taken off the menu rather than left to be changed under it. A row that
-- no longer decides anything is worse than no row.
--
-- The battle rows are the exception and they stay; see the rows hook.
local function dropRow(out, id)
  for i = #out, 1, -1 do
    if type(out[i]) == "table" and out[i].id == id then table.remove(out, i) end
  end
  return out
end

-- ------- TILT and GBC FX are gone while this mod is installed
--
-- Both fight the diorama, and both were already half-taken: the mode's own key
-- (3) forces them off on every press, and the registry switches TILT off
-- whenever a world pipeline takes the pass. What was left was two rows the
-- player could set and watch get reverted -- TILT is the flat fake of what
-- this mode does for real, and GBC FX is a full-screen present pass over the
-- top of the whole thing.
--
-- So they come OFF the menu, and are HELD at zero rather than merely dropped.
-- Hiding a live setting is a trap: a save written before the mod was installed
-- can carry TILT 3, and a row that is not there is a row that cannot turn it
-- back off. Pinned wherever the value could have arrived from -- the menu
-- opening, a save being loaded or begun -- so there is no route by which one
-- of them is on and unreachable.
--
-- Everything they did is still reachable: uninstall the mod and both rows are
-- back, at whatever they were last set to.
-- BATTLE BG rides the same reasoning, and comes off for a reason of its own.
-- The row picks what fills the screen AROUND the battle's 160x144 field --
-- WHITE paper, BLACK bars, or the frozen overworld dimmed behind it -- and
-- all three were answers to the same question: what to do with the voids,
-- given the battle is a small picture in the middle of a big window.
--
-- This mod answers that question differently and permanently. A staged fight
-- fills the whole window with the map the fight is standing on, and the
-- flat battle screen it composites over it is drawn on the mode's own
-- surface; there are no voids left for the row to fill. WORLD is the worst
-- of the three under it -- it makes the battle non-opaque so the engine
-- draws the overworld underneath, which is a SECOND copy of the world drawn
-- under the one the arena pass already put there, dimmed and at a different
-- camera. BLACK bars over a diorama read as a letterboxed screenshot.
--
-- So the value is pinned at WHITE, which is the one the mode was composed
-- against, and the row comes off the menu on the same reasoning as TILT and
-- GBC FX: a row that no longer decides anything is worse than no row.
-- Uninstall the mod and it is back, at whatever it was last set to.
local function pinEngineFx(game)
  game = game or require("src.core.Game")
  local opts = game and game.save and game.save.options
  local Tilt = require("src.render.Tilt")
  local GBCFX = require("src.render.GBCFX")
  local changed = false
  if opts then
    changed = (opts.tilt or 0) ~= 0 or (opts.gbcfx or 0) ~= 0
                or (opts.battleBg or "white") ~= "white"
    opts.tilt, opts.gbcfx = 0, 0
    opts.battleBg = "white"
  end
  pcall(Tilt.setLevel, 0)
  pcall(GBCFX.setLevel, 0)
  if changed and game.writeOptions then pcall(game.writeOptions, game) end
end

-- Build the complete PotatoVoxel-owned row set for the dedicated submenu.
local function cacheReadyLabel(status)
  if status ~= "READY" then return status end
  local codec = MeshCache.codec()
  if codec then return "READY " .. codec:upper() end
  local mode = MeshCache.compressionStatus()
  if mode == "mixed" then return "READY MIX" end
  if mode == "raw" then return "READY RAW" end
  return "READY"
end

local function showCacheStatus(game)
  local TextBox = require("src.render.TextBox")
  local status = CachePrebuild.status()
  local label = status
  if status == "READY" then
    local codec = MeshCache.codec()
    if codec then
      label = "READY (" .. codec:upper() .. ")"
    else
      local mode = MeshCache.compressionStatus()
      label = mode == "mixed" and "READY (MIXED)"
              or mode == "raw" and "READY (RAW)"
              or "READY"
    end
  end
  -- which backend created the cache dir: love.filesystem or the libc
  -- mkdir -- so a support report names the active path
  local backend = MeshCache.dirBackend()
  local backendLabel = backend == "love" and "LOVE FS"
      or backend == "ffi" and "FFI MKDIR"
      or "NONE"
  game.stack:push(TextBox.new(game,
    ("%s\fGEOMETRY %d\fDIR: %s"):format(label, MeshCache.GEOMETRY_VERSION,
                                          backendLabel)))
end

local function confirmCacheWipe(game)
  local _, _, running = CachePrebuild.progress()
  local TextBox = require("src.render.TextBox")
  if running then
    game.stack:push(TextBox.new(game, "CANCEL BUILD\nBEFORE WIPING."))
    return
  end
  game.stack:push(TextBox.new(game, "WIPE CACHE?", nil, {
    defaultNo = true,
    choice = function(yes)
      if yes then CachePrebuild.wipe(game) end
    end,
  }))
end

local function voxelSettingsRows(game)
  local Pipelines = require("src.render.Pipelines")
  local rows = {}
  for _, row in ipairs(Pipelines.rows(game)) do rows[#rows + 1] = row end
  -- Every setting row lives here. The potato tuning is the DEFAULT, not a
  -- lock, so each knob is a switchable row (WATER OFF/SKY/FULL, FOREST FX
  -- OFF/LOW/FULL, AA OFF/2X/4X, V-CURVE, V-GRID, 3D-BTL, BACK SPRITES,
  -- DAY/NIGHT, SHADOWS, SHADOW QUALITY). The only gates are the situational
  -- `when`s -- VR rows, and BACK SPRITES needing a staged fight -- so
  -- nothing a device can carry is hidden from it.
  for _, entry in ipairs(SETTINGS) do
    if not entry.when or entry.when() then
      rows[#rows + 1] = entry[1]:row()
    end
  end
  local okPick, importRow = pcall(function()
    return V.require("StadiumRomPick").row()
  end)
  if okPick and importRow then rows[#rows + 1] = importRow end
  rows[#rows + 1] = {
    id = "potato_voxel:prebuild",
    label = "PREBUILD CACHE",
    value = function() return CachePrebuild.status() end,
    activate = function(g)
      local status = CachePrebuild.status()
      local _, _, running = CachePrebuild.progress()
      local decision = CachePrebuild.activationDecision(status, running)
      if decision == "cancel" then CachePrebuild.cancel()
      elseif decision == "start" then CachePrebuild.start(g)
      elseif decision == "confirm_rebuild" then
        local TextBox = require("src.render.TextBox")
        local ChoiceBox = require("src.ui.ChoiceBox")
        g.stack:push(TextBox.new(g, "REBUILD CACHE?", function()
          g.stack:push(ChoiceBox.new(g, function(yes)
            if yes then CachePrebuild.start(g) end
          end, { defaultNo = true }))
        end))
      end
    end,
  }
  rows[#rows + 1] = {
    id = "potato_voxel:cache_status",
    label = "CACHE STATUS",
    value = function()
      local status = CachePrebuild.status()
      return status == "READY"
             and cacheReadyLabel(status)
             or ("GEO %d"):format(MeshCache.GEOMETRY_VERSION)
    end,
    activate = showCacheStatus,
  }
  rows[#rows + 1] = {
    id = "potato_voxel:wipe_cache",
    label = "WIPE CACHE",
    value = function() return "DELETE" end,
    activate = confirmCacheWipe,
  }
  return rows
end

-- Keep engine OPTIONS focused: one launcher replaces every PotatoVoxel row.
mod.hooks:wrap("ui.options.rows", function(next, game, rows)
  local out = next(game, rows)
  if type(out) ~= "table" then return out end
  pinEngineFx(game)
  dropRow(out, "tilt")
  dropRow(out, "gbcfx")
  dropRow(out, "battleBg")
  if stagedBattles() then
    OverworldBattle.forceOG(game)
    dropRow(out, "battleLayout")
  end
  for i = #out, 1, -1 do
    local id = type(out[i]) == "table" and out[i].id or ""
    id = id or ""
    if id == "pipeline:voxel"
       or id:find("^potato_voxel:") then table.remove(out, i) end
  end
  out[#out + 1] = {
    id = "potato_voxel:settings", label = "VOXEL SETTINGS",
    value = function() return "OPEN" end,
    activate = function(g)
      require("src.ui.Screens").push(g, "PotatoVoxelSettings")
    end,
  }
  return out
end)

mod.content.screens:register("PotatoVoxelSettings", {
  new = function(game)
    return V.require("VoxelSettingsMenu").new(game, voxelSettingsRows)
  end,
})

-- The cache build gate, moved OFF the title menu (F1). The game.ready-time
-- readiness check runs under the skeleton save's DEFAULT options, so a
-- player whose save chose another VOID FILL read as "cache stale" on every
-- launch even when the cache matched the save exactly. The READY re-check
-- and the one-time prompt now run AFTER the engine applies the save's own
-- options: CONTINUE lands here from restoreSave, NEW GAME from
-- makeTitleState's onNewGame callback. The prompt is a modal over whatever
-- the save left on top (the overworld, Oak's speech), and an accepted
-- build runs cooperatively in the background exactly like the
-- OPTIONS-menu prebuild.
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

-- The mod manager writes and persists on its own, so the only thing left
-- to do is move our cached index and pick the new value up.
mod.events:on("mod.options_changed", function(payload)
  if not (payload and payload.mod == mod.id) then return end
  for _, entry in ipairs(SETTINGS) do
    if payload.key == entry[1].key then entry[1]:sync(payload.value) end
  end
  -- 3D-BTL switched on from the manager's page pins BATTLE LAYOUT exactly as
  -- the OPTIONS row does. The manager persists its own value; this is the one
  -- that has to follow it.
  if stagedBattles() then OverworldBattle.forceOG() end
  -- and DAYTIME changed from the manager's page while FULL owns it snaps
  -- straight back to SYNC -- the OPTIONS row is hidden, but the manager's is
  -- not, and FULL's pin must hold against both
  local Pipelines = require("src.render.Pipelines")
  if Voxel.isFull(Pipelines.level("voxel")) then DayNight.forceSync() end
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
-- that list every frame. So stepping the VOXEL row onto or off FULL changed
-- which rows the hook would return but not which rows were on screen -- the
-- settings FULL owns stayed visible until the menu was closed and reopened,
-- and a player who stepped off FULL could not see the rows come back.
--
-- Rebuilt in place, and only on a step that changes the LIST: crossing FULL,
-- or toggling 3D-BTL, which is the other row that owns one (BATTLE LAYOUT).
-- Every other rung returns the same list, and rebuilding on all of them would
-- rerun every mod's ui.options.rows hook once per keypress. The cursor is
-- clamped rather than reset, so it stays on the row it was just used on
-- instead of jumping to the top when the list below it shortens.
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

-- ------- the free-roam rungs' inputs and their walk
--
-- 1ST and 3RD need two things no other rung does, and each is a named seam.
-- Both rungs are one rig -- the boom behind the shoulder is a number inside
-- it (lib/ThirdPerson.lua) -- so both are installed by the same two calls:
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
-- move vector). Every wrap forwards whatever it does not claim, and claims
-- only while one of the two rungs is actually driving.
--
-- FreeMove.install wraps OverworldState:handleInput -- the one choke point
-- where the grid walk reads the pad, and the same seam the engine's own
-- Cycling Road pull lives behind. While either drives, the walk is continuous
-- and camera-relative; the player's logical cell stays synced and every
-- per-cell consequence still runs through the engine's own machinery
-- (onStepComplete, checkEdgeExit, checkLedgeHop, checkBoulderPush). The
-- file argues the whole arrangement.
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

-- ------- the konami code, and everything it turns on
--
-- Installed last of the input seams so its handleInput reasoning sits
-- outside FreeMove's. The detector itself does not live on
-- handleInput at all -- it reads the fixed step's own press queue, which
-- is where keyboard, pad, touch and the VR controllers have all already
-- become the same eight buttons. See lib/Horde.lua.
Horde.install()

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
  if payload and payload.game then CachePrebuild.bootstrap(payload.game) end
end)

mod.events:on("save.writing", function()
  DayNight.store()
end)

mod.events:on("save.loaded", function()
  DayNight.restore()
  -- a save written before this mod was installed can carry TILT or GBC FX
  -- switched on, and their rows are not there to switch them back off (see
  -- pinEngineFx). Answered here rather than only when the menu opens, so a
  -- player who never opens it is not left playing under one.
  pinEngineFx()
end)

mod.events:on("save.created", function()
  DayNight.restore()
  pinEngineFx()
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

mod.exports.version = "1.6.2-brick.17"
-- exposed so a companion mod can pin its own tiles' shapes or read the
-- camera without reaching into this mod's file layout
mod.exports.lib = V
-- the Brick tuner, exposed so tests and tooling can probe isBrick() and
-- the pinned ladders without a device
mod.exports.brick = BrickProfile
