-- Voxel world mode: the map haze PROFILE -- hand-authored entries for
-- the maps that want weather, read through the mod's own loader like
-- voxel_heights.
--
-- The FOREST FX feature this descends from was removed in 1.6.1 because
-- its QUALITY LADDER was shaped by an Android OS probe the sandbox made
-- impossible to ask (see docs/adr/0004-feature-removals.md) -- the haze
-- itself was never the problem. The scene shader has kept its fog path
-- the whole time (Voxel3D: the vertex-stage vFog, the fogColor mix), so
-- this file plus lib/MapAtmos.lua restores it data-driven: an entry here
-- names what the fog IS, the ATMOS row decides whether it draws, and no
-- shader, geometry or engine seam is touched.
--
-- Entry shape (the same table Voxel3D.fog carries):
--
--   color     what the haze is made of, as {r, g, b} in 0..1
--   density   how fast distance fills the haze in (1 - exp(-density*d))
--   start     world pixels of clear air before the haze begins
--   heightK   how fast altitude climbs OUT of it (multiplies e^-y*heightK)
--
-- A map with no entry (or the row off) draws under clear air, exactly as
-- it always did. A wrong map id costs nothing -- no entry matches, no fog.
-- Nothing here reaches gameplay; a haze can only change how a map LOOKS.

return {
  -- the forest the forest is named for
  VIRIDIAN_FOREST = {
    color = { 0.42, 0.60, 0.35 },
    density = 0.0015,
    start = 30,
    heightK = 0.004,
  },

  -- cave gloom: walls fade into the dark before the void does
  MT_MOON_1F = {
    color = { 0.08, 0.09, 0.12 },
    density = 0.004,
    start = 20,
    heightK = 0,
  },
  MT_MOON_B1F = {
    color = { 0.08, 0.09, 0.12 },
    density = 0.004,
    start = 20,
    heightK = 0,
  },
  MT_MOON_B2F = {
    color = { 0.08, 0.09, 0.12 },
    density = 0.004,
    start = 20,
    heightK = 0,
  },
  ROCK_TUNNEL_1F = {
    color = { 0.08, 0.09, 0.12 },
    density = 0.004,
    start = 20,
    heightK = 0,
  },
  ROCK_TUNNEL_B1F = {
    color = { 0.08, 0.09, 0.12 },
    density = 0.004,
    start = 20,
    heightK = 0,
  },
  DIGLETTS_CAVE = {
    color = { 0.10, 0.08, 0.07 },
    density = 0.005,
    start = 16,
    heightK = 0,
  },
  CERULEAN_CAVE_1F = {
    color = { 0.07, 0.09, 0.12 },
    density = 0.004,
    start = 20,
    heightK = 0,
  },
  CERULEAN_CAVE_2F = {
    color = { 0.07, 0.09, 0.12 },
    density = 0.004,
    start = 20,
    heightK = 0,
  },
  CERULEAN_CAVE_B1F = {
    color = { 0.07, 0.09, 0.12 },
    density = 0.004,
    start = 20,
    heightK = 0,
  },
}
