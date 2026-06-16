/// Per-hit score decomposition across all evidence lanes.
///
/// Fields not populated by the active lane are 0.0. The locusOnly lane
/// sets `locus` to 1.0 for every returned hit. The `fieldFit`, `coOccurrence`,
/// `temporal`, and `graph` fields are populated by the matrix and graph lanes,
/// which are reserved for a future mission.
public struct RecallScoreVector: Sendable {
    /// Score contribution from the LocusKit bitmap lane.
    public let locus: Float
    /// Score contribution from BM25 keyword matching (CorpusKit lane).
    public let bm25: Float
    /// Score contribution from Hamming-distance vector matching.
    public let vector: Float
    /// Score contribution from matrix field-presence signal.
    public let fieldFit: Float
    /// Score contribution from matrix co-occurrence signal.
    public let coOccurrence: Float
    /// Score contribution from matrix temporal decay signal.
    public let temporal: Float
    /// Score contribution from graph coherence signal.
    public let graph: Float
    /// Score contribution from learned-preference (Bradley-Terry) signal.
    public let preference: Float
    /// Redundancy penalty subtracted from the combined score during deduplication.
    public let redundancyPenalty: Float
    /// Final combined score after all lane contributions and deduplication.
    public let final: Float

    /// Normalized cosine similarity from the DENSE FLOAT lane (Lane D), in
    /// `[0, 1]`. This is the TRUE float-embedding signal: cosine over the
    /// pooled 384/768-d vector, NOT the lossy 256-bit SimHash-Hamming `vector`
    /// column. Stored as `(cosineSimilarity + 1) / 2` so 1.0 = identical
    /// direction and the convention matches every other `[0, 1]` column
    /// (`normalizeFinals` and any weighted sum treat it uniformly). Defaults to
    /// 0 for hits that did not come from the dense lane — additive, like
    /// `hammingDistance`; no other field's meaning changes. RRF fusion is
    /// rank-based and never reads this magnitude; the column is for the
    /// explainer/optimizer and the `.matrixAware` weighted path.
    public let dense: Float

    /// Sentinel value for `hammingDistance` meaning "this hit did not come from
    /// the vector lane, so no Hamming distance was measured." Valid measured
    /// distances are in the inclusive range 0…256 (see `VectorMatch.distance`),
    /// so a negative value can never collide with a real measurement.
    public static let noHammingDistance: Int = -1

    /// Raw integer Hamming distance from the query probe to this candidate's
    /// stored engram, in the inclusive range 0…256, as produced by
    /// `VectorStore.findNearest` (carried verbatim from `VectorMatch.distance`).
    ///
    /// This is the exact popcount-on-XOR distance, NOT the lossy normalized
    /// similarity `vector = (256 - distance) / 256`. It is preserved here so the
    /// later dense-reduction recipes can rank on the integer distance directly
    /// rather than on the rounded similarity. Defaults to `noHammingDistance`
    /// (-1) for hits that did not come from the vector lane; the `vector` field
    /// remains the normalized similarity for all consumers that ranked on it.
    public let hammingDistance: Int

    /// Memberwise initializer with `hammingDistance` defaulted to the
    /// "no vector-lane hit" sentinel.
    ///
    /// `hammingDistance` is defaulted so every existing construction site that
    /// does not populate the vector lane compiles unchanged and carries the
    /// sentinel; the vector lane passes the raw `VectorMatch.distance` explicitly.
    /// This is purely additive: no other field's meaning or default changes.
    ///
    /// - Parameters:
    ///   - locus: LocusKit bitmap-lane contribution.
    ///   - bm25: BM25 keyword-lane contribution.
    ///   - vector: Normalized Hamming similarity in [0, 1].
    ///   - fieldFit: Matrix field-presence contribution.
    ///   - coOccurrence: Matrix co-occurrence contribution.
    ///   - temporal: Matrix temporal-decay contribution.
    ///   - graph: Graph-coherence contribution.
    ///   - preference: Learned-preference (Bradley-Terry) contribution.
    ///   - redundancyPenalty: Deduplication penalty subtracted from the combined score.
    ///   - final: Final combined score after fusion and deduplication.
    ///   - hammingDistance: Raw integer Hamming distance 0…256 for vector-lane
    ///     hits; `noHammingDistance` (-1) otherwise.
    ///   - dense: Normalized dense-float cosine similarity `(sim + 1) / 2` in
    ///     `[0, 1]`; 0 for hits not from the dense lane. Defaulted so existing
    ///     construction sites compile unchanged.
    public init(
        locus: Float,
        bm25: Float,
        vector: Float,
        fieldFit: Float,
        coOccurrence: Float,
        temporal: Float,
        graph: Float,
        preference: Float,
        redundancyPenalty: Float,
        final: Float,
        hammingDistance: Int = RecallScoreVector.noHammingDistance,
        dense: Float = 0
    ) {
        self.locus = locus
        self.bm25 = bm25
        self.vector = vector
        self.fieldFit = fieldFit
        self.coOccurrence = coOccurrence
        self.temporal = temporal
        self.graph = graph
        self.preference = preference
        self.redundancyPenalty = redundancyPenalty
        self.final = final
        self.hammingDistance = hammingDistance
        self.dense = dense
    }

    /// Create a score vector representing a pure locus-lane hit at full confidence.
    ///
    /// Used by the `locusOnly` lane where ordering is determined by
    /// LocusKit's own `RecallFrame` ordering, not by scoring math.
    /// All non-locus fields are 0.0; `final` equals the supplied `value`.
    ///
    /// - Parameter value: The locus-lane confidence score (typically 1.0).
    public static func locus(_ value: Float) -> RecallScoreVector {
        RecallScoreVector(
            locus: value,
            bm25: 0,
            vector: 0,
            fieldFit: 0,
            coOccurrence: 0,
            temporal: 0,
            graph: 0,
            preference: 0,
            redundancyPenalty: 0,
            final: value
        )
    }
}
