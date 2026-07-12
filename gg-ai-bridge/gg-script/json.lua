--[[
  Minimal JSON helpers for GameGuardian Lua.
  Supports the small structured payloads used by AI_Memory_Hunter.lua.
--]]

local json = {}

local escape_map = {
  ["\\"] = "\\\\",
  ["\""] = "\\\"",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function escape_str(value)
  return (tostring(value):gsub('[\\"\n\r\t]', function(ch)
    return escape_map[ch]
  end))
end

function json.encode(value)
  local t = type(value)
  if t == "nil" then
    return "null"
  end
  if t == "boolean" or t == "number" then
    return tostring(value)
  end
  if t == "string" then
    return '"' .. escape_str(value) .. '"'
  end
  if t ~= "table" then
    return '"' .. escape_str(value) .. '"'
  end

  local is_array = true
  local max_index = 0
  for k, _ in pairs(value) do
    if type(k) ~= "number" then
      is_array = false
      break
    end
    if k > max_index then
      max_index = k
    end
  end
  if max_index == 0 then
    for _ in pairs(value) do
      if max_index == 0 then
        is_array = false
      end
      break
    end
  end

  if is_array then
    local parts = {}
    for i = 1, max_index do
      parts[#parts + 1] = json.encode(value[i])
    end
    return "[" .. table.concat(parts, ",") .. "]"
  end

  local parts = {}
  for k, v in pairs(value) do
    parts[#parts + 1] = json.encode(tostring(k)) .. ":" .. json.encode(v)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function skip_ws(s, i)
  while true do
    local c = s:sub(i, i)
    if c == "" or not c:match("%s") then
      return i
    end
    i = i + 1
  end
end

local function parse_value(s, i)
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == "{" then
    return json.decode_object(s, i)
  end
  if c == "[" then
    return json.decode_array(s, i)
  end
  if c == '"' then
    return json.decode_string(s, i)
  end
  if s:sub(i, i + 3) == "null" then
    return nil, i + 4
  end
  if s:sub(i, i + 3) == "true" then
    return true, i + 4
  end
  if s:sub(i, i + 4) == "false" then
    return false, i + 5
  end
  local num = s:match("^%-?%d+%.?%d*", i)
  if num then
    if num:find("%.") then
      return tonumber(num), i + #num
    end
    return tonumber(num), i + #num
  end
  error("Invalid JSON at position " .. i)
end

function json.decode_string(s, i)
  i = i + 1
  local out = {}
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' then
      return table.concat(out), i + 1
    end
    if c == "\\" then
      local n = s:sub(i + 1, i + 1)
      if n == "n" then out[#out + 1] = "\n"
      elseif n == "r" then out[#out + 1] = "\r"
      elseif n == "t" then out[#out + 1] = "\t"
      elseif n == '"' then out[#out + 1] = '"'
      elseif n == "\\" then out[#out + 1] = "\\"
      else out[#out + 1] = n end
      i = i + 2
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  error("Unterminated JSON string")
end

function json.decode_array(s, i)
  i = i + 1
  local arr = {}
  i = skip_ws(s, i)
  if s:sub(i, i) == "]" then
    return arr, i + 1
  end
  while i <= #s do
    local value
    value, i = parse_value(s, i)
    arr[#arr + 1] = value
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == "]" then
      return arr, i + 1
    end
    if c ~= "," then
      error("Expected , or ] in array")
    end
    i = skip_ws(s, i + 1)
  end
  error("Unterminated JSON array")
end

function json.decode_object(s, i)
  i = i + 1
  local obj = {}
  i = skip_ws(s, i)
  if s:sub(i, i) == "}" then
    return obj, i + 1
  end
  while i <= #s do
    i = skip_ws(s, i)
    local key
    key, i = json.decode_string(s, i)
    i = skip_ws(s, i)
    if s:sub(i, i) ~= ":" then
      error("Expected : in object")
    end
    local value
    value, i = parse_value(s, i + 1)
    obj[key] = value
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == "}" then
      return obj, i + 1
    end
    if c ~= "," then
      error("Expected , or } in object")
    end
    i = skip_ws(s, i + 1)
  end
  error("Unterminated JSON object")
end

function json.decode(s)
  if not s or s == "" then
    return nil
  end
  local value, next_i = parse_value(s, 1)
  return value
end

function json.extract_object(text)
  if not text then return nil end
  local start = text:find("{", 1, true)
  while start do
    local depth = 0
    for i = start, #text do
      local c = text:sub(i, i)
      if c == "{" then
        depth = depth + 1
      elseif c == "}" then
        depth = depth - 1
        if depth == 0 then
          local chunk = text:sub(start, i)
          local ok, value = pcall(json.decode, chunk)
          if ok then
            return value
          end
        end
      end
    end
    start = text:find("{", start + 1, true)
  end
  return nil
end

return json
