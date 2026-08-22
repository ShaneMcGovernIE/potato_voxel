-- Headless golden for the shadow pass (the capture half of the shadow
-- screenshot pipeline, minus the GPU: the engine has no headless capture
-- path at all, so the golden pins the EXACT numbers the pass would feed a
-- GPU -- the fitted box, the snap, the resolution rung, the comparison
-- slack/bias and the snug matrix). Values are compared with a 1e-4
-- relative tolerance (libm trig differs by ULPs between macOS and Linux,
-- and anything below that is float noise, not a fit regression), so the
-- comparison is boundary-free; a structural change (a margin, a bias,
-- the snap) moves a value by orders of magnitude more and fails CI.
--
--     luajit tests/shadow_golden.lua --bless
--
-- Scenarios sweep the day/night rig's own extremes (sunrise, noon, sunset,
-- the moon) across the voxel rungs and two view sizes, so a sun that moves
-- (or a clamp that loosens) cannot silently drift the pass.

local script = debug.getinfo(1, "S").source:gsub("^@", "")
local root = script:match("^(.*)[/\\]tests[/\\][^/\\]+$") or "."

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: " .. name .. "\n") end
end

local Mat4 = assert(loadfile(root .. "/lib/Mat4.lua"))()
local Voxel = { level = 1, angle = 0.9, FOCAL = 1.0 }
local ShadowSettings = { quality = function() return nil end }
local V = {
  require = function(name)
    if name == "Mat4" then return Mat4 end
    if name == "VoxelState" then return Voxel end
    if name == "ShadowSettings" then return ShadowSettings end
    if name == "Platform" then
      return { isIOS = function() return false end }
    end
    if name == "PixelCanvas" then
      return assert(loadfile(root .. "/lib/PixelCanvas.lua"))(V)
    end
    error("golden: unexpected require " .. tostring(name))
  end,
}
local ShadowMap = assert(loadfile(root .. "/lib/ShadowMap.lua"))(V)
ShadowMap.SIZES = { 512, 768, 1024 }

local function fmt(m)
  local parts = {}
  for i = 1, #m do parts[i] = string.format("%.6g", m[i]) end
  return table.concat(parts, ",")
end

local function scenario(label, kx, kz, level, vw, vh, cx, cy)
  ShadowMap.KX, ShadowMap.KZ = kx, kz
  Voxel.level = level
  ShadowMap.BRICK_HIGH_RES = (level == 1) and 1536 or nil
  local fitOk = ShadowMap._fit(cx, cy, vw, vh)
  ok(fitOk == true, label .. " fits")
  if not fitOk then return nil end
  local snug = ShadowMap.snug(nil)
  local fkx, fky = ShadowMap.fitKey(cx, cy, vw, vh)
  return table.concat({ label, tostring(ShadowMap.res),
                        fmt(ShadowMap.clipVP), fmt(ShadowMap.uvVP),
                        fmt(snug),
                        string.format("%.6g", ShadowMap.slack),
                        string.format("%.6g", ShadowMap.bias),
                        tostring(fkx), tostring(fky) }, "|")
end

local function parse(line)
  local f = {}
  for part in line:gmatch("[^|]+") do f[#f + 1] = part end
  return f
end

local function closeEnough(got, want)
  local a, b = tonumber(got), tonumber(want)
  if a and b then
    local scale = math.max(1, math.abs(a), math.abs(b))
    return math.abs(a - b) <= 1e-4 * scale
  end
  -- a matrix field is one comma-joined string: compare element-wise
  if type(got) == "string" and type(want) == "string"
     and got:find(",", 1, true) then
    local ga, wa = {}, {}
    for v in got:gmatch("[^,]+") do ga[#ga + 1] = v end
    for v in want:gmatch("[^,]+") do wa[#wa + 1] = v end
    if #ga ~= #wa then return false end
    for i = 1, #ga do
      if not closeEnough(ga[i], wa[i]) then return false end
    end
    return true
  end
  return got == want
end

local lines = {}
local suns = {
  { "rise",  -math.cos(math.rad(-70)) * 1.5, -math.sin(math.rad(-70)) * 1.5 },
  { "noon",  -0.85, -0.55 },
  { "set",   -math.cos(math.rad(250)) * 1.5, -math.sin(math.rad(250)) * 1.5 },
  { "moon",  -math.cos(math.rad(-90)) * 1.19, -math.sin(math.rad(-90)) * 1.19 },
}
local cameras = { { 137.5, 89.25 }, { 300.125, 44.75 } }
for _, v in ipairs({ { 400, 200 }, { 640, 240 } }) do
  for level = 1, 4 do
    for _, s in ipairs(suns) do
      for ci, cam in ipairs(cameras) do
        local label = ("%dx%d L%d %s c%d"):format(v[1], v[2], level, s[1], ci)
        local line = scenario(label, s[2], s[3], level, v[1], v[2], cam[1], cam[2])
        if line then lines[#lines + 1] = line end
      end
    end
  end
end

local goldenPath = root .. "/tests/goldens/shadow_golden.txt"
local bless = (arg and arg[1] == "--bless") or false
if bless then
  local f = io.open(goldenPath, "wb")
  f:write(table.concat(lines, "\n") .. "\n")
  f:close()
  io.write("blessed " .. #lines .. " shadow golden lines\n")
else
  local want = {}
  local f = io.open(goldenPath, "rb")
  if f then
    for line in f:read("*a"):gmatch("[^\n]+\n?") do
      line = line:gsub("\n", "")
      if line ~= "" then want[line:match("^[^|]+")] = parse(line) end
    end
    f:close()
  end
  ok(next(want) ~= nil, "a golden file exists (run --bless to create it)")
  local missing = 0
  for _, line in ipairs(lines) do
    local got = parse(line)
    local w = want[got[1]]
    if not w then
      missing = missing + 1
      io.write("DIFF: no golden for " .. got[1] .. "\n")
    else
      local n = math.max(#got, #w)
      for i = 2, n do
        if not closeEnough(got[i], w[i]) then
          missing = missing + 1
          io.write("DIFF: " .. got[1] .. " field " .. i .. " "
                   .. tostring(got[i]) .. " vs " .. tostring(w[i]) .. "\n")
          break
        end
      end
    end
  end
  ok(missing == 0, "every scenario matches its golden within tolerance")
  io.write(("golden: %d lines checked, %d mismatches\n"):format(#lines, missing))
end

io.write("shadow golden: " .. passed .. " passed, " .. failed .. " failed\n")
os.exit(failed == 0 and 0 or 1)
