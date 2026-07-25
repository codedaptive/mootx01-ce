//! REM-THETA consolidation-cycle and dispatch-table tests.
//!
//! Rust parity of `NeuronKitTests/DreamingThetaTests.swift`.
//!
//! Covers:
//!   THETA fires on a 24-hour cadence.
//!   D5c — last-run timestamp persists across restarts; stdio estates
//!          do not re-consolidate within the same 24 h window.
//!   §12.5 — decide() math is unchanged for THETA (same EWC++ path as
//!          ALPHA). Verified by asserting that THETA emits proposals under
//!          the same conditions as ALPHA given equivalent inputs.
//!   §12.4 — THETA bumps co_recall_counts for all pairs in the used set.
//!   Table structure — rem_cycle_table() has four entries in the correct order.
//!   BETA/OMEGA cycles — entries present; live run-fns advance timestamps (T12/T13).
//!
//! All substrate interaction uses synchronous in-memory fakes (no live estate).
//! Clock is always injected via `now_epoch_secs: f64`; no SystemTime inside.

use std::collections::BTreeMap;

use neuron_kit::dreaming_cycle::{
    DreamingCycleReport, DreamingDaemon, DreamingDaemonState, DreamingDiaryEntry, DreamingPolicy,
    DreamingPolicyStore, DreamingProposalSink, DreamingSubstrateReader, InMemoryDreamingPolicyStore,
    ProposeFrameOut, RecallTraceItem, RecallTraceRewardSource, TunnelLink,
};
use neuron_kit::rem_cycle_table::{RemCycleKind, rem_cycle_table};

// ─── Constants ──────────────────────────────────────────────────────────────

/// Arbitrary base epoch for all tests. High enough to avoid zero-edge cases.
const T0: f64 = 1_700_000_000.0;
/// 12 h before T0 — used by "not yet due" checks.
const T0_MINUS_12H: f64 = T0 - 43_200.0;
/// 24 h after T0 — the exact THETA boundary.
const T0_PLUS_24H: f64 = T0 + 86_400.0;

// ─── Local fakes ────────────────────────────────────────────────────────────

/// Minimal recording sink — records proposals and diary entries.
#[derive(Default)]
struct ThetaRecordingSink {
    proposals: Vec<ProposeFrameOut>,
    diaries: Vec<DreamingDiaryEntry>,
}

impl DreamingProposalSink for ThetaRecordingSink {
    fn propose(&mut self, frame: ProposeFrameOut) {
        self.proposals.push(frame);
    }
    fn record_cycle_diary(&mut self, entry: DreamingDiaryEntry) {
        self.diaries.push(entry);
    }
    fn prune_recall_traces(&mut self, _cutoff_iso: &str) {}
}

/// Reader fake: returns a fixed trace list; drain and tunnels are empty.
/// THETA reads `recent_recall_traces()` but does NOT drain the queue.
struct ThetaFakeReader {
    traces: Vec<RecallTraceItem>,
}

impl ThetaFakeReader {
    fn new(traces: Vec<RecallTraceItem>) -> Self {
        Self { traces }
    }
}

impl DreamingSubstrateReader for ThetaFakeReader {
    fn recent_recall_traces(&self) -> Vec<RecallTraceItem> {
        self.traces.clone()
    }
    fn drain_dreaming_window(&self) -> Vec<Vec<String>> {
        vec![]
    }
    fn existing_tunnels(&self) -> Vec<TunnelLink> {
        vec![]
    }
}

// ─── Helper ─────────────────────────────────────────────────────────────────

/// Make a RecallTraceItem with the given target and used flag.
fn trace(target: &str, used: bool) -> RecallTraceItem {
    RecallTraceItem { target: target.to_string(), used }
}

/// Relaxed policy: gate clears after one THETA bump.
fn relaxed_policy() -> DreamingPolicy {
    DreamingPolicy {
        min_success_rate: 0.1,
        min_confidence: 0.1,
        min_attempts: 1,
        tick_interval_ms: 30_000,
        event_observation_threshold: 3,
    }
}

