//! The dreaming daemon's per-cycle ORCHESTRATION (NEURONKIT_SPEC § 3.1
//! steps 1-7) over seam traits, the Rust parity of the Swift
//! `DreamingDaemon` actor's `runCycle`. Where `dreaming_decision` owns the
//! DECISIONS, this module owns the SEQUENCE that wraps them: reduce reward
//! per target (step 1), gather candidates + existing tunnels (steps 2, 5),
//! delegate to `dreaming_decision::decide` (steps 3-6), emit a proposal per
//! cleared candidate, carry `consolidated` / `proposed_keys` across cycles,
//! and write exactly one diary entry (step 7).
//!
//! ── Why seam traits, not a live estate binding ───────────────────────
//! The READ seam (recall traces, co-occurrence, tunnels) is backable by
//! the Rust `Estate` today. The WRITE seam's `propose` is the Brain-layer
//! verb, which raises `NotSupportedByEstate` in BOTH the Rust and Swift GLK
//! surfaces until the Brain layer ships — so a live proposal adapter waits
//! on the same architectural boundary in both languages, not on this version.
//! The orchestration itself is pure of that boundary: it talks to the
//! `DreamingSubstrateReader` / `DreamingProposalSink` / `RewardSource`
//! traits, exactly as the Swift actor talks to its protocols, and is gated
//! with deterministic fakes (the same shape as the Swift DreamingDaemonTests
//! fakes). The production adapter binding these traits to the estate is the
//! future bridge, identical to Swift's deferred adapter.
//!
//! Determinism: no clock, no RNG. The daemon carries `cycle_count` and the
//! caller supplies any time-derived inputs through the seam.

use std::collections::{BTreeMap, BTreeSet};

use crate::dreaming_decision::{self, candidate_key};

/// Minimal identity-free projection of a recall-trace row — the only two
/// fields the cycle reads (the reward source maps `used` to a reward).
#[derive(Clone, Debug, PartialEq)]
pub struct RecallTraceItem {
    pub target: String,
    pub used: bool,
}

/// Identity-free co-occurrence candidate, mirroring the Swift
/// `CoOccurrenceObservation` seam value type.
#[derive(Clone, Debug, PartialEq)]
pub struct CoOccurrenceObservation {
    pub endpoint_a: String,
    pub endpoint_b: String,
    pub attempts: i64,
    pub evidence_targets: Vec<String>,
}

/// Identity-free projection of a tunnel — only the two drawer endpoints
/// matter for duplicate suppression. A room-level tunnel has `None`
/// endpoints and cannot duplicate a drawer-pair candidate.
#[derive(Clone, Debug, PartialEq)]
pub struct TunnelLink {
    pub source_drawer_id: Option<String>,
    pub target_drawer_id: Option<String>,
}

/// A proposal the sink receives. There is no Rust `ProposeFrame` estate
/// type (the propose verb is Brain-layer, `NotSupportedByEstate`); this is
/// the seam's value. `kind` is the proposal-kind tag ("miningPattern").
#[derive(Clone, Debug, PartialEq)]
pub struct ProposeFrameOut {
    pub target: String,
    pub kind: String,
    pub justification: String,
}

/// The one diary entry a cycle writes (step 7). The `entry` text is the
/// integer-only cycle summary, byte-identical to the Swift actor's.
#[derive(Clone, Debug, PartialEq)]
pub struct DreamingDiaryEntry {
    pub agent_name: String,
    pub entry: String,
    pub topic: String,
    pub wing: String,
    pub room: String,
}

/// What one dreaming cycle did — the Rust parity of `DreamingCycleReport`.
#[derive(Clone, Debug, PartialEq)]
pub struct DreamingCycleReport {
    pub candidates_considered: usize,
    pub proposals_emitted: Vec<ProposeFrameOut>,
    pub suppressed_duplicates: usize,
    pub below_threshold: usize,
    pub candidate_scores: BTreeMap<String, f32>,
    pub reward_by_target: BTreeMap<String, f32>,
    pub diary_entry: DreamingDiaryEntry,
}

/// Dreaming-policy gates, mirroring the Swift `DreamingPolicy` fields the
/// cycle reads.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DreamingPolicy {
    pub min_success_rate: f32,
    pub min_confidence: f32,
    pub min_attempts: i64,
}

