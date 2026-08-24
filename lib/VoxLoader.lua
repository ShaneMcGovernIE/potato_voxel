local V = ...

local byte, sub = string.byte, string.sub

local VoxLoader = {}

local function u32(s, i)
  local a, b, c, d = byte(s, i, i + 3)
  if not d then return nil end
  return a + b * 256 + c * 65536 + d * 16777216
end

function VoxLoader.parse(source)
  if type(source) ~= "string" or #source < 12 then return nil, "empty" end
  if sub(source, 1, 4) ~= "VOX " then return nil, "not a vox file" end

  local size, voxels, palette
  local n = #source
  local i = 9
  while i + 11 <= n do
    local id = sub(source, i, i + 3)
    local contentN, childN = u32(source, i + 4), u32(source, i + 8)
    if not (contentN and childN) then break end
    local body = i + 12
    if id == "MAIN" then
      i = body
    else
      if id == "SIZE" and not size then
        size = { u32(source, body), u32(source, body + 4),
                 u32(source, body + 8) }
      elseif id == "XYZI" and not voxels then
        local count = u32(source, body) or 0
        local out = {}
        local p = body + 4
        for k = 1, count do
          local x, y, z, c = byte(source, p, p + 3)
          if not c then break end
          local o = (k - 1) * 4
          out[o + 1], out[o + 2], out[o + 3], out[o + 4] = x, y, z, c
          p = p + 4
        end
        voxels = out
      elseif id == "RGBA" and not palette then
        palette = {}
        for k = 1, 256 do
          local p = body + (k - 1) * 4
          local r, g, b, a = byte(source, p, p + 3)
          if not a then break end
          palette[k] = { r, g, b, a }
        end
      end
      i = body + contentN + childN
    end
  end

  if not (size and size[1] and voxels) then return nil, "no model" end
  if #voxels == 0 then return nil, "empty model" end
  return { w = size[1], d = size[2], h = size[3],
           voxels = voxels, palette = palette }
end

function VoxLoader.luma(vox, c)
  local entry = vox.palette and vox.palette[c]
  if not entry then return 1 - (c % 256) / 255 end
  return (0.299 * entry[1] + 0.587 * entry[2] + 0.114 * entry[3]) / 255
end

return VoxLoader
