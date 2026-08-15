-- Voxel world mode: the sun's own pass -- a real shadow map.
--
-- The old drop shadows were decals: each character's sprite frame squashed
-- flat onto the ground plane it stood on. That can only ever paint the
-- FLOOR, so a shadow stopped dead at the foot of a wall, and nothing but a
-- character cast one at all -- buildings, trees, signs and ledges threw
-- nothing.
--
-- So render the scene once from the sun instead. An orthographic camera
-- pointed down the sun line stores, per texel, how far the light travelled
-- before it hit something; the main pass transforms each fragment into that
-- same space and asks whether anything got there first. What the sun cannot
-- see is in shadow, whatever surface it happens to be -- so a shadow climbs
-- a wall, drapes over a roof and slides across a passing NPC without a
-- single case in the code, and every caster is simply whatever the pass
-- draws: the terrain mesh (buildings, trees, ledges, props -- all of it)
-- plus one upright card per character.
--
-- Depth is stored in an ORDINARY color canvas, packed into two 8-bit
-- channels (~16 bits over the frustum, well under a tenth of a world
-- pixel). A readable depth texture would be tidier, but depth sampling is
-- the least portable corner of the graphics API and this mod's whole
-- contract is that an unsupported driver falls back rather than errors --
-- everything here is pcall-guarded and `available()` reports the result,
-- with VoxelScene dropping back to the flat decal shadows when it says no.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Mat4 = V.require("Mat4")
local Voxel = V.require("VoxelState")
local ShadowSettings = V.require("ShadowSettings")

local ShadowMap = {}

-- The sun, as the shear a shadow takes: a point `y` world-pixels above the
-- ground drops its shadow (KX*y, KZ*y) away from the point under it. Both
-- negative hangs the sun in the SOUTHEAST, so every shadow falls northwest
-- -- up and to the left on screen, since the camera puts north at the top
-- and east to the right at every tilt.
--
-- Their MAGNITUDE is how low the sun sits: hypot(KX, KZ) = 1.01 puts it
-- about 45 degrees up, so a 16px character throws a shadow about as long
-- as it is tall -- against the 62-degree noon these started at, which read
-- as a smudge under everybody's feet.
--
-- Their RATIO is the compass bearing, and it leans WEST of northwest on
-- purpose. A character is drawn as a slab leaning back away from the
-- camera, which covers the ground directly north of its feet -- so a
-- shadow thrown due north lands entirely underneath the figure casting it
-- and is never seen. At 0.85 west the shadow reaches 13px out against the
-- sprite's own 8px half-width, so it clears the slab and reads, while 0.55
-- north still puts it a clear 23 degrees up from horizontal on screen.
ShadowMap.KX = -0.85      -- west drift per pixel of height
ShadowMap.KZ = -0.55      -- north drift per pixel of height

-- Shadow map edge, in texels -- chosen per frame from this ladder, because
-- the light frustum is sized to the WORLD VIEW and that swings by 3x
-- between the closest zoom and a maximised window at the widest. A fixed
-- edge is either wasteful at one end or a blur at the other.
--
-- TARGET is the world pixels per texel worth paying for: at a third of a
-- pixel a shadow edge lands inside the pixel grid this whole mode exists
-- to keep crisp, and finer buys nothing the grid can show. The smallest
-- size that meets it wins, and the ladder tops out at 2048 (16 MB, and the
-- depth buffer behind it matches) rather than chasing the target forever.
ShadowMap.SIZES = { 1024, 1536, 2048 }
ShadowMap.TARGET = 0.45
-- The moving-actor layer is available on every device. VoxelScene gates it
-- by quality rung: HIGH uses the full two-layer map, while MEDIUM and lower
-- fall back to the contact/blob decals for actors.
ShadowMap.SPRITE_LAYER = true
-- BrickProfile sets this only for its HIGH rung. The fit is otherwise sized
-- from SIZES, so desktop keeps the full adaptive ladder and lower Brick rungs
-- keep their reduced ladder.
ShadowMap.BRICK_HIGH_RES = nil

