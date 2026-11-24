/// Per-node emit functions. Each has the same shape:
///   fn emit_X(node_data, writer, ctx)
/// and writes a JS code fragment that validates one AST form.
///
/// These are the composable building blocks. Each is independently testable
/// by feeding it a tiny AST fragment and checking the CodeWriter output.
use super::context::EmitContext;
use super::types::type_condition;
use super::writer::{escape_js, CodeWriter};
use crate::ast::TypeKeyword;

type FieldEmitter = (&'static str, &'static dyn Fn(&mut CodeWriter, &EmitContext));

// ── Empty ──────────────────────────────────────────────────────────────

/// Empty form: no code emitted. Accepts any value.
pub fn emit_empty(_w: &mut CodeWriter, _ctx: &EmitContext) {
    // Section 5.2: "Emit nothing. No check. No code."
}

// ── Type ───────────────────────────────────────────────────────────────

/// Type form: inline type check.
pub fn emit_type(w: &mut CodeWriter, ctx: &EmitContext, type_kw: TypeKeyword) {
    let cond = type_condition(type_kw, &ctx.val);
    let err_stmt = ctx.push_error("/type");
    w.line(&format!("if ({cond}) {err_stmt}"));
}

// ── Enum ───────────────────────────────────────────────────────────────

/// Enum form: string type guard + set membership.
pub fn emit_enum(w: &mut CodeWriter, ctx: &EmitContext, values: &[String]) {
    let items: Vec<String> = values
        .iter()
        .map(|v| format!("\"{}\"", escape_js(v)))
        .collect();
    let arr = items.join(",");
    let err_stmt = ctx.push_error("/enum");
    w.line(&format!(
        "if (typeof {val} !== \"string\" || ![{arr}].includes({val})) {err_stmt}",
        val = ctx.val,
    ));
}

// ── Ref ────────────────────────────────────────────────────────────────

/// Ref form: call the generated definition function.
/// The schema path is always the absolute path `/definitions/<name>` regardless
/// of call depth -- recursive refs must not accumulate path prefixes.
pub fn emit_ref(w: &mut CodeWriter, ctx: &EmitContext, def_name: &str) {
    let fn_name = def_fn_name(def_name);
    let escaped = super::writer::escape_js(def_name);
    w.line(&format!(
        "{fn_name}({}, {}, {}, \"/definitions/{escaped}\");",
        ctx.val, ctx.err, ctx.ip
    ));
}

/// Sanitize a definition name into a valid JS function name.
pub fn def_fn_name(name: &str) -> String {
    let safe: String = name
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect();
    format!("validate_{safe}")
}

// ── Nullable ───────────────────────────────────────────────────────────

/// Nullable modifier: emit `if (val !== null) { <inner> }`.
/// `emit_inner` is a closure that writes the inner node's code.
pub fn emit_nullable(
    w: &mut CodeWriter,
    ctx: &EmitContext,
    is_inner_empty: bool,
    emit_inner: impl FnOnce(&mut CodeWriter, &EmitContext),
) {
    if is_inner_empty {
        // Nullable(Empty) accepts everything
        return;
    }
    w.open(&format!("if ({} !== null)", ctx.val));
    emit_inner(w, ctx);
    w.close();
}

// ── Elements ───────────────────────────────────────────────────────────

/// Elements form: array type guard + loop with inner check.
/// `emit_inner` writes the check for each element.
pub fn emit_elements(
    w: &mut CodeWriter,
    ctx: &EmitContext,
    emit_inner: impl FnOnce(&mut CodeWriter, &EmitContext),
) {
    // Per test suite: type guard error points to "/elements"
    let err_stmt = ctx.push_error("/elements");
    w.open(&format!("if (!Array.isArray({}))", ctx.val));
    w.line(&err_stmt);
    w.close_open("else");

    let idx = ctx.idx_var();
    w.open(&format!(
        "for (let {idx} = 0; {idx} < {}.length; {idx}++)",
        ctx.val
    ));
    let elem_ctx = ctx.element(&idx);
    emit_inner(w, &elem_ctx);
    w.close(); // for
    w.close(); // else
}

// ── Values ─────────────────────────────────────────────────────────────

/// Values form: object type guard + for-in loop with inner check.
/// `emit_inner` writes the check for each value.
pub fn emit_values(
    w: &mut CodeWriter,
    ctx: &EmitContext,
    emit_inner: impl FnOnce(&mut CodeWriter, &EmitContext),
) {
    // Per test suite: type guard error points to "/values"
    let err_stmt = ctx.push_error("/values");
    w.open(&format!(
        "if ({val} === null || typeof {val} !== \"object\" || Array.isArray({val}))",
        val = ctx.val
    ));
    w.line(&err_stmt);
    w.close_open("else");

    let key_var = ctx.key_var();
    w.open(&format!("for (const {key_var} in {})", ctx.val));
    let entry_ctx = ctx.values_entry(&key_var);
    emit_inner(w, &entry_ctx);
    w.close(); // for
    w.close(); // else
}

