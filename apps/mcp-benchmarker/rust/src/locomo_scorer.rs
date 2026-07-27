//! locomo_scorer.rs — LoCoMo turn-recall scoring (Rust twin of `LoCoMoScorer.swift`).
//!
//! The core scoring math (lme_ranked_sessions, lme_recall_any, lme_recall_all,
//! lme_session_mrr, lme_percentile) is IDENTICAL to longmemeval_scorer.rs —
//! those functions are string-agnostic and work identically with dia_ids
//! (e.g. "D1:3") in place of session_ids.
//!
//! # What this file adds
//!
//! 1. `LoCoMoManifestEntry` / `LoCoMoQuestionResult` — the runner's output types.
//! 2. `locomo_manifest_as_lme()` — bridges LoCoMo manifest entries to the
//!    `LmeManifestEntry` form so `lme_ranked_sessions` can map UUID → dia_id.
//! 3. `score_locomo_question()` — thin wrapper calling the LME math with LoCoMo types.
//! 4. `aggregate_locomo_scores()` — per-category breakdown (single_hop / temporal /
//!    multi_hop / open_domain).
//! 5. JSON report types and `build_locomo_report()` / `write_locomo_report()`.
//!
//! # Conformance
//!
//! The conformance vectors in `conformance/locomo_vectors.json` pin the underlying
//! math against hand-computed values. Both the Swift and Rust legs must reproduce
//! those values to within 1e-9. See `conformance.rs` `locomo_scorer_recall_vectors`
//! and `locomo_scorer_uuid_mapping_vectors`.

use crate::longmemeval_scorer::{
    lme_percentile, lme_ranked_sessions, lme_recall_all, lme_recall_any, lme_session_mrr,
    LmeManifestEntry,
};
use std::collections::{BTreeMap, HashSet};

// ─────────────────────────────────────────────────────────────────────────────
// Manifest and per-question result (produced by locomo_runner)
// ─────────────────────────────────────────────────────────────────────────────

/// Maps a filed-memory UUID back to its origin turn in a LoCoMo conversation.
/// The runner builds one entry per ingested turn; the scorer uses the manifest
/// to correlate retrieved UUIDs → dia_ids for turn-level recall scoring.
///
/// Twin of Swift `LoCoMoManifestEntry`.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct LoCoMoManifestEntry {
    /// UUID returned by moot_file_memory ("filed memory <UUID>").
    pub uuid: String,
    /// Unique turn identifier: format "D<session>:<dialog>" (e.g. "D1:3").
    pub dia_id: String,
    /// 1-based session number this turn belongs to.
    pub session_number: usize,
    /// 0-based index of this turn within its session.
    pub turn_index: usize,
    /// Speaker name (matches conversation.speaker_a or speaker_b).
    pub speaker: String,
}

