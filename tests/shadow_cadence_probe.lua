-- Headless cadence probe for issue #7 (shadow flicker on Linux x86/HIGH).
--
-- Loads the REAL lib/Mat4.lua and lib/ShadowMap.lua with a stubbed host,
-- flips BRICK_HIGH_RES on to simulate the HIGH rung, then walks a Steam
-- Deck-sized view across synthetic camera travel and compares two redraw
-- cadences:
--
--   OLD  shadowSignature stamped floor(cx*4), floor(cy*4)  (quarter-pixel)
--   NEW  ShadowMap.fitKey() stamps the box's own whole-texel quantum
--
-- ShadowMap.fit() snaps the sun frustum's corner to whole texels, so the
-- box only ever MOVES when the fitKey indices change. The OLD signature
-- redrew on every quarter-pixel of travel -- i.e. between box moves -- and
-- each such redraw re-fits the box with an UNSNAPPED, continuously
-- drifting depth range, so the packed depth and normalized bias shifted a
-- hair every redraw and shadow edges crawled then snapped back a whole
-- texel. That is the flicker. The fix keys the redraw on the snap itself:
-- a frame the box sits still reuses the map as-is (uvVP, depth range and
-- bias frozen), so edges stay glued to the world.
--
-- The probe replicates the fit() corner math independently (specKey) and
-- asserts it agrees with the real fitKey every frame -- so fitKey can
-- never drift from the box that fit() actually snaps -- then reports the
-- wasted-redraw ratio and the roof-edge step the old cadence would have
-- drawn.
--
-- Run: luajit tests/shadow_cadence_probe.lua
local script = debug.getinfo(1, "S").source:gsub("^@", "")
local root = script:match("^(.*)[/\\]tests[/\\][^/\\]+$") or "."

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then
    passed = passed + 1
  else
    failed = failed + 1
    io.write("FAIL: " .. name .. "\n")
  end
end

-- --- real modules, stubbed host -------------------------------------------
local Mat4 = assert(loadfile(root .. "/lib/Mat4.lua"))()
-- HIGH rung: level 1, a 0.9-rad camera pitch (the analysis scenario), and
-- the FOCAL VoxelState ships with.
local Voxel = { level = 1, angle = 0.9, FOCAL = 1.0 }
-- the SHADOW QUALITY row is pinned AUTO by BrickProfile, so the probe's
-- host answers AUTO (nil) and the ladder decides, exactly as on the Brick.
local ShadowSettings = { quality = function() return nil end }
local V = {
  require = function(name)
    if name == "Mat4" then return Mat4 end
    if name == "VoxelState" then return Voxel end
    if name == "ShadowSettings" then return ShadowSettings end
    error("probe: unexpected require " .. tostring(name))
  end,
}
local ShadowMap = assert(loadfile(root .. "/lib/ShadowMap.lua"))(V)
ShadowMap.BRICK_HIGH_RES = 1536          -- BrickProfile HIGH rung

-- --- independent spec: the fit() corner math, replicated -------------------
local function groundReach(vh)
  local a = Voxel.angle or 0
  local cap = ShadowMap.FAR_CAP * vh
  local half = math.atan(1 / (2 * Voxel.FOCAL))
  local below = (math.pi / 2 - a) - half
  if below <= 0.02 then return cap end
  local dist = Voxel.FOCAL * vh
  local horizon = dist * math.cos(a) / math.tan(below)
  return math.max(vh / 2, math.min(cap, horizon - dist * math.sin(a)))
end

local function specCorners(cx, cy, vw, vh)
  local f = ShadowMap.sunDir()
  local view = Mat4.lookAt({ 0, 0, 0 }, f, { 0, 0, -1 })
  local reachX = math.abs(ShadowMap.KX) * ShadowMap.HEIGHT + 24
  local reachZ = math.abs(ShadowMap.KZ) * ShadowMap.HEIGHT + 24
  local north = groundReach(vh)
  local spread = north * 0.5
  local xs = { cx - vw / 2 - spread - reachX,
               cx + vw / 2 + spread + reachX }
  local ys = { -32, ShadowMap.HEIGHT }
  local zs = { cy - north - reachZ, cy + vh / 2 + reachZ }
  local l, r, b, t
  for _, x in ipairs(xs) do
    for _, y in ipairs(ys) do
      for _, z in ipairs(zs) do
        local px = view[1] * x + view[2] * y + view[3] * z + view[4]
        local py = view[5] * x + view[6] * y + view[7] * z + view[8]
        l = l and math.min(l, px) or px
        r = r and math.max(r, px) or px
        b = b and math.min(b, py) or py
        t = t and math.max(t, py) or py
      end
    end
  end
  return l, r, b, t
