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

local PlayerId = V.require("PlayerId")
local DiagnosticsStore = V.require("DiagnosticsStore")
local DiagnosticsEnvironment = V.require("DiagnosticsEnvironment")

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

-- The VOXEL SETTINGS summary, provided by main.lua (it owns the rows and
-- the live options API): one space-separated `key=label` line so a
-- received log shows exactly the rung and knobs the session ran with.
-- Read live at send time through the same paths the rows read, so the
-- excerpt can never disagree with what the menu showed.
local settingsReader = nil
function Overlay.setSettingsReader(fn)
  settingsReader = type(fn) == "function" and fn or nil
end

local function settingsLine()
  if not settingsReader then return nil end
  local ok, got = pcall(settingsReader)
  if not ok or type(got) ~= "string" or got == "" then return nil end
  return got
end

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

-- Deep enough for the full probe result (shadows.depth.failures[*] is
-- five levels down); deep data is still bounded, so a pathological table
-- cannot recurse forever.
local DATA_COPY_MAX_DEPTH = 8

local function dataCopy(value, depth)
  if depth and depth > DATA_COPY_MAX_DEPTH then return tostring(value) end
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

local diagnostics = DiagnosticsStore.new({
  sessionId = sessionId,
  dataCopy = dataCopy,
})
local health = diagnostics.health
local counters = diagnostics.counters

local Environment = DiagnosticsEnvironment.new({
  health = health,
  dataCopy = dataCopy,
})

local function snapshot()
  return diagnostics.snapshot({
    platform = health.platform or Environment.platformName(),
    settings = settingsLine(),
  })
end

local function logText()
  return diagnostics.logText()
end

-- Platform slug for the remote filename/folder: the send's
-- <platform>-<engine>-<mod>-<DD_MM_YYYY> name and the server's per-platform
-- subfolder both key off it.  Kept stable and folder-safe (lowercase
-- letters only) so the server never has to sanitise a free-text platform.
Overlay._platformSlug = function()
  return Environment.platformSlug()
end

-- The organized JSON document the send carries (schema 3).  Top-level
-- identity fields let the server name and sort the file without parsing
-- log lines; boot evidence ships once per session; the ring is a delta
-- (only lines newer than the last acked send); status is the structured
-- snapshot, not a flat text excerpt.
local function jsonPayload()
  local id = Environment.identityFields()
  local out = {
    schema = 3,
    session = tostring(diagnostics.sessionId),
    frame = health.frame,
    platform = id.platform,
    engine = id.engine,
    mod = id.mod,
    love = id.love,
    gpu = id.gpu,
    date = os.date("%d_%m_%Y"),
  }
  -- the per-install support token: random, persisted in OPTIONS, visible
  -- in the debugger; it only identifies a player once they share it
  -- (PlayerId). Omitted entirely when the store could not be read.
  local pid = PlayerId.get()
  if pid then out.playerId = pid end
  if not diagnostics.bootSent and #diagnostics.bootLog > 0 then
    out.boot = {}
    for _, line in ipairs(diagnostics.bootLog) do out.boot[#out.boot + 1] = line end
  end
  local ring = diagnostics.ringDelta()
  if ring then
    out.ring = ring
  end
  out.status = snapshot()
  return out
end

-- The engine's link-protocol JSON encoder (data-only tables, arrays,
-- strings, numbers, booleans, null).  Resolved once at first send.
local Json = nil
local function jsonEncode(v)
  if Json == nil then
    local ok, mod = pcall(require, "src.link.Json")
    Json = ok and mod and mod.encode or false
  end
  return Json and Json(v) or nil
end

-- The structured status object ships inside the JSON payload (the
-- server stores the organized document as-is).  The ring only covers
-- what has happened since boot, so a send made early in a session would
-- otherwise carry no rendering, prebuild, or cache evidence; the
-- snapshot aggregates all of it.  The playthroughId stays local.  The
-- one identifier the upload carries is playerId, the player-facing
-- 8-digit support token (PlayerId): random per install, visible in the
-- debugger, and unlinkable to any player who has not shared it.

local function managerLog(kind, msg)
  local mod = V.mod
  local logger = mod and mod.log
  local fn = logger and logger[kind]
  if fn then pcall(fn, logger, "%s", msg) end
end

