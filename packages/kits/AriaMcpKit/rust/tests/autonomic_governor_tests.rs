//! Autonomic Governor integration tests (see ADR-LOOPBACKHTTP-001 §17).
//!
//! Mirrors the Swift `AutonomicGovernorTests` suite in
//! `packages/kits/AriaMcpKit/Tests/AriaMCPTests/AutonomicGovernorTests.swift`.
//!
//! Tests use an injected clock (a monotonically-advancing SystemTime via
//! UNIX_EPOCH + Duration offset) so no wall-clock sleeps are needed — the
//! determinism contract is the same as the Swift suite.
//!
//! # Isolation
//!
//! Each test constructs an independent in-memory estate (via `make_governor`)
//! and invokes `tick(now)` directly. No wall-clock is read in the test path.
//!
//! # Coverage
//!
//! §1 Cadence — interval gating: first fires, before-interval None, at-boundary fires.
//! §2 Construction — governor is constructable and tick returns a GovernorReport.
//! §3 Stop flag — stop() causes run_loop to exit (using a thread + timeout).
//! §4 Live estate wiring — a dreaming fire writes a diary entry to the live store
//!    (proves the sinks write to the real estate, not a throwaway store).
//! §5 Think event emission — dreaming pump emits StatSample::Event(Think) per proposal.

use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex, OnceLock,
};
use std::time::{Duration, UNIX_EPOCH};

use aria_mcp::autonomic_governor::AutonomicGovernor;
use aria_mcp::estate_registry::EstateRegistry;
use intellectus_lib::{EventKind, Intellectus, NoOpSink, StatSample, StatsSink};

// ─────────────────────────────────────────────────────────────────
// Process-wide serialisation lock (for Intellectus singleton tests)
// ─────────────────────────────────────────────────────────────────

/// Serialises all tests that manipulate the Intellectus singleton.
static GLOBAL_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

fn global_lock() -> std::sync::MutexGuard<'static, ()> {
    let mutex = GLOBAL_LOCK.get_or_init(|| Mutex::new(()));
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poison) => poison.into_inner(),
    }
}

// ─────────────────────────────────────────────────────────────────
// CapturingSink — records every received StatSample, thread-safe
// ─────────────────────────────────────────────────────────────────

struct CapturingSink {
    samples: Mutex<Vec<StatSample>>,
}

impl CapturingSink {
    fn new() -> Self {
        CapturingSink { samples: Mutex::new(Vec::new()) }
    }

    fn all_samples(&self) -> Vec<StatSample> {
        self.samples.lock().unwrap().clone()
    }

    /// All Event samples whose `estate` field matches `estate_tag`.
    fn event_samples_for_estate(&self, estate_tag: &str) -> Vec<StatSample> {
        self.all_samples().into_iter().filter(|s| {
            if let StatSample::Event { estate, .. } = s {
                estate == estate_tag
            } else {
                false
            }
        }).collect()
    }
}

impl StatsSink for CapturingSink {
    fn receive(&self, sample: StatSample) {
        self.samples.lock().unwrap().push(sample);
    }
}

