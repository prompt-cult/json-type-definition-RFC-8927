#!/usr/bin/env -S luajit
-- codegen_validators.lua -- emit LuaJIT (Lua 5.1 ABI) JTD validators plus the
-- Teal declaration files that let `tl check` type the call sites.
--
-- For every schema given on the command line this writes two files:
--
--   <out>/<stem>.lua     validator module: validate(json_text) -> true | false, err
--                        (and validate_instance(value) -> { {instancePath, schemaPath} })
--   <out>/<stem>.d.tl    Teal declaration for the module above
--
-- The Lua body comes from `jtd-codegen --target lua`. Two edits are applied to
-- it, both guarded so an emitter change fails loudly instead of silently:
--
--   1. `require("dkjson")` becomes `require("jtd_json")`. The emitter uses that
--      module only for its `null` sentinel and `__jsontype` metatables, both of
--      which the vendored skills/lua/jtd_json.lua supplies in plain Lua 5.1.
--      This is what keeps generated validators free of luarocks dependencies.
--   2. A facade is appended: the emitter's `M.validate(instance)` returns an
--      error list, the facade exposes `M.validate(json_text) -> true | false,
--      err` for byte-oriented callers and keeps the instance-level validator
--      as `M.validate_instance`. The emitter's trailing `return M` is dropped so
--      the facade can be appended without a "return must be the last statement"
--      syntax error.
--
-- Usage:
--   luajit codegen_validators.lua --out DIR [--binary PATH] SCHEMA.jtd.json ...
--
-- Example (from the repository root):
--   luajit skills/lua/codegen_validators.lua --out skills/fixture/generated/lua \
--     skills/fixture/schemas/*.jtd.json

local function dirname(path)
  return (path:match("^(.*)/[^/]*$")) or "."
end

local script_dir = dirname(arg[0] or "codegen_validators.lua")
package.path = script_dir .. "/?.lua;" .. package.path

local usage = [[
usage: codegen_validators.lua --out DIR [--binary PATH] SCHEMA.jtd.json ...

  --out DIR       directory for generated <stem>.lua and <stem>.d.tl (created if absent)
  --binary PATH   jtd-codegen binary (default: $JTD_CODEGEN or "jtd-codegen")
  --barrel NAME   also write NAME.lua + NAME.d.tl re-exporting every validator as
                  validate_<stem> / validate_instance_<stem> (stem snake_cased)
  SCHEMA...      one or more *.jtd.json schema files
]]

local function die(message)
  io.stderr:write("codegen_validators: " .. message .. "\n")
  os.exit(1)
end

local function shell_quote(text)
  return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

-- os.execute returns a number on Lua 5.1 / LuaJIT and a boolean on 5.2+.
local function succeeded(status)
  if status == true then
    return true
  end
  if type(status) == "number" then
    return status == 0
  end
  return false
end

local function read_file(path)
  local handle = io.open(path, "r")
  if not handle then
    die("cannot read " .. path)
  end
  local text = handle:read("*a")
  handle:close()
  return text
end

local function write_file(path, text)
  local handle = io.open(path, "w")
  if not handle then
    die("cannot write " .. path)
  end
  handle:write(text)
  handle:close()
end

local function mkdir(path)
  -- mkdir -p without a C binding; a pre-existing directory is not an error.
  os.execute("mkdir -p " .. shell_quote(path))
end

local DKFJON_REQUIRE = 'require%(%s*[\'"]dkjson[\'"]%s*%)'

--- Make definition functions mutually visible.
--
-- jtd-codegen emits `local function validate_<Definition>` bodies in alphabetical
-- order, but a definition may `ref` one that sorts later; a `local function`
-- declaration is invisible above its own line, so such a call resolves to a nil
-- global at runtime. Forward-declare the whole set and turn the definitions into
-- assignments, which keeps the emitted logic byte-identical.
local function link_definitions(source, schema_name)
  local names, seen = {}, {}
  for name in source:gmatch("local function (validate_[%w_]+)%s*%(") do
    if not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  if #names == 0 then
    return source
  end

  local declared = false
  local linked = source:gsub("local function (validate_[%w_]+)%s*%(", function(name)
    if declared then
      return name .. " = function("
    end
    declared = true
    return "local " .. table.concat(names, ", ") .. "\n" .. name .. " = function("
  end)

  if linked:find("local function validate_") then
    die(schema_name .. ": could not link definition validators; inspect the emitter output")
  end
  return linked
end

local FACADE = [[
------------------------------------------------------------------------------
-- Facade appended by skills/lua/codegen_validators.lua.
-- `validate(json_text)` checks JSON text; `validate_instance(value)` keeps the
-- emitter's error-list contract for callers that decode JSON themselves.
------------------------------------------------------------------------------
local jtd_json = require("jtd_json")
local validate_instance = M.validate

function M.validate_instance(instance)
  return validate_instance(instance)
end

function M.validate(chunk)
  if type(chunk) ~= "string" then
    return false, "expected JSON text (string), got " .. type(chunk)
  end
  local value, decode_err = jtd_json.decode(chunk)
  if decode_err ~= nil then
    return false, decode_err
  end
  local errors = validate_instance(value)
  if #errors == 0 then
    return true, nil
  end
  local first = errors[1]
  local path = first.instancePath
  if path == "" then
    path = "/"
  end
  local schema_path = first.schemaPath
  if schema_path == "" then
    -- The emitter reports an unknown key with an empty schema path.
    schema_path = "/additionalProperties"
  end
  return false, path .. ": " .. schema_path
end

return M
]]

--- Rewrite the emitter's dkjson require and append the string-in facade.
local function finish_module(raw, schema_name)
  local source, replacements = raw:gsub(DKFJON_REQUIRE, 'require("jtd_json")')
  if replacements == 0 then
    if source:find("dkjson%.null") then
      die(
        schema_name
          .. ": emitter references dkjson.null but the require could not be rewritten;"
          .. " inspect `jtd-codegen --target lua` output and update skills/skill-lua.md"
      )
    end
    -- No dkjson usage: the emitter already produces dependency-free code.
  elseif replacements > 1 then
    die(schema_name .. ": emitter has " .. replacements .. " dkjson requires; expected exactly 1")
  end

  source = link_definitions(source, schema_name)

  local body = source:gsub("%s+$", ""):match("^(.*)return M$")
  if not body then
    die(schema_name .. ": emitter output does not end with 'return M'; cannot append the facade")
  end
  return body .. FACADE
end

local DECLARATION_TEMPLATE = [[
-- Generated by skills/lua/codegen_validators.lua from %s. Do not edit.
--
-- Teal declaration for the sibling Lua module, so `tl check` types call sites:
--   local user = require("user")
--   local ok, err = user.validate('{"name":"Ada"}')

local record M
   record JtdError
      instancePath: string
      schemaPath: string
   end

   -- Validate JSON text against the schema: true when the text is valid,
   -- otherwise false plus a "<instance path>: <schema path>" message.
   validate: function(chunk: string): boolean, string

   -- Validate an already-decoded value (see jtd_json.decode).
   -- An empty list means the instance is valid.
   validate_instance: function(instance: any): {JtdError}
end

return M
]]

local function parse_args(argv)
  local out_dir = nil
  local barrel = nil
  local binary = os.getenv("JTD_CODEGEN") or "jtd-codegen"
  local schemas = {}
  local index = 1
  while index <= #argv do
    local token = argv[index]
    if token == "--out" then
      index = index + 1
      out_dir = argv[index]
    elseif token == "--binary" then
      index = index + 1
      binary = argv[index]
    elseif token == "--barrel" then
      index = index + 1
      barrel = argv[index]
    elseif token == "--help" or token == "-h" then
      io.write(usage)
      os.exit(0)
    else
      schemas[#schemas + 1] = token
    end
    index = index + 1
  end
  if not out_dir or #schemas == 0 then
    io.stderr:write(usage)
    os.exit(1)
  end
  return out_dir, binary, schemas, barrel
end

--- Lua module name for a schema stem: punctuation becomes underscores, case is
-- preserved so `User.jtd.json` stays `require("User")`.
local function module_name_for(stem)
  return (stem:gsub("%-", "_"):gsub("%.", "_"))
end

--- Barrel export suffix: lowercase snake_case, matching the other target skills.
local function snake_case(text)
  return module_name_for(text):lower()
end

--- Write the barrel module and its declaration.
local function write_barrel(out_dir, barrel, stems)
  local exports = { "local M = {}", "" }
  local records = {
    "",
    "local record JtdError",
    "   instancePath: string",
    "   schemaPath: string",
    "end",
    "",
    "local record M",
  }
  for _, name in ipairs(stems) do
    local snake = snake_case(name)
    exports[#exports + 1] = "M.validate_" .. snake .. ' = require("' .. name .. '").validate'
    exports[#exports + 1] = "M.validate_instance_" .. snake .. ' = require("' .. name .. '").validate_instance'
    exports[#exports + 1] = ""
    records[#records + 1] = "   validate_" .. snake .. ": function(chunk: string): boolean, string"
    records[#records + 1] = "   validate_instance_" .. snake .. ": function(instance: any): {JtdError}"
  end
  exports[#exports + 1] = "return M"
  records[#records + 1] = "end"
  records[#records + 1] = ""
  records[#records + 1] = "return M"

  local lua_path = out_dir .. "/" .. barrel .. ".lua"
  local decl_path = out_dir .. "/" .. barrel .. ".d.tl"
  write_file(lua_path, table.concat(exports, "\n") .. "\n")
  write_file(
    decl_path,
    "-- Generated by skills/lua/codegen_validators.lua. Do not edit.\n"
      .. "-- Teal declaration for the " .. barrel .. " barrel module.\n"
      .. table.concat(records, "\n")
      .. "\n"
  )
  print("generated " .. lua_path)
  print("generated " .. decl_path)
end

local out_dir, binary, schemas, barrel = parse_args(arg)
mkdir(out_dir)

local stems = {}
for _, schema_path in ipairs(schemas) do
  local stem = schema_path:match("([^/]+)%.jtd%.json$")
  if not stem then
    die("schema file must be named *.jtd.json: " .. schema_path)
  end
  -- Hyphens would survive a require() but look wrong in a module name; case is
  -- preserved so `User.jtd.json` stays require("User").
  local module_name = module_name_for(stem)
  if module_name:match("^%d") then
    die(schema_path .. ": schema name must not start with a digit")
  end

  local raw_path = out_dir .. "/." .. module_name .. ".raw.lua"
  local command = shell_quote(binary)
    .. " --target lua "
    .. shell_quote(schema_path)
    .. " > "
    .. shell_quote(raw_path)
  if not succeeded(os.execute(command)) then
    die("jtd-codegen failed for " .. schema_path .. " (command: " .. command .. ")")
  end

  local raw = read_file(raw_path)
  os.remove(raw_path)

  local lua_path = out_dir .. "/" .. module_name .. ".lua"
  local decl_path = out_dir .. "/" .. module_name .. ".d.tl"
  write_file(lua_path, finish_module(raw, schema_path))
  write_file(decl_path, DECLARATION_TEMPLATE:format(stem))
  stems[#stems + 1] = module_name
  print("generated " .. lua_path)
  print("generated " .. decl_path)
end

if barrel then
  write_barrel(out_dir, barrel, stems)
end

print("generated " .. #schemas .. " Lua validator(s) in " .. out_dir)
