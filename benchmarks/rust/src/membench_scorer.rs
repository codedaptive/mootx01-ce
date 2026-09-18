//! membench_scorer.rs — MemBench per-item recall scoring (Rust twin of `MemBenchScorer.swift`).
//!
//! The core scoring math (`lme_ranked_sessions`, `lme_recall_any`, `lme_recall_all`,
//! `lme_session_mrr`, `lme_percentile`) is IDENTICAL to `longmemeval_scorer.rs` —
//! those functions are string-agnostic and work identically with global sids
//! (e.g. "119") in place of session_ids.
//!
//! # What this file adds
//!
//! 1. `MemBenchManifestEntry` / `MemBenchItemResult` — the runner's output types.
//! 2. `membench_manifest_as_lme()` — bridges MemBench manifest entries to the
//!    `LmeManifestEntry` form so `lme_ranked_sessions` can map UUID → global sid.
//! 3. `score_membench_item()` — thin wrapper calling the LME math with MemBench types.
//! 4. `aggregate_membench_scores()` — per-category breakdown.
//! 5. JSON report types and `build_membench_report()` / `write_membench_report()`.

use crate::longmemeval_scorer::{
    lme_parse_result_count, lme_percentile, lme_ranked_sessions, lme_recall_all, lme_recall_any,
    lme_session_mrr, LmeManifestEntry,
};
use crate::longmemeval_token_efficiency::lme_estimate_tokens;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::Path;

// ─────────────────────────────────────────────────────────────────────────────
// Manifest and per-item result (produced by membench_runner)
// ─────────────────────────────────────────────────────────────────────────────

/// Maps a filed-memory UUID back to its origin turn in a MemBench item.
///
/// Twin of Swift `MemBenchManifestEntry`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MemBenchManifestEntry {
    /// UUID returned by moot_file_memory ("filed memory <UUID>").
    pub uuid: String,
    /// Global sid of the turn (matches the turn's `sid` field, as a string).
    pub sid: String,
    /// 0-based session index this turn belongs to.
    pub session_index: usize,
}

/// The result of ingesting one MemBench item and querying its QA question.
/// Produced by `membench_runner::run_membench_items`; consumed by `score_membench_item`.
///
/// Twin of Swift `MemBenchItemResult`.
#[derive(Debug)]
pub struct MemBenchItemResult {
    /// Synthetic item identifier (e.g. "FirstAgent/simple/roles/0").
    pub item_id: String,
    /// Category label (e.g. "simple", "noisy").
    pub category: String,
    /// The question text that was queried.
    pub question: String,
    /// Time taken for the moot_memory_search call, in seconds.
    pub query_latency_seconds: f64,
    /// UUIDs returned by moot_memory_search, in ranked order.
    pub retrieved_uuids: Vec<String>,
    /// Manifest mapping UUID → sid for every ingested turn in this item's estate.
    pub manifest: Vec<MemBenchManifestEntry>,
    /// Ground-truth global sids for this item's question.
    pub evidence_sids: Vec<String>,
    /// True when the DegeneracyGuard classified the backend as healthy.
    pub guard_healthy: bool,
    /// If the guard was unhealthy, the diagnostic message.
    pub guard_diagnostic: Option<String>,
    /// Guard sampling policy active for this leg. Mirrors Swift `MemBenchItemResult.guardSamplingMode`.
    pub guard_sampling_mode: crate::degeneracy_guard::GuardSamplingPolicy,
    /// Total turns ingested into this item's estate.
    pub turns_ingested: usize,
    /// Mean write latency across all turns for this item.
    pub write_mean_latency_seconds: f64,
    /// Raw payload text from the MCP response. None when absent.
    pub payload_text: Option<String>,
    // C9: multiple-choice arm — carried through from the corpus loader so the
    // scorer can apply select_multiple_choice_prediction without a corpus lookup
    // at score time.
    /// 4-way balanced answer choices keyed A/B/C/D.
    pub choices: HashMap<String, String>,
    /// Correct letter (A/B/C/D) for this item's MC question.
    pub ground_truth: String,
}

// ─────────────────────────────────────────────────────────────────────────────
// Manifest bridge
// ─────────────────────────────────────────────────────────────────────────────

/// Converts `MemBenchManifestEntry` list to the `LmeManifestEntry` form that
/// `lme_ranked_sessions` expects. The `session_id` field carries the global sid
/// string so `lme_ranked_sessions` maps UUID → sid correctly.
///
/// Twin of Swift `memBenchManifestAsLME(_:)`.
fn membench_manifest_as_lme(entries: &[MemBenchManifestEntry]) -> Vec<LmeManifestEntry> {
    entries
        .iter()
        .map(|e| LmeManifestEntry {
            uuid: e.uuid.clone(),
            session_id: e.sid.clone(), // global sid stands in for session_id
            turn_index: 0,             // MemBench items score at the turn level
            session_index: e.session_index,
            role: "turn".to_string(),  // generic role
        })
        .collect()
}

// ─────────────────────────────────────────────────────────────────────────────
// C9 — multiple-choice arm
// ─────────────────────────────────────────────────────────────────────────────

