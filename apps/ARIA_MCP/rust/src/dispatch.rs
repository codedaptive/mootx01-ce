//! Top-level tool dispatch — maps a tool name to its handler.
//!
//! Routing order:
//!   0. teachme pre-check — intercepts `teachme:true` before any runner fires
//!   1. Federation tool (moot_federated_search)
//!   2. Interface tools (Tier 1–5, 19 tools)
//!   3. Vault tools (backed by vault-kit; ADR-VAULTKIT-002)
//!   4. Recipe tools (moot_list_lenses, moot_synthesize, …)
//!   5. Lens tools (moot_lens_keystones … moot_lens_concepts)
//!   6. Unknown tool → methodNotFound error
//!   hint: appended to non-error results by CoachingEngine
//!
//! Out-of-band faults (unknown tool, missing required argument, malformed
//! UUID) surface as `JSONRPCError` (thrown as Err). Substrate-level
//! refusals surface as a tool-call result with `isError: true`, matching
//! the Swift discipline.

use std::collections::BTreeMap;

use crate::estate_registry::EstateRegistry;
use crate::jsonrpc::{JSONRPCError, JSONRPCErrorCode, JsonValue};

/// Dispatch `name` with `args` against `registry`. Returns the MCP
/// `tools/call` result payload (a `serde_json::Value` with `content` array
/// and `isError` flag). Throws `JSONRPCError` for out-of-band failures.
///
/// Routing order (mirrors Swift `ToolDispatcher.dispatch(_:_:)`):
///   0. teachme interception — returns guide before any runner fires
///   1. Federation tool (moot_federated_search)
///   2. Interface tools (Tier 1–5, 19 tools)
///   3. Vault tools (backed by vault-kit; ADR-VAULTKIT-002)
///   4. Recipe tools (moot_list_lenses, moot_synthesize, …)
///   5. Lens tools (moot_lens_keystones … moot_lens_concepts)
///   post-dispatch: hint injection via CoachingEngine
pub fn dispatch_tool(
    name: &str,
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    // 0. Teachme interception — intercepts BEFORE any runner fires.
    //    Returns guide text; estate is never touched.
    if args.get("teachme").and_then(|v| v.as_bool()) == Some(true) {
        return Ok(text_result(crate::teachme_guides::guide(name)));
    }

    // 1. Federation tool — moot_federated_search sits above the recipe/lens surface.
    //    The Rust GLK fan_out has no grant model yet. Advertised in tools/list;
    //    every call returns error_result per DECISION_FEDERATION_SHARING_MODEL §13.
    if name == "moot_federated_search" {
        return Ok(error_result(
            "not yet implemented: federation requires the grant model",
        ));
    }

    // 2. Interface tools (Tier 1–5)
    if crate::interface_tools::is_interface_tool(name) {
        let result = crate::interface_tools::dispatch(name, args, registry)?;
        return Ok(inject_hint(name, args, result));
    }

    // 3. Vault tools — backed by vault-kit (VaultBridge + ObsidianAdapter +
    //    DrawerMapping). The ARIA layer owns the SHA-256 sidecar manifest for
    //    drift detection (ADR-VAULTKIT-002 decision b). No hint injection on
    //    vault results — they carry filesystem paths, not coaching triggers.
    if name.starts_with("moot_vault_") {
        return crate::vault_tools::dispatch_vault(name, args, registry);
    }

    // 4. Recipe tools
    if crate::recipe_tools::is_recipe_tool(name) {
        let result = crate::recipe_tools::dispatch(name, args, registry)?;
        return Ok(inject_hint(name, args, result));
    }

    // 5. Lens tools
    if crate::lens_tools::is_lens_tool(name) {
        let result = crate::lens_tools::dispatch(name, args, registry)?;
        return Ok(inject_hint(name, args, result));
    }

    // Unknown tool — transport-level fault (not a tool-level refusal).
    Err(JSONRPCError::new(
        JSONRPCErrorCode::METHOD_NOT_FOUND,
        format!("Unknown tool: {name}"),
    ))
}

