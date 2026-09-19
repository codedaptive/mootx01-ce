//! Retrieval-call override seam. Twin of Swift `RetrievalCallSpec.swift`.
//!
//! The lanes' query verb is normally fixed by their VerbMap; a caller may
//! override the tool and attach constant arguments through the environment,
//! the same instrument seam family as MOOT_BENCH_ANSWER_CMD /
//! MOOT_BENCH_JUDGE_CMD / MOOT_BENCH_RERANK_CMD:
//!
//!   MOOT_BENCH_RETRIEVAL_TOOL  tool to call instead of the verb map's query
//!   MOOT_BENCH_RETRIEVAL_ARGS  JSON object of constant arguments; values
//!                              pass through verbatim (string, number, bool,
//!                              …) so tools with integer parameters (pool,
//!                              limit) can be driven through the seam
//!   MOOT_BENCH_UNIT_IDS        path to a unit-ID file (one per line)

use std::collections::BTreeMap;

use crate::json_value::JsonValue;

/// One retrieval call description: tool + constant extra arguments.
/// `JsonValue` carries an f64 number, so this type is PartialEq only.
#[derive(Debug, Clone, PartialEq)]
pub struct RetrievalCallSpec {
    pub tool: String,
    pub extra_args: BTreeMap<String, JsonValue>,
}

/// Converts a parsed serde_json value into the wire JsonValue verbatim.
fn to_json_value(v: &serde_json::Value) -> JsonValue {
    match v {
        serde_json::Value::Null => JsonValue::Null,
        serde_json::Value::Bool(b) => JsonValue::Bool(*b),
        serde_json::Value::Number(n) => JsonValue::Number(n.as_f64().unwrap_or(0.0)),
        serde_json::Value::String(s) => JsonValue::String(s.clone()),
        serde_json::Value::Array(a) => JsonValue::Array(a.iter().map(to_json_value).collect()),
        serde_json::Value::Object(o) => JsonValue::Object(
            o.iter().map(|(k, v)| (k.clone(), to_json_value(v))).collect()),
    }
}

/// Reads the retrieval-call seam from the environment. None when unset.
/// A malformed args JSON is a hard error — a seam that silently dropped
/// its arguments would measure the wrong door.
pub fn retrieval_call_spec_from_environment() -> Result<Option<RetrievalCallSpec>, String> {
    let tool = match std::env::var("MOOT_BENCH_RETRIEVAL_TOOL") {
        Ok(t) if !t.is_empty() => t,
        _ => return Ok(None),
    };
    let mut extra: BTreeMap<String, JsonValue> = BTreeMap::new();
    if let Ok(raw) = std::env::var("MOOT_BENCH_RETRIEVAL_ARGS") {
        if !raw.is_empty() {
            let parsed: serde_json::Value = serde_json::from_str(&raw)
                .map_err(|_| "MOOT_BENCH_RETRIEVAL_ARGS must be a JSON object".to_string())?;
            let obj = parsed
                .as_object()
                .ok_or_else(|| "MOOT_BENCH_RETRIEVAL_ARGS must be a JSON object".to_string())?;
            for (k, v) in obj {
                extra.insert(k.clone(), to_json_value(v));
            }
        }
    }
    Ok(Some(RetrievalCallSpec { tool, extra_args: extra }))
}

/// Reads the unit-ID seam from the environment. None when unset.
pub fn unit_ids_from_environment(
) -> Result<Option<std::collections::HashSet<String>>, String> {
    match std::env::var("MOOT_BENCH_UNIT_IDS") {
        Ok(p) if !p.is_empty() => Ok(Some(crate::unit_id_filter::load_unit_ids(&p)?)),
        _ => Ok(None),
    }
}

