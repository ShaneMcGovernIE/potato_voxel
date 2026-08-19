-- Threaded geometry workers for the prebuilder (docs/threaded-geometry-design.md).
--
-- Runs the pure CPU phase of cache jobs (Structures analysis, geometry
-- streams, aux flattening) on love.thread workers so a cold fill uses more
-- than one core. Everything that touches love.graphics or the storage
-- facade stays on the main thread; the pool only ever exchanges data
-- tables (plus one shared ImageData) through channels.
--
-- Falls back to the serial pump automatically:
--   * no love.thread (headless tests, an engine build without it),
--   * an unsupported low-end class (Switch, web, the brick profile),
--   * a failed spawn or a worker that dies,
--   * a worker whose geometry version no longer matches (hot reload).
local V = ...
local WorkerPool = {}

local ChunkMesher = V.require("ChunkMesher")
local MeshCache = V.require("MeshCache")
local Diagnostics = V.require("DiagnosticsBridge")
local GeometrySnapshot = V.require("GeometrySnapshot")

local CMD_CH = "pv_geom_cmd"
local OUT_CH = "pv_geom_out"

local MAX_WORKERS = 3
local GEOMETRY_VERSION = MeshCache.GEOMETRY_VERSION
local MAX_IN_FLIGHT_CHUNKS = 4
WorkerPool.MAX_IN_FLIGHT_CHUNKS = MAX_IN_FLIGHT_CHUNKS
WorkerPool.HEARTBEAT_TIMEOUT = 60

local function clock()
  local timer = love and love.timer
  if timer and timer.getTime then
    local ok, value = pcall(timer.getTime)
    if ok and type(value) == "number" then return value end
  end
  return os.clock()
end

local state = {
  threads = {},   -- love.thread objects
  inFlight = 0,   -- jobs dispatched, not yet drained
  started = false,
  failed = false,
  nextGen = 1,
  mapCache = {},  -- map id -> Lua-source dump (short-lived per map)
  version = GEOMETRY_VERSION,
  root = "",      -- mod fs prefix ("mods/potato_voxel" in-game, "" in a harness)
  stopping = false,
  cancelled = {},
  resultGens = {},
  lastHeartbeat = {},
}

-- Every love.* touch is pcall-guarded: the engine's mod sandbox blocks
-- love.thread unless the mod declares the `compute` permission (see
-- src/mods/Sandbox.lua), and engines without that grant must see the
-- pool as unavailable, not as a crash.
local function threadApi()
  local ok, api = pcall(function()
    return love and love.thread
  end)
  return (ok and api) or nil
end

local function channel(name)
  local ok, ch = pcall(function()
    local api = threadApi()
    return api and api.getChannel and api.getChannel(name)
  end)
  return (ok and ch) or nil
end

local function platformInfo()
  local ok, Platform = pcall(require, "src.core.Platform")
  if ok and Platform and Platform.detect then
    local okD, detected = pcall(Platform.detect)
    if okD and type(detected) == "table" then return detected end
  end
  return {}
end

-- Android field data measured one geometry worker at 1.15 jobs/s and the
-- packed CPU-only experiment at 1.3 jobs/s, versus 2.9 jobs/s for the normal
-- serial queue. Mobile therefore uses that established queue. Desktop keeps
-- two workers; NX/web and Brick retain their compatibility paths.
function WorkerPool.enabled()
  local platform = platformInfo()
  if platform.mobile or platform.nx or platform.web then return false end
  local ok, brick = pcall(function()
    local B = V.require("BrickProfile")
    return B and B.isBrick and B.isBrick()
  end)
  if ok and brick then return false end
  if state.failed then return false end
  return threadApi() ~= nil
end

function WorkerPool.workerCount()
  if platformInfo().mobile then return 0 end
  -- Desktop uses two workers when no reliable core count is available.
  return math.min(2, MAX_WORKERS)
end

function WorkerPool.cpuOnlyPrebuild()
  return false
end

