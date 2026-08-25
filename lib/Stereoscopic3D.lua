local V = ...

local ModSetting = V.require("ModSetting")
local Voxel3D = V.require("Voxel3D")

local Stereoscopic3D = {}

Stereoscopic3D.modeSetting = ModSetting.new(
  "stereo3d", "3D MODE",
  { "off", "colorcode", "redblue", "redcyan", "mono" },
  { "OFF", "COLORCODE", "RED-BLUE", "RED-CYAN", "MONO" })

Stereoscopic3D.depthSetting = ModSetting.new(
  "stereoDepth", "3D DEPTH",
  { "medium", "low", "high" },
  { "MEDIUM", "LOW", "HIGH" })

Stereoscopic3D.PROFILES = {
  colorcode = {
    left = {
      { 1, 0, 0 },
      { 0.55, 0.45, 0 },
      { 0, 0, 0 },
    },
    right = {
      { 0, 0, 0 },
      { 0, 0, 0 },
      { 0, 0, 1 },
    },
  },
  redblue = {
    left = {
      { 1, 0, 0 },
      { 0, 0, 0 },
      { 0, 0, 0 },
    },
    right = {
      { 0, 0, 0 },
      { 0, 0, 0 },
      { 0, 0, 1 },
    },
  },
  redcyan = {
    left = {
      { 1, 0, 0 },
      { 0, 0, 0 },
      { 0, 0, 0 },
    },
    right = {
      { 0, 0, 0 },
      { 0, 1, 0 },
      { 0, 0, 1 },
    },
  },
  mono = {
    left = {
      { 0.299, 0.587, 0.114 },
      { 0, 0, 0 },
      { 0, 0, 0 },
    },
    right = {
      { 0, 0, 0 },
      { 0.299, 0.587, 0.114 },
      { 0.299, 0.587, 0.114 },
    },
  },
}

Stereoscopic3D.DEPTH = {
  low = 1.5,
  medium = 3,
  high = 5,
}

local COMPOSITE_SHADER = [[
  uniform Image leftEye;
  uniform Image rightEye;
  uniform vec3 leftR;
  uniform vec3 leftG;
  uniform vec3 leftB;
  uniform vec3 rightR;
  uniform vec3 rightG;
  uniform vec3 rightB;
  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec4 l = Texel(leftEye, tc);
    vec4 r = Texel(rightEye, tc);
    float a = max(l.a, r.a);
    vec3 rgb = vec3(
      dot(l.rgb, leftR) + dot(r.rgb, rightR),
      dot(l.rgb, leftG) + dot(r.rgb, rightG),
      dot(l.rgb, leftB) + dot(r.rgb, rightB));
    return vec4(clamp(rgb, 0.0, 1.0) * a, a) * color;
  }
]]

local compositeShader
local compositeError
local compositeTarget
local lastFailure

local function copyVector(v)
  return { v[1], v[2], v[3] }
end

local function copyCamera(camera)
  if not camera then return nil end
  local out = {}
  for key, value in pairs(camera) do
    if key == "eye" or key == "focus" or key == "up" then
      out[key] = copyVector(value)
    else
      out[key] = value
    end
  end
  return out
end

local function length(x, y, z)
  return math.sqrt(x * x + y * y + z * z)
end

local function rightVector(camera)
  local eye, focus = camera.eye, camera.focus
  local fx, fy, fz = focus[1] - eye[1], focus[2] - eye[2], focus[3] - eye[3]
  local fl = length(fx, fy, fz)
  if fl < 1e-6 then return nil end
  fx, fy, fz = fx / fl, fy / fl, fz / fl
  local up = camera.up or { 0, 1, 0 }
  local rx = fy * up[3] - fz * up[2]
  local ry = fz * up[1] - fx * up[3]
  local rz = fx * up[2] - fy * up[1]
  local rl = length(rx, ry, rz)
  if rl < 1e-6 then return nil end
  return rx / rl, ry / rl, rz / rl, fl
end

function Stereoscopic3D.mode()
  return Stereoscopic3D.modeSetting:get()
end

function Stereoscopic3D.supported()
  return true
end

function Stereoscopic3D.depth()
  return Stereoscopic3D.depthSetting:get()
end

function Stereoscopic3D.enabled()
  if Stereoscopic3D.mode() == "off" then return false end
  local ok, VR = pcall(V.require, "VR")
  return not (ok and VR and VR.active and VR.active())
end

function Stereoscopic3D.depthSeparation()
  return Stereoscopic3D.DEPTH[Stereoscopic3D.depth()] or Stereoscopic3D.DEPTH.medium
end

function Stereoscopic3D.profile(mode)
  return Stereoscopic3D.PROFILES[mode or Stereoscopic3D.mode()]
end

function Stereoscopic3D.orbitCamera(cx, cy, vh)
  local Voxel = V.require("VoxelState")
  local distance = Voxel.FOCAL * vh
  local angle = Voxel.angle
  return {
    eye = { cx, distance * math.cos(angle), cy + distance * math.sin(angle) },
    focus = { cx, 0, cy },
    fov = 2 * math.atan(1 / (2 * Voxel.FOCAL)),
    up = { 0, math.sin(angle), -math.cos(angle) },
  }
