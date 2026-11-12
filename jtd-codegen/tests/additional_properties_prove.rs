/// Regression test for a reported violation: "no matter whether RFC 8927
/// allowed extra properties, the generated validators ALWAYS rejected objects
/// with extra properties".
///
/// RFC 8927 section 2.2.8 (properties form) semantics:
///   A: "additionalProperties": true  -> extra properties are ACCEPTED
///   B: key absent                    -> defaults to false, extras REJECTED
///      (the official json-typedef-spec suite pins this: "strict properties -
///      bad additional property" expects one error with the key absent)
///
/// The claim is disproven when schema A's extras case passes with zero errors
/// while schema B's extras case is rejected: the generated validator follows
/// the schema; it does not "always" reject extras.
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::process::Command;

/// Scratch dir for the generated Cargo project, under the repo .tmp/ policy.
fn work_dir() -> PathBuf {
    let manifest_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let root = manifest_dir
        .parent()
        .expect("jtd-codegen has a workspace parent");
    let dir = root.join(".tmp").join("additional_properties_prove");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("src")).expect("create work dir");
    dir
}

fn build_validator(schema: &Value) -> String {
    let compiled =
        jtd_codegen::compiler::compile(schema).expect("schema must compile per RFC 8927");
    jtd_codegen::emit_rs::emit(&compiled)
}

#[test]
fn test_generated_validators_follow_additional_properties_semantics() {
    // Schema A: extras allowed because additionalProperties is explicitly true.
    let schema_a = json!({
        "properties": { "name": { "type": "string" } },
        "additionalProperties": true
    });
    // Schema B: key absent -> defaults to false per RFC 8927; extras rejected.
    let schema_b = json!({
        "properties": { "name": { "type": "string" } }
    });

    let clean = json!({ "name": "ada" });
    let invalid = json!({ "name": 123 });
    let extras = json!({ "name": "ada", "unknown_extra": 42 });

    let clean_json = serde_json::to_string(&clean).unwrap();
    let invalid_json = serde_json::to_string(&invalid).unwrap();
    let extras_json = serde_json::to_string(&extras).unwrap();

    // (validator name, schema, instance as JSON string, must_pass)
    let cases: [(&str, &Value, &str, bool); 6] = [
        ("schema_a_clean", &schema_a, &clean_json, true),
        ("schema_a_invalid", &schema_a, &invalid_json, false),
        ("schema_a_extras", &schema_a, &extras_json, true),
        ("schema_b_clean", &schema_b, &clean_json, true),
        ("schema_b_invalid", &schema_b, &invalid_json, false),
        // Key absent -> additionalProperties defaults to false (RFC 8927
        // section 2.2.8 and official suite "strict properties"), so the
        // extra key MUST be rejected here.
        ("schema_b_extras", &schema_b, &extras_json, false),
    ];

    // Build a single Rust test binary with one module per validator.
    let mut src = String::from("use serde_json::Value;\n\n");
    for (name, schema, _, _) in &cases {
        src.push_str(&format!("mod {name} {{\n"));
        for line in build_validator(schema).lines() {
            src.push_str(&format!("  {line}\n"));
        }
        src.push_str("}\n\n");
    }

    // main() reports one parseable line per validator: "name|error-count".
    src.push_str("fn main() {\n");
    for (name, _, instance_json, _) in &cases {
        src.push_str(&format!(
            "    let instance: Value = serde_json::from_str(r#\"{instance_json}\"#).unwrap();\n"
        ));
        src.push_str(&format!(
            "    println!(\"{name}|{{}}\", {name}::validate(&instance).len());\n"
        ));
    }
    src.push_str("}\n");

    let tmp = work_dir();
    let proj_dir = tmp.as_path();
    std::fs::write(
        proj_dir.join("Cargo.toml"),
        "[package]\nname = \"additional-properties-prove\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[workspace]\n\n[dependencies]\nserde_json = \"1\"\n",
    )
    .unwrap();
    std::fs::write(proj_dir.join("src/main.rs"), &src).unwrap();
    // Keep the generated source for post-mortem when the assertion fails.
    std::fs::write(proj_dir.join("generated_main.rs"), &src).unwrap();

    let build = Command::new("cargo")
        .args(["build", "--release"])
        .env("RUSTFLAGS", "-Awarnings")
        .current_dir(proj_dir)
        .output()
        .expect("cargo build");
    if !build.status.success() {
        panic!(
            "generated validators failed to compile:\n{}",
            String::from_utf8_lossy(&build.stderr)
        );
    }

    // Run: invoke the built binary directly; nested `cargo run` does not
    // reliably forward the program's stdout through this harness.
    let bin = proj_dir.join("target/release/additional-properties-prove");
    let run = Command::new(&bin)
        .output()
        .expect("run built validator binary");
    let stdout = String::from_utf8_lossy(&run.stdout);
    if !run.status.success() {
        // cargo run may print diagnostics on stderr; surface them before parsing.
        panic!(
            "validator run failed:\nstdout:\n{stdout}\nstderr:\n{}",
            String::from_utf8_lossy(&run.stderr)
        );
    }

    let mut results: Vec<(String, usize)> = Vec::new();
    for line in stdout.lines() {
        if let Some((name, count)) = line.split_once('|') {
            results.push((name.to_string(), count.trim().parse().unwrap_or(9999)));
        }
    }

    let lookup = |name: &str| results.iter().find(|(n, _)| n == name).map(|(_, c)| *c);

    for (name, _, _, must_pass) in &cases {
        let count = lookup(name).unwrap_or_else(|| panic!("no result line for {name}"));
        if *must_pass {
            assert_eq!(
                count, 0,
                "VIOLATION PROVEN: validator {name} reported {count} error(s); \
                 RFC 8927 requires acceptance here"
            );
        } else {
            assert!(
                count > 0,
                "validator {name} accepted an invalid instance; suite is broken"
            );
        }
    }

    // Cleanup is silent; the source copy is kept if work_dir removal raced.
    let _ = std::fs::remove_dir_all(&tmp);
}
