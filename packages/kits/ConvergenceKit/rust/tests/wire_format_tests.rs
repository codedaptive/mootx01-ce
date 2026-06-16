// Wire-format roundtrip tests for SyncRecord, SyncValueBox,
// PackedHLC, FingerprintWire. Mirror of Swift's SyncRecord
// codable tests; every TypedValue variant must round-trip
// through SyncValueBox without loss so the wire format is
// stable across the federation.

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
    FingerprintWire, PackedHLC, SyncEventKind, SyncRecord, SyncValueBox, SyncValueMap,
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
