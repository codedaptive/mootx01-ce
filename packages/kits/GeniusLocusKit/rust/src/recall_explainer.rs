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
//!   "score: locus=0.82 bm25=0.71 fieldFit=0.44"
//!   "mode: unionBest | scoring: matrixAware"
//!   "why: content query; BM25 and vector weighted high; MatrixO cluster preserved"

use crate::recall::{GLKRecallScoring, RecallHit, RecallPlan};

/// Explain one selected recall hit.
///
/// Returns the explanation lines characterising the hit's evidence sources,
/// score decomposition, recall mode, and a "why" sentence. `has_query_text`
/// is the request's `query_text.is_some()` (Swift reads the compiled sketch's
/// `queryText`; the sketch carries the request text unchanged, so the request
/// field is the same predicate).
pub fn explain(
    hit: &RecallHit,
    has_query_text: bool,
    plan: &RecallPlan,
    scoring: GLKRecallScoring,
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

    // Line 2 — non-zero score components to 2 dp. `{:.2}` on an f32 and
    // Swift's `String(format: "%.2f", Float)` both round the exact binary
    // value to nearest-even, so the rendered digits agree.
    let sv = &hit.score;
    let mut tokens: Vec<String> = Vec::new();
    if sv.locus         > 0.0 { tokens.push(format!("locus={:.2}",        sv.locus)); }
    if sv.bm25          > 0.0 { tokens.push(format!("bm25={:.2}",         sv.bm25)); }
    if sv.vector        > 0.0 { tokens.push(format!("vector={:.2}",       sv.vector)); }
    if sv.dense         > 0.0 { tokens.push(format!("dense={:.2}",        sv.dense)); }
    if sv.field_fit     > 0.0 { tokens.push(format!("fieldFit={:.2}",     sv.field_fit)); }
    if sv.co_occurrence > 0.0 { tokens.push(format!("coOccurrence={:.2}", sv.co_occurrence)); }
    if sv.temporal      > 0.0 { tokens.push(format!("temporal={:.2}",     sv.temporal)); }
    if sv.graph         > 0.0 { tokens.push(format!("graph={:.2}",        sv.graph)); }
    if sv.preference    > 0.0 { tokens.push(format!("preference={:.2}",   sv.preference)); }
    let score = if tokens.is_empty() {
        format!("final={:.2}", sv.final_score)
    } else {
        tokens.join(" ")
    };
    lines.push(format!("score: {score}"));

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
