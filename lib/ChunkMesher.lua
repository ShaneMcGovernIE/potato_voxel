-- Voxel world mode: turn a map's tile layer into one static 3D mesh.
--
-- The scene description comes from Structures.lua, which -- 3dSen-style --
-- detects each connected drawn thing on the map and picks its model:
--
--   flat      ground / water / void: a single quad.
--   top art   ledges, roofs (profile-authored): a box with the art on its
--             TOP face; partial side bands crop the art (a 6px ledge face
--             is the bottom of the lip drawing).
--   volume    walls, buildings, tree lines: each column rises to the
--             structure's REAL drawn height (Structures measures it,
--             repeat-aware and region-consistent -- a 6-row house is 48px,
--             a 40-row border forest is rows of 16px trees). The south
--             face folds the full artwork upright, 8px band by band, band
--             k sampling the map row k tiles north; the top wears the
--             structure's top rows.
--   object    small props with a silhouette (plants, signs, lone trees):
--             per-pixel voxel prisms prebuilt by Structures, standing on
--             synthesized ground -- this mesher just emits their quads.
--             Round trees arrive as STAMPS (a shared hull template plus a
--             cell offset) and expand here, straight into the vertex
--             stream, so no map retains per-cell copies of its forests.
--
-- Side faces are never stretched: all sides are 8px bands with the art
-- tiled per band and cropped at partial bands.
--
-- Texturing samples the TILESET ATLAS, not a rendered copy of the map. The
-- atlas is 128x48; a map-space canvas covering the biggest routes would be
-- ~5 MB each with up to five live at once (connected maps), which is real
-- memory on the mobile targets. Sampling the atlas costs 24 KB, and costs
-- nothing in fidelity because TerrainAtlas hands back the same atlas
-- TileRenderer draws with -- including the fully recolored one RED++
-- bakes -- so terrain color comes through untouched.
--
-- BUILDS ARE ASYNCHRONOUS. A frame never blocks on meshing: VoxelScene
-- requests what it wants to draw, request() queues a build job, and
-- pump() -- called once a frame from the pipeline's update -- advances
-- the queue inside a few-millisecond budget (BuildBudget suspends the
-- job's coroutine mid-loop when the slice is spent). Until a mesh lands
-- the scene simply draws without it: the engine's flat path while the
-- current map has nothing, its body while the ring delta is still cooking,
-- neighbours popping in as they finish.
-- The synchronous get() remains for probes and tests.
--
-- Meshes are cached per map id and EVICTED down to the live set (current
-- map + connected neighbours) whenever that set changes -- setLive()
-- releases far maps' GPU meshes and their Structures analysis, which is
-- what used to grow the heap by gigabytes over a cross-region trek.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Assets = require("src.render.Assets")
local Structures = V.require("Structures")
local Voxel3D = V.require("Voxel3D")
local Budget = V.require("BuildBudget")
local MeshCache = V.require("MeshCache")
local MeshRuntime = V.require("MeshRuntime")
local MeshQueue = V.require("MeshQueue")
local GeometryBuilder = V.require("GeometryBuilder")
local GeometryStream = V.require("GeometryStream")
local CacheDecodePool = V.require("CacheDecodePool")
local Diagnostics = V.require("DiagnosticsBridge")

-- ffi is gone (sandbox) and this engine's love.data ByteData carries no
-- accessors, so the native float buffers are gone with them: the table
-- sink (plain 1-based Lua tables) is the one build path.

local ChunkMesher = {}
local Runtime = MeshRuntime.new()
local Queue = MeshQueue.new()

local cache = {}     -- map id -> { body = mesh|false, ring = ..., grass = ... }
local gen = {}       -- map id -> generation, bumped by invalidate/evict

local function slotFor(variant)
  if variant == "body" or variant == "ring" then return variant end
  return variant and "body" or "ring"
end

-- ------------------------------------------------------------ vertex sinks

-- A sink accepts quads (4 corners, 4 uv pairs, flat or per-corner shade)
-- and finishes into a drawable mesh. The TABLE sink reproduces the
-- historical pure-Lua output -- geometry() returns its arrays for the
-- headless suite, buffer() flattens them for the cache codecs -- and
-- finish() uploads the rows through uploadTableMesh below, so a fresh
-- build's upload lands in budgeted pieces like every other slice of the
-- job.
-- Slice a table upload across frames: the mesh is created with the full
-- vertex count, then vertices land in budgeted pieces. The vertex map must
-- be uploaded in one call: setVertexMap replaces the complete map and has no
-- ranged-update form. The old ffi sink
-- sliced exactly this way; a one-shot newMesh(rows) on a 500k-vertex
-- map is a 100-500ms hitch in pure Lua, which is what the sliced path
-- exists to avoid. Budget.check() is a no-op outside the build
-- coroutine, so the warp-covered synchronous cache-hit path still
-- uploads whole -- the fade covers that one by design. (Declared BEFORE
-- its users: this LuaJIT resolves a later chunk-local as a global --
-- the forward-local bug class.)
--
-- The FLAT-array form of setVertices is a trap on this engine's LOVE
-- 11.5 and must not come back: on a vertex-count mesh it counts table
-- ELEMENTS as VERTICES and rejects the call ("expected at most N, got
-- M"), while a pcall'd rejection here used to leave a zeroed mesh --
-- right count, all-zero vertices, terrain that renders as nothing.
-- ROWS are the only working form for a vertex-count mesh (measured on
-- the engine's own build). Every upload below CHECKS its pcall and
-- drops the mesh on failure, so a regression fails the job loudly
-- (logged, flat-2D fallback) instead of silently blacking the world.
local function newTableSink()
  local verts, indices, quads = {}, {}, 0
  return {
    push = function(c, uv, shade)
      local flat = type(shade) ~= "table"
      for i = 1, 4 do
        local cc, t = c[i], uv[i]
        verts[#verts + 1] = { cc[1], cc[2], cc[3], t[1], t[2],
                              flat and shade or shade[i] }
      end
      Voxel3D.pushQuad(indices, quads)
      quads = quads + 1
    end,
    results = function()
      return verts, indices, quads
    end,
    -- The flat streams the cache codecs consume: the rows the sink keeps
    -- (a table of 6-float rows) flattened into one 1-based float table,
    -- and the 1-based u32 vertex map as-is. The wire format conversion
    -- (0-based) happens inside the encoders.
    buffer = function()
      local flat = {}
      for i, row in ipairs(verts) do
        if (i % 4096) == 0 then Budget.check() end
        local b = (i - 1) * 6 + 1
        flat[b] = row[1]
        flat[b + 1] = row[2]
        flat[b + 2] = row[3]
        flat[b + 3] = row[4]
        flat[b + 4] = row[5]
        flat[b + 5] = row[6]
      end
      local imap = {}
      for i, v in ipairs(indices) do
        if (i % 65536) == 0 then Budget.check() end
        imap[i] = v
      end
      return flat, #verts, imap, #indices
    end,
    finish = function()
      return Runtime.upload(verts, indices)
    end,
  }
end

-- The sandbox build has one sink: plain Lua tables. ffi is banned and
-- this engine's love.data ByteData carries no accessors, so the native
-- float buffers are gone with them.
local function newSink()
  return newTableSink()
end

-- Worker sink. Quads go straight into bounded numeric writers. At the
-- worker boundary only packed chunk strings leave this module; no per-vertex
-- row tables, flat whole-map buffers, or nested index tables cross threads.
local function newStreamSink(kind)
  local writer = GeometryStream.Writer.new(kind or "terrain")
  local chunks = {}
  local vertices, indices = 0, 0

  local function flush()
    local chunk = writer:flush()
    if chunk then
      chunks[#chunks + 1] = chunk
      vertices = vertices + chunk.vertexCount
      indices = indices + chunk.indexCount
    end
  end

  return {
    push = function(c, uv, shade)
      if writer:full(4, 6) then flush() end
      local base = writer:vertexCount()
      local flat = type(shade) ~= "table"
      for i = 1, 4 do
        local cc, t = c[i], uv[i]
        writer:pushVertex(cc[1], cc[2], cc[3], t[1], t[2],
                          flat and shade or shade[i])
      end
      writer:pushIndex(base + 1)
      writer:pushIndex(base + 2)
      writer:pushIndex(base + 3)
      writer:pushIndex(base + 1)
      writer:pushIndex(base + 3)
      writer:pushIndex(base + 4)
    end,
    results = function()
      flush()
      return { chunks = chunks, n = vertices, m = indices }
    end,
  }
end

-- -------------------------------------------------------------- geometry

-- Emit the raw geometry for `map` into `sink`. `bodyOnly` skips the
-- border ring -- the shape the 2D path's drawMapOnly has always had: a
-- neighbour map contributes its body, and only the CURRENT map supplies
-- the ring around the view.
--
-- `masks` (full variant only) lists rectangles, in this map's world
-- pixels, where connected neighbour BODIES sit: ring geometry inside them
-- is suppressed. The 2D renderer never needed this because it painted
-- neighbour bodies OVER the ring; with a depth buffer the ring's standing
-- trees would rise straight through the neighbour's flat ground -- cross
-- into Route 1 and a wall of border trees sprouts over Pallet.
--
-- Kept free of any GPU call so it can be exercised headless -- the
-- geometry is the part with the interesting invariants, and a suite that
-- needed a real GL context to check them would never run in CI.
-- `waterSink`, when given, takes the WATER SURFACE quads instead of the
-- main sink -- the one class in this world that is drawn as its own pass
-- (see Water: a mirror cannot be drawn until what it reflects exists).
-- Nothing else moves: the quads are the same quads, emitted by the same
-- corner and uv arithmetic at the same recessed height, and the shoreline
-- faces around them still belong to the GROUND that exposes them.
--
-- Omitted, water stays in the terrain mesh exactly as it always did, which
-- GeometryBuilder emits the same sink protocol for every build path.

-- The raw geometry for `map`: (vertex list, triangle index list, quad
-- count). Synchronous and GPU-free -- the headless suite and the probes
-- exercise the invariants through this.
--
-- `split` lifts the water surface out, as it is lifted out for the
-- reflective pass, and appends that sink's own three values -- so the suite
-- can check the same separation the GPU path relies on without a GPU.
-- Without it the water is in the first list, which is what every existing
-- caller reads.
function ChunkMesher.geometry(map, bodyOnly, masks, split)
  local sink = newTableSink()
  local waterSink = split and newTableSink() or nil
  GeometryBuilder.emit(map, bodyOnly, masks, sink, waterSink)
  if not waterSink then return sink.results() end
  local v, i, n = sink.results()
  local wv, wi, wn = waterSink.results()
  return v, i, n, wv, wi, wn
end

-- Build the mesh for `map` synchronously. Returns nil when there is
-- nothing to draw or meshes are unavailable (headless).
--
-- `split` asks for the water surface as a SECOND mesh, returned after the
-- terrain one -- the shape the reflective pass needs (see Water). Without
-- it the water is inside the terrain mesh, which is the historical
-- contract and what every other caller still wants.
function ChunkMesher.build(map, bodyOnly, masks, split)
  local sink = newSink()
  local waterSink = split and newSink() or nil
  GeometryBuilder.emit(map, bodyOnly, masks, sink, waterSink)
  return sink.finish(), waterSink and waterSink.finish() or nil
end

local function quadsMesh(quads)
  if #quads == 0 then return nil end
  local verts, indices, n = {}, {}, 0
  for _, q in ipairs(quads) do
    for i = 1, 4 do
      local c = q[i]
      local uv = q.uv and q.uv[i] or { q.u, q.v }
      verts[#verts + 1] = { c[1], c[2], c[3], uv[1], uv[2], q.shade }
    end
    Voxel3D.pushQuad(indices, n)
    n = n + 1
  end
  return Voxel3D.newMesh(verts, indices)
end

-- The tall-grass rows as their own mesh: VoxelScene draws it AFTER the
-- characters so the southern row of a grass cell still overdraws a
-- walker's feet (characters stamp over terrain, Gen 1 style, so ordinary
-- terrain could never do this).
local function buildGrassMesh(map)
  return quadsMesh(Structures.forMap(map).grassQuads)
end

-- The flower billboards as their own mesh, for the same reason as the
-- grass one: it draws AFTER the characters WITH the same camera-ward
-- pull, so a flower south of a walker occludes their feet and one north
-- of them hides behind them. Baked into the terrain mesh they lost that
-- depth fight against the pulled character card whenever the player
-- stood among flowers. Unlike grass this mesh still CASTS shadows (the
-- sun pass draws it): a handful of flowers per meadow, not thousands of
-- tufts.
local function buildFlowerMesh(map)
  return quadsMesh(Structures.forMap(map).flowerQuads)
end

-- Authored FIGURES (a person drawn into furniture) as one mesh each, in
-- the card's own local space -- because each one is placed by its own
-- matrix at draw time, leaned back by the camera pitch exactly like a
-- character card (VoxelScene). A figure baked into the terrain mesh could
-- not lean, and a shared mesh could not carry per-figure placement.
--
-- A list, not a mesh: `{ mesh, wx, wz, y, w }` per figure. Maps have one
-- or none, so the loop that draws them is shorter than the terrain's.
-- `w` is the card's own width in its local space (its quads start at
-- x = 0), measured here because the first-person pass yaws a card about
-- its middle -- a card yawed about its left edge swings off its seat.
local function buildFigureMeshes(map)
  local out = {}
  for _, f in ipairs(Structures.forMap(map).figures or {}) do
    local mesh = quadsMesh(f.quads)
    if mesh then
      local w = 0
      for _, q in ipairs(f.quads) do
        for c = 1, 4 do
          local x = q[c] and q[c][1]
          if x and x > w then w = x end
        end
      end
      out[#out + 1] = { mesh = mesh, wx = f.wx, wz = f.wz, y = f.y, w = w }
    end
  end
  return out
end

-- Figure lists hold their meshes one level down, so the generic slot
-- release cannot reach them.
local releaseFigures = Runtime.releaseFigures
local swapSlot = Runtime.swap
local fromAux = Runtime.fromAux
local releaseAux = Runtime.releaseAux
local swapAux = Runtime.swapAux

-- ------------------------------------------------------------- the cache

-- True once any map has created a mesh entry. The Assets boot-handoff
-- guard below uses it to tell "engine still booting" from "real asset
-- change" on Switch (see the guard for why that platform needs it).
local builtAnything = false

local function entry(id)
  local c = cache[id]
  if not c then
    c = {}
    cache[id] = c
    builtAnything = true
  end
  return c
end

-- The water surface that came out of a terrain slot's own build. Kept
-- beside it rather than in a slot of its own because the two are ONE
-- answer: each geometry slot owns its matching water surface.
local waterSlot = Runtime.waterSlot
local releaseEntry = Runtime.releaseEntry

-- ---------------------------------------------------------- async builds

local clock = (love and love.timer and love.timer.getTime) or os.clock

local function mergeStages(target, stages)
  if not stages then return target end
  target = target or {}
  for _, key in ipairs({ "queueMs", "readMs", "decompressMs",
                          "decodeMs", "uploadMs" }) do
    target[key] = (target[key] or 0) + (stages[key] or 0)
  end
  return target
end

local function traceStages(label, id, slot, stages, totalMs)
  stages = stages or {}
  Diagnostics.trace(
    "%s %s/%s queue=%.1fms read=%.1fms decompress=%.1fms "
      .. "decode=%.1fms upload=%.1fms total=%.1fms",
    label, tostring(id), tostring(slot), stages.queueMs or 0,
    stages.readMs or 0, stages.decompressMs or 0, stages.decodeMs or 0,
    stages.uploadMs or 0, totalMs or 0)
end

local function finishJob(job, ok, err)
  local key = Queue.key(job.id, job.slot)
  local jobMs = nil
  if job.queuedAt and love and love.timer and love.timer.getTime then
    jobMs = math.floor((love.timer.getTime() - job.queuedAt) * 1000 + 0.5)
  end
  if not ok then
    Diagnostics.count("jobFails")
    Diagnostics.note("mesh job failed %s: %s", key, tostring(err))
  else
    Diagnostics.count("jobs")
    Diagnostics.note("mesh done %s (%dms)", key, jobMs or 0)
  end
  traceStages("mesh stages", job.id, job.slot, job.stages, jobMs or 0)
  -- Per-job build health for the status snapshot: slices taken, the
  -- longest single resume (the freeze evidence), and how many resumes
  -- blew their budget.
  Diagnostics.buildDone(job.id, job.slot, job.slices or 0,
                        job.maxGapMs or 0, job.overshoots or 0)
  Queue.finish(job, ok)
  if not ok then
    -- name the reason: in a real session a lost build is a black map
    print("[warn] voxel mesh build failed for " .. tostring(job.id)
          .. ": " .. tostring(err))
    if (gen[job.id] or 0) == job.gen then
      entry(job.id)[job.slot] = false
    end
  end
end

-- Upload a serialized vertex stream (the MeshCache load records) into a
-- fresh love mesh. Table-based: verts and indices are plain 1-based Lua
-- tables -- the same shape the table sink's fresh builds produce -- so
-- both halves share Voxel3D.newMesh. Returns nil for an empty stream or
-- a failed upload. Every record is INDEXED since brick.13 (terrain/water
-- since brick.11, aux since 12): 4 verts per quad plus a u32 vertex map.
local meshFromData = Runtime.fromData

-- Flatten the map's grass/flower quads and authored figures into the
-- INDEXED vertex streams the disk cache stores, in one pass each. Only
-- reached on a fresh build -- a cache hit never needs Structures'
-- analysis. Records carry { n, buf, m, idx } to match the indexed
-- payload format (brick.13).
local function flattenAux(map)
  local S = Structures.forMap(map)
  local function flatten(quads)
    if #quads == 0 then return nil end
    local buf = {}
    local idx = {}
    local k, m = MeshCache.flattenQuads(quads, buf, idx)
    return { n = k / 6, buf = buf, m = m, idx = idx }
  end
  local grass = flatten(S.grassQuads)
  local flowers = flatten(S.flowerQuads)
  local figures = {}
  for _, f in ipairs(S.figures or {}) do
    local fq = flatten(f.quads)
    if fq then
      local w = 0
      for _, q in ipairs(f.quads) do
        for c = 1, 4 do
          local x = q[c] and q[c][1]
          if x and x > w then w = x end
        end
      end
      figures[#figures + 1] = { n = fq.n, buf = fq.buf, m = fq.m,
                                 idx = fq.idx,
                                 wx = f.wx, wz = f.wz, y = f.y, w = w }
    end
  end
  return { grass = grass, flowers = flowers, figures = figures }
end

-- Fill the aux slots (grass/flowers/figures) for a job, from the disk
-- cache when it has them, else by building fresh. Returns true when the
-- slots are filled and the job may keep running, false when the caller
-- should stop (a generation bump cancelled the work mid-build).
local function fillAux(job)
  local map = job.map
  local c = entry(job.id)
  local current = (gen[job.id] or 0) == job.gen

  if MeshCache.available() then
    local aux, cacheStages = MeshCache.loadAuxPacked(map, job.slot)
    if aux then
      local auxMeshes, meshStages = fromAux(aux)
      job.stages = mergeStages(job.stages, cacheStages)
      job.stages = mergeStages(job.stages, meshStages)
      if not current then
        releaseAux(auxMeshes)
        return false
      end
      swapAux(c, auxMeshes)
      if c.stale then c.stale.aux = nil end
      return true
    end
  end

  -- fresh build: flatten to the indexed stream once and build from it
  -- (and save it)
  local grass, flowers, figures
  if MeshCache.available() then
    local okFlat, flat = pcall(flattenAux, map)
    if okFlat and flat then
      MeshCache.saveAux(map, job.slot, flat, true)
      local auxMeshes, meshStages = fromAux(flat)
      job.stages = mergeStages(job.stages, meshStages)
      grass, flowers, figures = auxMeshes.grass, auxMeshes.flowers,
                                auxMeshes.figures
    end
  else
    local okG, g = pcall(buildGrassMesh, map)
    local okF, fl = pcall(buildFlowerMesh, map)
    local okX, fig = pcall(buildFigureMeshes, map)
    grass, flowers, figures = (okG and g) or false, (okF and fl) or false,
                              (okX and fig) or false
  end
  if not current then
    releaseAux({ grass = grass, flowers = flowers, figures = figures })
    return false
  end
  swapAux(c, { grass = grass, flowers = flowers, figures = figures })
  if c.stale then c.stale.aux = nil end
  return true
end

-- A build only lands if the map's generation still matches the one the
-- job was queued under -- invalidate/evict bump it to cancel in-flight
-- work whose inputs went stale.
local function runJob(job)
  job.stages = job.stages or {}
  if job.queuedAt then
    job.stages.queueMs = math.max(0, (clock() - job.queuedAt) * 1000)
  end
  local c = entry(job.id)
  job.phase = "load"
  local map = job.map
  if not map and job.loader then map = job.loader() end
  if not map then
    error("mesh build has no map for " .. tostring(job.id), 0)
  end
  job.map = map
  if c.grass == nil or c.flowers == nil or c.figures == nil
     or (c.stale and c.stale.aux) then
    job.phase = "aux"
    if not fillAux(job) then return end
  end

  -- the terrain slot: serve it from the disk cache when the pair is
  -- there, else build it fresh (and write it back). A cache hit skips
  -- Structures' analysis AND geometry generation -- the whole point of
  -- precompiled meshes -- leaving only the same sliced upload a fresh
  -- build's finish() would have done.
  job.phase = "cache-load"
  local current = (gen[job.id] or 0) == job.gen
  if MeshCache.available() then
    local tdata, wdata, cacheStages =
      MeshCache.loadTerrainPacked(map, job.slot)
    job.stages = mergeStages(job.stages, cacheStages)
    if tdata and wdata then
      local mesh, meshStages = meshFromData(tdata)
      local water, waterStages = meshFromData(wdata)
      job.stages = mergeStages(job.stages, meshStages)
      job.stages = mergeStages(job.stages, waterStages)
      if not current then
        if mesh and mesh.release then pcall(mesh.release, mesh) end
        if water and water.release then pcall(water.release, water) end
        return
      end
      swapSlot(c, job.slot, mesh or false)
      swapSlot(c, waterSlot(job.slot), water or false)
      if c.stale then
        c.stale[job.slot] = nil
        if not (c.stale.ring or c.stale.body or c.stale.aux) then
          c.stale = nil
        end
      end
      return
    end
  end
  job.phase = "geometry"
  local sink = newSink()
  local waterSink = newSink()
  GeometryBuilder.emit(map, job.slot, job.masks, sink, waterSink)
  local mesh, meshStages = sink.finish()
  local water, waterStages = waterSink.finish()
  job.stages = mergeStages(job.stages, meshStages)
  job.stages = mergeStages(job.stages, waterStages)
  if MeshCache.available() then
    job.phase = "save"
    local buf, n, idx, m = sink.buffer()
    MeshCache.saveTerrain(map, job.slot, buf, n, idx, m)
    local wbuf, wn, widx, wm = waterSink.buffer()
    MeshCache.saveWater(map, job.slot, wbuf, wn, widx, wm)
  end
  job.phase = "mesh"
  if (gen[job.id] or 0) ~= job.gen then
    if mesh and mesh.release then pcall(mesh.release, mesh) end
    if water and water.release then pcall(water.release, water) end
    return
  end
  swapSlot(c, job.slot, mesh or false)
  swapSlot(c, waterSlot(job.slot), water or false)
  if c.stale then
    c.stale[job.slot] = nil
    if not (c.stale.ring or c.stale.body or c.stale.aux) then
      c.stale = nil
    end
  end
end

-- Pure geometry for the threaded prebuilder (docs/threaded-geometry-design.md):
-- Structures analysis + the terrain/water sink streams + the flattened aux
-- records -- with NO graphics, storage or runtime cache entry. Runs on a
-- love.thread worker; the main thread turns the returned buffers into cache
-- files exactly like the serial path's save phase (saveTerrain/saveWater/
-- saveAux) and never uploads a mesh it does not draw.
local function appendStream(out, stream)
  for _, chunk in ipairs(stream.chunks or {}) do
    local decoded, err = GeometryStream.decode(chunk)
    if not decoded then error("geometry chunk decode failed: " .. tostring(err), 0) end
    local vertexOffset = out.n
    for i = 1, decoded.n * 6 do
      out.buf[vertexOffset * 6 + i] = decoded.buf[i]
    end
    for i = 1, decoded.m do
      out.idx[out.m + i] = decoded.idx[i] + vertexOffset
    end
    out.n = out.n + decoded.n
    out.m = out.m + decoded.m
  end
end

local function materializeStream(stream)
  local out = { buf = {}, n = 0, idx = {}, m = 0 }
  appendStream(out, stream)
  return out
end

local function geometryChunkStreams(map, bodyOnly, masks)
  local sink = newStreamSink()
  local waterSink = newStreamSink("water")
  GeometryBuilder.emit(map, bodyOnly, masks, sink, waterSink)
  return {
    terrain = sink.results(),
    water = waterSink.results(),
  }
end

local function geometryStreams(map, bodyOnly, masks)
  local chunks = geometryChunkStreams(map, bodyOnly, masks)
  return {
    terrain = materializeStream(chunks.terrain),
    water = materializeStream(chunks.water),
  }
end

function ChunkMesher.buildGeometryChunkData(map, bodyOnly, masks)
  local data = geometryChunkStreams(map, bodyOnly, masks)
  local okFlat, flat = pcall(flattenAux, map)
  data.aux = okFlat and flat or nil
  return data
end

function ChunkMesher.buildGeometryData(map, bodyOnly, masks)
  local data = geometryStreams(map, bodyOnly, masks)
  local okFlat, flat = pcall(flattenAux, map)
  data.aux = okFlat and flat or nil
  return data
end

-- Body and ring are disjoint views of the same map analysis. Drawing both is
-- byte-for-byte equivalent in counts to the old full mesh, without storing
-- or uploading the body twice.
function ChunkMesher.buildGeometryPairData(map, masks)
  local body = geometryStreams(map, true, masks)
  local ring = geometryStreams(map, "ring", masks)
  local okFlat, flat = pcall(flattenAux, map)
  return { body = body, ring = ring, aux = okFlat and flat or nil }
end

function ChunkMesher.buildGeometryPairChunkData(map, masks)
  local body = geometryChunkStreams(map, true, masks)
  local ring = geometryChunkStreams(map, "ring", masks)
  local okFlat, flat = pcall(flattenAux, map)
  return { body = body, ring = ring, aux = okFlat and flat or nil }
end

-- Worker-only analysis release. Do not call ChunkMesher.release here: that
-- also mutates main-thread mesh queues and cache state.
function ChunkMesher.releaseAnalysis(mapId)
  return Structures.release and Structures.release(mapId) or false
end

-- Queue a build unless the slot is already cached or queued. Returns the
-- cached mesh when there is one (false-cached misses return nil).
-- `urgent` marks the current map's meshes: pump() gives those a bigger
-- slice and runs them before neighbour jobs. A slot refresh() marked
-- stale queues its rebuild AND keeps handing back the old mesh, so a
-- one-block edit never drops the scene to the flat 2D path while the
-- replacement cooks.
-- `force` is used by the disk-cache prebuilder. Runtime cache state is not
-- evidence that the serialized terrain/aux files exist (or are current), so
-- a map visited earlier this session must still be allowed to run the job.
function ChunkMesher.request(map, bodyOnly, masks, urgent, force, priority)
  local slot = slotFor(bodyOnly)
  -- Create the entry HERE, at request time -- not in runJob when the
  -- build starts. The entry is the "seen this session" marker the
  -- crossing rule keys on: a map requested as a neighbour (its body
  -- job queued, maybe not started) must already be `seen()` by the
  -- time the player crosses into it, or the ring build would wrongly
  -- go urgent.
  local c = entry(map.id)
  -- Cache hydration always runs through the cooperative queue. A previous
  -- direct cache fast path decoded terrain, water, and aux meshes on the
  -- map-entry frame. Large Android maps therefore froze for up to 1.27s
  -- before Voxel.loading could cover the transition. runJob keeps the same
  -- cache-hit path but yields between bounded decode and upload slices.
  if force then
    -- Force the job to validate/load the disk payloads or rebuild them.
    -- Mark aux too: a populated in-memory slot can otherwise skip
    -- fillAux(), leaving the prebuilder reporting success with no aux file.
    c.stale = c.stale or {}
    c.stale.aux = true
    c.stale[slot] = true
  end
  local stale = c.stale and (c.stale[slot] or c.stale.aux)
  if c[slot] ~= nil and not force and not stale then return c[slot] or nil end
  local job = Queue.find(map.id, slot)
  if not job then
    job = { id = map.id, map = map, slot = slot, masks = masks,
            urgent = urgent or false, prebuild = force or false,
            priority = priority or (urgent and 1 or 0),
            gen = gen[map.id] or 0,
            queuedAt = love and love.timer and love.timer.getTime
                       and love.timer.getTime() or nil }
    Queue.enqueue(job, force)
  else
    if urgent then job.urgent = true end
    Queue.promote(map.id, slot, priority or (urgent and 1 or 0))
    if force then job.prebuild = true end
    if force then Queue.enqueue(job, true) end
  end
  return (c and c[slot]) or nil
end

-- Queue a prebuilder job whose map object is produced inside the pumped
-- coroutine by `loader` (the engine's MapLoader.load is too slow to run
-- on the update tick outside the pump, and inside the coroutine it is at
-- least measured and warned about like every other slice overshoot).
-- Every other field behaves exactly like request(): same queue, same
-- force/prebuild semantics, same completion record.
function ChunkMesher.requestMapId(mapId, bodyOnly, masks, urgent, force, loader)
  local slot = slotFor(bodyOnly)
  local c = entry(mapId)
  if force then
    c.stale = c.stale or {}
    c.stale.aux = true
    c.stale[slot] = true
  end
  local job = Queue.find(mapId, slot)
  if not job then
    job = { id = mapId, loader = loader, slot = slot, masks = masks,
            urgent = urgent or false, prebuild = force or false,
            gen = gen[mapId] or 0,
            queuedAt = love and love.timer and love.timer.getTime
                       and love.timer.getTime() or nil }
    Queue.enqueue(job, force)
  else
    if urgent then job.urgent = true end
    if force then job.prebuild = true end
    if force then Queue.enqueue(job, true) end
  end
  return (c and c[slot]) or nil
end

function ChunkMesher.pending()
  return Queue.pending()
end

-- A precise queue probe used by cooperative tooling. It does not inspect or
-- retain the mesh; it only answers whether a slot is still in flight.
function ChunkMesher.jobPending(mapId, bodyOnly)
  return Queue.jobPending(mapId, slotFor(bodyOnly))
end

function ChunkMesher.jobStatus(mapId, bodyOnly)
  return Queue.status(mapId, slotFor(bodyOnly))
end

-- Release a completed prebuild map immediately. Unlike invalidate(), this
-- intentionally leaves disk cache files intact and only drops runtime GPU/
-- Structures state.
function ChunkMesher.release(mapId)
  local c = cache[mapId]
  local had = c ~= nil
  if c then releaseEntry(c); cache[mapId] = nil end
  -- Cancellation is generation-based, but also remove queued jobs so a
  -- cancelled prebuild cannot keep a map/Structures graph alive in a closure.
  gen[mapId] = (gen[mapId] or 0) + 1
  Queue.removeIf(function(job) return job.id == mapId end, "cancelled")
  CacheDecodePool.cancel(mapId)
  Structures.invalidate(mapId)
  return had
end

-- Advance queued builds inside a per-frame time budget. Urgent jobs (the
-- current map) come first and get the larger slice -- the first voxel
-- frame after a toggle is worth more milliseconds than a neighbour
-- popping in one frame later. `covered` says the world pass is hidden
-- this frame (a warp's fade, a menu): nothing visible can hitch, so the
-- slice opens up and a door fade swallows most of a destination build.
-- Per-frame build budgets, exposed so the Brick build (BrickProfile) can
-- halve them. A smaller slice spreads each chunk's carve-in over more
-- frames but never spikes one; the parent build's 12ms/5ms/30ms are tuned
-- for desktop GPUs.
ChunkMesher.URGENT_SLICE = 0.012
ChunkMesher.IDLE_SLICE = 0.005
-- Nothing visible can hitch during covered phases (menus, warps, the
-- title screen, the loading canvas), so the prebuild takes as much as
-- the frame can give: 50ms per frame is still under a 60fps budget and
-- cuts cold-fill wall time roughly 1.6x versus the 30ms slice.
ChunkMesher.COVERED_SLICE = 0.050

function ChunkMesher.pump(covered)
  Queue.pump({
    clock = clock,
    slice = function(pick)
      return covered and ChunkMesher.COVERED_SLICE
        or (pick.urgent and ChunkMesher.URGENT_SLICE
            or ChunkMesher.IDLE_SLICE)
    end,
    step = function(pick, deadline)
      if not pick.co then
        pick.co = coroutine.create(runJob)
      end
      local t0 = clock()
      local slice = covered and ChunkMesher.COVERED_SLICE
        or (pick.urgent and ChunkMesher.URGENT_SLICE
            or ChunkMesher.IDLE_SLICE)
      Budget.begin(pick.co, deadline - clock())
      local ok, err = coroutine.resume(pick.co, pick)
      Budget.finish()
      -- The cooperative budget is the contract: a resume that runs far past
      -- its slice froze the frames it landed on (field logs: 590-1083ms on a
      -- Deck, a 20.3s frame on an Adreno 830). Name the job and its phase
      -- once per phase so a support log says exactly which step to slice.
      local elapsedMs = (clock() - t0) * 1000
      pick.slices = (pick.slices or 0) + 1
      if elapsedMs > (pick.maxGapMs or 0) then pick.maxGapMs = elapsedMs end
      local overshootThreshold = slice * 1000 * 4
      if elapsedMs > overshootThreshold then
        pick.overshoots = (pick.overshoots or 0) + 1
        if pick.warnedPhase ~= pick.phase then
          pick.warnedPhase = pick.phase
          Diagnostics.warn("mesh build overshot its slice: %s/%s in %s "
                           .. "(%.0fms resume vs %.0fms slice)",
                           tostring(pick.id), tostring(pick.slot),
                           tostring(pick.phase), elapsedMs,
                           overshootThreshold)
        end
      end
      if not ok then
        return "failed", err
      elseif coroutine.status(pick.co) == "dead" then
        return "complete"
      else
        return "yield"
      end
    end,
    complete = finishJob,
  })
end

-- Meshes for `map`, built SYNCHRONOUSLY on first use -- the historical
-- contract, kept for probes and any direct caller. `false` is cached for
-- a map whose mesh could not be built so a headless run does not retry
-- every frame. `masks` (the ring variant's neighbour-body rects) is
-- static per map id -- a map's connections never change -- so it caches
-- like everything else.
function ChunkMesher.get(map, bodyOnly, masks)
  local slot = slotFor(bodyOnly)
  local c = entry(map.id)
  if c.grass == nil or c.flowers == nil or (c.stale and c.stale.aux) then
    if MeshCache.available() then
      local aux = MeshCache.loadAuxPacked(map, slot)
      if aux then
        swapAux(c, fromAux(aux))
        if c.stale then c.stale.aux = nil end
      else
        local okG, grass = pcall(buildGrassMesh, map)
        local okF, flowers = pcall(buildFlowerMesh, map)
        swapSlot(c, "grass", (okG and grass) or false)
        swapSlot(c, "flowers", (okF and flowers) or false)
        if c.stale then c.stale.aux = nil end
      end
    else
      local okG, grass = pcall(buildGrassMesh, map)
      local okF, flowers = pcall(buildFlowerMesh, map)
      swapSlot(c, "grass", (okG and grass) or false)
      swapSlot(c, "flowers", (okF and flowers) or false)
      if c.stale then c.stale.aux = nil end
    end
  end
  if c[slot] == nil or (c.stale and c.stale[slot]) then
    if MeshCache.available() then
      local tdata, wdata = MeshCache.loadTerrainPacked(map, slot)
      if tdata and wdata then
        local mesh = meshFromData(tdata)
        local water = meshFromData(wdata)
        swapSlot(c, slot, mesh or false)
        swapSlot(c, waterSlot(slot), water or false)
        if c.stale then c.stale[slot] = nil end
        if c.stale and not (c.stale.ring or c.stale.body or c.stale.aux) then
          c.stale = nil
        end
        return c[slot] or nil
      end
    end
    local ok, mesh, water = pcall(ChunkMesher.build, map, bodyOnly, masks,
                                  true)
    if not ok then
      print("[warn] voxel mesh build failed for " .. tostring(map.id)
            .. ": " .. tostring(mesh))
    end
    swapSlot(c, slot, (ok and mesh) or false)
    swapSlot(c, waterSlot(slot), (ok and water) or false)
    if c.stale then
      c.stale[slot] = nil
      if not (c.stale.ring or c.stale.body or c.stale.aux) then
        c.stale = nil
      end
    end
    local job = Queue.find(map.id, slot)
    if job then finishJob(job, true) end
  end
  return c[slot] or nil
end

-- The cached mesh, or nil -- never builds. The async path's read side.
function ChunkMesher.peek(map, bodyOnly)
  local c = cache[map.id]
  local mesh = c and c[slotFor(bodyOnly)]
  return mesh or nil
end

-- A slot's terrain mesh AND the water surface lifted out of it, as one
-- answer. Never builds, like peek.
--
-- Both or neither, always from the SAME slot: the water was cut out of that
-- exact geometry, so body and ring surfaces cannot be accidentally crossed.
function ChunkMesher.pair(map, bodyOnly)
  local c = cache[map.id]
  if not c then return nil, nil end
  local slot = slotFor(bodyOnly)
  return c[slot] or nil, c[waterSlot(slot)] or nil
end

-- Has this map been requested at all this session? The crossing rule:
-- a destination that was ever a neighbour (its cache entry was created
-- when prefetch asked for its body) already has the scene-gating geometry.
-- Only its smaller ring delta may remain. Unlike
-- pair(), this is RACE-FREE: it is true from the first neighbour
-- request, not only once the body mesh has finished building.
function ChunkMesher.seen(mapId)
  return cache[mapId] ~= nil
end

function ChunkMesher.grass(map)
  local c = cache[map.id]
  return c and c.grass or nil
end

function ChunkMesher.flowers(map)
  local c = cache[map.id]
  return c and c.flowers or nil
end

-- Authored figures as `{ mesh, wx, wz, y, w }` records -- each placed by
-- its own leaning matrix at draw time, so they cannot share one mesh.
function ChunkMesher.figures(map)
  local c = cache[map.id]
  local list = c and c.figures
  return (type(list) == "table") and list or nil
end

-- Rebuild a map's meshes IN PLACE: the stale meshes keep drawing while
-- replacements cook, and each slot swaps as its build lands. This is
-- the block-edit path (a cut tree, a door stamp) -- invalidate() drops
-- the mesh outright, and until the async rebuild landed the scene fell
-- to the flat 2D path, a whole-world blink for a one-block edit.
function ChunkMesher.refresh(mapId)
  if not mapId then return ChunkMesher.invalidate() end
  local c = cache[mapId]
  -- nothing drawable cached: the plain drop costs nothing visible
  if not (c and (c.ring or c.body)) then
    return ChunkMesher.invalidate(mapId)
  end
  MeshCache.invalidate(mapId)
  CacheDecodePool.cancel(mapId)
  Structures.invalidate(mapId)
  gen[mapId] = (gen[mapId] or 0) + 1
  Queue.removeIf(function(job) return job.id == mapId end)
  -- false-cached slots count as stale too: a retry after a failed build
  -- is exactly a rebuild
  c.stale = { aux = true,
              ring = (c.ring ~= nil) or nil,
              body = (c.body ~= nil) or nil }
end

-- Evict everything outside `live` (a set of map ids): far maps' meshes
-- are released -- GPU buffer and LOVE's CPU copy both -- and their
-- Structures analysis dropped. The live set is the current map plus its
-- rendered neighbours, so memory stays bounded by what is on or near the
-- screen instead of growing with every area ever visited.
--
-- The PREVIOUS live set is retained too: warping into a building
-- collapses the set to one small interior, and evicting the town at the
-- door means rebuilding the whole neighbourhood on the way out -- a
-- flat-world flash after every house. One set of history makes the
-- round trip free while staying bounded at two neighbourhoods.
local prevLive = {}

function ChunkMesher.setLive(live)
  -- Route transitions change which queued job is the destination. Clear the
  -- old runtime ranking before VoxelScene re-promotes the new current map and
  -- its neighbours; prebuild work keeps its independent scheduling state.
  Queue.resetPriorities(function(job) return not job.prebuild end)
  prevLive = Runtime.evict({
    cache = cache,
    queue = Queue,
    live = live,
    previous = prevLive,
    generations = gen,
    onEvict = function(id)
      CacheDecodePool.cancel(id)
      Structures.invalidate(id)
    end,
  })
end

-- Drop one map's mesh (Cut swapped a block) or all of them (hot reload).
-- Structures' analysis is derived from the same block layer, so it drops
-- in the same breath; in-flight builds of the map are cancelled through
-- the generation counter.
function ChunkMesher.invalidate(mapId)
  MeshCache.invalidate(mapId)
  CacheDecodePool.cancel(mapId)
  Structures.invalidate(mapId)
  if mapId then
    local c = cache[mapId]
    if c then releaseEntry(c) end
    cache[mapId] = nil
    gen[mapId] = (gen[mapId] or 0) + 1
  else
    for _, c in pairs(cache) do releaseEntry(c) end
    cache = {}
    for id in pairs(gen) do gen[id] = gen[id] + 1 end
  end
  Queue.removeIf(function(job)
    return mapId == nil or job.id == mapId
  end, "cancelled")
end

-- The engine fires every registered invalidator at boot too: the mod
-- loader's Assets.installLoader -> Assets.invalidate handoff runs on
-- every launch, and on desktop it has been observed to fire TWICE (the
-- Steam Deck logs: "cache invalidate ALL" twice, 0.2s apart, 3 seconds
-- before the first frame sample). Those calls are an asset-search-path
-- handoff, not a geometry change -- no map has loaded yet -- and a full
-- MeshCache.invalidate() there would drop the manifest and force a cold
-- 444-job prebuild on every boot (observed: 162s rebuilds on Linux).
-- The runtime mesh cache is empty at that point, and the disk cache is
-- fingerprint-protected, so boot-time handoffs are skipped on EVERY
-- platform until the first real mesh entry exists -- a boot-time
-- handoff is never that. The moment any mesh work starts the guard
-- releases, so genuine invalidations (dev hot reload, a real asset
-- swap) still land.
local bootAssetsHandedOff = false
Assets.register(function()
  if not bootAssetsHandedOff then
    bootAssetsHandedOff = true
    return
  end
  if not builtAnything then return end
  ChunkMesher.invalidate()
end)

-- Test seam: the boot-handoff guard keys on the session-level
-- builtAnything flag; the headless suite replays boot scenarios in one
-- process and needs to re-arm it between blocks.
function ChunkMesher._resetBootHandoffForTests()
  builtAnything = false
end

return ChunkMesher
