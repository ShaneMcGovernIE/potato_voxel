-- Shared tile-pattern matcher for authored Structures passes.
--
-- Figures and mounted objects use different builders, but their placement
-- scan is identical: row-major bounded search, packed grid lookup, budget
-- accounting, and exact tile-pattern comparison. Keeping that policy here
-- prevents the two specialist passes from drifting apart.
local V = ...

local Budget = V.require("BuildBudget")
local GridKey = V.require("GridKey")

local StructureMatcher = {}

function StructureMatcher.each(patterns, tileAt, x0, x1, y0, y1, onMatch)
  for _, pattern in ipairs(patterns or {}) do
    for ty = y0, y1 - pattern.h + 1 do
      for tx = x0, x1 - pattern.w + 1 do
        Budget.tick()
        local hit = true
        for i = 1, #pattern.tiles do
          local dx = (i - 1) % pattern.w
          local dy = math.floor((i - 1) / pattern.w)
          if tileAt[GridKey.of(tx + dx, ty + dy)] ~= pattern.tiles[i] then
            hit = false
            break
          end
        end
        if hit then onMatch(pattern, tx, ty) end
      end
    end
  end
end

return StructureMatcher
