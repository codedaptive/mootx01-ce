// changed_columns_tests.rs
//
// Rust twin of PersistenceKitInMemoryTests/InMemoryChangedColumnsTests.swift.
// Verifies that InMemoryStorage stamps changed_columns on TableChange
// notifications with column-level precision (CVK-WB4).
//
// Contracts:
//  - insert: changed_columns == Some(Set(stored.keys))
//  - update (diff): changed_columns == Some(columns whose value changed)
//  - upsert-as-insert: changed_columns == Some(Set(written keys))
//  - upsert-as-update (diff): changed_columns == Some(changed columns only)
//  - delete: changed_columns == None

use persistence_kit::{
    inmemory::InMemoryStorage, Column, ColumnDeclaration, SchemaDeclaration, Storage,
    StorageEvent, StoragePredicate, TableDeclaration, TypedValue,
};
use std::collections::{BTreeMap, BTreeSet, HashSet};
use uuid::Uuid;

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

/// Schema: {row_id UUID PK, title TEXT, flags BITMAP}.
/// No optional columns — avoids NOT NULL constraint noise in upsert tests.
fn make_storage() -> InMemoryStorage {
    let storage = InMemoryStorage::with_estate(Uuid::new_v4());
    let schema = SchemaDeclaration::new(
        "changed-cols-kit",
        1,
        vec![TableDeclaration::new(
            "items",
            vec![
                ColumnDeclaration::uuid("row_id"),
                ColumnDeclaration::text("title"),
                ColumnDeclaration::bitmap("flags"),
            ],
            vec!["row_id".to_string()],
        )],
    );
    storage.open(&schema).expect("schema open");
    storage
}

fn row(id: Uuid, title: &str, flags: i64) -> BTreeMap<String, TypedValue> {
    let mut m = BTreeMap::new();
    m.insert("row_id".to_string(), TypedValue::Uuid(id));
    m.insert("title".to_string(), TypedValue::Text(title.to_string()));
    m.insert("flags".to_string(), TypedValue::Bitmap(flags));
    m
}

fn recv_change(
    rx: &std::sync::mpsc::Receiver<persistence_kit::observer::TableChange>,
) -> persistence_kit::observer::TableChange {
    rx.recv_timeout(std::time::Duration::from_millis(500))
        .expect("observer must receive a change within 500ms")
}

// ─── Insert: all stored columns stamped ────────────────────────────────────

#[test]
fn insert_stamps_all_columns() {
    let storage = make_storage();
    let observer = storage.observer();
    let mut events = BTreeSet::new();
    events.insert(StorageEvent::Insert);
    let rx = observer.observe("items", events).unwrap();

    let id = Uuid::new_v4();
    storage
        .row_store()
        .insert("items", row(id, "Hello", 0))
        .unwrap();

    let change = recv_change(&rx);
    assert_eq!(change.event, StorageEvent::Insert);
    let cols = change
        .changed_columns
        .expect("insert must carry changed_columns");
    // All three written columns must be stamped.
    assert!(cols.contains("row_id"), "row_id must be in changed_columns");
    assert!(cols.contains("title"), "title must be in changed_columns");
    assert!(cols.contains("flags"), "flags must be in changed_columns");
    assert_eq!(cols.len(), 3, "exactly 3 columns written");
}

// ─── Update: only actually-changed columns stamped ─────────────────────────

#[test]
fn update_stamps_only_changed_columns() {
    let storage = make_storage();
    let id = Uuid::new_v4();
    storage
        .row_store()
        .insert("items", row(id, "Original", 0))
        .unwrap();

    let observer = storage.observer();
    let mut events = BTreeSet::new();
    events.insert(StorageEvent::Update);
    let rx = observer.observe("items", events).unwrap();

    // Update title (changes) and flags (same value — no change).
    let mut update_vals = BTreeMap::new();
    update_vals.insert("title".to_string(), TypedValue::Text("Updated".to_string()));
    update_vals.insert("flags".to_string(), TypedValue::Bitmap(0)); // same value

    storage
        .row_store()
        .update(
            "items",
            update_vals,
            &StoragePredicate::Eq(
                Column::new("items", "row_id"),
                TypedValue::Uuid(id),
            ),
        )
        .unwrap();

    let change = recv_change(&rx);
    let cols = change
        .changed_columns
        .expect("update must carry changed_columns");
    assert!(cols.contains("title"), "title changed — must be in changed_columns");
    assert!(
        !cols.contains("flags"),
        "flags had same value — must NOT be in changed_columns"
    );
    assert!(
        !cols.contains("row_id"),
        "row_id not in SET clause — must NOT be in changed_columns"
    );
}

// ─── Upsert-as-insert: all written columns stamped ─────────────────────────

#[test]
fn upsert_insert_path_stamps_all_columns() {
    let storage = make_storage();
    let observer = storage.observer();
    let mut events = BTreeSet::new();
    events.insert(StorageEvent::Insert);
    events.insert(StorageEvent::Update);
    let rx = observer.observe("items", events).unwrap();

    // No pre-existing row — upsert fires the insert path.
    let id = Uuid::new_v4();
    storage
        .row_store()
        .upsert("items", row(id, "New", 1), &["row_id".to_string()])
        .unwrap();

    let change = recv_change(&rx);
    let cols = change
        .changed_columns
        .expect("upsert-insert must carry changed_columns");
    let expected: HashSet<String> = ["row_id", "title", "flags"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    assert_eq!(cols, expected, "upsert insert path: all written columns stamped");
}

// ─── Upsert-as-update: only changed columns stamped ────────────────────────

#[test]
fn upsert_update_path_stamps_only_changed_columns() {
    let storage = make_storage();
    let id = Uuid::new_v4();
    // Pre-insert so the upsert finds an existing row (update path).
    storage
        .row_store()
        .insert("items", row(id, "Existing", 0))
        .unwrap();

    let observer = storage.observer();
    let mut events = BTreeSet::new();
    events.insert(StorageEvent::Insert);
    events.insert(StorageEvent::Update);
    let rx = observer.observe("items", events).unwrap();

    // Upsert: title changes; flags stays at 0.
    storage
        .row_store()
        .upsert("items", row(id, "Modified", 0), &["row_id".to_string()])
        .unwrap();

    let change = recv_change(&rx);
    let cols = change
        .changed_columns
        .expect("upsert-update must carry changed_columns");
    assert!(cols.contains("title"), "title changed — must be stamped");
    assert!(
        !cols.contains("flags"),
        "flags unchanged — must NOT be stamped"
    );
}

// ─── Delete: changed_columns is None ───────────────────────────────────────

#[test]
fn delete_emits_nil_changed_columns() {
    let storage = make_storage();
    let id = Uuid::new_v4();
    storage
        .row_store()
        .insert("items", row(id, "To delete", 0))
        .unwrap();

    let observer = storage.observer();
    let mut events = BTreeSet::new();
    events.insert(StorageEvent::Delete);
    let rx = observer.observe("items", events).unwrap();

    storage
        .row_store()
        .delete(
            "items",
            &StoragePredicate::Eq(
                Column::new("items", "row_id"),
                TypedValue::Uuid(id),
            ),
        )
        .unwrap();

    let change = recv_change(&rx);
    assert_eq!(change.event, StorageEvent::Delete);
    assert!(
        change.changed_columns.is_none(),
        "delete tombstones carry no column granularity — changed_columns must be None"
    );
}