/// Scans choices A→B→C→D and returns the first letter whose option text appears
/// as a case-insensitive substring in `payload_text`. Returns `None` when the
/// payload is absent/empty or no option text matches.
///
/// The selection rule is deterministic given fixed retrieval output: A→D scan
/// order, case-insensitive substring match, first match wins. A `None` result
/// scores 0 in the aggregate.
///
/// Twin of Swift `selectMultipleChoicePrediction(from:choices:)`.
pub fn select_multiple_choice_prediction(
    payload_text: Option<&str>,
    choices: &HashMap<String, String>,
) -> Option<String> {
    let payload = payload_text.filter(|s| !s.is_empty())?;
    let payload_lower = payload.to_lowercase();
    for letter in &["A", "B", "C", "D"] {
        if let Some(option_text) = choices.get(*letter) {
            if !option_text.is_empty()
                && payload_lower.contains(&option_text.to_lowercase())
            {
                return Some(letter.to_string());
            }
        }
    }
    None
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-item score
// ─────────────────────────────────────────────────────────────────────────────

/// The scored result for one MemBench item.
/// Guard-excluded items have all recall/MRR metrics set to 0.0 and are
/// excluded from aggregate scoring.
///
/// Twin of Swift `MemBenchItemScore`.
#[derive(Debug, Clone)]
pub struct MemBenchItemScore {
    pub item_id: String,
    pub category: String,
    pub guard_healthy: bool,
    pub guard_diagnostic: Option<String>,
    pub recall_any_at_1: f64,
    pub recall_any_at_5: f64,
    pub recall_any_at_10: f64,
    pub recall_all_at_1: f64,
    pub recall_all_at_5: f64,
    pub recall_all_at_10: f64,
    pub mrr: f64,
    /// Deduplicated global sid ranking (first-UUID-appearance order).
    pub ranked_sids: Vec<String>,
    /// Ground-truth global sids for this item.
    pub evidence_sids: Vec<String>,
    pub query_latency_seconds: f64,
    pub write_mean_latency_seconds: f64,
    pub turns_ingested: usize,
    pub retrieved_uuid_count: usize,
    pub payload_text: Option<String>,
    // C9: multiple-choice arm
    /// Selected letter (A/B/C/D) from the MC scan; None when no match.
    pub multiple_choice_prediction: Option<String>,
    /// True when `multiple_choice_prediction` matches `ground_truth`.
    pub multiple_choice_correct: bool,
}

/// Scores one `MemBenchItemResult`. Guard-excluded items get zeroed recall/MRR.
///
/// Twin of Swift `scoreMemBenchItem(_:)`.
pub fn score_membench_item(result: MemBenchItemResult) -> MemBenchItemScore {
    let lme_manifest = membench_manifest_as_lme(&result.manifest);
    let ranked_sids = lme_ranked_sessions(&result.retrieved_uuids, &lme_manifest);
    let evidence_set: HashSet<String> = result.evidence_sids.iter().cloned().collect();

    let (recall_any_at_1, recall_any_at_5, recall_any_at_10,
         recall_all_at_1, recall_all_at_5, recall_all_at_10, mrr) = if result.guard_healthy {
        (
            lme_recall_any(&ranked_sids, &evidence_set, 1),
            lme_recall_any(&ranked_sids, &evidence_set, 5),
            lme_recall_any(&ranked_sids, &evidence_set, 10),
            lme_recall_all(&ranked_sids, &evidence_set, 1),
            lme_recall_all(&ranked_sids, &evidence_set, 5),
            lme_recall_all(&ranked_sids, &evidence_set, 10),
            lme_session_mrr(&ranked_sids, &evidence_set),
        )
    } else {
        (0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    };

    let retrieved_uuid_count = result.retrieved_uuids.len();

    // C9: multiple-choice arm — scored always regardless of guard status.
    // MC only needs the payload; retrieval guard exclusion does not apply.
    let mc_prediction = select_multiple_choice_prediction(
        result.payload_text.as_deref(),
        &result.choices,
    );
    let mc_correct = mc_prediction
        .as_deref()
        .map(|p| p == result.ground_truth)
        .unwrap_or(false);

    MemBenchItemScore {
        item_id: result.item_id,
        category: result.category,
        guard_healthy: result.guard_healthy,
        guard_diagnostic: result.guard_diagnostic,
        recall_any_at_1,
        recall_any_at_5,
        recall_any_at_10,
        recall_all_at_1,
        recall_all_at_5,
        recall_all_at_10,
        mrr,
        ranked_sids,
        evidence_sids: result.evidence_sids,
        query_latency_seconds: result.query_latency_seconds,
        write_mean_latency_seconds: result.write_mean_latency_seconds,
        turns_ingested: result.turns_ingested,
        retrieved_uuid_count,
        payload_text: result.payload_text,
        multiple_choice_prediction: mc_prediction,
        multiple_choice_correct: mc_correct,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Aggregate metrics
// ─────────────────────────────────────────────────────────────────────────────

/// Aggregate MemBench retrieval metrics over guard-healthy items.
///
/// Twin of Swift `MemBenchAggregateMetrics`.
#[derive(Debug, Clone)]
pub struct MemBenchAggregateMetrics {
    pub query_count: usize,
    pub recall_any_at_1: f64,
    pub recall_any_at_5: f64,
    pub recall_any_at_10: f64,
    pub recall_all_at_1: f64,
    pub recall_all_at_5: f64,
    pub recall_all_at_10: f64,
    pub mrr: f64,
    /// C9: fraction of guard-healthy items with a correct MC prediction.
    pub multiple_choice_accuracy: f64,
}

/// Per-category breakdown. One entry per category label.
///
/// Twin of Swift `MemBenchCategoryBreakdown`.
#[derive(Debug, Clone)]
pub struct MemBenchCategoryBreakdown {
    pub label: String,
    pub query_count: usize,
    pub recall_any_at_5: f64,
    pub recall_all_at_5: f64,
    pub mrr: f64,
}

/// Latency statistics.
///
/// Twin of Swift `MemBenchLatencyStats`.
#[derive(Debug, Clone)]
pub struct MemBenchLatencyStats {
    pub query_p50_seconds: f64,
    pub query_p95_seconds: f64,
    pub query_mean_seconds: f64,
    pub write_mean_seconds: f64,
}

/// MemBench category labels in canonical paper order (LowLevel set).
pub const MEMBENCH_CATEGORY_LABELS: &[&str] = &[
    "simple",
    "comparative",
    "aggregative",
    "conditional",
    "knowledge_update",
    "post_processing",
    "noisy",
];

/// Computes aggregate metrics, per-category breakdown, and latency stats.
///
/// Twin of Swift `aggregateMemBenchScores(_:)`.
pub fn aggregate_membench_scores(
    scores: &[MemBenchItemScore],
) -> (
    MemBenchAggregateMetrics,
    Vec<MemBenchCategoryBreakdown>,
    MemBenchLatencyStats,
) {
    // ── Aggregate (guard-healthy only) ────────────────────────────────────────
    let healthy: Vec<&MemBenchItemScore> = scores.iter().filter(|s| s.guard_healthy).collect();
    let n = healthy.len() as f64;
    // C9: MC accuracy over guard-healthy items; nil predictions score 0.
    let mc_correct_count = healthy.iter().filter(|s| s.multiple_choice_correct).count() as f64;

    let aggregate = if healthy.is_empty() {
        MemBenchAggregateMetrics {
            query_count: 0,
            recall_any_at_1: 0.0,
            recall_any_at_5: 0.0,
            recall_any_at_10: 0.0,
            recall_all_at_1: 0.0,
            recall_all_at_5: 0.0,
            recall_all_at_10: 0.0,
            mrr: 0.0,
            multiple_choice_accuracy: 0.0,
        }
    } else {
        MemBenchAggregateMetrics {
            query_count: healthy.len(),
            recall_any_at_1:  healthy.iter().map(|s| s.recall_any_at_1).sum::<f64>() / n,
            recall_any_at_5:  healthy.iter().map(|s| s.recall_any_at_5).sum::<f64>() / n,
            recall_any_at_10: healthy.iter().map(|s| s.recall_any_at_10).sum::<f64>() / n,
            recall_all_at_1:  healthy.iter().map(|s| s.recall_all_at_1).sum::<f64>() / n,
            recall_all_at_5:  healthy.iter().map(|s| s.recall_all_at_5).sum::<f64>() / n,
            recall_all_at_10: healthy.iter().map(|s| s.recall_all_at_10).sum::<f64>() / n,
            mrr:              healthy.iter().map(|s| s.mrr).sum::<f64>() / n,
            multiple_choice_accuracy: mc_correct_count / n,
        }
    };

    // ── Per-category breakdown ────────────────────────────────────────────────
    // Build an ordered list: canonical labels first, then any extras.
    let mut ordered: Vec<String> = Vec::new();
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    for &label in MEMBENCH_CATEGORY_LABELS {
        if healthy.iter().any(|s| s.category == label) {
            ordered.push(label.to_string());
            seen.insert(label.to_string());
        }
    }
    for s in &healthy {
        if seen.insert(s.category.clone()) {
            ordered.push(s.category.clone());
        }
    }

    let categories: Vec<MemBenchCategoryBreakdown> = ordered
        .iter()
        .map(|label| {
            let cat_healthy: Vec<&&MemBenchItemScore> =
                healthy.iter().filter(|s| &s.category == label).collect();
            let cn = cat_healthy.len() as f64;
            if cat_healthy.is_empty() {
                return MemBenchCategoryBreakdown {
                    label: label.clone(),
                    query_count: 0,
                    recall_any_at_5: 0.0,
                    recall_all_at_5: 0.0,
                    mrr: 0.0,
                };
            }
            MemBenchCategoryBreakdown {
                label: label.clone(),
                query_count: cat_healthy.len(),
                recall_any_at_5: cat_healthy.iter().map(|s| s.recall_any_at_5).sum::<f64>() / cn,
                recall_all_at_5: cat_healthy.iter().map(|s| s.recall_all_at_5).sum::<f64>() / cn,
                mrr: cat_healthy.iter().map(|s| s.mrr).sum::<f64>() / cn,
            }
        })
        .collect();

    // ── Latency (all items) ────────────────────────────────────────────────────
    let query_latencies: Vec<f64> = scores.iter().map(|s| s.query_latency_seconds).collect();
    let write_latencies: Vec<f64> = scores.iter().map(|s| s.write_mean_latency_seconds).collect();
    let latency = MemBenchLatencyStats {
        query_p50_seconds: lme_percentile(&query_latencies, 0.50),
        query_p95_seconds: lme_percentile(&query_latencies, 0.95),
        query_mean_seconds: if query_latencies.is_empty() {
            0.0
        } else {
            query_latencies.iter().sum::<f64>() / query_latencies.len() as f64
        },
        write_mean_seconds: if write_latencies.is_empty() {
            0.0
        } else {
            write_latencies.iter().sum::<f64>() / write_latencies.len() as f64
        },
    };

    (aggregate, categories, latency)
}

// ─────────────────────────────────────────────────────────────────────────────
// JSON report types
// ─────────────────────────────────────────────────────────────────────────────

/// Corpus statistics block.
#[derive(Debug, Serialize, Deserialize)]
pub struct MemBenchReportCorpusStats {
    pub items_loaded: usize,
    pub items_skipped: usize,
    pub items_run: usize,
    pub guard_excluded: usize,
}

/// Aggregate metrics block. Uses the same recall_any_*/recall_all_*/mrr/query_count
/// naming as LME and LoCoMo reports for optimizer compatibility.
#[derive(Debug, Serialize, Deserialize)]
pub struct MemBenchReportAggregate {
    pub query_count: usize,
    pub recall_any_at_1: f64,
    pub recall_any_at_5: f64,
    pub recall_any_at_10: f64,
    pub recall_all_at_1: f64,
    pub recall_all_at_5: f64,
    pub recall_all_at_10: f64,
    pub mrr: f64,
    /// C9: fraction of guard-healthy items with a correct MC letter.
    pub multiple_choice_accuracy: f64,
}

/// Per-category breakdown entry.
#[derive(Debug, Serialize, Deserialize)]
pub struct MemBenchReportCategoryEntry {
    pub label: String,
    pub query_count: usize,
    pub recall_any_at_5: f64,
    pub recall_all_at_5: f64,
    pub mrr: f64,
}

/// Latency statistics block.
#[derive(Debug, Serialize, Deserialize, Default)]
pub struct MemBenchReportLatency {
    pub query_p50_seconds: f64,
    pub query_p95_seconds: f64,
    pub query_mean_seconds: f64,
    pub write_mean_seconds: f64,
}

/// Per-item entry in the report.
#[derive(Debug, Serialize, Deserialize)]
pub struct MemBenchReportPerItem {
    pub item_id: String,
    pub category: String,
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
    /// Query latency kept internally; not emitted in accuracy-lane JSON (2026-08-18 doctrine).
    #[serde(skip_serializing)]
    #[serde(default)]
    pub query_latency_seconds: f64,
    /// Write latency kept internally; not emitted in accuracy-lane JSON (2026-08-18 doctrine).
    #[serde(skip_serializing)]
    #[serde(default)]
    pub write_mean_latency_seconds: f64,
    pub ranked_sids: Vec<String>,
    pub evidence_sids: Vec<String>,
    pub retrieved_uuid_count: usize,
    pub tokens_per_result: Option<f64>,
    pub payload_text: Option<String>,
    // C9: multiple-choice arm fields — always present, nil prediction = no match.
    pub multiple_choice_prediction: Option<String>,
    pub multiple_choice_correct: bool,
}

/// The full MemBench run report.
#[derive(Debug, Serialize, Deserialize)]
pub struct MemBenchReport {
    /// The estate schema the harness was built against, stamped into every
    /// report so the results record can carry the column without anyone typing
    /// it (BENCHMARK_PROTOCOL §9). Twin of Swift `estateSchemaVersion`.
    pub estate_schema_version: String,
    pub run_id: String,
    pub run_label: String,
    pub generated_at: String,
    pub corpus_stats: MemBenchReportCorpusStats,
    pub aggregate: MemBenchReportAggregate,
    pub category_breakdown: Vec<MemBenchReportCategoryEntry>,
    /// Latency stats kept internally for console output; not emitted in accuracy-lane JSON (2026-08-18 doctrine).
    #[serde(skip_serializing)]
    #[serde(default)]
    pub latency: MemBenchReportLatency,
    pub per_item: Vec<MemBenchReportPerItem>,
    pub encode_barrier: String,
    /// Guard probe sampling policy for the leg ("once" or "per-unit", C5).
    pub guard_sampling: String,
    pub estate_encryption: String,
    pub agent: String,
    pub categories_included: Option<Vec<String>>,
    pub category_filter: Option<String>,
    // MARK: Binary identity (additive — JB-01, slimmed 2026-08-18 doctrine)
    /// Binary and protocol identity captured at run start. Accuracy lane emits
    /// only the three identity fields; full machine profile is the timing lane's concern.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "run_environment")]
    pub identity_environment: Option<crate::run_environment::IdentityEnvironment>,
    /// Storage backend shape used for scratch estates: "disk" (SQLite) or "ram" (InMemory, C1).
    pub shape: String,
    /// Internal only — never emitted: a run is a run; width is not a
    /// property of accuracy figures.
    #[serde(skip_serializing)]
    #[serde(default)]
    pub parallel_units: usize,
    // MARK: Timing report (additive — C4, not emitted in accuracy lane 2026-08-18)
    /// Timing report kept for console output; not emitted in accuracy-lane JSON
    /// (2026-08-18 doctrine). Full timing data lives in the timing lane only.
    #[serde(skip_serializing)]
    #[serde(default)]
    pub timing_report: Option<String>,
    /// Labels the once-per-leg sampling strategy. Not emitted in accuracy-lane JSON
    /// (2026-08-18 doctrine).
    #[serde(skip_serializing)]
    #[serde(default)]
    pub timing_sampling: String,
    // C10: Shape 3 protocol-deviation labels. Always present in new reports;
    // absent in pre-C10 reports (missing JSON key decodes to None for backwards
    // compatibility with old report files).
    /// "per-item" (default Shape 1 protocol) or "consolidated-shape3".
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "estate_shape")]
    pub estate_shape: Option<String>,
    /// True when this run departs from the published per-item MemBench protocol.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "protocol_deviation")]
    pub protocol_deviation: Option<bool>,
    /// Shape 3: number of consolidated groups.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "shape_3_group_count")]
    pub shape3_group_count: Option<usize>,
    /// Shape 3: conflict key type used for grouping (always "question-text").
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "shape_3_conflict_key_type")]
    pub shape3_conflict_key_type: Option<String>,
    /// Shape 3: count of unique conflict key values across all run items.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "shape_3_unique_keys")]
    pub shape3_unique_keys: Option<usize>,
    /// Shape 3: item count in each group (index = group index).
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "shape_3_items_per_group")]
    pub shape3_items_per_group: Option<Vec<usize>>,

    // C11: Capacity tier fields. All absent in baseline mode; present when a
    // non-baseline tier is specified. Never claim target as achieved.
    /// Capacity tier label: "10k" or "100k". Absent in baseline mode.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "capacity_tier")]
    pub capacity_tier: Option<String>,
    /// Target token budget for the tier.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "capacity_target_tokens")]
    pub capacity_target_tokens: Option<usize>,
    /// p50 of achieved tokens across all items (token estimate of estate content at query time).
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "capacity_achieved_tokens_p50")]
    pub capacity_achieved_tokens_p50: Option<usize>,
    /// Maximum achieved tokens across all items.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "capacity_achieved_tokens_max")]
    pub capacity_achieved_tokens_max: Option<usize>,
    /// Achieved token count per item (one entry per scored item, in run order).
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "capacity_achieved_tokens_per_item")]
    pub capacity_achieved_tokens_per_item: Option<Vec<usize>>,
    /// Number of items (the measured item plus its conflict-free fillers)
    /// contributing sessions to each estate (one entry per item, run order).
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "capacity_items_per_estate")]
    pub capacity_items_per_estate: Option<Vec<usize>>,
    /// Number of items whose achieved tokens fell short of the target. Absent when zero.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "capacity_shortfall_items")]
    pub capacity_shortfall_items: Option<usize>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Report builder
