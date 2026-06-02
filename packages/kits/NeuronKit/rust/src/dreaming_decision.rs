//! The deterministic DECISION CORE of the dreaming daemon's tick
//! (NEURONKIT_SPEC § 3.1 steps 3-6), the Rust side of NeuronKit's
//! Swift-parity Bucket A. Mirrors `DreamingDecision.swift` field for
//! field; both gate on the shared fixtures below.
//!
//! The Swift `DreamingDaemon` actor owns the async seam I/O (recall
//! traces, co-occurrence observations, existing tunnels), the proposal
//! emission, the diary write, and the across-cycle state. This module —
//! like its Swift twin — owns only the DECISIONS: the InfoNCE contrastive
//! score (step 3), the EWC++ consolidation blend (step 4), duplicate
//! suppression against existing tunnels + already-proposed keys (step 5),
//! and the confidence-AND-attempts gate (step 6).
//!
//! There is no Rust dreaming actor: the seam I/O is estate-bound (Bucket
//! B, waiting on the Rust LocusKit estate). The decision math is pure, so
//! it ships in Rust now and is conformance-gated against the Swift version.
//!
//! ```text
//! contrastive(evidence, reward, baseline):
//!   mean = sum(reward[t] for t in evidence) / |evidence|
//!   pos  = exp(mean / temperature)     ; temperature = 0.2
//!   neg  = exp(baseline / temperature)
//!   conf = pos / (pos + neg)           ; 0 if evidence is empty
//!
//! ewc++ per key:  effective = max(raw, consolidated[key] * 0.9)
//! gate:           emit iff effective >= minConfidence AND attempts >= minAttempts
//! ```

use std::collections::{BTreeMap, BTreeSet};

/// InfoNCE softmax temperature for the contrastive score (step 3).
/// Matches `DreamingDecision.temperature`.
pub const TEMPERATURE: f64 = 0.2;

/// EWC++ retention factor (step 4): a consolidated confidence decays by at
/// most this factor per barren cycle rather than being overwritten.
/// Matches `DreamingDecision.ewcRetention`.
pub const EWC_RETENTION: f32 = 0.9;

/// A latent co-occurrence candidate — the identity-free projection of the
/// Swift `CoOccurrenceObservation` (`RowID` is its `String` alias).
#[derive(Clone, Debug, PartialEq)]
pub struct Observation {
    pub endpoint_a: String,
    pub endpoint_b: String,
    pub attempts: i64,
    pub evidence_targets: Vec<String>,
}

/// A candidate the gate cleared for proposal. The Swift actor turns each
/// into a `ProposeFrame`; there is no Rust frame type (estate-bound).
#[derive(Clone, Debug, PartialEq)]
pub struct EmittedCandidate {
    pub key: String,
    pub endpoint_a: String,
    pub endpoint_b: String,
    pub attempts: i64,
    pub confidence: f32,
}

/// The cycle's decisions. `updated_consolidated` folds the EWC++ value for
/// every observation considered (not just the emitted ones).
#[derive(Clone, Debug, PartialEq)]
pub struct Outcome {
    pub emitted: Vec<EmittedCandidate>,
    pub suppressed_duplicates: usize,
    pub below_threshold: usize,
    pub scores: BTreeMap<String, f32>,
    pub updated_consolidated: BTreeMap<String, f32>,
}

/// Canonical, order-independent key for an endpoint pair, so A<->B and
/// B<->A collapse to one candidate. Matches `DreamingDecision.candidateKey`.
pub fn candidate_key(a: &str, b: &str) -> String {
    if a <= b {
        format!("{a}|{b}")
    } else {
        format!("{b}|{a}")
    }
}

/// InfoNCE-inspired contrastive confidence in `[0, 1]` (step 3). Positive
/// logit = mean derived reward of the evidence targets; negative logit =
/// `baseline`; two-way softmax at `TEMPERATURE`. No evidence -> 0. Matches
/// `DreamingDecision.contrastiveConfidence` (f64 exps narrowed to f32).
pub fn contrastive_confidence(
    evidence_targets: &[String],
    reward_by_target: &BTreeMap<String, f32>,
    baseline: f32,
) -> f32 {
    if evidence_targets.is_empty() {
        return 0.0;
    }
    let mut sum: f32 = 0.0;
    for target in evidence_targets {
        sum += reward_by_target.get(target).copied().unwrap_or(0.0);
    }
    let mean = sum / evidence_targets.len() as f32;
    let pos = ((mean as f64) / TEMPERATURE).exp();
    let neg = ((baseline as f64) / TEMPERATURE).exp();
    (pos / (pos + neg)) as f32
}

