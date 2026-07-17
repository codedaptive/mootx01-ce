// field_lww_engine_tests.rs
//
// Integration tests for the FederationSyncEngine fieldLevelLWW column-grain
// apply path, exercising the full enqueue → push → pull pipeline.
//
// These tests verify the _fed_sync_meta_cols side table is populated and
// consulted correctly. They complement the unit tests in
// federation.rs#[cfg(test)] (pure field_lww_merge / tombstone_wins logic).
//
// Test matrix (mirrors swift FederationFieldLWWIntegrationTests where applicable):
//   1. disjoint_columns_both_survive — two peers exchange disjoint columns;
//      after bidirectional sync both replicas have both columns.
//   2. same_column_newer_wins — same column, peer B's later write wins.
//   3. same_column_stale_inbound_loses — peer B has a newer version; peer A's
//      stale resend must not overwrite it.
//   4. tombstone_loses_when_column_newer — a delete whose HLC is older than a
//      local column edit must not remove the row (edit-beats-delete).
//   5. tombstone_wins_when_column_not_newer — a delete whose HLC is >= all
//      local column HLCs must hard-delete the row.

use std::collections::BTreeMap;
use std::sync::Arc;
use persistence_kit::{
    inmemory::InMemoryStorage, Column, ColumnDeclaration, ColumnType, SchemaDeclaration,
    Storage, StoragePredicate, TableDeclaration, TypedValue,
};
use substrate_types::hlc::HLC;
use convergence_kit::{
    ColumnHLCMap, ConflictPolicy, FederationRelay, FederationSyncEngine, LocalIdentity,
    PackedHLC, SyncDirection, SyncEngine, SyncEventKind, SyncManifest, SyncRecord,
    SyncValueMap, SyncedTable,
};
use uuid::Uuid;

// ----- helpers ---------------------------------------------------------------

fn make_storage() -> Arc<dyn Storage> {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    // Schema for the "notes" table: id (UUID PK), title (TEXT), body (TEXT).
    let schema = SchemaDeclaration::new(
        "test-kit",
        1,
        vec![TableDeclaration::new(
            "notes",
            vec![
                ColumnDeclaration::new("id",    ColumnType::Uuid),
                ColumnDeclaration::new("title", ColumnType::Text),
                ColumnDeclaration::new("body",  ColumnType::Text),
            ],
            vec!["id".to_string()],
        )],
    );
    storage.open(&schema).expect("open notes schema");
    storage
}

fn flww_manifest() -> SyncManifest {
    SyncManifest::new(
        "test-kit",
        1,
        "zone-test",
        vec![SyncedTable::new("notes", "id")
            .with_direction(SyncDirection::Bidirectional)
            .with_conflict_policy(ConflictPolicy::FieldLevelLWW)],
    )
}

/// Pair two engines sharing the same relay; each with its own storage.
fn make_pair(
    storage_a: Arc<dyn Storage>,
    storage_b: Arc<dyn Storage>,
) -> (FederationSyncEngine, FederationSyncEngine) {
    let relay = Arc::new(FederationRelay::new());
    let id_a  = Arc::new(LocalIdentity::generate());
    let id_b  = Arc::new(LocalIdentity::generate());
    let mut eng_a = FederationSyncEngine::new(id_a, relay.clone());
    let mut eng_b = FederationSyncEngine::new(id_b, relay);
    eng_a.enable(flww_manifest(), storage_a).unwrap();
    eng_b.enable(flww_manifest(), storage_b).unwrap();
    let family = convergence_kit::HyperplaneFamilySpec::new(7);
    eng_a.pair(&eng_b, family).unwrap();
    eng_b.pair(&eng_a, family).unwrap();
    (eng_a, eng_b)
}

/// Build a fieldLevelLWW SyncRecord that carries per-column HLCs.
///
/// `values` is a slice of (column_name, TypedValue) pairs.
/// `col_hlc_time` is the physical time to stamp all columns with;
/// `row_hlc_time` is the row-grain HLC physical time.
fn make_flww_record(
    row_id: Uuid,
    values: &[(&str, TypedValue)],
    col_hlc_time: i64,
    row_hlc_time: i64,
) -> SyncRecord {
    let mut btree: BTreeMap<String, TypedValue> = BTreeMap::new();
    btree.insert("id".to_string(), TypedValue::Uuid(row_id));
    let mut hlc_entries = BTreeMap::new();
    for (col, val) in values {
        btree.insert(col.to_string(), val.clone());
        hlc_entries.insert(
            col.to_string(),
            PackedHLC { physical_time: col_hlc_time, logical_count: 0, node_id: 1 },
        );
    }
    let mut record = SyncRecord::new(
        "notes",
        SyncEventKind::Update,
        row_id,
        Some(SyncValueMap::from_typed(btree)),
        HLC::new(row_hlc_time, 0, 1),
        1,
        "test-kit",
    );
    record.column_hlcs = Some(ColumnHLCMap { entries: hlc_entries });
    record
}

