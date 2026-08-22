-- Voxel world mode: the cooperative build budget.
--
-- Mesh building runs inside a plain coroutine that ChunkMesher pumps for
-- a few milliseconds a frame (there is no worker thread: LOVE's graphics
-- objects are main-thread only, and the build is pure Lua that slices
-- cleanly). The long loops in Structures and ChunkMesher call tick() as
-- they go; when the frame's slice is spent, tick() suspends the build
-- coroutine and the frame carries on rendering whatever is already
-- cached.
--
-- tick() is deliberately safe to call from ANY context: outside the pump
-- (headless tests, the pure geometry API, a driver poking a build
-- function directly) it recognises it is not inside the build coroutine
-- and does nothing, so synchronous callers keep their synchronous
-- behavior.

local B = { n = 0 }

local clock = (love and love.timer and love.timer.getTime) or os.clock

local deadline = math.huge
local buildCo = nil

-- Enter/leave a pumped slice. `co` is the coroutine being resumed, so
-- tick() can tell the build apart from any other coroutine the engine
-- happens to be running (drivers are coroutines too).
function B.begin(co, seconds)
  buildCo = co
  deadline = clock() + seconds
end

function B.finish()
  buildCo = nil
  deadline = math.huge
end

function B.expired()
  return clock() > deadline
end

local tickCounter = 0

function B.tick()
  if not buildCo then return end
  tickCounter = tickCounter + 1
  if tickCounter >= 8 then
    tickCounter = 0
    if coroutine.running() == buildCo and clock() > deadline then
      coroutine.yield("budget")
    end
  end
end

function B.check()
  if not buildCo then return end
  if coroutine.running() == buildCo and clock() > deadline then
    coroutine.yield("budget")
  end
end

-- Whether the current call is inside the pumped build coroutine: the
-- same read can cost 300ms there (sliced, not a hitch) or synchronously
-- on the entry frame (a real freeze), and a support log needs to tell
-- them apart.
function B.inBuild()
  return buildCo ~= nil and coroutine.running() == buildCo
end

return B
