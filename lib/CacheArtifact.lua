-- PVMC2 per-map artifact with a last-write commit record.
--
-- Chunk bytes are durable before metadata and the commit marker.  Readers
-- accept nothing until every declared chunk, checksum, identity, and required
-- stream is present.
local CacheArtifact = {}

local function checksum(bytes)
  local hash = 2166136261
  for i = 1, #bytes do
    hash = (hash * 16777619 + bytes:byte(i)) % 2147483647
  end
  return tostring(hash)
end

local function streamKey(kind, sequence)
  return tostring(kind) .. "/" .. tostring(sequence)
end

function CacheArtifact.new(ctx)
  assert(type(ctx) == "table", "cache artifact context required")
  assert(type(ctx.writeBytes) == "function"
         and type(ctx.readBytes) == "function"
         and type(ctx.writeTable) == "function"
         and type(ctx.readTable) == "function",
         "cache artifact storage is incomplete")

  local function prefix(mapId, identity)
    return "artifact/" .. tostring(mapId) .. "/" .. tostring(identity)
  end

  local service = {}

  function service:begin(mapId, identity, required)
    assert(mapId ~= nil and identity ~= nil, "artifact identity required")
    local needed = {}
    for _, kind in ipairs(required or { "body", "ring", "aux" }) do
      needed[kind] = true
    end
    return {
      format = "PVMC2",
      mapId = tostring(mapId),
      identity = tostring(identity),
      prefix = prefix(mapId, identity),
      required = needed,
      chunks = {},
      committed = false,
    }
  end

  function service:append(artifact, stream, chunk)
    if type(artifact) ~= "table" or artifact.committed then
      return false, "closed"
    end
    if stream ~= "body" and stream ~= "ring" and stream ~= "aux" then
      return false, "stream"
    end
    if type(chunk) ~= "table" or type(chunk.bytes) ~= "string"
       or type(chunk.sequence) ~= "number"
       or chunk.sequence < 1 or chunk.sequence % 1 ~= 0 then
      return false, "chunk"
    end
    if artifact.chunks[streamKey(stream, chunk.sequence)] then
      return false, "duplicate"
    end
    if stream == "aux" and artifact.hasAux then return false, "duplicate_aux" end
    local actual = checksum(chunk.bytes)
    if chunk.checksum and tostring(chunk.checksum) ~= actual then
      return false, "checksum"
    end
    local key = artifact.prefix .. "/chunk/" .. stream .. "/"
              .. tostring(chunk.sequence)
    if not ctx.writeBytes(key, chunk.bytes) then return false, "storage" end
    local record = { kind = stream, sequence = chunk.sequence, key = key,
                     checksum = actual, bytes = #chunk.bytes }
    artifact.chunks[streamKey(stream, chunk.sequence)] = record
    if stream == "aux" then artifact.hasAux = true end
    return { sequence = chunk.sequence, checksum = actual, bytes = #chunk.bytes }
  end

  function service:commit(artifact)
    if type(artifact) ~= "table" or artifact.committed then
      return false, "closed"
    end
    for kind in pairs(artifact.required) do
      local found = false
      for _, record in pairs(artifact.chunks) do
        if record.kind == kind then found = true; break end
      end
      if not found then return false, "missing_" .. kind end
    end
    local meta = { format = "PVMC2", mapId = artifact.mapId,
                   identity = artifact.identity, chunks = artifact.chunks }
    if not ctx.writeTable(artifact.prefix .. "/meta", meta) then
      return false, "metadata"
    end
    local commit = { format = "PVMC2", mapId = artifact.mapId,
                     identity = artifact.identity,
                     chunkCount = 0, committed = true }
    for _ in pairs(artifact.chunks) do commit.chunkCount = commit.chunkCount + 1 end
    if not ctx.writeTable(artifact.prefix .. "/commit", commit) then
      return false, "commit"
    end
    artifact.committed = true
    return true
  end

  function service:open(mapId, identity)
    local p = prefix(mapId, identity)
    local commit = ctx.readTable(p .. "/commit")
    if type(commit) ~= "table" or commit.format ~= "PVMC2"
       or commit.committed ~= true then
      return nil, "uncommitted"
    end
    if tostring(commit.mapId) ~= tostring(mapId)
       or tostring(commit.identity) ~= tostring(identity) then
      return nil, "identity"
    end
    local meta = ctx.readTable(p .. "/meta")
    if type(meta) ~= "table" or meta.format ~= "PVMC2"
       or meta.identity ~= commit.identity then
      return nil, "metadata"
    end
    local chunks = {}
    local count = 0
    for key, record in pairs(meta.chunks or {}) do
      if type(record) ~= "table" or record.key == nil then
        return nil, "metadata"
      end
      local bytes = ctx.readBytes(record.key)
      if type(bytes) ~= "string"
         or checksum(bytes) ~= tostring(record.checksum)
         or #bytes ~= record.bytes then
        return nil, "checksum"
      end
      chunks[key] = { kind = record.kind, sequence = record.sequence,
                      key = record.key, checksum = record.checksum,
                      bytes = record.bytes }
      count = count + 1
    end
    if count ~= commit.chunkCount then return nil, "chunk_count" end
    return { format = "PVMC2", mapId = tostring(mapId),
             identity = tostring(identity), committed = true,
             chunks = chunks, metadata = meta }
  end

  service.checksum = checksum
  return service
end

return CacheArtifact