// ─────────────────────────────────────────────────────────────────────────────

/// Configuration snapshot for the report (passed in from the runner).
pub struct MemBenchReportConfig<'a> {
    pub run_label: &'a str,
    pub encode_barrier: &'a str,
    pub guard_sampling: &'a str,
    pub estate_encryption: &'a str,
    pub agent: &'a str,
    pub categories_included: Option<Vec<String>>,
    pub category_filter: Option<String>,
    pub items_loaded: usize,
    pub items_skipped: usize,
    /// Binary identity captured once at subcommand start (JB-01, slimmed 2026-08-18).
    pub run_environment: Option<crate::run_environment::IdentityEnvironment>,
    /// Storage backend shape string for the report (C1): "disk" or "ram".
    pub shape: &'a str,
    /// Number of concurrent items for this leg (C6). 1 = serial.
    pub parallel_units: usize,
    /// C4: verbatim moot_timing_report text from the first settled estate.
    /// None when no item reached a settle point (every unit cache-hit).
    pub timing_report: Option<String>,
    // C10: Shape 3 deviation metadata. None = per-item mode (no deviation).
    /// Item count per group (index = group index). None → per-item mode.
    pub shape3_items_per_group: Option<Vec<usize>>,
    /// Count of unique conflict key values across all run items.
    /// None → per-item mode.
    pub shape3_unique_keys: Option<usize>,
    // C11: Capacity tier. Baseline is a no-op (fields absent from report).
    pub capacity_tier: crate::membench_runner::CapacityTier,
    /// Achieved token counts per item; populated only for non-baseline tiers.
    pub capacity_achieved_tokens: Option<Vec<usize>>,
    /// Item counts per estate; populated only for non-baseline tiers.
    pub capacity_items_per_estate: Option<Vec<usize>>,
}

