//! Top-level tool dispatch — maps a tool name to its handler.
//!
//! Mirrors the Swift `ToolDispatcher.dispatch(name:arguments:)` routing
//! order:
//!   1. Federation tools (moot_cross_estate_recall — above the lexicon projection)
//!   2. Recipe tools (moot_list_recipes, moot_grounded_synthesis, …)
//!   3. Lens tools (moot_keystones … moot_estate_divergence)
//!   4. Lexicon tools (28 tools after v2b-p2 full-matrix fan-out)
//!   5. Unknown tool → methodNotFound error
//!
//! Out-of-band faults (unknown tool, missing required argument, malformed
//! UUID) surface as `JSONRPCError` (thrown as Err). Substrate-level
//! refusals (a recipe refusing an operation) surface as a tool-call result
//! with `isError: true`, matching the Swift discipline.

use std::collections::BTreeMap;

use crate::estate_registry::EstateRegistry;
use crate::jsonrpc::{JSONRPCError, JSONRPCErrorCode, JsonValue};

/// Dispatch `name` with `args` against `registry`. Returns the MCP
/// `tools/call` result payload (a `serde_json::Value` with `content` array
/// and `isError` flag). Throws `JSONRPCError` for out-of-band failures.
pub fn dispatch_tool(
    name: &str,
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    // 1. Federation tools — sit above the lexicon projection, dispatched by name.
    //    moot_cross_estate_recall is a scaffold: the Rust GLK fan_out has no grant
    //    model yet. The tool is advertised in tools/list so clients know it exists;
    //    every call returns error_result per the A-versus-C refusal discipline
    //    (DECISION_FEDERATION_SHARING_MODEL_2026-05-21 §13).
    if name == crate::lexicon_tools::CROSS_ESTATE_RECALL {
        return Ok(error_result(
            "not yet implemented: federation requires the grant model",
        ));
    }
    // 2. Recipe tools
    if crate::recipe_tools::is_recipe_tool(name) {
        return crate::recipe_tools::dispatch(name, args, registry);
    }
    // 3. Lens tools
    if crate::lens_tools::is_lens_tool(name) {
        return crate::lens_tools::dispatch(name, args, registry);
    }
    // 4. Lexicon tools (v1 + v2b-p1 + v2b-p2 full matrix)
    if crate::lexicon_tools::is_lexicon_tool(name) {
        return crate::lexicon_tools::dispatch(name, args, registry);
    }
    // 5. Unknown
    Err(JSONRPCError::new(
        JSONRPCErrorCode::METHOD_NOT_FOUND,
        format!("Unknown tool: {name}"),
    ))
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
