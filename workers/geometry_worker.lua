-- Geometry worker for the threaded prebuilder (docs/threaded-geometry-design.md).
--
-- Runs the pure CPU phase of a cache job -- Structures analysis,
-- runGeometry's terrain/water streams and the flattened aux records --
-- off the main thread, following the engine's own chip_worker pattern
-- (src/core/chip_worker.lua): command channel in, result channel out,
-- one job at a time per worker.
--
-- The mod's lib files load through the same `local V = ...` sandbox as
-- in-game; the engine modules the geometry path touches are replaced by
-- the small pure shims below (pre-seeded into package.loaded so the
-- libs' plain `require("src...")` gets them), because the real modules
-- can reach into love.graphics and are not thread-safe. Shims are
-- value-identical for the geometry surface:
--   TileRenderer.borderBlockFor + voidFill  (border ring + void fill)
--   Map.isOutdoor / Map:tileAt / Map:blockAt
--   Assets.imageData                        (void-tile pixel scan)
--   Assets.register                         (no-op: no runtime cache here)
--
-- Job payload:  { cmd="geometry", gen, mapSrc, variant, masks,
--                 voidFill, tilePath, pair, geometryProfile }
--   mapSrc   Lua-source dump of the map's data tables (WorkerPool.serializeMap)
--   tilePath  the tileset image path. The worker loads its own ImageData;
--             ImageData userdata is never copied through a channel.
--   pair      when true, return body+ring streams from one analysis.
--   geometryProfile  the main VM's round-hull switches. main.lua does not
--             execute in worker VMs, so this is required for visual parity.
-- Result:    one { gen, kind="chunk", stream, chunk } at a time, followed by
--            { gen, kind="complete", data={ aux=... } }.
--            Each chunk waits for a main-thread ACK, bounding channel memory.
--            Errors fall back to the serial pump.

require("love.thread")
require("love.timer")
require("love.filesystem")
require("love.image")

-- --------------------------------------------------------- engine shims

local TileRenderer = {}
TileRenderer.voidFill = "trees" -- per-job override; see handleGeometry
local TREE_WALL_BLOCK = 0x0F
local WATER_BORDER_BLOCK = 0x43
function TileRenderer.borderBlockFor(map)
  if map.def.tileset == "OVERWORLD" then
    local mode = TileRenderer.voidFill or "trees"
    if mode == "water" then return WATER_BORDER_BLOCK end
    if mode == "black" then return false end
    return TREE_WALL_BLOCK
  end
  return map.def.borderBlock
end

local root = ""
local Assets = {}
function Assets.register() end
local function loadImageData(path, baseRoot)
  if not (love and love.image and love.image.newImageData) then return nil end
  local ok, data = pcall(love.image.newImageData, path)
  if (not ok or not data) and baseRoot ~= "" and type(path) == "string"
     and path:sub(1, #baseRoot + 1) ~= baseRoot .. "/" then
    ok, data = pcall(love.image.newImageData, baseRoot .. "/" .. path)
  end
  return ok and data or nil
end

local Map = {}
function Map.isOutdoor(def)
  if not def then return false end
  if def.outdoor ~= nil then return def.outdoor end
  if def.tileset == "OVERWORLD" then return true end
  local env = def.environment
  return env == "TOWN" or env == "ROUTE"
end
function Map.blockAt(self, bx, by)
  if bx < 0 or by < 0 or bx >= self.def.width or by >= self.def.height then
    return self.def.borderBlock
  end
  return self.def.blocks[by * self.def.width + bx + 1]
end
local function gen2(self)
  return type(self.tileset and self.tileset.collision) == "table"
end
local function collisionAt(self, cx, cy)
  local bx, by = math.floor(cx / 2), math.floor(cy / 2)
  local blockId = self:blockAt(bx, by)
  local quad = self.tileset.collision[blockId + 1]
  if not quad then return 0xff end
  return quad[(cy % 2) * 2 + (cx % 2) + 1] or 0xff
end
-- CollisionPermissionTable lo-nybble (home/map_objects.asm): 0 land, 1 water,
-- 15 wall. Copied because the real Permissions module is not thread-safe to
-- load here (srcStub returns {}).
local COLL_PERM = {
   0,  0,  0,  0,  0,  0,  0, 15,  0,  0,  0,  0,  0,  0,  0, 15,
   0,  0, 15,  0,  0, 15,  0,  0,  0,  0, 15,  0,  0, 15,  0,  0,
   1,  1,  1,  0,  1,  1,  1, 15,  1,  1,  1,  0,  1,  1,  1, 15,
   1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,
   0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
   0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
   0,  0, 15,  0,  0,  0,  0,  0,  0,  0, 15,  0,  0,  0,  0,  0,
   0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
  15, 15, 15, 15, 15,  0,  0,  0, 15, 15, 15, 15, 15,  0,  0,  0,
  15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
   0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
   0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
   1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,
   0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
   0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
   0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0, 15,
}
local function collPerm(coll)
  if coll == nil or coll < 0 then return 15 end
  return COLL_PERM[(coll % 256) + 1] or 15
end
function Map.tileAt(self, tx, ty)
  local bx, by = math.floor(tx / 4), math.floor(ty / 4)
  local block = self.tileset.blocks[self:blockAt(bx, by) + 1]
  local ix = (ty % 4) * 4 + (tx % 4) + 1
  return block[ix]
end
function Map.cellCollision(self, cx, cy)
  if gen2(self) then return collisionAt(self, cx, cy) end
  return self:tileAt(cx * 2, cy * 2 + 1)
end
function Map.cellTile(self, cx, cy)
  return self:cellCollision(cx, cy)
end
function Map.inBounds(self, cx, cy)
  return cx >= 0 and cy >= 0 and cx < self.def.width * 2
         and cy < self.def.height * 2
end
function Map.isWalkableCell(self, cx, cy)
  if gen2(self) then
    if not self:inBounds(cx, cy) then return false end
    return collPerm(collisionAt(self, cx, cy)) == 0
  end
  return self.walkable and self.walkable[self:cellTile(cx, cy)] or false
end
function Map.isGrassCell(self, cx, cy)
  if not self:inBounds(cx, cy) then return false end
  if gen2(self) then
    local coll = collisionAt(self, cx, cy)
    return coll == 0x10 or coll == 0x14 or coll == 0x18 or coll == 0x1c
  end
  local grass = self.tileset.grassTile
  return grass ~= nil and self:cellTile(cx, cy) == grass
end
function Map.isWaterCell(self, cx, cy)
  if gen2(self) then
    if not self:inBounds(cx, cy) then return false end
    return collPerm(collisionAt(self, cx, cy)) == 1
  end
  return self.waterTiles and self.waterTiles[self:cellTile(cx, cy)] or false
end
function Map.isDoorTileCell(self, cx, cy)
  if not self:inBounds(cx, cy) then return false end
  if gen2(self) then
    local coll = collisionAt(self, cx, cy)
    if coll == 0x60 or coll == 0x68 then return true end
    if math.floor(coll / 16) ~= 7 then return false end
    return coll ~= 0x70 and coll ~= 0x76 and coll ~= 0x78 and coll ~= 0x7e
  end
  return self.doorTiles and self.doorTiles[self:cellTile(cx, cy)] or false
end

-- Anything else the libs touch lazily (MeshCache.resolveStore's Game,
-- DebugOverlay, Sky/DayNight's PaletteFX, ...) must never load the real
-- module in a thread: the pure geometry path does not need them. Anything
-- under "src." that is not pre-seeded above resolves to an empty-table
-- stub -- load-time side effects of the real modules (canvases, shaders)
-- are exactly what a thread cannot have.
local function srcStub(name)
  if name:find("^src%.") then
    return function() return {} end
  end
  return "\n\tno stub for " .. name
end
table.insert(package.loaders or package.searchers, 1, srcStub)

-- the shims we DO implement win over the stub via package.loaded
package.loaded["src.render.TileRenderer"] = TileRenderer
package.loaded["src.render.Assets"] = Assets
package.loaded["src.world.Map"] = Map

-- ------------------------------------------------------- mod sandbox

-- The mod's libs are loaded with `local V = ...` and V.require() exactly
-- like main.lua does; V.data is unused by the geometry path but shimmed
-- for load-time symmetry. `root` is the love.filesystem prefix to the mod
-- dir, set per job ("" for a dev harness, "mods/<id>" in the game).
local libs = {}
local V = { mod = {}, path = "potato_voxel" }
function V.require(name)
  local hit = libs[name]
  if hit ~= nil then return hit end
  local ok, chunk = pcall(love.filesystem.load,
                          root == "" and ("lib/" .. name .. ".lua")
                                       or (root .. "/lib/" .. name .. ".lua"))
  if not ok or not chunk then
    error("geometry worker: cannot load lib/" .. name .. ".lua: "
          .. tostring(chunk), 0)
  end
  local value = chunk(V)
  libs[name] = value
  return value
end
function V.data(name)
  local ok, chunk = pcall(love.filesystem.load,
                          root == "" and ("data/" .. name .. ".lua")
                                       or (root .. "/data/" .. name .. ".lua"))
  if not ok or not chunk then return nil end
  return chunk(V)
end
function V.read(rel)
  local path = root == "" and rel or (root .. "/" .. rel)
  local ok, data = pcall(love.filesystem.read, path)
  if ok and type(data) == "string" then return data end
  return nil
end

-- The worker's V.require resolves relative to `root`, which is supplied in
-- the first job.  Loading this at thread startup resolves against the engine
-- root in packaged builds (not mods/potato_voxel) and makes LÖVE terminate
-- the worker before it can report a job result.
local WorkerAtlas = nil
local atlas = nil
local atlasRoot = nil
function Assets.imageData(path)
  if not atlas then return nil end
  return atlas:get(path, root)
end

-- ChunkMesher loads lazily on the first job: its lib path needs the
-- job's fs root, which is only known once the pool has started.
local ChunkMesher = nil
local Structures = nil
local GeometryProfile = nil

-- -------------------------------------------------------------- loop

local cmdCh = love.thread.getChannel("pv_geom_cmd")
local outCh = love.thread.getChannel("pv_geom_out")
local cancelled = {}
local finished = {}
local cancelAll = false

local function waitChunkAck(gen, stream, sequence)
  local ackCh = love.thread.getChannel("pv_geom_ack_" .. tostring(gen))
  while true do
    if cancelled[gen] or cancelAll then return false end
    local ack = ackCh:pop()
    if ack and ack.cancel then return false end
    if ack and ack.stream == stream and ack.sequence == sequence then
      return true
    end
    love.timer.sleep(0.001)
  end
end

local function emitStream(gen, name, stream)
  local chunks = stream and stream.chunks or {}
  for i = 1, #chunks do
    local chunk = chunks[i]
    if cancelled[gen] or cancelAll then return false end
    outCh:push({ gen = gen, kind = "chunk", stream = name, chunk = chunk })
    if not waitChunkAck(gen, name, chunk.sequence) then return false end
    -- Release worker ownership after main ACK. Do not retain whole-map byte
    -- strings while later chunks are emitted.
    chunks[i] = nil
  end
  return true
end

local function emitResult(cmd, data)
  local streams = {}
  if cmd.pair then
    streams.body = data.body
    streams.ring = data.ring
  else
    streams.single = data
  end
  for name, payload in pairs(streams) do
    if not emitStream(cmd.gen, name .. ".terrain", payload.terrain)
       or not emitStream(cmd.gen, name .. ".water", payload.water) then
      return false
    end
  end
  outCh:push({ gen = cmd.gen, kind = "complete", data = { aux = data.aux } })
  return true
end

local function handleGeometry(cmd)
  local nextRoot = cmd.root or ""
  if atlasRoot ~= nil and atlasRoot ~= nextRoot and atlas then atlas:clear() end
  root = nextRoot
  atlasRoot = root
  if not WorkerAtlas then
    WorkerAtlas = V.require("WorkerAtlas")
    atlas = WorkerAtlas.new(loadImageData)
  end
  if not ChunkMesher then
    ChunkMesher = V.require("ChunkMesher")
    Structures = V.require("Structures")
    GeometryProfile = V.require("GeometryProfile")
  end
  local profileOk, profileErr =
    GeometryProfile.apply(Structures, cmd.geometryProfile)
  if not profileOk then error(profileErr, 0) end
  TileRenderer.voidFill = cmd.voidFill or "trees"
  local chunk, err = load(cmd.mapSrc, "@pv-job-map", "t")
  if not chunk then
    error("job map source did not compile: " .. tostring(err), 0)
  end
  local map = chunk()
  -- the engine Map class is not loaded in the worker; reattach the pure
  -- methods the geometry path uses (same implementations as src/world/Map.lua)
  for _, name in ipairs({ "tileAt", "blockAt", "cellTile", "inBounds",
                          "isWalkableCell", "isGrassCell", "isWaterCell" }) do
    map[name] = Map[name]
  end
  -- Pixel classification is load-bearing for sprite-stacked trees, posts,
  -- and bollards. Never silently fall back to volume voxels when the atlas
  -- is unavailable: fail this worker job and let the main thread's serial
  -- path rebuild it with the engine asset resolver.
  local tilePath = cmd.tilePath or (map.tileset and map.tileset.image)
  local tileImage = Assets.imageData(tilePath)
  if not tileImage and not cmd.allowMissingPixels then
    error("tileset pixel data unavailable: " .. tostring(tilePath), 0)
  end
  if tileImage and (cmd.imageWidth or cmd.imageHeight)
     and not WorkerAtlas.dimensionsMatch(tileImage, cmd.imageWidth,
                                         cmd.imageHeight) then
    error(("atlas dimensions mismatch gen=%s map=%s path=%s expected=%sx%s")
            :format(tostring(cmd.gen), tostring(cmd.mapId), tostring(tilePath),
                    tostring(cmd.imageWidth), tostring(cmd.imageHeight)), 0)
  end
  local ok, data = pcall(function()
    if cmd.pair then
      return ChunkMesher.buildGeometryPairChunkData(map, cmd.masks)
    end
    return ChunkMesher.buildGeometryChunkData(map, cmd.variant, cmd.masks)
  end)
  if Structures and Structures.release then Structures.release(map.id) end
  if not ok then error(data, 0) end
  return { gen = cmd.gen, data = data }
end

while true do
  local cmd = cmdCh:pop()
  if cmd then
    if cmd.cmd == "cancel" then
      if not finished[cmd.gen] then cancelled[cmd.gen] = true end
    elseif cmd.cmd == "cancel_all" then
      cancelAll = true
    elseif cmd.cmd == "quit" then
      break
    elseif cmd.cmd == "geometry" then
      if cancelled[cmd.gen] or cancelAll then
        outCh:push({ gen = cmd.gen, kind = "cancelled" })
        finished[cmd.gen] = true
      else
      outCh:push({ gen = cmd.gen, kind = "heartbeat" })
      local ok, res = pcall(handleGeometry, cmd)
      if ok and not cancelled[cmd.gen] and not cancelAll then
        if not emitResult(cmd, res.data) then
          outCh:push({ gen = cmd.gen, kind = "cancelled" })
        end
      elseif not ok and not cancelled[cmd.gen] and not cancelAll then
        outCh:push({ gen = cmd.gen, error = tostring(res) })
      else
        outCh:push({ gen = cmd.gen, kind = "cancelled" })
      end
      finished[cmd.gen] = true
      end
    end
  else
    love.timer.sleep(0.001)
  end
end
