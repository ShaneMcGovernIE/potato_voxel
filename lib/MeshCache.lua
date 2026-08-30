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
--   payload format   "DSM" magic + format byte + fingerprint + optional
--                    codec/lengths, then a GPU-native float32 indexed
--                    vertex payload. love.data compress/decompress handles
--                    storage compression; runtime can upload the decoded
--                    bytes without rebuilding per-vertex Lua rows.
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

local CacheIdentity = V.require("CacheIdentity")
local CacheManifest = V.require("CacheManifest")
local CacheStorage = V.require("CacheStorage")
local GeometryStream = V.require("GeometryStream")
local Budget = V.require("BuildBudget")
local DecodePool = V.require("CacheDecodePool")
local Platform = V.require("Platform")
local Diagnostics = V.require("DiagnosticsBridge")

-- The engine's save-root resolver used to pick the portable SD-card dir.
-- With storage the engine owns placement entirely; SaveData is no longer
-- consulted (kept out of the picture deliberately -- see the removals ADR).

local MeshCache = {}
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
local compressionStats = { attempts = 0, rawBytes = 0, packedBytes = 0,
                           milliseconds = 0 }

local function now()
  local timer = love and love.timer
  return timer and timer.getTime and timer.getTime() or os.clock()
end

local function elapsedMs(started)
  return math.max(0, (now() - started) * 1000)
end

-- Bump when the meshing algorithm changes the vertex/UV output, so a
-- cache written by an older build is never trusted by a newer one. (The
-- mod version alone is not enough: a settings-only release changes no
-- geometry.) NOTE: this is the CACHE FORMAT, not the storage layout --
-- the payload format has its own magic byte inside each value.
-- (History elided here for the storage rewrite; the version carries
-- forward: 19 = quantized terrain/water, indexed aux, ROM-identity
-- headers. The move to scoped storage does NOT bump it -- the new store
-- starts empty, so every device rebuilds once on its own.)
-- 19: threaded prebuilds rebuild sprite/round-prop geometry from tileset
-- pixels and batch body+full output. Reject v18 payloads, which may have
-- been built by a worker that silently lacked atlas data.
-- 22: round/can profile correction invalidated incorrect prop-slab data.
-- 23: workers receive the live Brick geometry profile. Reject v22 worker
-- payloads built with default carved hulls instead of sprite-stack crosses.
-- 24: every newly-written payload uses normal LZ4 and body/full jobs share
-- one aux payload per map. Reject mixed-codec and duplicate-aux entries.
-- 25: terrain/water vertices are GPU-ready float32 bytes. Runtime hands the
-- payload to LÖVE Data APIs without allocating one Lua table per vertex;
-- body plus a disjoint ring delta replaces the duplicate full mesh.
-- 26: compact quantization added costly whole-map save/load conversions.
-- 27: restore GPU-native terrain/water payloads while retaining bounded
-- streaming and body-plus-ring geometry. Reject every v26 cache artifact.
-- 28: preserve profile conditional row heights and Kanto Cut-tree props.
-- 29: carry Gen 2 collision quads into worker geometry so tall grass survives
--     threaded builds and cache reloads.
-- 30: Gold cellCollision pins, door fold, and outdoor/border dispatch.
-- 31: Johto hop lips stay 6px ledges instead of two-row walls.
-- 32: Johto house dining table uses the Gen 1 house_table band model.
-- 33: that table is the 4x4 grid (5/21 underside row), not a 3-row lip.
-- 34: Johto house table is a desk lid + flood-cut legs, not a roof-band slab.
-- 35: voxel shade reads are the grayscale tileset PNG, not the GBC atlas.
-- 36: Johto signs keep their wood grain (prop_bg white); tall pines
--     revolve instead of standing as a planter-spray slab.
-- 37: indoor border black tiles stay void even when authored in-body;
--     Johto pines flood as one 32px silhouette; Crystal Center beds
--     and wall panels are not one bookcase.
-- 38: Johto tall-pine mid-canopy is cylinder, not unclaimed planter boxes.
-- 39: Johto dirt banks next to water recess into the water sheet.
-- 40: Elm's house table/stools/PCs use desk-set models, not 6px slabs.
-- 41: Elm table has corner posts; wall-mounted PCs no longer punch the
--     north wall.
-- 42: MagicaVoxel .vox building replacements.
-- 43: Crystal Johto pines use MagicaVoxel models from the tileset art.
-- 44: MagicaVoxel palette UVs sample the colour's own texel, so filled
--     .vox models keep their faces (Johto pines were hollow shells).
-- 45: Johto hop banks use beveled MagicaVoxel dirt instead of 6px boxes.
-- 46: MagicaVoxel stamps greedy-mesh coplanar faces and cache the
--     template so forests of pines and dirt banks are not per-voxel quads.
-- 47: Persist MagicaVoxel auxiliary geometry in the shared cache stream.
-- 48: Recognize Violet City's three-row-roof wooden-house template.
-- 49: Use complete map-scoped Violet house drawings and tuned roof courses.
-- 50: Let Violet City's pitched wooden houses use the gable-aware detector.
-- 51: Keep the deferred Violet house facade at two rows (16px) via its
--     explicit detector roof-band hint.
-- 57: Use the flat Mart and Pokemon Center models for Violet City.
-- 58: Replace Gen1 wooden fence posts and runs with authored VOX models.
-- 59: Rotate Gen1 wooden fence models to match the 2D fence run orientation.
-- 60: Keep the two Gen1 fence palette rows separate for Advanced colours.
-- 61: Add authored stone-pole VOX geometry support.
-- 62: Move the stone pole replacement to the actual OVERWORLD bollard cells.
-- 63: Replace Gen1 FOREST's 2x2 canopy groups with day/night VOX models.
-- 64: Rotate Gen1 FOREST canopy VOX models to match the 2D trunk direction
--     and keep the Gen1 profile on the daytime model at night.
-- 65: Point the Gen1 FOREST trunk south/down instead of east/right.
-- 66: Pitch the Gen1 FOREST tree -90 degrees so its trunk rests on the floor.
-- 67: Add authored Gen1 ordinary-tree and jump-ledge VOX geometry.
-- 68: Replace the wrong Gen1 double-tree asset with the Johto short bush.
-- 69: Keep authored round scenery out of unmasked connection rings and accept
--     single-row upright top bands during Gen1 precache.
-- 70: Replace Gen1 jump-ledge terminal caps when tile 52 sits over ground.
-- 71: Give the Gen1 terminal-cap copy tile 52's Advanced palette group.
-- 72: Stop the corner AO probe shading a connected map edge against border
--     ring the connection hides, which changes the baked vertex shade of
--     every tile along a seam.
MeshCache.GEOMETRY_VERSION = 72
local Identity = CacheIdentity.new({
  geometryVersion = MeshCache.GEOMETRY_VERSION,
})

