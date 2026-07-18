// Integration tests for the _fed_pending_skew pending-queue (CVK-WC3).
//
// Five scenarios ported from the Swift PendingSkewQueue / SkewReplay
// / FederationSyncEngine test matrix:
//
//   1. hold_then_replay_after_version_bump — future-schema record held
//      during pull, then replayed automatically on re-enable when the
//      local schema version advances to match.
//
//   2. downgrade_rejected — a record from a sender at a schema version
//      BELOW the receiver's is treated as a conflict, not held.
//
//   3. cap_eviction — when >512 records are enqueued, the oldest entries
//      are evicted so the queue stays at exactly FED_SKEW_QUEUE_CAP (512).
//
//   4. event_emission — RecordsHeldForMigration fires (a) during pull()
//      when records are held, and (b) on re-enable() if held records
//      remain after replay (i.e. they are still ahead of the new version).
//
//   5. purge_interplay — when a tombstone is applied via RemoteWins, any
//      older-HLC skew-queue entries for the same (table, row_key) pair are
//      purged. This mirrors P5-M1b Swift behaviour.

use std::sync::Arc;
use std::time::Duration;
use convergence_kit::{
    ConflictPolicy, FederationRelay, FederationSyncEngine, HyperplaneFamilySpec, LocalIdentity,
    SyncDirection, SyncEngine, SyncEvent, SyncEventKind, SyncManifest, SyncRecord,
    SyncedTable,
};
use persistence_kit::{
    inmemory::InMemoryStorage, ColumnDeclaration, ColumnType, SchemaDeclaration, Storage,
    TableDeclaration,
};
use substrate_types::hlc::HLC;
use uuid::Uuid;

// ─── shared helpers ────────────────────────────────────────────────────────────

/// Create a minimal in-memory storage with a single "drawers" table.
/// Must match the table used in SyncRecord so apply_record can upsert.
fn make_storage() -> Arc<dyn Storage> {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let schema = SchemaDeclaration::new(
        "test-kit",
        1,
        vec![TableDeclaration::new(
            "drawers",
            vec![ColumnDeclaration::new("id", ColumnType::Uuid)],
            vec!["id".to_string()],
        )],
    );
    storage.open(&schema).expect("open drawers schema");
    storage
}

/// Manifest at schema_version=1 with bidirectional RemoteWins on "drawers".
/// RemoteWins is used to keep tombstone tests simple (no HLC gate).
fn manifest_v1() -> SyncManifest {
    SyncManifest::new(
        "test-kit",
        1,
        "zone-test",
        vec![SyncedTable::new("drawers", "id")
            .with_direction(SyncDirection::Bidirectional)
            .with_conflict_policy(ConflictPolicy::RemoteWins)],
    )
}

/// Manifest at schema_version=2; otherwise identical to manifest_v1.
fn manifest_v2() -> SyncManifest {
    let mut m = manifest_v1();
    m.schema_version = 2;
    m
}

/// SyncRecord with schema_version=2 (simulates a sender at a higher schema).
fn record_v2(row_key: Uuid) -> SyncRecord {
    SyncRecord::new(
        "drawers",
        SyncEventKind::Insert,
        row_key,
        None,
        HLC { physical_time: 100, logical_count: 0, node_id: 1 },
        2, // future schema
        "test-kit",
    )
}

/// SyncRecord with schema_version=1 (sender and receiver on same version).
fn record_v1_insert(row_key: Uuid, physical_time: i64) -> SyncRecord {
    SyncRecord::new(
        "drawers",
        SyncEventKind::Insert,
        row_key,
        None,
        HLC { physical_time, logical_count: 0, node_id: 1 },
        1, // matches receiver schema
        "test-kit",
    )
}

/// Tombstone (Delete) at schema_version=1 with the given HLC.
fn record_v1_delete(row_key: Uuid, physical_time: i64) -> SyncRecord {
    SyncRecord::new(
        "drawers",
        SyncEventKind::Delete,
        row_key,
        None,
        HLC { physical_time, logical_count: 0, node_id: 1 },
        1,
        "test-kit",
    )
}

/// Pair two engines symmetrically on a shared relay and return the family spec.
fn pair_engines(
    a: &mut FederationSyncEngine,
    b: &mut FederationSyncEngine,
) {
    let family = HyperplaneFamilySpec::new(42);
    a.pair(b, family.clone()).unwrap();
    b.pair(a, family).unwrap();
}

