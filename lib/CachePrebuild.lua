-- Cooperative all-map mesh-cache prebuilder.
-- Keeps only one runtime map resident while ChunkMesher's normal sliced queue
-- does the actual body/ring/aux work and writes terrain, water, and aux files.
local V = ...
local Prebuild = {}

local ChunkMesher = V.require("ChunkMesher")
local MeshCache = V.require("MeshCache")
local WorkerPool = V.require("WorkerPool")
local GeometryStream = V.require("GeometryStream")
local GeometryProfile = V.require("GeometryProfile")
local Structures = V.require("Structures")
local Budget = V.require("BuildBudget")
local Diagnostics = V.require("DiagnosticsBridge")

-- Use the engine's own placement routine so prebuilt FULL masks cover the same
-- connected strips (including two-hop neighbours) as the live renderer.
local OverworldState = require("src.world.OverworldController")

local state = { running = false, cancelled = false, maps = {}, index = 0,
                slot = nil, done = 0, total = 0, game = nil,
                startedAt = nil, eta = nil, ready = false,
                failed = false, error = nil, completed = {},
                threaded = {} }

-- BUG-2a pump budget: the slices the prebuild pumps the shared queue
-- with. The queue's idle/covered slices are tuned for live neighbour
-- builds; a prebuild monopolizes the queue for minutes, and the full
-- covered slice turned one hiccup into a wall-clock freeze (field logs:
-- the 30ms slice routinely overshot). Tightened from here -- the
-- prebuild owns the pump while it runs -- and restored around every
-- pump call, so the live path's numbers are untouched.
local PREBUILD_IDLE_SLICE = 0.003
local PREBUILD_COVERED_SLICE = 0.025
-- One tick of rest after a pump overshoots its slice: the frame after a
-- freeze must not compound it with another full slice (the job resumes
-- on the following pump).
local pumpPause = 0

-- BUG-2b resume-scan budgets: the survivor scan is ~2 storage reads per
-- job (seconds of cold-flash reads for a whole set), so it runs in
-- update() ticks, time-capped, instead of one synchronous pass. Job sets
-- at or below RESUME_SCAN_INLINE still scan inline (they cost nothing).
local RESUME_SCAN_INLINE = 16
local SCAN_IDLE_MS = 0.008
local SCAN_COVERED_MS = 0.020
local SCAN_MAX_JOBS = 32

Prebuild.MAX_CHUNK_VERTICES = 16384
Prebuild.MAX_CHUNK_INDICES = 24576
Prebuild.MAX_IN_FLIGHT_CHUNKS = 4

local metrics = {
  peakInFlightBytes = 0,
  workerFallbacks = 0,
  mainThreadMapLoadMs = 0,
  mainThreadEncodeMs = 0,
  mainThreadStorageMs = 0,
  commits = 0,
  commitFailures = 0,
  cancelledJobs = 0,
  duplicateResults = 0,
  worstFrameMs = 0,
  cpuOnlyPairs = 0,
  cpuOnlyJobs = 0,
}

-- BUG-1 pre-warm latch: the first map's body mesh primes from the cache
-- exactly once per session (see Prebuild.primeFirst).
local primed = false
local gen2MapCache = {}

local function populated(value)
  return type(value) == "table" and next(value) ~= nil
end

local function firstPopulated(primary, fallback)
  if populated(primary) then return primary end
  if populated(fallback) then return fallback end
  return primary or fallback or {}
end

local function resolveMaps(game, data)
  local world = game and (game.world or game.overworld)
  if world and populated(world.maps) then return world.maps end
  -- Gen 2 owns its imported tables under gen2Maps. Keep maps as a fallback
  -- for older API-2 engines and headless fixtures, but prefer the namespaced
  -- table so a Gen 2 boot never accidentally consumes a Gen 1 table.
  if data and populated(data.gen2Maps) then return data.gen2Maps end
  if data and populated(data.maps) then return data.maps end
  local okR, RuntimeHooks = pcall(function() return V.require("RuntimeHooks") end)
  if okR and RuntimeHooks and RuntimeHooks.liveGame then
    local okG, Game = pcall(RuntimeHooks.liveGame)
    if okG and Game then
      local gWorld = Game.world or Game.overworld
      if gWorld and populated(gWorld.maps) then return gWorld.maps end
      if Game.data and populated(Game.data.gen2Maps) then
        return Game.data.gen2Maps
      end
      if Game.data and populated(Game.data.maps) then return Game.data.maps end
    end
  end
  return firstPopulated(data and data.gen2Maps, data and data.maps)
end

local function resolveTilesets(game, data)
  local world = game and (game.world or game.overworld)
  if world and populated(world.tilesets) then return world.tilesets end
  if data and populated(data.gen2Tilesets) then return data.gen2Tilesets end
  if data and populated(data.tilesets) then return data.tilesets end
  local okR, RuntimeHooks = pcall(function() return V.require("RuntimeHooks") end)
  if okR and RuntimeHooks and RuntimeHooks.liveGame then
    local okG, Game = pcall(RuntimeHooks.liveGame)
    if okG and Game then
      local gWorld = Game.world or Game.overworld
      if gWorld and populated(gWorld.tilesets) then return gWorld.tilesets end
      if Game.data and populated(Game.data.gen2Tilesets) then
        return Game.data.gen2Tilesets
      end
      if Game.data and populated(Game.data.tilesets) then
        return Game.data.tilesets
      end
    end
  end
  return firstPopulated(data and data.gen2Tilesets, data and data.tilesets)
end

local function resolveData(game)
  local data = game and game.data
  local maps = resolveMaps(game, data)
  local tilesets = resolveTilesets(game, data)
  return {
    maps = maps,
    tilesets = tilesets,
    profileRevision = data and data.profileRevision,
    voxelProfileRevision = data and data.voxelProfileRevision,
    gen2Palettes = data and data.gen2Palettes,
    gen2Roofs = data and data.gen2Roofs,
  }
end

local function sortedIds(maps)
  local ids = {}
  for id, def in pairs(maps or {}) do
    if type(def) == "table" and (def.width or def.w or def.blocks or def.environment or def.tileset) then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
  return ids
end

-- Direct connection rectangles in the current map's world-pixel frame. This
-- is the same placement math as OverworldState.computeNeighbors, but uses the
-- authoritative generated map definitions and never constructs neighbours.
local function masksFor(maps, id)
  local out = {}
  local ok, neighbours = pcall(OverworldState.computeNeighbors, maps, id, 2)
  if not ok or not neighbours or #neighbours == 0 then
    local okWorld, World = pcall(require, "src.world.gen2.World")
    if okWorld and World and type(World.computeNeighbors) == "function" then
      local okN, n = pcall(World.computeNeighbors, maps, id, 2)
      if okN and n then neighbours = n end
    end
  end
  for _, neighbour in ipairs(neighbours or {}) do
    local other = maps[neighbour.id]
    if other then
      out[#out + 1] = {
        neighbour.ox, neighbour.oy,
        neighbour.ox + (other.width or 0) * 32,
        neighbour.oy + (other.height or 0) * 32,
      }
    end
  end
  table.sort(out, function(a, b)
    return (a[2] == b[2]) and (a[1] < b[1]) or (a[2] < b[2])
  end)
  return out