end

function Stereoscopic3D.buildEyes(camera, w, h, slot, adopt)
  local base = copyCamera(camera)
  if not (base and base.eye and base.focus) then return nil end
  local rx, ry, rz, distance = rightVector(base)
  if not rx then return nil end
  local separation = Stereoscopic3D.depthSeparation()
  local half = separation * 0.5
  local fov = base.fov or math.rad(53)
  local focal = 1 / math.tan(fov * 0.5)
  local aspect = w / math.max(1, h)
  local shift = focal / aspect * half / math.max(1, distance)
  local function eye(sign, name)
    local offset = half * sign
    local out = copyCamera(base)
    out.eye = {
      base.eye[1] + rx * offset,
      base.eye[2] + ry * offset,
      base.eye[3] + rz * offset,
    }
    out.focus = {
      base.focus[1] + rx * offset,
      base.focus[2] + ry * offset,
      base.focus[3] + rz * offset,
    }
    out.projectionShift = -shift * sign
    return { camera = out, w = w, h = h, slot = slot .. "_" .. name,
             adopt = adopt and true or false }
  end
  return { eye(-1, "left"), eye(1, "right") }
end

function Stereoscopic3D.spec(slot)
  return {
    build = function(camera, cx, cy, vw, vh, w, h)
      local base = camera or Stereoscopic3D.orbitCamera(cx, cy, vh)
      return Stereoscopic3D.buildEyes(base, w, h, slot, true)
    end,
  }
end

local function getShader()
  if compositeShader == nil then
    local ok, shader = pcall(love.graphics.newShader, COMPOSITE_SHADER)
    if ok and shader then
      compositeShader = shader
    else
      compositeShader = false
      compositeError = tostring(shader)
    end
  end
  return compositeShader or nil
end

local function getTarget(w, h)
  if compositeTarget and compositeTarget.w == w and compositeTarget.h == h then
    return compositeTarget.canvas, nil
  end
  local ok, canvas = pcall(love.graphics.newCanvas, w, h)
  if not (ok and canvas) then
    return nil, ok and "newCanvas returned nil" or tostring(canvas)
  end
  pcall(canvas.setFilter, canvas, "nearest", "nearest")
  if compositeTarget and compositeTarget.canvas
     and compositeTarget.canvas.release then
    pcall(compositeTarget.canvas.release, compositeTarget.canvas)
  end
  compositeTarget = { canvas = canvas, w = w, h = h }
  return canvas, nil
end

local function sendProfile(shader, profile)
  local left, right = profile.left, profile.right
  pcall(shader.send, shader, "leftR", left[1])
  pcall(shader.send, shader, "leftG", left[2])
  pcall(shader.send, shader, "leftB", left[3])
  pcall(shader.send, shader, "rightR", right[1])
  pcall(shader.send, shader, "rightG", right[2])
  pcall(shader.send, shader, "rightB", right[3])
end

function Stereoscopic3D.composite(left, right, w, h)
  if not (left and right and w and h) then return nil end
  local shader = getShader()
  local target, targetError = shader and getTarget(w, h) or nil
  if not shader then
    lastFailure = compositeError or "compositor shader unavailable"
    return nil
  end
  if not target then
    lastFailure = targetError or "compositor canvas unavailable"
    return nil
  end
  local profile = Stereoscopic3D.profile()
  if not profile then
    lastFailure = "unknown anaglyph profile"
    return nil
  end
  local previousCanvas = love.graphics.getCanvas()
  local previousShader = love.graphics.getShader()
  local previousBlend, previousAlpha = love.graphics.getBlendMode()
  local ok = pcall(function()
    left:setFilter("nearest", "nearest")
    right:setFilter("nearest", "nearest")
    love.graphics.setCanvas(target)
    love.graphics.clear(0, 0, 0, 0)
    love.graphics.setBlendMode("replace", "premultiplied")
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setShader(shader)
    pcall(shader.send, shader, "leftEye", left)
    pcall(shader.send, shader, "rightEye", right)
    sendProfile(shader, profile)
    love.graphics.draw(left)
  end)
  if previousCanvas then
    love.graphics.setCanvas(previousCanvas)
  else
    love.graphics.setCanvas()
  end
  love.graphics.setShader(previousShader)
  love.graphics.setBlendMode(previousBlend or "alpha", previousAlpha)
  if not ok then lastFailure = "compositor draw failed" end
  return ok and target or nil
end

function Stereoscopic3D.diagnostics()
  local available = love and love.graphics and love.graphics.newCanvas
                     and love.graphics.newShader and true or false
  return {
    available = available,
    mode = Stereoscopic3D.mode(),
    depth = Stereoscopic3D.depth(),
    shader = compositeShader and compositeShader ~= false or nil,
    reason = available and (lastFailure or compositeError) or
             "graphics canvas or shader unavailable",
  }
end

function Stereoscopic3D.invalidate()
  if compositeTarget and compositeTarget.canvas
     and compositeTarget.canvas.release then
    pcall(compositeTarget.canvas.release, compositeTarget.canvas)
  end
  compositeTarget = nil
  compositeShader = nil
  compositeError = nil
  lastFailure = nil
end

return Stereoscopic3D
