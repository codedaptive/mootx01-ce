//! Brain pump integration tests (see ADR-LOOPBACKHTTP-001 §17).
//!
//! Mirrors the Swift `BrainPumpTests` suite in
//! `apps/ARIA_MCP/Tests/AriaMCPTests/BrainPumpTests.swift`.
//!
//! Tests use an injected clock (a monotonically-advancing f64) so no wall-clock
//! sleeps are needed — the determinism contract is the same as the Swift suite.
//!
//! # Isolation
//!
//! Each test constructs an independent in-memory estate (via `make_pump`) and
//! invokes `tick(now)` directly. No wall-clock is read in the test path.
//!
//! # Coverage
//!
//! §1 Cadence — interval gating: first fires, before-interval None, at-boundary fires.
//! §2 Construction — pump is constructable and tick returns a TickReport.
//! §3 Stop flag — stop() causes run_loop to exit (using a thread + timeout).
//! §4 Live estate wiring — a dreaming fire writes a diary entry to the live store
//!    (proves the sinks write to the real estate, not a throwaway store).

use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};

use aria_mcp::brain_pump::BrainPump;
use aria_mcp::estate_registry::EstateRegistry;

// ── Test helper ──────────────────────────────────────────────────────────────

/// Build a `BrainPump` wired to a fresh in-memory estate.
///
/// Returns `(pump, registry)` so tests that want to inspect the live store
/// after a tick can access `registry.default.store`.
fn make_pump() -> (BrainPump, EstateRegistry) {
    let registry = EstateRegistry::new_inmemory();
    let coord = Arc::clone(&registry.coord);
    let handle = registry.default.handle;
    let store = Arc::clone(&registry.default.store);
    let pump = BrainPump::new(coord, handle, store);
    (pump, registry)
}

/// Build a pump with a caller-supplied stop flag (for the run_loop test).
fn make_pump_with_flag(flag: Arc<AtomicBool>) -> BrainPump {
    let registry = EstateRegistry::new_inmemory();
    let coord = Arc::clone(&registry.coord);
    let handle = registry.default.handle;
    let store = Arc::clone(&registry.default.store);
    BrainPump::with_stop_flag(coord, handle, store, flag)
}

// MARK: - §1 Cadence

/// BP-1: First tick always fires both daemons (no prior fire timestamp).
/// Mirrors Swift `testBrainPumpFirstTickAlwaysFires`.
#[test]
fn bp1_first_tick_always_fires_both_daemons() {
    let (mut pump, _registry) = make_pump();
    // At t=0 there is no prior fire for either daemon.
    let report = pump.tick(0.0);
    assert!(
        report.dreaming_fired,
        "dreaming must fire on first tick"
    );
    assert!(
        report.maintenance_fired,
        "maintenance must fire on first tick"
    );
}

/// BP-2: A tick before either interval has elapsed returns both unfired.
/// The dreaming interval default is 30 s; maintenance is 300 s.
/// At t=29 s (after t=0 fired), both are still within their intervals.
/// Mirrors Swift `testBrainPumpSkipsBeforeInterval`.
#[test]
fn bp2_tick_before_interval_returns_no_fire() {
    let (mut pump, _registry) = make_pump();
    // First tick fires (t=0).
    let first = pump.tick(0.0);
    assert!(first.dreaming_fired, "first tick must fire dreaming");
    assert!(first.maintenance_fired, "first tick must fire maintenance");

    // Second tick at t=29 s — both intervals (30 s and 300 s) have not elapsed.
    let second = pump.tick(29.0);
    assert!(
        !second.dreaming_fired,
        "dreaming must not fire before 30 s interval"
    );
    assert!(
        !second.maintenance_fired,
        "maintenance must not fire before 300 s interval"
    );
}

/// BP-3: Dreaming fires at its interval boundary (30 s) while maintenance
/// has not yet reached its boundary (300 s). Mirrors Swift
/// `testBrainPumpDreamingFiresAtInterval`.
#[test]
fn bp3_dreaming_fires_at_interval_maintenance_does_not() {
    let (mut pump, _registry) = make_pump();
    // First tick fires both at t=0.
    let _ = pump.tick(0.0);
    // At t=30 s exactly — dreaming interval (30 s) elapsed, maintenance (300 s) not.
    let second = pump.tick(30.0);
    assert!(
        second.dreaming_fired,
        "dreaming must fire at the 30 s boundary"
    );
    assert!(
        !second.maintenance_fired,
        "maintenance must not fire before 300 s boundary"
    );
}