/// Assembles a `MemBenchReport` from a config snapshot and scored results.
///
/// Twin of Swift `buildMemBenchReport(config:corpus:results:scores:)`.
pub fn build_membench_report(
    cfg: &MemBenchReportConfig<'_>,
    scores: &[MemBenchItemScore],
) -> MemBenchReport {
    let (agg, cats, lat) = aggregate_membench_scores(scores);
    let guard_excluded = scores.iter().filter(|s| !s.guard_healthy).count();

    let corpus_stats = MemBenchReportCorpusStats {
        items_loaded: cfg.items_loaded,
        items_skipped: cfg.items_skipped,
        items_run: scores.len(),
        guard_excluded,
    };

    let aggregate = MemBenchReportAggregate {
        query_count: agg.query_count,
        recall_any_at_1: agg.recall_any_at_1,
        recall_any_at_5: agg.recall_any_at_5,
        recall_any_at_10: agg.recall_any_at_10,
        recall_all_at_1: agg.recall_all_at_1,
        recall_all_at_5: agg.recall_all_at_5,
        recall_all_at_10: agg.recall_all_at_10,
        mrr: agg.mrr,
        multiple_choice_accuracy: agg.multiple_choice_accuracy,
    };

    let category_breakdown = cats
        .iter()
        .map(|c| MemBenchReportCategoryEntry {
            label: c.label.clone(),
            query_count: c.query_count,
            recall_any_at_5: c.recall_any_at_5,
            recall_all_at_5: c.recall_all_at_5,
            mrr: c.mrr,
        })
        .collect();

    let latency = MemBenchReportLatency {
        query_p50_seconds: lat.query_p50_seconds,
        query_p95_seconds: lat.query_p95_seconds,
        query_mean_seconds: lat.query_mean_seconds,
        write_mean_seconds: lat.write_mean_seconds,
    };

    let per_item = scores
        .iter()
        .map(|score| {
            let tpr = score.payload_text.as_deref().and_then(|text| {
                lme_parse_result_count(text).filter(|&n| n > 0).map(|n| {
                    lme_estimate_tokens(text) as f64 / n as f64
                })
            });
            MemBenchReportPerItem {
                item_id: score.item_id.clone(),
                category: score.category.clone(),
                turns_ingested: score.turns_ingested,
                guard_healthy: score.guard_healthy,
                guard_diagnostic: score.guard_diagnostic.clone(),
                recall_any_at_1: score.recall_any_at_1,
                recall_any_at_5: score.recall_any_at_5,
                recall_any_at_10: score.recall_any_at_10,
                recall_all_at_1: score.recall_all_at_1,
                recall_all_at_5: score.recall_all_at_5,
                recall_all_at_10: score.recall_all_at_10,
                mrr: score.mrr,
                query_latency_seconds: score.query_latency_seconds,
                write_mean_latency_seconds: score.write_mean_latency_seconds,
                ranked_sids: score.ranked_sids.clone(),
                evidence_sids: score.evidence_sids.clone(),
                retrieved_uuid_count: score.retrieved_uuid_count,
                tokens_per_result: tpr,
                payload_text: score.payload_text.clone(),
                multiple_choice_prediction: score.multiple_choice_prediction.clone(),
                multiple_choice_correct: score.multiple_choice_correct,
            }
        })
        .collect();

    // C10: Shape 3 protocol-deviation labels.
    // Consolidated mode: labels every figure as departing from the per-item protocol.
    // C11: Capacity tier mode: labels with per-item-capacity-{N} + protocol_deviation.
    // Per-item mode: records "per-item" + false so the field is always present in
    // new reports (missing = old pre-C10 report, decoded as None).
    let (estate_shape, protocol_deviation, shape3_group_count,
         shape3_conflict_key_type, shape3_unique_keys, shape3_items_per_group) =
        if let Some(ref per_group) = cfg.shape3_items_per_group {
            // Shape 3 consolidated mode.
            (
                Some("consolidated-shape3".to_string()),
                Some(true),
                Some(per_group.len()),
                Some("question-text".to_string()),
                cfg.shape3_unique_keys,
                Some(per_group.clone()),
            )
        } else if let Some(label) = cfg.capacity_tier.estate_shape_label() {
            // C11 capacity tier mode — per-item-capacity-10k / per-item-capacity-100k.
            (Some(label.to_string()), Some(true), None, None, None, None)
        } else {
            // Baseline per-item mode.
            (Some("per-item".to_string()), Some(false), None, None, None, None)
        };

    // C11: Capacity tier report fields. Absent in baseline mode.
    let (capacity_tier_label, capacity_target_tokens,
         capacity_achieved_tokens_p50, capacity_achieved_tokens_max,
         capacity_achieved_tokens_per_item, capacity_items_per_estate,
         capacity_shortfall_items) =
        if let Some(target) = cfg.capacity_tier.target_tokens() {
            let tier_label = Some(cfg.capacity_tier.report_label().to_string());
            let (p50, max, shortfall, per_item_tokens) =
                if let Some(ref tokens) = cfg.capacity_achieved_tokens {
                    let p50 = if tokens.is_empty() { None } else {
                        let mut sorted = tokens.clone();
                        sorted.sort_unstable();
                        let idx = (sorted.len().saturating_sub(1)) / 2;
                        Some(sorted[idx])
                    };
                    let max = tokens.iter().copied().max();
                    let shortfall_count = tokens.iter().filter(|&&t| t < target).count();
                    let shortfall = if shortfall_count > 0 { Some(shortfall_count) } else { None };
                    (p50, max, shortfall, Some(tokens.clone()))
                } else {
                    (None, None, None, None)
                };
            (
                tier_label,
                Some(target),
                p50,
                max,
                per_item_tokens,
                cfg.capacity_items_per_estate.clone(),
                shortfall,
            )
        } else {
            (None, None, None, None, None, None, None)
        };

    MemBenchReport {
        estate_schema_version: crate::artifact_manifest::CURRENT_ESTATE_SCHEMA_VERSION.to_string(),
        run_id: uuid_v4_hex(),
        run_label: cfg.run_label.to_string(),
        generated_at: chrono_now_iso8601(),
        corpus_stats,
        aggregate,
        category_breakdown,
        latency,
        per_item,
        encode_barrier: cfg.encode_barrier.to_string(),
        guard_sampling: cfg.guard_sampling.to_string(),
        estate_encryption: cfg.estate_encryption.to_string(),
        agent: cfg.agent.to_string(),
        categories_included: cfg.categories_included.clone(),
        category_filter: cfg.category_filter.clone(),
        identity_environment: cfg.run_environment.clone(),
        shape: cfg.shape.to_string(),
        parallel_units: cfg.parallel_units,
        timing_report: cfg.timing_report.clone(),
        timing_sampling: "once-per-leg".to_string(),
        estate_shape,
        protocol_deviation,
        shape3_group_count,
        shape3_conflict_key_type,
        shape3_unique_keys,
        shape3_items_per_group,
        capacity_tier: capacity_tier_label,
        capacity_target_tokens,
        capacity_achieved_tokens_p50,
        capacity_achieved_tokens_max,
        capacity_achieved_tokens_per_item,
        capacity_items_per_estate,
        capacity_shortfall_items,
    }
}

