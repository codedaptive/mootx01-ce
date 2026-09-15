// packager.rs — GLKResultsPackager Rust port (PACKAGER mission).
//
// Mirrors Swift `GeniusLocusKit/RecallDirector/GLKResultsPackager.swift`.
//
// Post-recall, pre-presentation packager that determines the response
// shape adjective (never/always/auto), computes the four gate signals,
// applies the WEAK -> CONFIDENT -> INTERMEDIATE gate, applies the score-cliff
// row cutoff, and returns a `GLKPackagedResult` for the ARIA boundary to
// render.
//
// ## Gate signals (all mirrored from the Swift reference)
//   m1 — Top-margin: (score[0] - score[1]) / max(score[0], epsilon).  Measures
//         how decisively the top hit leads the second.
//   m2 — Lane agreement: normalised Spearman footrule between the lexical head
//         order (bm25_rank ascending) and the span rerank order (cosine
//         descending, ties by bm25_rank ascending) over the span-scored top-10
//         hits. 1.0 when they agree perfectly, 0.0 when fully reversed.
//         Stays 0.0 when no span hits are available.
//   m3 — Span cosine spread: population standard deviation of the span cosines
//         over the span-scored top-10 hits. A non-zero spread signals that the
//         encoder found discriminative evidence. 0.0 when fewer than 2 span
//         hits exist (triggers WEAK for multi-hit results); 1.0 for the
//         single-total-hit special case (WEAK must not fire on the only hit).
//   m4 — Word-boundary containment: >=60% of the distinctive words in the
//         composed answer appear in the top hit's drawer content. Guards against
//         hallucinated answers that do not trace to the top citation.
//
// ## Gate decision (order is load-bearing — WEAK checked first)
//   WEAK        — m1 < t1'  OR  m3 < t3'
//   CONFIDENT   — m1 >= t1  AND  m2 >= t2  AND  m4 = true
//   INTERMEDIATE — neither of the above
//
// ## Response levels
//   L0AnswerOnly — answer block with no result rows (CONFIDENT only)
//   L1Full       — answer block + rows (CONFIDENT or INTERMEDIATE)
//   RowsOnly     — dense rows, no answer block (WEAK or answer:never)
//
// ## Score-cliff row cutoff
//   Start including rows at index 0. After the kMin-th row has been included,
//   check each successive gap. Stop (exclusive) when a gap >= c * spread fires.
//   If no cliff fires, include up to kMax rows.
//
// Conformance is gated by the golden-pin tests in
// `tests/packager_parity.rs`, using the same numeric fixtures as the Swift
// golden-pin tests in `GLKResultsPackagerTests.swift`.

use crate::recall::{GLKRecallResult, RecallHit};

// ---------------------------------------------------------------------------
// PackagerAnswerMode
// ---------------------------------------------------------------------------

/// Selects the response shape adjective at the ARIA boundary.
///
/// Mirrors Swift `PackagerAnswerMode`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PackagerAnswerMode {
    /// No answer block. Dense rows only, byte-identical to the pre-packager path.
    /// Default for backward compatibility.
    Never,
    /// Always compose and prepend an answer block (L1-full minimum).
    Always,
    /// Server selects the response level by confidence gate (L0/L1/rowsOnly).
    Auto,
}

impl PackagerAnswerMode {
    /// Parse from the string value sent over MCP (`"never"`, `"always"`, `"auto"`).
    /// Returns `None` on unknown values — callers must fail-closed (invalidParams).
    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "never" => Some(Self::Never),
            "always" => Some(Self::Always),
            "auto" => Some(Self::Auto),
            _ => None,
        }
    }
}

// ---------------------------------------------------------------------------
// PackagerConfidenceLevel
// ---------------------------------------------------------------------------

/// The gate verdict after evaluating the four gate signals.
///
/// Mirrors Swift `PackagerConfidenceLevel`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PackagerConfidenceLevel {
    Confident,
    Intermediate,
    Weak,
}

// ---------------------------------------------------------------------------
// GLKResponseLevel
// ---------------------------------------------------------------------------

/// Which response shape the packager selected for this result.
///
/// Mirrors Swift `GLKResponseLevel`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GLKResponseLevel {
    /// Answer block only; no result rows. Used when confidence is CONFIDENT and
    /// the answer fully covers the query.
    L0AnswerOnly,
    /// Answer block + result rows. Used for CONFIDENT (always mode) or INTERMEDIATE.
    L1Full,
    /// Dense rows only; no answer block. Used when WEAK or mode is `Never`.
    RowsOnly,
}

// ---------------------------------------------------------------------------
// GLKConfidenceSignals
// ---------------------------------------------------------------------------