/// The result of querying the harness with one LoCoMo question.
/// Produced by `locomo_runner::run_locomo_questions`; consumed by
/// `score_locomo_question`.
///
/// Twin of Swift `LoCoMoQuestionResult`.
#[derive(Debug)]
pub struct LoCoMoQuestionResult {
    /// Synthetic question identifier (e.g. "conv-26_q3").
    pub question_id: String,
    /// Category label: "single_hop" | "temporal" | "multi_hop" | "open_domain".
    pub category_label: String,
    /// Raw integer category (1-4).
    pub category: u8,
    /// Time taken for the moot_memory_search call, in seconds.
    pub query_latency_seconds: f64,
    /// UUIDs returned by moot_memory_search, in ranked order.
    pub retrieved_uuids: Vec<String>,
    /// Manifest mapping UUID → dia_id for every ingested turn in this
    /// conversation's estate. Shared across all questions for the same conversation.
    pub manifest: Vec<LoCoMoManifestEntry>,
    /// Ground-truth dia_ids that contain evidence for this question.
    pub evidence_dia_ids: Vec<String>,
    /// True when the DegeneracyGuard classified the backend as healthy.
    pub guard_healthy: bool,
    /// If the guard was unhealthy, the diagnostic message.
    pub guard_diagnostic: Option<String>,
    /// Total turns ingested into this conversation's estate.
    pub turns_ingested: usize,
    /// Mean write latency across all turns for this conversation's estate.
    pub write_mean_latency_seconds: f64,
    /// Whether this question's estate was served from the snapshot cache.
    /// Some(true) = cache hit, Some(false) = cache miss, None = cache off.
    pub cache_hit: Option<bool>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Manifest bridge
// ─────────────────────────────────────────────────────────────────────────────

/// Converts a LoCoMo manifest to the `LmeManifestEntry` form that
/// `lme_ranked_sessions` expects. The `session_id` field carries the `dia_id`
/// so the string-agnostic `lme_ranked_sessions` maps UUID → dia_id correctly.
///
/// Twin of Swift `loCoMoManifestAsLME(_:)`.
pub fn locomo_manifest_as_lme(manifest: &[LoCoMoManifestEntry]) -> Vec<LmeManifestEntry> {
    manifest
        .iter()
        .map(|e| LmeManifestEntry {
            uuid: e.uuid.clone(),
            session_id: e.dia_id.clone(), // dia_id stands in for session_id
            turn_index: e.turn_index,
            session_index: e.session_number,
            role: e.speaker.clone(), // speaker stands in for role
        })
        .collect()
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-question score
// ─────────────────────────────────────────────────────────────────────────────

/// The scored result for one LoCoMo question.
/// Guard-excluded questions have all recall/MRR metrics set to 0.0 and are
/// excluded from the aggregate denominator.
///
/// Twin of Swift `LoCoMoQuestionScore`.
#[derive(Debug)]
pub struct LoCoMoQuestionScore {
    pub question_id: String,
    /// Raw integer category (1-4).
    pub category: u8,
    /// Human-readable category label ("single_hop" | "temporal" | "multi_hop" | "open_domain").
    pub category_label: String,
    pub guard_healthy: bool,
    pub guard_diagnostic: Option<String>,
    // Per-question recall/MRR metrics. All 0.0 when guard_healthy is false.
    pub recall_any_at_1: f64,
    pub recall_any_at_5: f64,
    pub recall_any_at_10: f64,
    pub recall_all_at_1: f64,
    pub recall_all_at_5: f64,
    pub recall_all_at_10: f64,
    pub mrr: f64,
    /// Deduplicated dia_id ranking (first-UUID-appearance order).
    pub ranked_dia_ids: Vec<String>,
    /// Ground-truth dia_ids for this question.
    pub evidence_dia_ids: Vec<String>,
    // Latency and ingest stats — always recorded, not excluded by guard.
    pub query_latency_seconds: f64,
    pub write_mean_latency_seconds: f64,
    pub turns_ingested: usize,
    pub retrieved_uuid_count: usize,
}

/// Scores one `LoCoMoQuestionResult`. Guard-excluded questions are flagged with
/// zeroed recall/MRR (excluded from aggregate denominator).
///
/// Twin of Swift `scoreLoCoMoQuestion(_:)`.
pub fn score_locomo_question(result: LoCoMoQuestionResult) -> LoCoMoQuestionScore {
    // Bridge manifest to LME form: LoCoMoManifestEntry.dia_id → LmeManifestEntry.session_id.
    let lme_manifest = locomo_manifest_as_lme(&result.manifest);
    let ranked_dia_ids = lme_ranked_sessions(&result.retrieved_uuids, &lme_manifest);
    let evidence_set: HashSet<String> = result.evidence_dia_ids.iter().cloned().collect();

    let (ra1, ra5, ra10, rl1, rl5, rl10, mrr) = if result.guard_healthy {
        (
            lme_recall_any(&ranked_dia_ids, &evidence_set, 1),
            lme_recall_any(&ranked_dia_ids, &evidence_set, 5),
            lme_recall_any(&ranked_dia_ids, &evidence_set, 10),
            lme_recall_all(&ranked_dia_ids, &evidence_set, 1),
            lme_recall_all(&ranked_dia_ids, &evidence_set, 5),
            lme_recall_all(&ranked_dia_ids, &evidence_set, 10),
            lme_session_mrr(&ranked_dia_ids, &evidence_set),
        )
    } else {
        (0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    };

    let retrieved_uuid_count = result.retrieved_uuids.len();
    LoCoMoQuestionScore {
        question_id: result.question_id,
        category: result.category,
        category_label: result.category_label,
        guard_healthy: result.guard_healthy,
        guard_diagnostic: result.guard_diagnostic,
        recall_any_at_1: ra1,
        recall_any_at_5: ra5,
        recall_any_at_10: ra10,
        recall_all_at_1: rl1,
        recall_all_at_5: rl5,
        recall_all_at_10: rl10,
        mrr,
        ranked_dia_ids,
        evidence_dia_ids: result.evidence_dia_ids,
        query_latency_seconds: result.query_latency_seconds,
        write_mean_latency_seconds: result.write_mean_latency_seconds,
        turns_ingested: result.turns_ingested,
        retrieved_uuid_count,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Aggregate metrics
// ─────────────────────────────────────────────────────────────────────────────

/// Aggregate LoCoMo retrieval metrics over guard-healthy questions.
/// Twin of Swift `LoCoMoAggregateMetrics`.
#[derive(Debug)]
pub struct LoCoMoAggregateMetrics {
    pub query_count: usize,
    pub recall_any_at_1: f64,
    pub recall_any_at_5: f64,
    pub recall_any_at_10: f64,
    pub recall_all_at_1: f64,
    pub recall_all_at_5: f64,
    pub recall_all_at_10: f64,
    pub mrr: f64,
}

/// Per-category breakdown. One entry per category, guard-healthy only.
/// Only @5 and MRR are tracked at the per-category level (the report's category
/// table shows the three most useful cutoffs; @1 and @10 are in the aggregate).
///
/// Twin of Swift `LoCoMoCategoryBreakdown`.
#[derive(Debug)]
pub struct LoCoMoCategoryBreakdown {
    /// Category label ("single_hop" | "temporal" | "multi_hop" | "open_domain").
    pub label: String,
    pub query_count: usize,
    pub recall_any_at_5: f64,
    pub recall_all_at_5: f64,
    pub mrr: f64,
}

/// Latency statistics over all questions (healthy and excluded).
/// Twin of Swift `LoCoMoLatencyStats`.
#[derive(Debug)]
pub struct LoCoMoLatencyStats {
    pub query_p50_seconds: f64,
    pub query_p95_seconds: f64,
    pub query_mean_seconds: f64,
    pub write_mean_seconds: f64,
}

/// Helper: aggregate metrics over a slice of score references.
fn aggregate_scores_slice(scores: &[&LoCoMoQuestionScore]) -> LoCoMoAggregateMetrics {
    let healthy: Vec<&&LoCoMoQuestionScore> =
        scores.iter().filter(|s| s.guard_healthy).collect();
    let n = healthy.len();
    if n == 0 {
        return LoCoMoAggregateMetrics {
            query_count: 0,
            recall_any_at_1: 0.0,
            recall_any_at_5: 0.0,
            recall_any_at_10: 0.0,
            recall_all_at_1: 0.0,
            recall_all_at_5: 0.0,
            recall_all_at_10: 0.0,
            mrr: 0.0,
        };
    }
    let nf = n as f64;
    LoCoMoAggregateMetrics {
        query_count: n,
        recall_any_at_1:  healthy.iter().map(|s| s.recall_any_at_1).sum::<f64>()  / nf,
        recall_any_at_5:  healthy.iter().map(|s| s.recall_any_at_5).sum::<f64>()  / nf,
        recall_any_at_10: healthy.iter().map(|s| s.recall_any_at_10).sum::<f64>() / nf,
        recall_all_at_1:  healthy.iter().map(|s| s.recall_all_at_1).sum::<f64>()  / nf,
        recall_all_at_5:  healthy.iter().map(|s| s.recall_all_at_5).sum::<f64>()  / nf,
        recall_all_at_10: healthy.iter().map(|s| s.recall_all_at_10).sum::<f64>() / nf,
        mrr:              healthy.iter().map(|s| s.mrr).sum::<f64>()               / nf,
    }
}

/// Helper: per-category breakdown over a label-filtered slice.
fn category_breakdown_slice(label: &str, scores: &[&LoCoMoQuestionScore]) -> LoCoMoCategoryBreakdown {
    let healthy: Vec<&&LoCoMoQuestionScore> = scores
        .iter()
        .filter(|s| s.guard_healthy && s.category_label == label)
        .collect();
    let n = healthy.len();
    if n == 0 {
        return LoCoMoCategoryBreakdown {
            label: label.to_string(),
            query_count: 0,
            recall_any_at_5: 0.0,
            recall_all_at_5: 0.0,
            mrr: 0.0,
        };
    }
    let nf = n as f64;
    LoCoMoCategoryBreakdown {
        label: label.to_string(),
        query_count: n,
        recall_any_at_5: healthy.iter().map(|s| s.recall_any_at_5).sum::<f64>() / nf,
        recall_all_at_5: healthy.iter().map(|s| s.recall_all_at_5).sum::<f64>() / nf,
        mrr:             healthy.iter().map(|s| s.mrr).sum::<f64>()              / nf,
    }
}

/// Computes aggregate metrics, per-category breakdown, and latency stats.
/// An empty input yields zeroed structs.
///
/// Twin of Swift `aggregateLoCoMoScores(_:)`.
pub fn aggregate_locomo_scores(
    scores: &[LoCoMoQuestionScore],
) -> (LoCoMoAggregateMetrics, Vec<LoCoMoCategoryBreakdown>, LoCoMoLatencyStats) {
    let all_refs: Vec<&LoCoMoQuestionScore> = scores.iter().collect();

    // ── Aggregate (guard-healthy only) ─────────────────────────────────────
    let aggregate = aggregate_scores_slice(&all_refs);

    // ── Per-category breakdown (ascending category integer order: 1, 2, 3, 4) ──
    let categories = vec![
        category_breakdown_slice("single_hop",  &all_refs),
        category_breakdown_slice("temporal",    &all_refs),
        category_breakdown_slice("multi_hop",   &all_refs),
        category_breakdown_slice("open_domain", &all_refs),
    ];

    // ── Latency (all questions) ─────────────────────────────────────────────
    let query_latencies: Vec<f64> = scores.iter().map(|s| s.query_latency_seconds).collect();
    let write_latencies: Vec<f64> = scores.iter().map(|s| s.write_mean_latency_seconds).collect();
    let latency = LoCoMoLatencyStats {
        query_p50_seconds:  lme_percentile(&query_latencies, 0.50),
        query_p95_seconds:  lme_percentile(&query_latencies, 0.95),
        query_mean_seconds: if query_latencies.is_empty() { 0.0 }
            else { query_latencies.iter().sum::<f64>() / query_latencies.len() as f64 },
        write_mean_seconds: if write_latencies.is_empty() { 0.0 }
            else { write_latencies.iter().sum::<f64>() / write_latencies.len() as f64 },
    };

    (aggregate, categories, latency)
}

// ─────────────────────────────────────────────────────────────────────────────
// JSON report types
// ─────────────────────────────────────────────────────────────────────────────

/// Corpus statistics block.
/// Contract-compatible with BENCHMARKER_OPTIMIZER_CONTRACT.md (additive keys).
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct LoCoMoReportCorpusStats {
    pub questions_loaded: usize,
    pub adversarial_excluded: usize,
    pub questions_run: usize,
    pub guard_excluded: usize,
}

/// Aggregate metrics block.
/// Additive key naming: `recall_any_*` / `recall_all_*` / `mrr` / `query_count`
/// mirror the LME naming convention per BENCHMARKER_OPTIMIZER_CONTRACT.md.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct LoCoMoReportAggregate {
    pub query_count: usize,
    pub recall_any_at_1: f64,
    pub recall_any_at_5: f64,
    pub recall_any_at_10: f64,
    pub recall_all_at_1: f64,
    pub recall_all_at_5: f64,
    pub recall_all_at_10: f64,
    pub mrr: f64,
}

/// Per-category breakdown entry (additive `category_breakdown` key in report).
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct LoCoMoReportCategoryEntry {
    pub label: String,
    pub query_count: usize,
    pub recall_any_at_5: f64,
    pub recall_all_at_5: f64,
    pub mrr: f64,
}

/// Latency statistics block.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct LoCoMoReportLatency {
    pub query_p50_seconds: f64,
    pub query_p95_seconds: f64,
    pub query_mean_seconds: f64,
    pub write_mean_seconds: f64,
}

/// Per-question entry in the LoCoMo report.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct LoCoMoReportPerQuestion {
    pub question_id: String,
    pub category_label: String,
    pub category: u8,
    pub turns_ingested: usize,
    pub guard_healthy: bool,
    pub guard_diagnostic: Option<String>,
    pub recall_any_at_1: f64,
    pub recall_any_at_5: f64,
    pub recall_any_at_10: f64,
    pub recall_all_at_1: f64,
    pub recall_all_at_5: f64,
    pub recall_all_at_10: f64,
    pub mrr: f64,
    pub query_latency_seconds: f64,
    pub write_mean_latency_seconds: f64,
    pub ranked_dia_ids: Vec<String>,
    pub evidence_dia_ids: Vec<String>,
    pub retrieved_uuid_count: usize,
    /// Whether this question's estate was served from the snapshot cache.
    /// Some(true) = hit, Some(false) = miss, None = cache off.
    /// Additive key per BENCHMARKER_OPTIMIZER_CONTRACT.md.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_hit: Option<bool>,
}

/// The full LoCoMo run report.
/// Additive with BENCHMARKER_OPTIMIZER_CONTRACT.md §1.2: existing key names
/// unchanged; `category_breakdown` is a new additive key.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct LoCoMoReport {
    pub run_id: String,
    pub run_label: String,
    pub generated_at: String,
    /// Encode-queue synchronization strategy used for this run.
    /// One of: "drain" | "impatient" | "none". Self-documenting in the report.
    pub encode_barrier: String,
    pub corpus_stats: LoCoMoReportCorpusStats,
    pub aggregate: LoCoMoReportAggregate,
    /// Per-category breakdown: single_hop / temporal / multi_hop / open_domain.
    /// New in LoCoMo, not present in LME reports (additive key).
    pub category_breakdown: Vec<LoCoMoReportCategoryEntry>,
    pub latency: LoCoMoReportLatency,
    /// Estate cache mode used for this run: "off" | "reuse".
    /// Additive key per BENCHMARKER_OPTIMIZER_CONTRACT.md.
    pub estate_cache: String,
    /// Number of questions whose estate was served from the snapshot cache.
    /// Additive key per BENCHMARKER_OPTIMIZER_CONTRACT.md.
    pub cache_hits: usize,
    /// Number of questions that triggered a new snapshot (cache miss).
    /// Additive key per BENCHMARKER_OPTIMIZER_CONTRACT.md.
    pub cache_misses: usize,
    pub per_question: Vec<LoCoMoReportPerQuestion>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Report builder
// ─────────────────────────────────────────────────────────────────────────────

/// Assembles a `LoCoMoReport` from run metadata, corpus statistics, and scores.
///
/// `results` carries the raw per-question results (including `cache_hit`) needed
/// to populate the `cache_hit` per-question field and the aggregate `cache_hits` /
/// `cache_misses` counts. `estate_cache` is the cache-mode string ("off" | "reuse").
///
/// Twin of Swift `buildLoCoMoReport(config:corpus:scores:results:estateCache:)`.
pub fn build_locomo_report(
    run_id: String,
    run_label: String,
    generated_at: String,
    encode_barrier: String,
    questions_loaded: usize,
    adversarial_excluded: usize,
    scores: &[LoCoMoQuestionScore],
    cache_hit_by_id: &std::collections::HashMap<String, Option<bool>>,
    estate_cache: String,
) -> LoCoMoReport {
    let (aggregate, categories, latency) = aggregate_locomo_scores(scores);
    let guard_excluded = scores.iter().filter(|s| !s.guard_healthy).count();
    let cache_hits:   usize = cache_hit_by_id.values().filter(|&&v| v == Some(true)).count();
    let cache_misses: usize = cache_hit_by_id.values().filter(|&&v| v == Some(false)).count();

    let corpus_stats = LoCoMoReportCorpusStats {
        questions_loaded,
        adversarial_excluded,
        questions_run: scores.len(),
        guard_excluded,
    };

    let report_aggregate = LoCoMoReportAggregate {
        query_count:      aggregate.query_count,
        recall_any_at_1:  aggregate.recall_any_at_1,
        recall_any_at_5:  aggregate.recall_any_at_5,
        recall_any_at_10: aggregate.recall_any_at_10,
        recall_all_at_1:  aggregate.recall_all_at_1,
        recall_all_at_5:  aggregate.recall_all_at_5,
        recall_all_at_10: aggregate.recall_all_at_10,
        mrr:              aggregate.mrr,
    };

    let category_breakdown: Vec<LoCoMoReportCategoryEntry> = categories
        .into_iter()
        .map(|c| LoCoMoReportCategoryEntry {
            label:          c.label,
            query_count:    c.query_count,
            recall_any_at_5: c.recall_any_at_5,
            recall_all_at_5: c.recall_all_at_5,
            mrr:            c.mrr,
        })
        .collect();

    let report_latency = LoCoMoReportLatency {
        query_p50_seconds:  latency.query_p50_seconds,
        query_p95_seconds:  latency.query_p95_seconds,
        query_mean_seconds: latency.query_mean_seconds,
        write_mean_seconds: latency.write_mean_seconds,
    };

    let per_question: Vec<LoCoMoReportPerQuestion> = scores
        .iter()
        .map(|s| LoCoMoReportPerQuestion {
            question_id:             s.question_id.clone(),
            category_label:          s.category_label.clone(),
            category:                s.category,
            turns_ingested:          s.turns_ingested,
            guard_healthy:           s.guard_healthy,
            guard_diagnostic:        s.guard_diagnostic.clone(),
            recall_any_at_1:         s.recall_any_at_1,
            recall_any_at_5:         s.recall_any_at_5,
            recall_any_at_10:        s.recall_any_at_10,
            recall_all_at_1:         s.recall_all_at_1,
            recall_all_at_5:         s.recall_all_at_5,
            recall_all_at_10:        s.recall_all_at_10,
            mrr:                     s.mrr,
            query_latency_seconds:   s.query_latency_seconds,
            write_mean_latency_seconds: s.write_mean_latency_seconds,
            ranked_dia_ids:          s.ranked_dia_ids.clone(),
            evidence_dia_ids:        s.evidence_dia_ids.clone(),
            retrieved_uuid_count:    s.retrieved_uuid_count,
            // Look up cache_hit from the raw results map (key = question_id).
            cache_hit: cache_hit_by_id.get(&s.question_id).copied().flatten(),
        })
        .collect();

    LoCoMoReport {
        run_id,
        run_label,
        generated_at,
        encode_barrier,
        corpus_stats,
        aggregate: report_aggregate,
        category_breakdown,
        latency: report_latency,
        estate_cache,
        cache_hits,
        cache_misses,
        per_question,
    }
}

/// Serializes and writes a `LoCoMoReport` to a JSON file (pretty-printed,
/// keys sorted for deterministic diffs).
///
/// Twin of Swift `writeLoCoMoReport(_:to:)`.
pub fn write_locomo_report(report: &LoCoMoReport, path: &std::path::Path) -> Result<(), String> {
    let json = serde_json::to_string_pretty(report)
        .map_err(|e| format!("report encode failed: {e}"))?;
    // Re-serialize through a sorted Value to match Swift JSONEncoder .sortedKeys.
    let value: serde_json::Value = serde_json::from_str(&json)
        .map_err(|e| format!("report re-parse failed: {e}"))?;
    let sorted = sorted_json_value(&value);
    let sorted_json = serde_json::to_string_pretty(&sorted)
        .map_err(|e| format!("sorted report encode failed: {e}"))?;
    std::fs::write(path, sorted_json.as_bytes())
        .map_err(|e| format!("report write failed: {e}"))
}

/// Recursively sorts JSON object keys (matching JSONEncoder `.sortedKeys`).
/// Same algorithm as the one in longmemeval_scorer.rs.
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
