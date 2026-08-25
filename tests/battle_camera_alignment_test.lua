-- Reproject the solved tele/wide rigs against both generations' native slots.
local function check(condition, message)
  if not condition then error(message, 2) end
end

package.preload["src.core.GameVersion"] = function()
  return { generation = function() return 2 end }
end

local Mat4 = assert(loadfile("lib/Mat4.lua"))({})
local BattleCam = assert(loadfile("lib/BattleCam.lua"))({})

local function project(rig, z)
  local eye = { rig.side, rig.height, rig.back }
  local focus = { rig.lookX, rig.lookY, 0 }
  local dx, dy, dz = eye[1] - focus[1], eye[2] - focus[2], eye[3]
  local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
  local fov = 2 * math.atan((rig.frameH / 2) / dist)
  local view = Mat4.lookAt(eye, focus, { 0, 1, 0 })
  local projection = Mat4.perspective(fov, 160 / 144,
                                      math.max(1, dist * 0.05),
                                      dist * 4 + 4096)
  projection = Mat4.mul(Mat4.scale(1, -1, 1), projection)
  local vp = Mat4.mul(projection, view)
  local x = vp[3] * z + vp[4]
  local y = vp[7] * z + vp[8]
  local w = vp[15] * z + vp[16]
  return (x / w * 0.5 + 0.5) * 160,
         (y / w * 0.5 + 0.5) * 144
end

local function near(actual, expected, message)
  check(math.abs(actual - expected) < 0.03,
        ("%s (expected %.2f, got %.2f)"):format(message, expected, actual))
end

for _, name in ipairs({ "tele", "wide" }) do
  local rig = BattleCam.RIGS_GEN2[name]
  local px, py = project(rig, 24)
  local ex, ey = project(rig, -24)
  near(px, 40, name .. " Gen2 player X anchor")
  near(py, 96, name .. " Gen2 player Y anchor")
  near(ex, 124, name .. " Gen2 enemy X anchor")
  near(ey, 56, name .. " Gen2 enemy Y anchor")
end

package.loaded["src.core.GameVersion"] = nil
package.preload["src.core.GameVersion"] = nil

print("battle_camera_alignment_test: ok")
