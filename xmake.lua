-- xmake orchestration for compatibility tests.
--
-- Run:
--   xmake run fetch_suite
--   xmake run test_rust
--   xmake run test_js
--   xmake run test_all

local JSON_TYPEDEF_SPEC_COMMIT = "71ca275847318717c36f5a2322a8061070fe185d"
local VALIDATION_SHA256 = "ca2ee582044051a690e0a5b79e81f26f4a51623d8a5b73f7a1d488b6e7b11994"

local INVALID_SCHEMAS_SHA256 = "96ac0ab36d73389f2bca1f64896213cf4d30bfc88be8de7b6f1a633cc07be26d"

target("check")
    set_kind("phony")
    on_run(function ()
        cprint("${cyan}Formatting:${clear} cargo fmt --all -- --check")
        os.vrunv("cargo", {"fmt", "--all", "--", "--check"})
        
        cprint("${cyan}Linting:${clear} cargo clippy --workspace -- -D warnings")
        os.vrunv("cargo", {"clippy", "--workspace", "--", "-D", "warnings"})
        
        cprint("${green}OK:${clear} Code quality checks passed")
    end)
target_end()

target("install_hooks")
    set_kind("phony")
    on_run(function ()
        local hook_src = path.join(os.projectdir(), "scripts", "pre-commit")
        local hook_dst = path.join(os.projectdir(), ".git", "hooks", "pre-commit")
        
        os.cp(hook_src, hook_dst)
        
        if os.host() ~= "windows" then
            os.execv("chmod", {"+x", hook_dst})
        end
        
        cprint("${green}Installed pre-commit hook to .git/hooks/pre-commit${clear}")
    end)
target_end()

target("fetch_suite")
    set_kind("phony")
    on_run(function ()
        local dir = path.join(os.projectdir(), ".tmp", "json-typedef-spec", JSON_TYPEDEF_SPEC_COMMIT, "tests")
        local validation = path.join(dir, "validation.json")
        local invalid = path.join(dir, "invalid_schemas.json")
        local dkjson = path.join(os.projectdir(), ".tmp", "dkjson.lua")

        os.mkdir(dir)

        local base = "https://raw.githubusercontent.com/jsontypedef/json-typedef-spec/" .. JSON_TYPEDEF_SPEC_COMMIT .. "/tests/"
        os.vrunv("curl", {"-f", "-s", "-S", "-L", base .. "validation.json", "-o", validation})
        os.vrunv("curl", {"-f", "-s", "-S", "-L", base .. "invalid_schemas.json", "-o", invalid})
        
        -- Fetch dkjson.lua for Lua testing
        os.vrunv("curl", {"-f", "-s", "-S", "-L", "https://raw.githubusercontent.com/LuaDist/dkjson/master/dkjson.lua", "-o", dkjson})

        local function sha256(filepath)
            if os.host() == "windows" then
                -- certutil outputs: "SHA256 hash of file:\n<hex>\nCertUtil: ..."
                local out = os.iorunv("certutil", {"-hashfile", filepath, "SHA256"})
                return out:match("\n(%w+)\n")
            else
                -- shasum works on macOS and Linux
                local out = os.iorunv("shasum", {"-a", "256", filepath})
                return out:match("^(%w+)")
            end
        end

        local vhash = sha256(validation)
        if vhash ~= VALIDATION_SHA256 then
            raise("validation.json sha256 mismatch: expected " .. VALIDATION_SHA256 .. ", got " .. tostring(vhash))
        end

        local ihash = sha256(invalid)
        if ihash ~= INVALID_SCHEMAS_SHA256 then
            raise("invalid_schemas.json sha256 mismatch: expected " .. INVALID_SCHEMAS_SHA256 .. ", got " .. tostring(ihash))
        end

        cprint("${green}Fetched json-typedef-spec tests at ${clear}" .. JSON_TYPEDEF_SPEC_COMMIT)
        cprint("${green}" .. validation .. "${clear}")
    end)
target_end()

target("test_rust")
    set_kind("phony")
    on_run(function ()
        cprint("${cyan}Running:${clear} fetch_suite")
        os.vrunv("xmake", {"run", "fetch_suite"})
        local validation = path.join(os.projectdir(), ".tmp", "json-typedef-spec", JSON_TYPEDEF_SPEC_COMMIT, "tests", "validation.json")
        os.setenv("JTD_VALIDATION_JSON", validation)
        cprint("${cyan}Running:${clear} cargo test -p jtd-codegen --test rs_validation_suite -- --nocapture")
        os.vrunv("cargo", {"test", "-p", "jtd-codegen", "--test", "rs_validation_suite", "--", "--nocapture"})
        cprint("${green}OK:${clear} test_rust")
    end)
