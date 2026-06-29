// Integration tests for federation inbound event dispatch.
// Covers insert replication and delete behavior across several policies;
// does not exercise update behavior or insert behavior through every
// conflict policy. Mirrors FederationInboundEventTests.swift.

use std::collections::BTreeMap;
use std::sync::Arc;
use persistence_kit::{
    inmemory::InMemoryStorage, Column, ColumnDeclaration, ColumnType, SchemaDeclaration,
    Storage, StoragePredicate, TableDeclaration, TypedValue,
};
use substrate_types::hlc::HLC;
use convergence_kit::{
    ConflictPolicy, FederationRelay, FederationSyncEngine, LocalIdentity,
    SyncDirection, SyncEngine, SyncEventKind, SyncManifest, SyncRecord, SyncValueMap,
    SyncedTable,
};
use uuid::Uuid;

fn make_storage() -> Arc<dyn Storage> {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    // Open a minimal schema so apply_record can upsert/delete in "items".
    // InMemory requires tables to be declared before row operations.
    let schema = SchemaDeclaration::new(
        "test-kit",
        1,
        vec![TableDeclaration::new(
            "items",
            vec![
                ColumnDeclaration::new("id", ColumnType::Uuid),
                ColumnDeclaration::new("note", ColumnType::Text),
            ],
            vec!["id".to_string()],
        )],
    );
    storage.open(&schema).expect("open items schema");
    storage
}

fn make_manifest_with_policy(policy: ConflictPolicy) -> SyncManifest {
    SyncManifest::new(
        "test-kit",
        1,
        "zone-test",
        vec![SyncedTable::new("items", "id")
            .with_direction(SyncDirection::Bidirectional)
            .with_conflict_policy(policy)],
    )
}

fn make_record(row_id: Uuid, event: SyncEventKind, note: Option<&str>) -> SyncRecord {
    let values = note.map(|n| {
        let mut m = BTreeMap::new();
        m.insert("id".to_string(), TypedValue::Uuid(row_id));
        m.insert("note".to_string(), TypedValue::Text(n.to_string()));
        SyncValueMap::from_typed(m)
    });
    SyncRecord::new(
        "items",
        event,
        row_id,
        values,
        HLC { physical_time: 1, logical_count: 0, node_id: 1 },
        1,
        "test-kit",
    )
}

fn row_exists(storage: &Arc<dyn Storage>, row_id: Uuid) -> bool {
    let predicate = StoragePredicate::Eq(
        Column::new("items", "id"),
        TypedValue::Uuid(row_id),
    );
    storage
        .row_store()
        .count("items", Some(&predicate))
        .unwrap_or(0)
        > 0
}

fn setup_pair(
    policy: ConflictPolicy,
) -> (FederationSyncEngine, FederationSyncEngine, Arc<dyn Storage>, Arc<dyn Storage>) {
    let relay = Arc::new(FederationRelay::new());
    let id_a = Arc::new(LocalIdentity::generate());
    let id_b = Arc::new(LocalIdentity::generate());

    let storage_a = make_storage();
    let storage_b = make_storage();

    let mut engine_a = FederationSyncEngine::new(id_a, relay.clone());
    let mut engine_b = FederationSyncEngine::new(id_b, relay.clone());

    engine_a.enable(make_manifest_with_policy(policy), storage_a.clone()).unwrap();
    engine_b.enable(make_manifest_with_policy(policy), storage_b.clone()).unwrap();

    // Symmetric pairing required before push delivers envelopes.
    let family = convergence_kit::HyperplaneFamilySpec::new(42);
    engine_a.pair(&engine_b, family).unwrap();
    engine_b.pair(&engine_a, family).unwrap();

    (engine_a, engine_b, storage_a, storage_b)
}

/// Enqueue an insert for row_id on engine_a, push, and have engine_b pull.
fn seed_row(engine_a: &mut FederationSyncEngine, engine_b: &mut FederationSyncEngine, row_id: Uuid) {
    let record = make_record(row_id, SyncEventKind::Insert, Some("seeded"));
    engine_a.enqueue(record).unwrap();
    let push = engine_a.push().unwrap();
    assert!(push.pushed > 0, "seed push should have at least one record");
    let pull = engine_b.pull().unwrap();
    assert!(pull.pulled > 0, "seed pull should have at least one record");
}

// ── existing path ─────────────────────────────────────────────────────────────

#[test]
fn remote_insert_still_replicates() {
    let (mut engine_a, mut engine_b, _storage_a, storage_b) =
        setup_pair(ConflictPolicy::LastWriterWinsByHLC);

    let row_id = Uuid::new_v4();
    seed_row(&mut engine_a, &mut engine_b, row_id);
    assert!(row_exists(&storage_b, row_id), "inserted row should replicate to B");
}

// ── delete paths ──────────────────────────────────────────────────────────────

#[test]
fn remote_delete_applied_under_remote_wins() {
    let (mut engine_a, mut engine_b, _storage_a, storage_b) =
        setup_pair(ConflictPolicy::RemoteWins);

    let row_id = Uuid::new_v4();
    seed_row(&mut engine_a, &mut engine_b, row_id);
    assert!(row_exists(&storage_b, row_id), "row should exist before delete");

    engine_a.enqueue(make_record(row_id, SyncEventKind::Delete, None)).unwrap();
    let push = engine_a.push().unwrap();
    assert!(push.pushed > 0, "delete should be pushed");
    engine_b.pull().unwrap();

    assert!(!row_exists(&storage_b, row_id), "row should be deleted on B under remoteWins");
}

#[test]
fn remote_delete_applied_under_lww() {
    let (mut engine_a, mut engine_b, _storage_a, storage_b) =
        setup_pair(ConflictPolicy::LastWriterWinsByHLC);

    let row_id = Uuid::new_v4();
    seed_row(&mut engine_a, &mut engine_b, row_id);

    engine_a.enqueue(make_record(row_id, SyncEventKind::Delete, None)).unwrap();
    engine_a.push().unwrap();
    engine_b.pull().unwrap();

    assert!(!row_exists(&storage_b, row_id), "row should be deleted on B under lastWriterWinsByHLC");
}

#[test]
fn remote_delete_rejected_under_append_only() {
    let (mut engine_a, mut engine_b, _storage_a, storage_b) =
        setup_pair(ConflictPolicy::AppendOnly);

    let row_id = Uuid::new_v4();
    seed_row(&mut engine_a, &mut engine_b, row_id);
    assert!(row_exists(&storage_b, row_id), "row should exist before delete attempt");

    // appendOnly: B silently ignores the remote delete.
    engine_a.enqueue(make_record(row_id, SyncEventKind::Delete, None)).unwrap();
    engine_a.push().unwrap();
    engine_b.pull().unwrap();

    assert!(row_exists(&storage_b, row_id), "row should be preserved on B under appendOnly");
}

#[test]
fn remote_delete_rejected_under_local_wins_row_exists() {
    let (mut engine_a, mut engine_b, _storage_a, storage_b) =
        setup_pair(ConflictPolicy::LocalWins);

    let row_id = Uuid::new_v4();
    // localWins: B accepts the insert because it doesn't have the row yet.
    seed_row(&mut engine_a, &mut engine_b, row_id);
    assert!(row_exists(&storage_b, row_id), "row should exist on B after seed");

    // localWins: B rejects the remote delete; local state is authoritative.
    engine_a.enqueue(make_record(row_id, SyncEventKind::Delete, None)).unwrap();
    engine_a.push().unwrap();
    engine_b.pull().unwrap();

    assert!(row_exists(&storage_b, row_id), "row should be preserved on B under localWins");
}
