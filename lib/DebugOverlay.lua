-- DebugOverlay: a realtime activity/error/perf panel for this sandbox
-- build. It records from boot; F9 only toggles panel visibility. F10
-- switches verbosity (ALL vs important-only).
--
-- Everything event-shaped funnels through trace() (noise) or note()
-- (important): mesh job completions and failures (with durations), cache
-- saves and loads (with decode ms), the prebuild state machine, setting
-- changes, the mod's event handlers, the periodic frame/render stats
-- line, and any thrown error the pipeline tick catches.
--
-- Lessons learned, built in:
--   1. A boot-time self-lint scans every shipped module for the
--      forward-local bug class (a function called before its `local
--      function` declaration reads a nil GLOBAL -- this class shipped
--      twice during the migration) and warns with file:line.
--   2. Severity levels: trace() lines collapse in important-only mode,
--      so a healthy session is quiet and a broken one is legible.
--   3. Session counters + a summary (jobs, hits, slow loads, errors,
--      worst frame) written on toggle-off and into the stored log.
--   4. A data-only health snapshot names the pipeline decision, capability
--      reason, last world path, renderer, storage and session counters.
--   5. The first boot lines are preserved separately from the recent ring,
--      so a long cache build cannot evict the original failure.
--
-- The panel draws through render.hud over every screen; lines go to the
-- console and, when scoped storage is reachable, to the bytes key
-- "debug/log". Repeated identical messages collapse to "xN"; storage
-- writes throttle to once a second. DELIBERATELY TEMPORARY -- removed
-- before the 1.6.1 release.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Overlay = {}

local MAX_LINES = 20
local lines = {}         -- the on-screen ring buffer
local log = {}           -- the recent deduped line ring
local bootLog = {}       -- first boot lines, kept even after the ring rolls
local LOG_KEEP = 600
local BOOT_KEEP = 128
local running = true     -- capture starts at boot, even while hidden
local visible = false    -- F9 only changes panel visibility
local verbose = true     -- F10: true = all lines, false = important only
local game = nil
local probe = nil
local lastPersist = 0
local lastErrorPersist = 0
local lastMsg = nil
local lastCount = 0
local sessionId = os.date("%Y%m%d-%H%M%S")

-- frame/render aggregation, emitted every STATS_EVERY seconds
local STATS_EVERY = 5
local statsFrames = 0
local statsTime = 0
local statsMax = 0
local statsRender = 0
local statsLast = 0

-- session counters, folded into the summary
local counters = { jobs = 0, jobFails = 0, cacheHits = 0, slowLoads = 0,
                   errors = 0, storageFails = 0 }
local worstFrame = 0

-- This is deliberately data-only: it can be written through mod.storage's
-- table surface and exported without exposing a Canvas, shader or game object.
local health = {
  frame = 0,
  session = sessionId,
  startedAt = os.date("%Y-%m-%dT%H:%M:%S"),
  pipeline = {
    id = "voxel", level = 0, updateCalls = 0, drawWorldCalls = 0,
    rendered = 0, fallbacks = 0, loading = 0, noState = 0,
    unavailable = 0, availability = nil, reason = nil,
    detail = {}, lastPath = "never", lastPathFrame = 0,
    lastAvailabilityFrame = 0,
  },
  capabilities = {},
  renderer = {},
  storage = { writes = 0, failures = 0, available = nil },
  probe = { ok = nil },
  lastEvent = nil,
  lastError = nil,
}

local function clock()
  local timer = love and love.timer
  if timer and timer.getTime then
    local ok, v = pcall(timer.getTime)
    if ok and type(v) == "number" then return v end
  end
  return os.clock()
end

function Overlay.durationMs(t0)
  return math.floor(((clock() - (t0 or clock())) * 1000) + 0.5)
end

local function stamp(msg)
  return os.date("%H:%M:%S") .. "." .. string.format("%03d",
         math.floor(((clock() % 1) * 1000))) .. " " .. msg
end

