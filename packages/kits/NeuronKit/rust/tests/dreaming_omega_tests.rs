//! dreaming_omega_tests.rs — REM-OMEGA retire cycle.
//!
//! Rust parity of `NeuronKitTests/DreamingOmegaTests.swift`.
//!
//! Covers:
//!   §12.6 OMEGA row — dreamed tunnels unreinforced in the 14-day window are
//!          retired; reinforced ones are kept active.
//!   §12.8 — declared tunnels (is_dreamed() == false) are never returned by
//!          `dreamed_active_tunnels()` in production (reader-seam guard).
//!   Report shape — candidates_considered = dreamed-active count;
//!          suppressed_duplicates = reinforced count; proposals_emitted = [].
//!   Diary entry — exactly one per cycle, correct topic ("dreaming-omega").
//!   Cadence — last_omega_run_epoch_secs advances after a run.
//!   Anti-inert — a run with dreamed tunnels present returns Some(report).
//!   Prune — recall traces are pruned after the retire sweep.
//!
//! All substrate interaction uses in-memory seam fakes — no live estate.

use neuron_kit::dreaming_cycle::{
    DreamingDaemon, DreamingDiaryEntry, DreamingPolicy,
    DreamingProposalSink, DreamingSubstrateReader, DreamingTunnelItem, ProposeFrameOut,
    RecallTraceItem, TunnelLink,
};

// ─── Fakes ──────────────────────────────────────────────────────────────────

/// Recording sink for OMEGA tests. Captures retire calls, diary entries, and prune calls.
#[derive(Default)]
struct OmegaRecordingSink {
    retired_tunnel_ids: Vec<String>,
    diaries: Vec<DreamingDiaryEntry>,
    prune_calls: Vec<String>,
}

impl DreamingProposalSink for OmegaRecordingSink {
    fn propose(&mut self, _frame: ProposeFrameOut) { /* OMEGA emits no proposals */ }
    fn record_cycle_diary(&mut self, entry: DreamingDiaryEntry) {
        self.diaries.push(entry);
    }
    fn prune_recall_traces(&mut self, cutoff_iso: &str) {
        self.prune_calls.push(cutoff_iso.to_string());
    }
    fn retire_tunnel(&mut self, tunnel_id: &str, _changed_by: &str, _now_epoch_secs: i64) {
        self.retired_tunnel_ids.push(tunnel_id.to_string());
    }
}

/// Configurable reader for OMEGA tests.
///
/// - `traces`: recall-trace rows in the OMEGA window (for reinforcement check).
/// - `dreamed`: dreamed-active tunnels OMEGA evaluates.
///
/// Returns empty drain and empty existing tunnels — OMEGA does not use those.
struct OmegaFakeReader {
    traces: Vec<RecallTraceItem>,
    dreamed: Vec<DreamingTunnelItem>,
}

impl OmegaFakeReader {
    fn new(traces: Vec<RecallTraceItem>, dreamed: Vec<DreamingTunnelItem>) -> Self {
        Self { traces, dreamed }
    }
}

impl DreamingSubstrateReader for OmegaFakeReader {
    fn recent_recall_traces(&self) -> Vec<RecallTraceItem> {
        self.traces.clone()
    }
    fn drain_dreaming_window(&self) -> Vec<Vec<String>> {
        vec![]
    }
    fn existing_tunnels(&self) -> Vec<TunnelLink> {
        vec![]
    }
    fn dreamed_active_tunnels(&self) -> Vec<DreamingTunnelItem> {
        self.dreamed.clone()
    }
}

// ─── Helpers ────────────────────────────────────────────────────────────────

const T0: f64 = 1_700_000_000.0;

fn policy() -> DreamingPolicy {
    DreamingPolicy::default()
}

/// Dreamed tunnel item (id, source, target).
fn dt(id: &str, source: &str, target: &str) -> DreamingTunnelItem {
    DreamingTunnelItem {
        id: id.to_string(),
        source_drawer_id: source.to_string(),
        target_drawer_id: target.to_string(),
    }
}

/// Recall trace item (target, used).
fn trace(target: &str, used: bool) -> RecallTraceItem {
    RecallTraceItem { target: target.to_string(), used }
}

// ─── Anti-inert: non-None report when dreamed tunnels are present ────────────

#[test]
fn omega_with_dreamed_tunnels_returns_some_report() {
    // Both endpoints reinforced → no retirements, but report is Some.
    let reader = OmegaFakeReader::new(
        vec![trace("drawer-a", true), trace("drawer-b", true)],
        vec![dt("t1", "drawer-a", "drawer-b")],
    );
    let mut sink = OmegaRecordingSink::default();
    let mut daemon = DreamingDaemon::new(policy());
    let report = daemon.run_omega_cycle(T0, &reader, &mut sink);
    assert!(report.is_some(), "OMEGA returns Some when dreamed tunnels are evaluated");
}

