// Wire-format roundtrip tests for SyncRecord, SyncValueBox,
// PackedHLC, FingerprintWire. Mirror of Swift's SyncRecord
// codable tests. Note: standalone bool, float, timestamp, and
// json variants are not directly tested here (bool appears only
// inside the array test); text, int, null, bitmap, and array
// have dedicated round-trip cases.

use std::collections::BTreeMap;
use persistence_kit::TypedValue;
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_types::fingerprint256::Fingerprint256;
use substrate_types::hlc::HLC;
use convergence_kit::{
    ColumnHLCMap, ConflictPolicy, FingerprintWire, PackedHLC, SyncEventKind, SyncRecord,
    SyncValueBox, SyncValueMap,
};
use uuid::Uuid;

#[test]
fn typed_value_null_roundtrips() {
    let v = TypedValue::Null;
    let box_v: SyncValueBox = v.clone().into();
    let back: TypedValue = box_v.into();
    assert_eq!(v, back);
}

#[test]
fn typed_value_int_roundtrips() {
    let v = TypedValue::Int(42);
    let box_v: SyncValueBox = v.clone().into();
    let back: TypedValue = box_v.into();
    assert_eq!(v, back);
}

#[test]
fn typed_value_bitmap_roundtrips() {
    let v = TypedValue::Bitmap(0xDEAD_BEEF);
    let box_v: SyncValueBox = v.clone().into();
    let back: TypedValue = box_v.into();
    assert_eq!(v, back);
}

#[test]
fn typed_value_text_roundtrips() {
    let v = TypedValue::Text("hello, sync".to_string());
    let box_v: SyncValueBox = v.clone().into();
    let back: TypedValue = box_v.into();
    assert_eq!(v, back);
}

#[test]
fn typed_value_blob_roundtrips() {
    let v = TypedValue::Blob(vec![0xCA, 0xFE, 0xBA, 0xBE]);
    let box_v: SyncValueBox = v.clone().into();
    let back: TypedValue = box_v.into();
    assert_eq!(v, back);
}

#[test]
fn typed_value_uuid_roundtrips() {
    let id = Uuid::new_v4();
    let v = TypedValue::Uuid(id);
    let box_v: SyncValueBox = v.clone().into();
    let back: TypedValue = box_v.into();
    assert_eq!(v, back);
}

#[test]
fn typed_value_hlc_roundtrips() {
    let h = HLC { physical_time: 1_234, logical_count: 5, node_id: 7 };
    let v = TypedValue::Hlc(h);
    let box_v: SyncValueBox = v.clone().into();
    let back: TypedValue = box_v.into();
    assert_eq!(v, back);
}

#[test]
fn typed_value_fingerprint_roundtrips() {
    let fp = Fingerprint256::new(0xAAAA, 0xBBBB, 0xCCCC, 0xDDDD);
    let v = TypedValue::Fingerprint(fp);
    let box_v: SyncValueBox = v.clone().into();
    let back: TypedValue = box_v.into();
    assert_eq!(v, back);
}

#[test]
fn typed_value_array_roundtrips() {
    let v = TypedValue::Array(vec![
        TypedValue::Int(1),
        TypedValue::Text("two".to_string()),
        TypedValue::Bool(true),
    ]);
    let box_v: SyncValueBox = v.clone().into();
    let back: TypedValue = box_v.into();
    assert_eq!(v, back);
}

#[test]
fn sync_value_map_roundtrips() {
    let mut m = BTreeMap::new();
    m.insert("name".to_string(), TypedValue::Text("Bob".to_string()));
    m.insert("priority".to_string(), TypedValue::Int(5));
    m.insert("flags".to_string(), TypedValue::Bitmap(0xFF));
    let wire = SyncValueMap::from_typed(m.clone());
    let back = wire.into_typed();
    assert_eq!(m, back);
}

#[test]
fn packed_hlc_roundtrips() {
    let h = HLC { physical_time: 9_999, logical_count: 3, node_id: 1 };
    let p: PackedHLC = h.into();
    assert_eq!(p.physical_time, 9_999);
    let back: HLC = p.into();
    assert_eq!(back, h);
}

#[test]
fn fingerprint_wire_roundtrips() {
    let fp = Fingerprint256::new(1, 2, 3, 4);
    let w: FingerprintWire = fp.into();
    assert_eq!(w.block0, 1);
    let back: Fingerprint256 = w.into();
    assert_eq!(back, fp);
}

