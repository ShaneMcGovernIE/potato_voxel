-- Data-only state for the diagnostic recorder.
--
-- This module owns the bounded evidence rings, session counters, and health
-- document. It has no logging, storage, transport, input, or rendering
-- behavior; DebugOverlay supplies those policies around this state boundary.
local DiagnosticsStore = {}

local function defaultCopy(value, depth)
  if depth and depth > 8 then return tostring(value) end
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
      out[key] = defaultCopy(item, (depth or 0) + 1)
    end
  end
  return out
end

function DiagnosticsStore.new(options)
  options = options or {}
  local copy = options.dataCopy or defaultCopy
  local sessionId = options.sessionId or os.date("%Y%m%d-%H%M%S")
  local maxLines = options.maxLines or 20
  local logKeep = options.logKeep or 600
  local bootKeep = options.bootKeep or 128

  local store = {
    sessionId = sessionId,
    lines = {},
    log = {},
    logSeq = {},
    bootLog = {},
    seq = 0,
    lastSentSeq = 0,
    bootSent = false,
    counters = {
      jobs = 0, jobFails = 0, cacheHits = 0, cacheMisses = 0,
      slowLoads = 0, errors = 0, storageFails = 0,
    },
    worstFrame = 0,
    health = {
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
      build = { jobs = 0, slices = 0, overshoots = 0, worstResumeMs = 0,
                worstResumeJob = nil },
      probe = { ok = nil },
      lastEvent = nil,
      lastError = nil,
      platform = nil,
    },
  }

  function store.append(line)
    store.lines[#store.lines + 1] = line
    if #store.lines > maxLines then table.remove(store.lines, 1) end
    if #store.bootLog < bootKeep then store.bootLog[#store.bootLog + 1] = line end
    store.seq = store.seq + 1
    store.log[#store.log + 1] = line
    store.logSeq[#store.logSeq + 1] = store.seq
    if #store.log > logKeep then
      for _ = 1, logKeep / 2 do
        table.remove(store.log, 1)
        table.remove(store.logSeq, 1)
      end
    end
  end

  function store.replaceLatest(line)
    if #store.lines > 0 then store.lines[#store.lines] = line end
    if #store.log > 0 then store.log[#store.log] = line end
  end

  function store.logText()
    local out = {}
    if #store.bootLog > 0 then
      out[#out + 1] = "-- boot evidence (first lines) --"
      for _, line in ipairs(store.bootLog) do out[#out + 1] = line end
    end
    if #store.log > 0 then
      out[#out + 1] = "-- recent evidence (ring) --"
      for _, line in ipairs(store.log) do out[#out + 1] = line end
    end
    return table.concat(out, "\n")
  end

  function store.ringDelta()
    local first
    for i = 1, #store.log do
      if store.logSeq[i] and store.logSeq[i] > store.lastSentSeq then
        first = i
        break
      end
    end
    if not first then return nil end
    local out = {}
    for i = first, #store.log do out[#out + 1] = store.log[i] end
    return out
  end

  function store.snapshot(fields)
    fields = fields or {}
    local health = store.health
    return {
      schema = 2,
      session = store.sessionId,
      startedAt = health.startedAt,
      frame = health.frame,
      pipeline = copy(health.pipeline),
      capabilities = copy(health.capabilities),
      renderer = copy(health.renderer),
      storage = copy(health.storage),
      build = copy(health.build),
      probe = copy(health.probe),
      platform = fields.platform or health.platform,
      settings = fields.settings,
      lastEvent = copy(health.lastEvent),
      lastError = copy(health.lastError),
      lastPhase = health.lastPhase,
      counters = copy(store.counters),
      worstFrame = store.worstFrame,
    }
  end

  function store.count(name, amount)
    store.counters[name] = (store.counters[name] or 0) + (amount or 1)
  end

  function store.updateWorstFrame(frameMs)
    if frameMs > store.worstFrame then store.worstFrame = frameMs end
  end

  return store
end

return DiagnosticsStore
