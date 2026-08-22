-- Voxel world mode: falling weather -- rain and snow over the diorama.
--
-- Drops live in WORLD space and are drawn through the same FX overlay
-- seam the field effects use (Voxel3D.project anchors them under the
-- very camera the 3D pass drew with), so they parallax against the
-- terrain exactly like the world does -- and because they are an
-- overlay, they fall IN FRONT of everything, which is where rain is.
-- No geometry risk, no depth writes: the overlay is drawn after the
-- scene is complete.
--
-- One mesh draws the whole field: per drop a thin screen-space streak
-- quad (head + tail positions projected through the camera), stream
-- usage, positions rewritten each frame -- a handful of hundreds of
-- vertices, one draw call. The pool recycles in place: a drop that
-- reaches the ground respawns at the top of the view box, and the pool
-- resizes only when the view size changes.
--
-- Purely presentational: a map's weather is a LOOK, and the WEATHER row
-- (OFF by default, like every costly look-knob) is the only switch.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local ModSetting = V.require("ModSetting")

local Weather = {}

Weather.KEY = "weather"
Weather.LABEL = "WEATHER"

Weather.setting = ModSetting.new(Weather.KEY, Weather.LABEL,
                                 { false, true }, { "OFF", "ON" })

local spec = nil

local function load()
  if spec == nil then
    local ok, s = pcall(V.data, "voxel_weather")
    spec = (ok and type(s) == "table") and s or false
  end
  return spec or nil
end

-- What falls on `map`, or nil: the row on, an entry for the map, and a
-- kind this module knows. A typo in the data file degrades to clear
-- skies, never to a broken field.
function Weather.entryFor(map)
  if not Weather.setting:get() then return nil end
  local s = load()
  local e = s and map and map.id and s[map.id]
  if type(e) ~= "table" then return nil end
  if e.kind ~= "rain" and e.kind ~= "snow" then return nil end
  return e
end

-- the two kinds of weather, as the numbers the field is built from:
-- speed is world pixels per second of fall; drift how far sideways the
-- wind carries a drop; streak the screen-space tail a drop draws;
-- base the world-pixel area one drop wants at density 1.0 (so density
-- is a straight multiplier and the pool is bounded).
local KINDS = {
  rain = { speed = 340, drift = 18, streak = 10, base = 5000,
           color = { 0.72, 0.80, 0.95, 0.35 } },
  snow = { speed = 46, drift = 28, streak = 4, base = 9000,
           color = { 1, 1, 1, 0.65 } },
}

-- How many drops a view this size wants at this density. Bounded both
-- ends: a tiny window never gets a speck, a maximised one never drowns
-- the GE8300 in vertices.
function Weather.dropCount(vw, vh, entry)
  local k = KINDS[entry and entry.kind] or KINDS.rain
  local density = tonumber(entry and entry.density) or 0.5
  local n = math.floor((vw * vh * density) / k.base + 0.5)
  return math.max(40, math.min(220, n))
end

-- One drop's step. Returns true when the drop has reached the ground
-- and the caller should respawn it at the top of the view box. Rain
-- falls straight; snow drifts on a slow sinusoid -- the only state a
-- drop carries is a phase, so the pool stays plain numbers.
function Weather.stepDrop(d, dt, kind, t)
  local k = KINDS[kind] or KINDS.rain
  d.y = d.y - k.speed * dt
  if kind == "snow" then
    d.x = d.x + math.sin(d.phase + t * 0.7) * k.drift * dt
    d.z = d.z + math.cos(d.phase * 1.3 + t * 0.5) * k.drift * 0.4 * dt
  else
    d.x = d.x + math.sin(d.phase) * k.drift * dt
  end
  return d.y <= 0
end

-- ----------------------------------------------------------------- field

local drops = {}
local active = false
local kind = nil
local fieldT = 0
local lastTime = nil
local lastCx, lastCy = nil, nil
local lastVw, lastVh = 0, 0

local clock = (love and love.timer and love.timer.getTime) or os.clock

local MAX_DROPS = 220

