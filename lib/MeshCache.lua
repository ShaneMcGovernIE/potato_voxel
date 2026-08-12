-- lib/MeshCache.lua
--
-- Pre-compiled voxel meshes: persist the finished vertex streams a map's
-- build produced, so a later visit -- or a whole later session -- UPLOADS
-- the geometry instead of re-running the Structures analysis and triangle
-- generation. That cold build is what makes the 2D -> diorama transition
-- take seconds on the TrimUI Brick (4x A53 @1.8GHz); with a warm cache it
-- is a file read plus the same sliced GPU upload the build already does.
--
-- Active on every device (the Brick, desktops, other handhelds): the
-- cache is a strict win -- it can speed a build up but never changes
-- what a build produces. On ANY failure: a corrupt file, a full SD card,
-- a missing directory, a fingerprint mismatch -- this is a silent no-op.
--
-- What is stored: one binary file per (map, slot, kind), the same
-- 6-float-per-vertex unindexed stream the GPU meshes hold (position,
-- texcoord, shade). A mesh is rebuilt by streaming the file straight into
-- a love Mesh, so nothing about the 3D models is re-derived. The header
-- carries the fingerprint everything the geometry depends on: the mesher
-- version, the brick-profile knobs that change the geometry, the map id,
-- the tileset art path, and the true-colour flag (RED++ bakes a per-map
-- atlas whose UV layout is its own). A mismatch is a miss, so stale files
-- can never serve wrong geometry.
--
-- Files live under the engine's save root, in mod-derived/<id>/meshes/:
-- on the Brick that is the PORTABLE folder (lovegame/mod-derived/ -- the
-- SD card, not the firmware flash); everywhere else it is the LÖVE save
-- directory (the same io-rooted location the engine saves to). They are
-- dropped by ChunkMesher.invalidate/refresh when a block edit changes
-- the inputs, so an edit never serves a stale mesh. Cache files are a
-- few MB per map; stale ones are removed by the fingerprint check.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Brick = V.require("BrickProfile")
local Budget = V.require("BuildBudget")

local ffi = nil
do
  local ok, mod = pcall(require, "ffi")
  if ok then ffi = mod end
end

-- The engine's save-root resolver. On the Brick (portable mode on) this
-- is the SD-card lovegame dir; everywhere else it is nil and dir() falls
-- back to the LÖVE save directory.
local SaveData = nil
do
  local ok, mod = pcall(require, "src.core.SaveData")
  if ok then SaveData = mod end
end

local GameVersion = nil
do
  local ok, mod = pcall(require, "src.core.GameVersion")
  if ok then GameVersion = mod end
end

local MeshCache = {}
local dataKey = "unconfigured"
local dirty = false
local compression = "unknown"
local MANIFEST = "cache.info"

-- Bump when the meshing algorithm changes the vertex/UV output, so a
-- cache written by an older build is never trusted by a newer one. (The
-- mod version alone is not enough: a settings-only release changes no
-- geometry.) NOTE: this is the CACHE FORMAT, not the file layout -- the
-- layout has its own magic+version byte inside the file.
-- 4: the fingerprint gained the brick/full profile token. Brick ON and
-- OFF produce different geometry from the same mod id (billboard hulls,
-- no round ring), so the token keeps a brick-built mesh from ever being
-- served to full mode and vice-versa.
-- 5: the brick profile restores the full 12-tile border forest ring as
-- billboard cards (BrickProfile ROUND_RING 0 -> 12). Brick meshes built
-- before this bump have no ring past the map edge and must not be
-- served. Full-mode meshes are unchanged (their ring depth never moved),
-- but the version is shared across profiles, so both rebuild once.
-- 6: the brick's billboard hulls gain sprite stacking (BILLBOARD_LAYERS
-- 3 / STEP 4): the flat south-facing card is repeated at stepped depths
-- so canopies read as layered foliage. Every brick mesh changes; the
-- full carve never reads those fields, so full-mode geometry is
-- identical, but the shared version bumps both profiles once.
-- 7: sprite stacking is replaced by the sprite CROSSHAIR
-- (BILLBOARD_CROSS): each card is repeated at +45/-45 degrees about the
-- hull's vertical axis (the crossed-billboard dome). Every brick mesh
-- changes again; the full carve never reads the field.
-- 8: the crosshair is replaced by the full 360 SPRITE FAN
-- (BILLBOARD_ARMS): N vertical planes through the hull's axis at
-- azimuths k*180/N (the classic N64-era tree). Every brick mesh changes
-- again; the full carve never reads the field.
-- 9: REVERTED to the crosshair (brick.10): the fan's extra planes only
-- darkened the canopy interior (silhouette byte-identical at 4 planes)
-- and cost 2-3x the quads, so the brick goes back to BILLBOARD_CROSS.
-- Fan meshes from version 8 must not be served.
-- 10: terrain/water payloads become INDEXED (4 verts per quad + a u32
-- vertex map instead of 6 duplicated verts) -- ~33% fewer vertices
-- uploaded and transformed, zero visual change. Payload layout changed
-- (an index section follows the vertex stream), so every cache file
-- written before this bump must be discarded. Aux payloads (grass,
-- flowers, figures) keep the unindexed 6-vert layout.
-- 11: the index values in version-10 files were written 1-based, but
-- LOVE's Data vertex maps are RAW 0-BASED (table maps are 1-based;
-- Data maps are not converted) -- every triangle referenced vertices
-- one slot too far and the scene rendered as grey mush. The sink now
-- writes 0-based indices; every version-10 cache file must die.
-- 12: AUX payloads (grass/flowers/figures) become indexed too -- they
-- were the last unindexed 6-vert-per-quad streams, wasting the same
-- 33% duplicated corners brick.11 removed from terrain/water. Their
-- payloads now carry the u32 vertex map section like the terrain ones,
-- so every aux file written before this bump must be discarded.
-- 13: Method 3 adds dedicated octagonal stump geometry and changes the
-- billboard hull's cut-face projection; every existing stump mesh is stale.
-- 14: the OVERWORLD CUT bush now emits a dedicated 16-quad low-poly model
-- from the pinned prop path; cached auxiliary/object geometry must rebuild.
-- 16: CUT uses sprite stacking with region-relative atlas/state indexing and
-- isolates adjacent same-class props; all derived meshes must be regenerated.
-- 17: cache headers include the active ROM/data identity, so a Red/Blue/
-- Yellow switch or a changed map dataset can never reuse old geometry.
MeshCache.GEOMETRY_VERSION = 17