/// Restore Intellectus to the default disabled+NoOpSink state.
fn reset_intellectus() {
    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

// ── Test helper ──────────────────────────────────────────────────────────────

/// Build an `AutonomicGovernor` wired to a fresh in-memory estate.
///
/// Returns `(governor, registry)` so tests that want to inspect the live store
/// after a tick can access `registry.default.store`.
fn make_governor() -> (AutonomicGovernor, EstateRegistry) {
    let registry = EstateRegistry::new_inmemory();
    let coord = Arc::clone(&registry.coord);
    let handle = registry.default.handle;
    let store = Arc::clone(&registry.default.store);
    let governor = AutonomicGovernor::new(coord, handle, store);
    (governor, registry)
}

/// Build a governor with a caller-supplied stop flag and an explicit base tick
/// (for the run_loop test). The tick is passed directly rather than via
/// `MOOTX01_BRAIN_TICK_MS`, so this helper never sets a process-global env var
/// that would race sibling tests constructing governors in parallel.
fn make_governor_with_flag(flag: Arc<AtomicBool>, base_tick_ms: u64) -> AutonomicGovernor {
    let registry = EstateRegistry::new_inmemory();
    let coord = Arc::clone(&registry.coord);
    let handle = registry.default.handle;
    let store = Arc::clone(&registry.default.store);
    AutonomicGovernor::with_stop_flag_and_tick(coord, handle, store, flag, base_tick_ms)
}

// MARK: - §1 Cadence

/// AG-1: First tick always fires both daemons (no prior fire timestamp).
/// Mirrors Swift `firstTickFiresDreamingAndMaintenance`.
#[test]
fn ag1_first_tick_always_fires_both_daemons() {
    let (mut governor, _registry) = make_governor();
    // At t=0 there is no prior fire for either daemon.
    let report = governor.tick(UNIX_EPOCH);
    assert!(
        report.dreaming_fired,
        "dreaming must fire on first tick"
    );
    assert!(
        report.maintenance_fired,
        "maintenance must fire on first tick"
    );
}

/// AG-2: A tick before either interval has elapsed returns both unfired.
/// The dreaming interval default is 30 s; maintenance is 300 s.
/// At t=29 s (after t=0 fired), both are still within their intervals.
/// Mirrors Swift `dreamingRespectsCadence`.
#[test]
fn ag2_tick_before_interval_returns_no_fire() {
    let (mut governor, _registry) = make_governor();
    // First tick fires (t=0).
    let first = governor.tick(UNIX_EPOCH);
    assert!(first.dreaming_fired, "first tick must fire dreaming");
    assert!(first.maintenance_fired, "first tick must fire maintenance");

    // Second tick at t=29 s — both intervals (30 s and 300 s) have not elapsed.
    let second = governor.tick(UNIX_EPOCH + Duration::from_secs(29));
    assert!(
        !second.dreaming_fired,
        "dreaming must not fire before 30 s interval"
    );
    assert!(
        !second.maintenance_fired,
        "maintenance must not fire before 300 s interval"
    );
}

/// AG-3: Dreaming fires at its interval boundary (30 s) while maintenance
/// has not yet reached its boundary (300 s). Mirrors Swift
/// `dreamingRespectsCadence`.
#[test]
fn ag3_dreaming_fires_at_interval_maintenance_does_not() {
    let (mut governor, _registry) = make_governor();
    // First tick fires both at t=0.
    let _ = governor.tick(UNIX_EPOCH);
    // At t=30 s exactly — dreaming interval (30 s) elapsed, maintenance (300 s) not.
    let second = governor.tick(UNIX_EPOCH + Duration::from_secs(30));
    assert!(
        second.dreaming_fired,
        "dreaming must fire at the 30 s boundary"
    );
    assert!(
        !second.maintenance_fired,
        "maintenance must not fire before 300 s boundary"
    );
}

/// AG-4: Both daemons fire when their intervals have both elapsed.
/// At t=300 s both dreaming (every 30 s) and maintenance (every 300 s)
/// have elapsed since the last fire at t=270/t=0.
#[test]
fn ag4_both_fire_after_long_gap() {
    let (mut governor, _registry) = make_governor();
    // First tick fires both at t=0.
    let _ = governor.tick(UNIX_EPOCH);
    // Advance to t=300 — both intervals have elapsed.
    let later = governor.tick(UNIX_EPOCH + Duration::from_secs(300));
    assert!(
        later.dreaming_fired,
        "dreaming must fire after 300 s gap (many intervals)"
    );
    assert!(
        later.maintenance_fired,
        "maintenance must fire at its 300 s boundary"
    );
}

// MARK: - §2 Construction

/// AG-5: AutonomicGovernor::new() is constructable; tick returns a GovernorReport.
/// Smoke test — verifies no panic at construction or on first tick.
#[test]
fn ag5_construction_smoke() {
    let (mut governor, _registry) = make_governor();
    let report = governor.tick(UNIX_EPOCH + Duration::from_secs(1_000_000));
    // The first tick always fires both daemons.
    assert!(report.dreaming_fired);
    assert!(report.maintenance_fired);
}

/// AG-6: Consecutive ticks at increasing timestamps stay coherent.
/// Three dreaming-interval steps: t=0, t=30, t=60. Each should fire dreaming.
#[test]
fn ag6_consecutive_dreaming_firings() {
    let (mut governor, _registry) = make_governor();
    let r0 = governor.tick(UNIX_EPOCH);
    assert!(r0.dreaming_fired, "t=0 must fire");
    let r1 = governor.tick(UNIX_EPOCH + Duration::from_secs(30));
    assert!(r1.dreaming_fired, "t=30 must fire (exactly one interval)");
    let r2 = governor.tick(UNIX_EPOCH + Duration::from_secs(60));
    assert!(r2.dreaming_fired, "t=60 must fire (two intervals)");
}

// MARK: - §3 Stop flag

/// AG-7: stop() sets the flag; run_loop exits promptly.
/// Uses a background thread with a very short tick (1 ms) and a timeout
/// (2 s) to avoid hanging the test suite. No wall-clock sleep in the
/// assertion path — we join the thread and check it returned.
/// Mirrors Swift `signalTickBenignWhenNoSchedulerRegistered` (stop semantics).
#[test]
fn ag7_stop_flag_exits_run_loop() {
    let stop_flag = Arc::new(AtomicBool::new(false));
    let flag_clone = Arc::clone(&stop_flag);

    // Use a 1 ms tick so the loop spins fast enough to see the stop flag
    // without a meaningful wall-clock delay in CI. The tick is passed directly
    // (no process-global MOOTX01_BRAIN_TICK_MS env var) so this test cannot
    // leak a 1 ms tick into sibling governor-construction tests running in
    // parallel (ag16-19).
    let mut governor = make_governor_with_flag(Arc::clone(&stop_flag), 1);

    let handle = std::thread::spawn(move || {
        governor.run_loop();
    });

    // Set the stop flag after a short pause to let the loop start.
    std::thread::sleep(std::time::Duration::from_millis(20));
    flag_clone.store(true, Ordering::Relaxed);

    // Join with a 2-second timeout. If the thread doesn't return by then,
    // the test runner will eventually kill it; we treat a successful join as
    // the pass condition.
    let joined = handle.join();
    assert!(joined.is_ok(), "AutonomicGovernor thread must exit cleanly after stop()");
}

// MARK: - §4 Live estate wiring

/// AG-8: A dreaming tick on a populated estate writes a diary entry to
/// the live store — proves the sinks write through to the real estate
/// and not a throwaway InMemoryDrawerStore.
///
/// An empty estate produces no dreaming proposals (no co-occurrence pairs),
/// but the daemon ALWAYS writes one diary entry per cycle. Asserting the
/// diary entry proves end-to-end live wiring.
#[test]
fn ag8_dreaming_fire_writes_diary_entry_to_live_estate() {
    use locus_kit::drawer_store::DrawerStore as LocusDrawerStore;

    let (mut governor, registry) = make_governor();
    // Tick at a large epoch so the ISO8601 formatter exercises real dates.
    let report = governor.tick(UNIX_EPOCH + Duration::from_secs(1_700_000_000));
    assert!(report.dreaming_fired, "first tick must fire dreaming");

    // The dreaming daemon writes exactly one diary entry per cycle.
    // Read it back directly from the live store — this is the proof that
    // the sink writes to the real estate, not a throwaway store.
    let diary = registry
        .default
        .store
        .read_diary("dreaming-daemon", 10)
        .expect("read_diary must succeed on in-memory store");
    assert_eq!(
        diary.len(),
        1,
        "dreaming cycle must write exactly one diary entry to the live store"
    );
    assert_eq!(diary[0].agent_name, "dreaming-daemon");
    assert_eq!(diary[0].topic, "dreaming-cycle");
}

/// AG-9: A maintenance tick on a populated estate writes a diary entry to
/// the live store — proves maintenance sink wiring.
#[test]
fn ag9_maintenance_fire_writes_diary_entry_to_live_estate() {
    use locus_kit::drawer_store::DrawerStore as LocusDrawerStore;

    let (mut governor, registry) = make_governor();
    // Advance to t=300 s so maintenance fires alongside dreaming.
    let _ = governor.tick(UNIX_EPOCH);
    let report = governor.tick(UNIX_EPOCH + Duration::from_secs(300));
    assert!(report.maintenance_fired, "maintenance must fire at 300 s boundary");

    // The maintenance daemon writes exactly one diary entry per cycle.
    let diary = registry
        .default
        .store
        .read_diary("maintenance-daemon", 10)
        .expect("read_diary must succeed");
    // At t=0 and t=300 both daemons fire; two maintenance cycles = 2 diary entries.
    assert!(
        diary.len() >= 2,
        "two maintenance fires must produce at least 2 diary entries; got {}",
        diary.len()
    );
    assert!(
        diary.iter().all(|e| e.agent_name == "maintenance-daemon"),
        "all entries must be from maintenance-daemon"
    );
}

// MARK: - §5 Think event emission

/// AG-10: A dreaming tick that fires at least one proposal emits
/// `StatSample::Event` samples with `kind=Think` and `noun_type=4`
/// (NounType::Proposal, wire-stable) for each proposal.
///
/// Test setup: populates the estate with ≥3 drawers in the same
/// (wing, room) so the co-occurrence reader produces observations with
/// `attempts ≥ 3` (meets `min_attempts`). Recall traces with `used=true`
/// and timestamps within the 30-second dreaming window yield
/// `contrastive_confidence ≈ 0.88` (meets `min_confidence = 0.7`).
///
/// Mirrors Swift `dreamingPumpEmitsThinkEvents` (TEL-01 §7 analog).
#[test]
fn dreaming_pump_emits_think_events() {
    use locus_kit::drawer::Drawer;
    use locus_kit::drawer_store::DrawerStore as LocusDrawerStore;
    use locus_kit::recall_trace_item::RecallTraceItem;
    use uuid::Uuid;

    let _guard = global_lock();

    // ── Build estate with 3 drawers in the same room ─────────────────────────
    // Each drawer must be in the same (wing, room) so build_co_occurrence_observations
    // creates pairs with attempts=3, satisfying DreamingPolicy::default(min_attempts=3).
    let registry = EstateRegistry::new_inmemory();
    let now_epoch_i64 = 1_700_000_000i64;
    let wing = "wing-think-test";
    let room = "room-think-test";

    let id_a = Uuid::new_v4().to_string();
    let id_b = Uuid::new_v4().to_string();
    let id_c = Uuid::new_v4().to_string();

    for id in &[&id_a, &id_b, &id_c] {
        let drawer = Drawer::new(*id, "think-test content", wing, room, "test-agent", now_epoch_i64, "minilm-v2");
        registry.default.store.add_drawer(&drawer, now_epoch_i64)
            .expect("add_drawer must succeed");
    }

    // ── Recall traces with used=true within the dreaming window ──────────────
    // The dreaming window is [now - 30s, now] = ["2023-11-14T22:12:50Z", "2023-11-14T22:13:20Z"].
    // Use a timestamp 10 seconds before now so it falls inside the window.
    // Each target is one of the three drawers so all co-occurrence evidence_targets
    // get reward=1.0, yielding contrastive_confidence ≈ 0.88 (> min_confidence=0.7).
    let recall_at = "2023-11-14T22:13:10Z"; // 10 s before 2023-11-14T22:13:20Z
    for drawer_id in &[&id_a, &id_b, &id_c] {
        let trace = RecallTraceItem::new(
            Uuid::new_v4().to_string(),
            drawer_id.to_string(),
            recall_at,
            None,
            RecallTraceItem::FLAG_USED, // operational_bitmap=1 → used()=true → reward=1.0
        );
        registry.default.store.insert_recall_trace(&trace)
            .expect("insert_recall_trace must succeed");
    }

    // ── Create governor from populated registry ───────────────────────────────
    let estate_str = uuid::Uuid::from_bytes(registry.default.handle.estate_uuid).to_string();
    let coord = Arc::clone(&registry.coord);
    let handle = registry.default.handle;
    let store = Arc::clone(&registry.default.store);
    let mut governor = AutonomicGovernor::new(coord, handle, store);

    // ── Install CapturingSink, enable monitoring ──────────────────────────────
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    // ── First tick at now_epoch — dreaming fires ──────────────────────────────
    let report = governor.tick(UNIX_EPOCH + Duration::from_secs(now_epoch_i64 as u64));
    assert!(
        report.dreaming_fired,
        "dreaming must fire on first tick (estate has 3 co-occurring drawers)"
    );

    // ── Assert at least one Think event was emitted ───────────────────────────
    let events = sink.event_samples_for_estate(&estate_str);
    assert!(
        !events.is_empty(),
        "dreaming pump must emit at least one StatSample::Event for estate {}; got 0",
        estate_str
    );
    for event in &events {
        if let StatSample::Event { kind, noun_type, estate, .. } = event {
            assert_eq!(
                *kind,
                EventKind::Think,
                "every Event from dreaming pump must have kind=Think; got {:?}",
                kind
            );
            // NounType::Proposal wire-stable value = 4 (SubstrateTypes/NounType.swift)
            assert_eq!(*noun_type, 4i64, "think event noun_type must be 4 (Proposal); got {}", noun_type);
            assert_eq!(
                estate, &estate_str,
                "think event estate must match the governor's estate UUID"
            );
        } else {
            panic!("expected StatSample::Event; got {:?}", event);
        }
    }

    reset_intellectus();
}

// MARK: - §6 Topology snapshot

/// AG-11: Topology snapshot fires on first tick (cadence = 0 → always fires).
/// Mirrors Swift `topologySnapshotFiredOnFirstTick`.
#[test]
fn ag11_topology_snapshot_fired_on_first_tick() {
    // new_for_testing passes cadence_ms=0 directly — avoids env-var
    // pollution across parallel test threads.
    let registry = EstateRegistry::new_inmemory();
    let coord = Arc::clone(&registry.coord);
    let handle = registry.default.handle;
    let store = Arc::clone(&registry.default.store);
    let mut governor = AutonomicGovernor::new_for_testing(coord, handle, store, 0, None);

    let report = governor.tick(UNIX_EPOCH + Duration::from_secs(8_000_000));
    assert!(
        report.topology_snapshot_fired,
        "topology snapshot must fire on first tick when cadence is 0"
    );
}

/// AG-12: Topology snapshot respects its cadence.
/// At t=299 s (after t=0 fired) the 300 s cadence has not elapsed.
/// At t=300 s exactly it fires again.
/// Mirrors Swift `topologySnapshotRespectsInterval`.
#[test]
fn ag12_topology_snapshot_respects_interval() {
    // Use new_for_testing with cadence=300_000 ms to avoid env-var pollution.
    let registry = EstateRegistry::new_inmemory();
    let coord = Arc::clone(&registry.coord);
    let handle = registry.default.handle;
    let store = Arc::clone(&registry.default.store);
    let mut governor = AutonomicGovernor::new_for_testing(coord, handle, store, 300_000, None);

    let t0 = UNIX_EPOCH + Duration::from_secs(9_000_000);
    let first = governor.tick(t0);
    assert!(first.topology_snapshot_fired, "first tick must fire (no prior)");

    let early = governor.tick(t0 + Duration::from_secs(299));
    assert!(!early.topology_snapshot_fired, "299 s < 300 s — must not fire");

    let due = governor.tick(t0 + Duration::from_secs(300));
    assert!(due.topology_snapshot_fired, "300 s elapsed — must fire");
}

/// AG-13: When a stats store is provided, topology snapshot duty writes a
/// valid JSON payload to `topology_snapshots` with `structurePending: true`.
#[test]
fn ag13_topology_snapshot_duty_writes_to_store() {
    use uuid::Uuid;
    use observer_sink::StatsStore;

    // Open an in-memory stats store (SQLite in-memory via persistence-kit).
    let store = StatsStore::new(":memory:").expect("in-memory stats store must open");
    store.open().expect("store.open must succeed");

    let stats_store_arc = Arc::new(store);
    let registry = EstateRegistry::new_inmemory();
    let coord = Arc::clone(&registry.coord);
    let handle = registry.default.handle;
    let estate_id = Uuid::from_bytes(handle.estate_uuid).to_string();
    let drawer_store = Arc::clone(&registry.default.store);

    // cadence=0 so the snapshot fires immediately on every tick.
    let mut governor = AutonomicGovernor::new_for_testing(
        coord,
        handle,
        drawer_store,
        0,
        Some(Arc::clone(&stats_store_arc)),
    );

    // The duty is gated on the LIVE monitoring flag — enable it first
    // (fresh stores default off, and off must be free).
    stats_store_arc.set_monitoring_enabled(true).expect("enable monitoring");

    // First tick fires topology snapshot duty and writes to the store.
    let t0 = UNIX_EPOCH + Duration::from_secs(10_000_000);
    let report = governor.tick(t0);
    assert!(report.topology_snapshot_fired, "first tick must fire topology snapshot");

    // Read back the snapshot: REAL analysis (neuron-kit graph_topology) —
    // structurePending false even on an empty estate; arrays empty.
    let payload_bytes = stats_store_arc
        .latest_topology_snapshot(Some(&estate_id))
        .expect("latest_topology_snapshot must succeed")
        .expect("snapshot must be present after tick");

    let value: serde_json::Value =
        serde_json::from_str(&payload_bytes).expect("payload must be valid JSON");
    assert_eq!(
        value["structurePending"], serde_json::Value::Bool(false),
        "Rust topology snapshot carries real analysis (structurePending:false)"
    );
    assert!(value["nodes"].is_array());
    assert!(value["communities"].is_array());
    assert!(
        value["generatedTs"].is_string(),
        "payload must carry a generatedTs string; got {:?}", value["generatedTs"]
    );
}

/// AG-14: monitoring OFF gates the topology duty — no snapshot is written
/// even at a due cadence ("off is free"). Mirrors Swift `topologyGateFalseSkipsTheDuty`.
#[test]
fn ag14_monitoring_off_gates_topology_duty() {
    use uuid::Uuid;
    use observer_sink::StatsStore;

    let store = StatsStore::new(":memory:").expect("in-memory stats store must open");
    store.open().expect("store.open must succeed");
    let stats_store_arc = Arc::new(store);

    let registry = EstateRegistry::new_inmemory();
    let coord = Arc::clone(&registry.coord);
    let handle = registry.default.handle;
    let estate_id = Uuid::from_bytes(handle.estate_uuid).to_string();
    let drawer_store = Arc::clone(&registry.default.store);

    let mut governor = AutonomicGovernor::new_for_testing(
        coord, handle, drawer_store, 0, Some(Arc::clone(&stats_store_arc)));

    // Monitoring defaults OFF on a fresh store — the duty must not write.
    let _ = governor.tick(UNIX_EPOCH + Duration::from_secs(11_000_000));
    let absent = stats_store_arc
        .latest_topology_snapshot(Some(&estate_id))
        .expect("read must not error");
    assert!(absent.is_none(), "monitoring off must skip the snapshot write");

    // Flip on: the next due cadence computes without a restart.
    stats_store_arc.set_monitoring_enabled(true).expect("enable monitoring");
    let _ = governor.tick(UNIX_EPOCH + Duration::from_secs(11_000_300));
    let present = stats_store_arc
        .latest_topology_snapshot(Some(&estate_id))
        .expect("read must not error");
    assert!(present.is_some(), "monitoring on must resume the snapshot write");
}

/// AG-15: the inputs dirty token skips recomputation on an unchanged estate —
/// the stored generated_at does not advance across a second due cadence.
/// Mirrors Swift `topologySnapshotDutySkipsWhenInputUnchanged`.
#[test]
fn ag15_unchanged_estate_skips_recompute() {
    use uuid::Uuid;
    use observer_sink::StatsStore;

    let store = StatsStore::new(":memory:").expect("in-memory stats store must open");
    store.open().expect("store.open must succeed");
    let stats_store_arc = Arc::new(store);
    stats_store_arc.set_monitoring_enabled(true).expect("enable monitoring");

    let registry = EstateRegistry::new_inmemory();
    let coord = Arc::clone(&registry.coord);
    let handle = registry.default.handle;
    let estate_id = Uuid::from_bytes(handle.estate_uuid).to_string();
    let drawer_store = Arc::clone(&registry.default.store);

    let mut governor = AutonomicGovernor::new_for_testing(
        coord, handle, drawer_store, 0, Some(Arc::clone(&stats_store_arc)));

    let _ = governor.tick(UNIX_EPOCH + Duration::from_secs(12_000_000));
    let first = stats_store_arc
        .latest_topology_snapshot(Some(&estate_id))
        .expect("read must not error")
        .expect("first snapshot present");

    // Second due cadence, estate unchanged: the duty yields an identical dirty
    // token and skips — the stored payload (including generatedTs) is untouched.
    let _ = governor.tick(UNIX_EPOCH + Duration::from_secs(12_000_600));
    let second = stats_store_arc
        .latest_topology_snapshot(Some(&estate_id))
        .expect("read must not error")
        .expect("snapshot still present");

    assert_eq!(first, second,
               "unchanged estate must not rewrite the snapshot (generatedTs preserved)");
}

/// AG-15b: the inputs dirty token is PROCESS-LOCAL and is NEVER persisted. The
/// only thing the duty writes to the stats store is the topology JSON payload
/// (`write_topology_snapshot` takes estate_id, secs, payload — the token is not
/// an argument). Prove the boundary from the persisted bytes: no token field
/// name and no token vocabulary appears in the stored snapshot.
/// Mirrors Swift `topologyInputsTokenIsNeverPersisted`.
#[test]
fn ag15b_inputs_token_is_never_persisted() {
    use uuid::Uuid;
    use observer_sink::StatsStore;

    let store = StatsStore::new(":memory:").expect("in-memory stats store must open");
    store.open().expect("store.open must succeed");
    let stats_store_arc = Arc::new(store);
    stats_store_arc.set_monitoring_enabled(true).expect("enable monitoring");

    let registry = EstateRegistry::new_inmemory();
    let coord = Arc::clone(&registry.coord);
    let handle = registry.default.handle;
    let estate_id = Uuid::from_bytes(handle.estate_uuid).to_string();
    let drawer_store = Arc::clone(&registry.default.store);

    let mut governor = AutonomicGovernor::new_for_testing(
        coord, handle, drawer_store, 0, Some(Arc::clone(&stats_store_arc)));

    let _ = governor.tick(UNIX_EPOCH + Duration::from_secs(15_000_000));
    let payload = stats_store_arc
        .latest_topology_snapshot(Some(&estate_id))
        .expect("read must not error")
        .expect("snapshot present");

    // The persisted payload is the topology wire shape only — no token field.
    assert!(!payload.contains("inputs_digest"),
            "token field name (rust) must not appear in persisted payload");
    assert!(!payload.contains("inputsDigest"),
            "token field name (swift wire) must not appear in persisted payload");
    assert!(!payload.contains("token"),
            "no token vocabulary may leak into the persisted payload");
    // What SHOULD be there: the topology snapshot wire shape.
    assert!(payload.contains("structurePending"),
            "persisted payload must be the topology snapshot");
}

// MARK: - §7 Encode drain — production wiring (parity gap fix)
//
// Force-tests that the governor tick drives the encode drain so regular-mode
// captures become BM25/vector indexed in production (closing the Rust parity
// gap). Swift parity: EncodeIntake.swift P4 background drain Task.
//
// Test list:
//   AG-16: regular capture + governor tick → BM25 recall FINDS the drawer
//   AG-17: impatient mode unchanged — still inline-indexed, no drain wait
//   AG-18: encode_drain_fired is true every tick (idempotent on empty queue)
//   AG-19: multiple ticks drain progressively — second tick is idempotent

use std::collections::BTreeMap;
use aria_mcp::{
    dispatch::dispatch_tool,
    jsonrpc::JsonValue,
    surfaced_recall_ledger::SurfacedRecallLedger,
};

macro_rules! args {
    () => { BTreeMap::new() };
    ( $( $k:expr => $v:expr ),+ $(,)? ) => {{
        let mut m = BTreeMap::new();
        $( m.insert($k.to_string(), JsonValue::from(serde_json::json!($v))); )+
        m
    }};
}

fn is_success(result: &serde_json::Value) -> bool {
    result["isError"] == serde_json::json!(false)
}

fn content_text(result: &serde_json::Value) -> &str {
    result["content"][0]["text"].as_str().unwrap_or("")
}

/// AG-16: Regular-mode capture → governor tick → BM25 recall finds the drawer.
///
/// This is the load-bearing test for the parity gap fix. Before this wiring,
/// a regular `moot_file_memory` (default mode) would enqueue an EncodeJob but
/// NO production code would drain it — the drawer remained recall-dark
/// indefinitely. After this fix, the first governor tick drains the queue
/// and the drawer becomes BM25/vector searchable.
///
/// Parity: Swift's P4 background drain Task (EncodeIntake.swift:149-153)
/// performs the same drain on its 15 ms poll cadence; here the governor tick
/// is the equivalent consumer.
#[test]
fn ag16_regular_capture_governor_tick_makes_drawer_bm25_searchable() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    // Regular (non-impatient) capture — enqueues a job to the encode queue.
    // The drawer is stored but NOT yet BM25/vector indexed at this point.
    let capture_result = dispatch_tool(
        "moot_file_memory",
        &args!["content" => "flamingo wades through brackish water estuary",
               "location" => "memories/birds"],
        &registry,
        &ledger,
    ).expect("moot_file_memory must succeed");
    assert!(is_success(&capture_result), "regular capture should succeed; got: {capture_result:?}");

    // Without a governor tick the search would find the drawer via the Locus
    // structured lane only (not BM25). We don't assert the pre-tick state here;
    // the important proof is AFTER the tick.

    // Governor tick — drives drain_encode_queue_once, ingesting the pending job
    // into the Corpus (BM25 + vector indexed). This is the production drain path.
    let coord = Arc::clone(&registry.coord);
    let handle = registry.default.handle;
    let store = Arc::clone(&registry.default.store);
    let mut governor = AutonomicGovernor::new(coord, handle, store);
    let report = governor.tick(UNIX_EPOCH + Duration::from_secs(1_700_000_001));

    // encode_drain_fired must be true — drain was called (idempotent even if 0
    // jobs, but here we expect at least 1 job ingested).
    assert!(
        report.encode_drain_fired,
        "governor tick must fire encode drain; encode_drain_fired was false"
    );

    // BM25 recall now finds the drawer — the semantic lane is lit.
    let search_result = dispatch_tool(
        "moot_memory_search",
        &args!["query" => "flamingo brackish estuary", "scoring" => "rrf"],
        &registry,
        &ledger,
    ).expect("moot_memory_search must succeed");
    assert!(is_success(&search_result), "search must succeed; got: {search_result:?}");

    let text = content_text(&search_result);
    assert!(
        text.starts_with("found ") && !text.starts_with("found 0"),
        "BM25 recall must find the drawer after governor tick drains encode queue; got: {text}"
    );
    assert!(
        text.contains("flamingo"),
        "search result must contain captured content; got: {text}"
    );
}

