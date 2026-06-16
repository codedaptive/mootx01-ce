/// Produces human-readable explanation strings for a selected recall hit.
///
/// Explanations are computed ONLY for hits that survived the MMR selection
/// pass — never for all frontier candidates. This keeps the explanation
/// cost proportional to the result limit, not to frontierK.
///
/// Each explanation is a small array of strings, one per semantic line:
///   "sources: locusBitmap, corpusBM25"
///   "score: locus=0.82 bm25=0.71 fieldFit=0.44"
///   "mode: unionBest | scoring: matrixAware"
///   "why: content query; BM25 and vector weighted high; MatrixO cluster preserved"
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
    func explain(hit: RecallHit,
                 sketch: RecallQuerySketch,
                 plan: RecallPlan,
                 scoring: GLKRecallScoring) -> [String] {
        var lines: [String] = []

        // Line 1 — active evidence sources, sorted for deterministic output.
        let sourceNames = hit.sources.map(\.rawValue).sorted().joined(separator: ", ")
        lines.append("sources: \(sourceNames.isEmpty ? "none" : sourceNames)")

        // Line 2 — non-zero score components formatted to 2 dp.
        let sv = hit.score
        var scoreTokens: [String] = []
        if sv.locus        > 0 { scoreTokens.append(String(format: "locus=%.2f",        sv.locus))        }
        if sv.bm25         > 0 { scoreTokens.append(String(format: "bm25=%.2f",         sv.bm25))         }
        if sv.vector       > 0 { scoreTokens.append(String(format: "vector=%.2f",        sv.vector))       }
        if sv.dense        > 0 { scoreTokens.append(String(format: "dense=%.2f",         sv.dense))        }
        if sv.fieldFit     > 0 { scoreTokens.append(String(format: "fieldFit=%.2f",      sv.fieldFit))     }
        if sv.coOccurrence > 0 { scoreTokens.append(String(format: "coOccurrence=%.2f",  sv.coOccurrence)) }
        if sv.temporal     > 0 { scoreTokens.append(String(format: "temporal=%.2f",      sv.temporal))     }
        if sv.graph        > 0 { scoreTokens.append(String(format: "graph=%.2f",         sv.graph))        }
        if sv.preference   > 0 { scoreTokens.append(String(format: "preference=%.2f",    sv.preference))   }
        let scoreStr = scoreTokens.isEmpty ? "final=\(String(format: "%.2f", sv.final))" : scoreTokens.joined(separator: " ")
        lines.append("score: \(scoreStr)")

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
