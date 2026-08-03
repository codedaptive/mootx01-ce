// conflict_projection_sweep.rs — Rust twin of Brain/ConflictProjectionSweep.swift.
//
// DCP M3 — the typed lane's orchestration: project KGFacts (M2), bucket
// them on the coordinate index (M2), evaluate every within-bucket pair
// (M1 evaluator), and return one deterministic report. Retrieval
// proposes; typed constraints prove.
//
// This module is the PURE core: estate reads (all_kg_facts, all_drawers,
// all_tunnels) happen in the coordinator's `conflict_projection_sweep`
// verb seam, which also owns the epoch-millisecond → epoch-second
// conversion (KI-003). No clock, no writes, no tunnel proposals here —
// report rendering is M4, tunnel lifecycle wiring is M5.

use locus_kit::adjectives::AdjectiveSensitivity;
use locus_kit::kg_fact::KGFact;
use std::collections::{HashMap, HashSet};
use substrate_ml::conflict_projection::{
    evaluate, ConflictOutcome, ConflictOutcomeKind, ConflictRuleRegistry,
};

use super::conflict_projection_pass::{
    project, ConflictCoordinateIndex, ConflictProjectionDiagnostics, DEFAULT_BUCKET_CAP,
};

/// One proven-or-notable finding with the redaction input M4 needs: the
/// MAX endpoint sensitivity of the pair's source drawers (M0 §8 — the
/// report ceiling is the max of sources; rendering applies grants).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConflictFinding {
    pub outcome: ConflictOutcome,
    /// Raw adjective-sensitivity of the more sensitive source drawer.
    /// An endpoint whose sensitivity could not be resolved counts as the
    /// MAXIMUM tier (`Secret`), never as normal — see `run_sweep`'s
    /// `ceiling` closure for why this direction is the safe one.
    pub sensitivity_ceiling_raw: i64,
}

/// Outcome tallies for the report's additive lines (M0 §7).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ConflictSweepCounts {
    pub agreement: usize,
    pub compatible_plurality: usize,
    pub historical_succession: usize,
    pub proven_contradiction: usize,
    pub candidate_review: usize,
    /// InvalidInput + Irrelevant — pairs the typed lane could not judge
    /// (report line `unknown_or_invalid` together with unparsed facts).
    pub unknown_or_invalid: usize,
}

/// One sweep's outcome. Deterministic for a given estate state.
#[derive(Debug, Clone)]
pub struct ConflictProjectionSweepReport {
    /// Projection exclusion counts (`coverage: projected/scanned`).
    pub diagnostics: ConflictProjectionDiagnostics,
    /// Coordinate buckets that hit the cap (report line only when > 0).
    pub truncated_buckets: usize,
    /// Within-bucket pairs evaluated this sweep.
    pub pairs_evaluated: usize,
    pub counts: ConflictSweepCounts,
    /// Full detail for ProvenContradiction findings — the block M4
    /// renders (result id, rule, coordinate, reasons, source ids).
    pub proven: Vec<ConflictFinding>,
    /// Full detail for HistoricalSuccession findings — the "superseded,
    /// not conflicting" ledger.
    pub historical: Vec<ConflictFinding>,
}

/// Canonical unordered pair key — mirrors GLK `pairKey` (smaller ID first).
pub fn pair_key(a: &str, b: &str) -> String {
    if a < b {
        format!("{a}||{b}")
    } else {
        format!("{b}||{a}")
    }
}