-- A small deterministic revision for the inputs that can change terrain
-- output without changing the mesher. It is intentionally not a checksum:
-- it only separates cache generations, while the file headers still validate
-- the actual payloads.
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
  local maps = data and data.maps or {}
  for _, id in ipairs(sortedKeys(maps)) do
    local def = maps[id]
    hash = hashString(hash, id)
    hash = hashString(hash, def.width)
    hash = hashString(hash, def.height)
    hash = hashString(hash, def.tileset)
    hash = hashString(hash, def.borderBlock)
    hash = hashValues(hash, def.blocks)
    local connections = def.connections or {}
    for _, direction in ipairs(sortedKeys(connections)) do
      local connection = connections[direction]
      hash = hashString(hash, direction)
      hash = hashString(hash, connection.map)
      hash = hashString(hash, connection.offset)
    end
  end
  local tilesets = data and data.tilesets or {}
  for _, id in ipairs(sortedKeys(tilesets)) do
    local tileset = tilesets[id]
    hash = hashString(hash, id)
    hash = hashString(hash, tileset.image)
    hash = hashString(hash, tileset.trueColor)
    hash = hashString(hash, tileset.tilesPerRow)
    hash = hashValues(hash, tileset.blocks)
  end
  return tostring(hash)
end

local function activeVersion()
  if GameVersion and GameVersion.get then return GameVersion.get() end
  return "red"
end

local function identity()
  local okTR, TileRenderer = pcall(require, "src.render.TileRenderer")
  local voidFill = (okTR and TileRenderer and TileRenderer.voidFill) or "trees"
  local profile = Brick.isBrick() and "b" or "f"
  return table.concat({ "PVMC1", MeshCache.GEOMETRY_VERSION, activeVersion(),
                        profile, dataKey, tostring(voidFill) }, "|")
end

function MeshCache.configure(data)
  dataKey = datasetRevision(data)
  dirty = false
  compression = "unknown"
end

function MeshCache.isDirty()
  return dirty
end

function MeshCache.compressionStatus()
  return compression
end

MeshCache.identity = identity

-- ---------------------------------------------------------- availability

local dirTried = false
local cacheDir = false          -- resolved once; false when unusable

-- The shell commands that create the cache directory tree. Windows cmd has
-- no `mkdir -p`: it cannot create missing parents and errors when the
-- target already exists, so emit one guarded `if not exist ... mkdir ...`
-- per component below the drive root (each level idempotent -- creating a
-- missing level or skipping an existing one both exit cleanly). Everywhere
-- else a single POSIX `mkdir -p` (stderr silenced) is enough. Exported so
-- the headless suite can assert the exact commands without running cmd.exe.
local function mkdirCommands(dir, sep)
  if sep ~= "\\" then
    local q = dir:gsub('"', '\\"')
    return { 'mkdir -p "' .. q .. '" 2>/dev/null' }
  end
  local commands = {}
  local acc = ""
  for part in dir:gmatch("[^\\]+") do
    if part ~= "" then
      acc = acc == "" and part or (acc .. "\\" .. part)
      if acc:match("^%a:\\") then
        local q = acc:gsub('"', '\\"')
        commands[#commands + 1] =
          'if not exist "' .. q .. '" mkdir "' .. q .. '"'
      end
    end
  end
  return commands
end

function MeshCache.available()
  if not (ffi and love and love.graphics
          and love.data and love.data.newByteData) then
    return false
  end
  return MeshCache.dir() ~= nil
end

-- The cache directory, resolved and created on first use. On the Brick
-- this is the portable (SD-card) folder; everywhere else it is the LÖVE
-- save directory -- the engine's own io-rooted save location (on macOS
-- that resolves to ~/Library/Application Support/LOVE/<identity>/, the
-- folder the engine actually reads). nil when no writable root exists
-- (then everything no-ops).
function MeshCache.dir()
  if dirTried then return cacheDir end
  dirTried = true
  cacheDir = false
  local okBase, base
  if SaveData then
    okBase, base = pcall(function() return SaveData.portableBaseDir() end)
  end
  if not (okBase and base) then
    -- Desktop / non-portable: fall back to the LÖVE save directory. No
    -- platform branches -- the Brick keeps its SD-card portable root,
    -- everything else lands here.
    if love and love.filesystem and love.filesystem.getSaveDirectory then
      base = love.filesystem.getSaveDirectory()
    end
    if not base then return nil end
  end
  local sep = package.config:sub(1, 1)
  local d = base .. sep .. "mod-derived" .. sep .. "potato_voxel"
            .. sep .. "meshes"
  -- io.* cannot create missing parents; mkdir the tree like the engine's
  -- portable filesystem does. Failure stays a silent no-op (nil above).
  for _, command in ipairs(mkdirCommands(d, sep)) do
    local ok = os.execute(command)
    if not (ok == true or ok == 0) then return nil end
  end
  cacheDir = d
  return d
