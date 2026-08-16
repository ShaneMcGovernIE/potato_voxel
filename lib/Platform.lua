-- Platform detection for the voxel build.
--
-- The mod sandbox forbids raw OS queries from mod code, so the answer
-- comes from the engine's own Platform module (src.core.Platform) -- the
-- same module main.lua and DebugOverlay read for their mobile gates,
-- which resolves the OS name inside engine code. This wrapper exists so
-- platform policy in MeshCache / ChunkMesher stays readable and
-- testable: tests swap the OS the engine module answers (an OS-name
-- stub plus the engine module's test reset) exactly as the suite does.
--
-- Switch (NX) and iOS answers are exported. The cache fixes gate on Switch
-- because the observed failures there are port-specific, while the packed
-- shadow canvas has an iOS-only color-pipeline workaround. Other platforms
-- keep their historical behavior byte for byte. (No OS API is named here;
-- the engine answers both facts.)

local P = {}

local function enginePlatform()
  local ok, Engine = pcall(require, "src.core.Platform")
  if not ok or type(Engine) ~= "table" then return nil end
  return Engine
end

function P.isSwitch()
  local Engine = enginePlatform()
  if not Engine then return false end
  local okI, isNX = pcall(Engine.isNX)
  if okI and type(isNX) == "boolean" then return isNX end
  local okD, info = pcall(Engine.detect)
  if not okD or type(info) ~= "table" then return false end
  return not not info.nx
end

function P.isIOS()
  local Engine = enginePlatform()
  if not Engine then return false end
  local ok, info = pcall(Engine.detect)
  return ok and type(info) == "table" and info.os == "iOS"
end

-- Tests swap the OS the engine module answers between cases; the engine
-- module caches its answer, so the reset is forwarded for symmetry with
-- the engine API.
function P._resetForTests()
  local Engine = enginePlatform()
  if Engine and Engine._resetForTests then
    pcall(Engine._resetForTests)
  end
end

return P
