//! lmeb_scorer.rs — Pure scoring math for LMEB/ConvoMem document retrieval.
//!
//! Rust twin of `LMEBScorer.swift`. Every function is deterministic and pure
//! (no I/O, no live products) so the conformance vectors in
//! `conformance/lmeb_vectors.json` drive both legs identically.
//!
//! Key difference from `longmemeval_scorer.rs`: LMEB ground truth is a SET of
//! DOCUMENT IDs (not session IDs). Primary metric: nDCG@10 (standard IR).
//!
//! ## nDCG@k formula (binary relevance)
//!
//! ```text
//! DCG@k  = Σ_{i=1}^{k}           rel_i / log2(i+1)
//! IDCG@k = Σ_{i=1}^{min(k,|R|)} 1.0   / log2(i+1)   (ideal ordering)
//! nDCG@k = DCG@k / IDCG@k  (0.0 when IDCG=0 i.e. empty relevant set)
//! ```
//!
//! ## AP@k formula
//!
//! ```text
//! AP@k = (1/|R|) × Σ_{j=1}^{k} P@j × rel_j
//! MAP@k = mean AP@k over guard-healthy queries
//! ```

use std::collections::{BTreeMap, HashSet};

// ─────────────────────────────────────────────────────────────────────────────
// nDCG@k
// ─────────────────────────────────────────────────────────────────────────────

/// nDCG@k with binary relevance over document IDs.
///
/// Returns 0.0 when `k == 0` or `relevant_doc_ids` is empty (IDCG would be 0).
///
/// Twin of Swift `lmebNDCG(rankedDocIDs:relevantDocIDs:k:)`.
pub fn lmeb_ndcg(ranked_doc_ids: &[String], relevant_doc_ids: &HashSet<String>, k: usize) -> f64 {
    if k == 0 || relevant_doc_ids.is_empty() {
        return 0.0;
    }
    // DCG@k: sum rel_i / log2(rank+1) for positions 1..=k.
    // zero_based=0 → rank 1 → divisor log2(0+2) = log2(2).
    let mut dcg = 0.0_f64;
    for (zero_based, doc_id) in ranked_doc_ids.iter().take(k).enumerate() {
        if relevant_doc_ids.contains(doc_id.as_str()) {
            dcg += 1.0 / (zero_based as f64 + 2.0).log2();
        }
    }
    // IDCG@k: ideal DCG where the first min(k, |R|) positions are all relevant.
    let n_ideal = k.min(relevant_doc_ids.len());
    let mut idcg = 0.0_f64;
    for i in 1..=n_ideal {
        idcg += 1.0 / (i as f64 + 1.0).log2();
    }
    if idcg == 0.0 {
        return 0.0;
    }
    dcg / idcg
}

// ─────────────────────────────────────────────────────────────────────────────
// Document-level MRR
// ─────────────────────────────────────────────────────────────────────────────

/// Document-level MRR: 1 / (1-based rank of the FIRST relevant document found).
///
/// Returns 0.0 when no relevant document appears in the list, or when
/// `relevant_doc_ids` is empty.
///
/// Twin of Swift `lmebMRR(rankedDocIDs:relevantDocIDs:)`.
pub fn lmeb_mrr(ranked_doc_ids: &[String], relevant_doc_ids: &HashSet<String>) -> f64 {
    if relevant_doc_ids.is_empty() {
        return 0.0;
    }
    for (zero_based, doc_id) in ranked_doc_ids.iter().enumerate() {
        if relevant_doc_ids.contains(doc_id.as_str()) {
            return 1.0 / (zero_based + 1) as f64;
        }
    }
    0.0
}

// ─────────────────────────────────────────────────────────────────────────────
// Recall@k
// ─────────────────────────────────────────────────────────────────────────────

/// Recall@k: |relevant ∩ top-k| / |relevant|.
///
/// Returns 0.0 when `k == 0` or `relevant_doc_ids` is empty.
///
/// Twin of Swift `lmebRecall(rankedDocIDs:relevantDocIDs:k:)`.
pub fn lmeb_recall(ranked_doc_ids: &[String], relevant_doc_ids: &HashSet<String>, k: usize) -> f64 {
    if k == 0 || relevant_doc_ids.is_empty() {
        return 0.0;
    }
    let top_k: HashSet<&str> = ranked_doc_ids.iter().take(k).map(|s| s.as_str()).collect();
    let hits = top_k.iter().filter(|&&id| relevant_doc_ids.contains(id)).count();
    hits as f64 / relevant_doc_ids.len() as f64
}

