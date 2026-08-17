-- GPU-facing ownership for ChunkMesher's cached mesh slots.
--
-- Geometry and queue policy stay outside this module. This boundary owns
-- only the conversion from serialized vertex streams to LOVE meshes and the
-- release/swap rules for the mesh objects kept in a cache entry.
local V = ...

local Voxel3D = V.require("Voxel3D")
local Budget = V.require("BuildBudget")

local MeshRuntime = {}
local UPLOAD_CHUNK = 8192

function MeshRuntime.new()
  local runtime = {}

  local function uploadTableMesh(rows, indices)
    local n = #rows
    if n == 0 then return nil end
    local ok, mesh = pcall(love.graphics.newMesh, Voxel3D.FORMAT, n,
                           "triangles", "static")
    if not ok or not mesh then return nil end
    local i = 0
    while i < n do
      local count = math.min(UPLOAD_CHUNK, n - i)
      local slice = {}
      for j = 1, count do slice[j] = rows[i + j] end
      local okUp = pcall(mesh.setVertices, mesh, slice, i + 1)
      if not okUp then
        pcall(mesh.release, mesh)
        return nil
      end
      i = i + count
      Budget.check()
    end
    if indices and #indices > 0 then
      local okMap = pcall(mesh.setVertexMap, mesh, indices)
      if not okMap then
        pcall(mesh.release, mesh)
        return nil
      end
    end
    return mesh
  end

  function runtime.upload(rows, indices)
    return uploadTableMesh(rows, indices)
  end

  -- Accept both cache-load records ({ verts, indices }) and fresh-build
  -- records ({ buf, idx }). Both carry a flat six-float vertex stream.
  function runtime.fromData(data)
    if not data then return nil end
    local flat = data.verts or data.buf
    local indices = data.indices or data.idx
    if not flat or data.n == 0 then return nil end
    local rows = {}
    for i = 1, data.n do
      local b = (i - 1) * 6 + 1
      rows[i] = { flat[b], flat[b + 1], flat[b + 2],
                  flat[b + 3], flat[b + 4], flat[b + 5] }
      if i % 4096 == 0 then Budget.check() end
    end
    return uploadTableMesh(rows, indices)
  end

  function runtime.releaseFigures(list)
    for _, figure in ipairs(type(list) == "table" and list or {}) do
      if figure.mesh and figure.mesh.release then
        pcall(figure.mesh.release, figure.mesh)
      end
    end
  end

  function runtime.swap(entry, slot, mesh)
    local old = entry[slot]
    if old and old ~= mesh and old.release then
      pcall(old.release, old)
    end
    entry[slot] = mesh
  end

  function runtime.waterSlot(slot)
    return slot .. "Water"
  end

  function runtime.releaseEntry(entry)
    for _, slot in ipairs({ "full", "body", "fullWater", "bodyWater",
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
    queue.removeIf(function(job)
      return not job.prebuild and not live[job.id] and not previous[job.id]
    end, "cancelled")
    return live
  end

  return runtime
end

return MeshRuntime
