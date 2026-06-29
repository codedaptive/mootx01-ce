// DistillationScorerTests.swift
//
// Tests for DistillationScorer: structural (recurrence) threshold, SNR gate, PMI graph,
// connected components, dominant component selection, and confidence scoring.
//
// ExtractedFeature and DistillationFeatureType (TypedDecayWeighting.swift)
// are in this module.

import Testing
@testable import SubstrateML

struct DistillationScorerTests {

    // MARK: - binaryEntropy

    @Test func binaryEntropy_zero_returnsZero() {
        #expect(DistillationScorer.binaryEntropy(0) == 0)
    }

    @Test func binaryEntropy_one_returnsZero() {
        #expect(DistillationScorer.binaryEntropy(1) == 0)
    }

    @Test func binaryEntropy_half_returnsOne() {
        // H(0.5) = -(0.5 · log₂(0.5)) × 2 = 1.0
        #expect(abs(DistillationScorer.binaryEntropy(0.5) - 1.0) < 1e-5)
    }

    // MARK: - structuralThreshold (τ_struct = 2 / M)

    @Test func structuralThreshold_M3() {
        // 2/3 ≈ 0.667 — a feature recurring in ≥2 of 3 units passes.
        let τ = DistillationScorer.structuralThreshold(M: 3)
        #expect(abs(τ - Float32(2) / Float32(3)) < 1e-5)
    }

    @Test func structuralThreshold_M4() {
        // 2/4 = 0.5 — recurs in ≥2 of 4 units.
        let τ = DistillationScorer.structuralThreshold(M: 4)
        #expect(abs(τ - 0.5) < 1e-5)
    }

    @Test func structuralThreshold_M5() {
        // 2/5 = 0.4 — recurs in ≥2 of 5 units.
        let τ = DistillationScorer.structuralThreshold(M: 5)
        #expect(abs(τ - 0.4) < 1e-5)
    }

    @Test func structuralThreshold_M1_isTwo() {
        // M=1 → τ=2.0: nothing recurs, a single un-chunked unit is not distillable.
        let τ = DistillationScorer.structuralThreshold(M: 1)
        #expect(abs(τ - 2.0) < 1e-5)
    }

    // MARK: - applyStructuralThreshold

    @Test func applyStructuralThreshold_splitsCorrectly() {
        let M = 5
        let τ = DistillationScorer.structuralThreshold(M: M)  // 0.4
        let features = [
            ExtractedFeature(type: .entity,   value: "A", docFrequency: 0.8),  // passes
            ExtractedFeature(type: .relation, value: "B", docFrequency: 0.2),  // fails (1 of 5)
            ExtractedFeature(type: .temporal, value: "C", docFrequency: 0.4),  // passes (== τ, 2 of 5)
        ]
        let (passing, failing) = DistillationScorer.applyStructuralThreshold(
            features: features, M: M
        )
        #expect(passing.count == 2)
        #expect(failing.count == 1)
        #expect(passing.allSatisfy { $0.docFrequency >= τ })
        #expect(failing.allSatisfy { $0.docFrequency < τ })
    }

    // MARK: - computeSNR

    @Test func computeSNR_pureStructuralCluster_readyToDistill() {
        // M=3, all 3 features appear in all 3 memories (df=1.0).
        // structuralSignal = Σ df = 3.0 (raw df, spec §1); episodicNoise = 0.
        let features = [
            ExtractedFeature(type: .entity,   value: "A", docFrequency: 1.0),
            ExtractedFeature(type: .entity,   value: "B", docFrequency: 1.0),
            ExtractedFeature(type: .relation, value: "C", docFrequency: 1.0),
        ]
        let snr = DistillationScorer.computeSNR(features: features, M: 3)
        #expect(snr.readyToDistill == true)
        #expect(snr.snr >= 2.0)
        #expect(snr.structuralSignal > 0)
        #expect(snr.episodicNoise == 0)
    }

    @Test func computeSNR_allNoiseCluster_notReadyToDistill() {
        // M=5, τ_struct = 2/5 = 0.4; all features at df=0.2 (each in 1 of 5
        // memories), below threshold → no structural signal, all episodic.
        let features = [
            ExtractedFeature(type: .entity,    value: "A", docFrequency: 0.2),
            ExtractedFeature(type: .temporal,  value: "B", docFrequency: 0.2),
            ExtractedFeature(type: .numerical, value: "C", docFrequency: 0.2),
        ]
        let snr = DistillationScorer.computeSNR(features: features, M: 5)
        #expect(snr.readyToDistill == false)
        #expect(snr.snr < 2.0)
        #expect(snr.structuralSignal == 0)
        #expect(snr.episodicNoise > 0)
    }

    @Test func computeSNR_rawDfValueConformance() {
        // Cross-port anti-drift pin: SNR uses RAW df on BOTH terms (spec §1),
        // identical to Rust distillation_scorer::tests::compute_snr_raw_df_value_conformance.
        // M=4 → τ_struct = 2/4 = 0.5. Structural {1.0, 0.75, 0.5} → Σ = 2.25;
        // episodic {0.25, 0.25} → Σ = 0.5; snr = 2.25 / 0.5 = 4.5.
        let features = [
            ExtractedFeature(type: .entity, value: "a", docFrequency: 1.0),
            ExtractedFeature(type: .entity, value: "b", docFrequency: 0.75),
            ExtractedFeature(type: .entity, value: "c", docFrequency: 0.5),
            ExtractedFeature(type: .entity, value: "d", docFrequency: 0.25),
            ExtractedFeature(type: .entity, value: "e", docFrequency: 0.25),
        ]
        let snr = DistillationScorer.computeSNR(features: features, M: 4)
        #expect(snr.structuralSignal == 2.25)
        #expect(snr.episodicNoise == 0.5)
        #expect(snr.snr == 4.5)
        #expect(snr.readyToDistill == true)
    }

