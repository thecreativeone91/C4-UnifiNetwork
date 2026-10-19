-- Small JSON encoder/decoder for the UniFi Control4 drivers (MIT License).
--
-- Unlike most Lua JSON libraries this one round-trips UniFi device settings
-- faithfully, which matters because the drivers write port_overrides and
-- outlet_overrides back to the controller as a complete array:
--
--   * decoded objects and arrays carry a marker metatable, so an empty
--     object {} is written back as {} (not []) and an empty array as [];
--   * JSON null decodes to json.null and encodes back to null;
--   * object keys are written sorted, so equal values give equal strings.

local json = {}

local OBJECT_MT = { __jsontype = "object" }
local ARRAY_MT = { __jsontype = "array" }

json.null = setmetatable({}, {
  __jsontype = "null",
  __tostring = function() return "null" end,
  __newindex = function() error("json.null is immutable", 2) end,
})

function json.object(t) return setmetatable(t or {}, OBJECT_MT) end
function json.array(t) return setmetatable(t or {}, ARRAY_MT) end

function json.isArray(t)
  local mt = getmetatable(t)
  return mt == ARRAY_MT
end

function json.isNull(v) return v == json.null end

-------------------------------------------------------------------------------
-- Encoding
-------------------------------------------------------------------------------

local ESCAPES = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function escapeString(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return ESCAPES[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function encodeNumber(n)
  if n ~= n or n == math.huge or n == -math.huge then
    error("cannot encode non-finite number")
  end
  if math.floor(n) == n and math.abs(n) < 2 ^ 53 then
    return string.format("%d", n)
  end
  return string.format("%.17g", n)
end

local function sequenceLength(t)
  local n = 0
  for k, _ in pairs(t) do
    if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then return nil end
    if k > n then n = k end
  end
  for i = 1, n do
    if t[i] == nil then return nil end
  end
  return n
end

local encodeValue

local function encodeTable(t, seen)
  if seen[t] then error("cannot encode a cyclic table") end
  seen[t] = true

  local mt = getmetatable(t)
  local kind = mt and mt.__jsontype
  local out

  local n = (kind ~= "object") and sequenceLength(t) or nil
  if kind == "array" or (kind == nil and n and n > 0) then
    local parts = {}
    for i = 1, (n or 0) do parts[i] = encodeValue(t[i], seen) end
    out = "[" .. table.concat(parts, ",") .. "]"
  else
    local keys = {}
    for k, _ in pairs(t) do
      if type(k) ~= "string" and type(k) ~= "number" then
        error("object keys must be strings")
      end
      keys[#keys + 1] = tostring(k)
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
      local v = t[k]
      if v == nil then v = t[tonumber(k)] end
      parts[#parts + 1] = escapeString(k) .. ":" .. encodeValue(v, seen)
    end
    out = "{" .. table.concat(parts, ",") .. "}"
  end

  seen[t] = nil
  return out
end

encodeValue = function(v, seen)
  local tv = type(v)
  if v == json.null or v == nil then return "null" end
  if tv == "boolean" then return v and "true" or "false" end
  if tv == "number" then return encodeNumber(v) end
  if tv == "string" then return escapeString(v) end
  if tv == "table" then return encodeTable(v, seen) end
  error("cannot encode value of type " .. tv)
end

function json.encode(v)
  return encodeValue(v, {})
end

-------------------------------------------------------------------------------
-- Decoding
-------------------------------------------------------------------------------

local function decodeError(str, pos, msg)
  error(string.format("JSON decode error at position %d: %s", pos, msg), 0)
end

local function skipWhitespace(str, pos)
  local _, e = str:find("^[ \n\r\t]*", pos)
  return e + 1
end

local function codepointToUtf8(n)
  if n < 0x80 then return string.char(n) end
  if n < 0x800 then
    return string.char(0xC0 + math.floor(n / 0x40), 0x80 + n % 0x40)
  end
  if n < 0x10000 then
    return string.char(0xE0 + math.floor(n / 0x1000),
      0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
  end
  return string.char(0xF0 + math.floor(n / 0x40000),
    0x80 + math.floor(n / 0x1000) % 0x40,
    0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
end

local SIMPLE_ESCAPES = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }

local function decodeString(str, pos)
  -- pos is at the opening quote
  local buffer = {}
  local i = pos + 1
  while true do
    local s, e = str:find('["\\]', i)
    if not s then decodeError(str, pos, "unterminated string") end
    if s > i then buffer[#buffer + 1] = str:sub(i, s - 1) end
    if str:sub(s, s) == '"' then
      return table.concat(buffer), e + 1
    end
    local c = str:sub(s + 1, s + 1)
    if c == "u" then
      local hex = str:sub(s + 2, s + 5)
      if not hex:find("^%x%x%x%x$") then decodeError(str, s, "bad unicode escape") end
      local n = tonumber(hex, 16)
      local nextPos = s + 6
      if n >= 0xD800 and n <= 0xDBFF and str:sub(nextPos, nextPos + 1) == "\\u" then
        local lo = tonumber(str:sub(nextPos + 2, nextPos + 5), 16)
        if lo and lo >= 0xDC00 and lo <= 0xDFFF then
          n = 0x10000 + (n - 0xD800) * 0x400 + (lo - 0xDC00)
          nextPos = nextPos + 6
        end
      end
      buffer[#buffer + 1] = codepointToUtf8(n)
      i = nextPos
    else
      local r = SIMPLE_ESCAPES[c]
      if not r then decodeError(str, s, "bad escape") end
      buffer[#buffer + 1] = r
      i = s + 2
    end
  end
end

local decodeValue

local function decodeArray(str, pos)
  local result = json.array({})
  local n = 0
  pos = skipWhitespace(str, pos + 1)
  if str:sub(pos, pos) == "]" then return result, pos + 1 end
  while true do
    local v
    v, pos = decodeValue(str, pos)
    n = n + 1
    result[n] = v
    pos = skipWhitespace(str, pos)
    local c = str:sub(pos, pos)
    if c == "]" then return result, pos + 1 end
    if c ~= "," then decodeError(str, pos, "expected ',' or ']'") end
    pos = skipWhitespace(str, pos + 1)
  end
end

local function decodeObject(str, pos)
  local result = json.object({})
  pos = skipWhitespace(str, pos + 1)
  if str:sub(pos, pos) == "}" then return result, pos + 1 end
  while true do
    if str:sub(pos, pos) ~= '"' then decodeError(str, pos, "expected string key") end
    local key
    key, pos = decodeString(str, pos)
    pos = skipWhitespace(str, pos)
    if str:sub(pos, pos) ~= ":" then decodeError(str, pos, "expected ':'") end
    pos = skipWhitespace(str, pos + 1)
    local v
    v, pos = decodeValue(str, pos)
    result[key] = v
    pos = skipWhitespace(str, pos)
    local c = str:sub(pos, pos)
    if c == "}" then return result, pos + 1 end
    if c ~= "," then decodeError(str, pos, "expected ',' or '}'") end
    pos = skipWhitespace(str, pos + 1)
  end
end

decodeValue = function(str, pos)
  pos = skipWhitespace(str, pos)
  local c = str:sub(pos, pos)
  if c == "{" then return decodeObject(str, pos) end
  if c == "[" then return decodeArray(str, pos) end
  if c == '"' then return decodeString(str, pos) end
  if str:sub(pos, pos + 3) == "true" then return true, pos + 4 end
  if str:sub(pos, pos + 4) == "false" then return false, pos + 5 end
  if str:sub(pos, pos + 3) == "null" then return json.null, pos + 4 end
  local s, e = str:find("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
  if s then
    local n = tonumber(str:sub(s, e))
    if n == nil then decodeError(str, pos, "bad number") end
    return n, e + 1
  end
  decodeError(str, pos, "unexpected character '" .. c .. "'")
end

function json.decode(str)
  if type(str) ~= "string" then error("expected a string to decode", 2) end
  local v, pos = decodeValue(str, 1)
  pos = skipWhitespace(str, pos)
  if pos <= #str then decodeError(str, pos, "trailing characters") end
  return v
end

-- Returns value, nil on success or nil, err on failure.
function json.tryDecode(str)
  local ok, v = pcall(json.decode, str)
  if ok then return v, nil end
  return nil, tostring(v)
end

-- Plain-Lua read helper: nil for json.null.
function json.get(t, key)
  if type(t) ~= "table" then return nil end
  local v = t[key]
  if v == json.null then return nil end
  return v
end

return json
