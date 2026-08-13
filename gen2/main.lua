-- Gold-specific PotatoVoxel entry point.
--
-- Gold's World stores its connected maps as lightweight image records and
-- composites its overworld and UI into one scene canvas.  This bridge keeps
-- Gold authoritative for movement and UI, while supplying VoxelScene the
-- map/actor/atlas shape it was written to render.

local mod = ...

local V = { mod = mod, path = mod.path }
local modules = {}

function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  local rel = "lib/" .. name .. ".lua"
  local source = mod:read(rel)
  if not source then error("potato_voxel: missing " .. rel, 0) end
  local chunk, err = load(source, "@" .. mod.path .. "/" .. rel)
  if not chunk then error("potato_voxel: " .. rel .. " did not compile: " .. tostring(err), 0) end
  local value = chunk(V)
  modules[name] = value
  return value
end

local Voxel = V.require("VoxelState")
local Voxel3D = V.require("Voxel3D")
local VoxelScene = V.require("VoxelScene")
local ChunkMesher = V.require("ChunkMesher")
local GoldAtlas = V.require("GoldAtlas")
local Workbench = V.require("VoxelWorkbench")
local SpriteBillboards = V.require("SpriteBillboards")
local Buildings = V.require("Buildings")
local Structures = V.require("Structures")

local Bridge = { lastError = nil, frames = 0, rendered = 0, pending = 0,
                 primedMapId = nil, terrainReady = false, meshPending = 0,
                 overlayFrames = 0, overlayStates = 0, playerCard = nil,
                 cameraView = nil }
local mapModules = {}
local warned = {}
local voxelMaps = setmetatable({}, { __mode = "k" })

local function warnOnce(key, message)
  if warned[key] then return end
  warned[key] = true
  if mod.log and mod.log.warn then mod.log:warn("PotatoVoxel Gold: %s", message) end
end

local function mapModule()
  if mapModules.Map then return mapModules.Map end
  local ok, Map = pcall(require, "src.world.gen2.Map")
  if ok and type(Map) == "table" and type(Map.new) == "function" then
    mapModules.Map = Map
    return Map
  end
  return nil
end

-- Gold's NPC class already implements the shared seven-value pose contract,
-- but its Player class does not. VoxelScene consumes that contract for both
-- actors, so add the same non-mutating presentation adapter to the class.
local function ensurePlayerPose()
  local ok, Player = pcall(require, "src.world.gen2.Player")
  if not (ok and type(Player) == "table") then
    return nil, "Gold Player class is unavailable: " .. tostring(Player)
  end
  if type(Player.pose) ~= "function" then
    function Player:pose()
      return self.sprite, self.px, self.py + (self.spriteYOffset or 0),
             self.facing, (self.walkPhase and self:walkPhase()) or 0,
             self.stepFlip == true, false
    end
  end
  return true
end

-- Gold's live Map:cellTile deliberately answers a collision byte.  That is
-- correct for movement, but VoxelScene uses the Gen 1 spelling to sample the
-- bottom-left *graphics* tile for terrain height. Give the renderer a proxy
-- with that one presentation read translated; leave the live collision map
-- untouched for Gold's simulation.
local function voxelMap(map)
  local cached = voxelMaps[map]
  if cached then return cached end
  local proxy = {}
  setmetatable(proxy, { __index = function(_, key)
    if key == "cellTile" then
      return function(_, cx, cy)
        return map:tileAt(cx * 2, cy * 2 + 1)
      end
    end
    return map[key]
  end })
  voxelMaps[map] = proxy
  return proxy
end

