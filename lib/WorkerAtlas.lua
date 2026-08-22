-- Per-worker image-data cache. Cache key includes worker root and image path.
-- Worker jobs may use different tilesets; one job must never inherit another
-- job's ImageData.
local WorkerAtlas = {}

function WorkerAtlas.dimensionsMatch(image, expectedWidth, expectedHeight)
  if not image or type(image.getWidth) ~= "function"
     or type(image.getHeight) ~= "function" then
    return false
  end
  local okW, width = pcall(image.getWidth, image)
  local okH, height = pcall(image.getHeight, image)
  if not okW or not okH then return false end
  if expectedWidth ~= nil and width ~= expectedWidth then return false end
  if expectedHeight ~= nil and height ~= expectedHeight then return false end
  return true
end

function WorkerAtlas.new(loader)
  assert(type(loader) == "function", "worker atlas loader required")
  local cache = {}

  local service = {}

  function service:get(path, root)
    local pathKey = type(path) == "string" and path or tostring(path or "")
    local rootKey = type(root) == "string" and root or tostring(root or "")
    local key = rootKey .. "\0" .. pathKey
    local hit = cache[key]
    if hit ~= nil then
      if hit == false then return nil end
      return hit
    end
    local ok, image = pcall(loader, path, root)
    if not ok or not image then
      cache[key] = false
      return nil
    end
    cache[key] = image
    return image
  end

  function service:clear()
    cache = {}
  end

  return service
end

return WorkerAtlas
