---
name: jtd-py-validator
description: Generate standalone Python 3.13+ JTD validators with jtd-codegen from *.jtd.json schemas. Use when adding JTD validation to Python projects, Makefile or pyproject.toml codegen workflows, or multiple schema files that need differentiated validate exports.
---

# JTD → Python validator generation

Generate ahead-of-time Python validators from [RFC 8927 JSON Type Definition](https://www.rfc-editor.org/rfc/rfc8927) schemas using `jtd-codegen` from this repository.

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

Requires **Python 3.9+** to run generated `.py` validators. Generated code uses only the **standard library** — no third-party dependencies.

## File naming convention

| Input | Output | Export |
|-------|--------|--------|
| `schemas/user.jtd.json` | `generated/user.py` | `def validate(instance)` |
| `schemas/event.jtd.json` | `generated/event.py` | `def validate(instance)` |

Rules:

1. Schema files use the suffix `.jtd.json` (JTD schema JSON).
2. Generated validators use `.py` and live in a `generated/` directory (or `validators/` — be consistent).
3. Base name is the schema stem with lowercase: `User.jtd.json` → `user.py`.
4. Each generated module exports a single `validate(instance)` function.

### `validate` return value

`validate` accepts a parsed JSON value (dict/list/primitive) and returns a list of error dicts:

```python
{"instancePath": "/age", "schemaPath": "/properties/age/type"}
```

Empty list means valid. Do **not** pass a JSON string — parse first with `json.loads`.

## Common JTD patterns

| Use case | JTD form |
|----------|----------|
| Required field | `properties` |
| Optional field | `optionalProperties` |
| Nullable string | `{ "type": "string", "nullable": true }` |
| String-to-string map | `{ "values": { "type": "string" } }` |
| Array of values | `{ "elements": { "type": "string" } }` |
| Reusable nested schema | `definitions` plus `{ "ref": "Name" }` |

`properties` fields must be present; `optionalProperties` fields may be absent. Unless the schema sets `"additionalProperties": true`, object forms reject unknown keys, so model only the keys the API contract permits. For OpenAPI 3.1, a field with `type: [string, "null"]` maps to `{ "type": "string", "nullable": true }`; an object with `additionalProperties` maps to `values`.

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
jtd-codegen --target python schemas/user.jtd.json > generated/user.py
```

### Use the validator

```python
import json
from generated.user import validate

data = {"name": "Alice", "age": 30, "email": "alice@example.com"}
errors = validate(data)

if errors:
    for err in errors:
        print(f"{err['instancePath']}: {err['schemaPath']}")
```

## Multiple schemas: per-file validators + barrel re-exports

When several `.jtd.json` files exist, generate **one `.py` per schema**. Each file defines `validate`, which would collide if imported together. Solve this with a package barrel (`__init__.py`) that re-exports each `validate` under a **differentiated name**.

Naming rule for re-exports: `validate_` + snake_case schema stem.

| Schema | Generated module | Barrel export name |
|--------|------------------|-------------------|
| `user.jtd.json` | `user.py` | `validate_user` |
| `event.jtd.json` | `event.py` | `validate_event` |
| `order-item.jtd.json` | `order_item.py` | `validate_order_item` |

### Barrel file (`generated/__init__.py`)

Generate or maintain this file after codegen:

```python
from .user import validate as validate_user
from .event import validate as validate_event
```

Usage:

```python
from generated import validate_user, validate_event

user_errors = validate_user({"name": "Bob", "age": 25, "email": "bob@example.com"})
event_errors = validate_event(
    {"id": "evt-1", "created_at": "2026-01-01T00:00:00Z", "status": "active"}
)
```

## Makefile workflow

Set `JTD_CODEGEN` to the binary path. Discover schemas and map to outputs (hyphens in schema stems become underscores in `.py` filenames):

```makefile
JTD_CODEGEN ?= jtd-codegen
SCHEMA_DIR  := schemas
OUT_DIR     := generated
SCHEMAS     := $(wildcard $(SCHEMA_DIR)/*.jtd.json)

.PHONY: validators clean-validators test-validators FORCE

validators: $(OUT_DIR)/__init__.py

$(OUT_DIR)/__init__.py: FORCE
	@mkdir -p $(OUT_DIR)
	@rm -f $(OUT_DIR)/*.py $(OUT_DIR)/__init__.py
	@for schema in $(SCHEMAS); do \
	  stem=$$(basename "$$schema" .jtd.json); \
	  snake=$$(echo "$$stem" | sed 's/-/_/g'); \
	  $(JTD_CODEGEN) --target python "$$schema" > "$(OUT_DIR)/$$snake.py"; \
	done
	@for schema in $(SCHEMAS); do \
	  stem=$$(basename "$$schema" .jtd.json); \
	  snake=$$(echo "$$stem" | sed 's/-/_/g'); \
	  echo "from .$$snake import validate as validate_$$snake" >> $@; \
	done

FORCE:

clean-validators:
	rm -rf $(OUT_DIR)

test-validators: validators
	python3 test_py.py
```

Run: `make validators` then `make test-validators`.

## pyproject.toml workflow

```toml
[project]
name = "my-app"
requires-python = ">=3.9"

[project.scripts]
# optional: expose CLI entry points

[tool.setuptools]
packages = ["generated"]

[project.optional-dependencies]
dev = []

[tool.hatch.envs.default.scripts]
codegen-validators = "python scripts/codegen-validators.py"
test-validators = "python test_py.py"
```

If you use plain `setuptools` without Hatch, add equivalent scripts to `pyproject.toml` under `[project.scripts]` or use a `Makefile` target that calls the codegen script directly.

### `scripts/codegen-validators.py`

```python
#!/usr/bin/env python3
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCHEMA_DIR = ROOT / "schemas"
OUT_DIR = ROOT / "generated"
JTD_CODEGEN = os.environ.get("JTD_CODEGEN", "jtd-codegen")


def export_name(stem: str) -> str:
    return "validate_" + stem.replace("-", "_")


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for generated_path in OUT_DIR.glob("*.py"):
        generated_path.unlink()

    barrel_lines: list[str] = []

    for schema_path in sorted(SCHEMA_DIR.glob("*.jtd.json")):
        stem = schema_path.name.removesuffix(".jtd.json")
        snake = stem.replace("-", "_")
        out_path = OUT_DIR / f"{snake}.py"
        code = subprocess.check_output(
            [JTD_CODEGEN, "--target", "python", str(schema_path)],
            text=True,
        )
        out_path.write_text(code)
        barrel_lines.append(f"from .{snake} import validate as {export_name(stem)}")
        print(f"generated {out_path.relative_to(ROOT)}")

    (OUT_DIR / "__init__.py").write_text("\n".join(barrel_lines) + "\n")
    print("generated __init__.py barrel")


if __name__ == "__main__":
    main()
```

Run: `python scripts/codegen-validators.py` or `hatch run codegen-validators` (if using Hatch).

### setup.py workflow (legacy)

For projects still using `setup.py`, call the same codegen script from a custom command or Makefile:

```python
# setup.py (snippet)
from setuptools import setup
from setuptools.command.build_py import build_py
import subprocess

class BuildPy(build_py):
    def run(self):
        subprocess.check_call(["python", "scripts/codegen-validators.py"])
        super().run()

setup(cmdclass={"build_py": BuildPy})
```

## Agent checklist

When adding JTD Python validators to a project:

1. Place JTD schemas in `schemas/*.jtd.json`.
2. Add `generated/` to `.gitignore` if validators are build artifacts, or commit them if you want zero-codegen deploys.
3. Wire codegen into `Makefile` (`validators` target) or `pyproject.toml` / `scripts/codegen-validators.py`.
4. For multiple schemas, always generate `generated/__init__.py` with differentiated `validate_*` exports.
5. Pass parsed dicts/lists, not JSON strings.
6. Run the local test script after codegen to confirm valid/invalid cases.

## Local verification (this repo)

A runnable fixture lives in `skills/fixture/`:

```bash
# Build the codegen binary once
cargo build --release -p jtd-codegen

# Makefile path
cd skills/fixture && make test-validators-py

# pyproject.toml path
cd skills/fixture
JTD_CODEGEN=../../target/release/jtd-codegen python scripts/codegen-validators.py
python test_py.py
```

Both should print `Python validator fixture test PASSED`.

## Reference

- CLI: `jtd-codegen --target python <schema.jtd.json>` writes a Python module to stdout.
- Emitter source: `jtd-codegen/src/emit_py/`.
- Repo examples: `examples/01_simple_user/schema.jtd.json`, `examples/02_complex_event/schema.jtd.json`.
- Full test suite: `xmake run test_all` (includes Python validation via subprocess).
