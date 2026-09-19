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
    /// Haystack turn position, or -1 for a derived (non-turn) document.
    pub turn_index: i64,
    pub session_index: usize,
    pub role: String,
}

// ─────────────────────────────────────────────────────────────────────────────
// UUID → session mapping
// ─────────────────────────────────────────────────────────────────────────────

/// Maps a UUID-ranked result list to a session-ranked list, preserving the rank
/// of each session's FIRST appearing UUID.
///
/// A UUID the manifest cannot map still OCCUPIES ITS RANK, under a placeholder
/// id that no answer id can equal. It must: dropping unmappable hits does not
/// make scoring conservative, it makes it wrong in the generous direction. Every
/// dropped hit closes the gap between rank 1 and the first answer, so a manifest
/// covering only the answer rows scores an answer at true rank 40 as rank 1 and
/// reports recall@5 of 1.0. The tell is recall-any@1 == @5 == @10: the ranked
/// list ends up shorter than k, so k stops mattering.
///
/// With a complete manifest no placeholder is ever emitted; a nonzero count
/// means a drawer came back that the run did not seed.
///
/// Each session appears at most once — duplicate UUIDs from the same session
/// after the first are ignored.
///
/// Twin of Swift `lmeRankedSessions(uuids:manifest:)`.
pub fn lme_ranked_sessions(uuids: &[String], manifest: &[LmeManifestEntry]) -> Vec<String> {
    lme_ranked_sessions_audited(uuids, manifest).0
}

/// `lme_ranked_sessions` plus the count of hits the manifest could not map, for
/// callers that surface manifest coverage as a run diagnostic. Twin of Swift
/// `lmeRankedSessionsAudited(uuids:manifest:)`.
pub fn lme_ranked_sessions_audited(
    uuids: &[String],
    manifest: &[LmeManifestEntry],
) -> (Vec<String>, usize) {
    let mut uuid_to_session: HashMap<&str, &str> = HashMap::with_capacity(manifest.len());
    for entry in manifest {
        uuid_to_session.insert(entry.uuid.as_str(), entry.session_id.as_str());
    }
    let mut seen: HashSet<String> = HashSet::new();
    let mut ranked: Vec<String> = Vec::with_capacity(uuids.len());
    let mut unmapped = 0usize;
    for uuid in uuids {
        let session_id = match uuid_to_session.get(uuid.as_str()) {
            Some(&mapped) => mapped.to_string(),
            None => {
                // NUL-prefixed so it can never collide with a real session id,
                // dia id, or sid; the uuid keeps distinct unmapped hits
                // distinct so each consumes exactly one rank slot.
                unmapped += 1;
                format!("\u{0}unmapped:{uuid}")
            }
        };
        if seen.insert(session_id.clone()) {
            ranked.push(session_id);
        }
    }
    (ranked, unmapped)
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
    /// Guard sampling policy active for this leg. Mirrors Swift `LMEQuestionResult.guardSamplingMode`.
    pub guard_sampling_mode: crate::degeneracy_guard::GuardSamplingPolicy,
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
    /// Did the gold answer text reach the judge's context? None when no judge
    /// payload was assembled. Retrieval ceiling for the judged metric — twin
    /// of Swift `exactGoldReachable`.
    pub exact_gold_reachable: Option<bool>,
    /// Estimated tokens of the (hydrated) exact-arm judge payload.
    pub exact_judge_tokens: Option<usize>,
    /// Estimated tokens of the dense-arm judge payload (the distillate).
    pub dense_judge_tokens: Option<usize>,
    /// Judge answer over the raw PREVIEW payload — the cheapest point of the
    /// three-way payload frontier (see the preview-judge block in the runner).
    pub preview_judge_answer: Option<String>,
    pub preview_judge_correct: Option<bool>,
    pub preview_judge_tokens: Option<usize>,
    /// Judge subprocess answer for the dense arm. None when judge_cmd was not set
    /// or the dense arm was not run.
    pub dense_judge_answer: Option<String>,
    /// True when dense_judge_answer contains the normalized gold answer as a
    /// substring. None when dense_judge_answer is None.
    pub dense_judge_correct: Option<bool>,
    /// Whether this question's estate was served from the snapshot cache.
    /// Some(true) = cache hit, Some(false) = cache miss, None = cache off.
    pub cache_hit: Option<bool>,
    /// Whether the drain barrier observed the corpus_encode lane registered
    /// before accepting idle. false = converged via the no-lanes grace window
    /// (ambiguous evidence). None = barrier did not run for this unit.
    /// Additive — FIX-HARNESS-20260727.
    pub drain_lane_observed: Option<bool>,
    // ── Synthesize arm (additive — PR-08 D3) ────────────────────────────────
    /// Raw payload text from the `moot_synthesize` call. moot_synthesize generates
    /// a direct answer without returning ranked IDs — no retrieval metric, only
    /// judge accuracy. None when synthesize_arm was off.
    pub synthesize_payload_text: Option<String>,
    /// Judge subprocess answer for the synthesize arm. None when synthesize_arm
    /// was off, the judge was not configured, or the arm errored.
    pub synthesize_judge_answer: Option<String>,
    /// True when synthesize_judge_answer contains the gold answer as a substring.
    /// None when synthesize_judge_answer is None.
    pub synthesize_judge_correct: Option<bool>,
    /// Estimated token count for the synthesize payload (byte-count/4 estimator).
    /// None when payload is None.
    pub synthesize_judge_tokens: Option<usize>,
    // ── Settle cell (--settle mode, Mission 11X-RECALL-GAP-01 Stream C) ───────
    /// UUIDs returned by the settled exact-arm query. None when settle was off or
    /// exact arm was not run.
    pub settled_retrieved_uuids: Option<Vec<String>>,
    /// Settled exact-arm query latency in seconds. None when settle was off.
    pub settled_query_latency_seconds: Option<f64>,
    /// Whether the post-reindex drain barrier observed the corpus_encode lane.
    /// None when settle was off.
    pub settled_drain_lane_observed: Option<bool>,
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
    // ── Settle cell (--settle mode, Mission 11X-RECALL-GAP-01 Stream C) ───────
    /// recall_any@5 for the SETTLED cell. None when settle was off.
    pub settled_recall_any_at_5: Option<f64>,
    /// MRR for the SETTLED cell. None when settle was off.
    pub settled_mrr: Option<f64>,
    /// Deduplicated session ranking for the SETTLED cell. None when settle was off.
    pub settled_ranked_session_ids: Option<Vec<String>>,
    /// Settled exact-arm query latency. None when settle was off.
    pub settled_query_latency_seconds: Option<f64>,
    /// Whether the post-reindex drain barrier observed corpus_encode lane.
    /// None when settle was off.
    pub settled_drain_lane_observed: Option<bool>,
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

    // ── Settle cell scoring (--settle mode, Mission 11X-RECALL-GAP-01 Stream C) ──
    // Mirror the organic scoring path using settled_retrieved_uuids.
    // Guard exclusion applies equally: non-healthy questions have no fitness signal
    // regardless of which cell is scored.
    let (settled_recall_any_at_5, settled_mrr, settled_ranked_session_ids) =
        if let Some(ref settled_uuids) = result.settled_retrieved_uuids {
            let settled_ranked = lme_ranked_sessions(settled_uuids, &result.manifest);
            let (any5, mrr_val) = if result.guard_healthy {
                (
                    lme_recall_any(&settled_ranked, &answer_ids, 5),
                    lme_session_mrr(&settled_ranked, &answer_ids),
                )
            } else {
                // Guard-excluded: sentinel zeros (not None) — the cell ran but
                // produced no fitness signal, consistent with organic treatment.
                (0.0, 0.0)
            };
            (Some(any5), Some(mrr_val), Some(settled_ranked))
        } else {
            (None, None, None)
        };

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
        settled_recall_any_at_5,
        settled_mrr,
        settled_ranked_session_ids,
        settled_query_latency_seconds: result.settled_query_latency_seconds,
        settled_drain_lane_observed: result.settled_drain_lane_observed,
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
// Provenance parsing helpers (Defect 3)
// ─────────────────────────────────────────────────────────────────────────────

/// Parses the result count N from the first line of a payload text.
/// Expected formats (ARIA_MCP_SPEC 2.0.0): "found N candidate memories, one per line"
/// (singular: "found 1 candidate memory, one per line") or "found N distilled factoid(s)".
/// Twin of Swift `lmeParseResultCount(_:)`.
pub fn lme_parse_result_count(payload_text: &str) -> Option<usize> {
    let first_line = payload_text.lines().next()?;
    let lower = first_line.to_lowercase();
    if !lower.contains("found ") {
        return None;
    }
    // Find "found " token, then parse the next whitespace-separated word as usize.
    let after = first_line.find("found ")
        .map(|i| &first_line[i + 6..])?;
    after.split_whitespace().next()?.parse::<usize>().ok()
}

/// Finds the first line containing "discrimination:" in payload text.
/// Twin of Swift `lmeParseDiscriminationLine(_:)`.
pub fn lme_parse_discrimination_line(payload_text: &str) -> Option<String> {
    payload_text
        .lines()
        .find(|l| l.contains("discrimination:"))
        .map(|l| l.trim().to_string())
}

/// Extracts the discrimination level token from a discrimination diagnostic line.
/// Expected format: "discrimination: <level>" where level is one of:
///   high | medium | low | not_found | n/a
/// Twin of Swift `lmeExtractDiscriminationLevel(_:)`.
pub fn lme_extract_discrimination_level(line: &str) -> String {
    line.split(':')
        .nth(1)
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "n/a".to_string())
}

