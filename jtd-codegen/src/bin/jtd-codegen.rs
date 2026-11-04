/// CLI: reads a JTD schema from stdin or a file, emits code to stdout.
///
/// Usage:
///   jtd-codegen --target js     < schema.json > validator.mjs
///   jtd-codegen --target lua    < schema.json > validator.lua
///   jtd-codegen --target python < schema.json > validator.py
///   jtd-codegen --target rust   < schema.json > validator.rs
///   jtd-codegen --target rust   schema.json   > validator.rs
///   jtd-codegen --target js --name validateUser schema.json > validator.mjs
use std::io::Read;

fn is_valid_identifier(name: &str) -> bool {
    let mut chars = name.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if !(first == '_' || first.is_ascii_alphabetic()) {
        return false;
    }
    chars.all(|c| c == '_' || c.is_ascii_alphanumeric())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();

    let mut target = "rust";
    let mut validator_name = "validate";
    let mut file_path: Option<&str> = None;

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--target" | "-t" => {
                i += 1;
                if i < args.len() {
                    target = match args[i].as_str() {
                        "js" | "javascript" => "js",
                        "lua" => "lua",
                        "python" | "py" => "python",
                        "rust" | "rs" => "rust",
                        other => {
                            eprintln!(
                                "Unknown target: {other}. Use 'js', 'lua', 'python', or 'rust'."
                            );
                            std::process::exit(1);
                        }
                    };
                }
            }
            "--name" | "-n" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("Missing value for --name");
                    std::process::exit(1);
                }
                validator_name = &args[i];
            }
            "--help" | "-h" => {
                eprintln!(
                    "Usage: jtd-codegen [--target js|lua|python|rust] [--name validator_name] [schema.json]"
                );
                eprintln!("  Reads JTD schema from file or stdin, emits code to stdout.");
                eprintln!("  --name must be a valid identifier: [A-Za-z_][A-Za-z0-9_]*");
                std::process::exit(0);
            }
            path => {
                file_path = Some(path);
            }
        }
        i += 1;
    }

    let json_str = match file_path {
        Some(path) => std::fs::read_to_string(path).unwrap_or_else(|e| {
            eprintln!("Cannot read {path}: {e}");
            std::process::exit(1);
        }),
        None => {
            let mut buf = String::new();
            std::io::stdin()
                .read_to_string(&mut buf)
                .unwrap_or_else(|e| {
                    eprintln!("Cannot read stdin: {e}");
                    std::process::exit(1);
                });
            buf
        }
    };

    let schema: serde_json::Value = serde_json::from_str(&json_str).unwrap_or_else(|e| {
        eprintln!("Invalid JSON: {e}");
        std::process::exit(1);
    });

    let compiled = jtd_codegen::compiler::compile(&schema).unwrap_or_else(|e| {
        eprintln!("Invalid JTD schema: {e}");
        std::process::exit(1);
    });

    if !is_valid_identifier(validator_name) {
        eprintln!(
            "Invalid --name '{validator_name}'. Use [A-Za-z_][A-Za-z0-9_]* for compatibility across targets."
        );
        std::process::exit(1);
    }

    let code = match target {
        "js" => jtd_codegen::emit_js::emit_with_name(&compiled, validator_name),
        "lua" => jtd_codegen::emit_lua::emit_with_name(&compiled, validator_name),
        "python" => jtd_codegen::emit_py::emit_with_name(&compiled, validator_name),
        "rust" => jtd_codegen::emit_rs::emit_with_name(&compiled, validator_name),
        _ => unreachable!(),
    };

    print!("{code}");
}
