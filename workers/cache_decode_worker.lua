-- Runtime cache decompression worker. Storage and graphics remain on main.
require("love.thread")
require("love.data")

local commands = love.thread.getChannel("pv_cache_decode_cmd")
local results = love.thread.getChannel("pv_cache_decode_out")

while true do
  local job = commands:demand()
  if job and job.cmd == "quit" then break end
  if job and job.cmd == "decode" then
    local ok, raw = pcall(love.data.decompress, "string", job.codec, job.body)
    if ok and type(raw) == "string" and #raw == job.rawLength then
      results:push({ id = job.id, raw = raw })
    else
      results:push({ id = job.id, error = ok and "length" or tostring(raw) })
    end
  end
end
