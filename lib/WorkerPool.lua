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
--   * the low-end class (Switch, Android, the brick profile),
--   * a failed spawn or a worker that dies,
--   * a worker whose geometry version no longer matches (hot reload).
local V = ...
local WorkerPool = {}

local ChunkMesher = V.require("ChunkMesher")
local MeshCache = V.require("MeshCache")
local Diagnostics = V.require("DiagnosticsBridge")

local CMD_CH = "pv_geom_cmd"
local OUT_CH = "pv_geom_out"

local MAX_WORKERS = 3
local GEOMETRY_VERSION = MeshCache.GEOMETRY_VERSION

local state = {
  threads = {},   -- love.thread objects
  inFlight = 0,   -- jobs dispatched, not yet drained
  started = false,
  failed = false,
  nextGen = 1,
  mapCache = {},  -- map id -> Lua-source dump (shared by body+full)
  version = GEOMETRY_VERSION,
  root = "",      -- mod fs prefix ("mods/potato_voxel" in-game, "" in a harness)
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

local function lowEnd()
  -- the engine's Platform answers the OS; NX and Android stay serial
  -- (thermal/RAM ceilings)
  local ok, Platform = pcall(require, "src.core.Platform")
  if ok and Platform and Platform.detect then
    local okD, detected = pcall(Platform.detect)
    if okD and type(detected) == "table" then
      return detected.nx or detected.android or detected.web
    end
  end
  return false
end

-- The low-end class stays serial: one core to spare is not worth the
-- battery/thermal budget, and the 1GB RAM ceiling cannot hold extra VMs.
function WorkerPool.enabled()
  if lowEnd() then return false end
  local okBrick = pcall(V.require, "Brick")
  local ok, brick = pcall(function()
    local B = V.require("Brick")
    return B and B.isBrick and B.isBrick()
  end)
  if ok and brick then return false end
  if state.failed then return false end
  return threadApi() ~= nil
end

function WorkerPool.workerCount()
  -- without a core count, two workers are safe on a 2-core device
  -- and still 2x a single-core fill on an 8-core desktop.
  return math.min(2, MAX_WORKERS)
end

function WorkerPool.start()
  if state.started or not WorkerPool.enabled() then return end
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
  Diagnostics.note("geometry workers: %d threads", #state.threads)
end

function WorkerPool.working()
  return state.started and #state.threads > 0
end

function WorkerPool.shutdown()
  if not state.started then return end
  local cmd = channel(CMD_CH)
  if cmd then
    for _ = 1, #state.threads do cmd:push({ cmd = "quit" }) end
  end
  for _, t in ipairs(state.threads) do
    if t.join then pcall(t.join, t) end
  end
  state.threads = {}
  state.started = false
  state.inFlight = 0
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

-- Map -> Lua-source table, dumped once per map (body+full share it).
-- Skip-only fields are map internals the geometry path never reads.
function WorkerPool.serializeMap(map)
  local cached = state.mapCache[map.id]
  if cached then return cached end
  local out = { "return " }
  dumpValue(map, out, 0, {})
  local src = table.concat(out)
  state.mapCache[map.id] = src
  return src
end

-- ------------------------------------------------------------- jobs

-- Submit one geometry job. Returns a sequence number, or nil when the
-- pool is not working (callers fall back to the serial pump).
function WorkerPool.submit(job)
  if not WorkerPool.working() then return nil end
  if (job.version or 0) ~= state.version then return nil end
  local gen = state.nextGen
  state.nextGen = gen + 1
  state.inFlight = state.inFlight + 1
  local cmd = channel(CMD_CH)
  if not cmd then
    state.inFlight = state.inFlight - 1
    return nil
  end
  cmd:push({
    cmd = "geometry", gen = gen, mapSrc = job.mapSrc,
    bodyOnly = job.bodyOnly, masks = job.masks,
    voidFill = job.voidFill, tileImage = job.tileImage,
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
    results[#results + 1] = item
    state.inFlight = math.max(0, state.inFlight - 1)
    item = out:pop()
  end
  return results
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
end

return WorkerPool