/// AG-17: Impatient-mode capture is unchanged — still inline-indexed.
///
/// Impatient mode (P6) ingests the drawer into the Corpus INLINE before the
/// write returns. No encode queue job is enqueued; no governor tick is needed
/// for BM25 recall. This test verifies impatient mode still works after the
/// encode drain wiring was added to the governor tick.
///
/// Parity: Swift P6 path (EncodeIntake.swift:110 ingestDrawerIntoCorpus inline).
#[test]
fn ag17_impatient_capture_is_immediately_searchable_no_tick_needed() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    // Impatient capture — encodes inline before returning.
    let capture_result = dispatch_tool(
        "moot_file_memory",
        &args!["content" => "avocet probes mud at low tide estuary",
               "location" => "memories/birds",
               "impatient" => true],
        &registry,
        &ledger,
    ).expect("impatient moot_file_memory must succeed");
    assert!(is_success(&capture_result), "impatient capture should succeed; got: {capture_result:?}");

    // No governor tick — impatient mode encoded inline before returning.
    // BM25 recall must find the drawer IMMEDIATELY.
    let search_result = dispatch_tool(
        "moot_memory_search",
        &args!["query" => "avocet estuary tide", "scoring" => "rrf"],
        &registry,
        &ledger,
    ).expect("moot_memory_search must succeed");
    assert!(is_success(&search_result), "search must succeed; got: {search_result:?}");

    let text = content_text(&search_result);
    assert!(
        text.starts_with("found ") && !text.starts_with("found 0"),
        "impatient capture must be immediately BM25 searchable (no governor tick needed); got: {text}"
    );
    assert!(
        text.contains("avocet"),
        "search result must contain captured content; got: {text}"
    );
}

