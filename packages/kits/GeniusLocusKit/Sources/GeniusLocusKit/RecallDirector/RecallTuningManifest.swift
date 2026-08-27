// RecallTuningManifest.swift
//
// The OPTIMIZER-OWNED recall-tuning envelope: four knobs stored as a JSON
// object under the "recall_tuning" manifest key per estate. Consumers read
// the provisioned values with the same fail-quiet, precedence-aware contract
// used for "lane_weights":
//
//   explicit caller value > provisioned estate default > spec constant
//
// All spec-default values are embedded in the `default` singleton so an
// absent manifest key is byte-identical to today's behavior — no estate
// migration required to deploy this type.
//
// Fields in scope:
//   rrf_k               — RRF k constant (default 60)
//   mmr_lambda          — MMR λ trade-off (default 0.7)
//   rrf_bm25_weight     — BM25 lane blend weight for RRF (default 0.3)
//   rrf_vector_weight   — vector lane blend weight for RRF (default 0.7)
//
// Packager thresholds (added in the PACKAGER mission — GLKResultsPackager):
//   packager_t1         — CONFIDENT m1 minimum margin (default 0.25)
//   packager_t2         — CONFIDENT m2 minimum lane agreement (default 0.50)
//   packager_t1_prime   — WEAK m1 ceiling (default 0.05)
//   packager_t3_prime   — WEAK m3 (dense spread) floor (default 0.10)
//   packager_c          — score-cliff ratio threshold (default 0.20)
//   packager_k_min      — minimum response rows (default 3)
//   packager_k_max      — maximum response rows (default 20)
//
// Out of scope (noted as follow-ups):
//   weighted-all seed weights (CompositionGrid.all)
//   CompositeDistance alphas (0.5/0.5) used by the composite composition

import Foundation

// MARK: - RecallTuningManifest

/// Optimizer-owned per-estate recall-tuning envelope stored under the
/// `"recall_tuning"` manifest key as a JSON object.
///
/// All fields default to the current spec constants so an estate with no
/// `"recall_tuning"` key behaves exactly as before. The optimizer emits
/// this value via `GeniusLocusKit.provisionRecallTuning(_:for:)`; the
/// product reads it and threads it to consumers.
///
/// JSON wire keys are snake_case (e.g. `"rrf_k"`, `"mmr_lambda"`) so the
/// manifest is readable without a code reference. Any key absent from the
/// stored JSON is filled with the spec default at decode time — a partial
/// JSON object is safe.
public struct RecallTuningManifest: Sendable, Equatable, Codable {

    // MARK: - Fields

    /// Reciprocal Rank Fusion k constant. Lower k makes rank differences
    /// matter more; higher k flattens them. Spec value: 60. Used by the
    /// NeuronKit HybridRecall RRF fusion formula
    /// `1 / (k + rank + 1)`.
    public let rrfK: Int

    /// MMR diversity trade-off λ in [0, 1]. 1.0 is pure relevance (no
    /// diversity); 0.0 is pure diversity (no relevance). Spec value: 0.7.
    /// Used by the NeuronKit HybridRecall MMR re-rank and the
    /// CompositionGrid "text+mmr" composition.
    public let mmrLambda: Float

    /// BM25 lane blend weight in the NeuronKit HybridRecall two-lane RRF
    /// fusion. Spec value: 0.3. Must sum to 1.0 with `rrfVectorWeight`
    /// for the formula to be properly normalised.
    public let rrfBm25Weight: Float

    /// Vector lane blend weight in the NeuronKit HybridRecall two-lane
    /// RRF fusion. Spec value: 0.7. Must sum to 1.0 with
    /// `rrfBm25Weight` for the formula to be properly normalised.
    public let rrfVectorWeight: Float

    // MARK: - Packager thresholds (GLKResultsPackager, PACKAGER mission)

    /// CONFIDENT gate: minimum top-margin (m1). Spec value: 0.25.
    public let packagerT1: Double
    /// CONFIDENT gate: minimum lane agreement (m2). Spec value: 0.50.
    public let packagerT2: Double
    /// WEAK gate: m1 ceiling below which WEAK fires (t1'). Spec value: 0.05.
    public let packagerT1Prime: Double
    /// WEAK gate: dense-spread floor (t3'). Spec value: 0.10.
    public let packagerT3Prime: Double
    /// Score-cliff ratio threshold (c). Spec value: 0.20.
    public let packagerC: Double
    /// Minimum response rows (k_min). Spec value: 3.
    public let packagerKMin: Int
    /// Maximum response rows (k_max). Spec value: 20.
    public let packagerKMax: Int

    /// Extract the packager thresholds into a `PackagerThresholds` value for
    /// direct use by `GLKResultsPackager`. Callers request `RecallTuningManifest`
    /// and project to `PackagerThresholds` here rather than spelling out every
    /// threshold individually.
    public var packagerThresholds: PackagerThresholds {
        PackagerThresholds(
            t1: packagerT1,
            t2: packagerT2,
            t1Prime: packagerT1Prime,
            t3Prime: packagerT3Prime,
            c: packagerC,
            kMin: packagerKMin,
            kMax: packagerKMax
        )
    }

