// federation_durable_outbox_tests.rs
//
// Five durable _fed_outbox contracts (CVK-WC2) — Rust twin of
// FederationDurableOutboxTests.swift.
//
// CONTRACT SUMMARY:
//   DUR-1: durability across engine reopen
//           Outbox entries written before disable() survive to the next enable()
//           and are delivered by the subsequent push().
//   DUR-2: push-failure-retains (throwing relay)
//           If relay.send_to returns Err, push() does NOT confirm (delete)
//           outbox entries — they remain for the next push cycle's retry.
//   DUR-3: coalescing — same (table, row_key) collapses to newest-HLC entry
//           Two writes to the same row produce one outbox entry (the newer one).
//   DUR-4: drain-on-enable — leftover entries visible after reload
//           enable() finds outbox entries that survived from the prior run and
//           logs them; entries are NOT auto-drained (host triggers push separately).
//   DUR-5: echo-still-suppressed-after-reload
//           Inbound sync records applied by B do not populate B's outbox even
//           after B is disabled and re-enabled (echo suppression via `pulling`
//           flag fires at observe time and is not re-evaluated on reload).

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{Duration, Instant};
use ed25519_dalek::PUBLIC_KEY_LENGTH;
use persistence_kit::{
    inmemory::InMemoryStorage, Column, ColumnDeclaration, ColumnType, SchemaDeclaration,
    Storage, StoragePredicate, TableDeclaration, TypedValue,
};
use convergence_kit::{
    ConflictPolicy, FederationRelay, FederationSyncEngine, LocalIdentity,
    PeerIdentity, Relay, SignedEnvelope, SyncDirection, SyncEngine, SyncManifest,
    SyncedTable,
};
use uuid::Uuid;

// ---- ThrowingRelay -----------------------------------------------------------

/// A Relay whose send_to always returns Err — models a hosted transport failure.
///
/// register() returns a disconnected receiver (the channel's sender is dropped
/// immediately). This is correct for test isolation: the engine holds the
/// receiver for pull(), but no envelopes will ever arrive since send_to always
/// fails and the sender side is gone.
struct ThrowingRelay;

impl Relay for ThrowingRelay {
    fn register(&self, _identity: PeerIdentity) -> std::sync::mpsc::Receiver<SignedEnvelope> {
        // Sender dropped immediately — receiver is permanently disconnected.
        // pull() will always see an empty inbox, which is correct for DUR-2:
        // we only verify that push() retains entries on send_to failure.
        let (_tx, rx) = std::sync::mpsc::channel();
        rx
    }

    fn broadcast(&self, _from: &PeerIdentity, _envelope: SignedEnvelope) {
        // No-op: broadcast is unused in the federation engine (send_to is used).
    }

    fn send_to(
        &self,
        _from: &PeerIdentity,
        _to_public_key: &[u8; PUBLIC_KEY_LENGTH],
        _envelope: SignedEnvelope,
    ) -> Result<(), String> {
        Err("simulated transport failure".to_string())
    }
}

// ---- Shared helpers ----------------------------------------------------------

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

