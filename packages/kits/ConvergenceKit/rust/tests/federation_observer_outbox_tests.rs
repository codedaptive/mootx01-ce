// federation_observer_outbox_tests.rs
//
// Parity force-tests for the observer-driven outbox auto-population.
//
// These mirror FederationObserverOutboxTests.swift for cases 1 and 3;
// case 2 (explicit_enqueue_still_works) is a Rust-only regression test
// with no Swift analogue (the Swift file documents this explicitly):
//   1. write_auto_populates_outbox: an insert/update/delete to a
//      federation-enabled estate auto-populates the outbox WITHOUT any
//      explicit `enqueue` call — push then delivers the record to the peer.
//   2. explicit_enqueue_still_works: the explicit `enqueue` entry point
//      remains a working path (regression — it was the only path before
//      the observer wiring landed). Rust-only; no Swift mirror.
//   3. disable_stops_auto_population: after `disable`, a later write does
//      NOT auto-populate the outbox (lifecycle: workers stopped, no leak).
//
// The observer worker maps each storage write to a SyncRecord on a
// background thread, so the auto-population tests poll the push/pull path
// with a bounded retry rather than asserting on a single immediate tick.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{Duration, Instant};
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

fn manifest() -> SyncManifest {
    SyncManifest::new(
        "test-kit",
        1,
        "zone-test",
        vec![SyncedTable::new("items", "id")
            .with_direction(SyncDirection::Bidirectional)
            .with_conflict_policy(ConflictPolicy::LastWriterWinsByHLC)],
    )
}

fn make_pair(
    storage_a: Arc<dyn Storage>,
    storage_b: Arc<dyn Storage>,
) -> (FederationSyncEngine, FederationSyncEngine) {
    let relay = Arc::new(FederationRelay::new());
    let id_a = Arc::new(LocalIdentity::generate());
    let id_b = Arc::new(LocalIdentity::generate());
    let mut engine_a = FederationSyncEngine::new(id_a, relay.clone());
    let mut engine_b = FederationSyncEngine::new(id_b, relay.clone());
    engine_a.enable(manifest(), storage_a).unwrap();
    engine_b.enable(manifest(), storage_b).unwrap();

    // Symmetric pairing required before push delivers envelopes.
    let family = convergence_kit::HyperplaneFamilySpec::new(42);
    engine_a.pair(&engine_b, family).unwrap();
    engine_b.pair(&engine_a, family).unwrap();

    (engine_a, engine_b)
}

/// Write a row directly through the storage backend (NOT through `enqueue`).
/// This is the production capture path: the observer fires on the write.
fn write_row(storage: &Arc<dyn Storage>, row_id: Uuid, note: &str) {
    let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
    values.insert("id".to_string(), TypedValue::Uuid(row_id));
    values.insert("note".to_string(), TypedValue::Text(note.to_string()));
    storage
        .row_store()
        .upsert("items", values, &["id".to_string()])
        .expect("upsert row");
}

fn delete_row(storage: &Arc<dyn Storage>, row_id: Uuid) {
    let pred = StoragePredicate::Eq(Column::new("items", "id"), TypedValue::Uuid(row_id));
    storage.row_store().delete("items", &pred).expect("delete row");
}

fn row_note(storage: &Arc<dyn Storage>, row_id: Uuid) -> Option<String> {
    let pred = StoragePredicate::Eq(Column::new("items", "id"), TypedValue::Uuid(row_id));
    let rows = storage
        .row_store()
        .query("items", Some(&pred), &[], None, None)
        .ok()?;
    match rows.into_iter().next()?.get("note")? {
        TypedValue::Text(s) => Some(s.clone()),
        _ => None,
    }
}

fn row_exists(storage: &Arc<dyn Storage>, row_id: Uuid) -> bool {
    let pred = StoragePredicate::Eq(Column::new("items", "id"), TypedValue::Uuid(row_id));
    storage.row_store().count("items", Some(&pred)).unwrap_or(0) > 0
}

