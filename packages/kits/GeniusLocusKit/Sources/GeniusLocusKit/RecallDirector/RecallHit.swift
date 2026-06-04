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
}
