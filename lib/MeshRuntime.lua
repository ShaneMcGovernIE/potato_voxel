-- GPU-facing ownership for ChunkMesher's cached mesh slots.
--
-- Geometry and queue policy stay outside this module. This boundary owns
-- only the conversion from serialized vertex streams to LOVE meshes and the
-- release/swap rules for the mesh objects kept in a cache entry.
local V = ...

local Voxel3D = V.require("Voxel3D")
local Budget = V.require("BuildBudget")
local GeometryStream = V.require("GeometryStream")

local MeshRuntime = {}
-- Compatibility fallback for engines that reject Data-backed mesh uploads.
-- v27 cache records normally bypass this row conversion entirely.
local UPLOAD_CHUNK = 1024

local function now()
  local timer = love and love.timer
  return timer and timer.getTime and timer.getTime() or os.clock()
end

local function addElapsed(stages, key, started)
  stages[key] = (stages[key] or 0) + math.max(0, (now() - started) * 1000)
end

function MeshRuntime.new()
  local runtime = {}

  local function uploadTableMesh(rows, indices)
    local n = #rows
    if n == 0 then return nil end
    local stages = { decodeMs = 0, uploadMs = 0 }
    local started = now()
    local ok, mesh = pcall(love.graphics.newMesh, Voxel3D.FORMAT, n,
                           "triangles", "static")
    addElapsed(stages, "uploadMs", started)
    if not ok or not mesh then return nil, stages end
    local i = 0
    while i < n do
      local count = math.min(UPLOAD_CHUNK, n - i)
      started = now()
      local slice = {}
      for j = 1, count do slice[j] = rows[i + j] end
      addElapsed(stages, "decodeMs", started)
      started = now()
      local okUp = pcall(mesh.setVertices, mesh, slice, i + 1)
      addElapsed(stages, "uploadMs", started)
      if not okUp then
        pcall(mesh.release, mesh)
        return nil, stages
      end
      i = i + count
      Budget.check()
    end
    if indices and #indices > 0 then
      started = now()
      local okMap = pcall(mesh.setVertexMap, mesh, indices)
      addElapsed(stages, "uploadMs", started)
      if not okMap then
        pcall(mesh.release, mesh)
        return nil, stages
      end
    end
    return mesh, stages
  end

  function runtime.upload(rows, indices)
    return uploadTableMesh(rows, indices)
  end

  local function uploadPackedMesh(data)
    local stages = { decodeMs = 0, uploadMs = 0 }
    local info = GeometryStream.inspectPayload(data.packed)
    if not info or info.n == 0
       or (data.n and data.n ~= info.n)
       or (data.m and data.m ~= info.m) then
      return nil, stages
    end

    -- v27 stores exactly the six float32 attributes expected by FORMAT and
    -- a zero-based uint32 vertex map. LÖVE 11.5 accepts Data for both, so the
    -- normal path avoids rebuilding thousands of Lua vertex/index tables.
    if love.data and love.data.newByteData then
      local started = now()
      local vertexBytes = GeometryStream.payloadVertexBytes(data.packed, info)
      local okData, vertexData = false, nil
      if vertexBytes then
        okData, vertexData = pcall(love.data.newByteData, vertexBytes)
      end
      addElapsed(stages, "decodeMs", started)
      if okData and vertexData then
        started = now()
        local okMesh, nativeMesh = pcall(
          love.graphics.newMesh, Voxel3D.FORMAT, vertexData,
          "triangles", "static")
        addElapsed(stages, "uploadMs", started)
        if okMesh and nativeMesh then
          local mapped = true
          if info.m > 0 then
            started = now()
            local indexBytes = GeometryStream.payloadIndexBytes(data.packed,
                                                                 info)
            local okIndex, indexData = false, nil
            if indexBytes then
              okIndex, indexData = pcall(love.data.newByteData, indexBytes)
            end
            addElapsed(stages, "decodeMs", started)
            if okIndex and indexData then
              started = now()
              mapped = pcall(nativeMesh.setVertexMap, nativeMesh, indexData,
                             "uint32", info.m)
              addElapsed(stages, "uploadMs", started)
            else
              mapped = false
            end
          end
          if mapped then return nativeMesh, stages end
          pcall(nativeMesh.release, nativeMesh)
        end
      end
    end

    local started = now()
    local ok, mesh = pcall(love.graphics.newMesh, Voxel3D.FORMAT, info.n,
                           "triangles", "static")
    addElapsed(stages, "uploadMs", started)
    if not ok or not mesh then return nil, stages end
    local first = 1
    while first <= info.n do
      local count = math.min(UPLOAD_CHUNK, info.n - first + 1)
      started = now()
      local rows = GeometryStream.payloadRows(data.packed, first, count, info)
      addElapsed(stages, "decodeMs", started)
      started = now()
      local okUp = rows and pcall(mesh.setVertices, mesh, rows, first)
      addElapsed(stages, "uploadMs", started)
      if not okUp then
        pcall(mesh.release, mesh)
        return nil, stages
      end
      first = first + count
      Budget.check()
    end
    if info.m > 0 then
      -- Compatibility fallback: try Data for large maps, then a Lua table.
      local uploaded = false
      if info.n > 65536 and love.data and love.data.newByteData then
        started = now()
        local raw = GeometryStream.payloadIndexBytes(data.packed, info)
        local okData, byteData = false, nil
        if raw then
          okData, byteData = pcall(love.data.newByteData, raw)
        end
        addElapsed(stages, "decodeMs", started)
        if okData and byteData then
          started = now()
          local okMap = pcall(mesh.setVertexMap, mesh, byteData, "uint32",
                              info.m)
          addElapsed(stages, "uploadMs", started)
          uploaded = okMap
        end
      end
      if not uploaded then
        started = now()
        local indices = GeometryStream.payloadIndices(data.packed, info)
        addElapsed(stages, "decodeMs", started)
        started = now()
        local okMap = indices and pcall(mesh.setVertexMap, mesh, indices)
        addElapsed(stages, "uploadMs", started)
        uploaded = okMap
      end
      if not uploaded then
        pcall(mesh.release, mesh)
        return nil, stages
      end
    end
    return mesh, stages
  end

  -- Accept both cache-load records ({ verts, indices }) and fresh-build
  -- records ({ buf, idx }). Both carry a flat six-float vertex stream.
  function runtime.fromData(data)
    if not data then return nil end
    if data.packed then return uploadPackedMesh(data) end
    local flat = data.verts or data.buf
    local indices = data.indices or data.idx
    if not flat or data.n == 0 then return nil end
    local stages = { decodeMs = 0, uploadMs = 0 }
    local started = now()
    local rows = {}
    for i = 1, data.n do
      local b = (i - 1) * 6 + 1
      rows[i] = { flat[b], flat[b + 1], flat[b + 2],
                  flat[b + 3], flat[b + 4], flat[b + 5] }
      if i % 4096 == 0 then Budget.check() end
    end
    addElapsed(stages, "decodeMs", started)
    local mesh, uploadStages = uploadTableMesh(rows, indices)
    stages.decodeMs = stages.decodeMs + ((uploadStages and uploadStages.decodeMs) or 0)
    stages.uploadMs = (uploadStages and uploadStages.uploadMs) or 0
    return mesh, stages
  end

  function runtime.releaseFigures(list)
    for _, figure in ipairs(type(list) == "table" and list or {}) do
      if figure.mesh and figure.mesh.release then
        pcall(figure.mesh.release, figure.mesh)
      end
    end
  end

  -- Decode the auxiliary terrain streams at one lifecycle boundary. The
  -- cache, sliced builder, and synchronous get path all consume the same
  -- { grass, flowers, figures } record; keeping conversion here prevents
  -- one path from forgetting a figure release or using a different slot
  -- shape.
  function runtime.fromAux(aux)
    if not aux then return nil end
    local stages = { decodeMs = 0, uploadMs = 0 }
    local function materialize(data)
      local mesh, meshStages = runtime.fromData(data)
      if meshStages then
        stages.decodeMs = stages.decodeMs + (meshStages.decodeMs or 0)
        stages.uploadMs = stages.uploadMs + (meshStages.uploadMs or 0)
      end
      return mesh
    end
    local figures = {}
    for _, fd in ipairs(aux.figures or {}) do
      local mesh = materialize(fd)
      if mesh then
        figures[#figures + 1] = { mesh = mesh, wx = fd.wx, wz = fd.wz,
                                  y = fd.y, w = fd.w }
      end
    end
    return {
      grass = materialize(aux.grass),
      flowers = materialize(aux.flowers),
      figures = figures,
    }, stages
  end

  function runtime.releaseAux(aux)
    if not aux then return end
    if aux.grass and aux.grass.release then pcall(aux.grass.release, aux.grass) end
    if aux.flowers and aux.flowers.release then
      pcall(aux.flowers.release, aux.flowers)
    end
    runtime.releaseFigures(aux.figures)
  end

  function runtime.swap(entry, slot, mesh)
    local old = entry[slot]
    if old and old ~= mesh and old.release then
      pcall(old.release, old)
    end
    entry[slot] = mesh
  end

  function runtime.swapAux(entry, aux)
    if not aux then return end
    runtime.swap(entry, "grass", aux.grass or false)
    runtime.swap(entry, "flowers", aux.flowers or false)
    runtime.releaseFigures(entry.figures)
    entry.figures = aux.figures or false
  end

  function runtime.waterSlot(slot)
    return slot .. "Water"
  end

  function runtime.releaseEntry(entry)
    for _, slot in ipairs({ "ring", "body", "ringWater", "bodyWater",
                            "grass", "flowers" }) do
      local mesh = entry[slot]
      if mesh and mesh.release then pcall(mesh.release, mesh) end
      entry[slot] = nil
    end
    runtime.releaseFigures(entry.figures)
    entry.figures = nil
    entry.stale = nil
    entry.noDisk = nil
  end

  -- Keep the GPU live set bounded to the current and previous neighbourhood.
  -- Generation bumps and Structure invalidation are supplied by the caller;
  -- this module owns the eviction decision and mesh release itself.
  function runtime.evict(ctx)
    local cache = ctx.cache
    local queue = ctx.queue
    local jobs = queue.list()
    local live = ctx.live
    local previous = ctx.previous
    local generations = ctx.generations
    local function protectedByPrebuild(mapId)
      for _, job in ipairs(jobs) do
        if job.id == mapId and job.prebuild then return true end
      end
      return false
    end

    for id, entry in pairs(cache) do
      if not protectedByPrebuild(id) and not live[id] and not previous[id] then
        runtime.releaseEntry(entry)
        cache[id] = nil
        generations[id] = (generations[id] or 0) + 1
        if ctx.onEvict then ctx.onEvict(id) end
      end
    end
    -- Previous completed meshes stay warm for a quick door round trip, but
    -- unfinished work for maps no longer visible must not compete with the
    -- new destination. A later crossing can requeue the missing slot.
    queue.removeIf(function(job)
      return not job.prebuild and not live[job.id]
    end, "cancelled")
    return live
  end

  return runtime
end

return MeshRuntime
