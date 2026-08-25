-- Overworld battles: fights that happen on the map you were standing on.
--
-- The engine's battle is a screen: a white field with two pics on it, pushed
-- over a frozen overworld that stops drawing. This turns that white field
-- into the world -- the same terrain the free-roam mode extrudes, shot from
-- a placed over-the-shoulder camera at a clear patch of ground nearby --
-- while leaving the battle ITSELF alone. Every pic, HUD, HP bar, move
-- animation, faint slide and text box is the engine's own, drawn in the
-- engine's own order. What changes is what is behind them, and where the two
-- pics stand.
--
-- The sequence, from the moment something picks a fight:
--
--   1. the overworld cast is culled -- every NPC vanishes, so the wipe
--      plays over an empty map and no bystander is left standing in the
--      arena shot
--   2. the engine's own transition wipes the screen (untouched: it is the
--      right wipe, picked by the right three bits)
--   3. the battle draws over a live, window-resolution render of the arena,
--      with each mon PINNED to the cell it is standing on, the camera
--      drifting slowly enough to read as parallax, and a depth-of-field pass
--      holding the slab of world the two of them occupy sharp
--   4. the battle ends, the cast comes back, and the player is exactly
--      where they were standing
--
-- WHAT DOES NOT MOVE. The arena is where the CAMERA goes, not where the
-- player goes: nothing here writes a cell, a facing, a flag or a warp. A
-- real warp would have to survive trainer sight-lines, post-battle
-- dialogue, the blackout path and every script that assumes the player is
-- where it left them -- and it would have to put them back afterwards.
-- Moving the camera buys the whole shot and owes nothing back.
--
-- The feature declines cleanly rather than half-working: no depth support,
-- no open ground on the map, the row switched off, or a mesh still building
-- all end at the same place, which is the battle screen the engine has
-- always drawn.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local ModSetting = V.require("ModSetting")
local BattleArena = V.require("BattleArena")
local BattleCam = V.require("BattleCam")
local BattleScene = V.require("BattleScene")
local BattleDOF = V.require("BattleDOF")
local BattlePics = V.require("BattlePics")
local Voxel3D = V.require("Voxel3D")
local ChunkMesher = V.require("ChunkMesher")
local RuntimeHooks = V.require("RuntimeHooks")

local OverworldBattle = {}

OverworldBattle.KEY = "battles"
OverworldBattle.LABEL = "3D-BTL"

-- Three rungs: where the staged fight stands.
--
--   2D-3D A    the fight is staged on the map and the two Pokemon are the
--              GB's OWN PICS, stood up on their tiles as quads
--              (BattleBillboard).
--   2D-3D B    those same pics on a pair of DISCS against the sky, with no
--              map at all. The Game Boy's own framing with the Game Boy's
--              own art, in three dimensions -- and, like every B rung, it
--              works everywhere, including the caves and shop floors that
--              have nowhere to stage a fight.
--   OFF        the engine's own white battle screen.
--
-- The STADIUM A/B rungs are gone: they stood the Pokemon Stadium battle
-- models, built from the player's own ROM, and the sandbox removed the
-- only way to read a player-supplied ROM -- so the rungs went with it
-- (see docs/adr/0004-feature-removals.md). Stored values "stadium" and
-- "stadiumB" from older saves fall back to values[1], 2D-3D A, exactly
-- like any other unrecognised value.
--
-- A and B is the STAGE and it is the same stage either way -- the discs do
-- not know what is standing on them and BattleScene draws them off
-- `arena.discs` alone. 2D-3D A stays FIRST because ModSetting's values[1]
-- is both the default and what an unrecognised stored value falls back to,
-- and the stored value for this row has been `true` since the row existed.
-- Keeping `true` at the head means every save written before the later
-- rungs existed reads back as the 2D-3D it was written for.
OverworldBattle.FLAT_B = "flatB"

OverworldBattle.setting =
  ModSetting.new(OverworldBattle.KEY, OverworldBattle.LABEL,
                 { true, "flatB", false },
                 { "2D-3D A", "2D-3D B", "OFF" })

-- Whether the fight stands on the two carried DISCS rather than on the map
-- -- the B column above. Asked by stageFor (what to stage on), wantsFront
-- (whether this map needs an arena at all) and, once the arena carries the
-- answer as `arena.discs`, by BattleScene and VoxelScene for what to draw.
function OverworldBattle.discs()
  local value = OverworldBattle.setting:get()
  return value == OverworldBattle.FLAT_B
end

-- Whether the VR row is ON -- read lazily, because VR requires modules
-- that sit above this one. While it is, this mode stops being optional:
-- the headset's battle seat, the pokedex screen and the effects plane
-- all assume a fight standing on the world, and a white-field battle
-- inside a headset is exactly the flat screen VR exists to replace.
local function vrOn()
  local ok, vr = pcall(V.require, "VR")
  return ok and vr and vr.enabled and vr.enabled() or false
end

function OverworldBattle.enabled()
  if vrOn() then return true end
  return OverworldBattle.setting:get() and true or false
end

-- ------- BACK SPRITES: the player's own mon stays on the menu
--
-- The staged shot stands BOTH mons on the map, which is the mode's whole
-- claim -- but it costs the one piece of framing Gen 1 is most recognisable
-- by: your own Pokemon, seen from behind, sitting on top of the battle menu
-- with its feet on the box. That silhouette is the series' shot.
--
-- So BACK SPRITES is offered as a middle setting rather than a compromise
-- imposed on everyone. With it on the foe is still geometry standing on its
-- tile at the far end of the arena, and the player's side goes back to being
-- the GB's own flat back pic in the GB's own slot: same art, same 2x, same
-- feet on row 96.
-- Nothing else about the shot moves -- the arena, the camera and the drift are
-- solved exactly as they were, so the foe stands where it always stood and the
-- player's cell is simply empty ground in the foreground.
--
-- OFF by default: what the mode advertises is the pair of them out there.
OverworldBattle.BACK_KEY = "battleBack"
OverworldBattle.BACK_LABEL = "BACK SPRITES"

OverworldBattle.backSetting = ModSetting.new(OverworldBattle.BACK_KEY,
                                             OverworldBattle.BACK_LABEL,
                                             { false, true }, { "OFF", "ON" })

-- Gated on 3D-BTL rather than read alone: with staged battles off there is no
-- staged shot for a back pic to be pinned in FRONT of, and the engine's own
-- battle screen already draws exactly this. And held OFF under VR: the
-- headset stands both mons on the world -- a flat back pic pinned to the
-- 2D frame would keep your own mon off the arena the battle seat looks at.
function OverworldBattle.backPinned()
  if not OverworldBattle.enabled() then return false end
  if vrOn() then return false end
  return OverworldBattle.backSetting:get() and true or false
end

