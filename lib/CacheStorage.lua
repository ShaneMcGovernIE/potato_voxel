-- Scoped storage adapter for MeshCache.
-- Resolves playthrough storage lazily, supports byte/table fallbacks, and
-- keeps storage failures visible without exposing raw filesystem APIs.
local V = ...

local CacheStorage = {}
local Diagnostics = V.require("DiagnosticsBridge")

function CacheStorage.new()
  local store = nil
  local storeSource = nil

  local function liveGame()
    local okR, RuntimeHooks = pcall(function() return V.require("RuntimeHooks") end)
    if okR and RuntimeHooks and RuntimeHooks.liveGame then
      local okG, Game = pcall(RuntimeHooks.liveGame)
      if okG and Game then return Game end
    end
    local mod = V.mod
    if mod then
      local okG, Game = pcall(function() return mod.game end)
      if okG and type(Game) == "table" then return Game end
    end
    local ok, Game = pcall(require, "src.core.Game")
    return ok and Game or nil
  end

  local function resolveStore()
    local mod = V.mod
    if not (mod and mod.storage) then return nil end
    local game = liveGame()
    local ok, ctx = pcall(mod.storage.context, mod.storage, game)
    if not ok or not ctx then
      ok, ctx = pcall(mod.storage.context, mod.storage)
    end
    if ok and ctx then
      if type(ctx) == "table" and (ctx.playthroughId or ctx.playthrough or ctx.saveId or ctx.slot or ctx.id or ctx.save or ctx.engineVersion or next(ctx) ~= nil) then
        return mod.storage
      elseif type(ctx) == "boolean" and ctx then
        return mod.storage
      end
    end
    if mod.storage.selected then
      local okS, selected = pcall(mod.storage.selected, mod.storage, game)
      if not okS or not selected then
        okS, selected = pcall(mod.storage.selected, mod.storage)
      end
      if okS and selected then
        local okC, ctx2 = pcall(selected.context, selected, game)
        if not okC or not ctx2 then
          okC, ctx2 = pcall(selected.context, selected)
        end
        if okC and ctx2 then
          if type(ctx2) == "table" and (ctx2.playthroughId or ctx2.playthrough or ctx2.saveId or ctx2.slot or ctx2.id or ctx2.save or next(ctx2) ~= nil) then
            return selected
          elseif type(ctx2) == "boolean" and ctx2 then
            return selected
          end
        end
      end
    end
    -- A bound facade may not expose context, but the engine-owned root facade
    -- does. Never treat a root facade with a failed context probe as usable:
    -- its write methods would only fail later with not_in_playthrough.
    if type(mod.storage.context) ~= "function"
       and (type(mod.storage.write) == "function"
         or type(mod.storage.writeBytes) == "function") then
      return mod.storage
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
      if level == "warn" then
        Diagnostics.count("storageWarns")
        Diagnostics.warn("storage %s %q: %s (%s)", tostring(op),
                         tostring(key), tostring(code), tostring(message))
      else
        Diagnostics.count("storageFails")
        Diagnostics.error("storage %s %q: %s (%s)", tostring(op),
                          tostring(key), tostring(code), tostring(message))
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
      local ok, data, code, message = pcall(store_.readBytes, store_, game, key)
      if not ok or not data then
        local ok2, data2 = pcall(store_.readBytes, store_, key)
        if ok2 and data2 then return data2 end
      end
      if ok and data then return data end
      callFail("readBytes", key, code, message)
    end
    local ok, data, code, message = pcall(store_.read, store_, game, key)
    if not ok or not data then
      local ok2, data2 = pcall(store_.read, store_, key)
      if ok2 and data2 then data = data2; ok = true end
    end
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
      local ok2, result2 = pcall(store_.writeBytes, store_, key, bytes)
      if ok2 and result2 then return true end
      callFail("writeBytes", key, code, message)
    end
    local ok, result, code, message = pcall(store_.write, store_, game, key,
                                            { bytes = bytes })
    if ok and result then return true end
    local okW, resultW = pcall(store_.write, store_, key, { bytes = bytes })
    if okW and resultW then return true end

    pcall(store_.delete, store_, game, key)
    pcall(store_.delete, store_, key)
    local ok2, result2, code2, message2 = pcall(store_.write, store_, game,
                                                key, { bytes = bytes })
    if not ok2 or not result2 then
      ok2, result2, code2, message2 = pcall(store_.write, store_, key,
                                            { bytes = bytes })
    end
    if not ok2 or not result2 then
      callFail("write", key, code2, message2)
    end
    return ok2 and result2 and true or false
  end

  function service.writeTable(key, value)
    local store_ = facade()
    if not store_ or not store_.write then return false end
    local game = liveGame()
    local ok, result, code, message = pcall(store_.write, store_,
                                            game, key, value)
    if not ok or not result then
      local ok2, result2, code2, message2 = pcall(store_.write, store_,
                                                  key, value)
      if ok2 and result2 then return true end
      callFail("write", key, code or code2, message or message2)
      return false
    end
    return true
  end

  function service.readTable(key)
    local store_ = facade()
    if not store_ or not store_.read then return nil end
    local game = liveGame()
    local ok, data, code, message = pcall(store_.read, store_, game, key)
    if not ok or not data then
      local ok2, data2 = pcall(store_.read, store_, key)
      if ok2 and data2 then return data2 end
      callFail("read", key, code, message)
    end
    return ok and data or nil
  end

  function service.listKeys(prefix)
    local store_ = facade()
    if not store_ or not store_.list then return {} end
    local game = liveGame()
    local ok, keys, code, message = pcall(store_.list, store_, game, prefix)
    if not ok or not keys then
      local ok2, keys2 = pcall(store_.list, store_, prefix)
      if ok2 and keys2 then return keys2 end
      callFail("list", prefix, code, message)
    end
    return (ok and keys) or {}
  end

  function service.deleteKey(key)
    local store_ = facade()
    if not store_ or not store_.delete then return false end
    local game = liveGame()
    local ok, result, code, message = pcall(store_.delete, store_, game, key)
    if not ok or not result then
      local ok2, result2, code2, message2 = pcall(store_.delete, store_, key)
      if ok2 and result2 then return true end
      callFail("delete", key, code or code2, message or message2)
      return false
    end
    return true
  end

  return service
end

return CacheStorage