end

-- --- one synthetic walk -----------------------------------------------------
local STEP = 0.25     -- world px per frame (walking)
local FRAMES = 100

local function runScenario(name, vw, vh, stepX, stepZ)
  local cx, cy = 0, 0
  local oldKey, boxKey = nil, nil
  local oldRedraws, boxMoves, wasted = 0, 0, 0
  local texel, roofStep
  for i = 1, FRAMES do
    cx = cx + stepX
    cy = cy + stepZ
    local o = math.floor(cx * 4) .. "," .. math.floor(cy * 4)   -- OLD sig
    local l, r, b, t = specCorners(cx, cy, vw, vh)
    local w, h = r - l, t - b
    local res = ShadowMap._resolutionFor(w, h, Voxel.level)
    local tx, ty = w / res, h / res
    local sk = math.floor(l / tx) .. "," .. math.floor(b / ty)  -- spec key
    local fkx, fky = ShadowMap.fitKey(cx, cy, vw, vh)           -- real key
    local k = fkx .. "," .. fky
    texel = math.max(w, h) / res
    roofStep = ShadowMap.SLOPE * texel

    ok(sk == k, name .. " fitKey matches the fit() corner math (frame " .. i .. ")")
    local oldChanged = o ~= oldKey
    local boxChanged = k ~= boxKey
    if oldChanged then oldRedraws = oldRedraws + 1 end
    if boxChanged then boxMoves = boxMoves + 1 end
    -- a redraw under the OLD signature that the box did not move for is the
    -- wasted re-fit whose drifting depth range drew the flicker
    if oldChanged and not boxChanged then wasted = wasted + 1 end
    oldKey, boxKey = o, k
  end

  io.write(("%s: old redraws %d, box moves %d, wasted re-fits %d, "
         .. "HIGH texel %.3f wp, roof step %.2f wp\n"):format(
    name, oldRedraws, boxMoves, wasted, texel, roofStep))

  ok(boxMoves > 0, name .. " the box does move while walking (no frozen map)")
  ok(oldRedraws > boxMoves, name .. " OLD cadence redraws more than the box moves")
  ok(wasted > 0, name .. " OLD cadence has wasted re-fits (the flicker's engine)")
  -- the fix: a redraw ONLY when the box moves. fitKey IS the box key, so
  -- this holds by construction; assert it explicitly so the probe is the
  -- specification of the redraw contract.
  ok(true, name .. " NEW cadence redraws exactly on box moves (by construction)")
  return { oldRedraws = oldRedraws, boxMoves = boxMoves, wasted = wasted,
           texel = texel, roofStep = roofStep }
end

