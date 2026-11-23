-- jtd_json.lua -- zero-dependency JSON decoder for Lua 5.1 / LuaJIT.
--
-- Why this file exists: validators emitted by `jtd-codegen --target lua` use a
-- JSON library for exactly two things -- a `null` sentinel (`lib.null`) and
-- `__jsontype` metatables that let the generated `is_object` / `is_array`
-- helpers tell `{}` from `[]`. This module supplies both from plain Lua 5.1, so
-- generated validators need no luarocks install and no C extension.
--
-- Contract used by the generated code:
--   * null        : a unique sentinel table; never nil, never a plain object
--   * decode(s)   : JSON text -> value, or nil, error message
--   * objects     : tables with metatable { __jsontype = "object" }
--   * arrays      : tables with metatable { __jsontype = "array" }
--
-- RFC 8259 details handled here: \u escapes with surrogate pairs, rejection of
-- leading zeros, rejection of raw control characters inside strings, rejection
-- of trailing garbage after the top-level value, and a nesting-depth cap so
-- hostile input cannot exhaust the stack.

local M = {}

local null = setmetatable({}, {
  __tostring = function()
    return "null"
  end,
})
M.null = null

local ARRAY_MT = { __jsontype = "array" }
local OBJECT_MT = { __jsontype = "object" }
M.array_mt = ARRAY_MT
M.object_mt = OBJECT_MT

-- Deeper than any sane wire format; protects the C stack of the parser.
M.MAX_DEPTH = 128

local sub = string.sub
local byte = string.byte
local char = string.char

local ESCAPES = {
  ['"'] = '"',
  ["\\"] = "\\",
  ["/"] = "/",
  b = "\b",
  f = "\f",
  n = "\n",
  r = "\r",
  t = "\t",
}

local function utf8_char(cp)
  if cp < 0x80 then
    return char(cp)
  elseif cp < 0x800 then
    return char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return char(
      0xE0 + math.floor(cp / 0x1000),
      0x80 + math.floor(cp / 0x40) % 0x40,
      0x80 + cp % 0x40
    )
  end
  return char(
    0xF0 + math.floor(cp / 0x40000),
    0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40,
    0x80 + cp % 0x40
  )
end

local function skip_ws(s, i)
  while true do
    local c = sub(s, i, i)
    if c == " " or c == "\t" or c == "\n" or c == "\r" then
      i = i + 1
    else
      return i
    end
  end
end

