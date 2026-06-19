// typed_decay_weighting.rs
//
// Type-specific exponential decay weights per DISTILLATION_MATH_DIFFUSION.md §2.
// Rust port of TypedDecayWeighting.swift. Parity conformance to be verified in Dp1.
//
// The distillation pipeline treats different feature categories as analogous to
// frequency bands in diffusion noise schedules — high-frequency features (NUM)
// decay fastest, low-frequency features (ENT) persist longest:
//
//   λ by type: ENT=0.1, REL=0.2, TMP=0.5, NUM=0.8
//
// Implements the type-aware temporal weight:
//   w_i(f) = exp(-λ_{type(f)} × Δt_i)
//
// And the weighted document frequency per DISTILLATION_MATH_DIFFUSION.md §2:
//   W(type(f)) = Σ_{i=1}^{M} exp(-λ × age_i)            type-aware normalizer
//   df_w(f)    = [Σ_{i: X_{if}=1} exp(-λ × age_i)] / W(type(f))
//
// Used by:
//   DistillationScorer — Stage 4 temporal weighting
//   DistillationPipeline — feature score computation

/// Feature type classification for distillation scoring.
///
/// String representations match Swift DistillationFeatureType.rawValue exactly —
/// required for Dp1 bit-identical conformance on the DIST content header.
///
/// Decay rates mirror diffusion noise schedules: high-frequency features
/// (numerical, e.g. version numbers) become stale quickly; low-frequency
/// features (entities, e.g. domain concepts) persist across major changes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DistillationFeatureType {
    /// Entity features (domain concepts, named things). λ = 0.1 — slowest decay.
    Entity,
    /// Relation features (connections between entities). λ = 0.2.
    Relation,
    /// Temporal features (time-anchored facts). λ = 0.5.
    Temporal,
    /// Numerical features (counts, versions, measurements). λ = 0.8 — fastest decay.
    Numerical,
}

impl DistillationFeatureType {
    /// Canonical uppercase tag matching Swift DistillationFeatureType.rawValue.
    pub fn as_str(&self) -> &'static str {
        match self {
            DistillationFeatureType::Entity    => "ENT",
            DistillationFeatureType::Relation  => "REL",
            DistillationFeatureType::Temporal  => "TMP",
            DistillationFeatureType::Numerical => "NUM",
        }
    }

    /// Exponential decay rate λ for this feature type.
    /// Higher λ means faster staleness. Values from DISTILLATION_MATH_DIFFUSION.md §2.
    pub fn decay_lambda(&self) -> f32 {
        match self {
            DistillationFeatureType::Entity    => 0.1,
            DistillationFeatureType::Relation  => 0.2,
            DistillationFeatureType::Temporal  => 0.5,
            DistillationFeatureType::Numerical => 0.8,
        }
    }
}

/// Type-specific exponential decay weighting for distillation features.
/// Pure computation namespace; no state, no I/O.
pub struct TypedDecayWeighting;

impl TypedDecayWeighting {
    /// Temporal weight for a feature observation at `age_in_units` time units
    /// before the reference date.
    ///
    /// Formula: w = exp(-λ × age_in_units)
    ///
    /// Negative ages are clamped to 0 (future timestamps treated as present).
    /// Returns 1.0 at age 0.
    pub fn weight(feature_type: DistillationFeatureType, age_in_units: f32) -> f32 {
        let lambda = feature_type.decay_lambda();
        f32::exp(-lambda * age_in_units.max(0.0))
    }