// ─────────────────────────────────────────────────────────────────────────────
// JSON report types
// ─────────────────────────────────────────────────────────────────────────────

// ── Shape 3 conflict-key statistics (C10) ────────────────────────────────────

/// Statistics describing the LME corpus's conflict-key structure for Shape 3 grouping.
///
/// C10 conflict-key analysis finding: all LME-S questions have unique text and unique
/// Q+A pairs (0 conflicting question texts, 0 conflicting Q+A pairs). No structured
/// partition key is needed — the trivial grouping (all questions in one shared estate)
/// is the only valid Shape 3 topology for this corpus.
///
/// Session sharing (some session IDs appear in multiple questions' haystacks) is a
/// dataset design fact, not a conflict in the MemBench sense. MemBench required a key
/// because the SAME question appeared with DIFFERENT answers; LME never does.
///
/// Twin of Swift `LMEConflictKeyStats`.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct LmeConflictKeyStats {
    /// Identifying label for the partition key derived from this corpus.
    /// "none-questions-unique": all question texts are unique across the dataset,
    /// so no structured conflict key is needed — one shared estate covers all items.
    pub conflict_key: String,
    /// Number of non-overlapping groups the questions were partitioned into.
    /// 1 when using shared-estate mode (trivial single-group; all questions share one estate).
    pub group_count: usize,
    /// Total unique haystack session IDs across all questions in the corpus.
    pub total_unique_session_ids: usize,
    /// Count of session IDs that appear in 2 or more questions' haystacks.
    /// Reflects dataset construction, not competing answers.
    pub shared_session_count: usize,
    /// shared_session_count / total_unique_session_ids. Describes haystack overlap density.
    pub session_sharing_rate: f64,
}

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
#[derive(Debug, serde::Serialize, serde::Deserialize, Default)]
pub struct LmeReportLatency {
    pub query_p50_seconds: f64,
    pub query_p95_seconds: f64,
    pub query_mean_seconds: f64,
    pub write_mean_seconds: f64,
}

/// Aggregate discrimination health across the run (Defect 3).
/// Summarizes how often each discrimination level was observed.
/// Twin of Swift `LMEReportLaneHealth`.
///
/// NOTE: recall_provenance: is no longer emitted in search/get payloads as of
/// ARIA_MCP_SPEC 2.0.0 (moved to log-side only). The dark/degraded count
/// fields are always 0 in 2.0.0 runs; kept for report-schema stability.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct LmeReportLaneHealth {
    /// Distribution of discrimination levels seen in exact-arm responses.
    /// Keys: "high" | "medium" | "low" | "not_found" | "n/a".
    pub exact_discrimination_distribution: BTreeMap<String, usize>,
    /// Distribution of discrimination levels seen in dense-arm responses.
    pub dense_discrimination_distribution: BTreeMap<String, usize>,
    /// Always 0 in ARIA_MCP_SPEC 2.0.0 runs — recall_provenance no longer emitted.
    /// Kept for report-schema stability with pre-2.0.0 report consumers.
    pub exact_dense_lane_dark_count: usize,
    /// Always 0 in ARIA_MCP_SPEC 2.0.0 runs. Kept for report-schema stability.
    pub exact_degraded_count: usize,
    /// Always 0 in ARIA_MCP_SPEC 2.0.0 runs. Kept for report-schema stability.
    pub dense_degraded_count: usize,
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
    /// Query latency kept internally; not emitted in accuracy-lane JSON (2026-08-18 doctrine).
    #[serde(skip_serializing)]
    #[serde(default)]
    pub query_latency_seconds: f64,
    /// Write latency kept internally; not emitted in accuracy-lane JSON (2026-08-18 doctrine).
    #[serde(skip_serializing)]
    #[serde(default)]
    pub write_mean_latency_seconds: f64,
    pub ranked_session_ids: Vec<String>,
    pub answer_session_ids: Vec<String>,
    pub retrieved_uuid_count: usize,
    // ── Provenance fields (Defect 3) ──────────────────────────────────────────
    /// Parsed "discrimination: <level>" diagnostic from exact-arm response.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exact_discrimination: Option<String>,
    /// Parsed "discrimination: <level>" diagnostic from dense-arm response.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dense_discrimination: Option<String>,
    /// Whether this question's estate was served from the snapshot cache.
    /// Some(true) = hit, Some(false) = miss, None = cache off.
    /// Additive key per BENCHMARKER_OPTIMIZER_CONTRACT.md.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_hit: Option<bool>,
    /// Whether the drain barrier observed the corpus_encode lane registered
    /// before accepting idle. false = converged via the no-lanes grace window
    /// (ambiguous evidence). None = barrier did not run for this unit.
    /// Additive — FIX-HARNESS-20260727.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub drain_lane_observed: Option<bool>,
    // ── Settle cell (--settle mode, Mission 11X-RECALL-GAP-01 Stream C) ───────
    /// recall_any@5 for the SETTLED cell (after moot_reindex + drain).
    /// None when --settle was not set.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub settled_recall_any_at_5: Option<f64>,
    /// MRR for the SETTLED cell. None when --settle was not set.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub settled_mrr: Option<f64>,
    /// Deduplicated session ranking for the SETTLED cell. None when --settle was not set.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub settled_ranked_session_ids: Option<Vec<String>>,
    /// Settled exact-arm query latency in seconds. None when --settle was not set.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub settled_query_latency_seconds: Option<f64>,
    /// Whether the post-reindex drain barrier observed the corpus_encode lane.
    /// None when --settle was not set.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub settled_drain_lane_observed: Option<bool>,
}

/// Token efficiency block of the LME report. Additive key added by LME-03.
/// All fields are Option: nil when the arm was not active, or when `has_answer`
/// annotations are absent from the corpus (the fetched cleaned fixtures
/// carry the field; a corpus without it yields None).
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
    // ── Per-result token metrics (Defect 2) ───────────────────────────────────
    /// Mean tokens per returned result for the exact arm.
    /// Parsed result count N from "found N memory(s)" prefix in payload text.
    /// None when result count could not be parsed or no exact payloads.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exact_tokens_per_result: Option<f64>,
    /// Mean tokens per returned result for the dense arm.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dense_tokens_per_result: Option<f64>,
    /// dense / exact per-result token ratio.
    /// Exposes arithmetic-cancellation: when result counts differ between arms,
    /// this ratio diverges from the simple byte/token ratio even when total
    /// byte counts are similar.
    /// None when either per-result value is absent or exact is 0.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dense_exact_tokens_per_result_ratio: Option<f64>,
}

/// Testmark cell descriptor, additive to every LME report.
///
/// When --settle is off, `enabled` is false and settle fields are None.
/// When --settle is on, both ORGANIC and SETTLED cells are documented.
///
/// Self-documentation rationale: with two-tier vector composition the ORGANIC
/// and SETTLED states differ because mechanical stopword-strip composes the
/// initial vector at ingest and the full distillate recomposes it on the
/// background sweep. moot_reindex triggers the background backfill to ensure
/// the settled cell reflects full coverage before being measured. Neither cell
/// may substitute for the other in published numbers.
///
/// Twin of Swift `LMETestmarkCells`.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct LmeTestmarkCells {
    /// True when the settle flag was active for this run.
    pub enabled: bool,
    /// Ordered cells produced by this run: ["organic"] or ["organic", "settled"].
    pub cells: Vec<String>,
    /// MCP tool invoked to trigger settling. None when settle is off.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub settle_trigger_tool: Option<String>,
    /// Human-readable description of what the settle trigger does. None when settle is off.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub settle_trigger_description: Option<String>,
    /// Rationale for tracking both cells. None when settle is off.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rationale: Option<String>,
    /// Aggregate metrics for the SETTLED cell. None when settle is off.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub settled_aggregate: Option<LmeReportAggregate>,
}

