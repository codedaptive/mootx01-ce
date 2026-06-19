// brain/distillation_cycle.rs — Rust mirror of DistillationCycle.swift (DG5).
//
// Cluster assignment write-path and hourly distillation sweep for
// GeniusLocusKit. Mirrors the two halves of the distillation cycle
// described in DISTILLATION_DESIGN.md §5:
//
//   1. assign_cluster — Hamming-distance gated cluster join/seed decision.
//      Called after every successful capture. If the nearest stored vector
//      is within Hamming distance ≤ 64 and belongs to an open cluster, the
//      new drawer joins that cluster. Otherwise a new single-member cluster
//      is seeded.
//
//   2. run_distillation_sweep — processes all open clusters with
//      member_count ≥ 3. Calls the injected distill_fn and handles three
//      outcomes: succeeded (conf ≥ 0.4), held (SNR < 2.0), failed.
//
// NeuronKit is NOT a GeniusLocusKit dependency in the Rust port, so the
// distillation function is injected as a closure (DistillationInput →
// DistillationOutput). Both DistillationInput and DistillationOutput are
// defined in SubstrateML.
//
// Storage I/O (reading/writing `memory_clusters`, `drawers`, `tunnels`)
// lives at the Coordinator level where the storage handle is available.
// This module defines the pure algorithmic types and decision functions
// that the Coordinator delegates to.

use substrate_ml::distillation_pipeline::DistillationOutput;
use substrate_types::fingerprint256::Fingerprint256;

// MARK: - Cluster assignment decision

/// Outcome of the `assign_cluster_decision` function.
///
/// The coordinator inspects this to determine whether to:
///   - `Joined`: append `drawer_id` to `cluster_id`'s member list and
///     increment member_count.
///   - `Seeded`: insert a new single-member open cluster row.
#[derive(Debug, Clone, PartialEq)]
pub enum ClusterAssignmentDecision {
    /// The drawer joins an existing open cluster.
    Joined {
        /// UUID string of the cluster to append to.
        cluster_id: String,
    },
    /// No open cluster was close enough; seed a new one.
    Seeded,
}

/// Determine whether a newly captured drawer joins an existing cluster or
/// seeds a new one.
///
/// Mirrors Swift `assignCluster`'s inner Hamming gate and cluster lookup:
///   - `nearest_item_id`: the nearest VectorKit neighbor's item ID, if any
///     (after excluding a self-hit where `nearest_id == drawer_id`).
///   - `nearest_distance`: Hamming distance to that neighbor (0–256).
///   - `open_cluster_id`: the open cluster containing `nearest_item_id`,
///     if the coordinator found one.
///
/// Returns `ClusterAssignmentDecision::Joined` when the nearest neighbor is
/// within the consistency threshold (distance ≤ 64) AND belongs to an open
/// cluster. Returns `ClusterAssignmentDecision::Seeded` otherwise.
///
/// Pure function — no I/O. The coordinator resolves the VectorKit query and
/// open-cluster lookup before calling this.
pub fn assign_cluster_decision(
    nearest_distance: Option<u32>,
    open_cluster_id: Option<String>,
) -> ClusterAssignmentDecision {
    // Hamming consistency threshold per DISTILLATION_DESIGN.md §4: ≤ 64 bits.
    const HAMMING_GATE: u32 = 64;

    if let (Some(distance), Some(cluster_id)) = (nearest_distance, open_cluster_id) {
        if distance <= HAMMING_GATE {
            return ClusterAssignmentDecision::Joined { cluster_id };
        }
    }
    ClusterAssignmentDecision::Seeded
}

// MARK: - Distillation sweep outcome

/// Outcome of processing one cluster in the distillation sweep.
///
/// The coordinator maps this to the `status` column update and, on
/// `Succeeded`, captures the factoid drawer and writes tunnels.
#[derive(Debug, Clone, PartialEq)]
pub enum SweepOutcome {
    /// conf ≥ 0.4 and SNR gate passed. The coordinator must:
    ///   - Capture a `_distilled` drawer with `drawer_content`.
    ///   - Store `feature_fingerprint` in VectorKit's "distillation-features-v1" lane.
    ///   - Write M `_distilled_from` tunnels (source = factoid, target = source drawer).
    ///   - Update cluster status to "distilled" with `factoid_id`.
    Succeeded {
        drawer_content: String,
        feature_fingerprint: Fingerprint256,
        snr: f32,
    },
    /// !succeeded and SNR < 2.0. Cluster not dense enough yet.
    /// Update cluster status to "held" with `held_reason`.
    Held {
        snr: f32,
        held_reason: String,
    },
    /// !succeeded and SNR ≥ 2.0 (or explicit pipeline failure).
    /// Update cluster status to "failed".
    Failed {
        snr: f32,
        failure_reason: Option<String>,
    },
}

