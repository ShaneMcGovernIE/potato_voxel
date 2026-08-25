-- Compact geometry-only map snapshot.
--
-- MapLoader objects contain renderer back-references and engine methods.  The
-- worker boundary gets this projection instead, so one map can be released
-- as soon as its bounded chunks are acknowledged.
local GeometrySnapshot = {}

local DEFAULT_MAX_VALUES = 2000000
local DEFAULT_MAX_BYTES = 8 * 1024 * 1024

local function copy(value, depth, state)
  local t = type(value)
  if t == "nil" or t == "boolean" or t == "string" then return value end
  if t == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      error("geometry snapshot contains non-finite number", 0)
    end
    return value
  end
  if t ~= "table" then
    error("geometry snapshot contains unsupported " .. t, 0)
  end
  if depth > 6 then error("geometry snapshot is too deep", 0) end
  state.values = state.values + 1
  if state.values > state.maxValues then
    error("geometry snapshot exceeds value bound", 0)
  end
  local out = {}
  for key, item in pairs(value) do
    local kt = type(key)
    if kt ~= "string" and kt ~= "number" then
      error("geometry snapshot contains unsupported key", 0)
    end
    out[key] = copy(item, depth + 1, state)
  end
  return out
end

local function field(source, name, state)
  return copy(source and source[name], 0, state)
end

function GeometrySnapshot.fromMap(map, masks, voidFill, options)
  assert(type(map) == "table" and type(map.def) == "table",
         "geometry snapshot requires map definition")
  assert(type(map.tileset) == "table", "geometry snapshot requires tileset")
  options = options or {}
  local state = { values = 0, maxValues = options.maxValues or DEFAULT_MAX_VALUES }
  local def, tileset = map.def, map.tileset
  local snapshot = {
    format = "PVGS1",
    id = field(map, "id", state),
    def = {
      width = field(def, "width", state),
      height = field(def, "height", state),
      tileset = field(def, "tileset", state),
      outdoor = field(def, "outdoor", state),
      borderBlock = field(def, "borderBlock", state),
      blocks = field(def, "blocks", state),
      connections = field(def, "connections", state),
    },
    tileset = {
      id = field(tileset, "id", state),
      image = field(tileset, "image", state),
      trueColor = field(tileset, "trueColor", state),
      tilesPerRow = field(tileset, "tilesPerRow", state),
      imageWidth = field(tileset, "imageWidth", state),
      imageHeight = field(tileset, "imageHeight", state),
      blocks = field(tileset, "blocks", state),
      collision = field(tileset, "collision", state),
      walkable = field(tileset, "walkable", state),
      counterTiles = field(tileset, "counterTiles", state),
      doorTiles = field(tileset, "doorTiles", state),
      warpTiles = field(tileset, "warpTiles", state),
      grassTile = field(tileset, "grassTile", state),
      profileRevision = field(tileset, "profileRevision", state),
    },
    walkable = field(map, "walkable", state),
    waterTiles = field(map, "waterTiles", state),
    counterTiles = field(map, "counterTiles", state),
    doorTiles = field(map, "doorTiles", state),
    warpTiles = field(map, "warpTiles", state),
    grassTile = field(map, "grassTile", state),
    masks = copy(masks or {}, 0, state),
    voidFill = tostring(voidFill or "trees"),
    authoredProfileRevision = field(map, "profileRevision", state)
      or field(def, "profileRevision", state),
  }
  return snapshot
end

local function dump(value, out, depth)
  local t = type(value)
  if t == "nil" then out[#out + 1] = "nil"; return end
  if t == "string" then out[#out + 1] = string.format("%q", value); return end
  if t == "number" then out[#out + 1] = string.format("%.17g", value); return end
  if t == "boolean" then out[#out + 1] = tostring(value); return end
  if t ~= "table" then error("snapshot source contains " .. t, 0) end
  if depth > 8 then error("snapshot source is too deep", 0) end
  local keys = {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b)
    if type(a) == type(b) then return tostring(a) < tostring(b) end
    return type(a) < type(b)
  end)
  out[#out + 1] = "{"
  for _, key in ipairs(keys) do
    out[#out + 1] = "["
    dump(key, out, depth + 1)
    out[#out + 1] = "]="
    dump(value[key], out, depth + 1)
    out[#out + 1] = ","
  end
  out[#out + 1] = "}"
end

function GeometrySnapshot.toSource(snapshot, maxBytes)
  assert(type(snapshot) == "table" and snapshot.format == "PVGS1",
         "invalid geometry snapshot")
  local out = { "return " }
  dump(snapshot, out, 0)
  local source = table.concat(out)
  if #source > (maxBytes or DEFAULT_MAX_BYTES) then
    error("geometry snapshot exceeds byte bound", 0)
  end
  return source
end

return GeometrySnapshot
