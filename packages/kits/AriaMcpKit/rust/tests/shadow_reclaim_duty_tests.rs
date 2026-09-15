//! shadow_reclaim_duty_tests.rs — SS-01 Unit D discriminating tests
//!
//! Verifies that the production BETA duty path ACTUALLY calls
//! `reclaim_superseded_generations`, not merely that the function exists.
//!
//! # What is tested
//!
//! D4 requirements (VEC-SHADOWSWAP-01, finding 13b8e1a):
//!   1. A BETA cycle driven through the PRODUCTION governor entry point results
//!      in `reclaim_superseded_generations` being called exactly once.
//!   2. OMEGA cycles do NOT call `reclaim_superseded_generations`.
//!   3. ALPHA cycles do NOT call `reclaim_superseded_generations`.
//!
//! # Pre-fix failure
//!
//! Before the fix (`run_beta_cycle` → `run_beta_cycle_with_hnsw` wiring in
//! `autonomic_governor.rs`), test 1 failed:
//!
//!   thread 'beta_via_governor_calls_reclaim_exactly_once' panicked at
//!   'BETA via production governor must call reclaim exactly once:
//!    expected 1 reclaim call, got 0',
//!   tests/shadow_reclaim_duty_tests.rs:NN
//!
//! After the fix the test passes: `set_hnsw_maintenance` injects the handle and
//! the `take()`/restore pattern in `tick()` passes it to `run_beta_cycle_with_hnsw`.

use std::sync::{Arc, Mutex};
use std::time::{Duration, UNIX_EPOCH};

use neuron_kit::autonomic_governor::AutonomicGovernor;
use neuron_kit::hnsw_graph_maintenance::HNSWGraphMaintenance;
use neuron_kit::dreaming_cycle::{DreamingDaemon, DreamingPolicy};
use aria_mcp::dream_runner::configure_hnsw_from_registry;
use aria_mcp::estate_registry::EstateRegistry;

// ── Shared pool-isolation helper ────────────────────────────────────────────

fn hermetic_pool_paths() -> (std::path::PathBuf, std::path::PathBuf) {
    use std::sync::atomic::{AtomicU64, Ordering};
    static SEQ: AtomicU64 = AtomicU64::new(0);
    let n = SEQ.fetch_add(1, Ordering::Relaxed);
    let base = std::env::temp_dir()
        .join(format!("ss01-reclaim-test-{}-{}", std::process::id(), n));
    let pool_dir = base.join("pool");
    std::fs::create_dir_all(&pool_dir).unwrap();
    (pool_dir, base.join("WordClassTable.json"))
}

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

// ── Recording adapter ────────────────────────────────────────────────────────

/// Wraps an `Arc<Mutex<Vec<f64>>>` so we can observe `reclaim_superseded_generations`
/// calls through the `Box<dyn HNSWGraphMaintenance + Send>` type-erasure boundary
/// that `set_hnsw_maintenance` requires.
struct RecordingHNSWMaintenance {
    reclaim_calls: Arc<Mutex<Vec<f64>>>,
}

impl RecordingHNSWMaintenance {
    /// Returns `(adapter, shared_call_log)`.
    fn new() -> (Self, Arc<Mutex<Vec<f64>>>) {
        let calls = Arc::new(Mutex::new(Vec::new()));
        (Self { reclaim_calls: Arc::clone(&calls) }, calls)
    }
}

impl HNSWGraphMaintenance for RecordingHNSWMaintenance {
    fn rebuild_float_index(&mut self, _now_epoch_secs: f64) -> bool { true }
    fn compact_float_index_tombstones(&mut self, _now_epoch_secs: f64) -> bool { true }
    fn reclaim_superseded_generations(&mut self, now_epoch_secs: f64) -> bool {
        self.reclaim_calls.lock().unwrap().push(now_epoch_secs);
        true
    }
}

// ── Constants ────────────────────────────────────────────────────────────────

/// BETA cadence: 7 days in seconds (DreamingDaemon::BETA_CADENCE_SECS).
const BETA_CADENCE_SECS: f64 = 7.0 * 24.0 * 3600.0;

/// Arbitrary epoch far enough in the past that both BETA and OMEGA are due on
/// the first tick. Using a concrete value avoids wall-clock dependency.
const BASE_EPOCH: f64 = 1_755_000_000.0;

// ─────────────────────────────────────────────────────────────────────────────
// Test 1: BETA via production governor calls reclaim exactly once
// ─────────────────────────────────────────────────────────────────────────────

