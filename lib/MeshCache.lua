-- MeshCache: the terrain mesh cache.
--
-- v2 (1.6.1): the cache lives in the mod sandbox's scoped byte storage
-- (mod.storage:writeBytes/readBytes -- upstream PR #1304) instead of raw
-- files in the save directory. The engine owns the physical storage:
-- writes are crash-safe (tmp + verify + swap), keys are scoped per game
-- version x playthrough x mod id, and no path in any spelling exists to
-- get wrong. What this file keeps is everything ON TOP of that:
--
--   key layout       maps/<mapId>/<slot>/<kind>   payload bytes
--                    meta/<mapId>/<slot>/<kind>   small table: the
--                        fingerprint + format + lengths + codec -- the
--                        boot-time "header" the old file layout carried,
--                        so READY scans stay bounded (whole-key reads
--                        make partial payload reads impossible)
--                    manifest                      table: PVMC1 manifest
--                    buildinfo                     table: build identity
--
--   payload format   unchanged since v18: "DSM" magic + format byte +
--                    fingerprint + optional codec/lengths, then a
--                    quantized (terrain/water) or float (aux) INDEXED
--                    vertex payload. love.data compress/decompress do
--                    the entropy codec; love.data.newByteData replaces
--                    the old ffi float buffers end to end.
--
-- Availability is fail-open: when the storage facade cannot resolve (no
-- playthrough yet, title screen without an existing save), every cache
-- call no-ops and callers proceed as if the cache were empty -- the
-- prebuild gate and the BUILD NOW prompt both already understand "no
-- cache today". A resolution is re-probed on failure, so a session that
-- starts at the title screen and lands in a playthrough picks the store
-- up the moment it exists.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Brick = V.require("BrickProfile")
local Budget = V.require("BuildBudget")

-- The engine's save-root resolver used to pick the portable SD-card dir.
-- With storage the engine owns placement entirely; SaveData is no longer
-- consulted (kept out of the picture deliberately -- see the removals ADR).

local MeshCache = {}
local dataKey = "unconfigured"
local dirty = false
local compression = "unknown"
local codec = nil          -- "lz4"/"zstd"/"MIX" behind the compressed files
local MANIFEST_KEY = "manifest"
local BUILD_INFO_KEY = "buildinfo"
-- Populated by ready() whenever it returns false, so a caller (the boot
-- path) can report exactly WHY the cache was rejected. nil after a
-- successful ready().
local lastFailure = nil
-- Snapshot of identity() captured at begin(): every payload and the
-- manifest written by that build session share ONE identity even if a
-- live component (voidFill) changes mid-build. Cleared when the build
-- finishes.
local buildIdentity = nil
local buildParts = nil
-- Per-session write-error tracking (F5): every save write failure is
-- remembered, so a build that dies to a full disk or a missing store
-- says WHY instead of "cache verification failed".
local lastSaveError = nil
local saveFailures = 0

-- Bump when the meshing algorithm changes the vertex/UV output, so a
-- cache written by an older build is never trusted by a newer one. (The
-- mod version alone is not enough: a settings-only release changes no
-- geometry.) NOTE: this is the CACHE FORMAT, not the storage layout --
-- the payload format has its own magic byte inside each value.
-- (History elided here for the storage rewrite; the version carries
-- forward: 18 = quantized terrain/water, indexed aux, ROM-identity
-- headers. The move to scoped storage does NOT bump it -- the new store
-- starts empty, so every device rebuilds once on its own.)
MeshCache.GEOMETRY_VERSION = 18

-- ------------------------------------------------------------- storage
--
-- The storage facade is resolved lazily and re-probed after a failure,
-- because a session moves through states where no playthrough exists:
-- boot at the title screen has selected(game) at best (and only when a
-- save exists to select), NEW GAME has nothing until save.created, and
-- in-game has the plain facade. `false` is deliberately NOT cached.

local store = nil
local storeSource = nil

local function liveGame()
  local ok, Game = pcall(require, "src.core.Game")
  return ok and Game or nil
end

local function resolveStore()
  local mod = V.mod
  if not (mod and mod.storage) then return nil end
  local game = liveGame()
  local ok, ctx = pcall(mod.storage.context, mod.storage, game)
  if ok and ctx and ctx.playthroughId then
    return mod.storage
  end
  if mod.storage.selected then
    local okS, selected = pcall(mod.storage.selected, mod.storage, game)
    if okS and selected then
      local okC, ctx2 = pcall(selected.context, selected)
      if okC and ctx2 and ctx2.playthroughId then
        return selected
      end
    end
  end
  return nil
end

local function facade()
  local mod = V.mod
  local source = mod and mod.storage or nil
  if store and storeSource == source then return store end
  store = resolveStore()
  storeSource = source
  return store
end

-- Drop a facade that a storage call reported unusable (not_in_playthrough
-- mid-session, a wiped playthrough) so the next call re-resolves.
local function facadeFailed()
  store = nil
end

-- Storage failure codes worth surfacing: every write/read returns
-- (ok, code, message); a code other than nil is the WHY.
local function callFail(op, code, message)
  if code == "not_in_playthrough" or code == "not_at_title" then
    facadeFailed()
  end
  -- not_found (and a nil code from a stub) is the normal empty-cache
  -- case, not a failure worth logging; every other code is.
  if code ~= nil and code ~= "not_found" then
    local okD, Overlay = pcall(V.require, "DebugOverlay")
    if okD and Overlay then
      Overlay.count("storageFails")
      Overlay.error("storage %s: %s (%s)", tostring(op), tostring(code),
                    tostring(message))
    end
  end
  return false
end

-- The docs' byte surface (writeBytes/readBytes, PR #1304) is not present
-- in every engine build: when the methods are missing, payload bytes fall
-- back to TABLE storage with the string as the value -- strings are
-- data-only and legal table values, and the meta/manifest/buildinfo
-- records are tables already. One storage type per key is preserved
-- either way (payloads and metas live under different keys).
local function readBytes(key)
  local store_ = facade()
  if not store_ then return nil end
  if store_.readBytes then
    local ok, data, code, message = pcall(store_.readBytes, store_,
                                          liveGame(), key)
    if ok and data then return data end
    -- not_found and type conflicts both fall through: the table shape
    -- may hold what the byte read could not see.
    callFail("readBytes", code, message)
  end
  local ok, data, code, message = pcall(store_.read, store_,
                                        liveGame(), key)
  if not ok or not data then callFail("read", code, message) end
  if type(data) == "table" and data.bytes ~= nil then return data.bytes end
  if type(data) == "string" then return data end
  return nil
end

local function writeBytes(key, bytes)
  local store_ = facade()
  if not store_ then return false end
  if store_.writeBytes then
    local ok, result, code, message = pcall(store_.writeBytes, store_,
                                            liveGame(), key, bytes)
    if ok and result then return true end
    callFail("writeBytes", code, message)
    -- Fall through to the table shape: a playthrough whose keys were
    -- written by an engine without byte storage still has table-typed
    -- values, and a byte write over one is a type conflict -- the table
    -- write below replaces it in the same type.
  end
  local ok, result, code, message = pcall(store_.write, store_,
                                          liveGame(), key,
                                          { bytes = bytes })
  if ok and result then return true end
  -- A key written as bytes by a newer engine is a type conflict for the
  -- table write. Cache payload keys are disposable -- a delete + one
  -- retry clears the conflict without ever touching a live map.
  pcall(store_.delete, store_, liveGame(), key)
  local ok2, result2, code2, message2 = pcall(store_.write, store_,
                                              liveGame(), key,
                                              { bytes = bytes })
  if not ok2 or not result2 then
    callFail("write", code2, message2)
  end
  return ok2 and result2 and true or false
end

local function writeTable(key, value)
  local store_ = facade()
  if not store_ or not store_.write then return false end
  local ok, result, code, message = pcall(store_.write, store_,
                                          liveGame(), key, value)
  if not ok or not result then callFail("write", code, message) end
  return ok and result and true or false
end

local function readTable(key)
  local store_ = facade()
  if not store_ or not store_.read then return nil end
  local ok, data, code, message = pcall(store_.read, store_, liveGame(), key)
  if not ok or not data then callFail("read", code, message) end
  return ok and data or nil
end

local function listKeys(prefix)
  local store_ = facade()
  if not store_ or not store_.list then return {} end
  local ok, keys, code, message = pcall(store_.list, store_, liveGame(),
                                        prefix)
  if not ok then callFail("list", code, message) end
  return (ok and keys) or {}
end

local function deleteKey(key)
  local store_ = facade()
  if not store_ or not store_.delete then return false end
  pcall(store_.delete, store_, liveGame(), key)
  return true
end

function MeshCache.dir()
  -- Kept for callers that want a one-word "is there anywhere to put it"
  -- answer; the engine owns the real path now.
  return facade() and "storage" or nil
end

-- ------------------------------------------------------------ identity

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
      hash = hashString(hash, connection.walkable)
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
    hash = hashValues(hash, tileset.walkable)
    hash = hashValues(hash, tileset.counterTiles)
    hash = hashValues(hash, tileset.doorTiles)
    hash = hashValues(hash, tileset.warpTiles)
    hash = hashString(hash, tileset.grassTile)
  end
  return tostring(hash)
end

local GameVersion = nil
do
  local ok, mod = pcall(require, "src.core.GameVersion")
  if ok then GameVersion = mod end
end

local function activeVersion()
  if GameVersion and GameVersion.get then return GameVersion.get() end
  return "red"
end

local function identityParts()
  local okTR, TileRenderer = pcall(require, "src.render.TileRenderer")
  local voidFill = (okTR and TileRenderer and TileRenderer.voidFill) or "trees"
  local profile = Brick.isBrick() and "b" or "f"
  return {
    format = "PVMC1",
    version = MeshCache.GEOMETRY_VERSION,
    activeVersion = activeVersion(),
    profile = profile,
    dataKey = dataKey,
    voidFill = tostring(voidFill),
  }
end

local function identity()
  local parts = identityParts()
  return table.concat({ parts.format, parts.version, parts.activeVersion,
                        parts.profile, parts.dataKey, parts.voidFill }, "|")
end

local IDENTITY_COMPONENTS = { "format", "version", "activeVersion", "profile",
                              "dataKey", "voidFill" }

local function splitIdentity(id)
  local parts = {}
  for part in tostring(id):gmatch("([^|]*)") do
    if part ~= "" then parts[#parts + 1] = part end
  end
  return parts
end

local function identityDiff(expected, actual)
  local e = splitIdentity(expected)
  local a = splitIdentity(actual)
  local diffs = {}
  for i, name in ipairs(IDENTITY_COMPONENTS) do
    if e[i] ~= a[i] then diffs[#diffs + 1] = name end
  end
  return diffs
end

function MeshCache.configure(data)
  dataKey = datasetRevision(data)
  dirty = false
  compression = "unknown"
  codec = nil
  buildIdentity = nil
  buildParts = nil
end

function MeshCache.isDirty()
  return dirty
end

function MeshCache.compressionStatus()
  return compression
end

-- The codec behind the compressed payloads: "lz4", "zstd", "MIX" (a cache
-- spanning codecs), or nil when nothing is compressed.
function MeshCache.codec()
  return codec
end

MeshCache.identity = identity

-- ---------------------------------------------------------- availability

function MeshCache.available()
  return facade() ~= nil
end

function MeshCache.begin()
  dirty = true
  compression = "unknown"
  codec = nil
  -- Snapshot the identity at the START of a build session (see the
  -- module header): every payload and the manifest written by this
  -- session share this one identity, even if a live component (e.g.
  -- voidFill) changes mid-build.
  buildIdentity = identity()
  buildParts = identityParts()
  lastFailure = nil
  lastSaveError = nil
  saveFailures = 0
  -- The manifest is KEPT, not deleted: a build interrupted before
  -- finish() must leave the previous manifest behind rather than none
  -- at all, and the fingerprint check accepts whichever mix survived.
end

-- ------------------------------------------------------------- fingerprint

local function fingerprint(map, slot)
  local tileset = (map.tileset and map.tileset.image) or "?"
  local trueColor = (map.tileset and map.tileset.trueColor) and "1" or "0"
  local atlas = (map.renderer and map.renderer.gbcAtlas) and "g" or "s"
  local id = buildIdentity or identity()
  return id .. "|" .. tostring(map.id) .. "|" .. tostring(slot) .. "|"
         .. tileset .. "|" .. trueColor .. "|" .. atlas
end

-- Storage keys: slash-separated [A-Za-z0-9_-]+ segments, so a map id is
-- sanitised before it names a key.
local function safeId(mapId)
  return tostring(mapId):gsub("[^%w_-]", "_")
end

local function payloadKey(map, slot, kind)
  return "maps/" .. safeId(map.id) .. "/" .. tostring(slot) .. "/" .. kind
end

local function metaKey(map, slot, kind)
  return "meta/" .. safeId(map.id) .. "/" .. tostring(slot) .. "/" .. kind
end

-- ------------------------------------------------------------- encoding

-- Binary layout, little-endian throughout (unchanged from the file-era
-- cache):
--   raw format: "DSM" + format byte (1) + u32 fp-len + fp bytes + payload
--   compressed format: same header, then codec byte (1=lz4, 2=zstd) +
--     raw length + packed length + hash, then the packed bytes
--   mesh payload (terrain/water, v18):  u32 vertex count n, then n*11
--     quantized bytes (i16 x/y/z, u16 u/v, u8 shade), u32 index count m,
--     then m u32 indices
--   aux/figures payload:               u32 n, then n*6 floats (unchanged)
--   figures payload: u8 count, then per figure: u32 n, n*6 floats,
--                    then f32 wx, f32 wz, f32 y, f32 w
local MAGIC = "DSM"
local RAW_FORMAT = 1
local COMPRESSED_FORMAT = 2
local LZ4_CODEC = 1
local ZSTD_CODEC = 2
local ZLIB_CODEC = 3
-- zstd where the runtime has it (desktop LÖVE), else zlib/deflate, else
-- lz4. The engine's table-storage writes serialize byte values as escaped
-- Lua source (~4-6x the payload), so the payload size directly drives the
-- write+verify stall: zlib's better ratio on quantized mesh data is worth
-- its slower compress here (the compress is one bounded call, the write it
-- saves is seconds).
local CODEC_NAMES = { [LZ4_CODEC] = "lz4", [ZSTD_CODEC] = "zstd",
                      [ZLIB_CODEC] = "zlib" }
local MAX_PAYLOAD = 512 * 1024 * 1024

-- ffi is sandbox-banned and this engine's love.data ByteData carries no
-- float accessors, so float32 bytes are packed and unpacked in pure Lua.
-- Only the AUX/figures payloads use floats at all -- terrain and water
-- are quantized integers -- so the slow path is the small path.
local function f32(v)
  if v ~= v then v = 0 end                 -- NaN never reaches the cache
  if v == 0 then return string.char(0, 0, 0, 0) end
  local sign = 0
  if v < 0 then sign = 0x80; v = -v end
  if v == math.huge then return string.char(0, 0, 0x80, sign + 0x7F) end
  local mant, exp = math.frexp(v)          -- v = mant * 2^exp, 0.5 <= m < 1
  exp = exp + 126                          -- float32 bias
  if exp <= 0 then return string.char(sign, 0, 0, 0) end  -- subnormal -> 0
  mant = math.floor((mant * 2 - 1) * 8388608 + 0.5)
  if mant >= 8388608 then mant = 0; exp = exp + 1 end
  if exp >= 255 then return string.char(0, 0, 0x80, sign + 0x7F) end
  -- little-endian, like every other number in the wire format
  return string.char(mant % 256, math.floor(mant / 256) % 256,
                     (exp % 2) * 128 + math.floor(mant / 65536),
                     sign + math.floor(exp / 2))
end

local function f32s(values)
  local parts = {}
  for _, v in ipairs(values) do parts[#parts + 1] = f32(v) end
  return table.concat(parts)
end

local function f32read(s, i)
  local b1, b2, b3, b4 = s:byte(i, i + 3)  -- little-endian: b1 is LSB
  local sign = (b4 >= 128) and -1 or 1
  local exp = (b4 % 128) * 2 + math.floor(b3 / 128)
  local mant = ((b3 % 128) * 65536 + b2 * 256 + b1) / 8388608
  if exp == 0 then return 0 end            -- subnormals flushed to zero
  if exp == 255 then return sign * math.huge end
  return sign * math.ldexp(1 + mant, exp - 127)
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

local function header(fp, format, rawLen, packedLen, checksum, codec)
  local out = MAGIC .. string.char(format) .. u32(#fp) .. fp
  if format == COMPRESSED_FORMAT then
    out = out .. string.char(codec or LZ4_CODEC) .. u32(rawLen)
         .. u32(packedLen) .. u32(checksum)
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
    if meta.codec == nil or CODEC_NAMES[meta.codec] == nil
        or length - offset + 1 ~= meta.packedLen then
      return nil
    end
  end
  return s:sub(9, head), offset, meta
end

local function unpackPayload(s, offset, meta)
  local body = s:sub(offset)
  if meta.format == RAW_FORMAT then return body end
  if meta.rawLen > MAX_PAYLOAD or meta.packedLen > #body then return nil end
  local data = love and love.data
  if not (data and data.decompress) then return nil end
  local codecName = CODEC_NAMES[meta.codec]
  if not codecName then return nil end
  local ok, raw = pcall(data.decompress, "string", codecName, body)
  -- No per-byte checksum: truncation is caught by the packed-length and
  -- raw-length checks, and storage writes are crash-safe whole-value
  -- swaps, so a torn write cannot exist here at all.
  if not (ok and type(raw) == "string" and #raw == meta.rawLen) then
    return nil
  end
  return raw
end

local function packPayload(fp, body)
  local data = love and love.data
  if data and data.compress and #body >= 1024 then
    local ok, packed = pcall(data.compress, "string", "zstd", body)
    if ok and type(packed) == "string" and #packed < #body then
      return header(fp, COMPRESSED_FORMAT, #body, #packed, 0, ZSTD_CODEC)
             .. packed
    end
    ok, packed = pcall(data.compress, "string", "zlib", body)
    if ok and type(packed) == "string" and #packed < #body then
      return header(fp, COMPRESSED_FORMAT, #body, #packed, 0, ZLIB_CODEC)
             .. packed
    end
    ok, packed = pcall(data.compress, "string", "lz4", body)
    if ok and type(packed) == "string" and #packed < #body then
      return header(fp, COMPRESSED_FORMAT, #body, #packed, 0, LZ4_CODEC)
             .. packed
    end
  end
  return header(fp, RAW_FORMAT) .. body
end

-- ------------------------------------------------------------- payloads

-- Encode a vertex stream (n*6 floats) into payload bytes. ALWAYS
-- length-prefixed -- n == 0 writes just the u32 zero -- so a payload is
-- self-delimiting and empty meshes round-trip as empty meshes. `src` is
-- a 1-based Lua float table (the table sink's shape).
local function encodeMesh(n, src)
  local parts = { u32(n or 0) }
  if not src or n == nil or n == 0 then return table.concat(parts) end
  local CHUNK = 4096
  local off = 0
  local total = n * 6
  while off < total do
    local c = math.min(CHUNK, total - off)
    local chunk = {}
    for i = 1, c do
      chunk[i] = f32(src[off + i] or 0)
    end
    parts[#parts + 1] = table.concat(chunk)
    off = off + c
    Budget.check()
  end
  return table.concat(parts)
end

-- INDEXED payload (float): the vertex stream above, then a u32 vertex map
-- (m entries). Aux payloads (grass/flowers) are stored this way; terrain
-- and water use the quantized encodeQuant instead (v18). `idx` is a
-- 1-based u32 Lua table; the wire format is 0-based (LOVE Data-map
-- convention), so the encode subtracts one.
local function encodeIndexed(n, src, m, idx)
  local parts = { encodeMesh(n, src), u32(m or 0) }
  if not idx or m == nil or m == 0 then return table.concat(parts) end
  local CHUNK = 65536
  local off = 0
  while off < m do
    local c = math.min(CHUNK, m - off)
    local chunk = {}
    for i = 1, c do
      chunk[i] = u32((idx[off + i] or 0) - 1)
    end
    parts[#parts + 1] = table.concat(chunk)
    off = off + c
    Budget.check()
  end
  return table.concat(parts)
end

-- Decode a mesh payload into a data record { n, verts } -- verts a
-- 1-based Lua float table, the table sink's upload shape. nil when
-- corrupt. The length check is a MINIMUM (truncation guard), not exact:
-- aux payloads carry grass, then flowers, then figures, all concatenated.
local function decodeMesh(s)
  if not s or #s < 4 then return nil end
  local n = readU32(s, 1)
  if n > 0 and #s < 4 + n * 24 then return nil end
  if n == 0 then return { n = 0 } end
  local verts = {}
  for i = 0, n * 6 - 1 do
    verts[i + 1] = f32read(s, 4 + i * 4 + 1)
    if i % 4096 == 0 then Budget.check() end
  end
  return { n = n, verts = verts }
end

-- Decode an INDEXED float mesh payload (aux): the vertex stream as
-- decodeMesh reads it, then u32 index count + the u32 vertex map,
-- returned 1-based for table uploads (the wire format is 0-based).
local function decodeIndexed(s)
  if not s or #s < 8 then return nil end
  local n = readU32(s, 1)
  if n > 0 and #s < 4 + n * 24 + 4 then return nil end
  local voff = 4 + n * 24
  local m = readU32(s, voff + 1)
  if m > 0 and #s < voff + 4 + m * 4 then return nil end
  if n == 0 then return { n = 0, m = 0 } end
  local rec = decodeMesh(s:sub(1, 4 + n * 24))
  rec.m = m
  if m > 0 then
    local indices = {}
    for i = 1, m do
      indices[i] = readU32(s, voff + 4 + (i - 1) * 4 + 1) + 1
      if i % 16384 == 0 then Budget.check() end
    end
    rec.indices = indices
  end
  return rec
end

-- ------------------------------------------------------------ quantization
--
-- Terrain and water are stored quantized: 11 bytes/vertex (int16
-- position, u16 uv, u8 shade) instead of the 24-byte 6-float stream,
-- ~54% smaller before the entropy codec, near-lossless on the voxel
-- grid. Decode expands back to the same 6-float stream the GPU upload
-- consumes. Aux payloads keep the float layout (v18).
local QUANT_STRIDE = 11

-- i16 as two little-endian bytes (a 2-byte string), for the quantized
-- vertex records.
local function u16byte(v)
  v = v % 65536
  return string.char(v % 256, math.floor(v / 256) % 256)
end

local function readU16(s, off)
  return s:byte(off) + s:byte(off + 1) * 256
end

local function readI16(s, off)
  local w = readU16(s, off)
  return w >= 32768 and (w - 65536) or w
end

-- Encode a quantized INDEXED payload: u32 n, n*11 quantized vertex bytes,
-- u32 m, m u32 indices (0-based on the wire). `src` is a 1-based Lua
-- float table (the table sink's shape), `idx` a 1-based u32 table.
local function encodeQuant(n, src, m, idx)
  local parts = { u32(n or 0) }
  if src and n and n > 0 then
    local CHUNK = 4096
    local vi = 0
    while vi < n do
      local c = math.min(CHUNK, n - vi)
      local bytes = {}
      for i = 1, c do
        local base = (vi + i - 1) * 6 + 1
        local x = math.floor((src[base] or 0) + 0.5)
        local y = math.floor((src[base + 1] or 0) + 0.5)
        local z = math.floor((src[base + 2] or 0) + 0.5)
        local u = math.floor((src[base + 3] or 0) * 65535 + 0.5)
        local v = math.floor((src[base + 4] or 0) * 65535 + 0.5)
        local sh = math.floor((src[base + 5] or 0) * 255 + 0.5)
        if x < -32768 then x = -32768 elseif x > 32767 then x = 32767 end
        if y < -32768 then y = -32768 elseif y > 32767 then y = 32767 end
        if z < -32768 then z = -32768 elseif z > 32767 then z = 32767 end
        if u < 0 then u = 0 elseif u > 65535 then u = 65535 end
        if v < 0 then v = 0 elseif v > 65535 then v = 65535 end
        if sh < 0 then sh = 0 elseif sh > 255 then sh = 255 end
        local b = (i - 1) * 6 + 1
        bytes[b] = u16byte(x)
        bytes[b + 1] = u16byte(y)
        bytes[b + 2] = u16byte(z)
        bytes[b + 3] = u16byte(u)
        bytes[b + 4] = u16byte(v)
        bytes[b + 5] = string.char(sh)
        if i % 1024 == 0 then Budget.check() end
      end
      parts[#parts + 1] = table.concat(bytes)
      vi = vi + c
      Budget.check()
    end
  end
  parts[#parts + 1] = u32(m or 0)
  if idx and m and m > 0 then
    local CHUNK = 65536
    local off = 0
    while off < m do
      local c = math.min(CHUNK, m - off)
      local chunk = {}
      for i = 1, c do
        chunk[i] = u32((idx[off + i] or 0) - 1)
      end
      parts[#parts + 1] = table.concat(chunk)
      off = off + c
      Budget.check()
    end
  end
  return table.concat(parts)
end

-- Decode a quantized payload into { n, verts, m, indices } -- verts a
-- 1-based Lua float table (the table sink's upload shape) and indices a
-- 1-based u32 table. nil when corrupt.
local function decodeQuant(s)
  if not s or #s < 8 then return nil end
  local n = readU32(s, 1)
  local vbytes = n * QUANT_STRIDE
  if n > 0 and #s < 4 + vbytes + 4 then return nil end
  local verts = {}
  if n > 0 then
    local CHUNK = 4096
    local vi = 0
    while vi < n do
      local c = math.min(CHUNK, n - vi)
      for i = 1, c do
        local r = 4 + (vi + i - 1) * QUANT_STRIDE + 1
        local fo = (vi + i - 1) * 6 + 1
        verts[fo] = readI16(s, r)
        verts[fo + 1] = readI16(s, r + 2)
        verts[fo + 2] = readI16(s, r + 4)
        verts[fo + 3] = readU16(s, r + 6) / 65535
        verts[fo + 4] = readU16(s, r + 8) / 65535
        verts[fo + 5] = s:byte(r + 10) / 255
        if i % 1024 == 0 then Budget.check() end
      end
      vi = vi + c
      Budget.check()
    end
  end
  local voff = 4 + vbytes
  local m = readU32(s, voff + 1)
  if m > 0 and #s < voff + 4 + m * 4 then return nil end
  if n == 0 then return { n = 0, m = m } end
  local rec = { n = n, verts = verts, m = m }
  if m > 0 then
    local indices = {}
    for i = 1, m do
      indices[i] = readU32(s, voff + 4 + (i - 1) * 4 + 1) + 1
      if i % 16384 == 0 then Budget.check() end
    end
    rec.indices = indices
  end
  return rec
end

local function encodeFigures(list)
  local parts = { string.char(math.min(#list, 255)) }
  for _, f in ipairs(list) do
    parts[#parts + 1] = encodeIndexed(f.n, f.verts or f.buf, f.m,
                                      f.indices or f.idx)
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
    local p = pos - 1
    list[#list + 1] = { n = d.n, verts = d.verts, m = d.m,
                        indices = d.indices,
                        wx = f32read(s, p), wz = f32read(s, p + 4),
                        y = f32read(s, p + 8), w = f32read(s, p + 12) }
    pos = pos + 16
  end
  return list
end

-- ---------------------------------------------------------- meta records
--
-- One small table per payload, written AFTER the payload bytes: its
-- presence is the commit marker, and it carries everything the boot
-- scan needs (fingerprint, format, lengths, codec) without reading the
-- payload. The engine's storage writes are whole-value and crash-safe,
-- so a meta record can never describe a torn payload.

local function metaFromPayload(fp, bytes)
  local got, off, meta = parseHeader(bytes)
  if not got or got ~= fp then return nil end
  local rawLen = meta.format == COMPRESSED_FORMAT
               and meta.rawLen or (#bytes - off + 1)
  return { fp = fp, format = meta.format, rawLen = rawLen,
           packedLen = meta.format == COMPRESSED_FORMAT
                       and meta.packedLen or (#bytes - off + 1),
           codec = CODEC_NAMES[meta.codec],
           size = #bytes }
end

local function writePayload(key, mkey, bytes, fp)
  if not writeBytes(key, bytes) then return false end
  local meta = metaFromPayload(fp, bytes)
  if not meta then return false end
  return writeTable(mkey, meta)
end

local function readPayload(key, fp)
  local s = readBytes(key)
  if not s then return nil end
  local got, off, meta = parseHeader(s)
  if not got or got ~= fp then
    deleteKey(key)
    deleteKey(key:gsub("^maps/", "meta/"))
    return nil
  end
  local body = unpackPayload(s, off, meta)
  return body, meta
end

local function repackRaw(key, mkey, fp, body, meta)
  if meta.format ~= RAW_FORMAT then return end
  local packed = packPayload(fp, body)
  if packed:byte(4) == COMPRESSED_FORMAT then
    compression = "unknown"
    codec = nil
    pcall(function() writePayload(key, mkey, packed, fp) end)
  end
end

-- A meta record's fingerprint, validated against the live identity
-- prefix for the job. nil when missing or stale.
local function metaFingerprint(mkey, prefix)
  local ok, meta = pcall(readTable, mkey)
  if not (ok and type(meta) == "table" and type(meta.fp) == "string") then
    return nil
  end
  if prefix and meta.fp:sub(1, #prefix) ~= prefix then return nil end
  return meta
end

local function safeMetaFingerprint(mkey, prefix)
  local ok, got = pcall(metaFingerprint, mkey, prefix)
  return ok and got or nil
end

-- A payload is VERIFIED without decoding it. parseHeader bounds the body
-- (magic, format, fingerprint, packed length against the stored bytes),
-- the meta record is the write's commit marker, and the engine's storage
-- write already round-tripped the bytes (stage tmp, verify decode, write
-- main, verify again). The full decodeQuant was pure-Lua over every
-- vertex and ran OUTSIDE the build coroutine -- Budget.check() is a no-op
-- there -- so verifying one job's terrain+water this way was one of the
-- multi-second main-thread stalls during the prebuild. Payloads are
-- re-validated the moment a map actually loads (loadTerrain/loadWater).
local function payloadShape(key, mkey, fp)
  local ok, s = pcall(readBytes, key)
  if not ok or not s then return nil end
  local got = parseHeader(s)
  if not got or got ~= fp then return nil end
  return safeMetaFingerprint(mkey, fp) and got or nil
end

local function safeValidPayload(key, mkey, fp)
  local ok, valid = pcall(payloadShape, key, mkey, fp)
  return ok and valid
end

local function updateCompression(records)
  local total, compressed = 0, 0
  local codecNames = {}
  for _, record in pairs(records or {}) do
    for _, pair in ipairs({
      { record.terrain, record.terrainFp },
      { record.water, record.waterFp },
      { record.aux, record.auxFp },
    }) do
      local meta = safeMetaFingerprint(pair[1], pair[2])
      if meta and meta.rawLen and meta.rawLen >= 1024 then
        total = total + 1
        if meta.format == COMPRESSED_FORMAT then
          compressed = compressed + 1
          if meta.codec then codecNames[meta.codec] = true end
        end
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
  local names = {}
  for name in pairs(codecNames) do names[#names + 1] = name end
  if #names == 1 then
    codec = names[1]
  elseif #names > 1 then
    codec = "MIX"
  else
    codec = nil
  end
end

function MeshCache.jobRecord(map, slot)
  local slotName = tostring(slot)
  local mapSlot = { id = map.id }
  return {
    key = tostring(map.id) .. "/" .. slotName,
    terrain = metaKey(mapSlot, slot, "terrain"),
    terrainFp = fingerprint(map, slot),
    water = metaKey(mapSlot, slot, "water"),
    waterFp = fingerprint(map, slot .. "Water"),
    aux = metaKey(mapSlot, slot, "aux"),
    auxFp = fingerprint(map, slot .. "Aux"),
  }
end

-- A record whose terrain and water payload metas exist under the live
-- identity. The aux meta is OPTIONAL: a job whose aux save failed still
-- has complete terrain/water (fillAux builds the aux live), and treating
-- it as required made a stale-aux job fail the boot scan and re-trigger a
-- full rebuild every launch. NOTE the record carries META keys (the boot
-- scan's bounded reads); payload bytes are validated when a map loads.
local function scanJob(job)
  local map = { id = job.id }
  local slot = tostring(job.slot)
  local terrainMeta = safeMetaFingerprint(
    metaKey(map, slot, "terrain"),
    identity() .. "|" .. tostring(job.id) .. "|" .. slot .. "|")
  local waterMeta = safeMetaFingerprint(
    metaKey(map, slot, "water"),
    identity() .. "|" .. tostring(job.id) .. "|" .. slot .. "Water|")
  if not (terrainMeta and waterMeta) then return nil end
  local auxMeta = safeMetaFingerprint(
    metaKey(map, slot, "aux"),
    identity() .. "|" .. tostring(job.id) .. "|" .. slot .. "Aux|")
  return { key = tostring(job.id) .. "/" .. slot,
           terrain = metaKey(map, slot, "terrain"),
           terrainFp = terrainMeta.fp, water = metaKey(map, slot, "water"),
           waterFp = waterMeta.fp,
           aux = auxMeta and metaKey(map, slot, "aux") or nil,
           auxFp = auxMeta and auxMeta.fp or nil }
end

-- A job's critical payloads are terrain + water: the aux (grass/flowers/
-- figures) is optional because fillAux already falls back to building it
-- live when the cache has none. Requiring all three made a single aux
-- write failure fail the job -- and CachePrebuild then aborted the whole
-- build -- so a platform whose aux save failed rebuilt every job each
-- boot. Terrain/water remain mandatory: without them the map has nothing.
function MeshCache.verifyJob(map, slot)
  if not MeshCache.available() then return false end
  local record = MeshCache.jobRecord(map, slot)
  local mapSlot = { id = map.id }
  return safeValidPayload(payloadKey(mapSlot, slot, "terrain"),
                          record.terrain, record.terrainFp, "mesh")
     and safeValidPayload(payloadKey(mapSlot, slot, "water"),
                          record.water, record.waterFp, "mesh")
end

-- --------------------------------------------------------------- manifest

-- Returns (manifest, failReason, manifestIdentity) where failReason is
-- nil on success, or one of "no_store", "missing", "format", "identity",
-- "records". The manifest is a TABLE now (the file-era text format died
-- with the filesystem).
local function readManifest()
  if not MeshCache.available() then return nil, "no_store" end
  local manifest = readTable(MANIFEST_KEY)
  if not manifest then return nil, "missing" end
  if manifest.format ~= "PVMC1" then return nil, "format" end
  if manifest.identity ~= identity() then
    return nil, "identity", manifest.identity
  end
  if type(manifest.records) ~= "table"
     or type(manifest.total) ~= "number" then
    return nil, "records"
  end
  return manifest
end

local function setLastFailure(reason, detail)
  lastFailure = { reason = reason, expected = identity() }
  if detail then
    for k, v in pairs(detail) do lastFailure[k] = v end
  end
end

function MeshCache.ready(jobs)
  -- The mid-build guard keys on buildIdentity, not dirty: invalidate()
  -- sets dirty for "geometry may have changed" and is SUPPOSED to be
  -- followed by the self-heal rescan below -- the boot invalidate deletes
  -- the manifest and deletes nothing else, so a rescan that finds every
  -- payload's meta record restores READY in place. Bailing on dirty here
  -- left the flag set until a full rebuild ran, which made CONTINUE ask
  -- to rebuild on every launch.
  if buildIdentity or not MeshCache.available() then
    setLastFailure(buildIdentity and "dirty" or "unavailable")
    return false, 0
  end
  local manifest, failReason, manifestIdentity = readManifest()
  if not manifest then
    if failReason == "identity" then
      setLastFailure("identity_mismatch", {
        actual = manifestIdentity,
        diffs = identityDiff(manifestIdentity, identity()),
      })
    elseif failReason == "missing" or failReason == "no_store" then
      setLastFailure("no_manifest")
    else
      setLastFailure("corrupt_manifest", { reason = failReason })
    end
    local records, done = {}, 0
    for _, job in ipairs(jobs or {}) do
      local record = scanJob(job)
      if not record then
        if lastFailure.reason ~= "identity_mismatch" then
          setLastFailure("file_missing", { job = tostring(job.id) .. "/"
            .. tostring(job.slot) })
        end
        return false, done
      end
      records[record.key] = record
      done = done + 1
    end
    if done == #jobs and MeshCache.writeManifest(records, #jobs) then
      lastFailure = nil
      return true, done
    end
    return false, done
  end
  if manifest.total ~= #jobs then
    setLastFailure("total_mismatch",
      { actual = manifest.total, jobs = #jobs })
    return false, 0
  end
  local done = 0
  for _, job in ipairs(jobs or {}) do
    local key = tostring(job.id) .. "/" .. tostring(job.slot)
    local record = manifest.records[key]
    local ok = record ~= nil
           and safeMetaFingerprint(record.terrain, record.terrainFp) ~= nil
           and safeMetaFingerprint(record.water, record.waterFp) ~= nil
           and (record.aux == nil
                or safeMetaFingerprint(record.aux, record.auxFp) ~= nil)
    if ok then done = done + 1 end
  end
  if done == #jobs then
    lastFailure = nil
    updateCompression(manifest.records)
    return true, done
  end
  -- Some records are missing or stale -- a partial manifest from a build
  -- interrupted before finish(), a payload the player wiped -- so rescan
  -- the metas. Storage writes are atomic, so whatever survived is a
  -- COMPLETE payload and the scan accepts the mix. A full rescan
  -- self-heals the manifest (READY); a partial one reports how many jobs
  -- are done so the prebuild can RESUME instead of restarting.
  local records, scanned = {}, 0
  for _, candidate in ipairs(jobs or {}) do
    local migrated = scanJob(candidate)
    if migrated then
      records[migrated.key] = migrated
      scanned = scanned + 1
    end
  end
  if scanned == #jobs and MeshCache.writeManifest(records, #jobs) then
    lastFailure = nil
    return true, scanned
  end
  setLastFailure("file_missing", { done = scanned, jobs = #jobs })
  return false, scanned
end

-- The records of every job whose three payload metas all survive with
-- the live identity -- the resume set a boot can hand back to a prebuild
-- that was interrupted mid-session.
function MeshCache.scanComplete(jobs)
  if not MeshCache.available() then return {}, 0 end
  local records, done = {}, 0
  for _, job in ipairs(jobs or {}) do
    local record = scanJob(job)
    if record then
      records[record.key] = record
      done = done + 1
    end
  end
  return records, done
end

-- The build.info record: the identity (and its components) that the
-- cache was actually built with, plus a timestamp.
local function writeBuildInfo(id, parts)
  if not MeshCache.available() then return end
  local info = {
    identity = id,
    format = parts.format,
    version = tostring(parts.version),
    activeVersion = tostring(parts.activeVersion),
    profile = parts.profile,
    dataKey = parts.dataKey,
    voidFill = parts.voidFill,
    builtAt = os.time and os.time() or 0,
  }
  writeTable(BUILD_INFO_KEY, info)
end

-- The shared manifest writer: records keyed by job key, `total` the full
-- job count. writeProgress lets a build UPDATE the manifest after every
-- completed job, so a build interrupted before finish() still leaves a
-- manifest naming exactly the jobs whose payloads survived.
local function writeManifestLines(records, total)
  if not MeshCache.available() or type(records) ~= "table" then
    return false
  end
  local keys = sortedKeys(records)
  if #keys > total then return false end
  local id = dirty and buildIdentity or identity()
  local manifest = { format = "PVMC1", identity = id, total = total,
                     records = {} }
  for _, key in ipairs(keys) do
    local record = records[key]
    manifest.records[key] = { key = record.key,
                              terrain = record.terrain,
                              terrainFp = record.terrainFp,
                              water = record.water,
                              waterFp = record.waterFp,
                              aux = record.aux, auxFp = record.auxFp }
  end
  return writeTable(MANIFEST_KEY, manifest), id
end

function MeshCache.writeProgress(records, total)
  local ok, id = writeManifestLines(records, total)
  if ok then
    writeBuildInfo(id, buildParts or identityParts())
  end
  return ok
end

function MeshCache.writeManifest(records, total)
  if not records or #sortedKeys(records) ~= total then return false end
  local ok, id = writeManifestLines(records, total)
  if ok then
    writeBuildInfo(id, buildParts or identityParts())
    dirty = false
    buildIdentity = nil
    buildParts = nil
    updateCompression(records)
    local okD, Overlay = pcall(V.require, "DebugOverlay")
    if okD and Overlay then
      Overlay.trace("manifest written (%d jobs, codec %s)",
                   total, tostring(codec))
    end
  end
  return ok
end

-- ------------------------------------------------------------ save/load

local function recordSaveFailure(kind, detail)
  saveFailures = saveFailures + 1
  lastSaveError = kind .. (detail and (": " .. tostring(detail)) or "")
  local okD, Overlay = pcall(V.require, "DebugOverlay")
  if okD and Overlay then
    Overlay.note("cache save failed: %s", lastSaveError)
  end
  return false
end

function MeshCache.saveTerrain(map, slot, buf, n, idx, m)
  if not MeshCache.available() then return false end
  local ok, result = pcall(function()
    local fp = fingerprint(map, slot)
    local bytes = packPayload(fp, encodeQuant(n, buf, m, idx))
    return writePayload(payloadKey(map, slot, "terrain"),
                        metaKey(map, slot, "terrain"), bytes, fp)
  end)
  if not ok then
    return recordSaveFailure("terrain", result)
  end
  if result ~= true then return recordSaveFailure("terrain") end
  local okD, Overlay = pcall(V.require, "DebugOverlay")
  if okD and Overlay then
    Overlay.trace("saved terrain %s/%s (%d verts)", tostring(map.id),
                 tostring(slot), n or 0)
  end
  return true
end

function MeshCache.saveWater(map, slot, buf, n, idx, m)
  if not MeshCache.available() then return false end
  local ok, result = pcall(function()
    local fp = fingerprint(map, slot .. "Water")
    local bytes = packPayload(fp, encodeQuant(n, buf, m, idx))
    return writePayload(payloadKey(map, slot, "water"),
                        metaKey(map, slot, "water"), bytes, fp)
  end)
  if not ok then
    return recordSaveFailure("water", result)
  end
  if result ~= true then return recordSaveFailure("water") end
  local okD, Overlay = pcall(V.require, "DebugOverlay")
  if okD and Overlay then
    Overlay.trace("saved water %s/%s (%d verts)", tostring(map.id),
                 tostring(slot), n or 0)
  end
  return true
end

-- The terrain and water for (map, slot), as data records, or nil on a
-- miss. The two must land together (a body build's water beside a full
-- mesh would draw the ring twice): callers check both.
function MeshCache.loadTerrain(map, slot)
  if not MeshCache.available() then return nil, nil end
  local t0 = love and love.timer and love.timer.getTime
             and love.timer.getTime() or 0
  local mesh = MeshCache.loadMeshData(map, slot, "terrain",
                                      fingerprint(map, slot))
  local water = MeshCache.loadMeshData(map, slot, "water",
                                       fingerprint(map, slot .. "Water"))
  if mesh and water then
    local okD, Overlay = pcall(V.require, "DebugOverlay")
    if okD and Overlay then
      local ms = (love and love.timer and love.timer.getTime
                  and math.floor((love.timer.getTime() - t0) * 1000 + 0.5))
                 or 0
      Overlay.count("cacheHits")
      Overlay.trace("cache hit terrain %s/%s (%dms, %d verts)",
                   tostring(map.id), tostring(slot), ms, mesh.n or 0)
      if ms and ms > 250 then
        Overlay.count("slowLoads")
        Overlay.error("SLOW load terrain %s/%s: %dms", tostring(map.id),
                     tostring(slot), ms)
      end
    end
  end
  return mesh, water
end

-- Read + validate one mesh payload. nil when missing/corrupt/stale.
function MeshCache.loadMeshData(map, slot, kind, fp)
  if not MeshCache.available() then return nil end
  local key = payloadKey(map, slot, kind)
  local mkey = metaKey(map, slot, kind)
  local body, meta = readPayload(key, fp)
  if body then repackRaw(key, mkey, fp, body, meta) end
  return body and decodeQuant(body) or nil
end

-- Persist the aux (grass/flowers/figures) vertex streams. `flattened` is
-- { grass = {n=.., buf=..}, flowers = {n=.., buf=..}, figures = {..} } --
-- produced by ChunkMesher from the Structures quads.
function MeshCache.saveAux(map, slot, flattened)
  if not MeshCache.available() then return false end
  local ok, result = pcall(function()
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
    local bytes = packPayload(fp, body .. flowers .. figures)
    return writePayload(payloadKey(map, slot, "aux"),
                        metaKey(map, slot, "aux"), bytes, fp)
  end)
  if not ok then
    return recordSaveFailure("aux", result)
  end
  if result ~= true then return recordSaveFailure("aux") end
  local okD, Overlay = pcall(V.require, "DebugOverlay")
  if okD and Overlay then
    Overlay.trace("saved aux %s/%s", tostring(map.id), tostring(slot))
  end
  return true
end

-- Load the aux streams: { grass, flowers, figures } data records, or nil.
function MeshCache.loadAux(map, slot)
  if not MeshCache.available() then return nil end
  local key = payloadKey(map, slot, "aux")
  local mkey = metaKey(map, slot, "aux")
  local fp = fingerprint(map, slot .. "Aux")
  local body, meta = readPayload(key, fp)
  if not body then return nil end
  repackRaw(key, mkey, fp, body, meta)
  local g = decodeIndexed(body)
  if not g then return nil end
  local fpos = 4 + g.n * 24 + 4 + g.m * 4
  local flowers = decodeIndexed(body:sub(1 + fpos))
  if not flowers then return nil end
  local fpos2 = fpos + 4 + flowers.n * 24 + 4 + flowers.m * 4
  local figures = decodeFigures(body:sub(1 + fpos2))
  if not figures then return nil end
  local okD, Overlay = pcall(V.require, "DebugOverlay")
  if okD and Overlay then
    Overlay.trace("cache hit aux %s/%s", tostring(map.id), tostring(slot))
  end
  return { grass = g, flowers = flowers, figures = figures }
end

-- Drop the cached payloads for one map (a block edit / a reloaded map)
-- or every map. mapId-scoped deletes are REAL: a cut tree changes blocks
-- without changing any fingerprint component, so the payload must go or
-- the 3D world keeps the old tree. The nil (full) case drops the
-- manifest only -- stale payloads are fingerprint-protected and die at
-- load -- which is what keeps restarts warm.
function MeshCache.invalidate(mapId)
  dirty = true
  compression = "unknown"
  codec = nil
  local okD, Overlay = pcall(V.require, "DebugOverlay")
  if okD and Overlay then
    Overlay.trace("cache invalidate %s", tostring(mapId or "ALL"))
  end
  if not MeshCache.available() then return end
  deleteKey(MANIFEST_KEY)
  if not mapId then return end
  local prefix = safeId(mapId)
  for _, key in ipairs(listKeys("maps/" .. prefix)) do
    deleteKey(key)
  end
  for _, key in ipairs(listKeys("meta/" .. prefix)) do
    deleteKey(key)
  end
end

function MeshCache.wipe(jobs)
  dirty = true
  compression = "unknown"
  codec = nil
  local okD, Overlay = pcall(V.require, "DebugOverlay")
  if okD and Overlay then Overlay.trace("cache wipe") end
  if not MeshCache.available() then return false end
  deleteKey(MANIFEST_KEY)
  deleteKey(BUILD_INFO_KEY)
  -- Everything the storage scoping lets us see is ours: list and delete
  -- both namespaces. (The prefix pass catches stale payloads from maps
  -- no longer present in the current data, which the jobs pass alone
  -- would leave behind.)
  for _, key in ipairs(listKeys("maps")) do
    deleteKey(key)
  end
  for _, key in ipairs(listKeys("meta")) do
    deleteKey(key)
  end
  return true
end

-- ------------------------------------------------ pure helpers (exported)

-- Flatten a quads table (the Structures grass/flowers/figure shapes:
-- 4 corners + uv + shade per quad) into the same INDEXED stream the
-- table sink emits: 4 unique verts per quad in `buf` (a 1-based Lua
-- float table), plus 6 u32 indices per quad (1-based, the table-map
-- convention -- the wire format conversion happens in the encoders).
-- Returns (floatCount, indexCount).
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
    for i = 1, 4 do
      local v = corner[i]
      buf[k + 1] = v[1]
      buf[k + 2] = v[2]
      buf[k + 3] = v[3]
      buf[k + 4] = v[4]
      buf[k + 5] = v[5]
      buf[k + 6] = v[6]
      k = k + 6
    end
    local v0 = k / 6 - 4          -- 0-based first vertex of this quad
    idxBuf[m + 1] = v0 + 1        -- 1-based table-map convention
    idxBuf[m + 2] = v0 + 2
    idxBuf[m + 3] = v0 + 3
    idxBuf[m + 4] = v0 + 1
    idxBuf[m + 5] = v0 + 3
    idxBuf[m + 6] = v0 + 4
    m = m + 6
  end
  return k, m
end

-- A mesh payload encoder, exported for tests (no header -- the header
-- needs the fingerprint). Given a ByteData float buffer + vertex count,
-- returns the serialized bytes; decodeMesh reads them back.
MeshCache.encodeMesh = encodeMesh
MeshCache.decodeMesh = decodeMesh
MeshCache.encodeIndexed = encodeIndexed
MeshCache.decodeIndexed = decodeIndexed
-- Diagnostics: populated by ready() on failure, cleared on success.
function MeshCache.getLastFailure()
  return lastFailure
end
MeshCache.identityParts = identityParts
MeshCache.identityDiff = identityDiff
function MeshCache.saveError()
  return lastSaveError
end
function MeshCache.saveFailureCount()
  return saveFailures
end

-- Read the build.info record written at build time (nil when absent).
function MeshCache.readBuildInfo()
  if not MeshCache.available() then return nil end
  return readTable(BUILD_INFO_KEY)
end

-- A build-time snapshot of what this cache was built under, for the
-- CachePrebuild bootstrap log.
function MeshCache.buildInfoSnapshot()
  if not buildParts then return nil end
  local info = { identity = buildIdentity }
  for k, v in pairs(buildParts) do info[k] = tostring(v) end
  return info
end

return MeshCache
