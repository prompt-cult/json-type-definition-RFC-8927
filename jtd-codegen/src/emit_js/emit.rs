/// Top-level composition: walks a CompiledSchema AST and produces
/// a complete ES module by dispatching to the per-node emitters.
use std::collections::BTreeMap;

use super::context::EmitContext;
use super::nodes::*;
use super::writer::{escape_js, CodeWriter};
use crate::ast::{CompiledSchema, Node};

/// Emit a complete ES2020 module from a compiled schema.
pub fn emit(schema: &CompiledSchema) -> String {
    emit_with_name(schema, "validate")
}

/// Emit a complete ES2020 module from a compiled schema with a custom entry function name.
pub fn emit_with_name(schema: &CompiledSchema, validate_fn_name: &str) -> String {
    let mut w = CodeWriter::new();

    // Emit one function per definition
    for (name, node) in &schema.definitions {
        let fn_name = def_fn_name(name);
        w.open(&format!("function {fn_name}(v, e, p, sp)"));
        let ctx = EmitContext::definition();
        emit_node(&mut w, &ctx, node, None);
        w.close();
        w.line("");
    }

    // Emit the exported validate() entry point
    w.open(&format!("export function {validate_fn_name}(instance)"));
    w.line("const e = [];");
    let root_ctx = EmitContext::root();
    emit_node(&mut w, &root_ctx, &schema.root, None);
    w.line("return e;");
    w.close();

    w.finish()
}

/// Recursively emit validation code for one AST node.
/// This is the dispatcher that connects all the per-node emitters.
fn emit_node(w: &mut CodeWriter, ctx: &EmitContext, node: &Node, discrim_tag: Option<&str>) {
    match node {
        Node::Empty => emit_empty(w, ctx),

        Node::Type { type_kw } => emit_type(w, ctx, *type_kw),

        Node::Enum { values } => emit_enum(w, ctx, values),

        Node::Ref { name } => emit_ref(w, ctx, name),

        Node::Nullable { inner } => {
            let is_inner_empty = matches!(inner.as_ref(), Node::Empty);
            emit_nullable(w, ctx, is_inner_empty, |w, ctx| {
                emit_node(w, ctx, inner, None);
            });
        }

        Node::Elements { schema } => {
            emit_elements(w, ctx, |w, ctx| {
                emit_node(w, ctx, schema, None);
            });
        }

        Node::Values { schema } => {
            emit_values(w, ctx, |w, ctx| {
                emit_node(w, ctx, schema, None);
            });
        }

        Node::Properties {
            required,
            optional,
            additional,
        } => {
            emit_properties_node(w, ctx, required, optional, *additional, discrim_tag);
        }

        Node::Discriminator { tag, mapping } => {
            emit_discriminator_node(w, ctx, tag, mapping);
        }
    }
}

/// Properties: compose the object guard, per-property checks, and
/// additional-property rejection by calling emit_node for each value.
///
/// This bridges the tested emit_properties (which takes closures) with
/// the recursive AST walk. It's tested separately via the worked example.
fn emit_properties_node(
    w: &mut CodeWriter,
    ctx: &EmitContext,
    required: &BTreeMap<String, Node>,
    optional: &BTreeMap<String, Node>,
    additional: bool,
    discrim_tag: Option<&str>,
) {
    // Object type guard -- per test suite, schema path points to the form keyword
    let guard_sp = if !required.is_empty() {
        "/properties"
    } else {
        "/optionalProperties"
    };
    w.open(&format!(
        "if ({val} === null || typeof {val} !== \"object\" || Array.isArray({val}))",
        val = ctx.val
    ));
    w.line(&ctx.push_error(guard_sp));
    w.close_open("else");

    // Required properties
    for (key, node) in required {
        let escaped = escape_js(key);
        w.line(&format!(
            "if (!(\"{escaped}\" in {})) {}",
            ctx.val,
            ctx.push_error(&format!("/properties/{escaped}"))
        ));
        w.open("else");
        let child_ctx = ctx.required_prop(key);
        emit_node(w, &child_ctx, node, None);
        w.close();
    }

    // Optional properties
    for (key, node) in optional {
        let escaped = escape_js(key);
        w.open(&format!("if (\"{escaped}\" in {})", ctx.val));
        let child_ctx = ctx.optional_prop(key);
        emit_node(w, &child_ctx, node, None);
        w.close();
    }

    // Additional properties rejection
    if !additional {
        let k_var = "k";
        w.open(&format!("for (const {k_var} in {})", ctx.val));

        let mut known: Vec<&str> = Vec::new();
        if let Some(tag) = discrim_tag {
            known.push(tag);
        }
        for key in required.keys() {
            known.push(key);
        }
        for key in optional.keys() {
            known.push(key);
        }

        if known.is_empty() {
            w.line(&format!(
                "{}.push({{instancePath: {} + \"/\" + {k_var}, schemaPath: {}}});",
                ctx.err, ctx.ip, ctx.sp
            ));
        } else {
            let conds: Vec<String> = known
                .iter()
                .map(|k| format!("{k_var} !== \"{}\"", escape_js(k)))
                .collect();
            w.line(&format!(
                "if ({}) {}.push({{instancePath: {} + \"/\" + {k_var}, schemaPath: {}}});",
                conds.join(" && "),
                ctx.err,
                ctx.ip,
                ctx.sp
            ));
        }

        w.close(); // for
    }

    w.close(); // else
}

