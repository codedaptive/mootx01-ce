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
