-- Focused cache rewrite contracts that do not need a LÖVE window.
local function check(condition, message)
  if not condition then error(message, 0) end
end

local WorkerAtlas = assert(loadfile("lib/WorkerAtlas.lua"))()
local GeometryStream = assert(loadfile("lib/GeometryStream.lua"))()
local GeometryBuilder = assert(loadfile("lib/GeometryBuilder.lua"))({
  require = function()
    return {}
  end,
})
local GeometryProfile = assert(loadfile("lib/GeometryProfile.lua"))()
local GeometrySnapshot = assert(loadfile("lib/GeometrySnapshot.lua"))()
local CacheArtifact = assert(loadfile("lib/CacheArtifact.lua"))()
local CacheManifest = assert(loadfile("lib/CacheManifest.lua"))()
local AtlasLiveSet = assert(loadfile("lib/AtlasLiveSet.lua"))()
local AtlasPrewarmPolicy = assert(loadfile("lib/AtlasPrewarmPolicy.lua"))()

do
  local retained, previous = AtlasLiveSet.advance({ ROUTE_1 = true }, nil)
  check(retained.ROUTE_1 and previous.ROUTE_1,
        "first live atlas set must retain current route")
  retained, previous = AtlasLiveSet.advance({ ROUTE_2 = true }, previous)
  check(retained.ROUTE_1 and retained.ROUTE_2,
        "route crossing must retain prior atlas through handoff")
  retained = AtlasLiveSet.advance({ ROUTE_3 = true }, previous)
  check(not retained.ROUTE_1 and retained.ROUTE_2 and retained.ROUTE_3,
        "atlas retention must cap lifetime to current and prior live sets")
end

do
  local current = { id = "CURRENT" }
  local direct = { id = "DIRECT" }
  local distant = { id = "DISTANT" }
  local maps = AtlasPrewarmPolicy.maps(current, {
    { map = direct }, { map = current }, { map = distant },
  })
  check(#maps == 1 and maps[1] == current,
        "atlas prewarm must prime only the destination map")
end

do
  local savedAssets = package.loaded["src.render.Assets"]
  local savedRenderer = package.loaded["src.render.TileRenderer"]
  local savedPalette = package.loaded["src.render.PaletteFX"]
  package.loaded["src.render.Assets"] = { register = function() end }
  package.loaded["src.render.TileRenderer"] = {}
  package.loaded["src.render.PaletteFX"] = {}
  local TerrainAtlas = assert(loadfile("lib/TerrainAtlas.lua"))({
    require = function(name)
      if name == "AtlasLiveSet" then return AtlasLiveSet end
      if name == "DiagnosticsBridge" then
        return { count = function() end, trace = function() end }
      end
      error("unexpected atlas dependency: " .. tostring(name))
    end,
  })
  local staticMap = {
    id = "STATIC", renderer = { image = {} },
    tileset = { image = "tiles/static.png", animatedTiles = {} },
  }
  TerrainAtlas.forMap(staticMap, nil)
  TerrainAtlas.forMap(staticMap, nil)
  check(TerrainAtlas.metrics().fallbacks == 0,
        "non-animated atlas is healthy and must not count as a fallback")
  package.loaded["src.render.Assets"] = savedAssets
  package.loaded["src.render.TileRenderer"] = savedRenderer
  package.loaded["src.render.PaletteFX"] = savedPalette
end

