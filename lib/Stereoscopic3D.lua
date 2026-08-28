local V = ...

local ModSetting = V.require("ModSetting")
local Voxel3D = V.require("Voxel3D")

local Stereoscopic3D = {}

Stereoscopic3D.modeSetting = ModSetting.new(
  "stereo3d", "3D MODE",
  { "off", "colorcode", "redblue", "redcyan", "mono", "chromadepth" },
  { "OFF", "COLORCODE", "RED-BLUE", "RED-CYAN", "MONO", "CHROMADEPTH" })

Stereoscopic3D.depthSetting = ModSetting.new(
  "stereoDepth", "3D DEPTH",
  { "high", "medium", "low" },
  { "HIGH", "MEDIUM", "LOW" })

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
  high = 4,
}

Stereoscopic3D.CHROMA_RANGE = 0.45

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

local CHROMADEPTH_SHADER = [[
  uniform Image scene;
  uniform LOVE_HIGHP_OR_MEDIUMP Image depthTex;
  uniform vec4 depthInfo;
  uniform float depthRange;

  vec3 chromaRamp(float t) {
    if (t < 0.25) return mix(vec3(1.0, 0.0, 0.0),
                             vec3(1.0, 1.0, 0.0), t * 4.0);
    if (t < 0.5) return mix(vec3(1.0, 1.0, 0.0),
                            vec3(0.0, 1.0, 0.0), (t - 0.25) * 4.0);
    if (t < 0.75) return mix(vec3(0.0, 1.0, 0.0),
                            vec3(0.0, 1.0, 1.0), (t - 0.5) * 4.0);
    return mix(vec3(0.0, 1.0, 1.0),
               vec3(0.0, 0.0, 1.0), (t - 0.75) * 4.0);
  }

  float linearDepth(float z) {
    float n = depthInfo.x;
    float f = depthInfo.y;
    float clip = z * 2.0 - 1.0;
    return (2.0 * n * f) / (f + n - clip * (f - n));
  }

  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec4 source = Texel(scene, tc);
    if (source.a <= 0.0) return source * color;
    float rawDepth = Texel(depthTex, tc).r;
    if (rawDepth >= 0.9999 || rawDepth != rawDepth) {
      return source * color;
    }
    float distance = linearDepth(rawDepth);
    float focus = depthInfo.z;
    float span = max(0.001, focus * depthRange);
    float t = clamp(0.5 + (distance - focus) / span, 0.0, 1.0);
    float luminance = dot(source.rgb, vec3(0.299, 0.587, 0.114));
    float brightness = mix(0.55, 1.0, clamp(luminance, 0.0, 1.0));
    vec3 encoded = chromaRamp(t) * brightness;
    return vec4(clamp(encoded, 0.0, 1.0), source.a) * color;
  }
]]

local compositeShader
local compositeError
local compositeTarget
local lastFailure
local chromaShader
local chromaError
local chromaTarget
local lastChromaFailure

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

function Stereoscopic3D.anaglyphEnabled()
  return Stereoscopic3D.enabled() and Stereoscopic3D.mode() ~= "chromadepth"
end

function Stereoscopic3D.chromadepthEnabled()
  return Stereoscopic3D.enabled() and Stereoscopic3D.mode() == "chromadepth"
end

function Stereoscopic3D.chromaColor(t)
  t = math.max(0, math.min(1, tonumber(t) or 0))
  if t < 0.25 then
    local p = t * 4
    return { 1, p, 0 }
  end
  if t < 0.5 then
    local p = (t - 0.25) * 4
    return { 1 - p, 1, 0 }
  end
  if t < 0.75 then
    local p = (t - 0.5) * 4
    return { 0, 1, p }
  end
  local p = (t - 0.75) * 4
  return { 0, 1 - p, 1 }
end

function Stereoscopic3D.linearDepth(z, near, far)
  near = tonumber(near) or 1
  far = math.max(near + 1, tonumber(far) or near + 1)
  local clip = (tonumber(z) or 1) * 2 - 1
  return (2 * near * far) / (far + near - clip * (far - near))
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
    out.focus = copyVector(base.focus)
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