/// Run projection + index + evaluation. Pure on its inputs; the caller
/// supplies event times in EPOCH SECONDS and the accepted-supersession
/// pair-key set (ACTIVE `supersedes` tunnels between source drawers).
pub fn run_sweep(
    facts: &[KGFact],
    event_time_seconds_by_source_drawer: &HashMap<String, i64>,
    sensitivity_raw_by_source_drawer: &HashMap<String, i64>,
    accepted_supersession_pairs: &HashSet<String>,
    registry: &ConflictRuleRegistry,
    bucket_cap: usize,
) -> ConflictProjectionSweepReport {
    let projection = project(facts, event_time_seconds_by_source_drawer, registry);
    let mut index = ConflictCoordinateIndex::new(bucket_cap);
    index.insert_all(projection.signatures);

    let mut counts = ConflictSweepCounts::default();
    let mut proven: Vec<ConflictFinding> = Vec::new();
    let mut historical: Vec<ConflictFinding> = Vec::new();
    let pairs = index.pairs();

    for (a, b) in &pairs {
        let accepted = accepted_supersession_pairs
            .contains(&pair_key(&a.source_drawer_id, &b.source_drawer_id));
        let outcome = evaluate(a, b, registry, accepted);
        let ceiling = || -> i64 {
            // Fail closed. An endpoint whose sensitivity could not be
            // resolved counts as the MAXIMUM tier, never as Normal: a
            // hydration gap is not evidence of low sensitivity, and the
            // Elevated ceiling the proposal loop enforces
            // (coordinator::propose_conflict_tunnels) must not be
            // passable by a failed lookup.
            //
            // Secret — a real tier — rather than a sentinel like
            // i64::MAX, because this field is documented as a raw
            // AdjectiveSensitivity value and `from_raw` coerces
            // beyond-spec raws back to Normal. Parking an out-of-range
            // value here would re-open the fail-open hole for any future
            // caller that decodes before comparing.
            let unresolved = AdjectiveSensitivity::Secret.raw_value();
            let ra = sensitivity_raw_by_source_drawer
                .get(&a.source_drawer_id)
                .copied()
                .unwrap_or(unresolved);
            let rb = sensitivity_raw_by_source_drawer
                .get(&b.source_drawer_id)
                .copied()
                .unwrap_or(unresolved);
            ra.max(rb)
        };
        match outcome.kind {
            ConflictOutcomeKind::Agreement => counts.agreement += 1,
            ConflictOutcomeKind::CompatiblePlurality => counts.compatible_plurality += 1,
            ConflictOutcomeKind::HistoricalSuccession => {
                counts.historical_succession += 1;
                historical.push(ConflictFinding {
                    sensitivity_ceiling_raw: ceiling(),
                    outcome,
                });
            }
            ConflictOutcomeKind::ProvenContradiction => {
                counts.proven_contradiction += 1;
                proven.push(ConflictFinding {
                    sensitivity_ceiling_raw: ceiling(),
                    outcome,
                });
            }
            ConflictOutcomeKind::CandidateReview => counts.candidate_review += 1,
            ConflictOutcomeKind::InvalidInput | ConflictOutcomeKind::Irrelevant => {
                counts.unknown_or_invalid += 1
            }
        }
    }
    ConflictProjectionSweepReport {
        diagnostics: projection.diagnostics,
        truncated_buckets: index.truncated_buckets(),
        pairs_evaluated: pairs.len(),
        counts,
        proven,
        historical,
    }
}

/// One M5 pass's outcome (typed proposals). Mirrors Swift
/// `ConflictTunnelProposalReport`.
#[derive(Debug, Clone)]
pub struct ConflictTunnelProposalReport {
    /// The sweep the proposals were derived from.
    pub sweep: ConflictProjectionSweepReport,
    /// Tunnel ids proposed THIS pass, in sweep order.
    pub proposed_tunnel_ids: Vec<String>,
    /// Proven findings suppressed by the dedup contract.
    pub suppressed: usize,
}

/// Default bucket cap re-export for the coordinator seam.
pub const SWEEP_DEFAULT_BUCKET_CAP: usize = DEFAULT_BUCKET_CAP;

// DCP M3 tests — Rust leg. Mirrors ConflictProjectionSweepTests.swift:
// F06 (accepted supersession → HistoricalSuccession), planted-shape
// proven counting, F20 at the sweep level (fact order cannot change
// result identities), and the sensitivity ceiling carry.
#[cfg(test)]
mod tests {
    use super::*;

    fn fact(id: &str, subject: &str, object: &str, source: &str) -> KGFact {
        KGFact::new(
            id.into(),
            subject.into(),
            "Employer".into(),
            object.into(),
            source.into(),
            // Epoch milliseconds (the LocusKit Rust clock).
            1_700_000_000_000,
        )
    }

    fn seconds(entries: &[(&str, i64)]) -> HashMap<String, i64> {
        entries.iter().map(|(k, v)| (k.to_string(), *v)).collect()
    }