impl Default for DreamingPolicy {
    /// Spec defaults (NEURONKIT_SPEC § 3.1).
    fn default() -> Self {
        Self { min_success_rate: 0.6, min_confidence: 0.7, min_attempts: 5 }
    }
}

/// Read seam: the three substrate reads a dreaming cycle performs.
pub trait DreamingSubstrateReader {
    /// Recall-trace rows in the reward window. (The since/now windowing is
    /// the production adapter's concern; the trait yields the in-window set.)
    fn recent_recall_traces(&self) -> Vec<RecallTraceItem>;
    /// Latent co-occurrence candidates.
    fn co_occurrence_observations(&self) -> Vec<CoOccurrenceObservation>;
    /// Existing tunnels, for duplicate suppression.
    fn existing_tunnels(&self) -> Vec<TunnelLink>;
}

/// Reward seam: derive a reward in `[0, 1]` from a recall-trace row.
pub trait RewardSource {
    fn reward(&self, item: &RecallTraceItem) -> f32;
}

/// The v1 single-source reward: `used → 1.0`, otherwise `0.0` (C-15).
/// Mirrors `RecallTraceRewardSource`.
pub struct RecallTraceRewardSource;

impl RewardSource for RecallTraceRewardSource {
    fn reward(&self, item: &RecallTraceItem) -> f32 {
        if item.used { 1.0 } else { 0.0 }
    }
}

/// Write seam: emit a proposal and record the cycle diary. No remediation
/// method — the daemon can only propose (structural never-remediate).
pub trait DreamingProposalSink {
    fn propose(&mut self, frame: ProposeFrameOut);
    fn record_cycle_diary(&mut self, entry: DreamingDiaryEntry);
}

const AGENT_NAME: &str = "dreaming-daemon";
const DIARY_WING: &str = "wing_dreaming-daemon";

/// Candidate key for a tunnel, or `None` when it is not drawer-to-drawer.
/// Mirrors `DreamingDaemon.tunnelKey`.
pub fn tunnel_key(link: &TunnelLink) -> Option<String> {
    match (&link.source_drawer_id, &link.target_drawer_id) {
        (Some(a), Some(b)) => Some(candidate_key(a, b)),
        _ => None,
    }
}

/// The dreaming daemon's across-cycle state and cycle driver — the Rust
/// parity of the Swift `DreamingDaemon` actor (without the async/timer
/// machinery, which is the runtime's concern, not the algorithm's).
pub struct DreamingDaemon {
    pub policy: DreamingPolicy,
    consolidated: BTreeMap<String, f32>,
    proposed_keys: BTreeSet<String>,
    cycle_count: i64,
}

impl DreamingDaemon {
    pub fn new(policy: DreamingPolicy) -> Self {
        Self {
            policy,
            consolidated: BTreeMap::new(),
            proposed_keys: BTreeSet::new(),
            cycle_count: 0,
        }
    }