/// The four computed gate signals, exposed for diagnostics and the signals: line
/// in the ARIA response. All values are in `[0.0, 1.0]` except m4 which is bool.
///
/// Mirrors Swift `GLKConfidenceSignals`.
#[derive(Debug, Clone, PartialEq)]
pub struct GLKConfidenceSignals {
    /// m1: top-margin = (score[0] - score[1]) / max(score[0], epsilon).
    pub m1: f64,
    /// m2: lane agreement = normalised Spearman footrule between the lexical
    /// order and the span rerank order of the span-scored top-10 hits.
    pub m2: f64,
    /// m3: span cosine spread = population stddev of span cosines over the
    /// span-scored top-10 hits. 0.0 when fewer than 2 span hits exist
    /// (multi-hit case); 1.0 for a single-total-hit result.
    pub m3: f64,
    /// m4: word-boundary containment — ≥60% of answer's distinctive words appear
    /// in the top citation's drawer content.
    pub m4: bool,
}

// ---------------------------------------------------------------------------
// GLKAnswerBlock
// ---------------------------------------------------------------------------

/// The composed answer ready for the ARIA presentation layer.
///
/// Mirrors Swift `GLKAnswerBlock`.
#[derive(Debug, Clone, PartialEq)]
pub struct GLKAnswerBlock {
    /// The composed answer text. Source: GroundedSynthesis output injected by the
    /// AriaMcpKit layer; GLKResultsPackager never calls GroundedSynthesis directly.
    pub answer: String,
    /// The gate verdict (`Confident` or `Intermediate`; WEAK carries no
    /// block). The ARIA boundary renders `confidence:` from this value.
    pub confidence_level: PackagerConfidenceLevel,
    /// Drawer IDs of the top citations that back the answer: the first
    /// five hydrated hits, in rank order (Swift `citationIDs`).
    pub citation_ids: Vec<String>,
    /// The four computed gate signals.
    pub signals: GLKConfidenceSignals,
}

// ---------------------------------------------------------------------------
// GLKPackagedResult
// ---------------------------------------------------------------------------

/// The complete post-recall, pre-presentation output.
///
/// Mirrors Swift `GLKPackagedResult`.
///
/// Note: `GLKPackagedResult` does not derive `PartialEq` because `RecallHit`
/// does not implement `PartialEq`. Compare `level` and `answer_block` directly
/// in tests; compare `rows` lengths or ids.
#[derive(Debug, Clone)]
pub struct GLKPackagedResult {
    /// Which response level the packager selected.
    pub level: GLKResponseLevel,
    /// Answer block. Some when level is L0AnswerOnly or L1Full, None when RowsOnly.
    pub answer_block: Option<GLKAnswerBlock>,
    /// Result rows for the ARIA presentation layer (empty for L0AnswerOnly).
    pub rows: Vec<RecallHit>,
    /// Total candidate count before cliff cutoff (for the "found N memory(s)" header).
    pub total_count: usize,
}

// ---------------------------------------------------------------------------
// PackagerThresholds
// ---------------------------------------------------------------------------

/// Tunable gate thresholds. All fields carry spec-default values.
///
/// In normal operation these are derived from `RecallTuningManifest::packager_thresholds()`.
/// Overriding is primarily for tests and the quality optimizer.
///
/// Mirrors Swift `PackagerThresholds`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PackagerThresholds {
    /// CONFIDENT gate: minimum top-margin (m1). Default: 0.25.
    pub t1: f64,
    /// CONFIDENT gate: minimum lane agreement (m2). Default: 0.50.
    pub t2: f64,
    /// WEAK gate: m1 ceiling below which WEAK fires (t1′). Default: 0.05.
    pub t1_prime: f64,
    /// WEAK gate: span-cosine-spread floor below which WEAK fires (t3'). Default: 0.10.
    pub t3_prime: f64,
    /// Score-cliff ratio threshold (c). Default: 0.20.
    pub c: f64,
    /// Minimum response rows (k_min). Default: 3.
    pub k_min: usize,
    /// Maximum response rows (k_max). Default: 20.
    pub k_max: usize,
}

impl Default for PackagerThresholds {
    fn default() -> Self {
        Self {
            t1: 0.25,
            t2: 0.50,
            t1_prime: 0.05,
            t3_prime: 0.10,
            c: 0.20,
            k_min: 3,
            k_max: 20,
        }
    }
}

// ---------------------------------------------------------------------------
// GLKResultsPackager
// ---------------------------------------------------------------------------

/// Post-recall, pre-presentation packager.
///
/// Entry point is `package()`. All methods are pure functions over the supplied
/// inputs — no mutable state, no I/O. `GLKResultsPackager` does NOT call
/// `GroundedSynthesis`; the composed answer is injected by the AriaMcpKit layer.
///
/// Mirrors Swift `GLKResultsPackager`.
pub struct GLKResultsPackager;

impl GLKResultsPackager {
    pub fn new() -> Self {
        Self
    }