// ─── §12.6: unreinforced dreamed tunnel is retired ───────────────────────────

#[test]
fn omega_retires_unreinforced_dreamed_tunnel() {
    // No traces → neither endpoint reinforced → tunnel retired.
    let reader = OmegaFakeReader::new(
        vec![],
        vec![dt("t-unreinforced", "src", "tgt")],
    );
    let mut sink = OmegaRecordingSink::default();
    let mut daemon = DreamingDaemon::new(policy());
    daemon.run_omega_cycle(T0, &reader, &mut sink);
    assert_eq!(
        sink.retired_tunnel_ids,
        vec!["t-unreinforced"],
        "Unreinforced dreamed tunnel must be retired"
    );
}

#[test]
fn omega_retires_tunnel_when_only_one_endpoint_reinforced() {
    // Only source has a trace — target is absent → partially reinforced → retired.
    let reader = OmegaFakeReader::new(
        vec![trace("src-partial", true)], // no trace for "tgt-partial"
        vec![dt("t-partial", "src-partial", "tgt-partial")],
    );
    let mut sink = OmegaRecordingSink::default();
    let mut daemon = DreamingDaemon::new(policy());
    daemon.run_omega_cycle(T0, &reader, &mut sink);
    assert_eq!(
        sink.retired_tunnel_ids,
        vec!["t-partial"],
        "Tunnel with only one reinforced endpoint must be retired"
    );
}

// ─── §12.6: reinforced dreamed tunnel is NOT retired ────────────────────────

#[test]
fn omega_does_not_retire_reinforced_tunnel() {
    // Both endpoints have traces → reinforced → no retire.
    let reader = OmegaFakeReader::new(
        vec![trace("r-a", true), trace("r-b", true)],
        vec![dt("t-reinforced", "r-a", "r-b")],
    );
    let mut sink = OmegaRecordingSink::default();
    let mut daemon = DreamingDaemon::new(policy());
    daemon.run_omega_cycle(T0, &reader, &mut sink);
    assert!(
        sink.retired_tunnel_ids.is_empty(),
        "Reinforced tunnel must NOT be retired"
    );
}

#[test]
fn omega_unused_traces_count_as_reinforcement() {
    // Unused traces (used = false) still reinforce — OMEGA checks presence, not reward.
    let reader = OmegaFakeReader::new(
        vec![trace("u-a", false), trace("u-b", false)],
        vec![dt("t-unused", "u-a", "u-b")],
    );
    let mut sink = OmegaRecordingSink::default();
    let mut daemon = DreamingDaemon::new(policy());
    daemon.run_omega_cycle(T0, &reader, &mut sink);
    assert!(
        sink.retired_tunnel_ids.is_empty(),
        "Unused traces still reinforce — tunnel must NOT be retired"
    );
}

// ─── Report shape ────────────────────────────────────────────────────────────

#[test]
fn omega_report_counts_correct() {
    // Two tunnels: AB reinforced, CD not reinforced.
    let reader = OmegaFakeReader::new(
        vec![trace("rpt-a", true), trace("rpt-b", true)],
        vec![
            dt("t-rpt-ab", "rpt-a", "rpt-b"),
            dt("t-rpt-cd", "rpt-c", "rpt-d"),
        ],
    );
    let mut sink = OmegaRecordingSink::default();
    let mut daemon = DreamingDaemon::new(policy());
    let report = daemon.run_omega_cycle(T0, &reader, &mut sink).expect("Some report");
    assert_eq!(report.candidates_considered, 2, "candidates_considered = total dreamed-active");
    assert_eq!(report.suppressed_duplicates, 1, "suppressed_duplicates = reinforced (kept) count");
    assert!(report.proposals_emitted.is_empty(), "OMEGA emits no proposals (§12.6)");
    assert_eq!(report.below_threshold, 0, "OMEGA has no threshold gate");
    assert!(report.candidate_scores.is_empty(), "OMEGA has no scoring");
    assert!(report.reward_by_target.is_empty(), "OMEGA does not use the reward model");
}

#[test]
fn omega_report_never_emits_proposals() {
    // Even unreinforced tunnels → retire, not propose.
    let reader = OmegaFakeReader::new(
        vec![],
        vec![dt("t-no-propose", "x", "y")],
    );
    let mut sink = OmegaRecordingSink::default();
    let mut daemon = DreamingDaemon::new(policy());
    let report = daemon.run_omega_cycle(T0, &reader, &mut sink).expect("Some report");
    assert!(report.proposals_emitted.is_empty(), "OMEGA never emits proposals (§12.6)");
}

// ─── Diary entry ─────────────────────────────────────────────────────────────

