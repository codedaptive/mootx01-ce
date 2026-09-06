/// Produces human-readable explanation strings for a selected recall hit.
///
/// Explanations are computed ONLY for hits that survived the MMR selection
/// pass — never for all frontier candidates. This keeps the explanation
/// cost proportional to the result limit, not to frontierK.
///
/// Each explanation is a small array of strings, one per semantic line:
///   "sources: locusBitmap, corpusBM25"
///   "score: locus=0.82 bm25=0.71 vector=0.00 dense=0.00 fieldFit=0.44 coOccurrence=0.00 temporal=0.00 graph=0.00 preference=0.00 agreement=0.02 final=0.412 span:1:0.744"
///   "mode: unionBest | scoring: matrixAware"
///   "why: content query; BM25 and vector weighted high; MatrixO cluster preserved"
///
/// The `score:` line renders EVERY scoring column, zero or not (COL-1): a
/// column that reads 0.00 is evidence in its own right when the question is
/// which column moved a ranking, and a reader must not have to infer absence
/// from a missing token. `agreement` is the fixed signal-agreement bonus the
/// hit earned in the unionBest weighted score (0 under `.raw`/`.rrf`, which
/// never add it), and `final` is the fused ranking score. A hit the span
/// rerank stage scored carries one more token, `span:<bestSpanIndex>:<cosine
/// to 3 dp>` (contract sheet §8); a hit without a span hit carries no `span:`
/// token, so its absence means "no span row under the active encoder", not a
/// zero cosine.
struct RecallExplainer {

    /// Explain one selected recall hit.
    ///
    /// Returns an array of explanation strings characterising the hit's
    /// evidence sources, score decomposition, recall mode, and a
    /// human-readable "why" sentence. The array is non-empty for any hit
    /// with at least one active source.
    ///
    /// - Parameters:
    ///   - hit:     The selected `RecallHit` to explain.
    ///   - sketch:  The compiled query sketch (text, tokens, engram, filters).
    ///   - plan:    The execution plan the director used for this request.
    ///   - scoring: The scoring strategy active for this recall.
    ///   - agreement: The signal-agreement bonus this hit earned in the weighted
    ///     score (`0.05 × popcount(sourceMask) / 5`, scaled by the resolved
    ///     `signal:agreement` budget). Callers on paths that add no bonus pass 0.
    func explain(hit: RecallHit,
                 sketch: RecallQuerySketch,
                 plan: RecallPlan,
                 scoring: GLKRecallScoring,
                 agreement: Float = 0) -> [String] {
        var lines: [String] = []

        // Line 1 — active evidence sources, sorted for deterministic output.
        let sourceNames = hit.sources.map(\.rawValue).sorted().joined(separator: ", ")
        lines.append("sources: \(sourceNames.isEmpty ? "none" : sourceNames)")

        // Line 2 — every score column, 2 dp, in the fixed column order of the
        // weighted score, then the agreement bonus and the fused final (3 dp so
        // two hits that differ only in the third decimal still read as ordered).
        let sv = hit.score
        var scoreTokens: [String] = [
            String(format: "locus=%.2f",        sv.locus),
            String(format: "bm25=%.2f",         sv.bm25),
            String(format: "vector=%.2f",       sv.vector),
            String(format: "dense=%.2f",        sv.dense),
            String(format: "fieldFit=%.2f",     sv.fieldFit),
            String(format: "coOccurrence=%.2f", sv.coOccurrence),
            String(format: "temporal=%.2f",     sv.temporal),
            String(format: "graph=%.2f",        sv.graph),
            String(format: "preference=%.2f",   sv.preference),
            String(format: "agreement=%.2f",    agreement),
            String(format: "final=%.3f",        sv.final),
        ]
        // Span rerank evidence (sheet §8): index of the best span and its cosine
        // to 3 dp, only for hits the stage scored. The Rust twin renders the
        // same `span:%u:%.3f` token.
        if let span = hit.spanHit {
            scoreTokens.append(String(format: "span:%u:%.3f", span.bestSpanIndex, span.cosine))
        }
        lines.append("score: \(scoreTokens.joined(separator: " "))")

        // Line 3 — mode and scoring strategy.
        lines.append("mode: \(plan.effectiveMode.rawValue) | scoring: \(scoring.rawValue)")

        // Line 4 — "why" sentence built from query type and active signals.
        lines.append(whyLine(hit: hit, sketch: sketch))

        return lines
    }

    // MARK: - Private

    /// Build the "why" sentence from active query signals.
    private func whyLine(hit: RecallHit, sketch: RecallQuerySketch) -> String {
        var reasons: [String] = []
        if sketch.queryText != nil {
            reasons.append("content query")
        } else {
            reasons.append("bitmap filter match")
        }
        if hit.score.bm25 > 0 || hit.score.vector > 0 {
            reasons.append("BM25 and vector weighted high")
        }
        if hit.score.dense > 0 {
            reasons.append("dense float cosine match")
        }
        if hit.score.coOccurrence > 0 {
            reasons.append("MatrixO cluster preserved")
        }
        if hit.score.temporal > 0 {
            reasons.append("temporal pattern matched")
        }
        if hit.score.graph > 0 {
            reasons.append("graph coherence signal active")
        }
        return "why: \(reasons.joined(separator: "; "))"
    }
}