local function dataCopy(value, depth)
  if depth and depth > 4 then return tostring(value) end
  if type(value) ~= "table" then
    if type(value) == "number" or type(value) == "string"
       or type(value) == "boolean" then
      return value
    end
    return tostring(value)
  end
  local out = {}
  for key, item in pairs(value) do
    local keyType = type(key)
    if keyType == "string" or keyType == "number" then
      out[key] = dataCopy(item, (depth or 0) + 1)
    end
  end
  return out
end

local function snapshot()
  return {
    schema = 2,
    session = sessionId,
    startedAt = health.startedAt,
    frame = health.frame,
    pipeline = dataCopy(health.pipeline),
    capabilities = dataCopy(health.capabilities),
    renderer = dataCopy(health.renderer),
    storage = dataCopy(health.storage),
    probe = dataCopy(health.probe),
    lastEvent = dataCopy(health.lastEvent),
    lastError = dataCopy(health.lastError),
    lastPhase = health.lastPhase,
    counters = dataCopy(counters),
    worstFrame = worstFrame,
  }
end

local function logText()
  local out = {}
  if #bootLog > 0 then
    out[#out + 1] = "-- boot evidence (first lines) --"
    for _, line in ipairs(bootLog) do out[#out + 1] = line end
  end
  if #log > 0 then
    out[#out + 1] = "-- recent evidence (ring) --"
    for _, line in ipairs(log) do out[#out + 1] = line end
  end
  return table.concat(out, "\n")
end

-- Identity header for the remote payload.  The server's filename only
-- carries the client id, so without this a received log cannot be
-- attributed to an engine build, a mod version, or a session.
local function headerText()
  local mod = V.mod
  local manifest = mod and mod.manifest
  local ctx = health.storage.context or {}
  local lv = health.renderer and health.renderer.love
  local loveVer = lv and (tostring(lv.codename) .. " " .. tostring(lv.major)
    .. "." .. tostring(lv.minor)) or "?"
  return ("-- potato_voxel diagnostic send --\nmod: %s %s\nengine: %s\nlove: %s\nsession: %s\nframe: %s")
    :format(tostring(manifest and manifest.name or "potato_voxel"),
            tostring(manifest and manifest.version or "?"),
            tostring(ctx.engineVersion or "?"),
            loveVer, tostring(sessionId), tostring(health.frame))
end

-- Flat status excerpt.  The ring only covers what has happened since boot,
-- so a send made early in a session would otherwise carry no rendering,
-- prebuild, or cache evidence; the snapshot aggregates all of it.  The
-- playthroughId stays local: the upload adds no identifiers.
local function snapshotText()
  local out = {}
  local function kv(label, value)
    out[#out + 1] = label .. ": " .. tostring(value)
  end
  local c = counters
  kv("counters", ("jobs=%d errors=%d jobFails=%d cacheHits=%d slowLoads=%d storageFails=%d")
    :format(c.jobs, c.errors, c.jobFails, c.cacheHits, c.slowLoads, c.storageFails))
  local p = health.pipeline
  if p then
    kv("pipeline", ("availability=%s reason=%s level=%s rendered=%d path=%s")
      :format(tostring(p.availability), tostring(p.reason), tostring(p.level),
              p.rendered or 0, tostring(p.lastPath)))
    if p.lastPathDetail then
      kv("lastRender", ("renderMs=%s frame=%s")
        :format(tostring(p.lastPathDetail.renderMs), tostring(p.lastPathFrame)))
    end
  end
  local v = health.capabilities and health.capabilities.voxel
  if v then
    kv("voxel", ("available=%s reason=%s")
      :format(tostring(v.available), tostring(v.reason)))
  end
  local pr = health.probe and health.probe.result
  if pr then
    if pr.shadows then
      kv("shadows", ("available=%s reason=%s resolution=%s")
        :format(tostring(pr.shadows.available), tostring(pr.shadows.reason),
                tostring(pr.shadows.resolution)))
    end
    if pr.cache then
      kv("cache", ("identity=%s saveFailures=%d")
        :format(tostring(pr.cache.identity or "?"), pr.cache.saveFailures or 0))
    end
    if pr.prebuild then
      kv("prebuild", ("status=%s %s/%s")
        :format(tostring(pr.prebuild.status), tostring(pr.prebuild.done),
                tostring(pr.prebuild.total)))
    end
  end
  kv("worstFrame", worstFrame)
  local st = health.storage
  if st then
    kv("storage", ("state=%s writes=%d failures=%d")
      :format(tostring(st.state), st.writes or 0, st.failures or 0))
  end
  return table.concat(out, "\n")
end

local function managerLog(kind, msg)
  local mod = V.mod
  local logger = mod and mod.log
  local fn = logger and logger[kind]
  if fn then pcall(fn, logger, "%s", msg) end
end

local function storageFailure(op, code, message)
  local detail = tostring(code or message or "unknown")
  if message and code then detail = detail .. ": " .. tostring(message) end
  health.storage.available = false
  health.storage.state = tostring(code or "unavailable")
  health.storage.failures = (health.storage.failures or 0) + 1
  health.storage.lastError = op .. " " .. detail
  -- These are normal before a save is selected or while the title facade is
  -- not bound to a playthrough. Keep the state in the snapshot, but do not
  -- report expected lifecycle unavailability as a storage fault.
  if code == "not_in_playthrough" or code == "not_at_title" then
    health.storage.failures = health.storage.failures - 1
    health.storage.expectedUnavailable =
      (health.storage.expectedUnavailable or 0) + 1
    return
  end
  counters.storageFails = counters.storageFails + 1
  -- Do not call Overlay.error here: persistence is called by emit(), and
  -- recursively logging a storage failure would create a write loop.
  pcall(print, "[pv-debug] storage " .. health.storage.lastError)
end

local function storageWrite(store, method, key, value)
  local fn = store and store[method]
  if not fn then return false, "unsupported", method .. " unavailable" end
  local ok, result, code, message = pcall(fn, store, game, key, value)
  if not ok then return false, "exception", tostring(result) end
  if result == false or result == nil then
    return false, code or "write_failed", message
  end
  return true
end

local function persist(force)
  local c = clock()
  if not force and (c - lastPersist) < 1 then return end
  lastPersist = c
  local mod = V.mod
  if not (mod and mod.storage) then return end
  local store = mod.storage
  if mod.storage.selected then
    local okS, selected, code, message =
      pcall(mod.storage.selected, mod.storage, game)
    if okS and selected then
      store = selected
    elseif not okS or selected == false then
      storageFailure("selected", code or "exception", message or selected)
    end
  end
  if not store then
    storageFailure("resolve", "storage_unavailable")
    return
  end
  local context = store.context
  if context then
    local okC, value = pcall(context, store, game)
    if okC and type(value) == "table" then
      health.storage.context = dataCopy(value)
      health.storage.available = true
    end
  end
  local wrote, code, message
  if store.writeBytes then
    wrote, code, message = storageWrite(store, "writeBytes", "debug/log", logText())
  else
    wrote, code, message = storageWrite(store, "write", "debug/log", logText())
  end
  if not wrote then
    storageFailure("debug/log", code, message)
  else
    health.storage.writes = (health.storage.writes or 0) + 1
    health.storage.available = true
  end
  if store.write then
    local statusOk, statusCode, statusMessage =
      storageWrite(store, "write", "debug/status", snapshot())
    if not statusOk then storageFailure("debug/status", statusCode, statusMessage) end
  end
end

local function append(line)
  lines[#lines + 1] = line
  if #lines > MAX_LINES then table.remove(lines, 1) end
  if #bootLog < BOOT_KEEP then bootLog[#bootLog + 1] = line end
  log[#log + 1] = line
  if #log > LOG_KEEP then
    for i = 1, #log - (LOG_KEEP / 2) do table.remove(log, 1) end
  end
end

-- Error lines are the support-report artifact: the throttled persist would
-- otherwise lose up to a second of them on an abrupt exit. Force the write
-- on the first error, then only again after a quiet gap -- a flood of
-- errors must not become a per-line fs write loop.
local function persistFor(kind)
  local force = kind == "error"
  if force then
    local c = clock()
    if (c - lastErrorPersist) < 0.25 then force = false end
    if force then lastErrorPersist = c end
  end
  persist(force)
end

local function emit(msg, kind)
  -- Count every error occurrence, including deduped repeats: the summary's
  -- "N errors" must match how many errors actually happened.
  if kind == "error" then
    counters.errors = counters.errors + 1
    health.lastError = {
      message = msg,
      frame = health.frame,
      at = os.date("%Y-%m-%dT%H:%M:%S"),
    }
    managerLog("error", msg)
  end
  if msg == lastMsg then
    lastCount = lastCount + 1
    local line = stamp(msg .. (" (x%d)"):format(lastCount))
    lines[#lines] = line
    log[#log] = line
    persistFor(kind)
    return
  end
  lastMsg, lastCount = msg, 1
  local line = stamp(msg)
  append(line)
  pcall(print, "[pv-debug] " .. line)
  persistFor(kind)
end

-- Important: always shown and stored.
function Overlay.note(fmt, ...)
  local ok, msg = pcall(string.format, fmt, ...)
  if not ok then msg = tostring(fmt) .. " " .. tostring(msg) end
  emit(msg, "note")
end

-- Noise: shown in verbose mode, collapsed in important-only mode (still
-- stored -- the stored log is the support-report artifact).
function Overlay.trace(fmt, ...)
  local ok, msg = pcall(string.format, fmt, ...)
  if not ok then msg = tostring(fmt) .. " " .. tostring(msg) end
  emit(msg, "trace")
end

-- An error that should never be silenced: recorded and counted whether or
-- not the panel is up -- a support log must not depend on F9 being on when
-- the failure happened.
function Overlay.error(fmt, ...)
  local ok, msg = pcall(string.format, fmt, ...)
  if not ok then msg = tostring(fmt) .. " " .. tostring(msg) end
  emit(msg, "error")
end

-- Public, data-only support snapshot. Callers can serialize this through the
-- table storage API without ever touching a live game or GPU object.
function Overlay.status()
  return snapshot()
end

function Overlay.bindGame(value)
  if value ~= nil then game = value end
  health.storage.gameBound = game ~= nil
end

function Overlay.setProbe(fn)
  probe = type(fn) == "function" and fn or nil
end

function Overlay.runProbe()
  if not probe then
    health.probe = { ok = true, skipped = true }
    return dataCopy(health.probe)
  end
  local results = { xpcall(probe, function(e) return e end) }
  if not results[1] then
    health.probe = { ok = false, error = tostring(results[2]) }
    Overlay.error("capability probe failed: %s", tostring(results[2]))
    return dataCopy(health.probe)
  end
  health.probe = { ok = true, result = dataCopy(results[2]) }
  Overlay.note("capability probe complete")
  return dataCopy(health.probe)
end

-- Record the engine-visible pipeline heartbeat. The engine's private broken
-- flag is not exposed by the mod API, so these counters deliberately describe
-- the observable boundary: update ran, availability answered, and drawWorld
-- entered or returned a particular path.
function Overlay.pipelineUpdate(level)
  local p = health.pipeline
  p.level = tonumber(level) or 0
  p.updateCalls = p.updateCalls + 1
end

function Overlay.pipelineAvailable(ok, reason, detail)
  local p = health.pipeline
  local available = ok == true
  local normalized = reason or (available and "ready" or "unknown")
  local changed = p.availability ~= available or p.reason ~= normalized
  p.availability = available
  p.reason = normalized
  p.detail = dataCopy(detail or {})
  p.lastAvailabilityFrame = health.frame
  health.capabilities.voxel = dataCopy(detail or {})
  if changed then
    Overlay.note("pipeline voxel available=%s reason=%s",
                 tostring(available), tostring(normalized))
  end
end

function Overlay.pipelinePath(path, detail)
  local p = health.pipeline
  path = tostring(path or "unknown")
  p.lastPath = path
  p.lastPathFrame = health.frame
  if path == "entered" then p.drawWorldCalls = p.drawWorldCalls + 1 end
  if path == "rendered" then p.rendered = p.rendered + 1 end
  if path == "fallback" then p.fallbacks = p.fallbacks + 1 end
  if path == "loading" then p.loading = p.loading + 1 end
  if path == "no_state" then p.noState = p.noState + 1 end
  if path == "unavailable" then p.unavailable = p.unavailable + 1 end
  if detail then p.lastPathDetail = dataCopy(detail) end
end

function Overlay.event(name, detail)
  health.lastEvent = { name = tostring(name), detail = dataCopy(detail or {}),
                       frame = health.frame }
end

-- Session counters feed the summary and run from boot with the background
-- recorder. Panel visibility must not change the support report.
function Overlay.count(name)
  counters[name] = (counters[name] or 0) + 1
end

-- `enabled` is retained as the public visibility query used by the input
-- bridge; it no longer controls collection.
function Overlay.enabled()
  return visible
end

function Overlay.running()
  return running
end

-- Toggle panel visibility on F9 (and the SELECT hold chord). Boundary lines
-- always land in the background log and the console; hiding does not clear
-- the ring buffer, so reopening shows what happened while it was hidden.
function Overlay.toggle()
  Overlay.setVisible(not visible)
end

-- The DEBUGGER option row and the mod manager's page land on the same
-- flag as F9: an explicit show/hide that records the same boundary line.
function Overlay.setVisible(show)
  show = show and true or false
  if visible == show then return end
  visible = show
  if not visible then Overlay.summary() end
  local line = "debugger " .. (visible and "VISIBLE" or "HIDDEN")
  append(stamp(line))
  pcall(print, "[pv-debug] " .. stamp(line))
  persist(true)
end

-- Current panel state, for a caller that wants to stay in step with F9.
function Overlay.visible()
  return visible
end

-- F10: verbose <-> important-only.
function Overlay.toggleVerbose()
  verbose = not verbose
  Overlay.note("verbosity %s", verbose and "ALL" or "IMPORTANT")
end

-- F8's loghook companion: ship the stored evidence to the manifest-declared
-- log_url, one-way.  Engine feature #1363 (mod.postLog); silently no-ops on
-- engines without it or without a log_url.  Fire-and-forget: the job is
-- polled once on the next frame and released when it settles, so a hung
-- endpoint never accumulates in the worker pool.
local sendHandle = nil
local sendAt = 0   -- wall clock when the current send was submitted

function Overlay.sendLogs()
  local mod = V.mod
  if not (mod and type(mod.postLog) == "function") then return false end
  if not (mod.manifest and mod.manifest.log_url) then return false end
  -- Identity header + the persisted-evidence text + the aggregate status
  -- excerpt, then the explicit-send session summary.  The engine's
  -- postLog ceiling is 512 KiB since engine PR #1382 (64 KiB before), and
  -- a long session's ring can exceed either, so the evidence text is
  -- trimmed -- newest lines kept -- to a budget that always leaves room
  -- for the header, excerpt and summary.
  local function buildBody(budget)
    local body = headerText()
    local text = logText()
    if text ~= "" then
      budget = budget - #body - 3000
      if #text > budget then
        local kept = {}
        local size = 0
        for line in text:gmatch("[^\n]+") do
          kept[#kept + 1] = line
          size = size + #line + 1
        end
        local drop = 0
        while size > budget and drop < #kept - 1 do
          drop = drop + 1
          size = size - #kept[drop] - 1
        end
        local out = {}
        for i = drop + 1, #kept do out[#out + 1] = kept[i] end
        text = table.concat(out, "\n")
        Overlay.trace("log send: trimmed %d evidence lines to fit the engine ceiling", drop)
      end
      body = body .. "\n" .. text
    end
    body = body .. "\n-- status excerpt --\n" .. snapshotText()
    body = body .. "\n" .. stamp("session: " .. tostring(counters.jobs)
      .. " jobs, " .. tostring(counters.errors) .. " errors")
    return body
  end
  -- The engine rejects a send by returning nil plus a REASON (too large,
  -- too many in flight, bad URL...); pcall forwards both returns, so the
  -- reason is captured and shown instead of reading as a bare nil.
  local body = buildBody(400000)
  local ok, handle, reason = pcall(mod.postLog, mod, body, { format = "text" })
  if not ok or not handle and reason and reason:find("too large") then
    -- An engine without PR #1382 caps at 64 KiB: retry once with the
    -- conservative budget before reporting a failure.
    Overlay.trace("log send: payload too large for this engine; retrying trimmed")
    body = buildBody(48000)
    ok, handle, reason = pcall(mod.postLog, mod, body, { format = "text" })
  end
  if not ok or not handle then
    Overlay.note("log send failed: %s",
      tostring(handle or reason or "engine rejected the send"))
    return false
  end
  sendHandle = handle
  sendAt = clock()
  Overlay.note("log sent to loghook")
  return true
end

-- F8: export. Force the storage flush so the on-disk debug/log is
-- current, dump every line to the console in one block (terminal users
-- can copy it straight out), and stamp the boundary. Works even while
-- the debugger is toggled off -- exporting is the retrieval action.
function Overlay.export()
  Overlay.runProbe()
  persist(true)
  Overlay.sendLogs()
  pcall(print, "[pv-log] ---- boot evidence (" .. #bootLog .. " lines) ----")
  for _, line in ipairs(bootLog) do
    pcall(print, "[pv-log] " .. line)
  end
  pcall(print, "[pv-log] ---- recent evidence (" .. #log .. " lines) ----")
  for _, line in ipairs(log) do
    pcall(print, "[pv-log] " .. line)
  end
  local current = snapshot()
  pcall(print, "[pv-status] session=" .. tostring(current.session)
             .. " frame=" .. tostring(current.frame)
             .. " pipeline=" .. tostring(current.pipeline.availability)
             .. " reason=" .. tostring(current.pipeline.reason)
             .. " updates=" .. tostring(current.pipeline.updateCalls)
             .. " draws=" .. tostring(current.pipeline.drawWorldCalls)
             .. " rendered=" .. tostring(current.pipeline.rendered)
             .. " fallbacks=" .. tostring(current.pipeline.fallbacks))
  pcall(print, "[pv-log] ---- end ----")
  local line = stamp("log exported: " .. (#bootLog + #log)
                     .. " lines + status -> storage debug/log")
  append(line)
  pcall(print, "[pv-debug] " .. line)
  persist(true)
end

-- The session verdict, written into the stored log.
function Overlay.summary()
  local ok, msg = pcall(string.format,
    "session: %d jobs (%d failed), %d cache hits, %d slow loads, "
    .. "%d errors, %d storage fails, worst frame %.1fms",
    counters.jobs, counters.jobFails, counters.cacheHits,
    counters.slowLoads, counters.errors, counters.storageFails,
    worstFrame)
  if not ok then msg = "session summary unavailable" end
  local line = stamp(msg)
  append(line)
  pcall(print, "[pv-debug] " .. line)
  persist(true)
end

-- Feed the voxel tick every frame.
function Overlay.frame(dt, renderMs)
  if sendHandle and V.mod and V.mod.fetch
      and type(V.mod.fetch.poll) == "function" then
    local ok, st = pcall(V.mod.fetch.poll, V.mod.fetch, sendHandle)
    if ok and st and st.status ~= "pending" then
      -- The job settled.  The engine worker does not report through the
      -- send notice, so surface its result here: a failure is important
      -- (stored in the support log and shown), a success is a trace.
      if st.status == "ok" then
        Overlay.trace("log send confirmed")
      else
        Overlay.note("log send failed: %s", tostring(st.err or st.status))
      end
      pcall(V.mod.fetch.release, V.mod.fetch, sendHandle)
      sendHandle = nil
    elseif ok and clock() - sendAt > 40 then
      -- A worker that hangs (e.g. a stuck process spawn) leaves the job
      -- pending forever; every further F8 then trips the engine's
      -- 4-in-flight ceiling ("log send failed: nil").  Cancel and drop the
      -- handle so the next send starts clean.
      Overlay.note("log send timed out after %ds; cancelling",
                   math.floor(clock() - sendAt))
      pcall(V.mod.fetch.cancel, V.mod.fetch, sendHandle)
      pcall(V.mod.fetch.release, V.mod.fetch, sendHandle)
      sendHandle = nil
    elseif not ok then
      Overlay.note("log send poll failed: %s", tostring(st))
      pcall(V.mod.fetch.release, V.mod.fetch, sendHandle)
      sendHandle = nil
    end
  end
  health.frame = health.frame + 1
  local frameMs = (dt or 0) * 1000
  if frameMs > worstFrame then worstFrame = frameMs end
  statsFrames = statsFrames + 1
  statsTime = statsTime + frameMs
  if renderMs and renderMs > statsMax then statsMax = renderMs end
  if frameMs > statsMax then statsMax = frameMs end
  statsRender = statsRender + (renderMs or 0)
  local now = clock()
  if now - statsLast >= STATS_EVERY and statsFrames > 0 then
    statsLast = now
    local avg = statsTime / statsFrames
    local renderAvg = statsRender / statsFrames
    local gpu = ""
    if love and love.graphics and love.graphics.getStats then
      local okS, st = pcall(love.graphics.getStats)
      if okS and st then
        gpu = (" draws=%d sw=%d texMB=%.1f")
          :format(st.drawcalls or 0, st.canvasswitches or 0,
                  (st.texturememory or 0) / 1048576)
      end
    end
    local p = health.pipeline
    Overlay.trace("frame avg %.1fms max %.1fms render avg %.1fms%s%s "
                  .. "pipeline avail=%s reason=%s updates=%d draws=%d path=%s",
                  avg, statsMax, renderAvg, gpu,
                  statsMax > 40 and " [HITCH]" or "",
                  tostring(p.availability), tostring(p.reason),
                  p.updateCalls, p.drawWorldCalls, tostring(p.lastPath))
    statsFrames, statsTime, statsMax, statsRender = 0, 0, 0, 0
  end
end

function Overlay.try(label, fn, ...)
  health.lastPhase = tostring(label)
  local results = { xpcall(fn, function(e) return e end, ...) }
  if not results[1] then
    Overlay.error("ERROR %s: %s", label, tostring(results[2]))
  end
  return results[1], results[2]
end

-- ------- boot self-lint: the forward-local bug class
--
-- This class shipped TWICE during the migration (a closure calling a
-- function whose `local function` declaration comes later in the chunk
-- reads a nil GLOBAL on LuaJIT). Scan every shipped module once at boot
-- and name any hit: for each `local function NAME` declaration, any
-- earlier `NAME(` call outside comments/strings is a hit.

local function lintSource(name, src)
  if not src then return end
  local declared = {}
  for line in (src .. "\n"):gmatch("(.-)\n") do
    local fn = line:match("^%s*local%s+function%s+([%w_]+)")
    if fn then declared[fn] = #declared + 1 end
  end
  local stripped = src:gsub("%[%[(.-)%]%]", function(s)
    return s:gsub("[^\n]", " ")
  end)
  local linenum = 0
  for line in (stripped .. "\n"):gmatch("(.-)\n") do
    linenum = linenum + 1
    line = line:gsub('"[^"]*"', '""'):gsub("'[^']*'", "''")
    line = line:gsub("%-%-[^\n]*", " ")
    for fn in pairs(declared) do
      if line:find("%f[%w_]" .. fn .. "%s*%(") then
        local declLine = nil
        local scan, n = 1, 0
        for dline in (src .. "\n"):gmatch("(.-)\n") do
          scan = scan + 1
          if dline:match("^%s*local%s+function%s+" .. fn .. "%s*%(") then
            n = n + 1
            if n == declared[fn] then declLine = scan; break end
          end
        end
        if declLine and declLine > linenum then
          Overlay.error("FWD-LOCAL %s:%d calls %s (declared %d)",
                        name, linenum, fn, declLine)
        end
      end
    end
  end
end

function Overlay.lint(mod, moduleNames)
  Overlay.trace("self-lint: scanning %d modules", 1 + #moduleNames)
  local okM, mainSrc = pcall(mod.read, mod, "main.lua")
  if okM then lintSource("main.lua", mainSrc) end
  for _, name in ipairs(moduleNames) do
    local ok, src = pcall(mod.read, mod, "lib/" .. name .. ".lua")
    if ok then lintSource("lib/" .. name .. ".lua", src) end
  end
end

function Overlay.draw()
  if not visible or #lines == 0 then return end
  local g = love.graphics
  if not g then return end
  local prevFont, okF = pcall(g.getFont)
  local prevColor = { g.getColor() }
  pcall(g.setFont, nil)
  local lineH = 11
  local shown = {}
  for _, line in ipairs(lines) do
    if verbose or line:find(" ERROR ") or line:find("FWD%-LOCAL")
       or line:find("mesh job failed") or line:find("SLOW load")
       or line:find("storage ") or line:find("prebuild job failed")
       or line:find("pipeline voxel") or line:find("capability probe") then
      shown[#shown + 1] = line
    end
  end
  if #shown == 0 then return end
  g.setColor(0, 0, 0, 0.62)
  g.rectangle("fill", 2, 2, 520, lineH * #shown + 6)
  g.setColor(1, 1, 1, 1)
  for i, line in ipairs(shown) do
    g.print(line, 6, 4 + (i - 1) * lineH)
  end
  if okF then pcall(g.setFont, prevFont) end
  g.setColor(prevColor[1], prevColor[2], prevColor[3], prevColor[4])
end

function Overlay.captureEnvironment()
  local g = love and love.graphics
  local out = {}
  if love and love.getVersion then
    local ok, major, minor, revision, codename = pcall(love.getVersion)
    if ok then
      out.love = { major = major, minor = minor, revision = revision,
                   codename = codename }
    end
  end
  if g then
    if g.getRendererInfo then
      local ok, info = pcall(g.getRendererInfo)
      if ok and type(info) == "table" then out.renderer = dataCopy(info) end
    end
    if g.getDimensions then
      local ok, w, h = pcall(g.getDimensions)
      if ok then out.dimensions = { w = w, h = h } end
    end
    if g.getPixelDimensions then
      local ok, w, h = pcall(g.getPixelDimensions)
      if ok then out.pixelDimensions = { w = w, h = h } end
    end
    if g.getSupported then
      local ok, caps = pcall(g.getSupported)
      if ok then out.supported = dataCopy(caps) end
    end
    if g.getSystemLimits then
      local ok, limits = pcall(g.getSystemLimits)
      if ok then out.systemLimits = dataCopy(limits) end
    end
  end
  health.renderer = out
  return dataCopy(out)
end

function Overlay.install()
  if Overlay.installed then return end
  Overlay.installed = true
  local mod = V.mod
  if not (mod and mod.hooks) then return end
  Overlay.captureEnvironment()
  mod.hooks:wrap("render.hud", function(next, g, viewport)
    next(g, viewport)
    Overlay.bindGame(g)
    Overlay.draw()
  end)
  Overlay.note("debugger running in background -- F9 shows/hides, F10 verbosity")
end

-- The DEBUGGER option: the same visibility flag as F9, reachable from the
-- VOXEL SETTINGS screen and the mod manager's page (Android has no F9 key,
-- and its SELECT hold chord is gated off mobile).  Values { false, true }
-- make the manager's schema a toggle.  main.lua's always-running tick
-- applies it, re-asserting only when the stored value changes so it never
-- fights a manual F9 toggle.
local ModSetting = V.require("ModSetting")
Overlay.setting = ModSetting.new("debugger", "DEBUGGER", { false, true },
                                 { "OFF", "ON" })

return Overlay