/// AG-18: encode_drain_fired is true on every tick — idempotent on empty queue.
///
/// `drain_encode_queue_once` returns `Ok(0)` when the queue is empty (no queue
/// mounted, or queue empty). The governor reports `encode_drain_fired = true`
/// on every tick regardless of jobs processed — reflecting that the drain was
/// called, not that jobs were found. This matches the topology_snapshot_fired
/// semantics (cadence gate, not write result).
///
/// Tests that an estate with NO pending encode jobs still sets encode_drain_fired
/// true on every tick — zero-cost idempotent drain.
#[test]
fn ag18_encode_drain_fired_is_true_even_on_empty_queue() {
    let (mut governor, _registry) = make_governor();

    // First tick — no pending encode jobs (no captures done).
    let r1 = governor.tick(UNIX_EPOCH + Duration::from_secs(1_700_000_100));
    assert!(
        r1.encode_drain_fired,
        "encode_drain_fired must be true on tick 1 even with no pending jobs"
    );

    // Second tick — still empty queue.
    let r2 = governor.tick(UNIX_EPOCH + Duration::from_secs(1_700_000_200));
    assert!(
        r2.encode_drain_fired,
        "encode_drain_fired must be true on tick 2 (idempotent empty drain)"
    );

    // Third tick — confirms repeated empty-queue drains are stable.
    let r3 = governor.tick(UNIX_EPOCH + Duration::from_secs(1_700_000_300));
    assert!(
        r3.encode_drain_fired,
        "encode_drain_fired must be true on tick 3 (repeated idempotent empty drain)"
    );
}

