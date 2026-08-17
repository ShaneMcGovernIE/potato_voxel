-- Headless invariants for the single PotatoVoxel build.
package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.modkit")
local Data = require("src.core.Data")
Data:load()
local run = T.sdk.loadMod("mods/potato_voxel", { data = Data })
T.eq(#run.errors, 0, "loads clean")
local exports = run.loader.exports.potato_voxel
T.check(exports ~= nil, "mod exports a table")
local RuntimeHooks = exports.lib.require("RuntimeHooks")
local CacheFeature = exports.lib.require("CacheFeature")
T.check(type(CacheFeature.new) == "function",
        "cache feature exposes an explicit boundary")
local CacheIdentity = exports.lib.require("CacheIdentity")
T.check(type(CacheIdentity.new) == "function",
        "cache identity exposes an explicit boundary")
local CacheManifest = exports.lib.require("CacheManifest")
T.check(type(CacheManifest.new) == "function",
        "cache manifest exposes an explicit boundary")
local CacheStorage = exports.lib.require("CacheStorage")
T.check(type(CacheStorage.new) == "function",
        "cache storage exposes an explicit boundary")
local MeshRuntime = exports.lib.require("MeshRuntime")
T.check(type(MeshRuntime.new) == "function",
        "mesh runtime exposes an explicit boundary")
do
  local runtime = MeshRuntime.new()
  local released = 0
  local old = { release = function() released = released + 1 end }
  local replacement = { release = function() released = released + 1 end }
  local entry = { full = old, figures = { { mesh = replacement } } }
  runtime.swap(entry, "full", false)
  T.eq(released, 1, "mesh runtime releases a replaced GPU slot")
  runtime.releaseEntry(entry)
  T.eq(released, 2, "mesh runtime releases figure meshes with the entry")
  T.check(entry.full == nil and entry.figures == nil,
          "mesh runtime clears released cache ownership")
  local evicted = nil
  local cache = { FAR = { body = { release = function() end } } }
  local jobs = {
    { id = "FAR", slot = "body", prebuild = false,
      index = {}, completion = {} },
  }
  local generations = {}
  runtime.evict({ cache = cache, jobs = jobs, live = {}, previous = {},
                  generations = generations, index = jobs[1].index,
                  completion = jobs[1].completion,
                  onEvict = function(id) evicted = id end })
  T.check(cache.FAR == nil and #jobs == 0 and evicted == "FAR",
          "mesh runtime evicts GPU entries and queued jobs outside live sets")
end
do
  local target = { run = function(_, value) return value end }
  local installs = 0
  local wrapped = RuntimeHooks.wrapOnce(target, "run", "testHook", function(inner)
    installs = installs + 1
    return function(self, value) return inner(self, value) + 1 end
  end)
  T.eq(wrapped, true, "runtime hook helper installs once")
  T.eq(target:run(2), 3, "runtime hook helper preserves the inner call")
  T.eq(RuntimeHooks.wrapOnce(target, "run", "testHook", function()
    installs = installs + 1
    return function() return 99 end
  end), false, "runtime hook helper skips an installed marker")
  T.eq(installs, 1, "runtime hook helper does not rebuild a wrapper")
  T.eq(target:run(2), 3, "runtime hook helper keeps the original wrapper")
end
-- The sandbox-era settings read LIVE through mod.options, and writers
-- persist into a game's save options (the same dual write the engine's
-- manager page makes). The SDK stub has neither, so the suite installs a
-- functional store and a fake game whose save carries it.
local optionsState = { modOptions = {} }
optionsState.modOptions.potato_voxel = {}
exports.lib.mod.options = {
  get = function(_, key) return optionsState.modOptions.potato_voxel[key] end,
}
-- The engine's options API has NO set (only define/get); writers persist
-- through a game's save options, the loader's copy and writeOptions.
local wroteOptions = 0
local fakeGame = { save = { options = optionsState },
                   mods = { modOptions = {} },
                   writeOptions = function() wroteOptions = wroteOptions + 1 end }

-- --- the player support token (PlayerId) ----------------------------------
-- 8 digits, minted once per install, persisted in OPTIONS (per-install,
-- not per-save), stable within the session, and carried in consented log
-- payloads. It is the only way a support thread can match a player to
-- their logs, because the player must volunteer it first.
local PlayerId = exports.lib.require("PlayerId")
PlayerId._resetForTests()
local token = PlayerId.ensure()
T.check(token ~= nil and token:match("^%d%d%d%d%d%d%d%d$") ~= nil,
        "the player id is an 8-digit token")
T.eq(PlayerId.get(), token, "the token is stable within the session")
PlayerId.persist(fakeGame)
T.eq(optionsState.modOptions.potato_voxel.player_id, token,
     "the token persists in the per-install OPTIONS store")
T.eq(fakeGame.mods.modOptions.potato_voxel.player_id, token,
     "the loader copy carries the token for options:get")
T.eq(wroteOptions, 1, "the options file is written once")
PlayerId._resetForTests()
local rebooted = PlayerId.ensure()
T.eq(rebooted, token,
     "a reboot re-reads the persisted token (one id per install, not per boot)")
