-- Small private JSON codec for the localhost workbench transport.
local Json = {}

local function encode(value, out)
  local kind = type(value)
  if value == nil then out[#out + 1] = "null"
  elseif kind == "boolean" then out[#out + 1] = value and "true" or "false"
  elseif kind == "number" then out[#out + 1] = string.format("%.17g", value)
  elseif kind == "string" then
    out[#out + 1] = '"' .. value:gsub('[%c"\\]', function(c)
      if c == '"' then return '\\"' end
      if c == "\\" then return "\\\\" end
      if c == "\n" then return "\\n" end
      if c == "\r" then return "\\r" end
      if c == "\t" then return "\\t" end
      return string.format("\\u%04x", c:byte())
    end) .. '"'
  elseif kind == "table" then
    local count, array = #value, #value > 0 or next(value) == nil
    if array then
      out[#out + 1] = "["
      for i = 1, count do if i > 1 then out[#out + 1] = "," end; encode(value[i], out) end
      out[#out + 1] = "]"
    else
      out[#out + 1] = "{"
      local first = true
      for key, entry in pairs(value) do
        if not first then out[#out + 1] = "," end
        first = false; encode(tostring(key), out); out[#out + 1] = ":"; encode(entry, out)
      end
      out[#out + 1] = "}"
    end
  else error("cannot JSON encode " .. kind) end
end

function Json.encode(value)
  local out = {}; encode(value, out); return table.concat(out)
end

local function skip(source, i) return source:find("[^ \t\r\n]", i) or (#source + 1) end
local decodeValue
local function decodeString(source, i)
  local out = {}; i = i + 1
  while i <= #source do
    local char = source:sub(i, i)
    if char == '"' then return table.concat(out), i + 1 end
    if char == "\\" then
      local escape = source:sub(i + 1, i + 1)
      local escapes = { n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
      if escape == "u" then
        local code = tonumber(source:sub(i + 2, i + 5), 16) or 32
        out[#out + 1] = code < 128 and string.char(code) or "?"; i = i + 6
      else out[#out + 1] = escapes[escape] or escape; i = i + 2 end
    else out[#out + 1] = char; i = i + 1 end
  end
  error("unterminated JSON string")
end

decodeValue = function(source, i)
  i = skip(source, i); local char = source:sub(i, i)
  if char == '"' then return decodeString(source, i) end
  if char == "{" then
    local object = {}; i = skip(source, i + 1); if source:sub(i, i) == "}" then return object, i + 1 end
    while true do
      local key; key, i = decodeString(source, skip(source, i)); i = skip(source, i)
      assert(source:sub(i, i) == ":", "expected JSON colon")
      object[key], i = decodeValue(source, i + 1); i = skip(source, i)
      if source:sub(i, i) == "}" then return object, i + 1 end
      assert(source:sub(i, i) == ",", "expected JSON comma"); i = i + 1
    end
  end
  if char == "[" then
    local array = {}; i = skip(source, i + 1); if source:sub(i, i) == "]" then return array, i + 1 end
    while true do
      array[#array + 1], i = decodeValue(source, i); i = skip(source, i)
      if source:sub(i, i) == "]" then return array, i + 1 end
      assert(source:sub(i, i) == ",", "expected JSON comma"); i = i + 1
    end
  end
  if source:sub(i, i + 3) == "true" then return true, i + 4 end
  if source:sub(i, i + 4) == "false" then return false, i + 5 end
  if source:sub(i, i + 3) == "null" then return nil, i + 4 end
  local number = source:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
  assert(number, "expected JSON value"); return tonumber(number), i + #number
end

function Json.decode(source)
  local ok, value = pcall(function() return select(1, decodeValue(source, 1)) end)
  if ok then return value end
  return nil, value
end

return Json