-- ------------------------------------------------------------- storage

local Storage = CacheStorage.new()
local function storageAvailable() return Storage.available() end
local function readBytes(key) return Storage.readBytes(key) end
local function writeBytes(key, bytes) return Storage.writeBytes(key, bytes) end
local function writeTable(key, value) return Storage.writeTable(key, value) end
local function readTable(key) return Storage.readTable(key) end
local function listKeys(prefix) return Storage.listKeys(prefix) end
local function deleteKey(key) return Storage.deleteKey(key) end

function MeshCache.dir()
  return Storage.dir()
end

-- Compatibility forwards. MeshCache remains the public cache façade while
-- identity calculation lives in a side-effect-free service.
local function identity()
  return Identity.identity()
end

local function identityParts()
  return Identity.parts()
end

local function identityDiff(expected, actual)
  return Identity.identityDiff(expected, actual)
end

-- Manifest records have their own deterministic ordering; this is storage
-- serialization policy, not part of build identity.
local function sortedKeys(table_)
  local keys = {}
  for key in pairs(table_ or {}) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

local Manifest = CacheManifest.new({
  available = function() return MeshCache.available() end,
  readTable = readTable,
  writeTable = writeTable,
  identity = identity,
})

function MeshCache.configure(data)
  Identity.configure(data)
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

function MeshCache.compressionMetrics()
  return { attempts = compressionStats.attempts,
           rawBytes = compressionStats.rawBytes,
           packedBytes = compressionStats.packedBytes,
           milliseconds = compressionStats.milliseconds }
end

MeshCache.identity = identity

-- ---------------------------------------------------------- availability

function MeshCache.available()
  return storageAvailable()
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
  compressionStats = { attempts = 0, rawBytes = 0, packedBytes = 0,
                       milliseconds = 0 }
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