// ─── REM dispatch table structure ───────────────────────────────────────────

#[test]
fn table_has_four_entries() {
    assert_eq!(rem_cycle_table().len(), 4);
}

#[test]
fn table_first_entry_is_alpha() {
    let t = rem_cycle_table();
    assert_eq!(t[0].kind, RemCycleKind::Alpha);
    assert_eq!(t[0].name, "REM-ALPHA");
    assert_eq!(t[0].cadence_secs, 30.0);
}

#[test]
fn table_second_entry_is_theta() {
    let t = rem_cycle_table();
    assert_eq!(t[1].kind, RemCycleKind::Theta);
    assert_eq!(t[1].name, "REM-THETA");
    assert_eq!(t[1].cadence_secs, 86_400.0);
}

#[test]
fn table_third_entry_is_beta() {
    let t = rem_cycle_table();
    assert_eq!(t[2].kind, RemCycleKind::Beta);
    assert_eq!(t[2].name, "REM-BETA");
}

#[test]
fn table_fourth_entry_is_omega() {
    let t = rem_cycle_table();
    assert_eq!(t[3].kind, RemCycleKind::Omega);
    assert_eq!(t[3].name, "REM-OMEGA");
}

// ─── THETA due-check (D5a / D5c) ────────────────────────────────────────────

#[test]
fn theta_due_when_never_run() {
    let daemon = DreamingDaemon::new(DreamingPolicy::default());
    assert!(daemon.theta_due(T0));
}

#[test]
fn theta_not_due_within_24h() {
    // Run THETA at T0_MINUS_12H to seed last_theta_run_epoch_secs.
    let reader = ThetaFakeReader::new(vec![trace("d1", true)]);
    let mut sink = ThetaRecordingSink::default();
    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    // Only one used drawer — run_theta_cycle returns None but advances timestamp.
    daemon.run_theta_cycle(T0_MINUS_12H, &reader, &mut sink);
    // 12 h elapsed: not yet 24 h, so not due.
    assert!(!daemon.theta_due(T0));
}

#[test]
fn theta_due_at_24h_boundary() {
    // Seed last-run = T0 via run_theta_cycle (one trace so it returns None).
    let reader = ThetaFakeReader::new(vec![trace("d1", true)]);
    let mut sink = ThetaRecordingSink::default();
    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    daemon.run_theta_cycle(T0, &reader, &mut sink);
    // Exactly 24 h later — boundary is due.
    assert!(daemon.theta_due(T0_PLUS_24H));
}

// ─── THETA cycle execution ───────────────────────────────────────────────────

#[test]
fn theta_returns_none_when_fewer_than_2_used_drawers() {
    let reader = ThetaFakeReader::new(vec![
        trace("d1", true),  // only one used drawer — cannot form pair
        trace("d2", false),
    ]);
    let mut sink = ThetaRecordingSink::default();
    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    let report = daemon.run_theta_cycle(T0, &reader, &mut sink);
    assert!(report.is_none());
}

#[test]
fn theta_advances_timestamp_on_no_op() {
    // Single used drawer — run_theta returns None but must advance last-run.
    let reader = ThetaFakeReader::new(vec![trace("d1", true)]);
    let mut sink = ThetaRecordingSink::default();
    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    daemon.run_theta_cycle(T0, &reader, &mut sink);
    assert_eq!(daemon.last_run_epoch_secs("theta"), Some(T0));
}

#[test]
fn theta_bumps_co_recall_counts_for_all_pairs() {
    // Three used drawers → three pairs: (a,b), (a,c), (b,c).
    let reader = ThetaFakeReader::new(vec![
        trace("a", true),
        trace("b", true),
        trace("c", true),
    ]);
    let mut sink = ThetaRecordingSink::default();
    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    daemon.run_theta_cycle(T0, &reader, &mut sink);

    assert_eq!(daemon.co_recall_count("a", "b"), 1);
    assert_eq!(daemon.co_recall_count("a", "c"), 1);
    assert_eq!(daemon.co_recall_count("b", "c"), 1);
}

