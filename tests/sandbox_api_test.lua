-- The shipped mod must not mention APIs removed from the sandbox runtime.
-- This test runs outside the mod sandbox, so it may use the host filesystem
-- to inspect the source tree.

local function exists(path)
  local file = io.open(path, "rb")
  if not file then return false end
  file:close()
  return true
end

local root = exists("manifest.json") and "." or "mods/potato_voxel"
local files = { root .. "/main.lua" }
local listing = assert(io.popen(("find %q/lib %q/data -type f -name '*.lua' | sort")
                              :format(root, root)))
for path in listing:lines() do files[#files + 1] = path end
listing:close()

local forbidden = {
  { "love.filesystem", "love%.filesystem" },
  { "love.system", "love%.system" },
  { "love.event", "love%.event" },
  { "love.mousemoved assignment", "love%.mousemoved%s*=" },
  { "love.mousepressed assignment", "love%.mousepressed%s*=" },
  { "love.mousereleased assignment", "love%.mousereleased%s*=" },
  -- Match io.<fn> as a standalone name. A module such as
  -- src.audio.ChipAsm contains the letters "io." but does not use the
  -- removed io library.
  { "io", function(source)
      return source:find("^io%.") or source:find("[^%w_]io%.")
    end },
  { "os.getenv", "os%.getenv" },
  { "os.execute", "os%.execute" },
  { "os.remove", "os%.remove" },
  { "os.rename", "os%.rename" },
  { "os.exit", "os%.exit" },
  { "os.tmpname", "os%.tmpname" },
  { "debug library", "debug%.[%w_]+" },
  { "ffi require", "require%s*%(%s*[\"']ffi[\"']%s*%)" },
  { "package", "require%s*%(%s*[\"']package[\"']%s*%)" },
  { "dofile", "dofile%s*%(" },
  { "loadfile", "loadfile%s*%(" },
  { "getfenv", "getfenv%s*%(" },
  { "setfenv", "setfenv%s*%(" },
}

local failures = {}
for _, path in ipairs(files) do
  local file = assert(io.open(path, "rb"))
  local source = file:read("*a") or ""
  file:close()
  for _, rule in ipairs(forbidden) do
    local hit
    if type(rule[2]) == "function" then
      hit = rule[2](source)
    else
      hit = source:find(rule[2])
    end
    if hit then
      failures[#failures + 1] = path .. ": contains sandbox-forbidden " .. rule[1]
    end
  end
end

local manifest = assert(io.open(root .. "/manifest.json", "rb"))
local manifestSource = manifest:read("*a") or ""
manifest:close()
if manifestSource:find('"filesystem"') then
  failures[#failures + 1] = root .. "/manifest.json: requests raw filesystem permission"
end
-- love.thread is only reachable under the `compute` permission the
-- engine grants (src/mods/Sandbox.lua), so the mod cannot declare it
-- until that lands -- but its uses must still be safe on engines
-- WITHOUT the grant: every love.thread reference has to sit inside a
-- pcall (the pool then disables itself silently). The worker script
-- itself lives in workers/, which the scan does not ship.
if not manifestSource:find('"compute"') then
  for _, path in ipairs(files) do
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a") or ""
    file:close()
    -- love.thread is only ever legal inside a pcall(function() ... end)
    -- block: track the enclosing body so a multi-line pcall counts as
    -- guarded without parsing Lua.
    local inPcall = false
    for line in source:gmatch("[^\n]+") do
      if line:find("pcall%s*%(") then inPcall = true end
      local code = line:gsub("%-%-.*$", "")
      if code:find("love%.thread")
         and not (code:find("pcall") or inPcall) then
        failures[#failures + 1] = path .. ": unguarded love.thread "
          .. "(must be inside pcall so engines without the "
          .. '"compute" permission disable the pool silently)'
      end
      if line:find("^%s*end%)") then inPcall = false end
    end
  end
end

for _, failure in ipairs(failures) do print("FAIL: " .. failure) end
assert(#failures == 0, "sandbox API scan found " .. #failures .. " violation(s)")
print("sandbox API scan: clean")
