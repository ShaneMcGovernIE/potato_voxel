-- lib/BrickProfile.lua
--
-- The TrimUI Brick build of the fork. The Brick (tg5040: 4x Cortex-A53
-- @1.8GHz, PowerVR GE8300, ~998MB RAM) keeps the diorama but not the
-- desktop's frame budget, so every knob is pre-tuned here and the mod is
-- a single quality ladder.
--
-- This fork IS the Brick build, so the profile is the DEFAULT on every
-- device: the full desktop mod (the parent's 8-rung VOXEL ladder, the
-- T-SHIFT pipeline, every row on the OPTIONS menu) is one env var away
-- (DS_BRICK=0). Everything in this module is applied at load.
--
-- One lever makes the collapse safe rather than fragile:
--
--   * ModSetting treats values[1] as the default AND the fallback for any
--     unrecognised stored value. Pinning a setting's ladder to a single
--     tuned rung is therefore the same thing as forcing that rung: a fresh
--     install, an unknown stored value and a gated-off read all resolve to
--     it. Nothing can move a knob the ladder no longer names.
local BrickProfile = {}

function BrickProfile.on()
  -- DS_BRICK overrides the default on ANY device:
  --   DS_BRICK=1  force the Brick profile on
  --   DS_BRICK=0  force it off (the full desktop mod)
  -- Unset: ON -- this fork is the Brick build, so its tuning is what a
  -- fresh install gets everywhere.
  local force = os.getenv("DS_BRICK")
  if force == "1" then return true end
  if force == "0" then return false end
  return true
end

BrickProfile.brick = BrickProfile.on()

function BrickProfile.isBrick()
  return BrickProfile.brick
end

-- The fraction of the window resolution the voxel scene is rendered at
-- on the Brick, per VOXEL rung: HIGH renders the scene at the window's
-- own resolution, MEDIUM at 3/4, LOW at half -- the original 0.5 rung --
-- and POTATO at a third. The composite folds the smaller canvas back up to
-- the window with ordinary canvas filtering, so the
-- GE8300 fills a fraction of the pixels per scene pass -- the single
-- biggest frame-budget saving the fork has. Level 0 (OFF) never renders;
-- 1.0 is a harmless stand-in.
BrickProfile.RENDER_SCALES = { [1] = 1.0, [2] = 0.75, [3] = 0.5, [4] = 0.33 }

function BrickProfile.renderScale(level)
  if not BrickProfile.isBrick() then return 1 end
  return BrickProfile.RENDER_SCALES[level] or 1
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

-- HIGH, MEDIUM and LOW keep shadows; POTATO disables the shadow pass entirely
-- to preserve the rung's minimum frame budget. OFF remains shadow-free.
BrickProfile.POTATO_LEVEL = 4
function BrickProfile.shadowsEnabled(level)
  level = level or 0
  return level > 0 and level < BrickProfile.POTATO_LEVEL
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
  if not BrickProfile.isBrick() then return end

  local Voxel = V.require("VoxelState")
  local OverworldBattle = V.require("OverworldBattle")
  local TiltShift = V.require("TiltShift")
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

  -- VOXEL becomes OFF / HIGH / MEDIUM / LOW / POTATO. Every on-rung is the
  -- same classic 35-degree diorama framing (the FULL preset's camera); the
  -- rungs differ in RENDER SCALE (100% / 75% / 50% / 33%), which is the
  -- knob that buys frame budget on a handheld -- the sub-native rungs are
  -- folded back with ordinary canvas filtering. FULL_LEVEL stays 1
  -- because HIGH is FULL -- the engine's FULL branches still match -- and
  -- main.lua gates applyFull and the rows hook on the Brick so the
  -- preset cannot re-enable the expensive rungs it would otherwise set
  -- on arrival.
  replaceInPlace(Voxel.ANGLES_DEG, { 0, 35, 35, 35, 35 })
  replaceInPlace(Voxel.ANGLE_LABELS, { "OFF", "HIGH", "MEDIUM", "LOW", "POTATO" })
  Voxel.MAX_LEVEL = #Voxel.ANGLES_DEG - 1
  Voxel.HOTKEY_ORDER = { 0, 1, 2, 3, 4 }
  if Voxel.level > Voxel.MAX_LEVEL then Voxel.level = 0 end

  -- Every quality knob pins to its tuned rung.
  --   WATER      OFF  -- the reflective pass is the biggest fill-rate cost
  --                     after shadows, and a handheld diorama reads fine
  --                     without the lake's mirror; the player can still
  --                     turn it on per session.
  --   FOREST FX  OFF  -- the volumetric shafts and ground haze are the
  --                     single most expensive per-pixel pass in the mod
  --                     (FULL peaked near 40% of frame cost in forests);
  --                     the Brick's frame budget does not stretch to them.
  --   3D-BTL     OFF  -- a staged battle was the single biggest mid-battle
  --                     cost; flat card battles on the diorama floor.
  --   AA         OFF  -- OFF was already the default; the 4X rung's 4x
  --                     canvases are not worth a handheld's fill rate or
  --                     RAM.
  --   V-CURVE    OFF and V-GRID OFF -- the ornaments a fixed diorama does
  --                     not need.
  pin(V, "Water", { "off" }, { "OFF" })
  pin(V, "ForestAtmos", { "off" }, { "OFF" })
  pin(V, "OverworldBattle", { false }, { "OFF" })
  pin(V, "AntiAlias", { 0 }, { "OFF" })
  pin(V, "WorldCurve", { 0 }, { "OFF" })
  pin(V, "VoxelGrid", { false }, { "OFF" })

  -- BACK SPRITES decides what a STAGED battle frames; with 3D-BTL pinned
  -- off it decides nothing, so it is pinned off with it.
  OverworldBattle.backSetting.values = { false }
  OverworldBattle.backSetting.labels = { "OFF" }
  OverworldBattle.backSetting.index = nil

  -- T-SHIFT: the pipeline is not registered on the Brick (main.lua), so the
  -- blur never runs and its row and hotkey never exist. The LABELS table is
  -- still pinned in case anything reads it.
  replaceInPlace(TiltShift.LABELS, { "OFF" })
  TiltShift.level = 0

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
  -- MEDIUM and LOW turn the per-frame actor gate off in VoxelScene and
  -- continue using the existing flat contact/blob decals. POTATO disables
  -- the complete shadow pass, while HIGH keeps the two-layer map.
  ShadowMap.SPRITE_LAYER = true
end

return BrickProfile