/// Checks whether a retrieval result carries a tool-level refusal and, when
/// it does, converts it to `Err(MCPError)` with a `[class=CODE]` prefix.
///
/// ARIA v2 tool-level refusals arrive as `Ok(MCPToolResult { is_error: true,
/// refusal: Some(...) })` — the JSON-RPC transport succeeded; the tool itself
/// signalled an error. Without this check a refused retrieval propagates as an
/// empty-success and the cell records zero retrieved IDs with exit 0.
///
/// Parity with Swift `RetrievalCallSpec.retrieveThroughSeam` lines 100-110,
/// which checks `result.isError` and throws `MCPError` with `"[class=\(code)]"`.
/// Chain after `call_tool` via `.and_then(check_retrieval_result)`.
pub fn check_retrieval_result(
    result: crate::mcp_result::MCPToolResult,
) -> Result<crate::mcp_result::MCPToolResult, crate::mcp_client::MCPError> {
    if result.is_error {
        let code = result
            .refusal
            .as_ref()
            .map(|r| r.code.as_str())
            .unwrap_or("unknown");
        let msg = result
            .refusal
            .as_ref()
            .map(|r| r.message.as_str())
            .unwrap_or("tool returned is_error");
        return Err(crate::mcp_client::MCPError {
            description: format!("[class={}] {}", code, msg),
        });
    }
    Ok(result)
}

/// Builds the (tool, args) pair for one retrieval: the override spec when
/// present, else the lane's standard verb-map query. Twin of Swift
/// `retrieveThroughSeam` (the Rust call sites own the actual call).
pub fn seam_call(
    verb_map: &crate::config::VerbMap,
    spec: Option<&RetrievalCallSpec>,
    text: &str,
) -> (String, BTreeMap<String, crate::json_value::JsonValue>) {
    match spec {
        None => {
            // Use the adapter builder so `location` is remapped to `wing` for
            // moot_memory_search queries. moot_file_memory writes keep `location`
            // via their own write_args path; seam_call is query-only.
            let args = crate::aria_v2_surface::memory_search_args(&verb_map.constant_args, text);
            (verb_map.query.clone(), args)
        }
        Some(s) => {
            let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
            args.insert(verb_map.query_arg.clone(), JsonValue::String(text.to_string()));
            for (k, v) in &s.extra_args {
                args.insert(k.clone(), v.clone());
            }
            (s.tool.clone(), args)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mcp_result::{MCPToolResult, MCPRefusalInfo};

    fn refused_result(code: &str, message: &str) -> MCPToolResult {
        MCPToolResult {
            is_error: true,
            refusal: Some(MCPRefusalInfo {
                code: code.to_string(),
                message: message.to_string(),
                recovery: None,
                retryable: None,
                path: None,
                allowed: None,
                correction: None,
            }),
            ..MCPToolResult::default()
        }
    }

    /// Refused result (is_error=true) converts to Err with [class=CODE] prefix.
    /// Parity gate for Swift RetrievalCallSpec.retrieveThroughSeam:100-110.
    #[test]
    fn check_retrieval_result_is_error_carries_class_tag() {
        let r = refused_result("memory_not_found", "the drawer was not found");
        let err = check_retrieval_result(r).expect_err("is_error=true must yield Err");
        assert!(
            err.description.starts_with("[class=memory_not_found]"),
            "error description must start with [class=CODE]; got: {}",
            err.description
        );
    }

    /// Non-refused result (is_error=false) passes through as Ok.
    #[test]
    fn check_retrieval_result_ok_passes_through() {
        let r = MCPToolResult::default(); // is_error=false
        assert!(check_retrieval_result(r).is_ok());
    }

    /// Refused result with no refusal payload uses class "unknown".
    #[test]
    fn check_retrieval_result_no_refusal_uses_unknown_class() {
        let r = MCPToolResult { is_error: true, ..MCPToolResult::default() };
        let err = check_retrieval_result(r).expect_err("is_error=true must yield Err");
        assert!(
            err.description.starts_with("[class=unknown]"),
            "error description must use 'unknown' when refusal is absent; got: {}",
            err.description
        );
    }
}
