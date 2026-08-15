local script = debug.getinfo(1, "S").source:gsub("^@", "")
local root = script:match("^(.*)[/\\]tests[/\\][^/\\]+$") or "."
local released, townMapBuilds, townMapDraws = 0, 0, 0
local footer, clearColor

-- Loading state is map-scoped and leaving voxel mode always releases it.
do
  local oldLove = love
  love = { timer = { getTime = function() return 12.5 end } }
  local voxel = assert(loadfile(root .. "/lib/VoxelState.lua"))()
  voxel.beginLoading("PALLET_TOWN")
  assert(voxel.loading and voxel.loadingMap == "PALLET_TOWN")
  assert(voxel.loadingSince == 12.5)
  voxel.finishLoading("ROUTE_1")
  assert(voxel.loading, "another map released the cover")
  voxel.setLevel(0)
  assert(not voxel.loading, "voxel OFF kept the cover")
  love = oldLove
end

local function resource()
  return {
    setFilter = function() end,
    release = function() released = released + 1 end,
  }
end

love = {
  timer = { getTime = function() return 10 end },
  graphics = {
    newCanvas = function() return resource() end,
    newFont = function()
      return {
        getWidth = function(_, text) return #text * 8 end,
        release = function() released = released + 1 end,
      }
    end,
    getFont = function()
      return { getWidth = function(_, text) return #text * 8 end }
    end,
    setCanvas = function() end, setShader = function() end,
    setBlendMode = function() end, setFont = function() end,
    setColor = function() end, setLineWidth = function() end,
    origin = function() end,
    clear = function(...) clearColor = { ... } end,
    rectangle = function() end, print = function() end,
    push = function() end, pop = function() end,
    translate = function() end, scale = function() end,
  },
}

local location = { name = "PALLET TOWN", x = 4, y = 12 }
local view
local Game = { data = {}, save = {},
               overworld = { map = { id = "PALLET_TOWN" } } }

package.preload["src.core.Game"] = function() return Game end
package.preload["src.ui.TownMap"] = function()
  return {
    new = function(game)
      assert(game == Game)
      townMapBuilds = townMapBuilds + 1
      view = {
        mode = "grid",
        bg = {
          img = resource(), cursor = resource(),
          quads = { resource(), resource() },
        },
        byMap = { PALLET_TOWN = location },
        locs = { location },
        draw = function(self)
          assert(self.playerLoc == location)
          townMapDraws = townMapDraws + 1
        end,
      }
      return view
    end,
  }
end
package.preload["src.render.Font"] = function()
  return {
    drawBox = function() end,
    width = function(text) return #text * 8 end,
    draw = function(text) footer = text end,
  }
end

local Voxel = { loadingMap = "PALLET_TOWN", loadingSince = 1 }
local V = {
  require = function(name)
    assert(name == "VoxelState")
    return Voxel
  end,
}
local Loading = assert(loadfile(root .. "/lib/VoxelLoading.lua"))(V)

local first = Loading.draw(1920, 1080, 3)
assert(first, "Town Map cover did not return its canvas")
assert(townMapBuilds == 1 and townMapDraws == 1)
assert(view.sel == 1 and view.playerLoc == location)
assert(type(view.blink) == "number")
assert(footer == "BUILDING VOXELS" or footer == "3 AREAS LEFT")
assert(clearColor[1] == 0 and clearColor[2] == 0
       and clearColor[3] == 0 and clearColor[4] == 1,
       "loading letterbox is not opaque black")

local second = Loading.draw(1920, 1080, 3)
assert(second == first, "loading canvas was needlessly rebuilt")
assert(townMapBuilds == 1 and townMapDraws == 2)

Loading.invalidate()
assert(released == 5, "loading resources were not all released")

print("voxel loading tests: ok")