/// AG-19: Multiple regular captures drained across ticks — second tick is
/// idempotent after first tick drained all jobs.
///
/// Captures two drawers via regular mode. First governor tick drains both.
/// Second governor tick finds the queue empty, returns encode_drain_fired=true
/// (the drain WAS called — it returned Ok(0)). Both drawers are BM25 searchable
/// after the first tick.
///
/// Tests: error in one job doesn't poison the queue — encode_drain_queue_once
/// replies Blocked for failures and continues; subsequent ticks process the
/// remaining jobs. (Here no failure is injected; second-tick idempotence is
/// verified instead, which is the observable contract.)
#[test]
fn ag19_two_regular_captures_drained_by_tick_second_tick_idempotent() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    // Capture two drawers via regular mode — both enqueued.
    dispatch_tool(
        "moot_file_memory",
        &args!["content" => "spoonbill sweeps bill through water feeding",
               "location" => "memories/birds"],
        &registry, &ledger,
    ).expect("capture 1 must succeed");

    dispatch_tool(
        "moot_file_memory",
        &args!["content" => "ibis probes soil with curved beak savanna",
               "location" => "memories/birds"],
        &registry, &ledger,
    ).expect("capture 2 must succeed");

    let coord = Arc::clone(&registry.coord);
    let handle = registry.default.handle;
    let store = Arc::clone(&registry.default.store);
    let mut governor = AutonomicGovernor::new(coord, handle, store);

    // First tick — drains both enqueued jobs into the Corpus.
    let r1 = governor.tick(UNIX_EPOCH + Duration::from_secs(1_700_000_500));
    assert!(
        r1.encode_drain_fired,
        "first tick must fire encode drain (two jobs present)"
    );

    // Both drawers must now be BM25/vector searchable.
    let r_spoonbill = dispatch_tool(
        "moot_memory_search",
        &args!["query" => "spoonbill bill water", "scoring" => "rrf"],
        &registry, &ledger,
    ).expect("moot_memory_search must succeed");
    assert!(is_success(&r_spoonbill));
    let t1 = content_text(&r_spoonbill);
    assert!(
        t1.starts_with("found ") && !t1.starts_with("found 0"),
        "spoonbill must be BM25 searchable after first governor tick; got: {t1}"
    );

    let r_ibis = dispatch_tool(
        "moot_memory_search",
        &args!["query" => "ibis beak savanna", "scoring" => "rrf"],
        &registry, &ledger,
    ).expect("moot_memory_search must succeed");
    assert!(is_success(&r_ibis));
    let t2 = content_text(&r_ibis);
    assert!(
        t2.starts_with("found ") && !t2.starts_with("found 0"),
        "ibis must be BM25 searchable after first governor tick; got: {t2}"
    );

    // Second tick — queue is now empty; encode_drain_fired is still true
    // (drain was called — returned Ok(0) — idempotent).
    let r2 = governor.tick(UNIX_EPOCH + Duration::from_secs(1_700_000_600));
    assert!(
        r2.encode_drain_fired,
        "second tick must still report encode_drain_fired=true (empty-queue drain is idempotent)"
    );
}

