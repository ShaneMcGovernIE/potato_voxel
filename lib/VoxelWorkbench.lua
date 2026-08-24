-- Local browser-workbench bridge for Gold.

local V = ...
local mod = V.mod
local Json = V.require("WorkbenchJson")
local TileShape = V.require("TileShape")

local Workbench = {
  commandId = nil,
  lastWrite = 0,
  lastError = nil,
  lastCommand = nil,
  mapList = nil,
  lastCapture = nil,
  lastObjectCapture = nil,
  atlasKey = nil,
  atlasPath = nil,
  atlasRevision = 0,
}

local BRIDGE_DIR = "voxel-workbench"
local COMMAND_PATH = BRIDGE_DIR .. "/command.json"
local STATUS_PATH = BRIDGE_DIR .. "/status.json"
local STATUS_TMP = BRIDGE_DIR .. "/status.tmp"
local DIRECTIONS = { up = true, down = true, left = true, right = true }

local function clamp(n, low, high)
  n = math.floor(tonumber(n) or low)
  if n < low then return low end
  if n > high then return high end
  return n
end

local function mapList(world)
  if Workbench.mapList and Workbench.mapList.source == world.maps then
    return Workbench.mapList.rows
  end
  local rows = {}
  for id, def in pairs(world.maps or {}) do
    rows[#rows + 1] = {
      id = id,
      name = type(def.name) == "string" and def.name or id,
      tilesetId = def.tileset,
      widthCells = (tonumber(def.width) or 0) * 2,
      heightCells = (tonumber(def.height) or 0) * 2,
    }
  end
  table.sort(rows, function(a, b) return a.id < b.id end)
  Workbench.mapList = { source = world.maps, rows = rows }
  return rows
end

local function nearby(world)
  local map, player = world.map, world.player
  if not (map and player) then return {}, {} end
  local shapes = TileShape.forMap(map)
  local cx, cy = player.cellX or 0, player.cellY or 0
  local cells = {}
  for y = cy - 4, cy + 4 do
    for x = cx - 4, cx + 4 do
      if map:inBounds(x, y) then
        local tiles = {}
        for dy = 0, 1 do
          for dx = 0, 1 do
            local tx, ty = x * 2 + dx, y * 2 + dy
            local tile = map:tileAt(tx, ty)
            local shape = TileShape.at(map, shapes, tile, tx, ty)
            tiles[#tiles + 1] = {
              id = tile, x = tx, y = ty,
              class = shape and shape.class or "unknown",
              height = shape and shape.h or 0,
              authored = shape and shape.authored == true or false,
            }
          end
        end
        cells[#cells + 1] = {
          x = x, y = y, collision = map:cellCollision(x, y),
          walkable = map:isWalkableCell(x, y), water = map:isWaterCell(x, y),
          grass = map.isGrassCell and map:isGrassCell(x, y) or false,
          tiles = tiles,
        }
      end
    end
  end
  local objects = {}
  for _, entity in ipairs(world.npcs or {}) do
    local x, y = entity.cellX, entity.cellY
    if type(x) == "number" and type(y) == "number"
      and math.abs(x - cx) <= 5 and math.abs(y - cy) <= 5 then
      objects[#objects + 1] = {
        x = x, y = y, facing = entity.facing,
        name = tostring(entity.name or entity.id or entity.sprite or "NPC"),
      }
    end
  end
  return cells, objects
end

local function reloadGold(game)
  if os.getenv("POKEPORT_DEV") ~= "1" then
    return false, "Hot reload is enabled only when POKEPORT_DEV=1."
  end
  local HotReload = require("src.dev.HotReload")
  local world, map, player = game.world, game.world and game.world.map,
      game.world and game.world.player
  local mapId = map and map.id
  local x, y, facing = player and player.cellX, player and player.cellY,
      player and player.facing
  local loader, summary = HotReload.run(game)
  if world and mapId and world.setMap then
    world:setMap(mapId, x, y, facing, { via = "boot" })
  end
  return loader ~= nil, summary
