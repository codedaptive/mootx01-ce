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

// ---------------------------------------------------------------------------
// Catalog: every argument must be declared in memory_search properties
// ---------------------------------------------------------------------------

#[test]
fn catalog_declares_all_nine_arguments() {
    let tools = aria_mcp::v2::catalog::selected_tools();
    let descriptor = tools
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["name"] == "moot_memory_search")
        .expect("moot_memory_search must be in the catalog");

    let props = &descriptor["inputSchema"]["properties"];
    for arg in &["filter", "wing", "media_type", "door", "scoring", "ordering", "frontier_k", "explain", "answer"] {
        assert!(
            !props[arg].is_null(),
            "catalog missing property: {arg}"
        );
    }

    // Type assertions for the corrected fields.
    assert_eq!(props["frontier_k"]["type"], "integer",
        "frontier_k must be declared as integer in catalog");
    assert_eq!(props["explain"]["type"], "boolean",
        "explain must be declared as boolean in catalog");
    assert_eq!(props["answer"]["type"], "string",
        "answer must be declared as string in catalog");
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
    // Validation moved to decode: returns -32602 INVALID_PARAMS (matching Swift
    // JSONRPCError(code: .invalidParams)), not a success-shaped refusal envelope.
    let d = dispatcher();
    let r = search(&d, json!({"filter": "bogusFilter"}));
    assert_eq!(
        r["error"]["code"],
        json!(-32602),
        "unknown filter must produce a -32602 decode error; got: {r}"
    );
    assert_eq!(
        r["error"]["data"]["message"],
        json!("Unknown filter: bogusFilter. Valid: unconfirmed, userConfirmed, exportable, contained, pinned"),
        "error message must match exactly; got: {r}"
    );
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
    // Validation moved to decode: returns -32602 INVALID_PARAMS, not an envelope refusal.
    let d = dispatcher();
    let r = search(&d, json!({"media_type": "video"}));
    assert_eq!(
        r["error"]["code"],
        json!(-32602),
        "unknown media_type must produce a -32602 decode error; got: {r}"
    );
    assert_eq!(
        r["error"]["data"]["message"],
        json!("Unknown media_type: video. Valid: voice, image"),
        "error message must match exactly; got: {r}"
    );
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
    // Validation moved to decode: returns -32602 INVALID_PARAMS, not an envelope refusal.
    let d = dispatcher();
    let r = search(&d, json!({"door": "hedge"}));
    assert_eq!(
        r["error"]["code"],
        json!(-32602),
        "unknown door must produce a -32602 decode error; got: {r}"
    );
    assert_eq!(
        r["error"]["data"]["message"],
        json!("Unknown door: hedge. Valid: guess, raw, rrf, matrixAware, discriminative"),
        "error message must match exactly; got: {r}"
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
    // Validation moved to decode: returns -32602 INVALID_PARAMS, not an envelope refusal.
    let d = dispatcher();
    let r = search(&d, json!({"scoring": "fuzzy"}));
    assert_eq!(
        r["error"]["code"],
        json!(-32602),
        "unknown scoring must produce a -32602 decode error; got: {r}"
    );
    assert_eq!(
        r["error"]["data"]["message"],
        json!("Unknown scoring: fuzzy. Valid: raw, rrf, matrixAware, discriminative"),
        "error message must match exactly; got: {r}"
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
    // Validation moved to decode: returns -32602 INVALID_PARAMS, not an envelope refusal.
    let d = dispatcher();
    let r = search(&d, json!({"ordering": "newest"}));
    assert_eq!(
        r["error"]["code"],
        json!(-32602),
        "unknown ordering must produce a -32602 decode error; got: {r}"
    );
    assert_eq!(
        r["error"]["data"]["message"],
        json!("Unknown ordering: newest. Valid: byCaptureTimeDesc, byCaptureTimeAsc, byRoomAsc, byRelevanceDesc"),
        "error message must match exactly; got: {r}"
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

// ---------------------------------------------------------------------------
// answer — string enum: never, always, auto; unknown fails closed at decode
// ---------------------------------------------------------------------------

#[test]
fn answer_accepted_values_succeed() {
    let d = dispatcher();
    for value in &["never", "always", "auto"] {
        let r = search(&d, json!({"answer": value}));
        assert!(is_success(&r), "answer={value} must succeed; got: {r}");
    }
}

#[test]
fn answer_unknown_fails_closed_with_exact_message() {
    // Validation at decode: returns -32602 INVALID_PARAMS (matching Swift parity).
    let d = dispatcher();
    let r = search(&d, json!({"answer": "somehow"}));
    assert_eq!(
        r["error"]["code"],
        json!(-32602),
        "unknown answer must produce a -32602 decode error; got: {r}"
    );
    assert_eq!(
        r["error"]["data"]["message"],
        json!("Unknown answer: somehow. Valid: never, always, auto"),
        "error message must match exactly; got: {r}"
    );
}

#[test]
fn catalog_declares_answer_argument() {
    // The answer argument must be declared in the moot_memory_search catalog entry.
    let tools = aria_mcp::v2::catalog::selected_tools();
    let descriptor = tools
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["name"] == "moot_memory_search")
        .expect("moot_memory_search must be in the catalog");

    let props = &descriptor["inputSchema"]["properties"];
    assert!(
        !props["answer"].is_null(),
        "catalog must declare the 'answer' property for moot_memory_search"
    );
    // Enum must name all three accepted values.
    let enum_vals = props["answer"]["enum"].as_array().expect("answer must have enum");
    let val_strs: Vec<&str> = enum_vals.iter().filter_map(|v| v.as_str()).collect();
    assert!(val_strs.contains(&"never"),  "answer enum must include 'never'");
    assert!(val_strs.contains(&"always"), "answer enum must include 'always'");
    assert!(val_strs.contains(&"auto"),   "answer enum must include 'auto'");
}

// ---------------------------------------------------------------------------
// explain gate: discrimination line appears iff explain:true is passed
// ---------------------------------------------------------------------------

/// With explain:true and a populated estate that produces a non-trivial score
/// distribution, the moot_memory_search compact text MUST contain a
/// "discrimination:" line. Three closely-related memories produce a low or
/// medium signal — both are emitted in v2 compact text.
///
/// Both filing and searching go through the v2 Dispatcher — file_memory is a
/// v2 tool and the same Dispatcher handles both calls.
#[test]
fn explain_true_appends_discrimination_line() {
    let registry = EstateRegistry::new_inmemory();
    let disp = Dispatcher::new(registry, "test", "test", "test", None);

    // Three closely-related memories to produce a non-trivial score spread.
    for suffix in &["alpha", "beta", "gamma"] {
        let subject = format!("discrimination-gate-test content {suffix}");
        let r = call(&disp, "moot_file_memory", json!({
            "content": subject.as_str(),
            "subject": subject.as_str(),
            "location": "lab",
            "impatient": true
        }));
        assert!(is_success(&r), "file_memory must succeed; got: {r:?}");
    }

    let r = call(&disp, "moot_memory_search", json!({
        "query": "discrimination-gate-test",
        "explain": true
    }));
    assert!(is_success(&r), "explain:true must succeed; got: {r:?}");
    let text = r["result"]["content"][0]["text"].as_str().unwrap_or("");
    assert!(
        text.contains("discrimination:"),
        "explain:true must append a discrimination line; got: {text}"
    );
}

/// Without explain, the moot_memory_search compact text must NOT contain a
/// "discrimination:" line — the gate is strictly opt-in.
#[test]
fn explain_omitted_suppresses_discrimination_line() {
    let registry = EstateRegistry::new_inmemory();
    let disp = Dispatcher::new(registry, "test", "test", "test", None);

    for suffix in &["alpha", "beta", "gamma"] {
        let subject = format!("discrimination-gate-test content {suffix}");
        let r = call(&disp, "moot_file_memory", json!({
            "content": subject.as_str(),
            "subject": subject.as_str(),
            "location": "lab",
            "impatient": true
        }));
        assert!(is_success(&r), "file_memory must succeed; got: {r:?}");
    }

    // explain omitted — default is false, no discrimination line expected.
    let r = call(&disp, "moot_memory_search", json!({"query": "discrimination-gate-test"}));
    assert!(is_success(&r), "omitted explain must succeed; got: {r:?}");
    let text = r["result"]["content"][0]["text"].as_str().unwrap_or("");
    assert!(
        !text.contains("discrimination:"),
        "explain omitted must NOT produce a discrimination line; got: {text}"
    );
}
