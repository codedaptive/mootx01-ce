//! Autonomic Governor integration tests (see bounded loopback HTTP).
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

use neuron_kit::autonomic_governor::AutonomicGovernor;
use neuron_kit::governor_topology_sink::GovernorTopologySink;
use aria_mcp::estate_registry::EstateRegistry;
use aria_mcp::governor_topology_adapter::StatsStoreTopologySink;
use intellectus_lib::{EventKind, Intellectus, NoOpSink, StatSample, StatsSink};

// Dreaming-queue seeding imports (v2 pending-count gate).
// Used by seed_dreaming_queue and tests that assert dreaming fires.
use genius_locus_kit::recall::{GLKRecallMode, GLKRecallRequest, GLKRecallScoring,
    RecallFallbackPolicy};
use locus_kit::filter::{Filter, RecallFrame};
use locus_kit::frames::CaptureFrame;
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::estate_types::LatticeAnchor;

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

/// Per-call isolated pool paths so a governor's reducer never reads or writes the
/// real user pool (ce-fdcpool test isolation). Unique per call via a PID + atomic
/// counter — no `LATTICE_POOL_DIR` mutation, which would race across parallel test
/// threads, and no per-test serialization lock (the pool is private).
fn hermetic_pool_paths() -> (std::path::PathBuf, std::path::PathBuf) {
    use std::sync::atomic::{AtomicU64, Ordering};
    static SEQ: AtomicU64 = AtomicU64::new(0);
    let n = SEQ.fetch_add(1, Ordering::Relaxed);
    let base = std::env::temp_dir().join(format!("mootx01-testpool-{}-{}", std::process::id(), n));
    let pool_dir = base.join("pool");
    std::fs::create_dir_all(&pool_dir).unwrap();
    (pool_dir, base.join("WordClassTable.json"))
}

/// Build an `AutonomicGovernor` wired to a fresh in-memory estate.
///
/// Returns `(governor, registry)` so tests that want to inspect the live store
/// after a tick can access `registry.default.store`. The 300_000 ms topology and
/// 0 ms pool-reduce cadences mirror `new`'s production defaults; the pool reducer
/// targets a private temp dir so a tick never touches the real user pool.
fn make_governor() -> (AutonomicGovernor, EstateRegistry) {
    let registry = EstateRegistry::new_inmemory();
    let coord = Arc::clone(&registry.coord);
    let handle = registry.default.handle;
    let store = Arc::clone(&registry.default.store);
    let (pool_dir, artifact) = hermetic_pool_paths();
    let governor = AutonomicGovernor::new_for_testing_with_pool(
        coord, handle, store, 300_000, None, 0, pool_dir, artifact,
    );
    (governor, registry)
}

/// Build a governor with a caller-supplied stop flag and an explicit base tick
/// (for the run_loop test). The tick is passed directly rather than via
/// `MOOTX01_BRAIN_TICK_MS`, so this helper never sets a process-global env var
/// that would race sibling tests constructing governors in parallel. The pool
/// reducer targets a private temp dir (ce-fdcpool test isolation).
fn make_governor_with_flag(flag: Arc<AtomicBool>, base_tick_ms: u64) -> AutonomicGovernor {
    let registry = EstateRegistry::new_inmemory();
    let coord = Arc::clone(&registry.coord);
    let handle = registry.default.handle;
    let store = Arc::clone(&registry.default.store);
    let (pool_dir, artifact) = hermetic_pool_paths();
    AutonomicGovernor::with_stop_flag_tick_and_pool(
        coord, handle, store, flag, base_tick_ms, pool_dir, artifact,
    )
}

// ── Dreaming-queue seed helper ───────────────────────────────────────────────

