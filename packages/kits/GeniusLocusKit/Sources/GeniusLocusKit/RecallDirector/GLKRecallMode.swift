/// The recall lane a GLKRecallRequest routes through.
///
/// Five modes are defined. The first four (`.locusOnly`, `.corpusOnly`,
/// `.hybrid`, `.unionBest`) are the original scored recall lanes. The
/// fifth (`.nodeTreeNative`) activates the host-tree topology path:
/// tree edges from a registered `NodeTopologyProvider` are frozen once
/// at recall start (G1) and unioned with estate tunnel edges to produce
/// the StructureGraph that the structural lenses consume.
public enum GLKRecallMode: String, Sendable, Codable, CaseIterable {
    /// Bitmap-index scan through LocusKit only.
    case locusOnly
    /// BM25 keyword scan through CorpusKit only.
    case corpusOnly
    /// Combined LocusKit bitmap + CorpusKit BM25 + vector lane.
    case hybrid
    /// Union results from all available lanes, greedy MMR deduplication.
    case unionBest
    /// Host tree topology path. The RecallDirector reads tree edges from
    /// a registered `NodeTopologyProvider` exactly once (G1), freezes them
    /// into the StructureGraph for this recall, and unions them with estate
    /// tunnel edges. Tree edges are tagged with label "containment" so
    /// structural lenses can weight tree-vs-graph edges independently.
    /// When no provider is registered for the handle, this mode behaves
    /// identically to `.locusOnly` (empty tree edge set).
    case nodeTreeNative
}