/// Synthesize arm descriptor, additive to every LME report. Twin of Swift
/// `LMESynthesizeCell`. CodingKey: "synthesize_cell".
///
/// When `enabled` is false, metric fields are None. When enabled,
/// `moot_synthesize` was called per question as the fourth payload mode
/// beside preview / distilled / full-hydrated. No retrieval metric; only
/// judge accuracy is measurable when a judge is configured.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct LmeSynthesizeCell {
    /// True when at least one question produced a synthesize payload. Derived
    /// from the payloads themselves, never from the `--synthesize-arm` flag: a
    /// descriptor whose `enabled` comes from a flag reports the operator's
    /// intent as though it were a measurement.
    pub enabled: bool,
    /// Number of questions that produced a synthesize payload.
    pub question_count: usize,
    /// Number of questions where the judge graded the synthesize payload.
    /// None when no judge was configured or no payloads were produced.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub judged_count: Option<usize>,
    /// Fraction of judged questions where synthesize_judge_correct is true.
    /// None when judged_count is None or zero.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accuracy_rate: Option<f64>,
}

/// Lightweight per-question payload snapshot, extracted before results are
/// consumed by `score_lme_question`. Passed to `build_lme_report` so it can
/// compute the `token_efficiency` block without needing the full results vec.
pub struct LmePayloadEntry {
    pub question_id: String,
    pub exact_payload_text: Option<String>,
    pub dense_payload_text: Option<String>,
}

/// Every run option that moves the accuracy number, recorded so a published
/// cell can be attributed to the configuration that produced it.
///
/// The defect this closes: an option is parsed, honoured, and printed to
/// stdout, but never persisted — so two runs at different settings produce
/// different accuracy with no machine-readable record of why. Judge hydration
/// depth is the measured example, but the audit found it was one of nine.
///
/// Grouped into one nested block rather than loose top-level keys so that
/// adding the next parameter does not widen `build_lme_report`'s signature —
/// that function already carries a transposition hazard (see its parameter
/// comments) and more positional `String` params would compound it.
///
/// Twin of Swift `LMEReportRunParameters`, with three keys absent: this
/// port's `LmeRunConfig` has no `offset`, no `fresh_per_question`, and no
/// `synthesize_limit` option (this port never calls moot_synthesize), so
/// there is no true value to record. They are omitted rather than
/// fabricated. The `slice` key IS present in this port — the Rust runner
/// implements the full slice partition.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct LmeReportRunParameters {
    /// How many ranked hits were hydrated to full content for the judge.
    /// Recall is scored over SESSIONS while the judge reads DRAWERS, so a
    /// deeper window hands the judge more chances to see the answer-bearing
    /// turn. This is the parameter MXE-BK was opened for.
    pub judge_hydration_depth: usize,
    /// "substring" or "verdict". `LmeJudgeGrading`'s own documentation says a
    /// run must record which it used — the two modes answer different
    /// questions and produce different numbers on identical answers.
    pub judge_grading: String,
    /// Whether a judge command was configured at all. This presence flag is
    /// the ONLY thing the report records about `--judge-cmd`. The command is
    /// user-supplied shell that routinely carries API keys, and the report is
    /// a published artefact — so neither the command NOR ANYTHING DERIVED
    /// FROM IT (a hash, a digest, a truncation) may appear here. A digest of
    /// a secret-bearing string lets a report recipient confirm guesses of the
    /// command offline; no salt or slower hash changes that property, so do
    /// not reintroduce a "safer" fingerprint. If a stronger run identifier is
    /// ever needed, the correct shape is an explicit non-secret label the
    /// operator authors for publication — opt-in, never derived.
    pub judge_cmd_set: bool,
    /// Whether a rerank command was configured at all. Same secrecy rule as
    /// `judge_cmd_set`: the command is user-supplied shell that routinely
    /// carries API keys. Presence only — never the command text nor anything
    /// derived from it.
    #[serde(rename = "rerank_cmd_set")]
    pub rerank_cmd_set: bool,
    /// Which recall arm(s) produced numbers: "exact", "dense" or "both".
    pub arm: String,
    /// Exact-arm retrieval strategy. These are different retrieval verbs, so
    /// different text reaches the judge.
    pub exact_strategy: String,
    /// RecallShape preset steering the fusion under `--exact-strategy shaped`.
    /// `None` means the product's default preset was used.
    pub recall_shape: Option<String>,
    /// Seed for the deterministic question shuffle. Two runs at the same limit
    /// with different seeds score different question sets.
    pub seed: u64,
    /// Question cap. `None` = all non-abstention questions.
    pub limit: Option<usize>,
    /// The `--slice` partition selected for this run: "dev" (first 50 of the
    /// seeded shuffle), "holdout" (after the first 50), or `None` when the flag
    /// was absent (full set). Omitted from JSON when `None` to preserve backward
    /// compatibility with pre-slice reports.
    ///
    /// Cells produced with and without this flag are NOT interchangeable —
    /// record the value in every run. Absent = full set.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub slice: Option<String>,
}

/// The full LME run report.
/// Additive/compatible with BENCHMARKER_OPTIMIZER_CONTRACT.md §1.2.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct LmeReport {
    /// The estate schema the harness was built against, stamped into every
    /// report so the results record can carry the column without anyone typing
    /// it (BENCHMARK_PROTOCOL §9). Twin of Swift `estateSchemaVersion`.
    pub estate_schema_version: String,
    pub run_id: String,
    pub run_label: String,
    pub variant: String,
    pub generated_at: String,
    /// Measurement protocol identity. "v2-dreamed" = ingest → encode
    /// barrier → full cognition pass (moot_dream associates=all) → queries
    /// (2026-08-05 ruling). Pre-v2 reports lack the field entirely.
    #[serde(rename = "protocol")]
    pub protocol_version: String,
    /// Encode-queue synchronization strategy used for this run (Defect 1).
    /// One of: "drain" | "impatient" | "none". Self-documenting in the report.
    pub encode_barrier: String,
    /// Guard probe sampling policy for the leg ("once" or "per-unit", C5).
    pub guard_sampling: String,
    /// Backend shape for the scratch estate used in this run. C1.
    /// "disk" = SQLite (default); "ram" = PersistenceKit InMemory.
    /// Cells at different shapes are not directly comparable.
    pub shape: String,
    /// Number of questions run concurrently. C6.
    /// Internal only — never emitted: a run is a run; width is not a
    /// property of accuracy figures.
    #[serde(skip_serializing)]
    #[serde(default)]
    pub parallel_units: usize,
    pub corpus_stats: LmeReportCorpusStats,
    pub aggregate: LmeReportAggregate,
    /// Latency stats kept internally for console output; not emitted in accuracy-lane JSON (2026-08-18 doctrine).
    #[serde(skip_serializing)]
    #[serde(default)]
    pub latency: LmeReportLatency,
    pub per_question: Vec<LmeReportPerQuestion>,
    /// Token efficiency metrics (LME-03, additive per BENCHMARKER_OPTIMIZER_CONTRACT.md).
    pub token_efficiency: LmeReportTokenEfficiency,
    /// Aggregate discrimination and recall provenance health (Defect 3).
    pub lane_health: LmeReportLaneHealth,
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
    /// Whether corpus-side preference extraction was applied before ingest.
    /// Always false in this port — no extraction build exists. The key stays
    /// in the report so a cell remains attributable to its corpus shape after
    /// the fact (MXE-CA contract key).
    pub preference_extraction: bool,
    // ── Testmark cells (additive — Mission 11X-RECALL-GAP-01 Stream C) ─────────
    /// Testmark cell descriptor. Always present; `enabled` is false when
    /// --settle was not used.
    pub testmark_cells: LmeTestmarkCells,
    // ── Synthesize cell (additive — PR-08 D3) ────────────────────────────────
    /// Synthesize arm descriptor. Always present; every field is derived from
    /// observed results rather than from `--synthesize-arm`. On this port that
    /// means `enabled` is always false, because the per-question runner does not
    /// call moot_synthesize — see the builder comment and the flag-parse warning
    /// in main.rs. Supplying the flag does not change what this cell reports.
    pub synthesize_cell: LmeSynthesizeCell,
    // ── Run parameters (additive — MXE-BK) ────────────────────────────────────
    /// Every run option that moves the accuracy number. Always present.
    /// Without it, two cells at different judge hydration depths, grading
    /// modes or retrieval strategies are indistinguishable in the report.
    pub run_parameters: LmeReportRunParameters,
    // ── Rerank cell (additive — W2-rerank) ───────────────────────────────────
    /// Count of questions where the rerank command returned an unparseable
    /// reply. Omitted entirely when `--rerank-cmd` was not supplied — the
    /// field's presence is diagnostic; zero failures with the flag absent
    /// and zero failures with the flag present are different facts.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "rerank_failures")]
    pub rerank_failures: Option<u64>,
    // MARK: Binary identity (additive — JB-01, slimmed 2026-08-18 doctrine)
    /// Binary and protocol identity captured at run start. Accuracy lane emits
    /// only the three identity fields; full machine profile is the timing lane's concern.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "run_environment")]
    pub identity_environment: Option<crate::run_environment::IdentityEnvironment>,
    // MARK: Timing report (additive — C4, not emitted in accuracy lane 2026-08-18)
    /// Verbatim text of `moot_timing_report`. Kept for console output; not emitted
    /// in accuracy-lane JSON (2026-08-18 doctrine).
    #[serde(skip_serializing)]
    #[serde(default)]
    pub timing_report: Option<String>,
    /// Labels the once-per-leg sampling strategy. Not emitted in accuracy-lane JSON
    /// (2026-08-18 doctrine).
    #[serde(skip_serializing)]
    #[serde(default)]
    pub timing_sampling: String,
    // MARK: Shape 3 deviation label (additive — C10) ─────────────────────────
    /// The estate topology used for this run.
    /// "standard" = one fresh estate per question (the published per-item protocol).
    /// "consolidated-shape3" = one shared estate for all questions (Shape 3 deviation).
    /// The Rust port has no shared-estate execution path; always "standard" here.
    #[serde(rename = "estate_shape")]
    pub estate_shape: String,
    /// True when this run departs from the published per-item measurement protocol.
    /// Always false on the Rust port (no shared-estate execution path).
    #[serde(rename = "protocol_deviation")]
    pub protocol_deviation: bool,
    /// Conflict-key statistics from the corpus. Present when estate_shape ==
    /// "consolidated-shape3"; absent otherwise.
    /// Always absent on the Rust port (no shared-estate execution path).
    #[serde(rename = "conflict_key_stats")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub conflict_key_stats: Option<LmeConflictKeyStats>,
}