-- Choose the square shadow-map edge for a fitted frustum. Kept separate from
-- fit() so the profile's HIGH-size guarantee can be tested without a GPU.
--
-- The player's SHADOW QUALITY row wins first: a fixed rung (512/1024/2048)
-- forces the map's edge whatever the view, and returns before the profile
-- guarantees or the adaptive ladder can speak. AUTO (nil) falls through to
-- the existing choice -- the Brick HIGH guarantee, then the ladder.
function ShadowMap._resolutionFor(w, h, level)
  local fixed = ShadowSettings.quality()
  if fixed then return fixed end
  if level == 1 and ShadowMap.BRICK_HIGH_RES then
    return ShadowMap.BRICK_HIGH_RES
  end
  local res = ShadowMap.SIZES[#ShadowMap.SIZES]
  for _, size in ipairs(ShadowMap.SIZES) do
    if math.max(w, h) / size <= ShadowMap.TARGET then
      res = size
      break
    end
  end
  return res
end

-- Whether the optional actor layer participates in the current quality rung.
-- SPRITE_LAYER is the capability/allocation switch; this per-frame gate keeps
-- MEDIUM and lower modes from sampling a stale HIGH actor map after a rung
-- change, while retaining the canvas so HIGH can resume without rebuilding
-- the world layer.
local actorLayerActive = true
ShadowMap.res = 1024      -- the rung in use; read by the main pass's filter

-- The tallest geometry the pass covers: gabled buildings and border forest
-- run well under this, and the margin it buys costs only resolution --
-- with the sun this low the frustum has to widen by most of HEIGHT again
-- on every side to catch what casts in from off-screen.
ShadowMap.HEIGHT = 160

-- Depth slack at the comparison, in world pixels. Too little and a lit
-- surface shadows itself in a moire of acne; too much and a shadow detaches
-- from the foot of what casts it. The frustum is ~400 world pixels deep and
-- the packed depth resolves under 0.01 of one, so there is room.
--
-- It cannot be ONE number, because what the comparison has to forgive is
-- not fixed: the map stores one depth for a whole texel, so a lit surface
-- reads its own depth wrong by however far it RAMPS across that texel --
-- the texel's world size times the surface's slope in the light's frame.
-- The texel swings from a third of a world pixel at the closest zoom to
-- well over one at a maximised window on the widest, so a constant bias is
-- generous at one end of the ladder and short at the other. Short shows up
-- as diagonal bands of acne across big lit surfaces -- diagonal because
-- the moire runs along neither the world grid nor the screen's, but along
-- the depth ramp in the sun's own frame, and the sun sits southeast.
--
-- So: a floor for what does not scale (the packed depth's quantisation,
-- and the two passes reaching the same world point by different matrices),
-- plus a term in texels for what does.
ShadowMap.BIAS = 0.5

-- World pixels of slack per world pixel of texel, for the steepest LIT
-- surface here: a roof pitched 45 degrees and turned away from the sun,
-- whose depth ramps about 3.1 world pixels per texel crossed on EITHER of
-- the light frame's two axes (a vertical wall, by comparison, manages 1.7,
-- flat ground 0.7, and anything steeper than that roof has its back to the
-- sun and never reads the map at all). The 2x2 filter's taps sit half a
-- texel out on both axes at once, so the worst a tap can disagree by is
-- half the ramp along each -- which is where the halving that turns 6.2
-- into 3.1 comes from, and why it is the SUM of the two components rather
-- than their magnitude.
--
-- Measured against the artefact rather than trusted: the probe
-- (tests/voxel_acne_probe.lua) counts isolated shadowed pixels on lit
-- surfaces, and the banding stops at slack ~2.4 world px on the widest
-- rung -- where this lands 3.1 * 0.83 + 0.5.
ShadowMap.SLOPE = 3.1

-- The slack `fit` last worked out, in world pixels -- BIAS + SLOPE*texel.
-- Read by probes; `ShadowMap.bias` is the same number as the [0,1] depth
-- the map actually stores.
ShadowMap.slack = ShadowMap.BIAS

local SHADER = [[
  varying float vDepth;
#ifdef VERTEX
  uniform mat4 lightVP;
  uniform mat4 model;
  vec4 position(mat4 transform_projection, vec4 vertex_position) {
    vec4 c = lightVP * (model * vertex_position);
    // the projection is orthographic, so w is 1 and clip z IS the depth,
    // linear in world units along the sun line
    // A degenerate fit can put NaN into the matrix. NaN compares false in
    // GLSL, so it would sail through every downstream guard and poison the
    // packed map -- a depth of NaN reads as "everything is shadowed" on
    // Mali-family GPUs, which is a black screen. Store the far depth
    // (cast nothing) instead.
    vDepth = (c.z == c.z) ? (c.z * 0.5 + 0.5) : 1.0;
    return c;
  }
#endif
#ifdef PIXEL
  uniform float sprite;   // 1 while the CAST is being drawn; see ShadowMap.sprites
  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    // the same alpha discard the main pass uses: a sprite card casts its
    // silhouette, not its 16x16 bounding box
    if (Texel(tex, tc).a < 0.5) discard;
    // pack into two channels: the high byte in red, the low in green.
    // Blue says WHAT cast this, which costs a channel that was zero anyway
    // and lets a surface decline one kind of caster -- water does, for the
    // people (see Water's sunLit).
    float d = clamp(vDepth, 0.0, 1.0) * 255.0;
    return vec4(floor(d) / 255.0, fract(d), sprite, 1.0);
  }
#endif
]]