/// Drain all pending events on `rx` up to the given timeout and return them.
/// Used to collect multiple events that may arrive in close succession.
fn drain_events(
    rx: &std::sync::mpsc::Receiver<SyncEvent>,
    budget: Duration,
) -> Vec<SyncEvent> {
    let mut events = Vec::new();
    let deadline = std::time::Instant::now() + budget;
    while let Ok(e) = rx.recv_timeout(deadline.saturating_duration_since(std::time::Instant::now())) {
        events.push(e);
    }
    events
}

// ─── test 1: hold_then_replay_after_version_bump ───────────────────────────────

/// Engine A at schema_version=2 pushes a record to Engine B at schema_version=1.
/// B holds the record (does not apply it). After B is disabled and re-enabled
/// at schema_version=2, the held record is replayed and appears in "drawers".
#[test]
fn hold_then_replay_after_version_bump() {
    let relay = Arc::new(FederationRelay::new());
    let id_a = Arc::new(LocalIdentity::generate());
    let id_b = Arc::new(LocalIdentity::generate());
    let mut engine_a = FederationSyncEngine::new(id_a, relay.clone());
    let mut engine_b = FederationSyncEngine::new(id_b, relay.clone());

    let storage_b = make_storage();

    engine_a.enable(manifest_v2(), make_storage()).unwrap();
    engine_b.enable(manifest_v1(), storage_b.clone()).unwrap();
    pair_engines(&mut engine_a, &mut engine_b);

    let row_key = Uuid::new_v4();
    engine_a.enqueue(record_v2(row_key)).unwrap();
    engine_a.push().unwrap();

    // B pulls: record is future-schema, so it is held (not applied).
    let receipt = engine_b.pull().unwrap();
    assert_eq!(receipt.pulled, 0,  "future-schema record must NOT be applied");
    assert_eq!(receipt.conflicts, 0, "future-schema record must NOT count as conflict");

    // Verify the record is in the skew queue.
    let row_store = storage_b.row_store();
    let held_count = row_store
        .count("_fed_pending_skew", None)
        .expect("count _fed_pending_skew");
    assert_eq!(held_count, 1, "one record should be held in the skew queue");

    // Also verify the row has NOT been applied to "drawers" yet.
    let drawers_count = row_store.count("drawers", None).expect("count drawers");
    assert_eq!(drawers_count, 0, "drawers must be empty before schema upgrade");

    // Re-enable B at schema_version=2 — triggers drain-and-replay.
    engine_b.disable().unwrap();
    engine_b.enable(manifest_v2(), storage_b.clone()).unwrap();

    // The held record should now be applied to "drawers".
    let drawers_count_after = row_store.count("drawers", None).expect("count drawers after replay");
    assert_eq!(drawers_count_after, 1, "replayed record must appear in drawers");

    // The skew queue should be empty after successful replay.
    let skew_count_after = row_store
        .count("_fed_pending_skew", None)
        .expect("count _fed_pending_skew after replay");
    assert_eq!(skew_count_after, 0, "skew queue must be empty after successful replay");
}

// ─── test 2: downgrade_rejected ────────────────────────────────────────────────

/// A record from a sender at schema_version=1 arriving at a receiver at
/// schema_version=2 (i.e. the sender is BEHIND) must be rejected as a conflict,
/// NOT held in the skew queue.
#[test]
fn downgrade_rejected() {
    let relay = Arc::new(FederationRelay::new());
    let id_a = Arc::new(LocalIdentity::generate());
    let id_b = Arc::new(LocalIdentity::generate());
    let mut engine_a = FederationSyncEngine::new(id_a, relay.clone());
    let mut engine_b = FederationSyncEngine::new(id_b, relay.clone());

    let storage_b = make_storage();

    engine_a.enable(manifest_v1(), make_storage()).unwrap();
    engine_b.enable(manifest_v2(), storage_b.clone()).unwrap();
    pair_engines(&mut engine_a, &mut engine_b);

    let row_key = Uuid::new_v4();
    engine_a.enqueue(record_v1_insert(row_key, 50)).unwrap();
    engine_a.push().unwrap();

    let receipt = engine_b.pull().unwrap();
    // Downgrade record must be rejected as a conflict.
    assert_eq!(receipt.conflicts, 1, "downgrade record must count as conflict");
    assert_eq!(receipt.pulled, 0, "downgrade record must NOT be applied");

    // Must NOT be in the skew queue (queue is for future-schema, not old-schema).
    let row_store = storage_b.row_store();
    let held_count = row_store
        .count("_fed_pending_skew", None)
        .expect("count _fed_pending_skew");
    assert_eq!(held_count, 0, "downgrade record must NOT be placed in skew queue");
}