    /// Package a recall result according to the requested `mode`.
    ///
    /// - `result`:          The scored recall result from the Recall Director.
    /// - `mode`:            The answer adjective from the ARIA caller.
    /// - `composed_answer`: The synthesis output injected by the AriaMcpKit layer.
    ///                      `None` for `Never` mode (and ignored in the fast path).
    /// - `thresholds`:      Gate thresholds; pass `PackagerThresholds::default()` in
    ///                      normal operation.
    ///
    /// Mirrors Swift `GLKResultsPackager.package(result:mode:composedAnswer:thresholds:)`.
    pub fn package(
        &self,
        result: &GLKRecallResult,
        mode: PackagerAnswerMode,
        composed_answer: Option<&str>,
        thresholds: PackagerThresholds,
    ) -> GLKPackagedResult {
        let total_count = result.hits.len();

        // --- answer:never fast path — byte-identical to the pre-packager path ---
        // No gate computation, no cliff cutoff; return all hits as rows.
        if mode == PackagerAnswerMode::Never {
            return GLKPackagedResult {
                level: GLKResponseLevel::RowsOnly,
                answer_block: None,
                rows: result.hits.clone(),
                total_count,
            };
        }

        // --- compute gate signals ---
        let signals = self.compute_signals(result, composed_answer.unwrap_or(""), &thresholds);

        // --- gate decision (WEAK checked first — order is load-bearing) ---
        let confidence = if signals.m1 < thresholds.t1_prime || signals.m3 < thresholds.t3_prime {
            PackagerConfidenceLevel::Weak
        } else if signals.m1 >= thresholds.t1 && signals.m2 >= thresholds.t2 && signals.m4 {
            PackagerConfidenceLevel::Confident
        } else {
            PackagerConfidenceLevel::Intermediate
        };

        // --- apply cliff cutoff ---
        let rows = self.cliff_cutoff(&result.hits, &thresholds);

        // --- select response level and build answer block ---
        //
        // Spec §5: WEAK carries NO answer block — the answer is suppressed
        // universally when confidence is WEAK, regardless of mode.
        // answer:always: WEAK → RowsOnly (no block); CONFIDENT or INTERMEDIATE
        //   → L1Full (answer + rows). answer:always never produces L0AnswerOnly
        //   because the caller explicitly wants rows alongside the answer.
        //   Mirrors Swift: `if answerBlock != nil { level = .l1Full } else { .rowsOnly }`.
        // answer:auto: gate decides — CONFIDENT → L0AnswerOnly, INTERMEDIATE → L1Full,
        //   WEAK → RowsOnly.
        let level = match mode {
            PackagerAnswerMode::Never => unreachable!("handled above"),
            PackagerAnswerMode::Always => match confidence {
                // WEAK: no answer block emitted; return rows only.
                PackagerConfidenceLevel::Weak => GLKResponseLevel::RowsOnly,
                // CONFIDENT or INTERMEDIATE: answer + rows (L1Full — always forces rows).
                _ => GLKResponseLevel::L1Full,
            },
            PackagerAnswerMode::Auto => match confidence {
                PackagerConfidenceLevel::Confident => GLKResponseLevel::L0AnswerOnly,
                PackagerConfidenceLevel::Intermediate => GLKResponseLevel::L1Full,
                PackagerConfidenceLevel::Weak => GLKResponseLevel::RowsOnly,
            },
        };

        // Build the answer block only when confidence is not WEAK (spec §5).
        // WEAK responses carry no answer block — suppressed unconditionally.
        let answer_block = if confidence != PackagerConfidenceLevel::Weak {
            // Citation IDs: the first five HYDRATED hits before cliff cutoff,
            // exactly Swift `result.hits.prefix(5).compactMap { $0.drawer?.id }`.
            // An unhydrated hit (tombstoned row) is skipped, not counted.
            let citation_ids: Vec<String> = result
                .hits
                .iter()
                .take(5)
                .filter_map(|h| h.drawer.as_ref().map(|d| d.id.clone()))
                .collect();

            Some(GLKAnswerBlock {
                answer: composed_answer.unwrap_or("").to_string(),
                confidence_level: confidence,
                citation_ids,
                signals,
            })
        } else {
            None
        };

        let response_rows = match level {
            GLKResponseLevel::L0AnswerOnly => vec![],
            _ => rows,
        };

        GLKPackagedResult {
            level,
            answer_block,
            rows: response_rows,
            total_count,
        }
    }

    // -----------------------------------------------------------------------
    // Signal computation
    // -----------------------------------------------------------------------

