-- Bounded atlas retention across one route handoff.
--
-- Keep the current live set and exactly one prior live set. This lets a
-- transition draw a map whose private animated atlas was warm in the
-- preceding frame, without retaining atlases for an entire play session.
local AtlasLiveSet = {}

local function copy(set)
  local out = {}
  for id, active in pairs(set or {}) do
    if active then out[id] = true end
  end
  return out
end

function AtlasLiveSet.advance(current, previous)
  local retained = copy(current)
  for id, active in pairs(previous or {}) do
    if active then retained[id] = true end
  end
  return retained, copy(current)
end

return AtlasLiveSet
