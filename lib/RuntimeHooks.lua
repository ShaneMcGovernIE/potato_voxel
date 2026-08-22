-- Small install-once primitive for engine method wrappers.
-- Marker ownership stays with the engine object, matching the existing
-- compatibility guards while keeping wrapper setup out of feature modules.
local RuntimeHooks = {}

function RuntimeHooks.wrapOnce(owner, method, marker, build)
  if owner[marker] then return false end
  local inner = owner[method]
  owner[method] = build(inner)
  owner[marker] = true
  return true
end

return RuntimeHooks
