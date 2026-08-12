-- lib/BrickProfile.lua
--
-- The tuning this build ships with. The fork is the TrimUI Brick build
-- (tg5040: 4x Cortex-A53 @1.8GHz, PowerVR GE8300, ~998MB RAM): it keeps the
-- diorama but not a desktop's frame budget, so every knob is pre-tuned here
-- and the mod is a single quality ladder.
--
-- There is ONE build -- this one, on every device. The old DS_BRICK
-- environment switch that could opt a device into the full desktop mod is
-- gone, so the profile applies unconditionally at load and no device runs
-- anything else.
--
-- One lever makes the collapse safe rather than fragile:
--
--   * ModSetting treats values[1] as the default AND the fallback for any
--     unrecognised stored value. Pinning a setting's ladder to a single
--     tuned rung is therefore the same thing as forcing that rung: a fresh
--     install, an unknown stored value and a gated-off read all resolve to
--     it. Nothing can move a knob the ladder no longer names.
local V = ...
local BrickProfile = {}

-- The profile is unconditional: this build IS the Brick build on every
-- device. isBrick() is kept as an always-true predicate so callers and the
-- test suite still have one name for "the tuning this build ships with".
BrickProfile.brick = true

function BrickProfile.isBrick()
  return BrickProfile.brick
end

-- The fraction of the window resolution the voxel scene is rendered at.
-- The RENDER SCALE knob (QualityMode) owns it now -- the quality modes
-- write it as part of their preset and the player can move it on its own --
-- so this reads the knob rather than deriving a scale from the VOXEL rung.
-- The composite folds the smaller canvas back up to the window with
-- ordinary canvas filtering, so the GE8300 fills a fraction of the pixels
-- per scene pass -- the single biggest frame-budget saving the fork has.
--
-- QualityMode is required LAZILY, not at load: BrickProfile is loaded early
-- (VoxelScene asks for it), and QualityMode's settings chain reaches back
-- through OverworldBattle and BattleScene to VoxelScene -- a load-time
-- require would recurse forever. By the time a scale is ever read the whole
-- mod is loaded and the require is a cache hit.
local function renderFraction()
  return V.require("QualityMode").renderFraction()
end

function BrickProfile.renderScale()
  return renderFraction()
end

-- The battle arena renders at the same RENDER SCALE knob. 3D-BTL can be on
-- while VOXEL is off, and the knob is still the right answer there: it is
-- what the player chose, not a mode the arena is not running under.
function BrickProfile.battleRenderScale()
  return BrickProfile.renderScale()
end

function BrickProfile.battleActorShadowMap(level)
  return level == 1
end

-- Moving actors are the expensive, frequently changing half of the real
-- shadow-map path. HIGH always uses the full two-layer map, including the
-- animated actor layer, on desktop, Android, and the Brick. MEDIUM and lower
-- keep the existing contact/blob decal fallback for actors. The world layer
-- remains governed by the renderer's existing shadow gates.
BrickProfile.DESKTOP_HIGH_LEVEL = 1
BrickProfile.DESKTOP_MEDIUM_LEVEL = 2

function BrickProfile.actorShadowMapEnabled(level)
  return level == BrickProfile.DESKTOP_HIGH_LEVEL
end

-- Active Brick rungs keep the cheap actor contact/blob fallback. The old
-- policy disabled every shadow at LOW and POTATO, which also disabled the
-- fallback decals and made NPCs appear to float. OFF remains shadow-free.
function BrickProfile.shadowsEnabled(level)
  return (level or 0) > 0
end

-- The pipeline record and the rows hook captured the VOXEL ladder by
-- reference, so the ladder is mutated IN PLACE. Reassigning the table would
-- leave the pipeline reading the old rungs.
local function replaceInPlace(target, values)
  for i = 1, #target do target[i] = nil end
  for i, v in ipairs(values) do target[i] = v end
  return target
end

-- Pin a setting ladder to one tuned rung. Clearing the cached index makes
-- the next ModSetting:read re-evaluate against the new ladder, so a value
-- already read during load still lands on the pinned rung.
local function pin(V, name, values, labels)
  local module = V.require(name)
  module.setting.values = values
  module.setting.labels = labels
  module.setting.index = nil
end