    /// Run one dreaming cycle (steps 1-7) against the seams. Mirrors
    /// `DreamingDaemon.runCycle` step for step.
    pub fn run_cycle<R, Q, S>(
        &mut self,
        reader: &R,
        reward_source: &Q,
        sink: &mut S,
    ) -> DreamingCycleReport
    where
        R: DreamingSubstrateReader,
        Q: RewardSource,
        S: DreamingProposalSink,
    {
        // Step 1: reward retrieval. Keep the strongest signal per target.
        let traces = reader.recent_recall_traces();
        let mut reward_by_target: BTreeMap<String, f32> = BTreeMap::new();
        for trace in &traces {
            let r = reward_source.reward(trace);
            let cur = reward_by_target.get(&trace.target).copied().unwrap_or(0.0);
            reward_by_target.insert(trace.target.clone(), cur.max(r));
        }

        // Step 2: latent co-occurrence candidates.
        let observations = reader.co_occurrence_observations();
        let candidates_considered = observations.len();

        // Step 5 (prep): existing drawer-to-drawer tunnel keys.
        let existing_tunnel_keys: BTreeSet<String> =
            reader.existing_tunnels().iter().filter_map(tunnel_key).collect();

        // Steps 3-6: delegate every decision to the pure core.
        let decision_obs: Vec<dreaming_decision::Observation> = observations
            .iter()
            .map(|o| dreaming_decision::Observation {
                endpoint_a: o.endpoint_a.clone(),
                endpoint_b: o.endpoint_b.clone(),
                attempts: o.attempts,
                evidence_targets: o.evidence_targets.clone(),
            })
            .collect();
        let outcome = dreaming_decision::decide(
            &decision_obs,
            &reward_by_target,
            &existing_tunnel_keys,
            &self.proposed_keys,
            &self.consolidated,
            self.policy.min_confidence,
            self.policy.min_attempts,
            self.policy.min_success_rate,
        );

        // Fold consolidation back; emit one proposal per cleared candidate.
        self.consolidated = outcome.updated_consolidated.clone();
        let mut proposals_emitted: Vec<ProposeFrameOut> = Vec::new();
        for c in &outcome.emitted {
            let frame = ProposeFrameOut {
                target: c.endpoint_a.clone(),
                kind: "miningPattern".to_string(),
                justification: format!(
                    "dreaming: latent alignment {}<->{} (attempts {}, confidence {})",
                    c.endpoint_a, c.endpoint_b, c.attempts, c.confidence
                ),
            };
            sink.propose(frame.clone());
            self.proposed_keys.insert(c.key.clone());
            proposals_emitted.push(frame);
        }

        // Step 7: exactly one diary entry. The integer summary is
        // byte-identical to the Swift actor's.
        self.cycle_count += 1;
        let entry = DreamingDiaryEntry {
            agent_name: AGENT_NAME.to_string(),
            entry: format!(
                "dreaming cycle {}: considered {}, proposed {}, suppressed {}, below-threshold {}",
                self.cycle_count,
                candidates_considered,
                proposals_emitted.len(),
                outcome.suppressed_duplicates,
                outcome.below_threshold
            ),
            topic: "dreaming-cycle".to_string(),
            wing: DIARY_WING.to_string(),
            room: "diary".to_string(),
        };
        sink.record_cycle_diary(entry.clone());

        DreamingCycleReport {
            candidates_considered,
            proposals_emitted,
            suppressed_duplicates: outcome.suppressed_duplicates,
            below_threshold: outcome.below_threshold,
            candidate_scores: outcome.scores,
            reward_by_target,
            diary_entry: entry,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A configurable fake reader, the shape of the Swift FakeReader.
    struct FakeReader {
        traces: Vec<RecallTraceItem>,
        observations: Vec<CoOccurrenceObservation>,
        tunnels: Vec<TunnelLink>,
    }
    impl DreamingSubstrateReader for FakeReader {
        fn recent_recall_traces(&self) -> Vec<RecallTraceItem> { self.traces.clone() }
        fn co_occurrence_observations(&self) -> Vec<CoOccurrenceObservation> {
            self.observations.clone()
        }
        fn existing_tunnels(&self) -> Vec<TunnelLink> { self.tunnels.clone() }
    }

    /// Records what the cycle wrote, like the Swift RecordingSink.
    #[derive(Default)]
    struct RecordingSink {
        proposals: Vec<ProposeFrameOut>,
        diaries: Vec<DreamingDiaryEntry>,
    }
    impl DreamingProposalSink for RecordingSink {
        fn propose(&mut self, frame: ProposeFrameOut) { self.proposals.push(frame); }
        fn record_cycle_diary(&mut self, entry: DreamingDiaryEntry) { self.diaries.push(entry); }
    }

    fn trace(target: &str, used: bool) -> RecallTraceItem {
        RecallTraceItem { target: target.to_string(), used }
    }
    fn obs(a: &str, b: &str, attempts: i64, ev: &[&str]) -> CoOccurrenceObservation {
        CoOccurrenceObservation {
            endpoint_a: a.to_string(),
            endpoint_b: b.to_string(),
            attempts,
            evidence_targets: ev.iter().map(|s| s.to_string()).collect(),
        }
    }
    fn link(a: &str, b: &str) -> TunnelLink {
        TunnelLink { source_drawer_id: Some(a.to_string()), target_drawer_id: Some(b.to_string()) }
    }

    // DC-1: a strong, novel candidate is proposed; report + reward map and
    // the single diary entry are assembled. (Swift C3-style happy path.)
    #[test]
    fn dc1_strong_candidate_proposes_and_reports() {
        let reader = FakeReader {
            traces: vec![trace("r1", true), trace("r2", true)],
            observations: vec![obs("a", "b", 9, &["r1", "r2"])],
            tunnels: vec![],
        };
        let mut sink = RecordingSink::default();
        let mut d = DreamingDaemon::new(DreamingPolicy::default());
        let report = d.run_cycle(&reader, &RecallTraceRewardSource, &mut sink);

        assert_eq!(report.candidates_considered, 1);
        assert_eq!(report.proposals_emitted.len(), 1);
        assert_eq!(report.proposals_emitted[0].target, "a");
        assert_eq!(report.proposals_emitted[0].kind, "miningPattern");
        assert_eq!(report.reward_by_target["r1"], 1.0);
        assert_eq!(report.reward_by_target["r2"], 1.0);
        let key = candidate_key("a", "b");
        assert!(report.candidate_scores[&key] >= 0.7);
        assert_eq!(sink.proposals.len(), 1);
        assert_eq!(sink.diaries.len(), 1, "exactly one diary entry per cycle");
        assert_eq!(sink.diaries[0].wing, "wing_dreaming-daemon");
        assert_eq!(sink.diaries[0].agent_name, "dreaming-daemon");
        assert_eq!(
            sink.diaries[0].entry,
            "dreaming cycle 1: considered 1, proposed 1, suppressed 0, below-threshold 0"
        );
    }

    // DC-2: a candidate duplicating an existing drawer-to-drawer tunnel is
    // suppressed, not proposed. (Swift duplicate-suppression test.)
    #[test]
    fn dc2_existing_tunnel_suppresses() {
        let reader = FakeReader {
            traces: vec![trace("r1", true), trace("r2", true)],
            observations: vec![obs("a", "b", 9, &["r1", "r2"])],
            tunnels: vec![link("a", "b")],
        };
        let mut sink = RecordingSink::default();
        let mut d = DreamingDaemon::new(DreamingPolicy::default());
        let report = d.run_cycle(&reader, &RecallTraceRewardSource, &mut sink);
        assert_eq!(report.proposals_emitted.len(), 0);
        assert!(report.suppressed_duplicates >= 1);
    }

    // DC-3: EWC++ across two cycles through the daemon. Cycle 1 consolidates
    // a high score and proposes. Cycle 2 sees only-unused evidence: the
    // fresh score collapses but EWC++ keeps the consolidated score >= gate;
    // B-4 idempotency suppresses the re-proposal. (Swift EWC + B-4.)
    #[test]
    fn dc3_ewc_preserves_and_b4_suppresses_across_cycles() {
        let key = candidate_key("a", "b");
        let mut d = DreamingDaemon::new(DreamingPolicy::default());
        let mut sink = RecordingSink::default();

        let r1 = FakeReader {
            traces: vec![trace("r1", true), trace("r2", true)],
            observations: vec![obs("a", "b", 9, &["r1", "r2"])],
            tunnels: vec![],
        };
        let first = d.run_cycle(&r1, &RecallTraceRewardSource, &mut sink);
        assert_eq!(first.proposals_emitted.len(), 1);
        assert!(first.candidate_scores[&key] >= 0.7);

        let r2 = FakeReader {
            traces: vec![trace("r1", false), trace("r2", false)],
            observations: vec![obs("a", "b", 9, &["r1", "r2"])],
            tunnels: vec![],
        };
        let second = d.run_cycle(&r2, &RecallTraceRewardSource, &mut sink);
        assert_eq!(second.proposals_emitted.len(), 0, "B-4 suppresses the re-proposal");
        assert_eq!(second.suppressed_duplicates, 1);
        assert!(
            second.candidate_scores[&key] >= 0.7,
            "EWC++ preserved the prior association, got {}",
            second.candidate_scores[&key]
        );
        // Two cycles => two diary entries; the second counts cycle 2.
        assert_eq!(sink.diaries.len(), 2);
        assert!(sink.diaries[1].entry.starts_with("dreaming cycle 2:"));
    }

    // DC-4: per-target reward keeps the strongest signal — a target used in
    // one trace and ignored in another reduces to 1.0 (used wins via max).
    #[test]
    fn dc4_reward_keeps_strongest_per_target() {
        let reader = FakeReader {
            traces: vec![trace("r1", false), trace("r1", true)],
            observations: vec![],
            tunnels: vec![],
        };
        let mut sink = RecordingSink::default();
        let mut d = DreamingDaemon::new(DreamingPolicy::default());
        let report = d.run_cycle(&reader, &RecallTraceRewardSource, &mut sink);
        assert_eq!(report.reward_by_target["r1"], 1.0);
        assert_eq!(report.candidates_considered, 0);
        assert_eq!(report.proposals_emitted.len(), 0);
    }
}
