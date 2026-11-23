---
name: jtd-lua-validator
description: Generate standalone LuaJIT / Lua 5.1 JTD validators with jtd-codegen from *.jtd.json schemas, with no luarocks dependencies, plus .d.tl declarations so Teal call sites type-check. Use when adding RFC 8927 JSON Type Definition "JTD" validation to LuaJIT, OpenResty/nginx, Redis, game engines or Teal tooling projects, Makefile codegen workflows, or multiple schema files that need differentiated validate exports.
---

# JTD → Lua validator generation

Generate ahead-of-time Lua validators from [RFC 8927 JSON Type Definition](https://www.rfc-editor.org/rfc/rfc8927) schemas using `jtd-codegen` from this repository, then expose them as plain Lua 5.1 modules with a Teal declaration beside each one.

Generated validators have **no runtime dependencies**: no luarocks install, no C extensions, no `cjson`/`dkjson`/`lunajson`. They run on LuaJIT 2.x (5.1 ABI) and PUC Lua 5.1.

## Prerequisites

Install `jtd-codegen` (pick one):

```bash
# Pre-built binary from GitHub Releases
# https://github.com/simbo1905/jtd-wasm/releases

# From source (this repo)
cargo install --path jtd-codegen
# or after cloning:
cargo build --release -p jtd-codegen
# binary: target/release/jtd-codegen
```

Requires [LuaJIT](https://luajit.org/) 2.x (or Lua 5.1) to run generated validators, plus the two support files this skill ships:

| File | Role |
|------|------|
| `skills/lua/jtd_json.lua` | zero-dependency JSON decoder plus the `null` sentinel and `__jsontype` metatables the generated code relies on — copy it next to your validators |
| `skills/lua/codegen_validators.lua` | the codegen driver: `jtd-codegen --target lua` in, dogfoodable `.lua` + `.d.tl` out |

Teal (`tl`) is only needed at development time, for `tl check` over call sites:

```bash
luarocks --lua-version=5.1 install tl   # LuaJIT is the Lua 5.1 ABI
```

## Validator API

Every generated module exports two functions:

```lua
local user = require("user")

-- Byte-oriented: validate JSON text. This is the primary API.
local ok = user.validate('{"name":"Ada","age":36,"email":"ada@example.com"}')
-- ok == true

local ok2, err = user.validate('{"name":"Ada","age":"old","email":"ada@example.com"}')
-- ok2 == false, err == "/age: /properties/age/type"

-- Value-oriented: validate an already-decoded table and return the error list.
local errors = user.validate_instance({ name = "Ada" })
-- errors[1] == { instancePath = "", schemaPath = "/properties/age" }
```

| Call | Returns |
|------|---------|
| `validate(chunk)` | `true` when `chunk` is valid JSON text matching the schema |
| `validate(chunk)` | `false, err` otherwise — `err` names the first failure |
| `validate(non_string)` | `false, "expected JSON text (string), got <type>"` |
| `validate_instance(value)` | a list of `{ instancePath, schemaPath }` records; empty list means valid |

Error message formats:

| Situation | `err` |
|-----------|-------|
| Not valid JSON | `invalid JSON at byte 17: expected an object key` |
| Schema violation | `/age: /properties/age/type` |
| Violation at the document root | `/: /properties/email` |
| Unknown property (the emitter reports an empty schema path) | `/extra: /additionalProperties` |

Paths follow RFC 8927: property names are `/`-joined, array elements are **0-based**, and `instancePath` is relative to the failing value. Parse JSON yourself only when you need the decoded value too — `validate` decodes once and discards it.

## What the driver changes, and why

`jtd-codegen --target lua` emits the validation logic, but three things have to be true before that output is a usable Lua 5.1 module. `skills/lua/codegen_validators.lua` performs exactly these edits, and fails loudly instead of silently emitting broken code if the emitter changes:

1. **`require("dkjson")` becomes `require("jtd_json")`.** The emitter uses dkjson for two things only: a `null` sentinel (`dkjson.null`) and `__jsontype` metatables that let its `is_object` / `is_array` helpers tell `{}` from `[]`. The vendored `jtd_json.lua` supplies both in plain Lua, which is what removes the luarocks dependency. The driver rewrites the require, keeps the local name `dkjson` (the emitted body still reads `dkjson.null`), and aborts if the emitter ever references `dkjson.null` without a require it can rewrite.
2. **A facade makes `validate` take JSON text.** The emitter's `M.validate(instance)` returns an error list. The driver appends a facade that renames it `M.validate_instance` and defines `M.validate(chunk) -> true | false, err`. The emitter's trailing `return M` is dropped first, because Lua 5.1 requires `return` to be the last statement of a block.
3. **Definition validators are forward-declared.** The emitter writes `local function validate_<Definition>` bodies in alphabetical order, so a `ref` to a definition that sorts later resolves to a nil global at runtime (for example a `Profile` definition that references `User`). The driver replaces them with one forward declaration plus assignments, leaving the emitted logic byte-identical.

## File naming convention

| Input | Output | Exports |
|-------|--------|---------|
| `schemas/user.jtd.json` | `generated/user.lua` + `generated/user.d.tl` | `validate`, `validate_instance` |
| `schemas/event.jtd.json` | `generated/event.lua` + `generated/event.d.tl` | `validate`, `validate_instance` |
| `schemas/order-item.jtd.json` | `generated/order_item.lua` + `generated/order_item.d.tl` | `validate`, `validate_instance` |

Rules:

1. Schema files use the suffix `.jtd.json`.
2. Generated modules are `<stem>.lua`, with a `<stem>.d.tl` declaration as a sibling. Keep the two together: `tl` finds `<stem>.d.tl` when it resolves `require("<stem>")`.
3. Hyphens in a schema stem become underscores in the module name, since a `require` target reads better without punctuation: `order-item.jtd.json` → `order_item.lua`, `require("order_item")`.
4. Letter case is preserved: `User.jtd.json` → `User.lua`, `require("User")`. Barrel export names are lowercased (`validate_user`).
5. Never edit a generated `.lua` or `.d.tl` by hand — regenerate instead; the driver owns both files.

## Single schema workflow

Schema (`schemas/user.jtd.json`):

```json
{
  "properties": {
    "name": { "type": "string" },
    "age": { "type": "int32" },
    "email": { "type": "string" }
  },
  "optionalProperties": {
    "phone": { "type": "string" }
  }
}
```

Generate the module and its declaration:

```bash
mkdir -p generated
luajit skills/lua/codegen_validators.lua --out generated schemas/user.jtd.json
```

Call it from Lua:

```lua
package.path = "generated/?.lua;skills/lua/?.lua;" .. package.path
local user = require("user")

local ok, err = user.validate('{"name":"Ada","age":36,"email":"ada@example.com"}')
if not ok then
  error("rejected payload: " .. err)
end
```

Call it from Teal:

```lua
local user = require("user")

local ok, err = user.validate('{"name":"Ada","age":36,"email":"ada@example.com"}')
```

`tl check` resolves `user.d.tl` automatically when it sits beside `user.lua` in a directory on the search path, so no extra flags are needed.

## Multiple schemas: barrel re-exports

Each generated module exports `validate`, so requiring several into one scope collides. Pass `--barrel` to emit a barrel module that re-exports every validator under a differentiated name (`validate_` + snake_case schema stem):

| Schema | Generated module | Barrel export |
|--------|------------------|---------------|
| `user.jtd.json` | `user.lua` | `validate_user` |
| `event.jtd.json` | `event.lua` | `validate_event` |
| `order-item.jtd.json` | `order_item.lua` | `validate_order_item` |

```bash
luajit skills/lua/codegen_validators.lua --out generated --barrel validators \
  schemas/*.jtd.json
```

`generated/validators.lua`:

```lua
local M = {}

M.validate_user = require("user").validate
M.validate_instance_user = require("user").validate_instance

M.validate_event = require("event").validate
M.validate_instance_event = require("event").validate_instance

return M
```

Usage, from either language:

```lua
local validators = require("validators")

local ok, err = validators.validate_user('{"name":"Ada","age":36,"email":"a@b.c"}')
local event_ok = validators.validate_event('{"id":"evt-1","created_at":"2026-01-01T00:00:00Z","status":"active"}')
```

The barrel also gets a `validators.d.tl`, so one `tl check` covers every schema in the project.

## Makefile workflow

```makefile
JTD_CODEGEN ?= jtd-codegen
SCHEMA_DIR  := schemas
OUT_DIR     := generated
LUA_SKILL   := ../lua                       # where jtd_json.lua lives
LUAJIT      ?= luajit
SCHEMAS     := $(wildcard $(SCHEMA_DIR)/*.jtd.json)

.PHONY: validators-lua test-validators-lua clean-validators-lua FORCE

validators-lua: FORCE
	@mkdir -p $(OUT_DIR)
	@$(LUAJIT) $(LUA_SKILL)/codegen_validators.lua --out $(OUT_DIR) \
	  --binary $(JTD_CODEGEN) --barrel validators $(SCHEMAS)

test-validators-lua: validators-lua
	@$(LUAJIT) $(LUA_SKILL)/test_validators.lua $(OUT_DIR)

clean-validators-lua:
	rm -rf $(OUT_DIR)

FORCE:
```

`FORCE` keeps the recipe unconditional so schema edits always regenerate. Copy `jtd_json.lua` into your project (or keep a symlink) before your code `require`s a validator.

## Teal type-checking workflow

Each `<stem>.d.tl` declares the module contract:

```lua
local record M
   record JtdError
      instancePath: string
      schemaPath: string
   end

   validate: function(chunk: string): boolean, string
   validate_instance: function(instance: any): {JtdError}
end

return M
```

With the declaration in place `tl check` types every call site, and rejects mistakes:

```
$ tl check callsite.tl
callsite.tl:3:26: argument 1: got integer, expected string
```

Without it the same file reports `no type information for required module: 'user'`. Compile and run Teal call sites the usual way:

```bash
tl check callsite.tl
tl gen callsite.tl            # writes callsite.lua
luajit callsite.lua
```

`jtd_json.d.tl` does the same for the decoder, so Teal code can call `require("jtd_json").decode(text)` and `validate_instance` on the result without a cast.

## Common JTD patterns

| Use case | JTD form |
|----------|----------|
| Required field | `properties` |
| Optional field | `optionalProperties` |
| Nullable string | `{ "type": "string", "nullable": true }` → decoded value may be `null` |
| String-to-string map | `{ "values": { "type": "string" } }` → `{ k = "v" }` |
| Array of values | `{ "elements": { "type": "string" } }` → `{ "a", "b" }` |
| Reusable nested schema | `definitions` plus `{ "ref": "Name" }` |
| Tagged union | `discriminator` + `mapping` |

Unless the schema sets `"additionalProperties": true`, object forms reject unknown keys, so model every key the contract permits. For OpenAPI 3.1, `type: [string, "null"]` maps to `{ "type": "string", "nullable": true }`, and an object with `additionalProperties` maps to `values`.

Lua-specific notes:

- An empty JSON object decodes to a table tagged `object` and an empty JSON array to one tagged `array`; that tagging is what keeps `{}` and `[]` distinguishable, since bare Lua tables are not.
- JSON `null` inside a document decodes to the shared `null` sentinel, never `nil`, so a present-but-null property stays distinguishable from a missing one.
- Numbers are Lua doubles. `int8`…`uint32` are range-checked by the generated code; `float32`/`float64` are type-checked only. Schemas using `int64` or `uint64` are **rejected** by `jtd-codegen`, so represent such fields as strings on the Lua target.
- `timestamp` validation is a structural RFC 3339 check (component ranges plus offset shape), not a calendar check.
- Validation is single-error-per-check but not fail-fast: `validate_instance` collects every error it finds, while `validate` reports the first.

## Agent checklist

When adding JTD Lua validators to a project:

1. Put schemas in `schemas/*.jtd.json`.
2. Copy `jtd_json.lua` (and optionally `jtd_json.d.tl`) from `skills/lua/` into the project, and add the directory to `package.path`.
3. Run `codegen_validators.lua --out generated [--barrel validators] schemas/*.jtd.json`; commit `generated/` if you want zero-codegen deploys, otherwise add it to `.gitignore` and wire the Makefile target into your build.
4. For multiple schemas, always use `--barrel` so call sites get `validate_<stem>` instead of several colliding `validate` names.
5. Keep each `.lua` next to its `.d.tl`, and run `tl check` on the directories that call them.
6. Run `test_validators.lua <generated-dir>` after codegen to confirm the valid/invalid cases still hold.
7. Do not edit generated modules; change the schema and regenerate.

## Local verification (this repo)

A runnable fixture lives in `skills/fixture/`, and the committed reference output lives in `skills/lua/`:

```bash
# Build the codegen binary once (or use the installed jtd-codegen)
cargo build --release -p jtd-codegen

# Makefile path: generate for user, event and advanced schemas, then test
cd skills/fixture && make test-validators-lua

# Direct path
cd ../..
JTD_CODEGEN=target/release/jtd-codegen \
  luajit skills/lua/codegen_validators.lua --out /path/to/out --barrel validators \
  skills/fixture/schemas/*.jtd.json
luajit skills/lua/test_validators.lua /path/to/out
```

Both paths print `Lua validator fixture test PASSED`. The committed sample is regenerated with:

```bash
luajit skills/lua/codegen_validators.lua --out skills/lua \
  skills/fixture/schemas/user.jtd.json
luajit skills/lua/test_validators.lua          # 12 cases against skills/lua/user.lua
cd skills/lua && tl check test_callsite.tl     # Teal declaration type-checks
```

## Reference

- CLI: `jtd-codegen --target lua <schema.jtd.json>` writes a Lua module to stdout.
- Emitter: `jtd-codegen/src/emit_lua/emit.rs` (validators) and `emit_lua/context.rs` (error records).
- Runtime shim: `skills/lua/jtd_json.lua`; codegen driver: `skills/lua/codegen_validators.lua`.
- Repo examples: `examples/01_simple_user/schema.jtd.json`, `examples/02_complex_event/schema.jtd.json`.
- Full test suite: `xmake run test_all` (includes Lua validation of the Rust-emitted modules via mlua).