end

-- ------------------------------------------------------------- storage io

local function readFile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- Atomic-ish write: a temp file renamed over the target, so a crash mid-
-- write never leaves a half-file the loader would trust as a full cache.
local function writeFile(path, data)
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "wb")
  if not f then return false end
  local ok = f:write(data)
  f:close()
  if not ok then os.remove(tmp) return false end
  local ok2 = os.rename(tmp, path)
  if not ok2 then os.remove(tmp) return false end
  return true
end

local function manifestPath()
  local dir = MeshCache.dir()
  return dir and dir .. "/" .. MANIFEST or nil
end

function MeshCache.begin()
  dirty = true
  compression = "unknown"
  local path = manifestPath()
  if path then os.remove(path) end
end

-- ------------------------------------------------------------- fingerprint

-- The exact string of everything a map's geometry depends on. Stored in
-- each file header and compared at load; any difference (a tileset swap,
-- a RED++ vs SGB atlas, a mesher rewrite) is a miss and the file is
-- dropped.
local function fingerprint(map, slot)
  local tileset = (map.tileset and map.tileset.image) or "?"
  local trueColor = (map.tileset and map.tileset.trueColor) and "1" or "0"
  local atlas = (map.renderer and map.renderer.gbcAtlas) and "g" or "s"
  return identity() .. "|" .. tostring(map.id) .. "|" .. tostring(slot) .. "|"
         .. tileset .. "|" .. trueColor .. "|" .. atlas
end

local function fileName(map, slot, kind)
  return tostring(map.id):gsub("[^%w_]", "_") .. "." .. tostring(slot)
         .. "." .. kind
end

local function fileFor(map, slot, kind)
  return MeshCache.dir() .. "/" .. fileName(map, slot, kind)
end

-- ------------------------------------------------------------- encoding

-- Binary layout, little-endian throughout:
--   raw format: "DSM" + format byte (1) + u32 fp-len + fp bytes + payload
--   LZ4 format: same header, then codec + raw length + packed length + hash
--   mesh payload:   u32 vertex count n, then n*6 floats
--   figures payload: u8 count, then per figure: u32 n, n*6 floats,
--                    then f32 wx, f32 wz, f32 y, f32 w
local MAGIC = "DSM"
local RAW_FORMAT = 1
local COMPRESSED_FORMAT = 2
local LZ4_CODEC = 1
local MAX_PAYLOAD = 512 * 1024 * 1024

local function f32(v)
  local buf = ffi.new("float[1]")
  buf[0] = v
  local bytes = ffi.new("uint8_t[4]")
  ffi.copy(bytes, buf, 4)
  return string.char(bytes[0], bytes[1], bytes[2], bytes[3])
end

