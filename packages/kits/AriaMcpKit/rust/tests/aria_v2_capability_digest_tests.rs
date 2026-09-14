
use aria_mcp::v2::capability_digest::{
    canonical_capability_bytes, canonical_json_bytes, capability_digest, CapabilityEffect,
    CapabilityOperationDefinition,
};

#[test]
fn selected_catalog_digest_shared_vector() {
    let digest = aria_mcp::v2::catalog::selected_capability_digest();
    assert_eq!(digest, "f9e67547120a7034e464d01013a0e103a8a1a7d735f84a1a42c786e64783cceb");
    let artifact_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent().unwrap()
        .join("Registry/aria-v2-selected-release.json");
    let artifact: serde_json::Value = serde_json::from_slice(
        &std::fs::read(artifact_path).unwrap()).unwrap();
    assert_eq!(artifact["ariaVersion"], "v2");
    assert_eq!(artifact["catalogIdentity"], digest);
    let selected_tools = aria_mcp::v2::catalog::selected_tools();
    let descriptor = selected_tools.as_array().unwrap()
        .iter().find(|tool| tool["name"] == "moot_memory_list").unwrap();
    assert_eq!(descriptor["inputSchema"]["required"], serde_json::json!(["wing"]));
    assert_eq!(descriptor["outputSchema"]["properties"]["data"]["required"],
        serde_json::json!(["memories", "has_more", "revision"]));
}
use serde_json::json;

fn operation(
    name: &str,
    effect: CapabilityEffect,
    input_schema: serde_json::Value,
) -> CapabilityOperationDefinition {
    CapabilityOperationDefinition {
        identity: name.trim_start_matches("moot_").to_owned(),
        name: name.to_owned(),
        effect,
        availability: true,
        input_schema,
        output_schema: json!({
            "type": "object",
            "properties": {"data": {"type": "object"}},
            "required": ["data"]
        }),
        help: Some(json!({
            "description": "Read stable capability material.",
            "example": {"query": "catalog"}
        })),
        recipe_bindings: vec!["catalog.v1".to_owned()],
    }
}

#[test]
fn stable_vector_is_independent_of_operation_and_object_key_order() {
    let alpha = operation(
        "moot_alpha",
        CapabilityEffect::Read,
        json!({
            "required": ["query"],
            "properties": {"query": {"type": "string"}},
            "type": "object"
        }),
    );
    let beta = operation(
        "moot_beta",
        CapabilityEffect::Write,
        json!({"type": "object", "properties": {"enabled": {"type": "boolean"}}}),
    );
    let reordered_alpha = operation(
        "moot_alpha",
        CapabilityEffect::Read,
        json!({
            "type": "object",
            "properties": {"query": {"type": "string"}},
            "required": ["query"]
        }),
    );

    let expected_material = b"{\"operations\":[{\"availability\":true,\"effect\":\"read\",\"help\":{\"description\":\"Read stable capability material.\",\"example\":{\"query\":\"catalog\"}},\"identity\":\"alpha\",\"input_schema\":{\"properties\":{\"query\":{\"type\":\"string\"}},\"required\":[\"query\"],\"type\":\"object\"},\"name\":\"moot_alpha\",\"output_schema\":{\"properties\":{\"data\":{\"type\":\"object\"}},\"required\":[\"data\"],\"type\":\"object\"},\"recipe_bindings\":[\"catalog.v1\"]},{\"availability\":true,\"effect\":\"write\",\"help\":{\"description\":\"Read stable capability material.\",\"example\":{\"query\":\"catalog\"}},\"identity\":\"beta\",\"input_schema\":{\"properties\":{\"enabled\":{\"type\":\"boolean\"}},\"type\":\"object\"},\"name\":\"moot_beta\",\"output_schema\":{\"properties\":{\"data\":{\"type\":\"object\"}},\"required\":[\"data\"],\"type\":\"object\"},\"recipe_bindings\":[\"catalog.v1\"]}]}";

    let first = canonical_capability_bytes(&[beta, alpha]);
    let second = canonical_capability_bytes(&[reordered_alpha, operation(
        "moot_beta",
        CapabilityEffect::Write,
        json!({"properties": {"enabled": {"type": "boolean"}}, "type": "object"}),
    )]);

    assert_eq!(first, expected_material);
    assert_eq!(first, second);
    let first_digest = capability_digest(&[
        operation(
            "moot_beta",
            CapabilityEffect::Write,
            json!({"type":"object","properties":{"enabled":{"type":"boolean"}}}),
        ),
        operation(
            "moot_alpha",
            CapabilityEffect::Read,
            json!({"required":["query"],"properties":{"query":{"type":"string"}},"type":"object"}),
        ),
    ]);
    let second_digest = capability_digest(&[
        operation(
            "moot_alpha",
            CapabilityEffect::Read,
            json!({"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}),
        ),
        operation(
            "moot_beta",
            CapabilityEffect::Write,
            json!({"properties":{"enabled":{"type":"boolean"}},"type":"object"}),
        ),
    ]);
    assert_eq!(first_digest, second_digest);
}

#[test]
fn stable_vectors_retain_array_order_and_change_for_schema_effect_and_availability() {
    let base = operation(
        "moot_alpha",
        CapabilityEffect::Read,
        json!({"type": "object", "required": ["query", "limit"]}),
    );
    let reordered_array = operation(
        "moot_alpha",
        CapabilityEffect::Read,
        json!({"type": "object", "required": ["limit", "query"]}),
    );
    let mut write = base.clone();
    write.effect = CapabilityEffect::Write;
    let mut unavailable = base.clone();
    unavailable.availability = false;

    assert_ne!(
        canonical_json_bytes(&base.input_schema),
        canonical_json_bytes(&reordered_array.input_schema)
    );
    assert_ne!(capability_digest(&[base.clone()]), capability_digest(&[reordered_array]));
    assert_ne!(capability_digest(&[base.clone()]), capability_digest(&[write]));
    assert_ne!(capability_digest(&[base]), capability_digest(&[unavailable]));
}



/// Cross-port conformance: Rust catalog's moot_memory_search inputSchema must match
/// the frozen schema recorded in Tests/Conformance/aria_v2_mission02_vectors.json.
///
/// The fixture is the authoritative cross-port reference. If this test fails the
/// Rust catalog has drifted from the Swift port's declared schema. Fix the Rust
/// catalog — do not update the fixture without also updating the Swift catalog.
#[test]
fn memory_search_input_schema_matches_conformance_fixture() {
    let fixture_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("Tests/Conformance/aria_v2_mission02_vectors.json");
    let fixture: serde_json::Value =
        serde_json::from_slice(&std::fs::read(fixture_path).unwrap()).unwrap();

    // Extract memory_search inputSchema from the fixture.
    let fixture_schema = fixture["catalog"]["operations"]
        .as_array()
        .expect("fixture must have operations array")
        .iter()
        .find(|op| op["name"] == "moot_memory_search")
        .expect("fixture must contain moot_memory_search")["inputSchema"]
        .clone();

    // Extract memory_search inputSchema from the live Rust catalog.
    let tools = aria_mcp::v2::catalog::selected_tools();
    let catalog_schema = tools
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["name"] == "moot_memory_search")
        .expect("catalog must contain moot_memory_search")["inputSchema"]
        .clone();

    assert_eq!(
        catalog_schema, fixture_schema,
        "moot_memory_search inputSchema must match the cross-port conformance fixture"
    );
}