#[test]
fn sync_record_serde_json_roundtrips() {
    let mut values = BTreeMap::new();
    values.insert("id".to_string(), TypedValue::Uuid(Uuid::new_v4()));
    values.insert("content".to_string(), TypedValue::Text("body".into()));
    let record = SyncRecord::new(
        "drawers",
        SyncEventKind::Insert,
        Uuid::new_v4(),
        Some(SyncValueMap::from_typed(values)),
        HLC { physical_time: 100, logical_count: 0, node_id: 1 },
        1,
        "test-kit",
    );
    let bytes = serde_json::to_vec(&record).expect("encode");
    let back: SyncRecord = serde_json::from_slice(&bytes).expect("decode");
    assert_eq!(back.table, "drawers");
    assert_eq!(back.kit_id, "test-kit");
    assert_eq!(back.schema_version, 1);
    assert_eq!(back.event, SyncEventKind::Insert);
    assert_eq!(back.hlc.physical_time, 100);
}

#[test]
fn storage_event_to_sync_event_kind_bidirectional() {
    use persistence_kit::StorageEvent;
    assert_eq!(SyncEventKind::from(StorageEvent::Insert), SyncEventKind::Insert);
    assert_eq!(SyncEventKind::from(StorageEvent::Update), SyncEventKind::Update);
    assert_eq!(SyncEventKind::from(StorageEvent::Delete), SyncEventKind::Delete);
    let back: StorageEvent = SyncEventKind::Insert.into();
    assert!(matches!(back, StorageEvent::Insert));
}

// ── ColumnHLCMap wire-format tests (B-8 / C-8 cross-port parity) ─────────

/// ColumnHLCMap round-trips through serde_json without data loss.
/// Verifies entries key is present and PackedHLC fields use camelCase.
#[test]
fn column_hlc_map_serde_json_roundtrips() {
    use substrate_types::hlc::HLC;
    let mut map = ColumnHLCMap::new();
    let h1: PackedHLC = HLC { physical_time: 1_000_000, logical_count: 5, node_id: 2 }.into();
    let h2: PackedHLC = HLC { physical_time: 2_000_000, logical_count: 0, node_id: 1 }.into();
    map.entries.insert("title".to_string(), h1);
    map.entries.insert("body".to_string(), h2);

    let bytes = serde_json::to_vec(&map).expect("encode");
    let back: ColumnHLCMap = serde_json::from_slice(&bytes).expect("decode");
    assert_eq!(back, map);
    assert_eq!(back.entries["title"].physical_time, 1_000_000);
    assert_eq!(back.entries["title"].logical_count, 5);
    assert_eq!(back.entries["title"].node_id, 2);
}

/// JSON shape has top-level "entries" key matching the Swift encoding.
#[test]
fn column_hlc_map_json_has_entries_key() {
    use substrate_types::hlc::HLC;
    let mut map = ColumnHLCMap::new();
    let h: PackedHLC = HLC { physical_time: 100, logical_count: 0, node_id: 1 }.into();
    map.entries.insert("col".to_string(), h);

    let json = serde_json::to_string(&map).expect("encode");
    assert!(
        json.starts_with("{\"entries\":"),
        "ColumnHLCMap JSON must start with {{\"entries\":, got: {}",
        json
    );
}

/// PackedHLC within entries uses camelCase field names (physicalTime, logicalCount, nodeID).
/// Matches Swift JSONEncoder output for cross-port parity (C-8).
#[test]
fn column_hlc_map_hlc_uses_camel_case_keys() {
    use substrate_types::hlc::HLC;
    let mut map = ColumnHLCMap::new();
    let h: PackedHLC = HLC { physical_time: 42, logical_count: 1, node_id: 7 }.into();
    map.entries.insert("score".to_string(), h);

    let json = serde_json::to_string(&map).expect("encode");
    // Must contain camelCase keys
    assert!(json.contains("physicalTime"), "must contain 'physicalTime', got: {}", json);
    assert!(json.contains("logicalCount"), "must contain 'logicalCount', got: {}", json);
    assert!(json.contains("nodeID"), "must contain 'nodeID', got: {}", json);
    // Must NOT contain snake_case
    assert!(!json.contains("physical_time"), "must not contain 'physical_time', got: {}", json);
    assert!(!json.contains("node_id"), "must not contain 'node_id', got: {}", json);
}

