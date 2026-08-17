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
local BattleFeature = V.require("BattleFeature")
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
local InputFeature = V.require("InputFeature")
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
WorldFeature.installLoadingGuard()

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

local Battle = BattleFeature.new({
  mod = mod,
  OverworldBattle = OverworldBattle,
  BattleExit = BattleExit,
  DebugOverlay = DebugOverlay,
})

local Settings = SettingsFeature.new({
  mod = mod,
  Voxel = Voxel,
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

-- ------- input feature
--
-- Input owns the display hotkeys and Game:keypressed wrapper. Keep its
-- installation here, after the settings context and before the options-row
-- hook, so the engine-facing registration order remains explicit.
local Input = InputFeature.new({
  BrickProfile = BrickProfile,
  Voxel = Voxel,
  VoxelGrid = VoxelGrid,
  WorldCurve = WorldCurve,
  Water = Water,
  OverworldBattle = OverworldBattle,
  Horde = Horde,
  HordeGun = HordeGun,
  CamControl = CamControl,
  DebugOverlay = DebugOverlay,
  ShapeDebug = ShapeDebug,
  VR = VR,
  stagedBattles = stagedBattles,
})
Input.install()


-- SettingsFeature owns the options-row rewrite, the pinned engine options,
-- and the PotatoVoxel settings screen. The call stays before the cache
-- lifecycle wrapper, matching the original registration order.
Settings.installRowsHook({
  Cache = Cache,
  deferToNextTick = deferToNextTick,
})


Cache.installLifecycle()

-- The mod manager writes and persists these settings on its own, and the
-- current API has no options-changed event to announce it -- so there is
-- nothing to subscribe to here. The settings read LIVE through the
-- options API on every read (ModSetting:read), which is what keeps each
-- row's rung in step with a value changed from the manager's page. The
-- two pins the old event also carried -- BATTLE LAYOUT under staged
-- battles, DAYTIME held at SYNC under FULL -- are re-asserted every tick
-- from the voxel pipeline's update hook instead (both are guarded no-ops
-- when already correct).

-- WorldFeature owns map edit/reload hooks and the Map:setBlock invalidation
-- seam. Installing here preserves their order before settings-menu refresh.
WorldFeature.installMapHooks({
  mod = mod,
  DebugOverlay = DebugOverlay,
})


-- OptionsMenu rebuilds its rows only when FULL, 3D-BTL, or VR changes
-- the visible list. SettingsFeature owns that lifecycle wrapper; keeping the
-- call here preserves its registration point before battle installation.
Settings.installMenuRefresh()

-- ------- battles on the map
--
-- The wraps this needs -- OverworldState:pushBattle, BattleState:draw and
-- BattleState:drawHUDs -- all live in lib/OverworldBattle.lua, which is
-- where the reasoning for each one is written down. Installed once, here,
-- so this file keeps naming every engine seam the mod touches.
Battle.installCore()

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

-- BattleFeature owns the staged battle events, sprite override, and exit
-- transition. These calls stay after Horde's install and before DayTint so the
-- engine hook/event registration order remains unchanged.
Battle.installEvents()
Battle.installExit()


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
  Settings.pinEngineFx()
end)

mod.events:on("save.created", function(payload)
  DebugOverlay.event("save.created")
  if payload and payload.game then DebugOverlay.bindGame(payload.game) end
  DebugOverlay.trace("event save.created")
  DayNight.restore()
  Settings.pinEngineFx()
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