local function f32s(values)
  local parts = {}
  for _, v in ipairs(values) do parts[#parts + 1] = f32(v) end
  return table.concat(parts)
end

local function u32(n)
  n = n % 4294967296
  return string.char(n % 256, math.floor(n / 256) % 256,
                     math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

local function readU32(s, offset)
  return s:byte(offset) + s:byte(offset + 1) * 256
       + s:byte(offset + 2) * 65536 + s:byte(offset + 3) * 16777216
end

local function header(fp, format, rawLen, packedLen, checksum)
  local out = MAGIC .. string.char(format) .. u32(#fp) .. fp
  if format == COMPRESSED_FORMAT then
    out = out .. string.char(LZ4_CODEC) .. u32(rawLen) .. u32(packedLen)
         .. u32(checksum)
  end
  return out
end

-- Parse and validate the header at `s:sub(1)`. Returns the fingerprint
-- and payload metadata, or nil (bad magic/format/length).
local function parseHeader(s, totalLen)
  if not s or #s < 8 then return nil end
  local length = totalLen or #s
  local format = s:byte(4)
  if s:sub(1, 3) ~= MAGIC
     or (format ~= RAW_FORMAT and format ~= COMPRESSED_FORMAT) then
    return nil
  end
  local fpLen = readU32(s, 5)
  local head = 8 + fpLen             -- 1-based index of the LAST fp byte
  if #s < head or length < head then return nil end
  local meta = { format = format }
  local offset = head + 1
  if format == COMPRESSED_FORMAT then
    if #s < head + 13 or length < head + 13 then return nil end
    meta.codec = s:byte(offset)
    meta.rawLen = readU32(s, offset + 1)
    meta.packedLen = readU32(s, offset + 5)
    meta.checksum = readU32(s, offset + 9)
    offset = offset + 13
    if meta.codec ~= LZ4_CODEC or length - offset + 1 ~= meta.packedLen then
      return nil
    end
  end
  return s:sub(9, head), offset, meta
end

-- Boot only needs the cache identity and payload bounds. Reading the full mesh
-- here defeats the point of the disk cache: a complete cache can be hundreds
-- of megabytes, and decompressing every entry before the title screen makes
-- the launcher appear hung. Full checksum/decode validation still happens
-- when a map actually loads its mesh.
local MAX_HEADER = 64 * 1024
local function readHeader(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local prefix = f:read(8)
  if not prefix or #prefix < 8 then f:close(); return nil end
  local fpLen = readU32(prefix, 5)
  local format = prefix:byte(4)
  local extra = format == COMPRESSED_FORMAT and 13 or 0
  local headerLen = 8 + fpLen + extra
  if headerLen > MAX_HEADER then f:close(); return nil end
  local rest = headerLen > 8 and f:read(headerLen - 8) or ""
  local totalLen = f:seek("end")
  f:close()
  if not rest or #rest ~= headerLen - 8 or not totalLen then return nil end
  return prefix .. rest, totalLen
end

local function unpackPayload(s, offset, meta)
  local body = s:sub(offset)
  if meta.format == RAW_FORMAT then return body end
  if meta.rawLen > MAX_PAYLOAD or meta.packedLen > #body then return nil end
  local data = love and love.data
  if not (data and data.decompress) then return nil end
    local ok, raw = pcall(data.decompress, "string", "lz4", body)
  -- ponytail: no per-byte checksum -- a Lua loop over a 10-25MB payload is a
  -- 100ms+ hitch on every cold map transition. Truncation is caught by the
  -- packed-length check in parseHeader and the raw-length check here; corrupt
  -- LZ4 fails to decompress or yields the wrong size. Add hashing back only if
  -- bit-rot that decompresses to the exact length is ever observed.
  if not (ok and type(raw) == "string" and #raw == meta.rawLen) then
    return nil
  end
  return raw
end

local function packPayload(fp, body)
  local data = love and love.data
  if data and data.compress and #body >= 1024 then
    local ok, packed = pcall(data.compress, "string", "lz4", body)
    if ok and type(packed) == "string" and #packed < #body then
      return header(fp, COMPRESSED_FORMAT, #body, #packed, 0) .. packed
    end
  end
  return header(fp, RAW_FORMAT) .. body
end

local function repackRaw(path, fp, body, meta)
  if meta.format ~= RAW_FORMAT then return end
  local packed = packPayload(fp, body)
  if packed:byte(4) == COMPRESSED_FORMAT then
    compression = "unknown"
    pcall(writeFile, path, packed)
  end
end

-- A float* at byte offset `off` into a Lua string. The string keeps the
-- data alive for as long as the caller holds it -- callers MUST keep the
-- returned `str` in scope through any upload that reads `ptr`.
local function floatsPtr(s, off)
  return ffi.cast("const float*", ffi.cast("const char*", s) + off)
end

-- A uint32_t* at byte offset `off` into a Lua string (the vertex map).
local function u32Ptr(s, off)
  return ffi.cast("const uint32_t*", ffi.cast("const char*", s) + off)
end

-- ------------------------------------------------------------- payloads

-- Encode a vertex stream (n*6 floats from a float* src) into payload
-- bytes. ALWAYS length-prefixed -- n == 0 writes just the u32 zero -- so
-- a payload is self-delimiting and empty meshes round-trip as empty
-- meshes rather than making a whole file unparseable.
local function encodeMesh(n, srcPtr)
  local parts = { u32(n or 0) }
  if not srcPtr or n == nil or n == 0 then return table.concat(parts) end
  local CHUNK = 65536 * 6
  local off = 0
  local remaining = n
  while remaining > 0 do
    local c = math.min(CHUNK, remaining)
    local floats = c * 6
    local bytes = floats * 4
    local buf = ffi.new("char[?]", bytes)
    ffi.copy(buf, srcPtr + off, bytes)
    parts[#parts + 1] = ffi.string(buf, bytes)
    off = off + floats
    remaining = remaining - c
    -- a route-sized encode is several MB of ffi copy + string concat;
    -- inside the build coroutine this must yield with the rest
    Budget.check()
  end
  return table.concat(parts)
end

-- INDEXED payload: the vertex stream above, then a u32 vertex map
-- (m entries). Terrain and water meshes are stored this way (brick.11);
-- aux payloads never are (encodeMesh stays unindexed for them).
local function encodeIndexed(n, srcPtr, m, idxPtr)
  local parts = { encodeMesh(n, srcPtr), u32(m or 0) }
  if not idxPtr or m == nil or m == 0 then return table.concat(parts) end
  local CHUNK = 65536
  local off = 0
  local remaining = m
  while remaining > 0 do
    local c = math.min(CHUNK, remaining)
    local bytes = c * 4
    local buf = ffi.new("char[?]", bytes)
    ffi.copy(buf, idxPtr + off, bytes)
    parts[#parts + 1] = ffi.string(buf, bytes)
    off = off + c
    remaining = remaining - c
    Budget.check()
  end
  return table.concat(parts)
end

-- Decode a mesh payload into a data record { n, str, ptr } -- str is the
-- payload string (kept alive by the record) and ptr a float* into it.
-- nil when corrupt. The length check is a MINIMUM (truncation guard),
-- not exact: aux files carry the grass payload, then flowers, then the
-- figures payload, all concatenated -- exact equality would reject every
-- multi-payload file and the aux cache could never hit.
local function decodeMesh(s)
  if not s or #s < 4 then return nil end
  local n = s:byte(1) + s:byte(2) * 256 + s:byte(3) * 65536
            + s:byte(4) * 16777216
  if n > 0 and #s < 4 + n * 24 then return nil end
  if n == 0 then return { n = 0 } end
  return { n = n, str = s, ptr = floatsPtr(s, 4) }
end

-- Decode an INDEXED mesh payload (terrain/water, brick.11+): the vertex
-- stream as decodeMesh reads it, then u32 index count + the u32 vertex
-- map. Returns { n, str, ptr, m, istr, iptr } (m = index count; iptr a
-- uint32_t* into the map), or nil when corrupt. Files written before
-- the version-10 bump carried no index section and are rejected by the
-- fingerprint check before this ever runs.
local function decodeIndexed(s)
  if not s or #s < 8 then return nil end
  local n = s:byte(1) + s:byte(2) * 256 + s:byte(3) * 65536
            + s:byte(4) * 16777216
  if n > 0 and #s < 4 + n * 24 + 4 then return nil end
  local voff = 4 + n * 24
  local m = s:byte(voff + 1) + s:byte(voff + 2) * 256
            + s:byte(voff + 3) * 65536 + s:byte(voff + 4) * 16777216
  if m > 0 and #s < voff + 4 + m * 4 then return nil end
  if n == 0 then return { n = 0, m = 0 } end
  local rec = { n = n, str = s, ptr = floatsPtr(s, 4), m = m }
  if m > 0 then rec.istr = s; rec.iptr = u32Ptr(s, voff + 4) end
  return rec
end

local function encodeFigures(list)
  local parts = { string.char(math.min(#list, 255)) }
  for _, f in ipairs(list) do
    parts[#parts + 1] = encodeIndexed(f.n, f.ptr or f.buf, f.m, f.idx)
    parts[#parts + 1] = f32s({ f.wx or 0, f.wz or 0, f.y or 0, f.w or 0 })
  end
  return table.concat(parts)
end

local function decodeFigures(s)
  if not s or #s < 1 then return nil end
  local count = s:byte(1)
  local list, pos = {}, 2
  for _ = 1, count do
    local d = decodeIndexed(s:sub(pos))
    if not d then return nil end
    pos = pos + 4 + d.n * 24 + 4 + d.m * 4
    if pos + 16 > #s + 1 then return nil end
    local p = floatsPtr(s, pos - 1)
    list[#list + 1] = { n = d.n, str = d.str, ptr = d.ptr, m = d.m,
                        istr = d.istr, iptr = d.iptr,
                        wx = p[0], wz = p[1], y = p[2], w = p[3] }
    pos = pos + 16
  end
  return list
end

local function payloadFingerprint(path, fp, kind, prefix)
  local s = readFile(path)
  if not s then return nil end
  local got, off, meta = parseHeader(s)
  if not got then return nil end
  if prefix then
    if got:sub(1, #fp) ~= fp then return nil end
  elseif got ~= fp then
    return nil
  end
  local body = unpackPayload(s, off, meta)
  if not body then return nil end
  if kind ~= "aux" then
    return decodeIndexed(body) and got or nil
  end
  local grass = decodeIndexed(body)
  if not grass then return nil end
  local flowerPos = 4 + grass.n * 24 + 4 + grass.m * 4
  local flowers = decodeIndexed(body:sub(1 + flowerPos))
  if not flowers then return nil end
  local figurePos = flowerPos + 4 + flowers.n * 24 + 4 + flowers.m * 4
  return decodeFigures(body:sub(1 + figurePos)) and got or nil
end

local function validPayload(path, fp, kind)
  return payloadFingerprint(path, fp, kind) ~= nil
end

local function safeValidPayload(path, fp, kind)
  local ok, valid = pcall(validPayload, path, fp, kind)
  return ok and valid
end

local function headerFingerprint(path, prefix)
  local s, totalLen = readHeader(path)
  if not s then return false end
  local got, offset, meta = parseHeader(s, totalLen)
  if not (got and totalLen >= offset
         and (meta.format ~= COMPRESSED_FORMAT
              or meta.rawLen <= MAX_PAYLOAD)) then
    return nil
  end
  if prefix and got:sub(1, #prefix) ~= prefix then return nil end
  return got
end

local function safeHeaderFingerprint(path, prefix)
  local ok, got = pcall(headerFingerprint, path, prefix)
  return ok and type(got) == "string" and got or nil
end

local function validHeader(path, fp)
  return headerFingerprint(path) == fp
end

local function safeValidHeader(path, fp)
  local ok, valid = pcall(validHeader, path, fp)
  return ok and valid
end

local function safeFormat(path, fp)
  local ok, format, rawLen = pcall(function()
    local s, totalLen = readHeader(path)
    if not s then return nil end
    local got, offset, meta = parseHeader(s, totalLen)
    if got ~= fp then return nil end
    local rawLen = meta.format == COMPRESSED_FORMAT
                  and meta.rawLen or (totalLen - offset + 1)
    return meta.format, rawLen
  end)
  return ok and format or nil, ok and rawLen or nil
end

local function updateCompression(records, dir)
  local total, compressed = 0, 0
  for _, record in pairs(records or {}) do
    for _, pair in ipairs({
      { record.terrain, record.terrainFp },
      { record.water, record.waterFp },
      { record.aux, record.auxFp },
    }) do
      local format, rawLen = safeFormat(dir .. "/" .. pair[1], pair[2])
      if rawLen and rawLen >= 1024 then
        total = total + 1
        if format == COMPRESSED_FORMAT then compressed = compressed + 1 end
      end
    end
  end
  if total == 0 then
    compression = "unknown"
  elseif compressed == total then
    compression = "compressed"
  elseif compressed == 0 then
    compression = "raw"
  else
    compression = "mixed"
  end
end

function MeshCache.jobRecord(map, slot)
  return {
    key = tostring(map.id) .. "/" .. tostring(slot),
    terrain = fileName(map, slot, "terrain"),
    terrainFp = fingerprint(map, slot),
    water = fileName(map, slot, "water"),
    waterFp = fingerprint(map, slot .. "Water"),
    aux = fileName(map, slot, "aux"),
    auxFp = fingerprint(map, slot .. "Aux"),
  }
end

local function scanJob(job, dir)
  local map = { id = job.id }
  local slot = tostring(job.slot)
  local terrain = fileName(map, slot, "terrain")
  local water = fileName(map, slot, "water")
  local aux = fileName(map, slot, "aux")
  local terrainFp = safeHeaderFingerprint(
    dir .. "/" .. terrain,
    identity() .. "|" .. tostring(job.id) .. "|" .. slot .. "|")
  local waterFp = safeHeaderFingerprint(
    dir .. "/" .. water,
    identity() .. "|" .. tostring(job.id) .. "|" .. slot .. "Water|")
  local auxFp = safeHeaderFingerprint(
    dir .. "/" .. aux,
    identity() .. "|" .. tostring(job.id) .. "|" .. slot .. "Aux|")
  if not (terrainFp and waterFp and auxFp) then return nil end
  return { key = tostring(job.id) .. "/" .. slot, terrain = terrain,
           terrainFp = terrainFp, water = water, waterFp = waterFp,
           aux = aux, auxFp = auxFp }
end

function MeshCache.verifyJob(map, slot)
  local dir = MeshCache.dir()
  if not dir then return false end
  local record = MeshCache.jobRecord(map, slot)
  return safeValidPayload(dir .. "/" .. record.terrain, record.terrainFp, "mesh")
     and safeValidPayload(dir .. "/" .. record.water, record.waterFp, "mesh")
     and safeValidPayload(dir .. "/" .. record.aux, record.auxFp, "aux")
end

local function readManifest()
  local path = manifestPath()
  if not path then return nil end
  local text = readFile(path)
  if not text then return nil end
  local lines = {}
  for line in text:gmatch("[^\n]+") do lines[#lines + 1] = line end
  local format, manifestIdentity, total
  if lines[1] then
    format, manifestIdentity, total =
      lines[1]:match("^(%S+)%s+(%S+)%s+(%d+)$")
  end
  if format ~= "PVMC1" or manifestIdentity ~= identity() then return nil end
  local records = {}
  for i = 2, #lines do
    local key, terrain, terrainFp, water, waterFp, aux, auxFp =
      lines[i]:match("^job\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
    if not key then return nil end
    records[key] = { key = key, terrain = terrain, terrainFp = terrainFp,
                     water = water, waterFp = waterFp, aux = aux, auxFp = auxFp }
  end
  return { total = tonumber(total), records = records }
end

function MeshCache.ready(jobs)
  if dirty or not MeshCache.available() then return false, 0 end
  local manifest = readManifest()
  if not manifest or manifest.total ~= #jobs then
    local dir = MeshCache.dir()
    local records, done = {}, 0
    for _, job in ipairs(jobs or {}) do
      local record = scanJob(job, dir)
      if not record then return false, done end
      records[record.key] = record
      done = done + 1
    end
    if done == #jobs and MeshCache.writeManifest(records, #jobs) then
      return true, done
    end
    return false, done
  end
  local dir = MeshCache.dir()
  local done = 0
  for _, job in ipairs(jobs or {}) do
    local key = tostring(job.id) .. "/" .. tostring(job.slot)
    local record = manifest.records[key]
    if not record then return false, done end
    local ok = safeValidHeader(dir .. "/" .. record.terrain, record.terrainFp)
           and safeValidHeader(dir .. "/" .. record.water, record.waterFp)
           and safeValidHeader(dir .. "/" .. record.aux, record.auxFp)
    if not ok then
      local records, scanned = {}, 0
      for _, candidate in ipairs(jobs or {}) do
        local migrated = scanJob(candidate, dir)
        if not migrated then return false, done end
        records[migrated.key] = migrated
        scanned = scanned + 1
      end
      if scanned == #jobs and MeshCache.writeManifest(records, #jobs) then
        return true, scanned
      end
      return false, done
    end
    done = done + 1
  end
  if done == #jobs then
    updateCompression(manifest.records, dir)
    return true, done
  end
  return false, done
end

function MeshCache.writeManifest(records, total)
  local path = manifestPath()
  if not path or type(records) ~= "table" then return false end
  local keys = sortedKeys(records)
  if #keys ~= total then return false end
  local lines = { ("PVMC1\t%s\t%d"):format(identity(), total) }
  for _, key in ipairs(keys) do
    local record = records[key]
    lines[#lines + 1] = table.concat({ "job", record.key, record.terrain,
      record.terrainFp, record.water, record.waterFp, record.aux,
      record.auxFp }, "\t")
  end
  local ok = writeFile(path, table.concat(lines, "\n") .. "\n")
  if ok then
    dirty = false
    updateCompression(records, MeshCache.dir())
  end
  return ok
end

-- ------------------------------------------------------------ save/load

function MeshCache.saveTerrain(map, slot, buf, n, idx, m)
  if not MeshCache.dir() then return end
  local ok = pcall(function()
    local fp = fingerprint(map, slot)
    writeFile(fileFor(map, slot, "terrain"),
              packPayload(fp, encodeIndexed(n, buf, m, idx)))
  end)
  if not ok then os.remove(fileFor(map, slot, "terrain") .. ".tmp") end
end

function MeshCache.saveWater(map, slot, buf, n, idx, m)
  if not MeshCache.dir() then return end
  local ok = pcall(function()
    local fp = fingerprint(map, slot .. "Water")
    writeFile(fileFor(map, slot, "water"),
              packPayload(fp, encodeIndexed(n, buf, m, idx)))
  end)
  if not ok then os.remove(fileFor(map, slot, "water") .. ".tmp") end
end

-- The terrain and water for (map, slot), as data records, or nil on a
-- miss. The two must land together (a body build's water beside a full
-- mesh would draw the ring twice): callers check both.
function MeshCache.loadTerrain(map, slot)
  local dir = MeshCache.dir()
  if not dir then return nil, nil end
  local mesh = MeshCache.loadMeshData(fileFor(map, slot, "terrain"),
                                      fingerprint(map, slot))
  local water = MeshCache.loadMeshData(fileFor(map, slot, "water"),
                                       fingerprint(map, slot .. "Water"))
  return mesh, water
end

-- Read + validate one mesh file. nil when missing/corrupt/stale.
function MeshCache.loadMeshData(path, fp)
  local ok, s = pcall(readFile, path)
  if not ok or not s then return nil end
  local got, off, meta = parseHeader(s)
  if not got or got ~= fp then
    os.remove(path)
    return nil
  end
  local body = unpackPayload(s, off, meta)
  if body then repackRaw(path, fp, body, meta) end
  return body and decodeIndexed(body) or nil
end

-- Persist the aux (grass/flowers/figures) vertex streams. `flattened` is
-- { grass = {n=.., buf=..}, flowers = {n=.., buf=..}, figures = {..} } --
-- produced by ChunkMesher from the Structures quads.
function MeshCache.saveAux(map, slot, flattened)
  if not MeshCache.dir() then return end
  local ok = pcall(function()
    local fp = fingerprint(map, slot .. "Aux")
    local body = encodeIndexed(flattened.grass and flattened.grass.n or 0,
                               flattened.grass and flattened.grass.buf,
                               flattened.grass and flattened.grass.m or 0,
                               flattened.grass and flattened.grass.idx)
    local flowers = encodeIndexed(flattened.flowers and flattened.flowers.n or 0,
                                  flattened.flowers and flattened.flowers.buf,
                                  flattened.flowers and flattened.flowers.m or 0,
                                  flattened.flowers and flattened.flowers.idx)
    local figures = encodeFigures(flattened.figures or {})
    writeFile(fileFor(map, slot, "aux"),
              packPayload(fp, body .. flowers .. figures))
  end)
  if not ok then os.remove(fileFor(map, slot, "aux") .. ".tmp") end
end

-- Load the aux streams: { grass, flowers, figures } data records, or nil.
function MeshCache.loadAux(map, slot)
  local dir = MeshCache.dir()
  if not dir then return nil end
  local okS, s = pcall(readFile, fileFor(map, slot, "aux"))
  if not okS or not s then return nil end
  local got, off, meta = parseHeader(s)
  if not got or got ~= fingerprint(map, slot .. "Aux") then
    os.remove(fileFor(map, slot, "aux"))
    return nil
  end
  local body = unpackPayload(s, off, meta)
  if not body then return nil end
  repackRaw(fileFor(map, slot, "aux"), fingerprint(map, slot .. "Aux"), body, meta)
  -- grass mesh | flowers mesh | figures payload (each length-prefixed,
  -- and each carries its own u32 index section since version 12)
  local g = decodeIndexed(body)
  if not g then return nil end
  local fpos = 4 + g.n * 24 + 4 + g.m * 4
  local flowers = decodeIndexed(body:sub(1 + fpos))
  if not flowers then return nil end
  local fpos2 = fpos + 4 + flowers.n * 24 + 4 + flowers.m * 4
  local figures = decodeFigures(body:sub(1 + fpos2))
  if not figures then return nil end
  return { grass = g, flowers = flowers, figures = figures }
end

-- Drop the cached files for one map (a block edit / a reloaded map) or
-- every map. mapId-scoped deletes are REAL: a cut tree changes blocks
-- without changing any fingerprint component, so the file must go or the
-- 3D world keeps the old tree. The nil (full) case only handles hot
-- reload and boot -- in-memory meshes, canvases and generations are
-- dropped by the callers above -- and the DISK files are deliberately
-- KEPT: they are fingerprint-protected, so a stale one (new mesher
-- version, a tileset swap, a void-fill change, a brick/full profile
-- switch) fails validation at load and is dropped then. Wiping the disk
-- at boot is what made every launch cold -- the cache never survived a
-- restart.
function MeshCache.invalidate(mapId)
  dirty = true
  compression = "unknown"
  local dir = MeshCache.dir()
  if not dir then return end
  os.remove(dir .. "/" .. MANIFEST)
  if not mapId then return end
  local prefix = tostring(mapId):gsub("[^%w_]", "_")
  for _, slot in ipairs({ "body", "full" }) do
    for _, kind in ipairs({ "terrain", "water", "aux" }) do
      os.remove(dir .. "/" .. prefix .. "." .. slot .. "." .. kind)
    end
  end
end

local function listFiles(dir)
  if not io.popen then return {} end
  local quoted = dir:gsub('"', '\\"')
  local command = package.config:sub(1, 1) == "\\"
    and ('dir /b "' .. quoted .. '" 2>nul')
    or ('ls -1 "' .. quoted .. '" 2>/dev/null')
  local ok, pipe = pcall(io.popen, command, "r")
  if not ok or not pipe then return {} end
  local names = {}
  for name in pipe:lines() do names[#names + 1] = name end
  pipe:close()
  return names
end

function MeshCache.wipe(jobs)
  dirty = true
  compression = "unknown"
  local dir = MeshCache.dir()
  if not dir then return false end
  os.remove(dir .. "/" .. MANIFEST)
  -- The direct pass also works on platforms without io.popen. The directory
  -- pass catches stale files from maps no longer present in the current data.
  for _, job in ipairs(jobs or {}) do
    local prefix = tostring(job.id):gsub("[^%w_]", "_")
    for _, slot in ipairs({ "body", "full" }) do
      for _, kind in ipairs({ "terrain", "water", "aux" }) do
        os.remove(dir .. "/" .. prefix .. "." .. slot .. "." .. kind)
      end
    end
  end
  for _, name in ipairs(listFiles(dir)) do
    if name:match("%.terrain$") or name:match("%.water$")
       or name:match("%.aux$") or name:match("%.tmp$") then
      os.remove(dir .. "/" .. name)
    end
  end
  return true
end

-- ------------------------------------------------ pure helpers (exported)

-- Flatten a quads table (the Structures grass/flowers/figure shapes:
-- 4 corners + uv + shade per quad) into the same INDEXED stream the
-- ffi sink emits: 4 unique verts per quad in `buf`, plus 6 u32 indices
-- per quad (0-based, LOVE Data-map convention) in `idxBuf`. Returns
-- (floatCount, indexCount). The one function both aux save paths
-- share, exported so the headless suite can prove a round-trip is
-- byte-identical.
function MeshCache.flattenQuads(quads, buf, idxBuf)
  local k, m = 0, 0
  for _, q in ipairs(quads) do
    Budget.tick()
    local flatShade = type(q.shade) ~= "table"
    local corner = {}
    for i = 1, 4 do
      local c = q[i]
      local uv = q.uv and q.uv[i] or { q.u, q.v }
      corner[i] = { c[1], c[2], c[3], uv[1], uv[2],
                    flatShade and q.shade or q.shade[i] }
    end
    local base = k
    for i = 1, 4 do
      local v = corner[i]
      buf[k] = v[1]
      buf[k + 1] = v[2]
      buf[k + 2] = v[3]
      buf[k + 3] = v[4]
      buf[k + 4] = v[5]
      buf[k + 5] = v[6]
      k = k + 6
    end
    local v0 = base / 6        -- 0-based first vertex of this quad
    idxBuf[m] = v0
    idxBuf[m + 1] = v0 + 1
    idxBuf[m + 2] = v0 + 2
    idxBuf[m + 3] = v0
    idxBuf[m + 4] = v0 + 2
    idxBuf[m + 5] = v0 + 3
    m = m + 6
  end
  return k, m
end

-- A mesh payload encoder, exported for tests (no header -- the header
-- needs the fingerprint). Given a float* + vertex count, returns the
-- serialized bytes; decodeMesh reads them back.
MeshCache.encodeMesh = encodeMesh
MeshCache.decodeMesh = decodeMesh
-- mkdir command builder for MeshCache.dir, exported for tests
MeshCache.mkdirCommands = mkdirCommands
-- indexed terrain/water payloads (brick.11+)
MeshCache.encodeIndexed = encodeIndexed
MeshCache.decodeIndexed = decodeIndexed

return MeshCache
