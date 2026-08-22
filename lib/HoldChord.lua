-- Hold-chord timers: press and hold a button for HoldChord.SECONDS to
-- fire a one-shot chord.
--
-- Two chords ship:
--
--   select  five seconds held toggles the debugger -- F9's chord
--           for touch and pads, whose SELECT buttons never arrive as a
--           keypress.
--
--   start   five seconds held exports a one-shot log
--           -- F8's chord, the retrieval half of the same switch pair.
--
-- Each chord is a pure timer over one boolean answer per frame: feed it
-- `held` and it reports one crossing frame, then disarms.  A continued
-- hold does NOT retrigger: the chord stays fired until the button is
-- released (held == false), so one press = one fire even if the input is
-- stuck or held for minutes.  Releasing early aborts the count.  The
-- timer knows nothing about the overlay or the engine: main.lua feeds
-- `held` from the engine's Input and owns the side effect, so every
-- chord stays one switch with its desktop key.

local HoldChord = {}

HoldChord.SECONDS = 5

local heldFor = {}
local armed = {}   -- per chord: false after firing until a release re-arms

-- Advance one chord's timer.  `name` picks the chord; `dt` is the frame
-- time; `held` is whether the button is down this frame.  Returns true
-- on exactly the frame the hold crosses HoldChord.SECONDS, then disarms
-- so a continued hold cannot retrigger (it re-arms only on release).
function HoldChord.update(name, dt, held)
  if not held then
    heldFor[name] = 0
    armed[name] = true
    return false
  end
  if armed[name] == false then return false end
  local acc = (heldFor[name] or 0) + (dt or 0)
  if acc >= HoldChord.SECONDS then
    heldFor[name] = 0
    armed[name] = false
    return true
  end
  heldFor[name] = acc
  return false
end

return HoldChord