-- Whether a pic is the one drawn in the GB's own slot with its feet on the
-- text box, rather than geometry standing out on the map.
--
-- Exactly the player's side under BACK SPRITES -- its mon, or the trainer back
-- that holds the slot until "Go!" -- because that is the only pic this mod
-- ever leaves flat (see drawPicsLayer below). The foe is a billboard on its
-- tile whichever mode is on, and with the mode off the player's side is one
-- too, so both of those keep the open bottom that lets the arena through a
-- stride. What the answer buys is in BattlePics: a pic on the box has nothing
-- behind its lowest row, so its bottom edge seals.
-- Read by TRUTHINESS rather than against nil, because sideTexture blanks the
-- side it is not rendering by setting the field to FALSE (see OFF) and holds
-- it that way for the whole render -- during which the pic layer runs, and
-- picImage asks this. A nil test passes a `false` straight through to the
-- index below, and the error comes out of sideTexture into the pcall that
-- calls it: the foe's billboard is dropped for the frame and the Pokemon
-- simply is not there.
function OverworldBattle.pinnedPic(battle, img)
  if not (battle and img) then return false end
  if not OverworldBattle.backPinned() then return false end
  if img == battle.playerBackPic then return true end
  local player = battle.player
  return (player and img == player.sprite) and true or false
end

-- ------- both mons face you
--
-- Standing on a map, seen from in front, a Pokemon showing you its BACK is
-- wrong twice over: it is turned away from the camera that is looking at it,
-- and the back pics are a different, smaller drawing made for a slot the
-- player never really sees. So the player's side asks for the FRONT pic too,
-- through the engine's own pokemon.sprite hook -- the seam that exists for
-- exactly this, so no battle code has to be touched to get it.
--
-- Unless BACK SPRITES is on, the setting that asks for the back pic back:
-- that mon is drawn in its own slot on the menu, seen from behind, and the
-- front art would be it turned round to face the player it belongs to.
--
-- Answered BEFORE a battle exists, because the battler is built before the
-- battle is pushed. So it cannot ask whether this fight is staged; it asks
-- whether one on this map WOULD be -- the row is on, the 3D pass is
-- available, and the map has an arena -- which is the same question with the
-- same answer a moment later. Cached per map, because the arena search walks
-- the whole grid and this runs once per battler.
local staged = { mapId = nil, ok = false }

function OverworldBattle.wantsFront()
  if not OverworldBattle.enabled() then return false end
  if OverworldBattle.backPinned() then return false end
  if not Voxel3D.available() then return false end
  -- required here rather than through the file's own helper: this runs
  -- while a battler is being built, which is before that helper is defined
  local g = RuntimeHooks.gameOwner()
  local ow = g and (g.overworld or g.world)
  if not (ow and ow.map and ow.player) then return false end
  -- a B rung carries its own stage, so the answer is yes on every map and
  -- there is nothing to search or to cache
  if OverworldBattle.discs() then return true end
  if staged.mapId ~= ow.map.id then
    local ok, arena = pcall(BattleArena.find, ow.map,
                            ow.player.cellX, ow.player.cellY,
                            ow.player.surfing)
    staged = { mapId = ow.map.id, ok = (ok and arena) and true or false }
  end
  return staged.ok
end

-- ------- where the engine's own pics stand
--
-- The GB draws the player's back pic with its feet on the text box at row 96
-- and its 7x7-tile slot centred on x=40, and the enemy's front pic
-- bottom-aligned in a 7x7 slot centred on x=124 ending at row 56. Those two
-- points are the pics' FEET, they hold for every species at every scale (the
-- engine's placement helpers pin the bottom edge and the centre), and they
-- are what BattleCam is solved to put the two arena cells under.
--
-- Which makes the pin a subtraction: whatever the drift has done to the
-- camera this frame, each pic moves by its own cell's projected position
-- minus its anchor. At the middle of the drift that is zero.
OverworldBattle.ANCHOR = {
  player = { 26, 96 },
  enemy = { 124, 56 },
}

-- ------- how big a mon is
--
-- Not a decision made here. A pic is drawn at its own integer scale -- 1x for
-- a 56px front pic, 2x for a 32px back one -- because that is the only way it
-- keeps every pixel the artist drew, and the CAMERA is solved so that one
-- overworld square is that big on screen (see BattleCam). The mon fits its
-- tile because the tile was sized to the mon, not the other way round.
OverworldBattle.SLOT_W = { front = 56, back = 32 }

-- The two HUD blocks, as the pixel spans DrawEnemyHUDAndHPBar and
-- DrawPlayerHUDAndHPBar actually reach. Neither overlaps its side's pic at
-- the anchors above.
OverworldBattle.HUD_RECT = {
  enemy = { 8, 0, 80, 32 },
  player = { 72, 56, 88, 40 },
}

-- ------- the box at the bottom, on the same glass
--
-- The HUDs got frosted panels because black glyphs on grass are not readable.
-- The battle's text box and its menu had the opposite problem and the same
-- cause: they are drawn as an OPAQUE WHITE slab with a black border, which was
-- the field's own colour when the field was white and is a sheet of paper laid
-- over the bottom third of the diorama now that it is not.
--
-- So the box gets exactly what the HUDs get: the world behind it, blurred to
-- frosted glass and laid back down translucent, with the border and the text
-- drawn over it unchanged, and the same brightness verdict flipping the ink
-- when the ground under it is dark. Only the FILL is taken away -- every glyph
-- the engine draws inside the box is still the engine's own, in its own place.
--
-- These are the boxes BattleState:drawTextArea lays down, as GB-frame rects.
-- READ-ONLY duplicates of that function's own branches, the same kind of
-- mirror hudLive is and for the same reason: there is no seam that reports "a
-- move menu is up", and glass has to go down BEFORE the box that sits on it.
-- The worst a future engine change can do is frost a rectangle nothing lands
-- on, or leave a box unfrosted -- never break a battle.
--
-- Each rect stops where the next one starts rather than overlapping it: two
-- panels over the same pixels would frost it twice and leave a visible step
-- along the seam.
OverworldBattle.TEXT_RECT = {
  box = { 0, 96, 160, 48 },       -- Font.drawBox(0, 12, 20, 6), always
  -- moveSelect's TYPE/PP box, Font.drawBox(0, 8, 11, 5), trimmed to the rows
  -- above the box above -- its last tile row sits inside that one
  moves = { 0, 64, 88, 32 },
  -- mimicSelect's copy menu, Font.drawBox(0, 7, 16, 6), trimmed the same way
  mimic = { 0, 56, 128, 40 },
}

-- How far apart the two anchors are: the spacing every move animation was
-- authored against, and so the yardstick the live pair is measured with.
OverworldBattle.ANCHOR_SPAN = math.sqrt(
  (OverworldBattle.ANCHOR.enemy[1] - OverworldBattle.ANCHOR.player[1]) ^ 2
  + (OverworldBattle.ANCHOR.enemy[2] - OverworldBattle.ANCHOR.player[2]) ^ 2)