/// Push from `a` until it reports a non-zero pushed count, bounded by a short
/// deadline — the observer worker populates the outbox on a background thread,
/// so the first push can race ahead of the worker. Returns the pushed count.
fn push_until_nonzero(a: &mut FederationSyncEngine) -> usize {
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let pushed = a.push().unwrap().pushed;
        if pushed > 0 || Instant::now() >= deadline {
            return pushed;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

// ----- 1. auto-population ----------------------------------------------------

/// An insert (here via upsert of a new key) to a federation-enabled estate
/// auto-populates the outbox with no explicit enqueue; push delivers it.
#[test]
fn write_auto_populates_outbox_for_insert() {
    let storage_a = make_storage();
    let storage_b = make_storage();
    let (mut engine_a, mut engine_b) = make_pair(storage_a.clone(), storage_b.clone());

    let row_id = Uuid::new_v4();
    // No enqueue() — just a storage write. The observer must capture it.
    write_row(&storage_a, row_id, "auto-captured");

    let pushed = push_until_nonzero(&mut engine_a);
    assert!(pushed >= 1, "observer must auto-populate the outbox on a write");

    let receipt = engine_b.pull().unwrap();
    assert!(receipt.pulled >= 1, "peer must receive the auto-captured write");
    assert_eq!(row_note(&storage_b, row_id).as_deref(), Some("auto-captured"));
}

/// An update to an existing row also auto-populates the outbox.
#[test]
fn write_auto_populates_outbox_for_update() {
    let storage_a = make_storage();
    let storage_b = make_storage();
    let (mut engine_a, mut engine_b) = make_pair(storage_a.clone(), storage_b.clone());

    let row_id = Uuid::new_v4();
    write_row(&storage_a, row_id, "v1");
    assert!(push_until_nonzero(&mut engine_a) >= 1);
    engine_b.pull().unwrap();

    // A second write (update) must be captured and delivered too.
    write_row(&storage_a, row_id, "v2");
    assert!(push_until_nonzero(&mut engine_a) >= 1, "update must auto-populate");
    engine_b.pull().unwrap();
    assert_eq!(row_note(&storage_b, row_id).as_deref(), Some("v2"));
}

/// A delete to a federation-enabled estate auto-populates the outbox; the
/// peer's row is removed after the delete record syncs.
#[test]
fn write_auto_populates_outbox_for_delete() {
    let storage_a = make_storage();
    let storage_b = make_storage();
    let (mut engine_a, mut engine_b) = make_pair(storage_a.clone(), storage_b.clone());

    let row_id = Uuid::new_v4();
    write_row(&storage_a, row_id, "to-delete");
    assert!(push_until_nonzero(&mut engine_a) >= 1);
    engine_b.pull().unwrap();
    assert!(row_exists(&storage_b, row_id), "row must seed on peer first");

    // Delete on A — observer captures it, push delivers a delete record.
    delete_row(&storage_a, row_id);
    assert!(push_until_nonzero(&mut engine_a) >= 1, "delete must auto-populate");
    engine_b.pull().unwrap();
    assert!(!row_exists(&storage_b, row_id), "delete must propagate to peer");
}

// ----- 2. explicit enqueue regression ---------------------------------------

/// The explicit `enqueue` entry point still works alongside the observer path.
#[test]
fn explicit_enqueue_still_works() {
    let storage_a = make_storage();
    let storage_b = make_storage();
    let (mut engine_a, mut engine_b) = make_pair(storage_a.clone(), storage_b.clone());

    let row_id = Uuid::new_v4();
    let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
    values.insert("id".to_string(), TypedValue::Uuid(row_id));
    values.insert("note".to_string(), TypedValue::Text("explicit".to_string()));
    let record = SyncRecord::new(
        "items",
        SyncEventKind::Update,
        row_id,
        Some(SyncValueMap::from_typed(values)),
        HLC::new(1000, 0, 1),
        1,
        "test-kit",
    );
    // Explicitly enqueue WITHOUT touching storage on A.
    engine_a.enqueue(record).unwrap();
    let pushed = engine_a.push().unwrap().pushed;
    assert_eq!(pushed, 1, "explicit enqueue must still deliver exactly one record");

    engine_b.pull().unwrap();
    assert_eq!(row_note(&storage_b, row_id).as_deref(), Some("explicit"));
}

// ----- 3. lifecycle: disable stops auto-population ---------------------------

/// After `disable`, a later storage write must NOT auto-populate the outbox.
/// Re-enabling proves no worker leaked from the first session (a leaked worker
/// would double-capture on the shared storage).
#[test]
fn disable_stops_auto_population() {
    let storage_a = make_storage();
    let storage_b = make_storage();
    let (mut engine_a, mut engine_b) = make_pair(storage_a.clone(), storage_b.clone());

    // Disable A — its observer workers must stop and join (no leak).
    engine_a.disable().unwrap();

    // A write after disable must not be captured (engine is disabled, and
    // enqueue itself would error — but more importantly no background worker
    // should append to the outbox).
    let row_id = Uuid::new_v4();
    write_row(&storage_a, row_id, "after-disable");
    // Give any (incorrectly) surviving worker a chance to run.
    std::thread::sleep(Duration::from_millis(200));

    // Re-enable, re-pair, and push: the outbox must be empty (the pre-disable
    // write was cleared, and the post-disable write was not captured because
    // workers were stopped before the write). Re-pair so push actually checks
    // the outbox rather than short-circuiting on the pairing gate.
    engine_a.enable(manifest(), storage_a.clone()).unwrap();
    let family = convergence_kit::HyperplaneFamilySpec::new(42);
    engine_a.pair(&engine_b, family).unwrap();
    let pushed = engine_a.push().unwrap().pushed;
    assert_eq!(
        pushed, 0,
        "no write should remain captured across a disable boundary"
    );
    let receipt = engine_b.pull().unwrap();
    assert_eq!(receipt.pulled, 0, "peer must receive nothing after A disabled");
}
