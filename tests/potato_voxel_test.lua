-- Headless invariants for the single PotatoVoxel build.
package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.modkit")
local Data = require("src.core.Data")
Data:load()
local run = T.sdk.loadMod("mods/potato_voxel", { data = Data })
T.eq(#run.errors, 0, "loads clean")
local exports = run.loader.exports.potato_voxel
T.check(exports ~= nil, "mod exports a table")
-- The sandbox-era settings read LIVE through mod.options, and writers
-- persist into a game's save options (the same dual write the engine's
-- manager page makes). The SDK stub has neither, so the suite installs a
-- functional store and a fake game whose save carries it.
local optionsState = { modOptions = {} }
exports.lib.mod.options = {
  get = function(_, key) return optionsState.modOptions.potato_voxel[key] end,
}
local fakeGame = { save = { options = optionsState },
                   writeOptions = function() end }
local brick = exports and exports.brick
T.check(brick ~= nil and brick.isBrick(), "the one build is the Brick build")
if brick then
  local Voxel = exports.lib.require("VoxelState")
  local ShadowMap = exports.lib.require("ShadowMap")
  local Water = exports.lib.require("Water")
  local AntiAlias = exports.lib.require("AntiAlias")
  local WorldCurve = exports.lib.require("WorldCurve")
  local VoxelGrid = exports.lib.require("VoxelGrid")
  local Structures = exports.lib.require("Structures")
  local OverworldBattle = exports.lib.require("OverworldBattle")
  local QualityMode = exports.lib.require("QualityMode")
  local DayNight = exports.lib.require("DayNight")
  T.eq(#Voxel.ANGLES_DEG, 6, "VOXEL keeps OFF/HIGH/MEDIUM/LOW/POTATO/CUSTOM")
  T.eq(Voxel.ANGLE_LABELS[1], "OFF", "VOXEL OFF rung is retained")
  T.eq(Voxel.ANGLE_LABELS[2], "HIGH", "VOXEL HIGH rung is retained")
  T.eq(Voxel.ANGLE_LABELS[3], "MEDIUM", "VOXEL MEDIUM rung is retained")
  T.eq(Voxel.ANGLE_LABELS[4], "LOW", "VOXEL LOW rung is retained")
  T.eq(Voxel.ANGLE_LABELS[5], "POTATO", "VOXEL POTATO rung is retained")
  T.eq(Voxel.ANGLE_LABELS[6], "CUSTOM", "VOXEL CUSTOM rung exists")
  -- RENDER SCALE is a knob now; the default is 100% (the same HIGH shipped
  -- with), and the quality-mode presets write it
  T.eq(brick.renderScale(), 1.0, "RENDER SCALE defaults to 100 percent")
  T.eq(QualityMode.renderFraction(), 1.0, "render fraction follows the knob")
  T.eq(QualityMode.renderSetting.values[1], 100, "RENDER SCALE ladder starts at 100")
  -- applying a mode writes its preset, including the render scale
  QualityMode.applyMode(3, fakeGame)
  T.eq(QualityMode.renderFraction(), 0.5, "LOW preset renders at 50 percent")
  T.eq(Water.setting:get(), "off", "LOW preset turns WATER off")
  T.check(QualityMode.matches(3), "an applied preset matches its mode")
  QualityMode.applyMode(1, fakeGame)
  T.eq(QualityMode.renderFraction(), 1.0, "HIGH preset restores 100 percent")
  T.eq(Water.setting:get(), "full", "HIGH preset sets WATER to FULL")
  -- deviating from a preset breaks the match: the mode is then CUSTOM
  Water.setting:setValue("off", fakeGame)
  T.check(not QualityMode.matches(1), "a changed knob breaks the preset match")
  T.eq(QualityMode.CUSTOM_LEVEL, 5, "CUSTOM is the last VOXEL rung")
  T.eq(ShadowMap.BRICK_HIGH_RES, 1536, "HIGH uses a 1536 shadow map")
  T.eq(ShadowMap._resolutionFor(100, 100, 1), 1536, "HIGH shadow map is fixed")
  T.eq(brick.actorShadowMapEnabled(1), true, "HIGH keeps both shadow layers")
  for level = 1, 4 do T.eq(brick.actorShadowMapEnabled(level), true, "every active mode casts actor sun shadows") end
  for level = 1, 4 do T.eq(brick.shadowsEnabled(level), true, "active modes keep shadows on") end
  T.eq(brick.shadowsEnabled(0), false, "OFF disables shadows")
  local ShadowSettings = exports.lib.require("ShadowSettings")
  T.eq(ShadowSettings.enabledSetting.values[1], true, "SHADOWS defaults to on")
  T.eq(ShadowSettings.qualitySetting.values[1], 0, "SHADOW QUALITY defaults to AUTO")
  T.check(ShadowSettings.enabled(), "SHADOWS reads ON under the Brick pin")
  -- the SHADOW QUALITY row forces the map edge ahead of the profile's HIGH
  -- guarantee, and AUTO (the Brick pin) lets the guarantee through
  local qv, ql = ShadowSettings.qualitySetting.values,
                 ShadowSettings.qualitySetting.labels
  ShadowSettings.qualitySetting.values = { 0, 512, 1024, 2048 }
  ShadowSettings.qualitySetting.labels = { "AUTO", "512", "1024", "2048" }
  ShadowSettings.qualitySetting:setValue(2048, fakeGame)
  T.eq(ShadowSettings.quality(), 2048, "quality 2048 forces the map edge")
  T.eq(ShadowMap._resolutionFor(100, 100, 1), 2048,
       "quality wins over the HIGH fixed 1536 map")
  ShadowSettings.qualitySetting:setValue(512, fakeGame)
  T.eq(ShadowMap._resolutionFor(100, 100, 1), 512,
       "quality 512 forces a smaller map than the ladder would")
  ShadowSettings.qualitySetting.values = qv
  ShadowSettings.qualitySetting.labels = ql
  ShadowSettings.qualitySetting:setValue(0, fakeGame)
  T.eq(ShadowMap._resolutionFor(100, 100, 1), 1536,
       "AUTO restores the HIGH fixed 1536 map")
  -- the SHADOWS toggle gates the whole pass
  local ev, el = ShadowSettings.enabledSetting.values,
                 ShadowSettings.enabledSetting.labels
  ShadowSettings.enabledSetting.values = { true, false }
  ShadowSettings.enabledSetting.labels = { "ON", "OFF" }
  ShadowSettings.enabledSetting:setValue(false, fakeGame)
  T.check(not ShadowSettings.enabled(), "SHADOWS OFF disables the pass")
  ShadowSettings.enabledSetting.values = ev
  ShadowSettings.enabledSetting.labels = el
  ShadowSettings.enabledSetting:setValue(true, fakeGame)
  T.check(ShadowSettings.enabled(), "SHADOWS ON re-enables the pass")
  -- degenerate-fit guard: zero, negative or NaN extents must not write
  -- inf/NaN into the matrices the main pass samples (black-screen class)
  T.check(ShadowMap._degenerate(0, 100, -10, 10), "zero width is degenerate")
  T.check(ShadowMap._degenerate(100, 0, -10, 10), "zero height is degenerate")
  T.check(ShadowMap._degenerate(100, 100, 10, 10), "zero depth span is degenerate")
  T.check(ShadowMap._degenerate(100, 100, 10, -10), "inverted depth is degenerate")
  T.check(ShadowMap._degenerate(0 / 0, 100, -10, 10), "NaN width is degenerate")
  T.check(not ShadowMap._degenerate(100, 100, -100, 100),
          "a sane frustum is not degenerate")
  T.check(ShadowMap._source():find("c.z == c.z", 1, true),
          "shadow shader stores far depth instead of NaN")
  T.check(ShadowMap.abort ~= nil, "abort() exists for pcall error handlers")
  -- Mali (Mediatek) devices: every active rung takes the proven HIGH actor
  -- shadow path -- the blob decal fallback is what freezes/black-frames them
  local loveG = love and love.graphics
  local oldRendererInfo = loveG and loveG.getRendererInfo
  if loveG then
    loveG.getRendererInfo = function() return { name = "Mali-G57 MC2" } end
  end
  ShadowMap._maliReset()
  T.check(ShadowMap.isMali() == (loveG ~= nil),
          "a Mali renderer string is detected")
  if loveG then
    T.check(brick.actorShadowMapEnabled(2),
            "Mali: MEDIUM keeps the actor shadow map")
    T.check(brick.actorShadowMapEnabled(5),
            "Mali: CUSTOM keeps the actor shadow map")
    T.check(not brick.actorShadowMapEnabled(0),
            "Mali: OFF still disables it")
    T.check(brick.battleActorShadowMap(2),
            "Mali: MEDIUM battles also avoid the broken decal path")
    T.check(not brick.battleActorShadowMap(0),
            "Mali: OFF battles have no actor map")
  end
  if loveG then loveG.getRendererInfo = oldRendererInfo end
  ShadowMap._maliReset()
  T.check(not ShadowMap.isMali(), "a non-Mali renderer is not detected")
  T.check(brick.actorShadowMapEnabled(2),
          "non-Mali: MEDIUM keeps the actor shadow map too")
  T.check(brick.actorShadowMapEnabled(4),
          "non-Mali: POTATO keeps the actor shadow map")
  T.check(not brick.actorShadowMapEnabled(0),
          "OFF disables the actor map")
  T.check(not brick.battleActorShadowMap(2),
          "non-Mali battles stay blob-decals below HIGH")
  T.check(brick.battleActorShadowMap(1),
          "HIGH battles keep the actor map")
  -- The sun-grazing slack: the slope term scales with the shear's magnitude
  -- (the cotangent of the sun's elevation), so a dawn/dusk or moonlit frame
  -- keeps its acne margin instead of streaking. Noon is the calibration
  -- point and must stay exactly the shipped value.
  T.eq(ShadowMap._slackFor(1, 0, 0),
       ShadowMap.BIAS + ShadowMap.SLOPE,
       "the slack floor is the shipped noon calibration")
  T.check(ShadowMap._slackFor(1, -0.85, -0.55)
          > ShadowMap._slackFor(1, 0, 0),
          "the shipped noon sun sits at (or above) the calibration floor")
  T.check(ShadowMap._slackFor(1, -2.0, -0.0)
          > ShadowMap._slackFor(1, -0.85, -0.55),
          "a low sun widens the slope slack")
  T.check(ShadowMap._slackFor(1, -1.19, 0)
          > ShadowMap._slackFor(1, -0.85, -0.55),
          "the moon widens the slope slack")
  T.check(ShadowMap._slackFor(2, -0.85, -0.55)
          > ShadowMap._slackFor(1, -0.85, -0.55),
          "coarser texels take proportionally more slack")
  -- diagnostics: a session without the sun pass must be able to say why
  if not ShadowMap.available() then
    T.check(type(ShadowMap.unavailableReason()) == "string",
            "a disabled shadow pass names its reason")
  end
  -- DUSK/DAWN pins sit at the last fully-lit moment, not on the horizon:
  -- a pin on the exact horizon rides the shadow fade down to strength
  -- zero and reads as "no shadows in dusk/dawn"
  T.check(DayNight.T.dawn > 0 and DayNight.T.dawn < DayNight.T.day,
          "DAWN pins inside the day")
  T.check(DayNight.T.dusk > DayNight.T.day
          and DayNight.T.dusk < DayNight.DAY_LEN,
          "DUSK pins inside the day")
  T.check(DayNight.strengthAt(DayNight.T.dawn) > 1 - 1e-9,
          "DAWN has full shadow strength")
  T.check(DayNight.strengthAt(DayNight.T.dusk) > 1 - 1e-9,
          "DUSK has full shadow strength")
  T.check(DayNight.strengthAt(0) < 1e-9,
          "the cycle's dawn horizon gap stays shadowless")
  T.check(DayNight.strengthAt(DayNight.DAY_LEN) < 1e-9,
          "the cycle's dusk horizon gap stays shadowless")
  do
    local dkx, dkz = DayNight.shearAt(DayNight.T.dusk)
    T.check(math.sqrt(dkx * dkx + dkz * dkz) <= DayNight.K_MAX + 1e-9,
            "DUSK shadows obey the stretch clamp")
    local akx, akz = DayNight.shearAt(DayNight.T.dawn)
    T.check(math.sqrt(akx * akx + akz * akz) <= DayNight.K_MAX + 1e-9,
            "DAWN shadows obey the stretch clamp")
  end
  T.eq(Water.setting.values[1], "off", "WATER defaults off")
  T.eq(#Water.setting.values, 3, "WATER ladder stays available")
  -- FOREST FX was removed with the sandbox release (see the removals ADR):
  -- no setting exists to assert.
  T.eq(AntiAlias.setting.values[1], 0, "AA defaults off")
  T.eq(#AntiAlias.setting.values, 3, "AA ladder stays available")
  -- LÖVE 11.5 regression: the AA fold used to reset the draw colour with a
  -- bare love.graphics.setColor(), which LÖVE rejects with "bad argument #1
  -- to 'setColor' (number expected, got no value)". The throw rode the voxel
  -- pipeline's draw path back up and the error handling disabled voxel for
  -- the whole session. The fold must reset to explicit white -- and it must
  -- survive a strict setColor stub that models LÖVE 11.5 exactly.
  do
    local oldLove = _G.love
    local colorArgs
    local targetCanvas
    local function strictSetColor(...)
      if select("#", ...) == 0 then
        error("bad argument #1 to 'setColor' (number expected, got no value)")
      end
      colorArgs = { n = select("#", ...), ... }
    end
    _G.love = {
      graphics = {
        newCanvas = function(w, h)
          local c = { w = w, h = h }
          function c.getDimensions() return w, h end
          function c.setFilter() end
          function c.release() end
          targetCanvas = c
          return c
        end,
        newShader = function() return nil end,
        getBlendMode = function() return "alpha", "alphamultiply" end,
        setColor = strictSetColor,
        setBlendMode = function() end,
        setCanvas = function() end,
        clear = function() end,
        draw = function() end,
        setShader = function() end,
      },
    }
    local src = {}
    function src.getDimensions() return 160, 160 end
    function src.setFilter() end
    local folded = AntiAlias.resolve(src, 37, 21, "aa-setColor-regression")
    T.check(folded == targetCanvas,
            "AA fold survives a strict LÖVE 11.5 setColor stub")
    T.eq(colorArgs and colorArgs.n or 0, 4,
         "the fold resets colour with explicit RGBA arguments")
    T.eq(colorArgs and colorArgs[1] or 0, 1,
         "the fold's colour reset is white")
    _G.love = oldLove
  end
  T.eq(WorldCurve.setting.values[1], 0, "V-CURVE defaults off")
  T.eq(#WorldCurve.setting.values, 4, "V-CURVE ladder stays available")
  T.eq(VoxelGrid.setting.values[1], false, "V-GRID defaults off")
  T.eq(#VoxelGrid.setting.values, 2, "V-GRID stays a toggle")
  T.eq(Structures.ROUND_RING, 12, "Brick keeps the full border ring")
  T.eq(Structures.HULL_BILLBOARDS, true, "Brick uses billboard hulls")
  T.eq(Structures.BILLBOARD_CROSS, true, "Brick crosses billboard hulls")
  local intro = {
    enemy = { fainted = false },
    introBalls = true,
    statusHUDVisible = function() return true end,
    growInScale = function() return nil end,
  }
  T.eq(OverworldBattle.hudLive(intro, 0), false,
       "wild intro does not show an empty enemy HUD panel")
   intro.introBalls = nil
   T.eq(OverworldBattle.hudLive(intro, 0), true,
        "enemy HUD returns after the intro")
   -- The STADIUM rungs, STADIUM SPRITES row, packs and rigs were removed
   -- with the sandbox release (see the removals ADR): OverworldBattle now
   -- defines the 2D-3D A / 2D-3D B / OFF ladder, and the universal build
   -- pins 3D-BTL to plain OFF / ON (BrickProfile.apply) -- which is what
   -- ships, so that is the shape the suite asserts.
   T.eq(#OverworldBattle.setting.values, 2,
        "3D-BTL ships as OFF / ON in the universal build")
   T.eq(OverworldBattle.setting.values[1], false, "3D-BTL is OFF by default")
   T.eq(OverworldBattle.setting.values[2], true, "3D-BTL turns on")
   local Prebuild = exports.lib.require("CachePrebuild")
  local jobs = Prebuild.enumerate({ B = { id="B", width=3, height=2, connections={} }, A = { id="A", width=4, height=5, connections={} } })
  T.eq(#jobs, 4, "prebuild enumerates body and full variants")
end

-- The MeshCache storage format: encode/decode must round-trip
-- byte-identical for a real mesh stream, an empty mesh, and the aux quad
-- flattening -- the pure-Lua halves the cache relies on. Float bytes are
-- packed in pure Lua (this engine's ByteData has no accessors), and the
-- vertex streams are plain 1-based tables, the table sink's shape.
local MeshCache = exports and exports.lib and exports.lib.require("MeshCache")
if MeshCache and MeshCache.encodeMesh then
  local fakeStore = (function()
    local tables, bytes = {}, {}
    return {
      context = function()
        return { engineVersion = "test", gameVersion = "red",
                 playthroughId = "test-playthrough" }
      end,
      write = function(_, _, key, value) tables[key] = value return true end,
      read = function(_, _, key) return tables[key] end,
      writeBytes = function(_, _, key, value) bytes[key] = value return true end,
      readBytes = function(_, _, key) return bytes[key] end,
      list = function(_, _, prefix)
        local out = {}
        for key in pairs(tables) do
          if key:sub(1, #prefix) == prefix then out[#out + 1] = key end
        end
        for key in pairs(bytes) do
          if key:sub(1, #prefix) == prefix then out[#out + 1] = key end
        end
        table.sort(out)
        return out
      end,
      delete = function(_, _, key)
        tables[key] = nil
        bytes[key] = nil
        return true
      end,
      peekBytes = function() return bytes end,
    }
  end)()
  exports.lib.mod.storage = fakeStore

  T.check(MeshCache.dir() == "storage",
          "the cache lives in scoped storage, not a raw dir")
  T.check(MeshCache.available(),
          "cache availability resolves the storage facade")

  -- a small run of six-float vertices (2 triangles' worth)
  local n = 6
  local buf = {}
  for i = 1, n * 6 do buf[i] = i - 1 + 0.25 end
  local bytes = MeshCache.encodeMesh(n, buf)
  T.check(#bytes == 4 + n * 24, "encodeMesh writes a length prefix + raw floats")
  local d = MeshCache.decodeMesh(bytes)
  T.check(d ~= nil and d.n == n, "decodeMesh reads back the vertex count")
  if d then
    local match = true
    for i = 1, n * 6 do
      if math.abs(d.verts[i] - (i - 1 + 0.25)) > 1e-4 then match = false break end
    end
    T.check(match, "decodeMesh float stream is byte-identical")
  end
  -- an empty mesh round-trips as empty, not corrupt
  local empty = MeshCache.encodeMesh(0, nil)
  local ed = MeshCache.decodeMesh(empty)
  T.check(ed ~= nil and ed.n == 0, "empty mesh round-trips with n == 0")

  -- INDEXED payload: vertex stream + u32 vertex map. Table maps are
  -- 1-based; the wire format is 0-based, so the encoder subtracts one
  -- and the decoder adds it back.
  local iv = {}
  for i = 1, 4 * 6 do iv[i] = (i - 1) * 0.5 end
  local ii = { 1, 2, 3, 1, 3, 4 }     -- one quad, 1-based
  local ibytes = MeshCache.encodeIndexed(4, iv, 6, ii)
  T.check(#ibytes == 4 + 4 * 24 + 4 + 6 * 4,
          "encodeIndexed appends the vertex map after the stream")
  local id = MeshCache.decodeIndexed(ibytes)
  T.check(id ~= nil and id.n == 4 and id.m == 6,
          "decodeIndexed reads back vertex AND index counts")
  if id then
    local match = true
    for i = 1, 6 do
      if id.indices[i] ~= ii[i] then match = false break end
    end
    T.check(match, "decodeIndexed vertex map is 1-based on the way back")
  end
  -- an indexed EMPTY mesh round-trips too
  local iempty = MeshCache.decodeIndexed(MeshCache.encodeIndexed(0, nil, 0, nil))
  T.check(iempty ~= nil and iempty.n == 0 and iempty.m == 0,
          "empty indexed mesh round-trips with n == 0 and m == 0")

  -- flattenQuads: the grass shape (per-corner uv tables) and the figure
  -- shape (scalar u/v) both flatten to the indexed layout the table sink
  -- emits (4 verts per quad + 6 u32 indices, 1-based)
  local quads = {
    { { 0, 0, 0 }, { 1, 0, 0 }, { 1, 1, 0 }, { 0, 1, 0 },
      uv = { { 0, 1 }, { 1, 1 }, { 1, 0 }, { 0, 0 } }, shade = 1 },
    { { 0, 0, 0 }, { 1, 0, 0 }, { 1, 1, 0 }, { 0, 1, 0 },
      u = 0, v = 0, shade = 0.68 },
  }
  local fbuf = {}
  local fidx = {}
  local fk, fm = MeshCache.flattenQuads(quads, fbuf, fidx)
  T.eq(fk, 2 * 4 * 6, "flattenQuads emits 4 verts per quad")
  T.eq(fm, 2 * 6, "flattenQuads emits 6 indices per quad")
  -- both quads are the same unit square: quad 2's first vertex sits at
  -- float offset 25 (4 verts x 6 floats) and matches quad 1's first
  -- vertex's position
  T.eq(fbuf[7], fbuf[31], "flattenQuads UV order matches the table sink")
  -- indices are 1-based and reference each quad's own 4 vertices
  T.eq(fidx[1], 1, "quad 1 indices start at vertex 1 (1-based)")
  T.eq(fidx[7], 5, "quad 2 indices start at vertex 5 (1-based)")

  -- The FULL storage round-trip: saveTerrain + loadTerrain must return the
  -- written stream. This exercises the header + payload offset, which
  -- parseHeader used to return ONE BYTE EARLY (8+fpLen is the last fp
  -- byte, payload starts the byte after) -- decodeMesh read a garbage
  -- vertex count and failed validation, so the cache missed 100% of the
  -- time and the build fallback ran every launch.
  local fakeMap = { id = "VIRIDIAN_CITY",
                    tileset = { image = "tilesets/sample.png", trueColor = false },
                    renderer = { gbcAtlas = true } }
  local rtBuf = {}
  for i = 0, n - 1 do
    rtBuf[i * 6 + 1] = (i % 4) * 8                -- x: integer px (exact)
    rtBuf[i * 6 + 2] = math.floor(i / 4) * 4      -- y: integer height (exact)
    rtBuf[i * 6 + 3] = (i % 3) * 8                -- z: integer px (exact)
    rtBuf[i * 6 + 4] = ((i % 128) + 0.5) / 128    -- u: atlas texel centre
    rtBuf[i * 6 + 5] = ((i % 48) + 0.5) / 48      -- v
    rtBuf[i * 6 + 6] = 0.5 + (i % 10) / 20        -- shade: baked AO band
  end
  MeshCache.saveTerrain(fakeMap, "full", rtBuf, n)
  local rtTerrain, rtWater = MeshCache.loadTerrain(fakeMap, "full")
  T.check(rtTerrain ~= nil and rtTerrain.n == n,
          "loadTerrain reads back the written mesh (header+payload offset)")
  if rtTerrain then
    local match = true
    for i = 0, n - 1 do
      -- positions are integer pixels and round-trip exactly
      if rtTerrain.verts[i * 6 + 1] ~= rtBuf[i * 6 + 1]
         or rtTerrain.verts[i * 6 + 2] ~= rtBuf[i * 6 + 2]
         or rtTerrain.verts[i * 6 + 3] ~= rtBuf[i * 6 + 3] then
        match = false break
      end
      -- uv quantizes to u16, shade to u8 -- sub-visible error only
      if math.abs(rtTerrain.verts[i * 6 + 4] - rtBuf[i * 6 + 4]) > 0.01
         or math.abs(rtTerrain.verts[i * 6 + 5] - rtBuf[i * 6 + 5]) > 0.01
         or math.abs(rtTerrain.verts[i * 6 + 6] - rtBuf[i * 6 + 6]) > 0.01 then
        match = false break
      end
    end
    T.check(match, "loadTerrain round-trips quantized positions/uv/shade")
  end
  -- The AUX round-trip at scale. flattenQuads counts FLOATS while the
  -- payloads are vertex-counted; feeding k in as n made encodeMesh read
  -- 6x the buffer (the old brick.2 bug that the bench caught at 124,779
  -- vertices). A 10k-quad grass field overruns any plausible small-buffer
  -- slack, so a regression faults here (or inflates the file 6x and the
  -- byte-length check below catches it).
  local bigQuads = {}
  for i = 1, 10000 do
    bigQuads[i] = { { 0, 0, 0 }, { 1, 0, 0 }, { 1, 1, 0 }, { 0, 1, 0 },
                    uv = { { 0, 1 }, { 1, 1 }, { 1, 0 }, { 0, 0 } },
                    shade = 0.5 + (i % 10) / 20 }
  end
  local bigBuf = {}
  local bigIdx = {}
  local bigK, bigM = MeshCache.flattenQuads(bigQuads, bigBuf, bigIdx)
  T.eq(bigK, #bigQuads * 4 * 6, "flattenQuads float count scales linearly")
  T.eq(bigM, #bigQuads * 6, "flattenQuads index count scales linearly")
  local flat = { grass = { n = bigK / 6, buf = bigBuf, m = bigM,
                           idx = bigIdx },
                 flowers = nil, figures = {} }
  MeshCache.saveAux(fakeMap, "full", flat)
  local auxBytes = fakeStore.peekBytes()["maps/VIRIDIAN_CITY/full/aux"] or ""
  -- header (8 + fpLen) + indexed grass (u32 n + n*6 floats + u32 m +
  -- m u32s), then the empty flowers payload (u32 0 + u32 0) and the
  -- figures count byte (0) -- a 6x-inflated grass write is ~5.7MB vs
  -- the correct ~960KB and fails this check.
  local fpLen = auxBytes:byte(5) + auxBytes:byte(6) * 256
                + auxBytes:byte(7) * 65536 + auxBytes:byte(8) * 16777216
  local expected = 8 + fpLen + 4 + (bigK / 6) * 24 + 4 + bigM * 4 + 8 + 1
  T.eq(#auxBytes, expected,
       "saveAux writes vertex-counted bytes (floats are not vertices)")
  local aux = MeshCache.loadAux(fakeMap, "full")
  T.check(aux ~= nil and aux.grass ~= nil and aux.grass.n == bigK / 6
          and aux.grass.m == bigM,
          "loadAux reads back the grass stream at the same counts")
  if aux and aux.grass then
    local match = true
    for i = 1, bigK do
      if math.abs(aux.grass.verts[i] - bigBuf[i]) > 1e-4 then
        match = false break
      end
    end
    T.check(match, "loadAux grass stream is byte-identical")
    match = true
    for i = 1, bigM do
      if aux.grass.indices[i] ~= bigIdx[i] then match = false break end
    end
    T.check(match, "loadAux grass index map is byte-identical")
  end
  -- Cold-entry fast path: a destination with a VALID prebuilt payload
  -- must load it synchronously inside request() -- no queued job, so the
  -- BUILDING VOXELS cover never starts -- while a map with nothing in the
  -- box still queues the async job (the cover path).
  do
    local ChunkMesher = exports.lib.require("ChunkMesher")
    local fastMap = { id = "FASTPATH_CITY",
                      tileset = { image = "tilesets/sample.png", trueColor = false },
                      renderer = { gbcAtlas = true } }
    local fn = 16
    local fBuf = {}
    for i = 0, fn - 1 do
      fBuf[i * 6 + 1] = (i % 4) * 8
      fBuf[i * 6 + 2] = 1
      fBuf[i * 6 + 3] = (i % 4) * 8
      fBuf[i * 6 + 4] = 0.25
      fBuf[i * 6 + 5] = 0.25
      fBuf[i * 6 + 6] = 0.75
    end
    MeshCache.saveTerrain(fastMap, "full", fBuf, fn)
    MeshCache.saveWater(fastMap, "full", nil, 0, nil, 0)
    local fQuads = {
      { { 0, 0, 0 }, { 1, 0, 0 }, { 1, 1, 0 }, { 0, 1, 0 },
        uv = { { 0, 1 }, { 1, 1 }, { 1, 0 }, { 0, 0 } }, shade = 0.5 },
    }
    local fBuf2 = {}
    local fIdx = {}
    local fK, fM = MeshCache.flattenQuads(fQuads, fBuf2, fIdx)
    MeshCache.saveAux(fastMap, "full",
                       { grass = { n = fK / 6, buf = fBuf2, m = fM,
                                   idx = fIdx },
                         flowers = nil, figures = {} })
    -- fake GPU meshes so meshFromData's upload path runs headless
    local oldLove = _G.love
    local dataStub = oldLove and oldLove.data or nil
    _G.love = {
      data = dataStub,
      graphics = {
        newMesh = function()
          local m = {}
          function m.setVertices() end
          function m.setVertexMap() end
          function m.release() end
          return m
        end,
      },
    }
    local mesh = ChunkMesher.request(fastMap, false, nil, true)
    T.check(mesh ~= nil and mesh ~= false,
            "cold entry with a cached payload loads it synchronously")
    T.eq(ChunkMesher.pending(), 0,
         "a synchronous cache load queues no build job")
    T.check(ChunkMesher.pair(fastMap, false) ~= nil,
            "the loaded pair answers from memory")
    T.check(ChunkMesher.grass(fastMap) ~= nil,
            "the aux grass rode the same fast path")
    -- a map with nothing in the box still queues the async cover path
    local coldMap = { id = "FASTPATH_MISS",
                      tileset = { image = "tilesets/sample.png", trueColor = false },
                      renderer = { gbcAtlas = true } }
    T.check(ChunkMesher.request(coldMap, false, nil, true) == nil,
            "a storage miss still defers to the async job")
    T.eq(ChunkMesher.pending(), 1,
         "the miss queues exactly one job")
    T.check(ChunkMesher.request(coldMap, false, nil, true) == nil,
            "the miss is not re-attempted synchronously")
    T.eq(ChunkMesher.pending(), 1,
         "the queued job is not duplicated by later frames")
    _G.love = oldLove
  end
end

  -- The forward-local lint (see lib/BrickProfile.lua): a function that
  -- touches a name BEFORE the chunk's `local NAME =` declaration reads or
  -- writes a GLOBAL of that name -- apply() wrote the local, the Mali gate
  -- read a nil global, and the exception silently never fired. Scan every
  -- shipped module: a bare touch of a name before its FIRST local
  -- declaration fails the suite. Comments, [[ ]] long strings and
  -- "quoted" strings are stripped first so text can never false-positive;
  -- table keys, index keys and parameter lists are excluded from the
  -- "touch" test.
  do
    -- main.lua is a file; lib/ and data/ are directories. io.open on a
    -- DIRECTORY succeeds on macOS (only the read fails), so probing it as
    -- a file would silently skip the whole tree -- exactly how the first
    -- version of this lint missed the BrickProfile bug class.
    local files = { "mods/potato_voxel/main.lua" }
    for _, dir in ipairs({ "mods/potato_voxel/lib",
                           "mods/potato_voxel/data" }) do
      local p = io.popen('ls "' .. dir .. '"')
      for f in p:lines() do files[#files + 1] = dir .. "/" .. f end
      p:close()
    end
    local violations = {}
    for _, path in ipairs(files) do
      local f = io.open(path, "rb")
      if f then
        local src = f:read("*a") or ""
        f:close()
        -- strip in order: [[ ]] long strings first (their newlines are
        -- KEPT -- a shader embedded in a long string must not shift the
        -- lines below it), then PER LINE: quoted strings BEFORE comments --
        -- a `--` inside a string literal is string content, and stripping
        -- the comment first would unbalance the quotes and leak the text.
        -- Line numbers stay the source's own throughout.
        local stripped = src:gsub("%[%[(.-)%]%]", function(s) return s:gsub("[^\n]", " ") end)
        local lines = {}
        for line in (stripped .. "\n"):gmatch("(.-)\n") do
          line = line:gsub('"[^"]*"', '""')
          lines[#lines + 1] = line:gsub("%-%-[^\n]*", " ")
        end
        local declared = {}
        -- is `name` a parameter of the function `pi` sits inside (or of a
        -- for-loop header at or above it)? Those are locals, not touches.
        -- is `name` bound in any scope enclosing line `pi` -- a parameter
        -- of an enclosing function (nested closures included) or a
        -- for-loop variable between it and `pi`? Those are locals, not
        -- touches.
        local function scoped(name, pi)
          local k = pi
          while k >= 1 do
            local hdr = nil
            for j = k, 1, -1 do
              -- `local function f(...)` and the anonymous `function(...)`
              -- form both start a scope
              if lines[j]:match("%f[%w_]function[%s%(]") then hdr = j break end
            end
            if not hdr then return false end
            local params = lines[hdr]:match("function[^%(]*%b()")
            if not params then
              -- the parameter list spans lines: join until it closes --
              -- possibly BELOW the touch line (the touch may sit inside
              -- the list itself)
              local acc = lines[hdr]
              for j = hdr + 1, math.min(hdr + 30, #lines) do
                acc = acc .. " " .. lines[j]
                params = acc:match("function[^%(]*%b()")
                if params then break end
              end
            end
            if params and params:find("%f[%w_]" .. name .. "%f[^%w_]") then
              return true
            end
            for j = hdr, pi do
              if lines[j]:match("^%s*for%s") and
                 (lines[j]:match("for%s+[^=]-%f[%w_]" .. name
                                  .. "%f[^%w_][^%n=]-in")
                  or lines[j]:match("for%s+[%w_%s,]*%f[%w_]" .. name
                                    .. "%f[^%w_]%s*=")) then
                return true
              end
            end
            k = hdr - 1   -- climb to the enclosing scope
          end
          return false
        end
        for li = 1, #lines do
          -- `local a, b` without an initializer declares exactly like the
          -- `=` form; capture both (the pattern also eats `local function`,
          -- whose only captured name is "function" and is skipped below)
          local decl = lines[li]:match("^%s*local%s+([%w_%s,]+)")
          if decl then
            -- every name the declaration binds: `local a, b = ...` declares
            -- BOTH, and treating only the first as declared false-positives
            -- the rest
            for name in decl:gmatch("[%w_]+") do
              if name ~= "function" and name ~= "_" and not declared[name] then
                declared[name] = li
                for pi = 1, li - 1 do
                  local prior = lines[pi]
                  -- a line-leading `name =` is a table key or an assignment
                  -- target, not a read of the variable
                  if prior:match("^%s*" .. name .. "%s*=") then goto continue end
                  local pos = 1
                  while true do
                    local s = prior:find(name, pos, true)
                    if not s then break end
                    local j = s - 1
                    while j >= 1 and prior:sub(j, j) == " " do j = j - 1 end
                    local nonSpace = prior:sub(j, j)
                    local pre = prior:sub(s - 1, s - 1)
                    local post = prior:sub(s + #name, s + #name)
                    -- a table key (the `{ k = v` and `..., k = v, ...`
                    -- forms, whatever the spacing) is not a touch; everything
                    -- else is judged on the token IMMEDIATELY before --
                    -- `and profileShadowMap` is a standalone value, not a
                    -- member of `and`
                    local isKey = nonSpace == "," or nonSpace == "{"
                    if not isKey
                       and (pre == "" or not pre:match("[%w_%.:%(%[{%\"]"))
                       and (post == "" or not post:match("[%w_]"))
                       and not scoped(name, pi) then
                      violations[#violations + 1] = path .. ":" .. pi
                          .. " touches `" .. name .. "` before its first local at "
                          .. li
                      break
                    end
                    pos = s + #name
                  end
                  ::continue::
                end
              end
            end
          end
        end
      end
    end
    for _, v in ipairs(violations) do print("FWD-LOCAL " .. v) end
    T.eq(#violations, 0,
         "no module touches a name before its first local declaration")
  end

run.release()
T.finish("potato_voxel")
