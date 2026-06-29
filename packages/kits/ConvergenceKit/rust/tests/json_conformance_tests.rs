//! Golden JSON vector tests verifying the cross-port wire contract.
//! These tests use a mix of handwritten golden strings, decoded-field
//! assertions, and substring checks; they do not compare every Rust
//! JSON string byte-for-byte against Swift JSONEncoder output.

use std::collections::BTreeMap;
use convergence_kit::{
    FingerprintWire, PackedHLC, SyncEventKind, SyncRecord, SyncValueBox, SyncValueMap,
};
use convergence_kit::types::{SyncManifest, SyncedTable, SyncDirection, ConflictPolicy};
use convergence_kit::pairing::{PairingProposal, PairingAcceptance, HyperplaneFamilySpec};
use persistence_kit::TypedValue;
use substrate_types::hlc::HLC;
use uuid::Uuid;

// ── PackedHLC ──────────────────────────────────────────────────

#[test]
fn packed_hlc_encodes_camel_case() {
    let hlc = PackedHLC {
        physical_time: 1000,
        logical_count: 5,
        node_id: 3,
    };
    let json = serde_json::to_string(&hlc).unwrap();
    assert!(json.contains("\"physicalTime\""), "expected physicalTime, got: {json}");
    assert!(json.contains("\"logicalCount\""), "expected logicalCount, got: {json}");
    assert!(json.contains("\"nodeID\""), "expected nodeID, got: {json}");
    assert!(!json.contains("physical_time"));
    assert!(!json.contains("node_id"));
}

#[test]
fn packed_hlc_decodes_swift_golden() {
    let golden = r#"{"physicalTime":1000,"logicalCount":5,"nodeID":3}"#;
    let hlc: PackedHLC = serde_json::from_str(golden).unwrap();
    assert_eq!(hlc.physical_time, 1000);
    assert_eq!(hlc.logical_count, 5);
    assert_eq!(hlc.node_id, 3);
}

// ── SyncRecord ─────────────────────────────────────────────────

#[test]
fn sync_record_encodes_camel_case() {
    let uuid = Uuid::parse_str("e621e1f8-c36c-495a-93fc-0c247a3e6e5f").unwrap();
    let record = SyncRecord::new(
        "drawers",
        SyncEventKind::Insert,
        uuid,
        None,
        HLC { physical_time: 100, logical_count: 0, node_id: 1 },
        1,
        "TestKit",
    );
    let json = serde_json::to_string(&record).unwrap();
    assert!(json.contains("\"rowKey\""), "expected rowKey, got: {json}");
    assert!(json.contains("\"schemaVersion\""), "expected schemaVersion, got: {json}");
    assert!(json.contains("\"kitID\""), "expected kitID, got: {json}");
    assert!(!json.contains("\"row_key\""));
    assert!(!json.contains("\"schema_version\""));
    assert!(!json.contains("\"kit_id\""));
}

#[test]
fn sync_record_decodes_swift_golden() {
    let golden = r#"{"table":"drawers","event":"insert","rowKey":"e621e1f8-c36c-495a-93fc-0c247a3e6e5f","values":null,"hlc":{"physicalTime":100,"logicalCount":0,"nodeID":1},"schemaVersion":1,"kitID":"TestKit"}"#;
    let record: SyncRecord = serde_json::from_str(golden).unwrap();
    assert_eq!(record.table, "drawers");
    assert_eq!(record.event, SyncEventKind::Insert);
    assert_eq!(record.schema_version, 1);
    assert_eq!(record.kit_id, "TestKit");
    assert_eq!(record.hlc.physical_time, 100);
    assert_eq!(record.hlc.node_id, 1);
}

// ── SyncManifest ───────────────────────────────────────────────

#[test]
fn sync_manifest_encodes_camel_case() {
    let manifest = SyncManifest::new("TestKit", 1, "zone-1", vec![
        SyncedTable::new("drawers", "row_id"),
    ]);
    let json = serde_json::to_string(&manifest).unwrap();
    assert!(json.contains("\"kitID\""), "expected kitID, got: {json}");
    assert!(json.contains("\"schemaVersion\""), "expected schemaVersion, got: {json}");
    assert!(json.contains("\"zoneIdentifier\""), "expected zoneIdentifier, got: {json}");
    assert!(json.contains("\"primaryKeyColumn\""), "expected primaryKeyColumn, got: {json}");
    assert!(json.contains("\"conflictPolicy\""), "expected conflictPolicy, got: {json}");
    assert!(!json.contains("\"kit_id\""));
    assert!(!json.contains("\"zone_identifier\""));
    assert!(!json.contains("\"primary_key_column\""));
}

#[test]
fn sync_manifest_decodes_swift_golden() {
    let golden = r#"{"kitID":"TestKit","schemaVersion":1,"zoneIdentifier":"zone-1","tables":[{"name":"drawers","direction":"bidirectional","primaryKeyColumn":"row_id","conflictPolicy":"lastWriterWinsByHLC"}]}"#;
    let manifest: SyncManifest = serde_json::from_str(golden).unwrap();
    assert_eq!(manifest.kit_id, "TestKit");
    assert_eq!(manifest.schema_version, 1);
    assert_eq!(manifest.zone_identifier, "zone-1");
    assert_eq!(manifest.tables[0].name, "drawers");
    assert_eq!(manifest.tables[0].primary_key_column, "row_id");
    assert_eq!(manifest.tables[0].conflict_policy, ConflictPolicy::LastWriterWinsByHLC);
}