    fn compute_signals(
        &self,
        result: &GLKRecallResult,
        composed_answer: &str,
        thresholds: &PackagerThresholds,
    ) -> GLKConfidenceSignals {
        let hits = &result.hits;
        let eps: f64 = 1e-9;

        // m1: top-margin = (score[0] - score[1]) / max(score[0], epsilon).
        // Unchanged from the pre-span packager.
        let m1 = if hits.len() >= 2 {
            let s0 = hits[0].score.final_score as f64;
            let s1 = hits[1].score.final_score as f64;
            ((s0 - s1) / s0.max(eps)).max(0.0)
        } else if hits.len() == 1 {
            // Only one hit — treat as perfect margin.
            1.0
        } else {
            0.0
        };

        // Collect the SpanRerankHit of every hit in hits.prefix(10) that carries
        // one, in returned order. Used for both m2 and m3.
        let scored: Vec<&crate::span_rerank::SpanRerankHit> = hits
            .iter()
            .take(10)
            .filter_map(|h| h.span_hit.as_ref())
            .collect();

        // m2: lane agreement — normalised Spearman footrule between the lexical
        // order (bm25_rank ascending) and the span order (cosine descending, ties
        // by bm25_rank ascending) of the span-scored top-10 hits.
        // 0.0 when no span hits are available. Twin of Swift
        // `GLKResultsPackager.spanRerankAgreement(_:)`.
        let m2 = span_rerank_agreement(&scored);

        // m3: population stddev of span cosines over the span-scored top-10 hits.
        // Special cases mirror the pre-span dense-spread rules (the single-hit
        // WEAK guard is on total hits, not scored hits):
        //   hits empty    -> 0.0
        //   hits.len == 1 -> 1.0  (WEAK must not fire on the only hit)
        //   else scored < 2 -> 0.0 (no useful encoder signal for a multi-hit result)
        //   else stddev of cosines.
        // Mirrors Swift: `guard top.count >= 2 else { return top.isEmpty ? 0.0 : 1.0 }`.
        let m3 = if hits.is_empty() {
            // No candidates: spread undefined -> 0.0.
            0.0
        } else if hits.len() == 1 {
            // Single candidate: maximum margin — WEAK must not fire on m3 for
            // the only result regardless of whether it has a span hit.
            1.0
        } else {
            // Multi-hit: use span cosine spread. span_cosine_spread returns 0.0
            // when fewer than 2 span hits exist, which fires WEAK on a result
            // the encoder did not contribute to.
            span_cosine_spread(&scored)
        };

        // m4: word-boundary containment. Unchanged.
        // >=60% of the distinctive words in `composed_answer` must appear in the
        // top citation's drawer content. With no answer text or no top content
        // the signal is undefined and reads false, exactly Swift's
        // `if let text = composedAnswer, !text.isEmpty, let topContent = ...`
        // guard: an empty answer must never count as contained.
        let top_content = hits
            .first()
            .and_then(|h| h.drawer.as_ref())
            .map(|d| d.content.as_str())
            .unwrap_or("");
        let m4 = if composed_answer.is_empty() || top_content.is_empty() {
            false
        } else {
            self.word_boundary_containment(composed_answer, top_content, 0.60)
        };

        // t3_prime is consumed by the gate comparison upstream; read here so the
        // compiler does not warn about the unused parameter.
        let _ = thresholds;

        // Round m1/m2/m3 to 2 decimal places before gate comparisons, exactly
        // mirroring Swift's `round2` at GLKResultsPackager.swift:400-402.
        // `(v * 100.0).round() / 100.0` — Rust f64::round() rounds half away from
        // zero, matching Swift's Double.rounded() (same IEEE 754 default mode).
        // Without this step, values like m1=0.245 compare as < t1=0.25 and
        // misclassify to INTERMEDIATE; after rounding they compare as == 0.25
        // and reach CONFIDENT.
        fn round2(v: f64) -> f64 {
            (v * 100.0).round() / 100.0
        }

        GLKConfidenceSignals {
            m1: round2(m1),
            m2: round2(m2),
            m3: round2(m3),
            m4,
        }
    }

    // -----------------------------------------------------------------------
    // Word-boundary containment (m4)
    // -----------------------------------------------------------------------

    /// Returns `true` iff the fraction of DISTINCTIVE words from `answer` that
    /// appear in `citation` meets or exceeds `threshold`.
    ///
    /// "Distinctive" = words longer than 3 characters AND not in the stopword list.
    /// When all answer words are short/stopwords (empty distinctive set), containment
    /// is indeterminate and returns `true` — mirrors Swift's `guard !answerWords.isEmpty
    /// else { return true }` path.
    ///
    /// Mirrors Swift `GLKResultsPackager.wordBoundaryContains(answer:inSource:)`.
    fn word_boundary_containment(&self, answer: &str, citation: &str, threshold: f64) -> bool {
        const STOPWORDS: &[&str] = &[
            "the", "and", "for", "that", "this", "with", "from", "have", "not",
            "are", "was", "were", "been", "they", "their", "there", "what",
            "when", "where", "which", "will", "would", "could", "should", "about",
        ];

        // Lowercased word tokens — split on Swift's EXACT delimiter character set:
        //   " \t\n.,;:!?\"'()[]{}"
        // This matches Swift's `CharacterSet(charactersIn: " \t\n.,;:!?\"'()[]{}")` at
        // GLKResultsPackager.swift:508. Hyphens and underscores are NOT delimiters,
        // so compound tokens like "state-of-the-art" or "search_engine" are kept as
        // a single word — identical to Swift tokenise(). Using `!is_alphanumeric()` as
        // the predicate would split on hyphens and underscores, breaking parity.
        // Filter: length > 3 AND not a stopword. Mirrors Swift's tokenise() +
        // `filter { $0.count > 3 && !stopwords.contains($0) }`.
        const DELIMITERS: &str = " \t\n.,;:!?\"'()[]{}";
        let answer_words: Vec<String> = answer
            .split(|c: char| DELIMITERS.contains(c))
            .filter(|w| !w.is_empty())
            .map(|w| w.to_lowercase())
            .filter(|w| w.len() > 3 && !STOPWORDS.contains(&w.as_str()))
            .collect();

        if answer_words.is_empty() {
            // All answer words are short/stopwords: containment indeterminate → true.
            // Mirrors Swift: `guard !answerWords.isEmpty else { return true }`.
            return true;
        }

        let source_words: std::collections::HashSet<String> = citation
            .split(|c: char| DELIMITERS.contains(c))
            .filter(|w| !w.is_empty())
            .map(|w| w.to_lowercase())
            .collect();

        let contained = answer_words
            .iter()
            .filter(|w| source_words.contains(w.as_str()))
            .count();

        (contained as f64 / answer_words.len() as f64) >= threshold
    }