/// SNR gate threshold: clusters below this are held for more data.
/// Mirrors Swift's `output.snr < 2.0` check in runDistillationSweep.
pub const SNR_GATE: f32 = 2.0;

/// Confidence gate threshold: distillations below this are failed or held.
/// Mirrors Swift's `output.confidence >= 0.4` success condition.
pub const CONFIDENCE_GATE: f32 = 0.4;

/// Classify a `DistillationOutput` into a `SweepOutcome`.
///
/// Mirrors the three-way if/else in Swift's `runDistillationSweep`:
///   1. `!succeeded && snr < SNR_GATE`  → Held
///   2. `succeeded && confidence ≥ CONFIDENCE_GATE` → Succeeded
///   3. otherwise → Failed
///
/// Pure function — no I/O.
pub fn classify_sweep_output(output: &DistillationOutput) -> SweepOutcome {
    if !output.succeeded && output.snr < SNR_GATE {
        SweepOutcome::Held {
            snr: output.snr,
            held_reason: output
                .failure_reason
                .clone()
                .unwrap_or_else(|| format!("SNR {} < {}", output.snr, SNR_GATE)),
        }
    } else if output.succeeded && output.confidence >= CONFIDENCE_GATE {
        SweepOutcome::Succeeded {
            drawer_content: output.drawer_content.clone(),
            feature_fingerprint: output.feature_fingerprint,
            snr: output.snr,
        }
    } else {
        SweepOutcome::Failed {
            snr: output.snr,
            failure_reason: output.failure_reason.clone(),
        }
    }
}

// MARK: - Distillation lane constants

/// VectorKit model ID for the structural fingerprint distillation lane.
/// Second VectorKit lane, independent of the prose embedding lane.
/// Enables no-inference Hamming NN via `find_nearest_distilled`.
pub const DISTILLATION_LANE_MODEL_ID: &str = "distillation-features-v1";

/// The UDC Knowledge class code stamped onto `_distilled` factoid drawers.
/// Non-empty per spec I-5. "001" = Knowledge/Epistemology — appropriate for
/// synthesized knowledge drawers.
pub const DISTILLED_DRAWER_UDC_CODE: &str = "001";

/// Room where distilled factoid drawers are filed.
pub const DISTILLED_ROOM: &str = "_distilled";

/// Tunnel label written from each factoid drawer to its M source drawers.
/// Direction: source = factoidID (synthesis), target = raw memory drawer ID.
pub const DISTILLED_FROM_LABEL: &str = "_distilled_from";

