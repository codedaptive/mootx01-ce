extension RecallWeights {
    /// Compute adaptive weights for a query based on its sketch and the observed
    /// union profile.
    ///
    /// The planner starts from fixed base weights and applies additive bonuses
    /// according to query and profile signals, then normalises so all weights
    /// sum to 1.0:
    ///
    /// - Structured filters (non-empty `bitmapPredicates`): +0.1 to locus and
    ///   fieldFit, rewarding the bitmap-index and field-presence signals when
    ///   the query has explicit structural constraints.
    /// - Query text present: +0.1 to bm25 and vector, rewarding keyword and
    ///   vector lanes when there is free-text to match against.
    /// - High redundancy (redundancy > 0.5): +0.15 to diversity, raising the
    ///   diversity / MMR penalty when the candidate buffer is dominated by
    ///   near-duplicate content.
    /// - High signal agreement (signalAgreement > 0.6): +0.1 to graph,
    ///   rewarding the graph coherence signal when multiple lanes agree.
    ///
    /// Returns weights normalised to sum ≈ 1.0.
    ///
    /// - Parameters:
    ///   - sketch:  The compiled query sketch for the current request.
    ///   - profile: The union profile computed over the merged candidate buffer.
    static func adaptive(for sketch: RecallQuerySketch, profile: RecallUnionProfile) -> RecallWeights {
        // Base weights. The active scoring combiner applies: locus, bm25, vector,
        // fieldFit, and graph. `diversity` is computed here and reserved for the
        // MMR λ-tuning pass in a future mission; it does not yet enter the combiner.
        // `matrix` is 0.1 base weight, reserved for a future signal lane.
        var locusW:     Float = 0.2
        var bm25W:      Float = 0.2
        var vectorW:    Float = 0.2
        let matrixW:    Float = 0.1
        var fieldFitW:  Float = 0.1
        var diversityW: Float = 0.1
        var graphW:     Float = 0.1

        // Structural filter bonus: locus and field-presence signals become more
        // informative when the query has explicit bitmap predicates.
        if !sketch.bitmapPredicates.isEmpty {
            locusW    += 0.1
            fieldFitW += 0.1
        }

        // Free-text bonus: keyword and vector lanes become more informative
        // when the query contains text to embed and match.
        if let text = sketch.queryText, !text.isEmpty {
            bm25W   += 0.1
            vectorW += 0.1
        }

        // Redundancy penalty bonus: raise diversity weight when the candidate
        // buffer is dominated by near-duplicate content, so MMR suppresses them.
        if profile.redundancy > 0.5 {
            diversityW += 0.15
        }

        // Signal agreement bonus: raise graph weight when multiple lanes
        // corroborate the same candidates, indicating robust evidence.
        if profile.signalAgreement > 0.6 {
            graphW += 0.1
        }

        // Normalise all weights to sum ≈ 1.0.
        let total = locusW + bm25W + vectorW + matrixW + fieldFitW + diversityW + graphW
        // Guard against the degenerate zero-total case (should never occur with
        // positive base weights, but safe to handle).
        let norm = total > 0 ? total : 1
        return RecallWeights(
            locus:     locusW     / norm,
            bm25:      bm25W      / norm,
            vector:    vectorW    / norm,
            matrix:    matrixW    / norm,
            fieldFit:  fieldFitW  / norm,
            diversity: diversityW / norm,
            graph:     graphW     / norm
        )
    }
}