local function storageFailure(op, code, message, key)
  local detail = tostring(code or message or "unknown")
  if message and code then detail = detail .. ": " .. tostring(message) end
  health.storage.available = false
  health.storage.state = tostring(code or "unavailable")
  health.storage.failures = (health.storage.failures or 0) + 1
  -- The key is the first thing a support log needs when the state is
  -- invalid_key: it names WHICH write the engine refused.
  health.storage.lastError = op .. " " .. detail
    .. (key and (" (key=" .. tostring(key) .. ")") or "")
  -- These are normal before a save is selected or while the title facade is
  -- not bound to a playthrough. Keep the state in the snapshot, but do not
  -- report expected lifecycle unavailability as a storage fault.
  if code == "not_in_playthrough" or code == "not_at_title" then
    health.storage.failures = health.storage.failures - 1
    health.storage.expectedUnavailable =
      (health.storage.expectedUnavailable or 0) + 1
    return
  end
  diagnostics.count("storageFails")
  -- Do not call Overlay.error here: persistence is called by emit(), and
  -- recursively logging a storage failure would create a write loop.
  pcall(print, "[pv-debug] storage " .. health.storage.lastError)
end

-- Write through the MOD's storage API (mod.storage), never through a
-- Storage:selected facade: the two have different call shapes.  The
-- facade's write is function(_, key, value) with the game captured, so
-- passing (store, game, key, value) as a colon-style call shifts the game
-- into the KEY slot and every write fails validKey -> invalid_key.  The
-- mod wrapper (function(_, game, key, value)) is the documented mod API
-- and the one MeshCache already uses.
local function storageWrite(store, method, key, value)
  local fn = store and store[method]
  if not fn then return false, "unsupported", method .. " unavailable" end
  local ok, result, code, message = pcall(fn, store, game, key, value)
  if not ok then return false, "exception", tostring(result), key end
  if result == false or result == nil then
    return false, code or "write_failed", message, key
  end
  return true
end

-- A storage write this slow means the platform's flash (Switch) makes the
-- support log stutter the very game it diagnoses: after such a write,
-- non-forced persists back off until the returned expiry. Errors and
-- exports still force through -- losing crash evidence is worse than one
-- slow write. Exposed for the headless suite; returns seconds or nil.
local SLOW_WRITE_MS = 25
local slowUntil = 0

function Overlay.slowStorageBackoff(elapsedMs)
  if not elapsedMs or elapsedMs < SLOW_WRITE_MS then return nil end
  return math.max(30, math.min(300, elapsedMs / 1000 * 30))
end

local function persist(force)
  local c = clock()
  if not force then
    -- The 5s sample cadence would persist ~once per window; on flash
    -- that is a ~100ms hitch every window. Skip until the backoff from
    -- the last slow write expires (errors/exports bypass via force).
    if c < slowUntil then return end
    if (c - lastPersist) < 1 then return end
  end
  lastPersist = c
  local mod = V.mod
  if not (mod and mod.storage) then return end
  -- Use the MOD's own storage wrapper (mod.storage), never the
  -- Storage:selected facade: the two have different call shapes (see
  -- storageWrite). The wrapper resolves the playthrough scope from the
  -- live game exactly as MeshCache's primary path does.
  local store = mod.storage
  if not store then
    storageFailure("resolve", "storage_unavailable")
    return
  end
  local t0 = clock()
  local context = store.context
  if context then
    local okC, value = pcall(context, store, game)
    if okC and type(value) == "table" then
      health.storage.context = dataCopy(value)
      health.storage.available = true
    end
  end
  local wrote, code, message, key
  if store.writeBytes then
    wrote, code, message, key = storageWrite(store, "writeBytes", "debug/log", logText())
  else
    wrote, code, message, key = storageWrite(store, "write", "debug/log", logText())
  end
  local okAll = wrote
  if not wrote then
    storageFailure("debug/log", code, message, key or "debug/log")
  else
    health.storage.writes = (health.storage.writes or 0) + 1
    health.storage.available = true
  end
  if store.write then
    local statusOk, statusCode, statusMessage, statusKey =
      storageWrite(store, "write", "debug/status", snapshot())
    if not statusOk then
      okAll = false
      storageFailure("debug/status", statusCode, statusMessage, statusKey or "debug/status")
    end
  end
  -- A successful write clears the previous failure state: without this,
  -- the boot's expected not_in_playthrough failures stayed in every
  -- session's final status snapshot, reading as broken storage even
  -- though the log wrote fine all session.
  if okAll then
    health.storage.state = "ok"
    health.storage.lastError = nil
  end
  -- Slow flash (Switch): stretch the non-forced cadence so the support
  -- log cannot keep stuttering every 5s window for the whole session.
  local backoff = Overlay.slowStorageBackoff((clock() - t0) * 1000)
  if backoff then slowUntil = clock() + backoff end
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
    diagnostics.count("errors")
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
    diagnostics.replaceLatest(line)
    persistFor(kind)
    return
  end
  lastMsg, lastCount = msg, 1
  local line = stamp(msg)
  diagnostics.append(line)
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