/// Decodes the golden JSON produced by Swift's JSONEncoder for ColumnHLCMap.
/// This verifies the cross-port wire contract (C-8).
#[test]
fn column_hlc_map_decodes_swift_golden_json() {
    // Exact output of Swift's JSONEncoder on ColumnHLCMap with one entry
    // "title" → PackedHLC(physicalTime: 1000000, logicalCount: 5, nodeID: 2)
    let golden = r#"{"entries":{"title":{"physicalTime":1000000,"logicalCount":5,"nodeID":2}}}"#;
    let map: ColumnHLCMap = serde_json::from_str(golden).expect("decode Swift golden JSON");
    let entry = map.entries.get("title").expect("title entry missing");
    assert_eq!(entry.physical_time, 1_000_000);
    assert_eq!(entry.logical_count, 5);
    assert_eq!(entry.node_id, 2);
}

/// ColumnHLCMap.merge picks the highest HLC per column (commutative).
#[test]
fn column_hlc_map_merge_picks_highest_per_column() {
    use substrate_types::hlc::HLC;
    let lo: PackedHLC = HLC { physical_time: 100, logical_count: 0, node_id: 1 }.into();
    let hi: PackedHLC = HLC { physical_time: 200, logical_count: 0, node_id: 1 }.into();

    let mut a = ColumnHLCMap::new();
    a.entries.insert("c1".to_string(), hi);
    a.entries.insert("c2".to_string(), lo);

    let mut b = ColumnHLCMap::new();
    b.entries.insert("c1".to_string(), lo);
    b.entries.insert("c3".to_string(), hi);

    let ab = a.merge(&b);
    let ba = b.merge(&a);

    // Commutativity: a.merge(b) == b.merge(a)
    assert_eq!(ab, ba);
    // c1: hi wins
    assert_eq!(ab.entries["c1"].physical_time, 200);
    // c2: only in a
    assert_eq!(ab.entries["c2"].physical_time, 100);
    // c3: only in b
    assert_eq!(ab.entries["c3"].physical_time, 200);
}

/// SyncRecord with columnHLCs round-trips through serde_json.
#[test]
fn sync_record_with_column_hlcs_roundtrips() {
    use substrate_types::hlc::HLC;
    let mut col_map = ColumnHLCMap::new();
    let ch: PackedHLC = HLC { physical_time: 500_000, logical_count: 1, node_id: 3 }.into();
    col_map.entries.insert("name".to_string(), ch);

    let mut record = SyncRecord::new(
        "items",
        SyncEventKind::Insert,
        Uuid::new_v4(),
        None,
        HLC { physical_time: 1_000_000, logical_count: 0, node_id: 1 },
        1,
        "TestKit",
    );
    record.column_hlcs = Some(col_map.clone());

    let bytes = serde_json::to_vec(&record).expect("encode");
    let back: SyncRecord = serde_json::from_slice(&bytes).expect("decode");
    assert_eq!(back.column_hlcs, Some(col_map));
}

/// SyncRecord without columnHLCs omits the field from JSON (backward compat).
#[test]
fn sync_record_without_column_hlcs_omits_field() {
    let record = SyncRecord::new(
        "items",
        SyncEventKind::Insert,
        Uuid::new_v4(),
        None,
        substrate_types::hlc::HLC { physical_time: 1_000, logical_count: 0, node_id: 1 },
        1,
        "TestKit",
    );
    // column_hlcs is None by default
    assert!(record.column_hlcs.is_none());

    let json = serde_json::to_string(&record).expect("encode");
    assert!(
        !json.contains("column_hlcs") && !json.contains("columnHLCs"),
        "nil columnHLCs must be omitted from JSON, got: {}",
        json
    );
}

/// ConflictPolicy::FieldLevelLWW serialises as "fieldLevelLWW" (camelCase via
/// serde rename_all = "camelCase"). Must match Swift's raw-string encoding.
#[test]
fn conflict_policy_field_level_lww_encodes_camel_case() {
    let policy = ConflictPolicy::FieldLevelLWW;
    let json = serde_json::to_string(&policy).expect("encode");
    assert_eq!(json, "\"fieldLevelLWW\"",
               "ConflictPolicy::FieldLevelLWW must encode as 'fieldLevelLWW'");
}

/// ConflictPolicy::FieldLevelLWW decodes from "fieldLevelLWW" (Swift golden).
#[test]
fn conflict_policy_field_level_lww_decodes_from_camel_case() {
    let policy: ConflictPolicy = serde_json::from_str("\"fieldLevelLWW\"").expect("decode");
    assert_eq!(policy, ConflictPolicy::FieldLevelLWW);
}
