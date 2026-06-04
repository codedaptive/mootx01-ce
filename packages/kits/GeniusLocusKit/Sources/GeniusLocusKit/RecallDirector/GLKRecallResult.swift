import LocusKit

/// The complete output of a `GLKRecallRequest` routed through the Recall Director.
public struct GLKRecallResult: Sendable {
    /// The original request that produced this result.
    public let request: GLKRecallRequest
    /// The plan the director computed before lane recall ran.
    public let plan: RecallPlan
    /// Cross-lane union profile. Populated by the `.unionBest` lane only.
    /// Nil for `.locusOnly`, `.corpusOnly`, and `.hybrid` results.
    public let unionProfile: RecallUnionProfile?
    /// Hits in the order the active lane and scoring returned them.
    public let hits: [RecallHit]

    /// Convenience accessor — the hydrated `Drawer` for each hit that has one.
    public var drawers: [LocusKit.Drawer] { hits.compactMap(\.drawer) }
}