    /// Planted shape: same coordinate, different enum values, same event
    /// time → proven: 1 with full finding detail.
    #[test]
    fn planted_shape_is_proven() {
        let facts = vec![
            fact("f1", "Sarah Chen C0", "Acme Robotics", "d1"),
            fact("f2", "Sarah Chen C0", "Beta Corp", "d2"),
        ];
        let report = run_sweep(
            &facts,
            &seconds(&[("d1", 500), ("d2", 500)]),
            &seconds(&[("d1", 0), ("d2", 6)]),
            &HashSet::new(),
            &ConflictRuleRegistry::v01(),
            SWEEP_DEFAULT_BUCKET_CAP,
        );
        assert_eq!(report.pairs_evaluated, 1);
        assert_eq!(report.counts.proven_contradiction, 1);
        assert_eq!(report.proven.len(), 1);
        let finding = &report.proven[0];
        assert_eq!(finding.outcome.kind, ConflictOutcomeKind::ProvenContradiction);
        // Ceiling is the MAX endpoint sensitivity (d2's 6).
        assert_eq!(finding.sensitivity_ceiling_raw, 6);
        assert_eq!(
            finding.outcome.source_drawer_ids,
            vec!["d1".to_string(), "d2".to_string()]
        );
    }

    /// F06 — an accepted supersedes tunnel between the source drawers
    /// converts the same pair to HistoricalSuccession.
    #[test]
    fn f06_accepted_supersession_is_historical() {
        let facts = vec![
            fact("f1", "Sarah Chen C0", "Acme Robotics", "d1"),
            fact("f2", "Sarah Chen C0", "Beta Corp", "d2"),
        ];
        let mut accepted = HashSet::new();
        accepted.insert(pair_key("d2", "d1")); // insertion order must not matter
        let report = run_sweep(
            &facts,
            &seconds(&[("d1", 500), ("d2", 500)]),
            &HashMap::new(),
            &accepted,
            &ConflictRuleRegistry::v01(),
            SWEEP_DEFAULT_BUCKET_CAP,
        );
        assert_eq!(report.counts.proven_contradiction, 0);
        assert_eq!(report.counts.historical_succession, 1);
        assert_eq!(report.historical.len(), 1);
        assert_eq!(
            report.historical[0].outcome.kind,
            ConflictOutcomeKind::HistoricalSuccession
        );
    }

    /// F20 at sweep level — reversing fact order changes nothing about
    /// the result identities.
    #[test]
    fn f20_fact_order_cannot_change_result_ids() {
        let a = fact("f1", "Sarah Chen C0", "Acme Robotics", "d1");
        let b = fact("f2", "Sarah Chen C0", "Beta Corp", "d2");
        let times = seconds(&[("d1", 500), ("d2", 500)]);
        let reg = ConflictRuleRegistry::v01();
        let fwd = run_sweep(
            &[a.clone(), b.clone()],
            &times,
            &HashMap::new(),
            &HashSet::new(),
            &reg,
            SWEEP_DEFAULT_BUCKET_CAP,
        );
        let rev = run_sweep(
            &[b, a],
            &times,
            &HashMap::new(),
            &HashSet::new(),
            &reg,
            SWEEP_DEFAULT_BUCKET_CAP,
        );
        assert_eq!(fwd.proven.len(), 1);
        assert_eq!(rev.proven.len(), 1);
        assert_eq!(fwd.proven[0].outcome.result_id, rev.proven[0].outcome.result_id);
    }

    /// Mixed outcomes tally into the additive count lines; agreement and
    /// unknown-vs-known review are counted, not detailed.
    #[test]
    fn mixed_outcomes_tally() {
        let facts = vec![
            // Agreement pair (same value, different drawers).
            fact("f1", "Sarah Chen C0", "Acme Robotics", "d1"),
            fact("f2", "Sarah Chen C0", "Acme Robotics", "d2"),
            // Candidate-review pair (known vs unknown validity).
            fact("f3", "Noor Haddad C1", "Beta Corp", "d3"),
            fact("f4", "Noor Haddad C1", "Vireo Systems", "d4"),
        ];
        let report = run_sweep(
            &facts,
            // d4 has no event time → unknown validity → review.
            &seconds(&[("d1", 500), ("d2", 500), ("d3", 500)]),
            &HashMap::new(),
            &HashSet::new(),
            &ConflictRuleRegistry::v01(),
            SWEEP_DEFAULT_BUCKET_CAP,
        );
        assert_eq!(report.pairs_evaluated, 2);
        assert_eq!(report.counts.agreement, 1);
        assert_eq!(report.counts.candidate_review, 1);
        assert_eq!(report.counts.proven_contradiction, 0);
        assert!(report.proven.is_empty());
    }
}
