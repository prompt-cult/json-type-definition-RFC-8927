use serde_json::json;
use std::process::Command;

#[test]
fn emitters_support_custom_validator_name() {
    let schema = json!({"type": "string"});
    let compiled = jtd_codegen::compiler::compile(&schema).unwrap();

    let js = jtd_codegen::emit_js::emit_with_name(&compiled, "validate_user");
    assert!(js.contains("export function validate_user(instance)"));

    let py = jtd_codegen::emit_py::emit_with_name(&compiled, "validate_user");
    assert!(py.contains("def validate_user(instance)"));

    let lua = jtd_codegen::emit_lua::emit_with_name(&compiled, "validate_user");
    assert!(lua.contains("function M.validate_user(instance)"));

    let rs = jtd_codegen::emit_rs::emit_with_name(&compiled, "validate_user");
    assert!(rs.contains("pub fn validate_user(instance: &Value) -> Vec<(String, String)>"));
}

#[test]
fn cli_name_flag_sets_generated_entry_function_name() {
    let schema = json!({"type": "string"}).to_string();
    let bin = std::env::var("CARGO_BIN_EXE_jtd-codegen").unwrap();
    let checks = [
        (
            "rust",
            "pub fn validate_profile(instance: &Value) -> Vec<(String, String)>",
        ),
        ("js", "export function validate_profile(instance)"),
        ("python", "def validate_profile(instance)"),
        ("lua", "function M.validate_profile(instance)"),
    ];

    for (target, expected_snippet) in checks {
        let output = Command::new(&bin)
            .args(["--target", target, "--name", "validate_profile"])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .and_then(|mut child| {
                use std::io::Write;
                child.stdin.as_mut().unwrap().write_all(schema.as_bytes())?;
                child.wait_with_output()
            })
            .unwrap();

        assert!(output.status.success());
        let stdout = String::from_utf8(output.stdout).unwrap();
        assert!(
            stdout.contains(expected_snippet),
            "missing snippet for target {target}: {expected_snippet}"
        );
    }
}

#[test]
fn cli_name_flag_rejects_invalid_identifier() {
    let schema = json!({"type": "string"}).to_string();
    let bin = std::env::var("CARGO_BIN_EXE_jtd-codegen").unwrap();
    for invalid_name in ["bad-name", "123validate", ""] {
        let output = Command::new(&bin)
            .args(["--target", "js", "--name", invalid_name])
            .stdin(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .and_then(|mut child| {
                use std::io::Write;
                child.stdin.as_mut().unwrap().write_all(schema.as_bytes())?;
                child.wait_with_output()
            })
            .unwrap();

        assert!(!output.status.success());
        let stderr = String::from_utf8(output.stderr).unwrap();
        assert!(stderr.contains("Invalid --name"));
    }
}
