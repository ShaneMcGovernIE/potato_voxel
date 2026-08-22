-- Threaded-geometry smoke test. Runs under the REAL love binary (no
-- test stub) to prove the worker can load the mod's lib graph through the
-- sandbox shim and return a geometry result through the channels.
--
--   love /Users/shanemcgovern/dev/potato_voxel/tools/thread_smoke
--
-- Exits 0 on success, 1 on failure.

-- the mod directory: symlinked as lib/ + workers/ next to this file, so
-- the harness game dir itself resolves them (no mount needed)
local modRoot = "."
assert(love.filesystem.mount or true)

-- engine shims, exactly like workers/geometry_worker.lua seeds them
local Assets = { register = function() end, imageData = function() return nil end }
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
local TileRenderer = { voidFill = "trees",
  borderBlockFor = function(map)
    if map.def.tileset == "OVERWORLD" then return 0x0F end
    return map.def.borderBlock
  end }
package.loaded["src.render.Assets"] = Assets
package.loaded["src.world.Map"] = Map
package.loaded["src.render.TileRenderer"] = TileRenderer
package.loaded["src.core.Game"] = {}
package.loaded["DebugOverlay"] = {}

-- any other engine module the load graph pulls in resolves to a stub
local function srcStub(name)
  if name:find("^src%.") then
    return function() return {} end
  end
  return "\n\tno stub for " .. name
end
table.insert(package.loaders or package.searchers, 1, srcStub)

local libs = {}
local V = { mod = {}, path = "potato_voxel" }
function V.require(name)
  local hit = libs[name]
  if hit ~= nil then return hit end
  local ok, chunk = pcall(love.filesystem.load, "lib/" .. name .. ".lua")
  assert(ok and chunk, "load lib/" .. name)
  local value = chunk(V)
  libs[name] = value
  return value
end

local WorkerPool = V.require("WorkerPool")
local MeshCache = V.require("MeshCache")
local geometryProfile = {
  ROUND_RING = 12,
  HULL_BILLBOARDS = true,
  BILLBOARD_CROSS = true,
}

local function waitFor(gen, timeout)
  local streams = {}
  local deadline = love.timer.getTime() + (timeout or 60)
  while love.timer.getTime() < deadline do
    for _, item in ipairs(WorkerPool.poll()) do
      if item.gen == gen then
        if item.kind == "chunk" then
          local stream = streams[item.stream]
          if not stream then
            stream = { n = 0, m = 0, chunks = 0 }
            streams[item.stream] = stream
          end
          stream.n = stream.n + (item.chunk.vertexCount or 0)
          stream.m = stream.m + (item.chunk.indexCount or 0)
          stream.chunks = stream.chunks + 1
          WorkerPool.ack(gen, item.stream, item.chunk.sequence)
        else
          return item, streams
        end
      end
    end
    love.timer.sleep(0.01)
  end
  return nil, streams
end

-- a tiny flat map: 4x4 grass blocks, no structures to speak of
local blocks = {}
for i = 1, 16 do blocks[i] = 1 end          -- block 1 = grass
local tileset = {
  id = "SMOKE", image = "smoke.png", tilesPerRow = 16,
  imageWidth = 128, imageHeight = 48,
  blocks = { { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
             { 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2 } },
}
local map = {
  id = "SMOKE_CITY", def = { width = 4, height = 4, blocks = blocks,
                             borderBlock = 1, tileset = "OVERWORLD" },
  tileset = tileset,
  walkable = { [1] = true, [2] = true },
  waterTiles = {},
  doorTiles = {},
}

-- 1. serialization round-trip
local src = WorkerPool.serializeMap(map)
local chunk = assert(load(src, "@smoke", "t"))
local map2 = chunk()
map2.tileAt = Map.tileAt
map2.blockAt = Map.blockAt
assert(map2.id == "SMOKE_CITY" and map2.def.width == 4
       and map2.def.blocks[1] == 1 and map2.tileset.blocks[2][16] == 2,
       "serialize round-trip")

-- 2. the real threaded round trip
assert(WorkerPool.enabled(), "pool enabled under real love")
WorkerPool.start()
assert(WorkerPool.working(), "workers started")

local gen = WorkerPool.submit({
  version = MeshCache.GEOMETRY_VERSION,
  mapSrc = src,
  bodyOnly = false,
  masks = {},
  voidFill = "trees",
  tilePath = "smoke.png",
  allowMissingPixels = true,
  geometryProfile = geometryProfile,
})
assert(gen, "job submitted")

local result, streams = waitFor(gen)
assert(result, "worker returned a result within 60s")
assert(not result.error, "result carries no error: " .. tostring(result.error))
local d = result.data
assert(result.kind == "complete" and d and d.aux,
       "worker returns a complete result with aux")
assert(streams["single.terrain"] and streams["single.terrain"].n > 0,
       "terrain stream has bounded chunks with vertices")

-- 3. sequential job with a different atlas path.  The worker must keep the
-- resolver stable rather than replacing it with the previous job's image.
local secondGen = WorkerPool.submit({
  version = MeshCache.GEOMETRY_VERSION,
  mapSrc = src,
  mapId = "SMOKE_CITY_2",
  bodyOnly = true,
  masks = {},
  voidFill = "trees",
  tilePath = "other-smoke.png",
  allowMissingPixels = true,
  geometryProfile = geometryProfile,
})
assert(secondGen, "second atlas job submitted")
local second = waitFor(secondGen)
assert(second and not second.error, "second atlas job returned cleanly")

-- 4. Cancellation is terminal at the pool boundary even if the worker had
-- already completed the CPU call before it observed the cancel command.
local cancelGen = WorkerPool.submit({
  version = MeshCache.GEOMETRY_VERSION,
  mapSrc = src,
  mapId = "SMOKE_CANCEL",
  bodyOnly = true,
  masks = {},
  voidFill = "trees",
  tilePath = "cancel-smoke.png",
  allowMissingPixels = true,
  geometryProfile = geometryProfile,
})
assert(cancelGen and WorkerPool.cancel(cancelGen), "cancel requested")
local cancelled = waitFor(cancelGen)
assert(cancelled and cancelled.kind == "cancelled",
       "cancelled generation cannot return payload")

print("THREADED GEOMETRY OK: terrain="
      .. streams["single.terrain"].n .. " verts, "
      .. "aux grass=" .. tostring(d.aux.grass and d.aux.grass.n or 0)
      .. " figures=" .. tostring(#d.aux.figures))
WorkerPool.shutdown()
love.event.quit(0)
