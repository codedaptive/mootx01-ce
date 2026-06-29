//! Integration tests for the Merkle rollup (NT-Q1 Part 4).
//!
//! Covers: direct rollup cascade (bypassing capture verb), on-demand
//! leaf hash for pre-existing data without content_hash, and graceful
//! return when the rollup encounters a missing parent chain.
//!
//! Mirror: LocusKit/Tests/LocusKitTests/MerkleRollupTests.swift (Part 5 section)

use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_sqlite::SqliteDrawerStore;
use locus_kit::estate::Estate;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::frames::CaptureFrame;
use locus_kit::node_store::NodeStore;
use persistence_kit::types::TypedValue;
use std::collections::BTreeMap;
use std::sync::Arc;
use substrate_types::merkle_root::MerkleRoot;
use uuid::Uuid;

const NOW: i64 = 1_700_000_000;

// ---------------------------------------------------------------------------
// Test infrastructure
// ---------------------------------------------------------------------------

struct TempDb {
    path: String,
}

impl TempDb {
    fn new() -> Self {
        let name = format!("merkle_rollup_test_{}.db", Uuid::new_v4().simple());
        let path = std::env::temp_dir()
            .join(name)
            .to_string_lossy()
            .into_owned();
        TempDb { path }
    }

    fn path(&self) -> &str {
        &self.path
    }
}

impl Drop for TempDb {
    fn drop(&mut self) {
        for suffix in &["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{}", self.path, suffix));
        }
    }
}

fn make_estate(db: &TempDb) -> (Estate, Arc<SqliteDrawerStore>) {
    let store = Arc::new(
        SqliteDrawerStore::from_path(db.path(), NOW, None, 5.0).unwrap(),
    );
    let estate = Estate::create(
        store.clone(),
        OwnerCredentials::new("test-merkle"),
        None,
    )
    .unwrap();
    (estate, store)
}

fn node_store_from(store: &Arc<SqliteDrawerStore>) -> NodeStore {
    let storage = store.storage().expect("storage must be available");
    NodeStore::new(storage, None)
}

fn make_capture_frame(content: &str, wing: &str, room: &str) -> CaptureFrame {
    let mut frame = CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        room,
        LatticeAnchor::udc("001"),
        "test",
        "test-model",
    );
    frame.wing = Some(wing.to_string());
    frame
}

// ---------------------------------------------------------------------------
// Test 1: Direct rollup produces correct cascade
// ---------------------------------------------------------------------------

/// Insert drawers via raw storage (bypassing capture verb), then call
/// rollup_merkle_roots directly. Verifies room, wing, and estate nodes
/// all get correct merkle_root values.
#[test]
fn direct_rollup_produces_correct_cascade() {
    let db = TempDb::new();
    let (estate, store) = make_estate(&db);
    let ns = node_store_from(&store);

    // Capture a seed drawer so the containment tree exists.
    let d1 = estate
        .capture(make_capture_frame("seed drawer", "Science", "Lab"), NOW)
        .unwrap();
    let room_node_id = Uuid::parse_str(&d1.parent_node_id).unwrap();

    // Clear all merkle roots to force fresh computation.
    let room_node = ns.get_node(room_node_id).unwrap().unwrap();
    let wing_id = room_node.parent_id.unwrap();
    ns.update_merkle_root(room_node_id, &MerkleRoot::EMPTY, NOW + 1)
        .unwrap();
    ns.update_merkle_root(wing_id, &MerkleRoot::EMPTY, NOW + 1)
        .unwrap();
    let root = ns.root_node().unwrap().unwrap();
    ns.update_merkle_root(root.id, &MerkleRoot::EMPTY, NOW + 1)
        .unwrap();

    // Insert a second drawer via raw storage (bypasses capture verb).
    let raw_id = Uuid::new_v4().to_string();
    let storage = store.storage().unwrap();
    let mut vals = BTreeMap::new();
    vals.insert("id".into(), TypedValue::Text(raw_id));
    vals.insert("content".into(), TypedValue::Text("raw-inserted drawer".into()));
    vals.insert("parent_node_id".into(), TypedValue::Text(room_node_id.to_string()));
    vals.insert("addedBy".into(), TypedValue::Text("test".into()));
    vals.insert("filedAt".into(), TypedValue::Timestamp(NOW + 2));
    vals.insert("embeddingModelID".into(), TypedValue::Text("test-model".into()));
    vals.insert("provenance".into(), TypedValue::Int(0));
    vals.insert("adjectiveBitmap".into(), TypedValue::Int(0));
    vals.insert("operationalBitmap".into(), TypedValue::Int(0));
    vals.insert("lineageID".into(), TypedValue::Text(String::new()));
    vals.insert("udcCode".into(), TypedValue::Text(String::new()));
    storage.row_store().insert("drawers", vals).unwrap();

    // Call rollup directly.
    estate
        .rollup_merkle_roots(room_node_id, NOW + 3)
        .unwrap();

    // Room, wing, and estate roots must all be non-empty.
    let updated_room = ns.get_node(room_node_id).unwrap().unwrap();
    assert!(
        updated_room.merkle_root.is_some(),
        "room merkle_root must be set"
    );
    assert_ne!(
        updated_room.merkle_root.unwrap(),
        MerkleRoot::EMPTY,
        "room merkle_root must not be EMPTY"
    );

    let updated_wing = ns.get_node(wing_id).unwrap().unwrap();
    assert!(
        updated_wing.merkle_root.is_some(),
        "wing merkle_root must be set"
    );
    assert_ne!(
        updated_wing.merkle_root.unwrap(),
        MerkleRoot::EMPTY,
        "wing merkle_root must not be EMPTY"
    );

    let updated_root = ns.root_node().unwrap().unwrap();
    assert!(
        updated_root.merkle_root.is_some(),
        "estate root merkle_root must be set"
    );
    assert_ne!(
        updated_root.merkle_root.unwrap(),
        MerkleRoot::EMPTY,
        "estate root merkle_root must not be EMPTY"
    );
}

