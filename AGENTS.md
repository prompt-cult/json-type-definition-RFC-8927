# AGENTS.md

## Purpose & Scope
Operational guidance for human and AI agents working in `jtd-wasm`. This document supplements the user-facing `README.md` and `JTD_CODEGEN_SPEC.md` with developer-centric workflows and policies.

## Operating Principles
- **Zero Tolerance for Warnings**: `xmake run check` (fmt + clippy) must pass before any commit.
- **Mandatory Verification**: Run `xmake run test_all` before verifying a task complete.
- **Cross-Platform Compatibility**: Ensure `xmake run test_all` passes on macOS and Linux.
- **Windows Policy**: See "Windows Testing Strategy" below.

## Testing Strategy

### 1. Compatibility Suite
We validate against the official [json-typedef-spec](https://github.com/jsontypedef/json-typedef-spec) test suite.
- **Source**: `.tmp/json-typedef-spec` (fetched via `xmake run fetch_suite`)
- **Verification**: SHA256 checksums enforce suite integrity.

### 2. Supported Targets & Environments
- **Rust (Native)**: Tested on all platforms (macOS, Linux, Windows).
- **WebAssembly (WASI)**: Tested on all platforms via `wasmtime`.
- **JavaScript (ESM)**: Tested on macOS/Linux via `quickjs-rs`.
- **Lua (5.1/LuaJIT)**: Tested on all platforms via `mlua` + `dkjson`.
- **Python (3.11+)**: Tested on macOS/Linux via `python3` subprocess.

### 3. Windows Testing Strategy
We strictly enforce **Rust → Rust** and **Rust → WASM** correctness on Windows. However, we **skip JavaScript validation tests on Windows** (`test_js` target).

**Reasoning:**
- **Not a workaround**: This is an intentional policy, not a temporary hack.
- **Core Value**: Our primary deliverable for Windows users is the Rust-based code generator. The generated JavaScript logic is identical across all platforms (it is deterministic string emission).
- **Tooling Limitations**: The `quickjs-rs` crate (our test harness for JS) does not currently compile on MSVC Windows. We decline to maintain a complex C/C++ build toolchain just to run the JS test harness on Windows when the generator logic is already verified on Linux/macOS.
- **Confidence**: Since `jtd-codegen` produces identical output regardless of the host OS, verifying the JS output on Linux/macOS provides sufficient confidence for Windows users deploying that same JS code.
- **Full-Stack Rust**: Windows users targeting the browser should prefer our **WASM** path (`Rust -> Rust -> WASM`), which is fully tested and supported on Windows.

## Development Workflows

### Running Tests
```bash
# Full suite (fmt, clippy, fetch spec, run all tests)
xmake run test_all

# Specific targets
xmake run test_rust
xmake run test_js   # Skips on Windows
xmake run test_lua
xmake run test_py
xmake run test_wasm
```

### Git Hooks
Install the pre-commit hook to prevent accidental regressions:
```bash
xmake run install_hooks
```

### Definition-to-Main Workflow (mandatory)

All changes go through the issue -> branch -> PR flow. Master is protected
with required status checks, so nothing lands without green CI.

1. `gh issue create` describing the defect or work item (`gh issue -n` = its number).
2. Branch from `origin/master` named after the issue: `issue-<numbers>`.
3. Work the issue; commit conventional-style (`feat:`, `fix:`, `test:`, ...).
4. Push the branch, `gh pr create --base master`, then arm auto-merge:
   `gh pr merge --squash --auto`.
5. Monitor to merge (blocking poll loop, not `--watch`). Required checks:
   `Test (macos-latest)`, `Test (ubuntu-latest)`, `Test (windows-latest)`.
6. Long-running work is tracked in the ticketing plugin (gh issue <-> ticket NNN).

Note: `--auto` merges the moment required checks pass, but only if branch
protection demands those checks AND repo settings allow auto-merge; verify
both before trusting the gate.

### Release Process
1. Bump version in `jtd-codegen/Cargo.toml`.
2. Commit and tag: `git tag release/x.y.z`.
3. Push tag: `git push origin release/x.y.z`.
4. GitHub Actions will build and attach binaries for macOS, Linux, and Windows.
