#!/usr/bin/env -S luajit
-- test_validators.lua -- prove the generated Lua validators accept good input
-- and reject bad input. Runs under plain Lua 5.1 or LuaJIT.
--
-- Usage:
--   luajit skills/lua/test_validators.lua [GENERATED_DIR]
--
-- GENERATED_DIR defaults to this script's directory (which holds the committed
-- user.lua sample). Cases for a schema are skipped when its .lua is absent, so
-- the same file works for the committed sample and for a full fixture run.

local function dirname(path)
  return (path:match("^(.*)/[^/]*$")) or "."
end

local script_dir = dirname(arg[0] or "test_validators.lua")
local generated_dir = arg[1] or script_dir

package.path = script_dir .. "/?.lua;" .. generated_dir .. "/?.lua;" .. package.path

-- Each case is { json = <text>, ok = <expected>, err = <substring of message> }.
local CASES = {
  user = {
    { json = '{"name":"Alice","age":30,"email":"alice@example.com"}', ok = true },
    {
      json = '{"name":"Alice","age":30,"email":"alice@example.com","phone":"+1-555"}',
      ok = true,
      why = "optional property may be present",
    },
    {
      json = '  {"name":"Alice","age":30,"email":"a@b.c"}  ',
      ok = true,
      why = "surrounding whitespace is legal JSON",
    },
    {
      json = '{"name":"Zo\\u00eb","age":1,"email":"z@b.c"}',
      ok = true,
      why = "\\u escapes decode before validation",
    },
    {
      json = '{"name":"Alice","age":"thirty","email":"a@b.c"}',
      ok = false,
      err = "/age: /properties/age/type",
      why = "int32 rejects a string",
    },
    {
      json = '{"name":"Alice","age":2147483648,"email":"a@b.c"}',
      ok = false,
      err = "/age: /properties/age/type",
      why = "int32 rejects an out-of-range number",
    },
    {
      json = '{"name":"Alice","age":30}',
      ok = false,
      err = "/: /properties/email",
      why = "required property is missing",
    },
    {
      json = '{"name":null,"age":30,"email":"a@b.c"}',
      ok = false,
      err = "/name: /properties/name/type",
      why = "JSON null is not a string",
    },
    {
      json = '{"name":"Alice","age":30,"email":"a@b.c","extra":1}',
      ok = false,
      err = "/extra: /additionalProperties",
      why = "unknown properties are rejected by default",
    },
    {
      json = '{"name":"Alice",',
      ok = false,
      err = "invalid JSON at byte",
      why = "malformed JSON is reported before validation",
    },
    { json = "null", ok = false, why = "root is not an object" },
    { json = "123", ok = false, err = "/: /properties", why = "root is not an object" },
  },

  event = {
    {
      json = '{"id":"evt-1","created_at":"2026-01-01T00:00:00Z","status":"active","tags":["a","b"]}',
      ok = true,
    },
    {
      json = '{"id":"evt-1","created_at":"2026-01-01T00:00:00Z","status":"active"}',
      ok = true,
      why = "optional array may be absent",
    },
    {
      json = '{"id":"evt-2","created_at":"2026-01-01T00:00:00Z","status":"weird"}',
      ok = false,
      err = "/status: /properties/status/enum",
      why = "enum rejects an unknown value",
    },
    {
      json = '{"id":"evt-3","created_at":"yesterday","status":"active"}',
      ok = false,
      err = "/created_at: /properties/created_at/type",
      why = "timestamp rejects a non-RFC 3339 string",
    },
    {
      json = '{"id":"evt-4","created_at":"2026-01-01T00:00:00Z","status":"active","tags":"a"}',
      ok = false,
      err = "/tags: /optionalProperties/tags/elements",
      why = "elements rejects a non-array",
    },
  },

  advanced = {
    {
      json = '{"profile":{"author":{"name":"Ada","bio":null}},"errors":{"k":["a"]}}',
      ok = true,
      why = "nullable property accepts JSON null",
    },
    {
      json = '{"profile":{"author":{"name":"Ada","bio":null}},"errors":{}}',
      ok = true,
      why = "values accepts an empty object",
    },
    {
      json = '{"profile":{"author":{"name":"Ada"}},"errors":{}}',
      ok = false,
      err = "/profile/author: /definitions/User/properties/bio",
      why = "a required property reached through a ref is still required",
    },
    {
      json = '{"profile":{"author":{"name":1,"bio":null}},"errors":{}}',
      ok = false,
      err = "/profile/author/name: /definitions/User/properties/name/type",
      why = "ref-reached properties are validated",
    },
    {
      json = '{"profile":{"author":{"name":"Ada","bio":null}},"errors":{"k":"notarray"}}',
      ok = false,
      err = "/errors/k: /definitions/ErrorMap/values/elements",
      why = "values/elements rejects a non-array entry",
    },
  },
}

local function exists(path)
  local handle = io.open(path, "r")
  if handle then
    handle:close()
    return true
  end
  return false
end

local failures = 0
local checked = 0
local modules = 0

local function fail(message)
  failures = failures + 1
  print("FAIL: " .. message)
end

for stem, cases in pairs(CASES) do
  local module_path = generated_dir .. "/" .. stem .. ".lua"
  if not exists(module_path) then
    print("SKIP: " .. stem .. " (no " .. module_path .. ")")
  else
    modules = modules + 1
    local validator = require(stem)

    for index, case in ipairs(cases) do
      checked = checked + 1
      local label = stem .. " case " .. index .. (case.why and (" (" .. case.why .. ")") or "")
      local ok, err = validator.validate(case.json)

      if ok ~= case.ok then
        fail(
          label
            .. ": expected ok="
            .. tostring(case.ok)
            .. ", got "
            .. tostring(ok)
            .. " <<"
            .. tostring(err)
            .. ">>"
        )
      elseif not case.ok and case.err and not tostring(err):find(case.err, 1, true) then
        fail(label .. ": expected an error containing <<" .. case.err .. ">>, got <<" .. tostring(err) .. ">>")
      end
    end

    -- The byte-oriented API rejects anything that is not JSON text.
    local ok, err = validator.validate(42)
    if ok ~= false or not tostring(err):find("expected JSON text (string)", 1, true) then
      fail(stem .. ": validate(42) should report a type error, got <<" .. tostring(err) .. ">>")
    end

    -- The instance-level API is what Teal call sites use when they decode JSON
    -- themselves, so prove it still returns the emitter's error list.
    local errors = validator.validate_instance({})
    if type(errors) ~= "table" then
      fail(stem .. ": validate_instance must return a list of errors")
    elseif #errors > 0 and type(errors[1].instancePath) ~= "string" then
      fail(stem .. ": errors must carry an instancePath string")
    end
  end
end

if modules == 0 then
  print("FAIL: no generated validators found in " .. generated_dir)
  os.exit(1)
end

print(string.format("checked %d cases across %d validator(s)", checked, modules))
if failures > 0 then
  print("Lua validator fixture test FAILED")
  os.exit(1)
end
print("Lua validator fixture test PASSED")
