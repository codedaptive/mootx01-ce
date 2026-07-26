//! longmemeval_scorer.rs — Pure scoring math for LongMemEval session-recall.
//!
//! Rust twin of `LongMemEvalScorer.swift`. Every function is deterministic and
//! pure (no I/O, no live products) so the conformance vectors in
//! `conformance/longmemeval_vectors.json` can drive both legs identically.
//!
//! Key difference from the quality benchmark: LongMemEval ground truth is a
//! **set** of session IDs (one question can have multiple evidence sessions).
//! The scoring functions have "any" and "all" variants:
//!   - `lme_recall_any@k`: 1.0 iff ANY answer session is in the top-k
//!   - `lme_recall_all@k`: 1.0 iff ALL answer sessions are in the top-k
//!   - `lme_session_mrr`: 1/(rank of the FIRST answer session found)
//!
//! The pipeline:
//!   1. `lme_ranked_sessions` maps retrieved UUID order → session order,
//!      deduplicating while preserving rank of the first UUID per session.
//!   2. Scoring functions operate on the deduplicated session ranking.
//!   3. Guard-excluded questions are excluded from aggregate scoring per
//!      BENCHMARKER_OPTIMIZER_CONTRACT.md §1.2 guarantee 1.

use std::collections::{BTreeMap, HashMap, HashSet};
use crate::longmemeval_corpus::LmeCorpus;
use crate::longmemeval_token_efficiency::{lme_estimate_tokens, lme_evidence_hit};

// ─────────────────────────────────────────────────────────────────────────────
// Manifest entry (UUID → haystack position)
// ─────────────────────────────────────────────────────────────────────────────

/// Maps a filed-memory UUID back to its origin in the haystack.
/// Twin of Swift's `LMEManifestEntry` (`LongMemEvalRunner.swift`).
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct LmeManifestEntry {
    pub uuid: String,
    pub session_id: String,
    pub turn_index: usize,
    pub session_index: usize,
    pub role: String,
}

// ─────────────────────────────────────────────────────────────────────────────
// UUID → session mapping
// ─────────────────────────────────────────────────────────────────────────────

/// Maps a UUID-ranked result list to a session-ranked list, preserving the rank
/// of each session's FIRST appearing UUID.
///
/// UUIDs not in the manifest are dropped (conservative: unmappable hits never
/// earn credit). Each session appears at most once — duplicate UUIDs from the
/// same session after the first are ignored.
///
/// Twin of Swift `lmeRankedSessions(uuids:manifest:)`.
pub fn lme_ranked_sessions(uuids: &[String], manifest: &[LmeManifestEntry]) -> Vec<String> {
    let mut uuid_to_session: HashMap<&str, &str> = HashMap::with_capacity(manifest.len());
    for entry in manifest {
        uuid_to_session.insert(entry.uuid.as_str(), entry.session_id.as_str());
    }
    let mut seen: HashSet<String> = HashSet::new();
    let mut ranked: Vec<String> = Vec::with_capacity(uuids.len().min(manifest.len()));
    for uuid in uuids {
        if let Some(&session_id) = uuid_to_session.get(uuid.as_str()) {
            if seen.insert(session_id.to_string()) {
                ranked.push(session_id.to_string());
            }
        }
    }
    ranked
}

// ─────────────────────────────────────────────────────────────────────────────
// Recall-any@k
// ─────────────────────────────────────────────────────────────────────────────

