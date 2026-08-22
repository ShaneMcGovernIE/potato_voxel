-- Void-fill change debounce: the OPTIONS row can churn the value faster
-- than a cache can sensibly drop (field log: trees -> water -> trees in
-- 0.7s dropped the whole cache twice). Every tick feeds the live value;
-- a change is held for a one-second settle window, then acted on once --
-- or never, if the value settles back where it started.
--
-- Returns "none" (nothing to do), "hold" (a change is settling), or
-- "invalidate" plus the pre-burst value (the caller drops the cache).
local V = ...
local D = { last = nil, pendingFrom = nil, pendingAt = 0 }

local function clock()
  return love and love.timer and love.timer.getTime
         and love.timer.getTime() or 0
end

function D.tick(now, nowT)
  nowT = nowT or clock()
  if D.last ~= nil and now ~= D.last then
    if D.pendingFrom == nil then D.pendingFrom = D.last end
    D.pendingAt = nowT
  end
  D.last = now
  if D.pendingFrom == nil then return "none" end
  if now == D.pendingFrom then
    D.pendingFrom = nil   -- back where it started: nothing changed
    return "none"
  end
  if nowT - D.pendingAt >= 1 then
    local from = D.pendingFrom
    D.pendingFrom = nil
    return "invalidate", from
  end
  return "hold"
end

-- Re-arm without acting: the value that just landed IS the save's
-- declared value (Game:applyOptions), not a user edit.
function D.reseed(value)
  D.last = value
  D.pendingFrom = nil
end

return D