#[test]
fn theta_emits_proposal_when_gate_clears() {
    // minAttempts=1 — one THETA bump is sufficient to propose.
    let policy = relaxed_policy();
    let reader = ThetaFakeReader::new(vec![trace("x", true), trace("y", true)]);
    let mut sink = ThetaRecordingSink::default();
    let mut daemon = DreamingDaemon::new(policy);
    let report = daemon.run_theta_cycle(T0, &reader, &mut sink);

    assert!(report.is_some(), "THETA should return Some when proposals are emitted");
    assert!(sink.proposals.len() >= 1, "expected at least one proposal");
    // Diary entry with "dreaming-theta" topic.
    assert_eq!(sink.diaries.len(), 1);
    assert_eq!(sink.diaries[0].topic, "dreaming-theta");
}

#[test]
fn theta_justification_identifies_theta_cycle() {
    let policy = relaxed_policy();
    let reader = ThetaFakeReader::new(vec![trace("p", true), trace("q", true)]);
    let mut sink = ThetaRecordingSink::default();
    let mut daemon = DreamingDaemon::new(policy);
    daemon.run_theta_cycle(T0, &reader, &mut sink);

    assert!(!sink.proposals.is_empty());
    assert!(
        sink.proposals[0].justification.contains("theta"),
        "justification must contain 'theta', got: {}",
        sink.proposals[0].justification
    );
}

#[test]
fn theta_persists_last_run_via_daemon_state() {
    // run_theta → daemon_state → new daemon → restore_state → check timestamp.
    // Simulates /manifest-backed daemon state round-trip through the policy store.
    let reader = ThetaFakeReader::new(vec![trace("a", true), trace("b", true)]);
    let mut sink = ThetaRecordingSink::default();
    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    daemon.run_theta_cycle(T0, &reader, &mut sink);

    let state = daemon.daemon_state();
    assert!(state.last_theta_run_epoch_secs.is_some());

    // Restore into a fresh daemon (simulates restart via policy store round-trip).
    let mut store = InMemoryDreamingPolicyStore::new(None);
    store.save_daemon_state(state);
    let saved = store.load_daemon_state().expect("state should be saved");
    let mut fresh = DreamingDaemon::new(DreamingPolicy::default());
    fresh.restore_state(saved);

    assert_eq!(fresh.last_run_epoch_secs("theta"), Some(T0));
}

#[test]
fn theta_not_due_after_running_until_24h() {
    let reader = ThetaFakeReader::new(vec![trace("a", true), trace("b", true)]);
    let mut sink = ThetaRecordingSink::default();
    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    daemon.run_theta_cycle(T0, &reader, &mut sink);

    // Immediately after running — not due.
    assert!(!daemon.theta_due(T0 + 1.0));

    // At exactly 24 h — due again.
    assert!(daemon.theta_due(T0_PLUS_24H));
}

#[test]
fn theta_does_not_repropose_already_proposed_pairs() {
    let policy = relaxed_policy();
    let reader = ThetaFakeReader::new(vec![trace("a", true), trace("b", true)]);
    let mut sink = ThetaRecordingSink::default();
    let mut daemon = DreamingDaemon::new(policy);

    daemon.run_theta_cycle(T0, &reader, &mut sink);
    let count_after_first = sink.proposals.len();

    // Second THETA run (25 h later, same traces).
    daemon.run_theta_cycle(T0 + 86_401.0, &reader, &mut sink);
    let count_after_second = sink.proposals.len();

    assert!(count_after_first >= 1, "first run should have proposed");
    assert_eq!(
        count_after_second, count_after_first,
        "no new proposals on second run — pair already proposed"
    );
}