-- VoxelScene samples a tileset atlas through `map.renderer.image`.  Gold owns
-- that atlas through World:atlasFor, so attach a renderer-side view without
-- modifying Gold's map, collision, or image-bake logic.
local function attachAtlas(world, map)
  if not (world and map and map.def and type(world.atlasFor) == "function") then
    return nil, "Gold map or World:atlasFor is unavailable"
  end
  local ok, atlas, tileset = pcall(world.atlasFor, world, map.def)
  if not ok then return nil, "World:atlasFor failed: " .. tostring(atlas) end
  if not atlas then return nil, "World:atlasFor returned no atlas" end

  map.tileset = tileset or map.tileset
  map.renderer = map.renderer or {}
  local colored, isColored = GoldAtlas.forMap(world, map, atlas)
  map.renderer.image = colored
  -- Gold's atlas is already the native texture; preventing the Gen 1 palette
  -- rebake avoids reading a Gen 1 TileRenderer cache that Gold never creates.
  map.renderer.gbcAtlas = isColored
  map.renderer.data = world.game and world.game.data or map.renderer.data
  -- Gen 2 doors are collision kinds, not a Gen 1 tile set.  An empty table
  -- leaves the optional facade-folding pass inert instead of indexing nil.
  map.doorTiles = map.doorTiles or {}
  return map
end

