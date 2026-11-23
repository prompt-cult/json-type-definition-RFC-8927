-- Type-check proof for the generated Teal declaration, run from this directory:
--   tl check test_callsite.tl
--
-- The sibling user.d.tl is what makes this file type-check: without it, `tl`
-- reports "no type information for required module: 'user'". Compile it with
--   tl gen test_callsite.tl   (writes the matching .lua) or run it through the
--   Teal loader (`require("tl").loader()`).

local user = require("user")

local valid = '{"name":"Ada","age":36,"email":"ada@example.com"}'
local ok, err = user.validate(valid)
print("valid input:", ok, err)

local invalid = '{"name":"Ada","age":"old","email":"ada@example.com"}'
local bad_ok, bad_err = user.validate(invalid)
print("invalid input:", bad_ok, bad_err)
assert(ok == true)
assert(bad_ok == false)

-- validate_instance takes an already-decoded value and returns the error list.
local errors = user.validate_instance({ name = "Ada" })
for _, entry in ipairs(errors) do
   print("error:", entry.instancePath, entry.schemaPath)
end
