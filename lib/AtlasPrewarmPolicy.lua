-- Texture-atlas warmup targets for a map transition. Only the destination
-- is synchronous transition work; neighbour atlases resolve lazily if their
-- body mesh becomes drawable. Prewarming the whole two-hop neighbourhood
-- duplicated image work and delayed entry without preventing geometry pop-in.
local AtlasPrewarmPolicy = {}

function AtlasPrewarmPolicy.maps(current, neighbors)
  return current and current.id and { current } or {}
end

return AtlasPrewarmPolicy