end

local function exportAtlas(world, map)
  local tileset = map and map.tileset
  if not (world and map and map.def and tileset and tileset.image) then return nil end
  local roofName = world.roofs and world.roofs.mapGroupRoofs
      and world.roofs.mapGroupRoofs[map.def.group]
  local roofSpec = roofName and world.roofs and world.roofs.roofs and world.roofs.roofs[roofName]
  local key = tostring(map.id) .. ":" .. tostring(tileset.image) .. ":" .. tostring(roofSpec and roofSpec.image)
  if Workbench.atlasKey == key and Workbench.atlasPath then return Workbench.atlasPath end
  local path = BRIDGE_DIR .. "/live_atlas.png"
  love.filesystem.createDirectory(BRIDGE_DIR)
  local made, data = pcall(love.image.newImageData, tileset.image)
  if not (made and data and data.encode) then return nil end
  if roofSpec and roofSpec.image then
    local roofOK, roof = pcall(love.image.newImageData, roofSpec.image)
    if roofOK and roof then
      local perRow = tileset.tilesPerRow or 16
      for t = 0, 8 do
        local dx = ((0x0a + t) % perRow) * 8
        local dy = math.floor((0x0a + t) / perRow) * 8
        local sx = t * 8
        for y = 0, 7 do for x = 0, 7 do
          data:setPixel(dx + x, dy + y, roof:getPixel(sx + x, y))
        end end
      end
    end
  end
  local written = pcall(data.encode, data, "png", path)
  if not written then return nil end
  Workbench.atlasKey, Workbench.atlasPath = key, path
  Workbench.atlasRevision = Workbench.atlasRevision + 1
  return path
end