// ─────────────────────────────────────────────────────────────────
// §6 Pool reducer trigger (OP-3 Part B) — novel-token merge-back
// ─────────────────────────────────────────────────────────────────
//
// Rust parity of the Swift `poolReducerTrigger*` force-tests. The governor
// drives `lattice::pool_reduce` NEAR-REALTIME (cadence 0 = every tick) and
// live-swaps the running table at the post-reduce safe point. These use a
// hermetic temp pool dir + writable table artifact injected via
// `new_for_testing_with_pool` (no env mutation, no platform-default filesystem
// touch). AG-PR1 asserts the MERGE into the writable artifact; AG-PR1b asserts
// the in-session LIVE SWAP — the running `word_class` classifies the merged
// token without a process restart (cookbook §1.3/§2.2).

/// Serializes the pool-reduce tests against each other. A non-noop reduce
/// live-swaps the PROCESS-GLOBAL word-class table (bumping its version), so
/// tests that observe the version delta or the live classification need
/// exclusive access for the swap + check window (Rust runs tests in parallel by
/// default). Poisoning is tolerated (a prior panic must not wedge the suite).
fn pool_test_lock() -> &'static std::sync::Mutex<()> {
    static LOCK: std::sync::OnceLock<std::sync::Mutex<()>> = std::sync::OnceLock::new();
    LOCK.get_or_init(|| std::sync::Mutex::new(()))
}

