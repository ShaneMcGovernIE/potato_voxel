#!/usr/bin/env luajit
-- Inspect extracted Gen 2 tileset identifiers, tile/block layouts, and
-- collision quads. This is deliberately independent of the game so it can
-- be used while choosing a voxel replacement from the source artwork.
--
-- Examples:
--   luajit tools/inspect_tilesets.lua --list
--   luajit tools/inspect_tilesets.lua --tileset TILESET_JOHTO --block 0x5b
--   luajit tools/inspect_tilesets.lua --tileset TILESET_JOHTO --collision 0x12
--   luajit tools/inspect_tilesets.lua --tileset TILESET_JOHTO --tile 19
--   luajit tools/inspect_tilesets.lua --tileset TILESET_JOHTO \
--       --html /tmp/johto-tileset.html

local function fail(message)
  io.stderr:write("inspect_tilesets: " .. message .. "\n")
  os.exit(2)
end

local function parseNumber(value)
  if type(value) == "number" then return value end
  if type(value) ~= "string" then return nil end
  local hex = value:match("^0[xX]([%da-fA-F]+)$")
  if hex then return tonumber(hex, 16) end
  return tonumber(value)
end

local function hex(value, width)
  return string.format("0x%0" .. tostring(width or 2) .. "X", value)
end

local function sortedKeys(table_)
  local keys = {}
  for key in pairs(table_ or {}) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

local function countArray(values)
  local n = 0
  for i = 1, #(values or {}) do n = n + 1 end
  return n
end

local collisionNames = {
  [0x12] = "COLL_CUT_TREE",
  [0x15] = "COLL_HEADBUTT_TREE",
  [0x18] = "COLL_TALL_GRASS",
  [0x1A] = "COLL_CUT_TREE_1A",
  [0x1D] = "COLL_HEADBUTT_TREE_1D",
  [0x71] = "COLL_DOOR",
  [0x7A] = "COLL_STAIRCASE",
  [0x7B] = "COLL_CAVE",
}

local function collisionLabel(value)
  if value == nil then return "-" end
  local name = collisionNames[value]
  return name and (hex(value) .. " " .. name) or hex(value)
end

local function usage()
  print([[Usage:
  inspect_tilesets.lua --list
  inspect_tilesets.lua --tileset ID [--block ID] [--tile ID]
                       [--collision ID] [--html FILE]

Options:
  --data FILE       generated tilesets.lua (also checks POKEPORT_DATA_DIR)
  --list            list tileset identifiers and dimensions
  --tileset ID      select a tileset, for example TILESET_JOHTO
  --block ID        print one 4x4 block's graphics tiles and collision quad
  --tile ID         print atlas coordinates and every block occurrence
  --collision ID    list blocks containing a collision byte; --cut uses 0x12
  --html FILE       write a labeled atlas/block report for the selected set
  --cut             shorthand for --collision 0x12
  --help            show this help]])
end

local options = { data = nil, list = false, cut = false }
local i = 1
while i <= #arg do
  local key = arg[i]
  if key == "--help" or key == "-h" then
    usage()
    os.exit(0)
  elseif key == "--list" then
    options.list = true
  elseif key == "--cut" then
    options.cut = true
    options.collision = 0x12
  elseif key == "--data" or key == "--tileset" or key == "--block"
      or key == "--tile" or key == "--collision" or key == "--html" then
    i = i + 1
    if not arg[i] then fail(key .. " needs a value") end
    if key == "--data" then options.data = arg[i]
    elseif key == "--tileset" then options.tileset = arg[i]
    elseif key == "--html" then options.html = arg[i]
    else
      local value = parseNumber(arg[i])
      if value == nil then fail("invalid number for " .. key .. ": " .. arg[i]) end
      options[key:sub(3)] = value
    end
  else
    fail("unknown option " .. key)
  end
  i = i + 1
end

local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

local function dirname(path)
  return path:match("^(.*)/[^/]*$") or "."
end

