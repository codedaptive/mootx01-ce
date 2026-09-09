//! Selected-surface integration for the typed v2 packet operations.

#![cfg(feature = "aria-v2")]

use aria_mcp::{
    dispatcher::Dispatcher,
    estate_registry::EstateRegistry,
    jsonrpc::JSONRPCRequest,
};
use serde_json::{json, Value};

fn fixture(name: &str) -> Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent().expect("AriaMcpKit package root")
        .join("Tests/Conformance")
        .join(name);
    serde_json::from_slice(&std::fs::read(path).expect("read shared ARIA v2 fixture"))
        .expect("decode shared ARIA v2 fixture")
}

fn required_data_keys(tool: &str) -> std::collections::BTreeSet<String> {
    fixture("aria_v2_output_schemas_edge.json")["operations"][tool]["data_schema"]["required"]
        .as_array().expect("required data keys")
        .iter().map(|value| value.as_str().expect("string key").to_owned())
        .collect()
}

fn data_keys(response: &Value) -> std::collections::BTreeSet<String> {
    response["result"]["structuredContent"]["data"]
        .as_object().expect("typed operation data")
        .keys().cloned().collect()
}

fn dispatcher() -> Dispatcher {
    Dispatcher::new(EstateRegistry::new_inmemory_bare(), "ARIA", "test", "test-build", "", None)
}

fn call(dispatcher: &Dispatcher, name: &str, arguments: Value) -> Value {
    let request = JSONRPCRequest::decode(&json!({
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": {"name": name, "arguments": arguments},
    }))
    .expect("valid JSON-RPC request");
    serde_json::to_value(dispatcher.handle(&request)).expect("serializable response")
}

fn file_arguments(objective: &str) -> Value {
    json!({
        "objective": objective,
        "model": "test-model",
        "agent": "test-agent",
        "sources": [{"description": "source drawer", "kind": "drawer"}],
        "claims": [{"statement": "validated claim", "confidence": 0.75}],
        "uncertainties": ["needs review"],
        "next_steps": ["verify lineage"],
    })
}

#[test]
fn selected_packet_catalog_consumes_shared_input_schemas() {
    let vectors = fixture("aria_v2_mission02_vectors.json");
    let records = vectors["catalog"]["operations"].as_array().expect("operation vectors");
    let registry = aria_mcp::v2::catalog::selected_registry();
    for name in ["moot_file_packet", "moot_packet_get", "moot_packet_list", "moot_packet_lineage"] {
        let expected = records.iter()
            .find(|record| record["name"] == name)
            .expect("shared packet operation");
        let actual = registry.operations()
            .find(|operation| operation.public_name == name)
            .expect("selected packet operation");
        assert_eq!(actual.input_schema, expected["inputSchema"], "{name} input schema");
        assert_eq!(actual.help.description, expected["description"], "{name} description");
        assert_eq!(serde_json::to_value(actual.effect).unwrap(), expected["effect"], "{name} effect");
    }
}

#[test]
fn packet_operations_use_typed_drawer_identity_and_preserve_packet_fields() {
    let dispatcher = dispatcher();
    let parent = call(&dispatcher, "moot_file_packet", file_arguments("parent packet"));
    assert_eq!(parent["result"]["isError"], false, "{parent}");
    assert_eq!(data_keys(&parent), required_data_keys("moot_file_packet"));
    assert_eq!(parent["result"]["structuredContent"]["meta"]["effect"], "write");
    let parent_id = parent["result"]["structuredContent"]["data"]["drawer_id"]
        .as_str().expect("drawer UUID").to_owned();

    let mut child_arguments = file_arguments("child packet");
    child_arguments["lineage_links"] = json!([
        {"kind": "derivesFrom", "targetPacketID": parent_id.clone()}
    ]);
    let child = call(&dispatcher, "moot_file_packet", child_arguments);
    assert_eq!(child["result"]["isError"], false, "{child}");
    let child_id = child["result"]["structuredContent"]["data"]["drawer_id"]
        .as_str().expect("child drawer UUID").to_owned();
    assert_ne!(
        child_id,
        child["result"]["structuredContent"]["data"]["packet_id"]
            .as_str().expect("packet UUID"),
    );

    let get = call(&dispatcher, "moot_packet_get", json!({"drawer_id": child_id.clone()}));
    assert_eq!(get["result"]["isError"], false, "{get}");
    assert_eq!(data_keys(&get), required_data_keys("moot_packet_get"));
    assert_eq!(get["result"]["structuredContent"]["data"]["packet"]["objective"], "child packet");
    assert_eq!(get["result"]["structuredContent"]["data"]["packet"]["claims"][0]["statement"], "validated claim");
    assert_eq!(get["result"]["structuredContent"]["data"]["packet"]["next_steps"][0], "verify lineage");

    let list = call(&dispatcher, "moot_packet_list", json!({}));
    assert_eq!(list["result"]["isError"], false, "{list}");
    assert_eq!(data_keys(&list), required_data_keys("moot_packet_list"));
    assert!(list["result"]["structuredContent"]["data"]["packets"]
        .as_array().expect("typed packet rows")
        .iter().any(|row| row["drawer_id"].as_str() == Some(child_id.as_str())));

    let lineage = call(&dispatcher, "moot_packet_lineage", json!({"drawer_id": child_id}));
    assert_eq!(lineage["result"]["isError"], false, "{lineage}");
    assert_eq!(data_keys(&lineage), required_data_keys("moot_packet_lineage"));
    assert_eq!(lineage["result"]["structuredContent"]["data"]["antecedents"], json!([parent_id]));
}

#[test]
fn packet_surface_rejects_unknown_fields_and_hides_restricted_packet_existence() {
    let dispatcher = dispatcher();
    let rejected = call(&dispatcher, "moot_file_packet", json!({
        "objective": "bad", "model": "test-model", "agent": "test-agent",
        "sources": [{"description": "source", "unexpected": true}],
    }));
    assert_eq!(rejected["error"]["code"], -32602, "{rejected}");
    assert_eq!(rejected["error"]["data"]["code"], "invalid_argument");

    let restricted = call(&dispatcher, "moot_file_packet", json!({
        "objective": "restricted", "model": "test-model", "agent": "test-agent",
        "sensitivity": "restricted",
    }));
    assert_eq!(restricted["result"]["isError"], false, "{restricted}");
    let hidden_id = restricted["result"]["structuredContent"]["data"]["drawer_id"]
        .as_str().expect("restricted drawer UUID");
    let hidden = call(&dispatcher, "moot_packet_get", json!({"drawer_id": hidden_id}));
    let missing = call(&dispatcher, "moot_packet_get", json!({
        "drawer_id": "11111111-1111-4111-8111-111111111111"
    }));
    assert_eq!(hidden["result"]["structuredContent"]["error"], missing["result"]["structuredContent"]["error"]);
    assert_eq!(hidden["result"]["structuredContent"]["error"]["code"], "packet_not_found");
}
