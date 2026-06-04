/// Scoring strategy applied after lane recall completes.
///
/// `.raw` is applied by the `locusOnly` lane (no reranking). `.rrf` is used
/// by `corpusOnly` and `hybrid`. `.matrixAware` enables the full weighted pipeline
/// with matrix (co-occurrence + temporal), fieldFit, graph, and preference signals.
public enum GLKRecallScoring: String, Sendable, Codable, CaseIterable {
    /// No reranking: hits are returned in the order the active lane produced them.
    case raw
    /// Reciprocal Rank Fusion across multiple lanes. Live in `.corpusOnly` and `.hybrid`.
    case rrf
    /// Full weighted pipeline with matrix (co-occurrence + temporal), fieldFit, graph,
    /// and preference signals. Matrix scoring step 5.6 runs only when this is selected.
    case matrixAware
}
