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
    lme_parse_result_count, lme_percentile, lme_ranked_sessions, lme_recall_all, lme_recall_any,
    lme_session_mrr, LmeManifestEntry,
};
use crate::longmemeval_token_efficiency::lme_estimate_tokens;
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
    /// Guard sampling policy active for this leg. Mirrors Swift `LoCoMoQuestionResult.guardSamplingMode`.
    pub guard_sampling_mode: crate::degeneracy_guard::GuardSamplingPolicy,
    /// Total turns ingested into this conversation's estate.
    pub turns_ingested: usize,
    /// Mean write latency across all turns for this conversation's estate.
    pub write_mean_latency_seconds: f64,
    /// Raw text blocks from the MCP search response, joined with "\n".
    /// Used to compute tokens_per_result in the report builder.
    /// None when no text blocks were present (guard-excluded, error, or empty estate).
    pub payload_text: Option<String>,
    /// Whether this question's estate was served from the snapshot cache.
    /// Some(true) = cache hit, Some(false) = cache miss, None = cache off.
    pub cache_hit: Option<bool>,
    /// Whether the drain barrier observed the corpus_encode lane registered
    /// before accepting idle. false = converged via the no-lanes grace window
    /// (ambiguous evidence). None = barrier did not run for this conversation.
    /// Additive — FIX-HARNESS-20260727.
    pub drain_lane_observed: Option<bool>,
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
            turn_index: e.turn_index as i64,
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
    // Latency and ingest stats — always recorded internally; not forwarded to emitted JSON.
    pub query_latency_seconds: f64,
    pub write_mean_latency_seconds: f64,
    pub turns_ingested: usize,
    pub retrieved_uuid_count: usize,
    /// Raw MCP payload text (text_blocks joined with "\n"). Carried through for
    /// tokens_per_result computation in the report builder.
    pub payload_text: Option<String>,
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
        payload_text: result.payload_text,
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
#[derive(Debug, serde::Serialize, serde::Deserialize, Default)]
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
    /// Query latency kept internally; not emitted in accuracy-lane JSON (2026-08-18 doctrine).
    #[serde(skip_serializing)]
    #[serde(default)]
    pub query_latency_seconds: f64,
    /// Write latency kept internally; not emitted in accuracy-lane JSON (2026-08-18 doctrine).
    #[serde(skip_serializing)]
    #[serde(default)]
    pub write_mean_latency_seconds: f64,
    pub ranked_dia_ids: Vec<String>,
    pub evidence_dia_ids: Vec<String>,
    pub retrieved_uuid_count: usize,
    /// Estimated payload tokens divided by the retrieved result count.
    /// Nil when the payload was absent or the result count was zero.
    pub tokens_per_result: Option<f64>,
    /// Verbatim payload text (joined text_blocks) the recall verb returned for
    /// this question. Persisted so retrieval diagnosis (which chunks came back,
    /// whether a bridge query fired) reads from the report instead of requiring
    /// a re-run with instrumentation. None when the MCP response carried no
    /// text_blocks. Skipped when None to match the Swift leg's omit-when-nil
    /// encoding. Reports live in gitignored results directories, so size is a
    /// disk concern only, never a repo concern.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub payload_text: Option<String>,
    /// Whether this question's estate was served from the snapshot cache.
    /// Some(true) = hit, Some(false) = miss, None = cache off.
    /// Additive key per BENCHMARKER_OPTIMIZER_CONTRACT.md.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_hit: Option<bool>,
    /// Whether the drain barrier observed the corpus_encode lane registered
    /// before accepting idle. false = converged via the no-lanes grace window
    /// (ambiguous evidence). None = barrier did not run for this conversation.
    /// Additive — FIX-HARNESS-20260727.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub drain_lane_observed: Option<bool>,
}

