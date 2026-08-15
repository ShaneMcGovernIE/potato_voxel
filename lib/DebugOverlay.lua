-- DebugOverlay: a realtime activity/error/perf panel for this sandbox
-- build. F9 toggles it on and off; F10 switches verbosity (ALL vs
-- important-only).
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
local log = {}           -- every deduped line, bounded, for the stored key
local LOG_KEEP = 600
local enabled = false    -- OFF by default: F9 turns the debugger on
local verbose = true     -- F10: true = all lines, false = important only
local game = nil
local lastPersist = 0
local lastMsg = nil
local lastCount = 0

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

local function persist(force)
  local c = clock()
  if not force and (c - lastPersist) < 1 then return end
  lastPersist = c
  local mod = V.mod
  if not (mod and mod.storage) then return end
  pcall(function()
    local store = mod.storage
    local okS, selected = pcall(mod.storage.selected, mod.storage, game)
    if okS and selected then store = selected end
    if store then
      if store.writeBytes then
        pcall(store.writeBytes, store, game, "debug/log",
              table.concat(log, "\n"))
      elseif store.write then
        pcall(store.write, store, game, "debug/log",
              table.concat(log, "\n"))
      end
    end
  end)
end

local function append(line)
  lines[#lines + 1] = line
  if #lines > MAX_LINES then table.remove(lines, 1) end
  log[#log + 1] = line
  if #log > LOG_KEEP then
    for i = 1, #log - (LOG_KEEP / 2) do table.remove(log, 1) end
  end
end

local function emit(msg, kind)
  if msg == lastMsg then
    lastCount = lastCount + 1
    local line = stamp(msg .. (" (x%d)"):format(lastCount))
    lines[#lines] = line
    log[#log] = line
    persist(false)
    return
  end
  lastMsg, lastCount = msg, 1
  local line = stamp(msg)
  append(line)
  pcall(print, "[pv-debug] " .. line)
  persist(false)
  if kind == "error" then counters.errors = counters.errors + 1 end
end

-- Important: always shown and stored.
function Overlay.note(fmt, ...)
  if not enabled then return end
  local ok, msg = pcall(string.format, fmt, ...)
  if not ok then msg = tostring(fmt) .. " " .. tostring(msg) end
  emit(msg, "note")
end

-- Noise: shown in verbose mode, collapsed in important-only mode (still
-- stored -- the stored log is the support-report artifact).
function Overlay.trace(fmt, ...)
  if not enabled then return end
  local ok, msg = pcall(string.format, fmt, ...)
  if not ok then msg = tostring(fmt) .. " " .. tostring(msg) end
  emit(msg, "trace")
end

-- An error that should never be silenced: always on, always counted.
function Overlay.error(fmt, ...)
  if not enabled then return end
  local ok, msg = pcall(string.format, fmt, ...)
  if not ok then msg = tostring(fmt) .. " " .. tostring(msg) end
  emit(msg, "error")
end

function Overlay.count(name)
  counters[name] = (counters[name] or 0) + 1
end

-- Toggle on F9. Boundary lines always land in storage and the console.
function Overlay.toggle()
  enabled = not enabled
  local line = "debugger " .. (enabled and "ON" or "OFF")
  if enabled then
    lastMsg, lastCount = nil, 0
    append(stamp(line))
    pcall(print, "[pv-debug] " .. stamp(line))
    persist(true)
  else
    pcall(print, "[pv-debug] " .. stamp(line))
    log[#log + 1] = stamp(line)
    Overlay.summary()
    persist(true)
    lines = {}
  end
end

-- F10: verbose <-> important-only.
function Overlay.toggleVerbose()
  verbose = not verbose
  Overlay.note("verbosity %s", verbose and "ALL" or "IMPORTANT")
end

-- F8: export. Force the storage flush so the on-disk debug/log is
-- current, dump every line to the console in one block (terminal users
-- can copy it straight out), and stamp the boundary. Works even while
-- the debugger is toggled off -- exporting is the retrieval action.
function Overlay.export()
  persist(true)
  pcall(print, "[pv-log] ---- export (" .. #log .. " lines) ----")
  for _, line in ipairs(log) do
    pcall(print, "[pv-log] " .. line)
  end
  pcall(print, "[pv-log] ---- end ----")
  local line = stamp("log exported: " .. #log .. " lines -> storage debug/log")
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
  log[#log + 1] = line
  pcall(print, "[pv-debug] " .. line)
end

-- Feed the voxel tick every frame.
function Overlay.frame(dt, renderMs)
  if not enabled then return end
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
    Overlay.trace("frame avg %.1fms max %.1fms render avg %.1fms%s%s",
                  avg, statsMax, renderAvg, gpu,
                  statsMax > 40 and " [HITCH]" or "")
    statsFrames, statsTime, statsMax, statsRender = 0, 0, 0, 0
  end
end

function Overlay.try(label, fn, ...)
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
  if not enabled then return end
  Overlay.trace("self-lint: scanning %d modules", 1 + #moduleNames)
  local okM, mainSrc = pcall(mod.read, mod, "main.lua")
  if okM then lintSource("main.lua", mainSrc) end
  for _, name in ipairs(moduleNames) do
    local ok, src = pcall(mod.read, mod, "lib/" .. name .. ".lua")
    if ok then lintSource("lib/" .. name .. ".lua", src) end
  end
end

function Overlay.draw()
  if not enabled or #lines == 0 then return end
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
       or line:find("storage ") or line:find("prebuild job failed") then
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

function Overlay.install()
  if Overlay.installed then return end
  Overlay.installed = true
  local mod = V.mod
  if not (mod and mod.hooks) then return end
  mod.hooks:wrap("render.hud", function(next, g, viewport)
    next(g, viewport)
    game = game or g
    Overlay.draw()
  end)
  Overlay.note("debug overlay on -- F9 off, F10 verbosity (temporary)")
end

return Overlay