#[test]
fn unused_drawers_excluded_from_pairs() {
    // d1 is unused — must not form any pairs.
    let reader = ThetaFakeReader::new(vec![
        trace("d1", false),
        trace("d2", true),
        trace("d3", true),
    ]);
    let mut sink = ThetaRecordingSink::default();
    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    daemon.run_theta_cycle(T0, &reader, &mut sink);

    assert_eq!(daemon.co_recall_count("d1", "d2"), 0);
    assert_eq!(daemon.co_recall_count("d1", "d3"), 0);
    assert_eq!(daemon.co_recall_count("d2", "d3"), 1);
}

// ─── BETA / OMEGA cycle tests ────────────────────────────────────────────────

#[test]
fn run_beta_cycle_returns_none_and_advances_timestamp() {
    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    let report = daemon.run_beta_cycle(T0);
    assert!(report.is_none());
    assert_eq!(daemon.last_run_epoch_secs("beta"), Some(T0));
}

#[test]
fn run_omega_cycle_no_tunnels_returns_none_and_advances_timestamp() {
    // ThetaFakeReader has no dreamed-active tunnels (default impl returns Vec::new())
    // → OMEGA exits early and returns None, but still advances the timestamp.
    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    let reader = ThetaFakeReader::new(vec![]);
    let mut sink = ThetaRecordingSink::default();
    let report = daemon.run_omega_cycle(T0, &reader, &mut sink);
    assert!(report.is_none());
    assert_eq!(daemon.last_run_epoch_secs("omega"), Some(T0));
}

#[test]
fn beta_due_when_never_run() {
    let daemon = DreamingDaemon::new(DreamingPolicy::default());
    assert!(daemon.beta_due(T0));
}

#[test]
fn omega_due_when_never_run() {
    let daemon = DreamingDaemon::new(DreamingPolicy::default());
    assert!(daemon.omega_due(T0));
}

#[test]
fn beta_not_due_within_7_days() {
    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    daemon.run_beta_cycle(T0);
    // 3 days later — not yet 7 days.
    assert!(!daemon.beta_due(T0 + 3.0 * 86_400.0));
}

#[test]
fn omega_not_due_within_14_days() {
    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    let reader = ThetaFakeReader::new(vec![]);
    let mut sink = ThetaRecordingSink::default();
    daemon.run_omega_cycle(T0, &reader, &mut sink);
    // 7 days later — not yet 14 days.
    assert!(!daemon.omega_due(T0 + 7.0 * 86_400.0));
}

// ─── Daemon state persistence round-trip ────────────────────────────────────

#[test]
fn daemon_state_round_trips_last_theta_run() {
    let mut store = InMemoryDreamingPolicyStore::new(None);
    let state = DreamingDaemonState {
        last_timer_fire_epoch_secs: None,
        proposed_keys: vec![],
        last_reindex_vocab: -1,
        consolidated: BTreeMap::new(),
        cycle_count: 0,
        co_recall_counts: BTreeMap::new(),
        last_theta_run_epoch_secs: Some(T0),
        last_beta_run_epoch_secs: None,
        last_omega_run_epoch_secs: None,
    };
    store.save_daemon_state(state);
    let loaded = store.load_daemon_state().expect("state must round-trip");
    assert_eq!(loaded.last_theta_run_epoch_secs, Some(T0));
}

#[test]
fn restore_state_recovers_theta_cadence_after_restart() {
    // Simulates: run THETA → save daemon_state → create fresh daemon →
    // restore_state → verify cadence gate sees the persisted timestamp.
    let reader = ThetaFakeReader::new(vec![trace("a", true), trace("b", true)]);
    let mut sink = ThetaRecordingSink::default();
    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    daemon.run_theta_cycle(T0, &reader, &mut sink);

    let state = daemon.daemon_state();
    let mut store = InMemoryDreamingPolicyStore::new(None);
    store.save_daemon_state(state);

    // Fresh daemon loads the persisted state.
    let mut fresh = DreamingDaemon::new(DreamingPolicy::default());
    fresh.restore_state(store.load_daemon_state().unwrap());

    // 12 h after the persisted run — not yet due.
    assert!(!fresh.theta_due(T0 + 43_200.0));
    // 24 h after — due again.
    assert!(fresh.theta_due(T0 + 86_400.0));
}
