-- Minimal 4x4 matrix math for voxel world mode.
--
-- Row-major, and sent to the shader with shader:send("mvp", "row", m).
-- LOVE 11.5's matrix uniform defaults to column-major, so the "row" layout
-- argument is what lets these tables read the same way they are written
-- here -- translation in the fourth column, m[4]/m[8]/m[12].
--
-- Only what the renderer actually needs: a perspective projection (the
-- camera), an orthographic one (the sun's shadow pass), an asymmetric one
-- (a headset's per-eye frustum), a look-based view, a quaternion rotation
-- (a headset's pose), and the translate/rotateY/scale a model matrix is
-- built from. No general inverse -- the VR view inverts its rigid pieces
-- one at a time.

local Mat4 = {}

Mat4.scratch1 = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
Mat4.scratch2 = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
Mat4.scratch3 = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
Mat4.scratch4 = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }

function Mat4.identity()
  return { 1, 0, 0, 0,
           0, 1, 0, 0,
           0, 0, 1, 0,
           0, 0, 0, 1 }
end

function Mat4.identityInPlace(out)
  out[1], out[2], out[3], out[4]   = 1, 0, 0, 0
  out[5], out[6], out[7], out[8]   = 0, 1, 0, 0
  out[9], out[10], out[11], out[12] = 0, 0, 1, 0
  out[13], out[14], out[15], out[16] = 0, 0, 0, 1
  return out
end

function Mat4.copyInPlace(out, src)
  for i = 1, 16 do out[i] = src[i] end
  return out
end

-- a * b, both row-major
function Mat4.mul(a, b)
  local o = {}
  for r = 0, 3 do
    local a0, a1 = a[r * 4 + 1], a[r * 4 + 2]
    local a2, a3 = a[r * 4 + 3], a[r * 4 + 4]
    for c = 1, 4 do
      o[r * 4 + c] = a0 * b[c] + a1 * b[4 + c] + a2 * b[8 + c] + a3 * b[12 + c]
    end
  end
  return o
end

function Mat4.mulInPlace(out, a, b)
  local b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15, b16 =
    b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15], b[16]
  for r = 0, 3 do
    local offset = r * 4
    local a0, a1 = a[offset + 1], a[offset + 2]
    local a2, a3 = a[offset + 3], a[offset + 4]
    out[offset + 1] = a0 * b1  + a1 * b5  + a2 * b9  + a3 * b13
    out[offset + 2] = a0 * b2  + a1 * b6  + a2 * b10 + a3 * b14
    out[offset + 3] = a0 * b3  + a1 * b7  + a2 * b11 + a3 * b15
    out[offset + 4] = a0 * b4  + a1 * b8  + a2 * b12 + a3 * b16
  end
  return out
end

function Mat4.translate(x, y, z)
  return { 1, 0, 0, x,
           0, 1, 0, y,
           0, 0, 1, z,
           0, 0, 0, 1 }
end

function Mat4.translateInPlace(out, x, y, z)
  out[1], out[2], out[3], out[4]   = 1, 0, 0, x
  out[5], out[6], out[7], out[8]   = 0, 1, 0, y
  out[9], out[10], out[11], out[12] = 0, 0, 1, z
  out[13], out[14], out[15], out[16] = 0, 0, 0, 1
  return out
end

function Mat4.scale(x, y, z)
  return { x, 0, 0, 0,
           0, y, 0, 0,
           0, 0, z, 0,
           0, 0, 0, 1 }
end

function Mat4.scaleInPlace(out, x, y, z)
  out[1], out[2], out[3], out[4]   = x, 0, 0, 0
  out[5], out[6], out[7], out[8]   = 0, y, 0, 0
  out[9], out[10], out[11], out[12] = 0, 0, z, 0
  out[13], out[14], out[15], out[16] = 0, 0, 0, 1
  return out
end

function Mat4.rotateY(a)
  local c, s = math.cos(a), math.sin(a)
  return { c, 0, s, 0,
           0, 1, 0, 0,
          -s, 0, c, 0,
           0, 0, 0, 1 }
end

function Mat4.rotateYInPlace(out, a)
  local c, s = math.cos(a), math.sin(a)
  out[1], out[2], out[3], out[4]   = c, 0, s, 0
  out[5], out[6], out[7], out[8]   = 0, 1, 0, 0
  out[9], out[10], out[11], out[12] = -s, 0, c, 0
  out[13], out[14], out[15], out[16] = 0, 0, 0, 1
  return out
end

function Mat4.rotateX(a)
  local c, s = math.cos(a), math.sin(a)
  return { 1, 0, 0, 0,
           0, c, -s, 0,
           0, s, c, 0,
           0, 0, 0, 1 }
end

function Mat4.rotateXInPlace(out, a)
  local c, s = math.cos(a), math.sin(a)
  out[1], out[2], out[3], out[4]   = 1, 0, 0, 0
  out[5], out[6], out[7], out[8]   = 0, c, -s, 0
  out[9], out[10], out[11], out[12] = 0, s, c, 0
  out[13], out[14], out[15], out[16] = 0, 0, 0, 1
  return out
end

-- The rotation a unit quaternion describes, row-major. The VR rig is what
-- needs it: an OpenXR eye pose arrives as position + orientation
-- quaternion, and both the eye's transform and its inverse (the view) are
-- built from this.
function Mat4.fromQuat(x, y, z, w)
  local xx, yy, zz = x * x, y * y, z * z
  local xy, xz, yz = x * y, x * z, y * z
  local wx, wy, wz = w * x, w * y, w * z
  return { 1 - 2 * (yy + zz), 2 * (xy - wz), 2 * (xz + wy), 0,
           2 * (xy + wz), 1 - 2 * (xx + zz), 2 * (yz - wx), 0,
           2 * (xz - wy), 2 * (yz + wx), 1 - 2 * (xx + yy), 0,
           0, 0, 0, 1 }
end

-- Transpose. For a pure rotation this IS the inverse, which is how the VR
-- view matrix is assembled without a general 4x4 inverse.
function Mat4.transpose(m)
  return { m[1], m[5], m[9], m[13],
           m[2], m[6], m[10], m[14],
           m[3], m[7], m[11], m[15],
           m[4], m[8], m[12], m[16] }
end

-- Right-handed perspective from an OpenXR-style asymmetric field of view:
-- four signed HALF-ANGLES off the view axis (left and down negative), onto
-- GL clip space (z in [-1, 1]). A headset's per-eye frustum is off-centre
-- -- the nose side is narrower than the temple side -- so the symmetric
-- perspective() above cannot express it.
function Mat4.fovProjection(angleLeft, angleRight, angleUp, angleDown,
                            near, far)
  local l, r = math.tan(angleLeft), math.tan(angleRight)
  local u, d = math.tan(angleUp), math.tan(angleDown)
  local w, h, dz = r - l, u - d, near - far
  return { 2 / w, 0, (r + l) / w, 0,
           0, 2 / h, (u + d) / h, 0,
           0, 0, (far + near) / dz, (2 * far * near) / dz,
           0, 0, -1, 0 }
end

-- Right-handed perspective onto GL clip space (z in [-1, 1]).
function Mat4.perspective(fovY, aspect, near, far)
  local f = 1 / math.tan(fovY / 2)
  local d = near - far
  return { f / aspect, 0, 0, 0,
           0, f, 0, 0,
           0, 0, (far + near) / d, (2 * far * near) / d,
           0, 0, -1, 0 }
end

function Mat4.perspectiveInPlace(out, fovY, aspect, near, far)
  local f = 1 / math.tan(fovY / 2)
  local d = near - far
  out[1], out[2], out[3], out[4]   = f / aspect, 0, 0, 0
  out[5], out[6], out[7], out[8]   = 0, f, 0, 0
  out[9], out[10], out[11], out[12] = 0, 0, (far + near) / d, (2 * far * near) / d
  out[13], out[14], out[15], out[16] = 0, 0, -1, 0
  return out
end

-- Right-handed orthographic projection onto GL clip space (z in [-1, 1]).
-- The view-space box is x in [l, r], y in [b, t], z in [-f, -n] -- near and
-- far are DISTANCES down the view's -z, exactly as in perspective() above.
-- Parallel, so a sun is a direction and nothing else: no eye point, no
-- foreshortening, and clip z stays linear in world units, which is what
-- lets the shadow pass store depth as a plain number.
function Mat4.ortho(l, r, b, t, n, f)
  return { 2 / (r - l), 0, 0, -(r + l) / (r - l),
           0, 2 / (t - b), 0, -(t + b) / (t - b),
           0, 0, -2 / (f - n), -(f + n) / (f - n),
           0, 0, 0, 1 }
end

function Mat4.orthoInPlace(out, l, r, b, t, n, f)
  local rml = r - l
  local tmb = t - b
  local fmn = f - n
  out[1], out[2], out[3], out[4]   = 2 / rml, 0, 0, -(r + l) / rml
  out[5], out[6], out[7], out[8]   = 0, 2 / tmb, 0, -(t + b) / tmb
  out[9], out[10], out[11], out[12] = 0, 0, -2 / fmn, -(f + n) / fmn
  out[13], out[14], out[15], out[16] = 0, 0, 0, 1
  return out
end

-- Right-handed look-at. eye/target/up are {x, y, z}.
function Mat4.lookAt(eye, target, up)
  local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
  local function norm(v)
    local l = math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
    if l == 0 then return { 0, 0, 0 } end
    return { v[1] / l, v[2] / l, v[3] / l }
  end
  local function cross(a, b)
    return { a[2] * b[3] - a[3] * b[2],
             a[3] * b[1] - a[1] * b[3],
             a[1] * b[2] - a[2] * b[1] }
  end
  local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end

  local f = norm(sub(target, eye))     -- forward
  local s = norm(cross(f, up))         -- right
  local u = cross(s, f)                -- true up
  return { s[1], s[2], s[3], -dot(s, eye),
           u[1], u[2], u[3], -dot(u, eye),
          -f[1], -f[2], -f[3], dot(f, eye),
           0, 0, 0, 1 }
end

function Mat4.lookAtInPlace(out, eye, target, up)
  local fx = target[1] - eye[1]
  local fy = target[2] - eye[2]
  local fz = target[3] - eye[3]
  local fl = math.sqrt(fx * fx + fy * fy + fz * fz)
  if fl > 0 then fx, fy, fz = fx / fl, fy / fl, fz / fl else fx, fy, fz = 0, 0, 0 end

  local sx = fy * up[3] - fz * up[2]
  local sy = fz * up[1] - fx * up[3]
  local sz = fx * up[2] - fy * up[1]
  local sl = math.sqrt(sx * sx + sy * sy + sz * sz)
  if sl > 0 then sx, sy, sz = sx / sl, sy / sl, sz / sl else sx, sy, sz = 0, 0, 0 end

  local ux = sy * fz - sz * fy
  local uy = sz * fx - sx * fz
  local uz = sx * fy - sy * fx

  local dotS = sx * eye[1] + sy * eye[2] + sz * eye[3]
  local dotU = ux * eye[1] + uy * eye[2] + uz * eye[3]
  local dotF = fx * eye[1] + fy * eye[2] + fz * eye[3]

  out[1], out[2], out[3], out[4]   = sx, sy, sz, -dotS
  out[5], out[6], out[7], out[8]   = ux, uy, uz, -dotU
  out[9], out[10], out[11], out[12] = -fx, -fy, -fz, dotF
  out[13], out[14], out[15], out[16] = 0, 0, 0, 1
  return out
end

return Mat4
