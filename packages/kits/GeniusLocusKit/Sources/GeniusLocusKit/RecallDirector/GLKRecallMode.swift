/// The recall lane a GLKRecallRequest routes through.
///
/// All four modes are live. `.locusOnly`, `.corpusOnly`, and `.hybrid` use
/// RRF fusion. `.unionBest` runs multi-lane union with greedy MMR deduplication.
public enum GLKRecallMode: String, Sendable, Codable, CaseIterable {
    /// Bitmap-index scan through LocusKit only.
    case locusOnly
    /// BM25 keyword scan through CorpusKit only.
    case corpusOnly
    /// Combined LocusKit bitmap + CorpusKit BM25 + vector lane.
    case hybrid
    /// Union results from all available lanes, greedy MMR deduplication.
    case unionBest
}