// ── SyncValueBox ───────────────────────────────────────────────

#[test]
fn sync_value_box_text_encodes_adjacently_tagged() {
    let v = SyncValueBox::Text("hello".to_string());
    let json = serde_json::to_string(&v).unwrap();
    assert_eq!(json, r#"{"kind":"text","payload":"hello"}"#);
}

#[test]
fn sync_value_box_null_encodes_without_payload() {
    let v = SyncValueBox::Null;
    let json = serde_json::to_string(&v).unwrap();
    assert_eq!(json, r#"{"kind":"null"}"#);
}

#[test]
fn sync_value_box_int_encodes_adjacently_tagged() {
    let v = SyncValueBox::Int(42);
    let json = serde_json::to_string(&v).unwrap();
    assert_eq!(json, r#"{"kind":"int","payload":42}"#);
}

#[test]
fn sync_value_box_timestamp_encodes_as_epoch_seconds() {
    let v = SyncValueBox::Timestamp(1_700_000_000);
    let json = serde_json::to_string(&v).unwrap();
    assert_eq!(json, r#"{"kind":"timestamp","payload":1700000000}"#);
}

#[test]
fn sync_value_box_blob_encodes_as_byte_array() {
    let v = SyncValueBox::Blob(vec![0xCA, 0xFE]);
    let json = serde_json::to_string(&v).unwrap();
    assert_eq!(json, r#"{"kind":"blob","payload":[202,254]}"#);
}

#[test]
fn sync_value_box_hlc_encodes_nested_packed_hlc() {
    let v = SyncValueBox::Hlc(PackedHLC {
        physical_time: 500,
        logical_count: 1,
        node_id: 2,
    });
    let json = serde_json::to_string(&v).unwrap();
    assert!(json.contains("\"kind\":\"hlc\""));
    assert!(json.contains("\"physicalTime\":500"));
    assert!(json.contains("\"nodeID\":2"));
}

#[test]
fn sync_value_box_decodes_swift_golden_array() {
    let golden = r#"[{"kind":"text","payload":"hello"},{"kind":"int","payload":42},{"kind":"null"},{"kind":"bool","payload":true},{"kind":"bitmap","payload":255},{"kind":"float","payload":3.14},{"kind":"timestamp","payload":1700000000}]"#;
    let boxes: Vec<SyncValueBox> = serde_json::from_str(golden).unwrap();
    assert_eq!(boxes.len(), 7);
    assert!(matches!(&boxes[0], SyncValueBox::Text(s) if s == "hello"));
    assert!(matches!(&boxes[1], SyncValueBox::Int(42)));
    assert!(matches!(&boxes[2], SyncValueBox::Null));
    assert!(matches!(&boxes[3], SyncValueBox::Bool(true)));
    assert!(matches!(&boxes[4], SyncValueBox::Bitmap(255)));
    assert!(matches!(&boxes[6], SyncValueBox::Timestamp(1_700_000_000)));
}

// ── SyncRecord with values ─────────────────────────────────────

#[test]
fn sync_record_with_values_decodes_swift_golden() {
    let golden = r#"{"table":"drawers","event":"insert","rowKey":"e621e1f8-c36c-495a-93fc-0c247a3e6e5f","values":{"entries":{"name":{"kind":"text","payload":"test"},"flags":{"kind":"bitmap","payload":7}}},"hlc":{"physicalTime":100,"logicalCount":0,"nodeID":1},"schemaVersion":1,"kitID":"TestKit"}"#;
    let record: SyncRecord = serde_json::from_str(golden).unwrap();
    assert_eq!(record.table, "drawers");
    let values = record.values.unwrap().into_typed();
    assert_eq!(values["name"], TypedValue::Text("test".to_string()));
    assert_eq!(values["flags"], TypedValue::Bitmap(7));
}

// ── PairingProposal / PairingAcceptance ────────────────────────

#[test]
fn pairing_proposal_encodes_camel_case() {
    let proposal = PairingProposal {
        proposer_public_key: vec![1, 2, 3],
        proposed_family: HyperplaneFamilySpec::new(42),
        nonce: vec![10, 20],
    };
    let json = serde_json::to_string(&proposal).unwrap();
    assert!(json.contains("\"proposerPublicKey\""), "got: {json}");
    assert!(json.contains("\"proposedFamily\""), "got: {json}");
    assert!(!json.contains("\"proposer_public_key\""));
    assert!(!json.contains("\"proposed_family\""));
}

#[test]
fn pairing_acceptance_encodes_camel_case() {
    let acceptance = PairingAcceptance {
        accepter_public_key: vec![4, 5, 6],
        accepted_family: HyperplaneFamilySpec::new(42),
        signature_of_proposal: vec![7, 8, 9],
    };
    let json = serde_json::to_string(&acceptance).unwrap();
    assert!(json.contains("\"accepterPublicKey\""), "got: {json}");
    assert!(json.contains("\"acceptedFamily\""), "got: {json}");
    assert!(json.contains("\"signatureOfProposal\""), "got: {json}");
    assert!(!json.contains("\"accepter_public_key\""));
}
