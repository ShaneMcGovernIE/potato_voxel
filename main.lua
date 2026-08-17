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
-- lib/ modules require each other through V rather than the module
-- path: a
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
function V.loadedNames()
  local out = {}
  for name in pairs(modules) do out[#out + 1] = name end
  table.sort(out)
  return out
end
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
local ShadowMap = V.require("ShadowMap")
local VoxelScene = V.require("VoxelScene")
local ChunkMesher = V.require("ChunkMesher")
local VoxelGrid = V.require("VoxelGrid")
local WorldCurve = V.require("WorldCurve")
local OverworldBattle = V.require("OverworldBattle")
local BattleExit = V.require("BattleExit")
local DayNight = V.require("DayNight")
local DayTint = V.require("DayTint")
local Water = V.require("Water")
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
local CachePrebuild = V.require("CachePrebuild")
local CacheFeature = V.require("CacheFeature")
local MeshCache = V.require("MeshCache")
local HordeSfx = V.require("HordeSfx")
local MapAtmos = V.require("MapAtmos")
local Weather = V.require("Weather")
local WorldFeature = V.require("WorldFeature")
local VoxelLoading = V.require("VoxelLoading")
local SettingsFeature = V.require("SettingsFeature")
local RuntimeHooks = V.require("RuntimeHooks")
local DebugOverlay = V.require("DebugOverlay")
local PlayerId = V.require("PlayerId")
DebugOverlay.install()
local ShapeDebug = V.require("ShapeDebug")
ShapeDebug.install()
DebugOverlay.setProbe(function()
  local done, total, running, eta = CachePrebuild.progress()
  return {
    voxel = Voxel3D.diagnostics(),
    shadows = ShadowMap.diagnostics(),
    cache = {
      identity = MeshCache.identity(),
      build = MeshCache.buildInfoSnapshot(),
      lastFailure = MeshCache.getLastFailure(),
      saveFailures = MeshCache.saveFailureCount(),
    },
    prebuild = {
      status = CachePrebuild.status(), done = done, total = total,
      running = running, eta = eta,
    },
  }
end)
-- The hold chords: five seconds of SELECT toggles debug visibility,
-- and five seconds of START while the background debugger is running exports its log --
-- the touch/pad versions of F9 and F8 (see lib/HoldChord.lua). Polled
-- on the always-running update tick below, because the engine's Input is
-- the one place every road into a button -- touch overlay, pad, keyboard
-- aliases -- converges.
local HoldChord = V.require("HoldChord")
local publishedLoading
-- Last DEBUGGER-option value applied to the overlay; see the tick below.
local lastDebuggerSetting = false

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
-- calls these, and each is defined further down with the settings it
-- drives. Declared rather than left global -- a mod writing to _G would
-- leak into every other mod's namespace.
local applyFull
local stagedBattles

-- The last VOID FILL the terrain was meshed under; see the update hook.
local voidFill = {}
local VoidFillDebounce = V.require("VoidFillDebounce")
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
  VoidFillDebounce.reseed(TileRenderer.voidFill)
end
-- The last drawWorld's render duration, fed into the debug overlay's
-- frame aggregation by the update tick (drawn before the next update).
local renderMs = 0
-- drawWorld diagnostics (finding #6): every early-return path leaves
-- renderMs frozen at its last real value, so a blank-world report cannot
-- tell which path fired. These one-shot stamps put the path in the stored
-- log: the loading canvas (and whether it STAYS stuck), the first real
-- scene render, and the periods where voxel is inactive (drawWorld never
-- runs at all).
local worldDiag = { loadingEntered = 0, loadingReported = false,
                    inactiveNoted = false, firstRender = false }

-- Entry-frame work deferred off the frame that queued it (BUG-2c): a
-- non-urgent options write must not ride the restoreSave frame -- the
-- field logs' map-enter freezes -- so it lands here, one batch per
-- frame, from the always-running tick below. Deferral is one frame at
-- most, and the drain is unconditional (title, menus and warps all
-- tick).
local deferredWork = {}
local function deferToNextTick(fn)
  if type(fn) == "function" then deferredWork[#deferredWork + 1] = fn end
end
local function drainDeferredWork()
  if #deferredWork == 0 then return end
  local batch = deferredWork
  deferredWork = {}
  for i = 1, #batch do
    local ok, err = pcall(batch[i])
    if not ok then
      DebugOverlay.error("deferred entry-frame work failed: %s", tostring(err))
    end
  end
end

-- BUG-1 render-skip tuning: a frame is "stalled" past STALL_FRAME
-- seconds (a single slow frame is legit -- a mesh landing); two
-- consecutive stalled frames arm the skip, and drawWorld drops the
-- voxel pass for up to STALL_MAX_FRAMES so the driver's queue drains
-- and input stays live (the Deck log's GPU-side crawl).
local stallSkip = { count = 0, frames = 0 }

-- The cache feature owns the boot prompt's pending state. It is forward
-- declared because the always-running pipeline tick is defined before the
-- settings/context assembly below.
local Cache

function voidFill.check()
  local TileRenderer = require("src.render.TileRenderer")
  local action, from = VoidFillDebounce.tick(TileRenderer.voidFill)
  if action == "invalidate" then
    DebugOverlay.trace("void fill changed %s -> %s (invalidate)",
                       tostring(from), tostring(TileRenderer.voidFill))
    ChunkMesher.invalidate()   -- no map id: every ring on every map is stale
  end
end

do
  local Game = require("src.core.Game")
  RuntimeHooks.wrapOnce(Game, "applyOptions", "dramaticShapeApplyOptionsHook",
    function(applyOptions)
      return function(self, opts)
        applyOptions(self, opts)
        voidFill.reseed()
      end
    end)
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
    local caps = Voxel3D.diagnostics()
    DebugOverlay.pipelineAvailable(caps.available, caps.reason, caps)
    return caps.available
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
    return DebugOverlay.try("voxel-update", function()
    -- Entry-frame work deferred by the events below lands here, one
    -- batch per frame (BUG-2c): non-urgent option/save writes must not
    -- ride the restoreSave frame that queued them.
    drainDeferredWork()
    DebugOverlay.frame(dt, renderMs)
    DebugOverlay.pipelineUpdate(level)
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
    -- The manager's page can change any of these rows mid-session, and the
    -- current API has no options-changed event to announce it: the settings
    -- read LIVE through the options API on every read (ModSetting:read),
    -- and the two pins the old event carried are re-asserted here on this
    -- always-running tick instead. Both are guarded no-ops when already
    -- correct (DayNight.forceSync, OverworldBattle.forceOG).
    if Voxel.isFull(level) then
      DayNight.forceSync(require("src.core.Game"))
    end
    if stagedBattles() then OverworldBattle.forceOG() end
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
    -- The overworld battle rides this hook rather than owning a pipeline of
    -- its own, because it owns no pass of the FRAME: it draws under a battle
    -- screen the engine composites, which is not a stage the registry has.
    -- What it needs is a tick that keeps running once the overworld stops
    -- being the top state, and this is one -- Game:update calls
    -- Pipelines.update unconditionally, so it survives the transition wipe
    -- and the whole battle. Ahead of the active() gate below, because a 3D
    -- battle does not require the free-roam mode to be switched on.
    OverworldBattle.update(dt)
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
    -- An incomplete cache also starts on its own once the overworld is up
    -- (hands-off: a fresh device needs no menu hunt, and the cooperative
    -- pump slices keep it off the frame). The covered flag passes through
    -- to the prebuild pump: while a menu, warp or the title screen hides
    -- the world, fills use the wider 30ms covered slice -- 3-6x faster
    -- with nothing visible to hitch.
    DebugOverlay.try("prebuild-tick", function()
      local Game = require("src.core.Game")
      local ow = Game and Game.overworld
      local covered = Game and Game.stack and Game.stack:top() ~= ow
      if not Cache.isGatePending() then
        CachePrebuild.autoStart(Game)
      end
      CachePrebuild.update(covered)
    end)
    -- The DEBUGGER row (and the mod manager's page) write the stored
    -- option; F9 and the SELECT chord flip visibility directly, so the
    -- stored value is only re-applied here when it CHANGES -- never
    -- fighting a manual toggle, and never hiding a panel the player just
    -- called up. On Android this option is the only toggle (see the
    -- SELECT chord gate below).
    local debuggerOn = false
    local optMod = V.mod
    if optMod and optMod.options then
      local okG, got = pcall(optMod.options.get, optMod.options, "debugger")
      debuggerOn = okG and got == true
    end
    if debuggerOn ~= lastDebuggerSetting then
      lastDebuggerSetting = debuggerOn
      DebugOverlay.setVisible(debuggerOn)
    end
    -- The hold chords ride the same always-running tick: five seconds
    -- held fires a chord wherever the cursor is, exactly like the F9 and
    -- F8 keys. Same guard as F9's too: a screen with its own key handler
    -- (a text field) never arms a chord. The engine's Input answers for
    -- every road into a button at once -- the touch overlay's buttons, a
    -- pad's back/start, and the keyboard aliases. SELECT toggles the
    -- debugger visibility; START exports its background log -- exporting is
    -- the retrieval half of the pair.
    local Input = require("src.core.Input")
    local holdGame = require("src.core.Game")
    local holdTop = holdGame.stack and holdGame.stack:top()
    local chordable = not (holdTop and holdTop.onKeyPressed)
    -- On mobile the touch overlay's SELECT is a real game button (it feeds
    -- the same Input state as a pad), so a five-second hold while playing
    -- must not summon the debug overlay.  The START chord -- the support-log
    -- export half of the pair -- still works there.
    local Platform = require("src.core.Platform")
    local selectChordable = chordable
      and not (Platform.detect and Platform.detect().mobile)
    if HoldChord.update("select", dt, selectChordable and Input:isDown("select")) then
      DebugOverlay.toggle()
    end
    if HoldChord.update("start", dt, chordable and DebugOverlay.running()
                                               and Input:isDown("start")) then
      DebugOverlay.export(holdGame)
    end
    if not Voxel.active() then
      if not worldDiag.inactiveNoted then
        worldDiag.inactiveNoted = true
        DebugOverlay.note("voxel inactive: drawWorld not running")
      end
      publishLoading()
      stallSkip.count, stallSkip.frames = 0, 0
      return
    end
    worldDiag.inactiveNoted = false
    local Game = require("src.core.Game")
    local ow = Game and Game.overworld
    -- BUG-1: the first map's body mesh primes from the cache BEFORE the
    -- first prefetch: the entry frame's synchronous full-slot load (and
    -- its GPU upload burst) falls to the sliced pump, and the first
    -- scene renders a small mesh that is already in memory. One-shot,
    -- and a no-op while the prebuild owns the cache or no payloads
    -- exist.
    if ow and ow.map and ow.camera then
      CachePrebuild.primeFirst(ow.map)
      pcall(VoxelScene.prefetch, ow)
    end
    -- BUG-1: consecutive stalled frames (a GPU/compositor crawl -- the
    -- Deck log's 4s frames) arm the render-skip in drawWorld below.
    WorldFeature.updateStall(dt, stallSkip)
    local covered = Game and Game.stack and Game.stack:top() ~= ow
    -- The shared queue pumps with CachePrebuild's own slice budget while
    -- a prebuild runs (BUG-2a): the queue is shared, so the live pump
    -- would otherwise slurp prebuild jobs at the full covered slice.
    CachePrebuild.pump(covered or Voxel.loading)
    -- The covered slice may have completed the current terrain. Re-read now
    -- so the loading canvas does not survive for one empty extra frame.
    if Voxel.loading and ow and ow.map and ow.camera then
      pcall(VoxelScene.prefetch, ow)
    end
    publishLoading()
    end)
  end,

  drawWorld = function(ctx)
    local ok, result = DebugOverlay.try("voxel-drawWorld", function()
      local canvas, elapsed = WorldFeature.render(ctx, worldDiag, stallSkip)
      if elapsed ~= nil then renderMs = elapsed end
      return canvas
    end)
    if not ok then error(result, 0) end
    return result
  end,

  invalidate = function()
    Voxel3D.invalidate()
    OverworldBattle.invalidate()
    AntiAlias.invalidate()
    Upscale.invalidate()
    VoxelLoading.invalidate()
    Weather.invalidate()
    DebugOverlay.trace("pipeline invalidate (context change)")
    ChunkMesher.invalidate()   -- no map id = every cached mesh
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
stagedBattles = function()
  return OverworldBattle.enabled()
end

local Settings = SettingsFeature.new({
  mod = mod,
  QualityMode = QualityMode,
  VoxelGrid = VoxelGrid,
  WorldCurve = WorldCurve,
  Water = Water,
  OverworldBattle = OverworldBattle,
  DayNight = DayNight,
  MapAtmos = MapAtmos,
  Weather = Weather,
  AntiAlias = AntiAlias,
  VR = VR,
  ShadowSettings = ShadowSettings,
  DebugOverlay = DebugOverlay,
  stagedBattles = stagedBattles,
})
Cache = CacheFeature.new({
  CachePrebuild = CachePrebuild,
  MeshCache = MeshCache,
  DebugOverlay = DebugOverlay,
  PlayerId = PlayerId,
  settingsEntries = Settings.entries,
})
Settings.defineSchema()

-- Mint the per-install support token early so the PLAYER ID row and the
-- debugger show the real id from the title screen.
PlayerId.ensure()
DebugOverlay.setSettingsReader(Settings.settingsSummary)

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
  local Pipelines = require("src.render.Pipelines")
  DebugOverlay.trace("voxel level -> %s",
                    tostring(Pipelines.level("voxel")))
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
    -- F9: the debug overlay's own switch, wherever the cursor is (it has
    -- no screen of its own to type into).
    if key == "f9" and not (top and top.onKeyPressed) then
      DebugOverlay.toggle()
      return
    end
    if key == "f10" and not (top and top.onKeyPressed) then
      DebugOverlay.toggleVerbose()
      return
    end
    if key == "f8" and not (top and top.onKeyPressed) then
      DebugOverlay.export(self)
      return
    end
    -- F6: the class-map view -- every tile tinted by its resolved shape
    -- class (see lib/ShapeDebug.lua). Debug-only, like F9/F10/F8.
    if key == "f6" and not (top and top.onKeyPressed) then
      ShapeDebug.toggle()
      return
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
  if changed and game.writeOptions then
    -- Off the entry frame (BUG-2c): save.loaded/save.created already
    -- carry restoreSave and the cache gate -- the field logs' map-enter
    -- freezes -- and the pin holds in memory either way.
    deferToNextTick(function() pcall(game.writeOptions, game) end)
  end
end

local function voxelSettingsRows(game)
  return Cache.rows(game)
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

do
  local Game = require("src.core.Game")
  if not Game.dramaticShapeCacheGateHook then
    local restoreSave = Game.restoreSave
    function Game:restoreSave(loaded, recovered)
      restoreSave(self, loaded, recovered)
      Cache.gate(self)
    end
    local makeTitleState = Game.makeTitleState
    function Game:makeTitleState()
      local title = makeTitleState(self)
      local onNewGame = title.onNewGame
      title.onNewGame = function()
        onNewGame()
        Cache.gate(self)
      end
      return title
    end
    Game.dramaticShapeCacheGateHook = true
  end
end

-- The mod manager writes and persists these settings on its own, and the
-- current API has no options-changed event to announce it -- so there is
-- nothing to subscribe to here. The settings read LIVE through the
-- options API on every read (ModSetting:read), which is what keeps each
-- row's rung in step with a value changed from the manager's page. The
-- two pins the old event also carried -- BATTLE LAYOUT under staged
-- battles, DAYTIME held at SYNC under FULL -- are re-asserted every tick
-- from the voxel pipeline's update hook instead (both are guarded no-ops
-- when already correct).

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
  DebugOverlay.trace("event block_replaced %s", tostring(mapId))
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
  RuntimeHooks.wrapOnce(Map, "setBlock", "dramaticShapeBlockHook",
    function(setBlock)
      return function(self, bx, by, block)
        local before = self:blockAt(bx, by)
        setBlock(self, bx, by, block)
        if self.id and self:blockAt(bx, by) ~= before then
          ChunkMesher.refresh(self.id)
        end
      end
    end)
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
  DebugOverlay.event("map.reloaded", {
    mapId = payload and payload.mapId,
    reason = payload and payload.reason,
  })
  DebugOverlay.trace("event map.reloaded %s (%s)",
                    tostring(payload and payload.mapId), tostring(payload and payload.reason))
  if payload and payload.reason == "colors" then return end
  local mapId = payload and (payload.mapId or (payload.map and payload.map.id))
  if mapId then ChunkMesher.invalidate(mapId) end
end)

mod.events:on("map.entered", function(payload)
  DebugOverlay.event("map.entered", {
    mapId = payload and (payload.mapId or payload.id),
  })
  DebugOverlay.trace("event map.entered %s",
                    tostring(payload and (payload.mapId or payload.id)))
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
-- is where keyboard, pad and touch have all already become the same
-- eight buttons. See lib/Horde.lua.
Horde.install()

-- The overworld's own pushBattle is the choke point for a wild encounter or
-- a trainer, and it is wrapped. A battle that arrives some other way -- a
-- link battle, a script pushing a BattleState directly -- reaches this
-- instead, which stages the arena from wherever the player is standing.
-- Nothing visible is lost by being late: the cull only has to beat the
-- battle screen, and the wipe those battles skip is where it would have
-- shown.
mod.events:on("battle.started", function(payload)
  DebugOverlay.trace("event battle.started")
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
  DebugOverlay.trace("event battle.ended")
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
    DebugOverlay.bindGame(payload.game)
    DebugOverlay.event("game.ready")
    local caps = Voxel3D.diagnostics()
    DebugOverlay.pipelineAvailable(caps.available, caps.reason, caps)
    PlayerId.persist(payload.game)
    CachePrebuild.bootstrap(payload.game)
  end
end)

mod.events:on("save.writing", function(payload)
  DebugOverlay.event("save.writing")
  if payload and payload.game then DebugOverlay.bindGame(payload.game) end
  local tex = ""
  if love and love.graphics and love.graphics.getStats then
    local okS, st = pcall(love.graphics.getStats)
    if okS and st then
      tex = (" texMB=%.1f"):format((st.texturememory or 0) / 1048576)
    end
  end
  DebugOverlay.trace("event save.writing%s", tex)
  DayNight.store()
end)

mod.events:on("save.loaded", function(payload)
  DebugOverlay.event("save.loaded")
  if payload and payload.game then DebugOverlay.bindGame(payload.game) end
  DebugOverlay.trace("event save.loaded")
  DayNight.restore()
  -- a save written before this mod was installed can carry TILT or GBC FX
  -- switched on, and their rows are not there to switch them back off (see
  -- pinEngineFx). Answered here rather than only when the menu opens, so a
  -- player who never opens it is not left playing under one.
  pinEngineFx()
end)

mod.events:on("save.created", function(payload)
  DebugOverlay.event("save.created")
  if payload and payload.game then DebugOverlay.bindGame(payload.game) end
  DebugOverlay.trace("event save.created")
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

mod.exports.version = "1.7.11"
-- exposed so a companion mod can pin its own tiles' shapes or read the
-- camera without reaching into this mod's file layout
mod.exports.lib = V
-- the Brick tuner, exposed so tests and tooling can probe isBrick() and
-- the pinned ladders without a device
mod.exports.brick = BrickProfile
-- Public support seam: data-only status and export/probe controls without
-- exposing the live renderer objects themselves.
mod.exports.debug = DebugOverlay
