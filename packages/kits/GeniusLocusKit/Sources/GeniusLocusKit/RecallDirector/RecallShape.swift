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
///   - `"dense:<modelID>"` — spelled with the ACTIVE span encoder's registry
///     model id (`DenseSignal.encoder`, `"dense:minilm-l6-v2-w60"` for the
///     floor model), the span rerank stage's weight `w` in its reciprocal-rank
///     fusion (contract sheet §8): `1.0` neutral, `0` skips the stage. In the
///     A held whole-record provider's id (e.g. `"dense:random-indexing-v1"`)
///     steers that provider's per-signal float lane in the unionBest consensus fold.
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
///   Column-budget keys, namespace `signal:` (COL-1; steer ONLY the unionBest
///   `.matrixAware` weighted score). Where the per-lane keys above SCALE a
///   column's term, a `signal:*` key at 0 EXCLUDES the whole column and
///   REDISTRIBUTES its `RecallWeights` budget over the remaining columns, so
///   an excluded column never stands as a zero term that inflates the fixed
///   agreement and pinned bonuses. `1.0`/absent is neutral, `<0` suppresses,
///   other positive values scale (no redistribution). See `RecallSignalBudget`:
///   - `"signal:locus"`, `"signal:bm25"`, `"signal:vector"` (Hamming + dense),
///     `"signal:fieldFit"`, `"signal:matrix"` (coOccurrence + temporal),
///     `"signal:graph"`, `"signal:preference"`, `"signal:agreement"` (the
///     fixed signal-agreement bonus; it has no budget slice to redistribute).
///   - `"signal:encoder"` — the span rerank stage switch (sheet §8): `0` skips
///     the stage (the `no_encoder` ablation); it has no budget slice.
///
/// A lane whose key is ABSENT from `laneWeights` uses `defaultWeight(for:)`:
/// `1.0` (forward at full strength) for every key except `"signal:vector"`,
/// whose default is `0` — the whole-record vector column (Hamming + dense)
/// leaves the fused score unless a shape asks for it by setting the key
/// (Encoder Rerank Program ruling: the span rerank replaces it). So an empty
/// map, a `nil` shape and the `no_vector` preset fuse identically.
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

    /// Binary-lane metric selector (W2.5 M1 unlock): `"hamming"` (default)
    /// or `"jaccard"`. Jaccard scores set OVERLAP over set UNION of the
    /// 256-bit fingerprints (a length-normalized alternative to Hamming's
    /// symmetric-difference count) and always serves from the brute-force
    /// engine. Unknown values read as `"hamming"` — a shape must degrade,
    /// never fail, per the shape contract. Codable-additive: shapes
    /// persisted before this field decode with the default.
    public let binaryMetric: String

    /// Float-lane metric selector: `"cosine"` (default), `"l2"`, or `"dot"`.
    ///
    /// Selects the distance function used by the dense float embedding lane
    /// (Lane D: `FloatBruteForceIndex` / `HNSW`). All three metrics are
    /// implemented in `FloatBruteForceIndex` and produce well-formed rankings:
    ///
    /// - `"cosine"` — cosine distance `1 − cos(a,b)`. Scale-invariant;
    ///   the default and the only metric used before this field existed.
    ///   Byte-identical to the pre-field behaviour when absent or "cosine".
    /// - `"l2"` — Euclidean L2 distance `√Σ(aᵢ−bᵢ)²`. Useful when
    ///   absolute magnitude differences matter. Results comparable to
    ///   cosine when vectors are unit-normalised.
    /// - `"dot"` — Negative dot product `−Σ(aᵢbᵢ)`. Maximises inner
    ///   product; useful for embeddings trained with a dot-product
    ///   objective (e.g. some MRL/JM variants).
    ///
    /// Unknown values degrade to `"cosine"` per the shape contract — a
    /// shape must degrade, never fail. Codable-additive: payloads persisted
    /// before this field decode with the `"cosine"` default, preserving
    /// byte-identical behaviour.
    ///
    /// ONLY the float lane is affected; the binary lane keeps `binaryMetric`.
    public let floatMetric: String

    /// Matrix-signal weighting selector (W2.5 S4-C): "counts" (default —
    /// the canonical Int64 count matrices) or "decayed" (the §8.13
    /// exp-decayed projections computed each maintenance pass). Unknown
    /// values degrade to counts (shape contract). Arm surface: defaults
    /// never read the decayed maps.
    public let matrixWeighting: String

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
    private enum CodingKeys: String, CodingKey {
        case laneWeights, antiSimilarLanes, frontierK, binaryMetric, floatMetric, matrixWeighting
    }

    /// Custom decode so payloads persisted BEFORE any additive field existed
    /// decode with their defaults instead of failing on a missing key — the
    /// additive-Codable contract the field documentation promises.
    ///
    /// Fields added in document order, each with a `decodeIfPresent` fallback
    /// to the stated default. Never use `decode(_:forKey:)` here — that throws
    /// on a missing key and breaks the additive contract.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.laneWeights = try c.decodeIfPresent([String: Float].self, forKey: .laneWeights) ?? [:]
        self.antiSimilarLanes = try c.decodeIfPresent(Set<String>.self, forKey: .antiSimilarLanes) ?? []
        self.frontierK = try c.decodeIfPresent(Int.self, forKey: .frontierK)
        self.binaryMetric = try c.decodeIfPresent(String.self, forKey: .binaryMetric) ?? "hamming"
        self.floatMetric = try c.decodeIfPresent(String.self, forKey: .floatMetric) ?? "cosine"
        self.matrixWeighting = try c.decodeIfPresent(String.self, forKey: .matrixWeighting) ?? "counts"
    }

    public init(
        laneWeights: [String: Float] = [:],
        antiSimilarLanes: Set<String> = [],
        frontierK: Int? = nil,
        binaryMetric: String = "hamming",
        floatMetric: String = "cosine",
        matrixWeighting: String = "counts"
    ) {
        self.laneWeights = laneWeights
        self.antiSimilarLanes = antiSimilarLanes
        self.binaryMetric = binaryMetric
        self.floatMetric = floatMetric
        self.frontierK = frontierK
        self.matrixWeighting = matrixWeighting
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

    /// The signed weight for a lane key. Returns `defaultWeight(for:)` for any
    /// key absent from `laneWeights` — `1.0` for every key except
    /// `SignalKey.vector`, whose default is `0`.
    ///
    /// - Parameter laneKey: a stable lane identifier — a retrieval lane
    ///   (`"locus"`, `"bm25"`, `"hamming"`, `"dense"`, `"dense:<modelID>"`), a
    ///   matrix/graph/preference column (`"fieldFit"`, `"coOccurrence"`,
    ///   `"temporal"`, `"graph"`, `"preference"`) or a `signal:*` key. See the
    ///   lane-key scheme above.
    /// - Returns: the configured weight, or the key's default when absent.
    public func weight(for laneKey: String) -> Float {
        laneWeights[laneKey] ?? Self.defaultWeight(for: laneKey)
    }

    /// The weight a lane key carries when no shape and no provisioned default
    /// names it. `1.0` (neutral) for every key except `SignalKey.vector`, which
    /// defaults to `0`: the whole-record vector column (Hamming + dense) is out
    /// of the fused score by ruling (Encoder Rerank Program — the span rerank
    /// stage carries the semantic signal) and a shape brings it back by setting
    /// the key explicitly. The director's weight resolver and `weight(for:)`
    /// both read this, so the two agree. Rust twin: `RecallShape::default_weight`.
    public static func defaultWeight(for laneKey: String) -> Float {
        laneKey == SignalKey.vector ? 0 : 1.0
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

    // MARK: - Column-budget keys

    /// The `signal:*` lane keys (COL-1) that exclude or scale a WHOLE scoring
    /// column of the unionBest `.matrixAware` weighted score with budget
    /// redistribution. Spelled once here so a preset or an optimizer emission
    /// cannot mistype a key into a silent no-op. Each key names a
    /// `RecallSignalBudget.Column`.
    public enum SignalKey {
        /// The locus (bitmap-lane) column budget.
        public static let locus = "signal:locus"
        /// The BM25 column budget.
        public static let bm25 = "signal:bm25"
        /// The vector budget shared by the Hamming and dense columns.
        public static let vector = "signal:vector"
        /// The field-fit column budget.
        public static let fieldFit = "signal:fieldFit"
        /// The matrix budget shared by the coOccurrence and temporal columns.
        public static let matrix = "signal:matrix"
        /// The graph column budget.
        public static let graph = "signal:graph"
        /// The preference column budget (drawn from the graph slice).
        public static let preference = "signal:preference"
        /// The fixed signal-agreement bonus.
        public static let agreement = "signal:agreement"
        /// The span rerank stage switch (contract sheet §8): `0` skips the
        /// stage, any other value runs it. Not a scoring column — it has no
        /// budget slice and never redistributes — so it is not in `all`.
        public static let encoder = "signal:encoder"
        /// Every column-budget key, in step-9 column order.
        public static let all: [String] = [locus, bm25, vector, fieldFit, matrix, graph, preference, agreement]
    }

    // MARK: - Named preset roster

    /// The `dense:<modelID>` lane keys. `encoder` and `key(forModelID:)` name
    /// the span rerank stage's weight in every build. The whole-record
    /// provider keys (e.g. `randomIndexing`, `lsa`) name the exact `modelID`
    /// strings the CorpusKit providers ship (CorpusKitProviders/*Provider.swift),
    /// so a typo in a provider id surfaces as a build error, not a silent no-op.
    public enum DenseSignal {
        /// Random-Indexing distributional provider — `"random-indexing-v1"`.
        public static let randomIndexing = "dense:random-indexing-v1"
        /// Latent-Semantic-Analysis provider — `"lsa-v1"`.
        public static let lsa = "dense:lsa-v1"
        /// The span rerank encoder lane, keyed by the floor model's registry id
        /// (contract sheet §1: `<model>-w<window_words>`). The stage reads the
        /// key for whichever model is ACTIVE via `key(forModelID:)`; this
        /// constant is the floor model's spelling for presets and docs.
        public static let encoder = "dense:minilm-l6-v2-w60"

        /// The lane key for a model id: `"dense:<modelID>"`. One spelling for
        /// the dense consensus fold and the span rerank weight alike.
        public static func key(forModelID modelID: String) -> String { "dense:\(modelID)" }

        /// The distributional dense lane keys in stable canonical order: RI then LSA.
        /// Used by `consensus`/`broad` presets to forward every distributional signal.
        public static let all: [String] = [randomIndexing, lsa]
    }

    /// The names of every preset in the roster, in stable declaration order.
    /// This is the discoverable surface the catalog and the ARIA tool enumerate.
    ///
    /// `"balanced"` is included for completeness even though it resolves to a
    /// `nil` shape (uniform fusion = today's behaviour) — listing it lets a
    /// caller pick "no steering" by name alongside the steered shapes.
    public static let presetNames: [String] = {
        var names: [String] = [
            "balanced",
            "precise",
            "broad",
            "lexical",
            "not_lexical",
        ]
        // Whole-record dense presets: they steer the per-signal float lanes
        // of the held whole-record providers, which exist only in this build.
        names += ["conceptual", "associative", "consensus", "ri_forward", "lsa_forward"]
        names += [
            "fast",
            "jaccard",
        ]
        // Float-lane metric presets: identical fusion to balanced, but the
        // whole-record float lane uses L2 or dot-product distance instead of
        // the default cosine. Mirrors the binaryMetric/jaccard pattern.
        names += ["float-l2", "float-dot"]
        names += [
            "matrix_decayed",
            "structural",
            "temporal",
            "connection",
            "field",
            "preference",
            "anti_redundant",
        ]
        // Per-signal anti-similarity variants: same suppression shape as
        // anti_redundant (bm25/hamming at -0.5, narrow frontier) but each
        // inverts a different per-signal dense lane to FARTHEST so callers
        // can target diversity in that semantic space.
        names += ["anti_redundant_ri", "anti_redundant_lsa"]
        names += [
            "session_hybrid",
            // Multi-column matrix presets: each amplifies two matrixAware columns
            // simultaneously so both signals strengthen each other's ranking.
            "temporal_connection",
            "field_preference",
            // Column-exclusion (ablation) presets (COL-1): each EXCLUDES one scoring
            // column of the matrixAware weighted score via its `signal:*` key and
            // redistributes that column's budget over the rest. They exist so a
            // harness arm can ask "what does ranking look like without this
            // column" through the ARIA verb that carries a shape (moot_recall_shaped),
            // which accepts a preset name and no inline shape.
            "no_locus",
            "no_field_fit",
            "no_matrix",
            "no_graph",
            "no_preference",
            "no_agreement",
            "no_bm25",
            "no_vector",
            // Encoder Rerank Program: skip the span rerank stage so the lexical
            // order stands unreranked. With the vector column out by default, the
            // fused order equals `no_vector`'s — that identity is pinned by test.
            // The name `cross_encoder` is RESERVED for the cross-encoder hook
            // (sheet §8) and is deliberately NOT in this roster: no shape
            // implements it in this program, so the tool must reject it as
            // unknown rather than run balanced fusion under that name.
            "no_encoder",
        ]
        return names
    }()

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
    /// Leave-one-out is reachable WITHOUT a
    /// dedicated preset: take any forward shape and zero one `dense:<modelID>`
    /// lane (e.g. set `DenseSignal.randomIndexing` to `0`) to ablate exactly
    /// that signal.
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
            let weights: [String: Float] = ["bm25": 1.5, "dense": 1.2]
            return RecallShape(laneWeights: weights, frontierK: frontierKFloor)

        // Concepts over keywords: amplify the distributional dense lanes
        // (RI and LSA, both always on)
        // and damp the literal keyword lane so semantically related — not
        // lexically identical — memories rise.
        case "conceptual":
            var weights: [String: Float] = ["bm25": 0.5]
            for key in DenseSignal.all { weights[key] = 1.5 }
            return RecallShape(laneWeights: weights)

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
            let weights: [String: Float] = ["bm25": 1.5, "dense": 0, "hamming": 0]
            return RecallShape(laneWeights: weights)

        // Binary-lane metric swap (W2.5 M1): identical fusion, but the
        // engram lanes score Jaccard set-overlap instead of Hamming
        // symmetric difference. Length-normalized: sparse fingerprints are
        // not penalized for having few bits.
        case "jaccard":
            return RecallShape(binaryMetric: "jaccard")

        // Float-lane metric presets: identical fusion to balanced, but the
        // whole-record float lane uses L2 or dot-product distance instead of
        // the default cosine. Mirrors the jaccard/binaryMetric pattern:
        // only the distance function changes; all lane weights remain neutral.
        case "float-l2":
            return RecallShape(floatMetric: "l2")

        // Negative dot product (−Σaᵢbᵢ) as the float-lane distance. Useful
        // for embeddings trained with a dot-product objective where larger
        // inner products indicate higher relevance.
        case "float-dot":
            return RecallShape(floatMetric: "dot")

        // W2.5 S4-C arm: identical fusion, but the matrixAware O/T signals
        // read the §8.13 exp-decayed projections instead of the counts.
        case "matrix_decayed":
            return RecallShape(matrixWeighting: "decayed")

        // Suppress the literal lanes: ZERO bm25 + fdc so only the distributional
        // and structural lanes decide. The complement of `lexical`.
        case "not_lexical":
            let weights: [String: Float] = ["bm25": 0]
            return RecallShape(laneWeights: weights)

        // Loose association: amplify the two most "associative" distributional
        // signals (RI and NMF) and widen the frontier so loosely-related memories
        // surface. The free-association shape.
        case "associative":
            let weights: [String: Float] = [DenseSignal.randomIndexing: 1.5]
            return RecallShape(laneWeights: weights, frontierK: frontierKCeiling)

        // Dense consensus: forward EVERY per-signal dense lane at full strength
        // (so the consensus fold that builds the `dense` column weighs every
        // distributional provider) and narrow the frontier so the agreed-upon
        // candidates dominate. The "where all the embedding models agree" shape.
        case "consensus":
            var weights: [String: Float] = [:]
            for key in DenseSignal.all { weights[key] = 1.0 }
            return RecallShape(laneWeights: weights, frontierK: frontierKFloor)

        // Single-signal forwarding: amplify ONE distributional dense lane and
        // ZERO its siblings so only that provider's geometry votes. The
        // `*_forward` presets isolate each held provider for ablation/inspection;
        // each zeros the sibling dense lane so only that provider's geometry votes.
        case "ri_forward":
            return singleDenseForward(DenseSignal.randomIndexing)
        case "lsa_forward":
            return singleDenseForward(DenseSignal.lsa)

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
        // duplicates can still cluster. With the dense families dark there is no
        // FDC lane to invert: the preset keeps the suppression and the narrow
        // frontier; `anti_redundant_ri` is the inversion that stays live.
        case "anti_redundant":
            return RecallShape(
                laneWeights: ["bm25": -0.5, "hamming": -0.5],
                frontierK: frontierKFloor)

        // Per-signal anti-similarity: same suppression shape as anti_redundant
        // (bm25/hamming at -0.5, frontier narrowed to the floor) but inverts
        // RI or LSA to FARTHEST
        // instead of FDC. Each variant targets diversity in the corresponding
        // distributional semantic space — useful when FDC structural coding
        // already covers the query and the caller wants distributional diversity.
        case "anti_redundant_ri":
            return RecallShape(
                laneWeights: ["bm25": -0.5, "hamming": -0.5],
                antiSimilarLanes: [DenseSignal.randomIndexing],
                frontierK: frontierKFloor)
        case "anti_redundant_lsa":
            return RecallShape(
                laneWeights: ["bm25": -0.5, "hamming": -0.5],
                antiSimilarLanes: [DenseSignal.lsa],
                frontierK: frontierKFloor)

        // Session-granularity hybrid recall: amplify bm25 (keyword match for
        // conversation fragments), dense (semantic similarity within the
        // session context), and temporal (recency within the session window).
        // The ShapedRecall recipe special-cases this name to route through
        // hybridRecall's scoredLane seam; the shape here represents the
        // per-lane steering for the frame recall pass inside that path.
        // Post-processing applies a bounded temporal-window boost and
        // speaker-aware weighting before the final re-sort — both are
        // applied after the evidence gate, so a zero-evidence hit can never
        // be lifted past a scored hit.
        case "session_hybrid":
            return RecallShape(
                laneWeights: [
                    "bm25": 1.3,
                    "dense": 1.2,
                    "temporal": 1.2,
                ])

        // Multi-column matrix presets: each amplifies two matrixAware columns
        // simultaneously. The two columns reinforce each other in the
        // matrixAware scoring path (SPEC § unionBest weighted-column score).
        // These presets are a no-op under .raw/.rrf (the matrix columns are
        // dark under those scoring strategies).

        // Temporal + co-occurrence: surfaces memories that are BOTH recently
        // relevant AND frequently filed together with the query's neighbourhood.
        // The two matrix signals compound: a drawer that is both recent and
        // frequently co-filed rises ahead of one that is merely one or the other.
        case "temporal_connection":
            return RecallShape(
                laneWeights: [
                    "temporal": 1.5,
                    "coOccurrence": 1.5,
                ])

        // Field-fit + preference: surfaces memories that BOTH match the query's
        // filing facets (FDC field-fit column) AND have been historically favoured
        // by the user (learned-preference column). The compound signal favours
        // drawers the user has reinforced within the query's own filing context.
        case "field_preference":
            return RecallShape(
                laneWeights: [
                    "fieldFit": 1.5,
                    "preference": 1.5,
                ])

        // Column-exclusion presets (COL-1): one `signal:*` key at 0 each. The
        // excluded column's budget is redistributed (RecallSignalBudget), so the
        // arm measures the ranking WITHOUT the column, not with a zero term.
        case "no_locus":
            return RecallShape(laneWeights: [SignalKey.locus: 0])
        case "no_field_fit":
            return RecallShape(laneWeights: [SignalKey.fieldFit: 0])
        case "no_matrix":
            return RecallShape(laneWeights: [SignalKey.matrix: 0])
        case "no_graph":
            return RecallShape(laneWeights: [SignalKey.graph: 0])
        case "no_preference":
            return RecallShape(laneWeights: [SignalKey.preference: 0])
        case "no_agreement":
            return RecallShape(laneWeights: [SignalKey.agreement: 0])
        case "no_bm25":
            return RecallShape(laneWeights: [SignalKey.bm25: 0])
        case "no_vector":
            return RecallShape(laneWeights: [SignalKey.vector: 0])
        // Span rerank ablation (sheet §8): the stage is skipped and the lexical
        // list enters the pool in BM25 order. No budget slice is involved.
        case "no_encoder":
            return RecallShape(laneWeights: [SignalKey.encoder: 0])

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
            return "Exactness — amplify keyword (bm25) + dense consensus (+ field-coding when the dense families are compiled in) over a narrow frontier."
        case "conceptual":
            return "Concepts over keywords — amplify the distributional dense lanes (RI and LSA), damp bm25."
        case "broad":
            return "Cast wide — forward every retrieval lane and widen the candidate frontier to the ceiling."
        case "lexical":
            return "Keyword/field only — amplify bm25 (+ fdc when compiled in), exclude the dense and Hamming vector lanes."
        case "jaccard":
            return "Jaccard binary metric — the engram lanes score set-overlap/union instead of Hamming distance; length-normalized similarity."
        case "float-l2":
            return "L2 float metric — the whole-record float lane scores Euclidean L2 distance instead of cosine; useful when absolute vector magnitude differences matter."
        case "float-dot":
            return "Dot-product float metric — the whole-record float lane scores negative dot product instead of cosine; useful for embeddings trained with a dot-product objective."
        case "matrix_decayed":
            return "Decayed matrix signals — the co-occurrence and temporal matrix columns read the §8.13 exp-decayed projections (recent evidence outweighs stale) instead of raw counts."
        case "not_lexical":
            return "Suppress the literal lanes — exclude bm25 (+ fdc when compiled in) so distributional and structural signals decide."
        case "associative":
            return "Loose association — amplify the RI (+ NMF when compiled in) distributional lanes over a wide frontier."
        case "consensus":
            return "Dense consensus — forward every per-signal dense lane over a narrow frontier; where the embedding models agree."
        case "ri_forward":
            return "Isolate Random-Indexing — amplify the RI dense lane, exclude the other distributional signals."
        case "lsa_forward":
            return "Isolate LSA — amplify the LSA dense lane, exclude the other distributional signals."
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
            return "Diversity — suppress BM25/Hamming (-0.5) so lexical near-duplicates cannot dominate, invert FDC to farthest when the dense families are compiled in; narrow frontier to 64."
        case "anti_redundant_ri":
            return "Diversity (RI space) — invert the RI dense lane to farthest + suppress BM25/Hamming (-0.5); narrow frontier to 64. Targets distributional diversity in the random-indexing semantic space."
        case "anti_redundant_lsa":
            return "Diversity (LSA space) — invert the LSA dense lane to farthest + suppress BM25/Hamming (-0.5); narrow frontier to 64. Targets distributional diversity in the latent-semantic space."
        case "session_hybrid":
            return "Session-granularity — hybridRecall scoredLane + bounded temporal-window boost + speaker-aware weighting; amplify bm25 + dense + temporal."
        case "temporal_connection":
            return "Recent + co-filed — amplify temporal (recency) + coOccurrence (shared filing neighbourhood) together; matrixAware scoring only."
        case "field_preference":
            return "Filed + preferred — amplify fieldFit (FDC facet match) + preference (learned user preference) together; matrixAware scoring only."
        case "no_locus":
            return "Ablation — exclude the locus (bitmap recency-rank) column and redistribute its budget; matrixAware scoring only."
        case "no_field_fit":
            return "Ablation — exclude the fieldFit column and redistribute its budget; matrixAware scoring only."
        case "no_matrix":
            return "Ablation — exclude the coOccurrence + temporal matrix columns and redistribute their budget; matrixAware scoring only."
        case "no_graph":
            return "Ablation — exclude the graph column and redistribute its budget; matrixAware scoring only."
        case "no_preference":
            return "Ablation — exclude the preference column and redistribute its budget; matrixAware scoring only."
        case "no_agreement":
            return "Ablation — drop the fixed signal-agreement bonus; matrixAware scoring only."
        case "no_bm25":
            return "Ablation — exclude the BM25 column and redistribute its budget; candidates from the lexical lane still enter the pool; matrixAware scoring only."
        case "no_vector":
            return "Ablation — exclude the vector column (Hamming + dense) and redistribute its budget; candidates from the excluded lane still enter the pool; matrixAware scoring only. The vector column is already out by default, so this names the default explicitly."
        case "no_encoder":
            return "Ablation — skip the span rerank stage; the lexical list enters the pool in BM25 order. Fuses identically to no_vector."
        default:
            return ""
        }
    }

    /// A shape that forwards exactly one dense lane and zeroes its distributional
    /// siblings — the `*_forward` preset body. The named lane is amplified;
    /// every other `DenseSignal.all` key is excluded.
    private static func singleDenseForward(_ forwardKey: String) -> RecallShape {
        var weights: [String: Float] = [:]
        for key in DenseSignal.all {
            weights[key] = (key == forwardKey) ? 1.5 : 0
        }
        return RecallShape(laneWeights: weights)
    }
}
