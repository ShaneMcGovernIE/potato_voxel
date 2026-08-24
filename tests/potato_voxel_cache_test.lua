package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Data = require("src.core.Data")
Data:load()

local run = T.sdk.loadMod("mods/potato_voxel", { data = Data })
T.eq(#run.errors, 0, "loads clean")

local exports = run.loader.exports.potato_voxel
-- The same functional options store the main suite installs: the
-- sandbox-era rows read LIVE through mod.options, and the brick gate
-- below moves the RENDER SCALE knob.
local optionsState = { modOptions = {} }
exports.lib.mod.options = {
  get = function(_, key) return optionsState.modOptions.potato_voxel[key] end,
}
local fakeGame = { save = { options = optionsState },
                   writeOptions = function() end }
local Prebuild = exports.lib.require("CachePrebuild")
local MeshCache = exports.lib.require("MeshCache")
local ChunkMesher = exports.lib.require("ChunkMesher")
local Structures = exports.lib.require("Structures")
local Buildings = exports.lib.require("Buildings")
local WorkerPool = exports.lib.require("WorkerPool")
local Brick = exports.brick
local Battles = exports.lib.require("OverworldBattle")
local QualityMode = exports.lib.require("QualityMode")

T.eq(MeshCache.GEOMETRY_VERSION, 28,
     "v28 invalidates object streams built without authored vox props")

-- Platform switching for the Switch-gated cache fixes: stub the OS the
-- engine Platform module answers, exactly like the main suite does, and
-- restore afterwards. The mod's own Platform wrapper has no state of its
-- own (it forwards to the engine module), so only the engine cache needs
-- the reset.
local EnginePlatform = require("src.core.Platform")
local function withOS(osName, fn)
  local oldLove = _G.love
  _G.love = oldLove or {}
  _G.love.system = _G.love.system or {}
  local oldOS = _G.love.system.getOS
  _G.love.system.getOS = function() return osName end
  EnginePlatform._resetForTests()
  local ok, err = pcall(fn)
  EnginePlatform._resetForTests()
  -- Restore the shim's real getOS: _G.love is the SDK's SHARED love
  -- table, so mutating it in place and only restoring the reference
  -- leaks the stub to every later test (a leaked "NX" flipped the
  -- off-Switch codec assertions on CI).
  _G.love.system.getOS = oldOS
  _G.love = oldLove
  if not ok then error(err, 0) end
end

if Brick and Brick.isBrick() then
  T.eq(Brick.battleRenderScale(), 1.0,
       "battle scene follows the RENDER SCALE knob (default 100%)")
  QualityMode.renderSetting:setValue(50, fakeGame)
  T.eq(Brick.battleRenderScale(), 0.5,
       "battle scene follows a changed RENDER SCALE")
  QualityMode.renderSetting:setValue(100, fakeGame)
  T.eq(Brick.battleActorShadowMap(1), true,
       "HIGH keeps battle actor shadow map")
  T.eq(Brick.battleActorShadowMap(4), false,
       "POTATO uses cheap battle contact shadows")
  T.eq(Battles.setting.values[1], false, "3D-BTL is off by default")
  T.eq(Battles.setting.values[2], true, "3D-BTL remains available")
end

local maps = {
  B = { id = "B", width = 3, height = 2, borderBlock = 0,
        blocks = { 1, 2, 3, 4, 5, 6 }, connections = {} },
  A = { id = "A", width = 4, height = 5, borderBlock = 0,
        blocks = { 1, 2, 3, 4, 5, 6 }, connections = {
          east = { map = "B", offset = 0 },
        } },
}

local jobs = Prebuild.enumerate(maps)
T.check(type(Prebuild.rebuild) == "function",
        "prebuild exposes a destructive rebuild action")
T.eq(#jobs, 4, "prebuild enumerates body and ring variants")
T.eq(jobs[1].id, "A", "prebuild sorts map ids")
T.eq(jobs[1].slot, "body", "body runs before ring")
T.eq(jobs[2].slot, "ring", "ring follows body")
T.eq(Prebuild.activationDecision("PREBUILD", false), "start",
     "incomplete cache starts a build")
T.eq(Prebuild.activationDecision("READY", false), "confirm_rebuild",
     "ready cache confirms rebuild")
T.eq(Prebuild.activationDecision("BUILD 1/4", true), "cancel",
     "running cache build cancels")

MeshCache.configure({ maps = maps, tilesets = {} })
local firstIdentity = MeshCache.identity()
maps.A.blocks[1] = 99
MeshCache.configure({ maps = maps, tilesets = {} })
T.check(firstIdentity ~= MeshCache.identity(),
        "map data changes the cache identity")

T.check(MeshCache.mkdirCommands == nil,
        "directory creation is shell-free (love.filesystem / libc mkdir)")

local record = MeshCache.jobRecord({
  id = "A", tileset = { image = "tileset.png", trueColor = false },
  renderer = { gbcAtlas = false },
}, "body")
T.check(record.terrain ~= record.water and record.water ~= record.aux,
        "job record names terrain, water, and aux files separately")
T.check(record.terrainFp ~= record.waterFp
          and record.waterFp ~= record.auxFp,
        "job record fingerprints each payload separately")

-- F6: the dataset revision covers every tileset input the mesher reads.
local function shallowCopy(table_)
  local out = {}
  for key, value in pairs(table_ or {}) do out[key] = value end
  return out
end
local baseData = {
  maps = {
    A = { id = "A", width = 4, height = 5, borderBlock = 0,
          tileset = "T", blocks = { 1, 2, 3, 4, 5, 6 },
          connections = { east = { map = "B", offset = 0 } } },
  },
  tilesets = {
    T = { id = "T", image = "t.png", tilesPerRow = 16,
          blocks = { 1, 2 }, walkable = { 1, 2 }, counterTiles = {},
          doorTiles = {}, warpTiles = {}, grassTile = 1 },
  },
}
MeshCache.configure(baseData)
local baseIdentity = MeshCache.identity()
local function revisionDiffers(variant)
  MeshCache.configure(variant)
  local different = MeshCache.identity() ~= baseIdentity
  MeshCache.configure(baseData)
  return different
end
local counterVariant = { maps = baseData.maps,
                         tilesets = { T = shallowCopy(baseData.tilesets.T) } }
counterVariant.tilesets.T.counterTiles = { 42 }
T.check(revisionDiffers(counterVariant),
        "counterTiles changes the dataset revision")
local grassVariant = { maps = baseData.maps,
                       tilesets = { T = shallowCopy(baseData.tilesets.T) } }
grassVariant.tilesets.T.grassTile = 7
T.check(revisionDiffers(grassVariant),
        "grassTile changes the dataset revision")
local doorVariant = { maps = baseData.maps,
                      tilesets = { T = shallowCopy(baseData.tilesets.T) } }
doorVariant.tilesets.T.doorTiles = { 9 }
T.check(revisionDiffers(doorVariant),
        "doorTiles changes the dataset revision")
local warpVariant = { maps = baseData.maps,
                      tilesets = { T = shallowCopy(baseData.tilesets.T) } }
warpVariant.tilesets.T.warpTiles = { 4, 5 }
T.check(revisionDiffers(warpVariant),
        "warpTiles changes the dataset revision")
local walkVariant = { maps = baseData.maps,
                      tilesets = { T = shallowCopy(baseData.tilesets.T) } }
walkVariant.tilesets.T.walkable = { 1 }
T.check(revisionDiffers(walkVariant),
        "walkable changes the dataset revision")

-- The fake storage box: the sandbox's mod.storage shape, stubbed for
-- headless runs. Tables go in one drawer, bytes in another; list() answers
-- both with a shared prefix; delete() empties both. context() always names
-- a playthrough so MeshCache resolves this facade as the live store.
local fakeStore = (function()
  local tables, bytes = {}, {}
  local function listed(bucket, prefix)
    local out = {}
    for key in pairs(bucket) do
      if key:sub(1, #prefix) == prefix then out[#out + 1] = key end
    end
    return out
  end
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
      for _, k in ipairs(listed(tables, prefix)) do out[#out + 1] = k end
      for _, k in ipairs(listed(bytes, prefix)) do out[#out + 1] = k end
      table.sort(out)
      return out
    end,
    delete = function(_, _, key)
      tables[key] = nil
      bytes[key] = nil
      return true
    end,
    peekTables = function() return tables end,
    peekBytes = function() return bytes end,
  }
end)()

-- The mod namespace is exported (mod.exports.lib = V), so the test can
-- hand MeshCache the fake box directly.
exports.lib.mod.storage = fakeStore

local fakeMap = {
  id = "A", tileset = { image = "tileset.png", trueColor = false },
  renderer = { gbcAtlas = false },
}

if MeshCache.available() then
  T.check(MeshCache.dir() == "storage",
          "the cache lives in scoped storage, not a raw dir")
  T.check(MeshCache.available(),
          "cache availability resolves the storage facade")

  MeshCache.configure({ maps = maps, tilesets = {} })
  MeshCache.saveTerrain(fakeMap, "body", nil, 0)
  MeshCache.saveWater(fakeMap, "body", nil, 0)
  MeshCache.saveAux(fakeMap, "body", { figures = {} })
  local manifestRecord = MeshCache.jobRecord(fakeMap, "body")
  T.check(fakeStore.peekBytes()["maps/A/body/terrain"] ~= nil,
          "saveTerrain stores a terrain payload in the box")
  T.check(fakeStore.peekTables()["meta/A/body/terrain"] ~= nil,
          "each payload leaves a meta summary behind")
  -- Windows reserved-device names (AUX/CON/PRN/NUL/COM1-9/LPT1-9) cannot
  -- be file base names: a key ending "/aux" made every aux write fail
  -- write_failed on Windows while terrain/water in the same directory
  -- succeeded. The on-disk segment is remapped to "deco"; the internal
  -- kind and every trace stay "aux".
  T.check(fakeStore.peekBytes()["maps/A/shared/deco"] ~= nil,
          "aux payloads use one shared non-reserved map key")
  T.check(fakeStore.peekBytes()["maps/A/shared/aux"] == nil
          and fakeStore.peekBytes()["maps/A/shared/aux.bin"] == nil,
          "no Windows-reserved aux base name is ever used")
  local bodyAux = MeshCache.jobRecord(fakeMap, "body").aux
  local auxWrites = 0
  local payloadReads = 0
  local realWriteBytes = fakeStore.writeBytes
  local realReadBytes = fakeStore.readBytes
  fakeStore.writeBytes = function(_, game, key, value)
    if key == "maps/A/shared/deco" then auxWrites = auxWrites + 1 end
    return realWriteBytes(_, game, key, value)
  end
  fakeStore.readBytes = function(...)
    payloadReads = payloadReads + 1
    return realReadBytes(...)
  end
  T.check(MeshCache.verifyJob(fakeMap, "body"),
          "committed metadata verifies a cache job")
  MeshCache.saveAux(fakeMap, "ring", { figures = {} }, true)
  fakeStore.writeBytes = realWriteBytes
  fakeStore.readBytes = realReadBytes
  T.eq(MeshCache.jobRecord(fakeMap, "ring").aux, bodyAux,
       "body and ring jobs reference one shared aux payload")
  T.eq(auxWrites, 0,
       "a second slot never rewrites an already-valid shared aux payload")
  T.eq(payloadReads, 0,
       "verification and shared-aux skips never reread large payload bytes")
  fakeStore.delete(nil, nil, "manifest")
  local ready = MeshCache.ready({ { id = "A", slot = "body" } })
  T.check(ready, "complete cache without a manifest reports READY")
  T.check(fakeStore.peekTables().manifest ~= nil,
          "legacy complete cache gets a manifest")
  fakeStore.delete(nil, nil, manifestRecord.water)
  T.check(not MeshCache.ready({ { id = "A", slot = "body" } }),
          "missing cache payload clears READY")
  T.check(MeshCache.wipe({ { id = "A", slot = "body" } }),
          "wipe cache removes precache payloads")
  T.check(fakeStore.peekBytes()["maps/A/body/terrain"] == nil
          and fakeStore.peekBytes()["maps/A/body/water"] == nil
          and fakeStore.peekBytes()["maps/A/shared/deco"] == nil,
          "wipe cache removes all payload variants")

  -- --- Switch: a wipe that does not land is reported, not swallowed -----
  -- The Switch-port logs showed deletes no-oping while reporting
  -- success: after WIPE CACHE the prebuild restarted from zero (manifest
  -- and metas gone) yet the old payloads kept serving cache hits. On
  -- Switch the wipe verifies by read-back and answers false (plus a
  -- storage-fail count) when keys survive; every other platform keeps
  -- the historical fire-and-forget behavior.
  local realDelete = fakeStore.delete
  fakeStore.delete = function() return true end   -- a delete that no-ops
  MeshCache.saveTerrain(fakeMap, "body", nil, 0)
  MeshCache.saveWater(fakeMap, "body", nil, 0)
  MeshCache.saveAux(fakeMap, "body", { figures = {} })
  withOS("OS X", function()
    T.check(MeshCache.wipe({ { id = "A", slot = "body" } }),
            "off-Switch: wipe behavior unchanged when delete no-ops")
    T.check(fakeStore.peekBytes()["maps/A/body/terrain"] ~= nil,
            "off-Switch: surviving payload is not the wipe's problem")
  end)
  MeshCache.saveTerrain(fakeMap, "body", nil, 0)
  MeshCache.saveWater(fakeMap, "body", nil, 0)
  MeshCache.saveAux(fakeMap, "body", { figures = {} })
  withOS("NX", function()
    T.check(not MeshCache.wipe({ { id = "A", slot = "body" } }),
            "Switch: wipe reports false when keys survive delete")
    T.check(fakeStore.peekBytes()["maps/A/body/terrain"] ~= nil,
            "Switch: surviving payload kept (delete really no-oped)")
  end)
  fakeStore.delete = realDelete
  withOS("NX", function()
    T.check(MeshCache.wipe({ { id = "A", slot = "body" } }),
            "Switch: wipe reports true when delete actually lands")
    T.check(fakeStore.peekBytes()["maps/A/body/terrain"] == nil,
            "Switch: clean wipe removes the payloads")
  end)

  local oldLove = love
  local testLove = oldLove or {}
  local oldData = testLove.data
  local packed = {}
  local serial = 0
  local codecCalls = {}
  testLove.data = {
    compress = function(_, format, body)
      codecCalls[#codecCalls + 1] = format
      if format ~= "lz4" then return nil end
      serial = serial + 1
      local key = "packed" .. serial
      packed[key] = body
      return key
    end,
    decompress = function(_, _, body) return packed[body] end,
  }
  _G.love = testLove
  MeshCache.configure({ maps = maps, tilesets = {} })
  local vertices = {}              -- 128 zero-vertices, plain table
  for i = 1, 128 * 6 do vertices[i] = 0 end
  MeshCache.saveTerrain(fakeMap, "body", vertices, 128)
  local compressed = fakeStore.peekBytes()["maps/A/body/terrain"]
  T.eq(compressed and compressed:byte(4) or nil, 2,
       "cache uses compressed format when available")
  MeshCache.saveWater(fakeMap, "body", nil, 0)
  MeshCache.saveAux(fakeMap, "body", { figures = {} })
  local loaded = MeshCache.loadTerrain(fakeMap, "body")
  T.check(loaded ~= nil and loaded.n == 128,
          "compressed cache payload loads through the normal decoder")
  local oldDecompress = testLove.data.decompress
  testLove.data.decompress = function()
    error("boot validation should not decompress every cached payload")
  end
  T.check(MeshCache.ready({ { id = "A", slot = "body" } }),
          "compressed cache reports READY from summaries")
  T.eq(MeshCache.compressionStatus(), "compressed",
       "cache status identifies compressed payloads")
  T.eq(MeshCache.codec(), "lz4",
       "cache status identifies the universal lz4 codec")
  for _, format in ipairs(codecCalls) do
    T.eq(format, "lz4", "cache writes never probe another codec")
  end
  T.check(MeshCache.ready({ { id = "A", slot = "body" } }),
          "manifest READY check uses bounded meta summaries")
  testLove.data.decompress = oldDecompress

  -- LZ4 may expand already-compressed data. Store it raw rather than trying
  -- a slower second codec.
  MeshCache.wipe({ { id = "A", slot = "body" } })
  testLove.data.compress = function(_, format, body)
    codecCalls[#codecCalls + 1] = format
    return body
  end
  MeshCache.saveTerrain(fakeMap, "body", vertices, 128)
  MeshCache.saveWater(fakeMap, "body", nil, 0)
  T.eq(fakeStore.peekBytes()["maps/A/body/terrain"]:byte(4), 1,
       "incompressible payloads stay raw instead of using zlib")
  T.eq(codecCalls[#codecCalls], "lz4",
       "raw fallback still makes one lz4 attempt")
  local packedTerrain, packedWater, packedStages =
    MeshCache.loadTerrainPacked(fakeMap, "body")
  T.check(packedTerrain and packedTerrain.packed
          and packedTerrain.format == "native"
          and packedTerrain.verts == nil
          and packedWater and packedWater.packed
          and packedWater.format == "native",
          "runtime cache loader returns GPU-ready bytes without float tables")
  T.check(packedStages and type(packedStages.readMs) == "number"
          and packedStages.readMs >= 0
          and type(packedStages.decompressMs) == "number"
          and packedStages.decompressMs >= 0
          and packedStages.decodeMs == 0,
          "packed cache loader reports read/decompress and skips float decode")
  local decodedTerrain, decodedWater, decodedStages =
    MeshCache.loadTerrain(fakeMap, "body")
  T.check(decodedTerrain and decodedWater
          and decodedStages and type(decodedStages.decodeMs) == "number"
          and decodedStages.decodeMs >= 0,
          "compatibility cache loader reports its float decode stage")

  local loadCodecCalls, loadWrites = 0, 0
  local realWriteBytes = fakeStore.writeBytes
  fakeStore.writeBytes = function(...)
    loadWrites = loadWrites + 1
    return realWriteBytes(...)
  end
  testLove.data.compress = function(_, format, body)
    loadCodecCalls = loadCodecCalls + 1
    serial = serial + 1
    local key = "late" .. serial
    packed[key] = body
    return key
  end
  local rawReload = MeshCache.loadTerrainPacked(fakeMap, "body")
  fakeStore.writeBytes = realWriteBytes
  T.check(rawReload ~= nil, "raw runtime payload still loads")
  T.eq(loadCodecCalls, 0,
       "runtime cache entry never retries compression")
  T.eq(loadWrites, 0,
       "runtime cache entry never rewrites payload storage")

  testLove.data = oldData
  _G.love = oldLove
  MeshCache.wipe({ { id = "A", slot = "body" } })

  -- --- relaunch simulation: same data + options => READY, no rebuild ------
  local function readManifestIdentity()
    local manifest = fakeStore.peekTables().manifest
    return manifest and manifest.identity or nil
  end
  local function readBuildInfoText()
    local info = fakeStore.peekTables().buildinfo
    return info and info.identity or nil
  end

  fakeStore.delete(nil, nil, "buildinfo")
  local buildJob = { id = "A", slot = "body" }
  MeshCache.configure({ maps = maps, tilesets = {} })
  MeshCache.begin()
  MeshCache.saveTerrain(fakeMap, "body", nil, 0)
  MeshCache.saveWater(fakeMap, "body", nil, 0)
  MeshCache.saveAux(fakeMap, "body", { figures = {} })
  local builtRecord = MeshCache.jobRecord(fakeMap, "body")
  T.check(MeshCache.writeManifest({ [builtRecord.key] = builtRecord }, 1),
          "active build writes a manifest")
  local builtIdentity = readManifestIdentity()
  T.eq(builtIdentity, MeshCache.identity(),
       "manifest identity equals the live identity after an unchanged build")
  local buildInfo = readBuildInfoText()
  T.eq(buildInfo, builtIdentity,
       "buildinfo records the build identity")

  -- A fresh configure() is the relaunch: same maps, same default options.
  MeshCache.configure({ maps = maps, tilesets = {} })
  T.eq(MeshCache.identity(), builtIdentity,
       "relaunch recomputes the same cache identity")
  T.check(MeshCache.ready({ buildJob }),
          "relaunch reports READY from the existing manifest (no rebuild)")
  T.check(MeshCache.getLastFailure() == nil,
          "a READY cache leaves lastFailure unset")

  -- --- begin()-time snapshot survives a mid-build identity drift ---------
  local okTR, TileRenderer = pcall(require, "src.render.TileRenderer")
  if okTR and TileRenderer then
    local oldVoidFill = TileRenderer.voidFill
    local driftedFill = oldVoidFill == "cactus" and "trees" or "cactus"
    fakeStore.delete(nil, nil, "buildinfo")
    MeshCache.configure({ maps = maps, tilesets = {} })
    MeshCache.begin()
    local snapshotIdentity = MeshCache.identity()
    local snapshot = MeshCache.buildInfoSnapshot()
    T.check(snapshot and snapshot.identity == snapshotIdentity,
            "buildInfoSnapshot exposes the begin()-time identity")
    -- Mid-build drift: a live identity component changes after begin().
    TileRenderer.voidFill = driftedFill
    MeshCache.saveTerrain(fakeMap, "body", nil, 0)
    MeshCache.saveWater(fakeMap, "body", nil, 0)
    MeshCache.saveAux(fakeMap, "body", { figures = {} })
    T.check(MeshCache.writeManifest({ [builtRecord.key] = builtRecord }, 1),
            "build finishes normally despite a mid-build identity drift")
    local driftedManifestId = readManifestIdentity()
    T.eq(driftedManifestId, snapshotIdentity,
         "manifest carries the begin()-time identity, not the drifted one")
    local driftedBuildInfo = readBuildInfoText()
    T.eq(driftedBuildInfo, snapshotIdentity,
         "buildinfo carries the begin()-time identity")
    -- Next launch: a fresh session drops the snapshot while the live
    -- identity still carries the drifted voidFill, so ready() must report
    -- the mismatch explicitly instead of a generic rejection.
    MeshCache.configure({ maps = maps, tilesets = {} })
    T.check(not MeshCache.ready({ buildJob }),
            "drifted live identity rejects the cache")
    local failure = MeshCache.getLastFailure()
    T.check(failure and failure.reason == "identity_mismatch",
            "rejection is reported as identity_mismatch")
    T.eq(failure.actual, snapshotIdentity,
         "identity_mismatch reports the manifest (actual) identity")
    T.check(failure.diffs and failure.diffs[1] == "voidFill",
            "identity_mismatch diff pinpoints the voidFill drift")
    TileRenderer.voidFill = oldVoidFill
    MeshCache.wipe({ buildJob })
  end

  -- --- F3 + F5: saves report results; begin() keeps the manifest ---------
  MeshCache.configure({ maps = maps, tilesets = {} })
  MeshCache.begin()
  T.eq(MeshCache.saveTerrain(fakeMap, "body", nil, 0), true,
       "saveTerrain reports its write result")
  T.eq(MeshCache.saveWater(fakeMap, "body", nil, 0), true,
       "saveWater reports its write result")
  T.eq(MeshCache.saveAux(fakeMap, "body", { figures = {} }), true,
       "saveAux reports its write result")
  T.eq(MeshCache.saveError(), nil,
       "successful saves leave no write error")
  local f3Record = MeshCache.jobRecord(fakeMap, "body")
  T.check(MeshCache.writeManifest({ [f3Record.key] = f3Record }, 1),
          "build writes a manifest")
  T.check(fakeStore.peekTables().manifest ~= nil,
          "manifest exists after the build")
  MeshCache.begin()
  T.check(fakeStore.peekTables().manifest ~= nil,
          "begin() keeps the manifest (F3): a mid-build death leaves it")
  T.check(MeshCache.writeManifest({ [f3Record.key] = f3Record }, 1),
          "manifest rewrite over an existing record succeeds (F4 self-heal)")
  MeshCache.wipe({ buildJob })

  -- --- BUG-3: an aux-less record must never send a nil key to storage --
  -- A job whose aux save failed has no aux meta key (aux is OPTIONAL in
  -- the record shape). updateCompression read it anyway and the engine
  -- answered invalid_key, spamming one storageWarn per job between
  -- "prebuild N/N done" and "manifest written". The nil key must be
  -- skipped before storage: record every key the fake store's read sees
  -- during writeManifest and assert none is nil.
  MeshCache.configure({ maps = maps, tilesets = {} })
  MeshCache.begin()
  MeshCache.saveTerrain(fakeMap, "body", nil, 0)
  MeshCache.saveWater(fakeMap, "body", nil, 0)
  local auxless = MeshCache.jobRecord(fakeMap, "body")
  auxless.aux = nil
  auxless.auxFp = nil
  local readCount, sawNilKey = 0, false
  local realRead = fakeStore.read
  fakeStore.read = function(_, _, key)
    readCount = readCount + 1
    if key == nil then sawNilKey = true end
    return realRead(_, _, key)
  end
  local wrote = MeshCache.writeManifest({ [auxless.key] = auxless }, 1)
  fakeStore.read = realRead
  T.check(wrote, "manifest writes with an aux-less record (BUG-3)")
  T.check(readCount > 0,
          "compression update still reads the real terrain/water metas")
  T.check(not sawNilKey,
          "no nil key reaches storage: absent aux is skipped, not read")
  MeshCache.wipe({ buildJob })

  -- --- F3: an interrupted build leaves a manifest naming finished jobs --
  local jobSet = Prebuild.enumerate(maps)   -- A body/ring, B body/ring
  local fakeMapB = {
    id = "B", tileset = { image = "tileset.png", trueColor = false },
    renderer = { gbcAtlas = false },
  }
  do
    MeshCache.configure({ maps = maps, tilesets = {} })
    MeshCache.begin()
    local records = {}
    for _, job in ipairs(jobSet) do
      local map = job.id == "A" and fakeMap or fakeMapB
      MeshCache.saveTerrain(map, job.slot, nil, 0)
      MeshCache.saveWater(map, job.slot, nil, 0)
      MeshCache.saveAux(map, job.slot, { figures = {} }, true)
      local record = MeshCache.jobRecord(map, job.slot)
      records[record.key] = record
    end
    T.check(MeshCache.writeManifest(records, #jobSet),
            "rebuild test starts from a READY cache")
    local rebuildGame = { data = { maps = maps, tilesets = {} } }
    T.check(Prebuild.bootstrap(rebuildGame),
            "rebuild test bootstraps the complete cache")
    T.check(Prebuild.rebuild(rebuildGame),
            "confirmed rebuild wipes and starts a fresh build")
    local rebuildDone, rebuildTotal, rebuildRunning = Prebuild.progress()
    T.check(rebuildRunning and rebuildDone == 0
            and rebuildTotal == #jobSet,
            "rebuild never resumes already-complete payloads")
    T.check(fakeStore.peekBytes()["maps/A/body/terrain"] == nil,
            "rebuild removes the prior terrain before starting")
    Prebuild.cancel()
    Prebuild.update(false)
    MeshCache.wipe(jobSet)
  end
  MeshCache.configure({ maps = maps, tilesets = {} })
  MeshCache.begin()
  MeshCache.saveTerrain(fakeMap, "body", nil, 0)
  MeshCache.saveWater(fakeMap, "body", nil, 0)
  MeshCache.saveAux(fakeMap, "body", { figures = {} })
  local partial = {}
  local bodyRecord = MeshCache.jobRecord(fakeMap, "body")
  partial[bodyRecord.key] = bodyRecord
  T.check(MeshCache.writeProgress(partial, #jobSet),
          "writeProgress writes a partial manifest")
  T.check(fakeStore.peekTables().manifest ~= nil,
          "interrupted build leaves a manifest behind")
  -- the relaunch: a fresh session rescans the actual payload summaries
  MeshCache.configure({ maps = maps, tilesets = {} })
  local complete, doneCount = MeshCache.scanComplete(jobSet)
  T.eq(doneCount, 1, "scanComplete finds exactly the one finished job")
  T.check(complete["A/body"] ~= nil and complete["A/ring"] == nil
          and complete["B/body"] == nil,
          "scanComplete names the finished job and skips the rest")
  local readyOk, resumeCount = MeshCache.ready(jobSet)
  T.check(not readyOk, "a partial build is not READY")
  T.eq(resumeCount, 1, "ready reports the resumable job count")
  MeshCache.wipe(jobSet)

  -- --- F1: boot under skeleton options, refresh after the save loads ----
  local okTR, TileRenderer = pcall(require, "src.render.TileRenderer")
  if okTR and TileRenderer then
    local originalFill = TileRenderer.voidFill
    local saveFill = originalFill ~= "cactus" and "cactus" or "water"
    MeshCache.configure({ maps = maps, tilesets = {} })
    TileRenderer.voidFill = saveFill
    MeshCache.begin()
    for _, job in ipairs(jobSet) do
      local m = job.id == "A" and fakeMap or fakeMapB
      MeshCache.saveTerrain(m, job.slot, nil, 0)
      MeshCache.saveWater(m, job.slot, nil, 0)
      MeshCache.saveAux(m, job.slot, { figures = {} })
    end
    local full = {}
    for _, job in ipairs(jobSet) do
      local m = job.id == "A" and fakeMap or fakeMapB
      local rec = MeshCache.jobRecord(m, job.slot)
      full[rec.key] = rec
    end
    T.check(MeshCache.writeManifest(full, #jobSet),
            "build completes under the save's VOID FILL")
    -- boot: game.ready runs under the skeleton save's DEFAULT options
    TileRenderer.voidFill = originalFill
    local stubGame = { data = { maps = maps, tilesets = {} } }
    T.check(not Prebuild.bootstrap(stubGame),
            "skeleton defaults do not match the save's cache")
    T.check(not Prebuild.isReady(),
            "cache not READY while the skeleton options are active")
    -- the save loads and the engine applies the slot's real options; the
    -- post-load gate refreshes under them (no invalidation needed)
    TileRenderer.voidFill = saveFill
    T.check(Prebuild.refresh(stubGame),
            "refresh after the save's options land reports READY")
    T.check(Prebuild.isReady(),
            "no rebuild prompt after the boot/load options transition")
    TileRenderer.voidFill = originalFill
    MeshCache.wipe(jobSet)
  end
end

-- --- boot-time Assets handoffs must not drop the manifest anywhere -------
-- The port logs showed "cache invalidate ALL" 18ms after boot, before
-- save.created: the engine's installLoader -> Assets.invalidate handoff
-- fired twice, and the second call dropped the manifest, forcing a cold
-- 444-job prebuild on every launch. The Steam Deck logs showed the same
-- double handoff on desktop. On every platform, handoff invalidations
-- are ignored until the first mesh entry exists.
local Assets = require("src.render.Assets")
local function freshManifestCache()
  MeshCache.configure({ maps = maps, tilesets = {} })
  MeshCache.begin()
  MeshCache.saveTerrain(fakeMap, "body", nil, 0)
  MeshCache.saveWater(fakeMap, "body", nil, 0)
  MeshCache.saveAux(fakeMap, "body", { figures = {} })
  local rec = MeshCache.jobRecord(fakeMap, "body")
  T.check(MeshCache.writeManifest({ [rec.key] = rec }, 1),
          "handoff test: manifest written")
end
local function manifestGone()
  return fakeStore.peekTables().manifest == nil
end

withOS("OS X", function()
  ChunkMesher._resetBootHandoffForTests()
  freshManifestCache()
  Assets.invalidate()   -- the boot handoff (or a later one: loadMod may
  Assets.invalidate()   -- have fired the engine's handoff already)
  T.check(not manifestGone(),
          "desktop: boot-time invalidations must keep the manifest")
  ChunkMesher.request(fakeMap, true, {}, false, true)
  Assets.invalidate()
  T.check(manifestGone(),
          "desktop: invalidation lands once mesh work has started")
end)

withOS("NX", function()
  ChunkMesher._resetBootHandoffForTests()
  freshManifestCache()
  Assets.invalidate()
  Assets.invalidate()   -- the observed double boot handoff
  T.check(not manifestGone(),
          "Switch: boot-time invalidations must keep the manifest")
  ChunkMesher.request(fakeMap, true, {}, false, true)
  Assets.invalidate()
  T.check(manifestGone(),
          "Switch: invalidation lands once mesh work has started")
end)

-- --- hands-off auto-start: an incomplete cache fills itself ------------
-- A fresh device must not depend on the player finding the PREBUILD row
-- or answering the boot prompt: once the overworld is up (in-game storage
-- + live options exist), the tick auto-starts the fill. The gate is
-- exactly the PREBUILD state, so running/cancelled/failed/ready all block
-- it, and the resume set from the boot scan is respected.
local stubGame = { data = { maps = maps, tilesets = {} } }
T.check(not Prebuild.bootstrap(stubGame),
        "auto-start setup: cache not ready at boot")
T.eq(Prebuild.status(), "PREBUILD", "auto-start setup: never started")
T.check(not Prebuild.autoStart(nil),
        "auto-start needs a game")
T.check(not Prebuild.autoStart({ data = { maps = maps } }),
        "auto-start waits for the overworld to exist")
T.check(not Prebuild.autoStart({ data = { maps = maps },
                                 overworld = {} }),
        "auto-start waits for a live map")
local owGame = { data = { maps = maps, tilesets = {} },
                 overworld = { map = { id = "A" }, camera = {} } }
T.check(Prebuild.autoStart(owGame),
        "incomplete cache auto-starts once the overworld is up")
local aDone, aTotal, aRunning = Prebuild.progress()
T.check(aRunning, "auto-started prebuild is running")
T.eq(aTotal, 4, "auto-started prebuild covers the full job set")
T.eq(aDone, 1, "auto-start resumes from the boot scan's survivors")
T.check(not Prebuild.autoStart(owGame),
        "no second auto-start while a build is running")
T.check(Prebuild.cancel(), "running auto-started build cancels")
Prebuild.update()   -- the always-on tick lands the cooperative cancel
T.check(not Prebuild.autoStart(owGame),
        "auto-start respects an explicit cancel")
T.check(Prebuild.wipe(owGame),
        "wipe re-arms the auto-start gate")
T.check(Prebuild.autoStart(owGame),
        "auto-start fires again after a wipe")
Prebuild.cancel()
Prebuild.update()   -- land the cancel before the decline block

-- --- the boot prompt's NO must override the auto-start ------------------
-- The field log caught the fill starting 8 seconds after the player
-- declined the MAP CACHE prompt: the auto-start never consulted the
-- answer. decline() records a session-wide block; wipe re-arms it; the
-- OPTIONS row still starts a build whenever the player wants one.
T.check(not Prebuild.autoStart(owGame),
        "setup: declined cache does not auto-start yet")
T.check(Prebuild.decline(), "declining the boot prompt records the block")
T.check(not Prebuild.autoStart(owGame),
        "a declined prompt blocks the auto-start")
local dDone, dTotal, dRunning = Prebuild.progress()
T.check(not dRunning, "no build is running after a decline")
T.eq(dTotal, 4, "the decline leaves the job set intact")
T.check(Prebuild.start(owGame),
        "the OPTIONS row still starts a build after a decline")
T.check(Prebuild.cancel(), "row-started build cancels")
Prebuild.update()
T.check(not Prebuild.autoStart(owGame),
        "still blocked after the row build is cancelled")
T.check(Prebuild.wipe(owGame),
        "wipe works after a decline")
T.check(not Prebuild.autoStart(owGame),
        "a decline stays sticky through a wipe (no silent fill)")

-- --- the gate's CONTINUE check is itself consent ------------------------
-- refresh() runs from the boot gate; once it has run, the prompt (or
-- its ready-skip) answered the fill question and the hands-off
-- auto-start must not act on that boot at all -- a wipe of a READY
-- cache mid-session must not silently start a rebuild either.
Prebuild.bootstrap(owGame)
T.check(Prebuild.autoStart(owGame),
        "setup: a boot without the gate still auto-starts")
Prebuild.cancel()
Prebuild.update()
Prebuild.bootstrap(owGame)
Prebuild.refresh(owGame)
T.check(not Prebuild.autoStart(owGame),
        "a boot the gate ran never auto-starts")
T.check(Prebuild.wipe(owGame), "wipe works after the gate ran")
T.check(not Prebuild.autoStart(owGame),
        "wiping a gated boot does not start a silent fill")
T.check(Prebuild.start(owGame),
        "the OPTIONS row still starts the rebuild after the wipe")
Prebuild.cancel()
Prebuild.update()

-- --- prebuilder map loads ride the pumped job coroutine -----------------
-- The engine's MapLoader.load used to run on the update tick OUTSIDE the
-- pump -- the unaccounted freeze behind the field logs' 20.3s frames.
-- requestMapId queues the job and defers the load into runJob, so the
-- load is measured and warned like every other slice overshoot.
ChunkMesher.release("A")
local loaderRan = false
ChunkMesher.requestMapId("A", true, {}, false, true, function()
  loaderRan = true
  return fakeMap
end)
T.check(ChunkMesher.jobPending("A", true),
        "requestMapId queues the job by map id")
T.check(not loaderRan,
        "the map loader does not run until the job is pumped")
ChunkMesher.release("A")
T.check(not ChunkMesher.jobPending("A", true),
        "release cancels a loader-backed job like any other")
T.eq(ChunkMesher.jobStatus("A", true), "cancelled",
     "a cancelled loader-backed job records its status")

-- --- threaded geometry pool: degradation + serialization + parity -------
-- The worker path (docs/threaded-geometry-design.md) runs the pure
-- geometry phase on love.thread; headless the pool must be inert and the
-- serial pump untouched, while the pieces the workers exchange -- the map
-- source dump and the buildGeometryData streams -- stay byte-compatible
-- with what the serial path saves.
T.check(not WorkerPool.enabled(),
        "headless: no love.thread, the pool stays disabled")
T.check(not WorkerPool.working(),
        "headless: no workers are ever started")

-- One Android worker measured 1.15 jobs/s and the packed CPU-only experiment
-- measured 1.3 jobs/s, versus 2.9 jobs/s for the established serial queue.
-- Mobile must stay on that proven serial path.
local originalLove = _G.love
_G.love = { thread = {} }
withOS("Android", function()
  T.check(not WorkerPool.enabled(),
          "Android keeps geometry workers disabled despite love.thread")
  T.eq(WorkerPool.workerCount(), 0,
       "Android schedules no geometry workers")
  T.check(not (WorkerPool.cpuOnlyPrebuild
               and WorkerPool.cpuOnlyPrebuild()),
          "Android avoids the regressed packed CPU-only precache path")
end)
_G.love = originalLove

local serSrc = WorkerPool.serializeMap(fakeMap)
local serChunk = assert(load(serSrc, "@ser", "t"))
local serMap = serChunk()
T.check(serMap.id == fakeMap.id
        and serMap.tileset.image == fakeMap.tileset.image,
        "serializeMap round-trips the map data")
T.check(type(serMap.tileAt) == "nil",
        "methods are not serialized (the worker reattaches them)")

-- The engine Map carries a live TileRenderer that back-references the
-- map (map.renderer.map == map) and holds Game.data. The dump must drop
-- the renderer instead of recursing into the cycle -- the 1.7.9
-- regression: prebuild-tick threw "map serialization too deep (cycle?)"
-- on every map once the compute permission ran the threaded workers.
local cyclicMap = { id = "CYC", tileset = { image = "tileset.png" } }
cyclicMap.renderer = {
  map = cyclicMap,
  data = { maps = { CYC = cyclicMap } },
}
local cycSrc = WorkerPool.serializeMap(cyclicMap)
local cycMap = assert(load(cycSrc, "@ser", "t"))()
T.check(cycMap.id == "CYC"
        and cycMap.tileset.image == "tileset.png"
        and cycMap.renderer == nil,
        "serializeMap drops the cyclic renderer instead of recursing")
T.check(not cycSrc:find("renderer", 1, true),
        "the renderer never reaches the dumped source")

-- Backstop: any OTHER cyclic field (not named renderer) must degrade to
-- nil at the repeat, not blow the depth guard.
local deepMap = { id = "DEEP", tileset = { image = "tileset.png" } }
deepMap.def = deepMap
local deepSrc = WorkerPool.serializeMap(deepMap)
local deepMapOut = assert(load(deepSrc, "@ser", "t"))()
T.check(deepMapOut.id == "DEEP" and deepMapOut.def == nil,
        "a non-renderer cycle is cut at the repeat, not an error")

-- parity: the streams buildGeometryData returns feed saveTerrain/saveWater/
-- saveAux exactly like the serial sink buffers, and loadTerrain reads the
-- same counts back. The worker path runs with the pure engine shims from
-- workers/geometry_worker.lua (the real TileRenderer needs a full tileset
-- atlas the fixture cannot provide, and MapLoader constructs one per map)
-- -- seed the same shims here so the headless geometry matches what the
-- worker computes, and drive a smoke-map shaped fixture (as the harness
-- does) instead of MapLoader.
local TREE_WALL_BLOCK = 0x0F
local function mapShims()
  local Map = {
    isOutdoor = function(def)
      if def.outdoor ~= nil then return def.outdoor end
      return def.tileset == "OVERWORLD"
    end,
    blockAt = function(self, bx, by)
      if bx < 0 or by < 0 or bx >= self.def.width or by >= self.def.height then
        return self.def.borderBlock
      end
      return self.def.blocks[by * self.def.width + bx + 1]
    end,
    tileAt = function(self, tx, ty)
      local bx, by = math.floor(tx / 4), math.floor(ty / 4)
      local block = self.tileset.blocks[self:blockAt(bx, by) + 1]
      local ix = (ty % 4) * 4 + (tx % 4) + 1
      return block[ix]
    end,
    cellTile = function(self, cx, cy)
      return self:tileAt(cx * 2, cy * 2 + 1)
    end,
    inBounds = function(self, cx, cy)
      return cx >= 0 and cy >= 0 and cx < self.def.width * 2
             and cy < self.def.height * 2
    end,
    isWalkableCell = function(self, cx, cy)
      return self.walkable and self.walkable[self:cellTile(cx, cy)] or false
    end,
    isGrassCell = function(self, cx, cy)
      if not self:inBounds(cx, cy) then return false end
      local grass = self.tileset.grassTile
      return grass ~= nil and self:cellTile(cx, cy) == grass
    end,
    isWaterCell = function(self, cx, cy)
      return self.waterTiles and self.waterTiles[self:cellTile(cx, cy)] or false
    end,
  }
  return Map
end
local TestMap = mapShims()
package.loaded["src.render.TileRenderer"] = {
  voidFill = "trees",
  borderBlockFor = function(map)
    if map.def.tileset == "OVERWORLD" then
      return TREE_WALL_BLOCK
    end
    return map.def.borderBlock
  end,
  defaultAnimatedTiles = function() return nil end,
}
package.loaded["src.render.Assets"] = {
  register = function() end,
  imageData = function() return nil end,
}
package.loaded["src.world.Map"] = TestMap
do
  local testBlocks = {}
  for i = 1, 16 do testBlocks[i] = 1 end
  local realMap = {
    id = "PARITY_CITY",
    def = { width = 4, height = 4, blocks = testBlocks,
            borderBlock = 1, tileset = "PARITY" },
    tileset = {
      id = "PARITY", image = "parity.png", tilesPerRow = 16,
      imageWidth = 128, imageHeight = 48,
      blocks = { { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
                 { 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2 } },
    },
    walkable = { [1] = true, [2] = true },
    waterTiles = {},
    doorTiles = {},
  }
  for _, name in ipairs({ "tileAt", "blockAt", "cellTile", "inBounds",
                          "isWalkableCell", "isGrassCell", "isWaterCell" }) do
    realMap[name] = TestMap[name]
  end
  local gdata = ChunkMesher.buildGeometryData(realMap, true, {})
  T.check(gdata and gdata.terrain and gdata.terrain.n and gdata.terrain.n > 0,
          "buildGeometryData returns terrain streams")
  T.check(gdata.water ~= nil and gdata.aux ~= nil,
          "buildGeometryData returns water + aux records")
  local chunkData = ChunkMesher.buildGeometryChunkData(realMap, true, {})
  T.check(chunkData and chunkData.terrain
          and type(chunkData.terrain.chunks) == "table"
          and #chunkData.terrain.chunks > 0,
          "worker geometry returns bounded terrain chunks")
  T.check(chunkData.terrain.buf == nil and chunkData.terrain.idx == nil,
          "worker geometry does not return whole-map terrain tables")
  T.eq(chunkData.terrain.n, gdata.terrain.n,
       "packed worker chunks preserve terrain vertex count")
  local pair = ChunkMesher.buildGeometryPairData(realMap, {})
  T.check(pair and pair.body and pair.ring and pair.aux,
          "pair geometry builds body + ring streams with one aux result")
  T.check(pair.body.terrain.n > 0 and pair.ring.terrain.n > 0,
          "pair geometry returns both terrain streams")
  local fullData = ChunkMesher.buildGeometryData(realMap, false, {})
  T.eq(pair.body.terrain.n, gdata.terrain.n,
       "paired body stream matches the standalone body build")
  T.eq(pair.body.terrain.n + pair.ring.terrain.n, fullData.terrain.n,
       "body plus ring vertices exactly replace duplicate full geometry")
  T.eq(pair.body.terrain.m + pair.ring.terrain.m, fullData.terrain.m,
       "body plus ring indices exactly replace duplicate full geometry")
  local seamMasks = { { 128, 0, 256, 128 } }
  local maskedPair = ChunkMesher.buildGeometryPairData(realMap, seamMasks)
  local maskedFull = ChunkMesher.buildGeometryData(realMap, false, seamMasks)
  T.eq(maskedPair.body.terrain.n + maskedPair.ring.terrain.n,
       maskedFull.terrain.n,
       "body plus ring remains exact where a neighbour masks the seam")
  T.eq(maskedPair.body.terrain.m + maskedPair.ring.terrain.m,
       maskedFull.terrain.m,
       "body plus ring index parity survives a masked map seam")
  local structureState = Structures.forMap(realMap)
  T.check(type(structureState.shapeAt) == "table"
          and type(structureState.tileAt) == "table",
          "structures exposes resolved shape and tile grids")
  T.check(type(structureState.objectQuads) == "table"
          and type(structureState.runs) == "table"
          and type(structureState.skip) == "table",
          "structures exposes object, volume, and claim outputs")
  T.check(type(structureState.grassQuads) == "table"
          and type(structureState.flowerQuads) == "table"
          and type(structureState.figures) == "table",
          "structures keeps vegetation and figure streams separate")
  T.eq(Structures.forMap(realMap), structureState,
       "structures reuses the same per-map analysis result")
  T.check(Structures.release(realMap.id),
          "structures releases completed worker map analysis")
  WorkerPool.serializeMap(realMap)
  T.check(WorkerPool.forgetMap(realMap.id),
          "worker pool releases completed serialized map source")
  T.check(type(Buildings.stats()) == "table",
          "buildings retains an inspectable template-model boundary")
  MeshCache.configure({ maps = maps, tilesets = {} })
  local okT = MeshCache.saveTerrain(realMap, "body", gdata.terrain.buf,
                                    gdata.terrain.n, gdata.terrain.idx,
                                    gdata.terrain.m)
  T.check(okT, "saveTerrain accepts worker streams")
  local okA = MeshCache.saveAux(realMap, "body", gdata.aux)
  T.check(okA, "saveAux accepts worker streams")
  local tdata = MeshCache.loadTerrain(realMap, "body")
  T.check(tdata ~= nil and tdata.n == gdata.terrain.n,
          "worker terrain reads back at the same vertex count")
  local okTC = MeshCache.saveTerrainChunks(realMap, "ring", chunkData.terrain)
  local okWC = MeshCache.saveWaterChunks(realMap, "ring", chunkData.water)
  T.check(okTC and okWC,
          "packed worker chunks save without float-table expansion")
  local packedRead = MeshCache.loadTerrain(realMap, "ring")
  T.check(packedRead ~= nil and packedRead.n == chunkData.terrain.n,
          "packed worker terrain reads back at the same vertex count")
end

-- --- 1.7.11/1.7.12: worker save-call regression + payload fallback ------
-- 1.7.10 field sessions failed at MeshCache.lua:533 because finishThreaded
-- passed an extra receiver to dot-defined saveTerrain, shifting the worker
-- streams until terrain.n was a TABLE. The healthy path below locks the call
-- shape; the malformed case keeps the serial fallback safe at the boundary.
MeshCache.configure({ maps = maps, tilesets = {} })
Prebuild.wipe(owGame)
T.check(Prebuild.start(owGame), "malformed payload: build running")
local mJobs = Prebuild.enumerate(maps)
-- the serial rebuild needs a geometry-buildable map (the bare fakeMap
-- crashes TileShape), so the loader stub serves the parity-block shape
local structBlocks = {}
for i = 1, 16 do structBlocks[i] = 1 end
local structMap = {
  id = "A",
  def = { width = 4, height = 4, blocks = structBlocks,
          borderBlock = 1, tileset = "OVERWORLD" },
  tileset = {
    id = "TS", image = "tileset.png", tilesPerRow = 16,
    imageWidth = 128, imageHeight = 48,
    blocks = { { 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1 },
               { 2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2 } },
  },
  walkable = { [1] = true, [2] = true },
  waterTiles = {},
  doorTiles = {},
}
local shimMap = {}
function shimMap.isOutdoor(def)
  return def.tileset == "OVERWORLD"
end
function shimMap.blockAt(self, bx, by)
  if bx < 0 or by < 0 or bx >= self.def.width or by >= self.def.height then
    return self.def.borderBlock
  end
  return self.def.blocks[by * self.def.width + bx + 1]
end
function shimMap.tileAt(self, tx, ty)
  local bx, by = math.floor(tx / 4), math.floor(ty / 4)
  local block = self.tileset.blocks[self:blockAt(bx, by) + 1]
  local ix = (ty % 4) * 4 + (tx % 4) + 1
  return block[ix]
end
function shimMap.cellTile(self, cx, cy)
  return self:tileAt(cx * 2, cy * 2 + 1)
end
function shimMap.inBounds(self, cx, cy)
  return cx >= 0 and cy >= 0 and cx < self.def.width * 2
         and cy < self.def.height * 2
end
function shimMap.isWalkableCell(self, cx, cy)
  return self.walkable and self.walkable[self:cellTile(cx, cy)] or false
end
function shimMap.isGrassCell(self, cx, cy)
  return false
end
function shimMap.isWaterCell(self, cx, cy)
  return self.waterTiles and self.waterTiles[self:cellTile(cx, cy)] or false
end
for _, name in ipairs({ "isOutdoor", "blockAt", "tileAt", "cellTile",
                        "inBounds", "isWalkableCell", "isGrassCell",
                        "isWaterCell" }) do
  structMap[name] = shimMap[name]
end
local loadedIds = {}
local realLoader = package.loaded["src.world.MapLoader"]
package.loaded["src.world.MapLoader"] = {
  load = function(_, id) loadedIds[#loadedIds + 1] = id; return structMap end,
  cached = function() return structMap end,
  evict = function() end,
}
local malformed = { gen = 4242, data = {
  terrain = { buf = { 1, 2, 3 }, n = {}, idx = {}, m = 1 },
  water = { buf = {}, n = 0, idx = {}, m = 0 },
  aux = { figures = {} } } }
Prebuild._applyWorkerResult(malformed, { job = mJobs[1], map = fakeMap })
T.eq(Prebuild._workerFailures(), 0,
     "a malformed payload is not a job failure")
local mmDone, mmTotal, mmRunning = Prebuild.progress()
T.eq(mmDone, 0, "a malformed payload does not advance the build")
T.check(mmRunning, "the build keeps running after a malformed payload")
Prebuild.update(false)
T.eq(loadedIds[#loadedIds], mJobs[1].id,
     "the malformed job rebuilds through the serial pump")
Prebuild.cancel()
Prebuild.update(false)
package.loaded["src.world.MapLoader"] = realLoader

-- the healthy path still completes a job through the same seam
Prebuild.wipe(owGame)
T.check(Prebuild.start(owGame), "healthy payload: build running")
local healthy = { gen = 4243, data = {
  terrain = { buf = { 0, 0, 0, 1, 1, 1 }, n = 1, idx = {}, m = 0 },
  water = { buf = {}, n = 0, idx = {}, m = 0 },
  aux = { figures = {} } } }
Prebuild._applyWorkerResult(healthy, { job = Prebuild.enumerate(maps)[1],
                                       map = fakeMap })
local hDone = select(1, Prebuild.progress())
T.eq(hDone, 1, "a healthy worker payload still completes a job")
T.eq(Prebuild._workerFailures(), 0, "the healthy job is not a failure")
Prebuild.cancel()
Prebuild.update(false)

-- A worker that cannot open the atlas must return to the serial asset
-- resolver, not mark the map as a permanently failed cache job.
Prebuild.wipe(owGame)
T.check(Prebuild.start(owGame), "missing atlas: build running")
Prebuild._applyWorkerResult({ gen = 4244,
                              error = "tileset pixel data unavailable" },
                             { job = Prebuild.enumerate(maps)[1],
                               map = fakeMap })
local pixelDone, _, pixelRunning = Prebuild.progress()
T.eq(pixelDone, 0, "missing atlas does not advance the cache job")
T.check(pixelRunning, "missing atlas keeps the build alive for serial fallback")
T.eq(Prebuild._workerFailures(), 0, "missing atlas is not a cache failure")
Prebuild.cancel()
Prebuild.update(false)

-- --- BUG-2a: the pump pre-empts an oversized job mid-phase --------------
-- A synthetic job whose phase runs far past its slice must suspend and
-- resume on the next pump (the "yield, don't run to completion" contract
-- the freeze logs were missing: 81-428 overshoots a session). The
-- build-budget deadline itself is unobservable headless (the love stub's
-- timer is frozen at 0), so the loader spins a fixed oversized phase and
-- yields exactly where the real budget would suspend it.
MeshCache.configure({ maps = maps, tilesets = {} })
ChunkMesher.release("OVERSHOOT")
local overshootSteps = 0
local overshootSpun = false
ChunkMesher.requestMapId("OVERSHOOT", true, {}, false, true, function()
  if not overshootSpun then
    overshootSpun = true
    local target = os.clock() + 0.005   -- a phase longer than the slice
    while os.clock() < target do overshootSteps = overshootSteps + 1 end
    coroutine.yield("budget")           -- the budget suspends the job here
  end
  return fakeMap
end)
T.check(ChunkMesher.jobPending("OVERSHOOT", true), "oversized job queued")
ChunkMesher.pump(false)
T.check(overshootSteps > 0, "oversized phase ran before the yield")
T.check(ChunkMesher.jobPending("OVERSHOOT", true),
        "oversized job suspended mid-phase instead of running to completion")
local stepsAfterYield = overshootSteps
ChunkMesher.pump(false)
T.check(overshootSteps == stepsAfterYield,
        "the resumed job continues instead of re-running the phase")
T.check(ChunkMesher.jobStatus("OVERSHOOT", true) ~= "pending",
        "the suspended job ran to its end on the next pump")
ChunkMesher.release("OVERSHOOT")

-- --- BUG-2a: the prebuild pumps a tighter slice and restores it --------
local origIdle, origCovered = ChunkMesher.IDLE_SLICE, ChunkMesher.COVERED_SLICE
local pumpSlices = {}
local origPump = ChunkMesher.pump
ChunkMesher.pump = function(covered)
  pumpSlices[#pumpSlices + 1] = {
    idle = ChunkMesher.IDLE_SLICE, covered = ChunkMesher.COVERED_SLICE,
    coveredFlag = covered,
  }
end
Prebuild.bootstrap(owGame)
T.check(Prebuild.autoStart(owGame), "slice test: prebuild running")
Prebuild.update(false)
T.check(#pumpSlices >= 1, "slice test: the prebuild pumped once")
local tight = pumpSlices[#pumpSlices]
T.check(tight.idle < origIdle,
        "slice test: idle slice tightened during the build")
T.check(tight.covered < origCovered,
        "slice test: covered slice tightened during the build")
T.check(Prebuild.cancel(), "slice test: build cancels")
Prebuild.update(false)
T.eq(ChunkMesher.IDLE_SLICE, origIdle, "slice test: idle slice restored")
T.eq(ChunkMesher.COVERED_SLICE, origCovered,
     "slice test: covered slice restored")

-- --- BUG-2a: an overshooting pump yields the next tick ------------------
-- The containment half of the budget: a resume that blows the slice
-- pauses the FOLLOWING tick so the freeze does not compound (the job
-- resumes on the next pump, exactly once). The prebuild's own clock
-- reads love.timer per call, so a shim with a REAL timer makes the
-- overshoot measurable headless (the suite's stub timer is frozen).
ChunkMesher.pump = origPump
ChunkMesher.release("A")   -- drop the part-1 job so the shimmed loader
                           -- is captured by the fresh queue below
local realMapLoader = package.loaded["src.world.MapLoader"]
package.loaded["src.world.MapLoader"] = {
  load = function()
    local target = os.clock() + 0.030
    while os.clock() < target do end
    return fakeMap
  end,
  evict = function() end,
  cached = function() return nil end,
}
local oldLove = love
local realLove = {}
for key, value in pairs(oldLove or {}) do realLove[key] = value end
realLove.timer = { getTime = function() return os.clock() end }
_G.love = realLove
T.check(Prebuild.start(owGame), "overshoot test: build restarted")
Prebuild.update(false)   -- the ~30ms load resume vs the 3ms slice
local pumpCalls = 0
ChunkMesher.pump = function() pumpCalls = pumpCalls + 1 end
Prebuild.update(false)
T.eq(pumpCalls, 0, "overshoot test: the tick after an overshoot does not pump")
Prebuild.update(false)
T.eq(pumpCalls, 1, "overshoot test: pumping resumes on the following tick")
_G.love = oldLove
package.loaded["src.world.MapLoader"] = realMapLoader
ChunkMesher.pump = origPump
T.check(Prebuild.cancel(), "overshoot test: cancels")
Prebuild.update(false)
ChunkMesher.release("A")
MeshCache.configure({ maps = maps, tilesets = {} })

-- --- BUG-2b: the resume scan defers across ticks (large sets) ----------
-- A build whose survivor scan would take seconds on cold flash must not
-- scan synchronously in start(): the scan advances in update() ticks,
-- the on-disk survivors are skipped, and only the missing jobs are
-- dispatched (the resume semantics are unchanged).
local bigMaps = {}
for i = 1, 40 do
  local id = string.format("M%02d", i)
  bigMaps[id] = { id = id, width = 2, height = 2, borderBlock = 0,
                  blocks = { 1, 2, 3, 4 }, connections = {} }
end
local bigGame = { data = { maps = bigMaps, tilesets = {} } }
local bigJobs = Prebuild.enumerate(bigMaps)
T.check(#bigJobs > 16, "scan test: big set exceeds the inline threshold")
T.check(type(Prebuild.pendingJobs) == "function",
        "resume planner exposes pending-job filtering")
local scatteredPending = Prebuild.pendingJobs(bigJobs, {
  ["M01/body"] = {},
  ["M40/ring"] = {},
})
T.eq(#scatteredPending, #bigJobs - 2,
     "resume planner removes every survivor, not only the leading run")
T.eq(scatteredPending[1].id, "M01",
     "resume planner keeps first missing map")
T.eq(scatteredPending[1].slot, "ring",
     "resume planner skips leading body survivor")
T.eq(scatteredPending[#scatteredPending].id, "M40",
     "resume planner keeps final map when only its ring slot survived")
T.eq(scatteredPending[#scatteredPending].slot, "body",
     "resume planner skips noncontiguous final survivor")
MeshCache.configure({ maps = bigMaps, tilesets = {} })
local survivor = { id = "M01", tileset = { image = "tileset.png",
                                           trueColor = false },
                   renderer = { gbcAtlas = false } }
MeshCache.saveTerrain(survivor, "body", nil, 0)
MeshCache.saveWater(survivor, "body", nil, 0)
MeshCache.saveAux(survivor, "body", { figures = {} })
T.check(not Prebuild.bootstrap(bigGame), "scan test: big cache not ready")
T.check(Prebuild.start(bigGame), "scan test: big build starts")
local bDone, bTotal, bRunning = Prebuild.progress()
T.check(bRunning, "scan test: build running")
T.eq(bTotal, #bigJobs, "scan test: full job set")
T.eq(bDone, 0, "scan test: no synchronous scan on start (deferred)")
T.check(not ChunkMesher.jobPending("M01", true),
        "scan test: no dispatch before the resume scan completes")
ChunkMesher.pump = function() end   -- dispatch only: jobs never run
for _ = 1, 10 do Prebuild.update(false) end
T.check(ChunkMesher.jobPending("M01", "ring"),
        "scan test: dispatch begins at the first missing job")
T.check(not ChunkMesher.jobPending("M01", true),
        "scan test: the surviving M01/body job is skipped")
T.eq(select(1, Prebuild.progress()), 1,
     "scan test: the survivor counts as done")
ChunkMesher.pump = origPump
T.check(Prebuild.cancel(), "scan test: cancels")
Prebuild.update(false)
ChunkMesher.release("M01")
MeshCache.wipe(bigJobs)
MeshCache.configure({ maps = maps, tilesets = {} })

-- --- BUG-1: the pre-warm hook primes the first map's body mesh ---------
-- Empty cache: a no-op, never a fresh build, never a crash.
MeshCache.wipe(jobs)
ChunkMesher.release("A")
T.check(not Prebuild.primeFirst(fakeMap),
        "pre-warm: an empty cache no-ops")
T.check(ChunkMesher.peek(fakeMap, true) == nil,
        "pre-warm: no mesh comes out of an empty cache")
-- A running prebuild owns the cache: the prime must not touch it.
Prebuild.bootstrap(owGame)
T.check(Prebuild.autoStart(owGame), "pre-warm: build running for the gate")
T.check(not Prebuild.primeFirst(fakeMap),
        "pre-warm: no-op while the prebuild runs")
T.check(Prebuild.cancel(), "pre-warm: cancels")
Prebuild.update(false)
-- Payloads on disk: the prime hands the body slot to the runtime cache
-- (the first scene renders a small mesh already in memory), once per
-- session.
Prebuild.bootstrap(owGame)
MeshCache.configure({ maps = maps, tilesets = {} })
MeshCache.begin()
MeshCache.saveTerrain(fakeMap, "body", nil, 0)
MeshCache.saveWater(fakeMap, "body", nil, 0)
MeshCache.saveAux(fakeMap, "body", { figures = {} })
T.check(Prebuild.primeFirst(fakeMap),
        "pre-warm: primed with payloads on disk")
T.check(ChunkMesher.seen("A"),
        "pre-warm: the runtime cache entry exists after priming")
T.check(not Prebuild.primeFirst(fakeMap),
        "pre-warm: the prime is one-shot per session")
MeshCache.wipe({ { id = "A", slot = "body" } })
ChunkMesher.release("A")
MeshCache.configure({ maps = maps, tilesets = {} })

run.release()
T.finish("potato_voxel_cache")