function BrickProfile.apply(V)
  local Voxel = V.require("VoxelState")
  local OverworldBattle = V.require("OverworldBattle")
  local ChunkMesher = V.require("ChunkMesher")
  local ShadowMap = V.require("ShadowMap")
  local Structures = V.require("Structures")

  -- GEOMETRY DENSITY: the border forest wraps the map edge at the FULL
  -- 3-block depth (12 tiles -- the same width the flat renderer's
  -- border ring draws). On desktop that ring used carved hulls, and on
  -- the Brick those hulls were the dominant geometry term (hundreds of
  -- thousands of quads nobody walks near), pushing the terrain mesh past
  -- the GE8300's ~1GB shared memory and SIGSEGVing the load path -- so
  -- the fork collapsed it to ROUND_RING=0, leaving open sky past every
  -- route edge. The billboard hulls below (HULL_BILLBOARDS) change the
  -- economics: a ring tree costs ~12 quads instead of ~3000, so the full
  -- ring returns as flat south-facing cards and the void past the map
  -- edge reads as dense forest again (worst measured: ROUTE_12 at ~94K
  -- quads, in line with the billboard body meshes the Brick already
  -- renders). The body, buildings and interior tree-lined cells are
  -- unaffected -- this only restores the border forest that wraps the
  -- map edge.
  Structures.ROUND_RING = 12

  -- BILLBOARD HULLS: the round carving collapses to a single flat
  -- south-facing card per hull (Structures roundTemplate). The Brick's
  -- orbit camera is fixed south, so a card reads correctly from every
  -- angle it will be seen from, and the delete of the back faces, side
  -- walls, flat tops and foot rows cuts the terrain mesh roughly 3x
  -- (~298K -> ~105K quads in Viridian).
  Structures.HULL_BILLBOARDS = true
  -- SPRITE CROSSHAIR: repeat each card at +45 and -45 degrees about the
  -- hull's vertical axis (an X cross in plan -- the classic crossed-
  -- billboard dome, the N64-era tree look). The Brick's camera is
  -- yaw-locked due south, so a true 90-degree cross arm would be edge-
  -- on and invisible; the 45-degree arms project at 70.7% width and
  -- their far-side top edges rise above the front card, giving the
  -- canopy slanted shoulders instead of a flat top. Cost is ~3x the
  -- flat card (~36 quads a tree), still ~80x cheaper than the carve.
  Structures.BILLBOARD_CROSS = true

  -- VOXEL becomes OFF / HIGH / MEDIUM / LOW / POTATO / CUSTOM. Every on-rung
  -- is the same classic 35-degree diorama framing (the FULL preset's camera);
  -- the rungs differ in what QualityMode's preset applies -- the RENDER
  -- SCALE and the quality knobs. CUSTOM is the player's own combination,
  -- reached the moment any knob leaves its mode's preset (QualityMode).
  -- FULL_LEVEL stays 1 because HIGH is FULL -- the engine's FULL branches
  -- still match -- and main.lua gates applyFull and the rows hook so the
  -- preset cannot re-enable the expensive rungs it would otherwise set
  -- on arrival.
  replaceInPlace(Voxel.ANGLES_DEG, { 0, 35, 35, 35, 35, 35 })
  replaceInPlace(Voxel.ANGLE_LABELS,
                 { "OFF", "HIGH", "MEDIUM", "LOW", "POTATO", "CUSTOM" })
  Voxel.MAX_LEVEL = #Voxel.ANGLES_DEG - 1
  Voxel.HOTKEY_ORDER = { 0, 1, 2, 3, 4 }
  if Voxel.level > Voxel.MAX_LEVEL then Voxel.level = 0 end

  -- The quality knobs are NOT pinned: every device runs this one build, and
  -- its settings are the player's to change from the VOXEL SETTINGS menu.
  -- The potato tuning is carried by the DEFAULTS (each knob's values[1]),
  -- not by locks -- WATER and FOREST FX reorder their ladders to OFF-first
  -- so the low-end default holds, and the higher rungs stay reachable for
  -- devices that can carry them.
  --
  --   3D-BTL is the one exception: its module default is 2D-3D A (staged
  --   battles ON), which would spend the whole frame budget by default, so
  --   it pins to a plain OFF / ON toggle.
  pin(V, "OverworldBattle", { false, true }, { "OFF", "ON" })

  -- The mesh pump yields sooner per frame on four cores: each chunk's
  -- carve-in spreads over more frames but never spikes one. The parent
  -- build's 12ms/5ms/30ms are tuned for desktop GPUs.
  ChunkMesher.URGENT_SLICE = 0.010
  ChunkMesher.IDLE_SLICE = 0.004
  ChunkMesher.COVERED_SLICE = 0.040

  -- The shadow pass is the one thing the render-scale fix does not touch:
  -- it is fitted to the VIEWPORT, not the 512x384 scene canvas, and the
  -- parent ladder {1024,1536,2048} keeps Pallet Town on the 2048 rung -- a
  -- 16MB depth pass re-rasterised every frame the shadow signature moves
  -- (every posed sprite animates it). At 0.5 scene scale a 1024 shadow
  -- map still resolves ~2 texels per scene pixel, so the 4x fill saving
  -- costs nothing visible on a handheld screen. Smaller maps can still
  -- pick the 768/512 rungs.
  ShadowMap.SIZES = { 512, 768, 1024 }
  -- HIGH must not depend on the fitted viewport dimensions: keep its full
  -- two-layer map deterministic at 1536x1536. MEDIUM and lower continue to
  -- use the reduced Brick ladder above.
  ShadowMap.BRICK_HIGH_RES = 1536

  -- HIGH uses the full two-layer map on Brick/Android as well as desktop.
  -- Lower Brick rungs turn the per-frame actor gate off in VoxelScene and
  -- continue using the existing flat contact/blob decals, while the world
  -- layer keeps the reduced Brick shadow policy.
  ShadowMap.SPRITE_LAYER = true
end

return BrickProfile