ShadowMap._source = function() return SHADER end   -- named for the suite

local shader = nil            -- nil = untried, false = unavailable
local canvas = nil            -- nil = untried, false = unavailable
local canvasRes = 0           -- the edge `canvas` was made at
local spriteCanvas = nil      -- the CAST layer: sprites only (see below)
local blank = nil             -- 1x1 stand-in so the sampler is never unbound
local drawing = false         -- world layer open (beginWorld)
local drawingSprites = false  -- sprite layer open (beginSprites)
local ready = false
local spritesReady = false
local lastSig = nil
local lastSpriteSig = nil
local prevBlend, prevAlphaMode = nil, nil

local IDENTITY = Mat4.identity()

-- world -> [0,1] cube, applied on top of the clip matrix: the main pass
-- samples the map with the xy and compares against the z
local TO_UNIT = { 0.5, 0, 0, 0.5,
                  0, 0.5, 0, 0.5,
                  0, 0, 0.5, 0.5,
                  0, 0, 0, 1 }

-- world -> light clip space, for the pass that FILLS the map
ShadowMap.clipVP = IDENTITY
-- world -> the unit cube, for the pass that READS it
ShadowMap.uvVP = IDENTITY
-- ShadowMap.BIAS expressed in the [0,1] depth the map stores
ShadowMap.bias = 0

local getBlank

-- Mediatek/Mali detection. On Mali GPUs the blob-decal actor path (the
-- fallback MEDIUM and lower rungs use) misbehaves -- frozen last frame,
-- black frames, no actor shadow at all -- while the HIGH configuration
-- (the sprite-layer map) works. BrickProfile reads this to give every
-- active rung the HIGH shadow path on such devices. Cached; the result
-- cannot change mid-session.
local maliDevice = nil
function ShadowMap.isMali()
  if maliDevice ~= nil then return maliDevice end
  maliDevice = false
  if love and love.graphics and love.graphics.getRendererInfo then
    local ok, info = pcall(love.graphics.getRendererInfo)
    if ok and info and info.name then
      maliDevice = info.name:lower():find("mali", 1, true) ~= nil
    end
  end
  return maliDevice
end
-- Test seam: forget the cached answer so the suite can stub a device.
function ShadowMap._maliReset()
  maliDevice = nil
end

local function getShader()
  if shader == nil then
    local ok, sh = pcall(love.graphics.newShader, SHADER)
    shader = (ok and sh) or false
  end
  return shader or nil
end

-- The map canvas at edge `res`, rebuilt when the rung changes (a zoom
-- step, a window resize). `false` is sticky: a driver that could not make
-- one at all is not asked again every frame.
--
-- TWO layers share the rung. The WORLD layer holds everything that does
-- not move by itself -- terrain, neighbours, water, flowers, figures --
-- and is re-rasterised only when the camera, the sun or the world moves.
-- The SPRITE layer holds the cast (posed characters, battle cards), which
-- animates every frame a character idles or walks. Splitting them means
-- a standing player (or a dialog, or a menu) no longer re-rasterises the
-- whole world from the sun on every idle frame: only the handful of
-- sprite cards redraw. The main pass samples both and ANDs them, which is
-- exactly the single-map depth test -- a fragment is lit only when
-- nothing closer along the sun ray sits in EITHER layer.
local function getCanvas(res)
  if canvas == false then return nil end
  if canvas and canvasRes == res then return canvas end
  local ok, c = V.require("PixelCanvas").new(res, res)
  if not (ok and c) then
    canvas = false
    return nil
  end
  -- nearest: the 2x2 filter in the main pass wants raw texels, and a
  -- linearly blended PACKED depth is not a depth at all
  c:setFilter("nearest", "nearest")
  pcall(c.setWrap, c, "clamp", "clamp")
  if canvas and canvas.release then pcall(canvas.release, canvas) end
  canvas, canvasRes = c, res
  ready = false
  if spriteCanvas and spriteCanvas.release then
    pcall(spriteCanvas.release, spriteCanvas)
  end
  if ShadowMap.SPRITE_LAYER then
    local okS, sc = V.require("PixelCanvas").new(res, res)
    if okS and sc then
      sc:setFilter("nearest", "nearest")
      pcall(sc.setWrap, sc, "clamp", "clamp")
      spriteCanvas = sc
    else
      spriteCanvas = false
    end
  else
    spriteCanvas = false
  end
  spritesReady = false
  return canvas
end