/// Recall-any@k: 1.0 iff ANY answer session appears in the top-k ranked sessions.
/// Empty `answer_ids` or `k == 0` → 0.0.
///
/// Twin of Swift `lmeRecallAny(rankedSessions:answerIDs:k:)`.
pub fn lme_recall_any(ranked_sessions: &[String], answer_ids: &HashSet<String>, k: usize) -> f64 {
    if k == 0 || answer_ids.is_empty() {
        return 0.0;
    }
    if ranked_sessions
        .iter()
        .take(k)
        .any(|s| answer_ids.contains(s.as_str()))
    {
        1.0
    } else {
        0.0
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Recall-all@k
// ─────────────────────────────────────────────────────────────────────────────

/// Recall-all@k: 1.0 iff ALL answer sessions appear in the top-k ranked sessions.
/// Empty `answer_ids` → 1.0 (vacuously true). `k == 0` → 0.0 unless `answer_ids` empty.
///
/// Twin of Swift `lmeRecallAll(rankedSessions:answerIDs:k:)`.
pub fn lme_recall_all(ranked_sessions: &[String], answer_ids: &HashSet<String>, k: usize) -> f64 {
    if answer_ids.is_empty() {
        return 1.0;
    }
    if k == 0 {
        return 0.0;
    }
    let top_k: HashSet<&str> = ranked_sessions.iter().take(k).map(|s| s.as_str()).collect();
    if answer_ids.iter().all(|id| top_k.contains(id.as_str())) {
        1.0
    } else {
        0.0
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Session MRR
// ─────────────────────────────────────────────────────────────────────────────

/// Session-level MRR: 1 / (1-based rank of the FIRST answer session found in
/// the ranking). Returns 0.0 if no answer session appears in the ranked list.
///
/// Twin of Swift `lmeSessionMRR(rankedSessions:answerIDs:)`.
pub fn lme_session_mrr(ranked_sessions: &[String], answer_ids: &HashSet<String>) -> f64 {
    if answer_ids.is_empty() {
        return 0.0;
    }
    for (zero_based, session_id) in ranked_sessions.iter().enumerate() {
        if answer_ids.contains(session_id.as_str()) {
            return 1.0 / (zero_based + 1) as f64;
        }
    }
    0.0
}

// ─────────────────────────────────────────────────────────────────────────────
// Percentile
// ─────────────────────────────────────────────────────────────────────────────

/// Nearest-rank percentile of `values` at fraction `p` ∈ (0, 1].
/// Returns 0.0 for an empty input.
///
/// Matches the Swift `lmePercentile` (and `RollingSeries.p95`) algorithm:
/// rank = ceil(p × n), index = min(max(rank, 1), n) - 1.
///
/// Twin of Swift `lmePercentile(_:_:)`.
pub fn lme_percentile(values: &[f64], p: f64) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let mut sorted = values.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let n = sorted.len();
    // ceil(p * n), clamped to [1, n].
    let rank = ((p * n as f64).ceil() as usize).max(1).min(n);
    sorted[rank - 1]
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-question result (from runner) and score (from scorer)
// ─────────────────────────────────────────────────────────────────────────────

/// The result of running the LME harness against one question.
/// Produced by the runner; consumed by the scorer.
/// Twin of Swift `LMEQuestionResult`.
///
/// Optional fields (added for LME-03 token-efficiency arms) are None when the
/// corresponding arm was not run for this question.
#[derive(Debug)]
pub struct LmeQuestionResult {
    pub question_id: String,
    pub question_type: String,
    /// Exact-arm (moot_memory_search) query latency. None when arm = Dense only.
    pub query_latency_seconds: Option<f64>,
    /// UUIDs returned by moot_memory_search, ranked best-first. Empty when arm = Dense.
    pub retrieved_uuids: Vec<String>,
    /// UUID → haystack-position manifest built during ingest.
    pub manifest: Vec<LmeManifestEntry>,
    /// Ground-truth session IDs for this question.
    pub answer_session_ids: Vec<String>,
    /// True when the DegeneracyGuard classified the backend as healthy.
    pub guard_healthy: bool,
    /// Diagnostic when guard was not healthy; None when healthy.
    pub guard_diagnostic: Option<String>,
    pub turns_ingested: usize,
    pub write_mean_latency_seconds: f64,
    /// Raw payload text from the exact-arm moot_memory_search call (joined text_blocks).
    /// None when arm = Dense.
    pub exact_payload_text: Option<String>,
    /// Raw payload text from the dense-arm moot_recall_distilled call (joined text_blocks).
    /// None when arm = Exact.
    pub dense_payload_text: Option<String>,
    /// Dense-arm (moot_recall_distilled) query latency. None when arm = Exact.
    pub dense_query_latency_seconds: Option<f64>,
    // ── Judge mode fields (Part 4, LME-03) ───────────────────────────────────
    /// Judge subprocess answer for the exact arm. None when judge_cmd was not set
    /// or the exact arm was not run.
    pub exact_judge_answer: Option<String>,
    /// True when exact_judge_answer contains the normalized gold answer as a
    /// substring. None when exact_judge_answer is None.
    pub exact_judge_correct: Option<bool>,
    /// Judge subprocess answer for the dense arm. None when judge_cmd was not set
    /// or the dense arm was not run.
    pub dense_judge_answer: Option<String>,
    /// True when dense_judge_answer contains the normalized gold answer as a
    /// substring. None when dense_judge_answer is None.
    pub dense_judge_correct: Option<bool>,
}

/// The scored result for one LME question.
/// Guard-excluded questions have zeroed recall/MRR metrics and are excluded from
/// aggregate scoring.
#[derive(Debug)]
pub struct LmeQuestionScore {
    pub question_id: String,
    pub question_type: String,
    pub guard_healthy: bool,
    pub guard_diagnostic: Option<String>,
    pub recall_any_at_1: f64,
    pub recall_any_at_5: f64,
    pub recall_any_at_10: f64,
    pub recall_all_at_1: f64,
    pub recall_all_at_5: f64,
    pub recall_all_at_10: f64,
    pub mrr: f64,
    pub ranked_session_ids: Vec<String>,
    pub answer_session_ids: Vec<String>,
    pub query_latency_seconds: f64,
    pub write_mean_latency_seconds: f64,
    pub turns_ingested: usize,
    pub retrieved_uuid_count: usize,
}

/// Scores one `LmeQuestionResult`. Guard-excluded questions get zeroed metrics.
///
/// Twin of Swift `scoreLMEQuestion(_:)`.
pub fn score_lme_question(result: LmeQuestionResult) -> LmeQuestionScore {
    let ranked_sessions = lme_ranked_sessions(&result.retrieved_uuids, &result.manifest);
    let answer_ids: HashSet<String> = result.answer_session_ids.iter().cloned().collect();

    let (ra1, ra5, ra10, rl1, rl5, rl10, mrr) = if result.guard_healthy {
        (
            lme_recall_any(&ranked_sessions, &answer_ids, 1),
            lme_recall_any(&ranked_sessions, &answer_ids, 5),
            lme_recall_any(&ranked_sessions, &answer_ids, 10),
            lme_recall_all(&ranked_sessions, &answer_ids, 1),
            lme_recall_all(&ranked_sessions, &answer_ids, 5),
            lme_recall_all(&ranked_sessions, &answer_ids, 10),
            lme_session_mrr(&ranked_sessions, &answer_ids),
        )
    } else {
        (0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    };

    let retrieved_uuid_count = result.retrieved_uuids.len();
    LmeQuestionScore {
        question_id: result.question_id,
        question_type: result.question_type,
        guard_healthy: result.guard_healthy,
        guard_diagnostic: result.guard_diagnostic,
        recall_any_at_1: ra1,
        recall_any_at_5: ra5,
        recall_any_at_10: ra10,
        recall_all_at_1: rl1,
        recall_all_at_5: rl5,
        recall_all_at_10: rl10,
        mrr,
        ranked_session_ids: ranked_sessions,
        answer_session_ids: result.answer_session_ids,
        // query_latency_seconds is Option<f64> (None when only the dense arm ran).
        // Use 0.0 as sentinel — matches Swift's ?? 0.0 convention.
        query_latency_seconds: result.query_latency_seconds.unwrap_or(0.0),
        write_mean_latency_seconds: result.write_mean_latency_seconds,
        turns_ingested: result.turns_ingested,
        retrieved_uuid_count,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Aggregate metrics
// ─────────────────────────────────────────────────────────────────────────────

/// Aggregate LME retrieval metrics over many questions (guard-healthy only).
/// Twin of Swift `LMEAggregateMetrics`.
#[derive(Debug)]
pub struct LmeAggregateMetrics {
    pub query_count: usize,
    pub recall_any_at_1: f64,
    pub recall_any_at_5: f64,
    pub recall_any_at_10: f64,
    pub recall_all_at_1: f64,
    pub recall_all_at_5: f64,
    pub recall_all_at_10: f64,
    pub mrr: f64,
}

/// Latency statistics over all questions (healthy and excluded).
/// Twin of Swift `LMELatencyStats`.
#[derive(Debug)]
pub struct LmeLatencyStats {
    pub query_p50_seconds: f64,
    pub query_p95_seconds: f64,
    pub query_mean_seconds: f64,
    pub write_mean_seconds: f64,
}

/// Computes aggregate metrics (guard-healthy only) and latency stats (all).
/// An empty input yields zeroed structs with `query_count == 0`.
///
/// Twin of Swift `aggregateLMEScores(_:)`.
pub fn aggregate_lme_scores(scores: &[LmeQuestionScore]) -> (LmeAggregateMetrics, LmeLatencyStats) {
    // ── Aggregate (guard-healthy only) ─────────────────────────────────────
    let healthy: Vec<&LmeQuestionScore> = scores.iter().filter(|s| s.guard_healthy).collect();
    let n = healthy.len();
    let aggregate = if n == 0 {
        LmeAggregateMetrics {
            query_count: 0,
            recall_any_at_1: 0.0,
            recall_any_at_5: 0.0,
            recall_any_at_10: 0.0,
            recall_all_at_1: 0.0,
            recall_all_at_5: 0.0,
            recall_all_at_10: 0.0,
            mrr: 0.0,
        }
    } else {
        let nf = n as f64;
        LmeAggregateMetrics {
            query_count: n,
            recall_any_at_1:  healthy.iter().map(|s| s.recall_any_at_1).sum::<f64>()  / nf,
            recall_any_at_5:  healthy.iter().map(|s| s.recall_any_at_5).sum::<f64>()  / nf,
            recall_any_at_10: healthy.iter().map(|s| s.recall_any_at_10).sum::<f64>() / nf,
            recall_all_at_1:  healthy.iter().map(|s| s.recall_all_at_1).sum::<f64>()  / nf,
            recall_all_at_5:  healthy.iter().map(|s| s.recall_all_at_5).sum::<f64>()  / nf,
            recall_all_at_10: healthy.iter().map(|s| s.recall_all_at_10).sum::<f64>() / nf,
            mrr:              healthy.iter().map(|s| s.mrr).sum::<f64>()               / nf,
        }
    };

    // ── Latency (all questions) ─────────────────────────────────────────────
    let query_latencies: Vec<f64> = scores.iter().map(|s| s.query_latency_seconds).collect();
    let write_latencies: Vec<f64> = scores.iter().map(|s| s.write_mean_latency_seconds).collect();
    let latency = LmeLatencyStats {
        query_p50_seconds:  lme_percentile(&query_latencies, 0.50),
        query_p95_seconds:  lme_percentile(&query_latencies, 0.95),
        query_mean_seconds: if query_latencies.is_empty() { 0.0 }
            else { query_latencies.iter().sum::<f64>() / query_latencies.len() as f64 },
        write_mean_seconds: if write_latencies.is_empty() { 0.0 }
            else { write_latencies.iter().sum::<f64>() / write_latencies.len() as f64 },
    };

    (aggregate, latency)
}

// ─────────────────────────────────────────────────────────────────────────────
// JSON report types
// ─────────────────────────────────────────────────────────────────────────────

/// Corpus statistics block of the LME report.
/// Contract-compatible with BENCHMARKER_OPTIMIZER_CONTRACT.md.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct LmeReportCorpusStats {
    pub questions_loaded: usize,
    pub abstention_excluded: usize,
    pub questions_run: usize,
    pub guard_excluded: usize,
}

/// Aggregate metrics block of the LME report.
/// Contract note: `query_count` and `mrr` use the same key names as the
/// existing benchmarker outcome record. Recall keys use `recall_any_*` /
/// `recall_all_*` to extend the single-target `recall_at_*` pattern additively.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct LmeReportAggregate {
    pub query_count: usize,
    pub recall_any_at_1: f64,
    pub recall_any_at_5: f64,
    pub recall_any_at_10: f64,
    pub recall_all_at_1: f64,
    pub recall_all_at_5: f64,
    pub recall_all_at_10: f64,
    pub mrr: f64,
}

/// Latency statistics block.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct LmeReportLatency {
    pub query_p50_seconds: f64,
    pub query_p95_seconds: f64,
    pub query_mean_seconds: f64,
    pub write_mean_seconds: f64,
}

/// Per-question entry in the LME report.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct LmeReportPerQuestion {
    pub question_id: String,
    pub question_type: String,
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
    pub ranked_session_ids: Vec<String>,
    pub answer_session_ids: Vec<String>,
    pub retrieved_uuid_count: usize,
}

/// Token efficiency block of the LME report. Additive key added by LME-03.
/// All fields are Option: nil when the arm was not active, or when `has_answer`
/// annotations are absent from the corpus (real HuggingFace corpus always lacks
/// them — only the hand-authored synthetic sample carries them).
///
/// Token estimate: `(utf8_byte_len + 3) / 4` — deterministic, zero deps.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct LmeReportTokenEfficiency {
    /// Mean estimated token count for the exact-arm (`moot_memory_search`) payload.
    /// None when the exact arm was not active or returned no payloads.
    pub exact_arm_mean_tokens: Option<f64>,
    /// Mean estimated token count for the dense-arm (`moot_recall_distilled`) payload.
    pub dense_arm_mean_tokens: Option<f64>,
    /// dense / exact token ratio. None when either arm absent or exact mean is 0.
    pub dense_exact_token_ratio: Option<f64>,
    /// Fraction of questions where the exact payload contained the has_answer text.
    /// None when no has_answer annotations present (real corpus).
    pub exact_evidence_hit_rate: Option<f64>,
    /// Same for the dense arm.
    pub dense_evidence_hit_rate: Option<f64>,
    /// Evidence hits per 1000 tokens for the exact arm.
    pub exact_hits_per_1k_tokens: Option<f64>,
    /// Evidence hits per 1000 tokens for the dense arm.
    pub dense_hits_per_1k_tokens: Option<f64>,
}

/// Lightweight per-question payload snapshot, extracted before results are
/// consumed by `score_lme_question`. Passed to `build_lme_report` so it can
/// compute the `token_efficiency` block without needing the full results vec.
pub struct LmePayloadEntry {
    pub question_id: String,
    pub exact_payload_text: Option<String>,
    pub dense_payload_text: Option<String>,
}

/// The full LME run report.
/// Additive/compatible with BENCHMARKER_OPTIMIZER_CONTRACT.md §1.2.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct LmeReport {
    pub run_id: String,
    pub run_label: String,
    pub variant: String,
    pub generated_at: String,
    pub corpus_stats: LmeReportCorpusStats,
    pub aggregate: LmeReportAggregate,
    pub latency: LmeReportLatency,
    pub per_question: Vec<LmeReportPerQuestion>,
    /// Token efficiency metrics (LME-03, additive per BENCHMARKER_OPTIMIZER_CONTRACT.md).
    pub token_efficiency: LmeReportTokenEfficiency,
}

/// Assembles an `LmeReport` from scores and metadata.
///
/// `corpus` and `payload_entries` are needed to compute the `token_efficiency`
/// block: the corpus provides `has_answer` turn annotations; payload_entries
/// carry per-question payload texts extracted before results were consumed.
pub fn build_lme_report(
    run_id: String,
    run_label: String,
    variant: String,
    generated_at: String,
    questions_loaded: usize,
    abstention_excluded: usize,
    scores: &[LmeQuestionScore],
    corpus: &LmeCorpus,
    payload_entries: &[LmePayloadEntry],
) -> LmeReport {
    let (aggregate, latency) = aggregate_lme_scores(scores);
    let guard_excluded = scores.iter().filter(|s| !s.guard_healthy).count();

    let corpus_stats = LmeReportCorpusStats {
        questions_loaded,
        abstention_excluded,
        questions_run: scores.len(),
        guard_excluded,
    };

    let report_aggregate = LmeReportAggregate {
        query_count:      aggregate.query_count,
        recall_any_at_1:  aggregate.recall_any_at_1,
        recall_any_at_5:  aggregate.recall_any_at_5,
        recall_any_at_10: aggregate.recall_any_at_10,
        recall_all_at_1:  aggregate.recall_all_at_1,
        recall_all_at_5:  aggregate.recall_all_at_5,
        recall_all_at_10: aggregate.recall_all_at_10,
        mrr:              aggregate.mrr,
    };

    let report_latency = LmeReportLatency {
        query_p50_seconds:  latency.query_p50_seconds,
        query_p95_seconds:  latency.query_p95_seconds,
        query_mean_seconds: latency.query_mean_seconds,
        write_mean_seconds: latency.write_mean_seconds,
    };

    let per_question: Vec<LmeReportPerQuestion> = scores
        .iter()
        .map(|s| LmeReportPerQuestion {
            question_id:              s.question_id.clone(),
            question_type:            s.question_type.clone(),
            turns_ingested:           s.turns_ingested,
            guard_healthy:            s.guard_healthy,
            guard_diagnostic:         s.guard_diagnostic.clone(),
            recall_any_at_1:          s.recall_any_at_1,
            recall_any_at_5:          s.recall_any_at_5,
            recall_any_at_10:         s.recall_any_at_10,
            recall_all_at_1:          s.recall_all_at_1,
            recall_all_at_5:          s.recall_all_at_5,
            recall_all_at_10:         s.recall_all_at_10,
            mrr:                      s.mrr,
            query_latency_seconds:    s.query_latency_seconds,
            write_mean_latency_seconds: s.write_mean_latency_seconds,
            ranked_session_ids:       s.ranked_session_ids.clone(),
            answer_session_ids:       s.answer_session_ids.clone(),
            retrieved_uuid_count:     s.retrieved_uuid_count,
        })
        .collect();

    // ── Token efficiency (LME-03 additive key) ─────────────────────────────────
    // Build questionID → concatenated has_answer turn text. Real HuggingFace
    // corpus has no has_answer annotations — lookup will be empty, making all
    // evidence hit fields None. Only the hand-authored synthetic sample carries them.
    let has_answer_lookup: HashMap<&str, String> = corpus
        .questions
        .iter()
        .filter_map(|q| {
            let evidence: String = q.haystack_sessions
                .iter()
                .flat_map(|s| s.iter())
                .filter(|t| t.has_answer)
                .map(|t| t.content.as_str())
                .collect::<Vec<_>>()
                .join("\n");
            if evidence.is_empty() { None } else { Some((q.question_id.as_str(), evidence)) }
        })
        .collect();

    let mut exact_tokens: Vec<usize> = Vec::new();
    let mut dense_tokens: Vec<usize> = Vec::new();
    let mut exact_hits: usize = 0;
    let mut dense_hits: usize = 0;
    let mut exact_evidence_count: usize = 0;
    let mut dense_evidence_count: usize = 0;

    for entry in payload_entries {
        if let Some(ref text) = entry.exact_payload_text {
            exact_tokens.push(lme_estimate_tokens(text));
            if let Some(evidence) = has_answer_lookup.get(entry.question_id.as_str()) {
                exact_evidence_count += 1;
                if lme_evidence_hit(evidence, text) {
                    exact_hits += 1;
                }
            }
        }
        if let Some(ref text) = entry.dense_payload_text {
            dense_tokens.push(lme_estimate_tokens(text));
            if let Some(evidence) = has_answer_lookup.get(entry.question_id.as_str()) {
                dense_evidence_count += 1;
                if lme_evidence_hit(evidence, text) {
                    dense_hits += 1;
                }
            }
        }
    }

    let exact_mean: Option<f64> = if exact_tokens.is_empty() { None } else {
        Some(exact_tokens.iter().sum::<usize>() as f64 / exact_tokens.len() as f64)
    };
    let dense_mean: Option<f64> = if dense_tokens.is_empty() { None } else {
        Some(dense_tokens.iter().sum::<usize>() as f64 / dense_tokens.len() as f64)
    };
    let ratio: Option<f64> = match (exact_mean, dense_mean) {
        (Some(e), Some(d)) if e > 0.0 => Some(d / e),
        _ => None,
    };
    let exact_hit_rate: Option<f64> = if exact_evidence_count > 0 {
        Some(exact_hits as f64 / exact_evidence_count as f64)
    } else { None };
    let dense_hit_rate: Option<f64> = if dense_evidence_count > 0 {
        Some(dense_hits as f64 / dense_evidence_count as f64)
    } else { None };
    let exact_hits_per_1k: Option<f64> = match (exact_hit_rate, exact_mean) {
        (Some(r), Some(m)) if m > 0.0 => Some(r * 1000.0 / m),
        _ => None,
    };
    let dense_hits_per_1k: Option<f64> = match (dense_hit_rate, dense_mean) {
        (Some(r), Some(m)) if m > 0.0 => Some(r * 1000.0 / m),
        _ => None,
    };

    let token_efficiency = LmeReportTokenEfficiency {
        exact_arm_mean_tokens:    exact_mean,
        dense_arm_mean_tokens:    dense_mean,
        dense_exact_token_ratio:  ratio,
        exact_evidence_hit_rate:  exact_hit_rate,
        dense_evidence_hit_rate:  dense_hit_rate,
        exact_hits_per_1k_tokens: exact_hits_per_1k,
        dense_hits_per_1k_tokens: dense_hits_per_1k,
    };

    LmeReport {
        run_id,
        run_label,
        variant,
        generated_at,
        corpus_stats,
        aggregate: report_aggregate,
        latency: report_latency,
        per_question,
        token_efficiency,
    }
}

/// Serializes and writes an `LmeReport` to a JSON file (pretty-printed).
pub fn write_lme_report(report: &LmeReport, path: &std::path::Path) -> Result<(), String> {
    let json = serde_json::to_string_pretty(report)
        .map_err(|e| format!("report encode failed: {e}"))?;
    // Sort keys for deterministic diffs. serde_json doesn't support sorted keys
    // directly on to_string_pretty — serialize through BTreeMap to sort.
    // Re-serialize the serde_json::Value to get sorted keys at every level.
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