// ─────────────────────────────────────────────────────────────────────────────
// AP@k (average precision)
// ─────────────────────────────────────────────────────────────────────────────

/// Average precision at k: (1/|R|) × Σ_{j=1}^{k} P@j × rel_j.
///
/// P@j = (# relevant in top-j) / j. The denominator is |R| (total relevant
/// count), matching the standard IR definition. Returns 0.0 when `k == 0`,
/// `relevant_doc_ids` is empty, or no relevant document appears in the top-k.
///
/// Twin of Swift `lmebAP(rankedDocIDs:relevantDocIDs:k:)`.
pub fn lmeb_ap(ranked_doc_ids: &[String], relevant_doc_ids: &HashSet<String>, k: usize) -> f64 {
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

// ─────────────────────────────────────────────────────────────────────────────
// Percentile helper
// ─────────────────────────────────────────────────────────────────────────────

/// Nearest-rank percentile of `values` at fraction `p` ∈ (0, 1].
/// Returns 0.0 for an empty input.
///
/// Matches `lmeb_percentile` (Swift), `lme_percentile` (Swift/Rust), and
/// `RollingSeries.p95` — all latency surfaces are on the same scale.
///
/// Twin of Swift `lmebPercentile(_:_:)`.
pub fn lmeb_percentile(values: &[f64], p: f64) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let mut sorted = values.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let n = sorted.len();
    // rank = ceil(p × n), clamped to [1, n].
    let rank = ((p * n as f64).ceil() as usize).max(1).min(n);
    sorted[rank - 1]
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-query result (from runner) and score (from scorer)
// ─────────────────────────────────────────────────────────────────────────────

/// The raw result of running the LMEB harness against one query.
/// Produced by `lmeb_runner`; consumed by `score_lmeb_query`.
///
/// Twin of Swift `LMEBQueryResult`.
#[derive(Debug)]
pub struct LmebQueryResult {
    pub query_id: String,
    pub query_latency_seconds: f64,
    /// Doc IDs retrieved by moot_memory_search, ranked best-first (UUID→docID mapped).
    pub retrieved_doc_ids: Vec<String>,
    /// Ground-truth relevant document IDs.
    pub relevant_doc_ids: HashSet<String>,
    pub guard_healthy: bool,
    pub guard_diagnostic: Option<String>,
    pub docs_ingested: usize,
    pub write_mean_latency_seconds: f64,
    /// Whether this query's estate was served from the snapshot cache.
    /// Some(true) = cache hit, Some(false) = cache miss, None = cache off.
    pub cache_hit: Option<bool>,
}

/// The scored result for one LMEB query.
/// Guard-excluded queries have zeroed retrieval metrics.
///
/// Twin of Swift `LMEBQueryScore`.
#[derive(Debug)]
pub struct LmebQueryScore {
    pub query_id: String,
    pub guard_healthy: bool,
    pub guard_diagnostic: Option<String>,
    pub ndcg_at_10: f64,
    pub mrr: f64,
    pub recall_at_1: f64,
    pub recall_at_5: f64,
    pub recall_at_10: f64,
    pub ap_at_10: f64,
    pub query_latency_seconds: f64,
    pub write_mean_latency_seconds: f64,
    pub docs_ingested: usize,
    pub retrieved_doc_count: usize,
    pub ranked_doc_ids: Vec<String>,
    pub relevant_doc_ids: Vec<String>,
}

/// Scores one `LmebQueryResult`. Guard-excluded queries get zeroed metrics.
///
/// Twin of Swift `scoreLMEBQuery(_:)`.
pub fn score_lmeb_query(result: LmebQueryResult) -> LmebQueryScore {
    let (ndcg, mrr, r1, r5, r10, ap) = if result.guard_healthy {
        (
            lmeb_ndcg(&result.retrieved_doc_ids, &result.relevant_doc_ids, 10),
            lmeb_mrr(&result.retrieved_doc_ids, &result.relevant_doc_ids),
            lmeb_recall(&result.retrieved_doc_ids, &result.relevant_doc_ids, 1),
            lmeb_recall(&result.retrieved_doc_ids, &result.relevant_doc_ids, 5),
            lmeb_recall(&result.retrieved_doc_ids, &result.relevant_doc_ids, 10),
            lmeb_ap(&result.retrieved_doc_ids, &result.relevant_doc_ids, 10),
        )
    } else {
        (0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    };

    let retrieved_doc_count = result.retrieved_doc_ids.len();
    let mut relevant_sorted: Vec<String> = result.relevant_doc_ids.iter().cloned().collect();
    relevant_sorted.sort();

    LmebQueryScore {
        query_id: result.query_id,
        guard_healthy: result.guard_healthy,
        guard_diagnostic: result.guard_diagnostic,
        ndcg_at_10: ndcg,
        mrr,
        recall_at_1: r1,
        recall_at_5: r5,
        recall_at_10: r10,
        ap_at_10: ap,
        query_latency_seconds: result.query_latency_seconds,
        write_mean_latency_seconds: result.write_mean_latency_seconds,
        docs_ingested: result.docs_ingested,
        retrieved_doc_count,
        ranked_doc_ids: result.retrieved_doc_ids,
        relevant_doc_ids: relevant_sorted,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Aggregate metrics
// ─────────────────────────────────────────────────────────────────────────────

/// Aggregate LMEB metrics. All values are means over guard-healthy queries only.
#[derive(Debug)]
pub struct LmebAggregate {
    pub query_count: usize,
    pub ndcg_at_10: f64,
    pub mrr: f64,
    pub recall_at_1: f64,
    pub recall_at_5: f64,
    pub recall_at_10: f64,
    pub map_at_10: f64,
}

/// Latency statistics over ALL queries (guard-healthy and excluded alike).
#[derive(Debug)]
pub struct LmebLatencyStats {
    pub query_p50_seconds: f64,
    pub query_p95_seconds: f64,
    pub query_mean_seconds: f64,
    pub write_mean_seconds: f64,
}

/// Computes aggregate metrics and latency stats from scored queries.
///
/// Aggregate: guard-healthy only (per BENCHMARKER_OPTIMIZER_CONTRACT.md §1.2).
/// Latency: all queries.
///
/// Twin of Swift `aggregateLMEBScores(_:)`.
pub fn aggregate_lmeb_scores(scores: &[LmebQueryScore]) -> (LmebAggregate, LmebLatencyStats) {
    // ── Aggregate (guard-healthy only) ────────────────────────────────────────
    let healthy: Vec<&LmebQueryScore> = scores.iter().filter(|s| s.guard_healthy).collect();
    let n = healthy.len();

    let aggregate = if n == 0 {
        LmebAggregate {
            query_count: 0,
            ndcg_at_10: 0.0, mrr: 0.0,
            recall_at_1: 0.0, recall_at_5: 0.0, recall_at_10: 0.0,
            map_at_10: 0.0,
        }
    } else {
        let sum = |f: fn(&LmebQueryScore) -> f64| -> f64 {
            healthy.iter().map(|s| f(s)).sum::<f64>()
        };
        LmebAggregate {
            query_count: n,
            ndcg_at_10:  sum(|s| s.ndcg_at_10)  / n as f64,
            mrr:         sum(|s| s.mrr)          / n as f64,
            recall_at_1: sum(|s| s.recall_at_1)  / n as f64,
            recall_at_5: sum(|s| s.recall_at_5)  / n as f64,
            recall_at_10: sum(|s| s.recall_at_10) / n as f64,
            map_at_10:   sum(|s| s.ap_at_10)     / n as f64,
        }
    };

    // ── Latency (all queries) ─────────────────────────────────────────────────
    let query_latencies: Vec<f64> = scores.iter().map(|s| s.query_latency_seconds).collect();
    let write_latencies: Vec<f64> = scores.iter().map(|s| s.write_mean_latency_seconds).collect();
    let query_mean = if query_latencies.is_empty() {
        0.0
    } else {
        query_latencies.iter().sum::<f64>() / query_latencies.len() as f64
    };
    let write_mean = if write_latencies.is_empty() {
        0.0
    } else {
        write_latencies.iter().sum::<f64>() / write_latencies.len() as f64
    };
    let latency = LmebLatencyStats {
        query_p50_seconds:  lmeb_percentile(&query_latencies, 0.50),
        query_p95_seconds:  lmeb_percentile(&query_latencies, 0.95),
        query_mean_seconds: query_mean,
        write_mean_seconds: write_mean,
    };

    (aggregate, latency)
}

// ─────────────────────────────────────────────────────────────────────────────
// JSON report types
// ─────────────────────────────────────────────────────────────────────────────

/// Corpus statistics block of the LMEB report.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct LmebReportCorpusStats {
    pub queries_loaded: usize,
    pub queries_run: usize,
    pub guard_excluded: usize,
}

/// Aggregate metrics block.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct LmebReportAggregate {
    pub query_count: usize,
    pub ndcg_at_10: f64,
    pub mrr: f64,
    pub recall_at_1: f64,
    pub recall_at_5: f64,
    pub recall_at_10: f64,
    pub map_at_10: f64,
}

/// Latency statistics block.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct LmebReportLatency {
    pub query_p50_seconds: f64,
    pub query_p95_seconds: f64,
    pub query_mean_seconds: f64,
    pub write_mean_seconds: f64,
}

/// Per-query entry in the LMEB report.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct LmebReportPerQuery {
    pub query_id: String,
    pub docs_ingested: usize,
    pub guard_healthy: bool,
    pub guard_diagnostic: Option<String>,
    pub ndcg_at_10: f64,
    pub mrr: f64,
    pub recall_at_1: f64,
    pub recall_at_5: f64,
    pub recall_at_10: f64,
    pub ap_at_10: f64,
    pub query_latency_seconds: f64,
    pub write_mean_latency_seconds: f64,
    pub ranked_doc_ids: Vec<String>,
    pub relevant_doc_ids: Vec<String>,
    pub retrieved_doc_count: usize,
    /// Whether this query's estate was served from the snapshot cache.
    /// Some(true) = hit, Some(false) = miss, None = cache off.
    /// Additive key per BENCHMARKER_OPTIMIZER_CONTRACT.md.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_hit: Option<bool>,
}