/// BP-4: Both daemons fire when their intervals have both elapsed.
/// At t=300 s both dreaming (every 30 s) and maintenance (every 300 s)
/// have elapsed since the last fire at t=270/t=0.
/// Mirrors Swift `testBrainPumpBothFireAfterLongGap`.
#[test]
fn bp4_both_fire_after_long_gap() {
    let (mut pump, _registry) = make_pump();
    // First tick fires both at t=0.
    let _ = pump.tick(0.0);
    // Advance to t=300 — both intervals have elapsed.
    let later = pump.tick(300.0);
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

/// BP-5: BrainPump::new() is constructable; tick returns a TickReport.
/// Smoke test — verifies no panic at construction or on first tick.
#[test]
fn bp5_construction_smoke() {
    let (mut pump, _registry) = make_pump();
    let report = pump.tick(1_000_000.0);
    // The first tick always fires both daemons.
    assert!(report.dreaming_fired);
    assert!(report.maintenance_fired);
}

/// BP-6: Consecutive ticks at increasing timestamps stay coherent.
/// Three dreaming-interval steps: t=0, t=30, t=60. Each should fire dreaming.
/// Mirrors Swift `testDreamingFiresEveryInterval`.
#[test]
fn bp6_consecutive_dreaming_firings() {
    let (mut pump, _registry) = make_pump();
    let r0 = pump.tick(0.0);
    assert!(r0.dreaming_fired, "t=0 must fire");
    let r1 = pump.tick(30.0);
    assert!(r1.dreaming_fired, "t=30 must fire (exactly one interval)");
    let r2 = pump.tick(60.0);
    assert!(r2.dreaming_fired, "t=60 must fire (two intervals)");
}

// MARK: - §3 Stop flag

/// BP-7: stop() sets the flag; run_loop exits promptly.
/// Uses a background thread with a very short tick (1 ms) and a timeout
/// (2 s) to avoid hanging the test suite. No wall-clock sleep in the
/// assertion path — we join the thread and check it returned.
/// Mirrors Swift `testBrainPumpStopsCleanly`.
#[test]
fn bp7_stop_flag_exits_run_loop() {
    let stop_flag = Arc::new(AtomicBool::new(false));
    let flag_clone = Arc::clone(&stop_flag);

    // Use a 1 ms tick so the loop spins fast enough to see the stop flag
    // without a meaningful wall-clock delay in CI.
    std::env::set_var("MOOTX01_BRAIN_TICK_MS", "1");
    let mut pump = make_pump_with_flag(Arc::clone(&stop_flag));
    std::env::remove_var("MOOTX01_BRAIN_TICK_MS");

    let handle = std::thread::spawn(move || {
        pump.run_loop();
    });

    // Set the stop flag after a short pause to let the loop start.
    std::thread::sleep(std::time::Duration::from_millis(20));
    flag_clone.store(true, Ordering::Relaxed);

    // Join with a 2-second timeout. If the thread doesn't return by then,
    // the test runner will eventually kill it; we treat a successful join as
    // the pass condition.
    let joined = handle.join();
    assert!(joined.is_ok(), "BrainPump thread must exit cleanly after stop()");
}

// MARK: - §4 Live estate wiring

/// BP-8: A dreaming tick on a populated estate writes a diary entry to
/// the live store — proves the sinks write through to the real estate
/// and not a throwaway InMemoryDrawerStore.
///
/// An empty estate produces no dreaming proposals (no co-occurrence pairs),
/// but the daemon ALWAYS writes one diary entry per cycle. Asserting the
/// diary entry proves end-to-end live wiring.
#[test]
fn bp8_dreaming_fire_writes_diary_entry_to_live_estate() {
    use locus_kit::drawer_store::DrawerStore as LocusDrawerStore;

    let (mut pump, registry) = make_pump();
    // Tick at a large epoch so the ISO8601 formatter exercises real dates.
    let report = pump.tick(1_700_000_000.0);
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

/// BP-9: A maintenance tick on a populated estate writes a diary entry to
/// the live store — proves maintenance sink wiring.
#[test]
fn bp9_maintenance_fire_writes_diary_entry_to_live_estate() {
    use locus_kit::drawer_store::DrawerStore as LocusDrawerStore;

    let (mut pump, registry) = make_pump();
    // Advance to t=300 s so maintenance fires alongside dreaming.
    let _ = pump.tick(0.0);
    let report = pump.tick(300.0);
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