#[test]
fn omega_writes_exactly_one_diary_entry() {
    let reader = OmegaFakeReader::new(
        vec![],
        vec![dt("t-diary", "da", "db")],
    );
    let mut sink = OmegaRecordingSink::default();
    let mut daemon = DreamingDaemon::new(policy());
    daemon.run_omega_cycle(T0, &reader, &mut sink);
    assert_eq!(sink.diaries.len(), 1, "OMEGA writes exactly one diary entry per cycle");
}

#[test]
fn omega_diary_entry_topic_is_dreaming_omega() {
    let reader = OmegaFakeReader::new(
        vec![],
        vec![dt("t-topic", "ta", "tb")],
    );
    let mut sink = OmegaRecordingSink::default();
    let mut daemon = DreamingDaemon::new(policy());
    daemon.run_omega_cycle(T0, &reader, &mut sink);
    assert_eq!(
        sink.diaries[0].topic, "dreaming-omega",
        "OMEGA diary topic must be 'dreaming-omega'"
    );
}

// ─── Cadence gate ─────────────────────────────────────────────────────────────

#[test]
fn omega_advances_last_run_timestamp() {
    let reader = OmegaFakeReader::new(vec![], vec![]);
    let mut sink = OmegaRecordingSink::default();
    let mut daemon = DreamingDaemon::new(policy());
    daemon.run_omega_cycle(T0, &reader, &mut sink);
    assert_eq!(
        daemon.last_run_epoch_secs("omega"),
        Some(T0),
        "last_omega_run_epoch_secs must equal the injected now"
    );
}

#[test]
fn omega_not_due_within_14_days() {
    let reader = OmegaFakeReader::new(vec![], vec![]);
    let mut sink = OmegaRecordingSink::default();
    let mut daemon = DreamingDaemon::new(policy());
    daemon.run_omega_cycle(T0, &reader, &mut sink);
    // 7 days later — not yet 14 days.
    assert!(
        !daemon.omega_due(T0 + 7.0 * 86_400.0),
        "OMEGA must not be due 7 days after last run (cadence is 14 days)"
    );
}

// ─── No-dreamed-tunnels early exit ───────────────────────────────────────────

#[test]
fn omega_early_exit_no_dreamed_tunnels() {
    let reader = OmegaFakeReader::new(vec![], vec![]);
    let mut sink = OmegaRecordingSink::default();
    let mut daemon = DreamingDaemon::new(policy());
    let report = daemon.run_omega_cycle(T0, &reader, &mut sink);
    assert!(report.is_none(), "No dreamed tunnels → OMEGA returns None (early exit)");
    assert_eq!(
        daemon.last_run_epoch_secs("omega"),
        Some(T0),
        "last_omega_run_epoch_secs must still advance on early exit"
    );
}

// ─── Recall-trace prune ──────────────────────────────────────────────────────

#[test]
fn omega_prunes_recall_traces_after_sweep() {
    let reader = OmegaFakeReader::new(
        vec![],
        vec![dt("t-prune", "p1", "p2")],
    );
    let mut sink = OmegaRecordingSink::default();
    let mut daemon = DreamingDaemon::new(policy());
    daemon.run_omega_cycle(T0, &reader, &mut sink);
    assert!(
        !sink.prune_calls.is_empty(),
        "OMEGA must call prune_recall_traces after the retire sweep"
    );
}

// ─── Multi-tunnel mixed reinforcement ────────────────────────────────────────

#[test]
fn omega_mixed_reinforcement_correct() {
    // AB: reinforced (both traces), CD: unreinforced, EF: partially reinforced (E only).
    let reader = OmegaFakeReader::new(
        vec![trace("mix-a", true), trace("mix-b", true), trace("mix-e", true)],
        vec![
            dt("t-mix-ab", "mix-a", "mix-b"),
            dt("t-mix-cd", "mix-c", "mix-d"),
            dt("t-mix-ef", "mix-e", "mix-f"),
        ],
    );
    let mut sink = OmegaRecordingSink::default();
    let mut daemon = DreamingDaemon::new(policy());
    let report = daemon.run_omega_cycle(T0, &reader, &mut sink).expect("Some report");
    assert_eq!(report.candidates_considered, 3);
    assert_eq!(report.suppressed_duplicates, 1, "AB is reinforced and kept");
    assert_eq!(sink.retired_tunnel_ids.len(), 2, "CD and EF are unreinforced and retired");
    assert!(sink.retired_tunnel_ids.contains(&"t-mix-cd".to_string()), "CD retired");
    assert!(sink.retired_tunnel_ids.contains(&"t-mix-ef".to_string()), "EF retired");
    assert!(!sink.retired_tunnel_ids.contains(&"t-mix-ab".to_string()), "AB NOT retired");
}