// ---------------------------------------------------------------------------
// Test 2: On-demand leaf hash for pre-existing data
// ---------------------------------------------------------------------------

/// Insert a drawer row via raw storage WITHOUT a content_hash column
/// (simulating pre-existing data). Call recompute_all_merkle_roots.
/// Verify the room root is computed from the on-demand leaf hash.
#[test]
fn on_demand_leaf_hash_for_pre_existing_data() {
    let db = TempDb::new();
    let (estate, store) = make_estate(&db);
    let ns = node_store_from(&store);

    // Capture a seed drawer so the room exists.
    let d1 = estate
        .capture(make_capture_frame("seed", "Science", "Lab"), NOW)
        .unwrap();
    let room_node_id = Uuid::parse_str(&d1.parent_node_id).unwrap();

    // Insert a drawer WITHOUT content_hash (simulates pre-existing data).
    let raw_id = Uuid::new_v4().to_string();
    let storage = store.storage().unwrap();
    let mut vals = BTreeMap::new();
    vals.insert("id".into(), TypedValue::Text(raw_id));
    vals.insert("content".into(), TypedValue::Text("pre-existing drawer content".into()));
    vals.insert("parent_node_id".into(), TypedValue::Text(room_node_id.to_string()));
    vals.insert("addedBy".into(), TypedValue::Text("legacy".into()));
    vals.insert("filedAt".into(), TypedValue::Timestamp(NOW + 10));
    vals.insert("embeddingModelID".into(), TypedValue::Text("old-model".into()));
    vals.insert("provenance".into(), TypedValue::Int(0));
    vals.insert("adjectiveBitmap".into(), TypedValue::Int(0));
    vals.insert("operationalBitmap".into(), TypedValue::Int(0));
    vals.insert("lineageID".into(), TypedValue::Text(String::new()));
    vals.insert("udcCode".into(), TypedValue::Text(String::new()));
    // content_hash intentionally omitted
    storage.row_store().insert("drawers", vals).unwrap();

    // Recompute all roots — on-demand leaf hash path must fire.
    estate.recompute_all_merkle_roots(NOW + 20).unwrap();

    let room_node = ns.get_node(room_node_id).unwrap().unwrap();
    assert!(
        room_node.merkle_root.is_some(),
        "room merkle_root must be set after recompute"
    );
    assert_ne!(
        room_node.merkle_root.unwrap(),
        MerkleRoot::EMPTY,
        "room root must not be EMPTY — on-demand leaf hash should have been computed"
    );
}

// ---------------------------------------------------------------------------
// Test 3: Rollup with missing parent returns gracefully
// ---------------------------------------------------------------------------

/// Call rollup_merkle_roots with a room node ID that does not exist
/// in the node store. Verify it returns Ok — the guard-early-return
/// catches the missing node without panicking.
#[test]
fn rollup_with_missing_room_returns_gracefully() {
    let db = TempDb::new();
    let (estate, _store) = make_estate(&db);

    // Call rollup with a UUID that doesn't exist in the node store.
    // The guard (room node not found) fires and returns early.
    let result = estate.rollup_merkle_roots(Uuid::new_v4(), NOW + 200);
    assert!(
        result.is_ok(),
        "rollup with nonexistent room must return Ok, not panic or error"
    );
}
