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
    /// Matrix field-presence signal. The F-based correlation score for the query
    /// candidate's bitmap fields against the estate's field-frequency table.
    /// Populated by RecallDirector step 5.6 when scoring is `.matrixAware` and
    /// a MatrixTier is registered. Contributes to the `fieldFit` buffer column.
    case matrixFieldPresence
    /// Matrix correlation signal (field-presence correlation, C = F / liveRowCount).
    /// Used as the F-normalised field-fit score in the matrixAware weighted pipeline.
    case matrixCorrelation
    /// Matrix co-occurrence count. The O[query, candidate] score summed over all
    /// (queryCoord, candidateCoord) pairs and normalised by liveRowCount.
    /// Populated by RecallDirector step 5.6 into the `coOccurrence` buffer column.
    case matrixCoOccurrence
    /// Matrix temporal decay signal. The T[source, target, lag] score summed over
    /// active lag buckets and normalised by liveRowCount. Populated by
    /// RecallDirector step 5.6 into the `temporal` buffer column.
    case matrixTemporal
    /// Graph coherence across the association graph.
    case graphCoherence
    /// Learned-preference signal from Bradley-Terry training.
    case learnedPreference
}