-- i points at the opening quote. Returns text, nil, next_index on success and
-- nil, message, index on failure.
local function scan_string(s, i)
  local out = {}
  local n = #s
  i = i + 1
  local start = i
  while true do
    if i > n then
      return nil, "unterminated string", n
    end
    local c = byte(s, i)
    if c == 34 then -- '"'
      out[#out + 1] = sub(s, start, i - 1)
      return table.concat(out), nil, i + 1
    elseif c == 92 then -- '\'
      out[#out + 1] = sub(s, start, i - 1)
      local e = sub(s, i + 1, i + 1)
      if ESCAPES[e] then
        out[#out + 1] = ESCAPES[e]
        i = i + 2
      elseif e == "u" then
        local hex = sub(s, i + 2, i + 5)
        if not string.find(hex, "^%x%x%x%x$") then
          return nil, "invalid \\u escape", i
        end
        local cp = tonumber(hex, 16)
        i = i + 6
        if cp >= 0xD800 and cp <= 0xDBFF then
          if sub(s, i, i + 1) ~= "\\u" then
            return nil, "unpaired high surrogate", i
          end
          local low = sub(s, i + 2, i + 5)
          if not string.find(low, "^%x%x%x%x$") then
            return nil, "invalid \\u escape", i
          end
          local lcp = tonumber(low, 16)
          if lcp < 0xDC00 or lcp > 0xDFFF then
            return nil, "unpaired high surrogate", i
          end
          cp = 0x10000 + (cp - 0xD800) * 0x400 + (lcp - 0xDC00)
          i = i + 6
        elseif cp >= 0xDC00 and cp <= 0xDFFF then
          return nil, "unpaired low surrogate", i
        end
        out[#out + 1] = utf8_char(cp)
      else
        return nil, "invalid escape sequence", i
      end
      start = i
    elseif c < 0x20 then
      return nil, "raw control character in string", i
    else
      i = i + 1
    end
  end
end

-- i points at '-', a digit, or garbage. Returns number, nil, next_index.
local function scan_number(s, i)
  local start = i
  local c = sub(s, i, i)
  if c == "-" then
    i = i + 1
    c = sub(s, i, i)
  end
  if c == "0" then
    i = i + 1
  elseif c ~= "" and c >= "1" and c <= "9" then
    repeat
      i = i + 1
      c = sub(s, i, i)
    until not (c ~= "" and c >= "0" and c <= "9")
  else
    return nil, "expected a digit", start
  end
  if sub(s, i, i) == "." then
    i = i + 1
    c = sub(s, i, i)
    if not (c ~= "" and c >= "0" and c <= "9") then
      return nil, "expected a digit after '.'", i
    end
    repeat
      i = i + 1
      c = sub(s, i, i)
    until not (c ~= "" and c >= "0" and c <= "9")
  end
  local e = sub(s, i, i)
  if e == "e" or e == "E" then
    i = i + 1
    local sign = sub(s, i, i)
    if sign == "+" or sign == "-" then
      i = i + 1
    end
    c = sub(s, i, i)
    if not (c ~= "" and c >= "0" and c <= "9") then
      return nil, "expected a digit in exponent", i
    end
    repeat
      i = i + 1
      c = sub(s, i, i)
    until not (c ~= "" and c >= "0" and c <= "9")
  end
  local value = tonumber(sub(s, start, i - 1))
  if value ~= value or value == math.huge or value == -math.huge then
    return nil, "number out of range", start
  end
  return value, nil, i
end

local parse_value, parse_object, parse_array

parse_object = function(s, i, depth)
  if depth >= M.MAX_DEPTH then
    return nil, "nesting too deep", i
  end
  local obj = {}
  i = skip_ws(s, i + 1)
  if sub(s, i, i) == "}" then
    return setmetatable(obj, OBJECT_MT), nil, i + 1
  end
  while true do
    i = skip_ws(s, i)
    if sub(s, i, i) ~= '"' then
      return nil, "expected an object key", i
    end
    local key, key_err, key_next = scan_string(s, i)
    if key_err then
      return nil, key_err, key_next
    end
    i = skip_ws(s, key_next)
    if sub(s, i, i) ~= ":" then
      return nil, "expected ':' after object key", i
    end
    local value, value_err, value_next = parse_value(s, i + 1, depth + 1)
    if value_err then
      return nil, value_err, value_next
    end
    obj[key] = value
    i = skip_ws(s, value_next)
    local c = sub(s, i, i)
    if c == "," then
      i = i + 1
    elseif c == "}" then
      return setmetatable(obj, OBJECT_MT), nil, i + 1
    else
      return nil, "expected ',' or '}' in object", i
    end
  end
end

parse_array = function(s, i, depth)
  if depth >= M.MAX_DEPTH then
    return nil, "nesting too deep", i
  end
  local arr = {}
  i = skip_ws(s, i + 1)
  if sub(s, i, i) == "]" then
    return setmetatable(arr, ARRAY_MT), nil, i + 1
  end
  while true do
    local value, value_err, value_next = parse_value(s, i, depth + 1)
    if value_err then
      return nil, value_err, value_next
    end
    arr[#arr + 1] = value
    i = skip_ws(s, value_next)
    local c = sub(s, i, i)
    if c == "," then
      i = i + 1
    elseif c == "]" then
      return setmetatable(arr, ARRAY_MT), nil, i + 1
    else
      return nil, "expected ',' or ']' in array", i
    end
  end
end

parse_value = function(s, i, depth)
  i = skip_ws(s, i)
  local c = sub(s, i, i)
  if c == "{" then
    return parse_object(s, i, depth)
  elseif c == "[" then
    return parse_array(s, i, depth)
  elseif c == '"' then
    return scan_string(s, i)
  elseif c == "-" or (c ~= "" and c >= "0" and c <= "9") then
    return scan_number(s, i)
  elseif sub(s, i, i + 3) == "true" then
    return true, nil, i + 4
  elseif sub(s, i, i + 4) == "false" then
    return false, nil, i + 5
  elseif sub(s, i, i + 3) == "null" then
    return null, nil, i + 4
  elseif c == "" then
    return nil, "unexpected end of input", i
  end
  return nil, "unexpected character", i
end

--- Decode JSON text.
-- @param chunk string of JSON text
-- @return value, nil on success; nil, message on failure
function M.decode(chunk)
  if type(chunk) ~= "string" then
    return nil, "expected JSON text (string), got " .. type(chunk)
  end
  local value, err, pos = parse_value(chunk, 1, 0)
  if err then
    return nil, string.format("invalid JSON at byte %d: %s", pos or 0, err)
  end
  local after = skip_ws(chunk, pos)
  if after <= #chunk then
    return nil, string.format("invalid JSON at byte %d: trailing content", after)
  end
  return value
end

--- Encode a value as JSON text. Provided for tests and error messages; the
-- generated validators never call it. Values tagged with the object/array
-- metatables encode as objects/arrays, everything else by Lua type.
function M.encode(value)
  local t = type(value)
  if value == null or value == nil then
    return "null"
  elseif t == "boolean" then
    return tostring(value)
  elseif t == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      return "null"
    end
    if value == math.floor(value) and math.abs(value) < 1e15 then
      return string.format("%d", value)
    end
    return string.format("%.17g", value)
  elseif t == "string" then
    return '"'
      .. value:gsub('[%c"\\]', function(c)
        if c == '"' then
          return '\\"'
        elseif c == "\\" then
          return "\\\\"
        elseif c == "\n" then
          return "\\n"
        elseif c == "\r" then
          return "\\r"
        elseif c == "\t" then
          return "\\t"
        end
        return string.format("\\u%04x", byte(c))
      end)
      .. '"'
  elseif t == "table" then
    local mt = getmetatable(value)
    local is_array = mt and mt.__jsontype == "array"
    local parts = {}
    if is_array then
      for index = 1, #value do
        parts[#parts + 1] = M.encode(value[index])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for key in pairs(value) do
      keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    for _, key in ipairs(keys) do
      parts[#parts + 1] = M.encode(tostring(key)) .. ":" .. M.encode(value[key])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  error("cannot encode a " .. t)
end

return M