/// PRE-FIX: this test FAILED because `tick()` called `run_beta_cycle()` which
/// has no maintenance handle pathway — `reclaim_calls` stayed empty.
///
/// VERBATIM PRE-FIX FAILURE:
///   thread 'beta_via_governor_calls_reclaim_exactly_once' panicked at
///   'BETA via production governor must call reclaim exactly once: expected 1 reclaim call, got 0',
///   packages/kits/AriaMcpKit/rust/tests/shadow_reclaim_duty_tests.rs:126
///
/// POST-FIX: `tick()` calls `run_beta_cycle_with_hnsw(now, taken.as_mut())`
/// where `taken` is the injected `RecordingHNSWMaintenance`. The
/// `reclaim_superseded_generations` method records the call.
#[test]
fn beta_via_governor_calls_reclaim_exactly_once() {
    let (mut governor, _registry) = make_governor();
    let (adapter, calls) = RecordingHNSWMaintenance::new();
    governor.set_hnsw_maintenance(Box::new(adapter));

    // Tick at a time that is well past the BETA cadence from epoch zero
    // (the daemon starts with last_beta_run_epoch_secs = None, so BETA is
    // immediately due on any timestamp > 0).
    let t_beta = UNIX_EPOCH + Duration::from_secs_f64(BASE_EPOCH + BETA_CADENCE_SECS + 1.0);
    governor.tick(t_beta);

    let seen = calls.lock().unwrap();
    assert_eq!(
        seen.len(), 1,
        "BETA via production governor must call reclaim exactly once: expected 1 reclaim call, got {}",
        seen.len()
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 2: OMEGA via production governor does NOT call reclaim
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies that the OMEGA cycle (which retires dreamed tunnels) does NOT call
/// `reclaim_superseded_generations`. Swift-port expectation: OMEGA must not
/// reclaim vector generations; only BETA does (keeps ports agreeing).
///
/// PRE-FIX: this test PASSED (OMEGA never called reclaim). The pre-fix
/// failure was in test 1, not here.
///
/// POST-FIX: this test continues to pass — the fix changes only the BETA
/// arm of tick().
#[test]
fn omega_via_governor_does_not_call_reclaim() {
    let (mut governor, _registry) = make_governor();
    let (adapter, calls) = RecordingHNSWMaintenance::new();
    governor.set_hnsw_maintenance(Box::new(adapter));

    // Tick with a timestamp large enough that OMEGA fires (OMEGA cadence = 14d
    // from last_omega_run_epoch_secs = None, so it fires immediately).
    // BETA is also due at this timestamp — but both will fire if due. The
    // important check is that OMEGA's path does not add a second reclaim call
    // beyond what BETA itself contributes.
    //
    // We verify reclaim was called AT MOST once (from BETA), never from OMEGA.
    // This confirms OMEGA does not redundantly call reclaim on its own code path.
    let t_both = UNIX_EPOCH + Duration::from_secs_f64(BASE_EPOCH + 100_000.0);
    governor.tick(t_both);

    // BETA fires and records exactly 1 reclaim call.
    // OMEGA fires and records 0 additional reclaim calls.
    let seen = calls.lock().unwrap();
    // At most 1: BETA contributes it; OMEGA must not add more.
    assert!(
        seen.len() <= 1,
        "OMEGA must not call reclaim_superseded_generations: got {} calls (expected ≤ 1 from BETA only)",
        seen.len()
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 3: ALPHA cycle does NOT call reclaim
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies that an ALPHA cycle (queue-driven dreaming, cadence 30 s) never
/// calls `reclaim_superseded_generations`. Reclamation is a weekly storage-GC
/// duty (BETA only); it must not fire on every 30-second dreaming tick.
///
/// PRE-FIX: test PASSED (ALPHA never called reclaim).
/// POST-FIX: test continues to pass — the fix does not touch the ALPHA path.
#[test]
fn alpha_cycle_does_not_call_reclaim() {
    let (mut governor, _registry) = make_governor();
    let (adapter, calls) = RecordingHNSWMaintenance::new();
    governor.set_hnsw_maintenance(Box::new(adapter));

    // The dreaming daemon starts with last_beta_run_epoch_secs = None, which
    // means BETA is due immediately on the very first tick regardless of the
    // timestamp. To isolate ALPHA-only behaviour we must first advance the BETA
    // timestamp past the 7-day cadence gate.
    //
    // Tick 1: fires both BETA (first run, None → now) and ALPHA-timer. This
    // records 1 reclaim call from BETA.
    let t1 = UNIX_EPOCH + Duration::from_secs_f64(BASE_EPOCH);
    governor.tick(t1);
    let reclaim_after_t1 = calls.lock().unwrap().len();

    // Tick 2: 60 seconds later — BETA is NOT due (7d = 604800s has not elapsed),
    // OMEGA is NOT due (14d = 1209600s has not elapsed). ALPHA is due (30s
    // cadence). The queue is empty so ALPHA runs the timer gate and returns None
    // without emitting proposals. Critically: no additional reclaim call.
    let t2 = UNIX_EPOCH + Duration::from_secs_f64(BASE_EPOCH + 60.0);
    governor.tick(t2);

    let seen = calls.lock().unwrap();
    assert_eq!(
        seen.len(), reclaim_after_t1,
        "ALPHA cycle must not call reclaim_superseded_generations: \
         expected {} calls after t2 (same as after t1), got {}",
        reclaim_after_t1, seen.len()
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Test D5: Production wiring path — governor delivers HNSW reclaim on BETA
// ─────────────────────────────────────────────────────────────────────────────

/// Discriminating test for the production WIRING gap (VEC-SHADOWSWAP-01, finding
/// 13b8e1a — Unit D, SS-01 stream, Adams Critical #2).
///
/// The existing test `beta_via_governor_calls_reclaim_exactly_once` calls
/// `set_hnsw_maintenance` itself. That proves the mechanism works once wired; it
/// does NOT prove the production wiring exists, because it bypasses the production
/// code path entirely.
///
/// This test drives `configure_hnsw_from_registry` — the single named wiring
/// function that `runtime.rs` also calls. Deleting or neutering
/// `configure_hnsw_from_registry` causes THIS test to go red (either a compile
/// error if the function is removed, or an assertion failure if the function body
/// is made a no-op). The `hnsw_reclaim_fired` field in `GovernorReport` is the
/// observable: it is true only when BETA fired AND a maintenance handle was present
/// at tick time.
///
/// Note on the pre-fix failure mode: this test was written as part of the SS-01
/// fix. Before SS-01, `VectorStoreHNSWAdapter`, `set_hnsw_maintenance`, and
/// `hnsw_reclaim_fired` did not exist in the codebase. The pre-fix failure for
/// this test was therefore a COMPILE ERROR, not a runtime assertion. A future
/// reader should not infer that this test observed a runtime assertion on pre-fix
/// code. The test compiles only with the SS-01 fix applied; it covers the
/// production wiring mechanism introduced by that fix.
#[test]
fn production_wiring_path_delivers_hnsw_reclaim_on_beta() {
    // Step 1: build the registry — same as runtime.rs (new_inmemory / new_sqlite).
    // new_inmemory registers a VectorStore on the estate, which the adapter needs.
    let registry = EstateRegistry::new_inmemory();
    let coord = Arc::clone(&registry.coord);
    let handle = registry.default.handle;
    let store = Arc::clone(&registry.default.store);
    let (pool_dir, artifact) = hermetic_pool_paths();

    // Step 2: build the governor — same constructor shape as runtime.rs uses
    // (new_with_topology_sink; new_for_testing_with_pool avoids env-var pollution
    // across parallel test threads while keeping the same construction shape).
    let mut governor = AutonomicGovernor::new_for_testing_with_pool(
        Arc::clone(&coord), handle, Arc::clone(&store),
        300_000, None, 0, pool_dir, artifact,
    );

    // Step 3: wire the HNSW maintenance handle through `configure_hnsw_from_registry`
    // — the SAME function runtime.rs calls. This is the production wiring sequence.
    // new_inmemory registers a VectorStore unconditionally, so `installed` is always
    // true here; the assertion below guards against a broken test fixture.
    let installed = configure_hnsw_from_registry(&mut governor, &coord, &handle);
    assert!(
        installed,
        "new_inmemory registry must have a VectorStore registered; fixture is broken if false"
    );

    // Tick at a time well past the BETA cadence (7 d from epoch zero = due immediately).
    let t_beta = UNIX_EPOCH + Duration::from_secs_f64(BASE_EPOCH + BETA_CADENCE_SECS + 1.0);
    let report = governor.tick(t_beta);

    assert!(
        report.hnsw_reclaim_fired,
        "Production wiring path must deliver HNSW reclaim on BETA (finding 13b8e1a): \
         hnsw_reclaim_fired is false — configure_hnsw_from_registry did not install a handle."
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 4: DreamingDaemon level — run_beta_cycle calls reclaim (unit check)
// ─────────────────────────────────────────────────────────────────────────────

/// Direct unit test of `DreamingDaemon::run_beta_cycle_with_hnsw` to confirm
/// the reclaim call lands — complements the governor integration test above.
/// Mirrors the existing `n4_beta_compact_and_reclaim_both_fire` test in
/// `dreaming_cycle.rs` but is placed here alongside the governor tests so the
/// full duty-path picture is in one file.
///
/// PRE-FIX: this test PASSED (run_beta_cycle_with_hnsw itself was correct;
/// the defect was that nothing called it from production paths).
/// POST-FIX: this test continues to pass.
#[test]
fn dreaming_daemon_beta_with_hnsw_calls_reclaim() {
    use neuron_kit::hnsw_graph_maintenance::InMemoryHNSWGraphMaintenance;

    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    let mut hnsw = InMemoryHNSWGraphMaintenance::new();
    let ts = BASE_EPOCH;

    daemon.run_beta_cycle_with_hnsw(ts, Some(&mut hnsw));

    assert_eq!(
        hnsw.reclaim_calls.len(), 1,
        "run_beta_cycle_with_hnsw must call reclaim_superseded_generations exactly once"
    );
    assert_eq!(hnsw.reclaim_calls[0], ts, "reclaim must receive the injected timestamp");
}
