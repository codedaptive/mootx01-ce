//! Chunked Or-of-Eq batch lookup tests (large-wing estates).
//!
//! The SQLite predicate compiler renders an N-arm `StoragePredicate::Or`
//! as a flat `(a OR b OR ...)` SQL string, which SQLite parses as a
//! left-deep expression tree. At ~1000 terms SQLite aborts with
//! "Expression tree is too large (maximum depth 1000)". LocusKit
//! therefore chunks every unbounded id-batch lookup at 900 ids per
//! query, mirroring the Swift twin's `chunkSize = 900` ceiling
//! (`DrawerStore.swift`, `getDrawers(ids:)`).
//!
//! These tests run against `SqliteDrawerStore` deliberately: the depth
//! cap is a SQLite parser limit, so the `InMemoryDrawerStore` backend
//! (structural predicate evaluation) can never reproduce the defect.

use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_sqlite::SqliteDrawerStore;
use locus_kit::node_store::NodeStore;
use uuid::Uuid;

const NOW: i64 = 1_700_000_000;

/// RAII guard that deletes the SQLite database file (and its WAL/SHM
/// siblings) when dropped. Same shape as `drawer_store_sqlite.rs`.
struct TempDb {
    path: String,
}

impl TempDb {
    fn new() -> Self {
        let name = format!("locus_chunk_test_{}.db", Uuid::new_v4().simple());
        let path = std::env::temp_dir().join(name).to_string_lossy().into_owned();
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

fn open_sqlite(path: &str) -> SqliteDrawerStore {
    SqliteDrawerStore::from_path(path, NOW, None, 5.0).unwrap()
}

/// resolve_node_names must survive >1000 unique parent (room) ids AND
/// >1000 distinct parent wings — both inner id-batch queries cross the
/// SQLite expression-depth cap without chunking. 1100 wings each with
/// one room also crosses the 900-id chunk boundary, so the merge across
/// chunks is exercised, not just the single-chunk path.
#[test]
fn resolve_node_names_succeeds_for_over_1000_unique_parent_ids() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let storage = store.storage().expect("storage must be available");
    let ns = NodeStore::new(storage, None);
    let root = ns.create_root("Estate", NOW).unwrap();

    let mut room_ids: Vec<String> = Vec::with_capacity(1100);
    for i in 0..1100 {
        let wing = ns.create_node(&format!("Wing {i:04}"), root.id, NOW).unwrap();
        let room = ns.create_node(&format!("Room {i:04}"), wing.id, NOW).unwrap();
        room_ids.push(room.id.to_string());
    }

    let map = store
        .resolve_node_names(&room_ids)
        .expect("resolve_node_names must not exceed SQLite expression depth");
    assert_eq!(map.len(), 1100, "every room id resolves");

    // Spot-check both ends and the 900-id chunk boundary neighbours.
    for i in [0usize, 899, 900, 1099] {
        let (wing_name, room_name) =
            map.get(&room_ids[i]).unwrap_or_else(|| panic!("room {i} missing"));
        assert_eq!(wing_name, &format!("Wing {i:04}"));
        assert_eq!(room_name, &format!("Room {i:04}"));
    }
}
