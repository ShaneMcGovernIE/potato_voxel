-- One mobile worker for runtime cache decompression.
--
-- Scoped storage reads and GPU uploads stay on the main thread. Only the
-- one-shot love.data.decompress call crosses this boundary; callers wait from
-- an existing mesh-build coroutine, so gameplay keeps rendering meanwhile.
local V = ...
local Pool = {}

local Diagnostics = V.require("DiagnosticsBridge")

local CMD_CH = "pv_cache_decode_cmd"
local OUT_CH = "pv_cache_decode_out"

local state = {
  started = false,
  failed = false,
  nextId = 1,
  thread = nil,
  pending = {},
  results = {},
}

local function threadApi()
  local ok, api = pcall(function() return love and love.thread end)
  if not ok or not api or not api.getChannel or not api.newThread then
    return nil
  end
  return api
end

local function channel(name)
  local api = threadApi()
  if not api then return nil end
  local ok, value = pcall(api.getChannel, name)
  return ok and value or nil
end

local function platformInfo()
  local ok, Platform = pcall(require, "src.core.Platform")
  if ok and Platform and Platform.detect then
    local okD, value = pcall(Platform.detect)
    if okD and type(value) == "table" then return value end
  end
  return {}
end

local function inCoroutine()
  local co, isMain = coroutine.running()
  return co ~= nil and isMain ~= true
end

function Pool.enabled()
  return not state.failed and platformInfo().mobile == true
     and threadApi() ~= nil
end

function Pool.start()
  if state.started then return true end
  if not Pool.enabled() then return false end
  local root = (V.mod and V.mod.path) or ""
  local spawnPath = root == "" and "workers/cache_decode_worker.lua"
                    or root .. "/workers/cache_decode_worker.lua"
  local ok, worker = pcall(function()
    local api = threadApi()
    local thread, err = api.newThread(spawnPath)
    if not thread and V.mod and V.mod.read then
      local okRead, source = pcall(V.mod.read, V.mod,
                                   "workers/cache_decode_worker.lua")
      if okRead and type(source) == "string" then
        thread, err = api.newThread(source)
      end
    end
    if not thread then error(err or "decode worker unavailable", 0) end
    local okStart, startErr = pcall(thread.start, thread)
    if not okStart then error(startErr, 0) end
    return thread
  end)
  if not ok or not worker then
    state.failed = true
    Diagnostics.warn("cache decode worker unavailable: %s", tostring(worker))
    return false
  end
  state.thread = worker
  state.started = true
  Diagnostics.note("cache decode worker: 1 thread")
  return true
end

local function workerRunning()
  if not state.started or not state.thread then return false end
  if not state.thread.isRunning then return true end
  local ok, running = pcall(state.thread.isRunning, state.thread)
  return ok and running ~= false
end

local function drain()
  local out = channel(OUT_CH)
  if not out then return end
  while true do
    local ok, result = pcall(out.pop, out)
    if not ok or not result then break end
    if result.id and state.pending[result.id] then
      state.results[result.id] = result
    end
  end
end

-- Returns raw, handled. handled=false asks MeshCache to use synchronous
-- decompression because the worker capability was unavailable. handled=true
-- with raw=nil means the payload itself failed validation/decompression.
function Pool.decode(codec, body, rawLength, owner)
  if not inCoroutine() or not Pool.start() then return nil, false end
  local cmd = channel(CMD_CH)
  if not cmd then return nil, false end
  local id = state.nextId
  state.nextId = id + 1
  state.pending[id] = { owner = owner }
  local okPush, pushed = pcall(cmd.push, cmd, {
    cmd = "decode",
    id = id,
    codec = codec,
    body = body,
    rawLength = rawLength,
  })
  if not okPush or pushed == false then
    state.pending[id] = nil
    return nil, false
  end

  while state.pending[id] do
    drain()
    local result = state.results[id]
    if result then
      state.results[id] = nil
      state.pending[id] = nil
      local raw = result.raw
      if result.error or type(raw) ~= "string" or #raw ~= rawLength then
        return nil, true
      end
      return raw, true
    end
    if not workerRunning() then
      state.pending[id] = nil
      state.failed = true
      return nil, false
    end
    coroutine.yield("cache-decode")
  end
  return nil, true
end

function Pool.cancel(owner)
  local cancelled = false
  for id, record in pairs(state.pending) do
    if owner == nil or record.owner == owner then
      state.pending[id] = nil
      state.results[id] = nil
      cancelled = true
    end
  end
  return cancelled
end

function Pool.pending()
  local count = 0
  for _ in pairs(state.pending) do count = count + 1 end
  return count
end

function Pool.shutdown()
  if not state.started then return false end
  local cmd = channel(CMD_CH)
  if cmd then pcall(cmd.push, cmd, { cmd = "quit" }) end
  state.started = false
  state.thread = nil
  state.pending = {}
  state.results = {}
  return true
end

return Pool
