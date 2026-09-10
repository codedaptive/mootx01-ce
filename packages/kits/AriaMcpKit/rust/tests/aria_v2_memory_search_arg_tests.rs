//! Rust coverage for the eight v2 `moot_memory_search` arguments.
//!
//! Each argument is tested through the full v2 dispatch path (Dispatcher).
//! Accepted values succeed (isError:false); unknown values fail closed with
//! the exact error text specified by the brief. Type-wrong values (frontier_k
//! as string, explain as string) produce a -32602 JSONRPC decode error.
//! The catalog section verifies that each argument is declared in the
//! memory_search descriptor.

use aria_mcp::{
    dispatcher::Dispatcher, estate_registry::EstateRegistry, jsonrpc::JSONRPCRequest,
};
use serde_json::json;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn dispatcher() -> Dispatcher {
    let registry = EstateRegistry::new_inmemory();
    Dispatcher::new(registry, "test", "test", "test", None)
}

/// Drive a tools/call through the v2 dispatch path.
fn call(dispatcher: &Dispatcher, tool: &str, arguments: serde_json::Value) -> serde_json::Value {
    let request = JSONRPCRequest::decode(&json!({
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": {"name": tool, "arguments": arguments}
    }))
    .unwrap();
    serde_json::to_value(dispatcher.handle(&request)).unwrap()
}

/// Drive a search on an empty estate. With no content seeded the result is an
/// empty list — but isError must be false for the argument to be accepted.
fn search(dispatcher: &Dispatcher, extra: serde_json::Value) -> serde_json::Value {
    let mut args = json!({"query": "test"});
    if let (Some(obj), Some(ext)) = (args.as_object_mut(), extra.as_object()) {
        for (k, v) in ext {
            obj.insert(k.clone(), v.clone());
        }
    }
    call(dispatcher, "moot_memory_search", args)
}

fn is_success(r: &serde_json::Value) -> bool {
    r["result"]["isError"] == json!(false)
}

fn error_code(r: &serde_json::Value) -> &str {
    r["result"]["structuredContent"]["error"]["code"].as_str().unwrap_or("")
}

fn error_message(r: &serde_json::Value) -> &str {
    r["result"]["structuredContent"]["error"]["message"].as_str().unwrap_or("")
}

// ---------------------------------------------------------------------------
// Catalog: every argument must be declared in memory_search properties
// ---------------------------------------------------------------------------

#[test]
fn catalog_declares_all_eight_arguments() {
    let tools = aria_mcp::v2::catalog::selected_tools();
    let descriptor = tools
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["name"] == "moot_memory_search")
        .expect("moot_memory_search must be in the catalog");

    let props = &descriptor["inputSchema"]["properties"];
    for arg in &["filter", "wing", "media_type", "door", "scoring", "ordering", "frontier_k", "explain"] {
        assert!(
            !props[arg].is_null(),
            "catalog missing property: {arg}"
        );
    }

    // Type assertions for the two corrected fields.
    assert_eq!(props["frontier_k"]["type"], "integer",
        "frontier_k must be declared as integer in catalog");
    assert_eq!(props["explain"]["type"], "boolean",
        "explain must be declared as boolean in catalog");
}

// ---------------------------------------------------------------------------
// filter
// ---------------------------------------------------------------------------

#[test]
fn filter_accepted_values_succeed() {
    let d = dispatcher();
    for value in &["unconfirmed", "userConfirmed", "exportable", "contained", "pinned"] {
        let r = search(&d, json!({"filter": value}));
        assert!(is_success(&r), "filter={value} must succeed; got: {r}");
    }
}

#[test]
fn filter_unknown_fails_closed_with_exact_message() {
    let d = dispatcher();
    let r = search(&d, json!({"filter": "bogusFilter"}));
    assert!(!is_success(&r), "unknown filter must fail");
    assert_eq!(error_code(&r), "invalid_argument");
    assert_eq!(error_message(&r), "Unknown filter: bogusFilter",
        "error message must match exactly; got: {}", error_message(&r));
}

// ---------------------------------------------------------------------------
// wing
// ---------------------------------------------------------------------------

#[test]
fn wing_string_is_accepted() {
    let d = dispatcher();
    let r = search(&d, json!({"wing": "Agentic Memory"}));
    assert!(is_success(&r), "wing string must be accepted; got: {r}");
}

#[test]
fn wing_empty_string_is_accepted() {
    let d = dispatcher();
    let r = search(&d, json!({"wing": ""}));
    assert!(is_success(&r), "wing empty string must be accepted; got: {r}");
}

// ---------------------------------------------------------------------------
// media_type
// ---------------------------------------------------------------------------

#[test]
fn media_type_accepted_values_succeed() {
    let d = dispatcher();
    for value in &["voice", "image"] {
        let r = search(&d, json!({"media_type": value}));
        assert!(is_success(&r), "media_type={value} must succeed; got: {r}");
    }
}