    // -----------------------------------------------------------------------
    // Score-cliff row cutoff
    // -----------------------------------------------------------------------

    /// Apply the score-cliff row cutoff algorithm.
    ///
    /// - Include the first `k_min` rows unconditionally.
    /// - Starting from index `k_min`, check each successive gap (hits[i] − hits[i+1]).
    ///   Stop when a gap ≥ c × (score[0] − score[k_max−1]) fires; cutoff = i+1 rows.
    /// - If no cliff fires, include up to `k_max` rows.
    ///
    /// Threshold is `c × max(spread, ε)` where spread = score[0] − score[k_max−1],
    /// matching Swift `GLKResultsPackager.cliffCutoff(_:thresholds:)` exactly.
    fn cliff_cutoff(&self, hits: &[RecallHit], thresholds: &PackagerThresholds) -> Vec<RecallHit> {
        let n = hits.len();
        if n == 0 {
            return vec![];
        }

        let k_min = thresholds.k_min.max(1);
        let k_max = n.min(thresholds.k_max);
        if k_min > k_max {
            return hits[..n.min(k_min.max(1))].to_vec();
        }

        // Reference spread: score[0] − score[k_max−1]. Mirrors Swift:
        //   let s0 = hits[0].score.final; let sK = hits[min(kMax,n)−1].score.final
        //   threshold = c * max(s0 − sK, 1e-9)
        let s0 = hits[0].score.final_score as f64;
        let s_k = hits[k_max - 1].score.final_score as f64;
        let spread = (s0 - s_k).max(1e-9);
        let cliff_threshold = thresholds.c * spread;

        let mut cutoff = k_min.min(n);

        // Walk from k_min to k_max−1. At each i, check the gap between hits[i] and
        // hits[i+1] — same as Swift's `gap = hits[i].score - hits[i+1].score` loop
        // starting at i=kMin.
        for i in k_min..k_max {
            if i + 1 >= n {
                cutoff = i + 1;
                break;
            }
            let gap = hits[i].score.final_score as f64 - hits[i + 1].score.final_score as f64;
            if gap >= cliff_threshold {
                cutoff = i + 1;
                break;
            }
            cutoff = i + 1;
        }

        hits[..cutoff.min(k_max)].to_vec()
    }
}

impl Default for GLKResultsPackager {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// Lane-agreement and cosine-spread helpers
// ---------------------------------------------------------------------------

/// Lane-agreement margin (m2): 1 - footrule/maximum, where footrule is the
/// Spearman footrule distance between the lexical order (bm25_rank ascending)
/// and the span order (cosine descending, ties by bm25_rank ascending) of the
/// scored span hits; maximum = (n * n) / 2 (integer division). Returns 1.0
/// when n == 1, 0.0 when n == 0. f64 arithmetic from f32 cosines, same tie
/// rules as the Swift twin. Twin of Swift `GLKResultsPackager.spanRerankAgreement(_:)`.
fn span_rerank_agreement(scored: &[&crate::span_rerank::SpanRerankHit]) -> f64 {
    let n = scored.len();
    if n == 0 {
        return 0.0;
    }
    if n == 1 {
        return 1.0;
    }

    // Lexical order: sort by bm25_rank ascending.
    let mut lexical: Vec<&crate::span_rerank::SpanRerankHit> = scored.to_vec();
    lexical.sort_by_key(|h| h.bm25_rank);

    // Span order: sort by cosine descending, ties by bm25_rank ascending.
    let mut span: Vec<&crate::span_rerank::SpanRerankHit> = scored.to_vec();
    span.sort_by(|a, b| {
        b.cosine
            .partial_cmp(&a.cosine)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.bm25_rank.cmp(&b.bm25_rank))
    });

    // posS[item_id] = index of that item in the span order.
    let pos_s: std::collections::HashMap<&str, usize> = span
        .iter()
        .enumerate()
        .map(|(i, h)| (h.item_id.as_str(), i))
        .collect();

