/// Scoring strategy applied after lane recall completes.
///
/// All recall modes branch on the caller-requested scoring strategy. `.corpusOnly`
/// and `.hybrid` degrade `.matrixAware` to RRF and record a degraded-stage marker.
/// `.unionBest` degrades `.rrf` to raw (buffer.final) and implements the full
/// weighted pipeline only for `.matrixAware`. `.locusOnly` applies `.raw` ordering
/// (no reranking); other strategies on `.locusOnly` also resolve to raw ordering.
///
/// `.discriminative` is a lighter alternative to `.matrixAware`: it applies the
/// dense-lane saturation discount (computed identically to `.matrixAware`) to the
/// RRF-fused composite score, without enabling the matrix, fieldFit, graph, or
/// preference signal columns. When the dense lane is contrastive (spread ≥ 0.15)
/// the discount is 1.0 and discriminative is byte-identical to rrf.
public enum GLKRecallScoring: String, Sendable, Codable, CaseIterable {
    /// No reranking: hits are returned in the order the active lane produced them.
    case raw
    /// Reciprocal Rank Fusion across multiple lanes. Live in `.corpusOnly` and `.hybrid`.
    case rrf
    /// Full weighted pipeline with matrix (co-occurrence + temporal), fieldFit, graph,
    /// and preference signals. Matrix scoring step 5.6 runs only when this is selected.
    case matrixAware
    /// RRF-based scoring with the dense-lane saturation discount applied to the
    /// composite score. The discount (`denseDiscriminationFactor` ∈ [0, 1]) is
    /// computed from the mean relative spread of nearest cosines across all dense
    /// signals — the same factor used by `.matrixAware`. Unlike `.matrixAware`,
    /// no matrix steer, fieldFit, graph, or preference columns are applied.
    /// When the dense lane is absent or fully contrastive (spread ≥ 0.15) the
    /// factor is 1.0 and the result is byte-identical to `.rrf`.
    case discriminative
}