/// Append a coaching hint to a non-error result if the CoachingEngine fires.
/// Never modifies error results (`isError: true`).
fn inject_hint(
    name: &str,
    args: &BTreeMap<String, JsonValue>,
    mut result: serde_json::Value,
) -> serde_json::Value {
    // Only inject hints on success results.
    if result.get("isError").and_then(|v| v.as_bool()) == Some(true) {
        return result;
    }
    let result_text = result["content"][0]["text"]
        .as_str()
        .unwrap_or("")
        .to_string();
    if let Some(hint) = crate::coaching_engine::hint(name, args, &result_text) {
        let new_text = format!("{result_text}\nhint: {hint}");
        if let Some(text_field) = result["content"][0]["text"].as_str() {
            let _ = text_field; // drop immutable borrow so the mutable assignment below compiles
            result["content"][0]["text"] = serde_json::Value::String(new_text);
        }
    }
    result
}

// ---------------------------------------------------------------------------
// Shared result helpers — mirror Swift ToolDispatcher.textResult / errorResult
// ---------------------------------------------------------------------------

/// MCP `tools/call` success result with a single text content block.
/// Wire-identical to the Swift `ToolDispatcher.textResult(_:)`.
pub fn text_result(text: &str) -> serde_json::Value {
    serde_json::json!({
        "content": [{ "type": "text", "text": text }],
        "isError": false
    })
}

/// MCP `tools/call` failure result. Substrate refusals surface here so the
/// client retains the call id and can render the message.
/// Wire-identical to Swift `ToolDispatcher.errorResult(_:)`.
pub fn error_result(text: &str) -> serde_json::Value {
    serde_json::json!({
        "content": [{ "type": "text", "text": text }],
        "isError": true
    })
}

// ---------------------------------------------------------------------------
// Shared argument helpers used by recipe, lens, and lexicon modules
// ---------------------------------------------------------------------------

/// Extract a required string argument or return `invalidParams`.
pub fn require_string<'a>(
    args: &'a BTreeMap<String, JsonValue>,
    key: &str,
) -> Result<&'a str, JSONRPCError> {
    args.get(key).and_then(|v| v.as_str()).ok_or_else(|| {
        JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("Missing required string argument: {key}"),
        )
    })
}

/// Extract an optional integer argument with a fallback.
pub fn opt_integer(args: &BTreeMap<String, JsonValue>, key: &str, fallback: i64) -> i64 {
    args.get(key).and_then(|v| v.as_i64()).unwrap_or(fallback)
}

/// Extract an optional float argument with a fallback.
pub fn opt_float(args: &BTreeMap<String, JsonValue>, key: &str, fallback: f64) -> f64 {
    args.get(key).and_then(|v| v.as_f64()).unwrap_or(fallback)
}

/// Decode the recall filter from an optional `filter` argument.
/// Default: `Unconfirmed`. Mirrors Swift `RecipeTools.decodeFilter` and
/// `LensTools.frame(_:)`.
pub fn decode_filter(args: &BTreeMap<String, JsonValue>) -> locus_kit::filter::Filter {
    use locus_kit::filter::Filter;
    match args.get("filter").and_then(|v| v.as_str()) {
        Some("userConfirmed") => Filter::UserConfirmed,
        Some("exportable") => Filter::Exportable,
        Some("contained") => Filter::Contained,
        Some("currentlyBelieve") => Filter::CurrentlyBelieve,
        _ => Filter::Unconfirmed,
    }
}

/// Build a recall frame from the filter in `args`. Used by the lenses
/// that accept an optional filter. Mirrors `LensTools.frame(_:)`.
pub fn recall_frame(args: &BTreeMap<String, JsonValue>) -> locus_kit::filter::RecallFrame {
    locus_kit::filter::RecallFrame::new(vec![decode_filter(args)])
}

/// Wall-clock seconds at the time of dispatch. Lenses that take `now: i64`
/// call this. Tests inject fixed values through `dispatch_tool_at` below.
pub fn wall_now() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}
