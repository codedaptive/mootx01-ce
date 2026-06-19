// DistillationScorer.swift
//
// Core distillation scoring: SNR gate, majority vote, PMI graph,
// dominant component selection, confidence score.
// Per DISTILLATION_MATH_SSA.md §2–6.
//
// Wave-1 parallel stream: DistillationFeatureType is defined in
// TypedDecayWeighting.swift (Ds2, same module). This file resolves
// at wave merge when both streams land together in SubstrateML.

import Foundation

// MARK: - Types

/// A feature extracted from a cluster of memories, annotated with frequency
/// and structural metrics. The distillation pipeline operates on arrays of these.
public struct ExtractedFeature: Sendable, Equatable {
    /// Semantic type of the feature (entity, relation, temporal, numerical).
    public let type: DistillationFeatureType
    /// Canonical string representation of the extracted feature value.
    public let value: String
    /// Fraction of cluster memories that contain this feature: df(f) = (1/M) × Σ X_{ij}.
    public var docFrequency: Float32
    /// Temporally-weighted document frequency df_w, per §5. Equals docFrequency
    /// when memory timestamps are unavailable (uniform weighting).
    public var weightedDocFrequency: Float32
    /// Structural score σ(f) = df × (1 − H(df)), set by computeStructuralScores.
    /// Rewards features appearing often and consistently; near-zero for borderline features.
    public var structuralScore: Float32

    /// Initialize with a document frequency; weightedDocFrequency defaults to docFrequency
    /// and structuralScore defaults to 0 (populated by computeStructuralScores).
    public init(type: DistillationFeatureType, value: String, docFrequency: Float32) {
        self.type = type
        self.value = value
        self.docFrequency = docFrequency
        self.weightedDocFrequency = docFrequency
        self.structuralScore = 0
    }
}

/// Signal-to-noise ratio for a feature cluster, indicating distillation readiness.
/// Computed by computeSNR over all extracted features in a cluster.
public struct DistillationSNR: Sendable, Equatable {
    /// Ratio of structural signal to episodic noise. Distillation proceeds when snr >= 2.0.
    public let snr: Float32
    /// Total structural weight from majority-threshold-passing features: Σ df(f) for f in V_thresh.
    public let structuralSignal: Float32
    /// Total noise energy from sub-threshold features: Σ df(f) for f not in V_thresh.
    public let episodicNoise: Float32
    /// True when snr >= 2.0 — the cluster is coherent enough to distill into a factoid.
    public let readyToDistill: Bool
}

/// PMI-based feature coherence graph over the set of majority-threshold-passing features.
/// Edges exist between feature pairs whose PMI > 0 (co-occur more than chance).
public struct FeatureGraph: Sendable {
    /// Threshold-passing features (V_thresh), indexed to match pmiMatrix positions.
    public let nodes: [ExtractedFeature]
    /// Symmetric PMI matrix; diagonal is 0. pmiMatrix[j][k] = PMI(f_j, f_k).
    /// Values are -Float32.infinity when joint probability is zero.
    public let pmiMatrix: [[Float32]]
    /// Connected components of the positive-PMI subgraph, each as an index list into nodes.
    /// Sorted by total weighted docFrequency descending (max-weight component first).
    public let components: [[Int]]
}

// MARK: - Scorer

/// Deterministic distillation scoring over extracted feature clusters.
/// All methods are pure functions — no I/O, no state, no randomness.
/// Per DISTILLATION_MATH_SSA.md §2–6.
public enum DistillationScorer {

    // MARK: - Binary Entropy

    /// Binary entropy H(p) = −p·log₂(p) − (1−p)·log₂(1−p).
    /// Returns 0 at the boundaries p=0 and p=1 (entropy of certainty;
    /// convention: 0·log₂(0) = 0). Uses log2 throughout — NOT log or ln.
    static func binaryEntropy(_ p: Float32) -> Float32 {
        guard p > 0 && p < 1 else { return 0 }
        return -(p * log2(p)) - ((1 - p) * log2(1 - p))
    }

    // MARK: - Stage 2: Majority Threshold