-- A warning: shown and stored like a note, but deliberately NOT counted
-- as an error.  Slow cache loads and similar performance canaries used to
-- route through Overlay.error, which made counters.errors equal
-- counters.slowLoads in every session -- a support log could not tell a
-- real failure from a slow-but-successful load.  Warnings keep the ring
-- line and the stored log, but only the dedicated counter moves.
function Overlay.warn(fmt, ...)
  local ok, msg = pcall(string.format, fmt, ...)
  if not ok then msg = tostring(fmt) .. " " .. tostring(msg) end
  emit(msg, "warn")
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
    -- Carry the compile error text when a driver refuses the shader:
    -- the plain note ("reason=scene_shader_compile") names the failure
    -- class but not the GLSL line a Mali support log needs.
    local why = (not available and detail and detail.error)
      and (" -- " .. tostring(detail.error)) or ""
    Overlay.note("pipeline voxel available=%s reason=%s%s",
                 tostring(available), tostring(normalized), why)
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

-- Per-job mesh-build totals, pushed by the pump when a job finishes. The
-- resume gap is the freeze evidence: a gap far past its slice is a build
-- step the cooperative budget does not cover, and the support log must
-- name the job so the region can be found.
function Overlay.buildDone(id, slot, slices, maxGapMs, overshoots)
  local b = health.build
  b.jobs = b.jobs + 1
  b.slices = b.slices + (slices or 0)
  b.overshoots = b.overshoots + (overshoots or 0)
  if (maxGapMs or 0) > b.worstResumeMs then
    b.worstResumeMs = maxGapMs
    b.worstResumeJob = tostring(id) .. "/" .. tostring(slot)
  end
end

