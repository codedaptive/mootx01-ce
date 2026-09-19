// chest_diversity_tests.rs
//
// ADR-027 D3: `chest_diversity` is a per-call global modifier. The door
// strips it before the operation decodes, so a memory_search carrying it
// decodes cleanly, and the call-scoped value parses on/off and ignores any
// other spelling. Twin of the Swift `AriaV2ChestDiversityTests`.

use aria_mcp::dispatcher::Dispatcher;
use aria_mcp::estate_registry::EstateRegistry;
use aria_mcp::jsonrpc::JSONRPCRequest;

fn make_dispatcher() -> Dispatcher {
    Dispatcher::new(EstateRegistry::new_inmemory(), "ARIA_MCP_Rust", "test", "test-serial", None)
}

fn tools_call_response(dispatcher: &Dispatcher, tool_name: &str, args_json: serde_json::Value) -> serde_json::Value {
    let raw = serde_json::json!({
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": { "name": tool_name, "arguments": args_json }
    });
    let request = JSONRPCRequest::decode(&raw).expect("request must decode");
    let response = dispatcher.handle(&request);
    serde_json::to_value(&response).expect("response must serialize")
}

#[test]
fn modifier_is_stripped_before_decode() {
    let dispatcher = make_dispatcher();
    for value in ["on", "off", "sideways"] {
        let response = tools_call_response(
            &dispatcher,
            "moot_memory_search",
            serde_json::json!({ "query": "anything at all", "chest_diversity": value }),
        );
        assert!(response.get("error").is_none(), "chest_diversity={value} must not reach the decoder: {response}");
        assert_ne!(response["result"]["isError"], serde_json::json!(true), "chest_diversity={value}: {response}");
    }
}