do
  -- The live Brick profile is applied by main.lua, which worker VMs never
  -- execute. Every worker job must therefore carry and apply the live
  -- geometry switches; otherwise cache reloads replace billboard trees
  -- with the default carved voxel hulls after map eviction.
  local live = {
    ROUND_RING = 12,
    HULL_BILLBOARDS = true,
    BILLBOARD_CROSS = true,
  }
  local snapshot = GeometryProfile.capture(live)
  local worker = {
    ROUND_RING = 4,
    HULL_BILLBOARDS = false,
    BILLBOARD_CROSS = false,
  }
  check(GeometryProfile.apply(worker, snapshot),
        "worker geometry profile must accept a live snapshot")
  check(worker.ROUND_RING == live.ROUND_RING
        and worker.HULL_BILLBOARDS == live.HULL_BILLBOARDS
        and worker.BILLBOARD_CROSS == live.BILLBOARD_CROSS,
        "worker geometry must match the live sprite-stack profile")

  local prebuildFile = assert(io.open("lib/CachePrebuild.lua", "rb"))
  local prebuildSource = prebuildFile:read("*a") or ""
  prebuildFile:close()
  check(prebuildSource:find("GeometryProfile.capture(Structures)", 1, true),
        "prebuild jobs must capture the live geometry profile")

  local workerFile = assert(io.open("workers/geometry_worker.lua", "rb"))
  local workerSource = workerFile:read("*a") or ""
  workerFile:close()
  local profileApply = assert(workerSource:find(
    "GeometryProfile.apply(Structures, cmd.geometryProfile)", 1, true),
    "worker must apply the captured geometry profile")
  local geometryBuild = assert(workerSource:find(
    "ChunkMesher.buildGeometryPairChunkData", 1, true),
    "worker pair build missing")
  check(profileApply < geometryBuild,
        "worker must apply the live profile before building geometry")
end

do
  local file = assert(io.open("workers/geometry_worker.lua", "rb"))
  local source = file:read("*a") or ""
  file:close()
  local rootSet = assert(source:find("root = nextRoot", 1, true),
                        "worker must set its per-job mod root")
  local atlasLoad = assert(source:find('WorkerAtlas = V.require("WorkerAtlas")',
                                         1, true),
                           "worker must load its atlas dependency")
  check(atlasLoad > rootSet,
        "worker atlas must load after the per-job mod root is set")
  check(not source:find('local WorkerAtlas = V.require("WorkerAtlas")',
                        1, true),
        "worker must not load atlas from the engine root at startup")
end