local function directNeighbors(world)
  local root, maps, tilesets = world and world.map and world.map.def,
      world and world.maps, world and world.tilesets
  local Map = mapModule()
  if not (root and maps and tilesets and Map) then return {} end

  local native = {}
  for _, entry in ipairs(world.neighbors or {}) do
    if entry and entry.id then native[entry.id] = entry end
  end

  local out, seen = {}, {}
  for _, dir in ipairs({ "north", "south", "west", "east" }) do
    local conn = root.connections and root.connections[dir]
    local id = conn and (conn.mapId or conn.map)
    local def = id and maps[id]
    local tileset = def and tilesets[def.tileset]
    if def and tileset and not seen[id] then
      seen[id] = true
      local rec = native[id]
      local ox, oy = rec and tonumber(rec.ox), rec and tonumber(rec.oy)
      if not (ox and oy) then
        local offset = tonumber(conn.offset) or 0
        if dir == "north" then ox, oy = offset * 32, -def.height * 32
        elseif dir == "south" then ox, oy = offset * 32, root.height * 32
        elseif dir == "west" then ox, oy = -def.width * 32, offset * 32
        else ox, oy = root.width * 32, offset * 32 end
      end
      local map = voxelMap(Map.new(def, tileset))
      local attached, err = attachAtlas(world, map)
      if attached then
        out[#out + 1] = { id = id, map = map, ox = ox, oy = oy }
      else
        warnOnce("neighbor:" .. tostring(id), "skipping neighbour " .. tostring(id) .. ": " .. tostring(err))
      end
    end
  end
  return out
end

local function stateFor(world)
  if not (world and world.map and world.player and world.camera) then
    return nil, "Gold world is not ready"
  end
  local posed, poseErr = ensurePlayerPose()
  if not posed then return nil, poseErr end
  local map, err = attachAtlas(world, voxelMap(world.map))
  if not map then return nil, err end
  Bridge.mapId, Bridge.tilesetId = map.id, map.tileset and map.tileset.id

  local entities, seen = {}, {}
  local function add(entity)
    if type(entity) == "table" and not seen[entity] then
      seen[entity] = true
      entities[#entities + 1] = entity
    end
  end
  add(world.player)
  for _, entity in ipairs(world.npcs or {}) do add(entity) end
  for _, entity in ipairs(world.entities or {}) do add(entity) end

  local player = world.player
  local sprite, def = player and player.sprite, player and player.sprite and player.sprite.def
  local poseOk, pose = pcall(function()
    return player and player.pose and player:pose()
  end)
  local textureOk, texture = pcall(function()
    return sprite and sprite.resolveImage and sprite:resolveImage()
  end)
  local meshOk, mesh = pcall(function()
    return def and def.image and SpriteBillboards.mesh(def, 0)
  end)
  Bridge.playerCard = {
    inEntities = seen[player] == true,
    hasSprite = sprite ~= nil,
    image = def and def.image or nil,
    pose = poseOk and pose ~= nil,
    texture = textureOk and texture ~= nil,
    mesh = meshOk and mesh ~= nil,
    error = (not poseOk and tostring(pose))
      or (not textureOk and tostring(texture))
      or (not meshOk and tostring(mesh)) or nil,
  }

  return {
    map = map,
    camera = world.camera,
    player = world.player,
    entities = entities,
    neighbors = directNeighbors(world),
    ghosts = {},
  }
end

local function masksFor(neighbors)
  local masks = {}
  for _, neighbor in ipairs(neighbors or {}) do
    local map = neighbor.map
    if map and map.def then
      masks[#masks + 1] = {
        neighbor.ox, neighbor.oy,
        neighbor.ox + map.def.width * 32,
        neighbor.oy + map.def.height * 32,
      }
    end
  end
  return masks
end

local function targetLevel(world)
  local options = world and world.game and world.game.save and world.game.save.options
  local level = options and options.pipelines and tonumber(options.pipelines.voxel)
  if not level or level < 1 then return 3 end
  return math.max(1, math.min(Voxel.MAX_LEVEL, math.floor(level)))
end

local function renderFrame(world, ctx)
  if not Voxel3D.available() then return nil, "3D canvases/shaders are unavailable" end
  local state, err = stateFor(world)
  if not state then return nil, err end

  -- Gold reaches this renderer only from its composition phase; unlike the
  -- Gen 1 pipeline there is no earlier world-update slot that can hide a cold
  -- asynchronous build.  Prime each newly entered map once so the first
  -- visible Gold frame has either terrain or a concrete failure to report.
  if Bridge.primedMapId ~= state.map.id then
    Bridge.primedMapId = state.map.id
    local ok, mesh = pcall(ChunkMesher.get, state.map, false,
                           masksFor(state.neighbors))
    if not ok then return nil, "initial Gold mesh build failed: " .. tostring(mesh) end
    if not mesh then return nil, "initial Gold mesh build produced no terrain" end
  end
  Bridge.terrainReady = ChunkMesher.peek(state.map, false) ~= nil

  local level = targetLevel(world)
  Voxel.setLevel(level)
  Voxel.update(1 / 60, level)
  ChunkMesher.pump(false)

  local pw, ph = tonumber(ctx.pw), tonumber(ctx.ph)
  if not (pw and ph and pw > 0 and ph > 0) then pw, ph = love.graphics.getDimensions() end
  -- World:draw has already selected these exact dimensions before
  -- render.compose runs. Recomputing them from physical canvas pixels changes
  -- the centre by a pixel (and by an entire DPI ratio on Retina) when survey
  -- zoom changes, while Gold's Camera was followed for `viewW/viewH`. That is
  -- the side-slip seen when zooming out.
  local vw, vh = tonumber(world.viewW), tonumber(world.viewH)
  if not (vw and vh and vw > 0 and vh > 0) then
    local scale = type(world.zoomScale) == "function" and world:zoomScale() or 1
    vw, vh = math.max(1, math.ceil(pw / scale)), math.max(1, math.ceil(ph / scale))
  end
  if world.camera and world.player then
    Bridge.cameraView = {
      width = vw, height = vh, cameraX = world.camera.x, cameraY = world.camera.y,
      centerX = world.camera.x + vw / 2, centerY = world.camera.y + vh / 2,
      expectedX = world.player.px + 16, expectedY = world.player.py + 8,
    }
  end
  local canvas = VoxelScene.render(state, pw, ph, vw, vh, nil)
  Bridge.terrainReady = ChunkMesher.peek(state.map, false) ~= nil
  if not canvas then Bridge.meshPending = Bridge.meshPending + 1 end
  ChunkMesher.pump(false)
  return canvas
end

local function drawFull(canvas, ctx)
  local width, height = tonumber(ctx.ww), tonumber(ctx.wh)
  if not (width and height) then width, height = love.graphics.getDimensions() end
  local cw, ch = canvas:getDimensions()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(canvas, 0, 0, 0, width / cw, height / ch)
  return true
end

-- Gold's overworld and its stack UI normally end up in one scene canvas.
-- Once we replace that canvas with the voxel world, drawing the pre-composed
-- scene would put the original 2D terrain back.  Mirror Game2:drawScene's
-- live-overworld branch instead: draw the voxel world at its own scale, then
-- draw only the active stack at Gold's fixed 160x144 UI scale.
local function drawOverlayStack(game, world, ctx)
  local stack = game and game.stack
  if not (stack and stack.top and stack:top()) then return true, 0 end
  if not (world and world.fitScale and stack.draw) then
    return false, 0, "Gold overlay stack is unavailable"
  end
  local ww, wh = tonumber(ctx.ww), tonumber(ctx.wh)
  if not (ww and wh and ww > 0 and wh > 0) then ww, wh = love.graphics.getDimensions() end
  local okScale, scale = pcall(world.fitScale, world)
  scale = okScale and tonumber(scale) or nil
  if not (scale and scale > 0) then return false, 0, "Gold overlay scale is invalid" end
  local count = type(stack.states) == "table" and #stack.states or 1
  local ok, err = pcall(function()
    love.graphics.push("all")
    love.graphics.origin()
    love.graphics.translate(math.floor((ww - 160 * scale) / 2),
                            math.floor((wh - 144 * scale) / 2))
    love.graphics.scale(scale, scale)
    stack:draw()
    love.graphics.pop()
  end)
  if not ok then
    pcall(love.graphics.pop)
    return false, 0, tostring(err)
  end
  return true, count
end

local function drawGoldFrame(canvas, game, world, ctx)
  local ok, drawn, count, overlayErr = pcall(function()
    love.graphics.push("all")
    love.graphics.origin()
    if not drawFull(canvas, ctx) then
      love.graphics.pop()
      return false, 0, "Voxel canvas is unusable"
    end
    local overlaid, states, err = drawOverlayStack(game, world, ctx)
    love.graphics.pop()
    return overlaid, states, err
  end)
  if not ok then
    pcall(love.graphics.pop)
    return false, 0, tostring(drawn)
  end
  return drawn, count, overlayErr
end

-- Gold has one combined scene canvas.  Taking over `render.compose` lets us
-- replace only the live overworld; Game2 still draws HUD chrome after this
-- hook.  While an opaque Gold page is up, ctx.worldActive is false and the
-- native scene remains untouched.
mod.hooks:wrap("render.compose", function(next, game, ctx)
  if game then Workbench.frame(game) end
  if not (ctx and ctx.generation == 2 and ctx.worldActive and game and game.world) then
    return next(game, ctx)
  end
  Bridge.frames = Bridge.frames + 1
  local ok, canvas, err = pcall(renderFrame, game.world, ctx)
  -- pcall places a thrown message in its second result.  Without this
  -- normalization a real Gold adapter fault was reported as a harmless
  -- "mesh pending" frame, which concealed the cause of the overworld crash.
  if not ok then err, canvas = canvas, nil end
  if ok and canvas then
    local drawn, overlayCount, drawErr = drawGoldFrame(canvas, game, game.world, ctx)
    if drawn then
      Bridge.rendered = Bridge.rendered + 1
      if overlayCount and overlayCount > 0 then
        Bridge.overlayFrames = Bridge.overlayFrames + 1
        Bridge.overlayStates = Bridge.overlayStates + overlayCount
      end
      Bridge.lastError = nil
      return true
    end
    err = drawErr
  end
  if ok and not canvas then Bridge.pending = Bridge.pending + 1 end
  Bridge.lastError = tostring(err or "voxel mesh pending")
  warnOnce("frame:" .. Bridge.lastError, Bridge.lastError)
  return next(game, ctx)
end, 1000)

mod.exports.gen2Compatible = true
Workbench.install()
mod.exports.workbenchStatus = Workbench.status
mod.exports.goldBridgeStatus = function()
  return { frames = Bridge.frames, rendered = Bridge.rendered, pending = Bridge.pending,
                 meshPending = Bridge.meshPending, terrainReady = Bridge.terrainReady,
           overlayFrames = Bridge.overlayFrames, overlayStates = Bridge.overlayStates,
           playerCard = Bridge.playerCard,
           buildings = Buildings.stats(),
           buildingDiagnostics = Buildings.diagnostics(Bridge.mapId),
           workbenchCutouts = Structures.workbenchCutoutCount(Bridge.mapId),
           cameraView = Bridge.cameraView,
           mapId = Bridge.mapId, tilesetId = Bridge.tilesetId,
           lastError = Bridge.lastError }
end

if mod.log and mod.log.info then
  mod.log:info("PotatoVoxel Gold bridge installed (render.compose)")
end

return Bridge