-- A 1x1 opaque white image. The main pass's shader always declares the
-- shadow sampler, so something has to be bound even on the frames (and the
-- drivers) where there is no map -- unpacked it reads as depth 1 + 1/255,
-- which is beyond the far plane and therefore "nothing occludes anything".
getBlank = function()
  if blank == nil then
    local ok, img = pcall(function()
      local data = love.image.newImageData(1, 1)
      data:setPixel(0, 0, 1, 1, 1, 1)
      return love.graphics.newImage(data)
    end)
    blank = (ok and img) or false
  end
  return blank or nil
end

local unavailable = nil    -- why available() last answered false

-- Whether the sun pass can run at all. False headless, without shaders, or
-- where the canvas cannot be made -- VoxelScene then keeps the flat decal
-- shadows, which need nothing but a quad. A false answer is sticky for the
-- session (a driver does not grow a capability mid-session) and records
-- WHY, so a "shadows not appearing" report names the gate instead of the
-- player guessing.
function ShadowMap.available()
  if unavailable then return false end
  if not (love.graphics and love.graphics.newCanvas
          and love.graphics.setDepthMode) then
    unavailable = "no canvas/depth-mode graphics API"
    return false
  end
  -- the smallest rung is enough to answer the question; fit() picks the
  -- one this frame actually wants
  if getShader() == nil then
    unavailable = "the shadow shader did not compile"
    return false
  end
  if getCanvas(ShadowMap.SIZES[1]) == nil then
    unavailable = "the shadow canvas could not be allocated"
    return false
  end
  return true
end

-- Why the sun pass cannot run, for diagnostics; nil while it can. A player
-- report can carry this string straight into the issue tracker.
function ShadowMap.unavailableReason()
  if ShadowMap.available() then return nil end
  return unavailable
end

-- The map to sample, or the blank stand-in. Never nil once the main pass
-- has a shader at all, because an unbound sampler is a driver-dependent
-- crash rather than a driver-dependent fallback. `sprites` picks the
-- CAST layer (posed characters, battle cards); the default is the WORLD
-- layer (terrain, water, flowers, figures).
function ShadowMap.texture(sprites)
  if sprites and (not ShadowMap.SPRITE_LAYER or not actorLayerActive) then
    return getBlank()
  end
  local c = sprites and spriteCanvas or canvas
  if (sprites and spritesReady or (not sprites and ready)) and c then
    return c
  end
  return getBlank()
end

-- True while the map holds a frame the main pass can read.
function ShadowMap.active(sprites)
  if sprites then
    return ShadowMap.SPRITE_LAYER and actorLayerActive
       and spritesReady and spriteCanvas ~= nil and spriteCanvas ~= false
  end
  return ready and canvas ~= nil and canvas ~= false
end

