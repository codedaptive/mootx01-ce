// brain/distillation_cycle.rs — Rust mirror of DistillationCycle.swift.
//
// Per-item distillation for GeniusLocusKit.
//
// Implements the pure decision surface for the intra-item distillation model:
// each stored item is reduced from its OWN sentences. This module supplies the
// pure functions and constants the Coordinator delegates to.
//
// Storage I/O (`drawers`, `tunnels`) lives at the Coordinator level where
// the storage handle is available. This module defines only the pure
// algorithmic types and decision functions.

use substrate_ml::distillation_pipeline::DistillationOutput;
use substrate_types::fingerprint256::Fingerprint256;

// MARK: - Intra-item distillation decision

/// Minimum number of reduction units (sentences) an item needs to be
/// distillable intra-item. With M < 3 every feature has df = 1.0, so every
/// pairwise PMI = 0, the coherence graph fragments, and no honest factoid can
/// form — a too-short item is simply not distilled.
///
/// Mirrors the `guard sentences.count >= 3` in Swift `distillItem`.
pub const MIN_INTRA_ITEM_UNITS: usize = 3;

/// Decide whether an intra-item `DistillationOutput` should be captured as a
/// factoid.
///
/// Unlike the cross-memory sweep (which gates on confidence ≥ 0.4 and the SNR
/// hold), intra-item distillation produces a factoid whenever the pipeline
/// computed a real dominant component F* — i.e. whenever the feature
/// fingerprint is non-zero. For a single item the factoid is always emitted
/// from the item's recurring core; confidence rides along as metadata (the
/// `uncertain` flag / injection depth), it does NOT gate production. The
/// early-failure paths (no features, empty F*) yield a zero fingerprint and
/// are correctly skipped.
///
/// Mirrors the `guard output.featureFingerprint != .zero else { return nil }`
/// production gate in Swift `distillItem`. Pure function — no I/O.
pub fn should_produce_intra_item_factoid(output: &DistillationOutput) -> bool {
    output.feature_fingerprint != Fingerprint256::ZERO
}

/// Whether an item with `unit_count` reduction units (sentences) is long enough
/// to attempt intra-item distillation. Mirrors the Swift `≥ 3` guard.
pub fn item_is_distillable(unit_count: usize) -> bool {
    unit_count >= MIN_INTRA_ITEM_UNITS
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
    use substrate_ml::distillation_pipeline::DistillationOutput;

    // MARK: - intra-item decision tests

    #[test]
    fn intra_item_produces_when_fingerprint_non_zero() {
        let mut output = make_output(true, 0.85, 4.0, None);
        output.feature_fingerprint = Fingerprint256::new(1, 0, 0, 0);
        assert!(should_produce_intra_item_factoid(&output));
    }

    #[test]
    fn intra_item_produces_even_when_confidence_low() {
        // Intra-item produces whenever F* is non-zero — confidence is metadata,
        // not a gate. The pipeline's confidence value rides along as the uncertain
        // flag / injection depth; it does not block factoid production.
        let mut output = make_output(false, 0.2, 0.5, Some("low conf".to_string()));
        output.feature_fingerprint = Fingerprint256::new(0, 0, 0, 7);
        assert!(should_produce_intra_item_factoid(&output));
    }

    #[test]
    fn intra_item_skips_when_fingerprint_zero() {
        // No dominant component (empty F*) → zero fingerprint → not produced.
        let output = make_output(false, 0.0, 0.0, Some("PMI graph produced no dominant component".to_string()));
        assert!(!should_produce_intra_item_factoid(&output));
    }

    #[test]
    fn item_distillable_requires_three_units() {
        assert!(!item_is_distillable(0));
        assert!(!item_is_distillable(1));
        assert!(!item_is_distillable(2));
        assert!(item_is_distillable(3));
        assert!(item_is_distillable(10));
        assert_eq!(MIN_INTRA_ITEM_UNITS, 3);
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
