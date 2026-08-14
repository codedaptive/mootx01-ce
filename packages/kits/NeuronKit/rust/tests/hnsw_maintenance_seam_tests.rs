//! HNSW graph maintenance seam tests — VEC-HNSW-01 Rust parity.
//!
//! Guards the three `_with_hnsw` methods added to `DreamingDaemon` that wire
//! the HNSW maintenance operations into the ALPHA, THETA, and BETA dreaming
//! cadences. Mirrors the NeuronKit Swift tests for `HNSWGraphMaintenance`.
//!
//! Covered:
//!   ALPHA seam — `check_corpus_growth_with_hnsw` calls `clear_float_index`
//!     exactly once when vocabulary growth fires and reindex succeeds.
//!   ALPHA seam — no clear when reindex does not fire (baseline not exceeded).
//!   ALPHA seam — no clear when reindex fails (fail_all), no panic.
//!   ALPHA seam — None path is safe (hnsw=None behaves like base method).
//!   THETA seam — `run_theta_cycle_with_hook_and_hnsw` calls `rebuild_float_index`
//!     once per invocation regardless of retrain hook success.
//!   THETA seam — rebuild fires even with hook=None.
//!   THETA seam — None path is safe.
//!   BETA seam — `run_beta_cycle_with_hnsw` calls `compact_float_index_tombstones`
//!     once per invocation.
//!   BETA seam — compact fires even when consolidated map is empty.
//!   BETA seam — compact failure is non-fatal; base timestamp still advances.
//!   BETA seam — None path is safe.

use neuron_kit::dreaming_cycle::{
    DreamingDaemon, DreamingDiaryEntry, DreamingPolicy, InMemoryCorpusGrowthProbe,
    InMemoryThetaBasisRetrainHook, ProposeFrameOut, RecallTraceItem,
    DreamingProposalSink, DreamingSubstrateReader, TunnelLink,
};
use neuron_kit::hnsw_graph_maintenance::InMemoryHNSWGraphMaintenance;

// ─── Minimal fakes for THETA generic bounds ──────────────────────────────────

/// No-op reader: satisfies `DreamingSubstrateReader` with all-empty returns.
struct NoOpReader;

impl DreamingSubstrateReader for NoOpReader {
    fn recent_recall_traces(&self) -> Vec<RecallTraceItem> { vec![] }
    fn drain_dreaming_window(&self) -> Vec<Vec<String>> { vec![] }
    fn existing_tunnels(&self) -> Vec<TunnelLink> { vec![] }
}

/// No-op sink: satisfies `DreamingProposalSink` without recording anything.
struct NoOpSink;

impl DreamingProposalSink for NoOpSink {
    fn propose(&mut self, _: ProposeFrameOut) {}
    fn record_cycle_diary(&mut self, _: DreamingDiaryEntry) {}
    fn prune_recall_traces(&mut self, _: &str) {}
}

// ─── Constants ───────────────────────────────────────────────────────────────

const T0: f64 = 1_700_000_000.0;

// ─── Helper ──────────────────────────────────────────────────────────────────

/// A fresh daemon with a low reindex threshold (floor=5, fraction=0.0) so a
/// small vocabulary bump triggers the growth gate in ALPHA tests.
fn low_threshold_daemon() -> DreamingDaemon {
    let mut d = DreamingDaemon::new(DreamingPolicy::default());
    d.set_reindex_vocab_growth_floor(5);
    d.set_reindex_vocab_growth_fraction(0.0);
    d
}

// ─── ALPHA seam ──────────────────────────────────────────────────────────────

/// `check_corpus_growth_with_hnsw` calls `clear_float_index` when vocabulary
/// growth fires and reindex succeeds.
///
/// Mirrors Swift: ALPHA clears the HNSW graph after a successful corpus reindex
/// so the next `find_nearest_float` call lazily rebuilds from the fresh vectors.
#[test]
fn alpha_hnsw_clear_fires_when_reindex_succeeds() {
    let mut daemon = low_threshold_daemon();
    let mut hnsw = InMemoryHNSWGraphMaintenance::new();

    // First call establishes baseline (vocab=10). No reindex, no clear.
    let mut probe = InMemoryCorpusGrowthProbe::new(10);
    daemon.check_corpus_growth_with_hnsw(T0, &mut probe, Some(&mut hnsw));
    assert!(hnsw.clear_calls.is_empty(), "no clear on baseline establishment");

    // Second call: vocab grows above threshold (floor=5).
    probe.vocab = 16;
    daemon.check_corpus_growth_with_hnsw(T0 + 30.0, &mut probe, Some(&mut hnsw));

    assert_eq!(probe.reindex_calls.len(), 1, "reindex must fire once");
    assert_eq!(hnsw.clear_calls, vec![T0 + 30.0],
        "clear_float_index must fire with the cycle timestamp after successful reindex");
}