/// Decide one dreaming cycle over pre-gathered inputs (steps 3-6).
///
/// For each observation, in order: compute the contrastive score, blend
/// with `consolidated[key] * EWC_RETENTION` (keep the larger — step 4),
/// record it; suppress if the key duplicates an existing tunnel, an
/// already-proposed key, or a key emitted earlier this cycle; otherwise
/// emit iff `effective >= min_confidence && attempts >= min_attempts`.
#[allow(clippy::too_many_arguments)]
pub fn decide(
    observations: &[Observation],
    reward_by_target: &BTreeMap<String, f32>,
    existing_tunnel_keys: &BTreeSet<String>,
    already_proposed_keys: &BTreeSet<String>,
    consolidated: &BTreeMap<String, f32>,
    min_confidence: f32,
    min_attempts: i64,
    min_success_rate: f32,
) -> Outcome {
    let mut emitted: Vec<EmittedCandidate> = Vec::new();
    let mut suppressed_duplicates = 0usize;
    let mut below_threshold = 0usize;
    let mut scores: BTreeMap<String, f32> = BTreeMap::new();
    let mut updated_consolidated = consolidated.clone();
    // Keys emitted THIS cycle, so a duplicate pair within one batch is not
    // proposed twice (mirrors the actor inserting into proposedKeys as it
    // emits).
    let mut emitted_keys_this_cycle: BTreeSet<String> = BTreeSet::new();

    for obs in observations {
        let key = candidate_key(&obs.endpoint_a, &obs.endpoint_b);

        // Step 3 + 4: contrastive score, then EWC++ consolidation.
        let raw = contrastive_confidence(&obs.evidence_targets, reward_by_target, min_success_rate);
        let retained = updated_consolidated.get(&key).copied().unwrap_or(0.0) * EWC_RETENTION;
        let effective = raw.max(retained);
        updated_consolidated.insert(key.clone(), effective);
        scores.insert(key.clone(), effective);

        // Step 5: suppress duplicates of existing tunnels or prior /
        // this-cycle proposals.
        if existing_tunnel_keys.contains(&key)
            || already_proposed_keys.contains(&key)
            || emitted_keys_this_cycle.contains(&key)
        {
            suppressed_duplicates += 1;
            continue;
        }

        // Step 6: gate on confidence AND attempts.
        if effective >= min_confidence && obs.attempts >= min_attempts {
            emitted.push(EmittedCandidate {
                key: key.clone(),
                endpoint_a: obs.endpoint_a.clone(),
                endpoint_b: obs.endpoint_b.clone(),
                attempts: obs.attempts,
                confidence: effective,
            });
            emitted_keys_this_cycle.insert(key);
        } else {
            below_threshold += 1;
        }
    }

    Outcome {
        emitted,
        suppressed_duplicates,
        below_threshold,
        scores,
        updated_consolidated,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rewards(pairs: &[(&str, f32)]) -> BTreeMap<String, f32> {
        pairs.iter().map(|(k, v)| (k.to_string(), *v)).collect()
    }

    fn obs(a: &str, b: &str, attempts: i64, evidence: &[&str]) -> Observation {
        Observation {
            endpoint_a: a.to_string(),
            endpoint_b: b.to_string(),
            attempts,
            evidence_targets: evidence.iter().map(|s| s.to_string()).collect(),
        }
    }

    // DD-1: candidate_key is order-independent (a<->b == b<->a).
    #[test]
    fn dd1_candidate_key_is_order_independent() {
        assert_eq!(candidate_key("a", "b"), "a|b");
        assert_eq!(candidate_key("b", "a"), "a|b");
        assert_eq!(candidate_key("a", "b"), candidate_key("b", "a"));
    }

    // DD-2: used evidence (reward 1) scores high (>= 0.7); the Swift
    // fixture's "fully-used candidate scores ~= 0.88".
    #[test]
    fn dd2_used_evidence_scores_high() {
        let c = contrastive_confidence(
            &["r1".into(), "r2".into()],
            &rewards(&[("r1", 1.0), ("r2", 1.0)]),
            0.6,
        );
        assert!(c >= 0.7, "used evidence should clear the 0.7 gate, got {c}");
        assert!((c - 0.8808).abs() < 1e-3, "expected ~0.8808, got {c}");
    }

    // DD-3: unused evidence (reward 0) collapses toward 0 (< 0.1) — the
    // Swift EWC test's `freshRaw` assertion.
    #[test]
    fn dd3_unused_evidence_collapses() {
        let c = contrastive_confidence(
            &["r1".into(), "r2".into()],
            &rewards(&[("r1", 0.0), ("r2", 0.0)]),
            0.6,
        );
        assert!(c < 0.1, "unused evidence should collapse, got {c}");
    }

    // DD-4: no evidence -> guarded 0.
    #[test]
    fn dd4_empty_evidence_is_zero() {
        let c = contrastive_confidence(&[], &rewards(&[]), 0.6);
        assert_eq!(c, 0.0);
    }

    // DD-5: EWC++ keeps a prior strong association above the gate when the
    // fresh score collapses — the Swift
    // testEWC_PriorAssociationNotCatastrophicallyOverwritten core.
    #[test]
    fn dd5_ewc_preserves_prior_association() {
        // Cycle 1: strong evidence consolidates a high confidence.
        let c1 = decide(
            &[obs("a", "b", 9, &["r1", "r2"])],
            &rewards(&[("r1", 1.0), ("r2", 1.0)]),
            &BTreeSet::new(),
            &BTreeSet::new(),
            &BTreeMap::new(),
            0.7,
            5,
            0.6,
        );
        let key = candidate_key("a", "b");
        let first = c1.scores[&key];
        assert!(first >= 0.7);
        assert_eq!(c1.emitted.len(), 1);

        // Cycle 2: same candidate, only-unused evidence. Fresh raw
        // collapses, but effective = max(raw, retained*0.9) stays >= 0.7.
        let c2 = decide(
            &[obs("a", "b", 9, &["r1", "r2"])],
            &rewards(&[("r1", 0.0), ("r2", 0.0)]),
            &BTreeSet::new(),
            // Cycle 1 already proposed it; B-4 idempotency suppresses the
            // re-proposal but the consolidated score is still preserved.
            &c1.emitted.iter().map(|e| e.key.clone()).collect(),
            &c1.updated_consolidated,
            0.7,
            5,
            0.6,
        );
        let second = c2.scores[&key];
        let fresh_raw = contrastive_confidence(
            &["r1".into(), "r2".into()],
            &rewards(&[("r1", 0.0), ("r2", 0.0)]),
            0.6,
        );
        assert!(fresh_raw < 0.1);
        assert!(second >= 0.7, "prior preserved by EWC++, got {second}");
        assert!(second > fresh_raw);
        assert_eq!(
            c2.suppressed_duplicates, 1,
            "already-proposed key suppressed"
        );
        assert_eq!(c2.emitted.len(), 0);
    }

    // DD-6: a candidate duplicating an existing drawer-to-drawer tunnel is
    // suppressed, not emitted — the Swift duplicate-suppression test.
    #[test]
    fn dd6_existing_tunnel_suppresses_candidate() {
        let mut tunnels = BTreeSet::new();
        tunnels.insert(candidate_key("a", "b"));
        let out = decide(
            &[obs("a", "b", 9, &["r1", "r2"])],
            &rewards(&[("r1", 1.0), ("r2", 1.0)]),
            &tunnels,
            &BTreeSet::new(),
            &BTreeMap::new(),
            0.7,
            5,
            0.6,
        );
        assert_eq!(out.emitted.len(), 0);
        assert_eq!(out.suppressed_duplicates, 1);
    }

    // DD-7: the gate is confidence AND attempts — a high-confidence
    // candidate below minAttempts does not emit (it counts below-threshold).
    #[test]
    fn dd7_gate_requires_both_confidence_and_attempts() {
        let out = decide(
            &[obs("a", "b", 3, &["r1", "r2"])], // attempts 3 < minAttempts 5
            &rewards(&[("r1", 1.0), ("r2", 1.0)]),
            &BTreeSet::new(),
            &BTreeSet::new(),
            &BTreeMap::new(),
            0.7,
            5,
            0.6,
        );
        assert_eq!(out.emitted.len(), 0);
        assert_eq!(out.below_threshold, 1);
        // The score is still recorded and consolidated even when gated out.
        assert!(out.scores[&candidate_key("a", "b")] >= 0.7);
    }

    // DD-8: a within-batch duplicate pair (A<->B then B<->A) is proposed
    // exactly once; the second collapses to suppression.
    #[test]
    fn dd8_within_batch_duplicate_emitted_once() {
        let out = decide(
            &[
                obs("a", "b", 9, &["r1", "r2"]),
                obs("b", "a", 9, &["r1", "r2"]),
            ],
            &rewards(&[("r1", 1.0), ("r2", 1.0)]),
            &BTreeSet::new(),
            &BTreeSet::new(),
            &BTreeMap::new(),
            0.7,
            5,
            0.6,
        );
        assert_eq!(out.emitted.len(), 1, "the symmetric pair emits once");
        assert_eq!(out.suppressed_duplicates, 1);
    }
}