-- Advance the field for the frame: read the map's entry, resize the pool
-- when the view changed, step every drop and respawn the ones that
-- landed. A camera TELEPORT (warp, map change) re-seeds the whole field
-- so drops never streak across the screen from the old view. Called once
-- per visible world frame, off the wall clock -- weather keeps falling
-- through menus exactly like the day/night clock does.
function Weather.update(map, cx, cy, vw, vh)
  local entry = Weather.entryFor(map)
  if not entry then
    active = false
    drops = {}
    return
  end
  if math.abs(cx - (lastCx or 0)) > vw or math.abs(cy - (lastCy or 0)) > vh
     or vw ~= lastVw or vh ~= lastVh then
    drops = {}
    lastVw, lastVh = vw, vh
  end
  lastCx, lastCy = cx, cy
  local n = Weather.dropCount(vw, vh, entry)

  local now = clock()
  local dt = math.min(0.1, math.max(0, now - (lastTime or now)))
  lastTime = now
  fieldT = fieldT + dt
  kind = entry.kind

  local margin = 64
  local x0, x1 = cx - vw / 2 - margin, cx + vw / 2 + margin
  local z0, z1 = cy - vh / 2 - margin, cy + vh / 2 + margin
  local yTop = math.max(160, vh * 1.25)
  for i = 1, n do
    local d = drops[i]
    if not d then
      d = { x = x0 + math.random() * (x1 - x0),
            y = math.random() * yTop,
            z = z0 + math.random() * (z1 - z0),
            phase = math.random() * 6.283185307 }
      drops[i] = d
    end
    if Weather.stepDrop(d, dt, kind, fieldT) then
      d.y = yTop
      d.x = x0 + math.random() * (x1 - x0)
      d.z = z0 + math.random() * (z1 - z0)
    end
  end
  for i = #drops, n + 1, -1 do drops[i] = nil end
  active = true
end

-- ------------------------------------------------------------------ draw

local mesh = nil
local indices = nil

local function buildMesh()
  if mesh == nil then
    local ok, made = pcall(love.graphics.newMesh,
                           { { "VertexPosition", "float", 2 } },
                           MAX_DROPS * 4, "triangles", "stream")
    if not (ok and made) then mesh = false return end
    mesh = made
    indices = {}
    local function quad(b)
      indices[#indices + 1] = b + 1
      indices[#indices + 1] = b + 2
      indices[#indices + 1] = b + 3
      indices[#indices + 1] = b + 1
      indices[#indices + 1] = b + 3
      indices[#indices + 1] = b + 4
    end
    for i = 0, MAX_DROPS - 1 do quad(i * 4) end
    pcall(mesh.setVertexMap, mesh, indices)
  end
  return mesh or nil
end

-- Draw the field into the FX overlay: one stream mesh, each drop a thin
-- streak quad between its head and tail projections. `scale` is canvas
-- pixels per display pixel (the overlay's AA / render-scale factor), so
-- a streak is one display pixel wide on screen whatever the canvas is.
-- `project` is Voxel3D.project -- the camera the scene drew with.
function Weather.draw(scale, project)
  if not (active and project) then return end
  local lg = love and love.graphics
  if not (lg and lg.newMesh) then return end
  local n = #drops
  if n == 0 then return end
  local m = buildMesh()
  if not m then return end

  local k = KINDS[kind] or KINDS.rain
  local w = math.max(1, (scale or 1)) * 0.5
  local used = 0
  for i = 1, n do
    local d = drops[i]
    local x0, y0 = project(d.x, d.y, d.z)
    local x1, y1 = project(d.x, d.y + k.streak, d.z)
    if x0 and y0 and x1 and y1 then
      local dx, dy = x1 - x0, y1 - y0
      local len = math.sqrt(dx * dx + dy * dy)
      if len > 0.01 then
        local px, py = -dy / len * w, dx / len * w
        local b = used * 4 + 1
        -- per-vertex writes, not setVertices: this engine's LOVE 11.5
        -- rejects FLAT vertex arrays on a vertex-count mesh (it counts
        -- elements as vertices -- see ChunkMesher's upload header), and
        -- a silently rejected upload is a field of zero-vertex quads
        local ok = pcall(function()
          m:setVertex(b, x0 + px, y0 + py)
          m:setVertex(b + 1, x0 - px, y0 - py)
          m:setVertex(b + 2, x1 - px, y1 - py)
          m:setVertex(b + 3, x1 + px, y1 + py)
        end)
        if ok then used = used + 1 end
      end
    end
  end
  if used == 0 then return end

  local prevColor = { lg.getColor() }
  lg.setColor(k.color[1], k.color[2], k.color[3], k.color[4])
  if not pcall(m.setVertexCount, m, used * 4) then return end
  lg.draw(m)
  lg.setColor(prevColor[1], prevColor[2], prevColor[3], prevColor[4])
end

-- Drop the mesh (window resize, hot reload), the field, and the cached
-- profile -- all three belong to a context or a load that may no longer
-- be the one in front of the player.
function Weather.invalidate()
  if mesh and mesh ~= false and mesh.release then
    pcall(mesh.release, mesh)
  end
  mesh, indices = nil, nil
  drops = {}
  active = false
  spec = nil
end

return Weather
