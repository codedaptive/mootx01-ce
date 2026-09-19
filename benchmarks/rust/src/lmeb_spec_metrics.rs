//! lmeb_spec_metrics.rs — Official LMEB metric grid (§A3), instruction settings (§A4),
//! and two-level aggregation (§A1/§A3).
//!
//! Rust twin of `LMEBSpecMetrics.swift`. Every function is deterministic and pure
//! (no I/O, no system-clock calls) so the conformance vectors in
//! `conformance/lmeb-spec/metric_vectors.json` drive both legs identically.
//!
//! Spec reference: LMEB_CONVOMEM_OFFICIAL_PROTOCOL.md §A1, §A3, §A4.
//!
//! ## Metrics at k ∈ {1, 5, 10, 25, 50}
//!
//! - nDCG@k (binary relevance, pytrec_eval semantics)
//! - MAP@k (mean average precision = macro mean of AP@k)
//! - Recall@k = |relevant ∩ top-k| / |relevant|
//! - Precision@k = |relevant ∩ top-k| / k
//! - MRR@k = 1/(rank of first relevant in top-k), 0 if none
//! - R_cap@k = hits / min(total_relevant, k); None when no relevant docs (§A3, metric.py)
//!
//! ## Two-level aggregation (§A1/§A3)
//!
//! Per-query values → macro mean per subset → mean of subset scores (task score).

use std::collections::HashSet;

// ─────────────────────────────────────────────────────────────────────────────
// §A1: Canonical k values
// ─────────────────────────────────────────────────────────────────────────────

/// The k values the LMEB protocol evaluates at (§A1, §A3).
/// nDCG@k, MAP@k, Recall@k, Precision@k, MRR@k, R_cap@k computed for each.
pub const LMEB_SPEC_K_VALUES: &[usize] = &[1, 5, 10, 25, 50];

// ─────────────────────────────────────────────────────────────────────────────
// §A4: Instruction settings
// ─────────────────────────────────────────────────────────────────────────────

/// The two published evaluation settings for LMEB (§A4).
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LmebInstructionSetting {
    /// Standard evaluation without any task instruction prepended to the query (§A4 default).
    WithoutInstruction,
    /// Evaluation with the subset's instruction string prepended to the query (§A4).
    WithInstruction,
}

// ─────────────────────────────────────────────────────────────────────────────
// §A4: Verbatim per-subset instruction strings
// ─────────────────────────────────────────────────────────────────────────────

// §A4, subset: abstention_evidence
/// "Given a query, retrieve documents that answer the query"
pub const LMEB_INSTRUCTION_ABSTENTION_EVIDENCE: &str =
    "Given a query, retrieve documents that answer the query";

// §A4, subset: assistant_facts_evidence
/// "Given a query, retrieve assistant messages that answer the query"
pub const LMEB_INSTRUCTION_ASSISTANT_FACTS_EVIDENCE: &str =
    "Given a query, retrieve assistant messages that answer the query";

// §A4, subset: changing_evidence
/// "Given a question, retrieve the latest information to answer the question"
pub const LMEB_INSTRUCTION_CHANGING_EVIDENCE: &str =
    "Given a question, retrieve the latest information to answer the question";

// §A4, subset: implicit_connection_evidence
/// "Given a query, retrieve documents that answer the query"
pub const LMEB_INSTRUCTION_IMPLICIT_CONNECTION_EVIDENCE: &str =
    "Given a query, retrieve documents that answer the query";

// §A4, subset: preference_evidence
/// "Given a query, retrieve the user's stated preferences that can help answer the query"
pub const LMEB_INSTRUCTION_PREFERENCE_EVIDENCE: &str =
    "Given a query, retrieve the user's stated preferences that can help answer the query";

// §A4, subset: user_evidence
/// "Given a query, retrieve documents that answer the query"
pub const LMEB_INSTRUCTION_USER_EVIDENCE: &str =
    "Given a query, retrieve documents that answer the query";

/// Looks up the §A4 instruction string for a subset name.
/// Returns `None` when the subset name is not part of the ConvoMem protocol.
pub fn lmeb_spec_instruction_for_subset(subset_name: &str) -> Option<&'static str> {
    match subset_name {
        "abstention_evidence"          => Some(LMEB_INSTRUCTION_ABSTENTION_EVIDENCE),
        "assistant_facts_evidence"     => Some(LMEB_INSTRUCTION_ASSISTANT_FACTS_EVIDENCE),
        "changing_evidence"            => Some(LMEB_INSTRUCTION_CHANGING_EVIDENCE),
        "implicit_connection_evidence" => Some(LMEB_INSTRUCTION_IMPLICIT_CONNECTION_EVIDENCE),
        "preference_evidence"          => Some(LMEB_INSTRUCTION_PREFERENCE_EVIDENCE),
        "user_evidence"                => Some(LMEB_INSTRUCTION_USER_EVIDENCE),
        _ => None,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §A3: Evaluation options
// ─────────────────────────────────────────────────────────────────────────────

/// Options that modify which results enter the metric calculation (§A3).
/// Both default to false — matching the LMEB protocol defaults.
///
/// Twin of Swift `LMEBSpecOptions`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LmebSpecOptions {
    /// When true, the first result in the ranked list is dropped before any
    /// k-cutoff (§A3, skip_first_result, default off).
    pub skip_first_result: bool,
    /// When true, a result whose doc ID equals the query ID is removed before
    /// any k-cutoff (§A3, ignore_identical_ids, default off; not applicable to
    /// ConvoMem data but required by the spec).
    pub ignore_identical_ids: bool,
}

impl LmebSpecOptions {
    /// Default: both switches off (§A3 defaults).
    pub const fn default_options() -> Self {
        LmebSpecOptions { skip_first_result: false, ignore_identical_ids: false }
    }
}