-- The final KEY SEGMENT becomes the file base name in the engine's storage
-- ("<key>.bin" / "<key>.lua" + .bak/.tmp). Windows treats AUX, CON, PRN,
-- NUL, COM1-9 and LPT1-9 as reserved device names and refuses to create
-- files whose base name matches, case-insensitively -- every aux payload
-- write failed write_failed/verify_failed on Windows while terrain/water
-- in the same directory succeeded. The internal kind stays "aux"
-- (traces, status, manifest); only the on-disk segment changes.
local function kindSegment(kind)
  return kind == "aux" and "deco" or kind
end

local function payloadKey(map, slot, kind)
  return "maps/" .. safeId(map.id) .. "/" .. tostring(slot) .. "/"
         .. kindSegment(kind)
end

local function metaKey(map, slot, kind)
  return "meta/" .. safeId(map.id) .. "/" .. tostring(slot) .. "/"
         .. kindSegment(kind)
end

-- Aux geometry describes a map, not its body/ring connection mask. Keeping
-- it once avoids encoding, compressing, storing, and reading the same data
-- twice during every prebuild.
local AUX_SLOT = "shared"
local function auxPayloadKey(map)
  return payloadKey(map, AUX_SLOT, "aux")
end

local function auxMetaKey(map)
  return metaKey(map, AUX_SLOT, "aux")
end

local function auxFingerprint(map)
  return fingerprint(map, "Aux")
end

-- ------------------------------------------------------------- encoding

-- Binary layout, little-endian throughout (unchanged from the file-era
-- cache):
--   raw format: "DSM" + format byte (1) + u32 fp-len + fp bytes + payload
--   compressed format: same header, then codec byte (1=lz4, 2=zstd) +
--     raw length + packed length + hash, then the packed bytes
--   mesh payload (terrain/water, v27):  u32 vertex count n, then n*6
--     little-endian float32 attributes, u32 index count m, then m u32 indices
--   aux/figures payload:               u32 n, then n*6 floats (unchanged)
--   figures payload: u8 count, then per figure: u32 n, n*6 floats,
--                    then f32 wx, f32 wz, f32 y, f32 w
local MAGIC = "DSM"
local RAW_FORMAT = 1
local COMPRESSED_FORMAT = 2
local LZ4_CODEC = 1
local ZSTD_CODEC = 2
local ZLIB_CODEC = 3
-- v24 writes only normal LZ4. Older entries remain decodable so update
-- migrations stay safe, but the v24 identity ensures they are never reused.
local CODEC_NAMES = { [LZ4_CODEC] = "lz4", [ZSTD_CODEC] = "zstd",
                      [ZLIB_CODEC] = "zlib" }
local MAX_PAYLOAD = 512 * 1024 * 1024

-- ffi is sandbox-banned and this engine's love.data ByteData carries no
-- float accessors, so float32 bytes are packed and unpacked in pure Lua.
-- Worker-built terrain arrives already packed; this encoder is the serial
-- compatibility path plus auxiliary geometry.
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

