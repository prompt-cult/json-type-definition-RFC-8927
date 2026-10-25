---
name: jtd-rs-validator
description: Generate standalone Rust JTD validators with jtd-codegen from *.jdt.json schemas. Use when adding JTD validation to Rust projects, build.rs or Makefile codegen workflows, multiple schema files with differentiated validator exports, or wasm-pack validation packages.
---

# JTD → Rust validator generation

Generate ahead-of-time Rust validators from [RFC 8927 JSON Type Definition](https://www.rfc-editor.org/rfc/rfc8927) schemas using `jtd-codegen` from this repository.

## Prerequisites

Install `jtd-codegen`:

```bash
# From this repository
cargo install --path jtd-codegen
# Or build without installing:
cargo build --release -p jtd-codegen
# binary: target/release/jtd-codegen
```

Generated validators require this runtime dependency:

```toml
[dependencies]
serde_json = "1"
```

Schemas that use JTD `"type": "timestamp"` also require:

```toml
regex = "1"
chrono = "0.4"
```

## Validator API

Each generated module exports:

```rust
pub fn validate(instance: &serde_json::Value) -> Vec<(String, String)>
```

Each tuple is `(instance_path, schema_path)`. An empty vector means the instance is valid.

```rust
use serde_json::json;

let errors = generated::validate(&json!({"name": "Alice"}));
for (instance_path, schema_path) in errors {
    eprintln!("{instance_path}: {schema_path}");
}
```

Pass a parsed `serde_json::Value`, not a JSON string. Parse strings with
`serde_json::from_str` first.

## Single schema workflow

Given `schemas/user.jdt.json`:

```json
{
  "properties": {
    "name": { "type": "string" },
    "age": { "type": "int32" }
  }
}
```

Generate a module:

```bash
mkdir -p src/generated
jtd-codegen --target rust schemas/user.jdt.json > src/generated/user.rs
```

Include and call it from Rust:

```rust
use serde_json::Value;

#[allow(clippy::all)]
mod user_validator {
    include!("generated/user.rs");
}

fn validate_user(value: &Value) {
    let errors = user_validator::validate(value);
    assert!(errors.is_empty());
}
```

## Multiple schemas: `mod.rs` re-exports

Generate one `.rs` module per schema. Since every generated module exports
`validate`, re-export them under distinct snake_case names:

| Schema | Generated module | Re-export |
|---|---|---|
| `user.jdt.json` | `user.rs` | `validate_user` |
| `event.jdt.json` | `event.rs` | `validate_event` |
| `order-item.jdt.json` | `order_item.rs` | `validate_order_item` |

`src/generated/mod.rs`:

```rust
pub mod user;
pub mod event;
pub mod order_item;

pub use user::validate as validate_user;
pub use event::validate as validate_event;
pub use order_item::validate as validate_order_item;
```

Then import the validators without name collisions:

```rust
use crate::generated::{validate_event, validate_user};
use serde_json::json;

assert!(validate_user(&json!({"name": "Alice", "age": 30})).is_empty());
assert!(validate_event(&json!({"id": "evt-1"})).is_empty());
```

## `build.rs` workflow

Use build-time code generation when generated source should not be committed.
Add the generator and parser as build dependencies:

```toml
[build-dependencies]
jtd-codegen = { path = "../jtd-codegen" } # Or use the matching published crate version
serde_json = "1"
```

`build.rs`:

```rust
fn main() {
    let schema_path = "schemas/user.jdt.json";
    println!("cargo:rerun-if-changed={schema_path}");

    let schema_text = std::fs::read_to_string(schema_path)
        .expect("cannot read JTD schema");
    let schema: serde_json::Value = serde_json::from_str(&schema_text)
        .expect("invalid JTD schema JSON");
    let compiled = jtd_codegen::compiler::compile(&schema)
        .expect("invalid JTD schema");
    let code = jtd_codegen::emit_rs::emit(&compiled);

    let output = std::path::PathBuf::from(std::env::var("OUT_DIR").unwrap())
        .join("user_validator.rs");
    std::fs::write(output, code).expect("cannot write generated validator");
}
```

`src/lib.rs`:

```rust
#[allow(clippy::all)]
#[allow(unused_imports)]
mod user_validator {
    include!(concat!(env!("OUT_DIR"), "/user_validator.rs"));
}

pub use user_validator::validate;
```

This mirrors `jtd-wasm-validator/build.rs` in this repository.

## Makefile workflow

This recipe discovers all schemas, writes snake_case Rust modules, and
regenerates `mod.rs` re-exports:

```makefile
JTD_CODEGEN ?= jtd-codegen
SCHEMA_DIR  := schemas
OUT_DIR     := src/generated
SCHEMAS     := $(wildcard $(SCHEMA_DIR)/*.jdt.json)

.PHONY: validators clean-validators FORCE

validators: $(OUT_DIR)/mod.rs

$(OUT_DIR)/mod.rs: FORCE
	@mkdir -p $(OUT_DIR)
	@rm -f $(OUT_DIR)/*.rs
	@for schema in $(SCHEMAS); do \
	  stem=$$(basename "$$schema" .jdt.json); \
	  snake=$$(echo "$$stem" | sed 's/-/_/g'); \
	  $(JTD_CODEGEN) --target rust "$$schema" > "$(OUT_DIR)/$$snake.rs"; \
	  echo "pub mod $$snake;" >> $@; \
	  echo "pub use $$snake::validate as validate_$$snake;" >> $@; \
	done

FORCE:

clean-validators:
	rm -rf $(OUT_DIR)
```

Run `make validators`, then build or test the crate with Cargo.

## WASM workflow (`wasm-pack`)

Create a `cdylib` package that parses JSON strings at the WebAssembly boundary
and returns JavaScript error objects.

`Cargo.toml`:

```toml
[lib]
crate-type = ["cdylib", "rlib"]

[dependencies]
wasm-bindgen = "0.2"
js-sys = "0.3"
serde_json = "1"
```

Generate the module through the `build.rs` workflow above, then use:

```rust
use wasm_bindgen::prelude::*;

#[allow(clippy::all)]
#[allow(unused_imports)]
mod generated {
    include!(concat!(env!("OUT_DIR"), "/user_validator.rs"));
}

#[wasm_bindgen]
pub fn validate(instance_json: &str) -> Result<JsValue, JsError> {
    let instance: serde_json::Value = serde_json::from_str(instance_json)
        .map_err(|error| JsError::new(&format!("Invalid JSON: {error}")))?;

    let errors = generated::validate(&instance);
    let result = js_sys::Array::new();
    for (instance_path, schema_path) in errors {
        let error = js_sys::Object::new();
        js_sys::Reflect::set(&error, &"instancePath".into(), &instance_path.into()).unwrap();
        js_sys::Reflect::set(&error, &"schemaPath".into(), &schema_path.into()).unwrap();
        result.push(&error);
    }
    Ok(result.into())
}
```

Build the package:

```bash
wasm-pack build --target web
```

This follows the repository's `jtd-wasm-validator` crate: `cdylib`,
`#[wasm_bindgen]`, and a `JsValue` return containing `{ instancePath,
schemaPath }` objects.

## Agent checklist

1. Put schemas in `schemas/*.jdt.json`.
2. Add `serde_json` to runtime dependencies; add `regex` and `chrono` only if
   any schema uses `timestamp`.
3. Choose committed source (`Makefile`) or build artifacts (`build.rs` and
   `OUT_DIR`), and add generated source to `.gitignore` when appropriate.
4. For multiple schemas, generate `mod.rs` and differentiate every exported
   validator as `validate_<snake_case_schema_name>`.
5. Call `validate(&Value)`, then report each `(instance_path, schema_path)`
   tuple.
6. For browser use, expose a wasm-bindgen wrapper that converts tuples to
   JavaScript error objects.

## Local verification (this repository)

Fixture schemas are in `skills/fixture/schemas/`: `user.jdt.json`,
`event.jdt.json` (which exercises `timestamp`), and `advanced.jdt.json`.

```bash
cargo build --release -p jtd-codegen
target/release/jtd-codegen --target rust skills/fixture/schemas/user.jdt.json \
  > /tmp/user_validator.rs
target/release/jtd-codegen --target rust skills/fixture/schemas/event.jdt.json \
  > /tmp/event_validator.rs

# Compile and run all repository validation targets.
xmake run test_rust
xmake run test_wasm
```

For the full repository check, run `xmake run test_all`.

## Reference

- CLI: `jtd-codegen --target rust <schema.jdt.json>` writes a Rust module to stdout.
- Emitter: `jtd-codegen/src/emit_rs/emit.rs`.
- Build-time example: `jtd-wasm-validator/build.rs`.
- WASM wrapper: `jtd-wasm-validator/src/lib.rs`.