local dataCandidates = {}
local function candidate(path)
  if path and path ~= "" then dataCandidates[#dataCandidates + 1] = path end
end
candidate(options.data)
if not options.data then
  local dataRoot = os.getenv("POKEPORT_DATA_DIR")
  candidate(dataRoot and (dataRoot .. "/generated/tilesets.lua"))
  candidate(dataRoot and (dataRoot .. "/tilesets.lua"))
  candidate("data/generated/tilesets.lua")
  candidate("data/tilesets.lua")
  candidate("/Users/shanemcgovern/Library/Application Support/"
    .. "pokemon-love2d/crystal/data/generated/tilesets.lua")
end

local dataPath
for _, path in ipairs(dataCandidates) do
  if exists(path) then dataPath = path; break end
end
if not dataPath then
  fail("could not find generated tilesets.lua; pass --data FILE")
end

local ok, loaded = pcall(dofile, dataPath)
if not ok or type(loaded) ~= "table" then
  fail("could not load " .. dataPath .. ": " .. tostring(loaded))
end
local tilesets = loaded.tilesets or loaded

local function blockCount(tileset)
  return countArray(tileset and tileset.blocks)
end

local function tileCount(tileset)
  local width = tonumber(tileset and tileset.imageWidth) or 128
  return math.floor(width / 8) * math.floor(width / 8)
end

local function blockAt(tileset, id)
  return tileset and tileset.blocks and tileset.blocks[id + 1]
end

local function collisionAt(tileset, id)
  return tileset and tileset.collision and tileset.collision[id + 1]
end

local function printList()
  print("Source: " .. dataPath)
  print("Tileset identifiers:")
  for _, id in ipairs(sortedKeys(tilesets)) do
    local t = tilesets[id]
    if type(t) == "table" then
      print(string.format("  %-32s image=%s atlas=%sx%s blocks=%d",
        tostring(id), tostring(t.image or "-"),
        tostring(t.imageWidth or "?"), tostring(t.imageHeight or "?"),
        blockCount(t)))
    end
  end
end

local function printGrid(tileset, id)
  local block = blockAt(tileset, id)
  if type(block) ~= "table" then
    print(string.format("  block %s is not present", hex(id)))
    return
  end
  print(string.format("  block %s (%d) graphics tiles:", hex(id), id))
  for row = 0, 3 do
    local values = {}
    for col = 0, 3 do
      values[#values + 1] = string.format("%3d", block[row * 4 + col + 1] or -1)
    end
    print("    " .. table.concat(values, " "))
  end
  local collision = collisionAt(tileset, id)
  if collision then
    print("  collision quad:")
    for row = 0, 1 do
      local values = {}
      for col = 0, 1 do
        local value = collision[row * 2 + col + 1]
        values[#values + 1] = string.format("%s", collisionLabel(value))
      end
      print("    " .. table.concat(values, " | "))
    end
  else
    print("  collision quad: -")
  end
end

local function printTile(tileset, id)
  local width = tonumber(tileset.imageWidth) or 128
  local perRow = math.floor(width / 8)
  local row, col = math.floor(id / perRow), id % perRow
  print(string.format("Tile %d (%s): atlas tile column=%d row=%d pixels=(%d,%d)",
    id, hex(id), col, row, col * 8, row * 8))
  local found = 0
  for blockId = 0, blockCount(tileset) - 1 do
    local block = blockAt(tileset, blockId)
    if block then
      for pos = 1, 16 do
        if block[pos] == id then
          found = found + 1
          print(string.format("  block %s (%d), local tile=(%d,%d)",
            hex(blockId), blockId, (pos - 1) % 4, math.floor((pos - 1) / 4)))
        end
      end
    end
  end
  if found == 0 then print("  no block uses this tile") end
end

local function printCollision(tileset, wanted)
  print(string.format("Blocks containing collision %s:", collisionLabel(wanted)))
  local found = 0
  for blockId = 0, blockCount(tileset) - 1 do
    local collision = collisionAt(tileset, blockId)
    if collision then
      local hit = false
      for pos = 1, 4 do
        if collision[pos] == wanted then hit = true; break end
      end
      if hit then
        found = found + 1
        printGrid(tileset, blockId)
      end
    end
  end
  if found == 0 then print("  none") end
end

local function htmlEscape(value)
  local escaped = tostring(value)
  escaped = escaped:gsub("&", "&amp;")
  escaped = escaped:gsub("<", "&lt;")
  escaped = escaped:gsub(">", "&gt;")
  escaped = escaped:gsub('"', "&quot;")
  return escaped
end

local function fileUri(path)
  local uri = tostring(path):gsub("%%", "%%25")
  uri = uri:gsub(" ", "%%20")
  uri = uri:gsub("#", "%%23")
  return "file://" .. uri
end

local function writeHtml(tilesetId, tileset, output)
  local sourceDir = dirname(dirname(dirname(dataPath)))
  local image = tileset.image
  local imagePath = image
  if image and image:sub(1, 1) ~= "/" then imagePath = sourceDir .. "/" .. image end
  local width = tonumber(tileset.imageWidth) or 128
  local height = tonumber(tileset.imageHeight) or 48
  local perRow = math.floor(width / 8)
  local f = assert(io.open(output, "wb"))
  f:write("<!doctype html><meta charset='utf-8'><title>Tileset ",
    htmlEscape(tilesetId), "</title><style>")
  f:write([[body{font:14px system-ui,sans-serif;background:#202124;color:#eee;padding:20px}
h1{font-size:20px}.atlas{position:relative;display:inline-block;background:#000;border:1px solid #777}
.atlas img{display:block;width:]], tostring(width), [[px;height:]], tostring(height),
    [[px;image-rendering:pixelated}.tile{position:absolute;width:8px;height:8px;
box-sizing:border-box;border:1px solid rgba(255,255,255,.12);font:5px monospace;color:#fff;
text-shadow:0 0 2px #000,0 0 2px #000;text-align:center;line-height:8px}
details{margin:8px 0;background:#2b2c2f;padding:6px}table{border-collapse:collapse}
td,th{border:1px solid #555;padding:3px 5px;font-family:monospace}code{color:#9cdcfe}
]] )
  f:write("</style><h1>", htmlEscape(tilesetId), "</h1><p>Source: <code>",
    htmlEscape(dataPath), "</code><br>Atlas: <code>",
    htmlEscape(imagePath or "missing"), "</code></p><div class='atlas'>")
  if imagePath and exists(imagePath) then
    f:write("<img src='", htmlEscape(fileUri(imagePath)), "'>")
  else
    f:write("<div style='width:", width, "px;height:", height,
      "px;color:#f88;padding:8px'>Atlas image not found</div>")
  end
  for id = 0, perRow * math.floor(height / 8) - 1 do
    local col, row = id % perRow, math.floor(id / perRow)
    f:write("<span class='tile' title='tile ", id, "' style='left:",
      col * 8, "px;top:", row * 8, "px'>", id, "</span>")
  end
  f:write("</div><h2>Blocks</h2>")
  for blockId = 0, blockCount(tileset) - 1 do
    local block = blockAt(tileset, blockId)
    if block then
      f:write("<details><summary><code>", hex(blockId), "</code> (", blockId,
        ")</summary><table><tr>")
      for pos = 1, 16 do
        if (pos - 1) % 4 == 0 and pos > 1 then f:write("</tr><tr>") end
        f:write("<td>", tostring(block[pos] or "-"), "</td>")
      end
      f:write("</tr></table>")
      local collision = collisionAt(tileset, blockId)
      if collision then
        f:write("<p>collision: ")
        for pos = 1, 4 do
          if pos > 1 then f:write(" | ") end
          f:write(htmlEscape(collisionLabel(collision[pos])))
        end
        f:write("</p>")
      end
      f:write("</details>")
    end
  end
  f:close()
  print("Wrote " .. output)
end

if options.list or not options.tileset then
  printList()
  if not options.tileset then os.exit(0) end
end

local tileset = tilesets[options.tileset]
if type(tileset) ~= "table" then
  fail("unknown tileset " .. tostring(options.tileset))
end
print(string.format("Tileset %s: image=%s atlas=%sx%s blocks=%d",
  options.tileset, tostring(tileset.image or "-"),
  tostring(tileset.imageWidth or "?"), tostring(tileset.imageHeight or "?"),
  blockCount(tileset)))
if options.block then printGrid(tileset, options.block) end
if options.tile then printTile(tileset, options.tile) end
if options.collision then printCollision(tileset, options.collision) end
if options.html then writeHtml(options.tileset, tileset, options.html) end