target_end()

target("test_js")
    set_kind("phony")
    on_run(function ()
        if os.host() == "windows" then
            cprint("${yellow}Skipping:${clear} test_js on Windows (quickjs-rs not supported)")
            return
        end

        cprint("${cyan}Running:${clear} fetch_suite")
        os.vrunv("xmake", {"run", "fetch_suite"})
        local validation = path.join(os.projectdir(), ".tmp", "json-typedef-spec", JSON_TYPEDEF_SPEC_COMMIT, "tests", "validation.json")
        os.setenv("JTD_VALIDATION_JSON", validation)
        cprint("${cyan}Running:${clear} cargo test -p jtd-codegen --test quickjs_validation_suite -- --nocapture")
        os.vrunv("cargo", {"test", "-p", "jtd-codegen", "--test", "quickjs_validation_suite", "--", "--nocapture"})
        cprint("${green}OK:${clear} test_js")
    end)
target_end()

target("test_lua")
    set_kind("phony")
    on_run(function ()
        cprint("${cyan}Running:${clear} fetch_suite")
        os.vrunv("xmake", {"run", "fetch_suite"})
        local validation = path.join(os.projectdir(), ".tmp", "json-typedef-spec", JSON_TYPEDEF_SPEC_COMMIT, "tests", "validation.json")
        local dkjson = path.join(os.projectdir(), ".tmp", "dkjson.lua")
        os.setenv("JTD_VALIDATION_JSON", validation)
        os.setenv("JTD_DKJSON_PATH", dkjson)
        cprint("${cyan}Running:${clear} cargo test -p jtd-codegen --test lua_validation_suite -- --nocapture")
        os.vrunv("cargo", {"test", "-p", "jtd-codegen", "--test", "lua_validation_suite", "--", "--nocapture"})
        cprint("${green}OK:${clear} test_lua")
    end)
target_end()

target("test_py")
    set_kind("phony")
    on_run(function ()
        cprint("${cyan}Running:${clear} fetch_suite")
        os.vrunv("xmake", {"run", "fetch_suite"})
        local validation = path.join(os.projectdir(), ".tmp", "json-typedef-spec", JSON_TYPEDEF_SPEC_COMMIT, "tests", "validation.json")
        os.setenv("JTD_VALIDATION_JSON", validation)
        cprint("${cyan}Running:${clear} cargo test -p jtd-codegen --test py_validation_suite -- --nocapture")
        os.vrunv("cargo", {"test", "-p", "jtd-codegen", "--test", "py_validation_suite", "--", "--nocapture"})
        cprint("${green}OK:${clear} test_py")
    end)
target_end()

target("test_wasm")
    set_kind("phony")
    on_run(function ()
        cprint("${cyan}Running:${clear} fetch_suite")
        os.vrunv("xmake", {"run", "fetch_suite"})
        cprint("${cyan}Running:${clear} rustup target add wasm32-wasip1")
        os.vrunv("rustup", {"target", "add", "wasm32-wasip1"})
        local validation = path.join(os.projectdir(), ".tmp", "json-typedef-spec", JSON_TYPEDEF_SPEC_COMMIT, "tests", "validation.json")
        os.setenv("JTD_VALIDATION_JSON", validation)
        cprint("${cyan}Running:${clear} cargo test -p jtd-codegen --test wasmtime_validation_suite -- --nocapture")
        os.vrunv("cargo", {"test", "-p", "jtd-codegen", "--test", "wasmtime_validation_suite", "--", "--nocapture"})
    end)
target_end()