// ─── test 3: cap_eviction ──────────────────────────────────────────────────────

/// Enqueuing more than 512 future-schema records triggers oldest-eviction so
/// the queue is capped at exactly FED_SKEW_QUEUE_CAP (512).
///
/// Push 513 records from A (schema_version=2) to B (schema_version=1).
/// After pull completes, count the queue; it must be exactly 512.
#[test]
fn cap_eviction() {
    let relay = Arc::new(FederationRelay::new());
    let id_a = Arc::new(LocalIdentity::generate());
    let id_b = Arc::new(LocalIdentity::generate());
    let mut engine_a = FederationSyncEngine::new(id_a, relay.clone());
    let mut engine_b = FederationSyncEngine::new(id_b, relay.clone());

    let storage_b = make_storage();

    engine_a.enable(manifest_v2(), make_storage()).unwrap();
    engine_b.enable(manifest_v1(), storage_b.clone()).unwrap();
    pair_engines(&mut engine_a, &mut engine_b);

    // Enqueue 513 distinct rows (each with a unique UUID + unique HLC physical_time
    // so ordering by received_at is deterministic enough for eviction).
    for i in 0i64..513 {
        let r = SyncRecord::new(
            "drawers",
            SyncEventKind::Insert,
            Uuid::new_v4(),
            None,
            HLC { physical_time: i + 1, logical_count: 0, node_id: 1 },
            2, // future schema
            "test-kit",
        );
        engine_a.enqueue(r).unwrap();
    }
    engine_a.push().unwrap();
    engine_b.pull().unwrap();

    let row_store = storage_b.row_store();
    let held_count = row_store
        .count("_fed_pending_skew", None)
        .expect("count _fed_pending_skew");
    assert_eq!(held_count, 512, "skew queue must be capped at 512 after 513 enqueues");
}

// ─── test 4: event_emission ────────────────────────────────────────────────────

/// RecordsHeldForMigration fires synchronously inside pull() when future-schema
/// records are held, and again inside enable() when held records still remain
/// after a schema upgrade that does not fully cover them.
#[test]
fn event_emission_during_pull() {
    let relay = Arc::new(FederationRelay::new());
    let id_a = Arc::new(LocalIdentity::generate());
    let id_b = Arc::new(LocalIdentity::generate());
    let mut engine_a = FederationSyncEngine::new(id_a, relay.clone());
    let mut engine_b = FederationSyncEngine::new(id_b, relay.clone());

    engine_a.enable(manifest_v2(), make_storage()).unwrap();
    engine_b.enable(manifest_v1(), make_storage()).unwrap();
    pair_engines(&mut engine_a, &mut engine_b);

    let rx = engine_b.subscribe();

    let row_key = Uuid::new_v4();
    engine_a.enqueue(record_v2(row_key)).unwrap();
    engine_a.push().unwrap();
    engine_b.pull().unwrap();

    // Collect all events that arrive within 200ms.
    let events = drain_events(&rx, Duration::from_millis(200));

    let held_event = events.iter().find(|e| {
        matches!(e, SyncEvent::RecordsHeldForMigration { .. })
    });
    assert!(
        held_event.is_some(),
        "RecordsHeldForMigration must fire during pull when future-schema records are held; events: {:?}",
        events
    );
    if let Some(SyncEvent::RecordsHeldForMigration { count }) = held_event {
        assert_eq!(*count, 1, "held count must equal enqueued record count");
    }
}