do
  local calls = {}
  local atlas = WorkerAtlas.new(function(path, root)
    calls[#calls + 1] = { path = path, root = root }
    return { path = path, root = root }
  end)

  local first = atlas:get("tiles/overworld.png", "mods/potato_voxel")
  local repeatImage = atlas:get("tiles/overworld.png", "mods/potato_voxel")
  check(first == repeatImage, "same worker atlas path must reuse image")
  check(#calls == 1, "same worker atlas path must load once")

  local otherPath = atlas:get("tiles/interior.png", "mods/potato_voxel")
  check(otherPath.path == "tiles/interior.png",
        "different tileset path must return its own image")
  check(#calls == 2, "different tileset path must load separately")

  local otherRoot = atlas:get("tiles/overworld.png", "mods/other")
  check(otherRoot.root == "mods/other",
        "different worker root must not reuse prior image")
  check(#calls == 3, "different worker root must load separately")

  atlas:clear()
  atlas:get("tiles/overworld.png", "mods/potato_voxel")
  check(#calls == 4, "cleared worker atlas must reload image")
  local image = {
    getWidth = function() return 128 end,
    getHeight = function() return 48 end,
  }
  check(WorkerAtlas.dimensionsMatch(image, 128, 48),
        "worker atlas must accept matching dimensions")
  check(not WorkerAtlas.dimensionsMatch(image, 256, 48),
        "worker atlas must reject stale dimensions")
end

do
  local writer = GeometryStream.Writer.new("body", 4, 6)
  for i = 1, 4 do
    writer:pushVertex(i, i + 1, i + 2, 0.1, 0.2, 1)
  end
  for i = 1, 6 do writer:pushIndex(i) end
  check(writer:full(), "writer must expose its vertex bound")
  check(writer:vertexCount() == 4, "writer must track scalar vertices")
  check(writer:indexCount() == 6, "writer must track scalar indices")
  local first = writer:flush()
  check(first.vertexCount == 4 and first.indexCount == 6,
        "flush must report bounded stream counts")
  check(type(first.bytes) == "string" and not first.bytes:find("table:"),
        "flush must return packed bytes, not nested Lua tables")
  local decoded = GeometryStream.decode(first)
  check(decoded and decoded.n == 4 and decoded.m == 6,
        "packed chunk must decode with original counts")
  check(decoded.buf[1] == 1 and decoded.buf[6] == 1,
        "packed chunk must retain first vertex values")
  check(decoded.idx[1] == 1 and decoded.idx[6] == 6,
        "packed chunk must retain quad indices")
  local raw = GeometryStream.toPayload({ chunks = { first }, n = 4, m = 6 })
  check(type(raw) == "string" and #raw == 4 + 4 * 24 + 4 + 6 * 4,
        "chunks must convert to native cache bytes without vertex tables")
  local info = GeometryStream.inspectPayload(raw)
  check(info and info.n == 4 and info.m == 6
        and info.vertexBytes == 4 * 24 and info.indexBytes == 6 * 4,
        "runtime upload must validate native vertex and index regions")
  local vertexBytes = GeometryStream.payloadVertexBytes(raw, info)
  check(type(vertexBytes) == "string" and #vertexBytes == 4 * 24,
        "runtime upload must expose GPU-ready vertex bytes")
  local indexBytes = GeometryStream.payloadIndexBytes(raw, info)
  check(type(indexBytes) == "string" and #indexBytes == 6 * 4,
        "runtime upload must expose zero-based uint32 index bytes")
  local joined = raw .. raw
  local firstInfo = GeometryStream.inspectPayloadAt(joined, 1)
  local secondInfo = firstInfo
                     and GeometryStream.inspectPayloadAt(joined,
                                                         firstInfo.nextOffset)
  check(firstInfo and firstInfo.byteLength == #raw
          and firstInfo.nextOffset == #raw + 1
          and secondInfo and secondInfo.byteLength == #raw
          and secondInfo.nextOffset == #joined + 1,
        "aux parser must inspect adjacent indexed records without decoding")
  local rows = GeometryStream.payloadRows(raw, 2, 2, info)
  check(#rows == 2 and rows[1][1] == 2 and rows[2][1] == 3,
        "runtime upload must decode only the requested vertex row slice")
  local indices = GeometryStream.payloadIndices(raw, info)
  check(#indices == 6 and indices[1] == 1 and indices[6] == 6,
        "runtime upload must decode one complete 1-based vertex map")

  local largeWriter = GeometryStream.Writer.new("runtime", 9000, 1)
  for i = 1, 8200 do
    largeWriter:pushVertex(i, i + 1, i + 2, 0.1, 0.2, 1)
  end
  local largeChunk = largeWriter:flush()
  local largeRaw = GeometryStream.toPayload({ chunks = { largeChunk },
                                               n = 8200, m = 0 })
  local oldLove = _G.love
  local uploaded
  _G.love = {
    data = {
      newByteData = function(bytes)
        return { kind = "ByteData", bytes = bytes }
      end,
    },
    graphics = {
      newMesh = function(format, source, drawMode, usage)
        uploaded = {
          format = format,
          source = source,
          drawMode = drawMode,
          usage = usage,
          vertexCalls = {},
          vertexMapCalls = 0,
        }
        function uploaded.setVertices(_, slice, start)
          uploaded.vertexCalls[#uploaded.vertexCalls + 1] = {
            count = #slice, start = start,
            firstX = slice[1] and slice[1][1],
          }
        end
        function uploaded.setVertexMap(_, map, indexType, indexCount)
          uploaded.vertexMapCalls = uploaded.vertexMapCalls + 1
          uploaded.lastVertexMap = {
            map = map, indexType = indexType, indexCount = indexCount,
          }
        end
        function uploaded.release() end
        return uploaded
      end,
    },
  }
  local runtimeV = {
    require = function(name)
      if name == "Voxel3D" then return { FORMAT = {} } end
      if name == "BuildBudget" then return { check = function() end } end
      if name == "GeometryStream" then return GeometryStream end
      error("unexpected runtime dependency: " .. tostring(name))
    end,
  }
  local MeshRuntime = assert(loadfile("lib/MeshRuntime.lua"))(runtimeV)
  local mesh, stages = MeshRuntime.new().fromData(
    { packed = largeRaw, n = 8200, m = 0 })
  check(mesh == uploaded, "packed runtime data must create a GPU mesh")
  check(stages and type(stages.decodeMs) == "number"
        and stages.decodeMs >= 0
        and type(stages.uploadMs) == "number"
        and stages.uploadMs >= 0,
        "packed runtime upload must report decode and GPU stages separately")
  check(uploaded.source and uploaded.source.kind == "ByteData"
          and uploaded.source.bytes
              == GeometryStream.payloadVertexBytes(largeRaw),
        "v27 runtime must construct the GPU mesh from native vertex bytes")
  check(#uploaded.vertexCalls == 0,
        "v27 runtime must not reconstruct cached vertices as Lua rows")
  check(uploaded.vertexMapCalls == 0,
        "an unindexed packed stream must not upload a vertex map")
  local indexedWriter = GeometryStream.Writer.new("indexed-runtime", 70000, 3)
  for i = 1, 70000 do
    indexedWriter:pushVertex(i, 0, 0, 0, 0, 1)
  end
  indexedWriter:pushIndex(1)
  indexedWriter:pushIndex(35000)
  indexedWriter:pushIndex(70000)
  local indexedRaw = GeometryStream.toPayload({
    chunks = { indexedWriter:flush() }, n = 70000, m = 3,
  })
  local indexedInfo = GeometryStream.inspectPayload(indexedRaw)
  local largeIndexBytes = GeometryStream.payloadIndexBytes(indexedRaw, indexedInfo)
  check(type(largeIndexBytes) == "string" and #largeIndexBytes == 12,
        "large runtime index map must stay packed bytes")
  MeshRuntime.new().fromData({ packed = indexedRaw, n = 70000, m = 3 })
  check(uploaded.source and uploaded.source.kind == "ByteData"
          and uploaded.source.bytes
              == GeometryStream.payloadVertexBytes(indexedRaw, indexedInfo),
        "indexed v27 meshes must also upload native vertex bytes")
  check(#uploaded.vertexCalls == 0,
        "indexed v27 meshes must not use setVertices row slices")
  check(uploaded.vertexMapCalls == 1,
        "large indexed mesh must upload one vertex map")
  check(uploaded.lastVertexMap.map
          and uploaded.lastVertexMap.map.kind == "ByteData"
          and uploaded.lastVertexMap.map.bytes == largeIndexBytes,
        "large runtime index map must avoid a Lua index table")
  check(uploaded.lastVertexMap.indexType == "uint32"
          and uploaded.lastVertexMap.indexCount == 3,
        "large runtime index map must preserve zero-based uint32 values")

  local auxMeshes, auxStages = MeshRuntime.new().fromAux({
    grass = { n = 1, buf = { 0, 0, 0, 0, 0, 1 }, m = 0 },
    figures = {
      { n = 1, buf = { 1, 0, 1, 0, 0, 1 }, m = 0,
        wx = 1, wz = 2, y = 3, w = 4 },
    },
  })
  check(auxMeshes and auxMeshes.grass and #auxMeshes.figures == 1,
        "runtime must materialize cached auxiliary meshes")
  check(auxStages and type(auxStages.decodeMs) == "number"
          and type(auxStages.uploadMs) == "number",
        "runtime aux materialization must report decode and upload stages")
  _G.love = oldLove
  local secondWriter = GeometryStream.Writer.new("body", 4, 6)
  for i = 1, 4 do
    secondWriter:pushVertex(i, i + 1, i + 2, 0.1, 0.2, 1)
  end
  for i = 1, 6 do secondWriter:pushIndex(i) end
  local repeatChunk = secondWriter:flush()
  check(first.checksum == repeatChunk.checksum,
        "identical packed chunks must have stable checksums")
  check(first.sequence == 1, "first chunk sequence must start at one")
  writer:pushVertex(5, 6, 7, 0.1, 0.2, 1)
  local second = writer:flush()
  check(second.sequence == 2 and second.vertexCount == 1,
        "writer must advance sequence after each bounded flush")
end

do
  local ranges = GeometryBuilder.ringRanges(4, 3, 2)
  local visited = 0
  for rowIndex, row in ipairs(ranges) do
    local ty = rowIndex - 3
    for _, range in ipairs(row) do
      check(range[1] <= range[2], "ring range must be non-empty")
      for tx = range[1], range[2] do
        check(not (tx >= 0 and tx < 4 and ty >= 0 and ty < 3),
              "ring traversal must not scan body cells")
        visited = visited + 1
      end
    end
  end
  check(visited == (4 + 4) * (3 + 4) - 4 * 3,
        "ring traversal must visit only the outer ring")
end

do
  local file = assert(io.open("lib/ChunkMesher.lua", "rb"))
  local source = file:read("*a") or ""
  file:close()
  check(source:find("newStreamSink", 1, true) ~= nil,
        "geometry mesher must expose bounded stream sink")
  check(source:find("buildGeometryChunkData", 1, true) ~= nil,
        "worker geometry path must expose packed chunk data")
end

do
  -- Tree canopies and grey gym bollards must retain their authored round
  -- geometry. `prop` is a per-pixel slab and is the wrong renderer here.
  local profile = assert(loadfile("data/voxel_heights.lua"))()
  local TileShape = assert(loadfile("lib/TileShape.lua"))({
    data = function(name)
      return name == "voxel_heights" and profile or nil
    end,
  })
  local function mapFor(id)
    return {
      tileset = {
        id = id, imageWidth = 128, imageHeight = 48,
        tilesPerRow = 16, blocks = {}, animatedTiles = {},
      },
      walkable = {}, waterTiles = {},
    }
  end
  local overworld = TileShape.forMap(mapFor("OVERWORLD"))
  check(overworld[42].class == "cylinder"
        and overworld[42].art == "cylinder",
        "tree canopy must resolve to round sprite geometry")
  check(overworld[14].class == "post"
        and overworld[14].art == "post",
        "grey fence post must retain post geometry")
  local gym = TileShape.forMap(mapFor("GYM"))
  check(gym[11].class == "can" and gym[11].art == "cylinder",
        "grey gym bollard must resolve to can geometry")
  check(profile.tilesets.GYM.can_cap == 9
        and profile.tilesets.GYM.can_base == 4
        and profile.tilesets.GYM.can_height == 9
        and profile.tilesets.GYM.can_well == 5
        and profile.tilesets.GYM.can_taper == 4,
        "grey gym bollard must retain its authored can profile")
end

do
  local map = {
    id = "Route1",
    def = {
      width = 2, height = 3, tileset = "OVERWORLD", outdoor = true,
      borderBlock = 15, blocks = { 1, 2, 3, 4, 5, 6 },
    },
    tileset = {
      id = "OVERWORLD", image = "tiles/overworld.png", tilesPerRow = 16,
      imageWidth = 128, imageHeight = 48, blocks = { { 0 } },
      walkable = { [0] = true }, doorTiles = { [1] = true },
    },
    walkable = { [0] = true },
    waterTiles = { [2] = true },
    doorTiles = { [1] = true },
    renderer = function() error("must not be serialized") end,
  }
  local snapshot = GeometrySnapshot.fromMap(map, { { 0, 0, 8, 8 } }, "trees")
  check(snapshot.id == "Route1" and snapshot.def.outdoor == true,
        "snapshot must retain geometry identity")
  check(snapshot.renderer == nil and snapshot.def.blocks[6] == 6,
        "snapshot must omit renderer and retain compact map data")
  local source = GeometrySnapshot.toSource(snapshot)
  check(not source:find("renderer") and not source:find("function"),
        "snapshot source must contain no runtime references")

  local workerV = {
    require = function(name)
      if name == "MeshCache" then return { GEOMETRY_VERSION = 19 } end
      if name == "ChunkMesher" then return {} end
      if name == "DiagnosticsBridge" then
        return { note = function() end, warn = function() end }
      end
      if name == "GeometrySnapshot" then return GeometrySnapshot end
      error("unexpected worker dependency: " .. tostring(name))
    end,
    mod = {},
  }
  local WorkerPool = assert(loadfile("lib/WorkerPool.lua"))(workerV)
  check(WorkerPool.MAX_IN_FLIGHT_CHUNKS == 4,
        "worker pool must expose a bounded in-flight limit")
  check(type(WorkerPool.cancel) == "function"
        and type(WorkerPool.ack) == "function"
        and type(WorkerPool.stalled) == "function",
        "worker pool must expose cancellation, chunk ACK, and heartbeat checks")
  local workerSource = WorkerPool.serializeMap(map)
  check(workerSource:find("PVGS1") ~= nil,
        "worker serialization must use compact geometry snapshots")

  local workerFile = assert(io.open("workers/geometry_worker.lua", "rb"))
  local workerText = workerFile:read("*a") or ""
  workerFile:close()
  check(workerText:find('kind = "chunk"', 1, true) ~= nil
        and workerText:find("waitChunkAck", 1, true) ~= nil,
        "geometry worker must stream chunks behind acknowledgements")
  local cacheFile = assert(io.open("lib/MeshCache.lua", "rb"))
  local cacheText = cacheFile:read("*a") or ""
  cacheFile:close()
  check(cacheText:find("saveTerrainChunks", 1, true) ~= nil
        and cacheText:find("saveWaterChunks", 1, true) ~= nil,
        "cache must accept packed chunks without float-table expansion")
end

do
  local oldLove = _G.love
  local oldPlatform = package.loaded["src.core.Platform"]
  _G.love = { thread = {} }
  package.loaded["src.core.Platform"] = {
    detect = function() return { mobile = true } end,
  }
  local V = {
    require = function(name)
      if name == "MeshCache" then return { GEOMETRY_VERSION = 27 } end
      if name == "ChunkMesher" or name == "GeometrySnapshot" then return {} end
      if name == "DiagnosticsBridge" then
        return { note = function() end, warn = function() end }
      end
      if name == "Brick" then
        return { isBrick = function() return false end }
      end
      error("unexpected worker dependency: " .. tostring(name))
    end,
    mod = {},
  }
  local mobilePool = assert(loadfile("lib/WorkerPool.lua"))(V)
  check(not mobilePool.enabled(),
        "mobile geometry workers must stay disabled")
  check(mobilePool.workerCount() == 0,
        "mobile geometry worker count must be zero")
  package.loaded["src.core.Platform"] = oldPlatform
  _G.love = oldLove
end

do
  -- A thread can exit before posting a result.  The pool must mark that
  -- capability failed so the prebuilder records an explicit serial fallback
  -- instead of silently continuing as if workers were still available.
  local oldLove = _G.love
  local fakeChannels = {}
  local fakeThreads = {}
  local function channel(name)
    local existing = fakeChannels[name]
    if existing then return existing end
    local queue = {}
    existing = {
      push = function(_, value) queue[#queue + 1] = value end,
      pop = function()
        if #queue == 0 then return nil end
        local value = table.remove(queue, 1)
        return value
      end,
    }
    fakeChannels[name] = existing
    return existing
  end
  _G.love = {
    thread = {
      getChannel = channel,
      newThread = function()
        local thread = { dead = false }
        function thread:start() return true end
        function thread:isRunning() return not self.dead end
        function thread:join() return true end
        fakeThreads[#fakeThreads + 1] = thread
        return thread
      end,
    },
    timer = { getTime = function() return 0 end },
  }
  local workerV = {
    require = function(name)
      if name == "MeshCache" then return { GEOMETRY_VERSION = 19 } end
      if name == "ChunkMesher" then return {} end
      if name == "GeometrySnapshot" then return {} end
      if name == "DiagnosticsBridge" then
        return { note = function() end, warn = function() end,
                 error = function() end }
      end
      if name == "Brick" then
        return { isBrick = function() return false end }
      end
      error("unexpected worker dependency: " .. tostring(name))
    end,
    mod = {},
  }
  local deadPool = assert(loadfile("lib/WorkerPool.lua"))(workerV)
  deadPool.start()
  check(deadPool.working(), "fake worker pool starts before exit")
  for _, thread in ipairs(fakeThreads) do thread.dead = true end
  deadPool.poll()
  check(not deadPool.enabled(),
        "unexpected worker exit disables threaded mode explicitly")
  _G.love = oldLove
end

do
  local values = {}
  local storage = {
    writeBytes = function(_, _, key, bytes) values[key] = bytes; return true end,
    readBytes = function(_, _, key) return values[key] end,
    writeTable = function(_, _, key, value) values[key] = value; return true end,
    readTable = function(_, _, key) return values[key] end,
  }
  local artifact = CacheArtifact.new({
    writeBytes = function(key, bytes) return storage:writeBytes(nil, key, bytes) end,
    readBytes = function(key) return storage:readBytes(nil, key) end,
    writeTable = function(key, value) return storage:writeTable(nil, key, value) end,
    readTable = function(key) return storage:readTable(nil, key) end,
  })
  local a = artifact:begin("Route1", "PVMC2-test")
  local body = { kind = "body", sequence = 1, bytes = "body" }
  local ring = { kind = "ring", sequence = 1, bytes = "ring" }
  local aux = { kind = "aux", sequence = 1, bytes = "aux" }
  artifact:append(a, body.kind, body)
  artifact:append(a, ring.kind, ring)
  artifact:append(a, aux.kind, aux)
  check(not artifact:append(a, "aux", { sequence = 2, bytes = "aux2" }),
        "aux stream must be stored once per map artifact")
  check(artifact:commit(a), "complete artifact must commit")
  local opened = artifact:open("Route1", "PVMC2-test")
  check(opened ~= nil and opened.committed,
        "committed artifact must reopen")
  values[opened.chunks["body/1"].key] = "corrupt"
  local missing, reason = artifact:open("Route1", "PVMC2-test")
  check(missing == nil and reason == "checksum",
        "checksum mismatch must reject artifact")

  local incomplete = artifact:begin("Incomplete", "PVMC2-test")
  check(artifact:append(incomplete, "body",
                        { sequence = 1, bytes = "body" }) ~= false,
        "partial artifact accepts durable chunks")
  check(not artifact:commit(incomplete),
        "partial artifact must not commit without required streams")
  local unopened, incompleteReason = artifact:open("Incomplete", "PVMC2-test")
  check(unopened == nil and incompleteReason == "uncommitted",
        "interrupted artifact must remain unreadable")
end

do
  local values = {
    manifest = { format = "PVMC1", identity = "old" },
  }
  local ctx = {
    available = function() return true end,
    identity = function() return "new" end,
    readTable = function(key) return values[key] end,
    writeTable = function(key, value) values[key] = value; return true end,
  }
  local manifest = CacheManifest.new(ctx)
  local old, reason = manifest.read()
  check(old == nil and reason == "format",
        "PVMC1 manifest must be rejected")
  local ok = manifest.write({ ["Route1/body"] = {
    key = "Route1/body", terrain = "artifact/Route1", aux = "artifact/Route1",
  } }, 1, "new")
  check(ok and values.manifest.format == "PVMC2",
        "new manifests must use PVMC2")
end

do
  local deleteResult = false
  local storage = {
    context = function()
      return { playthroughId = "contract-playthrough" }
    end,
    delete = function()
      return deleteResult
    end,
  }
  local V = {
    mod = { storage = storage },
    require = function()
      return {
        count = function() end,
        error = function() end,
        warn = function() end,
      }
    end,
  }
  local CacheStorage = assert(loadfile("lib/CacheStorage.lua"))(V)
  local service = CacheStorage.new()
  check(service:deleteKey("cache/key") == false,
        "deleteKey must return storage failure")
  deleteResult = true
  check(service:deleteKey("cache/key") == true,
        "deleteKey must return storage success")
end

do
  local V = {
    require = function(name)
      if name == "BrickProfile" then
        return { isBrick = function() return false end }
      end
      error("unexpected dependency: " .. tostring(name))
    end,
  }
  local CacheIdentity = assert(loadfile("lib/CacheIdentity.lua"))(V)
  local function makeData()
    return {
      profileRevision = "profile-v1",
      maps = {
        Viridian = {
          width = 2,
          height = 2,
          tileset = "overworld",
          outdoor = true,
          borderBlock = 0,
          blocks = { 1, 2, 3, 4 },
        },
      },
      tilesets = {
        overworld = {
          image = "tiles/overworld.png",
          imageWidth = 128,
          imageHeight = 128,
          tilesPerRow = 16,
          blocks = { 1, 2 },
        },
      },
    }
  end
  local function identityFor(data)
    local service = CacheIdentity.new({ geometryVersion = 19 })
    service.configure(data)
    return service.identity()
  end

  local base = identityFor(makeData())
  local outdoor = makeData()
  outdoor.maps.Viridian.outdoor = false
  check(identityFor(outdoor) ~= base,
        "map outdoor flag must invalidate geometry cache")

  local width = makeData()
  width.tilesets.overworld.imageWidth = 256
  check(identityFor(width) ~= base,
        "tileset image width must invalidate geometry cache")

  local height = makeData()
  height.tilesets.overworld.imageHeight = 256
  check(identityFor(height) ~= base,
        "tileset image height must invalidate geometry cache")

  local profile = makeData()
  profile.profileRevision = "profile-v2"
  check(identityFor(profile) ~= base,
        "authored profile revision must invalidate geometry cache")
end

do
  -- Runtime cache decompression must leave the render thread. The coroutine
  -- submits compressed bytes, yields, then resumes with the worker's raw
  -- payload; map cancellation drops abandoned tickets.
  local oldLove = _G.love
  local oldPlatform = package.loaded["src.core.Platform"]
  local channels = {}
  local function channel(name)
    if channels[name] then return channels[name] end
    local values = {}
    local ch = {
      push = function(_, value) values[#values + 1] = value; return true end,
      pop = function()
        if #values == 0 then return nil end
        return table.remove(values, 1)
      end,
      peek = function() return values[1] end,
    }
    channels[name] = ch
    return ch
  end
  _G.love = {
    thread = {
      getChannel = channel,
      newThread = function()
        return {
          start = function() return true end,
          isRunning = function() return true end,
        }
      end,
    },
  }
  package.loaded["src.core.Platform"] = {
    detect = function() return { mobile = true } end,
  }
  local V = {
    mod = { path = "" },
    require = function(name)
      if name == "DiagnosticsBridge" then
        return { note = function() end, warn = function() end }
      end
      error("unexpected decode dependency: " .. tostring(name))
    end,
  }
  local DecodePool = assert(loadfile("lib/CacheDecodePool.lua"))(V)
  local raw, handled
  local co = coroutine.create(function()
    raw, handled = DecodePool.decode("lz4", "packed", 3, "ROUTE_1")
  end)
  check(coroutine.resume(co) and coroutine.status(co) == "suspended",
        "mobile cache decode must yield while worker runs")
  local command = channels.pv_cache_decode_cmd:peek()
  check(command and command.codec == "lz4" and command.body == "packed",
        "decode worker must receive compressed payload")
  channels.pv_cache_decode_out:push({ id = command.id, raw = "raw" })
  check(coroutine.resume(co) and coroutine.status(co) == "dead",
        "cache decode coroutine must resume after worker result")
  check(handled and raw == "raw",
        "cache decode worker must return raw payload")

  local abandoned = coroutine.create(function()
    DecodePool.decode("lz4", "later", 5, "ROUTE_2")
  end)
  check(coroutine.resume(abandoned), "second decode submits")
  check(DecodePool.cancel("ROUTE_2"),
        "map cancellation must drop abandoned decode tickets")
  check(DecodePool.pending() == 0,
        "cancelled decode tickets must not retain payload ownership")
  package.loaded["src.core.Platform"] = oldPlatform
  _G.love = oldLove
end

print("cache stream contract tests: PASS")
