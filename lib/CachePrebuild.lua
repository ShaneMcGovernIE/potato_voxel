-- Cooperative all-map mesh-cache prebuilder.
-- Keeps only one runtime map resident while ChunkMesher's normal sliced queue
-- does the actual body/full/aux work and writes terrain, water, and aux files.
local V = ...
local Prebuild = {}

local ChunkMesher = V.require("ChunkMesher")
local MeshCache = V.require("MeshCache")

-- Use the engine's own placement routine so prebuilt FULL masks cover the same
-- connected strips (including two-hop neighbours) as the live renderer.
local OverworldState = require("src.world.OverworldController")

local state = { running = false, cancelled = false, maps = {}, index = 0,
                slot = nil, done = 0, total = 0, game = nil,
                startedAt = nil, eta = nil, ready = false,
                failed = false, error = nil, completed = {} }

local function sortedIds(maps)
  local ids = {}
  for id, def in pairs(maps or {}) do
    if type(def) == "table" and def.width and def.height then
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
  -- The live renderer asks for two connection hops.  Keep that contract here
  -- rather than reimplementing placement (and drifting when the engine does).
  local neighbours = OverworldState.computeNeighbors(maps, id, 2)
  for _, neighbour in ipairs(neighbours or {}) do
    local other = maps[neighbour.id]
    if other then
      out[#out + 1] = {
        neighbour.ox, neighbour.oy,
        neighbour.ox + other.width * 32,
        neighbour.oy + other.height * 32,
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
    jobs[#jobs + 1] = { id = id, slot = "full", masks = masks }
  end
  return jobs
end
Prebuild.masksFor = masksFor

function Prebuild.available()
  return MeshCache.available()
end

function Prebuild.bootstrap(game)
  local data = game and game.data
  MeshCache.configure(data)
  local jobs = Prebuild.enumerate(data and data.maps)
  local ready, done = MeshCache.ready(jobs)
  -- Not READY is no longer "start from zero": a build interrupted
  -- mid-session (F3) left complete atomic payloads behind, and a rescan
  -- of the actual files recovers exactly which jobs survived. Those
  -- become the resume set -- start() skips them and only the missing
  -- remainder gets rebuilt.
  local completed = {}
  if not ready then completed, done = MeshCache.scanComplete(jobs) end
  state = { running = false, cancelled = false, maps = jobs, index = 0,
            slot = nil, done = ready and #jobs or done, total = #jobs,
            game = nil, startedAt = nil, eta = nil, ready = ready,
            failed = false, error = nil, completed = completed }
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

-- Never tear down an instance the overworld can still draw.  The options
-- action may outlive the menu that started it (and the player can move while
-- it runs), so the live set has to be checked at the moment a job completes,
-- not only when prebuild starts.
local function liveMaps(game)
  local live = {}
  local overworld = game and (game.overworld or game)
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
  -- the module table is gone (sandbox): the loader is reached the
  -- supported way.
  local okLoader, MapLoader = pcall(require, "src.world.MapLoader")
  if not okLoader then MapLoader = nil end
  local m = MapLoader and MapLoader.evict and MapLoader.cached(id)
  if m and MapLoader.evict then MapLoader.evict(id) end
  return true
end

local function finish(cancelled)
  if state.index > 0 and state.maps[state.index] then
    releaseMap(state.maps[state.index].id, state.game)
  end
  if not cancelled and not state.failed and state.done >= state.total then
    state.ready = MeshCache.writeManifest(state.completed, state.total)
    if not state.ready then
      state.failed = true
      state.error = MeshCache.saveError() or "manifest write failed"
    else
      local okD, Overlay = pcall(V.require, "DebugOverlay")
      if okD and Overlay then
        local secs = state.startedAt and
          (love and love.timer and love.timer.getTime
           and love.timer.getTime() - state.startedAt) or 0
        local rate = secs and secs > 0 and (state.total / secs) or 0
        Overlay.trace("prebuild finished READY in %.1fs (%.1f jobs/s)",
                     secs, rate)
      end
    end
  end
  state.running, state.cancelled = false, cancelled or false
  state.slot = nil
  state.game = nil
  state.eta = nil
end

local function now()
  local timer = love and love.timer
  if timer and timer.getTime then
    local ok, value = pcall(timer.getTime)
    if ok and type(value) == "number" then return value end
  end
  return nil
end

-- The old android() OS probe is gone with the sandbox: the one use was
-- a shortened progress label, which now reads the same everywhere.

Prebuild.isAndroid = android

function Prebuild.start(game)
  if state.running then
    state.cancelled = true
    return false
  end
  local data = game and game.data
  local jobs = Prebuild.enumerate(data and data.maps)
  if #jobs == 0 or not MeshCache.available() then return false end
  MeshCache.begin()
  -- RESUME (F3): jobs the boot scan found complete are skipped, so a
  -- prebuild interrupted mid-session finishes the remainder instead of
  -- rebuilding everything from zero. A fresh build (empty completed)
  -- starts at the first job as before.
  local completed = state.completed or {}
  local index = 1
  for i, job in ipairs(jobs) do
    local key = tostring(job.id) .. "/" .. tostring(job.slot)
    if not completed[key] then index = i; break end
    index = i + 1
  end
  state = { running = true, cancelled = false, maps = jobs, index = index,
            slot = nil, done = index - 1, total = #jobs, game = game,
            startedAt = now(), eta = nil, ready = false,
            failed = false, error = nil, completed = completed }
  local okD, Overlay = pcall(V.require, "DebugOverlay")
  if okD and Overlay then
    Overlay.trace("prebuild start: %d/%d done, %d jobs",
                 index - 1, #jobs, #jobs)
  end
  return true
end

function Prebuild.cancel()
  if state.running then state.cancelled = true; return true end
  return false
end

function Prebuild.wipe(game)
  if state.running then return false end
  local data = game and game.data
  local jobs = Prebuild.enumerate(data and data.maps)
  local ok = MeshCache.wipe(jobs)
  if ok then
    ChunkMesher.invalidate()
    state.ready, state.cancelled, state.failed = false, false, false
    state.done, state.total, state.error = 0, #jobs, nil
    state.completed = {}
  end
  return ok
end

local function countKeys(table_)
  local count = 0
  for _ in pairs(table_ or {}) do count = count + 1 end
  return count
end

-- Re-evaluate readiness against the live identity and files, and update
-- the resume set. Called after the engine applies a save's real options
-- (CONTINUE's restoreSave / NEW GAME's onNewGame): the game.ready-time
-- check ran under the skeleton save's defaults, and a player's VOID FILL
-- choice would otherwise read as a stale cache on every launch (F1).
function Prebuild.refresh(game)
  if state.running then return end
  local data = game and game.data
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
    local completed = MeshCache.scanComplete(jobs)
    state.completed = completed
    state.done = countKeys(completed)
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

function Prebuild.update()
  if not state.running then return end
  if state.cancelled then finish(true); return end
  local job = state.maps[state.index]
  if not job then finish(false); return end
  if not state.slot then
    local MapLoader = require("src.world.MapLoader")
    local map = MapLoader.load(state.game.data, job.id)
    state.slot = map
    ChunkMesher.request(map, job.slot == "body", job.masks, false, true)
  end
  -- Prebuild runs alongside normal gameplay; use the ordinary cooperative
  -- slice rather than the 30ms covered/menu budget.
  ChunkMesher.pump(false)
  local bodyOnly = job.slot == "body"
  local jobStatus = ChunkMesher.jobStatus(job.id, bodyOnly)
  if jobStatus == "pending" then return end
  if jobStatus ~= "complete" or not MeshCache.verifyJob(state.slot, job.slot) then
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
    local okD, Overlay = pcall(V.require, "DebugOverlay")
    if okD and Overlay then
      Overlay.error("prebuild job failed (%d/%d): %s -- %s/%s",
                    state.failedJobs, state.total, tostring(reason),
                    tostring(job.id), tostring(job.slot))
    end
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
    MeshCache.jobRecord(state.slot, job.slot)
  -- Update the manifest per completed job (F3): an interrupted build now
  -- leaves a manifest naming exactly the jobs whose files survived, so
  -- the next boot resumes instead of prompting forever.
  MeshCache.writeProgress(state.completed, state.total)
  releaseMap(job.id, state.game)
  state.done = state.done + 1
  state.index = state.index + 1
  state.slot = nil
  local okD, Overlay = pcall(V.require, "DebugOverlay")
  if okD and Overlay then
    Overlay.trace("prebuild %d/%d done %s/%s", state.done, state.total,
                 tostring(job.id), tostring(job.slot))
  end
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

function Prebuild.isReady()
  return state.ready and not MeshCache.isDirty()
end

return Prebuild
