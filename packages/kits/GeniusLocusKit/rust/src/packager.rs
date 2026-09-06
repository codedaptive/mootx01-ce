// packager.rs — GLKResultsPackager Rust port (PACKAGER mission).
//
// Mirrors Swift `GeniusLocusKit/RecallDirector/GLKResultsPackager.swift`.
//
// Post-recall, pre-presentation packager that determines the response
// shape adjective (never/always/auto), computes the four gate signals,
// applies the WEAK → CONFIDENT → INTERMEDIATE gate, applies the score-cliff
// row cutoff, and returns a `GLKPackagedResult` for the ARIA boundary to
// render.
//
// ## Gate signals (all mirrored from the Swift reference)
//   m1 — Top-margin: (score[0] - score[1]) / max(score[0], ε).  Measures
//         how decisively the top hit leads the second.
//   m2 — Lane agreement: `union_profile.signal_agreement`. Fraction of
//         lanes that confirmed each candidate; proxy for cross-lane
//         consensus.
//   m3 — Dense spread: population stddev of the dense-lane score over the
//         top-10 hits. A flat dense column signals the dense lane is dark or
//         uninformative; a high spread signals discriminative embedding recall.
//   m4 — Word-boundary containment: ≥60% of the distinctive words in the
//         composed answer appear in the top hit's drawer content. Guards against
//         hallucinated answers that do not trace to the top citation.
//
// ## Gate decision (order is load-bearing — WEAK checked first)
//   WEAK        — m1 < t1′  OR  m3 < t3′
//   CONFIDENT   — m1 ≥ t1  AND  m2 ≥ t2  AND  m4 = true
//   INTERMEDIATE — neither of the above
//
// ## Response levels
//   L0AnswerOnly — answer block with no result rows (CONFIDENT only)
//   L1Full       — answer block + rows (CONFIDENT or INTERMEDIATE)
//   RowsOnly     — dense rows, no answer block (WEAK or answer:never)
//
// ## Score-cliff row cutoff
//   Start including rows at index 0. After the kMin-th row has been included,
//   check each successive gap. Stop (exclusive) when a gap ≥ c × spread fires.
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
    /// m1: top-margin = (score[0] - score[1]) / max(score[0], ε).
    pub m1: f64,
    /// m2: lane agreement = union_profile.signal_agreement.
    pub m2: f64,
    /// m3: dense spread = population stddev of dense scores over top-10.
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
    /// WEAK gate: dense-spread floor (t3′). Default: 0.10.
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

        // m1: top-margin = (score[0] - score[1]) / max(score[0], ε)
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

        // m2: lane agreement from union_profile.signal_agreement.
        // 0.0 when no union profile is available (non-unionBest modes).
        let m2 = result
            .union_profile
            .as_ref()
            .map(|p| p.signal_agreement as f64)
            .unwrap_or(0.0);

        // m3: population stddev of dense-lane scores over top-10 hits.
        // Single-hit case → spread = 1.0 (maximum confidence — one unambiguous
        // result; WEAK gate must not fire on m3 for a single confident hit).
        // Mirrors Swift: `guard top.count >= 2 else { return top.isEmpty ? 0.0 : 1.0 }`.
        let top10: Vec<f64> = hits
            .iter()
            .take(10)
            .map(|h| h.score.dense as f64)
            .collect();
        let m3 = if top10.len() >= 2 {
            let mean = top10.iter().sum::<f64>() / top10.len() as f64;
            let variance = top10.iter().map(|x| (x - mean).powi(2)).sum::<f64>()
                / top10.len() as f64;
            variance.sqrt()
        } else if top10.is_empty() {
            // No hits: spread is undefined → 0.0 (WEAK fires via m1=0.0 anyway).
            0.0
        } else {
            // Single hit: maximum margin, spread treated as 1.0. Mirrors Swift.
            1.0
        };

        // m4: word-boundary containment.
        // ≥60% of the distinctive words in `composed_answer` must appear in the
        // top citation's drawer content. With no answer text or no top content
        // the signal is undefined and reads false, exactly Swift's
        // `if let text = composedAnswer, !text.isEmpty, let topContent = …,
        // !topContent.isEmpty` guard: an empty answer must never count as
        // contained (the containment helper's own empty-answer rule is only
        // reached with a non-empty answer whose words are all short or
        // stopwords). The Rust product path passes no answer, so without this
        // guard it could reach CONFIDENT where Swift cannot.
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

        // Use t3_prime from thresholds — passed in but also available in the outer
        // scope. We only need it for the return value's completeness.
        let _ = thresholds;

        // Round m1/m2/m3 to 2 decimal places before gate comparisons, exactly
        // mirroring Swift's `round2` at GLKResultsPackager.swift:400-402.
        // `(v * 100.0).round() / 100.0` — Rust f64::round() rounds half away from
        // zero, matching Swift's Double.rounded() (same IEEE 754 default mode).
        // Without this step, values like m1=0.245 compare as < t1=0.25 and
        // misclassify to INTERMEDIATE; after rounding they compare as == 0.25
        // and reach CONFIDENT. The gate comparisons downstream use the rounded
        // values so the classification is byte-identical to the Swift port.
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
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::recall::{
        GLKRecallMode, GLKRecallRequest, GLKRecallResult, GLKRecallScoring,
        RecallFallbackPolicy, RecallHit, RecallOrigin, RecallPlan, RecallScoreVector,
        RecallUnionProfile, RecallWeights,
    };
    use locus_kit::drawer::Drawer;
    use locus_kit::filter::RecallFrame;

    const NOW_MS: i64 = 1_700_000_000_000_i64;

    // Helper: build a minimal GLKRecallResult from a list of (final_score, dense_score, content)
    // tuples, with signal_agreement set on the union profile.
    fn make_result(
        hits_spec: &[(f32, f32, &str)], // (final_score, dense_score, content)
        signal_agreement: f32,
    ) -> GLKRecallResult {
        let hits: Vec<RecallHit> = hits_spec
            .iter()
            .enumerate()
            .map(|(i, (final_score, dense, content))| {
                let drawer = Drawer::new(
                    format!("drawer-{}", i),
                    *content,
                    "test-room",
                    "test-agent",
                    NOW_MS,
                    "test-model",
                );
                RecallHit {
                    id: format!("hit-{}", i),
                    drawer: Some(drawer),
                    sources: vec![],
                    score: RecallScoreVector {
                        final_score: *final_score,
                        dense: *dense,
                        ..RecallScoreVector::ZERO
                    },
                    explanation: vec![],
                    span_hit: None,
                }
            })
            .collect();

        let union_profile = Some(RecallUnionProfile {
            signal_agreement,
            ..RecallUnionProfile::ZERO
        });

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
            union_profile,
            hits,
            dense_lane_status: None,
            degraded_stages: vec![],
            lane_ranks: std::collections::HashMap::new(),
            query_lattice_anchor: None,
        }
    }

    // -----------------------------------------------------------------------
    // A. answer:never fast path
    // -----------------------------------------------------------------------

    /// Golden pin A: answer:never returns all hits unchanged and no answer block.
    #[test]
    fn test_a_never_mode_fast_path() {
        let result = make_result(
            &[
                (0.90, 0.80, "fruit banana information"),
                (0.30, 0.20, "other content"),
            ],
            0.80,
        );
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

    /// Golden pin B: CONFIDENT gate fires → L0AnswerOnly (rows list empty).
    ///
    /// Fixture: scores [0.90, 0.30], signal_agreement=0.80,
    ///   answer "fruit banana information" ⊂ content "fruit banana mango recall content test paragraph information"
    /// Expected signals: m1≈0.667 ≥ t1=0.25, m2=0.80 ≥ t2=0.50, m4=true → CONFIDENT.
    #[test]
    fn test_b_confident_gate_l0_answer_only() {
        let top_content = "fruit banana mango recall content test paragraph information";
        let result = make_result(
            &[
                (0.90, 0.80, top_content),
                (0.30, 0.20, "other content unrelated"),
            ],
            0.80,
        );
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

    /// Golden pin C: INTERMEDIATE gate fires → L1Full (answer block + rows).
    ///
    /// Fixture: scores [0.70, 0.40, 0.30], signal_agreement=0.30
    /// m1=(0.70-0.40)/0.70≈0.429 ≥ t1=0.25; m2=0.30 < t2=0.50 → NOT CONFIDENT.
    /// WEAK check: m1=0.429 ≥ t1'=0.05 → not WEAK from m1.
    /// Dense spread with zeros: m3=0.0 < t3'=0.10 → WEAK from m3.
    ///
    /// To get INTERMEDIATE, we need m3 ≥ t3_prime. Use dense scores [0.90,0.50,0.10].
    #[test]
    fn test_c_intermediate_gate_l1_full() {
        let result = make_result(
            &[
                (0.70, 0.90, "intermediate content first"),
                (0.40, 0.50, "intermediate content second"),
                (0.30, 0.10, "intermediate content third"),
            ],
            0.30, // m2=0.30 < t2=0.50 → not CONFIDENT
        );
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

    /// Golden pin D: WEAK gate fires → RowsOnly (no answer block).
    ///
    /// Fixture: scores [0.520, 0.500, 0.480]
    ///   m1 = (0.520-0.500)/0.520 ≈ 0.038 < t1′=0.05 → WEAK.
    #[test]
    fn test_d_weak_gate_rows_only() {
        let result = make_result(
            &[
                (0.520, 0.30, "weak content first"),
                (0.500, 0.29, "weak content second"),
                (0.480, 0.28, "weak content third"),
            ],
            0.80, // m2 would pass, but WEAK fires first
        );
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
    /// kMin=3 → the gap between hits[2] and hits[3] is inside kMin and NOT checked.
    /// i=4 is the first index checked (i ≥ kMin=3 means i=3,4,... but wait, Swift
    /// starts checking at i=kMin, meaning after INCLUDING kMin rows). Actually the
    /// Swift cliff checks gap at index i (between hit[i-1] and hit[i]) starting
    /// from i=kMin. So:
    ///   i=3: gap = 0.80-0.75 = 0.05 (below threshold)
    ///   i=4: gap = 0.75-0.20 = 0.55 ≥ threshold → cutoff=4.
    ///
    /// Spread over 7 scores ≈ 0.260; threshold = 0.20 × 0.260 ≈ 0.052.
    /// Gap at i=3 = 0.05 < 0.052 (barely passes — does NOT fire).
    /// Gap at i=4 = 0.55 >> threshold → fires → cutoff=4.
    #[test]
    fn test_e_cliff_cutoff_fires_at_kmin() {
        let result = make_result(
            &[
                (0.90, 0.30, "cliff content 0"),
                (0.85, 0.29, "cliff content 1"),
                (0.80, 0.28, "cliff content 2"),
                (0.75, 0.27, "cliff content 3"),
                (0.20, 0.06, "cliff content 4"),
                (0.18, 0.05, "cliff content 5"),
                (0.16, 0.04, "cliff content 6"),
            ],
            0.20,
        );
        let packager = GLKResultsPackager::new();
        // Use never mode to directly test cliff through the rows without the gate.
        // For cliff testing, use always mode with a composed answer so cliff runs.
        let packaged = packager.package(
            &result,
            PackagerAnswerMode::Always,
            Some("cliff test answer"),
            PackagerThresholds::default(),
        );

        // L1Full or L0AnswerOnly; either way the cliff must have fired at 4.
        // For always mode: CONFIDENT → L0AnswerOnly (rows empty), INTERMEDIATE/WEAK → L1Full.
        // With signal_agreement=0.20 and no m4 (answer "cliff test answer" not in "cliff content 0"),
        // this should be INTERMEDIATE → L1Full.
        assert_eq!(packaged.level, GLKResponseLevel::L1Full, "always mode with INTERMEDIATE → L1Full");
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
