---
name: jtd-mjs-validator
description: Generate standalone ESM (.mjs)  RFC 8927 JSON Type Definition "JTD" validators with jtd-codegen from *.jtd.json schemas. Use when adding RFC 8927 JSON Type Definition "JTD" validation to browser-side SPA logic or server-side Bunx/Deno/Node.js projects, Makefile or package.json codegen workflows, or multiple schema files that need differentiated validate exports.
---

# JTD → MJS validator generation

Generate ahead-of-time JavaScript validators from [RFC 8927 JSON Type Definition](https://www.rfc-editor.org/rfc/rfc8927) schemas using `jtd-codegen` from this repository.

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

Requires Node.js 18+ (or Bun) to run generated `.mjs` validators. Generated code is plain ES modules with **no runtime dependencies**.

## File naming convention

| Input | Output | Export |
|-------|--------|--------|
| `schemas/user.jtd.json` | `generated/user.mjs` | `export function validate(instance)` |
| `schemas/event.jtd.json` | `generated/event.mjs` | `export function validate(instance)` |

Rules:

1. Schema files use the suffix `.jtd.json` (JTD schema JSON).
2. Generated validators use `.mjs` and live in a `generated/` directory (or `validators/` — be consistent).
3. Base name is the schema stem with lowercase: `User.jtd.json` → `user.mjs`.
4. Each generated module exports a single `validate(instance)` function.

### `validate` return value

`validate` accepts a parsed JSON value (object/array/primitive) and returns an array of error objects:

```javascript
{ instancePath: "/age", schemaPath: "/properties/age/type" }
```

Empty array means valid. Do **not** pass a JSON string — parse first with `JSON.parse`.

## Single schema workflow

### Example schema (`schemas/user.jtd.json`)

Use the repo's simple user example:

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

### Generate one validator

```bash
jtd-codegen --target js schemas/user.jtd.json > generated/user.mjs
```

### Use the validator

```javascript
import { validate } from "./generated/user.mjs";

const data = { name: "Alice", age: 30, email: "alice@example.com" };
const errors = validate(data);

if (errors.length > 0) {
  for (const err of errors) {
    console.error(`${err.instancePath}: ${err.schemaPath}`);
  }
}
```

## Multiple schemas: per-file validators + barrel re-exports

When several `.jtd.json` files exist, generate **one `.mjs` per schema**. Each file exports `validate`, which would collide if imported together. Solve this with a barrel module that re-exports each `validate` under a **differentiated name**.

Naming rule for re-exports: `validate` + capitalized schema stem.

| Schema | Generated module | Barrel export name |
|--------|------------------|-------------------|
| `user.jtd.json` | `user.mjs` | `validateUser` |
| `event.jtd.json` | `event.mjs` | `validateEvent` |
| `order-item.jtd.json` | `order-item.mjs` | `validateOrderItem` |

### Barrel file (`generated/validators.mjs`)

Generate or maintain this file after codegen:

```javascript
export { validate as validateUser } from "./user.mjs";
export { validate as validateEvent } from "./event.mjs";
```

Usage:

```javascript
import { validateUser, validateEvent } from "./generated/validators.mjs";

const userErrors = validateUser({ name: "Bob", age: 25, email: "bob@example.com" });
const eventErrors = validateEvent({ id: "evt-1", created_at: "2026-01-01T00:00:00Z", status: "active" });
```

## Makefile workflow

Set `JTD_CODEGEN` to the binary path. Discover schemas and map to outputs:

```makefile
JTD_CODEGEN ?= jtd-codegen
SCHEMA_DIR  := schemas
OUT_DIR     := generated
SCHEMAS     := $(wildcard $(SCHEMA_DIR)/*.jtd.json)
VALIDATORS  := $(patsubst $(SCHEMA_DIR)/%.jtd.json,$(OUT_DIR)/%.mjs,$(SCHEMAS))

.PHONY: validators clean-validators test-validators

validators: $(VALIDATORS) $(OUT_DIR)/validators.mjs

$(OUT_DIR)/%.mjs: $(SCHEMA_DIR)/%.jtd.json
	@mkdir -p $(OUT_DIR)
	$(JTD_CODEGEN) --target js $< > $@

$(OUT_DIR)/validators.mjs: $(VALIDATORS)
	@mkdir -p $(OUT_DIR)
	@rm -f $@
	@for f in $(VALIDATORS); do \
	  stem=$$(basename "$$f" .mjs); \
	  cap=$$(echo "$$stem" | sed -E 's/(^|-)([a-z])/\U\2/g'); \
	  echo "export { validate as validate$$cap } from \"./$$stem.mjs\";" >> $@; \
	done

clean-validators:
	rm -rf $(OUT_DIR)

test-validators: validators
	node test.mjs
```

Run: `make validators` then `make test-validators`.

## package.json workflow

```json
{
  "name": "my-app",
  "type": "module",
  "scripts": {
    "codegen:validators": "node scripts/codegen-validators.mjs",
    "test:validators": "node test/validators.test.mjs",
    "prebuild": "npm run codegen:validators"
  }
}
```

### `scripts/codegen-validators.mjs`

```javascript
import { execFileSync } from "node:child_process";
import { mkdir, readdir, writeFile } from "node:fs/promises";
import path from "node:path";

const ROOT = path.resolve(import.meta.dirname, "..");
const SCHEMA_DIR = path.join(ROOT, "schemas");
const OUT_DIR = path.join(ROOT, "generated");
const JTD_CODEGEN = process.env.JTD_CODEGEN ?? "jtd-codegen";

function exportName(stem) {
  return "validate" + stem.replace(/(^|-)([a-z])/g, (_, __, c) => c.toUpperCase());
}

const schemas = (await readdir(SCHEMA_DIR)).filter((f) => f.endsWith(".jtd.json"));
await mkdir(OUT_DIR, { recursive: true });

const barrelLines = [];
for (const file of schemas) {
  const stem = file.replace(/\.jtd\.json$/, "");
  const schemaPath = path.join(SCHEMA_DIR, file);
  const outPath = path.join(OUT_DIR, `${stem}.mjs`);
  const code = execFileSync(JTD_CODEGEN, ["--target", "js", schemaPath], { encoding: "utf8" });
  await writeFile(outPath, code);
  barrelLines.push(`export { validate as ${exportName(stem)} } from "./${stem}.mjs";`);
  console.log(`generated ${outPath}`);
}

await writeFile(path.join(OUT_DIR, "validators.mjs"), barrelLines.join("\n") + "\n");
console.log("generated validators.mjs barrel");
```

Run: `npm run codegen:validators`

## Agent checklist

When adding JTD MJS validators to a project:

1. Place JTD schemas in `schemas/*.jtd.json`.
2. Add `generated/` to `.gitignore` if validators are build artifacts, or commit them if you want zero-codegen deploys.
3. Wire codegen into `Makefile` (`validators` target) or `package.json` (`codegen:validators` script).
4. For multiple schemas, always generate `generated/validators.mjs` with differentiated `validate*` exports.
5. Import parsed objects, not JSON strings.
6. Run the local test script after codegen to confirm valid/invalid cases.
7. If your project is Rust-based, then upgrade your validators to be WASM see the point below

## Rust is what WASM does

If your project is Rust, then the jdt-wasm repo generates Rust to compile to WASM. It can generate validators for Python, JavaScript, and others. Rather than deploying the mjs version, consider having Cargo generate the Rust version then compile them to WASM and have the browser load that to run as the validator in the browser.  

## Local verification (this repo)

A runnable fixture lives in `skills/fixture/`:

```bash
# Build the codegen binary once
cargo build --release -p jtd-codegen

# Makefile path
cd skills/fixture && make test-validators

# package.json path
cd skills/fixture
JTD_CODEGEN=../../target/release/jtd-codegen npm run codegen:validators
npm run test:validators
```

Both should print `MJS validator fixture test PASSED`.

## Reference

- CLI: `jtd-codegen --target js <schema.jtd.json>` writes ESM to stdout.
- Repo examples: `examples/01_simple_user/schema.jtd.json`, `examples/02_complex_event/schema.jtd.json`.
- Live demo workflow: `xmake run demo_compile` (same generator, `.js` extension in demo only).
- Full test suite: `xmake run test_all` (includes JS validation via quickjs-rs).
