-- DebugOverlay: an opt-in realtime activity/error/perf panel for this sandbox
-- build. It records only while DEBUGGER is ON; F9 toggles the debugger state.
-- F10 switches verbosity (ALL vs important-only).
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
--      worst frame) written into the stored log while active.
--   4. A data-only health snapshot names the pipeline decision, capability
--      reason, last world path, renderer, storage and session counters.
--   5. The first boot lines are preserved separately from the recent ring,
--      so a long cache build cannot evict the original failure.
--
-- The panel draws through render.hud over every screen; lines go to the
-- console and, when scoped storage is reachable, to the bytes key
-- "debug/log" while active. Repeated identical messages collapse to "xN";
-- storage writes throttle to once a second. Remote transport is manual-only:
-- SEND LOGS/F8/START are the explicit export paths.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Overlay = {}

local PlayerId = V.require("PlayerId")
local DiagnosticsStore = V.require("DiagnosticsStore")
local DiagnosticsEnvironment = V.require("DiagnosticsEnvironment")
local DiagnosticsTransport = V.require("DiagnosticsTransport")

local running = false    -- capture is opt-in; DEBUGGER starts OFF
local visible = false    -- active debugger state owns panel visibility
local exportCapture = false -- explicit SEND LOGS may capture one snapshot
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

local function captureActive()
  return running or exportCapture
end

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
  if not captureActive() then return end
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
  if not captureActive() then return end
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
  if not captureActive() then return dataCopy(health.probe) end
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
  if not captureActive() then return end
  local p = health.pipeline
  p.level = tonumber(level) or 0
  p.updateCalls = p.updateCalls + 1
end

function Overlay.pipelineAvailable(ok, reason, detail)
  if not captureActive() then return end
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
  if not captureActive() then return end
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
  if not captureActive() then return end
  health.lastEvent = { name = tostring(name), detail = dataCopy(detail or {}),
                       frame = health.frame }
end

-- Per-job mesh-build totals, pushed by the pump when a job finishes. The
-- resume gap is the freeze evidence: a gap far past its slice is a build
-- step the cooperative budget does not cover, and the support log must
-- name the job so the region can be found.
function Overlay.buildDone(id, slot, slices, maxGapMs, overshoots)
  if not captureActive() then return end
  local b = health.build
  b.jobs = b.jobs + 1
  b.slices = b.slices + (slices or 0)
  b.overshoots = b.overshoots + (overshoots or 0)
  if (maxGapMs or 0) > b.worstResumeMs then
    b.worstResumeMs = maxGapMs
    b.worstResumeJob = tostring(id) .. "/" .. tostring(slot)
  end
end

-- Session counters feed the summary while the debugger is active. Panel
-- visibility and capture always move together.
function Overlay.count(name)
  if not captureActive() then return end
  diagnostics.count(name)
end

-- `enabled` and `running` are retained as public state queries. They now
-- describe the same opt-in debugger state rather than separate visibility and
-- background-capture flags.
function Overlay.enabled()
  return running
end

function Overlay.running()
  return running
end

-- Toggle the debugger on F9 (and the SELECT hold chord). The hotkey mirrors
-- the DEBUGGER option and persists the choice when a game is available.
function Overlay.toggle(g)
  local show = not running
  Overlay.setEnabled(show, g)
  if Overlay.setting and g then Overlay.setting:setValue(show, g) end
end

-- The DEBUGGER option and the hotkey both land on this one state transition.
-- Enabling captures the environment at the moment the player opts in; it does
-- not collect any boot-time evidence while the debugger was OFF.
function Overlay.setEnabled(show, g)
  show = show and true or false
  if g ~= nil then game = g end
  if running == show and visible == show then return end
  running, visible = show, show
  -- A new capture window must not inherit dedupe, cadence, or storage
  -- backoff state from a previous window.
  lastMsg, lastCount = nil, 0
  lastPersist, lastErrorPersist, slowUntil = 0, 0, 0
  statsFrames, statsTime, statsMax, statsRender = 0, 0, 0, 0
  statsLast = clock()
  if running then
    Overlay.captureEnvironment()
    Overlay.note("debugger enabled -- F9 toggles, F10 verbosity")
  end
end

-- Backward-compatible name for callers that used the old visibility setter.
-- Visibility and capture now always move together.
function Overlay.setVisible(show)
  return Overlay.setEnabled(show)
end

-- Current panel state, for a caller that wants to stay in step with F9.
function Overlay.visible()
  return visible
end

-- F10: verbose <-> important-only.
function Overlay.toggleVerbose()
  if not running then return end
  verbose = not verbose
  Overlay.note("verbosity %s", verbose and "ALL" or "IMPORTANT")
end

local Transport = DiagnosticsTransport.new({
  store = diagnostics,
  environment = Environment,
  snapshot = snapshot,
  note = Overlay.note,
  trace = Overlay.trace,
  clock = clock,
})

local function sendLogs()
  return Transport.send()
end

-- F8's loghook companion: ship the stored evidence to the manifest-declared
-- log_url, one-way.  Engine feature #1363 (mod.postLog); silently no-ops on
-- engines without it or without a log_url.  Fire-and-forget: the job is
-- polled once on the next frame and released when it settles, so a hung
-- endpoint never accumulates in the worker pool.
-- ------- log-send opt-out
--
-- F8, the SEND LOGS row and the START chord are the only actions that ship
-- evidence to the manifest's log_url. Sending is ON by default: the send_logs
-- option (LOGS TO DEV) remains a second gate. There is no frame-tick upload.

-- Whether this engine can send at all: engine feature #1363 (mod.postLog)
-- plus a manifest log_url. The gate only exists where a send would
-- actually happen, so a local-only export never sends.
function Overlay.canSend()
  return Transport.canSend()
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
  if g ~= nil then Overlay.bindGame(g) end
  local priorExportCapture = exportCapture
  exportCapture = true
  local ok, err = xpcall(function()
    if not health.platform or not health.renderer then
      Overlay.captureEnvironment()
    end
    Overlay.runProbe()
    persist(true)
    if Overlay.canSend() then
      if Overlay.sendingAllowed() then
        sendLogs()
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
  end, function(e) return e end)
  exportCapture = priorExportCapture
  if not ok then pcall(print, "[pv-debug] log export failed: " .. tostring(err)) end
end

-- The session verdict, written into the stored log.
function Overlay.summary()
  if not captureActive() then return end
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
function Overlay.frame(dt, renderMs)
  Transport.poll()
  if not running then return end
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
  if captureActive() then health.lastPhase = tostring(label) end
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
  mod.hooks:wrap("render.hud", function(next, g, viewport)
    next(g, viewport)
    Overlay.bindGame(g)
    Overlay.draw()
  end)
end

-- The DEBUGGER option controls both capture and panel visibility. It is
-- reachable from VOXEL SETTINGS and the mod manager's page; F9/SELECT mirror
-- the same state. Values { false, true } make the manager's schema a toggle.
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
