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
