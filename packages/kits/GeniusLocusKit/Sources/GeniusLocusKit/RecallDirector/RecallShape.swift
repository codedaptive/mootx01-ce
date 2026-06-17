/// A SIGNED, per-lane steering vector for the RecallDirector's RRF fusion.
///
/// `RecallShape` makes the otherwise-uniform reciprocal-rank fusion (introduced
/// in 6b-core) STEERABLE without changing the fusion algorithm itself. It carries
/// a signed weight per fusion lane: a lane's reciprocal-rank mass is multiplied by
/// its weight before the per-id sum, so a recipe can forward, exclude, or suppress
/// individual signals. It is the ENGINE-level knob; named presets (the "shapes" a
/// recipe selects by name) are a separate layer (6b-modifiers-recipes) built ON TOP
/// of this type.
///
/// ## Lane-key scheme
///
/// Weights are keyed by a STABLE lane identifier string. This is the COMPLETE
/// steerable surface — the keys the optimizer and the preset roster target.
/// It spans the retrieval lanes AND (since 6b-modifiers-matrix-steer) the
/// matrix/graph/preference scoring columns:
///
///   Retrieval lanes (steer the RRF fusion in hybrid/corpusOnly AND the
///   weighted columns in unionBest):
///   - `"locus"`   — the LocusKit bitmap lane.
///   - `"bm25"`    — the CorpusKit BM25 keyword lane.
///   - `"hamming"` — the 256-bit SimHash-Hamming vector lane.
///   - `"dense"`   — the aggregate dense float column in the unionBest weighted
///     score (the per-signal `dense:<modelID>` keys below steer the dense
///     consensus fold that BUILDS that column).
///   - `"dense:<modelID>"` — a per-signal DENSE float lane, one key per held
///     embedding provider (e.g. `"dense:minilm-v6"`, `"dense:mpnet-base-v2"`).
///     The `<modelID>` suffix mirrors the per-signal fan-out from 6b-core so a
///     multi-provider corpus can weight each distributional signal independently.
///
///   Matrix/graph/preference columns (steer ONLY the unionBest `.matrixAware`
///   weighted score — the matrix columns are inactive under `.raw`/`.rrf`, so
///   these keys are a no-op there):
///   - `"fieldFit"`     — the FDC field-fit column.
///   - `"coOccurrence"` — the MatrixTier co-occurrence column.
///   - `"temporal"`     — the MatrixTier temporal-relevance column.
///   - `"graph"`        — the connection-graph column.
///   - `"preference"`   — the learned-preference column.
///
/// A lane whose key is ABSENT from `laneWeights` uses the default weight `1.0`
/// (forward at full strength) — so an empty map reproduces today's uniform fusion
/// exactly. This is the back-compat contract: `nil` shape ⇒ all-1.0 ⇒ byte-identical
/// to the pre-6b-modifiers fusion.
///
/// ## Signed-weight semantics
///
/// For lane `L` with weight `w_L`, the fused score is
/// `fused(id) = Σ_L w_L · 1/(k + rank_L(id) + 1)`:
///
///   - `w > 0` — FORWARD. The lane votes; larger `w` amplifies its rank mass.
///     `w == 1.0` is the neutral default (unchanged from uniform fusion).
///   - `w == 0` — EXCLUDE. The lane contributes nothing; its votes are dropped
///     as if the lane had not run. (Distinct from the lane being dark: the lane
///     still runs and its candidates still appear if ANOTHER lane surfaces them.)
///   - `w < 0`  — SUPPRESS. The lane SUBTRACTS its rank mass: a candidate the lane
///     ranks HIGH is DEMOTED. This is demotion of an existing-lane signal, NOT
///     anti-similarity retrieval (which changes which candidates the store
///     returns). The two are deliberately distinct.
///
/// ## Anti-similarity (`antiSimilarLanes`)
///
/// A DENSE lane key (`"dense:<modelID>"`) listed in `antiSimilarLanes` flips
/// that lane's OBJECTIVE from nearest to FARTHEST: the lane queries the store
/// for the most DISSIMILAR sources ("find things UNLIKE this") via CorpusKit's
/// `floatFarthestPerSignal`, and those dissimilar candidates become the lane's
/// voters in the same RRF/consensus fold. This is DISTINCT from a negative
/// weight:
///
///   - Anti-similarity (this set) changes WHICH candidates the store returns —
///     the farthest, not the nearest. The lane then FORWARDS the dissimilar set.
///   - A negative weight (`laneWeights[key] < 0`) keeps the NEAREST candidates
///     and SUBTRACTS their rank mass — demoting the similar.
///
/// The two compose: a lane can be anti-similar AND weighted (forward the
/// dissimilar at any strength, or even suppress the dissimilar). An empty set
/// ⇒ every lane nearest ⇒ byte-identical to today's fusion (the back-compat
/// contract, proven by test). Only `"dense:<modelID>"` keys are honoured; other
/// lane keys (locus/bm25/hamming) have no farthest variant and are ignored.
///
/// ## frontierK override
///
/// `frontierK` optionally widens or narrows the candidate pool depth each lane
/// retrieves before fusion (the RecallDirector's default is
/// `min(max(limit * 4, 64), 256)`). `nil` keeps the computed default. A larger
/// pool lets suppression/exclusion reshape a deeper frontier; a smaller pool
/// tightens the candidate set. The override is clamped to the same `[64, 256]`
/// envelope so a recipe cannot request an unbounded scan.
public struct RecallShape: Sendable, Codable, Equatable {
    /// Signed per-lane weights keyed by the stable lane identifier (see the
    /// lane-key scheme above). A missing key defaults to `1.0`. `0` excludes a
    /// lane; a negative value suppresses (demotes) the lane's high-ranked
    /// candidates.
    public let laneWeights: [String: Float]