-- The effects layer's scale for this shot: how far apart the two mons
-- actually are on screen, over how far apart the slots they were authored
-- for were. Clamped hard at both ends -- an effect is pixel art and a wild
-- factor is worse than a slightly wrong one -- and held at exactly 1 when
-- the marks coincide, which is a projection about to degenerate rather
-- than a pair that has genuinely closed up.
OverworldBattle.ANIM_SCALE_MIN = 0.5
OverworldBattle.ANIM_SCALE_MAX = 2.0

function OverworldBattle.animScale(shot, px, py)
  if not (shot and shot.enemy and px and py) then return 1 end
  local dx, dy = shot.enemy[1] - px, shot.enemy[2] - py
  local span = math.sqrt(dx * dx + dy * dy)
  if not (span > 1) then return 1 end
  local base = shot.anchorSpan or OverworldBattle.ANCHOR_SPAN
  if not (base > 0) then return 1 end
  local k = span / base
  return math.max(OverworldBattle.ANIM_SCALE_MIN,
                  math.min(OverworldBattle.ANIM_SCALE_MAX, k))
end

-- ------- the live battle
--
-- nil when no overworld battle is running. Never more than one: battles do
-- not nest.
local session = nil
local textureProvider = nil

-- Gen 1 renders its pic layer through BattleState:drawPicsLayer. Gold keeps
-- the same staged scene but owns a different screen API, so its feature can
-- supply a side-capture provider without changing the Gen 1 renderer path.
function OverworldBattle.setTextureProvider(provider)
  if provider ~= nil and type(provider) ~= "function" then
    error("OverworldBattle texture provider must be a function or nil", 2)
  end
  textureProvider = provider
end

local function game()
  return RuntimeHooks.gameOwner()
end

-- Gen 1 calls this owner `overworld`; Gold keeps the same live state under
-- `world`.  Resolve it at the boundary so the rest of the battle staging
-- code can remain generation-neutral.
local function world(gameOwner)
  return gameOwner and (gameOwner.overworld or gameOwner.world)
end

-- Put the map's cast back. Both lists are handed back by identity, so
-- anything that captured one before the battle still sees the same table.
local function restoreCast()
  if not (session and session.state) then return end
  if session.entities then session.state.entities = session.entities end
  if session.ghosts then session.state.ghosts = session.ghosts end
  session.entities, session.ghosts = nil, nil
end

-- Cull them. The player stays -- they are not an NPC, they are who the
-- battle belongs to, and Fly/surf animations and the save's own capture read
-- state.player through this list.
--
-- Only the DRAW lists are touched, and only while the overworld is frozen
-- underneath a battle: StateStack updates the top state alone, so nothing
-- walks, wanders, triggers or collides against a list that is short for
-- these frames. The originals go back at battle.ended.
local function cullCast(state)
  session.entities = state.entities
  session.ghosts = state.ghosts
  state.entities = { state.player }
  state.ghosts = {}
end

-- ------- one right battle layout
--
-- The classic anchors and HUD rectangles remain the OG defaults. The active
-- BattleScene layout metrics replace them for WIDE, including the translated
-- surface positions from src/battle/WideBattle.lua. The background-fill shim,
-- camera shot and animation layer consume that same boundary, so the world
-- and engine UI never solve against different surfaces.
--
-- So while a fight can be staged on the map there is one right answer, and it
-- is SET rather than worked around. The engine reads the option live
-- (BattleState:isWideBattleLayout is asked per frame, and Renderer asks the
-- top state for its surface the same way), so writing it here lands on the
-- battle being pushed as well as every one after it.
--
-- Where THIS fight stands, on whichever rung is running: the map's own
-- ground, or the pair of discs a B rung carries with it.
--
-- The one place the two columns actually diverge, and it is worth stating
-- plainly. On an A rung the answer can be NO -- a corridor, a shop floor, a
-- map whose authored entry is a refusal -- and the battle then plays exactly
-- as the vanilla game does. A B rung cannot fail: its stage is not something
-- the map has to have room for, so a fight in the tightest cave in Kanto is
-- staged as readily as one on Route 1.
function OverworldBattle.stageFor(state)
  if OverworldBattle.discs() and Voxel3D.available() then
    local okStage, arena = pcall(function()
      return V.require("DiscArena").arena(state.map)
    end)
    if okStage and arena then return arena end
    -- the discs could not be built; fall through to the map, which is a
    -- worse picture but a real one
  end
  local okFind, arena = pcall(BattleArena.find, state.map,
                              state.player.cellX, state.player.cellY,
                              state.player.surfing)
  return (okFind and arena) or nil
end

-- Stage a battle triggered from `state`, if this mode can. Returns true when
-- a session started -- which is also the only case where anything visible
-- changes, so a map with no room for an arena plays exactly the vanilla
-- battle it always did, cast and all.
function OverworldBattle.begin(state, battle)
  OverworldBattle.finish()
  if not OverworldBattle.enabled() then return false end
  if not (state and state.map and state.player) then return false end
  if not Voxel3D.available() then return false end

  local arena = OverworldBattle.stageFor(state)
  if not arena then return false end

  session = { state = state, arena = arena, battle = battle, shot = nil,
              armed = false, token = 0 }
  cullCast(state)
  BattleCam.reset()
  return true
end

-- The fallback entry point: a battle that arrived without going through the
-- overworld's own pushBattle (a link battle, a script pushing a BattleState
-- directly). Nothing visible depends on the cull for those -- the wipe has
-- already been and gone -- but the arena still has to be picked.
function OverworldBattle.ensure(battle)
  if session then
    -- a battle pushed through the overworld reaches begin() before it is
    -- built far enough to draw; battle.started is where it is finished
    if battle and not session.battle then session.battle = battle end
    return
  end
  local g = game()
  local ow = world(g)
  if ow and ow.map then OverworldBattle.begin(ow, battle) end
end

-- The arena this battle is staged on, or nil. Read by the shot driver so a
-- screenshot can be labelled with the ground it was taken on.
function OverworldBattle.arena()
  return session and session.arena or nil
end

function OverworldBattle.finish()
  if not session then return end
  restoreCast()
  session = nil
  Voxel3D.camera = nil
end