/// Discriminator: 5-step check dispatching to variant Properties via emit_node.
fn emit_discriminator_node(
    w: &mut CodeWriter,
    ctx: &EmitContext,
    tag: &str,
    mapping: &BTreeMap<String, Node>,
) {
    let escaped_tag = escape_js(tag);

    // Step 1: not an object -- per test suite, error points to "/discriminator"
    w.open(&format!(
        "if ({val} === null || typeof {val} !== \"object\" || Array.isArray({val}))",
        val = ctx.val
    ));
    w.line(&ctx.push_error("/discriminator"));

    // Step 2: tag missing -- per test suite, error points to "/discriminator"
    w.close_open(&format!("else if (!(\"{escaped_tag}\" in {}))", ctx.val));
    w.line(&ctx.push_error("/discriminator"));

    // Step 3: tag not string
    w.close_open(&format!(
        "else if (typeof {}[\"{escaped_tag}\"] !== \"string\")",
        ctx.val
    ));
    w.line(&ctx.push_error_at(&format!("/{escaped_tag}"), "/discriminator"));

    // Step 4: dispatch per variant
    for (variant_key, variant_node) in mapping {
        let escaped_variant = escape_js(variant_key);
        w.close_open(&format!(
            "else if ({}[\"{escaped_tag}\"] === \"{escaped_variant}\")",
            ctx.val
        ));
        let variant_ctx = ctx.discrim_variant(variant_key);
        // The variant node must be a Properties node; emit with tag exclusion
        emit_node(w, &variant_ctx, variant_node, Some(tag));
    }

    // Step 5: unknown tag value
    w.close_open("else");
    w.line(&ctx.push_error_at(&format!("/{escaped_tag}"), "/mapping"));
    w.close();
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::compiler;
    use serde_json::json;

    #[test]
    fn test_emit_empty_schema() {
        let schema = json!({});
        let compiled = compiler::compile(&schema).unwrap();
        let code = emit(&compiled);
        // Should have the validate function with no checks
        assert!(code.contains("export function validate(instance)"));
        assert!(code.contains("const e = [];"));
        assert!(code.contains("return e;"));
        // No type checks for empty schema
        assert!(!code.contains("typeof"));
    }

    #[test]
    fn test_emit_type_string() {
        let schema = json!({"type": "string"});
        let compiled = compiler::compile(&schema).unwrap();
        let code = emit(&compiled);
        assert!(code.contains("typeof instance !== \"string\""));
    }

    #[test]
    fn test_emit_ref_generates_definition_function() {
        let schema = json!({
            "definitions": {"addr": {"type": "string"}},
            "ref": "addr"
        });
        let compiled = compiler::compile(&schema).unwrap();
        let code = emit(&compiled);
        // Definition function
        assert!(code.contains("function validate_addr(v, e, p, sp)"));
        assert!(code.contains("typeof v !== \"string\""));
        // Root calls it
        assert!(code.contains("validate_addr(instance, e, \"\", \"/definitions/addr\");"));
    }

    #[test]
    fn test_emit_worked_example() {
        // Section 8 of the spec
        let schema = json!({
            "properties": {
                "name": {"type": "string"},
                "age": {"type": "uint8"},
                "tags": {"elements": {"type": "string"}}
            },
            "optionalProperties": {
                "email": {"type": "string"}
            }
        });
        let compiled = compiler::compile(&schema).unwrap();
        let code = emit(&compiled);

        // Required property checks
        assert!(code.contains("\"name\" in instance"));
        assert!(code.contains("\"age\" in instance"));
        assert!(code.contains("\"tags\" in instance"));

        // Type checks
        assert!(code.contains("Number.isInteger")); // uint8
        assert!(code.contains("Array.isArray")); // elements guard

        // Optional
        assert!(code.contains("\"email\" in instance"));

        // Additional properties
        assert!(code.contains("for (const k in instance)"));

        // No definition functions (schema has no definitions)
        assert!(!code.contains("function validate_"));
    }
}