    /// Weighted document frequency df_w(f) per DISTILLATION_MATH_DIFFUSION.md §2.
    ///
    /// Computes how much of the cluster's total temporal weight is attributable
    /// to observations where feature f is present:
    ///
    ///   W(type(f)) = Σ_{i=1}^{M} exp(-λ × age_i)   type-aware normalizer over all M memories
    ///   df_w(f)    = [Σ_{i: X_{if}=1} exp(-λ × age_i)] / W(type(f))
    ///
    /// where age_i = (reference_epoch_secs − timestamp_i) / time_unit_secs.
    ///
    /// Timestamps are f64 Unix epoch seconds. Age arithmetic is f64 to preserve
    /// precision; the final weight computation is f32 matching Swift's Float32.
    ///
    /// Returns 0.0 when `all_memory_epoch_secs` is empty or total weight is zero.
    pub fn weighted_doc_frequency(
        feature_type: DistillationFeatureType,
        presence_epoch_secs: &[f64],
        all_memory_epoch_secs: &[f64],
        reference_epoch_secs: f64,
        time_unit_secs: f64,
    ) -> f32 {
        if all_memory_epoch_secs.is_empty() {
            return 0.0;
        }

        let lambda = feature_type.decay_lambda();

        // Converts a timestamp (f64 epoch secs) to its f32 decay weight.
        let age_weight = |ts: f64| -> f32 {
            let age_units = ((reference_epoch_secs - ts) / time_unit_secs).max(0.0) as f32;
            f32::exp(-lambda * age_units)
        };

        // W(type(f)): sum of weights across all M memories.
        let total_weight: f32 = all_memory_epoch_secs.iter().map(|&ts| age_weight(ts)).sum();
        if total_weight <= 0.0 {
            return 0.0;
        }

        // Numerator: sum of weights only where feature f is present.
        let presence_weight: f32 = presence_epoch_secs.iter().map(|&ts| age_weight(ts)).sum();

        presence_weight / total_weight
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decay_lambda_entity() {
        assert_eq!(DistillationFeatureType::Entity.decay_lambda(), 0.1_f32);
    }

    #[test]
    fn decay_lambda_relation() {
        assert_eq!(DistillationFeatureType::Relation.decay_lambda(), 0.2_f32);
    }

    #[test]
    fn decay_lambda_temporal() {
        assert_eq!(DistillationFeatureType::Temporal.decay_lambda(), 0.5_f32);
    }

    #[test]
    fn decay_lambda_numerical() {
        assert_eq!(DistillationFeatureType::Numerical.decay_lambda(), 0.8_f32);
    }

    #[test]
    fn weight_at_age_zero_is_one() {
        let w = TypedDecayWeighting::weight(DistillationFeatureType::Entity, 0.0);
        assert_eq!(w, 1.0_f32);
    }

    #[test]
    fn weight_entity_age_5() {
        // exp(-0.1 * 5.0) = exp(-0.5) ≈ 0.60653066
        let w = TypedDecayWeighting::weight(DistillationFeatureType::Entity, 5.0);
        assert!((w - 0.6065_f32).abs() < 1e-4_f32, "got {w}");
    }

    #[test]
    fn weight_numerical_age_5() {
        // exp(-0.8 * 5.0) = exp(-4.0) ≈ 0.018316
        let w = TypedDecayWeighting::weight(DistillationFeatureType::Numerical, 5.0);
        assert!((w - 0.0183_f32).abs() < 1e-4_f32, "got {w}");
    }

    #[test]
    fn weight_negative_age_clamped_to_one() {
        // Negative age (future timestamp) is clamped to 0 → weight = 1.0.
        let w = TypedDecayWeighting::weight(DistillationFeatureType::Numerical, -3.0);
        assert_eq!(w, 1.0_f32);
    }

    #[test]
    fn weighted_doc_frequency_empty_returns_zero() {
        let wdf = TypedDecayWeighting::weighted_doc_frequency(
            DistillationFeatureType::Entity,
            &[],
            &[],
            1_000_000.0,
            86_400.0,
        );
        assert_eq!(wdf, 0.0_f32);
    }

    #[test]
    fn weighted_doc_frequency_full_presence_returns_one() {
        // When presence = all memories, df_w = W / W = 1.0.
        let timestamps = [1_000_000.0_f64, 1_086_400.0_f64, 1_172_800.0_f64];
        let reference = 1_259_200.0_f64;
        let wdf = TypedDecayWeighting::weighted_doc_frequency(
            DistillationFeatureType::Entity,
            &timestamps,
            &timestamps,
            reference,
            86_400.0,
        );
        assert!((wdf - 1.0_f32).abs() < 1e-6_f32, "got {wdf}");
    }

    #[test]
    fn weighted_doc_frequency_no_presence_returns_zero() {
        let all_timestamps = [1_000_000.0_f64, 1_086_400.0_f64];
        let reference = 1_259_200.0_f64;
        let wdf = TypedDecayWeighting::weighted_doc_frequency(
            DistillationFeatureType::Entity,
            &[],   // no presence
            &all_timestamps,
            reference,
            86_400.0,
        );
        assert_eq!(wdf, 0.0_f32);
    }

    #[test]
    fn as_str_canonical_tags() {
        assert_eq!(DistillationFeatureType::Entity.as_str(),    "ENT");
        assert_eq!(DistillationFeatureType::Relation.as_str(),  "REL");
        assert_eq!(DistillationFeatureType::Temporal.as_str(),  "TMP");
        assert_eq!(DistillationFeatureType::Numerical.as_str(), "NUM");
    }
}