fn make_delete_record(row_id: Uuid, hlc_time: i64) -> SyncRecord {
    let mut record = SyncRecord::new(
        "notes",
        SyncEventKind::Delete,
        row_id,
        None,
        HLC::new(hlc_time, 0, 1),
        1,
        "test-kit",
    );
    record.sync_deleted = Some(true);
    record
}

/// Read a text column value from a row in `notes`.
fn read_col(storage: &Arc<dyn Storage>, row_id: Uuid, col: &str) -> Option<String> {
    let pred = StoragePredicate::Eq(
        Column::new("notes", "id"),
        TypedValue::Uuid(row_id),
    );
    let rows = storage.row_store().query("notes", Some(&pred), &[], None, None).ok()?;
    let row = rows.into_iter().next()?;
    match row.get(col)? {
        TypedValue::Text(s) => Some(s.clone()),
        _ => None,
    }
}

fn row_exists(storage: &Arc<dyn Storage>, row_id: Uuid) -> bool {
    let pred = StoragePredicate::Eq(
        Column::new("notes", "id"),
        TypedValue::Uuid(row_id),
    );
    storage.row_store().count("notes", Some(&pred)).unwrap_or(0) > 0
}

// ----- column-grain apply tests ----------------------------------------------

/// Disjoint columns: peer A sends "title", peer B sends "body". After a
/// bidirectional sync cycle, each replica must have both columns.
///
/// This verifies the column-grain apply path: the merge function must apply
/// a column from the incoming record even when the local row has a different
/// (non-overlapping) column written — because each column is gated independently.
#[test]
fn disjoint_columns_both_survive_after_sync() {
    let storage_a = make_storage();
    let storage_b = make_storage();
    let (mut eng_a, mut eng_b) = make_pair(storage_a.clone(), storage_b.clone());

    let row_id = Uuid::new_v4();

    // A sends a record with only "title" at T=100.
    eng_a.enqueue(make_flww_record(row_id, &[
        ("title", TypedValue::Text("Hello from A".to_string())),
    ], 100, 100)).unwrap();
    eng_a.push().unwrap();
    let r_b = eng_b.pull().unwrap();
    assert_eq!(r_b.pulled, 1, "B must receive A's title record");
    assert_eq!(
        read_col(&storage_b, row_id, "title").as_deref(),
        Some("Hello from A"),
        "B must have A's title"
    );

    // B sends a record with only "body" at T=200.
    eng_b.enqueue(make_flww_record(row_id, &[
        ("body", TypedValue::Text("Body from B".to_string())),
    ], 200, 200)).unwrap();
    eng_b.push().unwrap();
    let r_a = eng_a.pull().unwrap();
    assert_eq!(r_a.pulled, 1, "A must receive B's body record");

    // After sync, A must have B's "body" column and B must have A's "title" column.
    assert_eq!(
        read_col(&storage_a, row_id, "body").as_deref(),
        Some("Body from B"),
        "A must have B's body after sync"
    );
    assert_eq!(
        read_col(&storage_b, row_id, "title").as_deref(),
        Some("Hello from A"),
        "B must still have A's title after sync"
    );
}

/// Same column, newer incoming HLC wins: peer A writes "title" at T=100,
/// then B writes a newer "title" at T=200. A's later pull must adopt B's value.
#[test]
fn same_column_newer_inbound_wins() {
    let storage_a = make_storage();
    let storage_b = make_storage();
    let (mut eng_a, mut eng_b) = make_pair(storage_a.clone(), storage_b.clone());

    let row_id = Uuid::new_v4();

    // A sends title at T=100; B receives.
    eng_a.enqueue(make_flww_record(row_id, &[
        ("title", TypedValue::Text("Old title".to_string())),
    ], 100, 100)).unwrap();
    eng_a.push().unwrap();
    eng_b.pull().unwrap();

    // B sends a newer title at T=200; A receives.
    eng_b.enqueue(make_flww_record(row_id, &[
        ("title", TypedValue::Text("New title from B".to_string())),
    ], 200, 200)).unwrap();
    eng_b.push().unwrap();
    let r_a = eng_a.pull().unwrap();
    assert_eq!(r_a.pulled, 1, "A must accept B's newer title");

    assert_eq!(
        read_col(&storage_a, row_id, "title").as_deref(),
        Some("New title from B"),
        "A must adopt B's newer title (T=200 > T=100)"
    );
}