target("test_all")
    set_kind("phony")
    on_run(function ()
        cprint("${cyan}Running:${clear} check (fmt + clippy)")
        os.vrunv("xmake", {"run", "check"})
        cprint("${cyan}Running:${clear} fetch_suite")
        os.vrunv("xmake", {"run", "fetch_suite"})
        local validation = path.join(os.projectdir(), ".tmp", "json-typedef-spec", JSON_TYPEDEF_SPEC_COMMIT, "tests", "validation.json")
        os.setenv("JTD_VALIDATION_JSON", validation)
        cprint("${cyan}Running:${clear} cargo test -p jtd-codegen --test rs_validation_suite -- --nocapture")
        os.vrunv("cargo", {"test", "-p", "jtd-codegen", "--test", "rs_validation_suite", "--", "--nocapture"})
        
        if os.host() ~= "windows" then
            cprint("${cyan}Running:${clear} cargo test -p jtd-codegen --test quickjs_validation_suite -- --nocapture")
            os.vrunv("cargo", {"test", "-p", "jtd-codegen", "--test", "quickjs_validation_suite", "--", "--nocapture"})
        else
            cprint("${yellow}Skipping:${clear} quickjs_validation_suite on Windows")
        end

        cprint("${cyan}Running:${clear} cargo test -p jtd-codegen --test lua_validation_suite -- --nocapture")
        local dkjson = path.join(os.projectdir(), ".tmp", "dkjson.lua")
        os.setenv("JTD_DKJSON_PATH", dkjson)
        os.vrunv("cargo", {"test", "-p", "jtd-codegen", "--test", "lua_validation_suite", "--", "--nocapture"})

        cprint("${cyan}Running:${clear} cargo test -p jtd-codegen --test py_validation_suite -- --nocapture")
        os.vrunv("cargo", {"test", "-p", "jtd-codegen", "--test", "py_validation_suite", "--", "--nocapture"})

        cprint("${cyan}Running:${clear} xmake run test_wasm")
        os.vrunv("xmake", {"run", "test_wasm"})
        cprint("${green}OK:${clear} test_all")
    end)
target_end()

-- Demo targets

target("demo_build")
    set_kind("phony")
    on_run(function ()
        -- Build the release binary
        cprint("${cyan}Building:${clear} cargo build --release")
        os.vrunv("cargo", {"build", "--release"})

        local binary = path.join(os.projectdir(), "target", "release", "jtd-codegen")
        if not os.isfile(binary) then
            raise("Failed to build jtd-codegen binary at " .. binary)
        end
        
        cprint("${green}Built:${clear} " .. binary)
    end)
target_end()

target("demo_init")
    set_kind("phony")
    on_run(function ()
        local projectdir = os.projectdir()
        local template = path.join(projectdir, "examples", "nginx.conf.template")
        local output = path.join(projectdir, "examples", "nginx.conf")
        
        if not os.isfile(template) then
            raise("nginx.conf.template not found at " .. template)
        end
        
        -- Detect nginx mime.types location
        local mime_types = nil
        local candidates = {
            "/opt/homebrew/etc/nginx/mime.types",
            "/usr/local/etc/nginx/mime.types",
            "/etc/nginx/mime.types"
        }
        
        for _, candidate in ipairs(candidates) do
            if os.isfile(candidate) then
                mime_types = candidate
                break
            end
        end
        
        if not mime_types then
            raise("Could not find nginx mime.types. Searched: " .. table.concat(candidates, ", "))
        end
        
        -- Read template
        local content = io.readfile(template)
        
        -- Replace placeholders
        content = content:gsub("{{PROJECT_DIR}}", projectdir)
        content = content:gsub("{{NGINX_MIME_TYPES}}", mime_types)
        
        -- Write output
        io.writefile(output, content)
        
        cprint("${green}Generated:${clear} " .. output)
        cprint("  ${dim}PROJECT_DIR=${clear}" .. projectdir)
        cprint("  ${dim}NGINX_MIME_TYPES=${clear}" .. mime_types)
    end)
target_end()

target("demo_compile")
    set_kind("phony")
    on_run(function ()
        local projectdir = os.projectdir()
        local binary = path.join(projectdir, "target", "release", "jtd-codegen")
        
        if not os.isfile(binary) then
            raise("jtd-codegen binary not found. Run 'xmake run demo_build' first")
        end
        
        local examples = path.join(projectdir, "examples")
        
        -- Find all numbered example directories
        local dirs = os.dirs(path.join(examples, "*"))
        table.sort(dirs)
        
        for _, dir in ipairs(dirs) do
            local dirname = path.basename(dir)
            if dirname:match("^%d+_") then
                local schema = path.join(dir, "schema.jtd.json")
                local validator_js = path.join(dir, "validator.js")
                
                if os.isfile(schema) then
                    cprint("${cyan}Compiling JS:${clear} " .. dirname)
                    local output = os.iorunv(binary, {"--target", "js", schema})
                    io.writefile(validator_js, output)
                    cprint("  ${green}→${clear} " .. path.relative(validator_js, projectdir))
                else
                    cprint("${yellow}Warning:${clear} " .. dirname .. " has no schema.jtd.json, skipping")
                end
            end
        end
        
        cprint("${green}Compiled all JS validators${clear}")
    end)