    /// Dense lane keys (`"dense:<modelID>"`) whose objective is FARTHEST rather
    /// than nearest — anti-similarity retrieval. A lane in this set queries the
    /// store for the most DISSIMILAR sources and forwards them. Empty ⇒ every
    /// lane nearest ⇒ byte-identical to today's fusion. Distinct from a negative
    /// weight (which demotes the NEAREST); the two compose. See the type-level
    /// "Anti-similarity" note.
    public let antiSimilarLanes: Set<String>

    /// Optional candidate-pool depth override. `nil` keeps the RecallDirector's
    /// computed default `min(max(limit * 4, 64), 256)`. When set, the value is
    /// clamped to the same `[64, 256]` envelope (see `effectiveFrontierK`).
    public let frontierK: Int?

    /// The inclusive lower bound for any `frontierK` override. Mirrors the
    /// RecallDirector's `frontierK` floor so a shape cannot request a pool
    /// narrower than the engine's own minimum.
    public static let frontierKFloor = 64
    /// The inclusive upper bound for any `frontierK` override. Mirrors the
    /// RecallDirector's `frontierK` ceiling so a shape cannot request an
    /// unbounded scan.
    public static let frontierKCeiling = 256

    /// Create a recall shape.
    ///
    /// - Parameters:
    ///   - laneWeights: signed per-lane weights keyed by stable lane id. Defaults
    ///     to empty (every lane at weight `1.0` — uniform, today's behaviour).
    ///   - antiSimilarLanes: dense lane keys (`"dense:<modelID>"`) that invert
    ///     their objective to FARTHEST (anti-similarity). Defaults to empty
    ///     (every lane nearest — today's behaviour). Distinct from a negative
    ///     weight; the two compose.
    ///   - frontierK: optional candidate-pool depth override, clamped to
    ///     `[frontierKFloor, frontierKCeiling]` when read via `effectiveFrontierK`.
    ///     Defaults to `nil` (the engine's computed default).
    public init(
        laneWeights: [String: Float] = [:],
        antiSimilarLanes: Set<String> = [],
        frontierK: Int? = nil
    ) {
        self.laneWeights = laneWeights
        self.antiSimilarLanes = antiSimilarLanes
        self.frontierK = frontierK
    }

    /// Whether the given dense lane key inverts its objective to FARTHEST
    /// (anti-similarity). Returns `false` for any key not in `antiSimilarLanes`
    /// — so an empty set keeps every lane nearest (the back-compat default).
    ///
    /// - Parameter laneKey: a dense lane identifier (`"dense:<modelID>"`).
    /// - Returns: `true` when the lane should query the farthest variant.
    public func isAntiSimilar(_ laneKey: String) -> Bool {
        antiSimilarLanes.contains(laneKey)
    }

    /// The signed weight for a lane key. Returns `1.0` for any key absent from
    /// `laneWeights` — the neutral default that keeps unweighted lanes voting at
    /// full strength.
    ///
    /// - Parameter laneKey: a stable lane identifier — a retrieval lane
    ///   (`"locus"`, `"bm25"`, `"hamming"`, `"dense"`, `"dense:<modelID>"`) or a
    ///   matrix/graph/preference column (`"fieldFit"`, `"coOccurrence"`,
    ///   `"temporal"`, `"graph"`, `"preference"`). See the lane-key scheme above.
    /// - Returns: the configured weight, or `1.0` when the lane is not in the map.
    public func weight(for laneKey: String) -> Float {
        laneWeights[laneKey] ?? 1.0
    }

    /// Resolve the effective candidate-pool depth for a computed engine default.
    ///
    /// When `frontierK` is `nil` the engine default is returned unchanged. When
    /// set, the override is clamped to `[frontierKFloor, frontierKCeiling]` so a
    /// recipe cannot widen the pool past the engine ceiling or narrow it below the
    /// engine floor.
    ///
    /// - Parameter engineDefault: the RecallDirector's computed `frontierK`.
    /// - Returns: the clamped override, or `engineDefault` when no override is set.
    public func effectiveFrontierK(engineDefault: Int) -> Int {
        guard let override = frontierK else { return engineDefault }
        return min(Self.frontierKCeiling, max(Self.frontierKFloor, override))
    }
}