/// Stale inbound does not overwrite a newer local column.
///
/// B writes "title" at T=200. Then A re-sends "title" at T=100 (stale).
/// B must not overwrite its newer value.
#[test]
fn same_column_stale_inbound_does_not_overwrite_newer_local() {
    let storage_a = make_storage();
    let storage_b = make_storage();
    let (mut eng_a, mut eng_b) = make_pair(storage_a.clone(), storage_b.clone());

    let row_id = Uuid::new_v4();

    // Establish B's value at T=200 by having A send it first, B receives.
    eng_a.enqueue(make_flww_record(row_id, &[
        ("title", TypedValue::Text("Newer value".to_string())),
    ], 200, 200)).unwrap();
    eng_a.push().unwrap();
    eng_b.pull().unwrap();
    assert_eq!(
        read_col(&storage_b, row_id, "title").as_deref(),
        Some("Newer value"),
        "B must have the T=200 value"
    );

    // Now A sends a stale version of "title" at T=100.
    eng_a.enqueue(make_flww_record(row_id, &[
        ("title", TypedValue::Text("Stale value".to_string())),
    ], 100, 100)).unwrap();
    eng_a.push().unwrap();
    eng_b.pull().unwrap();

    // B must retain the T=200 value; stale T=100 must not overwrite.
    assert_eq!(
        read_col(&storage_b, row_id, "title").as_deref(),
        Some("Newer value"),
        "stale inbound (T=100) must not overwrite B's newer local value (T=200)"
    );
}

/// Tombstone loses when a local column was written after the delete.
///
/// B receives a "title" write at T=200. Then B receives a delete at T=100.
/// Because the delete HLC (T=100) is less than the local "title" column HLC
/// (T=200), the row must be preserved (edit-beats-delete).
#[test]
fn tombstone_loses_when_column_newer_than_delete() {
    let storage_a = make_storage();
    let storage_b = make_storage();
    let (mut eng_a, mut eng_b) = make_pair(storage_a.clone(), storage_b.clone());

    let row_id = Uuid::new_v4();

    // Establish B's column write at T=200.
    eng_a.enqueue(make_flww_record(row_id, &[
        ("title", TypedValue::Text("Keep me".to_string())),
    ], 200, 200)).unwrap();
    eng_a.push().unwrap();
    eng_b.pull().unwrap();
    assert!(row_exists(&storage_b, row_id), "row must exist before tombstone");

    // Send a stale delete at T=100 — older than the T=200 column write.
    // edit-beats-delete: tombstone must lose.
    eng_a.enqueue(make_delete_record(row_id, 100)).unwrap();
    eng_a.push().unwrap();
    eng_b.pull().unwrap();

    assert!(
        row_exists(&storage_b, row_id),
        "stale tombstone (T=100) must not delete a row whose column was written at T=200"
    );
}

/// Tombstone wins when the delete HLC is >= all local column HLCs.
///
/// B receives "title" at T=100. Then B receives a delete at T=200 (>= T=100).
/// Tombstone must hard-delete the row.
#[test]
fn tombstone_wins_when_delete_hlc_ge_all_columns() {
    let storage_a = make_storage();
    let storage_b = make_storage();
    let (mut eng_a, mut eng_b) = make_pair(storage_a.clone(), storage_b.clone());

    let row_id = Uuid::new_v4();

    // Establish B's column write at T=100.
    eng_a.enqueue(make_flww_record(row_id, &[
        ("title", TypedValue::Text("Delete me".to_string())),
    ], 100, 100)).unwrap();
    eng_a.push().unwrap();
    eng_b.pull().unwrap();
    assert!(row_exists(&storage_b, row_id), "row must exist before tombstone");

    // Send a newer delete at T=200 (>= T=100 column write).
    // Tombstone wins; row must be hard-deleted.
    eng_a.enqueue(make_delete_record(row_id, 200)).unwrap();
    eng_a.push().unwrap();
    eng_b.pull().unwrap();

    assert!(
        !row_exists(&storage_b, row_id),
        "tombstone (T=200) must hard-delete row whose column was last written at T=100"
    );
}
