-- Scoped storage adapter for MeshCache.
-- Resolves playthrough storage lazily, supports byte/table fallbacks, and
-- keeps storage failures visible without exposing raw filesystem APIs.
local V = ...

local CacheStorage = {}

function CacheStorage.new()
  local store = nil
  local storeSource = nil

  local function liveGame()
    local ok, Game = pcall(require, "src.core.Game")
    return ok and Game or nil
  end

  local function resolveStore()
    local mod = V.mod
    if not (mod and mod.storage) then return nil end
    local game = liveGame()
    local ok, ctx = pcall(mod.storage.context, mod.storage, game)
    if ok and ctx and ctx.playthroughId then
      return mod.storage
    end
    if mod.storage.selected then
      local okS, selected = pcall(mod.storage.selected, mod.storage, game)
      if okS and selected then
        local okC, ctx2 = pcall(selected.context, selected)
        if okC and ctx2 and ctx2.playthroughId then
          return selected
        end
      end
    end
    return nil
  end

  local function facade()
    local mod = V.mod
    local source = mod and mod.storage or nil
    if store and storeSource == source then return store end
    store = resolveStore()
    storeSource = source
    return store
  end

  local function facadeFailed()
    store = nil
  end

  local function callFail(op, key, code, message)
    if code == "not_in_playthrough" or code == "not_at_title" then
      facadeFailed()
    end
    if code ~= nil and code ~= "not_found" then
      local level = (op:find("^read") and code == "invalid_key")
                    and "warn" or "error"
      local okD, Overlay = pcall(V.require, "DebugOverlay")
      if okD and Overlay then
        if level == "warn" then
          Overlay.count("storageWarns")
          Overlay.warn("storage %s %q: %s (%s)", tostring(op),
                       tostring(key), tostring(code), tostring(message))
        else
          Overlay.count("storageFails")
          Overlay.error("storage %s %q: %s (%s)", tostring(op),
                        tostring(key), tostring(code), tostring(message))
        end
      end
    end
    return false
  end

  local service = {}

  function service.available()
    return facade() ~= nil
  end

  function service.dir()
    return facade() and "storage" or nil
  end

  function service.readBytes(key)
    local store_ = facade()
    if not store_ then return nil end
    local game = liveGame()
    if store_.readBytes then
      local ok, data, code, message = pcall(store_.readBytes, store_,
                                            game, key)
      if ok and data then return data end
      callFail("readBytes", key, code, message)
    end
    local ok, data, code, message = pcall(store_.read, store_, game, key)
    if not ok or not data then callFail("read", key, code, message) end
    if type(data) == "table" and data.bytes ~= nil then return data.bytes end
    if type(data) == "string" then return data end
    return nil
  end

  function service.writeBytes(key, bytes)
    local store_ = facade()
    if not store_ then return false end
    local game = liveGame()
    if store_.writeBytes then
      local ok, result, code, message = pcall(store_.writeBytes, store_,
                                              game, key, bytes)
      if ok and result then return true end
      callFail("writeBytes", key, code, message)
    end
    local ok, result, code, message = pcall(store_.write, store_, game, key,
                                            { bytes = bytes })
    if ok and result then return true end
    pcall(store_.delete, store_, game, key)
    local ok2, result2, code2, message2 = pcall(store_.write, store_, game,
                                                key, { bytes = bytes })
    if not ok2 or not result2 then
      callFail("write", key, code2, message2)
    end
    return ok2 and result2 and true or false
  end

  function service.writeTable(key, value)
    local store_ = facade()
    if not store_ or not store_.write then return false end
    local ok, result, code, message = pcall(store_.write, store_,
                                            liveGame(), key, value)
    if not ok or not result then callFail("write", key, code, message) end
    return ok and result and true or false
  end

  function service.readTable(key)
    local store_ = facade()
    if not store_ or not store_.read then return nil end
    local ok, data, code, message = pcall(store_.read, store_, liveGame(), key)
    if not ok or not data then callFail("read", key, code, message) end
    return ok and data or nil
  end

  function service.listKeys(prefix)
    local store_ = facade()
    if not store_ or not store_.list then return {} end
    local ok, keys, code, message = pcall(store_.list, store_, liveGame(),
                                          prefix)
    if not ok then callFail("list", prefix, code, message) end
    return (ok and keys) or {}
  end

  function service.deleteKey(key)
    local store_ = facade()
    if not store_ or not store_.delete then return false end
    return pcall(store_.delete, store_, liveGame(), key)
  end

  return service
end

return CacheStorage