/// `check_corpus_growth_with_hnsw` does not call `clear_float_index` when the
/// growth gate does not fire (vocabulary is below the trigger threshold).
#[test]
fn alpha_hnsw_clear_does_not_fire_below_threshold() {
    let mut daemon = low_threshold_daemon();
    let mut hnsw = InMemoryHNSWGraphMaintenance::new();

    // Establish baseline at vocab=10.
    let mut probe = InMemoryCorpusGrowthProbe::new(10);
    daemon.check_corpus_growth_with_hnsw(T0, &mut probe, Some(&mut hnsw));

    // Vocab grows by only 3, below the floor of 5.
    probe.vocab = 13;
    daemon.check_corpus_growth_with_hnsw(T0 + 30.0, &mut probe, Some(&mut hnsw));

    assert!(probe.reindex_calls.is_empty(), "reindex must not fire below threshold");
    assert!(hnsw.clear_calls.is_empty(), "clear must not fire when reindex is skipped");
}

/// HNSW clear failure (`fail_all: true`) is non-fatal: no panic, reindex still
/// advances the baseline.
#[test]
fn alpha_hnsw_clear_failure_is_non_fatal() {
    let mut daemon = low_threshold_daemon();
    let mut hnsw = InMemoryHNSWGraphMaintenance::failing();

    let mut probe = InMemoryCorpusGrowthProbe::new(10);
    // Establish baseline.
    daemon.check_corpus_growth_with_hnsw(T0, &mut probe, Some(&mut hnsw));

    // Growth fires.
    probe.vocab = 16;
    daemon.check_corpus_growth_with_hnsw(T0 + 30.0, &mut probe, Some(&mut hnsw));

    // Reindex fired (baseline was advanced).
    assert_eq!(probe.reindex_calls.len(), 1, "reindex must fire");
    // Clear was attempted but failed silently — no panic, no clear_calls recorded.
    assert!(hnsw.clear_calls.is_empty(),
        "failing HNSW clear must not record a call (non-fatal)");
}

/// `check_corpus_growth_with_hnsw` with `hnsw: None` behaves identically to
/// `check_corpus_growth` (no HNSW side effect, no panic).
#[test]
fn alpha_hnsw_none_path_is_safe() {
    let mut daemon = low_threshold_daemon();
    let mut probe = InMemoryCorpusGrowthProbe::new(10);

    // Baseline.
    daemon.check_corpus_growth_with_hnsw::<_, InMemoryHNSWGraphMaintenance>(
        T0, &mut probe, None);
    // Growth fires.
    probe.vocab = 16;
    daemon.check_corpus_growth_with_hnsw::<_, InMemoryHNSWGraphMaintenance>(
        T0 + 30.0, &mut probe, None);

    assert_eq!(probe.reindex_calls.len(), 1, "reindex must fire with hnsw=None");
}

// ─── THETA seam ──────────────────────────────────────────────────────────────

/// `run_theta_cycle_with_hook_and_hnsw` calls `rebuild_float_index` once
/// per invocation when the THETA gate is due.
#[test]
fn theta_hnsw_rebuild_fires_per_cycle() {
    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    let mut hook = InMemoryThetaBasisRetrainHook::new();
    let mut hnsw = InMemoryHNSWGraphMaintenance::new();
    let reader = NoOpReader;
    let mut sink = NoOpSink;

    // THETA is due on first call (no prior run).
    let _ = daemon.run_theta_cycle_with_hook_and_hnsw(
        T0, &reader, &mut sink, Some(&mut hook), Some(&mut hnsw),
    );

    assert_eq!(hook.retrain_calls.len(), 1, "retrain must fire once");
    assert_eq!(hnsw.rebuild_calls, vec![T0],
        "rebuild_float_index must fire with the cycle timestamp");
}