    /// Majority vote threshold per §3.2: τ_maj = ⌈(M+1)/2⌉ / M.
    /// A feature survives the majority vote iff it appears in strictly more
    /// than half the cluster's memories.
    ///
    /// Values: M=3 → 2/3 ≈ 0.667, M=4 → 3/4 = 0.750, M=5 → 3/5 = 0.600.
    public static func majorityThreshold(M: Int) -> Float32 {
        // Ceiling integer arithmetic: ⌈a/b⌉ = (a + b - 1) / b
        // ⌈(M+1)/2⌉ = (M + 1 + 2 - 1) / 2 = (M + 2) / 2
        let numerator = (M + 2) / 2
        return Float32(numerator) / Float32(M)
    }

    /// Split features into those that pass and those that fail the majority vote threshold.
    /// Passing features form V_thresh — the input to the PMI coherence stage.
    public static func applyMajorityThreshold(
        features: [ExtractedFeature],
        M: Int
    ) -> (passing: [ExtractedFeature], failing: [ExtractedFeature]) {
        let τ = majorityThreshold(M: M)
        var passing: [ExtractedFeature] = []
        var failing: [ExtractedFeature] = []
        for f in features {
            if f.docFrequency >= τ { passing.append(f) } else { failing.append(f) }
        }
        return (passing, failing)
    }

    // MARK: - SNR Gate

    /// Compute cluster SNR to gate distillation readiness.
    ///
    /// structuralSignal = Σ df(f) for features with df ≥ τ_maj (majority-passing).
    /// episodicNoise    = Σ df(f) for features below threshold.
    /// snr              = structuralSignal / max(episodicNoise, 1e-6)
    /// readyToDistill   = snr ≥ 2.0
    ///
    /// Raw df accumulation is intentional: σ(f) is reserved for confidence weighting
    /// (computeStructuralScores / computeConfidence), not for the SNR gate.
    /// The 1e-6 floor prevents division by zero when all features are structural.
    public static func computeSNR(features: [ExtractedFeature], M: Int) -> DistillationSNR {
        let τ = majorityThreshold(M: M)
        var structuralSignal: Float32 = 0
        var episodicNoise: Float32 = 0

        for f in features {
            if f.docFrequency >= τ {
                // df — raw document frequency as structural weight
                structuralSignal += f.docFrequency
            } else {
                // df — sub-threshold feature frequency as noise contribution
                episodicNoise += f.docFrequency
            }
        }

        let snr = structuralSignal / max(episodicNoise, 1e-6)
        return DistillationSNR(
            snr: snr,
            structuralSignal: structuralSignal,
            episodicNoise: episodicNoise,
            readyToDistill: snr >= 2.0
        )
    }

    // MARK: - Stage 3: Structural Scores and PMI Graph

    /// Compute structural scores σ(f) = df × (1 − H(df)) for each feature in place.
    /// σ rewards features appearing often AND consistently — near 1.0 for universal features,
    /// near 0.0 for borderline-threshold features. Used for confidence weighting, not filtering.
    public static func computeStructuralScores(features: inout [ExtractedFeature]) {
        for i in features.indices {
            let df = features[i].docFrequency
            features[i].structuralScore = df * (1 - binaryEntropy(df))
        }
    }