target_end()

target("demo_compile_wasm")
    set_kind("phony")
    on_run(function ()
        local projectdir = os.projectdir()
        local binary = path.join(projectdir, "target", "release", "jtd-codegen")
        
        if not os.isfile(binary) then
            raise("jtd-codegen binary not found. Run 'xmake run demo_build' first")
        end
        
        -- Check for wasm-pack
        local wasm_pack = nil
        local result = os.iorun("which wasm-pack")
        if result and result:trim() ~= "" then
            wasm_pack = result:trim()
        end
        
        if not wasm_pack then
            raise("wasm-pack not found. Install with: cargo install wasm-pack")
        end
        
        local examples = path.join(projectdir, "examples")
        local dirs = os.dirs(path.join(examples, "*"))
        table.sort(dirs)
        
        for _, dir in ipairs(dirs) do
            local dirname = path.basename(dir)
            if dirname:match("^%d+_") then
                local schema = path.join(dir, "schema.jtd.json")
                local wasm_dir = path.join(dir, "wasm")
                local wasm_src = path.join(wasm_dir, "src")
                
                if os.isfile(schema) and os.isdir(wasm_dir) then
                    cprint("${cyan}Compiling Rust:${clear} " .. dirname)
                    
                    -- Generate Rust validator
                    local rust_output = os.iorunv(binary, {"--target", "rust", schema})
                    local validator_rs = path.join(wasm_src, "validator.rs")
                    io.writefile(validator_rs, rust_output)
                    cprint("  ${green}→${clear} " .. path.relative(validator_rs, projectdir))
                    
                    -- Build WASM with wasm-pack
                    cprint("${cyan}Building WASM:${clear} " .. dirname)
                    os.vrunv(wasm_pack, {"build", "--target", "web", "--out-dir", path.join("..", "pkg"), wasm_dir})
                    cprint("  ${green}→${clear} " .. path.relative(path.join(dir, "pkg"), projectdir))
                end
            end
        end
        
        cprint("${green}Compiled all WASM validators${clear}")
    end)
target_end()

target("demo_start")
    set_kind("phony")
    on_run(function ()
        local projectdir = os.projectdir()
        local nginx_conf = path.join(projectdir, "examples", "nginx.conf")
        
        if not os.isfile(nginx_conf) then
            raise("nginx.conf not found. Run 'xmake run demo_init' first")
        end
        
        -- Check if nginx is available
        local nginx_path = nil
        local try_paths = {
            "/opt/homebrew/bin/nginx",
            "/usr/local/bin/nginx",
            "/usr/bin/nginx"
        }
        
        for _, p in ipairs(try_paths) do
            if os.isfile(p) then
                nginx_path = p
                break
            end
        end
        
        if not nginx_path then
            -- Try PATH
            local result = os.iorun("which nginx")
            if result and result:trim() ~= "" then
                nginx_path = result:trim()
            end
        end
        
        if not nginx_path then
            raise("nginx not found. Install with: brew install nginx")
        end
        
        cprint("${cyan}Starting nginx:${clear} " .. nginx_path)
        cprint("  ${dim}Config:${clear} " .. nginx_conf)
        cprint("  ${dim}URL:${clear} http://localhost:8080/")
        cprint("")
        cprint("${yellow}Press Ctrl+C to stop${clear}")
        
        os.execv(nginx_path, {"-c", nginx_conf})
    end)
target_end()

target("demo")
    set_kind("phony")
    on_run(function ()
        cprint("${cyan}Running:${clear} check (fmt + clippy)")
        os.vrunv("xmake", {"run", "check"})
        
        cprint("${cyan}Running:${clear} demo_build")
        os.vrunv("xmake", {"run", "demo_build"})
        
        cprint("${cyan}Running:${clear} demo_init")
        os.vrunv("xmake", {"run", "demo_init"})
        
        cprint("${cyan}Running:${clear} demo_compile")
        os.vrunv("xmake", {"run", "demo_compile"})
        
        cprint("${cyan}Running:${clear} demo_compile_wasm")
        os.vrunv("xmake", {"run", "demo_compile_wasm"})
        
        cprint("${cyan}Running:${clear} demo_start")
        os.vrunv("xmake", {"run", "demo_start"})
    end)
target_end()
