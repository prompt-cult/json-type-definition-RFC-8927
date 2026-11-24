# Demo System

The demo system provides an interactive browser-based playground to test JTD validators compiled by `jtd-codegen`.

## Structure

```
examples/
├── index.html              # Main demo UI (Preact + HTM + Tailwind)
├── nginx.conf.template     # Nginx config template with {{placeholders}}
├── nginx.conf             # Generated nginx config (gitignored)
└── NN_example_name/       # Numbered example directories
    ├── schema.jtd.json    # JTD schema definition
    └── validator.js       # Generated validator (gitignored)
```

## Workflow

### 1. Build the Binary

```bash
xmake run demo_build
```

Compiles `jtd-codegen` in release mode to `target/release/jtd-codegen`.

### 2. Initialize Demo

```bash
xmake run demo_init
```

Generates `examples/nginx.conf` from `nginx.conf.template`:
- Replaces `{{PROJECT_DIR}}` with absolute path
- Replaces `{{NGINX_MIME_TYPES}}` with detected mime.types location

### 3. Compile Validators

```bash
xmake run demo_compile
```

For each `examples/NN_*/schema.jtd.json`:
- Runs `jtd-codegen --target js schema.jtd.json`
- Writes output to `validator.js`

### 4. Start Server

```bash
xmake run demo_start
```

Launches nginx on http://localhost:8080/ serving the demo UI.

### All-in-One

```bash
xmake run demo
```

Runs all four steps sequentially.

## Adding Examples

1. Create numbered directory: `examples/03_my_example/`
2. Add JTD schema: `examples/03_my_example/schema.jtd.json`
3. Update `index.html` examples array with test cases
4. Run `xmake run demo_compile`

The demo UI dynamically loads validators via ES modules:

```javascript
const validatorModule = await import('./01_simple_user/validator.js');
const errors = validatorModule.validate(jsonData);
```

## Requirements

- nginx (brew install nginx)
- Rust toolchain
- Modern browser with ES module support
