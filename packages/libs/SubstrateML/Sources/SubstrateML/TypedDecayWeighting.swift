// TypedDecayWeighting.swift
//
// Type-specific exponential decay weights per DISTILLATION_MATH_DIFFUSION.md §2.
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

import Foundation

/// Feature type classification for distillation scoring.
///
/// Raw values are the canonical type tags in the DIST content header
/// (e.g. "[DIST|conf=0.85|src=5|snr=6.2|delta=STATIC]").
///
/// Decay rates mirror diffusion noise schedules: high-frequency features
/// (numerical, e.g. version numbers) become stale quickly; low-frequency
/// features (entities, e.g. domain concepts) persist across major changes.
public enum DistillationFeatureType: String, Sendable, Codable, CaseIterable {
    case entity    = "ENT"
    case relation  = "REL"
    case temporal  = "TMP"
    case numerical = "NUM"

    /// Exponential decay rate λ for this feature type.
    /// Higher λ means faster staleness. Values from DISTILLATION_MATH_DIFFUSION.md §2.
    public var decayLambda: Float32 {
        switch self {
        case .entity:    return 0.1
        case .relation:  return 0.2
        case .temporal:  return 0.5
        case .numerical: return 0.8
        }
    }
}

/// Type-specific exponential decay weighting for distillation features.
/// Pure computation namespace; no state, no I/O.
public enum TypedDecayWeighting {

    /// Temporal weight for a feature observation at `ageInUnits` time units
    /// before the reference date.
    ///
    /// Formula: w = exp(-λ × ageInUnits)
    ///
    /// - Parameters:
    ///   - featureType: Determines λ via `decayLambda`.
    ///   - ageInUnits:  Age of the observation in time units (1 unit = 86 400 s by
    ///                  convention, though the caller chooses the unit). Negative
    ///                  values are clamped to 0 (future timestamps treated as present).
    /// - Returns: Weight in [0, 1]. Returns 1.0 at age 0.
    public static func weight(featureType: DistillationFeatureType, ageInUnits: Float32) -> Float32 {
        exp(-featureType.decayLambda * max(0, ageInUnits))
    }

    /// Weighted document frequency df_w(f) per DISTILLATION_MATH_DIFFUSION.md §2.
    ///
    /// Computes how much of the cluster's total temporal weight is attributable
    /// to observations where feature f is present:
    ///
    ///   W(type(f)) = Σ_{i=1}^{M} exp(-λ × age_i)       type-aware normalizer over all M memories
    ///   df_w(f)    = [Σ_{i: X_{if}=1} exp(-λ × age_i)] / W(type(f))
    ///
    /// where age_i = (referenceDate − timestamp_i) / timeUnit.
    ///
    /// - Parameters:
    ///   - featureType:         Determines λ.
    ///   - presenceTimestamps:  Timestamps of memories where feature f is present (X_if = 1).
    ///   - allMemoryTimestamps: All M memory timestamps in the cluster (M ≥ presence count).
    ///   - referenceDate:       The "now" anchor; ages are computed relative to this date.
    ///   - timeUnit:            Duration of one age unit in seconds (default: 86 400 = 1 day).
    /// - Returns: Weighted frequency in [0, 1]. Returns 0 when `allMemoryTimestamps` is empty.
    public static func weightedDocFrequency(
        featureType: DistillationFeatureType,
        presenceTimestamps: [Date],
        allMemoryTimestamps: [Date],
        referenceDate: Date,
        timeUnit: Double = 86_400
    ) -> Float32 {
        guard !allMemoryTimestamps.isEmpty else { return 0 }

        let lambda = featureType.decayLambda

        // Converts a timestamp to age in time units, clamped to [0, ∞).
        func ageWeight(_ date: Date) -> Float32 {
            let seconds = referenceDate.timeIntervalSince(date)
            return exp(-lambda * Float32(max(0, seconds / timeUnit)))
        }

        // W(type(f)): sum of weights across all M memories.
        let totalWeight = allMemoryTimestamps.reduce(Float32(0)) { $0 + ageWeight($1) }
        guard totalWeight > 0 else { return 0 }

        // Numerator: sum of weights only where feature f is present.
        let presenceWeight = presenceTimestamps.reduce(Float32(0)) { $0 + ageWeight($1) }

        return presenceWeight / totalWeight
    }
}