local function unpackPayload(s, offset, meta, owner)
  local body = s:sub(offset)
  if meta.format == RAW_FORMAT then return body end
  if meta.rawLen > MAX_PAYLOAD or meta.packedLen > #body then return nil end
  local data = love and love.data
  if not (data and data.decompress) then return nil end
  local codecName = CODEC_NAMES[meta.codec]
  if not codecName then return nil end
  local raw, handled = DecodePool.decode(codecName, body, meta.rawLen, owner)
  local ok = handled
  if not handled then
    ok, raw = pcall(data.decompress, "string", codecName, body)
  end
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
  compressionStats.rawBytes = compressionStats.rawBytes + #body
  if data and data.compress and #body >= 1024 then
    local timer = love and love.timer
    local started = timer and timer.getTime and timer.getTime() or os.clock()
    compressionStats.attempts = compressionStats.attempts + 1
    -- Level 0 is normal LZ4. LZ4HC spends much more CPU for a modest ratio
    -- gain, which recreates the Android prebuild-tail stalls we are removing.
    local ok, packed = pcall(data.compress, "string", "lz4", body, 0)
    local finished = timer and timer.getTime and timer.getTime() or os.clock()
    compressionStats.milliseconds = compressionStats.milliseconds
                                      + (finished - started) * 1000
    if ok and type(packed) == "string" and #packed < #body then
      compressionStats.packedBytes = compressionStats.packedBytes + #packed
      return header(fp, COMPRESSED_FORMAT, #body, #packed, 0, LZ4_CODEC)
             .. packed
    end
  end
  compressionStats.packedBytes = compressionStats.packedBytes + #body
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
-- (m entries). `idx` is a 1-based u32 Lua table; the wire format is 0-based
-- (LOVE Data-map convention), so the encode subtracts one.
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

local function readPayload(key, fp, owner)
  local timing = { readMs = 0, decompressMs = 0 }
  local started = now()
  local s = readBytes(key)
  timing.readMs = elapsedMs(started)
  if not s then return nil, nil, timing end
  local got, off, meta = parseHeader(s)
  if not got or got ~= fp then
    deleteKey(key)
    deleteKey(key:gsub("^maps/", "meta/"))
    return nil, nil, timing
  end
  started = now()
  local body = unpackPayload(s, off, meta, owner)
  if meta.format == COMPRESSED_FORMAT then
    timing.decompressMs = elapsedMs(started)
  end
  return body, meta, timing
end

-- A meta record's fingerprint, validated against the live identity
-- prefix for the job. nil when missing or stale.
local function metaFingerprint(mkey, prefix)
  -- A record whose optional save failed carries no meta key (aux is
  -- OPTIONAL): skip it before any storage call -- the engine answers
  -- invalid_key for a nil key, which would flood storageWarns on every
  -- prebuild. Genuinely-bad NON-nil keys still fall through to the read
  -- and its one-time invalid_key warn for legacy records.
  if not mkey then return nil end
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
  local seen = {}
  for _, record in pairs(records or {}) do
    for _, pair in ipairs({
      { record.terrain, record.terrainFp },
      { record.water, record.waterFp },
      { record.aux, record.auxFp },
    }) do
      local key = pair[1]
      local meta = key and not seen[key]
                   and safeMetaFingerprint(key, pair[2])
      if key then seen[key] = true end
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
    aux = auxMetaKey(mapSlot),
    auxFp = auxFingerprint(map),
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
    auxMetaKey(map),
    identity() .. "|" .. tostring(job.id) .. "|Aux|")
  return { key = tostring(job.id) .. "/" .. slot,
           terrain = metaKey(map, slot, "terrain"),
           terrainFp = terrainMeta.fp, water = metaKey(map, slot, "water"),
           waterFp = waterMeta.fp,
           aux = auxMeta and auxMetaKey(map) or nil,
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
  -- Storage.writeBytes already stages, rereads, byte-compares, commits and
  -- rereads each payload before its meta is written. Checking that commit
  -- marker avoids copying both large payload strings through Lua yet again.
  return safeMetaFingerprint(record.terrain, record.terrainFp) ~= nil
     and safeMetaFingerprint(record.water, record.waterFp) ~= nil
end

-- --------------------------------------------------------------- manifest

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
  local manifest, failReason, manifestIdentity = Manifest.read()
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

function MeshCache.writeProgress(records, total)
  local ok, id = Manifest.write(records, total, dirty and buildIdentity or nil)
  if ok then
    Manifest.writeBuildInfo(id, buildParts or identityParts())
  end
  return ok
end

function MeshCache.writeManifest(records, total)
  if not records or #sortedKeys(records) ~= total then return false end
  local ok, id = Manifest.write(records, total, dirty and buildIdentity or nil)
  if ok then
    Manifest.writeBuildInfo(id, buildParts or identityParts())
    dirty = false
    buildIdentity = nil
    buildParts = nil
    updateCompression(records)
    Diagnostics.trace("manifest written (%d jobs, codec %s)",
                      total, tostring(codec))
  end
  return ok
end

-- ------------------------------------------------------------ save/load

local function recordSaveFailure(kind, detail)
  saveFailures = saveFailures + 1
  lastSaveError = kind .. (detail and (": " .. tostring(detail)) or "")
  Diagnostics.note("cache save failed: %s", lastSaveError)
  return false
end

function MeshCache.saveTerrain(map, slot, buf, n, idx, m)
  if not MeshCache.available() then return false end
  local ok, result = pcall(function()
    local fp = fingerprint(map, slot)
    local bytes = packPayload(fp, encodeIndexed(n, buf, m, idx))
    return writePayload(payloadKey(map, slot, "terrain"),
                        metaKey(map, slot, "terrain"), bytes, fp)
  end)
  if not ok then
    return recordSaveFailure("terrain", result)
  end
  if result ~= true then return recordSaveFailure("terrain") end
  Diagnostics.trace("saved terrain %s/%s (%d verts)", tostring(map.id),
                    tostring(slot), n or 0)
  return true
end

function MeshCache.saveWater(map, slot, buf, n, idx, m)
  if not MeshCache.available() then return false end
  local ok, result = pcall(function()
    local fp = fingerprint(map, slot .. "Water")
    local bytes = packPayload(fp, encodeIndexed(n, buf, m, idx))
    return writePayload(payloadKey(map, slot, "water"),
                        metaKey(map, slot, "water"), bytes, fp)
  end)
  if not ok then
    return recordSaveFailure("water", result)
  end
  if result ~= true then return recordSaveFailure("water") end
  Diagnostics.trace("saved water %s/%s (%d verts)", tostring(map.id),
                    tostring(slot), n or 0)
  return true
end

local function savePackedChunks(map, slot, stream, kind)
  if not MeshCache.available() then return false end
  local ok, result = pcall(function()
    local raw, err = GeometryStream.toPayload(stream)
    if not raw then error("packed geometry: " .. tostring(err), 0) end
    local fp = fingerprint(map, kind == "terrain" and slot
                                or (slot .. "Water"))
    local bytes = packPayload(fp, raw)
    return writePayload(payloadKey(map, slot, kind),
                        metaKey(map, slot, kind), bytes, fp)
  end)
  if not ok then return recordSaveFailure(kind, result) end
  if result ~= true then return recordSaveFailure(kind) end
  Diagnostics.trace("saved %s chunks %s/%s", kind, tostring(map.id),
                    tostring(slot))
  return true
end

-- Fast worker boundary: PVGS3 chunks already carry MeshCache's native
-- vertex records. Join/rebase bytes directly; never expand into float or
-- index Lua tables on main thread.
function MeshCache.saveTerrainChunks(map, slot, stream)
  return savePackedChunks(map, slot, stream, "terrain")
end

function MeshCache.saveWaterChunks(map, slot, stream)
  return savePackedChunks(map, slot, stream, "water")
end

-- The terrain and water for (map, slot), as data records, or nil on a
-- miss. The two must land together: callers check both.
local function loadTerrainMode(map, slot, packed)
  if not MeshCache.available() then return nil, nil end
  local t0 = love and love.timer and love.timer.getTime
             and love.timer.getTime() or 0
  local mesh, meshTiming = MeshCache.loadMeshData(
    map, slot, "terrain", fingerprint(map, slot), packed)
  local water, waterTiming = MeshCache.loadMeshData(
    map, slot, "water", fingerprint(map, slot .. "Water"), packed)
  local timing = { readMs = 0, decompressMs = 0, decodeMs = 0 }
  for _, stage in ipairs({ meshTiming, waterTiming }) do
    if stage then
      timing.readMs = timing.readMs + (stage.readMs or 0)
      timing.decompressMs = timing.decompressMs + (stage.decompressMs or 0)
      timing.decodeMs = timing.decodeMs + (stage.decodeMs or 0)
    end
  end
  if mesh and water then
    local ms = (love and love.timer and love.timer.getTime
                and math.floor((love.timer.getTime() - t0) * 1000 + 0.5))
               or 0
    Diagnostics.count("cacheHits")
    Diagnostics.trace("cache hit terrain %s/%s (%dms, %d verts)",
                      tostring(map.id), tostring(slot), ms, mesh.n or 0)
    if ms and ms > 250 then
      Diagnostics.count("slowLoads")
      -- A warning, not an error: a slow-but-successful load must not
      -- inflate counters.errors (it never did before the counter split).
      -- The tag says WHERE it hitched: in-build loads are budgeted (the
      -- pump's overshoot warn covers them); sync loads run on the entry
      -- frame and ARE the freeze.
      local where = Budget.inBuild() and "in-build" or "sync"
      Diagnostics.warn("SLOW load terrain %s/%s: %dms (%s)", tostring(map.id),
                       tostring(slot), ms, where)
    end
  else
    Diagnostics.count("cacheMisses")
  end
  return mesh, water, timing
end

function MeshCache.loadTerrain(map, slot)
  return loadTerrainMode(map, slot, false)
end

function MeshCache.loadTerrainPacked(map, slot)
  return loadTerrainMode(map, slot, true)
end

-- Read + validate one mesh payload. nil when missing/corrupt/stale.
function MeshCache.loadMeshData(map, slot, kind, fp, packed)
  if not MeshCache.available() then return nil end
  local key = payloadKey(map, slot, kind)
  local body, _, timing = readPayload(key, fp, map and map.id)
  timing = timing or { readMs = 0, decompressMs = 0 }
  if packed and body then
    timing.decodeMs = 0
    local info = GeometryStream.inspectPayload(body)
    return info and { packed = body, format = "native",
                      n = info.n, m = info.m } or nil, timing
  end
  local started = now()
  local decoded = body and decodeIndexed(body) or nil
  timing.decodeMs = body and elapsedMs(started) or 0
  return decoded, timing
end

-- Persist the aux (grass/flowers/vox/figures) vertex streams. `flattened` is
-- { grass = {n=.., buf=..}, flowers = {n=.., buf=..},
--   vox = {n=.., buf=..}, figures = {..} } --
-- produced by ChunkMesher from the Structures quads.
function MeshCache.saveAux(map, slot, flattened, skipIfValid)
  if not MeshCache.available() then return false end
  local ok, result = pcall(function()
    local fp = auxFingerprint(map)
    local key = auxPayloadKey(map)
    local mkey = auxMetaKey(map)
    -- Pair jobs visit body then ring. The ring slot must not encode or
    -- rewrite an aux payload the body slot has already committed. Direct
    -- callers may omit this flag when intentionally refreshing a map.
    if skipIfValid and safeMetaFingerprint(mkey, fp) then return true end
    local body = encodeIndexed(flattened.grass and flattened.grass.n or 0,
                               flattened.grass and flattened.grass.buf,
                               flattened.grass and flattened.grass.m or 0,
                               flattened.grass and flattened.grass.idx)
    local flowers = encodeIndexed(flattened.flowers and flattened.flowers.n or 0,
                                  flattened.flowers and flattened.flowers.buf,
                                  flattened.flowers and flattened.flowers.m or 0,
                                  flattened.flowers and flattened.flowers.idx)
    local vox = encodeIndexed(flattened.vox and flattened.vox.n or 0,
                              flattened.vox and flattened.vox.buf,
                              flattened.vox and flattened.vox.m or 0,
                              flattened.vox and flattened.vox.idx)
    local figures = encodeFigures(flattened.figures or {})
    local bytes = packPayload(fp, body .. flowers .. vox .. figures)
    return writePayload(key, mkey, bytes, fp)
  end)
  if not ok then
    return recordSaveFailure("aux", result)
  end
  if result ~= true then return recordSaveFailure("aux") end
  Diagnostics.trace("saved aux %s/shared", tostring(map.id))
  return true
end

-- Load auxiliary streams as v25 native indexed records. Only the record
-- boundaries and four figure placement floats are parsed here; vertex and
-- index bytes remain packed for MeshRuntime's Data-backed GPU upload.
function MeshCache.loadAuxPacked(map, slot)
  if not MeshCache.available() then return nil end
  local key = auxPayloadKey(map)
  local fp = auxFingerprint(map)
  local body, _, timing = readPayload(key, fp, map and map.id)
  timing = timing or { readMs = 0, decompressMs = 0 }
  timing.decodeMs = 0
  if not body then
    Diagnostics.count("cacheMisses")
    return nil, timing
  end

  local started = now()
  local function recordAt(pos)
    local info = GeometryStream.inspectPayloadAt(body, pos)
    if not info then return nil end
    return {
      packed = body:sub(pos, info.nextOffset - 1),
      n = info.n,
      m = info.m,
    }, info.nextOffset
  end

  local grass, pos = recordAt(1)
  local flowers
  if grass then flowers, pos = recordAt(pos) end
  local vox
  if flowers then vox, pos = recordAt(pos) end
  if not flowers or not vox or pos > #body then
    timing.decodeMs = elapsedMs(started)
    return nil, timing
  end
  local count = body:byte(pos)
  pos = pos + 1
  local figures = {}
  for _ = 1, count do
    local figure
    figure, pos = recordAt(pos)
    if not figure or pos + 15 > #body then
      timing.decodeMs = elapsedMs(started)
      return nil, timing
    end
    figure.wx = f32read(body, pos)
    figure.wz = f32read(body, pos + 4)
    figure.y = f32read(body, pos + 8)
    figure.w = f32read(body, pos + 12)
    pos = pos + 16
    figures[#figures + 1] = figure
  end
  timing.decodeMs = elapsedMs(started)
  if pos ~= #body + 1 then return nil, timing end
  Diagnostics.trace("cache hit aux %s/shared", tostring(map.id))
  return { grass = grass, flowers = flowers, vox = vox, figures = figures }, timing
end

-- Compatibility decoded form used by probes and old direct callers.
-- Runtime map transitions use loadAuxPacked above.
function MeshCache.loadAux(map, slot)
  if not MeshCache.available() then return nil end
  local key = auxPayloadKey(map)
  local fp = auxFingerprint(map)
  local body, _, timing = readPayload(key, fp, map and map.id)
  timing = timing or { readMs = 0, decompressMs = 0 }
  timing.decodeMs = 0
  if not body then
    Diagnostics.count("cacheMisses")
    return nil, timing
  end
  local started = now()
  local g = decodeIndexed(body)
  if not g then
    timing.decodeMs = elapsedMs(started)
    return nil, timing
  end
  local fpos = 4 + g.n * 24 + 4 + g.m * 4
  local flowers = decodeIndexed(body:sub(1 + fpos))
  if not flowers then
    timing.decodeMs = elapsedMs(started)
    return nil, timing
  end
  local fpos2 = fpos + 4 + flowers.n * 24 + 4 + flowers.m * 4
  local vox = decodeIndexed(body:sub(1 + fpos2))
  if not vox then
    timing.decodeMs = elapsedMs(started)
    return nil, timing
  end
  local fpos3 = fpos2 + 4 + vox.n * 24 + 4 + vox.m * 4
  local figures = decodeFigures(body:sub(1 + fpos3))
  timing.decodeMs = elapsedMs(started)
  if not figures then return nil, timing end
  Diagnostics.trace("cache hit aux %s/shared", tostring(map.id))
  return { grass = g, flowers = flowers, vox = vox, figures = figures }, timing
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
  Diagnostics.trace("cache invalidate %s", tostring(mapId or "ALL"))
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
  Diagnostics.trace("cache wipe")
  if not MeshCache.available() then return false end
  deleteKey(MANIFEST_KEY)
  deleteKey(BUILD_INFO_KEY)
  -- Everything the storage scoping lets us see is ours: list and delete
  -- both namespaces. (The prefix pass catches stale payloads from maps
  -- no longer present in the current data, which the jobs pass alone
  -- would leave behind.)
  local mapsKeys = listKeys("maps")
  local metaKeys = listKeys("meta")
  for _, key in ipairs(mapsKeys) do
    deleteKey(key)
  end
  for _, key in ipairs(metaKeys) do
    deleteKey(key)
  end
  -- On Switch the scoped-storage delete has been observed to no-op while
  -- reporting success: after a wipe the prebuild restarted from zero
  -- (manifest/metas gone) yet the old payloads kept serving cache hits.
  -- Verify by read-back and re-list, count survivors as storage
  -- failures, and answer false so Prebuild.wipe does not reset its state
  -- over a wipe that did not land. Other platforms keep the historical
  -- fire-and-forget behavior.
  if Platform.isSwitch() then
    local survivors = {}
    if readTable(MANIFEST_KEY) ~= nil then
      survivors[#survivors + 1] = MANIFEST_KEY
    end
    if readTable(BUILD_INFO_KEY) ~= nil then
      survivors[#survivors + 1] = BUILD_INFO_KEY
    end
    for _, key in ipairs(listKeys("maps")) do
      survivors[#survivors + 1] = key
    end
    for _, key in ipairs(listKeys("meta")) do
      survivors[#survivors + 1] = key
    end
    if #survivors > 0 then
      Diagnostics.count("storageFails")
      Diagnostics.error("cache wipe: %d key(s) survived delete", #survivors)
      return false
    end
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
