-- Bounded geometry chunks.
--
-- The writer keeps flat numeric arrays only until flush. The worker/channel
-- boundary receives one compact binary string plus scalar metadata, never a
-- row per vertex or a nested vertex/index table.
local GeometryStream = {
  MAX_CHUNK_VERTICES = 16384,
  MAX_CHUNK_INDICES = 24576,
  MAX_IN_FLIGHT_CHUNKS = 4,
}

local function checksum(bytes)
  local hash = 2166136261
  for i = 1, #bytes do
    hash = (hash * 16777619 + bytes:byte(i)) % 2147483647
  end
  return tostring(hash)
end

local function finite(value)
  if type(value) ~= "number" or value ~= value
     or value == math.huge or value == -math.huge then
    error("geometry stream scalar must be finite", 0)
  end
  return value
end

local function u32(value)
  value = math.floor(finite(value))
  if value < 0 then value = 0 end
  return string.char(value % 256,
                     math.floor(value / 256) % 256,
                     math.floor(value / 65536) % 256,
                     math.floor(value / 16777216) % 256)
end

-- Native LÖVE mesh vertices use six little-endian float32 values. Packing
-- happens in workers during cache construction; runtime can hand these bytes
-- straight to love.graphics.newMesh without rebuilding Lua row tables.
local function f32(value)
  value = finite(value)
  if value == 0 then return string.char(0, 0, 0, 0) end
  local sign = 0
  if value < 0 then sign = 0x80; value = -value end
  if value == math.huge then
    return string.char(0, 0, 0x80, sign + 0x7F)
  end
  local mantissa, exponent = math.frexp(value)
  exponent = exponent + 126
  if exponent <= 0 then return string.char(0, 0, 0, sign) end
  mantissa = math.floor((mantissa * 2 - 1) * 8388608 + 0.5)
  if mantissa >= 8388608 then
    mantissa, exponent = 0, exponent + 1
  end
  if exponent >= 255 then
    return string.char(0, 0, 0x80, sign + 0x7F)
  end
  return string.char(mantissa % 256, math.floor(mantissa / 256) % 256,
                     (exponent % 2) * 128
                       + math.floor(mantissa / 65536),
                     sign + math.floor(exponent / 2))
end

local function readF32(bytes, offset)
  local b1, b2, b3, b4 = bytes:byte(offset, offset + 3)
  local sign = b4 >= 128 and -1 or 1
  local exponent = (b4 % 128) * 2 + math.floor(b3 / 128)
  local mantissa = ((b3 % 128) * 65536 + b2 * 256 + b1) / 8388608
  if exponent == 0 then return 0 end
  if exponent == 255 then return sign * math.huge end
  return sign * math.ldexp(1 + mantissa, exponent - 127)
end

local function readU32(bytes, offset)
  return bytes:byte(offset)
       + bytes:byte(offset + 1) * 256
       + bytes:byte(offset + 2) * 65536
       + bytes:byte(offset + 3) * 16777216
end

GeometryStream.checksum = checksum

local Writer = {}
Writer.__index = Writer

function Writer.new(kind, maxVertices, maxIndices)
  assert(type(kind) == "string" and kind ~= "", "stream kind required")
  local self = setmetatable({
    kind = kind,
    maxVertices = maxVertices or GeometryStream.MAX_CHUNK_VERTICES,
    maxIndices = maxIndices or GeometryStream.MAX_CHUNK_INDICES,
    sequence = 1,
    vertices = {},
    indices = {},
    vertexCount_ = 0,
    indexCount_ = 0,
  }, Writer)
  assert(self.maxVertices > 0 and self.maxIndices > 0,
         "geometry stream bounds must be positive")
  return self
end

function Writer:vertexCount()
  return self.vertexCount_
end

function Writer:indexCount()
  return self.indexCount_
end

function Writer:full(nextVertices, nextIndices)
  if nextVertices == nil and nextIndices == nil then
    return self.vertexCount_ >= self.maxVertices
       or self.indexCount_ >= self.maxIndices
  end
  return self.vertexCount_ + (nextVertices or 0) > self.maxVertices
      or self.indexCount_ + (nextIndices or 0) > self.maxIndices
end

function Writer:pushVertex(x, y, z, u, v, shade)
  if self:full(1, 0) then error("geometry vertex chunk full", 0) end
  local out = self.vertices
  local offset = self.vertexCount_ * 6
  out[offset + 1] = finite(x)
  out[offset + 2] = finite(y)
  out[offset + 3] = finite(z)
  out[offset + 4] = finite(u)
  out[offset + 5] = finite(v)
  out[offset + 6] = finite(shade)
  self.vertexCount_ = self.vertexCount_ + 1
  return self.vertexCount_