// ── Properties ─────────────────────────────────────────────────────────
// These closure-based emitters are used by per-node unit tests.
// The composition layer (emit.rs) uses its own _node variants that recurse directly.
#[allow(dead_code)]
/// Properties form: object guard, required checks, optional checks,
/// additional-property rejection.
///
/// `required` and `optional` are lists of (key, emit_value_fn) pairs.
/// `additional` controls whether unknown keys are rejected.
/// `discrim_tag` is set when inside a discriminator variant (tag excluded from additional check).
pub fn emit_properties(
    w: &mut CodeWriter,
    ctx: &EmitContext,
    required: &[FieldEmitter],
    optional: &[FieldEmitter],
    additional: bool,
    discrim_tag: Option<&str>,
) {
    // Object type guard -- error points to the form keyword
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
    for &(key, ref emit_value) in required {
        let escaped = escape_js(key);
        // Missing key check
        w.line(&format!(
            "if (!(\"{escaped}\" in {})) {}",
            ctx.val,
            ctx.push_error(&format!("/properties/{escaped}"))
        ));
        w.open("else");
        let child_ctx = ctx.required_prop(key);
        emit_value(w, &child_ctx);
        w.close();
    }

    // Optional properties
    for &(key, ref emit_value) in optional {
        let escaped = escape_js(key);
        w.open(&format!("if (\"{escaped}\" in {})", ctx.val));
        let child_ctx = ctx.optional_prop(key);
        emit_value(w, &child_ctx);
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
        for &(key, _) in required {
            known.push(key);
        }
        for &(key, _) in optional {
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

// ── Discriminator ──────────────────────────────────────────────────────
#[allow(dead_code)]
/// Discriminator form: 5-step check per Section 5.2.
///
/// `variants` maps tag values to closures that emit the variant's Properties check.
/// Each closure receives the writer and a context already scoped to the variant's
/// schema path (`.../mapping/<variant>`).
pub fn emit_discriminator(
    w: &mut CodeWriter,
    ctx: &EmitContext,
    tag: &str,
    variants: &[FieldEmitter],
) {
    let escaped_tag = escape_js(tag);

    // Step 1: not an object -- error points to "/discriminator"
    w.open(&format!(
        "if ({val} === null || typeof {val} !== \"object\" || Array.isArray({val}))",
        val = ctx.val
    ));
    w.line(&ctx.push_error("/discriminator"));

    // Step 2: tag missing -- error points to "/discriminator"
    w.close_open(&format!("else if (!(\"{escaped_tag}\" in {}))", ctx.val));
    w.line(&ctx.push_error("/discriminator"));

    // Step 3: tag not a string
    w.close_open(&format!(
        "else if (typeof {}[\"{escaped_tag}\"] !== \"string\")",
        ctx.val
    ));
    w.line(&ctx.push_error_at(&format!("/{escaped_tag}"), "/discriminator"));

    // Step 4: dispatch to each variant
    for &(variant_key, ref emit_variant) in variants {
        let escaped_variant = escape_js(variant_key);
        w.close_open(&format!(
            "else if ({}[\"{escaped_tag}\"] === \"{escaped_variant}\")",
            ctx.val
        ));
        let variant_ctx = ctx.discrim_variant(variant_key);
        emit_variant(w, &variant_ctx);
    }

    // Step 5: unknown tag value
    w.close_open("else");
    w.line(&ctx.push_error_at(&format!("/{escaped_tag}"), "/mapping"));
    w.close();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn emit_to_string(f: impl FnOnce(&mut CodeWriter, &EmitContext)) -> String {
        let mut w = CodeWriter::new();
        let ctx = EmitContext::root();
        f(&mut w, &ctx);
        w.finish()
    }

    fn emit_to_string_with_ctx(
        ctx: &EmitContext,
        f: impl FnOnce(&mut CodeWriter, &EmitContext),
    ) -> String {
        let mut w = CodeWriter::new();
        f(&mut w, ctx);
        w.finish()
    }

    #[test]
    fn test_emit_empty_produces_nothing() {
        let code = emit_to_string(|w, ctx| emit_empty(w, ctx));
        assert_eq!(code, "");
    }

    #[test]
    fn test_emit_type_boolean() {
        let code = emit_to_string(|w, ctx| emit_type(w, ctx, TypeKeyword::Boolean));
        assert!(code.contains("typeof instance !== \"boolean\""));
        assert!(code.contains("/type"));
        assert!(code.contains("e.push("));
    }

    #[test]
    fn test_emit_type_uint8() {
        let code = emit_to_string(|w, ctx| emit_type(w, ctx, TypeKeyword::Uint8));
        assert!(code.contains("Number.isInteger"));
        assert!(code.contains("< 0"));
        assert!(code.contains("> 255"));
    }

    #[test]
    fn test_emit_type_with_definition_context() {
        let ctx = EmitContext::definition();
        let code = emit_to_string_with_ctx(&ctx, |w, ctx| emit_type(w, ctx, TypeKeyword::String));
        assert!(code.contains("typeof v !== \"string\""));
        assert!(code.contains("e.push("));
    }

    #[test]
    fn test_emit_type_with_nested_context() {
        let root = EmitContext::root();
        let child = root.required_prop("name");
        let code = emit_to_string_with_ctx(&child, |w, ctx| emit_type(w, ctx, TypeKeyword::String));
        assert!(code.contains("instance[\"name\"]"));
    }

    #[test]
    fn test_emit_enum() {
        let code =
            emit_to_string(|w, ctx| emit_enum(w, ctx, &["a".into(), "b".into(), "c".into()]));
        assert!(code.contains("typeof instance !== \"string\""));
        assert!(code.contains("[\"a\",\"b\",\"c\"].includes(instance)"));
        assert!(code.contains("/enum"));
    }

    #[test]
    fn test_emit_enum_with_special_chars() {
        let code = emit_to_string(|w, ctx| emit_enum(w, ctx, &["a\"b".into(), "c\\d".into()]));
        assert!(code.contains("a\\\"b"));
        assert!(code.contains("c\\\\d"));
    }

    #[test]
    fn test_emit_ref() {
        let code = emit_to_string(|w, ctx| emit_ref(w, ctx, "address"));
        assert!(code.contains("validate_address(instance, e, \"\", \"/definitions/address\");"));
    }

    #[test]
    fn test_emit_ref_sanitizes_name() {
        assert_eq!(def_fn_name("my-type"), "validate_my_type");
        assert_eq!(def_fn_name("foo.bar"), "validate_foo_bar");
    }

    #[test]
    fn test_emit_nullable_wraps_inner() {
        let code = emit_to_string(|w, ctx| {
            emit_nullable(w, ctx, false, |w, ctx| {
                emit_type(w, ctx, TypeKeyword::String);
            });
        });
        assert!(code.contains("if (instance !== null)"));
        assert!(code.contains("typeof instance !== \"string\""));
    }

    #[test]
    fn test_emit_nullable_empty_produces_nothing() {
        let code = emit_to_string(|w, ctx| {
            emit_nullable(w, ctx, true, |w, ctx| {
                emit_type(w, ctx, TypeKeyword::String);
            });
        });
        assert_eq!(code, "");
    }

    // ── Elements tests ─────────────────────────────────────────────────

    #[test]
    fn test_emit_elements_with_type_inner() {
        let code = emit_to_string(|w, ctx| {
            emit_elements(w, ctx, |w, ctx| {
                emit_type(w, ctx, TypeKeyword::String);
            });
        });
        assert!(code.contains("Array.isArray(instance)"));
        assert!(code.contains("for (let i = 0;"));
        assert!(code.contains("instance[i]"));
        // The inner check uses the element context
        assert!(code.contains("/elements"));
    }

    #[test]
    fn test_emit_elements_with_empty_inner() {
        let code = emit_to_string(|w, ctx| {
            emit_elements(w, ctx, |w, ctx| {
                emit_empty(w, ctx);
            });
        });
        // Still emits array guard + loop, but loop body is empty
        assert!(code.contains("Array.isArray"));
        assert!(code.contains("for (let i"));
    }

    // ── Values tests ───────────────────────────────────────────────────

    #[test]
    fn test_emit_values_with_type_inner() {
        let code = emit_to_string(|w, ctx| {
            emit_values(w, ctx, |w, ctx| {
                emit_type(w, ctx, TypeKeyword::String);
            });
        });
        assert!(code.contains("typeof instance !== \"object\""));
        assert!(code.contains("for (const k in instance)"));
        assert!(code.contains("instance[k]"));
        assert!(code.contains("/values"));
    }

    #[test]
    fn test_emit_values_null_guard() {
        let code = emit_to_string(|w, ctx| {
            emit_values(w, ctx, |w, _ctx| {
                w.line("// inner");
            });
        });
        // Must reject null, arrays, and non-objects
        assert!(code.contains("instance === null"));
        assert!(code.contains("Array.isArray(instance)"));
    }

    // ── Properties tests ───────────────────────────────────────────────

    #[test]
    fn test_emit_properties_required_only() {
        const name_emitter: fn(&mut CodeWriter, &EmitContext) = |w, ctx| {
            emit_type(w, ctx, TypeKeyword::String);
        };
        let code = emit_to_string(|w, ctx| {
            emit_properties(w, ctx, &[("name", &name_emitter)], &[], false, None);
        });
        // Object guard
        assert!(code.contains("typeof instance !== \"object\""));
        // Missing key check
        assert!(code.contains("\"name\" in instance"));
        // Type check on value
        assert!(code.contains("/properties/name"));
        // Additional properties loop (additional=false)
        assert!(code.contains("for (const k in instance)"));
        assert!(code.contains("k !== \"name\""));
    }

    #[test]
    fn test_emit_properties_optional_only() {
        const age_emitter: fn(&mut CodeWriter, &EmitContext) = |w, ctx| {
            emit_type(w, ctx, TypeKeyword::Uint8);
        };
        let code = emit_to_string(|w, ctx| {
            emit_properties(w, ctx, &[], &[("age", &age_emitter)], false, None);
        });
        assert!(code.contains("\"age\" in instance"));
        assert!(code.contains("/optionalProperties/age"));
        assert!(code.contains("Number.isInteger"));
    }

    #[test]
    fn test_emit_properties_additional_true_no_loop() {
        const name_emitter: fn(&mut CodeWriter, &EmitContext) = |w, ctx| {
            emit_type(w, ctx, TypeKeyword::String);
        };
        let code = emit_to_string(|w, ctx| {
            emit_properties(w, ctx, &[("name", &name_emitter)], &[], true, None);
        });
        // With additional=true, no for-in rejection loop
        assert!(!code.contains("for (const k"));
    }

    #[test]
    fn test_emit_properties_with_discrim_tag() {
        const val_emitter: fn(&mut CodeWriter, &EmitContext) = |w, ctx| {
            emit_type(w, ctx, TypeKeyword::Boolean);
        };
        let code = emit_to_string(|w, ctx| {
            emit_properties(w, ctx, &[("bark", &val_emitter)], &[], false, Some("type"));
        });
        // The tag "type" should be in the known-keys exclusion
        assert!(code.contains("k !== \"type\""));
        assert!(code.contains("k !== \"bark\""));
    }

    #[test]
    fn test_emit_properties_empty_value() {
        // A required property with empty schema: check key exists, no value check
        const empty_emitter: fn(&mut CodeWriter, &EmitContext) = |w, ctx| {
            emit_empty(w, ctx);
        };
        let code = emit_to_string(|w, ctx| {
            emit_properties(w, ctx, &[("data", &empty_emitter)], &[], false, None);
        });
        assert!(code.contains("\"data\" in instance"));
        // No type check inside the else branch
        assert!(!code.contains("typeof instance[\"data\"]"));
    }

    // ── Discriminator tests ────────────────────────────────────────────

    #[test]
    fn test_emit_discriminator_structure() {
        fn cat_emitter(w: &mut CodeWriter, ctx: &EmitContext) {
            w.line(&format!("// validate cat at {}", ctx.sp));
        }
        fn dog_emitter(w: &mut CodeWriter, ctx: &EmitContext) {
            w.line(&format!("// validate dog at {}", ctx.sp));
        }
        let code = emit_to_string(|w, ctx| {
            emit_discriminator(
                w,
                ctx,
                "kind",
                &[("cat", &cat_emitter), ("dog", &dog_emitter)],
            );
        });
        // Step 1: object guard
        assert!(code.contains("typeof instance !== \"object\""));
        // Step 2: tag missing
        assert!(code.contains("\"kind\" in instance"));
        // Step 3: tag not string
        assert!(code.contains("typeof instance[\"kind\"] !== \"string\""));
        assert!(code.contains("/discriminator"));
        // Step 4: variant dispatch
        assert!(code.contains("instance[\"kind\"] === \"cat\""));
        assert!(code.contains("instance[\"kind\"] === \"dog\""));
        // Step 5: unknown tag -> /mapping error
        assert!(code.contains("/mapping"));
        // Variant contexts get scoped schema paths
        assert!(code.contains("/mapping/cat"));
        assert!(code.contains("/mapping/dog"));
    }

    #[test]
    fn test_emit_discriminator_empty_mapping() {
        let code = emit_to_string(|w, ctx| {
            emit_discriminator(w, ctx, "type", &[]);
        });
        // With no variants, still has object guard, tag checks, unknown fallback
        assert!(code.contains("\"type\" in instance"));
        assert!(code.contains("else"));
    }
}
