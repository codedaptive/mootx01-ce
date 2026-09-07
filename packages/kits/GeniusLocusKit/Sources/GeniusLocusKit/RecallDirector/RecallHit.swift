import LocusKit

/// A single drawer returned by the Recall Director, with its score decomposition
/// and evidence provenance.
public struct RecallHit: Sendable {
    /// The drawer's stable row identifier. Matches `Drawer.id` (a `RowID` string).
    public let id: RowID
    /// The hydrated drawer, or nil if the drawer was not found in the estate.
    public let drawer: LocusKit.Drawer?
    /// Evidence lanes that contributed this hit.
    public let sources: Set<RecallEvidencePath>
    /// Score decomposition across all evidence lanes.
    public let score: RecallScoreVector
    /// Human-readable explanation tokens, one per active evidence lane.
    public let explanation: [String]
    /// The span rerank hit for this drawer (best span index, word bounds, cosine
    /// and lexical rank under the active encoder), when the unionBest span stage
    /// scored it (contract sheet §8). Nil for every other lane and for drawers
    /// with no span rows under the active model; the composer renders the evidence
    /// snippet from the bounds when present (sheet §9).
    public let spanHit: SpanRerankHit?

    init(
        id: RowID,
        drawer: LocusKit.Drawer?,
        sources: Set<RecallEvidencePath>,
        score: RecallScoreVector,
        explanation: [String],
        spanHit: SpanRerankHit? = nil
    ) {
        self.id = id
        self.drawer = drawer
        self.sources = sources
        self.score = score
        self.explanation = explanation
        self.spanHit = spanHit
    }
}