local function captureGraphic(game, command, target)
  local world, map = game.world, game.world and game.world.map
  if not (world and map and map.tileset) then
    Workbench.lastError = "No Gold map is ready to capture."
    return
  end
  local maxX, maxY = math.max(0, (map.widthCells or 1) - 1), math.max(0, (map.heightCells or 1) - 1)
  local x0, x1 = clamp(command.x0, 0, maxX), clamp(command.x1, 0, maxX)
  local y0, y1 = clamp(command.y0, 0, maxY), clamp(command.y1, 0, maxY)
  if x1 < x0 then x0, x1 = x1, x0 end
  if y1 < y0 then y0, y1 = y1, y0 end
  if x1 - x0 + 1 > 24 or y1 - y0 + 1 > 24 then
    Workbench.lastError = "Graphic capture is limited to 24 by 24 map cells."
    return
  end
  local tiles = {}
  for cy = y0, y1 do
    local top, bottom = {}, {}
    for cx = x0, x1 do
      top[#top + 1] = map:tileAt(cx * 2, cy * 2)
      top[#top + 1] = map:tileAt(cx * 2 + 1, cy * 2)
      bottom[#bottom + 1] = map:tileAt(cx * 2, cy * 2 + 1)
      bottom[#bottom + 1] = map:tileAt(cx * 2 + 1, cy * 2 + 1)
    end
    tiles[#tiles + 1] = top
    tiles[#tiles + 1] = bottom
  end
  Workbench[target] = {
    mapId = map.id, tilesetId = map.tileset.id, x0 = x0, y0 = y0, x1 = x1, y1 = y1,
    tiles = tiles,
  }
end

local function processCommand(game)
  local raw = love.filesystem.read(COMMAND_PATH)
  if not raw then return end
  local command, err = Json.decode(raw)
  if type(command) ~= "table" or type(command.id) ~= "string" then
    Workbench.lastError = "Ignoring malformed workbench command: " .. tostring(err or "missing id")
    return
  end
  if command.id == Workbench.commandId then return end
  Workbench.commandId = command.id
  Workbench.lastCommand = command.op
  Workbench.lastError = nil

  if command.op == "teleport" then
    local world, def = game.world, game.world and game.world.maps and game.world.maps[command.mapId]
    if not (world and def) then
      Workbench.lastError = "Unknown Gold map: " .. tostring(command.mapId)
      return
    end
    local x = clamp(command.x, 0, math.max(0, (def.width or 1) * 2 - 1))
    local y = clamp(command.y, 0, math.max(0, (def.height or 1) * 2 - 1))
    local facing = DIRECTIONS[command.facing] and command.facing
      or (world.player and world.player.facing) or "down"
    local ok = world:setMap(command.mapId, x, y, facing, { via = "boot" })
    if not ok then Workbench.lastError = tostring(world.status or "Teleport failed") end
  elseif command.op == "reload" then
    local ok, message = reloadGold(game)
    if not ok then Workbench.lastError = tostring(message) end
  elseif command.op == "capture_building" then
    captureGraphic(game, command, "lastCapture")
  elseif command.op == "capture_object" then
    captureGraphic(game, command, "lastObjectCapture")
  elseif command.op ~= "snapshot" then
    Workbench.lastError = "Unknown workbench command: " .. tostring(command.op)
  end
end

local function writeStatus(game)
  local world, map, player = game.world, game.world and game.world.map,
      game.world and game.world.player
  local cells, objects = {}, {}
  if world and map and player then cells, objects = nearby(world) end
  local atlasPath = world and map and exportAtlas(world, map)
  local payload = {
    version = 1,
    connected = world ~= nil,
    saveDirectory = love.filesystem.getSaveDirectory(),
    bridgeDirectory = love.filesystem.getSaveDirectory() .. "/" .. BRIDGE_DIR,
    lastCommand = Workbench.lastCommand,
    lastError = Workbench.lastError,
    maps = world and mapList(world) or {},
    map = map and {
      id = map.id, name = map.def and (type(map.def.name) == "string" and map.def.name or map.id),
      tilesetId = map.tileset and map.tileset.id,
      widthCells = map.widthCells, heightCells = map.heightCells,
      tilesPerRow = map.tileset and map.tileset.tilesPerRow or 16,
    } or nil,
    player = player and { x = player.cellX, y = player.cellY, facing = player.facing } or nil,
    nearbyCells = cells,
    nearbyObjects = objects,
    lastCapture = Workbench.lastCapture,
    lastObjectCapture = Workbench.lastObjectCapture,
    atlas = atlasPath and { path = atlasPath, revision = Workbench.atlasRevision } or nil,
  }
  local body = Json.encode(payload)
  love.filesystem.createDirectory(BRIDGE_DIR)
  if love.filesystem.write(STATUS_TMP, body) then
    love.filesystem.write(STATUS_PATH, body)
  end
end

function Workbench.update(game, dt)
  Workbench.updatedThisFrame = true
  if not (game and game.world) then return end
  processCommand(game)
  Workbench.lastWrite = Workbench.lastWrite + (tonumber(dt) or 0)
  if Workbench.lastWrite >= 0.20 then
    Workbench.lastWrite = 0
    local ok, err = pcall(writeStatus, game)
    if not ok then Workbench.lastError = tostring(err) end
  end
end

function Workbench.frame(game)
  if not Workbench.updatedThisFrame then Workbench.update(game, 1 / 60) end
  Workbench.updatedThisFrame = false
end

function Workbench.install()
  local raw = love.filesystem.read(COMMAND_PATH)
  local existing = raw and Json.decode(raw)
  if type(existing) == "table" and type(existing.id) == "string" then
    Workbench.commandId = existing.id
  end
  mod.hooks:wrap("core.update", function(nextFn, game, dt)
    Workbench.update(game, dt)
    return nextFn(game, dt)
  end, 900)
end

function Workbench.status()
  return { bridgeDirectory = love.filesystem.getSaveDirectory() .. "/" .. BRIDGE_DIR,
           lastCommand = Workbench.lastCommand, lastError = Workbench.lastError }
end

return Workbench