-- Force both layers inactive without drawing: the main pass then sends
-- sunDark=0 and the blank stand-in, so a frame with shadows disabled
-- (the brick's LOW rung) renders flat-lit. The signatures are left
-- alone -- the next begin() redraws both layers from scratch.
function ShadowMap.off()
  ready = false
  spritesReady = false
end

-- The two layers share the sun, the box and the bias: both are filled
-- under the same lightVP, so one bias serves both compares. The main
-- pass ANDs the two depth tests (a fragment is shadowed if either layer
-- has something closer to the sun), which is exactly the single-map
-- result: the world layer holds everything that does not move by itself,
-- the sprite layer only the cast that animates -- so a standing player
-- redraws a handful of cards instead of the whole world.
ShadowMap.spritesReady = function() return spritesReady end
ShadowMap.spriteLayerEnabled = function() return ShadowMap.SPRITE_LAYER and actorLayerActive end
ShadowMap.actorLayerActive = function() return actorLayerActive end
function ShadowMap.setSpriteLayerActive(enabled)
  actorLayerActive = not not enabled
end

-- The direction the light TRAVELS, normalized. The shear is the shadow a
-- unit of height throws, so the displacement from a point to where its
-- shadow lands is (KX, -1, KZ) -- which is the ray.
local function sunDir()
  local x, y, z = ShadowMap.KX, -1, ShadowMap.KZ
  local l = math.sqrt(x * x + y * y + z * z)
  return { x / l, y / l, z / l }
end

ShadowMap.sunDir = sunDir

-- How far NORTH of the view centre the camera can still see ground, in
-- world pixels: the top edge of the view frustum dropped onto the ground
-- plane. The lower the camera the further that reaches, and past about 64
-- degrees the ray clears the horizon and the honest answer is "forever" --
-- hence the cap. Ground beyond it compresses into a few pixels near the
-- skyline, and its shadows with it, so the border fade in the main pass
-- eases them out rather than the frustum ending on a hard line.
ShadowMap.FAR_CAP = 2.5     -- multiples of the view height

local function groundReach(vh)
  local a = Voxel.angle or 0
  local cap = ShadowMap.FAR_CAP * vh
  -- half the vertical field of view: the same FOCAL the camera projects
  -- with, so the two frusta agree about what is on screen
  local half = math.atan(1 / (2 * Voxel.FOCAL))
  local below = (math.pi / 2 - a) - half     -- top ray, below horizontal
  if below <= 0.02 then return cap end
  local dist = Voxel.FOCAL * vh
  local horizon = dist * math.cos(a) / math.tan(below)
  return math.max(vh / 2, math.min(cap, horizon - dist * math.sin(a)))
end

-- Fit the light frustum to the ground the camera can see, plus the margin
-- the casters for it stand in.
--
-- Both are ASYMMETRIC, and for opposite reasons. The camera sits south of
-- its focus and looks north, so the ground it sees runs far north and
-- barely south. The sun sits southeast, so the things whose shadows land
-- on that ground stand south and east of it -- which means the caster
-- margin is only ever needed on two of the four sides. Paying for it on
-- all four (and for a view-sized box at every pitch) is what the first cut
-- did, and at 75 degrees it covered about a third of what was on screen.
--
-- The box is snapped to whole texels. Without that, a frustum that slides
-- continuously with the camera reprojects every shadow edge a fraction of a
-- texel every frame and the whole world's shadows crawl and shimmer while
-- you walk.
-- The light-space box the sun pass will cover: the view's slice of the
-- world sheared into the sun's frame. Returns the lateral bounds the ortho
-- projection maps onto the map (l, r, b, t), the depth span it maps into
-- (zn, zf) and the view matrix itself. Pure Lua (no GPU), so the same math
-- can stamp the shadow signature -- see fitKey -- without touching a
-- canvas.
local function boxCorners(cx, cy, vw, vh)
  local f = sunDir()
  local view = Mat4.lookAt({ 0, 0, 0 }, f, { 0, 0, -1 })

  -- The caster margin, paid on BOTH sides of each axis. The day/night rig
  -- swings the sun across the sky, and a sunset (or moonrise) flips the
  -- shear's sign: shadows that fell northwest at noon fall southeast at
  -- dusk. A caster margin paid only on the noon side (east/south) left the
  -- off-screen casters of the other side un-drawn, so a tall border tree
  -- just past the horizon threw its sunset shadow into view and the map
  -- had no record of it -- a hard shadowless band each evening. The
  -- symmetric margin costs a little resolution (the box grows) and covers
  -- every bearing the rig can choose.
  local reachX = math.abs(ShadowMap.KX) * ShadowMap.HEIGHT + 24
  local reachZ = math.abs(ShadowMap.KZ) * ShadowMap.HEIGHT + 24
  local north = groundReach(vh)
  -- the view widens with distance, so the far ground spans more than the
  -- near ground does; half the depth is a serviceable stand-in for the
  -- frustum's true spread and costs a good deal less resolution
  local spread = north * 0.5
  local xs = { cx - vw / 2 - spread - reachX,
               cx + vw / 2 + spread + reachX }
  local ys = { -32, ShadowMap.HEIGHT }         -- -32 covers recessed water
  local zs = { cy - north - reachZ, cy + vh / 2 + reachZ }

  local l, r, b, t, zn, zf
  for _, x in ipairs(xs) do
    for _, y in ipairs(ys) do
      for _, z in ipairs(zs) do
        local px = view[1] * x + view[2] * y + view[3] * z + view[4]
        local py = view[5] * x + view[6] * y + view[7] * z + view[8]
        local pz = view[9] * x + view[10] * y + view[11] * z + view[12]
        l = l and math.min(l, px) or px
        r = r and math.max(r, px) or px
        b = b and math.min(b, py) or py
        t = t and math.max(t, py) or py
        zn = zn and math.min(zn, pz) or pz
        zf = zf and math.max(zf, pz) or pz
      end
    end
  end

  return l, r, b, t, zn, zf, view
end

-- The light frustum's own texel quantum, as the whole-texel indices of the
-- snapped box corner. fit() snaps the corner to texel multiples (below), so
-- the box can only ever move when these two change -- and a signature that
-- decides when to redraw the map must stamp exactly these, not a finer
-- camera quantum. Redrawing on every quarter-pixel of travel re-fits the
-- box between moves, and because the depth range is NOT part of the snap
-- (it is a continuous function of the camera) that re-fit slides the packed
-- depth and normalized bias a hair each time: shadow edges crawl a little,
-- then snap back a whole texel when the corner finally lands on the next
-- multiple. Keying the redraw on the snap itself means a frame between box
-- moves reuses the map as-is -- uvVP, depth range and bias all frozen -- so
-- edges stay glued to the world. Pure Lua (no GPU), so the per-frame
-- signature can afford it. The box's SIZE follows from vw/vh/pitch/sun,
-- which are separate signature terms, so the corner indices plus those
-- terms identify the whole snapped box.
function ShadowMap.fitKey(cx, cy, vw, vh)
  local l, r, b, t = boxCorners(cx, cy, vw, vh)
  local w, h = r - l, t - b
  local res = ShadowMap._resolutionFor(w, h, Voxel.level)
  local tx, ty = w / res, h / res
  return math.floor(l / tx), math.floor(b / ty)
end

-- Whether a fitted box can be projected at all. Exported so the suite can
-- probe the exact guard: zero, negative or NaN extents (a camera mid-tween,
-- a half-initialised view) would otherwise write inf/NaN into clipVP and
-- uvVP, and every fragment the main pass looked up would read a poisoned
-- depth -- the black-screen-on-Mediatek report.
function ShadowMap._degenerate(w, h, near, far)
  return not (w > 0 and h > 0 and far > near)
end

-- The comparison slack (world pixels) a fitted map needs for a texel of
-- `texel` world pixels under a sun whose shear is (kx, kz). BIAS covers the
-- packed depth's quantisation; the SLOPE term covers the worst lit surface's
-- depth ramp across a texel -- and that ramp grows as the sun sinks toward
-- the horizon: a roof pitched away from a grazing sun ramps far faster than
-- under the noon the calibration was measured at. The shear magnitude IS the
-- cotangent of the elevation, so the noon shear (hypot 1.01) scales by 1
-- and the dawn/dusk clamp (2.0) doubles the slope term. Kept pure so the
-- suite can hold the calibration, and never narrower than noon -- an even
-- higher sun only flattens the ramps.
function ShadowMap._slackFor(texel, kx, kz)
  local grazing = math.sqrt((kx or 0) * (kx or 0) + (kz or 0) * (kz or 0))
  grazing = math.max(1, grazing / 1.01)
  return ShadowMap.BIAS + ShadowMap.SLOPE * (texel or 0) * grazing
end

local function fit(cx, cy, vw, vh)
  local l, r, b, t, zn, zf, view = boxCorners(cx, cy, vw, vh)

  local w, h = r - l, t - b

  -- pick the resolution rung: Brick HIGH is deliberately fixed at 1536;
  -- every other rung keeps the adaptive ladder for its profile.
  local res = ShadowMap._resolutionFor(w, h, Voxel.level)
  ShadowMap.res = res

  -- the box's SIZE is fixed (the sun and the view size are), so snapping
  -- its corner to a texel multiple moves it in whole texels only
  local tx, ty = w / res, h / res
  l = math.floor(l / tx) * tx
  b = math.floor(b / ty) * ty
  r, t = l + w, b + h

  -- view-space z runs NEGATIVE into the scene; ortho() wants distances,
  -- and the slack keeps geometry taller than HEIGHT from being clipped
  -- clean out of the pass instead of merely casting a truncated shadow
  local near, far = -zf - 64, -zn + 64
  -- A degenerate frustum (NaN or non-positive extents) must NOT update the
  -- matrices the main pass reads: the previous fit stays live, the caller
  -- skips the pass, and the frame renders flat-lit instead of poisoned.
  -- NaN compares false, so the plain > tests above reject it too.
  if ShadowMap._degenerate(w, h, near, far) then return false end
  local proj = Mat4.ortho(l, r, b, t, near, far)
  -- flip clip-space Y for the same reason the camera does: we bypass
  -- LOVE's transform_projection, and canvas coordinates run Y DOWN, so
  -- without this the map is stored upside down relative to the uv the
  -- main pass reads it with
  proj = Mat4.mul(Mat4.scale(1, -1, 1), proj)

  ShadowMap.clipVP = Mat4.mul(proj, view)
  ShadowMap.uvVP = Mat4.mul(TO_UNIT, ShadowMap.clipVP)
  -- what the frustum ended up covering, for probes: the lateral extent in
  -- world pixels divided by RES is how fine a shadow edge can land
  ShadowMap.extent = { r - l, t - b, far - near }
  -- the slack the comparison needs, against the coarser of the two texel
  -- axes (the box is asymmetric, and one number has to cover both)
  ShadowMap.slack = ShadowMap._slackFor(math.max(w, h) / res,
                                        ShadowMap.KX, ShadowMap.KZ)
  -- the stored depth spans the frustum, so a world-pixel bias is that
  -- fraction of it
  ShadowMap.bias = ShadowMap.slack / math.max(1, far - near)
  return true
end
-- the real fit, exported for the golden test -- same _-seam convention as
-- _resolutionFor/_degenerate/_slackFor
ShadowMap._fit = fit

-- How much of the compare's forgiveness a snugged caster takes back, 0..1.
-- Short of 1 on purpose: at exactly 1 the card's own fragments compare
-- against their own stored depth on a float-equality knife edge and can
-- speckle. The tenth left over is dozens of times the packed depth's
-- quantization -- ample for that -- and leaves the contact gap around a
-- quarter of a world pixel at any sun, which no zoom resolves.
ShadowMap.SNUG = 0.9

-- A CASTER snugged up the sun ray -- moved TOWARD the light -- before it is
-- drawn into the map.
--
-- The depth compare forgives `slack` world pixels (BIAS + the SLOPE term)
-- so lit surfaces do not acne against their own texels -- but that same
-- forgiveness is what lets the ground right next to a standing figure read
-- as lit: a receiver within `slack` of its blocker along the ray passes the
-- test, so the first stretch of every shadow is forgiven away and on screen
-- it starts that far from the feet, further the lower the sun. The classic
-- peter-panning; unseen while the sun hung at a fixed 45 degrees, plain at
-- a day/night golden hour or under the moon.
--
-- Moving the card ALONG ITS OWN RAY changes nothing about where its shadow
-- falls -- every point stays on the same light ray -- but moving it toward
-- the sun stores it SHALLOWER, so a ground point right at the foot is
-- already `slack` deeper than the stored blocker and fails the lit test:
-- the root lands back under the feet. Nothing else is touched -- no
-- terrain moved, so the acne margin the slack exists for is intact where
-- it matters. For sprite cards and other thin stand-ins only.
--
-- ONE OBLIGATION comes with it: the caster's LIT draw must hand this same
-- snugged transform to its shadow lookup (Voxel3D.draw's `sunModel`).
-- Stored and lookup then agree exactly, as they did before snugging, and
-- the compare keeps its full acne margin. A caster stored snugged but read
-- un-snugged is 0.9 of the margin short, and the loss shows up as diagonal
-- moire bands crawling across the card.
--
-- Valid between begin() and the next begin(): `slack` and the sun hold
-- still between redraws of the map, so a lit frame that reuses last
-- frame's map computes the same displacement it was stored with.
local snugMat = Mat4.identity()

function ShadowMap.snug(model)
  local f = sunDir()
  local s = -ShadowMap.slack * ShadowMap.SNUG
  Mat4.translateInPlace(snugMat, f[1] * s, f[2] * s, f[3] * s)
  return Mat4.mulInPlace(snugMat, snugMat, model or IDENTITY)
end

-- Whether the map has to be redrawn for `sig` -- a caller-built stamp of
-- everything the pass depends on (camera, terrain meshes, every pose). A
-- frame that changes none of it reuses the map it already has, which is
-- most of a dialog, a menu or any moment standing still. `sprites` asks
-- about the CAST layer, which animates on its own -- the world layer may
-- be cold while the sprite layer is stale.
function ShadowMap.stale(sig, sprites)
  if sprites then
    return not spritesReady or sig ~= lastSpriteSig
  end
  return not ready or sig ~= lastSig
end

-- Begin the sun pass for one layer. Returns false when it could not
-- start, in which case the caller must not draw into it or call finish.
-- `sprites` selects the CAST layer (posed characters, battle cards);
-- the default is the WORLD layer (terrain, water, flowers, figures).
-- The two layers share the same fitted box, so only a world begin
-- re-fits; a sprite begin reuses the current fit.
-- Why begin() last returned false (transient -- cleared by the next
-- successful begin), for diagnostics. Policy gates (the sprite layer being
-- off on a rung) are not failures and leave this alone.
ShadowMap.beginFailure = nil

function ShadowMap.begin(cx, cy, vw, vh, sprites)
  if sprites and (not ShadowMap.SPRITE_LAYER or not actorLayerActive) then
    return false
  end
  local sh = getShader()
  if not sh then
    ShadowMap.beginFailure = "the shadow shader did not compile"
    return false
  end
  if not sprites then
    -- fit first: it is what decides which resolution rung this view wants.
    -- The canvas is then (re)made at that edge -- the rung's whole point is
    -- how many texels the box is divided into, so a 1536 fit on a 1024
    -- canvas would be a 1024 map wearing a 1536 fit's snap and bias.
    if not fit(cx, cy, vw, vh) then
      ShadowMap.beginFailure = "the light frustum is degenerate this frame"
      return false
    end
    if getCanvas(ShadowMap.res) == nil then
      ShadowMap.beginFailure = "the shadow canvas could not be allocated"
      return false
    end
  end
  local c = sprites and spriteCanvas or canvas
  if not c or c == false then
    ShadowMap.beginFailure = sprites and "the sprite shadow canvas is unavailable"
                             or "the shadow canvas is unavailable"
    return false
  end
  local ok = pcall(love.graphics.setCanvas, { c, depth = true })
  if not ok then
    pcall(love.graphics.setCanvas)
    ShadowMap.beginFailure = "the shadow canvas could not be bound"
    return false
  end
  prevBlend, prevAlphaMode = love.graphics.getBlendMode()
  -- white clears to depth 1 + 1/255, past the far plane: a texel nothing
  -- was drawn into can never shadow anything
  love.graphics.clear(1, 1, 0, 1, true, true)
  love.graphics.setDepthMode("lequal", true)
  love.graphics.setMeshCullMode("none")
  -- replace, not alpha blend: these are packed numbers, not colors
  love.graphics.setBlendMode("replace", "premultiplied")
  love.graphics.setShader(sh)
  love.graphics.setColor(1, 1, 1, 1)
  pcall(sh.send, sh, "lightVP", "row", ShadowMap.clipVP)
  -- the world until a cast pass says otherwise, reset per pass so one that
  -- forgot to put it back cannot leak into the next map's terrain
  pcall(sh.send, sh, "sprite", 0)
  if sprites then
    drawingSprites = true
    spritesReady = false
  else
    drawing = true
    ready = false
  end
  ShadowMap.beginFailure = nil
  return true
end

-- Draw one caster. Same signature as Voxel3D.draw minus the camera-ward
-- pull, which is a trick for the VIEW's depth buffer and would drag a
-- shadow off whatever throws it.
-- Whether what is drawn next is one of the CAST -- a walker, an authored
-- figure, a battle's Pokemon -- rather than part of the world. false for the
-- length of such a pass, true to put it back.
--
-- The map records it per texel (the shader's blue channel) so a surface can
-- decline that kind of caster, and exactly one does: water. A character
-- standing at a lake's edge threw a hard cut-out of its own sprite across
-- the surface, which on something showing the sky and the shoreline reads as
-- a sticker rather than as a shadow in the water. Everything else -- ground,
-- roofs, ledges, the characters themselves -- still takes them.
--
-- Sent rather than branched, so a caller that forgets to put it back only
-- mislabels casters rather than losing them; begin() resets it per pass.
function ShadowMap.sprites(on)
  if not (drawing or drawingSprites) then return end
  local sh = getShader()
  if sh then pcall(sh.send, sh, "sprite", on and 1 or 0) end
end

function ShadowMap.draw(mesh, texture, model)
  if not (drawing or drawingSprites) then return end
  if not mesh then return end
  local sh = getShader()
  if texture then mesh:setTexture(texture) end
  pcall(sh.send, sh, "model", "row", model or IDENTITY)
  love.graphics.draw(mesh)
end

-- Close the pass and stamp it with the signature it was drawn for.
function ShadowMap.finish(sig, sprites)
  local open = sprites and drawingSprites or drawing
  if not open then return end
  if sprites then
    drawingSprites = false
  else
    drawing = false
  end
  love.graphics.setShader()
  love.graphics.setDepthMode()
  love.graphics.setCanvas()
  love.graphics.setBlendMode(prevBlend or "alpha", prevAlphaMode)
  love.graphics.setColor(1, 1, 1, 1)
  if sprites then
    lastSpriteSig = sig
    spritesReady = true
  else
    lastSig = sig
    ready = true
  end
end

-- Unconditionally restore the GL state a pass changes, after an error
-- anywhere inside begin..finish. A pass that dies mid-draw leaves the
-- shadow canvas bound, and every later frame renders the WORLD into that
-- 1024px offscreen map -- a black screen, exactly the Mediatek report.
-- Callers pcall-wrap their pass and call this from the error handler;
-- harmless (and cheap) when no pass is open.
function ShadowMap.abort()
  drawing, drawingSprites = false, false
  ready, spritesReady = false, false
  pcall(love.graphics.setShader)
  pcall(love.graphics.setDepthMode)
  pcall(love.graphics.setCanvas)
  pcall(love.graphics.setBlendMode, prevBlend or "alpha", prevAlphaMode)
  pcall(love.graphics.setColor, 1, 1, 1, 1)
end

-- Drop the GPU objects (window resize, hot reload).
function ShadowMap.invalidate()
  canvas, canvasRes, blank = nil, 0, nil
  spriteCanvas = nil
  drawing, drawingSprites = false, false
  ready, spritesReady = false, false
  lastSig, lastSpriteSig = nil, nil
  unavailable = nil
  ShadowMap.beginFailure = nil
end

return ShadowMap
