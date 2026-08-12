package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Data = require("src.core.Data")
Data:load()

local run = T.sdk.loadMod("mods/potato_voxel", { data = Data })
T.eq(#run.errors, 0, "loads clean")

local exports = run.loader.exports.potato_voxel
local Prebuild = exports.lib.require("CachePrebuild")
local MeshCache = exports.lib.require("MeshCache")
local Brick = exports.brick
local Battles = exports.lib.require("OverworldBattle")
local QualityMode = exports.lib.require("QualityMode")

if Brick and Brick.isBrick() then
  T.eq(Brick.battleRenderScale(), 1.0,
       "battle scene follows the RENDER SCALE knob (default 100%)")
  QualityMode.renderSetting:setValue(50)
  T.eq(Brick.battleRenderScale(), 0.5,
       "battle scene follows a changed RENDER SCALE")
  QualityMode.renderSetting:setValue(100)
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
T.eq(#jobs, 4, "prebuild enumerates body and full variants")
T.eq(jobs[1].id, "A", "prebuild sorts map ids")
T.eq(jobs[1].slot, "body", "body runs before full")
T.eq(jobs[2].slot, "full", "full follows body")
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

local posixMkdir = MeshCache.mkdirCommands(
  "/home/user/.local/share/love/game/mod-derived/potato_voxel/meshes", "/")
T.eq(type(posixMkdir), "table", "mkdir commands come back as a list")
T.eq(#posixMkdir, 1, "POSIX tree creation is a single command")
T.eq(posixMkdir[1],
     'mkdir -p "/home/user/.local/share/love/game/mod-derived/potato_voxel/meshes" 2>/dev/null',
     "POSIX uses mkdir -p with silenced stderr")
local winMkdir = MeshCache.mkdirCommands(
  "C:\\LOVE\\game\\mod-derived\\potato_voxel\\meshes", "\\")
T.eq(#winMkdir, 5, "Windows creates each component below the drive root")
T.eq(winMkdir[1], 'if not exist "C:\\LOVE" mkdir "C:\\LOVE"',
     "Windows guards the drive-level folder")
T.eq(winMkdir[2], 'if not exist "C:\\LOVE\\game" mkdir "C:\\LOVE\\game"',
     "Windows guards each intermediate folder")
T.eq(winMkdir[5],
     'if not exist "C:\\LOVE\\game\\mod-derived\\potato_voxel\\meshes" mkdir "C:\\LOVE\\game\\mod-derived\\potato_voxel\\meshes"',
     "Windows deepest component is the cache dir itself")

local record = MeshCache.jobRecord({
  id = "A", tileset = { image = "tileset.png", trueColor = false },
  renderer = { gbcAtlas = false },
}, "body")
T.check(record.terrain ~= record.water and record.water ~= record.aux,
        "job record names terrain, water, and aux files separately")
T.check(record.terrainFp ~= record.waterFp
          and record.waterFp ~= record.auxFp,
        "job record fingerprints each payload separately")

local ffiOk, ffi = pcall(require, "ffi")
local cacheDir = MeshCache.dir()
if ffiOk and cacheDir then
  local fakeMap = {
    id = "A", tileset = { image = "tileset.png", trueColor = false },
    renderer = { gbcAtlas = false },
  }
  MeshCache.configure({ maps = maps, tilesets = {} })
  MeshCache.saveTerrain(fakeMap, "body", nil, 0)
  MeshCache.saveWater(fakeMap, "body", nil, 0)
  MeshCache.saveAux(fakeMap, "body", { figures = {} })
  local manifestRecord = MeshCache.jobRecord(fakeMap, "body")
  local originalAvailable = MeshCache.available
  MeshCache.available = function() return true end
  os.remove(cacheDir .. "/cache.info")
  local ready = MeshCache.ready({ { id = "A", slot = "body" } })
  T.check(ready, "complete cache without a manifest reports READY")
  local manifest = io.open(cacheDir .. "/cache.info", "rb")
  T.check(manifest ~= nil, "legacy complete cache gets a manifest")
  if manifest then manifest:close() end
  os.remove(cacheDir .. "/" .. manifestRecord.water)
  T.check(not MeshCache.ready({ { id = "A", slot = "body" } }),
          "missing cache payload clears READY")
  T.check(MeshCache.wipe({ { id = "A", slot = "body" } }),
          "wipe cache removes precache files")
  local function exists(path)
    local file = io.open(path, "rb")
    if file then file:close(); return true end
    return false
  end
  T.check(not exists(cacheDir .. "/" .. manifestRecord.terrain)
          and not exists(cacheDir .. "/" .. manifestRecord.water)
          and not exists(cacheDir .. "/" .. manifestRecord.aux),
          "wipe cache removes all payload variants")

  local oldLove = love
  local testLove = oldLove or {}
  local oldData = testLove.data
  local packed = {}
  local serial = 0
  testLove.data = {
    compress = function(_, _, body)
      serial = serial + 1
      local key = "packed" .. serial
      packed[key] = body
      return key
    end,
    decompress = function(_, _, body) return packed[body] end,
  }
  _G.love = testLove
  MeshCache.configure({ maps = maps, tilesets = {} })
  local vertices = ffi.new("float[?]", 64 * 6)
  MeshCache.saveTerrain(fakeMap, "body", vertices, 64)
  local compressed = io.open(cacheDir .. "/A.body.terrain", "rb")
  local compressedFormat = compressed and compressed:read(4):byte(4) or nil
  if compressed then compressed:close() end
  T.eq(compressedFormat, 2, "cache uses compressed format when available")
  MeshCache.saveWater(fakeMap, "body", nil, 0)
  MeshCache.saveAux(fakeMap, "body", { figures = {} })
  local loaded = MeshCache.loadTerrain(fakeMap, "body")
  T.check(loaded ~= nil and loaded.n == 64,
          "compressed cache payload loads through the normal decoder")
  local oldDecompress = testLove.data.decompress
  testLove.data.decompress = function()
    error("boot validation should not decompress every cached payload")
  end
  T.check(MeshCache.ready({ { id = "A", slot = "body" } }),
          "compressed cache reports READY from headers")
  T.eq(MeshCache.compressionStatus(), "compressed",
       "cache status identifies compressed payloads")
  T.check(MeshCache.ready({ { id = "A", slot = "body" } }),
          "manifest READY check uses bounded payload headers")
  testLove.data.decompress = oldDecompress
  testLove.data = oldData
  _G.love = oldLove
  MeshCache.wipe({ { id = "A", slot = "body" } })
  MeshCache.available = originalAvailable
end

run.release()
T.finish("potato_voxel_cache")