local function getChromaShader()
  if chromaShader == nil then
    local ok, shader = pcall(love.graphics.newShader, CHROMADEPTH_SHADER)
    if ok and shader then
      chromaShader = shader
    else
      chromaShader = false
      chromaError = tostring(shader)
    end
  end
  return chromaShader or nil
end

local function getChromaTarget(w, h)
  if chromaTarget and chromaTarget.w == w and chromaTarget.h == h then
    return chromaTarget.canvas, nil
  end
  local ok, canvas = pcall(love.graphics.newCanvas, w, h)
  if not (ok and canvas) then
    return nil, ok and "newCanvas returned nil" or tostring(canvas)
  end
  pcall(canvas.setFilter, canvas, "nearest", "nearest")
  if chromaTarget and chromaTarget.canvas and chromaTarget.canvas.release then
    pcall(chromaTarget.canvas.release, chromaTarget.canvas)
  end
  chromaTarget = { canvas = canvas, w = w, h = h }
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

function Stereoscopic3D.chromadepth(canvas, depthCanvas, w, h,
                                     near, far, focus)
  if not (canvas and depthCanvas and w and h) then
    lastChromaFailure = "scene or depth canvas unavailable"
    return nil
  end
  local shader = getChromaShader()
  local target, targetError = shader and getChromaTarget(w, h) or nil
  if not shader then
    lastChromaFailure = chromaError or "chromadepth shader unavailable"
    return nil
  end
  if not target then
    lastChromaFailure = targetError or "chromadepth canvas unavailable"
    return nil
  end
  near = tonumber(near) or 1
  far = math.max(near + 1, tonumber(far) or near + 1)
  focus = math.max(near, math.min(far, tonumber(focus) or (near + far) * 0.5))
  local range = Stereoscopic3D.CHROMA_RANGE
  local previousCanvas = love.graphics.getCanvas()
  local previousShader = love.graphics.getShader()
  local previousBlend, previousAlpha = love.graphics.getBlendMode()
  local ok = pcall(function()
    canvas:setFilter("nearest", "nearest")
    pcall(depthCanvas.setFilter, depthCanvas, "nearest", "nearest")
    love.graphics.setCanvas(target)
    love.graphics.clear(0, 0, 0, 0)
    love.graphics.setBlendMode("replace", "premultiplied")
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setShader(shader)
    pcall(shader.send, shader, "scene", canvas)
    pcall(shader.send, shader, "depthTex", depthCanvas)
    pcall(shader.send, shader, "depthInfo", { near, far, focus, 0 })
    pcall(shader.send, shader, "depthRange", range)
    love.graphics.draw(canvas)
  end)
  if previousCanvas then
    love.graphics.setCanvas(previousCanvas)
  else
    love.graphics.setCanvas()
  end
  love.graphics.setShader(previousShader)
  love.graphics.setBlendMode(previousBlend or "alpha", previousAlpha)
  if not ok then lastChromaFailure = "chromadepth draw failed" end
  return ok and target or nil
end

function Stereoscopic3D.diagnostics()
  local available = love and love.graphics and love.graphics.newCanvas
                     and love.graphics.newShader and true or false
  local compositorReason = lastFailure or compositeError
  local chromadepthReason = lastChromaFailure or chromaError
  return {
    available = available,
    mode = Stereoscopic3D.mode(),
    depth = Stereoscopic3D.depth(),
    shader = compositeShader and compositeShader ~= false or nil,
    chromadepthShader = chromaShader and chromaShader ~= false or nil,
    chromadepthEnabled = Stereoscopic3D.chromadepthEnabled(),
    depthReadable = Voxel3D.depthTexture and Voxel3D.depthTexture() ~= nil
                    or false,
    compositorReason = compositorReason,
    chromadepthReason = chromadepthReason,
    reason = available and (Stereoscopic3D.chromadepthEnabled()
                            and chromadepthReason or compositorReason) or
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
  if chromaTarget and chromaTarget.canvas and chromaTarget.canvas.release then
    pcall(chromaTarget.canvas.release, chromaTarget.canvas)
  end
  chromaTarget = nil
  chromaShader = nil
  chromaError = nil
  lastChromaFailure = nil
end

return Stereoscopic3D
