// integrity_hook_tests.rs
//
// Parity tests for the post-apply integrity hook (R3, CVK-ICLOUD P2-M3).
// Mirrors IntegrityHookTests.swift for the four required behavioral contracts.
//
// R3-1  hook invoked once per pull batch with correct AppliedBatch contents
// R3-2  hook writes flow into the observer outbox and ship on next push
// R3-3  hook throw (Err return) counts as ONE additional conflict; pull does not abort
// R3-4  empty-batch rule: hook NOT invoked when zero records are applied

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use persistence_kit::{
    inmemory::InMemoryStorage, Column, ColumnDeclaration, ColumnType, SchemaDeclaration,
    Storage, StoragePredicate, TableDeclaration, TypedValue,
};
use convergence_kit::{
    AppliedBatch, ConflictPolicy, FederationRelay, FederationSyncEngine, HyperplaneFamilySpec,
    IntegrityHookFn, LocalIdentity, SyncDirection, SyncEngine, SyncError, SyncManifest, SyncedTable,
};
use uuid::Uuid;

// ----- helpers ---------------------------------------------------------------

fn make_storage() -> Arc<dyn Storage> {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let schema = SchemaDeclaration::new(
        "hook-test-kit",
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

fn plain_manifest() -> SyncManifest {
    SyncManifest::new(
        "hook-test-kit",
        1,
        "hook-test-zone",
        vec![SyncedTable::new("items", "id")
            .with_direction(SyncDirection::Bidirectional)
            .with_conflict_policy(ConflictPolicy::LastWriterWinsByHLC)],
    )
}

fn manifest_with_hook(hook: IntegrityHookFn) -> SyncManifest {
    plain_manifest().with_integrity_hook(hook)
}

/// Pair two engines symmetrically over a shared relay.
fn make_pair(
    storage_a: Arc<dyn Storage>,
    storage_b: Arc<dyn Storage>,
    manifest_b: SyncManifest,
) -> (FederationSyncEngine, FederationSyncEngine) {
    let relay = Arc::new(FederationRelay::new());
    let id_a = Arc::new(LocalIdentity::generate());
    let id_b = Arc::new(LocalIdentity::generate());
    let mut engine_a = FederationSyncEngine::new(id_a, relay.clone());
    let mut engine_b = FederationSyncEngine::new(id_b, relay.clone());
    engine_a.enable(plain_manifest(), storage_a).unwrap();
    engine_b.enable(manifest_b, storage_b).unwrap();

    // Symmetric pairing: both directions needed for bidirectional flow.
    let family = HyperplaneFamilySpec::new(0xBEEF);
    engine_a.pair(&engine_b, family).unwrap();
    engine_b.pair(&engine_a, family).unwrap();

    (engine_a, engine_b)
}

fn write_row(storage: &Arc<dyn Storage>, row_id: Uuid, note: &str) {
    let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
    values.insert("id".to_string(), TypedValue::Uuid(row_id));
    values.insert("note".to_string(), TypedValue::Text(note.to_string()));
    storage
        .row_store()
        .upsert("items", values, &["id".to_string()])
        .expect("upsert row");
}

fn row_count(storage: &Arc<dyn Storage>, row_id: Uuid) -> usize {
    let pred = StoragePredicate::Eq(Column::new("items", "id"), TypedValue::Uuid(row_id));
    storage.row_store().count("items", Some(&pred)).unwrap_or(0)
}

/// Retry push until nonzero pushed count or 2-second deadline.
/// Observer workers run on background threads; the first push may race ahead.
fn push_until_nonzero(engine: &mut FederationSyncEngine) -> usize {
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let pushed = engine.push().unwrap().pushed;
        if pushed > 0 || Instant::now() >= deadline {
            return pushed;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

// ----- R3-1: hook invoked once with correct AppliedBatch contents -----------

#[test]
fn r3_1_hook_invoked_once_with_correct_contents() {
    let storage_a = make_storage();
    let storage_b = make_storage();

    // Tracker: (call_count, applied_keys_for_items)
    let tracker: Arc<Mutex<(usize, Vec<Uuid>)>> = Arc::new(Mutex::new((0, vec![])));
    let tracker_clone = Arc::clone(&tracker);

    let hook: IntegrityHookFn = Arc::new(move |batch: &AppliedBatch| {
        let mut t = tracker_clone.lock().unwrap();
        t.0 += 1;
        if let Some(keys) = batch.applied_by_table.get("items") {
            t.1.extend_from_slice(keys);
        }
        Ok(())
    });

    let (mut engine_a, mut engine_b) = make_pair(
        storage_a.clone(),
        storage_b.clone(),
        manifest_with_hook(hook),
    );

    let inserted_id = Uuid::new_v4();
    write_row(&storage_a, inserted_id, "hello");

    let pushed = push_until_nonzero(&mut engine_a);
    assert!(pushed >= 1, "A must push at least one record");

    let receipt = engine_b.pull().unwrap();
    assert!(receipt.pulled >= 1, "B must have applied the record");

    let t = tracker.lock().unwrap();
    assert_eq!(t.0, 1, "hook must be invoked exactly once per pull batch");
    assert!(
        t.1.contains(&inserted_id),
        "applied_by_table[items] must contain the inserted row key"
    );
}

// ----- R3-2: hook writes flow into outbox and ship on next push -------------

#[test]
fn r3_2_hook_writes_ship_on_next_push() {
    let storage_a = make_storage();
    let storage_b = make_storage();

    let repair_id = Uuid::new_v4();

    let hook: IntegrityHookFn = Arc::new(move |batch: &AppliedBatch| {
        // Write a repair row using the hook's storage handle.
        // This write runs after pulling.store(false), so it is NOT suppressed
        // by the echo-suppression guard — it flows into the outbox normally.
        let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
        values.insert("id".to_string(), TypedValue::Uuid(repair_id));
        values.insert("note".to_string(), TypedValue::Text("repaired".to_string()));
        batch
            .storage
            .row_store()
            .upsert("items", values, &["id".to_string()])
            .map_err(|e| SyncError::TransportFailure { detail: e.to_string() })?;
        Ok(())
    });

    let (mut engine_a, mut engine_b) = make_pair(
        storage_a.clone(),
        storage_b.clone(),
        manifest_with_hook(hook),
    );

    // A inserts → B pulls → hook fires → hook writes repairID to storageB.
    let seed_id = Uuid::new_v4();
    write_row(&storage_a, seed_id, "seed");

    let pushed = push_until_nonzero(&mut engine_a);
    assert!(pushed >= 1);

    let _receipt = engine_b.pull().unwrap();

    // Verify repairID is in storageB before any push.
    assert_eq!(row_count(&storage_b, repair_id), 1, "hook must have written repair row");

    // Give the observer worker thread time to enqueue the hook write.
    // The write happens synchronously during pull, but the observer reads
    // the channel on a 100 ms tick — allow up to 200 ms for pick-up.
    std::thread::sleep(Duration::from_millis(200));

    // Push B → A: the repair row must propagate (hook-writes-must-ship).
    let repair_pushed = push_until_nonzero(&mut engine_b);
    assert!(repair_pushed >= 1, "repair row must flow into B's outbox and ship to A");

    let _receipt_a = engine_a.pull().unwrap();
    assert_eq!(
        row_count(&storage_a, repair_id),
        1,
        "repair row must arrive at A via the push/pull cycle"
    );
}

// ----- R3-3: hook Err counts as one conflict; pull does not abort -----------

#[test]
fn r3_3_hook_err_counts_as_one_conflict_and_does_not_abort() {
    let storage_a = make_storage();
    let storage_b = make_storage();

    // Hook always fails.
    let hook: IntegrityHookFn = Arc::new(|_batch: &AppliedBatch| {
        Err(SyncError::TransportFailure { detail: "integrity check failed".to_string() })
    });

    let (mut engine_a, mut engine_b) = make_pair(
        storage_a.clone(),
        storage_b.clone(),
        manifest_with_hook(hook),
    );

    let row_id = Uuid::new_v4();
    write_row(&storage_a, row_id, "trigger");

    let pushed = push_until_nonzero(&mut engine_a);
    assert!(pushed >= 1);

    let receipt = engine_b.pull().unwrap();

    // Record was applied (pulled >= 1), hook added one conflict.
    assert!(receipt.pulled >= 1, "record must be applied before the hook runs");
    assert_eq!(receipt.conflicts, 1, "hook Err must count as exactly one conflict");

    // Row must be in storageB despite the hook failure.
    assert_eq!(row_count(&storage_b, row_id), 1, "record must persist even when hook fails");
}

// ----- R3-4: empty-batch rule — hook NOT invoked when zero records applied --

#[test]
fn r3_4_hook_not_invoked_for_empty_batch() {
    let storage_b = make_storage();

    let call_count: Arc<Mutex<usize>> = Arc::new(Mutex::new(0));
    let call_count_clone = Arc::clone(&call_count);

    let hook: IntegrityHookFn = Arc::new(move |_batch: &AppliedBatch| {
        *call_count_clone.lock().unwrap() += 1;
        Ok(())
    });

    // Enable B alone (no peer). Pull with nothing in the relay.
    let relay = Arc::new(FederationRelay::new());
    let id_b = Arc::new(LocalIdentity::generate());
    let mut engine_b = FederationSyncEngine::new(id_b, relay);
    engine_b.enable(manifest_with_hook(hook), storage_b).unwrap();

    let receipt = engine_b.pull().unwrap();
    assert_eq!(receipt.pulled, 0, "no records were available to pull");

    let count = *call_count.lock().unwrap();
    assert_eq!(count, 0, "hook must NOT be invoked when zero records were applied");
}