/// `run_theta_cycle_with_hook_and_hnsw` fires the rebuild even when the retrain
/// hook fails (non-fatal policy matches Swift).
#[test]
fn theta_hnsw_rebuild_fires_even_when_retrain_fails() {
    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    let mut hook = InMemoryThetaBasisRetrainHook::failing();
    let mut hnsw = InMemoryHNSWGraphMaintenance::new();
    let reader = NoOpReader;
    let mut sink = NoOpSink;

    let _ = daemon.run_theta_cycle_with_hook_and_hnsw(
        T0, &reader, &mut sink, Some(&mut hook), Some(&mut hnsw),
    );

    assert!(hook.retrain_calls.is_empty(), "failing hook records no call");
    assert_eq!(hnsw.rebuild_calls, vec![T0],
        "rebuild must still fire after a failed retrain (non-fatal)");
}

/// THETA rebuild with `hook: None` still calls rebuild (the hook is orthogonal).
#[test]
fn theta_hnsw_rebuild_fires_with_hook_none() {
    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    let mut hnsw = InMemoryHNSWGraphMaintenance::new();
    let reader = NoOpReader;
    let mut sink = NoOpSink;

    let _ = daemon.run_theta_cycle_with_hook_and_hnsw::<_, _, InMemoryThetaBasisRetrainHook, _>(
        T0, &reader, &mut sink, None, Some(&mut hnsw),
    );

    assert_eq!(hnsw.rebuild_calls, vec![T0], "rebuild must fire even with hook=None");
}

/// `run_theta_cycle_with_hook_and_hnsw` with `hnsw: None` behaves identically to
/// `run_theta_cycle_with_hook`.
#[test]
fn theta_hnsw_none_path_is_safe() {
    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    let mut hook = InMemoryThetaBasisRetrainHook::new();
    let reader = NoOpReader;
    let mut sink = NoOpSink;

    let _ = daemon.run_theta_cycle_with_hook_and_hnsw::<_, _, _, InMemoryHNSWGraphMaintenance>(
        T0, &reader, &mut sink, Some(&mut hook), None,
    );

    assert_eq!(hook.retrain_calls.len(), 1, "retrain must fire with hnsw=None");
}

// ─── BETA seam ───────────────────────────────────────────────────────────────

/// `run_beta_cycle_with_hnsw` calls `compact_float_index_tombstones` once per
/// invocation.
#[test]
fn beta_hnsw_compact_fires_per_cycle() {
    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    let mut hnsw = InMemoryHNSWGraphMaintenance::new();

    let report = daemon.run_beta_cycle_with_hnsw(T0, Some(&mut hnsw));

    assert!(report.is_none(), "BETA returns None (no proposals)");
    assert_eq!(hnsw.compact_calls, vec![T0],
        "compact_float_index_tombstones must fire with the cycle timestamp");
}

/// `run_beta_cycle_with_hnsw` compact fires even when consolidated is empty
/// (nothing to prune — compaction is independent of the prune outcome).
#[test]
fn beta_hnsw_compact_fires_on_empty_state() {
    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    let mut hnsw = InMemoryHNSWGraphMaintenance::new();

    // No consolidated entries seeded — BETA prune is a no-op.
    daemon.run_beta_cycle_with_hnsw(T0, Some(&mut hnsw));

    assert_eq!(hnsw.compact_calls.len(), 1,
        "compact must fire even when consolidated map is empty");
}

/// HNSW compact failure (`fail_all: true`) is non-fatal: base BETA cycle
/// advances the timestamp regardless.
#[test]
fn beta_hnsw_compact_failure_is_non_fatal() {
    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    let mut hnsw = InMemoryHNSWGraphMaintenance::failing();

    daemon.run_beta_cycle_with_hnsw(T0, Some(&mut hnsw));

    assert!(hnsw.compact_calls.is_empty(),
        "failing compact records no call (non-fatal)");
    // Verify the base BETA timestamp still advanced.
    let state = daemon.daemon_state();
    assert_eq!(state.last_beta_run_epoch_secs, Some(T0),
        "BETA timestamp must advance even when HNSW compact fails");
}

/// `run_beta_cycle_with_hnsw` with `hnsw: None` behaves identically to
/// `run_beta_cycle` (no HNSW side effect, no panic).
#[test]
fn beta_hnsw_none_path_is_safe() {
    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());

    let report = daemon.run_beta_cycle_with_hnsw::<InMemoryHNSWGraphMaintenance>(T0, None);

    assert!(report.is_none(), "BETA returns None with hnsw=None");
    let state = daemon.daemon_state();
    assert_eq!(state.last_beta_run_epoch_secs, Some(T0),
        "BETA timestamp must advance with hnsw=None");
}
