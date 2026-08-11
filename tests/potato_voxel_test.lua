-- Headless Brick-only invariants for PotatoVoxel.
package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.modkit")
local Data = require("src.core.Data")
Data:load()
local run = T.sdk.loadMod("mods/potato_voxel", { data = Data })
T.eq(#run.errors, 0, "loads clean")
local exports = run.loader.exports.potato_voxel
T.check(exports ~= nil, "mod exports a table")
local brick = exports and exports.brick
T.check(brick ~= nil and brick.isBrick(), "Brick mode is unconditional")
if brick then
  local Voxel = exports.lib.require("VoxelState")
  local ShadowMap = exports.lib.require("ShadowMap")
  local Water = exports.lib.require("Water")
  local ForestAtmos = exports.lib.require("ForestAtmos")
  local Structures = exports.lib.require("Structures")
  local OverworldBattle = exports.lib.require("OverworldBattle")
  T.eq(#Voxel.ANGLES_DEG, 5, "VOXEL keeps OFF/HIGH/MEDIUM/LOW/POTATO")
  T.eq(Voxel.ANGLE_LABELS[1], "OFF", "VOXEL OFF rung is retained")
  T.eq(Voxel.ANGLE_LABELS[2], "HIGH", "VOXEL HIGH rung is retained")
  T.eq(Voxel.ANGLE_LABELS[3], "MEDIUM", "VOXEL MEDIUM rung is retained")
  T.eq(Voxel.ANGLE_LABELS[4], "LOW", "VOXEL LOW rung is retained")
  T.eq(Voxel.ANGLE_LABELS[5], "POTATO", "VOXEL POTATO rung is retained")
  T.eq(brick.renderScale(1), 1.0, "HIGH renders at full resolution")
  T.eq(brick.renderScale(2), 0.75, "MEDIUM renders at 75 percent")
  T.eq(brick.renderScale(3), 0.5, "LOW renders at 50 percent")
  T.eq(brick.renderScale(4), 0.33, "POTATO renders at 33 percent")
  T.eq(ShadowMap.BRICK_HIGH_RES, 1536, "HIGH uses a 1536 shadow map")
  T.eq(ShadowMap._resolutionFor(100, 100, 1), 1536, "HIGH shadow map is fixed")
  T.eq(brick.actorShadowMapEnabled(1), true, "HIGH keeps both shadow layers")
  for level = 2, 4 do T.eq(brick.actorShadowMapEnabled(level), false, "lower modes use contact shadows") end
  for level = 1, 4 do T.eq(brick.shadowsEnabled(level), true, "active modes keep contact shadows") end
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
  ShadowSettings.qualitySetting.index = nil
  ShadowSettings.qualitySetting:setValue(2048)
  T.eq(ShadowSettings.quality(), 2048, "quality 2048 forces the map edge")
  T.eq(ShadowMap._resolutionFor(100, 100, 1), 2048,
       "quality wins over the HIGH fixed 1536 map")
  ShadowSettings.qualitySetting:setValue(512)
  T.eq(ShadowMap._resolutionFor(100, 100, 1), 512,
       "quality 512 forces a smaller map than the ladder would")
  ShadowSettings.qualitySetting.values = qv
  ShadowSettings.qualitySetting.labels = ql
  ShadowSettings.qualitySetting.index = nil
  T.eq(ShadowMap._resolutionFor(100, 100, 1), 1536,
       "AUTO restores the HIGH fixed 1536 map")
  -- the SHADOWS toggle gates the whole pass
  local ev, el = ShadowSettings.enabledSetting.values,
                 ShadowSettings.enabledSetting.labels
  ShadowSettings.enabledSetting.values = { true, false }
  ShadowSettings.enabledSetting.labels = { "ON", "OFF" }
  ShadowSettings.enabledSetting.index = nil
  ShadowSettings.enabledSetting:setValue(false)
  T.check(not ShadowSettings.enabled(), "SHADOWS OFF disables the pass")
  ShadowSettings.enabledSetting.values = ev
  ShadowSettings.enabledSetting.labels = el
  ShadowSettings.enabledSetting.index = nil
  T.check(ShadowSettings.enabled(), "SHADOWS ON re-enables the pass")
  T.eq(Water.setting.values[1], "off", "WATER is pinned off")
  T.eq(ForestAtmos.setting.values[1], "off", "FOREST FX is pinned off")
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
  local Prebuild = exports.lib.require("CachePrebuild")
  local jobs = Prebuild.enumerate({ B = { id="B", width=3, height=2, connections={} }, A = { id="A", width=4, height=5, connections={} } })
  T.eq(#jobs, 4, "prebuild enumerates body and full variants")
end

-- The MeshCache disk format: encode/decode must round-trip byte-identical
-- for a real mesh stream, an empty mesh, and the aux quad flattening -- the
-- pure-Lua halves the disk cache relies on. Guarded so a change that ever
-- breaks ffi availability keeps the suite green rather than erroring.
local MeshCache = exports and exports.lib and exports.lib.require("MeshCache")
if MeshCache and MeshCache.encodeMesh then
  -- dir() must capture BOTH pcall returns: pcall returns (true, path) and
  -- the first value alone is a boolean -- on the Brick isBrick() is true
  -- so available() reaches dir(), and `true .. sep` used to throw, which
  -- killed every mesh build and left no mod-derived dir on device. (Headless
  -- isBrick() is false so available() never reaches dir(); we drive dir()
  -- directly and reset its one-shot latch to use the stubbed base.)
  local latchIdx
  for i = 1, 12 do
    if debug.getupvalue(MeshCache.dir, i) == "dirTried" then latchIdx = i end
  end
  MeshCache.portableBaseOverride = "/tmp/dsm_dir_test"
  if latchIdx then debug.setupvalue(MeshCache.dir, latchIdx, false) end
  local okD, d = pcall(MeshCache.dir)
  T.check(okD, "MeshCache.dir() must not throw on the pcall boolean bug")
  T.check(okD and type(d) == "string"
            and d:match("/mod%-derived/potato_voxel/meshes$") ~= nil,
          "MeshCache.dir() builds the meshes path from the portable base")

  -- Non-portable fallback: with no portable base, dir() falls back to the
  -- LÖVE save directory -- the love.filesystem root every host (NX/UWP/iOS
  -- included) can write to. (In the headless harness the love stub's
  -- getSaveDirectory is /tmp/pokeport-stub-save.)
  MeshCache.portableBaseOverride = nil
  if latchIdx then debug.setupvalue(MeshCache.dir, latchIdx, false) end
  local okSave, dirSave = pcall(MeshCache.dir)
  T.check(okSave, "MeshCache.dir() must not throw with no portable base")
  local stubSave = love and love.filesystem and love.filesystem.getSaveDirectory
                   and love.filesystem.getSaveDirectory()
  if stubSave then
    T.eq(dirSave, stubSave .. "/mod-derived/potato_voxel/meshes",
         "MeshCache.dir() falls back to the LÖVE save directory")
  end

  local ffi = pcall(require, "ffi") and require("ffi")
  if ffi then
    -- a small run of six-float vertices (2 triangles' worth)
    local n = 6
    local buf = ffi.new("float[?]", n * 6)
    for i = 0, n * 6 - 1 do buf[i] = i + 0.25 end
    local bytes = MeshCache.encodeMesh(n, buf)
    T.check(#bytes == 4 + n * 24, "encodeMesh writes a length prefix + raw floats")
    local d = MeshCache.decodeMesh(bytes)
    T.check(d ~= nil and d.n == n, "decodeMesh reads back the vertex count")
    if d then
      local match = true
      for i = 0, n * 6 - 1 do
        if math.abs(d.ptr[i] - (i + 0.25)) > 1e-4 then match = false break end
      end
      T.check(match, "decodeMesh float stream is byte-identical")
    end
    -- an empty mesh round-trips as empty, not corrupt
    local empty = MeshCache.encodeMesh(0, nil)
    local ed = MeshCache.decodeMesh(empty)
    T.check(ed ~= nil and ed.n == 0, "empty mesh round-trips with n == 0")

    -- INDEXED payload (brick.11): vertex stream + u32 vertex map, and
    -- the decoder must hand back both pointers. Indices are the raw
    -- 0-based values the sink writes (LOVE Data maps are not 1-based
    -- like table maps).
    local iv = ffi.new("float[?]", 4 * 6)      -- one quad, 4 verts
    for i = 0, 4 * 6 - 1 do iv[i] = i * 0.5 end
    local ii = ffi.new("uint32_t[?]", 6)       -- two triangles, 0-based
    for i = 0, 5 do ii[i] = i end
    local ibytes = MeshCache.encodeIndexed(4, iv, 6, ii)
    T.check(#ibytes == 4 + 4 * 24 + 4 + 6 * 4,
            "encodeIndexed appends the vertex map after the stream")
    local id = MeshCache.decodeIndexed(ibytes)
    T.check(id ~= nil and id.n == 4 and id.m == 6,
            "decodeIndexed reads back vertex AND index counts")
    if id then
      local match = true
      for i = 0, 5 do
        if id.iptr[i] ~= i then match = false break end
      end
      T.check(match, "decodeIndexed vertex map is byte-identical")
    end
    -- an indexed EMPTY mesh round-trips too
    local iempty = MeshCache.decodeIndexed(MeshCache.encodeIndexed(0, nil, 0, nil))
    T.check(iempty ~= nil and iempty.n == 0 and iempty.m == 0,
            "empty indexed mesh round-trips with n == 0 and m == 0")

    -- flattenQuads: the grass shape (per-corner uv tables) and the figure
    -- shape (scalar u/v) both flatten to the indexed layout the ffi sink
    -- emits (4 verts per quad + 6 u32 indices, 0-based)
    local quads = {
      { { 0, 0, 0 }, { 1, 0, 0 }, { 1, 1, 0 }, { 0, 1, 0 },
        uv = { { 0, 1 }, { 1, 1 }, { 1, 0 }, { 0, 0 } }, shade = 1 },
      { { 0, 0, 0 }, { 1, 0, 0 }, { 1, 1, 0 }, { 0, 1, 0 },
        u = 0, v = 0, shade = 0.68 },
    }
    local fbuf = ffi.new("float[?]", 2 * 4 * 6)
    local fidx = ffi.new("uint32_t[?]", 2 * 6)
    local fk, fm = MeshCache.flattenQuads(quads, fbuf, fidx)
    T.eq(fk, 2 * 4 * 6, "flattenQuads emits 4 verts per quad")
    T.eq(fm, 2 * 6, "flattenQuads emits 6 indices per quad")
    -- both quads are the same unit square: quad 2's first vertex sits
    -- at offset 24 (4 verts x 6 floats) and matches quad 1's first
    -- vertex's position
    T.eq(fbuf[6], fbuf[30], "flattenQuads UV order matches the ffi sink")
    -- indices are 0-based and reference each quad's own 4 vertices
    T.eq(fidx[0], 0, "quad 1 indices start at vertex 0 (0-based)")
    T.eq(fidx[6], 4, "quad 2 indices start at vertex 4 (0-based)")

    -- The FULL disk round-trip: saveTerrain + loadTerrain must return the
    -- written stream. This exercises the header + payload offset, which
    -- parseHeader used to return ONE BYTE EARLY (8+fpLen is the last fp
    -- byte, payload starts the byte after) -- decodeMesh read a garbage
    -- vertex count and failed validation, so the cache missed 100% of the
    -- time and the build fallback ran every launch (the ~60s transition).
    local rtLatch
    for i = 1, 12 do
      if debug.getupvalue(MeshCache.dir, i) == "dirTried" then rtLatch = i end
    end
    local rtBase = "/tmp/dsm_roundtrip"
    os.execute('rm -rf "' .. rtBase .. '"')
    MeshCache.portableBaseOverride = rtBase
    if rtLatch then debug.setupvalue(MeshCache.dir, rtLatch, false) end
    local fakeMap = { id = "VIRIDIAN_CITY",
                      tileset = { image = "tilesets/sample.png", trueColor = false },
                      renderer = { gbcAtlas = true } }
    local rtBuf = ffi.new("float[?]", n * 6)
    for i = 0, n * 6 - 1 do rtBuf[i] = (i + 1) * 0.5 end
    MeshCache.saveTerrain(fakeMap, "full", rtBuf, n)
    local rtTerrain, rtWater = MeshCache.loadTerrain(fakeMap, "full")
    T.check(rtTerrain ~= nil and rtTerrain.n == n,
            "loadTerrain reads back the written mesh (header+payload offset)")
    if rtTerrain then
      local match = true
      for i = 0, n * 6 - 1 do
        if math.abs(rtTerrain.ptr[i] - (i + 1) * 0.5) > 1e-4 then match = false break end
      end
      T.check(match, "loadTerrain stream is byte-identical to what was saved")
    end
    -- The AUX round-trip at scale. flattenQuads counts FLOATS while the
    -- payloads are vertex-counted; feeding k in as n made encodeMesh read
    -- 6x the buffer (native SIGSEGV past the ffi allocation, brick.2 bug
    -- that the bench caught at 124,779 vertices). A 10k-quad grass field
    -- overruns any plausible small-buffer slack, so a regression faults
    -- here (or, on an allocator with slack, inflates the file 6x and the
    -- byte-length check below catches it).
    local bigQuads = {}
    for i = 1, 10000 do
      bigQuads[i] = { { 0, 0, 0 }, { 1, 0, 0 }, { 1, 1, 0 }, { 0, 1, 0 },
                      uv = { { 0, 1 }, { 1, 1 }, { 1, 0 }, { 0, 0 } },
                      shade = 0.5 + (i % 10) / 20 }
    end
    local bigBuf = ffi.new("float[?]", #bigQuads * 4 * 6)
    local bigIdx = ffi.new("uint32_t[?]", #bigQuads * 6)
    local bigK, bigM = MeshCache.flattenQuads(bigQuads, bigBuf, bigIdx)
    T.eq(bigK, #bigQuads * 4 * 6, "flattenQuads float count scales linearly")
    T.eq(bigM, #bigQuads * 6, "flattenQuads index count scales linearly")
    local flat = { grass = { n = bigK / 6, buf = bigBuf, m = bigM,
                             idx = bigIdx },
                   flowers = nil, figures = {} }
    MeshCache.saveAux(fakeMap, "full", flat)
    local auxPath = MeshCache.dir() .. "/VIRIDIAN_CITY.full.aux"
    local auxF = io.open(auxPath, "rb")
    local auxBytes = auxF and auxF:read("*a") or ""
    if auxF then auxF:close() end
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
      for i = 0, bigK - 1 do
        if math.abs(aux.grass.ptr[i] - bigBuf[i]) > 1e-4 then match = false break end
      end
      T.check(match, "loadAux grass stream is byte-identical")
      match = true
      for i = 0, bigM - 1 do
        if aux.grass.iptr[i] ~= bigIdx[i] then match = false break end
      end
      T.check(match, "loadAux grass index map is byte-identical")
    end
    os.execute('rm -rf "' .. rtBase .. '"')
  end
end

run.release()
T.finish("potato_voxel")