#[test]
fn media_type_unknown_fails_closed_with_exact_message() {
    let d = dispatcher();
    let r = search(&d, json!({"media_type": "video"}));
    assert!(!is_success(&r), "unknown media_type must fail");
    assert_eq!(error_code(&r), "invalid_argument");
    assert_eq!(error_message(&r), "Unknown media_type: video. Valid: voice, image",
        "error message must match exactly; got: {}", error_message(&r));
}

// ---------------------------------------------------------------------------
// door
// ---------------------------------------------------------------------------

#[test]
fn door_accepted_values_succeed() {
    let d = dispatcher();
    // "guess" reads provisioned config (falls back to MatrixAware on empty estate).
    for value in &["guess", "raw", "rrf", "matrixAware", "discriminative"] {
        let r = search(&d, json!({"door": value}));
        assert!(is_success(&r), "door={value} must succeed; got: {r}");
    }
}

#[test]
fn door_unknown_fails_closed_with_exact_message() {
    let d = dispatcher();
    let r = search(&d, json!({"door": "hedge"}));
    assert!(!is_success(&r), "unknown door must fail closed");
    assert_eq!(error_code(&r), "invalid_argument");
    assert_eq!(
        error_message(&r),
        "Unknown door: hedge. Valid: guess, raw, rrf, matrixAware, discriminative",
        "error message must match exactly; got: {}", error_message(&r)
    );
}

#[test]
fn door_thorough_fails_closed() {
    // "thorough" is reserved at the recipe layer but unknown here.
    let d = dispatcher();
    let r = search(&d, json!({"door": "thorough"}));
    assert!(!is_success(&r), "thorough must fail closed at the door boundary");
}

// ---------------------------------------------------------------------------
// scoring
// ---------------------------------------------------------------------------

#[test]
fn scoring_accepted_values_succeed() {
    let d = dispatcher();
    for value in &["raw", "rrf", "matrixAware", "discriminative"] {
        let r = search(&d, json!({"scoring": value}));
        assert!(is_success(&r), "scoring={value} must succeed; got: {r}");
    }
}

#[test]
fn scoring_unknown_fails_closed_with_exact_message() {
    let d = dispatcher();
    let r = search(&d, json!({"scoring": "fuzzy"}));
    assert!(!is_success(&r), "unknown scoring must fail");
    assert_eq!(error_code(&r), "invalid_argument");
    assert_eq!(
        error_message(&r),
        "Unknown scoring: fuzzy. Valid: raw, rrf, matrixAware, discriminative",
        "error message must match exactly; got: {}", error_message(&r)
    );
}

// ---------------------------------------------------------------------------
// ordering
// ---------------------------------------------------------------------------

#[test]
fn ordering_accepted_values_succeed() {
    let d = dispatcher();
    for value in &["byCaptureTimeDesc", "byCaptureTimeAsc", "byRoomAsc", "byRelevanceDesc"] {
        let r = search(&d, json!({"ordering": value}));
        assert!(is_success(&r), "ordering={value} must succeed; got: {r}");
    }
}

#[test]
fn ordering_unknown_fails_closed_with_exact_message() {
    let d = dispatcher();
    let r = search(&d, json!({"ordering": "newest"}));
    assert!(!is_success(&r), "unknown ordering must fail");
    assert_eq!(error_code(&r), "invalid_argument");
    assert!(
        error_message(&r).starts_with("Unknown ordering: newest."),
        "error message must name the unknown value; got: {}", error_message(&r)
    );
}

// ---------------------------------------------------------------------------
// frontier_k — must be an integer; string is a decode error
// ---------------------------------------------------------------------------

#[test]
fn frontier_k_integer_is_accepted() {
    let d = dispatcher();
    let r = search(&d, json!({"frontier_k": 64}));
    assert!(is_success(&r), "frontier_k integer must be accepted; got: {r}");
}

#[test]
fn frontier_k_string_is_a_decode_error() {
    // The catalog declares frontier_k as integer; a string is a -32602 decode error.
    let d = dispatcher();
    let r = call(&d, "moot_memory_search", json!({"query": "test", "frontier_k": "64"}));
    // A decode error surfaces as a JSONRPC error, not as isError:true in the result.
    assert_eq!(
        r["error"]["code"],
        json!(-32602),
        "frontier_k string must produce a -32602 decode error; got: {r}"
    );
}

// ---------------------------------------------------------------------------
// explain — must be a boolean; string is a decode error
// ---------------------------------------------------------------------------

#[test]
fn explain_boolean_is_accepted() {
    let d = dispatcher();
    let r = search(&d, json!({"explain": false}));
    assert!(is_success(&r), "explain:false must be accepted; got: {r}");
    let r = search(&d, json!({"explain": true}));
    assert!(is_success(&r), "explain:true must be accepted; got: {r}");
}

#[test]
fn explain_string_is_a_decode_error() {
    // The catalog declares explain as boolean; passing a string is -32602.
    let d = dispatcher();
    let r = call(&d, "moot_memory_search", json!({"query": "test", "explain": "yes"}));
    assert_eq!(
        r["error"]["code"],
        json!(-32602),
        "explain string must produce a -32602 decode error; got: {r}"
    );
}