    /// Build the PMI feature coherence graph over threshold-passing features per §4.
    ///
    /// PMI(f_j, f_k) = log₂(p(j∧k) / (p(j) × p(k))).
    /// An edge exists iff PMI > 0 — features co-occur more than their individual
    /// frequencies would predict, indicating semantic relatedness.
    ///
    /// Connected components are sorted by total weighted docFrequency descending
    /// so components[0] is always the dominant semantic cluster.
    ///
    /// - Parameters:
    ///   - thresholdFeatures: V_thresh — features that passed the majority vote.
    ///   - incidenceMatrix: Row i column j is true iff thresholdFeatures[j] ∈ memory i.
    ///   - M: Number of memories in the cluster.
    public static func buildPMIGraph(
        thresholdFeatures: [ExtractedFeature],
        incidenceMatrix: [[Bool]],
        M: Int
    ) -> FeatureGraph {
        let n = thresholdFeatures.count
        guard n > 0, M > 0 else {
            return FeatureGraph(nodes: thresholdFeatures, pmiMatrix: [], components: [])
        }
        let mFloat = Float32(M)

        // Compute marginal probabilities p(j) = df(f_j) from incidence columns
        var pMarginal = [Float32](repeating: 0, count: n)
        for j in 0..<n {
            var count: Float32 = 0
            for i in 0..<M where incidenceMatrix[i][j] { count += 1 }
            pMarginal[j] = count / mFloat
        }

        // Compute PMI matrix and positive-edge adjacency
        var pmi = [[Float32]](repeating: [Float32](repeating: 0, count: n), count: n)
        var adjacency = [[Bool]](repeating: [Bool](repeating: false, count: n), count: n)

        for j in 0..<n {
            for k in (j + 1)..<n {
                // Joint probability: fraction of memories containing both features
                var jointCount: Float32 = 0
                for i in 0..<M where incidenceMatrix[i][j] && incidenceMatrix[i][k] {
                    jointCount += 1
                }
                let pJoint = jointCount / mFloat
                let pProduct = pMarginal[j] * pMarginal[k]

                // PMI = log₂(p(j∧k) / (p(j)·p(k))); -infinity when joint = 0
                let pmiValue: Float32 = (pJoint > 0 && pProduct > 0)
                    ? log2(pJoint / pProduct)
                    : -.infinity

                pmi[j][k] = pmiValue
                pmi[k][j] = pmiValue  // symmetric

                if pmiValue > 0 {
                    adjacency[j][k] = true
                    adjacency[k][j] = true
                }
            }
        }

        // Find connected components via DFS, then sort by total weighted docFrequency
        var components = findConnectedComponents(nodeCount: n, adjacency: adjacency)
        components.sort { a, b in
            let wA = a.reduce(Float32(0)) { $0 + thresholdFeatures[$1].weightedDocFrequency }
            let wB = b.reduce(Float32(0)) { $0 + thresholdFeatures[$1].weightedDocFrequency }
            return wA > wB
        }

        return FeatureGraph(nodes: thresholdFeatures, pmiMatrix: pmi, components: components)
    }

    /// Return the features in the dominant (highest-weight) connected component (F* per §4.4).
    /// Isolated features — those with PMI ≤ 0 with all neighbors — form singleton components
    /// and are passed over when a larger coherent cluster exists.
    /// Returns an empty array when the graph has no components.
    public static func selectDominantComponent(graph: FeatureGraph) -> [ExtractedFeature] {
        guard let dominant = graph.components.first else { return [] }
        return dominant.map { graph.nodes[$0] }
    }

    // MARK: - Stage 5: Confidence

    /// Compute factoid confidence per §6.2.
    ///
    /// conf(F*) = mean_df(F*) × coherence_ratio(F*)
    ///
    /// mean_df(F*) = mean document frequency of selected features.
    /// coherence_ratio = |F*| / |V_thresh| — penalizes fragmented V_thresh.
    ///
    /// A cluster where all threshold-passing features cluster together scores conf = mean_df,
    /// while fragmented V_thresh (many isolated nodes) drives coherence_ratio toward 0.
    ///
    /// - Parameters:
    ///   - selected: F* — features from the dominant component.
    ///   - allThreshold: V_thresh — all features that passed the majority threshold.
    public static func computeConfidence(
        selected: [ExtractedFeature],
        allThreshold: [ExtractedFeature]
    ) -> Float32 {
        guard !selected.isEmpty, !allThreshold.isEmpty else { return 0 }
        let meanDf = selected.reduce(Float32(0)) { $0 + $1.docFrequency } / Float32(selected.count)
        let coherenceRatio = Float32(selected.count) / Float32(allThreshold.count)
        return meanDf * coherenceRatio
    }

    // MARK: - Private helpers

    /// DFS-based connected component discovery over a symmetric adjacency matrix.
    /// O(n²) for n nodes — acceptable for |V_thresh| ≤ 150.
    private static func findConnectedComponents(
        nodeCount: Int,
        adjacency: [[Bool]]
    ) -> [[Int]] {
        var visited = [Bool](repeating: false, count: nodeCount)
        var components: [[Int]] = []

        for start in 0..<nodeCount {
            guard !visited[start] else { continue }
            var component: [Int] = []
            var stack = [start]
            while !stack.isEmpty {
                let node = stack.removeLast()
                guard !visited[node] else { continue }
                visited[node] = true
                component.append(node)
                for neighbor in 0..<nodeCount where !visited[neighbor] && adjacency[node][neighbor] {
                    stack.append(neighbor)
                }
            }
            components.append(component)
        }
        return components
    }
}