/// Seed the dreaming queue for a registry so the v2 pending-count gate
/// (`dreaming_queue_pending_count_for_gate`) returns `Some(n > 0)` on the
/// next governor tick.
///
/// The REM-ALPHA gate skips the dreaming cycle
/// entirely when the estate's dreaming queue is empty or not yet mounted —
/// an idle tick costs nothing. Tests that assert `dreaming_fired == true`
/// must therefore ensure ≥1 pending item is in the queue before the tick.
///
/// Mechanism (mirrors `dreaming_pump_emits_think_events`):
///   1. Capture 2 drawers into the estate so recall_scored surfaces ≥2 drawers.
///   2. Fire one external-origin `recall_scored` call. The coordinator mounts
///      the dreaming queue on first use, wraps the 2 drawer ids in a `DreamingItem`,
///      and enqueues it — `pending_count` becomes 1.
///
/// Call this once per tick that should fire dreaming (the tick drains the queue,
/// so each subsequent fire-tick needs a fresh enqueue). Captures are reused
/// across calls on the same registry.
///
/// `now_epoch_i64` is passed to capture and recall as the deterministic clock.
fn seed_dreaming_queue(registry: &EstateRegistry, now_epoch_i64: i64) {
    let capture_frame = |content: &str| {
        let frame = CaptureFrame::new(
            content,
            CaptureChannel::Typed,
            "cadence-test-room",
            LatticeAnchor::udc("000"),
            "cadence-test",
            "test-model-v1",
        );
        registry.coord
            .lock()
            .unwrap()
            .capture(&registry.default.handle, frame, now_epoch_i64)
            .expect("seed capture must succeed");
    };
    capture_frame("cadence-seed-alpha");
    capture_frame("cadence-seed-beta");

    // External-origin recall: coordinator mounts the dreaming queue and
    // enqueues one DreamingItem with the 2 captured drawer ids, making
    // pending_count = 1 so the pending-count gate passes on the next tick.
    let external_request = GLKRecallRequest::new(RecallFrame::new(vec![Filter::Unconfirmed]))
        .with_mode(GLKRecallMode::LocusOnly)
        .with_scoring(GLKRecallScoring::Raw)
        .with_limit(50)
        .with_fallback(RecallFallbackPolicy::FailClosed)
        .external();
    registry.coord
        .lock()
        .unwrap()
        .recall_scored(&registry.default.handle, external_request, now_epoch_i64)
        .expect("seed recall_scored must succeed");
}

// MARK: - §1 Cadence