/// The full LMEB run report. Written after a `lmeb` subcommand run.
///
/// Additive keys — does not overwrite any existing LME or benchmarker report keys.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct LmebReport {
    pub run_id: String,
    pub run_label: String,
    pub evidence_types: Vec<String>,
    pub generated_at: String,
    /// Encode-queue synchronization strategy used for this run.
    /// One of: "drain" | "impatient" | "none". Self-documenting in the report.
    pub encode_barrier: String,
    pub corpus_stats: LmebReportCorpusStats,
    pub aggregate: LmebReportAggregate,
    pub latency: LmebReportLatency,
    /// Estate cache mode used for this run: "off" | "reuse".
    /// Additive key per BENCHMARKER_OPTIMIZER_CONTRACT.md.
    pub estate_cache: String,
    /// Number of queries whose estate was served from the snapshot cache.
    /// Additive key per BENCHMARKER_OPTIMIZER_CONTRACT.md.
    pub cache_hits: usize,
    /// Number of queries that triggered a new snapshot (cache miss).
    /// Additive key per BENCHMARKER_OPTIMIZER_CONTRACT.md.
    pub cache_misses: usize,
    pub per_query: Vec<LmebReportPerQuery>,
}

/// Assembles an `LmebReport` from scores and metadata.
///
/// `cache_hit_by_id` maps query_id → cache_hit for per-query report population.
/// `estate_cache` is the cache-mode string ("off" | "reuse").
///
/// Twin of Swift `buildLMEBReport(runLabel:evidenceTypes:queriesLoaded:scores:results:estateCache:)`.
pub fn build_lmeb_report(
    run_id: String,
    run_label: String,
    evidence_types: Vec<String>,
    generated_at: String,
    encode_barrier: String,
    queries_loaded: usize,
    scores: &[LmebQueryScore],
    cache_hit_by_id: &std::collections::HashMap<String, Option<bool>>,
    estate_cache: String,
) -> LmebReport {
    let (aggregate, latency) = aggregate_lmeb_scores(scores);
    let guard_excluded = scores.iter().filter(|s| !s.guard_healthy).count();
    let cache_hits:   usize = cache_hit_by_id.values().filter(|&&v| v == Some(true)).count();
    let cache_misses: usize = cache_hit_by_id.values().filter(|&&v| v == Some(false)).count();

    let corpus_stats = LmebReportCorpusStats {
        queries_loaded,
        queries_run: scores.len(),
        guard_excluded,
    };

    let report_aggregate = LmebReportAggregate {
        query_count:  aggregate.query_count,
        ndcg_at_10:   aggregate.ndcg_at_10,
        mrr:          aggregate.mrr,
        recall_at_1:  aggregate.recall_at_1,
        recall_at_5:  aggregate.recall_at_5,
        recall_at_10: aggregate.recall_at_10,
        map_at_10:    aggregate.map_at_10,
    };

    let report_latency = LmebReportLatency {
        query_p50_seconds:  latency.query_p50_seconds,
        query_p95_seconds:  latency.query_p95_seconds,
        query_mean_seconds: latency.query_mean_seconds,
        write_mean_seconds: latency.write_mean_seconds,
    };

    let per_query: Vec<LmebReportPerQuery> = scores
        .iter()
        .map(|s| LmebReportPerQuery {
            query_id:                s.query_id.clone(),
            docs_ingested:           s.docs_ingested,
            guard_healthy:           s.guard_healthy,
            guard_diagnostic:        s.guard_diagnostic.clone(),
            ndcg_at_10:              s.ndcg_at_10,
            mrr:                     s.mrr,
            recall_at_1:             s.recall_at_1,
            recall_at_5:             s.recall_at_5,
            recall_at_10:            s.recall_at_10,
            ap_at_10:                s.ap_at_10,
            query_latency_seconds:   s.query_latency_seconds,
            write_mean_latency_seconds: s.write_mean_latency_seconds,
            ranked_doc_ids:          s.ranked_doc_ids.clone(),
            relevant_doc_ids:        s.relevant_doc_ids.clone(),
            retrieved_doc_count:     s.retrieved_doc_count,
            // Look up cache_hit from the raw results map (key = query_id).
            cache_hit: cache_hit_by_id.get(&s.query_id).copied().flatten(),
        })
        .collect();

    LmebReport {
        run_id,
        run_label,
        evidence_types,
        generated_at,
        encode_barrier,
        corpus_stats,
        aggregate: report_aggregate,
        latency: report_latency,
        estate_cache,
        cache_hits,
        cache_misses,
        per_query,
    }
}