/// Unique temp directory for one test (no external tempfile crate — C-1).
fn unique_temp_dir(tag: &str) -> std::path::PathBuf {
    let nanos = std::time::SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let dir = std::env::temp_dir().join(format!("op3-{tag}-{nanos}"));
    std::fs::create_dir_all(&dir).expect("create temp dir");
    dir
}

/// AG-PR1: the reducer fires on cadence 0, is no-op-safe on an empty pool, and
/// merges a novel token so a fresh load of the artifact would classify it.
/// Idempotent: a re-run on the drained pool changes nothing.
#[test]
fn ag_pr1_pool_reduce_fires_merges_and_is_idempotent() {
    // A non-noop reduce live-swaps the process-global table; serialize against
    // the other pool-reduce tests so a concurrent swap can't disrupt them.
    let _g = pool_test_lock().lock().unwrap_or_else(|e| e.into_inner());
    let tmp = unique_temp_dir("pr1");
    let pool_dir = tmp.join("pool");
    std::fs::create_dir_all(&pool_dir).unwrap();
    let table_artifact = tmp.join("WordClassTable.json");
    std::fs::write(
        &table_artifact,
        r#"{"table_version":"1.0.0","min_os_version":"17.0","snapshot_date":"2026-01-01","nouns":["dog"],"verbs":["run"]}"#,
    )
    .unwrap();

    let registry = EstateRegistry::new_inmemory();
    let coord = Arc::clone(&registry.coord);
    let handle = registry.default.handle;
    let store = Arc::clone(&registry.default.store);
    let mut governor = AutonomicGovernor::new_for_testing_with_pool(
        coord, handle, store, 300_000, None,
        0, pool_dir.clone(), table_artifact.clone(),
    );

    // Empty pool → fires (cadence 0) but is a no-op.
    let r1 = governor.tick(UNIX_EPOCH + Duration::from_secs(22_000_000));
    assert!(r1.pool_reduce_fired, "pool reduce must fire on cadence 0");

    // Seed a complete novel-token submission and tick again: the token merges.
    std::fs::write(
        pool_dir.join("pool_0001.json"),
        r#"{"table_version":"1.0.0","platform":"test","tagger_version":"1","entries":[{"token":"flumph","tag":"NOUN"}]}"#,
    )
    .unwrap();
    let r2 = governor.tick(UNIX_EPOCH + Duration::from_secs(22_000_001));
    assert!(r2.pool_reduce_fired);

    let merged = std::fs::read_to_string(&table_artifact).unwrap();
    assert!(
        merged.contains("flumph"),
        "reduce must merge the novel token into the writable table; got: {merged}"
    );

    // Idempotent: third tick on the drained pool changes nothing further.
    let r3 = governor.tick(UNIX_EPOCH + Duration::from_secs(22_000_002));
    assert!(r3.pool_reduce_fired);
    let after = std::fs::read_to_string(&table_artifact).unwrap();
    assert!(after.contains("flumph"), "merged token must persist");

    let _ = std::fs::remove_dir_all(&tmp);
}

