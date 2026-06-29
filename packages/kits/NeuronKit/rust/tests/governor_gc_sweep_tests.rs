//! governor_gc_sweep_tests.rs — Mission #54 Part C:
//! AutonomicGovernor GC sweep cadence tests (Rust parity).
//!
//! Mirrors Swift's GovernorGCSweepTests.swift.
//!
//! Success criteria:
//!   1. First tick always fires the GC sweep (last_gc_sweep_secs is None at startup).
//!   2. Second tick does NOT fire when the interval hasn't elapsed (large interval).
//!   3. gcSweepIntervalMs = 0 causes sweep to fire on every tick.
//!
//! Uses an InMemory estate — no SQLite I/O, no real sweep side effect.
//! The tests verify GovernorReport.gc_sweep_fired (the cadence gate in tick()).

use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::handle::EstateHandle;
use locus_kit::drawer_store::DrawerStore as LocusDrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::OwnerCredentials;

use neuron_kit::autonomic_governor::AutonomicGovernor;

// ---------------------------------------------------------------------------
// Infrastructure
// ---------------------------------------------------------------------------

fn make_coordinator_and_handle() -> (Arc<Mutex<EstateCoordinator>>, EstateHandle) {
    let store: Arc<dyn LocusDrawerStore> =
        Arc::new(InMemoryDrawerStore::new(0, None).expect("store"));
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(store, OwnerCredentials::new("gc-sweep-test"), 0, 100)
        .expect("open");
    (Arc::new(Mutex::new(coord)), handle)
}

fn make_governor_with_gc_cadence(gc_cadence_ms: u64) -> AutonomicGovernor {
    let store: Arc<dyn LocusDrawerStore> =
        Arc::new(InMemoryDrawerStore::new(0, None).expect("store"));
    let (coord, handle) = make_coordinator_and_handle();

    let mut gov = AutonomicGovernor::new_for_testing_with_pool(
        coord,
        handle,
        store,
        u64::MAX,         // topology cadence so large it never fires
        None,             // no topology sink
        u64::MAX,         // pool reduce cadence — never fires
        std::path::PathBuf::from("/dev/null"),
        std::path::PathBuf::from("/dev/null"),
    );
    gov.set_gc_sweep_cadence_ms(gc_cadence_ms);
    gov
}

// ---------------------------------------------------------------------------
// 1. First tick always fires the GC sweep
// ---------------------------------------------------------------------------

/// First tick must fire gc_sweep regardless of cadence — last_gc_sweep_secs is
/// None at startup, so the check `elapsed >= cadence` is vacuously true.
#[test]
fn first_tick_always_fires_gc_sweep() {
    let mut gov = make_governor_with_gc_cadence(99_999_999);
    let t0 = SystemTime::now();
    let report = gov.tick(t0);
    assert!(
        report.gc_sweep_fired,
        "first tick must always fire the GC sweep regardless of cadence"
    );
}

// ---------------------------------------------------------------------------
// 2. Second tick does NOT fire when interval has not elapsed
// ---------------------------------------------------------------------------

/// With a large cadence, the second tick (0.1 ms after the first) must not
/// fire the GC sweep.
#[test]
fn second_tick_does_not_fire_before_interval_elapses() {
    let mut gov = make_governor_with_gc_cadence(99_000);
    let t0 = SystemTime::now();
    let t1 = t0 + Duration::from_micros(100);   // 0.1 ms after t0

    let _ = gov.tick(t0);        // first tick fires the sweep
    let report2 = gov.tick(t1);
    assert!(
        !report2.gc_sweep_fired,
        "sweep must not fire on second tick when cadence has not elapsed"
    );
}

// ---------------------------------------------------------------------------
// 3. Cadence = 0 fires every tick
// ---------------------------------------------------------------------------

/// When gc_sweep_cadence_ms = 0, every tick fires the sweep — the zero cadence
/// is the test knob for exercising the sweep path without waiting 30 s.
#[test]
fn zero_cadence_fires_every_tick() {
    let mut gov = make_governor_with_gc_cadence(0);
    let t0 = SystemTime::now();
    let t1 = t0 + Duration::from_micros(100);

    let report1 = gov.tick(t0);
    let report2 = gov.tick(t1);
    assert!(report1.gc_sweep_fired, "first tick must fire when cadence = 0");
    assert!(report2.gc_sweep_fired, "second tick must fire when cadence = 0");
}
