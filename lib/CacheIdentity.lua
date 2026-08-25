-- Cache build identity and dataset revision.
-- This service has no storage side effects; MeshCache owns persistence and
-- keeps a compatibility facade for callers that already use identity().
local V = ...

local Brick = V.require("BrickProfile")

local CacheIdentity = {}

function CacheIdentity.new(ctx)
  local dataKey = "unconfigured"
  local GameVersion = nil
  do
    local ok, mod = pcall(require, "src.core.GameVersion")
    if ok then GameVersion = mod end
  end

  local function hashString(hash, value)
    value = tostring(value or "")
    for i = 1, #value do
      hash = (hash * 31 + value:byte(i)) % 2147483647
    end
    return hash
  end

  local function sortedKeys(table_)
    local keys = {}
    for key in pairs(table_ or {}) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
  end

  local function hashValues(hash, values)
    for i, value in ipairs(values or {}) do
      hash = hashString(hash, i)
      if type(value) == "table" then
        hash = hashValues(hash, value)
      else
        hash = hashString(hash, value)
      end
    end
    return hash
  end

  local function datasetRevision(data)
    local hash = 17
    hash = hashString(hash, data and data.profileRevision)
    hash = hashString(hash, data and data.voxelProfileRevision)
    -- see CachePrebuild.mapsOf: Gen 2 names this gen2Maps
    local maps = (data and (data.maps or data.gen2Maps)) or {}
    for _, id in ipairs(sortedKeys(maps)) do
      local def = maps[id]
      hash = hashString(hash, id)
      hash = hashString(hash, def.width)
      hash = hashString(hash, def.height)
      hash = hashString(hash, def.tileset)
      hash = hashString(hash, def.outdoor)
      hash = hashString(hash, def.borderBlock)
      hash = hashValues(hash, def.blocks)
      local connections = def.connections or {}
      for _, direction in ipairs(sortedKeys(connections)) do
        local connection = connections[direction]
        hash = hashString(hash, direction)
        hash = hashString(hash, connection.map)
        hash = hashString(hash, connection.offset)
        hash = hashString(hash, connection.walkable)
      end
    end
    do
      local okV, VA = pcall(function() return V.require("VoxAssets") end)
      if okV and VA and VA.revision then
        hash = hashString(hash, VA.revision())
      end
    end
    local tilesets = data and data.tilesets or {}
    for _, id in ipairs(sortedKeys(tilesets)) do
      local tileset = tilesets[id]
      hash = hashString(hash, id)
      hash = hashString(hash, tileset.image)
      hash = hashString(hash, tileset.imageWidth)
      hash = hashString(hash, tileset.imageHeight)
      hash = hashString(hash, tileset.trueColor)
      hash = hashString(hash, tileset.tilesPerRow)
      hash = hashString(hash, tileset.profileRevision)
      hash = hashValues(hash, tileset.blocks)
      hash = hashValues(hash, tileset.walkable)
      hash = hashValues(hash, tileset.counterTiles)
      hash = hashValues(hash, tileset.doorTiles)
      hash = hashValues(hash, tileset.warpTiles)
      hash = hashString(hash, tileset.grassTile)
    end
    return tostring(hash)
  end

  local function activeVersion()
    if GameVersion and GameVersion.get then return GameVersion.get() end
    return "red"
  end

  local function parts()
    local okTR, TileRenderer = pcall(require, "src.render.TileRenderer")
    local voidFill = (okTR and TileRenderer and TileRenderer.voidFill) or "trees"
    local profile = Brick.isBrick() and "b" or "f"
    return {
      format = "PVMC2",
      version = ctx.geometryVersion,
      activeVersion = activeVersion(),
      profile = profile,
      dataKey = dataKey,
      voidFill = tostring(voidFill),
    }
  end

  local function identity()
    local value = parts()
    return table.concat({ value.format, value.version, value.activeVersion,
                          value.profile, value.dataKey, value.voidFill }, "|"),
           value
  end

  local components = { "format", "version", "activeVersion", "profile",
                       "dataKey", "voidFill" }

  local function split(id)
    local value = {}
    for part in tostring(id):gmatch("([^|]*)") do
      if part ~= "" then value[#value + 1] = part end
    end
    return value
  end

  local service = {}

  function service.configure(data)
    dataKey = datasetRevision(data)
  end

  function service.parts()
    return parts()
  end

  function service.identity()
    local value = identity()
    return value
  end

  function service.identityDiff(expected, actual)
    local e = split(expected)
    local a = split(actual)
    local diffs = {}
    for i, name in ipairs(components) do
      if e[i] ~= a[i] then diffs[#diffs + 1] = name end
    end
    return diffs
  end

  return service
end

return CacheIdentity
