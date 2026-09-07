//! Human-readable explanation lines for a selected recall hit.
//!
//! Twin of Swift `RecallExplainer` (RecallExplainer.swift). Explanations are
//! computed ONLY for hits that survived the UnionBest selection pass, never
//! for frontier candidates, so the cost is proportional to the result limit,
//! not to frontierK.
//!
//! Each explanation is a small array of strings, one per semantic line, and
//! the two ports must render them byte-identically (the ARIA `explain`
//! argument surfaces them verbatim under each candidate row):
//!   "sources: corpusBM25, locusBitmap"
//!   "score: locus=0.82 bm25=0.71 vector=0.00 dense=0.00 fieldFit=0.44 coOccurrence=0.00 temporal=0.00 graph=0.00 preference=0.00 agreement=0.02 final=0.412 span:1:0.744"
//!   "mode: unionBest | scoring: matrixAware"
//!   "why: content query; BM25 and vector weighted high; MatrixO cluster preserved"
//!
//! A hit the span rerank stage scored carries one more token on the score line,
//! `span:<best_span_index>:<cosine to 3 dp>` (contract sheet §8); a hit without
//! a span hit carries no `span:` token, so its absence means "no span row under
//! the active encoder", not a zero cosine. A hit the step 5.8 sub-span window
//! budget left unscored carries the token `subSpan:budget`: its dense column
//! is the stored signal alone.

use crate::recall::{GLKRecallScoring, RecallHit, RecallPlan};

/// Explain one selected recall hit.
///
/// Returns the explanation lines characterising the hit's evidence sources,
/// score decomposition, recall mode, and a "why" sentence. `has_query_text`
/// is the request's `query_text.is_some()` (Swift reads the compiled sketch's
/// `queryText`; the sketch carries the request text unchanged, so the request
/// field is the same predicate). `agreement` is the signal-agreement bonus the
/// hit earned in the UnionBest MatrixAware weighted score
/// (`budget.agreement × 0.05 × popcount(sourceMask) / 5`); callers on paths
/// that add no bonus pass 0. `sub_span_unscored` is true when the step 5.8
/// sub-span window budget ran out before this hit was scored (Swift
/// `subSpanUnscored`); callers on paths without step 5.8 pass false.
pub fn explain(
    hit: &RecallHit,
    has_query_text: bool,
    plan: &RecallPlan,
    scoring: GLKRecallScoring,
    agreement: f32,
    sub_span_unscored: bool,
) -> Vec<String> {
    let mut lines: Vec<String> = Vec::with_capacity(4);

    // Line 1 — active evidence sources, sorted by raw value for deterministic
    // output (Swift sorts the Set's rawValues; Rust sorts the Vec's raw_values,
    // the same total order on the same ASCII names).
    let mut source_names: Vec<&'static str> = hit.sources.iter().map(|s| s.raw_value()).collect();
    source_names.sort_unstable();
    source_names.dedup();
    let sources = if source_names.is_empty() { "none".to_string() } else { source_names.join(", ") };
    lines.push(format!("sources: {sources}"));

    // Line 2 — EVERY score column to 2 dp in the fixed column order of the
    // weighted score, then the agreement bonus and the fused final to 3 dp (so
    // two hits that differ only in the third decimal still read as ordered). A
    // column that reads 0.00 is evidence in its own right when the question is
    // which column moved a ranking (COL-1). `{:.2}` on an f32 and Swift's
    // `String(format: "%.2f", Float)` both round the exact binary value to
    // nearest-even, so the rendered digits agree.
    let sv = &hit.score;
    let mut score_line = format!(
        "score: locus={:.2} bm25={:.2} vector={:.2} dense={:.2} fieldFit={:.2} coOccurrence={:.2} temporal={:.2} graph={:.2} preference={:.2} agreement={:.2} final={:.3}",
        sv.locus, sv.bm25, sv.vector, sv.dense, sv.field_fit, sv.co_occurrence,
        sv.temporal, sv.graph, sv.preference, agreement, sv.final_score
    );
    // Span rerank evidence (sheet §8): index of the best span and its cosine to
    // 3 dp, only for hits the stage scored. Swift renders the same
    // `span:%u:%.3f` token.
    if let Some(span) = &hit.span_hit {
        score_line.push_str(&format!(" span:{}:{:.3}", span.best_span_index, span.cosine));
    }
    // Sub-span budget evidence: the dense column of this hit is the stored
    // signal alone because the step 5.8 window budget ran out before it.
    // Swift renders the same `subSpan:budget` token.
    if sub_span_unscored {
        score_line.push_str(" subSpan:budget");
    }
    lines.push(score_line);

    // Line 3 — mode and scoring strategy.
    lines.push(format!(
        "mode: {} | scoring: {}",
        plan.effective_mode.raw_value(),
        scoring.raw_value()
    ));

    // Line 4 — "why" sentence built from query type and active signals.
    lines.push(why_line(hit, has_query_text));
    lines
}

/// Build the "why" sentence from the active query signals. Same reasons, same
/// order, same joiner as the Swift `whyLine`.
fn why_line(hit: &RecallHit, has_query_text: bool) -> String {
    let mut reasons: Vec<&'static str> = Vec::new();
    reasons.push(if has_query_text { "content query" } else { "bitmap filter match" });
    if hit.score.bm25 > 0.0 || hit.score.vector > 0.0 {
        reasons.push("BM25 and vector weighted high");
    }
    if hit.score.dense > 0.0 {
        reasons.push("dense float cosine match");
    }
    if hit.score.co_occurrence > 0.0 {
        reasons.push("MatrixO cluster preserved");
    }
    if hit.score.temporal > 0.0 {
        reasons.push("temporal pattern matched");
    }
    if hit.score.graph > 0.0 {
        reasons.push("graph coherence signal active");
    }
    format!("why: {}", reasons.join("; "))
}
