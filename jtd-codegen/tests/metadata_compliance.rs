/// Integration test: RFC 8927 section 2.3 compliance for the "metadata"
/// keyword. Section 2.3 defines that schemas may optionally contain a
/// "metadata" member whose value is an arbitrary JSON object, used to convey
/// information not pertinent to validation; Annex A admits it on every form
/// via the shared CDDL rule: shared = (? metadata: { * tstr => any },
/// ? nullable: bool).
///
/// Compliance pins three properties:
///   1. every form accepts a "metadata" member (schema is legal);
///   2. metadata changes neither the compiled AST nor the generated code;
///   3. metadata does not affect accept/reject behaviour.
use serde_json::json;

/// All eight schema forms from RFC 8927 section 2.2, each carrying metadata.
fn forms_with_metadata() -> Vec<serde_json::Value> {
    vec![
        // empty
        json!({"metadata": {"description": "accepts any instance"}}),
        // ref
        json!({
            "definitions": {"label": {"type": "string", "metadata": {"description": "text"}}},
            "ref": "label",
            "metadata": {"purpose": "show ref metadata"}
        }),
        // type
        json!({"type": "string", "metadata": {"description": "the name"}}),
        // enum
        json!({"enum": ["a", "b"], "metadata": {"description": "state machine states"}}),
        // elements
        json!({"elements": {"type": "uint8"}, "metadata": {"description": "bytes"}}),
        // properties
        json!({
            "properties": {"id": {"type": "string"}},
            "optionalProperties": {"note": {"type": "string"}},
            "additionalProperties": false,
            "metadata": {"description": "a record"}
        }),
        // values
        json!({"values": {"type": "string"}, "metadata": {"description": "string map"}}),
        // discriminator
        json!({
            "discriminator": "kind",
            "mapping": {
                "cat": {"properties": {"lives": {"type": "uint8"}}},
                "dog": {"properties": {"good": {"type": "boolean"}}}
            },
            "metadata": {"description": "pets"}
        }),
    ]
}

#[test]
fn test_metadata_accepted_on_all_forms() {
    for schema in forms_with_metadata() {
        let compiled = jtd_codegen::compiler::compile(&schema)
            .unwrap_or_else(|e| panic!("metadata must be legal on every RFC 8927 form: {e}"));
        // And the emitted code must still build as Rust? Byte-identity with the
        // bare form is asserted below; here just sanity-check non-empty output.
        assert!(jtd_codegen::emit_rs::emit(&compiled).contains("validate"));
    }
}

#[test]
fn test_metadata_changes_no_ast_and_no_generated_code() {
    let pairs: Vec<(serde_json::Value, serde_json::Value)> = forms_with_metadata()
        .into_iter()
        .map(|with_meta| {
            // Strip the metadata members (root-level and in nested schemas).
            let bare = strip_metadata(&with_meta);
            (with_meta, bare)
        })
        .collect();

    for (with_meta, bare) in pairs {
        let compiled_meta = jtd_codegen::compiler::compile(&with_meta).unwrap();
        let compiled_bare = jtd_codegen::compiler::compile(&bare).unwrap();

        assert_eq!(
            compiled_meta.root, compiled_bare.root,
            "metadata must not change the compiled AST"
        );
        assert_eq!(
            compiled_meta.definitions, compiled_bare.definitions,
            "metadata must not change compiled definitions"
        );
    }
}

#[test]
fn test_metadata_does_not_leak_into_emitted_code() {
    for with_meta in forms_with_metadata() {
        let bare = strip_metadata(&with_meta);
        let emitted_meta =
            jtd_codegen::emit_rs::emit(&jtd_codegen::compiler::compile(&with_meta).unwrap());
        let emitted_bare =
            jtd_codegen::emit_rs::emit(&jtd_codegen::compiler::compile(&bare).unwrap());
        assert_eq!(
            emitted_meta, emitted_bare,
            "metadata members must not change generated validator code (RFC 8927 section 2.3)"
        );
    }
}

/// Return a deep copy of the schema with every "metadata" member removed
/// (root level, inside definitions, and inside property schemas).
fn strip_metadata(value: &serde_json::Value) -> serde_json::Value {
    match value {
        serde_json::Value::Object(map) => serde_json::Value::Object(
            map.iter()
                .filter(|(k, _)| *k != "metadata")
                .map(|(k, v)| (k.clone(), strip_metadata(v)))
                .collect(),
        ),
        serde_json::Value::Array(items) => {
            serde_json::Value::Array(items.iter().map(strip_metadata).collect())
        }
        other => other.clone(),
    }
}
