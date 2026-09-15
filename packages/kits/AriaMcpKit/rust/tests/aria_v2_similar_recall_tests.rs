//! Typed v2 similar recall: strict decode and one dispatcher round-trip on a
//! scratch in-memory estate.  The estate has no registered corpus, so the
//! lane takes its empty path and the envelope carries zero matches.

use aria_mcp::{
    dispatcher::Dispatcher,
    estate_registry::EstateRegistry,
    jsonrpc::{JSONRPCRequest, JsonValue},
    v2::similar_recall::V2SimilarRecallRequest,
};
use serde_json::json;

fn dispatcher() -> Dispatcher {
    Dispatcher::new(EstateRegistry::new_inmemory(), "ARIA", "test", "test-build", None)
}

fn call(dispatcher: &Dispatcher, tool: &str, arguments: serde_json::Value) -> serde_json::Value {
    let request = JSONRPCRequest::decode(&json!({
        "jsonrpc":"2.0",
        "id":1,
        "method":"tools/call",
        "params":{"name":tool,"arguments":arguments},
    }))
    .expect("valid JSON-RPC request");
    serde_json::to_value(dispatcher.handle(&request)).expect("serializable response")
}

#[test]
fn decode_requires_query_and_defaults_limit() {
    let missing = V2SimilarRecallRequest::decode(&JsonValue::Object(Default::default()));
    assert!(missing.is_err(), "a missing query must be refused");
    let request = V2SimilarRecallRequest::decode(&JsonValue::Object(
        [("query".to_owned(), JsonValue::String("api timeout".to_owned()))].into_iter().collect(),
    ))
    .unwrap();
    assert_eq!(request.query, "api timeout");
    assert_eq!(request.limit, 10);
}

#[test]
fn dispatcher_round_trip_returns_a_result_envelope() {
    let dispatcher = dispatcher();
    let error = call(&dispatcher, "moot_recall_similar", json!({"limit": 5}));
    assert_eq!(error["error"]["code"], -32602, "missing query must be rejected by the typed decoder");
    let response = call(&dispatcher, "moot_recall_similar", json!({"query":"api timeout request gives up"}));
    assert_eq!(response["result"]["isError"], false);
    assert_eq!(response["result"]["structuredContent"]["tool"], "moot_recall_similar");
    assert!(response["result"]["structuredContent"]["data"]["matches"].is_array());
}
