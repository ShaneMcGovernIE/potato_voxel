-- Remote diagnostics payload and postLog lifecycle.
--
-- The HUD/overlay owns visibility and local persistence. This module owns
-- only the data envelope, JSON encoding, fire-and-forget handle polling, and
-- the at-least-once ring watermark contract.
local V = ...

local DiagnosticsTransport = {}

function DiagnosticsTransport.new(ctx)
  local store = ctx.store
  local environment = ctx.environment
  local snapshot = ctx.snapshot
  local note = ctx.note
  local trace = ctx.trace
  local clock = ctx.clock
  local PlayerId = V.require("PlayerId")
  local sendHandle = nil
  local sendAt = 0
  local Json = nil

  local function jsonEncode(value)
    if Json == nil then
      local ok, mod = pcall(require, "src.link.Json")
      Json = ok and mod and mod.encode or false
    end
    return Json and Json(value) or nil
  end

  local function payload()
    local id = environment.identityFields()
    local out = {
      schema = 3,
      session = tostring(store.sessionId),
      frame = store.health.frame,
      platform = id.platform,
      engine = id.engine,
      mod = id.mod,
      love = id.love,
      gpu = id.gpu,
      date = os.date("%d_%m_%Y"),
    }
    local pid = PlayerId.get()
    if pid then out.playerId = pid end
    if not store.bootSent and #store.bootLog > 0 then
      out.boot = {}
      for _, line in ipairs(store.bootLog) do out.boot[#out.boot + 1] = line end
    end
    local ring = store.ringDelta()
    if ring then out.ring = ring end
    out.status = snapshot()
    return out
  end

  local transport = {}

  function transport.canSend()
    local mod = V.mod
    return not not (mod and type(mod.postLog) == "function"
                    and mod.manifest and mod.manifest.log_url)
  end

  function transport.pending()
    return sendHandle ~= nil
  end

  function transport.send()
    local mod = V.mod
    if not transport.canSend() then return false end
    local function buildBody(slim)
      local body = payload()
      if slim then
        body.boot = nil
        if body.ring and #body.ring > 200 then
          local kept = {}
          for i = #body.ring - 199, #body.ring do
            kept[#kept + 1] = body.ring[i]
          end
          body.ring = kept
        end
      end
      local encoded = jsonEncode(body)
      if not encoded then
        note("log send failed: JSON encoder unavailable")
        return nil
      end
      return encoded
    end

    local body = buildBody(false)
    if not body then return false end
    local ok, handle, reason = pcall(mod.postLog, mod, body, { format = "text" })
    if not ok or ((not handle) and reason and reason:find("too large")) then
      trace("log send: payload too large for this engine; retrying trimmed")
      body = buildBody(true)
      if not body then return false end
      ok, handle, reason = pcall(mod.postLog, mod, body, { format = "text" })
    end
    if not ok or not handle then
      note("log send failed: %s",
           tostring(handle or reason or "engine rejected the send"))
      return false
    end
    store.bootSent = true
    sendHandle = handle
    sendAt = clock()
    note("log sent to loghook")
    store.lastSentSeq = store.seq
    return true
  end

  function transport.poll()
    local mod = V.mod
    if not (sendHandle and mod and mod.fetch
            and type(mod.fetch.poll) == "function") then
      return
    end
    local ok, status = pcall(mod.fetch.poll, mod.fetch, sendHandle)
    if ok and status and status.status ~= "pending" then
      if status.status == "ok" then
        trace("log send confirmed")
        store.lastSentSeq = store.seq
      else
        note("log send failed: %s", tostring(status.err or status.status))
      end
      pcall(mod.fetch.release, mod.fetch, sendHandle)
      sendHandle = nil
    elseif ok and clock() - sendAt > 40 then
      note("log send timed out after %ds; cancelling",
           math.floor(clock() - sendAt))
      pcall(mod.fetch.cancel, mod.fetch, sendHandle)
      pcall(mod.fetch.release, mod.fetch, sendHandle)
      sendHandle = nil
    elseif not ok then
      note("log send poll failed: %s", tostring(status))
      pcall(mod.fetch.release, mod.fetch, sendHandle)
      sendHandle = nil
    end
  end

  return transport
end

return DiagnosticsTransport
