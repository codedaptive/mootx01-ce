/// Scoring strategy applied after lane recall completes.
///
/// `.raw` is applied by the `locusOnly` lane (no reranking). `.rrf` is used
/// by `corpusOnly` and `hybrid`. `.matrixAware` is reserved for a future
/// mission that introduces learned co-occurrence and temporal signals.
public enum GLKRecallScoring: String, Sendable, Codable, CaseIterable {
    /// No reranking: hits are returned in the order the active lane produced them.
    case raw
    /// Reciprocal Rank Fusion across multiple lanes. Live in `.corpusOnly` and `.hybrid`.
    case rrf
    /// Matrix-aware scoring that folds in learned co-occurrence and temporal signals.
    /// Reserved for a future mission. Not yet active.
    case matrixAware
}