local brick = exports and exports.brick
T.check(brick ~= nil and brick.isBrick(), "the one build is the Brick build")
if brick then
  local Voxel = exports.lib.require("VoxelState")
  local ShadowMap = exports.lib.require("ShadowMap")
  local Voxel3D = exports.lib.require("Voxel3D")
  local Water = exports.lib.require("Water")
  local AntiAlias = exports.lib.require("AntiAlias")
  local WorldCurve = exports.lib.require("WorldCurve")
  local VoxelGrid = exports.lib.require("VoxelGrid")
  local GridKey = exports.lib.require("GridKey")
  local VR = exports.lib.require("VR")
  local Structures = exports.lib.require("Structures")
  local OverworldBattle = exports.lib.require("OverworldBattle")
  local QualityMode = exports.lib.require("QualityMode")
  local DayNight = exports.lib.require("DayNight")
  local MapAtmos = exports.lib.require("MapAtmos")
  T.eq(MapAtmos.setting:get(), false, "ATMOS defaults OFF")
  T.eq(GridKey.of(-64, -64), 0,
       "grid keys keep the lower supported coordinate at zero")
  T.eq(GridKey.of(0, 0), 262208,
       "grid keys use the shared 4096-wide packed coordinate")
  T.eq(GridKey.of(63, 63), (63 + 64) * 4096 + (63 + 64),
       "grid keys preserve the upper supported coordinate")
  T.eq(VR.supported(), false, "removed VR reports unsupported")
  T.eq(VR.enabled(), false, "removed VR never enables")
  T.eq(VR.active(), false, "removed VR never activates")
  VR.update(1 / 60)
  T.eq(VR.mirror(320, 240), nil, "removed VR has no mirror surface")
  VR.invalidate()
  T.eq(VR.paletteFor, nil, "removed VR has no palette callback")
  T.check(type(VR.cycleVoxel) == "function",
          "the composition root keeps the view-cycle compatibility callback")
  local fakeMap = { id = "VIRIDIAN_FOREST" }
  T.eq(MapAtmos.fogFor(fakeMap), nil, "ATMOS OFF: clear air even on a weather map")
  MapAtmos.setting:setValue(true, fakeGame)
  local fog = MapAtmos.fogFor(fakeMap)
  T.check(fog ~= nil, "ATMOS ON: the forest map has a haze record")
  T.check(fog ~= nil and fog.density > 0 and fog.start >= 0
          and fog.color[1] > 0, "the haze record carries color/density/start")
  T.eq(MapAtmos.fogFor({ id = "FIX_TOWN" }), nil,
       "a map with no entry draws clear air")
  local bogus = { id = "VIRIDIAN_FOREST" }
  MapAtmos.setting:setValue(false, fakeGame)
  T.eq(MapAtmos.fogFor(bogus), nil, "ATMOS OFF again: clear air")
  local ShapeDebug = exports.lib.require("ShapeDebug")
  T.eq(ShapeDebug.colorFor(nil), nil, "no shape resolves to no class colour")
  local waterC = ShapeDebug.colorFor({ class = "water" })
  T.check(waterC ~= nil and waterC[3] > waterC[1],
          "water resolves to a blue class colour")
  local groundC = ShapeDebug.colorFor({ class = "ground" })
  T.check(groundC ~= nil and groundC[2] > 0.3,
          "ground resolves to a green class colour")
  do
    local S = { shapeAt = { [50] = { class = "wall" } },
                runs = {}, skip = {} }
    local plain = ShapeDebug.pixelFor(S, 50)
    T.check(plain[1] > 0.5 and plain[2] < 0.5, "a wall tile tints red")
    S.runs[50] = true
    local run = ShapeDebug.pixelFor(S, 50)
    T.check(run[2] > plain[2], "a volume run pulls the tint toward white")
    S.runs[50] = nil
    S.skip[50] = true
    local claimed = ShapeDebug.pixelFor(S, 50)
    T.check(claimed[1] > plain[1] and claimed[3] > plain[3],
            "a claimed cell pulls the tint toward magenta")
  end
  T.check(Water.profileFor(nil) == nil, "no tileset resolves to no wave profile")
  local gymWater = Water.profileFor("GYM")
  T.check(gymWater ~= nil and #gymWater.trains == 3
          and gymWater.swell ~= nil and gymWater.bend ~= nil,
          "the GYM tileset has a calm wave profile")
  T.check(Water.waveRate(gymWater.trains) > 0,
          "a custom profile's rate derives from its own dominant train")
  T.check(Water.waveRate() > 0, "the default trains still derive a rate")
  local WeatherD = exports.lib.require("Weather")
  T.eq(WeatherD.setting:get(), false, "WEATHER defaults OFF")
  T.eq(WeatherD.entryFor({ id = "VIRIDIAN_FOREST" }), nil,
       "WEATHER OFF: clear skies even on a weather map")
  WeatherD.setting:setValue(true, fakeGame)
  local wEntry = WeatherD.entryFor({ id = "VIRIDIAN_FOREST" })
  T.check(wEntry ~= nil and wEntry.kind == "rain",
          "the forest has a rain entry")
  T.eq(WeatherD.entryFor({ id = "FIX_TOWN" }), nil,
       "a map with no entry keeps clear skies")
  local nDrops = WeatherD.dropCount(320, 288, wEntry)
  T.check(nDrops >= 40 and nDrops <= 220, "the drop pool is bounded")
  local drop = { x = 10, y = 100, z = 10, phase = 0 }
  T.eq(WeatherD.stepDrop(drop, 1 / 60, "rain", 0), false,
       "a rain drop falls without landing")
  T.check(drop.y < 100, "falling lowers the drop")
  drop.y = 1
  T.eq(WeatherD.stepDrop(drop, 1 / 60, "rain", 0), true,
       "a drop at the ground asks for a respawn")
  WeatherD.setting:setValue(false, fakeGame)
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
  T.check(ShadowMap._source():find(
            "varying LOVE_HIGHP_OR_MEDIUMP float vDepth", 1, true),
          "shadow-map depth varying keeps mobile precision")
  T.check(Voxel3D._source():find(
            "varying LOVE_HIGHP_OR_MEDIUMP vec3 vSun", 1, true),
          "scene shadow coordinates keep mobile precision")
  T.check(Voxel3D._source():find(
            "precision highp float", 1, true),
          "scene shadow comparisons request fragment high precision")
  local scenePinned = Voxel3D._source(false, false)
  local sceneBare = Voxel3D._source(false, true)
  T.check(scenePinned:find("#define EFFECT_PREC mediump\n", 1, true),
          "scene shader pins effect parameters for mobile prototypes")
  T.check(scenePinned:find(
            "EFFECT_PREC vec4 effect(EFFECT_PREC vec4 color", 1, true),
          "scene shader pins the effect RETURN type too (Mali S0023)")
  T.check(sceneBare:find("#define EFFECT_PREC\n", 1, true),
          "scene shader has a bare-precision retry variant")
  local shadowPinned = ShadowMap._source(false)
  local shadowBare = ShadowMap._source(true)
  T.check(shadowPinned:find("#define EFFECT_PREC mediump\n", 1, true),
          "shadow shader pins effect parameters for mobile prototypes")
  T.check(shadowPinned:find(
            "EFFECT_PREC vec4 effect(EFFECT_PREC vec4 color", 1, true),
          "shadow shader pins the effect RETURN type too (Mali S0023)")
  T.check(shadowBare:find("#define EFFECT_PREC\n", 1, true),
          "shadow shader has a bare-precision retry variant")
  do
    local caps = Voxel3D.diagnostics()
    T.check(type(caps) == "table" and type(caps.available) == "boolean",
            "scene capability diagnostics return a boolean gate")
    T.check(caps.reason ~= nil,
            "scene capability diagnostics name the current gate")
    T.check(type(caps.shaderErrors) == "table",
            "scene capability diagnostics preserve shader errors")
  end
  T.check(type(ShadowMap.diagnostics) == "function",
          "shadow diagnostics expose capability detail")
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
  -- The Steam Deck: its vangogh renderer rides the low-end compression
  -- class (the Deck's zlib compress stalls measured 500-680ms -- the
  -- same class the Pi had in 1.6.11). The LÖVE 11 shape (four values:
  -- name, version, vendor, device) is what the engine's LOVE answers.
  do
    local ModPlatform = exports.lib.require("Platform")
    local oldDeckRI = loveG and loveG.getRendererInfo
    if loveG then
      loveG.getRendererInfo = function()
        return "OpenGL", "4.6 (Core Profile) Mesa 25.3.0",
               "AMD Custom GPU 0932 (radeonsi, vangogh, LLVM 20.1.8)",
               "AMD"
      end
    end
    ModPlatform._resetForTests()
    T.check(ModPlatform.isSteamDeck() == (loveG ~= nil),
            "a vangogh renderer string is detected as the Deck")
    if loveG then
      T.eq(ModPlatform.lowEnd(), true,
           "the Deck rides the low-end compression class")
    end
    if loveG then loveG.getRendererInfo = oldDeckRI end
    ModPlatform._resetForTests()
    if loveG then
      T.check(not ModPlatform.isSteamDeck(),
              "a non-vangogh GPU is not the Deck")
    end
    ModPlatform._resetForTests()
  end
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
  T.eq(#Water.setting.values, 4, "WATER ladder stays available")
  Water.setting:setValue("half", fakeGame)
  T.eq(Water.level(), 2, "HALF is the reflective reduced-budget rung")
  T.eq(Water.enabled(), true, "HALF keeps the reflective pass on")
  Water.setting:setValue("full", fakeGame)
  T.eq(Water.level(), 3, "FULL is the full-budget reflective rung")
  Water.setting:setValue("off", fakeGame)
  T.eq(Water.level(), 0, "WATER back OFF")
  do
    -- The Android water flag: the reflective pass's Mali stripes are
    -- unresolved, so Android runs flat water regardless of the row -- a
    -- persisted FULL must be ignored, and the row gate reads the same
    -- answer (Water.onAndroid is also the row's `when`).
    local oldOverride = Water._androidOverride
    Water._androidOverride = true
    Water.setting:setValue("full", fakeGame)
    T.eq(Water.level(), 0, "Android forces WATER off (flat water)")
    T.eq(Water.enabled(), false, "Android never runs the reflective pass")
    T.eq(Water.onAndroid(), true, "the row gate reads the same flag")
    Water._androidOverride = false
    T.eq(Water.level(), 3, "off-Android keeps the FULL rung")
    Water._androidOverride = oldOverride
    Water.setting:setValue("off", fakeGame)
  end
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
  -- The hold chords: five seconds of SELECT toggles the debug overlay,
  -- and five seconds of START while the debugger is on exports its log --
  -- the touch/pad versions of F9 and F8. Each chord is a timer fed the
  -- engine's Input:isDown answer; releasing early aborts the count.
  local HoldChord = exports.lib.require("HoldChord")
  T.eq(HoldChord.SECONDS, 5, "the hold chords are five seconds")
  T.check(not HoldChord.update("select", 1, true),
          "a fresh SELECT hold does not fire early")
  T.check(not HoldChord.update("select", 1, true),
          "two seconds still short")
  T.check(not HoldChord.update("select", 0.5, false),
          "a SELECT release aborts the count")
  T.check(not HoldChord.update("select", 4, true),
          "a new SELECT hold restarts from zero")
  T.check(HoldChord.update("select", 1, true),
          "the fifth SELECT second fires the chord")
  T.check(not HoldChord.update("select", 1, true),
          "a continued SELECT hold does not retrigger")
  T.check(not HoldChord.update("select", 1, false),
          "a SELECT release after firing keeps it silent")
  T.check(not HoldChord.update("start", 4, true),
          "START counts its own chord independently")
  T.check(HoldChord.update("start", 1, true),
          "START fires on its own fifth second")
  T.check(not HoldChord.update("select", 1, true),
          "START firing does not disturb SELECT's timer")
  T.check(HoldChord.update("select", 5, true),
          "one long frame can cross the SELECT threshold")
  T.check(not HoldChord.update("select", 1, true),
          "the crossing frame resets the timer")
  local DebugOverlay = exports.lib.require("DebugOverlay")
  T.check(type(DebugOverlay.enabled) == "function",
          "the overlay exposes its visibility for the START chord")
  T.check(type(DebugOverlay.running) == "function",
          "the debugger exposes its background-running state")
  T.check(DebugOverlay.running(), "the debugger runs in the background at boot")
  T.check(not DebugOverlay.enabled(), "the debugger starts hidden")
  T.check(type(DebugOverlay.status) == "function",
          "the debugger exposes a data-only status snapshot")
  T.check(type(DebugOverlay.pipelineUpdate) == "function",
          "the debugger exposes pipeline heartbeat accounting")
  T.check(type(DebugOverlay.pipelineAvailable) == "function",
          "the debugger exposes pipeline capability reasons")
  T.check(type(DebugOverlay.pipelinePath) == "function",
          "the debugger exposes world-render path accounting")
  T.check(type(DebugOverlay.runProbe) == "function",
          "the debugger exposes a capability self-test")
  do
    DebugOverlay.pipelineUpdate(5)
    DebugOverlay.pipelineAvailable(false, "scene_shader_compile",
                                   { error = "test compiler error" })
    DebugOverlay.pipelinePath("fallback", { reason = "scene_shader_compile" })
    local status = DebugOverlay.status()
    T.eq(status.pipeline.level, 5, "debug status records the live voxel level")
    T.eq(status.pipeline.updateCalls, 1,
         "debug status counts pipeline update calls")
    T.eq(status.pipeline.availability, false,
         "debug status records pipeline availability")
    T.eq(status.pipeline.reason, "scene_shader_compile",
         "debug status records the pipeline failure reason")
    T.eq(status.pipeline.lastPath, "fallback",
         "debug status records the world fallback path")
    T.eq(status.pipeline.fallbacks, 1,
         "debug status counts world fallbacks")
    T.check(status.pipeline.detail.error == "test compiler error",
            "debug status preserves capability details")
    local probe = DebugOverlay.runProbe()
    T.check(type(probe) == "table", "debug capability probe returns data")
  end
  T.check(type(DebugOverlay.slowStorageBackoff) == "function",
          "the debugger exposes the slow-storage backoff policy")
  T.check(DebugOverlay.slowStorageBackoff(5) == nil,
          "fast storage never backs off the persist cadence")
  T.eq(DebugOverlay.slowStorageBackoff(25), 30,
       "a 25ms write backs off 30s (flash floor)")
  T.eq(DebugOverlay.slowStorageBackoff(105), 30,
       "the Switch's ~100ms writes back off 30s")
  T.eq(DebugOverlay.slowStorageBackoff(5000), 150,
       "multi-second writes scale the backoff")
  T.eq(DebugOverlay.slowStorageBackoff(20000), 300,
       "backoff caps at 300s")
  do
    DebugOverlay.buildDone("PALLET_TOWN", "full", 120, 843.5, 3)
    local b = DebugOverlay.status().build
    T.eq(b.jobs, 1, "build health counts finished mesh jobs")
    T.eq(b.slices, 120, "build health counts pumped slices")
    T.eq(b.overshoots, 3, "build health counts slice overshoots")
    T.eq(b.worstResumeMs, 843.5, "build health keeps the worst resume gap")
    T.eq(b.worstResumeJob, "PALLET_TOWN/full",
         "build health names the job with the worst resume")
    DebugOverlay.buildDone("VIRIDIAN_FOREST", "body", 40, 1200, 1)
    b = DebugOverlay.status().build
    T.eq(b.worstResumeMs, 1200, "build health keeps the global worst gap")
    T.eq(b.worstResumeJob, "VIRIDIAN_FOREST/body",
         "build health renames the worst job")
  end
  do
    local Budget = exports.lib.require("BuildBudget")
    T.check(Budget.inBuild and Budget.inBuild() == false,
            "the build budget reports out-of-build outside the pump")
  end
  do
    -- Void-fill churn must invalidate the cache once, or never for a
    -- round trip: the field log showed trees -> water -> trees in 0.7s
    -- dropping the whole cache twice.
    local Debounce = exports.lib.require("VoidFillDebounce")
    Debounce.reseed("trees")
    T.eq(Debounce.tick("trees", 0), "none", "an unchanged value does nothing")
    T.eq(Debounce.tick("water", 1), "hold", "a change waits for the settle window")
    T.eq(Debounce.tick("water", 1.5), "hold", "still settling")
    local action, from = Debounce.tick("water", 2)
    T.eq(action, "invalidate", "a settled change invalidates once")
    T.eq(from, "trees", "the invalidate names the pre-burst value")
    T.eq(Debounce.tick("water", 2.1), "none", "no repeat invalidations")
    Debounce.reseed("trees")
    Debounce.tick("water", 10)
    T.eq(Debounce.tick("trees", 10.5), "none",
         "a round trip cancels the invalidate")
    Debounce.reseed("trees")
    Debounce.tick("water", 20)
    Debounce.tick("grass", 20.3)
    Debounce.tick("sand", 20.6)
    action, from = Debounce.tick("sand", 21.6)
    T.eq(action, "invalidate", "a churn burst invalidates exactly once")
    T.eq(from, "trees", "the burst invalidate names the pre-burst value")
  end
  do
    local oldLove = _G.love
    local printed = {}
    _G.love = {
      graphics = {
        getFont = function() return nil end,
        getColor = function() return 1, 1, 1, 1 end,
        setFont = function() end,
        setColor = function() end,
        rectangle = function() end,
        print = function(line) printed[#printed + 1] = line end,
      },
    }
    DebugOverlay.note("hidden boot marker")
    DebugOverlay.toggle()
    DebugOverlay.draw()
    local found = false
    for _, line in ipairs(printed) do
      if tostring(line):find("hidden boot marker", 1, true) then
        found = true
        break
      end
    end
    T.check(found, "background diagnostics remain available when F9 shows the panel")
    DebugOverlay.toggle()
    _G.love = oldLove
  end
  -- The log-send gate: F8 / SEND LOGS / the START chord all land on
  -- Overlay.export, and sending is ON by default (opt-out) with no
  -- prompt -- LOGS TO DEV gates every send. The engine under test has
  -- neither postLog nor a manifest log_url, so the gate is exercised
  -- with fakes installed -- and with them removed the export must pass
  -- straight through, exactly as a local-only engine does.
  do
    local mod = exports.lib.mod
    local oldPostLog, oldManifest = mod.postLog, mod.manifest
    local oldFetch = mod.fetch
    local sends, lastBody = 0, nil
    local sendGame = { save = { options = optionsState } }
    -- Without a send capability the export must never send: the local
    -- dump is the whole action there. The engine loader now provides
    -- mod.postLog unconditionally, so this sub-case clears both the
    -- transport and the manifest's log_url explicitly.
    local noSendPostLog, noSendManifest = mod.postLog, mod.manifest
    mod.postLog = nil
    mod.manifest = nil
    T.check(not DebugOverlay.canSend(),
            "no postLog or log_url means nothing can be sent")
    DebugOverlay.export(sendGame)
    T.eq(sends, 0, "a local-only export sends nothing")
    mod.postLog, mod.manifest = noSendPostLog, noSendManifest
    mod.postLog = function(_, body) sends = sends + 1 lastBody = body return true end
    mod.manifest = { log_url = "https://logs.example.invalid/logs" }
    T.check(DebugOverlay.canSend(),
            "postLog plus a log_url makes a send possible")
    T.check(DebugOverlay.sendingAllowed(),
            "log sending defaults to ON (opt-out)")
    DebugOverlay.export(sendGame)
    T.eq(sends, 1, "an export sends immediately with no prompt")
    DebugOverlay.export(sendGame)
    T.eq(sends, 2, "a second export sends directly too")
    -- The send identity carries the platform AND the GPU the log came
    -- from.  The engine's Platform module answers the OS; captureEnvironment
    -- answers the renderer (LÖVE 12's table shape) and the DPI scale --
    -- the two facts every render/shadow report is sorted by.  All of it
    -- shows through into the send header, the status excerpt and the data
    -- snapshot.
    do
      local Platform = require("src.core.Platform")
      local oldLove = _G.love
      Platform._resetForTests()
      _G.love = {
        system = { getOS = function() return "Android" end },
        graphics = {
          getRendererInfo = function()
            return { name = "Metal", vendor = "Apple",
                     device = "Apple A13 GPU", version = "3.2" }
          end,
          getDimensions = function() return 200, 100 end,
          getPixelDimensions = function() return 600, 300 end,
        },
      }
      DebugOverlay.captureEnvironment()
      Platform._resetForTests()
      _G.love = oldLove
      T.eq(DebugOverlay.status().platform, "Android (mobile)",
           "the status snapshot names the platform and its class")
      T.eq(DebugOverlay.status().renderer.renderer.name, "Metal",
           "the status snapshot names the GPU backend")
      T.eq(DebugOverlay.status().renderer.renderer.device, "Apple A13 GPU",
           "the status snapshot names the GPU device")
      local statusSettings = DebugOverlay.status().settings
      T.check(type(statusSettings) == "string"
              and statusSettings:find("voxel=", 1, true) ~= nil
              and statusSettings:find(" water=", 1, true) ~= nil
              and statusSettings:find(" shadows=", 1, true) ~= nil,
              "the status snapshot carries the VOXEL SETTINGS line")
      DebugOverlay.export(sendGame)
      T.eq(sends, 3, "a consented export sends after the platform capture")
      -- L4T (Switch hardware running Linux) reports OS=Linux with a
      -- Tegra renderer; the slug must answer `switch` from the GPU
      -- witness -- and a non-Tegra Linux handheld (the Brick's GE8300)
      -- must keep its honest `linux`.
      do
        Platform._resetForTests()
        _G.love = {
          system = { getOS = function() return "Linux" end },
          graphics = {
            getRendererInfo = function()
              return { name = "OpenGL", vendor = "Mesa",
                       device = "Tegra X1 (NV13B)", version = "4.5" }
            end,
          },
        }
        DebugOverlay.captureEnvironment()
        Platform._resetForTests()
        _G.love = oldLove
        T.eq(DebugOverlay._platformSlug(), "switch",
             "a Tegra renderer under Linux slugs as switch (L4T)")
        -- the LÖVE 11 four-value shape, with the Tegra string in the
        -- DEVICE slot where real Mesa builds put it -- pins the field
        -- order so the Deck's scrambled-fields bug cannot come back
        Platform._resetForTests()
        _G.love = {
          system = { getOS = function() return "Linux" end },
          graphics = {
            getRendererInfo = function()
              return "OpenGL", "4.5", "NVIDIA", "Tegra X1 (NV13B)"
            end,
          },
        }
        DebugOverlay.captureEnvironment()
        Platform._resetForTests()
        _G.love = oldLove
        T.eq(DebugOverlay._platformSlug(), "switch",
             "the LÖVE 11 field order keeps the Tegra device in the match")
        T.eq(DebugOverlay.status().renderer.renderer.device, "Tegra X1 (NV13B)",
             "the LÖVE 11 field order lands device in the device slot")
        Platform._resetForTests()
        _G.love = {
          system = { getOS = function() return "Linux" end },
          graphics = {
            getRendererInfo = function()
              return { name = "OpenGL", vendor = "Mesa",
                       device = "GE8300", version = "4.5" }
            end,
          },
        }
        DebugOverlay.captureEnvironment()
        Platform._resetForTests()
        _G.love = oldLove
        T.eq(DebugOverlay._platformSlug(), "linux",
             "a non-Tegra Linux handheld keeps the linux slug")
      end
      -- The send is ONE organized JSON document (schema 3): identity
      -- fields at the top (the server names and sorts the file from
      -- them), boot evidence once per session, a ring DELTA, and the
      -- structured status snapshot.
      local okJ, Json = pcall(require, "src.link.Json")
      T.check(okJ and type(lastBody) == "string" and Json.decode,
              "the send body is decodable JSON")
      local sent = okJ and Json.decode(lastBody)
      T.check(sent ~= nil, "the send body parses")
      if sent then
        T.eq(sent.schema, 3, "the send carries the JSON schema version")
        T.check(sent.platform == "android", "the send carries the platform slug")
        T.check(sent.gpu and sent.gpu:find("Metal Apple A13 GPU", 1, true) ~= nil,
                "the send carries the GPU identity")
        T.check(sent.engine ~= nil and sent.mod ~= nil,
                "the send carries the engine and mod versions")
        T.check(sent.date and sent.date:match("^%d%d_%d%d_%d%d%d%d$") ~= nil,
                "the send carries the DD_MM_YYYY log date")
        T.eq(sent.playerId, token,
             "the send carries the player support token")
        local status = sent.status
        T.check(status ~= nil, "the send carries the status snapshot")
        if status then
          T.check(status.platform == "Android (mobile)",
                  "the status snapshot names the platform and its class")
          T.check(status.renderer and status.renderer.renderer
                  and status.renderer.renderer.device == "Apple A13 GPU",
                  "the status snapshot carries the full renderer identity")
          T.check(status.renderer and status.renderer.dimensions
                  and status.renderer.dimensions.w == 200
                  and status.renderer.pixelDimensions
                  and status.renderer.pixelDimensions.h == 300,
                  "the status snapshot carries the DPI-scale dimensions")
          T.check(type(status.settings) == "string"
                  and status.settings:find("voxel=", 1, true) ~= nil
                  and status.settings:find(" water=", 1, true) ~= nil
                  and status.settings:find(" shadows=", 1, true) ~= nil,
                  "the status snapshot carries the VOXEL SETTINGS line")
          local pr = status.probe and status.probe.result
          -- Headless the real probe may report shadows/voxel as
          -- unavailable (no GPU), but the section must still be present
          -- and carry the availability answer.
          T.check(pr and pr.shadows ~= nil and pr.shadows.available ~= nil,
                  "the status snapshot carries the shadow availability answer")
          T.check(pr and pr.voxel ~= nil and pr.voxel.available ~= nil,
                  "the status snapshot carries the voxel availability answer")
        end
      end
    end
    -- A pass on the internal depth buffer ships the per-format creation
    -- errors (the highdpi dpiscale mismatch is the usual suspect); a
    -- stubbed probe drives that path headlessly.
    do
      DebugOverlay.setProbe(function()
        return { shadows = {
          available = true, reason = "ready", resolution = 1024,
          shaderPrecision = "mediump",
          depth = { binding = "internal",
                    failures = { { format = "depth24", error = "mismatch" } } },
          spriteReady = false, passCounts = { aborts = 0 } } }
      end)
      DebugOverlay.runProbe()
      DebugOverlay.export(sendGame)
      T.eq(sends, 4, "a consented export sends with the stubbed probe")
      local okJ2, Json2 = pcall(require, "src.link.Json")
      local sent2 = okJ2 and Json2.decode(lastBody)
      local pr2 = sent2 and sent2.status and sent2.status.probe
                 and sent2.status.probe.result
      T.check(pr2 and pr2.shadows and pr2.shadows.available == true
              and pr2.shadows.depth and pr2.shadows.depth.binding == "internal",
              "the status snapshot shows the internal depth fallback")
      T.check(pr2 and pr2.shadows and pr2.shadows.depth
              and pr2.shadows.depth.failures
              and pr2.shadows.depth.failures[1]
              and pr2.shadows.depth.failures[1].format == "depth24"
              and pr2.shadows.depth.failures[1].error == "mismatch",
              "the status snapshot ships the per-format depth failure reasons")
      -- restore the real probe shape main.lua installed (headless-safe)
      local Prebuild = exports.lib.require("CachePrebuild")
      local Voxel3D = exports.lib.require("Voxel3D")
      local ShadowMap = exports.lib.require("ShadowMap")
      DebugOverlay.setProbe(function()
        local done, total, running, eta = Prebuild.progress()
        return {
          voxel = Voxel3D.diagnostics(),
          shadows = ShadowMap.diagnostics(),
          cache = { identity = "restored", saveFailures = 0 },
          prebuild = { status = "x", done = done, total = total },
        }
      end)
    end
    -- OFF stops the send while the local dump still happens, and the
    -- stored value is read live, so a manager-page write takes effect
    -- on the very next export.
    optionsState.modOptions.potato_voxel.send_logs = false
    T.check(not DebugOverlay.sendingAllowed(), "the toggle reads the stored OFF")
    DebugOverlay.export(sendGame)
    T.eq(sends, 4, "an export sends nothing while LOGS TO DEV is OFF")
    optionsState.modOptions.potato_voxel.send_logs = true
    T.check(DebugOverlay.sendingAllowed(), "the toggle reads the stored ON")
    DebugOverlay.export(sendGame)
    T.eq(sends, 5, "turning LOGS TO DEV back ON restores sending")
    -- The automatic send: every 90 seconds of accumulated game time the
    -- frame tick ships the log with no keypress -- but only when the ring
    -- grew since the last send (idle backoff, OPT-1: an unchanged delta
    -- is not worth a POST; a fully idle session still heartbeats at the
    -- five-minute cap). The schedule is a next-deadline, so a skipped
    -- interval fires at the first tick past it -- and OFF silences it
    -- like every other send. The fake fetch settles each handle so the
    -- next interval can send.
    do
      mod.fetch = {
        poll = function() return { status = "ok" } end,
        release = function() end,
        cancel = function() end,
      }
      optionsState.modOptions.potato_voxel.send_logs = false
      DebugOverlay.frame(90)
      T.eq(sends, 5, "the auto-send respects LOGS TO DEV OFF")
      optionsState.modOptions.potato_voxel.send_logs = true
      DebugOverlay.frame(0.01)
      T.eq(sends, 5, "an idle ring skips the 90s deadline (backoff)")
      DebugOverlay.note("tick marker one")
      DebugOverlay.frame(89.99)
      T.eq(sends, 5, "the skip pushed the next deadline out a full interval")
      DebugOverlay.frame(89.99)
      T.eq(sends, 6, "the frame tick auto-sends once 90 seconds of game time pass")
      DebugOverlay.frame(89.99)
      T.eq(sends, 6, "an idle ring skips the next deadline too (backoff)")
      DebugOverlay.note("tick marker two")
      DebugOverlay.frame(89.99)
      T.eq(sends, 7, "the auto-send repeats every 90 seconds of game time")
      mod.fetch = oldFetch
    end
    -- Delta sends: after a successful send the next payload carries only
    -- the ring lines added since (the watermark advances on success, and
    -- a failed send keeps it so the next send retries the same delta).
    do
      local mod2 = exports.lib.mod
      local oldPostLog2, oldManifest2 = mod2.postLog, mod2.manifest
      local bodies = {}
      local failNext = false
      mod2.postLog = function(_, body)
        if failNext then
          failNext = false
          return nil, "engine rejected the send"
        end
        bodies[#bodies + 1] = body
        return true
      end
      mod2.manifest = { log_url = "https://logs.example.invalid/logs" }
      optionsState.modOptions.potato_voxel.send_logs = true
      local Json2 = require("src.link.Json")
      -- Emit a couple of distinct lines through the overlay so the ring
      -- has content, then send twice and inspect the deltas.
      DebugOverlay.note("delta marker one")
      DebugOverlay.note("delta marker two")
      DebugOverlay.export(sendGame)
      DebugOverlay.export(sendGame)
      T.eq(#bodies, 2, "two consented exports send")
      local first = bodies[1] and Json2.decode(bodies[1])
      local second = bodies[2] and Json2.decode(bodies[2])
      T.check(first ~= nil and first.schema == 3, "the first send is JSON schema 3")
      T.check(second ~= nil and second.schema == 3, "the second send is JSON schema 3")
      if first and second then
        T.check(type(first.ring) == "table" and #first.ring > 0,
                "the first send carries the ring")
        T.check(second.boot == nil,
                "boot evidence is not repeated on the second send")
        T.check(type(second.ring) == "table",
                "the second send still carries a ring array")
        -- The watermark means the second ring is the delta (shorter or
        -- equal to the first, never a full re-send of everything).
        T.check(#second.ring <= #(first.ring or {}),
                "the second send carries a delta, not a full re-send")
        -- Failed send: watermark stays, next send retries the same delta.
        local before = #bodies
        failNext = true
        DebugOverlay.export(sendGame)
        T.eq(#bodies, before, "a rejected send does not count as sent")
        DebugOverlay.export(sendGame)
        T.eq(#bodies, before + 1, "the next send goes out")
        local retried = bodies[#bodies] and Json2.decode(bodies[#bodies])
        T.check(retried ~= nil and type(retried.ring) == "table",
                "the retried send carries a ring")
      end
      mod2.postLog, mod2.manifest = oldPostLog2, oldManifest2
    end
    mod.postLog, mod.manifest = oldPostLog, oldManifest
  end

  -- The auto-send cadence backs off on an idle ring: an interval only
  -- ships when new lines arrived since the last send (or the boot
  -- evidence is still unsent), and a fully idle session still sends a
  -- liveness heartbeat at most once per five minutes of game time.  The
  -- schedule is driven by synthetic 90s ticks through the same fake
  -- transport as the gate block above -- no real timers.
  do
    local mod3 = exports.lib.mod
    local oldPostLog3, oldManifest3 = mod3.postLog, mod3.manifest
    local oldFetch3 = mod3.fetch
    local oldSendSetting3 = optionsState.modOptions.potato_voxel.send_logs
    local sends = 0
    local bodies = {}
    mod3.postLog = function(_, body)
      sends = sends + 1
      bodies[#bodies + 1] = body
      return true
    end
    mod3.manifest = { log_url = "https://logs.example.invalid/logs" }
    mod3.fetch = {
      poll = function() return { status = "ok" } end,
      release = function() end,
      cancel = function() end,
    }
    optionsState.modOptions.potato_voxel.send_logs = true
    local sendGame = { save = { options = optionsState } }
    -- Settle the send handle a prior send left in flight so the deadline
    -- branch is the only gate in play, then give the ring one new line
    -- so the first deadline crossing ships -- that send anchors the idle
    -- window (the last-auto-send cap) at a known point.
    DebugOverlay.frame(0.01)
    DebugOverlay.note("cadence baseline marker")
    DebugOverlay.frame(90)
    DebugOverlay.frame(0.01)
    local baseline = sends
    T.check(baseline >= 1, "the auto-send ships when the ring grew")
    -- (a) Nothing new since that send: the next 90s deadline must NOT
    -- ship the identical delta, and the same holds for the next two
    -- deadlines while the ring stays idle.
    DebugOverlay.frame(90)
    DebugOverlay.frame(0.01)
    T.eq(sends, baseline, "an idle deadline ships nothing")
    DebugOverlay.frame(90)
    DebugOverlay.frame(0.01)
    T.eq(sends, baseline, "the idle backoff extends the deadline again")
    DebugOverlay.frame(90)
    DebugOverlay.frame(0.01)
    T.eq(sends, baseline, "the idle backoff holds until the heartbeat cap")
    -- (b) The five-minute cap: with the ring still idle, the deadline
    -- the cap lands on must send the liveness heartbeat -- at most once
    -- per 300s of game time, never a flood.
    DebugOverlay.frame(90)
    DebugOverlay.frame(0.01)
    T.eq(sends, baseline + 1, "an idle session heartbeats at the five-minute cap")
    local okH, JsonH = pcall(require, "src.link.Json")
    local heartbeat = okH and JsonH.decode(bodies[#bodies])
    T.check(heartbeat ~= nil and heartbeat.boot == nil,
            "the heartbeat repeats no boot evidence")
    -- Manual sends stay untouched by the backoff: an export ships even
    -- with a completely idle ring.
    DebugOverlay.export(sendGame)
    T.eq(sends, baseline + 2, "a manual export is never throttled by the backoff")
    mod3.postLog, mod3.manifest = oldPostLog3, oldManifest3
    mod3.fetch = oldFetch3
    optionsState.modOptions.potato_voxel.send_logs = oldSendSetting3
  end

  -- The stall tag names the driver and the shader-switch counter: when a
  -- stats window's worst frame crosses 500ms, the tagged line must carry
  -- the GPU identity (health.renderer) and getStats().shaderswitches --
  -- the two witnesses for a driver/compositor upload burst (the Deck's
  -- 34s crawl pinned texMB flat, so texture memory alone could not prove
  -- it).  A fake love supplies a controllable clock and the getStats
  -- table; the renderer identity is captured fresh so the fields are
  -- exact.
  do
    local oldLove4 = _G.love
    local fakeT = 0
    _G.love = {
      timer = { getTime = function() return fakeT end },
      graphics = {
        getRendererInfo = function()
          return { name = "OpenGL", vendor = "Mesa",
                   device = "Steam Deck (Van Gogh)", version = "4.6" }
        end,
        getStats = function()
          return { texturememory = 19327352, shaderswitches = 7 }
        end,
      },
    }
    local Platform = require("src.core.Platform")
    Platform._resetForTests()
    DebugOverlay.captureEnvironment()
    local mod4 = exports.lib.mod
    local oldPostLog4, oldManifest4 = mod4.postLog, mod4.manifest
    local oldFetch4 = mod4.fetch
    local oldSendSetting4 = optionsState.modOptions.potato_voxel.send_logs
    local bodies = {}
    mod4.postLog = function(_, body)
      bodies[#bodies + 1] = body
      return true
    end
    mod4.manifest = { log_url = "https://logs.example.invalid/logs" }
    mod4.fetch = {
      poll = function() return { status = "ok" } end,
      release = function() end,
      cancel = function() end,
    }
    optionsState.modOptions.potato_voxel.send_logs = true
    local sendGame = { save = { options = optionsState } }
    DebugOverlay.frame(0.01)  -- settle any in-flight send handle
    -- One >500ms frame into the open stats window, then jump the clock
    -- past STATS_EVERY so the window closes on it and the stall tag is
    -- written while the fake getStats and renderer identity are live.
    DebugOverlay.frame(0.6)
    fakeT = 1e9
    DebugOverlay.frame(0.01)
    DebugOverlay.export(sendGame)
    Platform._resetForTests()
    _G.love = oldLove4
    local okJ4, Json4 = pcall(require, "src.link.Json")
    local sent4 = okJ4 and Json4.decode(bodies[#bodies])
    local stallLine = nil
    if sent4 and sent4.ring then
      for _, line in ipairs(sent4.ring) do
        if tostring(line):find("STALL>500ms", 1, true) then
          stallLine = tostring(line)
          break
        end
      end
    end
    T.check(stallLine ~= nil, "a >500ms window ships a STALL-tagged line")
    if stallLine then
      T.check(stallLine:find("shaderSw=7", 1, true) ~= nil,
              "the stall tag carries the shader-switch counter")
      T.check(stallLine:find("texMB=18.4", 1, true) ~= nil,
              "the stall tag still carries the texture memory")
      T.check(stallLine:find("gpu=OpenGL Mesa Steam Deck (Van Gogh)", 1, true) ~= nil,
              "the stall tag names the GPU driver")
    end
    mod4.postLog, mod4.manifest = oldPostLog4, oldManifest4
    mod4.fetch = oldFetch4
    optionsState.modOptions.potato_voxel.send_logs = oldSendSetting4
  end
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

  do
    -- A successful persist clears the boot's expected failure state: the
    -- not_in_playthrough entries from before the playthrough existed
    -- must not poison every later status snapshot.
    local DebugOverlay = exports.lib.require("DebugOverlay")
    local goodStore = exports.lib.mod.storage
    local badStore = setmetatable({}, {
      __index = function(_, k)
        if k == "writeBytes" then
          return function() return false, "not_in_playthrough",
            "Storage is available only inside an identified playthrough." end
        end
        return nil
      end,
    })
    exports.lib.mod.storage = badStore
    DebugOverlay.note("storage failure probe")
    local failed = DebugOverlay.status().storage
    T.eq(failed.state, "not_in_playthrough",
         "a failing write records the failure state")
    T.check(failed.lastError ~= nil,
            "a failing write records the failure reason")
    exports.lib.mod.storage = goodStore
    DebugOverlay.export()
    local cleared = DebugOverlay.status().storage
    T.eq(cleared.state, "ok",
         "a successful write clears the stale storage failure state")
    T.check(cleared.lastError == nil,
            "a successful write clears the stale storage lastError")
    exports.lib.mod.storage = goodStore
  end

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
  local auxBytes = fakeStore.peekBytes()["maps/VIRIDIAN_CITY/full/deco"] or ""
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
          m.vertexMapCalls = {}
          function m.setVertices() end
          function m.setVertexMap(_, map, start)
            m.vertexMapCalls[#m.vertexMapCalls + 1] = {
              count = type(map) == "table" and #map or 0,
              start = start,
            }
          end
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
    -- Mesh:setVertexMap replaces the complete map; it has no ranged-update
    -- overload. The cache loader must therefore call it exactly once with
    -- the complete index list, even when a large map needs sliced vertices.
    do
      local manyQuads, manyBuf, manyIdx = {}, {}, {}
      for i = 1, 2731 do
        manyQuads[#manyQuads + 1] = {
          { 0, 0, 0 }, { 1, 0, 0 }, { 1, 1, 0 }, { 0, 1, 0 },
          u = 0.25, v = 0.25, shade = 0.5,
        }
      end
      local manyK, manyM = MeshCache.flattenQuads(manyQuads, manyBuf, manyIdx)
      MeshCache.saveAux(fastMap, "full",
                        { grass = { n = manyK / 6, buf = manyBuf,
                                    m = manyM, idx = manyIdx },
                          flowers = nil, figures = {} })
      ChunkMesher.release(fastMap.id)
      local reloaded = ChunkMesher.request(fastMap, false, nil, true)
      T.check(reloaded ~= nil, "large cached mesh reloads")
      local grass = ChunkMesher.grass(fastMap)
      local calls = grass and grass.vertexMapCalls or {}
      T.eq(#calls, 1, "large cached mesh uploads one complete vertex map")
      T.eq(calls[1] and calls[1].count, manyM,
           "large cached mesh uploads every vertex-map index")
      T.eq(calls[1] and calls[1].start, nil,
           "vertex-map upload does not pass a false range offset")
    end
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
