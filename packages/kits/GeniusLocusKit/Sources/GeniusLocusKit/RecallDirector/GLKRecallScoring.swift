/// Scoring strategy applied after lane recall completes.
///
/// All recall modes branch on the caller-requested scoring strategy. `.corpusOnly`
/// and `.hybrid` degrade `.matrixAware` to RRF and record a degraded-stage marker.
/// `.unionBest` degrades `.rrf` to raw (buffer.final) and implements the full
/// weighted pipeline only for `.matrixAware`. `.locusOnly` applies `.raw` ordering
/// (no reranking); other strategies on `.locusOnly` also resolve to raw ordering.
public enum GLKRecallScoring: String, Sendable, Codable, CaseIterable {
    /// No reranking: hits are returned in the order the active lane produced them.
    case raw
    /// Reciprocal Rank Fusion across multiple lanes. Live in `.corpusOnly` and `.hybrid`.
    case rrf
    /// Full weighted pipeline with matrix (co-occurrence + temporal), fieldFit, graph,
    /// and preference signals. Matrix scoring step 5.6 runs only when this is selected.
    case matrixAware
}
