// Distillation.swift
//
// Thin NeuronKit lens wrapper over SubstrateML.DistillationPipeline.
//
// Responsibilities:
//   1. Provide the LatticeLib HMM tagger as the production FeatureExtractor
//      via `NeuronKit.hmmFeatureExtractor` (defaulting to
//      DistillationPipeline.defaultExtractor for tests).
//   2. Call DistillationPipeline.run(input:extractFeatures:).
//   3. Project DistillationOutput → DistillationLensResult (adds InjectionDepth).
//
// No pipeline logic in this file. See SubstrateML/DistillationPipeline.swift.
// Layer discipline B-1/B-2: no I/O, no state, no substrate touch.

import Foundation
import SubstrateML

/// NeuronKit-layer result shape. Carries the SubstrateML output plus
/// InjectionDepth, which governs how much provenance context the ARIA
/// layer appends alongside factoid prose.
public struct DistillationLensResult: Sendable {
    /// Pass-through from DistillationOutput.distilledText — the §5
    /// token-economical rendering (zero inline metadata).
    public let distilledText: String
    /// Confidence score conf(F*) ∈ [0, 1].
    public let confidence: Float32
    /// True when conf ∈ [0.4, 0.7): signal to inject with additional provenance.
    public let uncertain: Bool
    /// Cluster SNR at distillation time.
    public let snr: Float32
    /// DeltaType of the dominant feature, if non-static.
    public let deltaType: DeltaType?
    /// True when a factoid was successfully produced.
    public let succeeded: Bool
    /// Human-readable failure reason when succeeded == false.
    public let failureReason: String?
    /// Governs how much provenance context the ARIA layer appends alongside prose.
    public let injectionDepth: InjectionDepth
}

/// Controls how much provenance context is injected alongside a distilled factoid.
///
/// Thresholds must stay in lockstep with the Rust InjectionDepth in distillation.rs.
///
/// conf >= 0.7  → factoidOnly          (prose only; high-confidence factoid)
/// conf ∈ [0.4, 0.7) → factoidWithMeta      (prose + distillation metadata)
/// conf < 0.4   → factoidWithProvenance (prose + metadata + source drawer IDs)
public enum InjectionDepth: Sendable, Equatable {
    /// conf >= 0.7: prose only.
    case factoidOnly
    /// conf ∈ [0.4, 0.7): prose + [distilled from N memories, conf=X].
    case factoidWithMeta
    /// conf < 0.4: prose + [distilled, conf=X, sources: drawer_id].
    case factoidWithProvenance
}

extension NeuronKit {
    /// Thin wrapper: wires the feature extractor, calls the distillation pipeline,
    /// and projects the output into the NeuronKit lens result shape.
    ///
    /// - Parameters:
    ///   - input: cluster memories, optional timestamps, cluster UUID, source IDs.
    ///   - extractFeatures: feature extraction closure. Defaults to
    ///     `NeuronKit.hmmFeatureExtractor` — the production HMM-tagger-backed
    ///     extractor that produces byte-identical ENT/REL/NUM/TMP features on all
    ///     platforms (HMM path, cross-port parity guaranteed).
    ///     Pass `DistillationPipeline.defaultExtractor` explicitly for tests that
    ///     exercise the capitalization-heuristic stub without pulling the HMM path.
    /// - Returns: DistillationLensResult with injectionDepth derived from confidence.
    public static func distillCluster(
        input: DistillationInput,
        extractFeatures: DistillationPipeline.FeatureExtractor? = nil
    ) -> DistillationLensResult {
        // Default to the production HMM extractor (one door: all callers route here).
        // Test callers that need the stub pass DistillationPipeline.defaultExtractor.
        let extractor = extractFeatures ?? NeuronKit.hmmFeatureExtractor
        let output = DistillationPipeline.run(input: input, extractFeatures: extractor)
        let depth = injectionDepth(from: output.confidence)
        return DistillationLensResult(
            distilledText: output.distilledText,
            confidence: output.confidence,
            uncertain: output.uncertain,
            snr: output.snr,
            deltaType: output.deltaType,
            succeeded: output.succeeded,
            failureReason: output.failureReason,
            injectionDepth: depth
        )
    }
}

// MARK: - Private helpers

private func injectionDepth(from confidence: Float32) -> InjectionDepth {
    if confidence >= 0.7 {
        return .factoidOnly
    } else if confidence >= 0.4 {
        return .factoidWithMeta
    } else {
        return .factoidWithProvenance
    }
}