/// Encodes and writes a `MemBenchReport` to a JSON file.
///
/// Twin of Swift `writeMemBenchReport(_:to:)`.
pub fn write_membench_report(report: &MemBenchReport, path: &Path) -> Result<(), String> {
    let json = serde_json::to_string_pretty(report)
        .map_err(|e| format!("MemBench report encode error: {e}"))?;
    // Records are never overwritten (2026-08-17).
    crate::record_writer::write_record_never_overwrite(json.as_bytes(), path)
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers — shared with other scorers in this crate
// ─────────────────────────────────────────────────────────────────────────────

/// Generates a UUID-like hex string using the system time as entropy.
/// Not cryptographically strong — only used for run_id values in reports.
fn uuid_v4_hex() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .subsec_nanos();
    format!("{:08x}-{:04x}-4{:03x}-{:04x}-{:012x}",
        nanos, nanos >> 16, nanos & 0xFFF, nanos >> 4 & 0x3FFF | 0x8000,
        nanos as u64 * 1_000_000_003)
}

/// Returns the current time as an ISO8601 string (UTC seconds precision).
/// Mirrors Swift's `ISO8601DateFormatter` output.
fn chrono_now_iso8601() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    // Manual ISO8601: seconds are fine for report timestamps.
    let s = secs % 60;
    let m = (secs / 60) % 60;
    let h = (secs / 3600) % 24;
    let days = secs / 86400;
    // Days since 1970-01-01: convert to Y-M-D using the proleptic Gregorian calendar.
    let (y, mo, d) = days_to_ymd(days as i64);
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{m:02}:{s:02}Z")
}

