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

    // MARK: - Named preset roster

    /// The per-signal DENSE lane key for a held embedding provider, by its
    /// `modelID`. These are the exact `modelID` strings the CorpusKit providers
    /// ship (see CorpusKitProviders/*Provider.swift) — the suffix on a
    /// `dense:<modelID>` lane key. The roster targets them by these constants so
    /// a typo in a provider id surfaces as a build error, not a silent no-op.
    public enum DenseSignal {
        /// Random-Indexing distributional provider — `"random-indexing-v1"`.
        public static let randomIndexing = "dense:random-indexing-v1"
        /// Positive-PMI distributional provider — `"ppmi-v1"`.
        public static let ppmi = "dense:ppmi-v1"
        /// Latent-Semantic-Analysis provider — `"lsa-v1"`.
        public static let lsa = "dense:lsa-v1"
        /// Non-negative-Matrix-Factorisation provider — `"nmf-v1"`.
        public static let nmf = "dense:nmf-v1"
        /// Field-Distribution-Coding provider — `"fdc-v1"`.
        public static let fdc = "dense:fdc-v1"

        /// The distributional dense lane keys (ri, ppmi, lsa, nmf) in stable
        /// order. Used by the `consensus`/`broad` presets to forward (or the
        /// leave-one-out pattern to zero) each distributional signal. `fdc`
        /// is intentionally excluded — it is a structural-coding signal and
        /// is targeted by its own explicit presets rather than bundled here.
        public static let all: [String] = [randomIndexing, ppmi, lsa, nmf]
    }

    /// The names of every preset in the roster, in stable declaration order.
    /// This is the discoverable surface the catalog and the ARIA tool enumerate.
    ///
    /// `"balanced"` is included for completeness even though it resolves to a
    /// `nil` shape (uniform fusion = today's behaviour) — listing it lets a
    /// caller pick "no steering" by name alongside the steered shapes.
    public static let presetNames: [String] = [
        "balanced",
        "precise",
        "conceptual",
        "broad",
        "lexical",
        "not_lexical",
        "associative",
        "consensus",
        "ri_forward",
        "ppmi_forward",
        "lsa_forward",
        "nmf_forward",
        "fast",
        "structural",
        "temporal",
        "connection",
        "field",
        "preference",
        "anti_redundant",
    ]

    /// Resolve a named preset to its documented signed-weight shape.
    ///
    /// Returns the shape for a known preset name, or `nil` when the name is not
    /// in `presetNames`. `"balanced"` deliberately resolves to `nil` too — the
    /// uniform, unsteered fusion is the absence of a shape, so a `nil` return for
    /// `"balanced"` and for an unknown name are the SAME thing at the call site
    /// (run recall with no steering). Callers that must distinguish "balanced"
    /// from "unknown" check `presetNames.contains(name)` first.
    ///
    /// The weights below are SENSIBLE, DEFENSIBLE starting points — the
    /// optimizer tunes the exact magnitudes later (recall-architecture: the
    /// optimizer owns weights). They are NOT canon: the contract a preset honours
    /// is its DIRECTION (which lanes it forwards, zeroes, suppresses, inverts, and
    /// how it bounds the frontier), not the literal float. Every key a preset
    /// sets is a key the engine reads (verified in RecallDirector's unionBest
    /// weighted path), so no preset is a silent no-op.
    ///
    /// Leave-one-out is reachable WITHOUT a dedicated preset: take any forward
    /// shape and zero one `dense:<modelID>` lane (e.g. set
    /// `DenseSignal.lsa` to `0`) to ablate exactly that distributional signal.
    ///
    /// - Parameter name: a preset name from `presetNames`.
    /// - Returns: the resolved shape, or `nil` for `"balanced"` / an unknown name.
    public static func preset(_ name: String) -> RecallShape? {
        switch name {
        // Uniform fusion — the absence of steering. `nil` ⇒ every lane at 1.0 ⇒
        // byte-identical to today's behaviour.
        case "balanced":
            return nil

        // Exactness: amplify the keyword (bm25) and field-coding (fdc) lanes and
        // forward the dense consensus, then NARROW the frontier so suppression
        // reshapes a tight, high-precision pool. The "find the exact answer" shape.
        case "precise":
            return RecallShape(
                laneWeights: [
                    "bm25": 1.5,
                    DenseSignal.fdc: 1.5,
                    "dense": 1.2,
                ],
                frontierK: frontierKFloor)

        // Concepts over keywords: amplify the distributional dense lanes
        // (RI/PPMI/LSA/NMF) and damp the literal keyword lane so semantically
        // related — not lexically identical — memories rise.
        case "conceptual":
            return RecallShape(
                laneWeights: [
                    DenseSignal.randomIndexing: 1.5,
                    DenseSignal.ppmi: 1.5,
                    DenseSignal.lsa: 1.5,
                    DenseSignal.nmf: 1.5,
                    "bm25": 0.5,
                ])

        // Cast wide: forward every retrieval lane above neutral and WIDEN the
        // frontier to the ceiling so the fused set draws from a deep candidate
        // pool. The "don't miss anything" shape.
        case "broad":
            return RecallShape(
                laneWeights: [
                    "locus": 1.3,
                    "bm25": 1.3,
                    "hamming": 1.3,
                    "dense": 1.3,
                ],
                frontierK: frontierKCeiling)

        // Keyword/field only: amplify bm25 + fdc and ZERO the vector lanes
        // (dense aggregate and 256-bit Hamming) so only literal/field signals
        // vote. The pure-lexical lane.
        case "lexical":
            return RecallShape(
                laneWeights: [
                    "bm25": 1.5,
                    DenseSignal.fdc: 1.5,
                    "dense": 0,
                    "hamming": 0,
                ])

        // Suppress the literal lanes: ZERO bm25 + fdc so only the distributional
        // and structural lanes decide. The complement of `lexical`.
        case "not_lexical":
            return RecallShape(
                laneWeights: [
                    "bm25": 0,
                    DenseSignal.fdc: 0,
                ])

        // Loose association: amplify the two most "associative" distributional
        // signals (RI and NMF) and widen the frontier so loosely-related memories
        // surface. The free-association shape.
        case "associative":
            return RecallShape(
                laneWeights: [
                    DenseSignal.randomIndexing: 1.5,
                    DenseSignal.nmf: 1.5,
                ],
                frontierK: frontierKCeiling)

        // Dense consensus: forward EVERY per-signal dense lane at full strength
        // (so the consensus fold that builds the `dense` column weighs every
        // distributional provider) and narrow the frontier so the agreed-upon
        // candidates dominate. The "where all the embedding models agree" shape.
        case "consensus":
            var weights: [String: Float] = [:]
            for key in DenseSignal.all { weights[key] = 1.0 }
            weights[DenseSignal.fdc] = 1.0
            return RecallShape(laneWeights: weights, frontierK: frontierKFloor)

        // Single-signal forwarding: amplify ONE distributional dense lane and
        // ZERO its siblings so only that provider's geometry votes. The four
        // `*_forward` presets isolate each held provider for ablation/inspection.
        case "ri_forward":
            return singleDenseForward(DenseSignal.randomIndexing)
        case "ppmi_forward":
            return singleDenseForward(DenseSignal.ppmi)
        case "lsa_forward":
            return singleDenseForward(DenseSignal.lsa)
        case "nmf_forward":
            return singleDenseForward(DenseSignal.nmf)

        // Cheapest vote: boost the 256-bit Hamming lane and set the `dense`
        // weight to 0. RecallDirector still runs floatNearestPerSignal when a
        // corpus and query text are present; the zero weight eliminates the
        // dense column's contribution to the final aggregate score, but dense
        // candidates can still enter the buffer before scoring. Latency-first shape.
        case "fast":
            return RecallShape(
                laneWeights: [
                    "hamming": 1.5,
                    "dense": 0,
                ])

        // Structure-led: amplify the LocusKit bitmap lane so filed structure
        // (wing/room/facet) drives ranking over content similarity.
        case "structural":
            return RecallShape(laneWeights: ["locus": 1.5])

        // Time-led: amplify the MatrixTier temporal-relevance column (a
        // matrixAware-only column — neutral under raw/rrf). "What's relevant now."
        case "temporal":
            return RecallShape(laneWeights: ["temporal": 1.5])

        // Connection-led: amplify the connection-graph column so memories central
        // in the association graph rank up. matrixAware-only.
        case "connection":
            return RecallShape(laneWeights: ["graph": 1.5])

        // Field-led: amplify the co-occurrence column so memories that share
        // filing facets with the query's neighbourhood rank up. matrixAware-only.
        case "field":
            return RecallShape(laneWeights: ["coOccurrence": 1.5])

        // Preference-led: amplify the learned-preference column (Bradley-Terry /
        // RecallTrace) so memories the user has historically favoured rank up.
        // matrixAware-only.
        case "preference":
            return RecallShape(laneWeights: ["preference": 1.5])

        // Diversity: invert the FDC dense lane's objective to FARTHEST so it
        // surfaces the most DISSIMILAR sources, pulling the fused set away from
        // near-duplicates of the query. BM25 and Hamming (Hamming vector lane) are
        // suppressed (negative weight) so lexical near-duplicates cannot rank at
        // the top via keyword or SimHash similarity alone — only FDC farthest and
        // the remaining lanes contribute. The frontier is narrowed to frontierKFloor
        // so the re-rank pool is tight and focused rather than a wide list where
        // duplicates can still cluster.
        case "anti_redundant":
            return RecallShape(
                laneWeights: ["bm25": -0.5, "hamming": -0.5],
                antiSimilarLanes: [DenseSignal.fdc],
                frontierK: frontierKFloor)

        default:
            return nil
        }
    }

    /// A one-line, human-readable description of what a preset emphasises — the
    /// text the ARIA tool surfaces when it lists the roster. Each line names the
    /// signals the preset forwards/zeroes/inverts so an AI can pick a preset by
    /// intent. Returns an empty string for an unknown name (not in `presetNames`).
    ///
    /// - Parameter name: a preset name from `presetNames`.
    /// - Returns: the description, or `""` for an unknown name.
    public static func presetDescription(_ name: String) -> String {
        switch name {
        case "balanced":
            return "Uniform fusion — every lane votes equally. The unsteered default."
        case "precise":
            return "Exactness — amplify keyword (bm25) + field-coding (fdc) + dense consensus over a narrow frontier."
        case "conceptual":
            return "Concepts over keywords — amplify the distributional dense lanes (RI/PPMI/LSA/NMF), damp bm25."
        case "broad":
            return "Cast wide — forward every retrieval lane and widen the candidate frontier to the ceiling."
        case "lexical":
            return "Keyword/field only — amplify bm25 + fdc, exclude the dense and Hamming vector lanes."
        case "not_lexical":
            return "Suppress the literal lanes — exclude bm25 + fdc so distributional and structural signals decide."
        case "associative":
            return "Loose association — amplify the RI + NMF distributional lanes over a wide frontier."
        case "consensus":
            return "Dense consensus — forward every per-signal dense lane over a narrow frontier; where the embedding models agree."
        case "ri_forward":
            return "Isolate Random-Indexing — amplify the RI dense lane, exclude the other distributional signals."
        case "ppmi_forward":
            return "Isolate PPMI — amplify the PPMI dense lane, exclude the other distributional signals."
        case "lsa_forward":
            return "Isolate LSA — amplify the LSA dense lane, exclude the other distributional signals."
        case "nmf_forward":
            return "Isolate NMF — amplify the NMF dense lane, exclude the other distributional signals."
        case "fast":
            return "Cheapest vote — keep only the 256-bit Hamming lane, skip the float-dense cosine pass."
        case "structural":
            return "Structure-led — amplify the LocusKit bitmap lane so filed structure drives ranking."
        case "temporal":
            return "Time-led — amplify the temporal-relevance column (matrixAware scoring only)."
        case "connection":
            return "Connection-led — amplify the connection-graph column (matrixAware scoring only)."
        case "field":
            return "Field-led — amplify the co-occurrence column (matrixAware scoring only)."
        case "preference":
            return "Preference-led — amplify the learned-preference column (matrixAware scoring only)."
        case "anti_redundant":
            return "Diversity — invert FDC to farthest (anti-similarity) + suppress BM25/Hamming (-0.5) so lexical near-duplicates cannot dominate; narrow frontier to 64."
        default:
            return ""
        }
    }

    /// A shape that forwards exactly one dense lane and zeroes the other three
    /// distributional siblings — the `*_forward` preset body. The named lane is
    /// amplified; every other `DenseSignal.all` key is excluded.
    private static func singleDenseForward(_ forwardKey: String) -> RecallShape {
        var weights: [String: Float] = [:]
        for key in DenseSignal.all {
            weights[key] = (key == forwardKey) ? 1.5 : 0
        }
        return RecallShape(laneWeights: weights)
    }
}
