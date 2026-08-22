-- Headless runtime contract for the mobile shadow target.
--
-- The host deliberately rejects the implicit { color, depth = true } target
-- while accepting an explicit depthstencil canvas. This mirrors the class of
-- GLES backend where colour canvas allocation succeeds but the transient
-- depth attachment does not. The second assertion protects the independent
-- world/sprite layer lifetime: a sprite pass failure must not erase a world
-- map that already finished successfully.

local script = debug.getinfo(1, "S").source:gsub("^@", "")
local root = script:match("^(.*)[/\\]tests[/\\][^/\\]+$") or "."

local function canvas(w, h, kind)
  local c = { w = w, h = h, kind = kind }
  function c.setFilter() end
  function c.setWrap() end
  function c.release() end
  return c
end

local bound = nil
local binds = {}
local canvasKinds = {}
local canvasFormats = {}
local ios = true
local rejectExplicit = false
local rejectImplicit = true
local oldLove = _G.love
_G.love = { graphics = {} }
local g = _G.love.graphics

function g.newCanvas(w, h, opts)
  canvasKinds[#canvasKinds + 1] = opts and opts.format or "default"
  if opts and opts.format then
    canvasFormats[#canvasFormats + 1] = opts.format
    if rejectExplicit and opts.format ~= "rgba8" then
      error("explicit depth format rejected by test backend")
    end
    return canvas(w, h, opts.format)
  end
  return canvas(w, h, "color")
end
function g.newShader()
  return { send = function() end }
end
function g.setCanvas(target)
  if rejectImplicit and type(target) == "table" and target.depth == true then
    error("implicit depth attachment rejected by mobile backend")
  end
  bound = target
  binds[#binds + 1] = target
end
function g.getBlendMode() return "alpha", "alphamultiply" end
function g.clear() end
function g.setDepthMode() end
function g.setMeshCullMode() end
function g.setBlendMode() end
function g.setShader() end
function g.setColor() end

local Mat4 = assert(loadfile(root .. "/lib/Mat4.lua"))()
local Voxel = { level = 1, angle = 0.9, FOCAL = 1.0 }
local ShadowSettings = { quality = function() return nil end }
local V = {
  require = function(name)
    if name == "Mat4" then return Mat4 end
    if name == "VoxelState" then return Voxel end
    if name == "ShadowSettings" then return ShadowSettings end
    if name == "Platform" then
      return { isIOS = function() return ios end }
    end
    if name == "PixelCanvas" then
      return assert(loadfile(root .. "/lib/PixelCanvas.lua"))(V)
    end
    error("shadow runtime probe: unexpected require " .. tostring(name))
  end,
}
local ShadowMap = assert(loadfile(root .. "/lib/ShadowMap.lua"))(V)
ShadowMap.BRICK_HIGH_RES = 1024

local passed, failed = 0, 0
local function check(condition, name)
  if condition then
    passed = passed + 1
  else
    failed = failed + 1
    io.write("FAIL: " .. name .. "\n")
  end
end

check(ShadowMap.available(), "shadow capability accepts explicit depth target")
check(canvasFormats[1] == "rgba8" and canvasFormats[2] == "rgba8",
      "packed shadow layers use a raw rgba8 canvas format")
check(ShadowMap.begin(0, 0, 160, 144, false),
      "world pass begins when implicit depth binding is unavailable")
local worldDiagnostics = ShadowMap.diagnostics()
check(worldDiagnostics.depth and worldDiagnostics.depth.binding == "explicit",
      "diagnostics identify explicit depth binding")
ShadowMap.finish("world", false)
check(ShadowMap.diagnostics().worldReady,
      "world pass becomes ready after finish")

check(ShadowMap.begin(0, 0, 160, 144, true),
      "sprite pass begins with the shared explicit depth target")
ShadowMap.abort(true)
local afterSpriteAbort = ShadowMap.diagnostics()
check(afterSpriteAbort.worldReady,
      "sprite abort preserves a completed world layer")
check(not afterSpriteAbort.spriteReady,
      "sprite abort leaves only the sprite layer unavailable")
check(afterSpriteAbort.lastPass == "sprite",
      "diagnostics identify the aborted sprite pass")
check(#binds > 0,
      "shadow pass bound a render target")

-- A second backend rejects explicit depth formats but accepts LOVE's internal
-- attachment. The fallback must keep the pass alive rather than disabling
-- shadows just because the preferred format is unavailable.
ShadowMap.invalidate()
rejectExplicit = true
rejectImplicit = false
check(ShadowMap.available(), "shadow capability accepts internal depth fallback")
check(ShadowMap.begin(0, 0, 160, 144, false),
      "world pass falls back to the internal depth target")
check(ShadowMap.diagnostics().depth.binding == "internal",
      "diagnostics identify internal depth fallback")
ShadowMap.finish("world-fallback", false)
check(ShadowMap.diagnostics().worldReady,
      "internal depth fallback produces a ready world layer")

-- Non-iOS platforms retain the historical default color canvas. Only iOS
-- needs the explicit raw format because that is where the packed depth was
-- observed being altered by the display color pipeline.
ShadowMap.invalidate()
ios = false
rejectExplicit = false
rejectImplicit = false
local beforeNonIOS = #canvasKinds
check(ShadowMap.available(), "non-iOS shadow capability remains available")
check(canvasKinds[beforeNonIOS + 1] == "default"
      and canvasKinds[beforeNonIOS + 2] == "default",
      "non-iOS shadow layers keep the default canvas format")

_G.love = oldLove
io.write(("shadow runtime: %d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
