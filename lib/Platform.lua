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

-- The Steam Deck: not a mobile OS, but its mesh-compress stalls were
-- measured in the 500-680ms class (the same zlib spikes the Pi had in
-- 1.6.11), so the Deck rides the low-end compression class for the same
-- reason the consoles do. Detected by the renderer's own signature --
-- the vangogh APU, the valve/neptune kernel string -- which
-- getRendererInfo answers without any OS query the sandbox would refuse.
local deckDevice = nil

function P.isSteamDeck()
  if deckDevice ~= nil then return deckDevice end
  deckDevice = false
  if not (love and love.graphics and love.graphics.getRendererInfo) then
    return false
  end
  local ok, a, b, c, d = pcall(love.graphics.getRendererInfo)
  if not (ok and a) then return false end
  -- LÖVE 12 answers a table; LÖVE 11 four values (name, version, vendor,
  -- device). Both carry the Deck signature in the version/vendor strings
  -- this checks, whichever shape arrives.
  local s = ""
  if type(a) == "table" then
    s = ("%s %s %s"):format(tostring(a.version or ""),
                            tostring(a.vendor or ""),
                            tostring(a.device or ""))
  else
    s = ("%s %s %s"):format(tostring(b or ""), tostring(c or ""),
                            tostring(d or ""))
  end
  s = s:lower()
  deckDevice = s:find("vangogh", 1, true) ~= nil
            or s:find("neptune", 1, true) ~= nil
            or s:find("steamdeck", 1, true) ~= nil
  return deckDevice
end

-- The constrained-device class this build targets: console (Switch),
-- mobile (iOS) and the Steam Deck (measured zlib compress stalls).
-- Compression and render-budget decisions use this to pick the fast
-- path (lz4 before zlib) where a multi-hundred-ms zlib stall on a big
-- payload would otherwise land on a device that can least afford it.
-- Desktop and the desktop-adjacent ports keep the historical
-- zstd -> zlib -> lz4 chain.
function P.lowEnd()
  return P.isSwitch() or P.isIOS() or P.isSteamDeck()
end

-- Tests swap the OS the engine module answers between cases; the engine
-- module caches its answer, so the reset is forwarded for symmetry with
-- the engine API. The Deck's cached answer clears with it, so a stubbed
-- renderer never outlives its case.
function P._resetForTests()
  local Engine = enginePlatform()
  if Engine and Engine._resetForTests then
    pcall(Engine._resetForTests)
  end
  deckDevice = nil
end

return P
