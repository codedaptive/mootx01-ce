// federation_lww_tests.rs
//
// Force-tests for FederationSyncEngine last-writer-wins-by-HLC semantics.
//
// These tests cover four cases per port:
//   1. stale_inbound_loses: an older inbound write must not overwrite a newer
//      local row (the core LWW contract).
//   2. newer_inbound_wins: a newer inbound write must overwrite an older
//      local row.
//   3. stale_delete_loses: a delete whose HLC is older than the local row's
//      _syncHLC must not remove the local row.
//   4. newer_delete_wins: a delete whose HLC is >= the local row's _syncHLC
//      must hard-delete the local row.
//
// apply_record is reached indirectly via the public enqueue/push/pull path;
// record HLCs are explicitly set in the enqueued SyncRecord, giving full
// HLC control without relying on wall-clock timing.
//
// This mirrors FederationLWWTests.swift — all four force-test cases and their
// assertions must match across both ports.

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

// ----- helpers ---------------------------------------------------------------

fn make_storage() -> Arc<dyn Storage> {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    // id, note — no _syncHLC column declared; InMemory accepts extra columns on upsert.
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

fn lww_manifest() -> SyncManifest {
    SyncManifest::new(
        "test-kit",
        1,
        "zone-test",
        vec![SyncedTable::new("items", "id")
            .with_direction(SyncDirection::Bidirectional)
            .with_conflict_policy(ConflictPolicy::LastWriterWinsByHLC)],
    )
}

/// Build a paired two-engine setup sharing a relay and the given storage pair.
fn make_pair(
    storage_a: Arc<dyn Storage>,
    storage_b: Arc<dyn Storage>,
) -> (FederationSyncEngine, FederationSyncEngine) {
    let relay = Arc::new(FederationRelay::new());
    let id_a = Arc::new(LocalIdentity::generate());
    let id_b = Arc::new(LocalIdentity::generate());
    let mut engine_a = FederationSyncEngine::new(id_a, relay.clone());
    let mut engine_b = FederationSyncEngine::new(id_b, relay.clone());
    engine_a.enable(lww_manifest(), storage_a).unwrap();
    engine_b.enable(lww_manifest(), storage_b).unwrap();

    // Symmetric pairing required before push delivers envelopes.
    let family = convergence_kit::HyperplaneFamilySpec::new(42);
    engine_a.pair(&engine_b, family).unwrap();
    engine_b.pair(&engine_a, family).unwrap();

    (engine_a, engine_b)
}

/// Build an upsert SyncRecord for `items` with an explicit HLC physical time.
fn make_upsert_record(row_id: Uuid, note: &str, hlc_time: i64) -> SyncRecord {
    let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
    values.insert("id".to_string(), TypedValue::Uuid(row_id));
    values.insert("note".to_string(), TypedValue::Text(note.to_string()));
    SyncRecord::new(
        "items",
        SyncEventKind::Update,
        row_id,
        Some(SyncValueMap::from_typed(values)),
        HLC::new(hlc_time, 0, 1),
        1,
        "test-kit",
    )
}

/// Build a delete SyncRecord for `items` with an explicit HLC physical time.
fn make_delete_record(row_id: Uuid, hlc_time: i64) -> SyncRecord {
    SyncRecord::new(
        "items",
        SyncEventKind::Delete,
        row_id,
        None,
        HLC::new(hlc_time, 0, 1),
        1,
        "test-kit",
    )
}

fn row_note(storage: &Arc<dyn Storage>, row_id: Uuid) -> Option<String> {
    let pred = StoragePredicate::Eq(
        Column::new("items", "id"),
        TypedValue::Uuid(row_id),
    );
    let rows = storage
        .row_store()
        .query("items", Some(&pred), &[], None, None)
        .ok()?;
    let first = rows.into_iter().next()?;
    match first.get("note")? {
        TypedValue::Text(s) => Some(s.clone()),
        _ => None,
    }
}

fn row_exists(storage: &Arc<dyn Storage>, row_id: Uuid) -> bool {
    let pred = StoragePredicate::Eq(
        Column::new("items", "id"),
        TypedValue::Uuid(row_id),
    );
    storage
        .row_store()
        .count("items", Some(&pred))
        .unwrap_or(0)
        > 0
}

// ----- upsert path -----------------------------------------------------------

/// A stale inbound write (older HLC) must not overwrite a newer local row.
/// Force-test sequence: push T=1000 to B, then push T=500 to B; B's row
/// must still carry the T=1000 note.
#[test]
fn stale_inbound_does_not_overwrite_newer_local_row() {
    let storage_a = make_storage();
    let storage_b = make_storage();
    let (mut engine_a, mut engine_b) = make_pair(storage_a, storage_b.clone());

    let row_id = Uuid::new_v4();

    // Deliver T=1000 write to B — sets _syncHLC=1000 on the row.
    engine_a.enqueue(make_upsert_record(row_id, "first-at-T1000", 1000)).unwrap();
    engine_a.push().unwrap();
    let r = engine_b.pull().unwrap();
    assert_eq!(r.pulled, 1, "first write must be applied");
    assert_eq!(row_note(&storage_b, row_id).as_deref(), Some("first-at-T1000"));

    // Deliver T=500 write to B — stale; must be rejected.
    engine_a.enqueue(make_upsert_record(row_id, "stale-at-T500", 500)).unwrap();
    engine_a.push().unwrap();
    engine_b.pull().unwrap();

    assert_eq!(
        row_note(&storage_b, row_id).as_deref(),
        Some("first-at-T1000"),
        "stale inbound must not overwrite the newer local row"
    );
}

/// A newer inbound write (larger HLC) must overwrite an older local row.
#[test]
fn newer_inbound_wins_over_older_local_row() {
    let storage_a = make_storage();
    let storage_b = make_storage();
    let (mut engine_a, mut engine_b) = make_pair(storage_a, storage_b.clone());

    let row_id = Uuid::new_v4();

    // Deliver T=500 first.
    engine_a.enqueue(make_upsert_record(row_id, "old-at-T500", 500)).unwrap();
    engine_a.push().unwrap();
    let r = engine_b.pull().unwrap();
    assert_eq!(r.pulled, 1);

    // Deliver T=1000 — newer; must win.
    engine_a.enqueue(make_upsert_record(row_id, "newer-at-T1000", 1000)).unwrap();
    engine_a.push().unwrap();
    let r2 = engine_b.pull().unwrap();
    assert_eq!(r2.pulled, 1, "newer write must be accepted");

    assert_eq!(
        row_note(&storage_b, row_id).as_deref(),
        Some("newer-at-T1000"),
        "newer inbound write must win LWW"
    );
}

// ----- delete path -----------------------------------------------------------

/// A stale delete (older HLC than local _syncHLC) must not remove the row.
#[test]
fn stale_delete_does_not_remove_newer_local_row() {
    let storage_a = make_storage();
    let storage_b = make_storage();
    let (mut engine_a, mut engine_b) = make_pair(storage_a, storage_b.clone());

    let row_id = Uuid::new_v4();

    // Seed row at T=1000 on B — establishes _syncHLC=1000.
    engine_a.enqueue(make_upsert_record(row_id, "keep-me", 1000)).unwrap();
    engine_a.push().unwrap();
    let r = engine_b.pull().unwrap();
    assert_eq!(r.pulled, 1);
    assert!(row_exists(&storage_b, row_id));

    // Stale delete at T=500 — must be rejected because local _syncHLC=1000 is newer.
    engine_a.enqueue(make_delete_record(row_id, 500)).unwrap();
    engine_a.push().unwrap();
    engine_b.pull().unwrap();

    assert!(
        row_exists(&storage_b, row_id),
        "stale delete must not remove a row whose _syncHLC is newer"
    );
}

/// A newer delete (HLC >= local _syncHLC) must hard-delete the row.
#[test]
fn newer_delete_removes_local_row() {
    let storage_a = make_storage();
    let storage_b = make_storage();
    let (mut engine_a, mut engine_b) = make_pair(storage_a, storage_b.clone());

    let row_id = Uuid::new_v4();

    // Seed row at T=500 on B — establishes _syncHLC=500.
    engine_a.enqueue(make_upsert_record(row_id, "delete-me", 500)).unwrap();
    engine_a.push().unwrap();
    let r = engine_b.pull().unwrap();
    assert_eq!(r.pulled, 1);
    assert!(row_exists(&storage_b, row_id));

    // Newer delete at T=1000 — >= local _syncHLC=500; must hard-delete the row.
    engine_a.enqueue(make_delete_record(row_id, 1000)).unwrap();
    engine_a.push().unwrap();
    engine_b.pull().unwrap();

    assert!(
        !row_exists(&storage_b, row_id),
        "newer delete must hard-delete the local row"
    );
}
