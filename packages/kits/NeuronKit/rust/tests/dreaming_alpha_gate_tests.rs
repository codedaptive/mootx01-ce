//! REM-ALPHA pending-count gate tests.
//!
//! The §12.2 gate skips the dreaming cycle when the dreaming queue is empty
//! (or not yet mounted), EVEN when the timer interval is due. Only a non-empty
//! queue proceeds to the EstateDreamingReader snapshot + drain + decide path.
//!
//! Coverage:
//!   §1  POSITIVE:  dreaming queue has pending items AND timer due
//!                  → governor tick FIRES the dreaming cycle (dreaming_fired=true).
//!   §2  NEGATIVE:  dreaming queue EMPTY AND timer due
//!                  → governor tick does NOT fire (dreaming_fired=false).
//!                  This is the anti-regression: without the gate this tick
//!                  would run the reader + scan. The test MUST fail if the gate
//!                  is removed.
//!   §3  CADENCE:   dreaming queue has pending items BUT timer interval not
//!                  elapsed → governor tick does NOT fire (dreaming_fired=false).
//!
//! Infrastructure mirrors `dreaming_queue_drain_tests.rs`: live InMemoryDrawerStore
//! + EstateCoordinator, AutonomicGovernor::new_for_testing_with_pool (no pool
//! I/O, deterministic cadences).

use std::sync::{Arc, Mutex};
use std::time::{Duration, UNIX_EPOCH};

use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallScoring, RecallFallbackPolicy,
};
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store::DrawerStore as LocusDrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::filter::{Filter, RecallFrame};
use locus_kit::frames::CaptureFrame;
use neuron_kit::autonomic_governor::AutonomicGovernor;

// ── Infrastructure ─────────────────────────────────────────────────────────────

/// Shared estate setup: one in-memory DrawerStore, opened into coordinator.
/// Returns the coordinator Arc (shared with governor), the handle, and the raw
/// Arc<dyn DrawerStore> the governor needs for sink construction.
fn make_estate() -> (Arc<Mutex<EstateCoordinator>>, EstateHandle, Arc<dyn LocusDrawerStore>) {
    let store: Arc<dyn LocusDrawerStore> =
        Arc::new(InMemoryDrawerStore::new(0, None).expect("InMemoryDrawerStore::new"));
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(Arc::clone(&store), OwnerCredentials::new("alpha-gate-test"), 0, 100)
        .expect("coord.open");
    (Arc::new(Mutex::new(coord)), handle, store)
}

/// Capture a drawer into the estate via the coordinator.
fn capture_drawer(
    coord: &Arc<Mutex<EstateCoordinator>>,
    handle: &EstateHandle,
    content: &str,
    now: i64,
) {
    let frame = CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "test-room",
        LatticeAnchor::udc("000"),
        "alpha-gate-test",
        "no-embedding",
    );
    let c = coord.lock().unwrap();
    c.capture(handle, frame, now).expect("capture");
}

/// Fire one external-origin scored recall, which enqueues a DreamingItem
/// for the co-surfaced set (B-10a: enqueue fires ONLY on external origin).
fn fire_external_recall(
    coord: &Arc<Mutex<EstateCoordinator>>,
    handle: &EstateHandle,
    now: i64,
) {
    let req = GLKRecallRequest::new(RecallFrame::new(vec![Filter::Unconfirmed]))
        .with_mode(GLKRecallMode::LocusOnly)
        .with_scoring(GLKRecallScoring::Raw)
        .with_limit(50)
        .with_fallback(RecallFallbackPolicy::FailClosed)
        .external(); // B-10a boundary
    let c = coord.lock().unwrap();
    c.recall_scored(handle, req, now).expect("recall_scored");
}

/// Build an AutonomicGovernor configured for deterministic tests:
/// - topology_cadence_ms = u64::MAX (topology snapshot never fires — no sink)
/// - pool_reduce_cadence_ms = u64::MAX (no pool I/O in these tests)
/// - pool paths point to non-existent temp dirs (no filesystem touch)
fn make_governor(
    coord: Arc<Mutex<EstateCoordinator>>,
    handle: EstateHandle,
    store: Arc<dyn LocusDrawerStore>,
) -> AutonomicGovernor {
    // Disable pool reduce and topology duties so the tick is purely dreaming +
    // maintenance. Use paths that will never exist so a pool-reduce miss is a
    // no-op rather than an actual filesystem operation.
    let pool_dir = std::path::PathBuf::from("/tmp/alpha-gate-test-pool-NONEXISTENT");
    let pool_table = std::path::PathBuf::from("/tmp/alpha-gate-test-table-NONEXISTENT.bin");
    AutonomicGovernor::new_for_testing_with_pool(
        coord,
        handle,
        store,
        u64::MAX, // topology cadence: never
        None,     // no topology sink
        u64::MAX, // pool-reduce cadence: never
        pool_dir,
        pool_table,
    )
}