/// Token-efficiency and barrier provenance summary for a LoCoMo run.
/// Aggregates token-efficiency state so every report JSON is self-documenting
/// without cross-referencing external logs.
///
/// Twin of Swift `LoCoMoProvenanceSummary`.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct LoCoMoProvenanceSummary {
    /// Number of questions for which the MCP response contained a non-empty payload.
    pub questions_with_payload: usize,
    /// Mean (payload tokens / retrieved UUID count) across questions where both
    /// payload and at least one retrieved result were present. None when no questions
    /// had payload text.
    pub mean_tokens_per_result: Option<f64>,
    /// Encode barrier mode used during ingest. Mirrors top-level encode_barrier
    /// to keep provenance summary self-contained for log analysis.
    pub encode_barrier: String,
}

/// The full LoCoMo run report.
/// Additive with BENCHMARKER_OPTIMIZER_CONTRACT.md §1.2: existing key names
/// unchanged; `category_breakdown` is a new additive key.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct LoCoMoReport {
    /// The estate schema the harness was built against, stamped into every
    /// report so the results record can carry the column without anyone typing
    /// it (BENCHMARK_PROTOCOL §9). Twin of Swift `estateSchemaVersion`.
    pub estate_schema_version: String,
    pub run_id: String,
    pub run_label: String,
    pub generated_at: String,
    /// Encode-queue synchronization strategy used for this run.
    /// One of: "drain" | "impatient" | "none". Self-documenting in the report.
    pub encode_barrier: String,
    /// Guard probe sampling policy for the leg ("once" or "per-unit", C5).
    pub guard_sampling: String,
    pub corpus_stats: LoCoMoReportCorpusStats,
    pub aggregate: LoCoMoReportAggregate,
    /// Per-category breakdown: single_hop / temporal / multi_hop / open_domain.
    /// New in LoCoMo, not present in LME reports (additive key).
    pub category_breakdown: Vec<LoCoMoReportCategoryEntry>,
    /// Latency stats kept internally for console output; not emitted in accuracy-lane JSON (2026-08-18 doctrine).
    #[serde(skip_serializing)]
    #[serde(default)]
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
    /// At-rest posture of the run's scratch estates: "plaintext-optout"
    /// (default) or "encrypted-ephemeral" (--estate-mode encrypted).
    /// Additive — FIX-HARNESS-20260727.
    pub estate_encryption: String,
    /// What one filed document was for this run: "turn" or "session". Cells
    /// at different granularities are different tasks and never comparable.
    /// Additive.
    pub granularity: String,
    pub per_question: Vec<LoCoMoReportPerQuestion>,
    /// Token-efficiency and barrier provenance summary. None when no question had
    /// payload text (e.g. estate was empty during a dry run).
    pub provenance_summary: Option<LoCoMoProvenanceSummary>,
    // MARK: Recall strategy (PR-08 D1)
    /// Recall verb strategy used for per-question queries: "search" (default),
    /// "shaped", or "precise". Additive field — all prior reports record "search"
    /// by default.
    pub recall_strategy: String,
    /// Named RecallShape preset for the "shaped" strategy. Absent when strategy
    /// is not "shaped" or no preset was configured (product default used).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recall_shape: Option<String>,
    // ── Rerank cell (additive — W2-rerank) ───────────────────────────────────
    /// Whether a rerank command was configured at all. Presence only — the
    /// command text is user-supplied shell that routinely carries API keys and
    /// must never reach a published report.
    #[serde(rename = "rerank_cmd_set")]
    pub rerank_cmd_set: bool,
    /// Count of questions where the rerank command returned an unparseable
    /// reply. Omitted entirely when `--rerank-cmd` was not supplied.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "rerank_failures")]
    pub rerank_failures: Option<u64>,
    // MARK: Binary identity (additive — JB-01, slimmed 2026-08-18 doctrine)
    /// Binary and protocol identity captured at run start. Accuracy lane emits
    /// only the three identity fields; full machine profile is the timing lane's concern.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "run_environment")]
    pub identity_environment: Option<crate::run_environment::IdentityEnvironment>,
    // MARK: Estate shape + parallelism (additive — C1/C6)
    /// Estate backend used for scratch estates: "disk" (default SQLite) or
    /// "ram" (--in-memory flag to serve; ephemeral, no keychain contact).
    /// Additive key per BENCHMARKER_OPTIMIZER_CONTRACT.md.
    pub shape: String,
    /// Number of conversation threads used for this run (C6). 1 = serial
    /// (legacy behavior); N > 1 = bounded parallel. Results are always
    /// reassembled in conversation-index order regardless of thread count.
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
    // MARK: C10 — Shape 3 fleet topology deviation labels
    /// Estate fleet topology for this run: "per-conversation" (default, published
    /// LoCoMo protocol) or "consolidated-shape3" (all conversations share one estate).
    /// Byte-identical to the Swift field name and value strings.
    #[serde(rename = "estate_shape")]
    pub estate_shape: String,
    /// Whether this run deviates from the published LoCoMo protocol. True only
    /// for consolidated-shape3 runs. Default false (per-conversation runs).
    #[serde(rename = "protocol_deviation")]
    pub protocol_deviation: bool,
    /// Number of estate groups used in consolidated mode. Always 1 for Shape 3.
    /// Absent for per-conversation runs.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "consolidated_group_count")]
    pub consolidated_group_count: Option<usize>,
    /// The conflict key used to namespace record IDs in consolidated mode.
    /// "sample_id" for Shape 3. Absent for per-conversation runs.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "consolidated_group_key")]
    pub consolidated_group_key: Option<String>,
    /// Total turns ingested into the single consolidated estate. Absent for
    /// per-conversation runs (each conversation tracks its own `turns_ingested`).
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "consolidated_total_turns")]
    pub consolidated_total_turns: Option<usize>,
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
    guard_sampling: String,
    questions_loaded: usize,
    adversarial_excluded: usize,
    scores: &[LoCoMoQuestionScore],
    cache_hit_by_id: &std::collections::HashMap<String, Option<bool>>,
    drain_lane_by_id: &std::collections::HashMap<String, Option<bool>>,
    estate_cache: String,
    estate_encryption: String,
    // Ingest granularity of this run ("turn" | "session").
    granularity: String,
    // Recall strategy name ("search" | "shaped" | "precise") — PR-08 D1.
    recall_strategy: String,
    // Named RecallShape preset when strategy is "shaped". None otherwise.
    recall_shape: Option<String>,
    // Whether --rerank-cmd was supplied. Presence only — command text must
    // never reach the report.
    rerank_cmd_set: bool,
    // Count of rerank-command parse failures. None when flag absent.
    rerank_failures: Option<u64>,
    // Binary identity captured once at subcommand start (JB-01, slimmed 2026-08-18).
    identity_environment: Option<crate::run_environment::IdentityEnvironment>,
    // Estate backend: "disk" | "ram" (C1). Recorded verbatim in report.
    shape: String,
    // Effective parallel conversation count for this run (C6).
    parallel_units: usize,
    // C10: consolidated total turns (Shape 3 only). None for per-conversation runs.
    consolidated_total_turns: Option<usize>,
    // C4: leg-level timing report. None when every conversation restored from
    // the artifact cache (no settle pass ran) or the first fetch failed.
    timing_report: Option<String>,
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

    // Compute per-question tokens_per_result and accumulate provenance data.
    // Uses lme_parse_result_count (parses "found N memory(s)") and lme_estimate_tokens
    // (byte-count/4) for consistency with the LME dual-arm computation.
    let mut tokens_per_result_list: Vec<f64> = Vec::new();
    let questions_with_payload = scores.iter().filter(|s| s.payload_text.is_some()).count();

    let per_question: Vec<LoCoMoReportPerQuestion> = scores
        .iter()
        .map(|s| {
            let tpr: Option<f64> = s.payload_text.as_deref().and_then(|text| {
                let n = lme_parse_result_count(text)?;
                if n == 0 { return None; }
                Some(lme_estimate_tokens(text) as f64 / n as f64)
            });
            if let Some(v) = tpr { tokens_per_result_list.push(v); }
            LoCoMoReportPerQuestion {
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
                tokens_per_result:       tpr,
                payload_text:            s.payload_text.clone(),
                // Look up cache_hit from the raw results map (key = question_id).
                cache_hit:               cache_hit_by_id.get(&s.question_id).copied().flatten(),
                drain_lane_observed:     drain_lane_by_id.get(&s.question_id).copied().flatten(),
            }
        })
        .collect();

    let mean_tokens_per_result: Option<f64> = if tokens_per_result_list.is_empty() {
        None
    } else {
        Some(tokens_per_result_list.iter().sum::<f64>() / tokens_per_result_list.len() as f64)
    };
    let provenance_summary = if questions_with_payload > 0 {
        Some(LoCoMoProvenanceSummary {
            questions_with_payload,
            mean_tokens_per_result,
            encode_barrier: encode_barrier.clone(),
        })
    } else {
        None
    };

    // C10: derive Shape 3 deviation labels from consolidated_total_turns presence.
    // A non-None consolidated_total_turns indicates consolidated mode was used.
    let is_consolidated = consolidated_total_turns.is_some();
    let estate_shape = if is_consolidated {
        "consolidated-shape3".to_string()
    } else {
        "per-conversation".to_string()
    };
    let consolidated_group_count: Option<usize> = if is_consolidated { Some(1) } else { None };
    let consolidated_group_key: Option<String> = if is_consolidated {
        Some("sample_id".to_string())
    } else {
        None
    };

    LoCoMoReport {
        estate_schema_version: crate::artifact_manifest::CURRENT_ESTATE_SCHEMA_VERSION.to_string(),
        run_id,
        run_label,
        generated_at,
        encode_barrier,
        guard_sampling,
        corpus_stats,
        aggregate: report_aggregate,
        category_breakdown,
        latency: report_latency,
        estate_cache,
        estate_encryption,
        granularity,
        cache_hits,
        cache_misses,
        per_question,
        provenance_summary,
        recall_strategy,
        recall_shape,
        rerank_cmd_set,
        rerank_failures,
        identity_environment,
        shape,
        parallel_units,
        // C4: timing report from the first freshly-settled estate of the leg.
        timing_report,
        timing_sampling: "once-per-leg".to_string(),
        // C10: Shape 3 deviation labels.
        estate_shape,
        protocol_deviation: is_consolidated,
        consolidated_group_count,
        consolidated_group_key,
        consolidated_total_turns,
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
    // Records are never overwritten (2026-08-17): a taken path raises so the
    // operator is told which measurement was about to be destroyed.
    crate::record_writer::write_record_never_overwrite(sorted_json.as_bytes(), path)
        .map_err(|e| format!("report write failed: {e}"))
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests — provenance summary and tokens_per_result fields
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Constructs a minimal `LoCoMoQuestionScore` for use in report-builder tests.
    fn make_score(payload_text: Option<String>) -> LoCoMoQuestionScore {
        LoCoMoQuestionScore {
            question_id: "test-q1".to_string(),
            category: 1,
            category_label: "single_hop".to_string(),
            guard_healthy: true,
            guard_diagnostic: None,
            recall_any_at_1: 1.0,
            recall_any_at_5: 1.0,
            recall_any_at_10: 1.0,
            recall_all_at_1: 1.0,
            recall_all_at_5: 1.0,
            recall_all_at_10: 1.0,
            mrr: 1.0,
            ranked_dia_ids: vec!["D1:1".to_string()],
            evidence_dia_ids: vec!["D1:1".to_string()],
            query_latency_seconds: 0.1,
            write_mean_latency_seconds: 0.05,
            turns_ingested: 5,
            retrieved_uuid_count: 3,
            payload_text,
        }
    }

    /// `build_locomo_report` populates `encode_barrier`, `tokens_per_result`, and
    /// `provenance_summary` fields when a score has a payload_text with a recognized
    /// "found N memory(s)" header.
    ///
    /// Twin of Swift `testBuildLoCoMoReportPopulatesProvenanceFields`.
    #[test]
    fn build_locomo_report_populates_provenance_fields() {
        // Payload with "found 3 memory(s)" header — lme_parse_result_count returns Some(3).
        let payload = "found 3 memory(s)\nblock one content\nblock two content\nblock three content";
        let score = make_score(Some(payload.to_string()));
        let scores = vec![score];

        let report = build_locomo_report(
            "test-run-id".to_string(),
            "test-label".to_string(),
            "2026-01-01T00:00:00Z".to_string(),
            "drain".to_string(),
            "once".to_string(),
            1,     // questions_loaded
            0,     // adversarial_excluded
            &scores,
            &std::collections::HashMap::new(),
            &std::collections::HashMap::new(),
            "off".to_string(),
            "plaintext-optout".to_string(),
            "turn".to_string(),
            "search".to_string(),  // recall_strategy (PR-08 D1)
            None,                  // recall_shape
            false,                 // rerank_cmd_set
            None,                  // rerank_failures
            None,                  // identity_environment
            "disk".to_string(),    // shape
            1,                     // parallel_units
            None,                  // consolidated_total_turns (C10)
            None,                  // timing_report
        );

        // Top-level encode_barrier must be "drain".
        assert_eq!(report.encode_barrier, "drain", "encode_barrier field must equal run's barrier mode");

        // Per-question tokens_per_result must be set and non-zero.
        let q = &report.per_question[0];
        assert!(
            q.tokens_per_result.is_some(),
            "tokens_per_result must be Some when payload had recognized 'found N' header"
        );
        assert!(
            q.tokens_per_result.unwrap() > 0.0,
            "tokens_per_result must be positive"
        );

        // provenance_summary must be populated.
        let prov = report.provenance_summary.as_ref()
            .expect("provenance_summary must be Some when at least one question had payload");
        assert_eq!(prov.questions_with_payload, 1, "questions_with_payload must be 1");
        assert!(prov.mean_tokens_per_result.is_some(), "mean_tokens_per_result must be Some");
        assert_eq!(prov.encode_barrier, "drain", "provenance_summary.encode_barrier must match run barrier");
    }

    /// When no score has payload_text, `provenance_summary` must be None and every
    /// `tokens_per_result` entry must be None.
    #[test]
    fn build_locomo_report_no_payload_provenance_is_none() {
        let score = make_score(None);
        let scores = vec![score];

        let report = build_locomo_report(
            "test-run-id".to_string(),
            "test-label".to_string(),
            "2026-01-01T00:00:00Z".to_string(),
            "drain".to_string(),
            "once".to_string(),
            1, 0,
            &scores,
            &std::collections::HashMap::new(),
            &std::collections::HashMap::new(),
            "off".to_string(),
            "plaintext-optout".to_string(),
            "turn".to_string(),
            "search".to_string(),  // recall_strategy (PR-08 D1)
            None,                  // recall_shape
            false,                 // rerank_cmd_set
            None,                  // rerank_failures
            None,                  // identity_environment
            "disk".to_string(),    // shape
            1,                     // parallel_units
            None,                  // consolidated_total_turns (C10)
            None,                  // timing_report
        );

        assert!(
            report.provenance_summary.is_none(),
            "provenance_summary must be None when no score had payload"
        );
        assert!(
            report.per_question[0].tokens_per_result.is_none(),
            "tokens_per_result must be None when score had no payload"
        );
    }

    /// Pinning test: payload_text survives runner → scorer → report per_question row.
    ///
    /// Constructs a `LoCoMoQuestionResult` with a non-None `payload_text`, threads it
    /// through `score_locomo_question`, then through `build_locomo_report`, and asserts
    /// that `per_question[0].payload_text` equals the original string verbatim.
    ///
    /// Any future refactor that accidentally drops the field at the scorer or report-
    /// builder boundary will be caught here rather than requiring a live benchmark re-run
    /// with extra instrumentation to diagnose the silence.
    ///
    /// Twin of Swift `testPayloadTextSurvivesToPerQuestionRow`.
    #[test]
    fn payload_text_survives_to_per_question_row() {
        let raw_payload = "found 2 memory(s)\nfirst chunk text\nsecond chunk text";

        // Build a minimal result with payload_text set.
        let result = LoCoMoQuestionResult {
            question_id: "payload-pin-q1".to_string(),
            category_label: "single_hop".to_string(),
            category: 1,
            guard_sampling_mode: crate::degeneracy_guard::GuardSamplingPolicy::OncePerLeg,
            query_latency_seconds: 0.08,
            retrieved_uuids: vec!["uuid-A".to_string(), "uuid-B".to_string()],
            manifest: vec![
                LoCoMoManifestEntry {
                    uuid: "uuid-A".to_string(),
                    dia_id: "D1:1".to_string(),
                    session_number: 1,
                    turn_index: 0,
                    speaker: "Alice".to_string(),
                },
                LoCoMoManifestEntry {
                    uuid: "uuid-B".to_string(),
                    dia_id: "D1:2".to_string(),
                    session_number: 1,
                    turn_index: 1,
                    speaker: "Bob".to_string(),
                },
            ],
            evidence_dia_ids: vec!["D1:1".to_string()],
            guard_healthy: true,
            guard_diagnostic: None,
            turns_ingested: 2,
            write_mean_latency_seconds: 0.01,
            payload_text: Some(raw_payload.to_string()),
            cache_hit: None,
            drain_lane_observed: None,
        };

        // Score step: scorer must pass payload_text through unchanged.
        let score = score_locomo_question(result);
        assert_eq!(
            score.payload_text.as_deref(),
            Some(raw_payload),
            "score_locomo_question must pass payload_text through unchanged"
        );

        // Report-builder step: per_question row must carry payload_text verbatim.
        let scores = vec![score];
        let report = build_locomo_report(
            "run-id".to_string(),
            "payload-pin-label".to_string(),
            "2026-01-01T00:00:00Z".to_string(),
            "drain".to_string(),
            "once".to_string(),
            1, // questions_loaded
            0, // adversarial_excluded
            &scores,
            &std::collections::HashMap::new(), // cache_hit_by_id
            &std::collections::HashMap::new(), // drain_lane_by_id
            "off".to_string(),
            "plaintext-optout".to_string(),
            "turn".to_string(),
            "search".to_string(),
            None,                  // recall_shape
            false,                 // rerank_cmd_set
            None,                  // rerank_failures
            None,                  // identity_environment
            "disk".to_string(),    // shape
            1,                     // parallel_units
            None,                  // consolidated_total_turns (C10)
            None,                  // timing_report
        );

        let row = &report.per_question[0];
        assert_eq!(
            row.payload_text.as_deref(),
            Some(raw_payload),
            "payload_text in LoCoMoReportPerQuestion must equal the original MCP payload \
             captured by the runner; the runner→scorer→report chain must not drop it"
        );
    }

    /// Helper — builds a minimal LoCoMoReport with specified rerank parameters.
    fn build_minimal_report(rerank_cmd_set: bool, rerank_failures: Option<u64>) -> LoCoMoReport {
        build_locomo_report(
            "run-id".to_string(),
            "label".to_string(),
            "2026-01-01T00:00:00Z".to_string(),
            "drain".to_string(),
            "once".to_string(),
            0, 0,
            &[],
            &std::collections::HashMap::new(),
            &std::collections::HashMap::new(),
            "off".to_string(),
            "plaintext-optout".to_string(),
            "turn".to_string(),
            "search".to_string(),
            None,                  // recall_shape
            rerank_cmd_set,
            rerank_failures,
            None,                  // identity_environment
            "disk".to_string(),    // shape
            1,                     // parallel_units
            None,                  // consolidated_total_turns (C10)
            None,                  // timing_report
        )
    }

    /// Rerank command follows the same secrecy rule as the judge command:
    /// presence only (W2-rerank). The command text must never reach the report.
    #[test]
    fn rerank_command_leaves_no_trace_beyond_presence() {
        let report = build_minimal_report(true, Some(0));
        let json = serde_json::to_string(&report).unwrap();
        let raw: serde_json::Value = serde_json::from_str(&json).unwrap();

        assert_eq!(raw["rerank_cmd_set"], true,
            "rerank_cmd_set must appear in the report");
        assert!(
            raw.get("rerank_cmd").is_none(),
            "the rerank command string must NEVER be persisted to the report"
        );
        assert!(
            raw.get("rerank_cmd_digest").is_none(),
            "no fingerprint of the rerank command may appear in the report"
        );
    }

    /// When --rerank-cmd is active, rerank_failures appears in the report.
    /// When the flag is absent, the field is omitted entirely.
    #[test]
    fn rerank_failures_present_when_active_omitted_when_absent() {
        // Flag absent
        let report_no_rerank = build_minimal_report(false, None);
        let json_no = serde_json::to_string(&report_no_rerank).unwrap();
        let raw_no: serde_json::Value = serde_json::from_str(&json_no).unwrap();
        assert!(
            raw_no.get("rerank_failures").is_none(),
            "rerank_failures must be omitted when --rerank-cmd was not set"
        );
        assert_eq!(raw_no["rerank_cmd_set"], false);

        // Flag active — 5 failures
        let report_with = build_minimal_report(true, Some(5));
        let json_with = serde_json::to_string(&report_with).unwrap();
        let raw_with: serde_json::Value = serde_json::from_str(&json_with).unwrap();
        assert_eq!(
            raw_with["rerank_failures"], 5u64,
            "rerank_failures must be present and correct when --rerank-cmd is active"
        );
        assert_eq!(raw_with["rerank_cmd_set"], true);
    }

    /// Report must carry the `shape` field verbatim from the caller ("disk" or "ram").
    ///
    /// Twin of Swift `testLoCoMoReportRecordsShape`.
    #[test]
    fn report_records_shape_field() {
        // disk shape
        let report_disk = build_locomo_report(
            "id".to_string(), "label".to_string(), "2026-01-01T00:00:00Z".to_string(),
            "drain".to_string(), "once".to_string(), 0, 0,
            &[], &std::collections::HashMap::new(), &std::collections::HashMap::new(),
            "off".to_string(), "plaintext-optout".to_string(),
            "turn".to_string(), "search".to_string(), None, false, None, None,
            "disk".to_string(), 1, None, None,
        );
        assert_eq!(report_disk.shape, "disk", "shape field must be 'disk' when disk backend");

        // ram shape
        let report_ram = build_locomo_report(
            "id".to_string(), "label".to_string(), "2026-01-01T00:00:00Z".to_string(),
            "drain".to_string(), "once".to_string(), 0, 0,
            &[], &std::collections::HashMap::new(), &std::collections::HashMap::new(),
            "off".to_string(), "plaintext-optout".to_string(),
            "turn".to_string(), "search".to_string(), None, false, None, None,
            "ram".to_string(), 4, None, None,
        );
        assert_eq!(report_ram.shape, "ram", "shape field must be 'ram' when ram backend");
        assert_eq!(report_ram.parallel_units, 4, "parallel_units must equal effective thread count");
    }

    /// `parallel_units` stays internal: absent from JSON output (a run is a
    /// run; width is not a property of accuracy figures).
    ///
    /// Twin of Swift "LMEBReport encodes shape and omits parallel_units".
    #[test]
    fn report_omits_parallel_units_in_json() {
        let report = build_locomo_report(
            "id".to_string(), "label".to_string(), "2026-01-01T00:00:00Z".to_string(),
            "drain".to_string(), "once".to_string(), 0, 0,
            &[], &std::collections::HashMap::new(), &std::collections::HashMap::new(),
            "off".to_string(), "plaintext-optout".to_string(),
            "turn".to_string(), "search".to_string(), None, false, None, None,
            "disk".to_string(), 6, None, None,
        );
        assert_eq!(report.parallel_units, 6);

        let json = serde_json::to_string(&report).unwrap();
        let raw: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert!(raw.get("parallel_units").is_none(), "parallel_units must never appear in JSON output");
        assert!(raw.get("shape").is_some(), "shape must appear in JSON output");
    }
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
