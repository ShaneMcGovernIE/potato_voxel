-- Manifest and build-info records for MeshCache.
-- Storage access and identity policy arrive through ctx, keeping this module
-- focused on record shape, validation, and deterministic serialization.
local CacheManifest = {}

function CacheManifest.new(ctx)
  local function sortedKeys(table_)
    local keys = {}
    for key in pairs(table_ or {}) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
  end

  local service = {}

  function service.read()
    if not ctx.available() then return nil, "no_store" end
    local manifest = ctx.readTable("manifest")
    if not manifest then return nil, "missing" end
    if manifest.format ~= "PVMC2" then return nil, "format" end
    if manifest.identity ~= ctx.identity() then
      return nil, "identity", manifest.identity
    end
    if type(manifest.records) ~= "table"
       or type(manifest.total) ~= "number" then
      return nil, "records"
    end
    return manifest
  end

  function service.writeBuildInfo(id, parts)
    if not ctx.available() then return end
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
    ctx.writeTable("buildinfo", info)
  end

  function service.write(records, total, buildIdentity)
    if not ctx.available() or type(records) ~= "table" then
      return false
    end
    local keys = sortedKeys(records)
    if #keys > total then return false end
    local id = buildIdentity or ctx.identity()
    local manifest = { format = "PVMC2", identity = id, total = total,
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
    return ctx.writeTable("manifest", manifest), id
  end

  return service
end

return CacheManifest
