//! SEC-04 regressions for the selected v2 memory-search disclosure boundary.

use aria_mcp::{dispatcher::Dispatcher, estate_registry::{EstateOpening, EstateRegistry}, jsonrpc::JSONRPCRequest};
use locus_kit::{
    drawer_operational::CaptureChannel, estate_types::LatticeAnchor, frames::CaptureFrame,
    provenance::Sensitivity,
};
use serde_json::json;

fn call(dispatcher: &Dispatcher, arguments: serde_json::Value) -> serde_json::Value {
    let request = JSONRPCRequest::decode(&json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {"name": "moot_memory_search", "arguments": arguments}
    }))
    .expect("valid tools/call request");
    serde_json::to_value(dispatcher.handle(&request)).expect("serializable response")
}

#[test]
fn answer_always_cannot_cite_a_provenance_restricted_unique_hit() {
    // A unique-hit disclosure fixture must not include unrelated seeded charter rows.
    let registry = EstateRegistry::new_inmemory_with(EstateOpening::TRANSIENT);
    let sentinel = "sec04-hidden-citation-oracle-unique-marker";
    let hidden_id = {
        let mut frame = CaptureFrame::new(
            sentinel,
            CaptureChannel::Typed,
            "sec04",
            LatticeAnchor::udc("004"),
            "sec04-tests",
            "default",
        );
        // Keep adjective sensitivity Normal so lower recall admits the hit. The
        // selected v2 provenance boundary must remove it before packaging.
        frame.provenance_sensitivity = Sensitivity::Restricted;
        registry
            .coord
            .lock()
            .expect("coordinator lock")
            .capture(&registry.default.handle, frame, 1_700_000_000_000)
            .expect("capture provenance-restricted fixture")
            .id
    };
    let dispatcher = Dispatcher::new(registry, "test", "test", "test", None);

    let response = call(
        &dispatcher,
        json!({"query": sentinel, "limit": 1, "answer": "always"}),
    );

    assert_eq!(response["result"]["isError"], json!(false));
    assert_eq!(
        response["result"]["structuredContent"]["data"]["results"],
        json!([]),
        "the provenance-restricted hit must not become a visible result row"
    );
    let encoded = serde_json::to_string(&response).expect("serialize response for leak check");
    assert!(
        !encoded.contains(&hidden_id),
        "answer packaging must not expose the hidden row id as a citation: {encoded}"
    );
    assert!(
        !encoded.contains(sentinel),
        "answer packaging must not expose content derived from the hidden row: {encoded}"
    );
}