    // footrule = sum over lexical of |lexical_index - span_index|.
    let footrule: usize = lexical
        .iter()
        .enumerate()
        .map(|(i, h)| {
            let j = pos_s[h.item_id.as_str()];
            if i > j { i - j } else { j - i }
        })
        .sum();

    // maximum = (n * n) / 2 (integer division, the footrule upper bound);
    // n >= 2 here, so it is never zero.
    let maximum = (n * n) / 2;
    1.0 - footrule as f64 / maximum as f64
}

/// Span-cosine spread (m3): population standard deviation of the cosine values
/// of the scored span hits, computed from f64 casts of the f32 cosines.
/// Returns 0.0 when fewer than 2 scored hits exist. The single-total-hit
/// special case (m3 = 1.0) is handled by the caller. Formula: mean, then
/// sqrt(sum((x - mean)^2) / n). Twin of Swift `GLKResultsPackager.spanCosineSpread(_:)`.
fn span_cosine_spread(scored: &[&crate::span_rerank::SpanRerankHit]) -> f64 {
    let n = scored.len();
    if n < 2 {
        return 0.0;
    }
    let values: Vec<f64> = scored.iter().map(|h| h.cosine as f64).collect();
    let mean = values.iter().sum::<f64>() / n as f64;
    let variance = values.iter().map(|x| (x - mean).powi(2)).sum::<f64>() / n as f64;
    variance.sqrt()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::recall::{
        GLKRecallMode, GLKRecallRequest, GLKRecallResult, GLKRecallScoring,
        RecallFallbackPolicy, RecallHit, RecallOrigin, RecallPlan, RecallScoreVector,
        RecallWeights,
    };
    use crate::span_rerank::SpanRerankHit;
    use locus_kit::drawer::Drawer;
    use locus_kit::filter::RecallFrame;

    const NOW_MS: i64 = 1_700_000_000_000_i64;

    // Helper: build a minimal GLKRecallResult from hit specs.
    //
    // Each spec is (final_score, Option<(lexical_rank, span_cosine)>, content).
    // When span evidence is provided a SpanRerankHit is attached with
    // bestSpanIndex/Start/End zeroed (the packager reads only cosine and bm25_rank).
    // union_profile is left None: m2 now reads the span order, not signal_agreement.
    // score.dense stays 0: m3 now reads span cosines, not the dense-lane column.
    fn make_result(
        hits_spec: &[(f32, Option<(usize, f32)>, &str)],
    ) -> GLKRecallResult {
        let hits: Vec<RecallHit> = hits_spec
            .iter()
            .enumerate()
            .map(|(i, (final_score, span_ev, content))| {
                let drawer = Drawer::new(
                    format!("drawer-{}", i),
                    *content,
                    "test-room",
                    "test-agent",
                    NOW_MS,
                    "test-model",
                );
                let span_hit = span_ev.map(|(bm25_rank, cosine)| SpanRerankHit {
                    item_id: format!("hit-{}", i),
                    best_span_index: 0,
                    best_span_start: 0,
                    best_span_end: 0,
                    cosine,
                    bm25_rank,
                });
                RecallHit {
                    id: format!("hit-{}", i),
                    drawer: Some(drawer),
                    sources: vec![],
                    score: RecallScoreVector {
                        final_score: *final_score,
                        ..RecallScoreVector::ZERO
                    },
                    explanation: vec![],
                    span_hit,
                }
            })
            .collect();

        let request = GLKRecallRequest::new(
            RecallFrame::new(vec![]),
            GLKRecallMode::UnionBest,
            GLKRecallScoring::MatrixAware,
            10,
            RecallFallbackPolicy::AllowDegraded,
            RecallOrigin::Internal,
        )
        .with_query_text("test query");

        let plan = RecallPlan {
            effective_mode: GLKRecallMode::UnionBest,
            frontier_k: 40,
            weights: RecallWeights::UNIFORM,
        };

        GLKRecallResult {
            request,
            plan,
            union_profile: None,
            hits,
            withheld_by_sensitivity: 0,
            #[cfg(feature = "whole-record-dense")]
            dense_lane_status: None,
            degraded_stages: vec![],
            lane_ranks: std::collections::HashMap::new(),
            query_lattice_anchor: None,
            cross_encoder: None,
            route: None,
        }
    }

    // -----------------------------------------------------------------------
    // A. answer:never fast path
    // -----------------------------------------------------------------------

    /// Golden pin A: answer:never returns all hits unchanged and no answer block.
    #[test]
    fn test_a_never_mode_fast_path() {
        let result = make_result(&[
            (0.90, None, "fruit banana information"),
            (0.30, None, "other content"),
        ]);
        let packager = GLKResultsPackager::new();
        let packaged = packager.package(&result, PackagerAnswerMode::Never, None, PackagerThresholds::default());

        assert_eq!(packaged.level, GLKResponseLevel::RowsOnly);
        assert!(packaged.answer_block.is_none());
        assert_eq!(packaged.rows.len(), 2, "never mode must return all hits");
        assert_eq!(packaged.total_count, 2);
    }

    // -----------------------------------------------------------------------
    // B. CONFIDENT gate → L0AnswerOnly
    // -----------------------------------------------------------------------

    /// Golden pin B: CONFIDENT gate fires -> L0AnswerOnly (rows list empty).
    ///
    /// Span evidence: h-0(cos=0.90,rank=1), h-1(cos=0.50,rank=2). Lexical and span
    /// orders agree (0.90>0.50 => span leads same as lexical), footrule=0, m2=1.0>=t2.
    /// m3=stddev(0.90,0.50)=0.20>=t3_prime. m1=(0.90-0.30)/0.90=0.67>=t1. m4=true.
    #[test]
    fn test_b_confident_gate_l0_answer_only() {
        let top_content = "fruit banana mango recall content test paragraph information";
        let result = make_result(&[
            (0.90, Some((1, 0.90)), top_content),
            (0.30, Some((2, 0.50)), "other content unrelated"),
        ]);
        let packager = GLKResultsPackager::new();
        let packaged = packager.package(
            &result,
            PackagerAnswerMode::Auto,
            Some("fruit banana information"),
            PackagerThresholds::default(),
        );

        assert_eq!(packaged.level, GLKResponseLevel::L0AnswerOnly, "CONFIDENT must produce L0AnswerOnly");
        assert!(packaged.answer_block.is_some(), "CONFIDENT must have answer block");
        assert_eq!(packaged.rows.len(), 0, "L0AnswerOnly must have empty rows");
        let block = packaged.answer_block.unwrap();
        assert_eq!(block.confidence_level, PackagerConfidenceLevel::Confident);
        assert!(block.signals.m1 >= 0.25, "m1={} must be ≥ t1=0.25", block.signals.m1);
        assert!(block.signals.m2 >= 0.50, "m2={} must be ≥ t2=0.50", block.signals.m2);
        assert!(block.signals.m4, "m4 must be true for CONFIDENT gate");
    }

    // -----------------------------------------------------------------------
    // C. INTERMEDIATE gate → L1Full
    // -----------------------------------------------------------------------

    /// Golden pin C: INTERMEDIATE gate fires -> L1Full (answer block + rows).
    ///
    /// Span evidence: lexical ranks [3,2,1] with cosines [0.80,0.50,0.30].
    /// Lexical order (rank asc): [hit-2(rank1), hit-1(rank2), hit-0(rank3)].
    /// Span order (cos desc): [hit-0(0.80), hit-1(0.50), hit-2(0.30)].
    /// posS: {hit-0:0, hit-1:1, hit-2:2}. footrule = |0-2|+|1-1|+|2-0| = 4.
    /// maximum = (3*3)/2 = 4. m2 = 1-4/4 = 0.0 < t2=0.50 -> not CONFIDENT.
    /// m1=(0.70-0.40)/0.70=0.43>=t1'=0.05 (not WEAK from m1).
    /// m3=stddev(0.80,0.50,0.30)=0.205>=t3_prime=0.10 (not WEAK from m3).
    /// Neither CONFIDENT nor WEAK -> INTERMEDIATE.
    #[test]
    fn test_c_intermediate_gate_l1_full() {
        let result = make_result(&[
            (0.70, Some((3, 0.80)), "intermediate content first"),
            (0.40, Some((2, 0.50)), "intermediate content second"),
            (0.30, Some((1, 0.30)), "intermediate content third"),
        ]);
        let packager = GLKResultsPackager::new();
        let packaged = packager.package(
            &result,
            PackagerAnswerMode::Auto,
            Some("intermediate answer text"),
            PackagerThresholds::default(),
        );

        assert_eq!(packaged.level, GLKResponseLevel::L1Full, "INTERMEDIATE must produce L1Full");
        assert!(packaged.answer_block.is_some(), "INTERMEDIATE must have answer block");
        assert!(!packaged.rows.is_empty(), "L1Full must include rows");
        let block = packaged.answer_block.unwrap();
        assert_eq!(block.confidence_level, PackagerConfidenceLevel::Intermediate);
    }

    // -----------------------------------------------------------------------
    // D. WEAK gate → RowsOnly
    // -----------------------------------------------------------------------

    /// Golden pin D: WEAK gate fires -> RowsOnly (no answer block).
    ///
    /// Span evidence: cosines [0.80,0.50,0.20], ranks [1,2,3]. Lexical and span
    /// orders agree, footrule=0, m2=1.0. m3=stddev(0.80,0.50,0.20)=0.245>=t3_prime.
    /// m1=(0.520-0.500)/0.520=0.038<t1'=0.05 -> WEAK fires from m1 margin first.
    #[test]
    fn test_d_weak_gate_rows_only() {
        let result = make_result(&[
            (0.520, Some((1, 0.80)), "weak content first"),
            (0.500, Some((2, 0.50)), "weak content second"),
            (0.480, Some((3, 0.20)), "weak content third"),
        ]);
        let packager = GLKResultsPackager::new();
        let packaged = packager.package(
            &result,
            PackagerAnswerMode::Auto,
            Some("weak answer"),
            PackagerThresholds::default(),
        );

        assert_eq!(packaged.level, GLKResponseLevel::RowsOnly, "WEAK must produce RowsOnly");
        // Spec §5: WEAK carries no answer block — suppressed universally.
        assert!(packaged.answer_block.is_none(), "WEAK must produce no answer block (spec §5)");
    }

    // -----------------------------------------------------------------------
    // E. Cliff cutoff fires at kMin
    // -----------------------------------------------------------------------

    /// Golden pin E: cliff fires at index kMin (3), cutoff = 4 rows returned.
    ///
    /// Fixture: 7 hits with scores [0.90,0.85,0.80,0.75,0.20,0.18,0.16].
    /// The large gap between hit[3]=0.75 and hit[4]=0.20 (gap=0.55) fires the cliff.
    /// Spread over 7 scores = 0.90-0.16=0.74; threshold = 0.20*0.74=0.148.
    /// i=3: gap = 0.80-0.75 = 0.05 < 0.148 (no cliff).
    /// i=4: gap = 0.75-0.20 = 0.55 >= 0.148 -> fires -> cutoff=4.
    ///
    /// Span evidence: hits 0-3 carry cosines [0.80,0.60,0.40,0.20], ranks [1,2,3,4].
    /// Lexical and span orders agree, footrule=0, m2=1.0. m3=stddev>=0.10 (not WEAK).
    /// m1=(0.90-0.85)/0.90=0.056>=t1'=0.05 (not WEAK from m1, < t1=0.25 not CONFIDENT).
    /// m4=false (answer not in "cliff content 0"). -> INTERMEDIATE -> L1Full.
    #[test]
    fn test_e_cliff_cutoff_fires_at_kmin() {
        let result = make_result(&[
            (0.90, Some((1, 0.80)), "cliff content 0"),
            (0.85, Some((2, 0.60)), "cliff content 1"),
            (0.80, Some((3, 0.40)), "cliff content 2"),
            (0.75, Some((4, 0.20)), "cliff content 3"),
            (0.20, None, "cliff content 4"),
            (0.18, None, "cliff content 5"),
            (0.16, None, "cliff content 6"),
        ]);
        let packager = GLKResultsPackager::new();
        let packaged = packager.package(
            &result,
            PackagerAnswerMode::Always,
            Some("cliff test answer"),
            PackagerThresholds::default(),
        );

        // INTERMEDIATE -> L1Full (always mode: CONFIDENT -> L1Full too, but m4=false
        // and m1<t1 mean we cannot reach CONFIDENT here). The cliff fires at i=4.
        assert_eq!(packaged.level, GLKResponseLevel::L1Full, "always mode with INTERMEDIATE -> L1Full");
        assert_eq!(packaged.rows.len(), 4, "cliff must fire at i=4, returning 4 rows; got {}", packaged.rows.len());
    }

    // -----------------------------------------------------------------------
    // F1. PackagerThresholds default values match spec
    // -----------------------------------------------------------------------

    #[test]
    fn test_f1_thresholds_spec_defaults() {
        let t = PackagerThresholds::default();
        assert_eq!(t.t1, 0.25);
        assert_eq!(t.t2, 0.50);
        assert_eq!(t.t1_prime, 0.05);
        assert_eq!(t.t3_prime, 0.10);
        assert_eq!(t.c, 0.20);
        assert_eq!(t.k_min, 3);
        assert_eq!(t.k_max, 20);
    }

    // -----------------------------------------------------------------------
    // F2. RecallTuningManifest packager_thresholds() round-trips through defaults
    // -----------------------------------------------------------------------

    #[test]
    fn test_f2_recall_tuning_manifest_packager_thresholds_defaults() {
        let manifest = crate::coordinator::RecallTuningManifest::default();
        let t = manifest.packager_thresholds();
        assert_eq!(t.t1, 0.25);
        assert_eq!(t.t2, 0.50);
        assert_eq!(t.t1_prime, 0.05);
        assert_eq!(t.t3_prime, 0.10);
        assert_eq!(t.c, 0.20);
        assert_eq!(t.k_min, 3);
        assert_eq!(t.k_max, 20);
    }

    // -----------------------------------------------------------------------
    // F3. PackagerAnswerMode::from_str parses all three values and rejects unknown
    // -----------------------------------------------------------------------

    #[test]
    fn test_f3_packager_answer_mode_from_str() {
        assert_eq!(PackagerAnswerMode::from_str("never"), Some(PackagerAnswerMode::Never));
        assert_eq!(PackagerAnswerMode::from_str("always"), Some(PackagerAnswerMode::Always));
        assert_eq!(PackagerAnswerMode::from_str("auto"), Some(PackagerAnswerMode::Auto));
        assert_eq!(PackagerAnswerMode::from_str("maybe"), None);
        assert_eq!(PackagerAnswerMode::from_str(""), None);
    }
}