function WorkerPool.start()
  if state.started or state.stopping or not WorkerPool.enabled() then return end
  -- A fresh fill may follow a wipe or data hot-reload with the same ids.
  state.mapCache = {}
  -- the mod's own fs path ("mods/potato_voxel" in-game, "" in a dev
  -- harness whose game root IS the mod dir)
  state.root = (V.mod and V.mod.path) or ""
  local n = WorkerPool.workerCount()
  for i = 1, n do
    local ok, thread = pcall(function()
      -- prefer a path spawn; fall back to the source string (read through
      -- the mod API) when the engine fs cannot see the file
      local spawnPath = state.root == "" and "workers/geometry_worker.lua"
                        or state.root .. "/workers/geometry_worker.lua"
      local t, err = love.thread.newThread(spawnPath)
      if not t and V.mod and V.mod.read then
        local okRead, source = pcall(V.mod.read, V.mod,
                                     "workers/geometry_worker.lua")
        if okRead and type(source) == "string" then
          t, err = love.thread.newThread(source)
        end
      end
      if not t then return nil, err end
      local okS, errS = pcall(t.start, t)
      if not okS then return nil, errS end
      return t
    end)
    if ok and thread then
      state.threads[#state.threads + 1] = thread
    else
      print("[warn] voxel geometry worker " .. i .. " failed to start: "
            .. tostring(thread))
    end
  end
  if #state.threads == 0 then
    state.failed = true
    return
  end
  state.started = true
  state.stopping = false
  state.cancelled = {}
  state.resultGens = {}
  state.lastHeartbeat = {}
  Diagnostics.note("geometry workers: %d threads", #state.threads)
end

function WorkerPool.working()
  return state.started and not state.stopping and #state.threads > 0
end

local function reapStopped()
  local unexpectedExit = false
  for i = #state.threads, 1, -1 do
    local thread = state.threads[i]
    local running = true
    if thread.isRunning then
      local ok, value = pcall(thread.isRunning, thread)
      running = ok and value ~= false
    end
    if not running then
      if state.started and not state.stopping then
        unexpectedExit = true
      end
      if thread.join then pcall(thread.join, thread) end
      table.remove(state.threads, i)
    end
  end
  if unexpectedExit then
    -- A dead worker may leave submitted generations with no result.  Mark
    -- the capability failed immediately so CachePrebuild rewinds those jobs
    -- into its serial path instead of silently skipping them.
    state.failed = true
    state.started = false
    Diagnostics.error("geometry worker exited unexpectedly; using serial fallback")
  end
  if state.stopping and #state.threads == 0 then
    state.stopping = false
  end
end

function WorkerPool.shutdown()
  if not state.started and not state.stopping then return end
  local cmd = channel(CMD_CH)
  if cmd then
    for gen in pairs(state.lastHeartbeat) do
      local ack = channel("pv_geom_ack_" .. tostring(gen))
      if ack then ack:push({ cancel = true }) end
    end
    cmd:push({ cmd = "cancel_all" })
    for _ = 1, #state.threads do cmd:push({ cmd = "quit" }) end
  end
  state.started = false
  state.stopping = true
  state.inFlight = 0
  state.mapCache = {}
  reapStopped()
end

function WorkerPool.cancel(gen)
  if not gen then return false end
  state.cancelled[gen] = true
  local cmd = channel(CMD_CH)
  local ack = channel("pv_geom_ack_" .. tostring(gen))
  if ack then ack:push({ cancel = true }) end
  if not cmd then return false end
  cmd:push({ cmd = "cancel", gen = gen })
  return true
end

-- A worker sends one packed chunk, then waits for this acknowledgement before
-- producing the next one. This keeps channel and worker-side retained bytes
-- bounded even when one map has millions of vertices.
function WorkerPool.ack(gen, stream, sequence)
  if not gen or not stream or not sequence then return false end
  local ack = channel("pv_geom_ack_" .. tostring(gen))
  if not ack then return false end
  ack:push({ stream = stream, sequence = sequence })
  return true
end

-- ------------------------------------------------------- serialization

-- The map's `renderer` is a live engine object, not map data: it
-- back-references the map (map.renderer.map == map) and holds Game.data,
-- so dumping it would cycle forever and drag the whole database into the
-- job payload. The geometry path never reads it -- the worker rebuilds
-- fresh map data -- so the key is dropped. `seen` is the backstop for
-- any other cyclic engine field: a table already walked is dropped as
-- nil (the same convention functions/userdata already follow).
local function dumpValue(value, out, depth, seen)
  if depth > 40 then
    error("map serialization too deep (cycle?)", 0)
  end
  local t = type(value)
  if t == "number" then
    if value ~= value then out[#out + 1] = "0/0"      -- NaN
    elseif value == math.huge then out[#out + 1] = "1/0"
    elseif value == -math.huge then out[#out + 1] = "-1/0"
    else
      out[#out + 1] = string.format("%.17g", value)
    end
  elseif t == "string" then
    out[#out + 1] = string.format("%q", value)
  elseif t == "boolean" then
    out[#out + 1] = tostring(value)
  elseif t == "nil" then
    out[#out + 1] = "nil"
  elseif t == "table" then
    if seen[value] then
      out[#out + 1] = "nil"
      return
    end
    seen[value] = true
    -- map tables are data-only trees (MapLoader builds fresh objects);
    -- methods/functions are dropped -- the worker reattaches tileAt.
    local seq = #value > 0
    out[#out + 1] = seq and "{" or "{ "
    local count = 0
    for k, v in pairs(value) do
      if type(k) ~= "string" or k:find("^[%a_][%w_]*$") then
        if k == "renderer" then
          -- engine TileRenderer (map back-ref + Game.data): not geometry
        else
          count = count + 1
          if count > 1 then out[#out + 1] = seq and "," or ", " end
          if not seq then
            if type(k) == "string" then
              out[#out + 1] = "[" .. string.format("%q", k) .. "]="
            else
              out[#out + 1] = "[" .. tostring(k) .. "]="
            end
          end
          if type(v) ~= "function" and type(v) ~= "userdata" then
            dumpValue(v, out, depth + 1, seen)
          else
            out[#out + 1] = "nil"
          end
        end
      end
    end
    out[#out + 1] = "}"
  elseif t == "function" or t == "userdata" or t == "thread" then
    out[#out + 1] = "nil"
  else
    out[#out + 1] = "nil"
  end
end

-- Map -> Lua-source table, dumped once per map (body+ring share it).
-- Skip-only fields are map internals the geometry path never reads.
function WorkerPool.serializeMap(map)
  local cached = state.mapCache[map.id]
  if cached then return cached end
  -- Real MapLoader objects have the complete geometry contract.  Project
  -- those objects before crossing the worker boundary; the legacy dumper is
  -- retained only for tiny compatibility probes that intentionally omit a
  -- map definition.
  if type(map) == "table" and type(map.def) == "table"
     and type(map.def.width) == "number"
     and type(map.def.height) == "number"
     and type(map.tileset) == "table" then
    local snapshot = GeometrySnapshot.fromMap(map, nil, "trees")
    local src = GeometrySnapshot.toSource(snapshot)
    state.mapCache[map.id] = src
    return src
  end
  local out = { "return " }
  dumpValue(map, out, 0, {})
  local src = table.concat(out)
  state.mapCache[map.id] = src
  return src
end

-- The command channel has copied the source by the time submit returns.
function WorkerPool.forgetMap(mapId)
  if not mapId or state.mapCache[mapId] == nil then return false end
  state.mapCache[mapId] = nil
  return true
end

-- ------------------------------------------------------------- jobs

-- Submit one geometry job. Returns a sequence number, or nil when the
-- pool is not working (callers fall back to the serial pump).
function WorkerPool.submit(job)
  if not WorkerPool.working() then return nil end
  if state.inFlight >= MAX_IN_FLIGHT_CHUNKS then return nil end
  if (job.version or 0) ~= state.version then return nil end
  local gen = state.nextGen
  state.nextGen = gen + 1
  state.inFlight = state.inFlight + 1
  state.lastHeartbeat[gen] = clock()
  local cmd = channel(CMD_CH)
  if not cmd then
    state.inFlight = state.inFlight - 1
    return nil
  end
  cmd:push({
    cmd = "geometry", gen = gen, mapSrc = job.mapSrc,
    bodyOnly = job.bodyOnly, pair = job.pair, masks = job.masks,
    voidFill = job.voidFill, tilePath = job.tilePath,
    mapId = job.mapId, imageWidth = job.imageWidth,
    imageHeight = job.imageHeight,
    geometryProfile = job.geometryProfile,
    allowMissingPixels = job.allowMissingPixels,
    root = state.root,
  })
  return gen
end

-- Drain finished jobs. Returns a list of { gen, data } results or
-- { gen, error } failures; removes nothing else from the pool state.
function WorkerPool.poll()
  local out = channel(OUT_CH)
  local results = {}
  if not out then return results end
  local item = out:pop()
  while item do
    if item.gen and state.cancelled[item.gen]
       and item.kind ~= "cancelled" then
      item = { gen = item.gen, kind = "cancelled" }
    end
    if item.kind == "heartbeat" then
      if item.gen then state.lastHeartbeat[item.gen] = clock() end
    elseif item.kind == "chunk" then
      if item.gen then state.lastHeartbeat[item.gen] = clock() end
      results[#results + 1] = item
    else
      local duplicate = item.gen and state.resultGens[item.gen]
      if duplicate then
        Diagnostics.count("duplicateResults")
      else
        if item.gen then state.resultGens[item.gen] = true end
        results[#results + 1] = item
      end
      state.inFlight = math.max(0, state.inFlight - 1)
      if item.gen then state.lastHeartbeat[item.gen] = nil end
    end
    item = out:pop()
  end
  reapStopped()
  return results
end

function WorkerPool.stalled(timeout, at)
  local limit = timeout or WorkerPool.HEARTBEAT_TIMEOUT
  local now = at or clock()
  local stalled = {}
  for gen, seen in pairs(state.lastHeartbeat) do
    if now - seen > limit then stalled[#stalled + 1] = gen end
  end
  table.sort(stalled)
  return stalled
end

function WorkerPool.inFlight()
  return state.inFlight
end

-- Test seam: forget serialized maps and worker state (the headless suite
-- replays boots in one process).
function WorkerPool._resetForTests()
  state.mapCache = {}
  state.started = false
  state.failed = false
  state.nextGen = 1
  state.inFlight = 0
  state.stopping = false
  state.cancelled = {}
  state.resultGens = {}
  state.lastHeartbeat = {}
end

return WorkerPool