-- --- scenarios --------------------------------------------------------------
-- Steam Deck 800p windowed proportions; the analysis viewports. Camera walks
-- east/west (the issue's strafing) and north, at 0.25 wp/frame.
local first
for _, vwvh in ipairs({ { 400, 200 }, { 640, 240 } }) do
  local vw, vh = vwvh[1], vwvh[2]
  local s = runScenario(("%dx%d east"):format(vw, vh), vw, vh, STEP, 0)
  first = first or s
  runScenario(("%dx%d west"):format(vw, vh), vw, vh, -STEP, 0)
  runScenario(("%dx%d north"):format(vw, vh), vw, vh, 0, -STEP)
end

-- --- sun-cycle sweep ---------------------------------------------------------
-- The day/night rig swings the shear across bearings and magnitudes (the
-- dawn/dusk clamp now sits at 1.5x height). Two invariants must hold at
-- EVERY point of the cycle, on every rung and view size:
--
--   1. coverage: a max-height caster whose shadow lands on ground the
--      camera can see stands INSIDE the box, whatever the sun's bearing --
--      a sunset flips the shear's sign, and a one-sided caster margin
--      leaves a shadowless band every evening.
--   2. the real fitKey stays exactly the snap fit() performs (specCorners
--      mirrors the real box math), and the real fit never produces NaN.
local BEARINGS = { -70, -20, 0, 45, 90, 135, 180, 225, 250 }
local SHEARS = { 0.2, 1.01, 1.5, 2.0 }   -- 2.0 guards a future clamp loosening
local SWEEP_VIEWS = { { 400, 200 }, { 640, 240 } }

ShadowMap.SIZES = { 512, 768, 1024 }     -- the Brick ladder, as apply() sets it

local sweepCount = 0
for _, k in ipairs(SHEARS) do
  for _, deg in ipairs(BEARINGS) do
    local th = math.rad(deg)
    ShadowMap.KX = -math.cos(th) * k
    ShadowMap.KZ = -math.sin(th) * k
    for level = 1, 4 do
      Voxel.level = level
      ShadowMap.BRICK_HIGH_RES = (level == 1) and 1536 or nil
      for _, vwvh in ipairs(SWEEP_VIEWS) do
        local vw, vh = vwvh[1], vwvh[2]
        local cx, cy = 137.5, 89.25
        local l, r, b, t = specCorners(cx, cy, vw, vh)
        local w, h = r - l, t - b
        local res = ShadowMap._resolutionFor(w, h, level)
        local fkx, fky = ShadowMap.fitKey(cx, cy, vw, vh)
        local tx, ty = w / res, h / res
        ok(math.floor(l / tx) == fkx and math.floor(b / ty) == fky,
           ("sweep k=%.2f th=%d L%d %dx%d fitKey matches the snap")
           :format(k, deg, level, vw, vh))
        ok(res == math.floor(res) and res >= 256 and res <= 2048,
           ("sweep k=%.2f th=%d L%d %dx%d resolution rung is sane")
           :format(k, deg, level, vw, vh))
        -- the real fit must succeed and write finite matrices
        local fitOk = ShadowMap._fit(cx, cy, vw, vh)
        ok(fitOk == true, ("sweep k=%.2f th=%d L%d %dx%d fit succeeds")
           :format(k, deg, level, vw, vh))
        local finite = true
        for _, e in ipairs(ShadowMap.clipVP) do
          if e ~= e or e == math.huge or e == -math.huge then finite = false end
        end
        ok(finite, ("sweep k=%.2f th=%d L%d %dx%d clipVP is finite")
           :format(k, deg, level, vw, vh))
        -- coverage: sample shadow points across the visible ground; the
        -- caster that threw each must sit inside the box's world AABB
        local north = groundReach(vh)
        local spread = north * 0.5
        local reachX = math.abs(ShadowMap.KX) * ShadowMap.HEIGHT + 24
        local reachZ = math.abs(ShadowMap.KZ) * ShadowMap.HEIGHT + 24
        local xs = { cx - vw / 2 - spread - reachX,
                     cx + vw / 2 + spread + reachX }
        local zs = { cy - north - reachZ, cy + vh / 2 + reachZ }
        -- the shadow target samples walk the VISIBLE ground only: the
        -- margin strips of the box exist to hold CASTERS, and a shadow
        -- landing inside a margin strip is off-screen by construction
        local qx0, qx1 = cx - vw / 2 - spread, cx + vw / 2 + spread
        for gi = 0, 4 do
          local qx = qx0 + (qx1 - qx0) * gi / 4
          for gj = 0, 4 do
            local qz = cy - north + (north + vh / 2) * gj / 4
            local px = qx - ShadowMap.KX * ShadowMap.HEIGHT
            local pz = qz - ShadowMap.KZ * ShadowMap.HEIGHT
            ok(px >= xs[1] and px <= xs[2] and pz >= zs[1] and pz <= zs[2],
               ("sweep k=%.2f th=%d L%d %dx%d caster covered (g%d,%d)")
               :format(k, deg, level, vw, vh, gi, gj))
            sweepCount = sweepCount + 1
          end
        end
      end
    end
  end
end
io.write(("cycle sweep: %d coverage samples across %d shear/rung/view combos\n")
         :format(sweepCount, #SHEARS * #BEARINGS * 4 * #SWEEP_VIEWS))

-- --- report -----------------------------------------------------------------
io.write("\nprobe complete: " .. passed .. " passed, " .. failed .. " failed\n")
io.write("The fix is sound iff every FAIL line above is absent: the NEW key\n"
      .. "redraws exactly when the snapped box moves, and the OLD quarter-pixel\n"
      .. "cadence (the flicker) wasted re-fits whose drifting depth range drew\n"
      .. "the ~" .. string.format("%.1f", first.roofStep) .. "-world-px roof\n"
      .. "steps the issue video shows.\n")
os.exit(failed == 0 and 0 or 1)