    // MARK: - computeStructuralScores

    @Test func computeStructuralScores_setsScoreOnFeatures() {
        // σ(1.0) = 1.0 × (1 − H(1.0)) = 1.0 × 1.0 = 1.0
        var features = [ExtractedFeature(type: .entity, value: "A", docFrequency: 1.0)]
        DistillationScorer.computeStructuralScores(features: &features)
        #expect(abs(features[0].structuralScore - 1.0) < 1e-5)
    }

    @Test func computeStructuralScores_halfDf_lowScore() {
        // σ(0.5) = 0.5 × (1 − H(0.5)) = 0.5 × (1 − 1.0) = 0.0
        var features = [ExtractedFeature(type: .entity, value: "A", docFrequency: 0.5)]
        DistillationScorer.computeStructuralScores(features: &features)
        #expect(abs(features[0].structuralScore - 0.0) < 1e-5)
    }

    // MARK: - buildPMIGraph

    @Test func buildPMIGraph_edgeExistsWhenCoOccurrenceAboveChance() {
        // M=4; features A and B both appear in memories {0,1,2}
        // p(A) = p(B) = 3/4, p(A∧B) = 3/4
        // PMI = log₂(0.75 / (0.75 × 0.75)) = log₂(4/3) > 0 → edge exists
        let features = [
            ExtractedFeature(type: .entity, value: "A", docFrequency: 0.75),
            ExtractedFeature(type: .entity, value: "B", docFrequency: 0.75),
        ]
        let incidence: [[Bool]] = [
            [true,  true ],
            [true,  true ],
            [true,  true ],
            [false, false],
        ]
        let graph = DistillationScorer.buildPMIGraph(
            thresholdFeatures: features, incidenceMatrix: incidence, M: 4
        )
        #expect(graph.pmiMatrix[0][1] > 0)
        #expect(graph.components.count == 1)
    }

    @Test func buildPMIGraph_noEdgeWhenIndependent() {
        // M=4; feature A in memories {0,1}, feature B in memories {2,3}
        // p(A∧B) = 0 → PMI = -infinity → no edge
        let features = [
            ExtractedFeature(type: .entity, value: "A", docFrequency: 0.5),
            ExtractedFeature(type: .entity, value: "B", docFrequency: 0.5),
        ]
        let incidence: [[Bool]] = [
            [true,  false],
            [true,  false],
            [false, true ],
            [false, true ],
        ]
        let graph = DistillationScorer.buildPMIGraph(
            thresholdFeatures: features, incidenceMatrix: incidence, M: 4
        )
        #expect(graph.pmiMatrix[0][1] <= 0)
        #expect(graph.components.count == 2)
    }

    // MARK: - selectDominantComponent

    @Test func selectDominantComponent_returnsHighestWeightComponent() {
        // Two components: {0} weight=0.25, {1,2} weight=1.5 (dominant)
        // Feature 0 never co-occurs with 1 or 2; features 1 and 2 always co-occur.
        let features = [
            ExtractedFeature(type: .entity, value: "low",   docFrequency: 0.25),
            ExtractedFeature(type: .entity, value: "highA", docFrequency: 0.75),
            ExtractedFeature(type: .entity, value: "highB", docFrequency: 0.75),
        ]
        let incidence: [[Bool]] = [
            [false, true,  true ],
            [false, true,  true ],
            [false, true,  true ],
            [true,  false, false],
        ]
        let graph = DistillationScorer.buildPMIGraph(
            thresholdFeatures: features, incidenceMatrix: incidence, M: 4
        )
        let dominant = DistillationScorer.selectDominantComponent(graph: graph)
        #expect(dominant.count == 2)
        #expect(dominant.allSatisfy { abs($0.docFrequency - 0.75) < 1e-5 })
    }

    // MARK: - computeConfidence

    @Test func computeConfidence_fullCoherence_returnsOne() {
        // All threshold features are selected: mean_df=1.0, coherence_ratio=1.0 → conf=1.0
        let features = [
            ExtractedFeature(type: .entity, value: "A", docFrequency: 1.0),
            ExtractedFeature(type: .entity, value: "B", docFrequency: 1.0),
        ]
        let confidence = DistillationScorer.computeConfidence(
            selected: features, allThreshold: features
        )
        #expect(abs(confidence - 1.0) < 1e-5)
    }

    @Test func computeConfidence_partialCoherence_penalizedByRatio() {
        // 2 selected out of 4 threshold features; mean_df=0.8
        // conf = 0.8 × (2/4) = 0.4
        let allThreshold = [
            ExtractedFeature(type: .entity, value: "A", docFrequency: 0.8),
            ExtractedFeature(type: .entity, value: "B", docFrequency: 0.8),
            ExtractedFeature(type: .entity, value: "C", docFrequency: 0.8),
            ExtractedFeature(type: .entity, value: "D", docFrequency: 0.8),
        ]
        let selected = Array(allThreshold.prefix(2))
        let confidence = DistillationScorer.computeConfidence(
            selected: selected, allThreshold: allThreshold
        )
        #expect(abs(confidence - 0.4) < 1e-5)
    }

    @Test func computeConfidence_emptySelected_returnsZero() {
        let allThreshold = [ExtractedFeature(type: .entity, value: "A", docFrequency: 1.0)]
        let confidence = DistillationScorer.computeConfidence(
            selected: [], allThreshold: allThreshold
        )
        #expect(confidence == 0)
    }
}
