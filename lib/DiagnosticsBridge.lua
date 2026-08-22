-- Optional diagnostics transport for feature modules.
--
-- Core/cache/meshing code reports through this narrow boundary instead of
-- resolving the HUD overlay at every call site. The lookup is lazy so the
-- bridge is safe during module bootstrap, and all methods are no-ops when
-- diagnostics are not installed.
local V = ...

local DiagnosticsBridge = {}
local resolved = false
local overlay = nil

local function target()
  if not resolved then
    resolved = true
    local ok, value = pcall(V.require, "DebugOverlay")
    if ok and type(value) == "table" then overlay = value end
  end
  return overlay
end

local function call(name, ...)
  local value = target()
  local fn = value and value[name]
  if type(fn) ~= "function" then return nil end
  local ok, result = pcall(fn, ...)
  if ok then return result end
  return nil
end

function DiagnosticsBridge.note(...)
  return call("note", ...)
end

function DiagnosticsBridge.trace(...)
  return call("trace", ...)
end

function DiagnosticsBridge.warn(...)
  return call("warn", ...)
end

function DiagnosticsBridge.error(...)
  return call("error", ...)
end

function DiagnosticsBridge.count(...)
  return call("count", ...)
end

function DiagnosticsBridge.buildDone(...)
  return call("buildDone", ...)
end

function DiagnosticsBridge.pipelinePath(...)
  return call("pipelinePath", ...)
end

return DiagnosticsBridge