-- ------- per-frame
--
-- Driven from the voxel pipeline's update hook, which the engine ticks every
-- frame regardless of which state is on top -- including the frames the
-- transition wipe covers, which is what gets the arena's meshes built before
-- the first battle frame needs them.
--
-- The scene is rendered HERE rather than inside the battle's draw, because
-- update runs with no canvas bound: a 3D pass that binds a depth target and
-- unbinds to the screen when it is done cannot do that in the middle of
-- someone else's frame without putting the frame back itself.
function OverworldBattle.update(dt, activeBattle)
  if not session then return end

  local g = game()
  local top = g and g.stack and g.stack:top()
  local ow = world(g)
  -- A battle that ended without saying so (a script tearing the state down,
  -- a path that never emits battle.ended) would otherwise leave the cast
  -- culled for good. Armed only once something has actually covered the
  -- overworld, because begin() runs while the overworld is still on top.
  if top ~= nil and top ~= ow then
    session.armed = true
  elseif session.armed then
    OverworldBattle.finish()
    return
  end

  -- Whether the shot is the player's to steer at all. BACK SPRITES pins
  -- their own mon to the GB's slot on the menu while the foe stands out on
  -- the map, and there is no angle that half-framed, half-solid
  -- composition survives -- so under it the camera holds the shot the rig
  -- was solved for (the slow drift aside, which was always there). Polled
  -- per frame rather than latched at battle start: the row is reachable
  -- from the mod manager's page mid-session.
  BattleCam.steerable = not OverworldBattle.backPinned()
  -- the right stick, read as a rate before the rig is built from it: the
  -- wheel, the keys, the mouse and a drag all arrive as events and have
  -- already landed, but a stick is a HELD position and only a tick can
  -- turn it into travel (CamControl, which owns every one of those inputs)
  pcall(V.require("CamControl").tick, dt)
  BattleCam.update(dt)
  -- the battle only exists once it has been pushed; a session opened at
  -- pushBattle time has it, one opened from battle.started was handed it
  session.battle = activeBattle or session.battle or (top ~= ow and top or nil)
  -- the world pass is hidden behind the battle, so mesh builds get the wide
  -- slice: nothing visible can hitch on them
  ChunkMesher.pump(true)

  -- The mons' textures are rendered HERE, with no canvas bound, for the same
  -- reason the scene is: the pics layer binds its own targets, and doing that
  -- inside somebody else's frame means putting the frame back afterwards.
  local okTex, textures = pcall(OverworldBattle.textures, session.battle)
  if not okTex then textures = nil end
  -- stashed for the VR eye pass, which stands these same pics on the map
  -- in ITS view of the world (VoxelScene's eyes path). Stashed HERE
  -- because rendering them binds canvases, which the eye pass -- mid-scene
  -- when it wants them -- must never do; reading a stashed canvas is free.
  session.textures = textures
  -- and the move-animation layer, for the same eyes -- rendered only
  -- while a headset is actually watching, because only the VR world
  -- pass draws it (the flat screen has the animations in-frame already)
  session.animTex = nil
  local okVR, vrOn = pcall(function()
    local vr = V.require("VR")
    return vr.active and vr.active() or false
  end)
  if okVR and vrOn and session.battle then
    local okA, anim = pcall(OverworldBattle.animTexture, session.battle)
    if okA then session.animTex = anim end
  end
  session.token = (session.token or 0) + 1
  local ok, shot = pcall(BattleScene.render, session.state, session.arena,
                         textures, session.token, session.battle)
  if not ok then
    -- One failure retires the arena for THIS battle and nothing else: the
    -- battle screen carries on as the engine's own, the free-roam pipeline
    -- this runs inside keeps rendering the overworld, and the next battle
    -- tries again. Rethrowing would hand the whole voxel mode to Pipelines'
    -- guard, which retires a pipeline for the session.
    session.shot = nil
    session.broken = true
    V.mod.log:warn("overworld battle scene failed: %s -- this battle draws "
                   .. "on the plain battle background", tostring(shot))
    return
  end
  if shot and shot.canvas then
    -- the depth of field is measured off the two marks: the slab in focus is
    -- the one the mons are standing in, at whatever the drift has done to
    -- where that lands
    local y1 = shot.ly + shot.player[2] * shot.scale
    local y2 = shot.ly + shot.enemy[2] * shot.scale
    local focusY, band, range = BattleDOF.bandFor(y1, y2, shot.ph)
    local okDof, blurred = pcall(BattleDOF.apply, shot.canvas,
                                 focusY, band, range)
    if okDof and blurred then shot.canvas = blurred end
  end
  session.shot = shot
end

-- The finished shot for this frame, or nil when there is none and the battle
-- should draw the way it always did.
function OverworldBattle.shot()
  if not session or session.broken then return nil end
  local s = session.shot
  if s and s.canvas then return s end
  return nil
end

-- The staged fight's WORLD-side pieces, for a pass that stands the mons in
-- its own view of the map rather than in the arena's composed shot -- the
-- VR eyes. Returns the two cards as BattleScene.monCards builds them (yawed
-- toward whatever Voxel3D.eye is at CALL time, so a per-eye caller gets
-- per-eye cards), the live textures table (for the hit-flash flag), and the
-- token the shadow signature keys on. nil while nothing is staged, the
-- arena is broken, or the pics have not been rendered yet.
function OverworldBattle.worldCards()
  if not (session and session.arena and not session.broken) then return nil end
  local tex = session.textures
  if not tex then return nil end
  local host = (session.state and session.state.map) or nil
  if not host then return nil end
  local groundY = BattleScene.groundY(host, session.arena)
  return BattleScene.monCards(session.arena, groundY, tex), tex, session.token
end

-- The live session's BATTLE STATE, once the pushed battle has been met
-- (session.battle fills in from the stack in update). The VR quad reads
-- it to tell "the battle screen is on top" from "a menu is over the
-- battle" -- the UI-only panel is right for the first and wrong for the
-- second. nil with no session, a broken one, or a battle not yet pushed.
function OverworldBattle.battle()
  if not (session and not session.broken) then return nil end
  return session.battle
end

-- The move-animation layer as a texture: the engine's own drawAnimLayer,
-- rendered UNSHIFTED (slot-authored coordinates) into a GB-sized
-- transparent canvas of its own. This is what stands the effects up in
-- the VR eyes' world -- see worldAnim below -- the same move the pics
-- made through sideTexture: let the engine draw what it always draws,
-- catch it on a canvas, stand the canvas in the scene.
local animLayer = nil
local animLayerW, animLayerH = nil, nil
-- the engine's own drawAnimLayer, captured by install(). Declared HERE,
-- above the function that reads it: a local declared further down the
-- chunk would leave this function reading a global of the same name --
-- nil forever, and the effects silently absent from the eyes (the bug
-- this comment is the tombstone of).
local innerAnim = nil

function OverworldBattle.animTexture(battle)
  if not (innerAnim and battle) then return nil end
  if not (love.graphics and love.graphics.newCanvas) then return nil end
  local layout = BattleScene.layoutMetrics(battle)
  if not animLayer or animLayerW ~= layout.surfaceW
     or animLayerH ~= layout.surfaceH then
    local ok, c = pcall(love.graphics.newCanvas,
                        layout.surfaceW, layout.surfaceH, { dpiscale = 1 })
    if not (ok and c) then return nil end
    pcall(c.setFilter, c, "nearest", "nearest")
    animLayer = c
    animLayerW, animLayerH = layout.surfaceW, layout.surfaceH
  end
  local g = love.graphics
  local prevCanvas = g.getCanvas()
  local ok = pcall(function()
    g.push("all")
    g.origin()
    g.setCanvas(animLayer)
    g.clear(0, 0, 0, 0)
    g.setBlendMode("alpha")
    g.setColor(1, 1, 1, 1)
    local dx, dy = BattleScene.animationOffset(battle, layout)
    g.translate(dx, dy)
    innerAnim(battle, false)
    g.pop()
  end)
  if not ok then pcall(g.pop, g) end
  if prevCanvas then pcall(g.setCanvas, g, prevCanvas)
  else pcall(g.setCanvas, g) end
  return ok and animLayer or nil
end

-- The staged fight's effects, for the VR eyes: the animation layer plus
-- the plane to stand it on (BattleScene.fxCard -- anchored so a hit
-- authored at a slot lands on the mon standing in for that slot). nil
-- while nothing is staged or no layer was rendered this frame.
function OverworldBattle.worldAnim()
  if not (session and session.arena and not session.broken) then return nil end
  local tex = session.animTex
  if not tex then return nil end
  local host = (session.state and session.state.map) or nil
  if not host then return nil end
  local groundY = BattleScene.groundY(host, session.arena)
  local shot = session.shot
  local layout = shot and shot.layout or BattleScene.layoutMetrics(session.battle)
  local anchors = shot and shot.anchors or layout.anchors
  local model = BattleScene.fxCard(session.arena, groundY,
                                   anchors, layout)
  if not model then return nil end
  return tex, model
end

-- Where the staged fight STANDS -- the arena and its floor height -- for a
-- camera that wants to look at it rather than draw it (the VR battle
-- mount). Answered as soon as the stage exists, textures or not: the
-- camera should be seated behind the fade before the first pic lands.
-- nil whenever no fight is staged on the world.
function OverworldBattle.stage()
  if not (session and session.arena and not session.broken) then return nil end
  local host = (session.state and session.state.map) or nil
  if not host then return nil end
  return session.arena, BattleScene.groundY(host, session.arena)
end

function OverworldBattle.invalidate()
  BattleDOF.invalidate()
  BattlePics.invalidate()
end

-- ------- the battle screen's background
--
-- BattleState opens by filling 160x144 white -- that fill IS the battle's
-- background, and in the colorized pipeline it is also the BG canvas's clear
-- (nothing else clears it, so skipping it outright would ghost last frame).
-- So for the length of one draw, that one call is intercepted: on the two
-- offscreen canvases it becomes a transparent clear, so the shade-remap pass
-- composites the HUD and the text box over the arena and leaves the empty
-- field showing it; on the screen it is simply dropped, because the UI canvas
-- has already been cleared transparent for the world to show through.
--
-- Matched exactly -- fill, the full frame, at the origin, in opaque white --
-- so the text box (a 20x6 box lower down), a mon pic, an HP bar and the
-- move-animation flash (which is white at 0.85) all pass through untouched.
--
-- This is a shim over love.graphics and it is the one invasive thing here,
-- so it is scoped as tightly as it can be: installed around a single call,
-- removed on the way out including on error, and never live outside a battle
-- frame this mode is drawing.
local function withoutBackgroundFill(battle, fn)
  local g = love.graphics
  local rectangle = g.rectangle
  local layout = BattleScene.layoutMetrics(battle)
  g.rectangle = function(mode, x, y, w, h, ...)
    if mode == "fill" and x == 0 and y == 0
       and w == layout.surfaceW and h == layout.surfaceH then
      local r, gr, b, a = g.getColor()
      if r > 0.99 and gr > 0.99 and b > 0.99 then
        -- Two different full-frame whites, both replaced rather than drawn.
        --
        -- OPAQUE is the battle's background, and on the offscreen canvases it
        -- doubles as their clear, so there it becomes a transparent one.
        --
        -- TRANSLUCENT is the hit flash. Over a white field that reads as a
        -- flash; over a world it whites out the map, the HUD and the text box
        -- together. BattleScene puts it back on the mons alone.
        if a > 0.99 then
          local target = g.getCanvas()
          if target ~= nil
             and (target == battle.bgCanvas or target == battle.waveCanvas) then
            g.clear(0, 0, 0, 0)
          end
        end
        return
      end
    end
    return rectangle(mode, x, y, w, h, ...)
  end
  local ok, err = pcall(fn, battle)
  g.rectangle = rectangle
  if not ok then error(err, 0) end
end

-- ------- the hour's light, on a pic that is not geometry
--
-- Everything standing in the arena goes through the voxel shader, and that
-- shader multiplies by the hour's tint: at dusk the whole diorama warms, at
-- night it goes blue, and the two mons' cards go with it because they are
-- drawn in the same pass as the ground they stand on.
--
-- A back pic pinned to the menu is not in that pass. It is the engine's own
-- flat blit over the finished shot, so it arrived at noon while the world
-- behind it was at midnight -- a mon lit by nothing in the frame.
--
-- So the tint is applied by hand, to that one draw. Every colour the pics
-- layer sets is multiplied on its way past, which is the whole of it: the
-- layer draws the pic with love.graphics.draw and LOVE multiplies by the draw
-- colour, so tinting the colour tints the pixels -- and the alpha, the faint
-- slide's fade and the blink's own colour all compose with it rather than
-- being overwritten.
--
-- What this does NOT get is the sun: the cards are shadow-mapped, so one
-- standing under a tree is darker than the tint alone, and this pic has no
-- position in the scene to be shadowed at. It carries the hour and not the
-- weather, which is the part the eye reads.
local function withTint(tint, fn, ...)
  if not tint then return fn(...) end
  local r, g, b = tint[1] or 1, tint[2] or 1, tint[3] or 1
  if r > 0.999 and g > 0.999 and b > 0.999 then return fn(...) end
  local gfx = love.graphics
  local setColor = gfx.setColor
  gfx.setColor = function(cr, cg, cb, ca, ...)
    if type(cr) == "table" then
      return setColor({ (cr[1] or 1) * r, (cr[2] or 1) * g, (cr[3] or 1) * b,
                        cr[4] }, cg, ...)
    end
    if cr == nil then return setColor(cr, cg, cb, ca, ...) end
    return setColor(cr * r, (cg or 1) * g, (cb or 1) * b, ca, ...)
  end
  local ok, err = pcall(fn, ...)
  gfx.setColor = setColor
  -- the layer leaves whatever colour it last set, and that one is tinted;
  -- hand the next caller plain white rather than a dimmed one
  setColor(1, 1, 1, 1)
  if not ok then error(err, 0) end
end

-- ------- the mons, as textures for the 3D pass
--
-- The two Pokemon are not composited over the world any more: they are quads
-- standing in it (see BattleBillboard). What that needs from the battle
-- screen is a TEXTURE per side -- and the honest way to get one is to let the
-- engine draw its own pics layer, unchanged, into a canvas.
--
-- So the layer is rendered twice, once per side, with the other side
-- falsified out of existence by nulling exactly the fields its branches
-- test. Everything the engine does to a pic comes along for free that way:
-- the trainer pic before the send-out, the grow-out-of-the-ball scale, the
-- faint slide, the damage blink, the squish, every SE displacement. None of
-- it is reimplemented and none of it can drift.
--
-- Two things are forced during that render. The scale, to 1, so the texture
-- carries the artwork's own pixels and the BILLBOARD does the sizing; and the
-- placement, so the pic lands centred on a known column with its feet on a
-- known row. That known point is what the quad is then hung from.
local TEX_AX, TEX_AY = 80, 96          -- forced pic centre and baseline
local TRAINER_AX, TRAINER_AY = 124, 56 -- the intro trainer pic's own slot

OverworldBattle.TEX_AX, OverworldBattle.TEX_AY = TEX_AX, TEX_AY

-- Which side is being rendered, or nil. The placement wrappers read it.
local texturing = nil

local texCanvas = {}
local innerPics = nil                   -- captured by install()
-- (innerAnim, their sibling, is declared up beside animTexture, which
-- sits earlier in the chunk than this group and must see the local)

local function texCanvasFor(side, metrics)
  local c = texCanvas[side]
  if c then return c end
  local ok, made = pcall(love.graphics.newCanvas, metrics.captureW,
                         metrics.captureH, { dpiscale = 1 })
  if not ok then return nil end
  made:setFilter("nearest", "nearest")
  texCanvas[side] = made
  return made
end

-- Whether this side has anything to draw at all. Mirrors drawPicsLayer's own
-- guards, so an empty canvas is never hung on a quad: a fainted, hidden or
-- not-yet-sent-out mon simply has no billboard this frame.
local function sideVisible(battle, side)
  if side == "enemy" then
    if battle.showEnemyTrainer and battle.trainerPic then return true end
    return (battle.enemy and battle.enemy.sprite and not battle.enemyHidden
            and not battle.enemySendingOut
            and not battle:fxHidden(battle.enemy)) and true or false
  end
  if battle.showPlayerBack and battle.playerBackPic then return true end
  local hide = battle.safari or battle.demo
  return (battle.player and battle.player.sprite and not hide
          and not battle.sendingOut
          and not battle:fxHidden(battle.player)) and true or false
end

local OFF = {
  enemy = { player = false, showPlayerBack = false },
  player = { enemy = false, showEnemyTrainer = false },
}

-- Render one side's pics layer into its canvas and report where the pic's
-- feet ended up, in canvas coordinates.
function OverworldBattle.sideTexture(battle, side)
  if not (innerPics and battle) then return nil end
  if not sideVisible(battle, side) then return nil end
  local metrics = BattleScene.layoutMetrics(battle)
  local canvas = texCanvasFor(side, metrics)
  if not canvas then return nil end

  local g = love.graphics
  local prevCanvas = g.getCanvas()
  local prevBlend, prevAlpha = g.getBlendMode()
  -- The pic-window scissors are in the battle screen's fixed coordinates and
  -- would clip a pic that has been moved to the middle of its own canvas.
  -- There is nothing here for them to protect -- no HUD, no text box, just
  -- the one pic -- so they are switched off for the render.
  local setScissor, intersectScissor = g.setScissor, g.intersectScissor
  local getScissor = g.getScissor
  g.setScissor = function() end
  g.intersectScissor = function() end
  g.getScissor = function() return nil end

  local saved = {}
  for k, v in pairs(OFF[side]) do saved[k] = battle[k]; battle[k] = v end
  texturing = side

  local ok, err = pcall(function()
    g.setCanvas(canvas)
    g.clear(0, 0, 0, 0)
    g.setBlendMode("alpha")
    g.setColor(1, 1, 1, 1)
    innerPics(battle, 0, 0, 0)
  end)

  texturing = nil
  for k in pairs(OFF[side]) do battle[k] = saved[k] end
  g.setScissor, g.intersectScissor, g.getScissor =
    setScissor, intersectScissor, getScissor
  if prevCanvas then g.setCanvas(prevCanvas) else g.setCanvas() end
  g.setBlendMode(prevBlend or "alpha", prevAlpha)
  if not ok then error(err, 0) end

  local ax, ay = TEX_AX, TEX_AY
  local trainer = false
  -- The intro trainer pic draws itself straight into its own 7x7 slot rather
  -- than through the placement helpers, so it is hung from that slot instead.
  if side == "enemy" and battle.showEnemyTrainer and battle.trainerPic then
    ax, ay, trainer = TRAINER_AX, TRAINER_AY, true
  elseif side == "player" and battle.showPlayerBack and battle.playerBackPic then
    trainer = true
  end
  return { canvas = canvas, ax = ax, ay = ay, trainer = trainer,
           captureW = metrics.captureW, captureH = metrics.captureH }
end

-- Whether the hit flash is showing this frame.
--
-- Mirrors BattleState:draw's own test, because the flash is a DRAW-time
-- decision there (a counter plus the frame parity that makes it flicker) and
-- there is no seam that reports it. Read-only, so the worst a future engine
-- change can do is flash on a frame the engine would not have.
function OverworldBattle.flashing(battle)
  local fx = battle and battle.fx
  if not (fx and fx.flash and fx.flash > 0) then return false end
  return (battle.frame or 0) % 4 < 2
end

-- Both sides, or nil when neither has anything to show.
--
-- One side under BACK SPRITES: the player's mon is not standing on the map at all
-- there, it is on the menu, so it has no card to be a texture for -- and
-- nothing downstream has to know that. No billboard, and no shadow on the
-- ground under a mon that is not on it.
function OverworldBattle.textures(battle)
  if not battle then return nil end
  local out = {}
  local provider = textureProvider or OverworldBattle.sideTexture
  local okE, enemy = pcall(provider, battle, "enemy")
  local okP, player = true, nil
  if not OverworldBattle.backPinned() then
    okP, player = pcall(provider, battle, "player")
  end
  out.enemy = okE and enemy or nil
  out.player = okP and player or nil
  -- This table must still come back when a side has no pic, because it
  -- carries the HIT FLASH, and because the VR eye pass uses its presence
  -- to decide there is a staged fight to draw at all.
  if not (out.enemy or out.player) then
    return nil
  end
  out.flash = OverworldBattle.flashing(battle)
  return out
end

-- ------- engine seams
--
-- Four wraps, each idempotent so a hot reload cannot stack them.

local function gen1BattleEngine()
  local ok, GameVersion = pcall(require, "src.core.GameVersion")
  return not (ok and GameVersion and type(GameVersion.generation) == "function"
              and tonumber(GameVersion.generation()) == 2)
end

function OverworldBattle.install()
  if not gen1BattleEngine() then return false end
  local OverworldState = require("src.world.OverworldController")
  if not OverworldState.dramaticShapeBattleHook then
    local inner = gen1BattleEngine() and OverworldState.pushBattle or nil
    -- The one place the overworld starts a battle, and it runs BEFORE the
    -- transition is pushed -- which is what lets the cull happen off-screen
    -- and the wipe play over a map with nobody on it.
    rawset(OverworldState, "pushBattle", function(self, battle)
      pcall(OverworldBattle.begin, self, battle)
      return inner(self, battle)
    end)
    OverworldState.dramaticShapeBattleHook = true
  end

  local BattleState = require("src.battle.BattleState")
  if BattleState.dramaticShapeBattleHook then return end

  -- Integer scales only. The camera is solved to make one overworld square
  -- exactly big enough for a pic at its own integer scale (see BattleCam), so
  -- the fit never has to come out of the pixels -- and a species override or
  -- a battle_sprite_scales entry that asks for 1.7x would undo that and
  -- resample the sprite into mush. Rounded rather than refused, so such a mod
  -- still gets the bigger or smaller mon it asked for, on the pixel grid.
  local innerScale = BattleState.resolveBattleScale
  function BattleState.resolveBattleScale(data, side, path, species)
    local base = innerScale(data, side, path, species)
    -- 1:1 into the billboard texture: the artwork's own pixels, with the
    -- quad's world size doing every bit of the scaling. Anything else would
    -- resample the sprite twice -- once into the texture and again on the way
    -- to the screen -- and a twice-resampled Gen 1 pic is mush.
    if texturing then return 1 end
    if not OverworldBattle.shot() then return base end
    return math.max(1, math.floor((tonumber(base) or 1) + 0.5))
  end

  -- Keyed-out whites inside a pic used to be filled by the white field
  -- behind it. There is a world back there now, so they are filled here
  -- instead -- see BattlePics, which puts the paper back without touching
  -- the silhouette.
  --
  -- The pinned pic is told that its feet are on the box, which is what lets
  -- the pale-bodied back sprites be filled at all: their bellies leak out
  -- through an opening too wide to read as a drain, and only the box under
  -- them settles that it is not a hole. Passed the pre-bake image, because
  -- that is the one the battle holds a reference to.
  local innerPic = BattleState.picImage
  function BattleState:picImage(img)
    local out = innerPic(self, img)
    if not OverworldBattle.shot() then return out end
    return BattlePics.filled(out, OverworldBattle.pinnedPic(self, img))
  end

  -- While a billboard texture is being rendered both pics are put in the same
  -- known place -- centred on TEX_AX with their feet on TEX_AY -- so the quad
  -- has one anchor to hang from whichever side and whichever species it is
  -- carrying. Outside that render both helpers answer exactly as they always
  -- did.
  local innerBack = gen1BattleEngine() and BattleState.backPlacement or nil
  rawset(BattleState, "backPlacement", function(w, h, pad, padL, scale)
    local x, y, s = innerBack(w, h, pad, padL, scale)
    if not texturing then return x, y, s end
    return TEX_AX - w * scale / 2, TEX_AY - (h - pad) * scale, s
  end)

  local innerFront = gen1BattleEngine() and BattleState.frontPlacement or nil
  rawset(BattleState, "frontPlacement", function(ex, ey, w, h, scale)
    local x, y, s = innerFront(ex, ey, w, h, scale)
    if not texturing then return x, y, s end
    return TEX_AX - w * scale / 2, TEX_AY - h * scale, s
  end)

  local innerDraw = BattleState.draw
  function BattleState:draw()
    local shot = OverworldBattle.shot()
    -- AskName blanks the field on purpose (the nickname prompt is meant to
    -- sit on nothing); leave that one alone.
    if not shot or self.blankForAskName then
      -- nil, not false: the class default is inherited again, so a battle
      -- that loses its arena mid-fight goes back to white voids
      self.letterboxWhite = nil
      self.dramaticShapeShot = nil
      return innerDraw(self)
    end
    self.dramaticShapeShot = shot
    -- The world reaches the screen through the seam a render pipeline's
    -- finished world image already uses: one window-resolution canvas,
    -- blitted a pixel to a pixel, with the 160x144 UI canvas composited over
    -- it in the classic letterbox afterwards. That is what makes the backdrop
    -- as crisp as the free-roam diorama while the pics and text stay GB art.
    local renderer = game().renderer
    if renderer and renderer.setWorldOverride then
      renderer:setWorldOverride(shot.canvas)
    end
    -- beginFrame clears the UI canvas white for an opaque state; the world is
    -- under it now, so clear it back to nothing and let it through. Safe to
    -- do here: an opaque battle is the lowest state drawn, so nothing has
    -- drawn into this canvas yet.
    love.graphics.clear(0, 0, 0, 0)
    -- the white letterbox exists so the window matches the white battle
    -- canvas; there is a world out to the window edges now
    self.letterboxWhite = false
    OverworldBattle.drawHudPanels(self)
    withoutBackgroundFill(self, innerDraw)
  end

  -- The mons are geometry standing on the map now, drawn in the 3D pass
  -- before this screen is composited at all, so the flat pics layer has
  -- nothing left to do here. Skipped rather than left to draw underneath, or
  -- every Pokemon would appear twice: once on its tile and once in its slot.
  --
  -- Except under BACK SPRITES, where the player's side never became geometry and this
  -- layer is the only thing that draws it. The engine's own onlySide argument
  -- does the whole job: one call, the player's branches alone, in the slot and
  -- at the scale the GB always put them -- feet on the box, 2x, back view.
  innerPics = BattleState.drawPicsLayer
  function BattleState:drawPicsLayer(slide, sx, sy, onlySide, skipMenuClip)
    local shot = self.dramaticShapeShot
    if not shot then
      return innerPics(self, slide, sx, sy, onlySide, skipMenuClip)
    end
    if OverworldBattle.backPinned() and onlySide ~= "enemy" then
      -- under the hour's own light, like everything else in the frame -- see
      -- withTint, and the tint BattleScene hands over with the shot.
      --
      -- Except on the wavy path, where the pic is baked into the GRAYSCALE bg
      -- canvas for the zone pass to colour by region. That pass keys off the
      -- red channel, and a night tint pulls red down -- it would not darken
      -- the mon, it would remap it to the wrong shade. SE_WAVY_SCREEN lasts a
      -- second and the hour survives it fine.
      local tint = not self.grayPics and shot.tint or nil
      return withTint(tint, innerPics, self, slide, sx, sy, "player",
                      skipMenuClip)
    end
  end

  -- The battle's text box and its menus draw the way they always did --
  -- over their own white paper. The frosted-glass panels they once sat on
  -- are gone (see the removals ADR), so nothing here is wrapped or taken
  -- away any more.

  -- Move animations are authored against the pics' fixed slots, and a single
  -- animation reaches across both sides, so there is no per-side offset to
  -- give them. They ride the average, which is where the pair's centre went
  -- -- a few pixels at most, and it keeps a hit landing on the mon it is
  -- aimed at instead of drifting off it.
  innerAnim = BattleState.drawAnimLayer
  function BattleState:drawAnimLayer(colorized)
    local shot = self.dramaticShapeShot
    if not shot then return innerAnim(self, colorized) end
    -- Move animations are authored against the pics' old fixed slots, and one
    -- animation reaches across both sides, so there is no per-side offset to
    -- give them. They ride to where the PAIR went: the midpoint of the two
    -- mons' projected positions, less the midpoint of the slots they used to
    -- sit in. A hit still lands on the mon it is aimed at.
    --
    -- And they ride the pair's SEPARATION as well, because the mons
    -- themselves do. Both are geometry standing on the map, so the camera
    -- sizes them: zoom in and they grow, swing round to side-on and the two
    -- marks close up as the axis foreshortens. A layer that only slid would
    -- have held the authored 106-pixel spacing through all of it -- a beam
    -- fired between two mons that are no longer that far apart, ending in
    -- the air beside the one it was aimed at. Scaling about the same
    -- midpoint keeps every authored offset the same fraction of the gap it
    -- was authored as.
    local a = shot.anchors or OverworldBattle.ANCHOR
    -- BACK SPRITES leaves the player's mon exactly where the GB put it, so that side
    -- contributes no movement at all and the pair's centre has gone half as
    -- far as the foe's mark did.
    local px, py = shot.player[1], shot.player[2]
    if OverworldBattle.backPinned() then px, py = a.player[1], a.player[2] end
    local cx, cy = (shot.enemy[1] + px) / 2, (shot.enemy[2] + py) / 2
    local ax = (a.enemy[1] + a.player[1]) / 2
    local ay = (a.enemy[2] + a.player[2]) / 2
    love.graphics.push()
    love.graphics.translate(cx - ax, cy - ay)
    -- Clamped, and skipped outright if the marks ever coincide: a
    -- degenerate projection must leave the effects the size they were
    -- rather than collapse them to nothing or blow them across the screen.
    local k = OverworldBattle.animScale(shot, px, py)
    if k ~= 1 then
      love.graphics.translate(ax, ay)
      love.graphics.scale(k, k)
      love.graphics.translate(-ax, -ay)
    end
    local ok, err = pcall(innerAnim, self, colorized)
    love.graphics.pop()
    if not ok then error(err, 0) end
  end

  -- The engine's flash has a SECOND half, and it is the one that reaches the
  -- menu. Beside the white rectangle (dropped above) the flash moves are
  -- driven by a BGP palette fade -- BGP_LIGHT and friends -- which the
  -- colorized pipeline applies in drawZonePass to the WHOLE background
  -- canvas. That canvas carries the HUD glyphs and the text box, so a fade
  -- meant for the two mons washed the menu out with them.
  --
  -- The fade is left switched on for the pics, which read it through
  -- picImage, and switched off for the zone pass alone. So the mons flash
  -- and the furniture around them does not.
  --
  -- The zone pass has a SECOND thing it paints, and this is the one that
  -- reads as the menu box flashing. A screen shake makes it fill every zone
  -- with the zone's own color 0 before it draws the offset copy -- the
  -- hardware showing empty BG in the strip the shake vacated. On a white
  -- battle field that fill is invisible; over a world it is an opaque white
  -- sheet across the whole frame, and since a shake program alternates
  -- offset and no-offset frames (SE_SHAKE_SCREEN steps dx 1, 0, 1, 0...) it
  -- switches on and off a few times a second. It is dropped: the background
  -- here is the map, so what the shake vacates should show the map.
  local innerZone = BattleState.drawZonePass
  function BattleState:drawZonePass(src, sx, sy)
    if not self.dramaticShapeShot then return innerZone(self, src, sx, sy) end
    -- shadow the method on the instance for this call only; putting the
    -- field back to whatever it was (normally nil) lets the class method be
    -- found again
    local had = rawget(self, "activeBgp")
    self.activeBgp = function() return nil end
    local g = love.graphics
    local rectangle = g.rectangle
    g.rectangle = function(mode, ...)
      -- the pass draws no other rectangle; the shake still shifts the copy
      if mode == "fill" then return end
      return rectangle(mode, ...)
    end
    local ok, err = pcall(innerZone, self, src, sx, sy)
    g.rectangle = rectangle
    self.activeBgp = had
    if not ok then error(err, 0) end
  end

  BattleState.dramaticShapeBattleHook = true
end

-- Whether each HUD block is on screen this frame.
--
-- READ-ONLY duplicates of drawHUDs' own guards. Honour the shared visibility
-- seam first so hidden HUDs do not leave their plain backings behind.
function OverworldBattle.hudLive(battle, slide)
  if battle.statusHUDVisible and not battle:statusHUDVisible() then
    return false, false
  end
  local enemy = battle.enemy and not battle.showEnemyTrainer
                and not battle.enemySendingOut
                and not battle:growInScale(battle.enemy) and slide == 0
                and not battle.introBalls
                and not battle.enemy.fainted
  local player = battle.player and not (battle.safari or battle.demo)
                 and not battle.showPlayerBack and slide == 0
  return enemy and true or false, player and true or false
end
--
-- The engine's own HUD layer, rendered into a texture.
--
-- One thing is falsified for the render, and it is falsified because this layer
-- never reaches the battle's zone pass -- it is composited into the world image,
-- outside the frame that pass covers. In the colorized pipeline drawHUDs leaves
-- the HP bar's fill as DMG gray for the zone pass to colour by region (#229);
-- answered false, it tints its own greens and reds instead, exactly as it does
-- on the flat path.
--
-- Shadowed on the instance for this call only, the way drawZonePass shadows
-- activeBgp: putting the field back to whatever it was (normally nil) lets the
-- class method be found again.
-- The engine owns the WIDE HUD panels and draws their bordered white boxes.
-- Keep this seam as a no-op for callers from older staged-battle builds, but
-- do not paint translucent backings over the world: those were the leftover
-- frosted-glass rectangles visible between the real HUD and the battle field.
function OverworldBattle.drawHudPanels(battle)
  return
end

return OverworldBattle