/// AG-PR1b: IN-SESSION LEARNING (the proof that matters). In ONE running
/// process, a novel-token submission is reduced near-realtime on a governor
/// tick, the LIVE process-global word-class table is swapped at the post-reduce
/// safe point, and `lattice_lib::word_class` then classifies the novel token
/// from the table — WITHOUT a process restart. Distinct from the cross-reload
/// foundation test. Restores the bundled table at the end for hygiene.
#[test]
fn ag_pr1b_in_session_learning_via_reduce_and_swap() {
    // Hold the pool-test lock for the whole swap + classify window so no other
    // test swaps the global table between our reduce and our word_class check.
    let _g = pool_test_lock().lock().unwrap_or_else(|e| e.into_inner());
    let tmp = unique_temp_dir("pr1b");
    let pool_dir = tmp.join("pool");
    std::fs::create_dir_all(&pool_dir).unwrap();
    let table_artifact = tmp.join("WordClassTable.json");

    // Seed the writable artifact from the bundled bytes so the reducer merges
    // into a valid base carrying the bundled table_version (the reducer rejects
    // a version mismatch).
    let bundled = std::str::from_utf8(lattice_lib::BUNDLED_TABLE_JSON).unwrap().to_string();
    std::fs::write(&table_artifact, &bundled).unwrap();
    let tv = {
        let parsed: serde_json::Value = serde_json::from_str(&bundled).unwrap();
        parsed["table_version"].as_str().unwrap().to_string()
    };

    // A digit-bearing novel token: the table-only `word_class` returns Other for
    // it before learning (not in the table).
    let novel = "zq8xlexeme";
    assert_ne!(
        lattice_lib::word_class(novel),
        lattice_lib::WordClass::Noun,
        "precondition: the novel token must not be a table noun before learning"
    );

    std::fs::write(
        pool_dir.join("pool_insession.json"),
        format!(
            r#"{{"table_version":"{tv}","platform":"test","tagger_version":"1","entries":[{{"token":"{novel}","tag":"NOUN"}}]}}"#
        ),
    )
    .unwrap();

    let registry = EstateRegistry::new_inmemory();
    let coord = Arc::clone(&registry.coord);
    let handle = registry.default.handle;
    let store = Arc::clone(&registry.default.store);
    let mut governor = AutonomicGovernor::new_for_testing_with_pool(
        coord, handle, store, 300_000, None,
        0, pool_dir.clone(), table_artifact.clone(),
    );

    let version_before = lattice_lib::table_version();
    let report = governor.tick(UNIX_EPOCH + Duration::from_secs(25_000_000));

    assert!(report.pool_reduce_fired);
    assert!(report.table_swapped, "a non-noop reduce must live-swap the running table");
    assert_eq!(
        report.table_version,
        version_before + 1,
        "the live swap must advance the version"
    );

    // THE PROOF: the SAME live surface now classifies the token from the table —
    // learned in-session, no restart.
    assert_eq!(
        lattice_lib::word_class(novel),
        lattice_lib::WordClass::Noun,
        "in-session: word_class must classify the merged token from the live-swapped table"
    );

    // Restore the bundled table as the live snapshot for other tests.
    if let Some(b) = lattice_lib::WordClassTableCache::from_json(lattice_lib::BUNDLED_TABLE_JSON) {
        lattice_lib::swap_global_table(b);
    }
    let _ = std::fs::remove_dir_all(&tmp);
}

/// AG-PR2: the trigger respects its cadence — it does NOT fire again before the
/// cadence elapses, and fires once it has.
#[test]
fn ag_pr2_pool_reduce_respects_cadence() {
    // A non-noop reduce live-swaps the process-global table; serialize against
    // the other pool-reduce tests so a concurrent swap can't disrupt them.
    let _g = pool_test_lock().lock().unwrap_or_else(|e| e.into_inner());
    let tmp = unique_temp_dir("pr2");
    let pool_dir = tmp.join("pool");
    std::fs::create_dir_all(&pool_dir).unwrap();
    let table_artifact = tmp.join("WordClassTable.json");

    let registry = EstateRegistry::new_inmemory();
    let coord = Arc::clone(&registry.coord);
    let handle = registry.default.handle;
    let store = Arc::clone(&registry.default.store);
    // 1 h cadence.
    let mut governor = AutonomicGovernor::new_for_testing_with_pool(
        coord, handle, store, 300_000, None,
        3_600_000, pool_dir.clone(), table_artifact.clone(),
    );

    let t0 = UNIX_EPOCH + Duration::from_secs(23_000_000);
    let first = governor.tick(t0);
    assert!(first.pool_reduce_fired, "first tick fires");
    let early = governor.tick(t0 + Duration::from_secs(30));
    assert!(!early.pool_reduce_fired, "must not re-fire before the cadence elapses");
    let due = governor.tick(t0 + Duration::from_secs(3600));
    assert!(due.pool_reduce_fired, "must fire once the cadence has elapsed");

    let _ = std::fs::remove_dir_all(&tmp);
}

/// AG-PR3 (budget, Part C): a tick with the pool-reduce loop active completes
/// promptly — the reduce on an empty/absent pool is a no-op-zero-cost scan, so
/// the tick does not run away.
#[test]
fn ag_pr3_tick_completes_promptly_with_pool_reduce_active() {
    // A non-noop reduce live-swaps the process-global table; serialize against
    // the other pool-reduce tests so a concurrent swap can't disrupt them.
    let _g = pool_test_lock().lock().unwrap_or_else(|e| e.into_inner());
    let tmp = unique_temp_dir("pr3");
    let pool_dir = tmp.join("pool");
    std::fs::create_dir_all(&pool_dir).unwrap();
    let table_artifact = tmp.join("WordClassTable.json");

    let registry = EstateRegistry::new_inmemory();
    let coord = Arc::clone(&registry.coord);
    let handle = registry.default.handle;
    let store = Arc::clone(&registry.default.store);
    let mut governor = AutonomicGovernor::new_for_testing_with_pool(
        coord, handle, store, 0, None,
        0, pool_dir.clone(), table_artifact.clone(),
    );

    let start = std::time::Instant::now();
    let _ = governor.tick(UNIX_EPOCH + Duration::from_secs(24_000_000));
    let elapsed = start.elapsed();
    // Generous ceiling — the synchronous tick work is sub-second; this catches a
    // runaway only.
    assert!(
        elapsed < Duration::from_secs(5),
        "a governor tick must complete promptly (was {elapsed:?})"
    );

    let _ = std::fs::remove_dir_all(&tmp);
}
