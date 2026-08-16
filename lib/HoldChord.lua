-- Hold-chord timers: press and hold a button for HoldChord.SECONDS to
-- fire a one-shot chord.
--
-- Two chords ship:
--
--   select  five seconds held toggles the debug overlay -- F9's chord
--           for touch and pads, whose SELECT buttons never arrive as a
--           keypress.
--
--   start   five seconds held while the debugger is ON exports its log
--           -- F8's chord, the retrieval half of the same switch pair.
--
-- Each chord is a pure timer over one boolean answer per frame: feed it
-- `held` and it reports one crossing frame, then resets.  Releasing
-- early aborts the count.  The timer knows nothing about the overlay or
-- the engine: main.lua feeds `held` from the engine's Input and owns
-- the side effect, so every chord stays one switch with its desktop key.

local HoldChord = {}

HoldChord.SECONDS = 5

local heldFor = {}

-- Advance one chord's timer.  `name` picks the chord; `dt` is the frame
-- time; `held` is whether the button is down this frame.  Returns true
-- on exactly the frame the hold crosses HoldChord.SECONDS, then resets
-- so a continued hold cannot retrigger.
function HoldChord.update(name, dt, held)
  local acc = heldFor[name] or 0
  if held then
    acc = acc + (dt or 0)
    if acc >= HoldChord.SECONDS then
      heldFor[name] = nil
      return true
    end
  else
    acc = 0
  end
  heldFor[name] = acc
  return false
end

return HoldChord
