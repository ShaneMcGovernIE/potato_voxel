-- Voxel world mode: the WEATHER profile -- hand-authored entries naming
-- the maps that want falling weather, read through the mod's own loader
-- like voxel_atmos and voxel_heights.
--
-- Entry shape:
--
--   kind      "rain" or "snow" -- what falls
--   density   0..1, how thick the fall is (the drop pool scales to it)
--
-- A map with no entry (or the WEATHER row off) gets no weather. A wrong
-- map id costs nothing. Entries belong on OUTDOOR maps -- the drops fall
-- through the whole diorama, and an indoor ceiling has nothing to do
-- with them -- but the profile cannot know that, so authoring is the
-- gate, exactly like the atmos profile.
--
-- Nothing here reaches gameplay: weather is a visual overlay, drawn
-- through the same FX seam the "!" bubble and the fishing rod use.

return {
  -- the forest pairs its haze with a light canopy drizzle
  VIRIDIAN_FOREST = {
    kind = "rain",
    density = 0.5,
  },

  -- a total conversion with a cold region would add, e.g.:
  -- ROUTE_16 = { kind = "snow", density = 0.7 },
}
