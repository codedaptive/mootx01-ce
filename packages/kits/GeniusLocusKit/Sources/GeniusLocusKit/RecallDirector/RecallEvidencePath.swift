/// The evidence lane that contributed a hit to a recall result.
public enum RecallEvidencePath: String, Sendable, Codable, CaseIterable {
    /// Bitmap-index scan through LocusKit (locusOnly lane).
    case locusBitmap
    /// Knowledge-graph traversal through LocusKit.
    case locusGraph
    /// BM25 keyword score from CorpusKit.
    case corpusBM25
    /// Hamming-distance vector match.
    case vectorHamming
    /// Dense float-embedding cosine match (Lane D) — the TRUE float vector
    /// lane, distinct from the 256-bit SimHash-Hamming `vectorHamming` lane.
    case vectorDense
    /// Matrix field-presence signal. Reserved for a future mission.
    case matrixFieldPresence
    /// Matrix co-occurrence signal. Reserved for a future mission.
    case matrixCorrelation
    /// Matrix co-occurrence count. Reserved for a future mission.
    case matrixCoOccurrence
    /// Matrix temporal decay signal. Reserved for a future mission.
    case matrixTemporal
    /// Graph coherence across the association graph.
    case graphCoherence
    /// Learned-preference signal from Bradley-Terry training.
    case learnedPreference
}
