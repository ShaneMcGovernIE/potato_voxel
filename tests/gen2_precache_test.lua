package.path = "./?.lua;./?/init.lua;" .. package.path

local function check(cond, msg)
  if not cond then error(msg or "assertion failed", 2) end
end

local function eq(a, b, msg)
  if a ~= b then
    error(string.format("%s (expected %s, got %s)",
                        msg or "mismatch", tostring(b), tostring(a)), 2)
  end
end

-- Mock Gen 2 engine environment
local gen2Active = true
local activeVersion = "gold"
package.loaded["src.core.GameVersion"] = {
  generation = function() return gen2Active and 2 or 1 end,
  get = function() return gen2Active and activeVersion or "red" end,
}

package.loaded["src.render.Assets"] = {
  register = function() end,
  imageData = function() return nil end,
}
package.loaded["src.render.PaletteFX"] = {}
package.loaded["src.render.Font"] = {
  drawBox = function() end,
  draw = function() end,
}
package.loaded["src.render.TileRenderer"] = {
  borderBlockFor = function(map) return map and map.def and map.def.borderBlock or 0 end,
  defaultAnimatedTiles = function() return nil end,
  voidFill = "trees",
}
package.loaded["src.world.OverworldController"] = {
  computeNeighbors = function(maps, id, hops)
    return {}
  end,
}
package.loaded["src.world.gen2.World"] = {
  computeNeighbors = function(maps, id, hops)
    if id == "NEW_BARK" then
      return {
        { id = "ROUTE_29", ox = -32 * 30, oy = 0 },
      }
    end
    return {}
  end,
}

local fakeGen2Maps = {
  NEW_BARK = {
    id = "NEW_BARK",
    width = 10,
    height = 9,
    environment = "TOWN",
    tileset = "TILESET_JOHTO",
    borderBlock = 5,
    blocks = {},
    connections = {
      west = { map = "ROUTE_29", offset = 0 },
    },
  },
  ROUTE_29 = {
    id = "ROUTE_29",
    width = 30,
    height = 9,
    environment = "ROUTE",
    tileset = "TILESET_JOHTO",
    borderBlock = 5,
    blocks = {},
    connections = {
      east = { map = "NEW_BARK", offset = 0 },
    },
  },
}

for i = 1, 90 do fakeGen2Maps.NEW_BARK.blocks[i] = 1 end
for i = 1, 270 do fakeGen2Maps.ROUTE_29.blocks[i] = 1 end

