-- Gold-specific PotatoVoxel entry point.

local mod = ...

local V = { mod = mod, path = mod.path }
local modules = {}
local dataFiles = {}

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

function V.data(name)
  if dataFiles[name] ~= nil then return dataFiles[name] end
  local rel = "data/" .. name .. ".lua"
  local source = mod:read(rel)
  if not source then error("potato_voxel: missing " .. rel, 0) end
  local chunk, err = load(source, "@" .. mod.path .. "/" .. rel)
  if not chunk then error("potato_voxel: " .. rel .. " did not compile: " .. tostring(err), 0) end
  local value = chunk(V)
  dataFiles[name] = value
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
local BrickProfile = V.require("BrickProfile")
BrickProfile.apply(V)

local VoxelGrid = V.require("VoxelGrid")
local WorldCurve = V.require("WorldCurve")
local OverworldBattle = V.require("OverworldBattle")
local DayNight = V.require("DayNight")
local Water = V.require("Water")
local AntiAlias = V.require("AntiAlias")
local ShadowSettings = V.require("ShadowSettings")
local QualityMode = V.require("QualityMode")
local VR = V.require("VR")
local MapAtmos = V.require("MapAtmos")
local Weather = V.require("Weather")
local SettingsFeature = V.require("SettingsFeature")
local RuntimeHooks = V.require("RuntimeHooks")
local DebugOverlay = V.require("DebugOverlay")
local PlayerId = V.require("PlayerId")
DebugOverlay.install()

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
  map.renderer.gbcAtlas = isColored
  map.renderer.data = world.game and world.game.data or map.renderer.data
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
  local Pipelines = require("src.render.Pipelines")
  local level = Pipelines.level("voxel")
  if not (level and level >= 1) then
    local options = world and world.game and world.game.save and world.game.save.options
    level = options and options.pipelines and tonumber(options.pipelines.voxel)
  end
  level = tonumber(level) or 0
  if level < 1 then return 0 end
  return math.max(1, math.min(Voxel.MAX_LEVEL, math.floor(level)))
end

local function renderFrame(world, ctx)
  if not Voxel3D.available() then return nil, "3D canvases/shaders are unavailable" end
  local state, err = stateFor(world)
  if not state then return nil, err end

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

-- LOVE 12 on iOS/Metal presents this 3D canvas Y-flipped. Gen 1 undoes that
-- when Renderer blits worldOverride (src/render/Renderer.lua); Gold presents
-- through render.compose instead, so the same bottom-origin negative-Y draw
-- belongs here.
local function drawFull(canvas, ctx)
  local width, height = tonumber(ctx.ww), tonumber(ctx.wh)
  if not (width and height) then width, height = love.graphics.getDimensions() end
  local cw, ch = canvas:getDimensions()
  local sx, sy = width / cw, height / ch
  love.graphics.setColor(1, 1, 1, 1)
  local loveMajor = love.getVersion()
  if love.system and love.system.getOS and love.system.getOS() == "iOS" and loveMajor >= 12 then
    love.graphics.draw(canvas, 0, height, 0, sx, -sy)
  else
    love.graphics.draw(canvas, 0, 0, 0, sx, sy)
  end
  return true
end

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

mod.hooks:wrap("render.compose", function(next, game, ctx)
  if game then Workbench.frame(game) end
  if not (ctx and ctx.generation == 2 and ctx.worldActive and game and game.world) then
    return next(game, ctx)
  end
  if targetLevel(game.world) < 1 then
    return next(game, ctx)
  end
  Bridge.frames = Bridge.frames + 1
  local ok, canvas, err = pcall(renderFrame, game.world, ctx)
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

do
  local deferredWork = {}
  local function deferToNextTick(fn)
    if type(fn) == "function" then deferredWork[#deferredWork + 1] = fn end
  end
  RuntimeHooks.wrapOnce(RuntimeHooks.gameOwner(), "update",
    "potatoVoxelGoldDeferHook", function(inner)
      return function(self, dt)
        inner(self, dt)
        if #deferredWork == 0 then return end
        local batch = deferredWork
        deferredWork = {}
        for i = 1, #batch do pcall(batch[i]) end
      end
    end)

  mod.content.render_pipelines:register("voxel", {
    label = "VOXEL",
    levels = Voxel.ANGLE_LABELS,
    hotkey = "8",
    priority = 20,
    available = function()
      return Voxel3D.available()
    end,
    worldPresent = function(canvas) return canvas end,
    update = function(dt, level)
      Voxel.setLevel(level)
      QualityMode.onLevel(level)
      QualityMode.enforce(level)
    end,
  })

  local Settings = SettingsFeature.new({
    mod = mod,
    Voxel = Voxel,
    QualityMode = QualityMode,
    VoxelGrid = VoxelGrid,
    WorldCurve = WorldCurve,
    Water = Water,
    OverworldBattle = OverworldBattle,
    DayNight = DayNight,
    MapAtmos = MapAtmos,
    Weather = Weather,
    AntiAlias = AntiAlias,
    VR = VR,
    ShadowSettings = ShadowSettings,
    DebugOverlay = DebugOverlay,
    stagedBattles = function()
      return OverworldBattle.enabled()
    end,
  })
  local CachePrebuild = V.require("CachePrebuild")
  local MeshCache = V.require("MeshCache")
  local CacheFeature = V.require("CacheFeature")
  local Cache = CacheFeature.new({
    CachePrebuild = CachePrebuild,
    MeshCache = MeshCache,
    DebugOverlay = DebugOverlay,
    PlayerId = PlayerId,
    settingsEntries = Settings.entries,
  })
  Settings.defineSchema()
  PlayerId.ensure()
  DebugOverlay.setSettingsReader(Settings.settingsSummary)
  Settings.installRowsHook({
    Cache = Cache,
    deferToNextTick = deferToNextTick,
  })
  Settings.installMenuRefresh()
  Cache.installLifecycle()
  if mod.events and mod.events.on then
    mod.events:on("game.ready", function(payload)
      local game = payload and payload.game
      if not game then return end
      CachePrebuild.bootstrap(game)
      local Pipelines = require("src.render.Pipelines")
      local opts = (game.save and game.save.options) or game.options
      local stored = opts and opts.pipelines and opts.pipelines.voxel
      if stored == nil and Pipelines.get("voxel")
         and Pipelines.level("voxel") < 1 then
        Pipelines.setLevel("voxel", math.min(3, Voxel.MAX_LEVEL))
        if opts then Pipelines.syncOptions(opts) end
      end
    end)
  end
end
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