/// Converts days since the Unix epoch to (year, month, day).
/// Uses the algorithm from RFC 3339 / civil time.
fn days_to_ymd(z: i64) -> (i64, i64, i64) {
    let z = z + 719468;
    let era = (if z >= 0 { z } else { z - 146096 }) / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let mo = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if mo <= 2 { y + 1 } else { y };
    (y, mo, d)
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(uuid: &str, sid: &str) -> MemBenchManifestEntry {
        MemBenchManifestEntry {
            uuid: uuid.to_string(),
            sid: sid.to_string(),
            session_index: 0,
        }
    }

    fn make_result(
        item_id: &str,
        category: &str,
        retrieved: Vec<&str>,
        manifest: Vec<MemBenchManifestEntry>,
        evidence: Vec<&str>,
        guard_healthy: bool,
    ) -> MemBenchItemResult {
        MemBenchItemResult {
            item_id: item_id.to_string(),
            category: category.to_string(),
            question: "test?".to_string(),
            guard_sampling_mode: crate::degeneracy_guard::GuardSamplingPolicy::OncePerLeg,
            query_latency_seconds: 0.05,
            retrieved_uuids: retrieved.into_iter().map(String::from).collect(),
            manifest,
            evidence_sids: evidence.into_iter().map(String::from).collect(),
            guard_healthy,
            guard_diagnostic: if guard_healthy { None } else { Some("degenerate".to_string()) },
            turns_ingested: 3,
            write_mean_latency_seconds: 0.01,
            payload_text: None,
            // C9 fields default to no choices; existing tests don't exercise the MC arm.
            choices: HashMap::new(),
            ground_truth: String::new(),
        }
    }

    #[test]
    fn test_exact_match() {
        let manifest = vec![entry("uuid-A", "5")];
        let result = make_result("simple/roles/0", "simple", vec!["uuid-A"], manifest, vec!["5"], true);
        let score = score_membench_item(result);
        assert!((score.recall_any_at_1 - 1.0).abs() < 1e-9);
        assert!((score.mrr - 1.0).abs() < 1e-9);
    }

    #[test]
    fn test_miss() {
        let manifest = vec![entry("uuid-A", "1"), entry("uuid-B", "2")];
        let result = make_result("simple/roles/0", "simple", vec!["uuid-A", "uuid-B"], manifest, vec!["99"], true);
        let score = score_membench_item(result);
        assert!((score.recall_any_at_10 - 0.0).abs() < 1e-9);
        assert!((score.mrr - 0.0).abs() < 1e-9);
    }

    #[test]
    fn test_guard_excluded_zeroed() {
        let manifest = vec![entry("uuid-A", "5")];
        let result = make_result("simple/roles/0", "simple", vec!["uuid-A"], manifest, vec!["5"], false);
        let score = score_membench_item(result);
        assert!(!score.guard_healthy);
        assert!((score.recall_any_at_1 - 0.0).abs() < 1e-9);
        assert!((score.mrr - 0.0).abs() < 1e-9);
    }

    #[test]
    fn test_aggregate_two_items() {
        let m = vec![entry("uuid-A", "1")];
        let r1 = make_result("a", "simple", vec!["uuid-A"], m.clone(), vec!["1"], true);
        let r2 = make_result("b", "simple", vec![], vec![], vec!["1"], true);
        let scores: Vec<MemBenchItemScore> = vec![r1, r2].into_iter().map(score_membench_item).collect();
        let (agg, _, _) = aggregate_membench_scores(&scores);
        assert_eq!(agg.query_count, 2);
        assert!((agg.recall_any_at_5 - 0.5).abs() < 1e-9);
    }

    #[test]
    fn test_guard_excluded_dropped_from_aggregate() {
        let m = vec![entry("uuid-A", "1")];
        let healthy = make_result("a", "simple", vec!["uuid-A"], m.clone(), vec!["1"], true);
        let unhealthy = make_result("b", "simple", vec![], vec![], vec!["1"], false);
        let scores: Vec<MemBenchItemScore> = vec![healthy, unhealthy].into_iter().map(score_membench_item).collect();
        let (agg, _, _) = aggregate_membench_scores(&scores);
        // Only 1 healthy item; unhealthy excluded from denominator.
        assert_eq!(agg.query_count, 1);
    }

    #[test]
    fn test_category_breakdown_order() {
        let m = vec![entry("uuid-A", "1")];
        let noisy = make_result("a", "noisy", vec!["uuid-A"], m.clone(), vec!["1"], true);
        let simple = make_result("b", "simple", vec!["uuid-A"], m.clone(), vec!["1"], true);
        let scores: Vec<MemBenchItemScore> = vec![noisy, simple].into_iter().map(score_membench_item).collect();
        let (_, cats, _) = aggregate_membench_scores(&scores);
        let labels: Vec<&str> = cats.iter().map(|c| c.label.as_str()).collect();
        let si = labels.iter().position(|&l| l == "simple").unwrap();
        let ni = labels.iter().position(|&l| l == "noisy").unwrap();
        assert!(si < ni, "simple should precede noisy in canonical order");
    }

    #[test]
    fn test_report_round_trip() {
        let m = vec![entry("uuid-A", "0")];
        let result = make_result("simple/roles/0", "simple", vec!["uuid-A"], m, vec!["0"], true);
        let scores = vec![score_membench_item(result)];
        let cfg = MemBenchReportConfig {
            run_label: "membench-firstagent-seed20260806",
            encode_barrier: "drain",
            guard_sampling: "once",
            estate_encryption: "plaintext-optout",
            agent: "FirstAgent",
            categories_included: Some(vec!["simple".to_string()]),
            category_filter: None,
            items_loaded: 1,
            items_skipped: 0,
            run_environment: None,
            shape: "disk",
            parallel_units: 1,
            timing_report: None,
            // C10: per-item mode (no Shape 3 deviation).
            shape3_items_per_group: None,
            shape3_unique_keys: None,
            // C11: baseline (no capacity tier).
            capacity_tier: crate::membench_runner::CapacityTier::Baseline,
            capacity_achieved_tokens: None,
            capacity_items_per_estate: None,
        };
        let report = build_membench_report(&cfg, &scores);
        // Round-trip through JSON.
        let json = serde_json::to_string(&report).unwrap();
        let decoded: MemBenchReport = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.run_label, "membench-firstagent-seed20260806");
        assert_eq!(decoded.agent, "FirstAgent");
        assert_eq!(decoded.aggregate.query_count, 1);
        assert_eq!(decoded.per_item.len(), 1);
        assert_eq!(decoded.per_item[0].item_id, "simple/roles/0");
        // C1 round-trips; parallel_units is internal-only (never serialized),
        // so a decode lands on the numeric default.
        assert_eq!(decoded.shape, "disk");
        assert_eq!(decoded.parallel_units, 0);
        // C9: MC fields present (default empty choices → nil prediction, false correct).
        assert_eq!(decoded.per_item[0].multiple_choice_prediction, None);
        assert!(!decoded.per_item[0].multiple_choice_correct);
        assert!((decoded.aggregate.multiple_choice_accuracy - 0.0).abs() < 1e-9);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // C9 — multiple-choice arm
    // ─────────────────────────────────────────────────────────────────────────

    fn choices_portland() -> HashMap<String, String> {
        let mut m = HashMap::new();
        m.insert("A".to_string(), "Portland".to_string());
        m.insert("B".to_string(), "Seattle".to_string());
        m.insert("C".to_string(), "Denver".to_string());
        m.insert("D".to_string(), "Austin".to_string());
        m
    }

    #[test]
    fn c9_payload_matching_option_returns_letter() {
        let pred = select_multiple_choice_prediction(
            Some("The event is in Portland this summer."),
            &choices_portland(),
        );
        assert_eq!(pred.as_deref(), Some("A"));
    }

    #[test]
    fn c9_match_is_case_insensitive() {
        let pred = select_multiple_choice_prediction(
            Some("Confirmed venue: PORTLAND, Oregon."),
            &choices_portland(),
        );
        assert_eq!(pred.as_deref(), Some("A"));
    }

    #[test]
    fn c9_nil_payload_returns_none() {
        let pred = select_multiple_choice_prediction(None, &choices_portland());
        assert_eq!(pred, None);
    }

    #[test]
    fn c9_empty_payload_returns_none() {
        let pred = select_multiple_choice_prediction(Some(""), &choices_portland());
        assert_eq!(pred, None);
    }

    #[test]
    fn c9_no_match_returns_none() {
        let pred = select_multiple_choice_prediction(
            Some("The event is in New York City."),
            &choices_portland(),
        );
        assert_eq!(pred, None);
    }

    #[test]
    fn c9_first_match_wins() {
        // B ("dog") appears before C ("bird") in the payload; A ("cat") absent.
        let mut choices = HashMap::new();
        choices.insert("A".to_string(), "cat".to_string());
        choices.insert("B".to_string(), "dog".to_string());
        choices.insert("C".to_string(), "bird".to_string());
        choices.insert("D".to_string(), "fish".to_string());
        let pred = select_multiple_choice_prediction(
            Some("There is a dog and a bird here."),
            &choices,
        );
        assert_eq!(pred.as_deref(), Some("B"), "B is reached first in A→D scan order");
    }

    #[test]
    fn c9_correct_prediction_sets_mc_correct_true() {
        let mut result = make_result("a", "simple", vec![], vec![], vec![], true);
        result.payload_text = Some("The event will be held in Portland.".to_string());
        result.choices = choices_portland();
        result.ground_truth = "A".to_string();
        let score = score_membench_item(result);
        assert_eq!(score.multiple_choice_prediction.as_deref(), Some("A"));
        assert!(score.multiple_choice_correct);
    }

    #[test]
    fn c9_wrong_prediction_sets_mc_correct_false() {
        let mut result = make_result("a", "simple", vec![], vec![], vec![], true);
        result.payload_text = Some("The event will be held in Portland.".to_string());
        result.choices = choices_portland();
        result.ground_truth = "B".to_string(); // correct is B but payload matches A
        let score = score_membench_item(result);
        assert_eq!(score.multiple_choice_prediction.as_deref(), Some("A"));
        assert!(!score.multiple_choice_correct);
    }

    #[test]
    fn c9_nil_prediction_sets_mc_correct_false() {
        let mut result = make_result("a", "simple", vec![], vec![], vec![], true);
        result.payload_text = None; // no payload → nil prediction
        result.choices = choices_portland();
        result.ground_truth = "A".to_string();
        let score = score_membench_item(result);
        assert_eq!(score.multiple_choice_prediction, None);
        assert!(!score.multiple_choice_correct);
    }

    #[test]
    fn c9_aggregate_mc_accuracy_over_healthy_items() {
        let mut r1 = make_result("a", "simple", vec![], vec![], vec![], true);
        r1.payload_text = Some("I see a cat.".to_string());
        let mut choices = HashMap::new();
        choices.insert("A".to_string(), "cat".to_string());
        choices.insert("B".to_string(), "dog".to_string());
        choices.insert("C".to_string(), "bird".to_string());
        choices.insert("D".to_string(), "fish".to_string());
        r1.choices = choices.clone();
        r1.ground_truth = "A".to_string(); // correct

        let mut r2 = make_result("b", "simple", vec![], vec![], vec![], true);
        r2.payload_text = Some("I see a cat.".to_string());
        r2.choices = choices.clone();
        r2.ground_truth = "B".to_string(); // wrong (predicts A, correct is B)

        let mut r3 = make_result("c", "simple", vec![], vec![], vec![], false);
        r3.payload_text = Some("I see a cat.".to_string());
        r3.choices = choices.clone();
        r3.ground_truth = "A".to_string(); // guard-excluded

        let scores: Vec<MemBenchItemScore> = vec![r1, r2, r3]
            .into_iter()
            .map(score_membench_item)
            .collect();
        let (agg, _, _) = aggregate_membench_scores(&scores);
        // 1 correct out of 2 healthy → 0.5
        assert!(
            (agg.multiple_choice_accuracy - 0.5).abs() < 1e-9,
            "expected 0.5, got {}",
            agg.multiple_choice_accuracy
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // C10 — Shape 3 report fields
    // ─────────────────────────────────────────────────────────────────────────

    fn make_c10_cfg_per_item() -> MemBenchReportConfig<'static> {
        MemBenchReportConfig {
            run_label: "test-c10",
            encode_barrier: "drain",
            guard_sampling: "once",
            estate_encryption: "plaintext-optout",
            agent: "FirstAgent",
            categories_included: None,
            category_filter: None,
            items_loaded: 0,
            items_skipped: 0,
            run_environment: None,
            shape: "disk",
            parallel_units: 1,
            timing_report: None,
            shape3_items_per_group: None,
            shape3_unique_keys: None,
            capacity_tier: crate::membench_runner::CapacityTier::Baseline,
            capacity_achieved_tokens: None,
            capacity_items_per_estate: None,
        }
    }

    fn make_c10_cfg_consolidated(per_group: Vec<usize>, unique_keys: usize) -> MemBenchReportConfig<'static> {
        MemBenchReportConfig {
            run_label: "test-c10-consolidated",
            encode_barrier: "drain",
            guard_sampling: "once",
            estate_encryption: "plaintext-optout",
            agent: "FirstAgent",
            categories_included: None,
            category_filter: None,
            items_loaded: 0,
            items_skipped: 0,
            run_environment: None,
            shape: "disk",
            parallel_units: 1,
            timing_report: None,
            shape3_items_per_group: Some(per_group),
            shape3_unique_keys: Some(unique_keys),
            capacity_tier: crate::membench_runner::CapacityTier::Baseline,
            capacity_achieved_tokens: None,
            capacity_items_per_estate: None,
        }
    }

    #[test]
    fn c10_per_item_mode_labels_in_report() {
        let cfg = make_c10_cfg_per_item();
        let report = build_membench_report(&cfg, &[]);
        assert_eq!(report.estate_shape.as_deref(), Some("per-item"));
        assert_eq!(report.protocol_deviation, Some(false));
        assert!(report.shape3_group_count.is_none());
        assert!(report.shape3_conflict_key_type.is_none());
        assert!(report.shape3_unique_keys.is_none());
        assert!(report.shape3_items_per_group.is_none());
    }

    #[test]
    fn c10_consolidated_mode_labels_in_report() {
        let cfg = make_c10_cfg_consolidated(vec![3, 1], 2);
        let report = build_membench_report(&cfg, &[]);
        assert_eq!(report.estate_shape.as_deref(), Some("consolidated-shape3"));
        assert_eq!(report.protocol_deviation, Some(true));
        assert_eq!(report.shape3_group_count, Some(2));
        assert_eq!(report.shape3_conflict_key_type.as_deref(), Some("question-text"));
        assert_eq!(report.shape3_unique_keys, Some(2));
        assert_eq!(report.shape3_items_per_group.as_deref(), Some([3usize, 1].as_slice()));
    }

    #[test]
    fn c10_shape3_fields_round_trip_json() {
        let cfg = make_c10_cfg_consolidated(vec![2, 1], 2);
        let report = build_membench_report(&cfg, &[]);
        let json = serde_json::to_string(&report).unwrap();
        // Verify JSON contains deviation keys.
        assert!(json.contains("\"estate_shape\""), "JSON must contain estate_shape");
        assert!(json.contains("consolidated-shape3"), "JSON must contain consolidated-shape3 value");
        assert!(json.contains("\"protocol_deviation\""), "JSON must contain protocol_deviation");
        assert!(json.contains("\"shape_3_group_count\""), "JSON must contain shape_3_group_count");
        // Round-trip decode.
        let decoded: MemBenchReport = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.estate_shape.as_deref(), Some("consolidated-shape3"));
        assert_eq!(decoded.protocol_deviation, Some(true));
        assert_eq!(decoded.shape3_group_count, Some(2));
        assert_eq!(decoded.shape3_conflict_key_type.as_deref(), Some("question-text"));
        assert_eq!(decoded.shape3_unique_keys, Some(2));
        assert_eq!(decoded.shape3_items_per_group.as_deref(), Some([2usize, 1].as_slice()));
    }

    #[test]
    fn c10_per_item_report_json_contains_estate_shape_per_item() {
        let cfg = make_c10_cfg_per_item();
        let report = build_membench_report(&cfg, &[]);
        let json = serde_json::to_string(&report).unwrap();
        assert!(json.contains("\"estate_shape\":\"per-item\""), "per-item mode must emit estate_shape=per-item");
        // Shape 3 group fields must be absent from per-item reports.
        assert!(!json.contains("shape_3_group_count"), "per-item reports must not contain shape_3_group_count");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // C1 — BenchShape parse
    // ─────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_bench_shape_parse_none_gives_disk() {
        assert_eq!(
            crate::membench_runner::BenchShape::parse(None).unwrap(),
            crate::membench_runner::BenchShape::Disk
        );
    }

    #[test]
    fn test_bench_shape_parse_disk_explicit() {
        assert_eq!(
            crate::membench_runner::BenchShape::parse(Some("disk")).unwrap(),
            crate::membench_runner::BenchShape::Disk
        );
    }

    #[test]
    fn test_bench_shape_parse_ram() {
        assert_eq!(
            crate::membench_runner::BenchShape::parse(Some("ram")).unwrap(),
            crate::membench_runner::BenchShape::Ram
        );
    }

    #[test]
    fn test_bench_shape_parse_invalid_returns_err() {
        let err = crate::membench_runner::BenchShape::parse(Some("ssd")).unwrap_err();
        assert!(err.contains("'ssd'"), "expected error to mention the bad value, got: {err}");
    }

    #[test]
    fn test_bench_shape_as_str() {
        assert_eq!(crate::membench_runner::BenchShape::Disk.as_str(), "disk");
        assert_eq!(crate::membench_runner::BenchShape::Ram.as_str(), "ram");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // C6 — parallel index sort (determinism pin)
    // ─────────────────────────────────────────────────────────────────────────

    /// Verifies that sorting (run_index, result) pairs by index and flattening
    /// produces output in original run order regardless of which arrived first.
    /// This is the same sort used in main.rs to reconstruct ordered results.
    #[test]
    fn test_parallel_index_sort_is_deterministic() {
        // Simulate items arriving out of order (e.g. items 2, 0, 1 completed first).
        let mut indexed: Vec<(usize, &str)> = vec![(2, "item-C"), (0, "item-A"), (1, "item-B")];
        indexed.sort_by_key(|&(idx, _)| idx);
        let ordered: Vec<&str> = indexed.into_iter().map(|(_, v)| v).collect();
        assert_eq!(ordered, vec!["item-A", "item-B", "item-C"]);
    }
}