/// `SystemTime` at epoch + `secs` seconds. Used to feed deterministic `now`
/// into governor ticks without calling `SystemTime::now()`.
fn epoch_plus_secs(secs: u64) -> std::time::SystemTime {
    UNIX_EPOCH + Duration::from_secs(secs)
}

// ── §1 POSITIVE: pending > 0 AND timer due → dreaming_fired = true ─────────

/// Verify that the governor fires the dreaming cycle when:
///   (a) the dreaming queue has at least one pending item (≥1 external-origin recall fired),
///   (b) the timer interval (default 30 s) has elapsed.
///
/// This is the base case: recalls were made, the queue is loaded, the timer
/// is due — the cycle MUST run to drain the queue and process the co-recall set.
#[test]
fn t9_alpha_gate_positive_pending_and_timer_due_fires() {
    let (coord, handle, store) = make_estate();

    // Capture two drawers so they co-surface on external-origin recall.
    let t0: i64 = 1_000_000;
    capture_drawer(&coord, &handle, "REM-ALPHA content A", t0);
    capture_drawer(&coord, &handle, "REM-ALPHA content B", t0);

    // Fire one external-origin recall → one DreamingItem in the queue.
    // The pending count is now 1 (§12.2 gate will see Some(1) → proceed).
    fire_external_recall(&coord, &handle, t0);

    // Verify the item is in the queue before constructing the governor
    // (uses the test-seam accessor — not needed by production, just confirming
    // our test setup is correct).
    {
        let c = coord.lock().unwrap();
        let pending = c.dreaming_queue_pending_count_for_gate(&handle);
        assert_eq!(pending, Some(1), "setup: expected 1 pending dreaming item");
    }

    let mut gov = make_governor(Arc::clone(&coord), handle.clone(), Arc::clone(&store));

    // Tick at t=31 s — past the 30 s default dreaming interval.
    // Timer gate: due. Pending gate: Some(1) > 0. Both pass → cycle fires.
    let report = gov.tick(epoch_plus_secs(31));

    assert!(
        report.dreaming_fired,
        "§1 POSITIVE: pending items + timer due → dreaming_fired must be true"
    );
}

// ── §2 NEGATIVE: empty queue AND timer due → dreaming_fired = false ─────────

/// Verify that the governor does NOT fire the dreaming cycle when the dreaming
/// queue is empty — even when the timer interval has elapsed.
///
/// This is the anti-regression test: without the §12.2 pending-count gate,
/// the governor would build an EstateDreamingReader and run a scan here,
/// wasting work on an idle tick. The test MUST FAIL if the gate is removed.
///
/// Empty-queue scenario: no external-origin recall has fired for this estate,
/// so the dreaming queue is not mounted at all (None from the probe, which is
/// treated identically to Some(0) — skip).
#[test]
fn t9_alpha_gate_negative_empty_queue_timer_due_no_fire() {
    let (coord, handle, store) = make_estate();

    // Capture drawers but do NOT fire any external-origin recall.
    // The dreaming queue is never mounted → pending = None.
    let t0: i64 = 1_000_000;
    capture_drawer(&coord, &handle, "idle content A", t0);
    capture_drawer(&coord, &handle, "idle content B", t0);

    // Verify queue is not mounted (test-seam confirmation of setup).
    {
        let c = coord.lock().unwrap();
        let pending = c.dreaming_queue_pending_count_for_gate(&handle);
        assert_eq!(pending, None, "setup: expected queue not mounted (None)");
    }

    let mut gov = make_governor(Arc::clone(&coord), handle.clone(), Arc::clone(&store));

    // Tick at t=31 s — timer gate is DUE. But pending gate is None → skip.
    let report = gov.tick(epoch_plus_secs(31));

    assert!(
        !report.dreaming_fired,
        "§2 NEGATIVE: empty queue + timer due → dreaming_fired must be false \
         (the §12.2 gate must block the scan; this test fails if the gate is removed)"
    );
}

// ── §2b NEGATIVE: queue mounted but zero remaining → dreaming_fired = false ─