/// Encodes and writes an `LmebReport` to a JSON file (sorted keys).
///
/// Twin of Swift `writeLMEBReport(_:to:)`.
pub fn write_lmeb_report(report: &LmebReport, path: &std::path::Path) -> Result<(), String> {
    let json = serde_json::to_string_pretty(report)
        .map_err(|e| format!("report encode failed: {e}"))?;
    let value: serde_json::Value = serde_json::from_str(&json)
        .map_err(|e| format!("report re-parse failed: {e}"))?;
    let sorted = sorted_json_value(&value);
    let sorted_json = serde_json::to_string_pretty(&sorted)
        .map_err(|e| format!("sorted report encode failed: {e}"))?;
    std::fs::write(path, sorted_json.as_bytes())
        .map_err(|e| format!("report write failed: {e}"))
}

/// Recursively sorts JSON object keys (matching JSONEncoder `.sortedKeys`).
fn sorted_json_value(v: &serde_json::Value) -> serde_json::Value {
    match v {
        serde_json::Value::Object(obj) => {
            let sorted: serde_json::Map<String, serde_json::Value> = obj
                .iter()
                .collect::<BTreeMap<_, _>>()
                .into_iter()
                .map(|(k, val)| (k.clone(), sorted_json_value(val)))
                .collect();
            serde_json::Value::Object(sorted)
        }
        serde_json::Value::Array(arr) => {
            serde_json::Value::Array(arr.iter().map(sorted_json_value).collect())
        }
        other => other.clone(),
    }
}
