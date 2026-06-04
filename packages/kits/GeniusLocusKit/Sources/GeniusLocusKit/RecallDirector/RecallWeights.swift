/// Per-lane weights for the Recall Director's scoring combiner.
///
/// Default weights are uniform across the four primary lanes. Additional
/// fields (`fieldFit`, `diversity`, `graph`) are zero by default and are
/// raised adaptively by `RecallWeights.adaptive` when the union profile
/// indicates those signals are informative.
public struct RecallWeights: Sendable {
    /// Weight for the LocusKit bitmap lane.
    public let locus: Float
    /// Weight for the BM25 keyword lane (CorpusKit).
    public let bm25: Float
    /// Weight for the vector similarity lane.
    public let vector: Float
    /// Weight for the matrix (co-occurrence / temporal) lane.
    public let matrix: Float
    /// Weight for the matrix field-presence signal.
    public let fieldFit: Float
    /// Weight for the diversity / redundancy-penalty term.
    public let diversity: Float
    /// Weight for the graph coherence signal.
    public let graph: Float

    /// Uniform weights — all primary lanes contribute equally at 0.25.
    ///
    /// `fieldFit`, `diversity`, and `graph` are 0.0; use
    /// `RecallWeights.adaptive` to compute signal-aware weights for a
    /// given query and union profile.
    public static let uniform = RecallWeights(
        locus: 0.25, bm25: 0.25, vector: 0.25, matrix: 0.25,
        fieldFit: 0, diversity: 0, graph: 0
    )

    /// Create a fully specified weight set.
    ///
    /// - Parameters:
    ///   - locus:     Weight for the LocusKit bitmap lane.
    ///   - bm25:      Weight for the BM25 keyword lane.
    ///   - vector:    Weight for the vector similarity lane.
    ///   - matrix:    Weight for the matrix lane.
    ///   - fieldFit:  Weight for the matrix field-presence signal.
    ///   - diversity: Weight for the diversity / redundancy-penalty term.
    ///   - graph:     Weight for the graph coherence signal.
    public init(
        locus: Float,
        bm25: Float,
        vector: Float,
        matrix: Float,
        fieldFit: Float,
        diversity: Float,
        graph: Float
    ) {
        self.locus     = locus
        self.bm25      = bm25
        self.vector    = vector
        self.matrix    = matrix
        self.fieldFit  = fieldFit
        self.diversity = diversity
        self.graph     = graph
    }
}

/// The Recall Director's execution plan for a single request.
///
/// Computed before lane recall runs; captures the effective mode and the
/// frontier-K value (how many candidates to retrieve before applying limit).
public struct RecallPlan: Sendable {
    /// The mode the director resolved to (may differ from request.mode
    /// when fallback applies in a future version).
    public let effectiveMode: GLKRecallMode
    /// Candidate retrieval count before scoring.
    ///
    /// Formula: `min(max(limit * 4, 64), 256)`. This provides enough
    /// candidates for scoring and deduplication without retrieving
    /// unbounded rows from the estate.
    public let frontierK: Int
    /// Weights in effect for this plan.
    public let weights: RecallWeights
}