/// AG-1: First tick always fires both daemons when the dreaming queue has
/// pending work (v2 pending-count gate: cadence + pending > 0 → fire).
/// Mirrors Swift `firstTickFiresDreamingAndMaintenance`.
#[test]
fn ag1_first_tick_always_fires_both_daemons() {
    let (mut governor, registry) = make_governor();
    // Seed the dreaming queue so the v2 pending-count gate passes.
    // The gate skips dreaming when the queue is empty; one external-origin
    // recall enqueues a DreamingItem (pending_count = 1) so the cadence
    // gate (no prior fire) + pending gate both pass on this tick.
    seed_dreaming_queue(&registry, 0);
    // At t=0 there is no prior fire for either daemon.
    let report = governor.tick(UNIX_EPOCH);
    assert!(
        report.dreaming_fired,
        "dreaming must fire on first tick (pending-count gate seeded)"
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
///
/// v2 pending-count gate: the first tick is seeded so dreaming fires there.
/// The second tick at t=29 s is before the cadence boundary — the cadence
/// gate fires before the pending-count gate is even consulted, so both
/// assertions remain unchanged: cadence gate dominates.
#[test]
fn ag2_tick_before_interval_returns_no_fire() {
    let (mut governor, registry) = make_governor();
    // Seed the dreaming queue so the first tick fires dreaming.
    // The cadence gate fires first; the pending-count gate is the second gate.
    seed_dreaming_queue(&registry, 0);
    // First tick fires (t=0).
    let first = governor.tick(UNIX_EPOCH);
    assert!(first.dreaming_fired, "first tick must fire dreaming (pending-count gate seeded)");
    assert!(first.maintenance_fired, "first tick must fire maintenance");

    // Second tick at t=29 s — the cadence gate (30 s interval) has not elapsed,
    // so dreaming is skipped before the pending-count gate is consulted.
    // No seeding needed: the cadence gate is the controlling gate here.
    let second = governor.tick(UNIX_EPOCH + Duration::from_secs(29));
    assert!(
        !second.dreaming_fired,
        "dreaming must not fire before 30 s interval (cadence gate dominates)"
    );
    assert!(
        !second.maintenance_fired,
        "maintenance must not fire before 300 s interval"
    );
}

/// AG-3: Dreaming fires at its interval boundary (30 s) while maintenance
/// has not yet reached its boundary (300 s). Mirrors Swift
/// `dreamingRespectsCadence`.
///
/// v2 pending-count gate: seed before each tick that must fire dreaming.
/// The first tick (t0) drains the queue; the second tick (+30 s) needs a
/// fresh enqueue so pending_count > 0 when the cadence gate opens.
#[test]
fn ag3_dreaming_fires_at_interval_maintenance_does_not() {
    let (mut governor, registry) = make_governor();
    // Realistic base instant (Swift dreamingRespectsCadence t0 = 2_000_000) so the
    // post-cycle bandit re-selection is conformant with Swift — the seed keeps the
    // trigger mode on .timer, so this exercises the cadence gate, not a mode flip.
    let t0 = UNIX_EPOCH + Duration::from_secs(2_000_000);
    // Seed and fire first tick (result unused; seeds cadence state for second tick).
    seed_dreaming_queue(&registry, 2_000_000);
    let _ = governor.tick(t0);
    // Seed again: the first tick drained the queue; re-enqueue so pending_count > 0
    // for the second tick at +30 s (cadence elapsed, pending gate must also pass).
    seed_dreaming_queue(&registry, 2_000_000);
    // At +30 s exactly — dreaming interval (30 s) elapsed, maintenance (300 s) not.
    let second = governor.tick(t0 + Duration::from_secs(30));
    assert!(
        second.dreaming_fired,
        "dreaming must fire at the 30 s boundary (pending-count gate seeded)"
    );
    assert!(
        !second.maintenance_fired,
        "maintenance must not fire before 300 s boundary"
    );
}

/// AG-4: Both daemons fire when their intervals have both elapsed.
/// At t=300 s both dreaming (every 30 s) and maintenance (every 300 s)
/// have elapsed since the last fire at t=270/t=0.
///
/// v2 pending-count gate: seed before the +300 s tick so the dreaming
/// pending-count gate passes alongside the elapsed cadence gate.
#[test]
fn ag4_both_fire_after_long_gap() {
    let (mut governor, registry) = make_governor();
    // Realistic base instant (Swift t0 = 2_000_000) so the bandit re-selection is
    // conformant and the trigger mode stays .timer across the gap.
    let t0 = UNIX_EPOCH + Duration::from_secs(2_000_000);
    // Seed and fire first tick (sets cadence state; result unused).
    seed_dreaming_queue(&registry, 2_000_000);
    let _ = governor.tick(t0);
    // Seed again: the first tick drained the queue; re-enqueue so pending_count > 0
    // for the +300 s tick where both dreaming and maintenance must fire.
    seed_dreaming_queue(&registry, 2_000_000);
    // Advance +300 s — both intervals have elapsed.
    let later = governor.tick(t0 + Duration::from_secs(300));
    assert!(
        later.dreaming_fired,
        "dreaming must fire after 300 s gap (pending-count gate seeded)"
    );
    assert!(
        later.maintenance_fired,
        "maintenance must fire at its 300 s boundary"
    );
}

// MARK: - §2 Construction

/// AG-5: AutonomicGovernor::new() is constructable; tick returns a GovernorReport.
/// Smoke test — verifies no panic at construction or on first tick.
///
/// v2 pending-count gate: seed the dreaming queue so the first tick fires
/// dreaming (cadence gate: no prior fire; pending gate: seeded to > 0).
#[test]
fn ag5_construction_smoke() {
    let (mut governor, registry) = make_governor();
    // Seed the dreaming queue before the first tick so the v2 pending-count
    // gate passes alongside the cadence gate (no prior fire timestamp).
    seed_dreaming_queue(&registry, 1_000_000);
    let report = governor.tick(UNIX_EPOCH + Duration::from_secs(1_000_000));
    // The first tick fires both daemons when cadence gate + pending gate pass.
    assert!(report.dreaming_fired, "dreaming must fire on first tick (pending-count gate seeded)");
    assert!(report.maintenance_fired);
}

/// AG-6: Consecutive ticks at increasing timestamps stay coherent.
/// Three dreaming-interval steps: t=0, t=30, t=60. Each should fire dreaming.
///
/// v2 pending-count gate: each tick drains the queue, so seed once before
/// each tick that asserts dreaming fires (cadence gate + pending gate both
/// must pass for every fire assertion).
#[test]
fn ag6_consecutive_dreaming_firings() {
    let (mut governor, registry) = make_governor();
    // Realistic base instant (Swift t0 = 2_000_000) so the post-cycle bandit
    // re-selections stay conformant on .timer across consecutive intervals — the
    // test exercises the cadence gate over multiple ticks, not a mode flip.
    let t0 = UNIX_EPOCH + Duration::from_secs(2_000_000);
    seed_dreaming_queue(&registry, 2_000_000);
    let r0 = governor.tick(t0);
    assert!(r0.dreaming_fired, "first tick must fire (pending-count gate seeded)");
    // Re-seed: first tick drained the queue; enqueue a fresh DreamingItem.
    seed_dreaming_queue(&registry, 2_000_000);
    let r1 = governor.tick(t0 + Duration::from_secs(30));
    assert!(r1.dreaming_fired, "+30 s must fire (exactly one interval; pending-count gate seeded)");
    // Re-seed again for the third tick.
    seed_dreaming_queue(&registry, 2_000_000);
    let r2 = governor.tick(t0 + Duration::from_secs(60));
    assert!(r2.dreaming_fired, "+60 s must fire (two intervals; pending-count gate seeded)");
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
/// v2 pending-count gate: seed the dreaming queue before the tick so the
/// pending-count gate passes and the dreaming daemon runs (diary entry write).
#[test]
fn ag8_dreaming_fire_writes_diary_entry_to_live_estate() {
    use locus_kit::drawer_store::DrawerStore as LocusDrawerStore;

    let (mut governor, registry) = make_governor();
    // Seed the dreaming queue so the v2 pending-count gate passes on this tick.
    // The seed captures 2 drawers and fires one external-origin recall, enqueuing
    // one DreamingItem — pending_count = 1 so the gate opens.
    seed_dreaming_queue(&registry, 1_700_000_000);
    // Tick at a large epoch so the ISO8601 formatter exercises real dates.
    let report = governor.tick(UNIX_EPOCH + Duration::from_secs(1_700_000_000));
    assert!(report.dreaming_fired, "first tick must fire dreaming (pending-count gate seeded)");

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
/// Test setup (v2 drain-fed model):
///   1. Capture 3 drawers into the estate so they co-surface on external-origin recall.
///   2. Fire 3 external-origin `recall_scored` calls → 3 DreamingItems enqueued
///      on the estate's dreaming queue, one per co-surfaced set.
///   3. Insert recall traces with `used=true` inside the dreaming reward window
///      for each drawer → reward=1.0 for all targets →
///      `contrastive_confidence ≈ 0.88` (> `min_confidence=0.7`).
///   4. Governor tick: `EstateDreamingReader` drains the 3 windows, bumps
///      `co_recall_count(a,b)` ≥ 3 (meets `min_attempts`), `decide` emits
///      proposals → Think events flow via Intellectus.
///
/// The v2 path: candidates come ONLY from draining the dreaming queue.
/// Removing the 3 `recall_scored` enqueues would leave the queue empty → 0
/// candidates → 0 proposals → 0 Think events — that is the correct v2 sentinel.
///
/// Mirrors Swift `dreamingPumpEmitsThinkEvents` (TEL-01 §7 analog).
#[test]
fn dreaming_pump_emits_think_events() {
    use genius_locus_kit::recall::{GLKRecallMode, GLKRecallRequest, GLKRecallScoring,
        RecallFallbackPolicy};
    use locus_kit::drawer_store::DrawerStore as LocusDrawerStore;
    use locus_kit::filter::{Filter, RecallFrame};
    use locus_kit::frames::CaptureFrame;
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::estate_types::LatticeAnchor;
    use locus_kit::recall_trace_item::RecallTraceItem;
    use uuid::Uuid;

    let _guard = global_lock();

    let registry = EstateRegistry::new_inmemory();
    let now_epoch_i64 = 1_700_000_000i64;

    // ── Capture 3 drawers so they co-surface on external-origin recall ────────
    // Using coord.capture so the drawers are registered on the coordinator's
    // estate and surface in recall_scored. The coordinator is the same Arc
    // shared with the governor below.
    let capture_frame = |content: &str| -> String {
        let frame = CaptureFrame::new(
            content,
            CaptureChannel::Typed,
            "think-test-room",
            LatticeAnchor::udc("000"),
            "think-test",
            "test-model-v1",
        );
        registry.coord
            .lock()
            .unwrap()
            .capture(&registry.default.handle, frame, now_epoch_i64)
            .expect("capture must succeed")
            .id
    };
    let id_a = capture_frame("think-test alpha content");
    let id_b = capture_frame("think-test beta content");
    let id_c = capture_frame("think-test gamma content");

    // ── Insert recall traces with used=true inside the dreaming reward window ──
    // The dreaming window is [now - 30s, now].
    // A trace at now-10s falls inside; reward=1.0 for each drawer endpoint.
    // With 3 enqueues and reward=1.0, contrastive_confidence ≈ 0.88 (> min_confidence=0.7).
    let recall_at = "2023-11-14T22:13:10Z"; // 10 s before now (1_700_000_000)
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

    // ── Fire 3 external-origin recalls → 3 DreamingItems enqueued ────────────
    // B-10a: dreaming enqueue fires ONLY on external-origin scored recalls.
    // Each call surfaces all 3 drawers and writes one DreamingItem to the estate's
    // dreaming queue. After 3 calls, co_recall_count(a,b), co_recall_count(a,c),
    // co_recall_count(b,c) each reach 3 — meeting DreamingPolicy::default min_attempts=3.
    let external_request = || {
        GLKRecallRequest::new(RecallFrame::new(vec![Filter::Unconfirmed]))
            .with_mode(GLKRecallMode::LocusOnly)
            .with_scoring(GLKRecallScoring::Raw)
            .with_limit(50)
            .with_fallback(RecallFallbackPolicy::FailClosed)
            .external()
    };
    for _ in 0..3 {
        registry.coord
            .lock()
            .unwrap()
            .recall_scored(&registry.default.handle, external_request(), now_epoch_i64)
            .expect("recall_scored must succeed");
    }

    // ── Create governor from the populated registry ───────────────────────────
    // The coordinator Arc is shared: recall_scored above and the governor's tick
    // below operate on the same estate, so the enqueued dreaming items are visible
    // to the governor's EstateDreamingReader on the first tick.
    let estate_str = uuid::Uuid::from_bytes(registry.default.handle.estate_uuid).to_string();
    let coord = Arc::clone(&registry.coord);
    let handle = registry.default.handle;
    let store = Arc::clone(&registry.default.store);
    // ce-fdcpool test isolation: private temp pool, production-default cadences.
    let (pool_dir, artifact) = hermetic_pool_paths();
    let mut governor = AutonomicGovernor::new_for_testing_with_pool(
        coord, handle, store, 300_000, None, 0, pool_dir, artifact,
    );

    // ── Install CapturingSink, enable monitoring ──────────────────────────────
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    // ── First tick at now_epoch — dreaming fires, drains 3 windows, emits proposals ──
    let report = governor.tick(UNIX_EPOCH + Duration::from_secs(now_epoch_i64 as u64));
    assert!(
        report.dreaming_fired,
        "dreaming must fire on first tick (3 co-recall windows enqueued)"
    );

    // ── Assert at least one Think event was emitted ───────────────────────────
    // Think events are emitted once per proposal. With 3 enqueued windows and
    // reward=1.0, at least one pair clears both the min_confidence and min_attempts
    // gates in DreamingDecision.decide and becomes a proposal.
    let events = sink.event_samples_for_estate(&estate_str);
    assert!(
        !events.is_empty(),
        "dreaming pump must emit at least one StatSample::Event for estate {}; got 0 \
         (verify that 3 external-origin recalls were enqueued above — removing them \
         returns 0 events, which is the correct v2 no-queue sentinel)",
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
    let (pool_dir, artifact) = hermetic_pool_paths();
    let mut governor = AutonomicGovernor::new_for_testing_with_pool(
        coord, handle, store, 0, None, 0, pool_dir, artifact);

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
    let (pool_dir, artifact) = hermetic_pool_paths();
    let mut governor = AutonomicGovernor::new_for_testing_with_pool(
        coord, handle, store, 300_000, None, 0, pool_dir, artifact);

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
    let sink: Box<dyn GovernorTopologySink> =
        Box::new(StatsStoreTopologySink::new(Arc::clone(&stats_store_arc)));
    let (pool_dir, artifact) = hermetic_pool_paths();
    let mut governor = AutonomicGovernor::new_for_testing_with_pool(
        coord,
        handle,
        drawer_store,
        0,
        Some(sink),
        0,
        pool_dir,
        artifact,
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

    let sink: Box<dyn GovernorTopologySink> =
        Box::new(StatsStoreTopologySink::new(Arc::clone(&stats_store_arc)));
    let (pool_dir, artifact) = hermetic_pool_paths();
    let mut governor = AutonomicGovernor::new_for_testing_with_pool(
        coord, handle, drawer_store, 0, Some(sink), 0, pool_dir, artifact);

    // Fresh stores default ON since Wave 8.1. Exercise the authoritative
    // operator-off state explicitly: the duty must not write.
    stats_store_arc.set_monitoring_enabled(false).expect("disable monitoring");
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

    let sink: Box<dyn GovernorTopologySink> =
        Box::new(StatsStoreTopologySink::new(Arc::clone(&stats_store_arc)));
    let (pool_dir, artifact) = hermetic_pool_paths();
    let mut governor = AutonomicGovernor::new_for_testing_with_pool(
        coord, handle, drawer_store, 0, Some(sink), 0, pool_dir, artifact);

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

/// AG-15b: F5 — the stable fingerprint IS persisted (in its own column, so a
/// restarting governor can skip the recompute), but it must NOT leak into the
/// served topology JSON payload, which moot-mgr renders verbatim. Two things:
///   1. The fingerprint is persisted and loadable (`load_topology_fingerprint`).
///   2. The served payload is the topology wire shape only — no token fields.
/// Mirrors Swift `topologyPayloadExcludesTokenFieldsButFingerprintIsDelivered`.
#[test]
fn ag15b_fingerprint_persisted_but_excluded_from_payload() {
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

    let sink: Box<dyn GovernorTopologySink> =
        Box::new(StatsStoreTopologySink::new(Arc::clone(&stats_store_arc)));
    let (pool_dir, artifact) = hermetic_pool_paths();
    let mut governor = AutonomicGovernor::new_for_testing_with_pool(
        coord, handle, drawer_store, 0, Some(sink), 0, pool_dir, artifact);

    let _ = governor.tick(UNIX_EPOCH + Duration::from_secs(15_000_000));
    let payload = stats_store_arc
        .latest_topology_snapshot(Some(&estate_id))
        .expect("read must not error")
        .expect("snapshot present");

    // (1) The fingerprint is persisted for the post-restart skip.
    let fingerprint = stats_store_arc
        .load_topology_fingerprint(&estate_id)
        .expect("load must not error")
        .expect("a fingerprint must be persisted alongside the snapshot");
    assert!(!fingerprint.is_empty(), "persisted fingerprint must be non-empty");

    // (2) The served payload is the topology wire shape only — no token fields,
    // and the fingerprint travels as a separate column, not embedded in the JSON.
    assert!(!payload.contains("inputs_digest"),
            "token field name (rust) must not appear in served payload");
    assert!(!payload.contains("inputsDigest"),
            "token field name (swift wire) must not appear in served payload");
    assert!(!payload.contains(&fingerprint),
            "fingerprint must travel as a separate column, not embedded in the payload JSON");
    // What SHOULD be there: the topology snapshot wire shape.
    assert!(payload.contains("structurePending"),
            "served payload must be the topology snapshot");
}

/// AG-15c: F5 — a FRESH governor (simulating a process restart) loads the
/// persisted fingerprint on its first duty and skips the recompute when the
/// estate is unchanged. Proves the persist→load→skip chain holds across the
/// governor's in-memory state boundary, not just within one governor instance.
#[test]
fn ag15c_restart_loads_fingerprint_and_skips_recompute() {
    use uuid::Uuid;
    use observer_sink::StatsStore;

    // One shared store across both governor "lifetimes".
    let store = StatsStore::new(":memory:").expect("in-memory stats store must open");
    store.open().expect("store.open must succeed");
    let stats_store_arc = Arc::new(store);
    stats_store_arc.set_monitoring_enabled(true).expect("enable monitoring");

    let registry = EstateRegistry::new_inmemory();
    let coord = Arc::clone(&registry.coord);
    let handle = registry.default.handle;
    let estate_id = Uuid::from_bytes(handle.estate_uuid).to_string();
    let drawer_store = Arc::clone(&registry.default.store);

    // First "process": governor writes a snapshot + persists the fingerprint.
    {
        let sink: Box<dyn GovernorTopologySink> =
            Box::new(StatsStoreTopologySink::new(Arc::clone(&stats_store_arc)));
        let (pool_dir, artifact) = hermetic_pool_paths();
        let mut governor = AutonomicGovernor::new_for_testing_with_pool(
            Arc::clone(&coord), handle, Arc::clone(&drawer_store), 0, Some(sink), 0, pool_dir, artifact);
        let _ = governor.tick(UNIX_EPOCH + Duration::from_secs(16_000_000));
    }
    let first = stats_store_arc
        .latest_topology_snapshot(Some(&estate_id))
        .expect("read must not error")
        .expect("first snapshot present");

    // Second "process": a brand-new governor (no in-memory fingerprint) opens on
    // the same store + unchanged estate. Its first duty loads the persisted
    // fingerprint, finds it matches, and skips the write — generatedTs unchanged.
    {
        let sink: Box<dyn GovernorTopologySink> =
            Box::new(StatsStoreTopologySink::new(Arc::clone(&stats_store_arc)));
        let (pool_dir, artifact) = hermetic_pool_paths();
        let mut governor = AutonomicGovernor::new_for_testing_with_pool(
            coord, handle, drawer_store, 0, Some(sink), 0, pool_dir, artifact);
        let _ = governor.tick(UNIX_EPOCH + Duration::from_secs(16_000_600));
    }
    let second = stats_store_arc
        .latest_topology_snapshot(Some(&estate_id))
        .expect("read must not error")
        .expect("snapshot still present");

    assert_eq!(first, second,
               "restart with unchanged estate must skip recompute (loaded fingerprint matched)");
}

// MARK: - §7 Encode drain — production wiring (parity gap fix)
//
// Force-tests that regular-mode captures become BM25/vector indexed in
// production. The encode pipeline lives in CorpusKit now (a Corpus self-drains
// via its own background worker); these tests drive it to completion with the
// await_encode_drain barrier. Swift parity: the Corpus drain worker.
//
// Test list:
//   AG-16: regular capture + drain → BM25 recall FINDS the drawer
//   AG-17: impatient mode unchanged — still inline-indexed, no drain wait
//   AG-19: multiple regular captures all searchable after the drain

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

/// AG-16: Regular-mode capture → drain → BM25 recall finds the drawer.
///
/// This is the load-bearing test for the dual-path intake: a regular
/// `moot_file_memory` (default mode) enqueues the drawer onto the Corpus ingest
/// queue, and once the Corpus drain worker has ingested it (awaited here via
/// await_encode_drain) the drawer becomes BM25/vector searchable. The encode
/// pipeline lives in CorpusKit (a Corpus self-drains); both ports run the same
/// foreground drain worker on a ~15 ms poll cadence.
#[test]
fn ag16_regular_capture_becomes_bm25_searchable_after_drain() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    // Regular (non-impatient) capture — enqueues a job to the encode queue.
    // The drawer is stored but NOT yet BM25/vector indexed at this point.
    let capture_result = dispatch_tool(
        "moot_file_memory",
        &args!["content" => "flamingo wades through brackish water estuary",
               "subject" => "Flamingo wades through brackish estuary water.",
               "location" => "memories/birds"],
        &registry,
        &ledger,
    ).expect("moot_file_memory must succeed");
    assert!(is_success(&capture_result), "regular capture should succeed; got: {capture_result:?}");

    // Without a governor tick the search would find the drawer via the Locus
    // structured lane only (not BM25). We don't assert the pre-tick state here;
    // the important proof is AFTER the tick.

    // Drain the Corpus ingest queue to completion. The encode pipeline lives in
    // CorpusKit now — a Corpus self-drains via its own background worker;
    // await_encode_drain pumps it to empty and confirms both frontiers clear,
    // the deterministic barrier that replaced the old governor-tick drain (the
    // governor no longer pumps the encode queue).
    {
        let handle = registry.default.handle;
        registry
            .coord
            .lock()
            .expect("coordinator lock")
            .await_encode_drain(&handle)
            .expect("await_encode_drain");
    }

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
               "subject" => "Avocet probes mud at low tide.",
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

/// AG-19: Multiple regular captures all become searchable after the drain.
///
/// Captures two drawers via regular mode (both enqueued onto the Corpus ingest
/// queue), drains to completion via await_encode_drain (the Corpus self-drains —
/// CorpusKit owns the encode pipeline), and asserts both are BM25 searchable.
#[test]
fn ag19_two_regular_captures_both_searchable_after_drain() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    // Capture two drawers via regular mode — both enqueued.
    dispatch_tool(
        "moot_file_memory",
        &args!["content" => "spoonbill sweeps bill through water feeding",
               "subject" => "Spoonbill sweeps bill through water while feeding.",
               "location" => "memories/birds"],
        &registry, &ledger,
    ).expect("capture 1 must succeed");

    dispatch_tool(
        "moot_file_memory",
        &args!["content" => "ibis probes soil with curved beak savanna",
               "subject" => "Ibis probes savanna soil with curved beak.",
               "location" => "memories/birds"],
        &registry, &ledger,
    ).expect("capture 2 must succeed");

    // Drain the Corpus ingest queue to completion (deterministic barrier).
    {
        let handle = registry.default.handle;
        registry
            .coord
            .lock()
            .expect("coordinator lock")
            .await_encode_drain(&handle)
            .expect("await_encode_drain");
    }

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
        "spoonbill must be BM25 searchable after the drain; got: {t1}"
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
        "ibis must be BM25 searchable after the drain; got: {t2}"
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