end

function Writer:pushIndex(index)
  if self:full(0, 1) then error("geometry index chunk full", 0) end
  assert(type(index) == "number" and index >= 1 and index % 1 == 0,
         "geometry index must be a positive integer")
  self.indexCount_ = self.indexCount_ + 1
  self.indices[self.indexCount_] = index
  return self.indexCount_
end

function Writer:flush()
  if self.vertexCount_ == 0 and self.indexCount_ == 0 then return nil end
  local parts = { "PVGS3", u32(self.vertexCount_), u32(self.indexCount_) }
  local vertexBytes = {}
  for i = 1, self.vertexCount_ do
    local base = (i - 1) * 6 + 1
    vertexBytes[i] = f32(self.vertices[base])
      .. f32(self.vertices[base + 1])
      .. f32(self.vertices[base + 2])
      .. f32(self.vertices[base + 3])
      .. f32(self.vertices[base + 4])
      .. f32(self.vertices[base + 5])
  end
  parts[#parts + 1] = table.concat(vertexBytes)
  local indexBytes = {}
  for i = 1, self.indexCount_ do
    indexBytes[i] = u32(self.indices[i])
  end
  parts[#parts + 1] = table.concat(indexBytes)
  local bytes = table.concat(parts)
  local chunk = {
    kind = self.kind,
    sequence = self.sequence,
    vertexCount = self.vertexCount_,
    indexCount = self.indexCount_,
    byteLength = #bytes,
    checksum = checksum(bytes),
    bytes = bytes,
  }
  self.sequence = self.sequence + 1
  self.vertices = {}
  self.indices = {}
  self.vertexCount_ = 0
  self.indexCount_ = 0
  return chunk
end

GeometryStream.Writer = Writer

-- Inspect one native indexed record inside a larger payload without
-- allocating vertex or index tables. Layout: u32 vertex count, n * 24-byte
-- vertices, u32 index count, then zero-based u32 indices.
function GeometryStream.inspectPayloadAt(bytes, offset)
  offset = offset or 1
  if type(bytes) ~= "string" or type(offset) ~= "number"
     or offset < 1 or offset % 1 ~= 0 or #bytes - offset + 1 < 8 then
    return nil, "payload"
  end
  local n = readU32(bytes, offset)
  local vertexBytes = n * 24
  local indexCountOffset = offset + 4 + vertexBytes
  if indexCountOffset + 3 > #bytes then return nil, "vertices" end
  local m = readU32(bytes, indexCountOffset)
  local indexBytes = m * 4
  local byteLength = 8 + vertexBytes + indexBytes
  local nextOffset = offset + byteLength
  if nextOffset - 1 > #bytes then return nil, "length" end
  return {
    n = n,
    m = m,
    vertexOffset = offset + 4,
    vertexBytes = vertexBytes,
    indexOffset = indexCountOffset + 4,
    indexBytes = indexBytes,
    byteLength = byteLength,
    nextOffset = nextOffset,
  }
end

function GeometryStream.inspectPayload(bytes)
  local info, reason = GeometryStream.inspectPayloadAt(bytes, 1)
  if not info then return nil, reason end
  if info.nextOffset ~= #bytes + 1 then return nil, "length" end
  return info
end

function GeometryStream.payloadVertexBytes(bytes, info)
  info = info or GeometryStream.inspectPayload(bytes)
  if not info then return nil, "payload" end
  if info.vertexBytes == 0 then return "" end
  return bytes:sub(info.vertexOffset,
                   info.vertexOffset + info.vertexBytes - 1)
end

-- Decode only the rows needed for one Mesh:setVertices call. The returned
-- table never exceeds the caller's upload bound and is discarded afterwards.
function GeometryStream.payloadRows(bytes, first, count, info)
  info = info or GeometryStream.inspectPayload(bytes)
  if not info then return nil, "payload" end
  first = first or 1
  count = count or (info.n - first + 1)
  if first < 1 or count < 0 or first + count - 1 > info.n then
    return nil, "range"
  end
  local rows = {}
  for i = 1, count do
    local source = info.vertexOffset + (first + i - 2) * 24
    rows[i] = {
      readF32(bytes, source),
      readF32(bytes, source + 4),
      readF32(bytes, source + 8),
      readF32(bytes, source + 12),
      readF32(bytes, source + 16),
      readF32(bytes, source + 20),
    }
  end
  return rows
end

-- LÖVE replaces the complete vertex map in one call, so indices are the one
-- unavoidable whole-stream table. Convert the wire's zero-based values to
-- the 1-based table convention expected by Mesh:setVertexMap.
function GeometryStream.payloadIndices(bytes, info)
  info = info or GeometryStream.inspectPayload(bytes)
  if not info then return nil, "payload" end
  local indices = {}
  for i = 1, info.m do
    indices[i] = readU32(bytes, info.indexOffset + (i - 1) * 4) + 1
  end
  return indices
end

-- Large LÖVE meshes can accept their complete vertex map as a ByteData
-- object. The cache already stores exactly that zero-based uint32 layout,
-- so expose only its index region instead of first expanding it into a Lua
-- table. Callers use this only for meshes that require uint32 indices.
function GeometryStream.payloadIndexBytes(bytes, info)
  info = info or GeometryStream.inspectPayload(bytes)
  if not info then return nil, "payload" end
  if info.m == 0 then return "" end
  return bytes:sub(info.indexOffset, info.indexOffset + info.m * 4 - 1)
end

-- Decode one bounded chunk at the main-thread cache boundary. This returns
-- the legacy flat upload shape, but only for one chunk at a time; workers no
-- longer build or send whole-map row tables.
function GeometryStream.decode(chunk)
  if type(chunk) ~= "table" or type(chunk.bytes) ~= "string" then
    return nil, "chunk"
  end
  local bytes = chunk.bytes
  if bytes:sub(1, 5) ~= "PVGS3" or #bytes < 13 then
    return nil, "format"
  end
  local n, m = readU32(bytes, 6), readU32(bytes, 10)
  local expected = 13 + n * 24 + m * 4
  if #bytes ~= expected then return nil, "length" end
  if chunk.vertexCount and chunk.vertexCount ~= n then return nil, "vertices" end
  if chunk.indexCount and chunk.indexCount ~= m then return nil, "indices" end
  if chunk.checksum and tostring(chunk.checksum) ~= checksum(bytes) then
    return nil, "checksum"
  end
  local buf = {}
  for i = 0, n - 1 do
    local source = 14 + i * 24
    local target = i * 6 + 1
    buf[target] = readF32(bytes, source)
    buf[target + 1] = readF32(bytes, source + 4)
    buf[target + 2] = readF32(bytes, source + 8)
    buf[target + 3] = readF32(bytes, source + 12)
    buf[target + 4] = readF32(bytes, source + 16)
    buf[target + 5] = readF32(bytes, source + 20)
  end
  local idx = {}
  local indexOffset = 14 + n * 24
  for i = 1, m do
    idx[i] = readU32(bytes, indexOffset + (i - 1) * 4)
  end
  return { buf = buf, n = n, idx = idx, m = m }
end

-- Convert bounded PVGS3 chunks to MeshCache's native indexed payload. Vertex
-- bytes already match LÖVE's six-float mesh format, so runtime performs no
-- per-vertex Lua conversion.
function GeometryStream.toPayload(stream)
  if type(stream) ~= "table" or type(stream.chunks) ~= "table" then
    return nil, "stream"
  end
  local infos = {}
  local totalVertices, totalIndices = 0, 0
  local vertexParts = { u32(0) }
  for _, chunk in ipairs(stream.chunks) do
    local bytes = chunk and chunk.bytes
    if type(bytes) ~= "string" or bytes:sub(1, 5) ~= "PVGS3"
       or #bytes < 13 then return nil, "format" end
    local n, m = readU32(bytes, 6), readU32(bytes, 10)
    local expected = 13 + n * 24 + m * 4
    if #bytes ~= expected then return nil, "length" end
    if chunk.vertexCount and chunk.vertexCount ~= n then return nil, "vertices" end
    if chunk.indexCount and chunk.indexCount ~= m then return nil, "indices" end
    if chunk.checksum and tostring(chunk.checksum) ~= checksum(bytes) then
      return nil, "checksum"
    end
    infos[#infos + 1] = {
      bytes = bytes, n = n, m = m, vertexOffset = totalVertices,
      indexOffset = 14 + n * 24,
    }
    vertexParts[#vertexParts + 1] = bytes:sub(14, 13 + n * 24)
    totalVertices = totalVertices + n
    totalIndices = totalIndices + m
  end
  if stream.n ~= totalVertices or stream.m ~= totalIndices then
    return nil, "count"
  end
  vertexParts[1] = u32(totalVertices)
  local parts = { table.concat(vertexParts), u32(totalIndices) }
  for _, info in ipairs(infos) do
    local indexParts = {}
    for i = 0, info.m - 1 do
      local localIndex = readU32(info.bytes, info.indexOffset + i * 4)
      indexParts[i + 1] = u32(localIndex - 1 + info.vertexOffset)
    end
    parts[#parts + 1] = table.concat(indexParts)
  end
  return table.concat(parts)
end

return GeometryStream