-- Session counters feed the summary and run from boot with the background
-- recorder. Panel visibility must not change the support report.
function Overlay.count(name)
  diagnostics.count(name)
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
  diagnostics.append(stamp(line))
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
  -- The organized JSON document (schema 3): identity fields at the top
  -- (the server names and sorts the file from them), boot evidence once
  -- per session, a ring DELTA (only lines newer than the last acked
  -- send), and the structured status snapshot.  The engine's postLog
  -- ceiling is 512 KiB since engine PR #1382 (64 KiB before); a delta is
  -- normally <2 KiB, and the first send of a session (boot + full ring)
  -- still fits the conservative budget.  If the engine rejects the JSON
  -- as too large, retry once with boot omitted and the ring capped.
  local function buildBody(slim)
    local payload = jsonPayload()
    if slim then
      payload.boot = nil
      if payload.ring and #payload.ring > 200 then
        local kept = {}
        for i = #payload.ring - 199, #payload.ring do
          kept[#kept + 1] = payload.ring[i]
        end
        payload.ring = kept
      end
    end
    local body = jsonEncode(payload)
    if not body then
      Overlay.note("log send failed: JSON encoder unavailable")
      return nil
    end
    return body
  end
  local body = buildBody(false)
  if not body then return false end
  -- The engine rejects a send by returning nil plus a REASON (too large,
  -- too many in flight, bad URL...); pcall forwards both returns, so the
  -- reason is captured and shown instead of reading as a bare nil.
  local ok, handle, reason = pcall(mod.postLog, mod, body, { format = "text" })
  if not ok or not handle and reason and reason:find("too large") then
    -- An engine without PR #1382 caps at 64 KiB: retry once with the
    -- conservative budget before reporting a failure.
    Overlay.trace("log send: payload too large for this engine; retrying trimmed")
    body = buildBody(true)
    if not body then return false end
    ok, handle, reason = pcall(mod.postLog, mod, body, { format = "text" })
  end
  if not ok or not handle then
    Overlay.note("log send failed: %s",
      tostring(handle or reason or "engine rejected the send"))
    return false
  end
  -- Acknowledged: advance the delta watermark so the next send carries
  -- only newer lines.  On a failed send the watermark stays put, so the
  -- next send retries the same delta (at-least-once, same as today).
  -- The watermark is captured AFTER the confirmation note below appends
  -- its own ring line, so the send's self-lines are never re-sent and
  -- the idle gate (seq == lastSentSeq) can actually trip once the send
  -- settles; the poll half advances it again past its confirmation trace.
  diagnostics.bootSent = true
  sendHandle = handle
  sendAt = clock()
  Overlay.note("log sent to loghook")
  diagnostics.lastSentSeq = diagnostics.seq
  return true
end

-- ------- log-send opt-out
--
-- F8, the SEND LOGS row and the START chord all ship the stored evidence
-- to the manifest's log_url -- the ONE action that leaves the device.
-- Sending is ON by default: the send_logs option (LOGS TO DEV, ON by
-- default) gates every send, and the frame tick sends automatically on
-- its own schedule (see autoSendEvery below). Turning the row OFF stops
-- all sends immediately and permanently -- there is no prompt to ask
-- and nothing to decline. Engines or manifests without a log_url never
-- send: there is no endpoint.

-- Whether this engine can send at all: engine feature #1363 (mod.postLog)
-- plus a manifest log_url. The gate only exists where a send would
-- actually happen, so a local-only export never sends.
function Overlay.canSend()
  local mod = V.mod
  return not not (mod and type(mod.postLog) == "function"
                  and mod.manifest and mod.manifest.log_url)
end

-- Whether the player has opted out. Read live through the options API
-- (ModSetting), the same store every other setting lives in, so the
-- row, the manager's page and this gate all see the same value.
function Overlay.sendingAllowed()
  return Overlay.sendSetting:get() ~= false
end

-- F8: export. Force the storage flush so the on-disk debug/log is
-- current, dump every line to the console in one block (terminal users
-- can copy it straight out), and stamp the boundary. Works even while
-- the debugger is toggled off -- exporting is the retrieval action.
--
-- The send half respects LOGS TO DEV: ON ships, OFF notes and skips
-- while the local dump still happens. A local-only engine (no endpoint)
-- just dumps, exactly as before.
function Overlay.export(g)
  g = g or game
  Overlay.runProbe()
  persist(true)
  if Overlay.canSend() then
    if Overlay.sendingAllowed() then
      Overlay.sendLogs()
    else
      Overlay.note("log send disabled (LOGS TO DEV OFF)")
    end
  end
  pcall(print, "[pv-log] ---- boot evidence (" .. #diagnostics.bootLog .. " lines) ----")
  for _, line in ipairs(diagnostics.bootLog) do
    pcall(print, "[pv-log] " .. line)
  end
  pcall(print, "[pv-log] ---- recent evidence (" .. #diagnostics.log .. " lines) ----")
  for _, line in ipairs(diagnostics.log) do
    pcall(print, "[pv-log] " .. line)
  end
  local current = snapshot()
  local curGpu = current.renderer and current.renderer.renderer
  pcall(print, "[pv-status] platform=" .. tostring(current.platform)
             .. " gpu=" .. tostring(curGpu and curGpu.name or "?")
             .. " session=" .. tostring(current.session)
             .. " frame=" .. tostring(current.frame)
             .. " pipeline=" .. tostring(current.pipeline.availability)
             .. " reason=" .. tostring(current.pipeline.reason)
             .. " updates=" .. tostring(current.pipeline.updateCalls)
             .. " draws=" .. tostring(current.pipeline.drawWorldCalls)
             .. " rendered=" .. tostring(current.pipeline.rendered)
             .. " fallbacks=" .. tostring(current.pipeline.fallbacks))
  pcall(print, "[pv-log] ---- end ----")
  local line = stamp("log exported: " .. (#diagnostics.bootLog + #diagnostics.log)
                     .. " lines + status -> storage debug/log")
  diagnostics.append(line)
  pcall(print, "[pv-debug] " .. line)
  persist(true)
end

-- The session verdict, written into the stored log.
function Overlay.summary()
  local ok, msg = pcall(string.format,
    "session: %d jobs (%d failed), %d cache hits (%d misses), %d slow loads, "
    .. "%d errors, %d storage fails, worst frame %.1fms",
    counters.jobs, counters.jobFails, counters.cacheHits, counters.cacheMisses,
    counters.slowLoads, counters.errors, counters.storageFails,
    diagnostics.worstFrame)
  if not ok then msg = "session summary unavailable" end
  local line = stamp(msg)
  diagnostics.append(line)
  pcall(print, "[pv-debug] " .. line)
  persist(true)
end

-- Feed the voxel tick every frame.
--
-- The automatic send rides this tick: every autoSendEvery seconds of
-- accumulated GAME time (frame dt, not wall clock -- a paused game never
-- sends), the log ships on its own with no keypress. It is the same
-- opt-out default as every manual send: the send_logs gate, a send
-- already in flight, or an engine without an endpoint all skip it, and
-- the schedule is expressed as a next-deadline so a skipped interval
-- fires at the next opportunity rather than backing up.
--
-- Idle backoff: an auto-send only ships when the ring grew since the
-- last send (seq > lastSentSeq) or the boot evidence is still unsent.
-- A quiet session would otherwise POST an identical near-empty delta
-- every 90s forever (a field session logged 32 sends / 2.2MB of them).
-- The deadline still moves so the cadence cannot wedge, but only out to
-- IDLE_HEARTBEAT_EVERY seconds of game time past the last auto-send:
-- a fully idle session still ships a liveness heartbeat at most once
-- per five minutes.  Manual sends (F8, SEND LOGS, the START chord) are
-- deliberate and never throttled.
Overlay.autoSendEvery = 90
local autoSendElapsed = 0
local nextAutoAt = Overlay.autoSendEvery
local IDLE_HEARTBEAT_EVERY = 300
local lastAutoSendElapsed = 0   -- game time of the last auto-send (heartbeat cap anchor)

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
        diagnostics.lastSentSeq = diagnostics.seq
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
  if Overlay.canSend() and Overlay.sendingAllowed()
      and not sendHandle and autoSendElapsed >= nextAutoAt then
    if diagnostics.bootSent and diagnostics.seq == diagnostics.lastSentSeq
        and nextAutoAt < lastAutoSendElapsed + IDLE_HEARTBEAT_EVERY then
      -- Nothing new since the last send and the heartbeat window is
      -- still open: skip the identical-delta ship and push the deadline
      -- out, capped at IDLE_HEARTBEAT_EVERY seconds of game time past
      -- the last auto-send so an idle session still heartbeats.
      nextAutoAt = math.min(nextAutoAt + Overlay.autoSendEvery,
                            lastAutoSendElapsed + IDLE_HEARTBEAT_EVERY)
    else
      -- New ring lines, the first send of a session (the boot evidence
      -- only ships there), or the idle heartbeat window elapsed: ship.
      nextAutoAt = nextAutoAt + Overlay.autoSendEvery
      lastAutoSendElapsed = autoSendElapsed
      persist(true)
      Overlay.trace("auto-send: shipping log (%.0f s of game time)",
                    autoSendElapsed)
      Overlay.sendLogs()
    end
  end
  autoSendElapsed = autoSendElapsed + (dt or 0)
  health.frame = health.frame + 1
  local frameMs = (dt or 0) * 1000
  diagnostics.updateWorstFrame(frameMs)
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
        -- texMB only: getStats().drawcalls / canvasswitches are
        -- unpopulated on the engine's LOVE builds (field logs showed
        -- draws=0 sw=0 on every platform while rendering thousands of
        -- frames), so those fields were pure noise.
        gpu = (" texMB=%.1f"):format((st.texturememory or 0) / 1048576)
      end
    end
    local p = health.pipeline
    -- A frame this long is a stall worth explaining: tag it with the
    -- evidence that distinguishes a GPU driver freeze (texture memory
    -- collapsed or re-uploading -- the Raspberry Pi's ~55s 1fps crawl
    -- started exactly after texMB dropped 85.8 -> 25.4) from a mesh or
    -- storage hitch, so the next support log states its cause.  The
    -- driver identity and the shader-switch counter ride along: a
    -- compositor-side upload burst (the Deck's 34s crawl with texMB
    -- pinned flat) shows up in both.
    local stall = ""
    if statsMax > 500 then
      local tex = ""
      local shaderSw = ""
      if love and love.graphics and love.graphics.getStats then
        local okS, st = pcall(love.graphics.getStats)
        if okS and st then
          tex = (" texMB=%.1f"):format((st.texturememory or 0) / 1048576)
          -- Shader-compile witness: getStats().shaderswitches counts
          -- every switch since boot, and switching is when the driver
          -- compiles/uploads.  A stall window whose counter jumped since
          -- the previous one dates the burst; builds that leave the
          -- field unpopulated omit it, like drawcalls above.
          if type(st.shaderswitches) == "number" and st.shaderswitches > 0 then
            shaderSw = (" shaderSw=%d"):format(st.shaderswitches)
          end
        end
      end
      -- Driver identity, restated on the stall line: the boot evidence
      -- names the GPU once, but the received log is triaged by its STALL
      -- lines first, and the same crawl reads differently per driver (a
      -- Deck vangogh vs a Switch Tegra).  health.renderer carries the
      -- captureEnvironment normalise; absent (a love-less stub) omit.
      local ri = health.renderer and health.renderer.renderer
      local gpuId = ""
      if ri then
        local gpuName = (("%s %s %s %s"):format(
            tostring(ri.name or ""), tostring(ri.vendor or ""),
            tostring(ri.device or ""), tostring(ri.version or "")))
          :gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        if gpuName ~= "" then gpuId = " gpu=" .. gpuName end
      end
      local lastEvent = health.lastEvent
      local lastEventText = "none"
      if type(lastEvent) == "table" then
        lastEventText = tostring(lastEvent.mapId or lastEvent.name or lastEvent.kind or "?")
      elseif lastEvent ~= nil then
        lastEventText = tostring(lastEvent)
      end
      stall = (" [STALL>500ms %s %s path=%s level=%s lastEvent=%s]")
        :format(tostring(p.availability), tostring(p.reason),
                tostring(p.lastPath), tostring(p.level),
                lastEventText) .. tex .. shaderSw .. gpuId
    end
    Overlay.trace("frame avg %.1fms max %.1fms render avg %.1fms%s%s%s "
                  .. "pipeline avail=%s reason=%s updates=%d draws=%d path=%s",
                  avg, statsMax, renderAvg, gpu,
                  statsMax > 40 and " [HITCH]" or "",
                  stall,
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
  if not visible or #diagnostics.lines == 0 then return end
  local g = love.graphics
  if not g then return end
  local prevFont, okF = pcall(g.getFont)
  local prevColor = { g.getColor() }
  -- the hud pass can be running under a text-box SCISSOR or a UI BLEND
  -- (glow), and neither was restored -- a scissored panel reads as
  -- broken and a poisoned state breaks whatever draws next. Capture,
  -- clear, restore, the same discipline the font and colour keep.
  local okSc, sx, sy, sw, sh = pcall(g.getScissor)
  local prevScissor = okSc and sx and { sx, sy, sw, sh } or nil
  local okBl, prevBlend, prevBlendAlpha = pcall(g.getBlendMode)
  pcall(g.setFont, nil)
  pcall(g.setScissor)
  pcall(g.setBlendMode, "alpha", "alphamultiply")
  local lineH = 11
  local shown = {}
  -- the player-facing support id, always on top when the panel is open:
  -- this is the token a player reads out in a support chat so their logs
  -- can be found (PlayerId). Session id rides beside it for a quick
  -- match against the received file's name.
  local pid = PlayerId.get() or "--------"
  shown[#shown + 1] = ("id %s   session %s"):format(pid, tostring(sessionId))
  for _, line in ipairs(diagnostics.lines) do
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
  pcall(g.setScissor, prevScissor)
  pcall(g.setBlendMode, prevBlend, prevBlendAlpha)
end

Overlay.captureEnvironment = Environment.capture

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

-- The LOGS TO DEV toggle: sending is ON by default (opt-out) and the
-- row lives in VOXEL SETTINGS and on the mod manager's page, so the
-- player can turn it off there or anywhere else the schema lands.
-- Stored through the same options store as every other setting, so it
-- survives restarts and New Game, and read live at send time so a
-- manager-page write takes effect immediately.
Overlay.sendSetting = ModSetting.new("send_logs", "LOGS TO DEV",
                                     { true, false }, { "ON", "OFF" })

return Overlay
