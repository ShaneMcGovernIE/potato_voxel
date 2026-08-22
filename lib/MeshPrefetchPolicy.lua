-- Runtime mesh priorities for the current map and its rendered neighbours.
--
-- Gen1Recomp exposes a two-hop (or view-expanded) neighbour list without the
-- BFS depth. The current map's authored connection table is the stable source
-- for deciding which entries are one crossing away; every other rendered map
-- is distant work and must not delay the next route transition.
local MeshPrefetchPolicy = {
  CURRENT_BODY = 400,
  DIRECT = 300,
  CURRENT_RING = 200,
  DISTANT = 100,
}

function MeshPrefetchPolicy.neighborPriorities(map, neighbors)
  local direct = {}
  local def = map and (map.def or map) or {}
  for _, connection in pairs(def.connections or {}) do
    if connection and connection.map then direct[connection.map] = true end
  end

  local priorities = {}
  for i, neighbor in ipairs(neighbors or {}) do
    local neighborMap = neighbor and neighbor.map
    local id = neighborMap and neighborMap.id or neighbor and neighbor.id
    priorities[i] = direct[id] and MeshPrefetchPolicy.DIRECT
                    or MeshPrefetchPolicy.DISTANT
  end
  return priorities
end

return MeshPrefetchPolicy