/// RecordsHeldForMigration fires on enable() when records remain held AFTER
/// replay (because they are at a version still higher than the new manifest).
#[test]
fn event_emission_on_reenable_with_still_held() {
    let relay = Arc::new(FederationRelay::new());
    let id_a = Arc::new(LocalIdentity::generate());
    let id_b = Arc::new(LocalIdentity::generate());
    let mut engine_a = FederationSyncEngine::new(id_a, relay.clone());
    let mut engine_b = FederationSyncEngine::new(id_b, relay.clone());

    let storage_b = make_storage();

    // A is at schema_version=3 (two versions ahead).
    let mut manifest_a = manifest_v2();
    manifest_a.schema_version = 3;
    engine_a.enable(manifest_a, make_storage()).unwrap();
    engine_b.enable(manifest_v1(), storage_b.clone()).unwrap();
    pair_engines(&mut engine_a, &mut engine_b);

    // A pushes a schema_version=3 record.
    let r = SyncRecord::new(
        "drawers",
        SyncEventKind::Insert,
        Uuid::new_v4(),
        None,
        HLC { physical_time: 1, logical_count: 0, node_id: 1 },
        3,
        "test-kit",
    );
    engine_a.enqueue(r).unwrap();
    engine_a.push().unwrap();
    engine_b.pull().unwrap();

    // Disable B. Subscribe before re-enable so we catch the on-enable event.
    engine_b.disable().unwrap();
    // subscribe() can be called at any time (before or after enable);
    // it returns a fresh receiver that captures events emitted after this call.
    let rx = engine_b.subscribe();

    // Re-enable B at schema_version=2. The held record (schema_version=3) is
    // still ahead, so drain_ready finds nothing, and still_held=1 → event fires.
    engine_b.enable(manifest_v2(), storage_b.clone()).unwrap();

    let events = drain_events(&rx, Duration::from_millis(200));
    let held_event = events.iter().find(|e| {
        matches!(e, SyncEvent::RecordsHeldForMigration { .. })
    });
    assert!(
        held_event.is_some(),
        "RecordsHeldForMigration must fire on enable() when records remain held; events: {:?}",
        events
    );
}

// ─── test 5: purge_interplay ───────────────────────────────────────────────────

/// P5-M1b: when a tombstone is applied via RemoteWins, older-HLC skew-queue
/// entries for the same (table, row_key) are purged.
///
/// Scenario:
///   1. A pushes a future-schema record for row_key=uuid1 at HLC=100, schema=2.
///   2. B (schema=1) pulls → record held in queue (HLC=100, schema=2).
///   3. A pushes a same-schema DELETE tombstone for the same row_key at HLC=200.
///   4. B pulls the tombstone → applied via RemoteWins tombstone arm →
///      fed_skew_delete_older_than purges the held entry (HLC 100 < 200).
///   5. Queue is empty after step 4.
#[test]
fn purge_interplay() {
    let relay = Arc::new(FederationRelay::new());
    let id_a = Arc::new(LocalIdentity::generate());
    let id_b = Arc::new(LocalIdentity::generate());
    let mut engine_a = FederationSyncEngine::new(id_a, relay.clone());
    let mut engine_b = FederationSyncEngine::new(id_b, relay.clone());

    let storage_b = make_storage();

    // B is at schema_version=1 (RemoteWins so tombstone applies unconditionally).
    engine_a.enable(manifest_v2(), make_storage()).unwrap();
    engine_b.enable(manifest_v1(), storage_b.clone()).unwrap();
    pair_engines(&mut engine_a, &mut engine_b);

    let row_key = Uuid::new_v4();

    // Step 1-2: push future-schema record; B holds it.
    engine_a.enqueue(record_v2(row_key)).unwrap();  // HLC=100, schema=2
    engine_a.push().unwrap();
    let receipt1 = engine_b.pull().unwrap();
    assert_eq!(receipt1.pulled, 0, "future-schema record must be held, not applied");

    let row_store = storage_b.row_store();
    assert_eq!(
        row_store.count("_fed_pending_skew", None).unwrap(), 1,
        "one record should be in queue after step 2"
    );

    // Step 3-4: push a same-schema tombstone for the same row at a higher HLC.
    engine_a.enqueue(record_v1_delete(row_key, 200)).unwrap();  // HLC=200, schema=1
    engine_a.push().unwrap();
    let receipt2 = engine_b.pull().unwrap();
    assert_eq!(receipt2.pulled, 1, "tombstone must be applied (pulled==1)");

    // Step 5: queue must be empty — the held entry (HLC=100) was purged because
    // 100 < 200 (tombstone HLC).
    let skew_after = row_store
        .count("_fed_pending_skew", None)
        .expect("count after purge");
    assert_eq!(skew_after, 0, "skew queue must be empty after tombstone purge");
}
