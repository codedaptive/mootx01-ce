
use aria_mcp::{dispatcher::Dispatcher, estate_posture::EstatePosture,
    estate_registry::EstateRegistry, jsonrpc::JSONRPCRequest};

fn call(dispatcher: &Dispatcher, tool: &str, arguments: serde_json::Value) -> serde_json::Value {
    let request = JSONRPCRequest::decode(&serde_json::json!({
        "jsonrpc":"2.0", "id":1, "method":"tools/call",
        "params":{"name":tool,"arguments":arguments}
    })).unwrap();
    serde_json::to_value(dispatcher.handle(&request)).unwrap()
}

#[test]
fn frozen_selected_memory_search_preserves_traces_and_live_search_records_usage() {
    for posture in [EstatePosture::Frozen, EstatePosture::Live] {
        let registry = EstateRegistry::new_inmemory();
        let store = registry.default.store.clone();
        let dispatcher = Dispatcher::new(registry, "test", "test", "test", "", None)
            .with_posture(EstatePosture::Live);
        let filed = call(&dispatcher, "moot_file_memory", serde_json::json!({
            "subject":"orchard", "content":"Orchard radio calibration uses channel 17.",
            "location":"Lab"
        }));
        assert_eq!(filed["result"]["isError"], false, "{filed}");
        let before = store.count_recall_traces().unwrap();
        let dispatcher = dispatcher.with_posture(posture);
        let result = call(&dispatcher, "moot_memory_search", serde_json::json!({
            "query":"orchard radio calibration", "limit":1
        }));
        assert_eq!(result["result"]["isError"], false, "{result}");
        assert!(!result["result"]["structuredContent"]["data"]["results"].as_array().unwrap().is_empty());
        let after = store.count_recall_traces().unwrap();
        if posture == EstatePosture::Frozen { assert_eq!(after,before); }
        else { assert!(after>before); }
    }
}