/// Verify the no-fire case when the queue WAS populated but was already fully
/// drained in a prior cycle. The governor sees Some(0) — also a skip.
///
/// After the first tick drains the queue, the second tick (timer due again)
/// must NOT re-fire the dreaming cycle (the drain-once semantics guarantee the
/// queue is empty).
#[test]
fn t9_alpha_gate_negative_drained_queue_second_tick_no_fire() {
    let (coord, handle, store) = make_estate();

    let t0: i64 = 1_000_000;
    capture_drawer(&coord, &handle, "drain-once content A", t0);
    capture_drawer(&coord, &handle, "drain-once content B", t0);

    // One external-origin recall → one DreamingItem.
    fire_external_recall(&coord, &handle, t0);

    let mut gov = make_governor(Arc::clone(&coord), handle.clone(), Arc::clone(&store));

    // First tick at t=31 s: timer due + queue non-empty → dreaming fires + drains.
    let first = gov.tick(epoch_plus_secs(31));
    assert!(
        first.dreaming_fired,
        "§2b setup: first tick (pending=1, timer due) must fire"
    );

    // After drain, the queue is empty. Second tick at t=62 s: timer due again,
    // but queue is empty (Some(0)) → pending gate blocks the cycle.
    let second = gov.tick(epoch_plus_secs(62));
    assert!(
        !second.dreaming_fired,
        "§2b NEGATIVE: drained queue + timer due on second tick → dreaming_fired must be false"
    );
}

// ── §3 CADENCE: timer-mode cadence gate + NK-2 event-mode pump_on_event wiring ──

/// Verify the cadence gate and NK-2 event-mode wiring together.
///
/// After the first dreaming cycle fires at t=0, the SolverBandit updates the
/// trigger mode based on the cycle's reward. If the bandit selects Timer mode,
/// the timer gate holds at t=10 s (10 s < 30 s interval, timer not due →
/// dreaming_fired = false). If the bandit selects Event or Hybrid mode, the
/// NK-2 pump_on_event path fires at t=10 s (pending > 0, threshold = 1 →
/// dreaming_fired = true) — this is CORRECT NK-2 behavior: event-mode estates
/// receive near-realtime cycles as observations accumulate, independent of the
/// timer cadence.
///
/// The test reads `gov.dreaming_trigger_mode()` after the first tick to determine
/// which assertion applies. Both paths are validated.
#[test]
fn t9_alpha_gate_cadence_timer_not_due_no_fire_despite_pending() {
    use neuron_kit::DreamingTriggerMode;

    let (coord, handle, store) = make_estate();

    let t0: i64 = 1_000_000;
    capture_drawer(&coord, &handle, "cadence content A", t0);
    capture_drawer(&coord, &handle, "cadence content B", t0);

    // Enqueue one dreaming item and fire at t=0 to SET the timer baseline.
    // The first tick always fires (None last_fire → true). After this tick
    // the dreaming queue is drained (empty) and the timer baseline is set at t=0.
    fire_external_recall(&coord, &handle, t0);

    let mut gov = make_governor(Arc::clone(&coord), handle.clone(), Arc::clone(&store));
    let first = gov.tick(epoch_plus_secs(0));
    // The first tick fires dreaming (first-tick-fires behaviour) and drains the queue.
    // The bandit may update trigger_mode after the cycle.
    let _ = first.dreaming_fired;

    // Read the bandit-selected trigger mode AFTER the first cycle.
    let mode_after_first_cycle = gov.dreaming_trigger_mode();

    // Now enqueue a SECOND item while the timer is NOT due yet.
    fire_external_recall(&coord, &handle, t0 + 5);

    {
        // Confirm the new item is pending.
        let c = coord.lock().unwrap();
        let pending = c.dreaming_queue_pending_count_for_gate(&handle);
        assert!(
            pending.is_some() && pending.unwrap() >= 1,
            "setup: expected ≥ 1 pending item after second enqueue, got {:?}", pending
        );
    }

    // Tick at t=10 s — BEFORE the 30 s interval.
    let report = gov.tick(epoch_plus_secs(10));

    match mode_after_first_cycle {
        DreamingTriggerMode::Timer => {
            // Timer mode: timer NOT due (10 s < 30 s), pump_on_event returns None →
            // dreaming_fired must be false. This is the classic cadence gate.
            assert!(
                !report.dreaming_fired,
                "§3 CADENCE (timer mode): pending > 0 but timer not due → dreaming_fired must be false"
            );
        }
        DreamingTriggerMode::Event | DreamingTriggerMode::Hybrid => {
            // Event / hybrid mode: pump_on_event fires when pending ≥ threshold (1).
            // Timer NOT due only blocks the timer path, not the event path.
            // This is correct NK-2 behavior: near-realtime dreaming for event estates.
            assert!(
                report.dreaming_fired,
                "§3 NK-2 (event/hybrid mode): pending > 0 → pump_on_event must fire → dreaming_fired = true"
            );
        }
    }
}