impl Default for LmebSpecOptions {
    fn default() -> Self { Self::default_options() }
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-query metric output (§A3)
// ─────────────────────────────────────────────────────────────────────────────

/// Per-query metric values at every k in LMEB_SPEC_K_VALUES (§A3).
/// Both aggregation levels start from these per-query values.
///
/// Twin of Swift `LMEBSpecQueryMetrics`.
#[derive(Debug, Clone)]
pub struct LmebSpecQueryMetrics {
    /// Query identifier.
    pub query_id: String,
    /// nDCG@k for each k (binary relevance, pytrec_eval semantics, §A3).
    pub ndcg: Vec<(usize, f64)>,
    /// AP@k for each k (for MAP aggregation). Denominator = |relevant|, §A3.
    pub ap: Vec<(usize, f64)>,
    /// Recall@k: |relevant ∩ top-k| / |relevant|, §A3.
    pub recall: Vec<(usize, f64)>,
    /// Precision@k: |relevant ∩ top-k| / k, §A3.
    pub precision: Vec<(usize, f64)>,
    /// MRR@k with cutoff at k, §A3.
    pub mrr: Vec<(usize, f64)>,
    /// R_cap@k per §A3 (metric.py verbatim). None when zero relevant docs.
    pub r_cap: Vec<(usize, Option<f64>)>,
}

impl LmebSpecQueryMetrics {
    /// Retrieves nDCG@k for a specific k. Returns 0.0 if k is absent.
    pub fn ndcg_at(&self, k: usize) -> f64 {
        self.ndcg.iter().find(|(kk, _)| *kk == k).map(|(_, v)| *v).unwrap_or(0.0)
    }
    /// Retrieves R_cap@k for a specific k. Returns None if k is absent.
    pub fn r_cap_at(&self, k: usize) -> Option<f64> {
        self.r_cap.iter().find(|(kk, _)| *kk == k).and_then(|(_, v)| *v)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Subset-level aggregated metrics (§A1/§A3, level 1)
// ─────────────────────────────────────────────────────────────────────────────

/// Macro mean of per-query metrics over all queries in one subset (§A1/§A3, level 1).
///
/// Twin of Swift `LMEBSpecSubsetMetrics`.
#[derive(Debug, Clone)]
pub struct LmebSpecSubsetMetrics {
    /// Subset name, e.g. "user_evidence".
    pub subset_name: String,
    /// Number of queries in this subset.
    pub query_count: usize,
    /// Per-k macro mean of nDCG@k.
    pub ndcg: Vec<(usize, f64)>,
    /// Per-k MAP@k: macro mean of AP@k.
    pub map: Vec<(usize, f64)>,
    /// Per-k macro mean of Recall@k.
    pub recall: Vec<(usize, f64)>,
    /// Per-k macro mean of Precision@k.
    pub precision: Vec<(usize, f64)>,
    /// Per-k macro mean of MRR@k.
    pub mrr: Vec<(usize, f64)>,
    /// Per-k macro mean of R_cap@k, ignoring None values (§A3, metric.py).
    /// None when ALL queries have None for that k.
    /// Rounded to 5 decimal places (§A3, metric.py).
    pub r_cap: Vec<(usize, Option<f64>)>,
    /// Per-query metrics (available for record-level JSON output).
    pub per_query: Vec<LmebSpecQueryMetrics>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Task-level aggregated metrics (§A1/§A3, level 2)
// ─────────────────────────────────────────────────────────────────────────────

/// Mean of subset scores across all subsets (§A1/§A3, level 2 = task score).
/// Headline metric: ndcg_at_10.
///
/// Twin of Swift `LMEBSpecTaskMetrics`.
#[derive(Debug, Clone)]
pub struct LmebSpecTaskMetrics {
    /// Number of subsets contributing to the task score.
    pub subset_count: usize,
    pub ndcg: Vec<(usize, f64)>,
    pub map: Vec<(usize, f64)>,
    pub recall: Vec<(usize, f64)>,
    pub precision: Vec<(usize, f64)>,
    pub mrr: Vec<(usize, f64)>,
    /// R_cap at task level: mean of non-None subset values; None when all are None.
    pub r_cap: Vec<(usize, Option<f64>)>,

    // ── Expand-verify scoreboard task metrics (§7.5) ─────────────────────────
    /// Fraction of questions where ≥1 gold doc appears in the pool.
    /// 0.0 default; set by run_lmeb_spec_queries after retrieval.
    pub pool_guarantee: f64,
    /// Gold docs in pool / total gold docs across all healthy questions.
    pub pool_gold_recall: f64,
    /// Number of questions classified as short (content_term_count < short_query_terms).
    pub short_query_count: usize,
    /// Mean nDCG@10 over the short-query subset. 0.0 when no short queries.
    pub short_query_ndcg_at_10: f64,
    /// Mean Recall@10 over the short-query subset. 0.0 when no short queries.
    pub short_query_recall_at_10: f64,
    /// Pool guarantee over the short-query subset. 0.0 when no short queries.
    pub short_query_pool_guarantee: f64,
}

impl LmebSpecTaskMetrics {
    /// Headline metric: nDCG@10 (§A1, main_score="ndcg_at_10").
    pub fn ndcg_at_10(&self) -> f64 {
        self.ndcg.iter().find(|(k, _)| *k == 10).map(|(_, v)| *v).unwrap_or(0.0)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §A3: Per-query metric primitives
// ─────────────────────────────────────────────────────────────────────────────

/// Applies `LmebSpecOptions` to a ranked list before cutoff scoring (§A3).
///
/// - `ignore_identical_ids`: removes any result whose doc ID equals the query ID.
/// - `skip_first_result`: drops the first ranked result (index 0) after any identical-id removal.
///
/// Twin of Swift `lmebSpecApplyOptions(rankedDocIDs:queryID:options:)`.
pub fn lmeb_spec_apply_options(
    ranked_doc_ids: &[String],
    query_id: &str,
    options: &LmebSpecOptions,
) -> Vec<String> {
    let mut result: Vec<String> = if options.ignore_identical_ids {
        // §A3 ignore_identical_ids: remove any result whose doc ID equals the query ID.
        ranked_doc_ids.iter().filter(|id| id.as_str() != query_id).cloned().collect()
    } else {
        ranked_doc_ids.to_vec()
    };
    // §A3 skip_first_result: drop rank 1 (index 0) before applying k-cutoffs.
    if options.skip_first_result && !result.is_empty() {
        result.remove(0);
    }
    result
}

/// nDCG@k with binary relevance (§A3, pytrec_eval semantics).
///
/// DCG@k  = Σ_{i=1..k} 1/log2(i+1) for each relevant hit at 1-based rank i.
/// IDCG@k = Σ_{i=1..min(k,|R|)} 1/log2(i+1)  (ideal ordering).
/// nDCG@k = DCG@k / IDCG@k; returns 0.0 when IDCG=0 (empty relevant set).
///
/// Twin of Swift `lmebSpecNDCG(rankedDocIDs:relevantDocIDs:k:)`.
pub fn lmeb_spec_ndcg(
    ranked_doc_ids: &[String],
    relevant_doc_ids: &HashSet<String>,
    k: usize,
) -> f64 {
    if k == 0 || relevant_doc_ids.is_empty() {
        return 0.0;
    }
    // DCG@k: sum 1/log2(zero_based+2) for each relevant hit in top-k.
    let mut dcg = 0.0_f64;
    for (zero_based, doc_id) in ranked_doc_ids.iter().take(k).enumerate() {
        if relevant_doc_ids.contains(doc_id.as_str()) {
            dcg += 1.0 / (zero_based as f64 + 2.0).log2();
        }
    }
    // IDCG@k: ideal DCG — first min(k, |R|) positions all relevant.
    let n_ideal = k.min(relevant_doc_ids.len());
    let mut idcg = 0.0_f64;
    for i in 1..=n_ideal {
        idcg += 1.0 / (i as f64 + 1.0).log2();
    }
    if idcg == 0.0 { return 0.0; }
    dcg / idcg
}

/// AP@k for MAP aggregation (§A3, pytrec_eval semantics).
///
/// AP@k = (1/|R|) × Σ_{j=1..k} P@j × rel_j
/// Denominator is |R| (total relevant count), not min(|R|, k).
/// Returns 0.0 when k==0, relevant is empty, or no relevant doc appears in top-k.
///
/// Twin of Swift `lmebSpecAP(rankedDocIDs:relevantDocIDs:k:)`.
pub fn lmeb_spec_ap(
    ranked_doc_ids: &[String],
    relevant_doc_ids: &HashSet<String>,
    k: usize,
) -> f64 {
    if k == 0 || relevant_doc_ids.is_empty() {
        return 0.0;
    }
    let mut relevant_seen: usize = 0;
    let mut sum_precision = 0.0_f64;
    for (zero_based, doc_id) in ranked_doc_ids.iter().take(k).enumerate() {
        if relevant_doc_ids.contains(doc_id.as_str()) {
            relevant_seen += 1;
            let rank = zero_based + 1;  // 1-based
            sum_precision += relevant_seen as f64 / rank as f64;
        }
    }
    sum_precision / relevant_doc_ids.len() as f64
}

/// Recall@k: |relevant ∩ top-k| / |relevant| (§A3, pytrec_eval semantics).
///
/// Returns 0.0 when k==0 or relevant is empty.
///
/// Twin of Swift `lmebSpecRecall(rankedDocIDs:relevantDocIDs:k:)`.
pub fn lmeb_spec_recall(
    ranked_doc_ids: &[String],
    relevant_doc_ids: &HashSet<String>,
    k: usize,
) -> f64 {
    if k == 0 || relevant_doc_ids.is_empty() {
        return 0.0;
    }
    let hits = ranked_doc_ids
        .iter()
        .take(k)
        .filter(|id| relevant_doc_ids.contains(id.as_str()))
        .count();
    hits as f64 / relevant_doc_ids.len() as f64
}

/// Precision@k: |relevant ∩ top-k| / k (§A3, pytrec_eval semantics).
///
/// Returns 0.0 when k==0.
///
/// Twin of Swift `lmebSpecPrecision(rankedDocIDs:relevantDocIDs:k:)`.
pub fn lmeb_spec_precision(
    ranked_doc_ids: &[String],
    relevant_doc_ids: &HashSet<String>,
    k: usize,
) -> f64 {
    if k == 0 { return 0.0; }
    let hits = ranked_doc_ids
        .iter()
        .take(k)
        .filter(|id| relevant_doc_ids.contains(id.as_str()))
        .count();
    hits as f64 / k as f64
}

/// MRR@k with cutoff at k (§A3, pytrec_eval semantics).
///
/// Reciprocal rank of the FIRST relevant document in top-k.
/// Returns 0.0 when k==0, relevant is empty, or no relevant doc in top-k.
///
/// Twin of Swift `lmebSpecMRR(rankedDocIDs:relevantDocIDs:k:)`.
pub fn lmeb_spec_mrr(
    ranked_doc_ids: &[String],
    relevant_doc_ids: &HashSet<String>,
    k: usize,
) -> f64 {
    if k == 0 || relevant_doc_ids.is_empty() {
        return 0.0;
    }
    for (zero_based, doc_id) in ranked_doc_ids.iter().take(k).enumerate() {
        if relevant_doc_ids.contains(doc_id.as_str()) {
            return 1.0 / (zero_based + 1) as f64;
        }
    }
    0.0
}

/// R_cap@k — LMEB-specific capped recall (§A3, verbatim from metric.py).
///
/// R_cap@k = hits / min(total_relevant, k)
///
/// Returns `None` when the query has zero relevant documents (denominator = 0).
/// The macro average at the subset level ignores `None` values (§A3, metric.py).
/// Values are rounded to 5 decimal places at aggregation.
///
/// Twin of Swift `lmebSpecRCap(rankedDocIDs:relevantDocIDs:k:)`.
pub fn lmeb_spec_r_cap(
    ranked_doc_ids: &[String],
    relevant_doc_ids: &HashSet<String>,
    k: usize,
) -> Option<f64> {
    if k == 0 { return Some(0.0); }
    let num_relevant_total = relevant_doc_ids.len();
    // §A3: None when the query has no relevant documents (denominator = 0).
    let denom = num_relevant_total.min(k);
    if denom == 0 { return None; }
    let hits = ranked_doc_ids
        .iter()
        .take(k)
        .filter(|id| relevant_doc_ids.contains(id.as_str()))
        .count();
    Some(hits as f64 / denom as f64)
}

// ─────────────────────────────────────────────────────────────────────────────
// §A3: Full per-query metric computation
// ─────────────────────────────────────────────────────────────────────────────

/// Computes all official LMEB metrics at every k in LMEB_SPEC_K_VALUES for one query (§A3).
///
/// The ranked list is first filtered by options before any k-cutoff is applied.
/// Accepts the NUL-prefixed-placeholder form that the runner produces.
///
/// Twin of Swift `lmebSpecPerQueryMetrics(rankedDocIDs:relevantDocIDs:queryID:options:)`.
pub fn lmeb_spec_per_query_metrics(
    ranked_doc_ids: &[String],
    relevant_doc_ids: &HashSet<String>,
    query_id: &str,
    options: &LmebSpecOptions,
) -> LmebSpecQueryMetrics {
    // Apply options once before any k-cutoff — both filters operate on the full list.
    let filtered = lmeb_spec_apply_options(ranked_doc_ids, query_id, options);

    let mut ndcg      = Vec::with_capacity(LMEB_SPEC_K_VALUES.len());
    let mut ap        = Vec::with_capacity(LMEB_SPEC_K_VALUES.len());
    let mut recall    = Vec::with_capacity(LMEB_SPEC_K_VALUES.len());
    let mut precision = Vec::with_capacity(LMEB_SPEC_K_VALUES.len());
    let mut mrr       = Vec::with_capacity(LMEB_SPEC_K_VALUES.len());
    let mut r_cap     = Vec::with_capacity(LMEB_SPEC_K_VALUES.len());

    // §A3: compute every metric at each k in the canonical k-value list.
    for &k in LMEB_SPEC_K_VALUES {
        ndcg.push((k,      lmeb_spec_ndcg(&filtered, relevant_doc_ids, k)));
        ap.push((k,        lmeb_spec_ap(&filtered, relevant_doc_ids, k)));
        recall.push((k,    lmeb_spec_recall(&filtered, relevant_doc_ids, k)));
        precision.push((k, lmeb_spec_precision(&filtered, relevant_doc_ids, k)));
        mrr.push((k,       lmeb_spec_mrr(&filtered, relevant_doc_ids, k)));
        r_cap.push((k,     lmeb_spec_r_cap(&filtered, relevant_doc_ids, k)));
    }

    LmebSpecQueryMetrics {
        query_id: query_id.to_string(),
        ndcg,
        ap,
        recall,
        precision,
        mrr,
        r_cap,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §A1/§A3: Subset aggregation (level 1)
// ─────────────────────────────────────────────────────────────────────────────

/// Computes subset-level metrics: macro mean of per-query values for each metric and k (§A1/§A3).
///
/// R_cap@k macro mean ignores None values (§A3). If ALL query values are None for a given k,
/// the subset R_cap@k is None. Values are rounded to 5 decimal places per metric.py (§A3).
///
/// Twin of Swift `lmebSpecSubsetMetrics(queries:subsetName:)`.
pub fn lmeb_spec_subset_metrics(
    queries: Vec<LmebSpecQueryMetrics>,
    subset_name: &str,
) -> LmebSpecSubsetMetrics {
    let n = queries.len();

    let mut ndcg_out      = Vec::with_capacity(LMEB_SPEC_K_VALUES.len());
    let mut map_out       = Vec::with_capacity(LMEB_SPEC_K_VALUES.len());
    let mut recall_out    = Vec::with_capacity(LMEB_SPEC_K_VALUES.len());
    let mut precision_out = Vec::with_capacity(LMEB_SPEC_K_VALUES.len());
    let mut mrr_out       = Vec::with_capacity(LMEB_SPEC_K_VALUES.len());
    let mut r_cap_out     = Vec::with_capacity(LMEB_SPEC_K_VALUES.len());

    for &k in LMEB_SPEC_K_VALUES {
        // Simple macro means for nDCG, MAP, Recall, Precision, MRR.
        // Empty subset returns 0.0 rather than NaN.
        let mean_of = |getter: &dyn Fn(&LmebSpecQueryMetrics) -> f64| -> f64 {
            if n == 0 { return 0.0; }
            queries.iter().map(getter).sum::<f64>() / n as f64
        };

        let ndcg_val = mean_of(&|q| {
            q.ndcg.iter().find(|(kk, _)| *kk == k).map(|(_, v)| *v).unwrap_or(0.0)
        });
        let map_val = mean_of(&|q| {
            q.ap.iter().find(|(kk, _)| *kk == k).map(|(_, v)| *v).unwrap_or(0.0)
        });
        let recall_val = mean_of(&|q| {
            q.recall.iter().find(|(kk, _)| *kk == k).map(|(_, v)| *v).unwrap_or(0.0)
        });
        let prec_val = mean_of(&|q| {
            q.precision.iter().find(|(kk, _)| *kk == k).map(|(_, v)| *v).unwrap_or(0.0)
        });
        let mrr_val = mean_of(&|q| {
            q.mrr.iter().find(|(kk, _)| *kk == k).map(|(_, v)| *v).unwrap_or(0.0)
        });

        ndcg_out.push((k, ndcg_val));
        map_out.push((k, map_val));
        recall_out.push((k, recall_val));
        precision_out.push((k, prec_val));
        mrr_out.push((k, mrr_val));

        // §A3 R_cap macro mean: ignore None values; all-None → None.
        // §A3 metric.py: `round(sum(valid) / len(valid), 5)`.
        let valid_r_cap: Vec<f64> = queries.iter().filter_map(|q| {
            q.r_cap.iter().find(|(kk, _)| *kk == k)?.1
        }).collect();

        let r_cap_val: Option<f64> = if valid_r_cap.is_empty() {
            // All queries had None (zero relevant docs) → subset R_cap@k is None.
            None
        } else {
            // §A3: round to 5 decimal places.
            let avg = valid_r_cap.iter().sum::<f64>() / valid_r_cap.len() as f64;
            Some((avg * 1e5).round() / 1e5)
        };
        r_cap_out.push((k, r_cap_val));
    }

    LmebSpecSubsetMetrics {
        subset_name: subset_name.to_string(),
        query_count: n,
        ndcg: ndcg_out,
        map: map_out,
        recall: recall_out,
        precision: precision_out,
        mrr: mrr_out,
        r_cap: r_cap_out,
        per_query: queries,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §A1/§A3: Task aggregation (level 2)
// ─────────────────────────────────────────────────────────────────────────────

/// Computes task-level metrics: mean of subset scores across all subsets (§A1/§A3).
///
/// R_cap@k at task level: mean of non-None subset values; None when ALL subsets are None.
///
/// Twin of Swift `lmebSpecTaskMetrics(subsets:)`.
pub fn lmeb_spec_task_metrics(subsets: &[LmebSpecSubsetMetrics]) -> LmebSpecTaskMetrics {
    let n = subsets.len();

    let mut ndcg_out      = Vec::with_capacity(LMEB_SPEC_K_VALUES.len());
    let mut map_out       = Vec::with_capacity(LMEB_SPEC_K_VALUES.len());
    let mut recall_out    = Vec::with_capacity(LMEB_SPEC_K_VALUES.len());
    let mut precision_out = Vec::with_capacity(LMEB_SPEC_K_VALUES.len());
    let mut mrr_out       = Vec::with_capacity(LMEB_SPEC_K_VALUES.len());
    let mut r_cap_out     = Vec::with_capacity(LMEB_SPEC_K_VALUES.len());

    for &k in LMEB_SPEC_K_VALUES {
        let mean_of = |getter: &dyn Fn(&LmebSpecSubsetMetrics) -> f64| -> f64 {
            if n == 0 { return 0.0; }
            subsets.iter().map(getter).sum::<f64>() / n as f64
        };

        let ndcg_val = mean_of(&|s| {
            s.ndcg.iter().find(|(kk, _)| *kk == k).map(|(_, v)| *v).unwrap_or(0.0)
        });
        let map_val = mean_of(&|s| {
            s.map.iter().find(|(kk, _)| *kk == k).map(|(_, v)| *v).unwrap_or(0.0)
        });
        let recall_val = mean_of(&|s| {
            s.recall.iter().find(|(kk, _)| *kk == k).map(|(_, v)| *v).unwrap_or(0.0)
        });
        let prec_val = mean_of(&|s| {
            s.precision.iter().find(|(kk, _)| *kk == k).map(|(_, v)| *v).unwrap_or(0.0)
        });
        let mrr_val = mean_of(&|s| {
            s.mrr.iter().find(|(kk, _)| *kk == k).map(|(_, v)| *v).unwrap_or(0.0)
        });

        ndcg_out.push((k, ndcg_val));
        map_out.push((k, map_val));
        recall_out.push((k, recall_val));
        precision_out.push((k, prec_val));
        mrr_out.push((k, mrr_val));

        // R_cap@k task mean: mean of non-None subset values; None when all are None.
        let valid_r_cap: Vec<f64> = subsets.iter().filter_map(|s| {
            s.r_cap.iter().find(|(kk, _)| *kk == k)?.1
        }).collect();

        let r_cap_val: Option<f64> = if valid_r_cap.is_empty() {
            None
        } else {
            Some(valid_r_cap.iter().sum::<f64>() / valid_r_cap.len() as f64)
        };
        r_cap_out.push((k, r_cap_val));
    }

    LmebSpecTaskMetrics {
        subset_count: n,
        ndcg: ndcg_out,
        map: map_out,
        recall: recall_out,
        precision: precision_out,
        mrr: mrr_out,
        r_cap: r_cap_out,
        // Expand-verify fields default to zero; caller sets them after retrieval.
        pool_guarantee: 0.0,
        pool_gold_recall: 0.0,
        short_query_count: 0,
        short_query_ndcg_at_10: 0.0,
        short_query_recall_at_10: 0.0,
        short_query_pool_guarantee: 0.0,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §7.1: Content-term counting and stopword fixture
// ─────────────────────────────────────────────────────────────────────────────

/// Complete 178-word EN stopword set, mirrored from `conformance/lmeb-spec/stopwords_en.json`.
///
/// Used as a compile-time embedded fallback when the JSON fixture cannot be loaded at runtime
/// (e.g. test environments where the package root differs from the binary's cwd). The set here
/// must remain byte-identical to the JSON fixture array — both ports load the same fixture.
///
/// Do NOT trim this list; the term-count test vectors in the conformance fixture depend on the
/// complete 178-word set, including contractions and pronouns.
const LMEB_STOPWORDS_EN: &[&str] = &[
    "a","about","above","after","again","against","all","am","an","and",
    "any","are","aren't","as","at","be","because","been","before","being",
    "below","between","both","but","by","can","can't","cannot","could","couldn't",
    "did","didn't","do","does","doesn't","doing","don't","down","during","each",
    "few","for","from","further","get","got","had","hadn't","has","hasn't",
    "have","haven't","having","he","he'd","he'll","he's","her","here","here's",
    "hers","herself","him","himself","his","how","how's","i","i'd","i'll",
    "i'm","i've","if","in","into","is","isn't","it","it's","its",
    "itself","let's","me","more","most","mustn't","my","myself","no","nor",
    "not","of","off","on","once","only","or","other","ought","our",
    "ours","ourselves","out","over","own","same","shan't","she","she'd","she'll",
    "she's","should","shouldn't","so","some","such","than","that","that's","the",
    "their","theirs","them","themselves","then","there","there's","these","they","they'd",
    "they'll","they're","they've","this","those","through","to","too","under","until",
    "up","very","was","wasn't","we","we'd","we'll","we're","we've","were",
    "weren't","what","what's","when","when's","where","where's","which","while","who",
    "who's","whom","why","why's","will","with","won't","would","wouldn't","you",
    "you'd","you'll","you're","you've","your","yours","yourself","yourselves",
];

/// Loads the shared EN stopword set.
///
/// Primary path: `conformance/lmeb-spec/stopwords_en.json` relative to this file's
/// source directory (works when running from the crate root). Falls back to the
/// compile-time embedded set when the file cannot be read or parsed.
fn lmeb_stopwords_loaded() -> HashSet<String> {
    // Try runtime file load: file sits next to the crate root.
    let fixture_paths = [
        concat!(env!("CARGO_MANIFEST_DIR"), "/conformance/lmeb-spec/stopwords_en.json"),
        "../conformance/lmeb-spec/stopwords_en.json",
        "conformance/lmeb-spec/stopwords_en.json",
    ];
    for path in &fixture_paths {
        if let Ok(data) = std::fs::read_to_string(path) {
            if let Ok(json) = serde_json::from_str::<serde_json::Value>(&data) {
                if let Some(arr) = json["stopwords"].as_array() {
                    let words: HashSet<String> = arr.iter()
                        .filter_map(|v| v.as_str())
                        .map(|s| s.to_string())
                        .collect();
                    if words.len() > 50 {
                        return words;
                    }
                }
            }
        }
    }
    // Embedded fallback: the complete 178-word list above.
    LMEB_STOPWORDS_EN.iter().map(|s| s.to_string()).collect()
}

/// Count content terms in `text` using the shared EN stopword fixture.
///
/// Tokens are formed by lowercasing `text` and splitting on non-alnum characters.
/// Empty tokens and stopword tokens are excluded. The resulting count is the
/// §7.1 content_term_count for the short-query gate.
///
/// Twin of Swift `lmebContentTermCount(text:stopwords:)`.
pub fn lmeb_content_term_count(text: &str) -> usize {
    let stopwords = lmeb_stopwords_loaded();
    let lower = text.to_lowercase();
    lower.split(|c: char| !c.is_alphanumeric())
        .filter(|tok| !tok.is_empty() && !stopwords.contains(*tok))
        .count()
}

/// Count content terms against an explicit stopword set.
/// Used in tests where the caller controls the stopword fixture.
///
/// Twin of Swift `lmebContentTermCount(text:stopwords:)` with explicit stopwords parameter.
pub fn lmeb_content_term_count_with_stopwords(text: &str, stopwords: &HashSet<String>) -> usize {
    let lower = text.to_lowercase();
    lower.split(|c: char| !c.is_alphanumeric())
        .filter(|tok| !tok.is_empty() && !stopwords.contains(*tok))
        .count()
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn rel(ids: &[&str]) -> HashSet<String> {
        ids.iter().map(|s| s.to_string()).collect()
    }
    fn ranked(ids: &[&str]) -> Vec<String> {
        ids.iter().map(|s| s.to_string()).collect()
    }

    // ── nDCG ──────────────────────────────────────────────────────────────────

    /// nDCG@1 = 1.0 when the single relevant doc is at rank 1.
    /// Pinned to conformance/lmeb-spec/metric_vectors.json "ndcg_rank1_hit".
    #[test]
    fn ndcg_rank1_hit() {
        let r = ranked(&["A", "B", "C"]);
        let rel = rel(&["A"]);
        let v = lmeb_spec_ndcg(&r, &rel, 1);
        assert!((v - 1.0).abs() < 1e-9, "nDCG@1 hit: got {v}");
    }

    /// nDCG@1 = 0.0 when the relevant doc is NOT at rank 1.
    #[test]
    fn ndcg_rank1_miss() {
        let r = ranked(&["B", "A", "C"]);
        let rel = rel(&["A"]);
        let v = lmeb_spec_ndcg(&r, &rel, 1);
        assert!((v - 0.0).abs() < 1e-9, "nDCG@1 miss: got {v}");
    }

    /// nDCG@5 with relevant docs at ranks 1 and 3.
    /// DCG = 1/log2(2) + 1/log2(4) = 1.0 + 0.5 = 1.5
    /// IDCG = 1/log2(2) + 1/log2(3) = 1.0 + 0.6309... = 1.6309...
    /// nDCG ≈ 0.91961
    /// Pinned to conformance/lmeb-spec/metric_vectors.json "ndcg_two_relevant_at_1_and_3".
    #[test]
    fn ndcg_two_relevant_at_1_and_3() {
        let r = ranked(&["A", "B", "C", "D", "E"]);
        let rel = rel(&["A", "C"]);
        let v = lmeb_spec_ndcg(&r, &rel, 5);
        let expected = 1.5_f64 / (1.0_f64 + 1.0_f64 / 3.0_f64.log2());
        assert!((v - expected).abs() < 1e-9, "nDCG@5 two_rel: got {v}, expected {expected}");
    }

    /// nDCG@k = 0.0 when relevant set is empty.
    #[test]
    fn ndcg_empty_relevant() {
        let r = ranked(&["A", "B"]);
        let rel: HashSet<String> = HashSet::new();
        for &k in LMEB_SPEC_K_VALUES {
            let v = lmeb_spec_ndcg(&r, &rel, k);
            assert!((v - 0.0).abs() < 1e-9, "nDCG@{k} empty_rel: got {v}");
        }
    }

    // ── AP@k / MAP ────────────────────────────────────────────────────────────

    /// AP@5 with relevant docs at ranks 1 and 3.
    /// P@1=1 (1 rel/1), P@3=2/3 (2 rel/3). AP = (1 + 2/3) / 2 = 5/6.
    #[test]
    fn ap_two_relevant_at_1_and_3() {
        let r = ranked(&["A", "B", "C", "D", "E"]);
        let rel = rel(&["A", "C"]);
        let v = lmeb_spec_ap(&r, &rel, 5);
        let expected = 5.0_f64 / 6.0_f64;
        assert!((v - expected).abs() < 1e-9, "AP@5 got {v}, expected {expected}");
    }

    // ── Recall ────────────────────────────────────────────────────────────────

    /// Recall@1 = 0, Recall@5 = 1 when the only relevant doc is at rank 2.
    #[test]
    fn recall_at_1_miss_at_2_hit() {
        let r = ranked(&["B", "A", "C", "D", "E"]);
        let rel = rel(&["A"]);
        assert!((lmeb_spec_recall(&r, &rel, 1) - 0.0).abs() < 1e-9);
        assert!((lmeb_spec_recall(&r, &rel, 5) - 1.0).abs() < 1e-9);
    }

    // ── Precision ─────────────────────────────────────────────────────────────

    /// Precision@5 = 2/5 when 2 relevant docs are in the top 5.
    #[test]
    fn precision_at_5_two_hits() {
        let r = ranked(&["A", "B", "C", "D", "E"]);
        let rel = rel(&["A", "C"]);
        let v = lmeb_spec_precision(&r, &rel, 5);
        assert!((v - 0.4).abs() < 1e-9, "Precision@5 got {v}");
    }

    /// Precision@1 = 0 when the rank-1 doc is not relevant.
    #[test]
    fn precision_at_1_miss() {
        let r = ranked(&["B", "A"]);
        let rel = rel(&["A"]);
        assert!((lmeb_spec_precision(&r, &rel, 1) - 0.0).abs() < 1e-9);
    }

    // ── MRR@k ─────────────────────────────────────────────────────────────────

    /// MRR@1 = 0, MRR@5 = 1/3 when the relevant doc is at rank 3.
    #[test]
    fn mrr_at_k_rank3() {
        let r = ranked(&["B", "C", "A", "D", "E"]);
        let rel = rel(&["A"]);
        assert!((lmeb_spec_mrr(&r, &rel, 1) - 0.0).abs() < 1e-9);
        assert!((lmeb_spec_mrr(&r, &rel, 3) - 1.0 / 3.0).abs() < 1e-9);
        // MRR@2 = 0 because rank 3 is beyond the cutoff.
        assert!((lmeb_spec_mrr(&r, &rel, 2) - 0.0).abs() < 1e-9);
    }

    // ── R_cap@k ───────────────────────────────────────────────────────────────

    /// R_cap@k = None when zero relevant docs (§A3, metric.py verbatim).
    /// Pinned to conformance/lmeb-spec/metric_vectors.json "rcap_zero_relevant_none".
    #[test]
    fn r_cap_zero_relevant_is_none() {
        let r = ranked(&["A", "B", "C"]);
        let rel: HashSet<String> = HashSet::new();
        for &k in LMEB_SPEC_K_VALUES {
            let v = lmeb_spec_r_cap(&r, &rel, k);
            assert!(v.is_none(), "R_cap@{k} must be None when no relevant docs, got {v:?}");
        }
    }

    /// R_cap@1 = 0 and R_cap@5 = 1 when the single relevant is at rank 2 (miss at 1, hit at 5).
    #[test]
    fn r_cap_one_relevant_miss_at_k1() {
        let r = ranked(&["B", "A", "C", "D", "E"]);
        let rel = rel(&["A"]);
        // R_cap@1: hits=0, denom=min(1,1)=1, value=0.0
        assert_eq!(lmeb_spec_r_cap(&r, &rel, 1), Some(0.0));
        // R_cap@5: hits=1, denom=min(1,5)=1, value=1.0
        assert_eq!(lmeb_spec_r_cap(&r, &rel, 5), Some(1.0));
    }

    // ── Options ───────────────────────────────────────────────────────────────

    /// skip_first_result: relevant doc at rank 1 becomes unreachable (§A3).
    /// Pinned to conformance/lmeb-spec/metric_vectors.json "skip_first_result_drops_rank1".
    #[test]
    fn skip_first_result_drops_rank1_relevant() {
        let r = ranked(&["A", "B", "C"]);
        let rel = rel(&["A"]);
        let opts = LmebSpecOptions { skip_first_result: true, ignore_identical_ids: false };
        let filtered = lmeb_spec_apply_options(&r, "q1", &opts);
        // After skip, A is gone; recall@1 = 0.
        let recall = lmeb_spec_recall(&filtered, &rel, 1);
        assert!((recall - 0.0).abs() < 1e-9, "skip_first_result: recall@1 should be 0, got {recall}");
        // R_cap@1 = 0 (not None — there IS a relevant doc, just missed).
        let rc = lmeb_spec_r_cap(&filtered, &rel, 1);
        assert_eq!(rc, Some(0.0), "skip_first_result: R_cap@1 should be Some(0), got {rc:?}");
    }

    /// ignore_identical_ids: the query's own doc ID is removed before cutoffs (§A3).
    /// Pinned to conformance/lmeb-spec/metric_vectors.json "ignore_identical_ids_removes_self".
    #[test]
    fn ignore_identical_ids_removes_self() {
        // Query ID = "doc1" is at rank 1; relevant doc "doc2" is at rank 2.
        let r = ranked(&["doc1", "doc2", "doc3"]);
        let rel = rel(&["doc2"]);
        let opts = LmebSpecOptions { skip_first_result: false, ignore_identical_ids: true };
        let filtered = lmeb_spec_apply_options(&r, "doc1", &opts);
        // After removal of doc1, doc2 is now rank 1.
        let ndcg1 = lmeb_spec_ndcg(&filtered, &rel, 1);
        assert!((ndcg1 - 1.0).abs() < 1e-9, "ignore_identical_ids: nDCG@1 should be 1.0, got {ndcg1}");
    }

    // ── Two-level aggregation ─────────────────────────────────────────────────

    /// Two-level aggregation: subset nDCG@10 = macro mean; task = mean of subsets (§A1/§A3).
    ///
    /// Subset "user_evidence": q1 nDCG@10=1.0, q2 nDCG@10=0.5 → mean=0.75
    /// Subset "preference_evidence": q3 nDCG@10=0.0 → mean=0.0
    /// Task nDCG@10 = (0.75 + 0.0) / 2 = 0.375
    ///
    /// Pinned to conformance/lmeb-spec/metric_vectors.json "aggregation_two_level".
    #[test]
    fn aggregation_two_level_ndcg_at_10() {
        // q1: relevant at rank 1 (nDCG@10=1.0)
        let q1 = lmeb_spec_per_query_metrics(
            &ranked(&["A"]),
            &rel(&["A"]),
            "q1",
            &LmebSpecOptions::default(),
        );
        // q2: 1 relevant doc, list of 3 (A at rank 1, relevant={B} so miss): nDCG@10=0.0
        // Wait, I need nDCG@10=0.5, so let me set up differently.
        // 1 relevant doc at rank 2 out of [X, A]: nDCG@10 = 1/log2(3) / 1/log2(2) = 1/log2(3)
        // That's ≈0.631, not 0.5.
        // Better: 1 relevant at rank 2, IDCG=1. DCG=1/log2(3). Not 0.5.
        // For 0.5: we need DCG/IDCG = 0.5. IDCG = 1/log2(2) = 1. DCG = 0.5. That would
        // require 1/log2(rank+1) = 0.5 → log2(rank+1) = 2 → rank+1=4 → rank=3.
        // So rank 3: DCG = 1/log2(4) = 0.5. nDCG@10 = 0.5. ✓
        let q2 = lmeb_spec_per_query_metrics(
            &ranked(&["X", "Y", "A", "Z"]),
            &rel(&["A"]),  // A is at rank 3, DCG=1/log2(4)=0.5, IDCG=1, nDCG@10=0.5
            "q2",
            &LmebSpecOptions::default(),
        );
        // q3: no relevant hit → nDCG@10=0.0
        let q3 = lmeb_spec_per_query_metrics(
            &ranked(&["X", "Y", "Z"]),
            &rel(&["A"]),  // A not in ranked list
            "q3",
            &LmebSpecOptions::default(),
        );

        let ndcg_q1 = q1.ndcg_at(10);
        let ndcg_q2 = q2.ndcg_at(10);
        let ndcg_q3 = q3.ndcg_at(10);

        assert!((ndcg_q1 - 1.0).abs() < 1e-9, "q1 nDCG@10={ndcg_q1}");
        assert!((ndcg_q2 - 0.5).abs() < 1e-9, "q2 nDCG@10={ndcg_q2}");
        assert!((ndcg_q3 - 0.0).abs() < 1e-9, "q3 nDCG@10={ndcg_q3}");

        let subset1 = lmeb_spec_subset_metrics(vec![q1, q2], "user_evidence");
        let subset2 = lmeb_spec_subset_metrics(vec![q3], "preference_evidence");

        let s1_ndcg10 = subset1.ndcg.iter().find(|(k, _)| *k == 10).map(|(_, v)| *v).unwrap();
        let s2_ndcg10 = subset2.ndcg.iter().find(|(k, _)| *k == 10).map(|(_, v)| *v).unwrap();
        assert!((s1_ndcg10 - 0.75).abs() < 1e-9, "subset1 nDCG@10={s1_ndcg10}");
        assert!((s2_ndcg10 - 0.0).abs() < 1e-9, "subset2 nDCG@10={s2_ndcg10}");

        let task = lmeb_spec_task_metrics(&[subset1, subset2]);
        let task_ndcg10 = task.ndcg_at_10();
        assert!((task_ndcg10 - 0.375).abs() < 1e-9, "task nDCG@10={task_ndcg10}");
    }

    /// R_cap@k macro mean ignores None; if all None, subset and task R_cap = None (§A3).
    #[test]
    fn r_cap_none_propagation_through_levels() {
        // q_none: zero relevant → R_cap@k = None for all k
        let q_none = lmeb_spec_per_query_metrics(
            &ranked(&["A", "B"]),
            &HashSet::new(),
            "q_none",
            &LmebSpecOptions::default(),
        );
        // q_val: 1 relevant at rank 1 → R_cap@5 = 1/min(1,5) = 1.0
        let q_val = lmeb_spec_per_query_metrics(
            &ranked(&["A", "B"]),
            &rel(&["A"]),
            "q_val",
            &LmebSpecOptions::default(),
        );

        // Subset with one None and one value: macro avg ignores None → avg = 1.0.
        let subset_mixed = lmeb_spec_subset_metrics(vec![q_none.clone(), q_val], "user_evidence");
        let rc5_mixed = subset_mixed.r_cap.iter().find(|(k, _)| *k == 5).and_then(|(_, v)| *v);
        assert_eq!(rc5_mixed, Some(1.0), "mixed subset R_cap@5 should be 1.0, got {rc5_mixed:?}");

        // Subset with only None: R_cap = None.
        let subset_all_none = lmeb_spec_subset_metrics(vec![q_none], "preference_evidence");
        let rc5_none = subset_all_none.r_cap.iter().find(|(k, _)| *k == 5).unwrap().1;
        assert!(rc5_none.is_none(), "all-None subset R_cap@5 must be None");

        // Task with one None-subset and one valued-subset: task picks up the value.
        let task = lmeb_spec_task_metrics(&[subset_mixed, subset_all_none]);
        let task_rc5 = task.r_cap.iter().find(|(k, _)| *k == 5).and_then(|(_, v)| *v);
        assert_eq!(task_rc5, Some(1.0), "task R_cap@5 should be 1.0, got {task_rc5:?}");
    }

    // ── Instruction constants ─────────────────────────────────────────────────

    /// All six §A4 instruction strings are present and verbatim.
    #[test]
    fn instruction_strings_verbatim() {
        assert_eq!(
            lmeb_spec_instruction_for_subset("abstention_evidence"),
            Some("Given a query, retrieve documents that answer the query")
        );
        assert_eq!(
            lmeb_spec_instruction_for_subset("assistant_facts_evidence"),
            Some("Given a query, retrieve assistant messages that answer the query")
        );
        assert_eq!(
            lmeb_spec_instruction_for_subset("changing_evidence"),
            Some("Given a question, retrieve the latest information to answer the question")
        );
        assert_eq!(
            lmeb_spec_instruction_for_subset("implicit_connection_evidence"),
            Some("Given a query, retrieve documents that answer the query")
        );
        assert_eq!(
            lmeb_spec_instruction_for_subset("preference_evidence"),
            Some("Given a query, retrieve the user's stated preferences that can help answer the query")
        );
        assert_eq!(
            lmeb_spec_instruction_for_subset("user_evidence"),
            Some("Given a query, retrieve documents that answer the query")
        );
        assert_eq!(lmeb_spec_instruction_for_subset("unknown_subset"), None);
    }

    // ── Expand-verify: content-term count (§7.1) ──────────────────────────────

    /// Helper: build a controlled stopword set for deterministic tests.
    fn stopwords(words: &[&str]) -> HashSet<String> {
        words.iter().map(|s| s.to_string()).collect()
    }

    /// Empty text → 0 content terms.
    #[test]
    fn content_term_count_empty() {
        let sw = stopwords(&["the", "a"]);
        assert_eq!(lmeb_content_term_count_with_stopwords("", &sw), 0);
    }

    /// All-stopword text → 0 content terms.
    #[test]
    fn content_term_count_all_stopwords() {
        let sw = stopwords(&["the", "a", "an"]);
        assert_eq!(lmeb_content_term_count_with_stopwords("the a an", &sw), 0);
    }

    /// Mixed text: "what" and "the" are stopwords; "happened" and "yesterday" are content terms.
    #[test]
    fn content_term_count_mixed() {
        let sw = stopwords(&["what", "the"]);
        let count = lmeb_content_term_count_with_stopwords("what happened the yesterday", &sw);
        assert_eq!(count, 2);
    }

    /// Punctuation stripped; tokens lowercased; stopwords removed.
    /// "Where" "did" "I" are stopwords; "travel" "paris" "london" are content terms → 3.
    #[test]
    fn content_term_count_punctuation_and_case() {
        let sw = stopwords(&["where", "did", "i"]);
        let count = lmeb_content_term_count_with_stopwords("Where did I travel? Paris, London!", &sw);
        assert_eq!(count, 3);
    }

    /// Short-query gate: 3 content terms < 4 (threshold) → short; 4 not short.
    #[test]
    fn short_query_gate() {
        let sw: HashSet<String> = HashSet::new(); // no stopwords for this gate test
        let short_count = lmeb_content_term_count_with_stopwords("alice bob charlie", &sw);
        assert_eq!(short_count, 3);
        assert!(short_count < 4, "3 terms should be below the default threshold of 4");

        let not_short_count = lmeb_content_term_count_with_stopwords("alice bob charlie delta", &sw);
        assert_eq!(not_short_count, 4);
        assert!(not_short_count >= 4, "4 terms should NOT be below the default threshold of 4");
    }

    // ── Expand-verify: pool guarantee and gold-rank computation (§3) ──────────

    /// goldRanks: 1-based positions of gold docs in the ranked list.
    #[test]
    fn gold_ranks_correct() {
        let ranked = vec!["d1", "d2", "d3", "d4", "d5"];
        let relevant = rel(&["d2", "d4"]);
        let ranks: Vec<usize> = ranked.iter().enumerate()
            .filter_map(|(i, id)| if relevant.contains(*id) { Some(i + 1) } else { None })
            .collect();
        assert_eq!(ranks, vec![2, 4]);
    }

    /// When no gold doc appears in the returned list → poolGoldHit = 0.
    #[test]
    fn pool_gold_hit_zero() {
        let ranked = vec!["d1", "d2", "d3"];
        let relevant = rel(&["d9", "d10"]);
        let ranks: Vec<usize> = ranked.iter().enumerate()
            .filter_map(|(i, id)| if relevant.contains(*id) { Some(i + 1) } else { None })
            .collect();
        assert!(ranks.is_empty());
        let pool_gold_hit = if ranks.is_empty() { 0usize } else { 1 };
        assert_eq!(pool_gold_hit, 0);
    }

    /// When ≥1 gold doc appears → poolGoldHit = 1.
    #[test]
    fn pool_gold_hit_one() {
        let ranked = vec!["d1", "d2", "d3"];
        let relevant = rel(&["d2"]);
        let ranks: Vec<usize> = ranked.iter().enumerate()
            .filter_map(|(i, id)| if relevant.contains(*id) { Some(i + 1) } else { None })
            .collect();
        assert!(!ranks.is_empty());
        let pool_gold_hit = if ranks.is_empty() { 0usize } else { 1 };
        assert_eq!(pool_gold_hit, 1);
    }

    /// poolGuarantee = fraction of questions with ≥1 gold in the pool.
    #[test]
    fn pool_guarantee_fraction() {
        let hits: Vec<usize> = vec![1, 0, 1]; // 2 of 3 questions have gold in pool
        let guarantee = hits.iter().filter(|&&h| h == 1).count() as f64 / hits.len() as f64;
        let expected = 2.0 / 3.0;
        assert!((guarantee - expected).abs() < 1e-9, "guarantee={guarantee}, expected={expected}");
    }

    /// poolGoldRecall = gold docs in pool / total gold docs.
    #[test]
    fn pool_gold_recall_fraction() {
        // Q1: 2 gold docs, 1 in pool. Q2: 3 gold docs, 2 in pool. Total gold=5, in pool=3.
        let total_gold = 5usize;
        let gold_in_pool = 3usize;
        let recall = gold_in_pool as f64 / total_gold as f64;
        assert!((recall - 0.6).abs() < 1e-9, "recall={recall}");
    }
}
