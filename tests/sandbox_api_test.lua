-- The shipped mod must not mention APIs removed from the sandbox runtime.
-- This test runs outside the mod sandbox, so it may use the host filesystem
-- to inspect the source tree.

local function exists(path)
  local file = io.open(path, "rb")
  if not file then return false end
  file:close()
  return true
end

local root = exists("main.lua") and "." or "mods/potato_voxel"
local files = { root .. "/main.lua" }
local listing = assert(io.popen(("find %q/lib %q/data -type f -name '*.lua' | sort")
                              :format(root, root)))
for path in listing:lines() do files[#files + 1] = path end
listing:close()

local forbidden = {
  { "love.filesystem", "love%.filesystem" },
  { "love.system", "love%.system" },
  { "love.thread", "love%.thread" },
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

for _, failure in ipairs(failures) do print("FAIL: " .. failure) end
assert(#failures == 0, "sandbox API scan found " .. #failures .. " violation(s)")
print("sandbox API scan: clean")