/// Make an engine pair backed by `relay`. Both engines are enabled and
/// symmetrically paired before returning.
fn make_pair(
    relay: Arc<dyn Relay>,
    storage_a: Arc<dyn Storage>,
    storage_b: Arc<dyn Storage>,
) -> (FederationSyncEngine, FederationSyncEngine) {
    let id_a = Arc::new(LocalIdentity::generate());
    let id_b = Arc::new(LocalIdentity::generate());
    let mut engine_a = FederationSyncEngine::new(id_a, relay.clone());
    let mut engine_b = FederationSyncEngine::new(id_b, relay.clone());
    engine_a.enable(manifest(), storage_a).unwrap();
    engine_b.enable(manifest(), storage_b).unwrap();
    let family = convergence_kit::HyperplaneFamilySpec::new(0xABCD_1234u64);
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

fn row_note(storage: &Arc<dyn Storage>, row_id: Uuid) -> Option<String> {
    let pred = StoragePredicate::Eq(
        Column::new("items", "id"),
        TypedValue::Uuid(row_id),
    );
    let rows = storage.row_store().query("items", Some(&pred), &[], None, None).ok()?;
    match rows.into_iter().next()?.get("note")? {
        TypedValue::Text(s) => Some(s.clone()),
        _ => None,
    }
}

/// Count rows in the durable _fed_outbox table.
fn outbox_count(storage: &Arc<dyn Storage>) -> usize {
    storage.row_store().count("_fed_outbox", None).unwrap_or(0)
}

/// Poll until outbox reaches at least `min` entries, bounded by 2s.
fn wait_for_outbox(storage: &Arc<dyn Storage>, min: usize) {
    let deadline = Instant::now() + Duration::from_secs(2);
    while Instant::now() < deadline {
        if outbox_count(storage) >= min { return; }
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Push from engine until it reports a non-zero pushed count, or 2s elapses.
fn push_until_nonzero(engine: &mut FederationSyncEngine) -> usize {
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let pushed = engine.push().unwrap().pushed;
        if pushed > 0 || Instant::now() >= deadline { return pushed; }
        std::thread::sleep(Duration::from_millis(10));
    }
}

// ---- DUR-1: Durability across engine reopen ----------------------------------

/// Outbox entries written before disable() survive to the next enable() and
/// are delivered by the subsequent push().
#[test]
fn dur1_outbox_entries_survive_disable_enable_cycle() {
    let storage_a = make_storage();
    let storage_b = make_storage();
    let relay = Arc::new(FederationRelay::new()) as Arc<dyn Relay>;
    let (mut engine_a, mut engine_b) =
        make_pair(relay.clone(), storage_a.clone(), storage_b.clone());

    // Write on A without pushing — observer populates the durable outbox.
    let row_id = Uuid::new_v4();
    write_row(&storage_a, row_id, "before-reopen");
    wait_for_outbox(&storage_a, 1);
    let count_before_disable = outbox_count(&storage_a);
    assert!(count_before_disable >= 1, "outbox must have an entry after the write");

    // Disable A — the durable outbox must NOT be cleared.
    engine_a.disable().unwrap();
    let count_after_disable = outbox_count(&storage_a);
    assert_eq!(
        count_after_disable, count_before_disable,
        "disable() must NOT clear the durable _fed_outbox (DUR-1)"
    );

    // Reload: new engine instance on the same storage.
    let id_a2 = Arc::new(LocalIdentity::generate());
    let mut engine_a2 = FederationSyncEngine::new(id_a2, relay.clone());
    engine_a2.enable(manifest(), storage_a.clone()).unwrap();
    let family = convergence_kit::HyperplaneFamilySpec::new(0xABCD_5678u64);
    engine_a2.pair(&engine_b, family).unwrap();
    engine_b.pair(&engine_a2, family).unwrap();

    // Push on the reloaded engine — surviving outbox entry must be delivered.
    let pushed = push_until_nonzero(&mut engine_a2);
    assert!(pushed >= 1, "reloaded engine must deliver the surviving outbox entry (DUR-1)");

    engine_b.pull().unwrap();
    assert_eq!(
        row_note(&storage_b, row_id).as_deref(), Some("before-reopen"),
        "peer B must receive the record that survived engine reopen"
    );

    // Outbox must be empty after confirmed push.
    assert_eq!(outbox_count(&storage_a), 0, "outbox must be empty after confirmed push");

    engine_a2.disable().unwrap();
    engine_b.disable().unwrap();
}

// ---- DUR-2: Push-failure retains outbox entries -----------------------------

/// When relay.send_to returns Err, push() must NOT confirm (delete) outbox
/// entries — they remain for the next push cycle's retry.
#[test]
fn dur2_push_failure_retains_outbox_entries() {
    let storage_a = make_storage();
    let storage_b = make_storage();
    let throwing_relay = Arc::new(ThrowingRelay) as Arc<dyn Relay>;
    let (mut engine_a, mut engine_b) =
        make_pair(throwing_relay.clone(), storage_a.clone(), storage_b.clone());

    // Write on A — observer populates the durable outbox.
    let row_id = Uuid::new_v4();
    write_row(&storage_a, row_id, "retry-me");
    wait_for_outbox(&storage_a, 1);
    let count_before = outbox_count(&storage_a);
    assert!(count_before >= 1, "outbox must be populated before the failing push");

    // Push with ThrowingRelay. push() handles Err internally and returns Ok
    // (it does not propagate the relay error as a SyncError). The receipt
    // `pushed` field counts attempted records, not confirmed-delivered ones.
    engine_a.push().expect("push() must not return Err — relay failures are handled internally (DUR-2)");

    // Entries must still be in the outbox — confirm is NOT called on send_to failure.
    let count_after = outbox_count(&storage_a);
    assert_eq!(
        count_after, count_before,
        "outbox entries must survive a push-failure (retain-on-failure DUR-2)"
    );

    // Repair: disable A (outbox survives), re-enable with a working relay.
    engine_a.disable().unwrap();
    engine_b.disable().unwrap();

    let working_relay = Arc::new(FederationRelay::new()) as Arc<dyn Relay>;
    let id_a2 = Arc::new(LocalIdentity::generate());
    let id_b2 = Arc::new(LocalIdentity::generate());
    let mut engine_a2 = FederationSyncEngine::new(id_a2, working_relay.clone());
    let mut engine_b2 = FederationSyncEngine::new(id_b2, working_relay.clone());
    engine_a2.enable(manifest(), storage_a.clone()).unwrap();
    engine_b2.enable(manifest(), storage_b.clone()).unwrap();
    let family = convergence_kit::HyperplaneFamilySpec::new(0xDEAD_BEEFu64);
    engine_a2.pair(&engine_b2, family).unwrap();
    engine_b2.pair(&engine_a2, family).unwrap();

    let recovered = push_until_nonzero(&mut engine_a2);
    assert!(recovered >= 1, "retained entries must deliver on retry with working relay");
    engine_b2.pull().unwrap();
    assert_eq!(
        row_note(&storage_b, row_id).as_deref(), Some("retry-me"),
        "the retained entry must reach peer B after relay repair"
    );

    engine_a2.disable().unwrap();
    engine_b2.disable().unwrap();
}

// ---- DUR-3: Coalescing -------------------------------------------------------

/// Two writes to the same (table, row_key) must collapse to a single outbox
/// entry (the newer-HLC one). Peer B receives the latest value only.
#[test]
fn dur3_two_writes_same_row_coalesce_to_one_outbox_entry() {
    let storage_a = make_storage();
    let storage_b = make_storage();
    let relay = Arc::new(FederationRelay::new()) as Arc<dyn Relay>;
    let (mut engine_a, mut engine_b) =
        make_pair(relay, storage_a.clone(), storage_b.clone());

    let row_id = Uuid::new_v4();
    // Two writes to the same row. A 50ms sleep between them ensures the second
    // write gets a strictly higher HLC physical_time, so the coalescing
    // comparison (packed_hlc = physical_time) correctly identifies v2 as newer
    // and replaces v1's outbox entry. Without the sleep, both writes may land
    // in the same millisecond and produce identical packed_hlc values, making
    // coalescing ambiguous (the first writer's entry would be retained as
    // "newer-or-equal" under the >= guard in fed_outbox_append).
    write_row(&storage_a, row_id, "v1");
    std::thread::sleep(Duration::from_millis(50)); // ensure distinct HLC physical_time
    write_row(&storage_a, row_id, "v2");

    // Give both observer workers time to fire and coalesce.
    std::thread::sleep(Duration::from_millis(500));

    let count = outbox_count(&storage_a);
    assert_eq!(
        count, 1,
        "two writes to the same (table, row_key) must coalesce to one outbox entry (DUR-3)"
    );

    // Push and verify B receives the coalesced (newest) value.
    let pushed = engine_a.push().unwrap().pushed;
    assert!(pushed >= 1, "one coalesced entry must be pushed");
    engine_b.pull().unwrap();
    assert_eq!(
        row_note(&storage_b, row_id).as_deref(), Some("v2"),
        "coalesced entry must carry the newest value (v2) to peer B"
    );

    engine_a.disable().unwrap();
    engine_b.disable().unwrap();
}

// ---- DUR-4: Drain-on-enable --------------------------------------------------

/// Outbox entries survive disable(); enable() finds them and logs the count
/// (drain-on-enable advisory). The host is responsible for triggering push().
#[test]
fn dur4_leftover_entries_survive_disable_and_visible_after_enable() {
    let storage_a = make_storage();
    let storage_b = make_storage();
    let relay = Arc::new(FederationRelay::new()) as Arc<dyn Relay>;
    let (mut engine_a, mut engine_b) =
        make_pair(relay.clone(), storage_a.clone(), storage_b.clone());

    // Write without pushing — entries accumulate in the outbox.
    let row_id = Uuid::new_v4();
    write_row(&storage_a, row_id, "leftover");
    wait_for_outbox(&storage_a, 1);

    // Disable A — entries must remain (durable leave-in-place).
    engine_a.disable().unwrap();
    let count_after_disable = outbox_count(&storage_a);
    assert!(
        count_after_disable >= 1,
        "outbox entries must persist through disable() — drain-on-enable requires them (DUR-4)"
    );

    // Re-enable on the same storage. enable() logs the leftover count but
    // does NOT consume them (host triggers push() separately).
    let id_a2 = Arc::new(LocalIdentity::generate());
    let mut engine_a2 = FederationSyncEngine::new(id_a2, relay.clone());
    engine_a2.enable(manifest(), storage_a.clone()).unwrap();
    let count_after_enable = outbox_count(&storage_a);
    assert_eq!(
        count_after_enable, count_after_disable,
        "enable() must NOT consume outbox entries — host triggers push() separately (DUR-4)"
    );

    // Re-pair and push to drain the leftovers.
    let family = convergence_kit::HyperplaneFamilySpec::new(0xFEED_CAFEu64);
    engine_a2.pair(&engine_b, family).unwrap();
    engine_b.pair(&engine_a2, family).unwrap();
    let pushed = push_until_nonzero(&mut engine_a2);
    assert!(pushed >= 1, "push() must drain leftover entries after re-enable");
    engine_b.pull().unwrap();
    assert_eq!(
        row_note(&storage_b, row_id).as_deref(), Some("leftover"),
        "leftover entry must be delivered after drain-on-enable push cycle"
    );

    engine_a2.disable().unwrap();
    engine_b.disable().unwrap();
}

// ---- DUR-5: Echo suppressed after reload ------------------------------------

/// B's outbox stays empty when B receives inbound records (echo suppression,
/// I-10 parity via `pulling: Arc<AtomicBool>`). This invariant holds even
/// after B is disabled and re-enabled on the same storage.
#[test]
fn dur5_echo_suppressed_after_engine_reload() {
    let storage_a = make_storage();
    let storage_b = make_storage();
    let relay = Arc::new(FederationRelay::new()) as Arc<dyn Relay>;
    let (mut engine_a, mut engine_b) =
        make_pair(relay.clone(), storage_a.clone(), storage_b.clone());

    // A writes and pushes to B. The `pulling` flag on B suppresses the
    // inbound-apply write from entering B's outbox.
    let row_id = Uuid::new_v4();
    write_row(&storage_a, row_id, "echo-check");
    let pushed = push_until_nonzero(&mut engine_a);
    assert!(pushed >= 1);
    engine_b.pull().unwrap();
    std::thread::sleep(Duration::from_millis(200)); // observer settle
    assert_eq!(
        outbox_count(&storage_b), 0,
        "inbound apply must not populate B's outbox (echo suppression I-10, DUR-5)"
    );

    // Reload B: disable + re-enable on the same storage (durable outbox stays
    // empty because B never produced outbound records).
    engine_b.disable().unwrap();
    let id_b2 = Arc::new(LocalIdentity::generate());
    let mut engine_b2 = FederationSyncEngine::new(id_b2, relay.clone());
    engine_b2.enable(manifest(), storage_b.clone()).unwrap();
    assert_eq!(
        outbox_count(&storage_b), 0,
        "B's outbox must remain empty after reload — no outbound records were produced (DUR-5)"
    );

    // Re-pair and push another record from A → B. B's outbox must stay empty.
    let family = convergence_kit::HyperplaneFamilySpec::new(0xEC50_1234u64);
    engine_a.pair(&engine_b2, family).unwrap();
    engine_b2.pair(&engine_a, family).unwrap();
    write_row(&storage_a, row_id, "echo-check-v2");
    let pushed2 = push_until_nonzero(&mut engine_a);
    assert!(pushed2 >= 1);
    engine_b2.pull().unwrap();
    std::thread::sleep(Duration::from_millis(200)); // observer settle
    assert_eq!(
        outbox_count(&storage_b), 0,
        "echo suppression must hold after B engine reload — `pulling` flag fires at observe time (DUR-5)"
    );

    // A's outbox must be empty (entries pushed + confirmed).
    assert_eq!(outbox_count(&storage_a), 0, "A's outbox must be empty after confirmed pushes");

    engine_a.disable().unwrap();
    engine_b2.disable().unwrap();
}