local fakeGen2Tilesets = {
  TILESET_JOHTO = {
    id = "TILESET_JOHTO",
    image = "assets/tilesets/johto.png",
    imageWidth = 128,
    imageHeight = 128,
    tilesPerRow = 16,
    blocks = {
      { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    },
    collision = {
      { 0, 0, 0, 0 },
    },
    walkable = { true },
  },
}

local fakeGen2MapInstances = {}
package.loaded["src.world.gen2.Map"] = {
  new = function(def, tileset)
    local inst = {
      id = def.id,
      def = def,
      tileset = tileset,
      width = def.width,
      height = def.height,
      tileAt = function(self, tx, ty) return 0 end,
      cellCollision = function(self, cx, cy) return 0 end,
      isWaterCell = function(self, cx, cy) return false end,
      isWalkableCell = function(self, cx, cy) return true end,
    }
    fakeGen2MapInstances[def.id] = inst
    return inst
  end,
  isOutdoor = function(def)
    return def and (def.environment == "TOWN" or def.environment == "ROUTE")
  end,
}

local storage = {}
local oldLove = _G.love
_G.love = {
  filesystem = {
    getSaveDirectory = function() return "/tmp/potato_voxel_test" end,
    getInfo = function(p)
      if storage[p] then return { size = #storage[p], type = "file" } end
      return nil
    end,
    read = function(p) return storage[p] end,
    write = function(p, data) storage[p] = data; return true end,
    remove = function(p) storage[p] = nil; return true end,
    createDirectory = function() return true end,
    getDirectoryItems = function()
      local items = {}
      for k in pairs(storage) do items[#items + 1] = k end
      return items
    end,
  },
  timer = {
    getTime = function() return 1000.0 end,
  },
  graphics = {
    newMesh = function(format, source, drawMode, usage)
      local mesh = {
        setVertices = function() end,
        setVertexMap = function() end,
        release = function() end,
      }
      return mesh
    end,
    newCanvas = function(w, h)
      return {
        setFilter = function() end,
        release = function() end,
      }
    end,
  },
}

local loadedModules = {}
local activeGame = nil
local V = {}
V.require = function(name)
  if loadedModules[name] then return loadedModules[name] end
  local fn = assert(loadfile("lib/" .. name .. ".lua"))
  local m = fn(V)
  loadedModules[name] = m
  return m
end
local memStore = {}
V.mod = {
  game = nil,
  storage = {
    context = function(self, game)
      if game ~= activeGame then return nil, "wrong_live_game" end
      return { playthroughId = "test_gen2" }
    end,
    dir = function(self, game) return "cache/test_gen2" end,
    writeBytes = function(self, game, key, bytes)
      if game ~= activeGame then return false, "wrong_live_game" end
      memStore[key] = bytes; return true
    end,
    readBytes = function(self, game, key)
      if game ~= activeGame then return nil, "wrong_live_game" end
      return memStore[key]
    end,
    write = function(self, game, key, tbl)
      if game ~= activeGame then return false, "wrong_live_game" end
      memStore[key] = tbl; return true
    end,
    read = function(self, game, key)
      if game ~= activeGame then return nil, "wrong_live_game" end
      return memStore[key]
    end,
    list = function(self, game, prefix)
      local out = {}
      for k in pairs(memStore) do
        if k:sub(1, #prefix) == prefix then out[#out + 1] = k end
      end
      return out
    end,
    delete = function(self, game, key)
      if game ~= activeGame then return false, "wrong_live_game" end
      memStore[key] = nil; return true
    end,
  },
}

loadedModules["RuntimeHooks"] = {
  gameOwner = function() return {} end,
  liveGame = function() return activeGame end,
  borderBlockFor = function(map)
    return map and map.def and map.def.borderBlock or 0
  end,
  treeVoidFill = function() return false end,
  isOutdoor = function(def)
    return def and (def.environment == "TOWN" or def.environment == "ROUTE")
  end,
}

loadedModules["DebugOverlay"] = {
  note = function(fmt, ...) print("[note] " .. string.format(fmt or "", ...)) end,
  warn = function(fmt, ...) print("[warn] " .. string.format(fmt or "", ...)) end,
  error = function(fmt, ...) print("[error] " .. string.format(fmt or "", ...)) end,
  trace = function(fmt, ...) end,
  count = function(...) end,
  buildDone = function(...) end,
  pipelinePath = function(...) end,
}

local Prebuild = V.require("CachePrebuild")
local MeshCache = V.require("MeshCache")
local GeometrySnapshot = V.require("GeometrySnapshot")
local GoldAtlas = V.require("GoldAtlas")

-- Missing atlas pixels must force the worker path to fail and use the
-- complete serial fallback. Treating a Gen 2 miss as success creates a
-- cache that looks READY but contains incomplete geometry.
local prebuildSource = assert(io.open("lib/CachePrebuild.lua", "r")):read("*a")
check(not prebuildSource:find("allowMissingPixels = isGen2()", 1, true),
      "Gen 2 workers must not silently accept missing atlas pixels")
local workerSource = assert(io.open("workers/geometry_worker.lua", "r")):read("*a")
check(workerSource:find("if not tileImage and not cmd.allowMissingPixels then", 1, true),
      "geometry workers must reject missing atlas pixels for Gen 2")
local rawAtlas = { marker = "native-atlas" }
local atlas, colored = GoldAtlas.forMap({}, { tileset = { image = "crystal.png" } },
                                       rawAtlas)
check(atlas == rawAtlas and colored == false,
      "Gen 2 must keep the native atlas when private palette helpers are absent")

-- 1. Test masksFor with Gen 2 computeNeighbors
local masks = Prebuild.masksFor(fakeGen2Maps, "NEW_BARK")
check(#masks == 1, "masksFor must resolve Gen 2 Route 29 connection")
eq(masks[1][1], -32 * 30, "neighbor ox matches")
eq(masks[1][3], 0, "neighbor right bound matches")

-- 2. Test GeometrySnapshot environment & tilePalettes propagation
local testMap = package.loaded["src.world.gen2.Map"].new(
  fakeGen2Maps.NEW_BARK, fakeGen2Tilesets.TILESET_JOHTO
)
testMap.tileset.tilePalettes = { 1, 2, 3 }
local snap = GeometrySnapshot.fromMap(testMap, masks, "trees")
eq(snap.def.environment, "TOWN", "snapshot captures def.environment")
check(snap.tileset.tilePalettes ~= nil, "snapshot captures tileset.tilePalettes")

-- 3. Test Prebuild.bootstrap with Gen 2 dataset
local fakeData = {
  gen2Maps = fakeGen2Maps,
  gen2Tilesets = fakeGen2Tilesets,
  gen2Palettes = {},
}
local fakeGame = {
  data = fakeData,
  world = nil,
}
activeGame = fakeGame
V.mod.game = fakeGame

-- Gen 2 source tables must participate in the cache identity even before the
-- world object is constructed. This catches a stale cache being accepted when
-- only gen2Maps/gen2Tilesets change.
MeshCache.configure(fakeData)
local baseIdentity = MeshCache.identity()
local changedMaps = {}
for id, def in pairs(fakeGen2Maps) do changedMaps[id] = def end
changedMaps.NEW_BARK = {}
for key, value in pairs(fakeGen2Maps.NEW_BARK) do changedMaps.NEW_BARK[key] = value end
changedMaps.NEW_BARK.width = changedMaps.NEW_BARK.width + 1
MeshCache.configure({ gen2Maps = changedMaps,
                      gen2Tilesets = fakeGen2Tilesets,
                      gen2Palettes = fakeData.gen2Palettes })
check(MeshCache.identity() ~= baseIdentity,
      "Gen 2 map tables must invalidate the cache identity")

local ready = Prebuild.bootstrap(fakeGame)
check(not ready, "fresh cache is not ready")
local done, total, running = Prebuild.progress()
eq(total, 4, "4 jobs enumerated (2 maps * body/ring)")
eq(done, 0, "0 done initially")

-- 4. Test liveMaps protection in Gen 2
fakeGame.world = {
  map = testMap,
  neighbors = {},
}
local started = Prebuild.start(fakeGame)
check(started, "Prebuild.start succeeds")

-- 5. Drive prebuild ticks to completion
local maxTicks = 200
local ticks = 0
while ticks < maxTicks do
  ticks = ticks + 1
  Prebuild.update(true)
  done, total, running = Prebuild.progress()
  if not running and Prebuild.status() ~= "BUILD" then break end
end

eq(Prebuild.status(), "READY", "Prebuild completes to READY status for Gen 2")
eq(done, total, "All jobs marked done")

-- 6. Every Gen 2 version must use the same live/data seam without falling
-- back to a Gold-only branch.
for _, version in ipairs({ "gold", "silver", "crystal" }) do
  activeVersion = version
  Prebuild.wipe(fakeGame)
  check(Prebuild.start(fakeGame), version .. " prebuild starts")
  local versionTicks = 0
  while versionTicks < maxTicks do
    versionTicks = versionTicks + 1
    Prebuild.update(true)
    local _, _, versionRunning = Prebuild.progress()
    if not versionRunning then break end
  end
  eq(Prebuild.status(), "READY", version .. " prebuild completes")
end

-- 7. Test primeFirst in Gen 2
local primed = Prebuild.primeFirst(testMap)
check(primed, "primeFirst succeeds on cached Gen 2 map")

-- 8. Test CacheFeature rows inclusion on Crystal
package.loaded["src.render.Pipelines"] = {
  rows = function() return {} end,
}
local CacheFeature = V.require("CacheFeature")
local Cache = CacheFeature.new({
  CachePrebuild = Prebuild,
  MeshCache = MeshCache,
  DebugOverlay = loadedModules["DebugOverlay"],
  PlayerId = { get = function() return "CRYSTAL123" end },
  settingsEntries = {},
})

-- Simulate Crystal stack where Gen2TitleState and Gen2MainMenu are in history
fakeGame.stack = {
  states = {
    { screenId = "Gen2TitleState" },
    { screenId = "Gen2MainMenu" },
    { screenId = "World" },
    { screenId = "OptionsMenu" },
  },
  top = function(self) return self.states[#self.states] end,
}

local rows = Cache.rows(fakeGame)
local prebuildRow = nil
for _, r in ipairs(rows) do
  if r.id == "potato_voxel:prebuild" then
    prebuildRow = r
    eq(r.label, "PREBUILD CACHE", "Row label is PREBUILD CACHE")
    break
  end
end
check(prebuildRow ~= nil, "PREBUILD CACHE option must be present in settings on Crystal")

-- 9. Test row activation with maps exclusively in world.maps (no data.maps)
local pushedScreen = nil
fakeGame.data = {} -- No maps in game.data!
fakeGame.world.maps = fakeGen2Maps
fakeGame.world.tilesets = fakeGen2Tilesets
fakeGame.stack.push = function(self, screen)
  pushedScreen = screen
  self.states[#self.states + 1] = screen
end
fakeGame.stack.pop = function(self)
  return table.remove(self.states)
end
fakeGame.input = {
  wasPressed = function(self, key) return false end,
}

-- Wipe first
Prebuild.wipe(fakeGame)
eq(Prebuild.status(), "PREBUILD", "Status is PREBUILD after wipe")

-- Activate menu row
prebuildRow.activate(fakeGame)
check(pushedScreen ~= nil, "Activating PREBUILD CACHE pushes CachePrebuildScreen")
check(Prebuild.progress(), "Prebuild is running after row activation")

-- Tick through CachePrebuildScreen
local screenTicks = 0
while screenTicks < 200 do
  screenTicks = screenTicks + 1
  pushedScreen:update()
  local d, t, r = Prebuild.progress()
  if not r then break end
end

eq(Prebuild.status(), "READY", "Prebuild via CachePrebuildScreen completed to READY")

_G.love = oldLove
print("gen2_precache_test: ok")