    // MARK: - Defaults

    /// Spec-default tuning singleton. All fields equal the hardcoded
    /// spec constants: k=60, λ=0.7, bm25=0.3, vector=0.7, plus packager
    /// spec defaults. An estate with no "recall_tuning" manifest key
    /// resolves to this value.
    public static let `default` = RecallTuningManifest()

    // MARK: - Init

    /// Build a manifest envelope. All parameters default to the spec
    /// constants so partial construction is safe.
    ///
    /// - Parameters:
    ///   - rrfK: RRF k constant (default 60).
    ///   - mmrLambda: MMR λ trade-off (default 0.7).
    ///   - rrfBm25Weight: BM25 lane blend weight (default 0.3).
    ///   - rrfVectorWeight: vector lane blend weight (default 0.7).
    ///   - packagerT1: CONFIDENT m1 minimum margin (default 0.25).
    ///   - packagerT2: CONFIDENT m2 minimum lane agreement (default 0.50).
    ///   - packagerT1Prime: WEAK m1 ceiling (default 0.05).
    ///   - packagerT3Prime: WEAK m3 dense-spread floor (default 0.10).
    ///   - packagerC: score-cliff ratio threshold (default 0.20).
    ///   - packagerKMin: minimum response rows (default 3).
    ///   - packagerKMax: maximum response rows (default 20).
    public init(
        rrfK: Int = 60,
        mmrLambda: Float = 0.7,
        rrfBm25Weight: Float = 0.3,
        rrfVectorWeight: Float = 0.7,
        packagerT1: Double = 0.25,
        packagerT2: Double = 0.50,
        packagerT1Prime: Double = 0.05,
        packagerT3Prime: Double = 0.10,
        packagerC: Double = 0.20,
        packagerKMin: Int = 3,
        packagerKMax: Int = 20
    ) {
        self.rrfK = rrfK
        self.mmrLambda = mmrLambda
        self.packagerT1 = packagerT1
        self.packagerT2 = packagerT2
        self.packagerT1Prime = packagerT1Prime
        self.packagerT3Prime = packagerT3Prime
        self.packagerC = packagerC
        self.packagerKMin = packagerKMin
        self.packagerKMax = packagerKMax
        self.rrfBm25Weight = rrfBm25Weight
        self.rrfVectorWeight = rrfVectorWeight
    }

    // MARK: - Coding keys

    /// Snake_case JSON keys so the manifest is human-readable.
    enum CodingKeys: String, CodingKey {
        case rrfK = "rrf_k"
        case mmrLambda = "mmr_lambda"
        case rrfBm25Weight = "rrf_bm25_weight"
        case rrfVectorWeight = "rrf_vector_weight"
        // Packager thresholds (PACKAGER mission):
        case packagerT1 = "packager_t1"
        case packagerT2 = "packager_t2"
        case packagerT1Prime = "packager_t1_prime"
        case packagerT3Prime = "packager_t3_prime"
        case packagerC = "packager_c"
        case packagerKMin = "packager_k_min"
        case packagerKMax = "packager_k_max"
    }

    // MARK: - Decode (fail-quiet partial JSON)

    /// Decode from JSON, filling any absent key with its spec default.
    /// A partial JSON object (e.g. only `"rrf_k"` present) is valid;
    /// unrecognised keys are silently ignored by `JSONDecoder`. This
    /// mirrors the fail-quiet contract on "lane_weights". Packager
    /// threshold keys are also optional; absent keys fall back to the
    /// spec defaults so no estate migration is required.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rrfK = try c.decodeIfPresent(Int.self, forKey: .rrfK) ?? 60
        mmrLambda = try c.decodeIfPresent(Float.self, forKey: .mmrLambda) ?? 0.7
        rrfBm25Weight = try c.decodeIfPresent(Float.self, forKey: .rrfBm25Weight) ?? 0.3
        rrfVectorWeight = try c.decodeIfPresent(Float.self, forKey: .rrfVectorWeight) ?? 0.7
        packagerT1 = try c.decodeIfPresent(Double.self, forKey: .packagerT1) ?? 0.25
        packagerT2 = try c.decodeIfPresent(Double.self, forKey: .packagerT2) ?? 0.50
        packagerT1Prime = try c.decodeIfPresent(Double.self, forKey: .packagerT1Prime) ?? 0.05
        packagerT3Prime = try c.decodeIfPresent(Double.self, forKey: .packagerT3Prime) ?? 0.10
        packagerC = try c.decodeIfPresent(Double.self, forKey: .packagerC) ?? 0.20
        packagerKMin = try c.decodeIfPresent(Int.self, forKey: .packagerKMin) ?? 3
        packagerKMax = try c.decodeIfPresent(Int.self, forKey: .packagerKMax) ?? 20
    }
}