/// Actor identifier written into distilled factoid drawers and tunnel rows.
pub const DISTILLATION_DAEMON_ACTOR: &str = "distillation-daemon";

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;
    use substrate_ml::distillation_pipeline::{DistillationInput, DistillationOutput, DistillationPipeline};

    // MARK: - assign_cluster_decision tests

    #[test]
    fn seeds_new_cluster_when_no_nearest_neighbor() {
        let decision = assign_cluster_decision(None, None);
        assert_eq!(decision, ClusterAssignmentDecision::Seeded);
    }

    #[test]
    fn seeds_new_cluster_when_distance_exceeds_gate() {
        // distance = 65 > HAMMING_GATE (64) → seed new cluster.
        let decision = assign_cluster_decision(
            Some(65),
            Some("cluster-abc".to_string()),
        );
        assert_eq!(decision, ClusterAssignmentDecision::Seeded);
    }

    #[test]
    fn joins_cluster_when_distance_within_gate() {
        // distance = 64 ≤ HAMMING_GATE → join.
        let decision = assign_cluster_decision(
            Some(64),
            Some("cluster-xyz".to_string()),
        );
        assert_eq!(
            decision,
            ClusterAssignmentDecision::Joined {
                cluster_id: "cluster-xyz".to_string()
            }
        );
    }

    #[test]
    fn joins_cluster_when_distance_is_zero() {
        let decision = assign_cluster_decision(
            Some(0),
            Some("cluster-zero".to_string()),
        );
        assert_eq!(
            decision,
            ClusterAssignmentDecision::Joined {
                cluster_id: "cluster-zero".to_string()
            }
        );
    }

    #[test]
    fn seeds_when_distance_within_gate_but_no_open_cluster() {
        // Nearest neighbor is close but doesn't belong to an open cluster.
        let decision = assign_cluster_decision(Some(10), None);
        assert_eq!(decision, ClusterAssignmentDecision::Seeded);
    }

    // MARK: - classify_sweep_output tests

    #[test]
    fn classifies_held_when_not_succeeded_and_snr_below_gate() {
        let output = make_output(false, 0.0, 1.0, None);
        match classify_sweep_output(&output) {
            SweepOutcome::Held { snr, .. } => assert_eq!(snr, 1.0),
            other => panic!("expected Held, got {:?}", other),
        }
    }

    #[test]
    fn classifies_succeeded_when_succeeded_and_confidence_above_gate() {
        let output = make_output(true, 0.80, 3.5, None);
        match classify_sweep_output(&output) {
            SweepOutcome::Succeeded { snr, .. } => assert_eq!(snr, 3.5),
            other => panic!("expected Succeeded, got {:?}", other),
        }
    }

    #[test]
    fn classifies_failed_when_not_succeeded_and_snr_above_gate() {
        // !succeeded and SNR ≥ 2.0 → Failed.
        let output = make_output(false, 0.2, 2.5, Some("confidence too low".to_string()));
        match classify_sweep_output(&output) {
            SweepOutcome::Failed { snr, failure_reason } => {
                assert_eq!(snr, 2.5);
                assert!(failure_reason.is_some());
            }
            other => panic!("expected Failed, got {:?}", other),
        }
    }

    #[test]
    fn classifies_failed_when_succeeded_false_and_conf_zero_and_snr_exactly_at_gate() {
        // SNR == 2.0 is not < 2.0, so this falls into Failed, not Held.
        let output = make_output(false, 0.0, 2.0, None);
        match classify_sweep_output(&output) {
            SweepOutcome::Failed { .. } => {}
            other => panic!("expected Failed at SNR == gate, got {:?}", other),
        }
    }

    #[test]
    fn pipeline_run_integration_with_classify() {
        // Run the real pipeline on a three-memory cluster with overlapping
        // named entities. Verify that classify_sweep_output parses the
        // result without panicking.
        let input = DistillationInput::new(
            vec![
                "Alice spoke to Bob and Carol about the project".to_string(),
                "Bob reported to Alice that Carol had finished".to_string(),
                "Carol confirmed with Alice and Bob the deadline".to_string(),
            ],
            None,
            "test-cluster-rust-dc",
            vec!["src-1".to_string(), "src-2".to_string(), "src-3".to_string()],
        );
        let output = DistillationPipeline::run(&input, DistillationPipeline::default_extractor);
        let outcome = classify_sweep_output(&output);
        // The outcome may be Succeeded, Held, or Failed depending on pipeline
        // internals. The contract is that classify_sweep_output covers all
        // cases without panicking and returns a well-formed variant.
        match outcome {
            SweepOutcome::Succeeded { .. }
            | SweepOutcome::Held { .. }
            | SweepOutcome::Failed { .. } => {}
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    fn make_output(
        succeeded: bool,
        confidence: f32,
        snr: f32,
        failure_reason: Option<String>,
    ) -> DistillationOutput {
        use substrate_types::fingerprint256::Fingerprint256;
        DistillationOutput {
            drawer_content: if succeeded {
                format!("[DIST|conf={:.2}|src=3|snr={:.1}|delta=STATIC] test", confidence, snr)
            } else {
                String::new()
            },
            confidence,
            uncertain: false,
            snr,
            delta_type: None,
            succeeded,
            failure_reason,
            feature_fingerprint: Fingerprint256::ZERO,
        }
    }
}
