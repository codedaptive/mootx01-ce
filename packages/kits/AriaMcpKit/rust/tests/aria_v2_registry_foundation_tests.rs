//! Dormant parity source for the v2 registry foundation.
//!
//! The serialized integration owner exposes `aria_mcp::v2` and activates this
//! file with the `aria-v2` feature.  This unit must not add that module export.


use std::collections::BTreeSet;

use aria_mcp::jsonrpc::JsonValue;
use aria_mcp::v2::codec::{canonical_uuid, decode_uuid, strict_object};
use aria_mcp::v2::help::{resolve_help, V2HelpRequest};
use aria_mcp::v2::operation::{
    V2Availability, V2AvailabilityInputs, V2DirectoryRecord, V2HelpMetadata,
    V2OperationDescriptor, V2OperationEffect, V2ResultProjection,
};
use aria_mcp::v2::registry::{V2CatalogInput, V2EffectiveRegistry};
use aria_mcp::v2::render::{compact_text, refusal, success, V2OperationalRefusal, V2ResultMeta};
use serde_json::json;

fn descriptor() -> V2OperationDescriptor {
    V2OperationDescriptor {
        identity: "foundation.test.read".to_owned(),
        public_name: "foundation_test_read".to_owned(),
        effect: V2OperationEffect::Read,
        availability: V2Availability::default(),
        input_schema: json!({"type": "object"}),
        projection: V2ResultProjection {
            output_schema: json!({"type": "object"}),
            compact_text: true,
        },
        help: V2HelpMetadata {
            description: "Returns a synthetic foundation result.".to_owned(),
            intents: vec!["foundation".to_owned()],
            example: Some(json!({})),
        },
        recipe_bindings: Vec::new(),
    }
}

#[test]
fn availability_filters_tools_but_keeps_only_selected_help_records() {
    let mut gated = descriptor();
    gated.identity = "foundation.test.gated".to_owned();
    gated.public_name = "foundation_test_gated".to_owned();
    gated.availability.required_capabilities = BTreeSet::from(["needed".to_owned()]);
    let registry = V2EffectiveRegistry::build(
        V2CatalogInput {
            operations: vec![descriptor(), gated],
            directory_records: vec![V2DirectoryRecord {
                recipe_id: "foundation-directory".to_owned(),
                callable_tools: vec!["foundation_test_read".to_owned()],
                availability: V2Availability::default(),
                help: V2HelpMetadata {
                    description: "Synthetic non-callable directory record.".to_owned(),
                    intents: Vec::new(),
                    example: None,
                },
            }],
        },
        V2AvailabilityInputs::new("test-build"),
    )
    .unwrap();

    assert!(registry.operation("foundation_test_read").is_some());
    assert!(registry.operation("foundation_test_gated").is_none());
    let help = resolve_help(&registry, &V2HelpRequest::default()).unwrap().as_value();
    assert_eq!(help["operations"].as_array().unwrap().len(), 1);
    assert_eq!(help["directory_records"].as_array().unwrap().len(), 1);
    assert_eq!(help["directory_records"][0]["callable"], false);
}

#[test]
fn strict_decode_reports_unknown_fields_and_normalizes_uuid() {
    let arguments = JsonValue::Object(
        [("unexpected".to_owned(), JsonValue::String("x".to_owned()))]
            .into_iter()
            .collect(),
    );
    let error = strict_object(&arguments, ["expected"]).unwrap_err();
    assert_eq!(error.path, "$.unexpected");
    assert_eq!(error.data()["code"], "invalid_argument");

    let uuid = decode_uuid("A0B1C2D3-E4F5-4678-9012-3456789ABCDE", "$.memory_id").unwrap();
    assert_eq!(canonical_uuid(uuid), "a0b1c2d3-e4f5-4678-9012-3456789abcde");
}

#[test]
fn renderer_preserves_typed_envelope_and_caps_unicode_scalars() {
    let meta = V2ResultMeta::incomplete("test-build", "digest", V2OperationEffect::Read);
    let text = "😀".repeat(513);
    let result = success("foundation_test_read", &json!({"ok": true}), &meta, &text).unwrap();
    assert_eq!(result["structuredContent"]["meta"]["completeness"], "incomplete");
    assert_eq!(result["content"][0]["text"].as_str().unwrap().chars().count(), 512);
    assert_eq!(compact_text(&text).chars().count(), 512);

    let refused = refusal(
        "foundation_test_read",
        &V2OperationalRefusal {
            code: "capability_unavailable".to_owned(),
            message: "not available".to_owned(),
            retryable: false,
            recovery: None,
        },
        &meta,
    );
    assert_eq!(refused["isError"], true);
    assert_eq!(refused["structuredContent"]["error"]["code"], "capability_unavailable");
}