/// Assembles an `LmeReport` from scores and metadata.
///
/// `corpus` and `payload_entries` are needed to compute the `token_efficiency`
/// and `lane_health` blocks. `cache_hit_by_id` maps question_id → cache_hit for
/// per-question report population and aggregate counts. `estate_cache` is the
/// cache-mode string ("off" | "reuse").
pub fn build_lme_report(
    run_id: String,
    run_label: String,
    variant: String,
    generated_at: String,
    encode_barrier: String,
    guard_sampling: String,
    // C1: backend shape string ("disk" or "ram"). Additive report key.
    shape: String,
    // C6: effective number of concurrent questions (1 = serial). Additive.
    parallel_units: usize,
    questions_loaded: usize,
    abstention_excluded: usize,
    scores: &[LmeQuestionScore],
    corpus: &LmeCorpus,
    payload_entries: &[LmePayloadEntry],
    cache_hit_by_id: &HashMap<String, Option<bool>>,
    drain_lane_by_id: &HashMap<String, Option<bool>>,
    // Parameter order matches the call site in main.rs and the sibling
    // builders (build_locomo_report / build_lmeb_report): estate_cache FIRST.
    // Both params are String — a transposition compiles clean and silently
    // swaps the two report keys.
    estate_cache: String,
    estate_encryption: String,
    // Ingest granularity of this run ("turn" | "session").
    granularity: String,
    // preference_extraction: whether corpus-side preference extraction was
    // applied before ingest (always false; report contract key).
    preference_extraction: bool,
    // --settle mode: whether both ORGANIC and SETTLED cells were run.
    settle: bool,
    // Per-question synthesize results — (payload text, judge correct) per question.
    // The synthesize cell descriptor is computed entirely from these observed
    // results; the --synthesize-arm flag is deliberately not a parameter here.
    synthesize_results: &[(Option<String>, Option<bool>)],
    // Every run option that moves the accuracy number, passed as ONE struct.
    // Deliberately not a run of loose positional params: the String params
    // above already carry a transposition hazard (see their comment), and a
    // struct makes each field name-checked at the call site.
    run_parameters: LmeReportRunParameters,
    // Count of rerank-command parse failures for this run. None when
    // --rerank-cmd was not supplied; zero is a distinct meaningful value.
    rerank_failures: Option<u64>,
    // Binary identity captured once at subcommand start (JB-01, slimmed 2026-08-18).
    // None when the binary path was unavailable; all new runs should supply Some(env).
    identity_environment: Option<crate::run_environment::IdentityEnvironment>,
    // C4: verbatim moot_timing_report text from the first settled estate.
    // None when no question reached a settle point (every unit cache-hit).
    // Not emitted in accuracy-lane JSON (2026-08-18 doctrine).
    timing_report: Option<String>,
    // C10: Shape 3 conflict-key stats. Some when running in consolidated Shape 3
    // mode (shared-estate); None for standard fresh-per-question runs.
    // The Rust port has no shared-estate execution path; callers always pass None.
    // The parameter exists so the Rust report struct carries the same JSON keys as
    // the Swift twin, satisfying the byte-identical field-name contract.
    conflict_key_stats: Option<LmeConflictKeyStats>,
) -> LmeReport {
    let (aggregate, latency) = aggregate_lme_scores(scores);
    let guard_excluded = scores.iter().filter(|s| !s.guard_healthy).count();
    let cache_hits:   usize = cache_hit_by_id.values().filter(|&&v| v == Some(true)).count();
    let cache_misses: usize = cache_hit_by_id.values().filter(|&&v| v == Some(false)).count();

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

    // ── Provenance lookup (Defect 3): parse per-question discrimination lines ───
    // Build a map from question_id → (exact_discrimination, dense_discrimination).
    // recall_provenance: is no longer emitted in search/get payloads as of
    // ARIA_MCP_SPEC 2.0.0 (moved to log-side only).
    struct ProvenanceEntry {
        exact_discrimination: Option<String>,
        dense_discrimination: Option<String>,
    }
    let provenance_lookup: HashMap<String, ProvenanceEntry> = payload_entries
        .iter()
        .map(|entry| {
            let exact_discrimination = entry.exact_payload_text.as_deref()
                .and_then(lme_parse_discrimination_line);
            let dense_discrimination = entry.dense_payload_text.as_deref()
                .and_then(lme_parse_discrimination_line);
            (entry.question_id.clone(), ProvenanceEntry {
                exact_discrimination,
                dense_discrimination,
            })
        })
        .collect();

    let per_question: Vec<LmeReportPerQuestion> = scores
        .iter()
        .map(|s| {
            let prov = provenance_lookup.get(&s.question_id);
            LmeReportPerQuestion {
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
                exact_discrimination:     prov.and_then(|p| p.exact_discrimination.clone()),
                dense_discrimination:     prov.and_then(|p| p.dense_discrimination.clone()),
                // Look up cache_hit from the raw results map (key = question_id).
                cache_hit: cache_hit_by_id.get(&s.question_id).copied().flatten(),
                drain_lane_observed: drain_lane_by_id.get(&s.question_id).copied().flatten(),
                // Settle cell fields — sourced from LmeQuestionScore (scored by score_lme_question).
                settled_recall_any_at_5: s.settled_recall_any_at_5,
                settled_mrr: s.settled_mrr,
                settled_ranked_session_ids: s.settled_ranked_session_ids.clone(),
                settled_query_latency_seconds: s.settled_query_latency_seconds,
                settled_drain_lane_observed: s.settled_drain_lane_observed,
            }
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
    let mut exact_result_counts: Vec<usize> = Vec::new();
    let mut dense_result_counts: Vec<usize> = Vec::new();
    let mut exact_hits: usize = 0;
    let mut dense_hits: usize = 0;
    let mut exact_evidence_count: usize = 0;
    let mut dense_evidence_count: usize = 0;

    for entry in payload_entries {
        if let Some(ref text) = entry.exact_payload_text {
            exact_tokens.push(lme_estimate_tokens(text));
            if let Some(n) = lme_parse_result_count(text) {
                exact_result_counts.push(n);
            }
            if let Some(evidence) = has_answer_lookup.get(entry.question_id.as_str()) {
                exact_evidence_count += 1;
                if lme_evidence_hit(evidence, text) {
                    exact_hits += 1;
                }
            }
        }
        if let Some(ref text) = entry.dense_payload_text {
            dense_tokens.push(lme_estimate_tokens(text));
            if let Some(n) = lme_parse_result_count(text) {
                dense_result_counts.push(n);
            }
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

    // ── Per-result token metrics (Defect 2) ───────────────────────────────────
    let exact_tpr: Option<f64> = if exact_tokens.len() == exact_result_counts.len()
        && !exact_tokens.is_empty()
    {
        let total_tokens: usize = exact_tokens.iter().sum();
        let total_results: usize = exact_result_counts.iter().sum();
        if total_results > 0 {
            Some(total_tokens as f64 / total_results as f64)
        } else { None }
    } else { None };

    let dense_tpr: Option<f64> = if dense_tokens.len() == dense_result_counts.len()
        && !dense_tokens.is_empty()
    {
        let total_tokens: usize = dense_tokens.iter().sum();
        let total_results: usize = dense_result_counts.iter().sum();
        if total_results > 0 {
            Some(total_tokens as f64 / total_results as f64)
        } else { None }
    } else { None };

    let tpr_ratio: Option<f64> = match (exact_tpr, dense_tpr) {
        (Some(e), Some(d)) if e > 0.0 => Some(d / e),
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
        exact_tokens_per_result:  exact_tpr,
        dense_tokens_per_result:  dense_tpr,
        dense_exact_tokens_per_result_ratio: tpr_ratio,
    };

    // ── Lane health (Defect 3) ────────────────────────────────────────────────
    // Aggregate discrimination levels across all questions.
    // recall_provenance: is no longer emitted in search/get payloads as of
    // ARIA_MCP_SPEC 2.0.0 (moved to log-side). The dark/degraded counts are
    // always 0; kept for report-schema stability.
    let mut exact_disc_dist: BTreeMap<String, usize> = BTreeMap::new();
    let mut dense_disc_dist: BTreeMap<String, usize> = BTreeMap::new();

    for entry in payload_entries {
        if let Some(ref text) = entry.exact_payload_text {
            if let Some(disc_line) = lme_parse_discrimination_line(text) {
                let level = lme_extract_discrimination_level(&disc_line);
                *exact_disc_dist.entry(level).or_insert(0) += 1;
            }
        }
        if let Some(ref text) = entry.dense_payload_text {
            if let Some(disc_line) = lme_parse_discrimination_line(text) {
                let level = lme_extract_discrimination_level(&disc_line);
                *dense_disc_dist.entry(level).or_insert(0) += 1;
            }
        }
    }

    let lane_health = LmeReportLaneHealth {
        exact_discrimination_distribution: exact_disc_dist,
        dense_discrimination_distribution: dense_disc_dist,
        // Always 0 in ARIA_MCP_SPEC 2.0.0 runs — recall_provenance no longer emitted.
        exact_dense_lane_dark_count: 0,
        exact_degraded_count: 0,
        dense_degraded_count: 0,
    };

    // ── Testmark cells (additive — Mission 11X-RECALL-GAP-01 Stream C) ─────────
    // Build the SETTLED cell aggregate from guard-healthy scores when --settle was active.
    // Only recall_any@5 and MRR are tracked for the settled cell; other variants are 0.0.
    let settled_aggregate: Option<LmeReportAggregate> = if settle {
        let healthy: Vec<&LmeQuestionScore> = scores.iter().filter(|s| s.guard_healthy).collect();
        if healthy.is_empty() {
            None
        } else {
            let n = healthy.len() as f64;
            // compactMap equivalent: guard-excluded questions carry 0.0 (not None),
            // so sentinel zeros contribute correctly to the mean.
            let any5_sum: f64 = healthy.iter().filter_map(|s| s.settled_recall_any_at_5).sum();
            let mrr_sum:  f64 = healthy.iter().filter_map(|s| s.settled_mrr).sum();
            Some(LmeReportAggregate {
                query_count:      healthy.len(),
                recall_any_at_1:  0.0,  // not tracked for the settled cell
                recall_any_at_5:  any5_sum / n,
                recall_any_at_10: 0.0,  // not tracked for the settled cell
                recall_all_at_1:  0.0,  // not tracked for the settled cell
                recall_all_at_5:  0.0,  // not tracked for the settled cell
                recall_all_at_10: 0.0,  // not tracked for the settled cell
                mrr:              mrr_sum / n,
            })
        }
    } else {
        None
    };
    let testmark_cells = LmeTestmarkCells {
        enabled: settle,
        cells: if settle {
            vec!["organic".to_string(), "settled".to_string()]
        } else {
            vec!["organic".to_string()]
        },
        settle_trigger_tool: if settle { Some(crate::aria_v2_surface::REINDEX.to_string()) } else { None },
        settle_trigger_description: if settle {
            Some(
                "Triggers background backfill of every unindexed drawer to full coverage; \
                 corpus_encode drain barrier polled until idle before re-running queries \
                 as the settled cell."
                    .to_string(),
            )
        } else {
            None
        },
        rationale: if settle {
            Some(
                "With two-tier vector composition, ORGANIC (query immediately after ingest \
                 and drain) and SETTLED (query after moot_reindex and drain) are two \
                 distinct performance states; neither may substitute for the other in \
                 published numbers."
                    .to_string(),
            )
        } else {
            None
        },
        settled_aggregate,
    };

    // ── Synthesize cell descriptor (PR-08 D3) ────────────────────────────────
    // Every field here derives from OBSERVED results, never from the
    // `synthesize_arm` flag. The flag says what was asked for; these fields say
    // what happened. The Rust port does not yet call moot_synthesize per question
    // (see the warning emitted at flag-parse time in main.rs), so a run with
    // --synthesize-arm produces no payloads and this cell correctly reports
    // enabled: false, question_count: 0.
    //
    // The builder takes no `synthesize_arm` parameter. It used to, and `enabled`
    // was assigned from it — a descriptor cell whose `enabled` comes from a flag
    // reports the operator's intent as though it were a measurement. There is
    // nothing left for the flag to say here, so it is not threaded in; a wired
    // arm will show up in `synthesize_results` on its own.
    //
    // A question counts as synthesized when it produced a payload. Judged is the
    // subset of those that also came back from the judge.
    let synth_question_count = synthesize_results
        .iter()
        .filter(|(payload, _)| payload.is_some())
        .count();
    let judged: Vec<Option<bool>> = synthesize_results
        .iter()
        .filter(|(payload, _)| payload.is_some())
        .map(|(_, correct)| *correct)
        .collect();
    let (judged_count, accuracy_rate) = if judged.is_empty() {
        (None, None)
    } else {
        let correct = judged.iter().filter(|c| **c == Some(true)).count();
        let acc = correct as f64 / judged.len() as f64;
        (Some(judged.len()), Some(acc))
    };
    let synthesize_cell = LmeSynthesizeCell {
        enabled: synth_question_count > 0,
        question_count: synth_question_count,
        judged_count,
        accuracy_rate,
    };

    LmeReport {
        estate_schema_version: crate::artifact_manifest::CURRENT_ESTATE_SCHEMA_VERSION.to_string(),
        run_id,
        run_label,
        variant,
        generated_at,
        protocol_version: "v2-dreamed".to_string(),
        encode_barrier,
        guard_sampling,
        shape,
        parallel_units,
        corpus_stats,
        aggregate: report_aggregate,
        latency: report_latency,
        per_question,
        token_efficiency,
        lane_health,
        estate_cache,
        estate_encryption,
        granularity,
        preference_extraction,
        cache_hits,
        cache_misses,
        testmark_cells,
        synthesize_cell,
        run_parameters,
        rerank_failures,
        identity_environment,
        timing_report,
        timing_sampling: "once-per-leg".to_string(),
        // C10: Shape 3 deviation label. Derived from conflict_key_stats: Some → Shape 3.
        estate_shape: if conflict_key_stats.is_some() {
            "consolidated-shape3".to_string()
        } else {
            "standard".to_string()
        },
        protocol_deviation: conflict_key_stats.is_some(),
        conflict_key_stats,
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
    // Records are never overwritten (2026-08-17).
    crate::record_writer::write_record_never_overwrite(sorted_json.as_bytes(), path)
        .map_err(|e| format!("report write failed: {e}"))
}

/// Recursively sorts JSON object keys (matching JSONEncoder `.sortedKeys`).
pub fn sorted_json_value(v: &serde_json::Value) -> serde_json::Value {
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

// ─────────────────────────────────────────────────────────────────────────────
// Judge accuracy aggregation (answer-accuracy path)
// ─────────────────────────────────────────────────────────────────────────────

/// Per-arm judged-answer accuracy. Twin of Swift `LMEJudgeArmAccuracy`.
pub struct LmeJudgeArmAccuracy {
    pub judged: usize,
    pub correct: usize,
    pub accuracy: f64,
}

/// Judge accuracy across arms, tagged with the grading mode that produced it
/// (the two modes are not comparable to each other). Twin of Swift
/// `LMEJudgeAccuracy`.
pub struct LmeJudgeAccuracy {
    pub grading: String,
    pub exact: Option<LmeJudgeArmAccuracy>,
    pub dense: Option<LmeJudgeArmAccuracy>,
    // MARK: Synthesize arm (additive — PR-08 D3)
    /// Accuracy for the synthesize arm. None when synthesize_arm was off or
    /// the judge was not configured. moot_synthesize generates a direct answer
    /// without returning ranked IDs — only judge accuracy is measurable.
    pub synthesize: Option<LmeJudgeArmAccuracy>,
}

/// Aggregates judged-answer accuracy per arm. Returns None when no judge ran
/// on any arm — a run without a judge has no accuracy, and 0.0 would read as
/// "answered nothing correctly" rather than "did not measure". Twin of Swift
/// `lmeAggregateJudgeAccuracy(_:grading:)`.
pub fn lme_aggregate_judge_accuracy(
    results: &[LmeQuestionResult],
    grading: &str,
) -> Option<LmeJudgeAccuracy> {
    fn arm(judged_correct: Vec<(bool, Option<bool>)>) -> Option<LmeJudgeArmAccuracy> {
        let judged: Vec<&(bool, Option<bool>)> =
            judged_correct.iter().filter(|(answered, _)| *answered).collect();
        if judged.is_empty() {
            return None;
        }
        let correct = judged.iter().filter(|(_, c)| *c == Some(true)).count();
        Some(LmeJudgeArmAccuracy {
            judged: judged.len(),
            correct,
            accuracy: correct as f64 / judged.len() as f64,
        })
    }

    let exact = arm(results
        .iter()
        .map(|r| (r.exact_judge_answer.is_some(), r.exact_judge_correct))
        .collect());
    let dense = arm(results
        .iter()
        .map(|r| (r.dense_judge_answer.is_some(), r.dense_judge_correct))
        .collect());
    let synthesize = arm(results
        .iter()
        .map(|r| (r.synthesize_judge_answer.is_some(), r.synthesize_judge_correct))
        .collect());
    if exact.is_none() && dense.is_none() && synthesize.is_none() {
        return None;
    }
    Some(LmeJudgeAccuracy {
        grading: grading.to_string(),
        exact,
        dense,
        synthesize,
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // MARK: - Provenance parsing (Defect 3)

    #[test]
    fn parse_result_count_memory() {
        // "found N memory(s)" prefix
        let payload = "found 5 memory(s)\nsome content\ndiscrimination: high";
        assert_eq!(lme_parse_result_count(payload), Some(5));
    }

    #[test]
    fn parse_result_count_distilled() {
        // "found N distilled factoid(s)" prefix (dense arm)
        let payload = "found 3 distilled factoid(s)\nsome factoid text";
        assert_eq!(lme_parse_result_count(payload), Some(3));
    }

    #[test]
    fn parse_result_count_no_found() {
        let payload = "no results returned";
        assert_eq!(lme_parse_result_count(payload), None);
    }

    #[test]
    fn parse_result_count_zero() {
        let payload = "found 0 candidate memories, one per line";
        assert_eq!(lme_parse_result_count(payload), Some(0));
    }

    #[test]
    fn parse_discrimination_line_present() {
        let payload = "found 5 candidate memories, one per line\ndiscrimination: high";
        let line = lme_parse_discrimination_line(payload);
        assert!(line.is_some());
        assert!(line.unwrap().contains("discrimination:"));
    }

    #[test]
    fn parse_discrimination_line_absent() {
        let payload = "found 5 candidate memories, one per line\nsome content";
        assert_eq!(lme_parse_discrimination_line(payload), None);
    }

    #[test]
    fn extract_discrimination_level_high() {
        assert_eq!(lme_extract_discrimination_level("discrimination: high"), "high");
    }

    #[test]
    fn extract_discrimination_level_medium() {
        assert_eq!(lme_extract_discrimination_level("discrimination: medium"), "medium");
    }

    #[test]
    fn extract_discrimination_level_not_found() {
        assert_eq!(lme_extract_discrimination_level("discrimination: not_found"), "not_found");
    }

    // MARK: - Tokens per result (Defect 2): arithmetic cancellation case
    //
    // 20 exact results × 168 chars each = 3360 bytes → ~840 tokens → 840/20 = 42 tpr
    // 8 dense results  × 414 chars each = 3312 bytes → ~828 tokens → 828/8  = ~103.5 tpr
    // Per-result ratio: ~103.5 / 42 ≈ 2.46 — clearly non-1.
    // Simple byte ratio: 3312 / 3360 ≈ 0.986 — almost 1.
    //
    // This is the arithmetic-cancellation case: per-result ratio diverges while
    // the simple byte ratio stays near 1. Confirms the metric is non-trivial.
    //
    // Twin of Swift `LMETokensPerResultTests.arithmeticCancellationCase`.
    #[test]
    fn arithmetic_cancellation_case() {
        use crate::longmemeval_token_efficiency::lme_estimate_tokens;

        let exact_char_count = 168_usize;
        let exact_result_count = 20_usize;
        let dense_char_count = 414_usize;
        let dense_result_count = 8_usize;

        let exact_payload = "a".repeat(exact_char_count * exact_result_count);
        let dense_payload  = "a".repeat(dense_char_count  * dense_result_count);

        // Prepend "found N" lines so the result-count parser fires.
        let exact_text = format!("found {} candidate memories, one per line\n{}", exact_result_count, &exact_payload);
        let dense_text = format!("found {} distilled factoid(s)\n{}", dense_result_count, &dense_payload);

        let exact_tokens = lme_estimate_tokens(&exact_text) as f64;
        let dense_tokens  = lme_estimate_tokens(&dense_text)  as f64;

        // Simple byte ratio should be close to 1.0.
        let byte_ratio = dense_tokens / exact_tokens;
        assert!((byte_ratio - 1.0).abs() < 0.05,
            "byte_ratio should be near 1.0, got {byte_ratio:.4}");

        // Per-result token counts.
        let exact_tpr = exact_tokens / exact_result_count as f64;
        let dense_tpr  = dense_tokens  / dense_result_count  as f64;
        let tpr_ratio  = dense_tpr / exact_tpr;

        // Per-result ratio should be significantly > 1.0 (approximately 2.5).
        assert!(tpr_ratio > 2.0,
            "tpr_ratio should be > 2.0, got {tpr_ratio:.4}");
        assert!(tpr_ratio < 4.0,
            "tpr_ratio should be < 4.0, got {tpr_ratio:.4}");
    }
}

#[cfg(test)]
mod report_provenance_tests {
    use super::*;

    /// Regression for the report-key ordering defect: the two
    /// String params of `build_lme_report` were transposed at the boundary —
    /// compiles clean, swaps the `estate_cache` / `estate_encryption` report
    /// keys. Distinct sentinel values assert each key carries its own value.
    #[test]
    fn build_lme_report_keys_not_transposed() {
        let corpus = LmeCorpus { questions: Vec::new(), abstention_count: 0 };
        let report = build_lme_report(
            "run-id".to_string(),
            "label".to_string(),
            "s".to_string(),
            "2026-01-01T00:00:00Z".to_string(),
            "drain".to_string(),
            "once".to_string(),
            "disk".to_string(),  // C1: shape sentinel
            1,                   // C6: parallel_units — serial for this boundary test
            0,
            0,
            &[],
            &corpus,
            &[],
            &HashMap::new(),
            &HashMap::new(),
            "CACHE-SENTINEL".to_string(),
            "ENCRYPTION-SENTINEL".to_string(),
            "GRANULARITY-SENTINEL".to_string(),
            true,   // preference_extraction: on, so a dropped thread reads as false
            false,  // settle: off for this boundary test
            &[],    // synthesize_results: empty
            test_run_parameters(),
            None,   // rerank_failures: flag absent
            None,   // identity_environment
            None,   // timing_report
            None,   // conflict_key_stats: standard (non-Shape-3) run
        );
        assert_eq!(report.estate_cache, "CACHE-SENTINEL");
        assert_eq!(report.estate_encryption, "ENCRYPTION-SENTINEL");
        assert_eq!(report.granularity, "GRANULARITY-SENTINEL");
        assert_eq!(report.encode_barrier, "drain");
        assert!(report.preference_extraction,
            "preference_extraction must arrive from the argument, not a default");
    }

    /// Minimal builder call for the MXE-CA cell tests. Everything not under test
    /// is a zero value; the two parameters that matter are threaded through.
    fn build_minimal_report(
        preference_extraction: bool,
        synthesize_results: &[(Option<String>, Option<bool>)],
    ) -> LmeReport {
        let corpus = LmeCorpus { questions: Vec::new(), abstention_count: 0 };
        build_lme_report(
            "run-id".to_string(),
            "label".to_string(),
            "s".to_string(),
            "2026-01-01T00:00:00Z".to_string(),
            "drain".to_string(),
            "once".to_string(),
            "disk".to_string(),  // C1: shape — disk for fixture reports
            1,                   // C6: parallel_units — serial for fixture reports
            0,
            0,
            &[],
            &corpus,
            &[],
            &HashMap::new(),
            &HashMap::new(),
            "off".to_string(),
            "plaintext-optout".to_string(),
            "turn".to_string(),
            preference_extraction,
            false,  // settle
            synthesize_results,
            test_run_parameters(),
            None,   // rerank_failures: flag absent in these fixture reports
            None,   // identity_environment
            None,   // timing_report
            None,   // conflict_key_stats: standard (non-Shape-3) run
        )
    }

    /// MXE-BK. The report must carry every option that moves the accuracy
    /// number, under stable contract keys, surviving a JSON round trip.
    /// Without this block two cells at different judge hydration depths or
    /// grading modes are indistinguishable in the report — the same disease
    /// MXE-CA fixed for `preference_extraction`.
    #[test]
    fn report_round_trips_run_parameters() {
        let report = build_minimal_report(false, &[]);
        let json = serde_json::to_string(&report).unwrap();
        let raw: serde_json::Value = serde_json::from_str(&json).unwrap();

        let rp = raw
            .get("run_parameters")
            .expect("additive key 'run_parameters' must be present");
        assert_eq!(rp["judge_hydration_depth"], 30);
        assert_eq!(rp["judge_grading"], "verdict");
        assert_eq!(rp["arm"], "both");
        assert_eq!(rp["exact_strategy"], "auto");
        assert_eq!(rp["recall_shape"], "balanced");
        assert_eq!(rp["seed"], 20_260_725u64);
        assert_eq!(rp["limit"], 10);

        let decoded: LmeReport = serde_json::from_str(&json).unwrap();
        assert_eq!(
            decoded.run_parameters.judge_hydration_depth, 30,
            "judge_hydration_depth must survive the round trip"
        );
        assert_eq!(decoded.run_parameters.judge_grading, "verdict");
    }

    /// The judge COMMAND is recorded as presence ONLY (MXE-JD). Its text is
    /// user-supplied shell that routinely carries API keys, so neither it nor
    /// anything derived from it may reach a published report — any
    /// fingerprint of the command, however hashed, lets a report recipient
    /// confirm offline guesses of it. Pinned so nobody adds a "safer" digest
    /// or "completes" the parameter set with the raw string.
    #[test]
    fn judge_command_leaves_no_trace_beyond_presence() {
        let report = build_minimal_report(false, &[]);
        let json = serde_json::to_string(&report).unwrap();
        let raw: serde_json::Value = serde_json::from_str(&json).unwrap();
        let rp = &raw["run_parameters"];

        assert_eq!(rp["judge_cmd_set"], true);
        assert!(
            rp.get("judge_cmd_digest").is_none(),
            "no fingerprint of the judge command may appear in the report"
        );
        assert!(
            rp.get("judge_cmd").is_none(),
            "the judge command string must NEVER be persisted to the report"
        );
    }

    /// Rerank command follows the same secrecy rule as the judge command:
    /// presence only (W2-rerank). Pinned so nobody adds a text field or digest.
    #[test]
    fn rerank_command_leaves_no_trace_beyond_presence() {
        let report = build_minimal_report(false, &[]);
        let json = serde_json::to_string(&report).unwrap();
        let raw: serde_json::Value = serde_json::from_str(&json).unwrap();
        let rp = &raw["run_parameters"];

        // test_run_parameters() sets rerank_cmd_set: true
        assert_eq!(rp["rerank_cmd_set"], true,
            "rerank_cmd_set must appear in run_parameters");
        assert!(
            rp.get("rerank_cmd").is_none(),
            "the rerank command string must NEVER be persisted to the report"
        );
        assert!(
            rp.get("rerank_cmd_digest").is_none(),
            "no fingerprint of the rerank command may appear in the report"
        );
    }

    /// When --rerank-cmd is active, rerank_failures appears at the top level
    /// of the report. When the flag is absent, the field is omitted entirely.
    #[test]
    fn rerank_failures_present_when_flag_active_omitted_when_absent() {
        // Flag absent: rerank_failures must be omitted
        let report_no_rerank = build_minimal_report(false, &[]);
        let json_no = serde_json::to_string(&report_no_rerank).unwrap();
        let raw_no: serde_json::Value = serde_json::from_str(&json_no).unwrap();
        assert!(
            raw_no.get("rerank_failures").is_none(),
            "rerank_failures must be omitted when --rerank-cmd was not set"
        );

        // Flag active: build a report with rerank_failures = 3
        let corpus = LmeCorpus { questions: Vec::new(), abstention_count: 0 };
        let report_with = build_lme_report(
            "run-id".to_string(),
            "label".to_string(),
            "s".to_string(),
            "2026-01-01T00:00:00Z".to_string(),
            "drain".to_string(),
            "once".to_string(),
            "disk".to_string(),
            1,
            0,
            0,
            &[],
            &corpus,
            &[],
            &HashMap::new(),
            &HashMap::new(),
            "off".to_string(),
            "plaintext-optout".to_string(),
            "turn".to_string(),
            false,
            false,
            &[],
            test_run_parameters(),
            Some(3), // rerank_failures: flag active, 3 parse failures
            None,    // identity_environment
            None,    // timing_report
            None,    // conflict_key_stats: standard (non-Shape-3) run
        );
        let json_with = serde_json::to_string(&report_with).unwrap();
        let raw_with: serde_json::Value = serde_json::from_str(&json_with).unwrap();
        assert_eq!(
            raw_with["rerank_failures"], 3u64,
            "rerank_failures must be present and correct when --rerank-cmd is active"
        );
    }

    /// Builds the run-parameters block from a judge command value exactly the
    /// way `main.rs` does: presence only, nothing derived. Every other value
    /// is fixed so the only input that varies between calls is the command
    /// itself.
    fn run_parameters_for_judge_cmd(judge_cmd: Option<&str>) -> LmeReportRunParameters {
        LmeReportRunParameters {
            judge_hydration_depth: 30,
            judge_grading: "verdict".to_string(),
            judge_cmd_set: judge_cmd.is_some(),
            rerank_cmd_set: false,
            arm: "both".to_string(),
            exact_strategy: "auto".to_string(),
            recall_shape: Some("balanced".to_string()),
            seed: 20_260_725,
            limit: Some(10),
            slice: None,
        }
    }

    /// A run with no judge command records the presence flag false — and,
    /// like every run, no digest key.
    #[test]
    fn run_parameters_record_absent_judge_command_as_false() {
        let value = serde_json::to_value(run_parameters_for_judge_cmd(None)).unwrap();
        assert_eq!(value["judge_cmd_set"], false);
        assert!(
            value.get("judge_cmd_digest").is_none(),
            "no fingerprint of the judge command may appear in the report"
        );
    }

    /// This indistinguishability is the point of MXE-JD: the report can no
    /// longer tell two judge commands apart, and that is the intended loss.
    /// Any field that COULD distinguish them would necessarily be derived
    /// from a secret-bearing string, which is exactly what lets a report
    /// recipient confirm guesses of the command offline.
    #[test]
    fn run_parameters_do_not_distinguish_judge_commands() {
        let a = serde_json::to_value(run_parameters_for_judge_cmd(Some(
            "claude -p --api-key guessable-low-entropy",
        )))
        .unwrap();
        let b =
            serde_json::to_value(run_parameters_for_judge_cmd(Some("ollama run llama3 -")))
                .unwrap();
        assert_eq!(a, b, "run_parameters must not distinguish judge commands");
    }

    /// Run parameters for report tests. Every value is deliberately NOT the
    /// default so a dropped field or a renamed serde key surfaces as a failed
    /// assertion rather than a value that happens to match the zero case.
    fn test_run_parameters() -> LmeReportRunParameters {
        LmeReportRunParameters {
            judge_hydration_depth: 30,
            judge_grading: "verdict".to_string(),
            judge_cmd_set: true,
            // Non-default value so a dropped field surfaces as a failed assertion
            // rather than silently matching the zero case.
            rerank_cmd_set: true,
            arm: "both".to_string(),
            exact_strategy: "auto".to_string(),
            recall_shape: Some("balanced".to_string()),
            seed: 20_260_725,
            limit: Some(10),
            slice: Some("dev".to_string()),
        }
    }

    /// The report must carry the extraction mode under the contract key
    /// `preference_extraction`, and it must survive a JSON round trip. Without
    /// this key a published cell cannot be attributed to a corpus shape after
    /// the fact — which is half of what MXE-CA exists to fix.
    #[test]
    fn report_round_trips_preference_extraction() {
        // true, not false, so a dropped field reads as a failure rather than as a
        // value that happens to match the zero case.
        let report = build_minimal_report(true, &[]);
        let json = serde_json::to_string(&report).expect("report must serialize");
        let value: serde_json::Value =
            serde_json::from_str(&json).expect("report must re-parse");
        assert_eq!(value["preference_extraction"], serde_json::json!(true),
            "contract key 'preference_extraction' must be present in the report JSON");
        let decoded: LmeReport =
            serde_json::from_str(&json).expect("report must deserialize");
        assert!(decoded.preference_extraction,
            "preference_extraction must survive the encode/decode round trip");
    }

    /// The synthesize cell must describe what ran, not what was asked for.
    ///
    /// The builder takes no `--synthesize-arm` parameter, so there is no path by
    /// which the flag can reach `enabled` — that is the structural half of the
    /// fix. This test pins the behavioural half: with the arm requested and the
    /// Rust per-question runner emitting no payloads (its permanent state until
    /// moot_synthesize is wired), the cell reports zeros.
    #[test]
    fn synthesize_cell_reports_zeros_when_no_synthesis_ran() {
        // What a real --synthesize-arm run on this port produces today: one entry
        // per question, every payload None because the runner never calls
        // moot_synthesize.
        let unwired: Vec<(Option<String>, Option<bool>)> =
            vec![(None, None), (None, None), (None, None)];
        let report = build_minimal_report(false, &unwired);
        assert!(!report.synthesize_cell.enabled,
            "no synthesize payloads were produced; the cell must not claim enabled");
        assert_eq!(report.synthesize_cell.question_count, 0,
            "question_count counts synthesized questions, not questions run");
        assert_eq!(report.synthesize_cell.judged_count, None);
        assert_eq!(report.synthesize_cell.accuracy_rate, None);
    }

    /// The converse: when payloads exist the cell reports them, and the counts
    /// come from the payloads rather than from the length of the results vec.
    #[test]
    fn synthesize_cell_reports_observed_payloads() {
        let observed: Vec<(Option<String>, Option<bool>)> = vec![
            (Some("answer one".to_string()), Some(true)),
            (Some("answer two".to_string()), Some(false)),
            (None, None),  // a question with no synthesize payload
        ];
        let report = build_minimal_report(false, &observed);
        assert!(report.synthesize_cell.enabled,
            "payloads exist; the cell must report enabled");
        assert_eq!(report.synthesize_cell.question_count, 2,
            "only questions that produced a payload are counted");
        assert_eq!(report.synthesize_cell.judged_count, Some(2));
        assert_eq!(report.synthesize_cell.accuracy_rate, Some(0.5));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shape 3 deviation label tests (C10)
// ─────────────────────────────────────────────────────────────────────────────

/// Tests for the estate_shape / protocol_deviation / conflict_key_stats fields
/// added by C10 to LmeReport.
///
/// Contract: callers pass None for a standard run, Some(LmeConflictKeyStats {...})
/// for a Shape 3 run. The builder derives estate_shape and protocol_deviation from
/// whether conflict_key_stats is Some. On the Rust port, all callers pass None because
/// there is no shared-estate execution path; the fields exist so the JSON output is
/// byte-identical to the Swift twin.
#[cfg(test)]
mod shape3_deviation_label_tests {
    use super::*;
    use std::collections::HashMap;

    fn make_corpus() -> LmeCorpus {
        LmeCorpus { questions: Vec::new(), abstention_count: 0 }
    }

    fn make_run_params() -> LmeReportRunParameters {
        LmeReportRunParameters {
            judge_hydration_depth: 10,
            judge_grading: "substring".to_string(),
            judge_cmd_set: false,
            rerank_cmd_set: false,
            arm: "exact".to_string(),
            exact_strategy: "auto".to_string(),
            recall_shape: None,
            seed: 42,
            limit: None,
            slice: None,
        }
    }

    /// Helper: build a minimal report with a given conflict_key_stats value.
    fn build_shape3_report(
        conflict_key_stats: Option<LmeConflictKeyStats>,
    ) -> LmeReport {
        let corpus = make_corpus();
        build_lme_report(
            "run-id".to_string(),
            "label".to_string(),
            "s".to_string(),
            "2026-01-01T00:00:00Z".to_string(),
            "drain".to_string(),
            "once".to_string(),
            "disk".to_string(),
            1,
            0,
            0,
            &[],
            &corpus,
            &[],
            &HashMap::new(),
            &HashMap::new(),
            "off".to_string(),
            "plaintext-optout".to_string(),
            "turn".to_string(),
            false,
            false,
            &[],
            make_run_params(),
            None,
            None,
            None,
            conflict_key_stats,
        )
    }

    /// Standard run (None): estate_shape=standard, protocol_deviation=false, no stats key.
    #[test]
    fn standard_run_labels_standard_no_deviation() {
        let report = build_shape3_report(None);
        assert_eq!(report.estate_shape, "standard",
            "None conflict_key_stats → estate_shape must be 'standard'");
        assert!(!report.protocol_deviation,
            "None conflict_key_stats → protocol_deviation must be false");
        assert!(report.conflict_key_stats.is_none(),
            "None conflict_key_stats must remain None in the report");

        // Verify JSON keys are present and correct.
        let json = serde_json::to_string(&report).unwrap();
        let raw: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(raw["estate_shape"], "standard",
            "estate_shape key must be present in JSON even for standard runs");
        assert_eq!(raw["protocol_deviation"], false,
            "protocol_deviation key must be present in JSON even for standard runs");
        // conflict_key_stats must be absent (skip_serializing_if = None).
        assert!(raw.get("conflict_key_stats").is_none() || raw["conflict_key_stats"].is_null(),
            "conflict_key_stats must be absent from JSON when the run is standard");
    }

    /// Shape 3 run (Some): estate_shape=consolidated-shape3, protocol_deviation=true,
    /// conflict_key_stats present with byte-identical field names.
    #[test]
    fn shape3_run_labels_consolidated_with_deviation() {
        let stats = LmeConflictKeyStats {
            conflict_key: "none-questions-unique".to_string(),
            group_count: 1,
            total_unique_session_ids: 19_195,
            shared_session_count: 3_932,
            session_sharing_rate: 0.2047,
        };
        let report = build_shape3_report(Some(stats));

        assert_eq!(report.estate_shape, "consolidated-shape3",
            "Some conflict_key_stats → estate_shape must be 'consolidated-shape3'");
        assert!(report.protocol_deviation,
            "Some conflict_key_stats → protocol_deviation must be true");
        let ks = report.conflict_key_stats.as_ref()
            .expect("conflict_key_stats must be Some for a Shape 3 report");
        assert_eq!(ks.conflict_key, "none-questions-unique");
        assert_eq!(ks.group_count, 1);
        assert_eq!(ks.total_unique_session_ids, 19_195);
        assert_eq!(ks.shared_session_count, 3_932);
        assert!((ks.session_sharing_rate - 0.2047).abs() < 1e-9,
            "session_sharing_rate must round-trip exactly");

        // Verify JSON field names are byte-identical to the Swift contract.
        let json = serde_json::to_string(&report).unwrap();
        let raw: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(raw["estate_shape"], "consolidated-shape3");
        assert_eq!(raw["protocol_deviation"], true);
        let ks_json = raw.get("conflict_key_stats")
            .expect("conflict_key_stats must be present in JSON for Shape 3 runs");
        assert_eq!(ks_json["conflict_key"], "none-questions-unique",
            "JSON key 'conflict_key' must be byte-identical to Swift twin");
        assert_eq!(ks_json["group_count"], 1u64,
            "JSON key 'group_count' must be byte-identical to Swift twin");
        assert_eq!(ks_json["total_unique_session_ids"], 19_195u64,
            "JSON key 'total_unique_session_ids' must be byte-identical to Swift twin");
        assert_eq!(ks_json["shared_session_count"], 3_932u64,
            "JSON key 'shared_session_count' must be byte-identical to Swift twin");
    }
}