end

Prebuild.enumerate = function(maps)
  local ids = sortedIds(maps)
  local jobs = {}
  for _, id in ipairs(ids) do
    local masks = masksFor(maps, id)
    jobs[#jobs + 1] = { id = id, slot = "body", masks = masks }
    jobs[#jobs + 1] = { id = id, slot = "ring", masks = masks }
  end
  return jobs
end
Prebuild.masksFor = masksFor

-- Resume records may be scattered through the sorted job set.  Keeping only
-- the leading completed run makes those later survivors count as done and
-- then rebuilds them anyway, so progress can reach total before the frontier
-- is exhausted.  Build the actual pending frontier once instead.
function Prebuild.pendingJobs(jobs, completed)
  local pending = {}
  for _, job in ipairs(jobs or {}) do
    local key = tostring(job.id) .. "/" .. tostring(job.slot)
    if not (completed and completed[key]) then
      pending[#pending + 1] = job
    end
  end
  return pending
end

function Prebuild.available()
  return MeshCache.available()
end

function Prebuild.bootstrap(game)
  primed = false
  pumpPause = 0
  gen2MapCache = {}
  local data = resolveData(game)
  MeshCache.configure(data)
  local jobs = Prebuild.enumerate(data and data.maps)
  local ready, done = MeshCache.ready(jobs)
  -- Not READY is no longer "start from zero": a build interrupted
  -- mid-session (F3) left complete atomic payloads behind, and a rescan
  -- of the actual files recovers exactly which jobs survived. Those
  -- become the resume set -- start() skips them and only the missing
  -- remainder gets rebuilt. The rescan itself is ~2 storage reads per
  -- job -- seconds of cold-flash reads on the game.ready frame (the NX
  -- boot log: a 3.0s first frame with a cold cache) -- so it is
  -- DEFERRED: start() runs it once, when a build actually begins --
  -- chunked across update() ticks for a full job set -- never on the
  -- boot frame. completed == nil is the deferred marker;
  -- a ready cache and a wipe both leave a real (empty) table.
  local completed = ready and {} or nil
  if not ready then done = 0 end
  state = { running = false, cancelled = false, maps = jobs, index = 0,
            slot = nil, done = ready and #jobs or done, total = #jobs,
            game = nil, startedAt = nil, eta = nil, ready = ready,
            failed = false, error = nil, completed = completed,
            declined = false, gateRan = false }
  -- Boot diagnostics: log the full cache identity, the resolved cache dir,
  -- and -- when the cache was rejected -- exactly why, plus how it compares
  -- to the build.info sidecar written at build time. This is the only window
  -- into a persistent cache rejection on real hardware.
  local parts = MeshCache.identityParts()
  local build = MeshCache.readBuildInfo()
  print("[PotatoVoxel] cache identity: " .. MeshCache.identity())
  print("[PotatoVoxel]   format=" .. tostring(parts.format)
    .. " version=" .. tostring(parts.version)
    .. " activeVersion=" .. tostring(parts.activeVersion)
    .. " profile=" .. tostring(parts.profile)
    .. " dataKey=" .. tostring(parts.dataKey)
    .. " voidFill=" .. tostring(parts.voidFill))
  print("[PotatoVoxel] cache dir: " .. tostring(MeshCache.dir()))
  print("[PotatoVoxel] cache ready: " .. tostring(ready) .. " (" .. done
    .. "/" .. #jobs .. ")")
  if build then
    print("[PotatoVoxel] build.info: identity=" .. tostring(build.identity)
      .. " version=" .. tostring(build.version)
      .. " activeVersion=" .. tostring(build.activeVersion)
      .. " profile=" .. tostring(build.profile)
      .. " dataKey=" .. tostring(build.dataKey)
      .. " voidFill=" .. tostring(build.voidFill)
      .. " builtAt=" .. tostring(build.builtAt))
    if ready then
      print("[PotatoVoxel]   build identity matches live identity")
    else
      local diffs = MeshCache.identityDiff(build.identity, MeshCache.identity())
      print("[PotatoVoxel]   build identity differs in: "
        .. (#diffs > 0 and table.concat(diffs, ",") or "?"))
    end
  end
  if not ready then
    local failure = MeshCache.getLastFailure()
    if failure then
      print("[PotatoVoxel] cache rejected: " .. tostring(failure.reason))
      if failure.expected then
        print("[PotatoVoxel]   expected=" .. tostring(failure.expected))
      end
      if failure.actual then
        print("[PotatoVoxel]   actual=" .. tostring(failure.actual))
      end
      if failure.diffs and #failure.diffs > 0 then
        print("[PotatoVoxel]   diffs=" .. table.concat(failure.diffs, ","))
      end
      if failure.job then
        print("[PotatoVoxel]   job=" .. tostring(failure.job))
      end
    end
    if done > 0 then
      print("[PotatoVoxel]   resumable: " .. done .. "/" .. #jobs
        .. " jobs already complete")
    end
  end
  return ready
end

local function isGen2()
  local okVersion, GameVersion = pcall(require, "src.core.GameVersion")
  return okVersion and GameVersion and type(GameVersion.generation) == "function"
         and tonumber(GameVersion.generation()) == 2
end

local function gen2MapOwner(game)
  local world = game and (game.world or game.overworld)
  local liveMap = world and world.map
  local owner = liveMap and getmetatable(liveMap)
  if type(owner) == "table" and type(owner.new) == "function" then
    return owner
  end
  local okR, RuntimeHooks = pcall(function() return V.require("RuntimeHooks") end)
  if okR and RuntimeHooks and RuntimeHooks.liveGame then
    local okG, live = pcall(RuntimeHooks.liveGame)
    local liveWorld = okG and live and (live.world or live.overworld)
    local liveOwner = liveWorld and liveWorld.map
                       and getmetatable(liveWorld.map)
    if type(liveOwner) == "table" and type(liveOwner.new) == "function" then
      return liveOwner
    end
  end
  -- Current GS engines expose this alias. It is a fallback only; Crystal
  -- runtimes can supply their own map class through the live world above.
  local okMap, Gen2Map = pcall(require, "src.world.gen2.Map")
  if okMap and type(Gen2Map) == "table"
     and type(Gen2Map.new) == "function" then
    return Gen2Map
  end
  return nil
end

local function loadPrebuildMap(data, id, game)
  if not id then return nil end
  data = resolveData(game or state.game)
  if isGen2() then
    if gen2MapCache[id] then return gen2MapCache[id] end
    local Gen2Map = gen2MapOwner(game or state.game)
    if Gen2Map then
      local def = data.maps and data.maps[id]
      local tileset = def and data.tilesets and data.tilesets[def.tileset]
      if def and tileset then
        local map = Gen2Map.new(def, tileset)
        local world = (game and game.world) or (state.game and state.game.world)
        if not world then
          local okR, RuntimeHooks = pcall(function() return V.require("RuntimeHooks") end)
          local okG, Game = okR and RuntimeHooks and RuntimeHooks.liveGame
                              and pcall(RuntimeHooks.liveGame)
          world = okG and Game and (Game.world or Game.overworld) or nil
        end
        if world and type(world.atlasFor) == "function" then
          local okA, atlas, ts = pcall(world.atlasFor, world, def)
          if okA and atlas then
            map.tileset = ts or map.tileset
            map.renderer = map.renderer or {}
            local okGA, GoldAtlas = pcall(function() return V.require("GoldAtlas") end)
            if okGA and GoldAtlas and GoldAtlas.forMap then
              local colored, isColored, atlasData = GoldAtlas.forMap(world, map, atlas)
              map.renderer.image = colored
              map.renderer.gbcAtlas = isColored
              map.renderer.data = data
              map.renderer.atlasData = atlasData
            end
          end
        end
        if not (map.renderer and map.renderer.atlasData) then
          local okAssets, Assets = pcall(require, "src.render.Assets")
          local okPix, pix = okAssets and Assets and pcall(Assets.imageData, tileset.image)
          if okPix and pix and pix.getPixel then
            map.renderer = map.renderer or {}
            map.renderer.atlasData = pix
            map.renderer.data = data
          end
        end
        gen2MapCache[id] = map
        return map
      end
    end
  end

  local okLoader, MapLoader = pcall(require, "src.world.MapLoader")
  if okLoader and MapLoader and type(MapLoader.load) == "function" then
    return MapLoader.load(data, id)
  end
  return nil
end

local function cachedPrebuildMap(id)
  if gen2MapCache[id] then return gen2MapCache[id] end
  local okLoader, MapLoader = pcall(require, "src.world.MapLoader")
  return (okLoader and MapLoader and MapLoader.cached) and MapLoader.cached(id) or nil
end

-- Never tear down an instance the overworld can still draw.  The options
-- action may outlive the menu that started it (and the player can move while
-- it runs), so the live set has to be checked at the moment a job completes,
-- not only when prebuild starts.
local function liveMaps(game)
  local live = {}
  local overworld = game and (game.world or game.overworld or game)
  local current = overworld and overworld.map
  if current and current.id then live[current.id] = true end
  for _, neighbour in ipairs((overworld and overworld.neighbors) or {}) do
    local map = neighbour.map or neighbour
    if map and map.id then live[map.id] = true end
  end
  return live
end

local function releaseMap(id, game)
  if liveMaps(game)[id] then return false end
  if ChunkMesher.release then ChunkMesher.release(id) end
  gen2MapCache[id] = nil
  -- the module table is gone (sandbox): the loader is reached the
  -- supported way.
  local okLoader, MapLoader = pcall(require, "src.world.MapLoader")
  if not okLoader then MapLoader = nil end
  local m = MapLoader and MapLoader.evict and MapLoader.cached(id)
  if m and MapLoader.evict then MapLoader.evict(id) end
  return true
end

local function finish(cancelled)
  -- Completion can arrive through both the worker drain and the update
  -- frontier in the same frame. Only the first caller may write the final
  -- manifest or shut down the pool.
  if not state.running or state.finishing then
    metrics.duplicateResults = metrics.duplicateResults + 1
    return
  end
  state.finishing = true
  if cancelled then
    local cancelledCount = 0
    for cancelIndex, entry in pairs(state.threaded or {}) do
      WorkerPool.cancel(cancelIndex)
      cancelledCount = cancelledCount + 1
      releaseMap(entry.job.id, state.game)
    end
    metrics.cancelledJobs = metrics.cancelledJobs + cancelledCount
    state.threaded = {}
    if state.cpuTask then
      metrics.cancelledJobs = metrics.cancelledJobs
        + #(state.cpuTask.jobs or {})
      releaseMap(state.cpuTask.job.id, state.game)
      state.cpuTask = nil
    end
    pcall(MeshCache.writeProgress, state.completed, state.total)
    WorkerPool.shutdown()
  end
  if state.index > 0 and state.maps[state.index] then
    releaseMap(state.maps[state.index].id, state.game)
  end
  if not cancelled and not state.failed and state.done >= state.total then
    state.ready = MeshCache.writeManifest(state.completed, state.total)
    if not state.ready then
      state.failed = true
      state.error = MeshCache.saveError() or "manifest write failed"
      metrics.commitFailures = metrics.commitFailures + 1
    else
      metrics.commits = metrics.commits + 1
      local secs = state.startedAt and
        (love and love.timer and love.timer.getTime
         and love.timer.getTime() - state.startedAt) or 0
      local rate = secs and secs > 0 and (state.total / secs) or 0
      Diagnostics.trace("prebuild finished READY in %.1fs (%.1f jobs/s)",
                        secs, rate)
      local compressed = MeshCache.compressionMetrics
                       and MeshCache.compressionMetrics()
      if compressed then
        Diagnostics.trace("prebuild lz4: %d payloads, %d -> %d bytes, %.1fms",
                          compressed.attempts or 0, compressed.rawBytes or 0,
                          compressed.packedBytes or 0,
                          compressed.milliseconds or 0)
      end
    end
    WorkerPool.shutdown()
  end
  state.running, state.cancelled = false, cancelled or false
  state.slot = nil
  state.game = nil
  state.eta = nil
  state.finishing = false
end

local function now()
  local timer = love and love.timer
  if timer and timer.getTime then
    local ok, value = pcall(timer.getTime)
    if ok and type(value) == "number" then return value end
  end
  return nil
end

local function countKeys(table_)
  local count = 0
  for _ in pairs(table_ or {}) do count = count + 1 end
  return count
end

-- The old android() OS probe is gone with the sandbox: the one use was
-- a shortened progress label, which now reads the same everywhere.

Prebuild.isAndroid = function() return false end

function Prebuild.start(game)
  if state.running then
    state.cancelled = true
    return false
  end
  pumpPause = 0
  state.finishing = false
  for key in pairs(metrics) do metrics[key] = 0 end
  -- An explicit start overrides nothing: the session's decline and gate
  -- history survive the row build (so a cancel then a wipe cannot
  -- silently re-arm the auto-start). Only bootstrap -- a fresh boot --
  -- clears them.
  local sessionDeclined, sessionGateRan = state.declined, state.gateRan
  local data = resolveData(game or state.game)
  MeshCache.configure(data)
  local jobs = Prebuild.enumerate(data and data.maps)
  if #jobs == 0 or not MeshCache.available() then return false end
  MeshCache.begin()
  -- RESUME (F3): jobs the boot scan found complete are skipped, so a
  -- prebuild interrupted mid-session finishes the remainder instead of
  -- rebuilding everything from zero. A fresh build (empty completed)
  -- starts at the first job as before. The boot scan was deferred off
  -- the first frame (cold-flash reads measured seconds there); it runs
  -- here, once, only when a build actually starts -- and, for a full
  -- job set, in update() ticks rather than one synchronous pass (a
  -- 444-job rescan is the field logs' 1.5s freeze). Small sets scan
  -- inline: they cost nothing.
  local completed = state.completed
  if completed == nil then
    completed = {}
    if #jobs <= RESUME_SCAN_INLINE then
      local okS, records = pcall(MeshCache.scanComplete, jobs)
      if okS and records then completed = records end
      state.scan = nil   -- a leftover chunked scan (data shrank) is stale
    elseif not (state.scan and #state.scan.jobs == #jobs) then
      -- deferred: the survivor scan advances in update() ticks, and
      -- dispatch waits for it (the resume set decides which jobs skip)
      state.scan = { jobs = jobs, index = 1, records = {} }
    end
  end
  -- The pending chunked scan must survive the state rebuild below.
  local pendingScan = state.scan
  local pending = pendingScan and jobs or Prebuild.pendingJobs(jobs, completed)
  WorkerPool.start()
  state = { running = true, cancelled = false, maps = pending, index = 1,
            slot = nil, done = countKeys(completed), total = #jobs,
            game = game, scan = pendingScan,
            startedAt = now(), eta = nil, ready = false,
            failed = false, error = nil, completed = completed,
            declined = sessionDeclined, gateRan = sessionGateRan,
            threaded = {} }
  Diagnostics.trace("prebuild start: %d/%d done, %d jobs",
                    countKeys(completed), #jobs, #jobs)
  return true
end

-- Hands-off boot fill: an incomplete cache starts building on its own
-- once a playthrough's overworld is up -- the OPTIONS row and the boot
-- prompt both need in-game storage and the save's live options, and a
-- fresh device should not depend on the player finding either. Gated to
-- exactly the PREBUILD (never started) state, so an explicit cancel, a
-- declined prompt, a FAILED build, a completed READY cache or a running
-- build all block it, and the cooperative pump slices keep it invisible
-- on the frame.
function Prebuild.autoStart(game)
  if state.gateRan then return false end
  if state.declined then return false end
  if Prebuild.status() ~= "PREBUILD" then return false end
  local ow = game and (game.overworld or game.world or game)
  if not (ow and ow.map and ow.camera) then return false end
  Diagnostics.trace("prebuild auto-start: cache incomplete, filling in "
                    .. "the background")
  return Prebuild.start(game)
end

-- The boot gate's "MAP CACHE NOT READY. BUILD NOW?" prompt answered NO:
-- the auto-start must not override an explicit decline (it did once --
-- field log: the player said no, the fill started anyway). Per-session:
-- bootstrap re-arms it, a wipe re-arms it, and the OPTIONS row still
-- starts a build whenever the player wants one.
function Prebuild.decline()
  if state.running then return false end
  state.declined = true
  return true
end

function Prebuild.cancel()
  if state.running then state.cancelled = true; return true end
  return false
end

function Prebuild.wipe(game)
  if state.running then return false end
  local data = resolveData(game or state.game)
  MeshCache.configure(data)
  local jobs = Prebuild.enumerate(data and data.maps)
  local ok = MeshCache.wipe(jobs)
  if ok then
    ChunkMesher.invalidate()
    gen2MapCache = {}
    state.ready, state.cancelled, state.failed = false, false, false
    -- A decline stays sticky through a wipe: the player answered NO to
    -- the prompt this session, and wiping must not silently override
    -- that (field log: a wipe started the fill anyway). The OPTIONS row
    -- and a fresh boot are the re-arm paths.
    state.done, state.total, state.error = 0, #jobs, nil
    state.completed = {}
    state.scan = nil   -- a stale survivor scan describes the old cache
  end
  return ok
end

-- A confirmed REBUILD is intentionally different from start/resume: delete
-- every committed payload first, clear the survivor set, then build all jobs
-- from zero. This keeps the UI promise honest and prevents a READY cache from
-- merely validating and re-uploading its existing records.
function Prebuild.rebuild(game)
  if state.running then return false end
  if not Prebuild.wipe(game) then return false end
  return Prebuild.start(game)
end

-- Re-evaluate readiness against the live identity and files, and update
-- the resume set. Called after the engine applies a save's real options
-- (CONTINUE's restoreSave / NEW GAME's onNewGame): the game.ready-time
-- check ran under the skeleton save's defaults, and a player's VOID FILL
-- choice would otherwise read as a stale cache on every launch (F1).
-- Running the gate IS the consent event: the prompt (or its ready-skip)
-- answers the fill question, so the hands-off auto-start must never act
-- on a boot the gate already handled.
function Prebuild.refresh(game)
  state.gateRan = true
  if state.running then return end
  local data = resolveData(game or state.game)
  MeshCache.configure(data)
  local jobs = Prebuild.enumerate(data and data.maps)
  if #jobs ~= state.total then
    -- the dataset changed under us (hot reload): full re-bootstrap
    return Prebuild.bootstrap(game)
  end
  local ready, done = MeshCache.ready(jobs)
  state.ready = ready
  if ready then
    state.done = #jobs
    state.failed, state.error = false, nil
    state.completed = {}
  else
    if #jobs <= RESUME_SCAN_INLINE then
      local completed = MeshCache.scanComplete(jobs)
      state.completed = completed
      state.done = countKeys(completed)
    else
      -- The survivor scan is deferred to update() ticks (cold-flash
      -- reads): the gate's prompt can go up now, and a build that
      -- starts mid-scan waits for the resume set. completed == nil is
      -- the same deferred marker start() consumes.
      state.completed = nil
      state.done = 0
      if not (state.scan and #state.scan.jobs == #jobs) then
        state.scan = { jobs = jobs, index = 1, records = {} }
      end
    end
  end
  state.total = #jobs
  return ready
end

-- Keep the options-row decision separate from the UI so the READY path can be
-- covered headlessly.  A running build keeps its existing A-to-cancel action;
-- only a completed cache needs confirmation before it is rebuilt.
function Prebuild.activationDecision(status, running)
  if running then return "cancel" end
  if status == "READY" then return "confirm_rebuild" end
  return "start"
end

-- Throttled manifest progress: F3 resume needs a manifest naming the
-- jobs whose files survived, but writing it on EVERY job costs a full
-- manifest encode + storage write per job -- O(n^2) bytes on slow flash,
-- the prebuild's biggest fixed overhead. Every 8 jobs or every 5 seconds,
-- plus always on finish (writeManifest).
local function progressTick()
  local since = state.lastProgress or 0
  if state.done % 8 == 0 or (now() or 0) - since >= 5 then
    if MeshCache.writeProgress(state.completed, state.total) then
      state.lastProgress = now()
    end
  end
end

-- A worker error is a capability/transport failure, not a cache failure.
-- Drop the pool and replay the frontier through the serial resolver; this is
-- especially important when a worker cannot open a generated tileset image.
local function fallbackThreaded(entry, reason)
  metrics.workerFallbacks = metrics.workerFallbacks + 1
  Diagnostics.warn("geometry worker fallback: %s", tostring(reason))
  WorkerPool.shutdown()
  local rewind = #state.maps + 1
  for i, candidate in ipairs(state.maps) do
    if candidate == entry.job
       or (candidate.id == entry.job.id
           and candidate.slot == entry.job.slot) then
      rewind = i
      break
    end
  end
  for _, pending in pairs(state.threaded) do
    releaseMap(pending.job.id, state.game)
  end
  state.threaded = {}
  releaseMap(entry.job.id, state.game)
  state.done = countKeys(state.completed)
  state.index = rewind
  while state.index <= #state.maps do
    local candidate = state.maps[state.index]
    local key = tostring(candidate.id) .. "/" .. tostring(candidate.slot)
    if not state.completed[key] then break end
    state.index = state.index + 1
  end
  state.slot = nil
end

local function streamOk(s)
  return type(s) == "table" and type(s.n) == "number"
     and type(s.m) == "number"
     and ((type(s.buf) == "table" and type(s.idx) == "table")
          or type(s.chunks) == "table")
end

-- Decode one packed worker stream on demand. Main thread materializes only
-- current stream being committed; workers never send whole-map Lua arrays.
local function materializeThreadStream(stream)
  if type(stream.buf) == "table" and type(stream.idx) == "table" then
    return stream
  end
  local out = { buf = {}, n = 0, idx = {}, m = 0 }
  for _, chunk in ipairs(stream.chunks or {}) do
    local decoded, err = GeometryStream.decode(chunk)
    if not decoded then return nil, "chunk decode: " .. tostring(err) end
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
  if out.n ~= stream.n or out.m ~= stream.m then
    return nil, "chunk count mismatch"
  end
  return out
end

local function saveThreadedSlot(map, job, data)
  if not (data and streamOk(data.terrain) and streamOk(data.water)) then
    return false
  end
  local started = now()
  local chunked = type(data.terrain.chunks) == "table"
                  and type(data.water.chunks) == "table"
  if chunked and MeshCache.saveTerrainChunks
     and MeshCache.saveWaterChunks then
    local okT, terrainSaved = pcall(MeshCache.saveTerrainChunks, map, job.slot,
                                    data.terrain)
    if not okT or not terrainSaved then return false end
    Budget.check()
    local okW, waterSaved = pcall(MeshCache.saveWaterChunks, map, job.slot,
                                  data.water)
    if not okW or not waterSaved then return false end
  else
    local terrain, terrainErr = materializeThreadStream(data.terrain)
    local water, waterErr = materializeThreadStream(data.water)
    if not terrain or not water then
      Diagnostics.warn("worker stream materialization failed: %s",
                       tostring(terrainErr or waterErr))
      return false
    end
    local okT, terrainSaved = pcall(MeshCache.saveTerrain, map, job.slot,
                                    terrain.buf, terrain.n,
                                    terrain.idx, terrain.m)
    if not okT or not terrainSaved then return false end
    Budget.check()
    local okW, waterSaved = pcall(MeshCache.saveWater, map, job.slot,
                                  water.buf, water.n,
                                  water.idx, water.m)
    if not okW or not waterSaved then return false end
  end
  if not data.aux then return false end
  local okA, aux = pcall(MeshCache.saveAux, map, job.slot, data.aux, true)
  if not okA or not aux then return false end
  Budget.check()
  local elapsed = started and now()
  if started and elapsed then
    metrics.mainThreadStorageMs = metrics.mainThreadStorageMs
      + (elapsed - started) * 1000
  end
  return MeshCache.verifyJob(map, job.slot)
end

-- Mobile serial path. One worker regressed Android throughput by 60%, while
-- the old serial fallback built throwaway GPU meshes for every cache slot.
-- Build packed body/ring geometry inside one cooperative coroutine, share one
-- Structures analysis, commit bytes directly, and never touch love.graphics.
local function cpuPairAtFrontier()
  local job = state.maps[state.index]
  if not job then return nil end
  local nextJob = state.maps[state.index + 1]
  local pair = nil
  if job.slot == "body" and nextJob
     and nextJob.id == job.id and nextJob.slot == "ring"
     and not state.completed[tostring(job.id) .. "/body"]
     and not state.completed[tostring(job.id) .. "/ring"] then
    pair = nextJob
  end
  return job, pair
end

local function startCpuTask()
  local job, pair = cpuPairAtFrontier()
  if not job then return nil end
  local task = {
    job = job,
    jobs = pair and { job, pair } or { job },
    pair = pair,
    results = {},
    phase = "load",
  }
  task.co = coroutine.create(function()
    local data = state.game and state.game.data
    local started = now()
    task.map = loadPrebuildMap(data, job.id, state.game)
    local loadedAt = now()
    if started and loadedAt then
      local loadMs = (loadedAt - started) * 1000
      metrics.mainThreadMapLoadMs = metrics.mainThreadMapLoadMs + loadMs
      if loadMs > 250 then
        Diagnostics.warn("prebuild map load overshot: %s %.0fms",
                         tostring(job.id), loadMs)
      end
    end
    if not task.map then error("map load failed", 0) end
    Budget.check()

    task.phase = "geometry"
    local built
    if pair then
      built = ChunkMesher.buildGeometryPairChunkData(task.map, job.masks)
      if not (built and built.body and built.ring and built.aux) then
        error("paired geometry failed", 0)
      end
      built.body.aux = built.aux
      built.ring.aux = built.aux
      task.payloads = { built.body, built.ring }
      metrics.cpuOnlyPairs = metrics.cpuOnlyPairs + 1
    else
      local variant = job.slot == "body" and true or "ring"
      built = ChunkMesher.buildGeometryChunkData(task.map, variant, job.masks)
      if not (built and built.terrain and built.water and built.aux) then
        error("geometry failed", 0)
      end
      task.payloads = { built }
    end
    Budget.check()

    task.phase = "save"
    for i, candidate in ipairs(task.jobs) do
      task.results[i] = saveThreadedSlot(task.map, candidate,
                                         task.payloads[i]) == true
      Budget.check()
    end
  end)
  state.cpuTask = task
  return task
end

local function finishCpuTask(task, errorMessage)
  local successes = 0
  for i, job in ipairs(task.jobs) do
    if not errorMessage and task.results[i] then
      state.completed[tostring(job.id) .. "/" .. tostring(job.slot)] =
        MeshCache.jobRecord(task.map, job.slot)
      successes = successes + 1
      Diagnostics.trace("prebuild %d/%d done %s/%s (cpu-only)",
                        state.done + i, state.total, tostring(job.id),
                        tostring(job.slot))
    else
      state.failedJobs = (state.failedJobs or 0) + 1
      Diagnostics.error("prebuild job failed (%d/%d): %s -- %s/%s",
                        state.failedJobs, state.total,
                        tostring(errorMessage or MeshCache.saveError()
                          or "cache verification failed"),
                        tostring(job.id), tostring(job.slot))
    end
  end
  metrics.cpuOnlyJobs = metrics.cpuOnlyJobs + #task.jobs
  state.done = state.done + #task.jobs
  state.index = state.index + #task.jobs
  state.cpuTask = nil
  state.slot = nil
  if successes > 0 then progressTick() end
  releaseMap(task.job.id, state.game)

  local maxFailures = math.max(4, math.floor(state.total / 10))
  if (state.failedJobs or 0) > maxFailures then
    state.failed = true
    state.error = ("%d jobs failed"):format(state.failedJobs)
    finish(false)
    return
  end
  local elapsed = state.startedAt and now()
  if elapsed and state.startedAt and state.done > 0 then
    state.eta = (elapsed - state.startedAt) * (state.total - state.done)
             / state.done
  end
  if state.done >= state.total then finish(false) end
end

local function updateCpuOnly(covered)
  local task = state.cpuTask or startCpuTask()
  if not task then finish(false); return end
  local slice = covered and PREBUILD_COVERED_SLICE or PREBUILD_IDLE_SLICE
  local started = now()
  Budget.begin(task.co, slice)
  local ok, err = coroutine.resume(task.co)
  Budget.finish()
  local finishedAt = now()
  local elapsedMs = started and finishedAt and (finishedAt - started) * 1000 or 0
  if elapsedMs > metrics.worstFrameMs then metrics.worstFrameMs = elapsedMs end
  if elapsedMs > slice * 1000 * 4 then
    pumpPause = 1
    Diagnostics.warn("prebuild CPU overshot: %s/%s in %s %.0fms vs %.0fms "
                    .. "slice; pausing next tick", tostring(task.job.id),
                    tostring(task.job.slot), tostring(task.phase), elapsedMs,
                    slice * 1000)
  end
  if not ok then
    finishCpuTask(task, err)
  elseif coroutine.status(task.co) == "dead" then
    finishCpuTask(task)
  end
end

-- One threaded result writes one or two slots. Pair jobs share the worker's
-- Structures analysis and aux flattening, then release the map once.
local function finishThreaded(result)
  local entry = state.threaded[result.gen]
  if not entry then return end
  if result.kind == "chunk" then
    local bucket = entry.chunks[result.stream]
    if not bucket then
      bucket = { chunks = {}, n = 0, m = 0, nextSequence = 1 }
      entry.chunks[result.stream] = bucket
    end
    local chunk = result.chunk
    if not chunk or chunk.sequence ~= bucket.nextSequence then
      fallbackThreaded(entry, "worker chunk sequence mismatch")
      return
    end
    bucket.chunks[#bucket.chunks + 1] = chunk
    bucket.n = bucket.n + (chunk.vertexCount or 0)
    bucket.m = bucket.m + (chunk.indexCount or 0)
    bucket.nextSequence = bucket.nextSequence + 1
    WorkerPool.ack(result.gen, result.stream, chunk.sequence)
    return
  end
  state.threaded[result.gen] = nil
  if result.kind == "cancelled" then
    metrics.cancelledJobs = metrics.cancelledJobs + 1
    releaseMap(entry.job.id, state.game)
    return
  end
  if result.error then
    fallbackThreaded(entry, "worker: " .. tostring(result.error))
    return
  end
  if result.kind == "complete" then
    local function packed(prefix)
      local terrain = entry.chunks[prefix .. ".terrain"]
                         or { chunks = {}, n = 0, m = 0 }
      local water = entry.chunks[prefix .. ".water"]
                       or { chunks = {}, n = 0, m = 0 }
      return { terrain = terrain, water = water,
               aux = result.data and result.data.aux }
    end
    if entry.pair then
      result.data = { body = packed("body"), ring = packed("ring"),
                      aux = result.data and result.data.aux }
    else
      result.data = packed("single")
    end
  end
  local map = entry.map
  local jobs = { entry.job }
  if entry.pair then jobs[#jobs + 1] = entry.pair end
  local payloads
  if entry.pair then
    payloads = { result.data and result.data.body,
                 result.data and result.data.ring }
  else
    payloads = { result.data }
  end
  for i, job in ipairs(jobs) do
    local payload = payloads[i]
    if payload then payload.aux = result.data.aux end
    if not saveThreadedSlot(map, job, payload) then
      fallbackThreaded(entry, MeshCache.saveError()
        or "worker payload verification failed")
      return
    end
    state.completed[tostring(job.id) .. "/" .. tostring(job.slot)] =
      MeshCache.jobRecord(map, job.slot)
    state.done = state.done + 1
    Diagnostics.trace("prebuild %d/%d done %s/%s (worker)", state.done,
                      state.total, tostring(job.id), tostring(job.slot))
  end
  progressTick()
  releaseMap(entry.job.id, state.game)
  WorkerPool.forgetMap(entry.job.id)
  local elapsed = state.startedAt and now()
  if elapsed and state.startedAt and state.done > 0 then
    state.eta = (elapsed - state.startedAt) * (state.total - state.done)
             / state.done
  end
  if state.done >= state.total then finish(false) end
end

-- WorkerPool can observe a thread exit before any result reaches its output
-- channel. Rewind the earliest stranded entry so every submitted job returns
-- through the serial resolver; otherwise state.index has already advanced
-- past it and the build can finish without ever committing that job.
local function recoverDeadWorkers()
  local first, firstIndex = nil, #state.maps + 1
  for _, entry in pairs(state.threaded) do
    for i, candidate in ipairs(state.maps) do
      if candidate == entry.job
         or (candidate.id == entry.job.id
             and candidate.slot == entry.job.slot) then
        if i < firstIndex then
          first, firstIndex = entry, i
        end
        break
      end
    end
  end
  if not first then return false end
  fallbackThreaded(first, "worker exited unexpectedly")
  return true
end

-- Dispatch the next frontier job to the pool. The map loads here, on the
-- update tick -- the same single blocking load the serial path's pumped
-- job performs -- then the data tables are dumped once per map and the
-- geometry phase runs off-main. Returns true when a job was dispatched.
local function dispatchThreaded(covered)
  local job = state.maps[state.index]
  if not job then return false end
  local nextJob = state.maps[state.index + 1]
  local pair = nil
  if job.slot == "body" and nextJob
     and nextJob.id == job.id and nextJob.slot == "ring"
     and not state.completed[tostring(job.id) .. "/body"]
     and not state.completed[tostring(job.id) .. "/ring"] then
    pair = nextJob
  end
  local data = state.game and state.game.data
  local t0 = love and love.timer and love.timer.getTime
            and love.timer.getTime() or 0
  local map = loadPrebuildMap(data, job.id, state.game)
  local loadMs = (love and love.timer and love.timer.getTime
                 and (love.timer.getTime() - t0) * 1000) or 0
  metrics.mainThreadMapLoadMs = metrics.mainThreadMapLoadMs + loadMs
  if not map then
    state.failedJobs = (state.failedJobs or 0) + 1
    Diagnostics.error("prebuild job failed (%d/%d): map load failed -- %s/%s",
                      state.failedJobs, state.total, tostring(job.id),
                      tostring(job.slot))
    local count = pair and 2 or 1
    state.done = state.done + count
    state.index = state.index + count
    return true
  end
  if loadMs > 250 then
    Diagnostics.warn("prebuild map load overshot: %s %.0fms",
                     tostring(job.id), loadMs)
  end
  local okTR, TileRenderer = pcall(require, "src.render.TileRenderer")
  local voidFill = (okTR and TileRenderer and TileRenderer.voidFill)
                   or "trees"
  local okSer, mapSrc = pcall(WorkerPool.serializeMap, map)
  if not okSer then
    -- a map the dump cannot represent (a cyclic engine field past the
    -- renderer): the serial pump builds the same geometry from the live
    -- object, so report and let update() drop the pool and fall back
    Diagnostics.error("map dump failed for %s: %s", tostring(job.id),
                      tostring(mapSrc))
    return false
  end
  local gen = WorkerPool.submit({
    version = MeshCache.GEOMETRY_VERSION,
    mapSrc = mapSrc,
    mapId = job.id,
    variant = job.slot,
    pair = pair ~= nil,
    masks = job.masks,
    voidFill = tostring(voidFill),
    tilePath = map.tileset and map.tileset.image,
    imageWidth = map.tileset and map.tileset.imageWidth,
    imageHeight = map.tileset and map.tileset.imageHeight,
    geometryProfile = GeometryProfile.capture(Structures),
  })
  if not gen then return false end
  state.threaded[gen] = { job = job, pair = pair, map = map, at = now(),
                          chunks = {} }
  state.index = state.index + (pair and 2 or 1)
  if pair then WorkerPool.forgetMap(job.id) end
  return true
end

-- The shared mesh queue, pumped with the prebuild's OWN slice budget
-- while a build runs (BUG-2a). main.lua's live pump calls this too: the
-- queue is shared, and the live pump would otherwise slurp prebuild jobs
-- at the full covered slice right after this tick's tighter pump. A
-- plain pass-through when no build is running. Returns the pump wall
-- time in ms (nil when no clock is available).
function Prebuild.pump(covered)
  local idle, coveredSlice = ChunkMesher.IDLE_SLICE, ChunkMesher.COVERED_SLICE
  if state.running then
    if idle and idle > PREBUILD_IDLE_SLICE then
      ChunkMesher.IDLE_SLICE = PREBUILD_IDLE_SLICE
    end
    if coveredSlice and coveredSlice > PREBUILD_COVERED_SLICE then
      ChunkMesher.COVERED_SLICE = PREBUILD_COVERED_SLICE
    end
  end
  local t0 = now()
  local ok, err = pcall(ChunkMesher.pump, covered)
  local t1 = now()
  ChunkMesher.IDLE_SLICE, ChunkMesher.COVERED_SLICE = idle, coveredSlice
  if not ok then error(err, 0) end
  if t0 and t1 then return (t1 - t0) * 1000 end
  return nil
end

-- Advance the deferred resume scan a little (BUG-2b): the survivor
-- records are read a few jobs per tick, time-capped -- cold-flash meta
-- reads run ~1-2ms each, so a whole-set pass is the 1.5s freeze -- until
-- the whole set is covered. Returns true when the scan finished on this
-- call.
local function scanStep(covered)
  local scan = state.scan
  if not scan then return true end
  local jobs = scan.jobs
  local budget = covered and SCAN_COVERED_MS or SCAN_IDLE_MS
  local t0 = now()
  local scanned = 0
  while scan.index <= #jobs and scanned < SCAN_MAX_JOBS do
    local t = now()
    if t and scanned > 0 and t - t0 >= budget then break end
    local okS, records = pcall(MeshCache.scanComplete, { jobs[scan.index] })
    if okS and records then
      for key, record in pairs(records) do scan.records[key] = record end
    end
    scan.index = scan.index + 1
    scanned = scanned + 1
  end
  if state.running then state.done = countKeys(scan.records) end
  if scan.index > #jobs then
    state.completed = scan.records
    state.scan = nil
    return true
  end
  return false
end

-- The resume scan just finished: adopt the resume set. A running build
-- skips straight to the first job the scan found missing -- only the
-- missing jobs rebuild, exactly like the synchronous scan did -- and a
-- build that starts later reads state.completed as before.
local function adoptScan()
  local records = state.completed or {}
  state.done = countKeys(records)
  if not state.running then return end
  state.maps = Prebuild.pendingJobs(state.maps, records)
  state.index = 1
end

function Prebuild.update(covered)
  -- The deferred resume scan advances every frame, running or not: the
  -- gate's prompt and a build that starts mid-scan never block on the
  -- cold-flash survivor scan.
  if state.scan then
    if scanStep(covered) then adoptScan() end
    if state.scan then return end   -- dispatch waits for the resume set
  end
  if not state.running then return end
  if state.cancelled then finish(true); return end
  -- BUG-2a: after a pump overshot its slice, yield this tick to gameplay
  -- (the paused job resumes on the next pump) instead of compounding the
  -- freeze with another full slice.
  if pumpPause > 0 then
    pumpPause = pumpPause - 1
    return
  end

  if WorkerPool.working() then
    -- Threaded mode: dispatch up to the pool's depth and drain results;
    -- the serial pump is not used while workers are alive. A worker that
    -- died mid-job strands its generation -- after 60s of silence the
    -- pool is declared failed and the remainder falls back to the serial
    -- path below (the stranded job was never written, so the resume set
    -- picks it up next boot).
    for _, res in ipairs(WorkerPool.poll()) do
      finishThreaded(res)
    end
    if not WorkerPool.working() and recoverDeadWorkers() then
      return
    end
    local poolSize = WorkerPool.workerCount()
    -- One dispatch per tick (BUG-2a): every dispatch blocks on a
    -- MapLoader.load (hundreds of ms on cold flash), and a tick that
    -- filled the whole pool was poolSize loads in ONE frame -- the field
    -- logs' STALL lines. The workers keep the geometry fed; the main
    -- thread feeds them one map a frame.
    local dispatched = 0
    local t0d = now()
    while state.running
      and not state.cancelled
      and state.index <= #state.maps
      and dispatched < 1
      and WorkerPool.inFlight() < poolSize do
      if not dispatchThreaded(covered) then
        -- nothing dispatched (version mismatch, dead pool): drop the
        -- pool so the serial pump below takes over the remainder
        WorkerPool.shutdown()
        break
      end
      dispatched = dispatched + 1
    end
    local t1d = now()
    local dispatchMs = t0d and t1d and ((t1d - t0d) * 1000) or 0
    if dispatchMs > 250 then
      -- a map load froze this tick (cold flash): the next tick belongs
      -- to the game, not another load
      pumpPause = 1
    end
    if state.index > #state.maps and WorkerPool.inFlight() == 0 then
      finish(false)
      return
    end
    local stalled = WorkerPool.stalled and WorkerPool.stalled(60) or {}
    if #stalled > 0 then
      local stuck = stalled[1]
      local entry = state.threaded[stuck]
      if entry then
        Diagnostics.error("geometry worker heartbeat timeout gen=%s: "
                         .. "falling back to serial", tostring(stuck))
        fallbackThreaded(entry, "heartbeat timeout")
      end
    end
    if not WorkerPool.working() and state.index <= #state.maps
       and not state.cancelled then
      -- fall through to the serial pump below for the remainder
    else
      return
    end
  end

  if WorkerPool.cpuOnlyPrebuild and WorkerPool.cpuOnlyPrebuild() then
    updateCpuOnly(covered)
    return
  end

  local job = state.maps[state.index]
  if not job then finish(false); return end
  if not state.slot then
    -- The map loads INSIDE the pumped job coroutine (ChunkMesher owns the
    -- build now): a slow engine load is measured and warned like any other
    -- slice overshoot instead of freezing the frame unaccounted, and the
    -- completed job is still reachable through MapLoader.cached for the
    -- verification below.
    local data = state.game and state.game.data
    state.slot = true
    ChunkMesher.requestMapId(job.id, job.slot, job.masks,
                             false, true, function()
      return loadPrebuildMap(data, job.id, state.game)
    end)
  end
  -- Prebuild runs alongside normal gameplay; the covered flag (menus,
  -- warps, the title screen, the loading canvas) opens the wider pump
  -- slice -- nothing visible can hitch there, and fills run faster.
  -- BUG-2a: the pump runs under the prebuild's OWN (tighter) budget --
  -- see Prebuild.pump -- and a resume that blows it pauses the NEXT
  -- tick so the freeze does not compound.
  local pumpMs = Prebuild.pump(covered) or 0
  if pumpMs > metrics.worstFrameMs then metrics.worstFrameMs = pumpMs end
  local sliceMs = covered and PREBUILD_COVERED_SLICE or PREBUILD_IDLE_SLICE
  if pumpMs > sliceMs * 1000 * 4 then
    pumpPause = 1
    Diagnostics.warn("prebuild pump overshot: %.0fms vs %.0fms slice; "
                     .. "pausing next tick", pumpMs, sliceMs * 1000)
    return
  end
  local jobStatus = ChunkMesher.jobStatus(job.id, job.slot)
  if jobStatus == "pending" then return end
  local slotMap = cachedPrebuildMap(job.id)
  if jobStatus ~= "complete" or not slotMap
     or not MeshCache.verifyJob(slotMap, job.slot) then
    -- A single bad job must not abort the whole build: record it, release
    -- the map, and move on. writeProgress has already left a manifest
    -- naming every job that survived, so the next boot's resume set
    -- retries exactly this job -- the ones around it are NOT rebuilt from
    -- scratch (this was a full rebuild every boot when one aux save
    -- failed). Only an epidemic aborts: a platform-wide storage failure is
    -- better reported as FAILED than ground through job by job.
    state.failedJobs = (state.failedJobs or 0) + 1
    local maxFailures = math.max(4, math.floor(state.total / 10))
    local reason = jobStatus or MeshCache.saveError()
      or "cache verification failed"
    Diagnostics.error("prebuild job failed (%d/%d): %s -- %s/%s",
                      state.failedJobs, state.total, tostring(reason),
                      tostring(job.id), tostring(job.slot))
    if state.failedJobs > maxFailures then
      state.failed = true
      state.error = ("%d jobs failed"):format(state.failedJobs)
      finish(false)
      return
    end
    releaseMap(job.id, state.game)
    state.done = state.done + 1
    state.index = state.index + 1
    state.slot = nil
    if state.done >= state.total then finish(false) end
    return
  end
  state.completed[tostring(job.id) .. "/" .. tostring(job.slot)] =
    MeshCache.jobRecord(slotMap, job.slot)
  -- Update the manifest per completed job (F3): an interrupted build now
  -- leaves a manifest naming exactly the jobs whose files survived, so
  -- the next boot resumes instead of prompting forever. Writing it on
  -- EVERY job costs a full manifest encode + storage write per job --
  -- O(n^2) bytes on slow flash, measured as the prebuild's biggest fixed
  -- overhead -- so it is throttled: every 8 jobs or every 5 seconds,
  -- plus always on finish/cancel (writeManifest).
  progressTick()
  releaseMap(job.id, state.game)
  state.done = state.done + 1
  state.index = state.index + 1
  state.slot = nil
  Diagnostics.trace("prebuild %d/%d done %s/%s", state.done, state.total,
                    tostring(job.id), tostring(job.slot))
  local elapsed = state.startedAt and now()
  if elapsed and state.startedAt and state.done > 0 then
    state.eta = (elapsed - state.startedAt) * (state.total - state.done) / state.done
  end
  if state.done >= state.total then finish(false) end
end

function Prebuild.status()
  if state.running then
    return "BUILD " .. ("%d/%d"):format(
      state.done, state.total)
  end
  if state.ready and MeshCache.isDirty() then state.ready = false end
  if not Prebuild.available() then return "UNAVAILABLE" end
  if state.failed then return "FAILED" end
  if state.ready then return "READY" end
  if state.cancelled then return "CANCELLED" end
  return "PREBUILD"
end

function Prebuild.progress()
  return state.done, state.total, state.running, state.eta
end

function Prebuild.metrics()
  local out = {}
  for key, value in pairs(metrics) do out[key] = value end
  out.maxChunkVertices = Prebuild.MAX_CHUNK_VERTICES
  out.maxChunkIndices = Prebuild.MAX_CHUNK_INDICES
  out.maxInFlightChunks = Prebuild.MAX_IN_FLIGHT_CHUNKS
  return out
end

function Prebuild.isReady()
  return state.ready and not MeshCache.isDirty()
end

-- BUG-1 pre-warm: the FIRST map's body mesh primes from the cache before
-- the pipeline's first full scene render (main.lua calls this ahead of
-- the first prefetch). Priming the BODY slot ahead of it leaves the first
-- scene drawing its essential mesh from memory while the ring delta can
-- hydrate separately. One-shot, and conservative by
-- contract: a running prebuild owns the cache, and a map with no
-- payloads has nothing to prime -- it never builds fresh (that would
-- just move the freeze).
function Prebuild.primeFirst(map)
  if primed or state.running then return false end
  if not (map and map.id and map.tileset) then return false end
  primed = true
  if not MeshCache.available() then return false end
  local okP, terrain = pcall(MeshCache.loadTerrain, map, "body")
  if not okP or not terrain then return false end
  local okG, mesh = pcall(ChunkMesher.get, map, true, nil)
  Diagnostics.note("pre-warm: primed %s/body%s", tostring(map.id),
                   okG and mesh and "" or " (payloads present, no mesh)")
  return okG
end

-- Test seams for the worker-result path (the suite cannot start threads):
-- _applyWorkerResult drives the poll loop's finishThreaded with an
-- explicit in-flight entry (production registers entries at dispatch);
-- _workerFailures exposes the counter the seam's assertions read.
function Prebuild._applyWorkerResult(result, entry)
  state.threaded[result.gen] = entry or state.threaded[result.gen]
  finishThreaded(result)
end

function Prebuild._workerFailures()
  return state.failedJobs or 0
end

return Prebuild
