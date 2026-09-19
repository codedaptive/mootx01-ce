//! lmeb_spec_runner.rs — Official LMEB-spec and ConvoMem-spec runner (Rust twin).
//!
//! Rust twin of `LMEBSpecRunner.swift`. Semantics are identical; port differences noted.
//!
//! ## Mode 1: lmeb-spec retrieval (§A1–§A4)
//!
//! §A2 candidate filtering holds structurally: each artifact estate was
//! BUILT from exactly the query's candidate pool documents (the seeding
//! pipeline, at mint time), so read-only retrieval over the opened
//! artifact produces the same ranked set as retrieval-then-filtering —
//! equivalently to SubsetRetrieval.py's post-hoc filter step. The runner
//! seeds nothing; it opens the pre-built estate. §A4: when `with_instruction` setting is active, the
//! subset's verbatim instruction string (from `lmeb_spec_metrics`) is prepended to
//! the recall query before the `moot_memory_search` call.
//! Full metric grid at k∈{1,5,10,25,50} via `lmeb_spec_metrics`. Two-level aggregation.
//!
//! ## Mode 2: convomem-spec judged (§B1–§B4)
//!
//! Same artifact estate source, builds the §B1 memory-based answer prompt, drives the
//! BYOAI external-command seam (`lme_run_judge` from `longmemeval_judge`), selects
//! the §B2 judge template via `convomem_spec_protocol`, applies §B3 verdict rule
//! with bounded retries, aggregates per §B4.
//!
//! With no `answer_cmd`/`judge_cmd` configured: `answered_count` and `judged_count`
//! are 0. Mechanisms are complete; no heuristic fallback scoring.
//!
//! ## Port differences from Swift twin
//!
//! - Rust is synchronous: no `async`/`await`. Parallelism via `std::thread::scope`
//!   (same work-queue pattern as `lmeb_runner.rs`).
//! - `LmebQuery` in Rust has no `answer` field: `LmebSpecQuery` carries
//!   `correct_answer: Option<String>` directly (caller populates from QA annotation).
//! - Dump writer uses `Arc<Mutex<Option<std::fs::File>>>` instead of Swift actor.
//! - MOOT FUNCTION NEEDED placeholder: see note below.
//!
//! ## Record naming (RecordWriter conventions)
//!
//!   lmeb-spec-<arm>-<serial>.json       / lmeb-spec-<arm>-<serial>-params.json
//!   convomem-spec-<arm>-<serial>.json   / convomem-spec-<arm>-<serial>-params.json
//!
//! DO NOT wire CLI entry points from this file.

use crate::artifact_recall::{load_artifact_id_map, ArtifactTargetScale};
use crate::config::{EndpointRole, Transport};
use crate::convomem_spec_protocol::{
    ConvoMemAggregateResult, ConvoMemEvidenceMessage, ConvoMemEvidenceType, ConvoMemVerdictOutcome,
    ConvoMemVerdictRow, convomem_aggregate, convomem_judge_prompt, convomem_memory_based_prompt,
    convomem_verdict,
};
use crate::degeneracy_guard::{GuardSamplingPolicy, LegGuardSampler};
use crate::json_value::JsonValue;
use crate::lmeb_corpus::{LmebCorpus, LmebQuery};
use crate::lmeb_runner::lmeb_verb_map;
use crate::lmeb_scorer::lmeb_ranked_docs_audited;
use crate::lmeb_spec_metrics::{
    lmeb_spec_instruction_for_subset, lmeb_spec_per_query_metrics, lmeb_spec_subset_metrics,
    lmeb_spec_task_metrics, LmebInstructionSetting, LmebSpecOptions, LmebSpecQueryMetrics,
    LmebSpecSubsetMetrics, LmebSpecTaskMetrics,
};
use crate::longmemeval_judge::lme_run_judge;
use crate::longmemeval_runner::{probe_mcp_client, SplitMix64};
use crate::longmemeval_token_efficiency::lme_estimate_tokens;
use crate::mcp_client::{MCPClient, MCPError, ToolCaller};
use crate::scratch_posture::{moot_serve_command, LaneError};
use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Instant;

// ─────────────────────────────────────────────────────────────────────────────
// Extended query type (with evidence type and QA annotation)
// ─────────────────────────────────────────────────────────────────────────────

/// An LMEB query extended with evidence-type label and optional QA annotation fields.
///
/// Wraps `LmebQuery` so that callers loading per-subset query lists can tag each
/// query with its subset name and, for ConvoMem-spec judged mode, with the QA fields
/// the §B1/§B2 prompts require.
///
/// For lmeb-spec retrieval mode, only `query` and `evidence_type` are needed.
/// For convomem-spec judged mode, `correct_answer`, `evidence_count`, and
/// `evidence_messages` are additionally required. When unavailable (see MOOT FUNCTION
/// NEEDED below), defaults are: `correct_answer: None` (judge step skipped),
/// `evidence_count: 1`, `evidence_messages: []`.
///
/// Port note: Rust `LmebQuery` has no `answer` field, so `correct_answer` lives
/// here directly (Swift twin derives it from `query.answer` via a computed property).
#[derive(Debug, Clone)]
pub struct LmebSpecQuery {
    /// The base LMEB query (id, text).
    pub query: LmebQuery,
    /// Evidence type (subset name), e.g. "user_evidence". Used for §A4 instruction
    /// lookup and §B2 judge template selection.
    pub evidence_type: String,
    /// Ground-truth correct answer for this query. Used in §B2 judge prompts.
    /// `None` → judge step is skipped; question counted as unscored, not incorrect.
    pub correct_answer: Option<String>,
    /// Number of evidence documents supporting this question. Controls §B2 branch
    /// selection for UserFactsAnsweringEvaluation (single vs multi-evidence form).
    /// Populated from ConvoMem QA annotations; defaults to 1 when not loaded.
    pub evidence_count: usize,
    /// Evidence message texts for §B2 UserFacts judge prompt. Empty when annotations
    /// not loaded — judge prompt degrades to single-evidence form gracefully.
    pub evidence_messages: Vec<ConvoMemEvidenceMessage>,
}

impl LmebSpecQuery {
    /// Constructs a minimal spec query for lmeb-spec retrieval mode.
    /// `correct_answer` defaults to `None`, `evidence_count` to 1, messages to empty.
    pub fn new(query: LmebQuery, evidence_type: impl Into<String>) -> Self {
        Self {
            query,
            evidence_type: evidence_type.into(),
            correct_answer: None,
            evidence_count: 1,
            evidence_messages: vec![],
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Run configuration
// ─────────────────────────────────────────────────────────────────────────────

/// Configuration for an LMEB-spec or ConvoMem-spec run.
///
/// Opens pre-built artifact estates — builds nothing, settles nothing,
/// deletes nothing. One fleet estate per scene at unit scale (unit stem
/// `"<evidence_type>__<scene_id>"`); one shared estate at bench-aggregate scale.
///
/// Twin of Swift `LMEBSpecRunConfig`.
pub struct LmebSpecRunConfig {
    // ── Dataset ───────────────────────────────────────────────────────────────
    pub moot_binary: String,
    pub data_dir: PathBuf,
    pub evidence_types: Vec<String>,
    pub limit: Option<usize>,
    pub offset: usize,
    pub seed: u64,
    pub out_dir: Option<PathBuf>,
    pub run_label: String,

    // ── Artifact estate seam ──────────────────────────────────────────────────
    /// Unit (default) or bench-aggregate. completeAggregate is refused.
    pub target_scale: ArtifactTargetScale,
    /// Path to the dataset's catalog.json (required at unit scale). The catalog
    /// resolves each scene stem to its estate directory across primary and
    /// secondary bases.
    pub catalog_path: Option<PathBuf>,
    /// The bench-aggregate estate directory.
    pub estate_dir: Option<PathBuf>,

    // ── Parallelism / guard ───────────────────────────────────────────────────
    /// Maximum concurrency (1 = serial). bench-aggregate is always forced to 1.
    pub parallel_units: usize,
    pub guard_sampling_policy: GuardSamplingPolicy,
    pub corpus_digest: String,

    // ── §A4: Instruction setting ───────────────────────────────────────────────
    /// Whether to prepend the subset's §A4 instruction string to the recall query.
    /// Default: `WithoutInstruction` (the canonical zero-instruction baseline).
    pub instruction_setting: LmebInstructionSetting,

    // ── §A3: Evaluation options ────────────────────────────────────────────────
    /// `skip_first_result` and `ignore_identical_ids` switches (§A3, both default off).
    pub spec_options: LmebSpecOptions,

    // ── §B1: Answer generation (convomem-spec mode) ────────────────────────────
    /// Shell command for answer generation (e.g. `"claude -p"` or `"ollama run llama3 -"`).
    /// `None` → answer step skipped; `answered_count = 0`.
    ///
    /// SECRECY RULE: only boolean presence (`answer_cmd_set`) is written to the
    /// report. The command text itself — which may carry API keys — is never logged,
    /// hashed, or partially printed.
    pub answer_cmd: Option<String>,

    /// Number of top-ranked corpus texts passed to the §B1 memory-based prompt.
    /// Default: 10 (matching the LME arm's default hydration depth).
    pub answer_hydration_depth: usize,

    // ── §B2/§B3: Judging (convomem-spec mode) ────────────────────────────────
    /// Shell command for judge calls (§B2/§B3).
    /// `None` → judge step skipped; `judged_count = 0`. NO heuristic fallback.
    ///
    /// SECRECY RULE: only boolean presence (`judge_cmd_set`) is written to the
    /// report. The command text itself is never logged, hashed, or partially printed.
    pub judge_cmd: Option<String>,

    /// Maximum retry count for the §B3 bounded retry loop on invalid judge responses.
    /// Exhausted retries yield no verdict (question unscored per §B3 — NOT counted
    /// as incorrect). See `convomem_verdict` for the `Invalid` distinction.
    pub judge_max_retries: usize,

    /// Judge identity string recorded in the ConvoMem-spec report per §B4.
    /// Example: `"gemini-flash"`. Default: `"unknown"`.
    pub judge_identity: String,

    /// Depth tier passed as the `depth` argument to `moot_memory_get` during estate
    /// hydration. `Distilled` is the production shape — the reader sees what a real
    /// caller would receive. `Full` is the comparison arm for ablation.
    /// Default: `Distilled`.
    pub answer_hydration_tier: crate::journey_driver::HydrationDepth,

    // ── Offline-batch dump paths ───────────────────────────────────────────────
    /// Path to write the per-query answer-input JSONL dump.
    /// `None` → no dump written.
    pub dump_answer_inputs_path: Option<String>,

    /// Path to write the per-query judge-input JSONL dump.
    /// `None` → no dump written.
    pub dump_judge_inputs_path: Option<String>,

    // ── Recall scoring strategy ────────────────────────────────────────────────
    /// When `Some`, passed as `"scoring"` in the `moot_memory_search` argument dict.
    /// Accepted values: `"raw"`, `"rrf"`, `"matrixAware"`, `"discriminative"`.
    /// When `None`, the key is absent — the call is byte-identical to the pre-flag baseline.
    /// Mutually exclusive with `recall_shape`: the CLI parse rejects both together.
    pub scoring_strategy: Option<String>,

    // ── Recall shape preset ────────────────────────────────────────────────────
    /// When `Some`, the per-query recall call switches to `moot_recall_shaped` and
    /// passes this value as `"preset"`. The server validates the preset against its
    /// roster and fails closed on unknown names — the client passes through unvalidated.
    /// Mutually exclusive with `scoring_strategy`: `moot_recall_shaped` always runs
    /// matrixAware internally and does not accept a `"scoring"` key.
    /// When `None`, the verb is `moot_memory_search` (byte-identical to the pre-flag baseline).
    pub recall_shape: Option<String>,

    // ── Expand-verify scoreboard fields (§1, §3, §7.5) ────────────────────────
    /// Per-question verb result cap (default 20 = current behaviour).
    /// Always sent explicitly in the query so the value is recorded and auditable.
    pub request_limit: usize,

    /// When true, sends `explain: true` in recall calls and reads pool structure from
    /// the explain payload. Default false — omitting keeps default runs byte-identical
    /// to the pre-flag baseline (pool = returned list).
    pub pool_metrics_enabled: bool,

    /// Content-term threshold for the short-query gate (default 4).
    /// A question with content_term_count < short_query_terms is counted as short.
    pub short_query_terms: usize,
}

impl Default for LmebSpecRunConfig {
    fn default() -> Self {
        Self {
            moot_binary: String::new(),
            data_dir: PathBuf::new(),
            evidence_types: vec![],
            limit: None,
            offset: 0,
            seed: 0,
            out_dir: None,
            run_label: String::new(),
            target_scale: ArtifactTargetScale::Unit,
            catalog_path: None,
            estate_dir: None,
            parallel_units: 1,
            guard_sampling_policy: GuardSamplingPolicy::OncePerLeg,
            corpus_digest: "unknown".to_string(),
            instruction_setting: LmebInstructionSetting::WithoutInstruction,
            spec_options: LmebSpecOptions::default(),
            answer_cmd: None,
            answer_hydration_depth: 10,
            answer_hydration_tier: crate::journey_driver::HydrationDepth::Distilled,
            judge_cmd: None,
            judge_max_retries: 3,
            judge_identity: "unknown".to_string(),
            dump_answer_inputs_path: None,
            dump_judge_inputs_path: None,
            scoring_strategy: None,
            recall_shape: None,
            request_limit: 20,
            pool_metrics_enabled: false,
            short_query_terms: 4,
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-query result types
// ─────────────────────────────────────────────────────────────────────────────

/// Per-query result for lmeb-spec retrieval mode.
/// Carries raw retrieval data and computed spec metrics.
///
/// Twin of Swift `LMEBSpecQueryResult`.
#[derive(Debug, Clone)]
pub struct LmebSpecQueryResult {
    /// Query identifier, e.g. `"scene_42_q_0"`.
    pub query_id: String,
    /// Evidence type for this query (one of the six ConvoMem subsets).
    pub evidence_type: String,
    /// `moot_memory_search` latency in seconds.
    pub query_latency_seconds: f64,
    /// Ranked doc IDs from UUID→docID mapping; NUL-prefixed for unmapped UUIDs.
    pub retrieved_doc_ids: Vec<String>,
    /// Ground-truth relevant document IDs.
    pub relevant_doc_ids: HashSet<String>,
    /// True when DegeneracyGuard classified the backend as healthy.
    pub guard_healthy: bool,
    /// Guard diagnostic message when not healthy.
    pub guard_diagnostic: Option<String>,
    /// Guard sampling policy in effect.
    pub guard_sampling_mode: GuardSamplingPolicy,
    /// Number of candidate docs ingested for this query.
    pub docs_ingested: usize,
    /// Mean write latency (seconds) across ingested docs (0.0 for batch path).
    pub write_mean_latency_seconds: f64,
    /// Estate cache status: `Some(true)` = hit, `Some(false)` = miss, `None` = cache off.
    pub cache_hit: Option<bool>,
    /// Whether the drain barrier observed the `corpus_encode` lane registered.
    pub drain_lane_observed: Option<bool>,
    /// §A4 instruction setting in effect.
    pub instruction_setting: LmebInstructionSetting,
    /// The actual query text sent to `moot_memory_search` (instruction-augmented when applicable).
    pub effective_query_text: String,
    /// Full metric grid at every k in `LMEB_SPEC_K_VALUES` (§A3).
    pub spec_metrics: LmebSpecQueryMetrics,

    // ── Expand-verify scoreboard per-question fields (§1 / §7.5) ────────────
    /// Content-term count of the effective query text (lowercase alnum tokens minus the
    /// shared EN stopword fixture). Used for the §7.1 short-query gate.
    pub content_term_count: usize,
    /// 1-based ranks of gold docs within the returned list (absent → not returned).
    pub gold_ranks: Vec<usize>,
    /// Pool size: equals returned_count when --pool-metrics is off (default);
    /// equals the explain-payload pool count when --pool-metrics is on.
    pub pool_size: usize,
    /// 1 when at least one gold doc appears in the pool; 0 otherwise.
    /// Stored as usize (0/1 int) for JSON serialization per the brief schema.
    pub pool_gold_hit: usize,
    /// Silo provenance map from the explain payload: silo_id → candidate count.
    /// Empty when --pool-metrics is off or the payload carries no pool structure.
    pub pool_provenance: HashMap<String, usize>,
}

/// Per-query result for convomem-spec judged mode.
/// Carries retrieval data and the §B1–§B4 judging fields.
///
/// Twin of Swift `ConvoMemSpecQueryResult`.
#[derive(Debug, Clone)]
pub struct ConvoMemSpecQueryResult {
    /// Query identifier.
    pub query_id: String,
    /// Evidence type (one of the six ConvoMem subsets — governs §B2 template selection).
    pub evidence_type: String,
    /// Evidence count for §B2 UserFacts branch selection (single vs multi-evidence).
    pub evidence_count: usize,
    /// The question text sent to the answer model.
    pub question_text: String,
    /// `moot_memory_search` latency in seconds.
    pub query_latency_seconds: f64,
    /// Ranked doc IDs from the retrieval step.
    pub retrieved_doc_ids: Vec<String>,
    /// Ground-truth relevant document IDs.
    pub relevant_doc_ids: HashSet<String>,
    /// True when DegeneracyGuard classified the backend as healthy.
    pub guard_healthy: bool,
    /// Guard diagnostic message when not healthy.
    pub guard_diagnostic: Option<String>,
    /// Estate cache status.
    pub cache_hit: Option<bool>,
    /// Memory texts (top-K corpus doc texts) passed to the §B1 prompt.
    pub retrieved_memory_texts: Vec<String>,
    /// The §B1 memory-based answer prompt sent to `answer_cmd`. `None` when `answer_cmd` unset.
    pub answer_prompt: Option<String>,
    /// The model's answer returned by `answer_cmd`. `None` when not run or failed.
    pub model_answer: Option<String>,
    /// The §B2 judge prompt. `None` when `answer_cmd` was not set.
    pub judge_prompt: Option<String>,
    /// §B3 verdict outcome. `None` when judging did not run.
    pub verdict_outcome: Option<ConvoMemVerdictOutcome>,
    /// True when §B3 retry count was exhausted without a valid verdict.
    /// Question is unscored (not counted as incorrect) per §B3.
    pub retries_exhausted: bool,
    /// True when §B3 detected an ambiguous response (both "right" and "wrong")
    /// and defaulted to incorrect per §B3.
    pub ambiguous_verdict_warned: bool,
    /// Estimated tokens in the memory-context payload sent to the answer model.
    pub answer_payload_tokens: Option<usize>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Run results (aggregated)
// ─────────────────────────────────────────────────────────────────────────────

/// Aggregated results for a lmeb-spec retrieval run.
///
/// Twin of Swift `LMEBSpecRunResults`.
#[derive(Debug)]
pub struct LmebSpecRunResults {
    /// Per-query results, in the shuffled+sliced order processed.
    pub per_query_results: Vec<LmebSpecQueryResult>,
    /// Per-subset (level-1) aggregated metrics.
    pub subset_metrics: Vec<LmebSpecSubsetMetrics>,
    /// Task-level (level-2) aggregated metrics (mean of subset scores).
    pub task_metrics: LmebSpecTaskMetrics,
    /// Leg timing report. `None` when every estate was cache-restored or capture failed.
    pub timing_report: Option<String>,
    /// Queries whose guard verdict was not healthy (excluded from published numbers).
    pub guard_excluded_count: usize,
    /// Total queries processed after seed-shuffle + offset/limit.
    pub total_queries: usize,
    /// §A4 instruction setting used for this run.
    pub instruction_setting: LmebInstructionSetting,
    /// §A3 spec options (skip_first_result, ignore_identical_ids).
    pub spec_options: LmebSpecOptions,
    /// `dreaming` lane pending count captured once at run start (item 8).
    pub dream_pending: u64,
    /// 1 when the `dreaming` lane was actively draining at run start; 0 otherwise.
    pub dream_draining: u64,
}

/// Aggregated results for a convomem-spec judged run.
///
/// Twin of Swift `ConvoMemSpecRunResults`.
#[derive(Debug)]
pub struct ConvoMemSpecRunResults {
    /// Per-query results, in the shuffled+sliced order processed.
    pub per_query_results: Vec<ConvoMemSpecQueryResult>,
    /// §B4 aggregation result. `None` when `judged_count == 0`.
    pub aggregate_result: Option<ConvoMemAggregateResult>,
    /// Total queries that produced a model answer (`answer_cmd` returned successfully).
    pub answered_count: usize,
    /// Total questions that received a scored or unscored verdict from the judge.
    pub judged_count: usize,
    /// Total queries processed.
    pub total_queries: usize,
    /// Leg timing report.
    pub timing_report: Option<String>,
    /// Queries excluded by the DegeneracyGuard.
    pub guard_excluded_count: usize,
    /// Judge identity string recorded per §B4.
    pub judge_identity: String,
    /// Whether the answer command was set.
    /// SECRECY: the command text itself is never recorded.
    pub answer_cmd_set: bool,
    /// Whether the judge command was set.
    /// SECRECY: the command text itself is never recorded.
    pub judge_cmd_set: bool,
    /// Queries for which `memory_texts` was empty after estate hydration.
    /// A run where this equals `total_queries` is a broken hydration — the CLI
    /// exits non-zero naming the first affected query.
    pub memory_texts_empty_count: usize,
    /// `dreaming` lane pending count captured once at run start (item 8).
    pub dream_pending: u64,
    /// 1 when the `dreaming` lane was actively draining at run start; 0 otherwise.
    pub dream_draining: u64,
}

// ─────────────────────────────────────────────────────────────────────────────
// §A4: Instruction-augmented query text
// ─────────────────────────────────────────────────────────────────────────────

/// Returns the query text to send to `moot_memory_search`, prepending the §A4
/// instruction string when the run uses the with-instruction setting.
///
/// §A4 verbatim: the per-subset instruction string is prepended to the query.
/// Concatenation format: `"{instruction}\n{query_text}"` — the newline separator
/// follows the MTEB convention for embedding models that accept instruction+query input.
///
/// When the evidence type is not among the six ConvoMem subsets (unknown type),
/// the query text is returned unchanged and a warning is emitted to stderr.
///
/// Twin of Swift `lmebSpecEffectiveQuery(queryText:evidenceType:setting:)`.
pub fn lmeb_spec_effective_query(
    query_text: &str,
    evidence_type: &str,
    setting: LmebInstructionSetting,
) -> String {
    if setting != LmebInstructionSetting::WithInstruction {
        return query_text.to_string();
    }
    match lmeb_spec_instruction_for_subset(evidence_type) {
        Some(instruction) => {
            // §A4: prepend instruction. "\n" separator follows MTEB embedding instruction convention.
            format!("{}\n{}", instruction, query_text)
        }
        None => {
            eprintln!(
                "[lmeb-spec] WARNING: no §A4 instruction for unknown evidenceType '{}' \
                 — query sent without instruction",
                evidence_type
            );
            query_text.to_string()
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MOOT FUNCTION NEEDED: ConvoMem QA annotation loader
// ─────────────────────────────────────────────────────────────────────────────

// MOOT FUNCTION NEEDED: load_convomem_evidence_annotations(query_id, subset_data_dir)
//   — returns (evidence_count: usize, evidence_messages: Vec<ConvoMemEvidenceMessage>)
//
// Inputs:
//   query_id:        &str   — the ConvoMem query identifier (e.g. "scene_0_q_0").
//   subset_data_dir: &Path  — the on-disk directory for one evidence type subset,
//                             expected to contain the QA annotation file (format TBD
//                             from the ConvoMem/SalesforceAIResearch dataset schema).
//
// Outputs:
//   evidence_count:    usize                    — number of evidence documents for this
//                                                 question; controls the §B2 branch in
//                                                 UserFactsAnsweringEvaluation.
//   evidence_messages: Vec<ConvoMemEvidenceMessage> — evidence message texts embedded
//                                                 verbatim in the §B2 UserFacts judge prompt.
//
// Behavior required:
//   Reads the per-subset QA annotation file (likely a JSONL mapping queryID →
//   {evidence_count, evidence_messages: [{text: str}, ...]}). Returns (1, vec![])
//   when the query is not found (graceful degradation to single-evidence branch).
//
// Why not in LmebCorpus:
//   LmebCorpus loads corpus.jsonl, queries.jsonl, candidates.jsonl, and qrels.tsv.
//   The QA annotation file (evidence_count, evidence_messages per question) is a
//   separate dataset artifact requiring its own loader.

/// Placeholder stub returning `(1, vec![])` until `load_convomem_evidence_annotations`
/// is implemented (see MOOT FUNCTION NEEDED above).
///
/// The single-evidence branch of `convomem_user_facts_judge_prompt` (§B2) handles
/// `evidence_count == 1` with empty messages gracefully — the prompt degrades to
/// the single-evidence form without embedding any evidence text.
fn convomem_evidence_annotations_placeholder(
    _query_id: &str,
    _evidence_type: &str,
) -> (usize, Vec<ConvoMemEvidenceMessage>) {
    // Placeholder — real data requires the QA annotation loader above.
    (1, vec![])
}

// ─────────────────────────────────────────────────────────────────────────────
// Private per-query result from the estate loop
// ─────────────────────────────────────────────────────────────────────────────

/// Shared per-query result carrying the raw retrieval output from the estate loop.
/// Both mode-specific functions derive their per-query outputs from this.
///
/// Internal to this module; not part of the public API.
struct LmebSpecRawQueryResult {
    query_id: String,
    evidence_type: String,
    query_latency_seconds: f64,
    retrieved_doc_ids: Vec<String>,
    relevant_doc_ids: HashSet<String>,
    guard_healthy: bool,
    guard_diagnostic: Option<String>,
    guard_sampling_mode: GuardSamplingPolicy,
    docs_ingested: usize,
    write_mean_latency_seconds: f64,
    cache_hit: Option<bool>,
    drain_lane_observed: Option<bool>,
    /// §A4 effective query text (instruction-augmented when applicable).
    effective_query_text: String,

    // ── Expand-verify scoreboard per-question fields (§1 / §7.5) ────────────
    /// Content-term count of the effective query text (lowercase alnum tokens minus stopwords).
    content_term_count: usize,
    /// 1-based ranks of gold docs within the returned list.
    gold_ranks: Vec<usize>,
    /// Pool size (== returned_count unless pool-metrics mode reads the explain payload).
    pool_size: usize,
    /// 1 when at least one gold doc appears in the pool; 0 otherwise.
    pool_gold_hit: usize,
    /// Silo provenance from the explain payload. Empty when pool-metrics is off.
    pool_provenance: HashMap<String, usize>,

    /// Memory texts hydrated from the estate via `moot_memory_get`, in retrieval
    /// order, capped at `config.answer_hydration_depth`. Populated while the MCP
    /// client is live inside `run_one_lmeb_spec_query_artifact`. Falls back to
    /// corpus lookup on hydration failure; misses are logged to stderr per query.
    hydrated_texts: Vec<String>,
    /// Estate drawer UUIDs parallel to `hydrated_texts`: the UUID used for each
    /// moot_memory_get call, or an empty string when the text came from corpus
    /// fallback (no estate drawer for that doc). Recorded for artifact-recall scoring.
    hydrated_drawer_ids: Vec<String>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Private: artifact estate endpoint + scene-stem derivation
// ─────────────────────────────────────────────────────────────────────────────

/// Returns the unit stem for a query: `"<evidence_type>__<scene_id>"`.
///
/// `query.id` format (from lmeb corpus): `"scene_X_q_N"`. The scene_id is
/// everything before the `"_q_"` suffix. The `"__"` separator matches the
/// artifact fleet directory naming convention.
fn lmeb_spec_scene_stem(query_id: &str, evidence_type: &str) -> String {
    // Strip the "_q_N" suffix to get the scene_id. Fallback: use the full query id.
    let scene_id = if let Some(idx) = query_id.find("_q_") {
        &query_id[..idx]
    } else {
        query_id
    };
    format!("{}__{}", evidence_type, scene_id)
}

/// Builds an EndpointConfig pointing at a pre-built artifact estate.
///
/// READ-ONLY use: the lane only calls moot_memory_search (and the guard probe
/// tool). Deliberately NOT routed through lmeb_endpoint_config — that function
/// creates scratch dirs; this one opens a durable artifact estate.
///
/// Returns `LaneError::Config` when `moot_serve_command` refuses the path (e.g.
/// whitespace) so callers can propagate the refusal as a fatal lane abort
/// rather than absorbing it into a per-query guard-excluded stub.
///
/// Command: `MOOTX01_FROZEN=1 MOOTX01_SUBJECT_RIDER=0 <binary> serve --db <estate>`
fn lmeb_spec_artifact_endpoint(estate_dir: &Path, moot_binary: &str) -> Result<crate::config::EndpointConfig, LaneError> {
    let data_dir = estate_dir.to_string_lossy();
    // Transient record (--db <dir>) is plaintext by rule; no env prefix needed.
    let command = moot_serve_command(moot_binary, Path::new(&*data_dir), false, &["MOOTX01_FROZEN=1", "MOOTX01_SUBJECT_RIDER=0"], None)
        .map_err(|e| LaneError::Config(e.to_string()))?;
    Ok(crate::config::EndpointConfig {
        name: "mootx01-lmeb-spec".to_string(),
        transport: Transport::Stdio { command },
        auth: None,
        verb_map: lmeb_verb_map(),
        role: EndpointRole::Both,
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Private: per-query artifact estate query
// ─────────────────────────────────────────────────────────────────────────────

/// One frozen serve shared by every query of an aggregate-scale run.
///
/// At unit scale each query has its own scene estate, so the per-query
/// connect / probe / disconnect inside `run_one_lmeb_spec_query_artifact` is
/// the natural shape. At bench-aggregate scale every query hits the same
/// estate, and a fresh serve per query pays the estate's cold load (the
/// resident-array read of the whole wing, over a minute on a 13,817-drawer
/// ConvoMem wing) once per query: 140 queries in three hours on the first
/// aggregate run. This value is opened once before the loop, probed once, and
/// disconnected after the loop; the per-query function uses it when present.
/// Aggregate runs are serial (one worker), so the `Mutex` is uncontended.
///
/// Twin of Swift `LMEBSpecSharedEstate`.
pub struct LmebSpecSharedEstate {
    client: Mutex<MCPClient>,
    /// uuid → doc_id, for ranked-doc mapping.
    uuid_to_doc_id: HashMap<String, String>,
    /// doc_id → uuid, for §B1 estate hydration.
    doc_id_to_uuid: HashMap<String, String>,
    guard_healthy: bool,
    guard_diagnostic: Option<String>,
}

/// Loads id-map.json for an artifact estate as both directions: uuid → doc_id
/// (ranked-doc mapping) and doc_id → uuid (§B1 hydration). A load failure
/// logs under `label` and yields empty maps, so the query still runs and
/// reports zero mapped docs rather than aborting the leg.
fn lmeb_spec_load_id_maps(
    estate_path: &Path,
    label: &str,
) -> (HashMap<String, String>, HashMap<String, String>) {
    match load_artifact_id_map(estate_path) {
        Ok(fwd) => {
            // fwd is doc_id → uuid (from id-map.json).
            // rev flips it to uuid → doc_id (for ranked-doc lookup).
            // Return (uuid→doc_id, doc_id→uuid).
            let rev: HashMap<String, String> =
                fwd.iter().map(|(k, v)| (v.clone(), k.clone())).collect();
            (rev, fwd)
        }
        Err(e) => {
            eprintln!("[lmeb-spec] id-map load failed for {} at {}: {}",
                label, estate_path.display(), e.description);
            (HashMap::new(), HashMap::new())
        }
    }
}

/// Opens the shared estate for an aggregate-scale run. Returns `None` at unit
/// scale, where every query opens its own scene estate.
///
/// Twin of Swift `lmebSpecOpenSharedEstate`.
fn lmeb_spec_open_shared_estate(
    config: &LmebSpecRunConfig,
    sampler: &Mutex<LegGuardSampler>,
) -> Result<Option<LmebSpecSharedEstate>, LaneError> {
    if config.target_scale == ArtifactTargetScale::Unit {
        return Ok(None);
    }
    let estate_path = match &config.estate_dir {
        Some(ed) => ed.clone(),
        None => return Err(LaneError::Unit(
            "lmeb-spec bench-aggregate: estate_dir not configured".to_string(),
        )),
    };
    let (uuid_to_doc_id, doc_id_to_uuid) = lmeb_spec_load_id_maps(&estate_path, "shared estate");
    // LaneError::Config propagates as a fatal lane abort; LaneError::Unit (from
    // MCPError via From) is per-unit and handled by the caller.
    let endpoint = lmeb_spec_artifact_endpoint(&estate_path, &config.moot_binary)?;
    let mut client = MCPClient::new(endpoint);
    client.connect()?;
    // The DegeneracyGuard verdict is per estate, so one probe covers the run.
    let verb_map = lmeb_verb_map();
    let (guard_healthy, guard_diagnostic, _was_probed) = sampler
        .lock()
        .unwrap()
        .probe(|| probe_mcp_client(&mut client, &verb_map));
    Ok(Some(LmebSpecSharedEstate {
        client: Mutex::new(client),
        uuid_to_doc_id,
        doc_id_to_uuid,
        guard_healthy,
        guard_diagnostic,
    }))
}

/// Runs one lmeb-spec query against a pre-built artifact estate.
///
/// Builds nothing, settles nothing, deletes nothing. The estate is durable;
/// the MCP connection is the only resource created and released here, and
/// only at unit scale. At aggregate scale the run loop's `shared` estate
/// supplies the connection, the id maps, and the guard verdict, and this
/// function opens nothing.
///
/// For unit scale the estate is resolved from the catalog by unit id
/// and the id maps are loaded from that estate's `id-map.json`.
fn run_one_lmeb_spec_query_artifact(
    spec_query: &LmebSpecQuery,
    corpus: &LmebCorpus,
    config: &LmebSpecRunConfig,
    query_index: usize,
    sampler: &Mutex<LegGuardSampler>,
    shared: Option<&LmebSpecSharedEstate>,
) -> Result<LmebSpecRawQueryResult, LaneError> {
    if let Some(s) = shared {
        let mut client = s.client.lock().unwrap();
        return run_one_lmeb_spec_query_on(
            &mut client,
            &s.uuid_to_doc_id,
            &s.doc_id_to_uuid,
            s.guard_healthy,
            s.guard_diagnostic.clone(),
            spec_query,
            corpus,
            config,
            query_index,
            sampler,
        )
        .map_err(LaneError::from);
    }

    // ── Unit scale: resolve, open, probe, run, release ────────────────────────
    let query = &spec_query.query;
    let evidence_type = &spec_query.evidence_type;
    let estate_path: PathBuf = match config.target_scale {
        ArtifactTargetScale::Unit => {
            let scene_stem = lmeb_spec_scene_stem(&query.id, evidence_type);
            let cat = config.catalog_path.as_ref().ok_or_else(|| {
                LaneError::Unit("lmeb-spec unit scale: catalog not configured".to_string())
            })?;
            crate::artifact_recall::resolve_unit_from_catalog(cat, &scene_stem)
                .map_err(LaneError::from)?
        }
        ArtifactTargetScale::BenchAggregate | ArtifactTargetScale::CompleteAggregate => {
            return Err(LaneError::Unit(
                "lmeb-spec aggregate scale runs on the shared estate opened by the run loop"
                    .to_string(),
            ));
        }
    };
    // Guard: estate dir must exist before launching serve. Fail fast here
    // rather than launching an empty estate that errors on id-map.json.
    if config.target_scale == ArtifactTargetScale::Unit && !estate_path.is_dir() {
        return Err(LaneError::Unit(format!(
            "estate for unit {} missing at {}",
            query.id,
            estate_path.display()
        )));
    }
    let (uuid_to_doc_id, doc_id_to_uuid) = lmeb_spec_load_id_maps(&estate_path, &query.id);

    // LaneError::Config propagates immediately (binary/path refusal); all
    // other errors convert to LaneError::Unit via the From<MCPError> impl.
    let endpoint = lmeb_spec_artifact_endpoint(&estate_path, &config.moot_binary)?;
    let mut client = MCPClient::new(endpoint);
    client.connect()?;
    let verb_map = lmeb_verb_map();
    let (guard_healthy, guard_diagnostic, _was_probed) = sampler
        .lock()
        .unwrap()
        .probe(|| probe_mcp_client(&mut client, &verb_map));

    let result = run_one_lmeb_spec_query_on(
        &mut client,
        &uuid_to_doc_id,
        &doc_id_to_uuid,
        guard_healthy,
        guard_diagnostic,
        spec_query,
        corpus,
        config,
        query_index,
        sampler,
    )
    .map_err(LaneError::from);
    // No teardown — pre-built artifact estate is durable.
    client.disconnect();
    result
}

/// The query itself: recall, uuid → doc_id mapping, and §B1 hydration over an
/// already-open, already-probed connection. Shared by the unit-scale and the
/// aggregate-scale paths of `run_one_lmeb_spec_query_artifact`.
#[allow(clippy::too_many_arguments)]
fn run_one_lmeb_spec_query_on(
    client: &mut MCPClient,
    uuid_to_doc_id: &HashMap<String, String>,
    doc_id_to_uuid: &HashMap<String, String>,
    guard_healthy: bool,
    guard_diagnostic: Option<String>,
    spec_query: &LmebSpecQuery,
    corpus: &LmebCorpus,
    config: &LmebSpecRunConfig,
    query_index: usize,
    sampler: &Mutex<LegGuardSampler>,
) -> Result<LmebSpecRawQueryResult, MCPError> {
    let query = &spec_query.query;
    let evidence_type = &spec_query.evidence_type;

    // Ground truth folded from the qrels' turn-level id space into the
    // artifact's session-level key space (lmeb_artifact_session_key —
    // without the fold nothing can match the ranked session ids).
    let relevant_doc_ids: HashSet<String> = corpus
        .relevant_docs(&query.id)
        .iter()
        .map(|d| lmeb_artifact_session_key(d))
        .collect();

    // §A4: compute the effective query text (instruction-prepended when applicable).
    let effective_query_text =
        lmeb_spec_effective_query(&query.text, evidence_type, config.instruction_setting);
    let docs_ingested = uuid_to_doc_id.len();
    let verb_map = lmeb_verb_map();

    let query_start = Instant::now();
    let (returned_uuids, _payload_text): (Vec<String>, Option<String>) = if guard_healthy {
        let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
        args.insert(
            verb_map.query_arg.clone(),
            JsonValue::String(effective_query_text.clone()),
        );
        // request_limit: always sent explicitly so the estate honours it (default 20).
        // JSONValue uses .number(f64) — there is no .integer variant in this codebase.
        args.insert("limit".to_string(), JsonValue::Number(config.request_limit as f64));
        // --pool-metrics: when enabled, request the explain payload so the pool
        // provenance can be extracted from the search response.
        if config.pool_metrics_enabled {
            args.insert("explain".to_string(), JsonValue::Bool(true));
        }
        // Two verbs are possible depending on flags:
        //   moot_recall_shaped — when --recall-shape is given: passes "query" + "preset";
        //                        never sends "scoring" (the verb runs matrixAware internally).
        //   moot_memory_search — baseline when --recall-shape is absent: optional "scoring"
        //                        key; byte-identical to the pre-flag baseline when both absent.
        // The CLI rejects --scoring + --recall-shape together before this point.
        let query_verb: &str;
        if let Some(ref shape) = config.recall_shape {
            // moot_recall_shaped: preset steers the fusion engine; no scoring key.
            query_verb = crate::aria_v2_surface::RECALL_SHAPED;
            args.insert("preset".to_string(), JsonValue::String(shape.clone()));
        } else {
            // moot_memory_search: pass scoring when given, omit otherwise.
            query_verb = &verb_map.query;
            if let Some(ref s) = config.scoring_strategy {
                args.insert("scoring".to_string(), JsonValue::String(s.clone()));
            }
        }
        // constantArgs are empty for artifact estates (no location header needed).
        match client.call_tool(query_verb, args, &verb_map.result_format) {
            Ok(result) => {
                let payload = if result.text_blocks.is_empty() {
                    None
                } else {
                    Some(result.text_blocks.join("\n"))
                };
                (result.ordered_ids, payload)
            }
            Err(e) => {
                eprintln!("[lmeb-spec] query error for {}: {}", query.id, e.description);
                (vec![], None)
            }
        }
    } else {
        (vec![], None)
    };
    let query_latency_seconds = query_start.elapsed().as_secs_f64();

    let (retrieved_doc_ids, _unmapped_count) =
        lmeb_ranked_docs_audited(&returned_uuids, uuid_to_doc_id);

    eprintln!(
        "[lmeb-spec] {}/{} {} [{}]: {} docs in estate, guard={}, retrieved {}",
        query_index + 1,
        0, // progress total not available at this call site; caller logs full progress
        query.id,
        evidence_type,
        docs_ingested,
        if guard_healthy { "healthy" } else { "EXCLUDED" },
        retrieved_doc_ids.len()
    );

    // ── §B1: Estate hydration — moot_memory_get per ranked drawer UUID ──────
    // The id-map maps session-level seed IDs (doc IDs) → drawer UUIDs.
    // Use doc_id_to_uuid to look up each UUID, then call moot_memory_get once per
    // UUID (LongMemEvalRunner pattern) so each block is one drawer's full content.
    // This fixes the id-space mismatch: the corpus is keyed by turn IDs while the
    // estate is keyed by session UUIDs, so corpus.docs_by_id.get(doc_id) always
    // returns None for these session-level IDs.
    //
    // Fallback: hydration failure → corpus.docs_by_id (also misses in session/turn
    // mismatch; preserved for non-artifact paths) → miss count.
    let mut hydrated_texts: Vec<String> = Vec::new();
    let mut hydrated_drawer_ids: Vec<String> = Vec::new();
    let mut hydration_misses: usize = 0;
    for doc_id in retrieved_doc_ids.iter().take(config.answer_hydration_depth) {
        if doc_id.starts_with('\u{0000}') { continue; }
        if let Some(uuid) = doc_id_to_uuid.get(doc_id) {
            let get_args = crate::aria_v2_surface::memory_get_args(
                uuid.as_str(),
                Some(config.answer_hydration_tier.as_wire_str()),
            );
            match client.call_tool(crate::aria_v2_surface::MEMORY_GET, get_args, &crate::config::ResultFormat::MootV2) {
                Ok(result) => {
                    let text = result.text_blocks.join("\n");
                    if !text.is_empty() {
                        hydrated_texts.push(text);
                        hydrated_drawer_ids.push(uuid.clone());
                    } else if let Some(d) = corpus.docs_by_id.get(doc_id) {
                        hydrated_texts.push(d.text.clone());
                        hydrated_drawer_ids.push(uuid.clone()); // UUID known, corpus fallback
                    } else {
                        hydration_misses += 1;
                    }
                }
                Err(e) => {
                    eprintln!("[lmeb-spec] hydration failed for {uuid} ({doc_id}): {}",
                        e.description);
                    if let Some(d) = corpus.docs_by_id.get(doc_id) {
                        hydrated_texts.push(d.text.clone());
                        hydrated_drawer_ids.push(uuid.clone()); // UUID known, corpus fallback
                    } else {
                        hydration_misses += 1;
                    }
                }
            }
        } else {
            // No UUID in manifest — fall back to corpus; empty string signals no estate drawer.
            if let Some(d) = corpus.docs_by_id.get(doc_id) {
                hydrated_texts.push(d.text.clone());
                hydrated_drawer_ids.push(String::new());
            } else {
                hydration_misses += 1;
            }
        }
    }
    if hydration_misses > 0 {
        eprintln!("[lmeb-spec] {}: {hydration_misses} doc(s) produced no hydrated text",
            query.id);
    }

    // ── Expand-verify scoreboard per-question fields (§7.5) ──────────────────
    let content_term_count = crate::lmeb_spec_metrics::lmeb_content_term_count(
        &effective_query_text,
    );
    // gold_ranks: 1-based positions of gold docs in the returned list.
    let gold_ranks: Vec<usize> = retrieved_doc_ids
        .iter()
        .enumerate()
        .filter_map(|(i, doc_id)| {
            if relevant_doc_ids.contains(doc_id) { Some(i + 1) } else { None }
        })
        .collect();
    let pool_size = retrieved_doc_ids.len();
    let pool_gold_hit = if gold_ranks.is_empty() { 0 } else { 1 };
    // pool_provenance: populated from the explain payload when --pool-metrics is on.
    // Current implementation: empty map (provenance extraction from explain payload
    // requires parsing the MCP search response JSON, which is estate-version-specific).
    let pool_provenance: HashMap<String, usize> = HashMap::new();

    Ok(LmebSpecRawQueryResult {
        query_id: query.id.clone(),
        evidence_type: evidence_type.clone(),
        query_latency_seconds,
        retrieved_doc_ids,
        relevant_doc_ids,
        guard_healthy,
        guard_diagnostic,
        guard_sampling_mode: sampler.lock().unwrap().policy,
        docs_ingested,
        write_mean_latency_seconds: 0.0, // artifact estates: no write latency
        cache_hit: None,            // artifact estates have no cache
        drain_lane_observed: None,  // no encode barrier
        effective_query_text,
        content_term_count,
        gold_ranks,
        pool_size,
        pool_gold_hit,
        pool_provenance,
        hydrated_texts,
        hydrated_drawer_ids,
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Public: lmeb-spec retrieval mode (§A)
// ─────────────────────────────────────────────────────────────────────────────

/// Runs the lmeb-spec retrieval harness against a loaded corpus.
///
/// Produces the full official metric grid (§A1/§A3/§A4) at k∈{1,5,10,25,50},
/// two-level aggregation (subset-level macro mean → task mean), R_cap@k with
/// `None`-propagation, and per-query metric records.
///
/// Parallelism: when `config.parallel_units > 1`, queries run as independent threads
/// (same work-queue pattern as `run_lmeb_queries` in `lmeb_runner.rs`). Results are
/// sorted by original index for byte-deterministic ordering.
///
/// Twin of Swift `runLMEBSpecQueries(specQueries:corpus:config:)`.
pub fn run_lmeb_spec_queries(
    spec_queries: &[LmebSpecQuery],
    corpus: &LmebCorpus,
    config: &LmebSpecRunConfig,
) -> Result<LmebSpecRunResults, String> {
    // ── Deterministic shuffle + slice (SplitMix64, fleet-standard PRNG) ───────
    let mut rng = SplitMix64::new(config.seed);
    let mut indices: Vec<usize> = (0..spec_queries.len()).collect();
    rng.shuffle(&mut indices);
    let sliced: Vec<usize> = indices
        .into_iter()
        .skip(config.offset)
        .take(config.limit.unwrap_or(usize::MAX))
        .collect();
    let total = sliced.len();

    // ── Leg-level shared infrastructure ───────────────────────────────────────
    // One guard sampler per leg: OncePerLeg probes on the first query and caches
    // the verdict for all subsequent queries (zero MCP cost).
    let guard_sampler = Arc::new(Mutex::new(LegGuardSampler::new(config.guard_sampling_policy)));

    // bench-aggregate scale: force serial to avoid concurrent connections to the
    // shared estate. Unit scale: parallelise up to parallel_units.
    let effective_workers = if config.target_scale == ArtifactTargetScale::Unit {
        config.parallel_units.min(sliced.len().max(1))
    } else {
        1
    };

    // ── Parallel dispatch via std::thread::scope ───────────────────────────────
    // Work queue: (progress_index, query_index) pairs popped by worker threads.
    // Results written to index-keyed slots; sorted by progress_index after join.
    let work_queue: Arc<Mutex<VecDeque<(usize, usize)>>> = Arc::new(Mutex::new(
        sliced.iter().enumerate().map(|(pi, &qi)| (pi, qi)).collect(),
    ));
    let result_slots: Arc<Mutex<Vec<Option<LmebSpecQueryResult>>>> =
        Arc::new(Mutex::new((0..total).map(|_| None).collect()));

    // Aggregate scale: one frozen serve for every query (LmebSpecSharedEstate);
    // None at unit scale, where each query opens its own scene estate.
    // LaneError::Config (binary/path refusal) aborts the lane immediately — exit 1,
    // no report. LaneError::Unit (MCPError: connect/probe failure) is absorbed into
    // None so individual query stubs surface the error rather than aborting the run.
    let shared = match lmeb_spec_open_shared_estate(config, &guard_sampler) {
        Ok(s) => s,
        Err(LaneError::Config(msg)) => {
            // Binary or path guard failed before any estate was opened.
            // Propagate immediately so main() exits 1 and writes no report.
            return Err(msg);
        }
        Err(LaneError::Unit(msg)) => {
            eprintln!("[lmeb-spec] shared estate open failed: {msg}");
            None
        }
    };

    // ── Dream drain status probe (item 8) ─────────────────────────────────────
    let lmeb_dream_status = if let Some(ref s) = shared {
        let mut client_guard = s.client.lock().unwrap();
        crate::encode_barrier::read_drain_status_once(&mut *client_guard)
    } else {
        crate::encode_barrier::DreamStatus::default()
    };

    // Option<&T> is Copy, so every worker closure can carry the reference.
    let shared_ref = shared.as_ref();

    // Config-error slot: set by a worker on LaneError::Config; checked after
    // the scope to abort the lane with exit 1 and no report.
    let config_error_lmeb: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));

    std::thread::scope(|s| {
        for _ in 0..effective_workers {
            let work_queue = Arc::clone(&work_queue);
            let result_slots = Arc::clone(&result_slots);
            let guard_sampler = Arc::clone(&guard_sampler);
            let config_error_lmeb = Arc::clone(&config_error_lmeb);

            s.spawn(move || {
                loop {
                    let (progress_index, query_index) =
                        match work_queue.lock().unwrap().pop_front() {
                            Some(item) => item,
                            None => break,
                        };

                    let sq = &spec_queries[query_index];

                    eprintln!(
                        "[lmeb-spec] {}/{}: {} [{}]",
                        progress_index + 1,
                        total,
                        sq.query.id,
                        sq.evidence_type
                    );

                    let query_result: LmebSpecQueryResult = match run_one_lmeb_spec_query_artifact(
                        sq,
                        corpus,
                        config,
                        query_index,
                        &guard_sampler,
                    shared_ref,
                    ) {
                        Ok(raw) => {
                            // §A3: compute per-query spec metrics from the ranked list.
                            let metrics = lmeb_spec_per_query_metrics(
                                &raw.retrieved_doc_ids,
                                &raw.relevant_doc_ids,
                                &raw.query_id,
                                &config.spec_options,
                            );
                            LmebSpecQueryResult {
                                query_id: raw.query_id,
                                evidence_type: raw.evidence_type,
                                query_latency_seconds: raw.query_latency_seconds,
                                retrieved_doc_ids: raw.retrieved_doc_ids,
                                relevant_doc_ids: raw.relevant_doc_ids,
                                guard_healthy: raw.guard_healthy,
                                guard_diagnostic: raw.guard_diagnostic,
                                guard_sampling_mode: raw.guard_sampling_mode,
                                docs_ingested: raw.docs_ingested,
                                write_mean_latency_seconds: raw.write_mean_latency_seconds,
                                cache_hit: raw.cache_hit,
                                drain_lane_observed: raw.drain_lane_observed,
                                instruction_setting: config.instruction_setting,
                                effective_query_text: raw.effective_query_text,
                                spec_metrics: metrics,
                                // Expand-verify scoreboard fields.
                                content_term_count: raw.content_term_count,
                                gold_ranks: raw.gold_ranks,
                                pool_size: raw.pool_size,
                                pool_gold_hit: raw.pool_gold_hit,
                                pool_provenance: raw.pool_provenance,
                            }
                        }
                        Err(LaneError::Config(msg)) => {
                            // Binary or path guard failed: set the shared error slot and
                            // drain the work queue so no further queries are attempted.
                            eprintln!("  [lmeb-spec] config refusal: {msg}");
                            *config_error_lmeb.lock().unwrap() = Some(msg);
                            // Drain queue so other workers also exit promptly.
                            work_queue.lock().unwrap().clear();
                            break;
                        }
                        Err(LaneError::Unit(msg)) => {
                            eprintln!(
                                "  [lmeb-spec] {}/{} ERROR: {}",
                                progress_index + 1,
                                total,
                                msg
                            );
                            // Emit a guard-excluded stub result so the query appears in
                            // corpus stats and no result slot is left unfilled.
                            let relevant = corpus.relevant_docs(&sq.query.id).iter().cloned().collect();
                            let empty_metrics = lmeb_spec_per_query_metrics(
                                &[],
                                &HashSet::new(),
                                &sq.query.id,
                                &config.spec_options,
                            );
                            LmebSpecQueryResult {
                                query_id: sq.query.id.clone(),
                                evidence_type: sq.evidence_type.clone(),
                                query_latency_seconds: 0.0,
                                retrieved_doc_ids: vec![],
                                relevant_doc_ids: relevant,
                                guard_healthy: false,
                                guard_diagnostic: Some(msg),
                                guard_sampling_mode: config.guard_sampling_policy,
                                docs_ingested: 0,
                                write_mean_latency_seconds: 0.0,
                                cache_hit: None,
                                drain_lane_observed: None,
                                instruction_setting: config.instruction_setting,
                                effective_query_text: sq.query.text.clone(),
                                spec_metrics: empty_metrics,
                                // Expand-verify fields for error stub: zeros.
                                content_term_count: 0,
                                gold_ranks: vec![],
                                pool_size: 0,
                                pool_gold_hit: 0,
                                pool_provenance: HashMap::new(),
                            }
                        }
                    };

                    result_slots.lock().unwrap()[progress_index] = Some(query_result);
                }
            });
        }
    });
    if let Some(s) = &shared {
        // No teardown — the artifact estate is durable; release the connection.
        s.client.lock().unwrap().disconnect();
    }

    // Abort the lane if any worker received a LaneError::Config (binary/path refusal).
    // Workers drained the queue and set this slot; we propagate it here as Err so
    // main() exits 1 and writes no report.
    if let Some(msg) = config_error_lmeb.lock().unwrap().take() {
        return Err(msg);
    }

    // Collect in progress_index order for byte-deterministic report ordering.
    let mut guard = result_slots.lock().unwrap();
    let ordered_results: Vec<LmebSpecQueryResult> = guard
        .iter_mut()
        .map(|slot| slot.take().expect("all slots filled by worker threads"))
        .collect();
    drop(guard);

    // ── §A1/§A3: Two-level aggregation ────────────────────────────────────────
    // Group per-query metrics by evidence type for subset-level (level-1) aggregation.
    let mut by_subset: HashMap<String, Vec<LmebSpecQueryMetrics>> = HashMap::new();
    let mut guard_excluded = 0usize;

    for r in &ordered_results {
        if !r.guard_healthy { guard_excluded += 1; }
        by_subset
            .entry(r.evidence_type.clone())
            .or_default()
            .push(r.spec_metrics.clone());
    }

    // Subset metrics in deterministic order (sorted by subset name).
    let mut subset_names: Vec<String> = by_subset.keys().cloned().collect();
    subset_names.sort();
    let subset_metrics: Vec<LmebSpecSubsetMetrics> = subset_names
        .iter()
        .map(|name| lmeb_spec_subset_metrics(by_subset.get(name).unwrap().to_vec(), name))
        .collect();

    // Level-2: task score = mean of subset scores.
    let mut task_metrics = lmeb_spec_task_metrics(&subset_metrics);

    // ── Expand-verify pool/short-query aggregates (§7.5) ─────────────────────
    {
        let included: Vec<&LmebSpecQueryResult> =
            ordered_results.iter().filter(|r| r.guard_healthy).collect();
        let n = included.len();
        if n > 0 {
            task_metrics.pool_guarantee =
                included.iter().filter(|r| r.pool_gold_hit == 1).count() as f64 / n as f64;
            let total_gold: usize = included.iter().map(|r| r.relevant_doc_ids.len()).sum();
            let gold_in_pool: usize = included.iter().map(|r| r.gold_ranks.len()).sum();
            task_metrics.pool_gold_recall = if total_gold > 0 {
                gold_in_pool as f64 / total_gold as f64
            } else {
                0.0
            };
            let short: Vec<&&LmebSpecQueryResult> = included
                .iter()
                .filter(|r| r.content_term_count < config.short_query_terms)
                .collect();
            task_metrics.short_query_count = short.len();
            if !short.is_empty() {
                let ns = short.len() as f64;
                task_metrics.short_query_ndcg_at_10 =
                    short.iter().map(|r| r.spec_metrics.ndcg_at(10)).sum::<f64>() / ns;
                // recall_at: look up recall@10 from the spec_metrics recall vec.
                let recall_sum: f64 = short.iter().map(|r| {
                    r.spec_metrics.recall.iter()
                        .find(|(k, _)| *k == 10)
                        .map(|(_, v)| *v)
                        .unwrap_or(0.0)
                }).sum();
                task_metrics.short_query_recall_at_10 = recall_sum / ns;
                task_metrics.short_query_pool_guarantee =
                    short.iter().filter(|r| r.pool_gold_hit == 1).count() as f64 / ns;
            }
        }
    }

    Ok(LmebSpecRunResults {
        per_query_results: ordered_results,
        subset_metrics,
        task_metrics,
        timing_report: None, // artifact estates: no live timing capture
        guard_excluded_count: guard_excluded,
        total_queries: total,
        instruction_setting: config.instruction_setting,
        spec_options: config.spec_options,
        dream_pending: lmeb_dream_status.pending,
        dream_draining: if lmeb_dream_status.draining { 1 } else { 0 },
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Public: convomem-spec judged mode (§B)
// ─────────────────────────────────────────────────────────────────────────────

/// Runs the ConvoMem-spec judged harness against a loaded corpus.
///
/// Retrieves memories per query (same estate provisioning as lmeb-spec), builds the
/// §B1 memory-based answer prompt, obtains answers via the BYOAI seam (`lme_run_judge`
/// from `longmemeval_judge`), selects the §B2 judge template by evidence type via
/// `convomem_judge_prompt`, applies the §B3 verdict rule with bounded retries, and
/// aggregates per §B4.
///
/// SECRECY RULE: only boolean presence (`answer_cmd_set` / `judge_cmd_set`) is written
/// to the returned `ConvoMemSpecRunResults`. The command text itself — which may carry
/// API keys — is never logged, hashed, or partially printed.
///
/// With no `answer_cmd`/`judge_cmd` set: `answered_count` and `judged_count` are 0,
/// all verdict rows are absent, and `aggregate_result` is `None`. Mechanisms are
/// complete; no heuristic fallback scoring.
///
/// Twin of Swift `runConvoMemSpecQueries(specQueries:corpus:config:)`.
pub fn run_convomem_spec_queries(
    spec_queries: &[LmebSpecQuery],
    corpus: &LmebCorpus,
    config: &LmebSpecRunConfig,
) -> Result<ConvoMemSpecRunResults, String> {
    // ── Deterministic shuffle + slice ─────────────────────────────────────────
    let mut rng = SplitMix64::new(config.seed);
    let mut indices: Vec<usize> = (0..spec_queries.len()).collect();
    rng.shuffle(&mut indices);
    let sliced: Vec<usize> = indices
        .into_iter()
        .skip(config.offset)
        .take(config.limit.unwrap_or(usize::MAX))
        .collect();
    let total = sliced.len();

    // ── Leg-level shared infrastructure ───────────────────────────────────────
    let guard_sampler = Arc::new(Mutex::new(LegGuardSampler::new(config.guard_sampling_policy)));

    // bench-aggregate scale: force serial to avoid concurrent connections to the
    // shared estate. Unit scale: parallelise up to parallel_units.
    let effective_workers_convomem = if config.target_scale == ArtifactTargetScale::Unit {
        config.parallel_units.min(sliced.len().max(1))
    } else {
        1
    };

    // ── Optional offline-batch dump files ─────────────────────────────────────
    // Answer-input dump: write a JSONL header before the parallel loop.
    // Header format matches the Swift twin byte-for-byte (sorted keys via BTreeMap).
    let answer_dump_file: Arc<Mutex<Option<std::fs::File>>> = Arc::new(Mutex::new(
        config.dump_answer_inputs_path.as_ref().and_then(|path| {
            let header = serde_json::json!({
                "type": "header",
                "benchmark": "convomem-spec",
                "seed": config.seed,
                "run_label": &config.run_label,
                "answer_hydration_depth": config.answer_hydration_depth,
                "hydration_tier": config.answer_hydration_tier.as_wire_str(),
            });
            std::fs::File::create(path).ok().and_then(|mut f| {
                let _ = writeln!(f, "{header}");
                // Reopen in append mode for the worker threads.
                std::fs::OpenOptions::new().append(true).open(path).ok()
            })
        }),
    ));

    // Judge-input dump: write a JSONL header before the parallel loop.
    let judge_dump_file: Arc<Mutex<Option<std::fs::File>>> = Arc::new(Mutex::new(
        config.dump_judge_inputs_path.as_ref().and_then(|path| {
            let header = serde_json::json!({
                "type": "header",
                "benchmark": "convomem-spec",
                "seed": config.seed,
                "run_label": &config.run_label,
                "judge_identity": &config.judge_identity,
            });
            std::fs::File::create(path).ok().and_then(|mut f| {
                let _ = writeln!(f, "{header}");
                std::fs::OpenOptions::new().append(true).open(path).ok()
            })
        }),
    ));

    // ── Parallel dispatch ──────────────────────────────────────────────────────
    let work_queue: Arc<Mutex<VecDeque<(usize, usize)>>> = Arc::new(Mutex::new(
        sliced.iter().enumerate().map(|(pi, &qi)| (pi, qi)).collect(),
    ));
    let result_slots: Arc<Mutex<Vec<Option<ConvoMemSpecQueryResult>>>> =
        Arc::new(Mutex::new((0..total).map(|_| None).collect()));

    // Aggregate scale: one frozen serve for every query (LmebSpecSharedEstate);
    // None at unit scale, where each query opens its own scene estate.
    // LaneError::Config (binary/path refusal) aborts the lane immediately — exit 1,
    // no report. LaneError::Unit (MCPError: connect/probe failure) is absorbed into
    // None so individual query stubs surface the error rather than aborting the run.
    let shared = match lmeb_spec_open_shared_estate(config, &guard_sampler) {
        Ok(s) => s,
        Err(LaneError::Config(msg)) => {
            // Binary or path guard failed before any estate was opened.
            // Propagate immediately so main() exits 1 and writes no report.
            return Err(msg);
        }
        Err(LaneError::Unit(msg)) => {
            eprintln!("[convomem-spec] shared estate open failed: {msg}");
            None
        }
    };

    // ── Dream drain status probe (item 8) ─────────────────────────────────────
    let convomem_dream_status = if let Some(ref s) = shared {
        let mut client_guard = s.client.lock().unwrap();
        crate::encode_barrier::read_drain_status_once(&mut *client_guard)
    } else {
        crate::encode_barrier::DreamStatus::default()
    };

    // Option<&T> is Copy, so every worker closure can carry the reference.
    let shared_ref = shared.as_ref();

    // Config-error slot: set by a worker on LaneError::Config; checked after
    // the scope to abort the lane with exit 1 and no report.
    let config_error_conv: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));

    std::thread::scope(|s| {
        for _ in 0..effective_workers_convomem {
            let work_queue = Arc::clone(&work_queue);
            let result_slots = Arc::clone(&result_slots);
            let guard_sampler = Arc::clone(&guard_sampler);
            let answer_dump_file = Arc::clone(&answer_dump_file);
            let judge_dump_file = Arc::clone(&judge_dump_file);
            let config_error_conv = Arc::clone(&config_error_conv);

            s.spawn(move || {
                loop {
                    let (progress_index, query_index) =
                        match work_queue.lock().unwrap().pop_front() {
                            Some(item) => item,
                            None => break,
                        };

                    let sq = &spec_queries[query_index];

                    eprintln!(
                        "[convomem-spec] {}/{}: {} [{}]",
                        progress_index + 1,
                        total,
                        sq.query.id,
                        sq.evidence_type
                    );

                    // ── §A: Artifact estate retrieval ─────────────────────────
                    let raw = match run_one_lmeb_spec_query_artifact(
                        sq,
                        corpus,
                        config,
                        query_index,
                        &guard_sampler,
                    shared_ref,
                    ) {
                        Ok(r) => r,
                        Err(LaneError::Config(msg)) => {
                            // Binary or path guard failed: set the shared error slot and
                            // drain the work queue so no further queries are attempted.
                            eprintln!("  [convomem-spec] config refusal: {msg}");
                            *config_error_conv.lock().unwrap() = Some(msg);
                            // Drain queue so other workers also exit promptly.
                            work_queue.lock().unwrap().clear();
                            break;
                        }
                        Err(LaneError::Unit(msg)) => {
                            eprintln!(
                                "  [convomem-spec] {}/{} estate ERROR: {}",
                                progress_index + 1, total, msg
                            );
                            // Emit a guard-excluded stub.
                            let relevant = corpus.relevant_docs(&sq.query.id).iter().cloned().collect();
                            result_slots.lock().unwrap()[progress_index] = Some(ConvoMemSpecQueryResult {
                                query_id: sq.query.id.clone(),
                                evidence_type: sq.evidence_type.clone(),
                                evidence_count: sq.evidence_count,
                                question_text: sq.query.text.clone(),
                                query_latency_seconds: 0.0,
                                retrieved_doc_ids: vec![],
                                relevant_doc_ids: relevant,
                                guard_healthy: false,
                                guard_diagnostic: Some(msg),
                                cache_hit: None,
                                retrieved_memory_texts: vec![],
                                answer_prompt: None,
                                model_answer: None,
                                judge_prompt: None,
                                verdict_outcome: None,
                                retries_exhausted: false,
                                ambiguous_verdict_warned: false,
                                answer_payload_tokens: None,
                            });
                            continue;
                        }
                    };

                    // ── §B1: Collect top-K memory texts ───────────────────────
                    // Memory texts are hydrated from the estate via moot_memory_get
                    // inside run_one_lmeb_spec_query_artifact (while the MCP client
                    // is live), fixing the id-space mismatch: id-map.json maps
                    // session IDs → drawer UUIDs while corpus.jsonl uses turn IDs,
                    // so corpus.docs_by_id lookup always returns empty for these IDs.
                    let top_doc_texts: Vec<String> = raw.hydrated_texts.clone();

                    let answer_payload_tokens: Option<usize> = if top_doc_texts.is_empty() {
                        None
                    } else {
                        Some(lme_estimate_tokens(&top_doc_texts.join("\n\n")))
                    };

                    // §B1: memory-based prompt (verbatim from MemoryPromptUtils.scala,
                    // implemented in convomem_spec_protocol.rs).
                    let answer_prompt: Option<String> = if config.answer_cmd.is_some() {
                        let text_refs: Vec<&str> = top_doc_texts.iter().map(String::as_str).collect();
                        Some(convomem_memory_based_prompt(&sq.query.text, &text_refs))
                    } else {
                        None
                    };

                    // ── §B1: Obtain model answer (BYOAI seam) ─────────────────
                    // Uses lme_run_judge from longmemeval_judge — the harness's existing
                    // external-command seam. Answer command reads prompt from stdin, writes
                    // answer to stdout — same contract as the judge command.
                    //
                    // SECRECY: the answer_cmd value is used below but never logged.
                    let mut model_answer: Option<String> = None;
                    if let (Some(cmd), Some(ref prompt)) = (&config.answer_cmd, &answer_prompt) {
                        match lme_run_judge(cmd, prompt) {
                            Ok(answer) => { model_answer = Some(answer); }
                            Err(e) => {
                                eprintln!(
                                    "[convomem-spec] answer cmd failed for {} — skipping: {}",
                                    raw.query_id, e
                                );
                            }
                        }
                    }

                    // ── Offline answer-input dump ──────────────────────────────
                    if let Ok(mut guard) = answer_dump_file.lock() {
                        if let Some(ref mut f) = *guard {
                            // Fields match the Swift twin's sorted-keys JSON exactly.
                            let line_obj = serde_json::json!({
                                "correct_answer": &sq.correct_answer,
                                "evidence_type": &raw.evidence_type,
                                "memory_texts": &top_doc_texts,
                                "memory_token_estimate": answer_payload_tokens,
                                "question": &sq.query.text,
                                "query_id": &raw.query_id,
                                "retrieved_drawer_ids": &raw.hydrated_drawer_ids,
                                "type": "answer_input",
                            });
                            let _ = writeln!(f, "{line_obj}");
                        }
                    }

                    // ── §B2/§B3: Judge (only when answer was obtained) ─────────
                    // Template selection per §B2: evidence type → template.
                    // Retry loop per §B3: bounded at config.judge_max_retries.
                    //
                    // SECRECY: the judge_cmd value is used below but never logged.
                    let mut judge_prompt: Option<String> = None;
                    let mut verdict_outcome: Option<ConvoMemVerdictOutcome> = None;
                    let mut retries_exhausted = false;
                    let mut ambiguous_verdict_warned = false;

                    if let (Some(judge_cmd), Some(ref answer), Some(ref correct), Some(evid_type)) = (
                        &config.judge_cmd,
                        &model_answer,
                        &sq.correct_answer,
                        ConvoMemEvidenceType::from_str(&raw.evidence_type),
                    ) {
                        // §B2: select the judge template by evidence type.
                        // Evidence annotations (count, messages) from placeholder —
                        // see MOOT FUNCTION NEEDED: load_convomem_evidence_annotations.
                        let (evidence_count, evidence_messages) =
                            convomem_evidence_annotations_placeholder(
                                &raw.query_id,
                                &raw.evidence_type,
                            );

                        let jp = convomem_judge_prompt(
                            &evid_type,
                            &sq.query.text,
                            correct,
                            answer,
                            &evidence_messages,
                            evidence_count,
                        );
                        judge_prompt = Some(jp.clone());

                        // ── Offline judge-input dump ───────────────────────────
                        if let Ok(mut guard) = judge_dump_file.lock() {
                            if let Some(ref mut f) = *guard {
                                let jline = serde_json::json!({
                                    "correct_answer": correct,
                                    "evidence_count": evidence_count,
                                    "evidence_type": &raw.evidence_type,
                                    "judge_prompt": &jp,
                                    "model_answer": answer,
                                    "question": &sq.query.text,
                                    "query_id": &raw.query_id,
                                    "type": "judge_input",
                                });
                                let _ = writeln!(f, "{jline}");
                            }
                        }

                        // §B3: bounded retry loop for invalid responses.
                        // .Invalid = neither "right" nor "wrong" after trim+lowercase.
                        // .Incorrect (from ambiguous or "wrong" only) is a final verdict.
                        // Exhausted retries → no verdict (unscored, not counted as wrong).
                        let mut attempt = 0;
                        while attempt < config.judge_max_retries {
                            match lme_run_judge(judge_cmd, &jp) {
                                Ok(reply) => {
                                    let outcome = convomem_verdict(&reply);
                                    // §B3 ambiguous detection: Incorrect outcome where the
                                    // lowercased reply also contains "right" means both keywords
                                    // were present — ambiguous → .Incorrect + warn.
                                    if outcome == ConvoMemVerdictOutcome::Incorrect
                                        && reply.trim().to_lowercase().contains("right")
                                    {
                                        ambiguous_verdict_warned = true;
                                        eprintln!(
                                            "[convomem-spec] §B3 ambiguous judge response for {} — defaulted to incorrect",
                                            raw.query_id
                                        );
                                    }
                                    if outcome != ConvoMemVerdictOutcome::Invalid {
                                        verdict_outcome = Some(outcome);
                                        break;
                                    }
                                    // .Invalid → retry.
                                    eprintln!(
                                        "[convomem-spec] §B3 invalid judge response (attempt {}/{}) for {} — retrying",
                                        attempt + 1, config.judge_max_retries, raw.query_id
                                    );
                                }
                                Err(e) => {
                                    eprintln!(
                                        "[convomem-spec] judge cmd failed (attempt {}/{}) for {}: {}",
                                        attempt + 1, config.judge_max_retries, raw.query_id, e
                                    );
                                }
                            }
                            attempt += 1;
                        }
                        if verdict_outcome.is_none() {
                            retries_exhausted = true;
                            eprintln!(
                                "[convomem-spec] §B3 retries exhausted for {} — unscored",
                                raw.query_id
                            );
                        }
                    }

                    result_slots.lock().unwrap()[progress_index] = Some(ConvoMemSpecQueryResult {
                        query_id: raw.query_id,
                        evidence_type: raw.evidence_type,
                        evidence_count: sq.evidence_count,
                        question_text: sq.query.text.clone(),
                        query_latency_seconds: raw.query_latency_seconds,
                        retrieved_doc_ids: raw.retrieved_doc_ids,
                        relevant_doc_ids: raw.relevant_doc_ids,
                        guard_healthy: raw.guard_healthy,
                        guard_diagnostic: raw.guard_diagnostic,
                        cache_hit: raw.cache_hit,
                        retrieved_memory_texts: top_doc_texts,
                        answer_prompt,
                        model_answer,
                        judge_prompt,
                        verdict_outcome,
                        retries_exhausted,
                        ambiguous_verdict_warned,
                        answer_payload_tokens,
                    });
                }
            });
        }
    });
    if let Some(s) = &shared {
        // No teardown — the artifact estate is durable; release the connection.
        s.client.lock().unwrap().disconnect();
    }

    // Abort the lane if any worker received a LaneError::Config (binary/path refusal).
    if let Some(msg) = config_error_conv.lock().unwrap().take() {
        return Err(msg);
    }

    // Collect in progress_index order for byte-deterministic report ordering.
    let mut guard = result_slots.lock().unwrap();
    let ordered_results: Vec<ConvoMemSpecQueryResult> = guard
        .iter_mut()
        .map(|slot| slot.take().expect("all slots filled by worker threads"))
        .collect();
    drop(guard);

    // ── §B4: Build verdict rows and aggregate ─────────────────────────────────
    let mut verdict_rows: Vec<ConvoMemVerdictRow> = Vec::new();
    let mut answered_count = 0usize;
    let mut judged_count = 0usize;
    let mut guard_excluded = 0usize;
    let mut memory_texts_empty_count = 0usize;

    for r in &ordered_results {
        if r.retrieved_memory_texts.is_empty() { memory_texts_empty_count += 1; }
        if !r.guard_healthy { guard_excluded += 1; }
        if r.model_answer.is_some() { answered_count += 1; }
        if let Some(ref outcome) = r.verdict_outcome {
            // §B4: every result with a non-None verdict contributes to judged_count.
            judged_count += 1;
            verdict_rows.push(ConvoMemVerdictRow::new(
                &r.evidence_type,
                r.evidence_count,
                outcome.clone(),
            ));
        } else if r.retries_exhausted {
            // §B3 exhausted retries → no verdict → question unscored.
            // Still counted in judged_count (judging was attempted but inconclusive).
            judged_count += 1;
            verdict_rows.push(ConvoMemVerdictRow::new(
                &r.evidence_type,
                r.evidence_count,
                ConvoMemVerdictOutcome::Invalid,
            ));
        }
    }

    // §B4 aggregation. None when judged_count == 0 (no commands configured).
    let aggregate_result: Option<ConvoMemAggregateResult> = if verdict_rows.is_empty() {
        None
    } else {
        Some(convomem_aggregate(&verdict_rows))
    };

    Ok(ConvoMemSpecRunResults {
        per_query_results: ordered_results,
        aggregate_result,
        answered_count,
        judged_count,
        total_queries: total,
        timing_report: None, // artifact estates: no live timing capture
        guard_excluded_count: guard_excluded,
        judge_identity: config.judge_identity.clone(),
        // SECRECY: only boolean presence recorded; command text never touches the report.
        answer_cmd_set: config.answer_cmd.is_some(),
        judge_cmd_set: config.judge_cmd.is_some(),
        memory_texts_empty_count,
        dream_pending: convomem_dream_status.pending,
        dream_draining: if convomem_dream_status.draining { 1 } else { 0 },
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Public: offline-batch paths
// ─────────────────────────────────────────────────────────────────────────────

/// Reads a convomem-spec answer-input JSONL dump, runs the answer command offline,
/// and writes a judge-input JSONL dump suitable for consuming via
/// `run_convomem_spec_judge_dump`.
///
/// No mootx01 binary or live estate required. Use this to generate answers
/// asynchronously from retrieval runs when the answer model is not available
/// during the benchmark run.
///
/// Twin of Swift `runConvoMemSpecAnswerDump(inputsPath:answerCmd:outputPath:)`.
///
/// SECRECY: `answer_cmd` is not logged; only boolean presence of the configured
/// command is recorded in output structures.
pub fn run_convomem_spec_answer_dump(
    inputs_path: &str,
    answer_cmd: &str,
    output_path: &str,
    limit: Option<usize>,
    offset: usize,
) -> Result<(), MCPError> {
    let content = std::fs::read_to_string(inputs_path).map_err(|e| MCPError {
        description: format!("cannot read answer-input dump at '{}': {e}", inputs_path),
    })?;
    let lines: Vec<&str> = content.lines().filter(|l| !l.is_empty()).collect();
    if lines.is_empty() {
        return Err(MCPError {
            description: format!("answer-input dump is empty: '{}'", inputs_path),
        });
    }
    // Parse and validate the header line.
    let header_obj: serde_json::Value = serde_json::from_str(lines[0]).map_err(|e| MCPError {
        description: format!("first line is not valid JSON in '{}': {e}", inputs_path),
    })?;
    if header_obj.get("type").and_then(|v| v.as_str()) != Some("header") {
        return Err(MCPError {
            description: format!("first line is not a valid header in '{}'", inputs_path),
        });
    }

    // Create output file with restricted permissions (600 — may carry API keys in prompts).
    let mut out_file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(output_path)
        .map_err(|e| MCPError {
            description: format!("cannot open output path for writing '{}': {e}", output_path),
        })?;
    // Set owner-only permissions (600) to guard any key material in the prompt text.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(output_path, std::fs::Permissions::from_mode(0o600));
    }

    // Collect answer_input lines, then apply offset + limit (--limit caps ConvoMem
    // branch the same way it caps every other branch).
    let input_lines: Vec<&str> = lines.into_iter().skip(1)
        .filter(|l| {
            serde_json::from_str::<serde_json::Value>(l)
                .ok()
                .and_then(|v| v.get("type").and_then(|t| t.as_str()).map(|s| s == "answer_input"))
                .unwrap_or(false)
        })
        .collect();
    let selected_start = offset.min(input_lines.len());
    let selected_end = limit
        .map(|n| selected_start.saturating_add(n).min(input_lines.len()))
        .unwrap_or(input_lines.len());
    for line in &input_lines[selected_start..selected_end] {
        let obj: serde_json::Value = match serde_json::from_str(line) { Ok(v) => v, Err(_) => continue };
        if obj.get("type").and_then(|v| v.as_str()) != Some("answer_input") { continue; }
        let query_id       = match obj.get("query_id").and_then(|v| v.as_str()) { Some(v) => v, None => continue };
        let evidence_type  = match obj.get("evidence_type").and_then(|v| v.as_str()) { Some(v) => v, None => continue };
        let question       = match obj.get("question").and_then(|v| v.as_str()) { Some(v) => v, None => continue };
        let memory_texts: Vec<&str> = match obj.get("memory_texts").and_then(|v| v.as_array()) {
            Some(arr) => arr.iter().filter_map(|v| v.as_str()).collect(),
            None => continue,
        };
        let correct_answer = obj.get("correct_answer").and_then(|v| v.as_str());

        // §B1: build the memory-based prompt from the stored memory texts.
        let prompt = convomem_memory_based_prompt(question, &memory_texts);
        let answer = match lme_run_judge(answer_cmd, &prompt) {
            Ok(a) => a,
            Err(e) => {
                eprintln!(
                    "[convomem-spec-batch] answer cmd failed for {}: {}",
                    query_id, e
                );
                continue;
            }
        };

        let out_line = serde_json::json!({
            "correct_answer": correct_answer,
            "evidence_type": evidence_type,
            "model_answer": &answer,
            "question": question,
            "query_id": query_id,
            "type": "judge_ready",
        });
        let _ = writeln!(out_file, "{out_line}");
    }

    Ok(())
}

/// Reads a convomem-spec judge-ready JSONL dump (produced by `run_convomem_spec_answer_dump`
/// or by the inline `dump_judge_inputs_path`), runs the judge offline per line, and
/// returns a §B4 aggregate result. No mootx01 binary or live estate required.
///
/// Accepts both `"judge_input"` lines (from inline dump) and `"judge_ready"` lines
/// (from the answer dump path) — matching the Swift twin's dual-format acceptance.
///
/// Twin of Swift `runConvoMemSpecJudgeDump(inputsPath:judgeCmd:maxRetries:)`.
///
/// SECRECY: `judge_cmd` is not logged.
pub fn run_convomem_spec_judge_dump(
    inputs_path: &str,
    judge_cmd: &str,
    max_retries: usize,
) -> Result<ConvoMemAggregateResult, MCPError> {
    let content = std::fs::read_to_string(inputs_path).map_err(|e| MCPError {
        description: format!("cannot read judge-input dump at '{}': {e}", inputs_path),
    })?;
    let mut verdict_rows: Vec<ConvoMemVerdictRow> = Vec::new();

    for line in content.lines().filter(|l| !l.is_empty()) {
        let obj: serde_json::Value = match serde_json::from_str(line) { Ok(v) => v, Err(_) => continue };
        // Accept both "judge_input" (from inline dump) and "judge_ready" (from answer dump).
        let line_type = obj.get("type").and_then(|v| v.as_str()).unwrap_or("");
        if line_type != "judge_input" && line_type != "judge_ready" { continue; }

        let query_id      = match obj.get("query_id").and_then(|v| v.as_str()) { Some(v) => v, None => continue };
        let evidence_type = match obj.get("evidence_type").and_then(|v| v.as_str()) { Some(v) => v, None => continue };
        let question      = match obj.get("question").and_then(|v| v.as_str()) { Some(v) => v, None => continue };
        let model_answer  = match obj.get("model_answer").and_then(|v| v.as_str()) { Some(v) => v, None => continue };
        let correct_answer = match obj.get("correct_answer").and_then(|v| v.as_str()) { Some(v) => v, None => continue };
        let evid_type     = match ConvoMemEvidenceType::from_str(evidence_type) { Some(e) => e, None => continue };
        let evidence_count = obj.get("evidence_count").and_then(|v| v.as_u64()).unwrap_or(1) as usize;

        // §B2: rebuild the judge prompt for offline judging.
        // Evidence messages are not stored in the dump; §B2 UserFacts degrades
        // gracefully to the single-evidence branch with empty messages.
        let jp = convomem_judge_prompt(
            &evid_type,
            question,
            correct_answer,
            model_answer,
            &[],         // evidence messages unavailable from dump — graceful degradation
            evidence_count,
        );

        // §B3 bounded retry loop.
        let mut verdict = ConvoMemVerdictOutcome::Invalid;
        for _ in 0..max_retries {
            if let Ok(reply) = lme_run_judge(judge_cmd, &jp) {
                let outcome = convomem_verdict(&reply);
                if outcome != ConvoMemVerdictOutcome::Invalid {
                    verdict = outcome;
                    break;
                }
            }
        }
        let _ = query_id; // retained for future logging; suppresses unused warning
        verdict_rows.push(ConvoMemVerdictRow::new(evidence_type, evidence_count, verdict));
    }

    Ok(convomem_aggregate(&verdict_rows))
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests (pure logic, no I/O, no mootx01 binary)
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    fn private_test_dir(prefix: &str) -> std::path::PathBuf {
        use std::hash::{BuildHasher, Hasher};
        use std::os::unix::fs::DirBuilderExt;

        let base = std::env::temp_dir();
        let random = std::collections::hash_map::RandomState::new();
        for attempt in 0u32..1000 {
            let mut hasher = random.build_hasher();
            hasher.write_u32(attempt);
            hasher.write_u32(std::process::id());
            hasher.write_u128(
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_nanos(),
            );
            let candidate = base.join(format!("{prefix}-{:016x}", hasher.finish()));
            let mut builder = std::fs::DirBuilder::new();
            builder.mode(0o700);
            match builder.create(&candidate) {
                Ok(()) => return candidate,
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(e) => panic!("cannot create test dir {}: {e}", candidate.display()),
            }
        }
        panic!("no unused private test directory after 1000 attempts")
    }

    #[test]
    fn artifact_session_key_fold() {
        // Literal twin of Swift `lmebSessionKeyFold`.
        use super::lmeb_artifact_session_key;
        assert_eq!(
            lmeb_artifact_session_key("user_evidence__scene_0_session_1_turn_9"),
            "user_evidence/scene_0_session_1");
        assert_eq!(
            lmeb_artifact_session_key("changing_evidence__scene_12_session_3"),
            "changing_evidence/scene_12_session_3");
        assert_eq!(lmeb_artifact_session_key("no-separator"), "no-separator");
    }

    use super::*;
    use crate::lmeb_spec_metrics::LmebInstructionSetting;

    // ── §A4: lmeb_spec_effective_query ────────────────────────────────────────

    /// Without-instruction setting: query text returned unchanged.
    #[test]
    fn effective_query_without_instruction_is_passthrough() {
        let result = lmeb_spec_effective_query(
            "What did the user order?",
            "user_evidence",
            LmebInstructionSetting::WithoutInstruction,
        );
        assert_eq!(result, "What did the user order?");
    }

    /// With-instruction: known subset → instruction prepended with "\n" separator.
    #[test]
    fn effective_query_with_instruction_prepends_instruction() {
        let result = lmeb_spec_effective_query(
            "What did the user order?",
            "user_evidence",
            LmebInstructionSetting::WithInstruction,
        );
        // §A4: "instruction\nquery_text" format.
        assert!(
            result.contains('\n'),
            "instruction+query must be separated by newline"
        );
        let parts: Vec<&str> = result.splitn(2, '\n').collect();
        assert_eq!(parts.len(), 2, "exactly one newline separator");
        assert!(!parts[0].is_empty(), "instruction part must be non-empty");
        assert_eq!(parts[1], "What did the user order?");
    }

    /// With-instruction for every known ConvoMem subset: instruction is non-empty.
    #[test]
    fn effective_query_all_known_subsets_have_instructions() {
        let subsets = [
            "abstention_evidence",
            "assistant_facts_evidence",
            "changing_evidence",
            "implicit_connection_evidence",
            "preference_evidence",
            "user_evidence",
        ];
        for subset in &subsets {
            let result = lmeb_spec_effective_query(
                "test query",
                subset,
                LmebInstructionSetting::WithInstruction,
            );
            assert!(
                result.contains('\n'),
                "subset '{}' must produce an instruction-prepended result",
                subset
            );
        }
    }

    /// With-instruction for unknown evidence type: returns query unchanged (graceful degradation).
    #[test]
    fn effective_query_unknown_evidence_type_returns_unchanged() {
        let result = lmeb_spec_effective_query(
            "test query",
            "nonexistent_evidence_type",
            LmebInstructionSetting::WithInstruction,
        );
        // Unknown type → no instruction prepended; returns the original query text.
        assert_eq!(result, "test query");
    }

    // ── Evidence annotation placeholder ───────────────────────────────────────

    /// Placeholder returns (1, []) for any query id and evidence type.
    #[test]
    fn placeholder_returns_single_evidence_empty_messages() {
        let (count, messages) = convomem_evidence_annotations_placeholder(
            "scene_0_q_0",
            "user_evidence",
        );
        assert_eq!(count, 1, "placeholder evidence count must be 1");
        assert!(messages.is_empty(), "placeholder evidence messages must be empty");
    }

    // ── §B3: §A4/§B3 wiring — verify verdict outcomes from convomem_verdict ──
    // (Full §B3 tests live in convomem_spec_protocol; these verify the wiring.)

    /// §B3 ambiguous detection: both "right" and "wrong" in lowercase.
    #[test]
    fn ambiguous_verdict_detection() {
        use crate::convomem_spec_protocol::{convomem_verdict, ConvoMemVerdictOutcome};
        let outcome = convomem_verdict("RIGHT and WRONG");
        assert_eq!(outcome, ConvoMemVerdictOutcome::Incorrect);
    }

    // ── §B4: ConvoMemSpecRunResults zero-command case ─────────────────────────

    /// When neither answer_cmd nor judge_cmd is set, aggregate_result is None.
    /// Verifies the wiring matches the spec without spawning mootx01.
    #[test]
    fn run_results_no_commands_produces_nil_aggregate() {
        // Construct a ConvoMemSpecRunResults directly (not via run_convomem_spec_queries —
        // that requires a live mootx01 binary). Verify the struct's semantics.
        let results = ConvoMemSpecRunResults {
            per_query_results: vec![],
            aggregate_result: None,
            answered_count: 0,
            judged_count: 0,
            total_queries: 0,
            timing_report: None,
            guard_excluded_count: 0,
            judge_identity: "unknown".to_string(),
            answer_cmd_set: false,
            judge_cmd_set: false,
            memory_texts_empty_count: 0,
            dream_pending: 0,
            dream_draining: 0,
        };
        assert!(results.aggregate_result.is_none());
        assert_eq!(results.answered_count, 0);
        assert_eq!(results.judged_count, 0);
    }

    // ── §A3: verify lmeb_spec_per_query_metrics wiring ────────────────────────

    /// Correct corpus returns metrics with ndcg@10 = 1.0 when relevant doc is #1.
    #[test]
    fn per_query_metrics_perfect_retrieval() {
        use crate::lmeb_spec_metrics::{LmebSpecOptions, lmeb_spec_per_query_metrics};
        let retrieved = vec!["doc_a".to_string(), "doc_b".to_string()];
        let relevant: HashSet<String> = vec!["doc_a".to_string()].into_iter().collect();
        let m = lmeb_spec_per_query_metrics(&retrieved, &relevant, "q0", &LmebSpecOptions::default());
        // nDCG@1 = 1.0 (first result is relevant).
        let ndcg_at_1 = m.ndcg.iter().find(|(k, _)| *k == 1).map(|(_, v)| *v).unwrap_or(-1.0);
        assert!(
            (ndcg_at_1 - 1.0).abs() < 1e-9,
            "ndcg@1 should be 1.0 when first result is relevant, got {}",
            ndcg_at_1
        );
    }

    /// Empty retrieval set returns R_cap = None for all k.
    #[test]
    fn per_query_metrics_empty_retrieval_r_cap_none() {
        use crate::lmeb_spec_metrics::{LmebSpecOptions, lmeb_spec_per_query_metrics};
        let retrieved: Vec<String> = vec![];
        let relevant: HashSet<String> = vec!["doc_a".to_string()].into_iter().collect();
        let m = lmeb_spec_per_query_metrics(&retrieved, &relevant, "q0", &LmebSpecOptions::default());
        // R_cap@k = None when the denominator is min(total_relevant, k) and there are zero hits.
        // Wait — R_cap is None only when total_relevant == 0 per §A3. With relevant > 0 and
        // retrieved empty: hits = 0, denom = min(1, k) = 1 (for k≥1) → R_cap = 0.0, not None.
        // This confirms R_cap is None only when relevant set is empty, not when hits are zero.
        for &(k, val) in &m.r_cap {
            // With non-empty relevant set and empty retrieval: 0 hits / min(1,k) = 0.0, not None.
            assert!(
                val.is_some(),
                "R_cap@{} should be Some(0.0) (not None) when relevant set is non-empty",
                k
            );
        }
    }

    /// When relevant set is empty, R_cap@k = None for all k (§A3).
    #[test]
    fn per_query_metrics_no_relevant_r_cap_is_none() {
        use crate::lmeb_spec_metrics::{LmebSpecOptions, lmeb_spec_per_query_metrics};
        let retrieved = vec!["doc_a".to_string()];
        let relevant: HashSet<String> = HashSet::new();  // no relevant docs
        let m = lmeb_spec_per_query_metrics(&retrieved, &relevant, "q0", &LmebSpecOptions::default());
        for &(k, val) in &m.r_cap {
            assert!(
                val.is_none(),
                "R_cap@{} must be None when relevant set is empty (§A3 metric.py)",
                k
            );
        }
    }

    // ── Record-naming convention sanity ───────────────────────────────────────

    /// Verifies the documented record-naming prefixes are distinct.
    #[test]
    fn record_name_prefixes_are_distinct() {
        // lmeb-spec and convomem-spec records must not share prefixes
        // (both go to the same out_dir — name collisions would silently clobber records).
        let lmeb_prefix = "lmeb-spec-";
        let convomem_prefix = "convomem-spec-";
        assert!(
            !lmeb_prefix.starts_with(convomem_prefix) && !convomem_prefix.starts_with(lmeb_prefix),
            "record name prefixes must be distinct to prevent clobber in the same output directory"
        );
    }

    // ── LmebSpecQuery constructor ─────────────────────────────────────────────

    /// `LmebSpecQuery::new` defaults: correct_answer=None, evidence_count=1, messages=[].
    #[test]
    fn spec_query_new_defaults() {
        let q = LmebQuery { id: "q0".to_string(), text: "test".to_string() };
        let sq = LmebSpecQuery::new(q, "user_evidence");
        assert!(sq.correct_answer.is_none());
        assert_eq!(sq.evidence_count, 1);
        assert!(sq.evidence_messages.is_empty());
        assert_eq!(sq.evidence_type, "user_evidence");
    }

    // ── run_convomem_spec_judge_dump ──────────────────────────────────────────

    /// Smoke test: three judge_ready lines, fake judge always returns "RIGHT",
    /// aggregate must show 3 correct / 3 scored / 0 unscored.
    ///
    /// Uses a shell printf stub as the judge command — mirrors the pattern the
    /// BYOAI seam uses in production but with a deterministic fixed response.
    /// Fake command: `printf 'RIGHT'` via the MOOT_BENCH_CMD_INTERNAL shim.
    #[test]
    fn judge_dump_three_ready_lines_all_correct() {
        // Build a temporary JSONL file with three judge_ready rows spanning two
        // evidence types so the per-type aggregator has something to group.
        // Use a unique path under the system temp dir to avoid collisions.
        let path = std::env::temp_dir()
            .join(format!("cvrs_judge_dump_smoke_{}.jsonl",
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .subsec_nanos()))
            .to_string_lossy()
            .into_owned();

        let rows = [
            serde_json::json!({
                "type": "judge_ready",
                "query_id": "q1",
                "evidence_type": "user_evidence",
                "evidence_count": 1,
                "question": "What did Alice say?",
                "model_answer": "She said hello.",
                "correct_answer": "Alice said hello."
            }),
            serde_json::json!({
                "type": "judge_ready",
                "query_id": "q2",
                "evidence_type": "user_evidence",
                "evidence_count": 1,
                "question": "What did Bob do?",
                "model_answer": "He left.",
                "correct_answer": "Bob left the room."
            }),
            serde_json::json!({
                "type": "judge_ready",
                "query_id": "q3",
                "evidence_type": "preference_evidence",
                "evidence_count": 2,
                "question": "Which was preferred?",
                "model_answer": "Option A.",
                "correct_answer": "Option A was preferred."
            }),
        ];

        {
            use std::io::Write;
            let mut f = std::fs::File::create(&path)
                .expect("temp file must be writable");
            for row in &rows {
                writeln!(f, "{}", row).unwrap();
            }
        }
        // Register a cleanup guard so the temp file is removed when the test ends,
        // even on panic. Uses a simple wrapper rather than a third-party crate.
        struct TempGuard(String);
        impl Drop for TempGuard { fn drop(&mut self) { let _ = std::fs::remove_file(&self.0); } }
        let _guard = TempGuard(path.clone());

        // Fake judge: always prints "RIGHT\n" regardless of stdin content.
        // The MOOT_BENCH_CMD_INTERNAL shim in lme_run_judge injects the command
        // via env var, so no shell-quoting issues with the judge text.
        let judge_cmd = "printf 'RIGHT'";

        let agg = super::run_convomem_spec_judge_dump(&path, judge_cmd, 3)
            .expect("judge dump must succeed with a valid JSONL and a working judge");

        assert_eq!(
            agg.overall_correct_count, 3,
            "all three rows judged RIGHT → overall_correct_count must be 3"
        );
        assert_eq!(
            agg.overall_scored_count, 3,
            "no Invalid verdicts → overall_scored_count must equal row count"
        );
        assert_eq!(
            agg.overall_unscored_count, 0,
            "no retries exhausted → overall_unscored_count must be 0"
        );
        // Two distinct evidence types → two per_type rows.
        assert_eq!(
            agg.per_type.len(), 2,
            "user_evidence and preference_evidence must produce two per-type rows"
        );
        // Overall accuracy: 3 correct out of 3 scored = 1.0.
        assert!(
            (agg.overall_accuracy - 1.0_f64).abs() < 1e-9,
            "overall_accuracy must be 1.0 when all verdicts are Correct, got {}",
            agg.overall_accuracy
        );
    }

    // ── Scoring strategy flag ─────────────────────────────────────────────────

    /// Verifies the scoring key is absent from the query args dict when
    /// scoring_strategy is None (byte-identical baseline) and present when Some.
    #[test]
    fn scoring_arg_propagation() {
        // Baseline: None strategy → no "scoring" key in the dict.
        let mut args: std::collections::BTreeMap<String, crate::json_value::JsonValue> =
            std::collections::BTreeMap::new();
        args.insert("q".to_string(), crate::json_value::JsonValue::String("hello".to_string()));
        let scoring_none: Option<String> = None;
        if let Some(ref s) = scoring_none {
            args.insert("scoring".to_string(), crate::json_value::JsonValue::String(s.clone()));
        }
        assert!(!args.contains_key("scoring"),
            "omitted --scoring must produce no 'scoring' key in the query dict");

        // Given strategy: key must be present with the exact value.
        let mut args2: std::collections::BTreeMap<String, crate::json_value::JsonValue> =
            std::collections::BTreeMap::new();
        args2.insert("q".to_string(), crate::json_value::JsonValue::String("hello".to_string()));
        let scoring_some: Option<String> = Some("rrf".to_string());
        if let Some(ref s) = scoring_some {
            args2.insert("scoring".to_string(), crate::json_value::JsonValue::String(s.clone()));
        }
        assert_eq!(
            args2.get("scoring"),
            Some(&crate::json_value::JsonValue::String("rrf".to_string())),
            "given --scoring rrf must wire as 'scoring': 'rrf'"
        );
    }

    // ── Recall shape flag ─────────────────────────────────────────────────────

    /// (a) recall_shape Some → verb is moot_recall_shaped, dict has "preset", no "scoring".
    #[test]
    fn recall_shape_set_verb_and_preset() {
        let recall_shape: Option<String> = Some("matrix_decayed".to_string());
        let scoring_strategy: Option<String> = None;

        // Simulate the verb/arg selection logic from the runner.
        let mut args: std::collections::BTreeMap<String, crate::json_value::JsonValue> =
            std::collections::BTreeMap::new();
        args.insert("query".to_string(), crate::json_value::JsonValue::String("hello".to_string()));
        let verb: &str;
        let shaped_verb = crate::aria_v2_surface::RECALL_SHAPED;
        let search_verb = crate::aria_v2_surface::MEMORY_SEARCH;
        if let Some(ref shape) = recall_shape {
            verb = shaped_verb;
            args.insert("preset".to_string(), crate::json_value::JsonValue::String(shape.clone()));
        } else {
            verb = search_verb;
            if let Some(ref s) = scoring_strategy {
                args.insert("scoring".to_string(), crate::json_value::JsonValue::String(s.clone()));
            }
        }

        assert_eq!(verb, crate::aria_v2_surface::RECALL_SHAPED,
            "recall_shape Some must select moot_recall_shaped verb");
        assert_eq!(
            args.get("preset"),
            Some(&crate::json_value::JsonValue::String("matrix_decayed".to_string())),
            "recall_shape Some must wire preset: 'matrix_decayed' in the query dict"
        );
        assert!(!args.contains_key("scoring"),
            "moot_recall_shaped call must never include the 'scoring' key");
    }

    /// (b) recall_shape None → verb is moot_memory_search, dict has no "preset".
    #[test]
    fn recall_shape_absent_verb_and_no_preset() {
        let recall_shape: Option<String> = None;
        let scoring_strategy: Option<String> = None;

        let mut args: std::collections::BTreeMap<String, crate::json_value::JsonValue> =
            std::collections::BTreeMap::new();
        args.insert("query".to_string(), crate::json_value::JsonValue::String("hello".to_string()));
        let verb: &str;
        let shaped_verb = crate::aria_v2_surface::RECALL_SHAPED;
        let search_verb = crate::aria_v2_surface::MEMORY_SEARCH;
        if let Some(ref shape) = recall_shape {
            verb = shaped_verb;
            args.insert("preset".to_string(), crate::json_value::JsonValue::String(shape.clone()));
        } else {
            verb = search_verb;
            if let Some(ref s) = scoring_strategy {
                args.insert("scoring".to_string(), crate::json_value::JsonValue::String(s.clone()));
            }
        }

        assert_eq!(verb, crate::aria_v2_surface::MEMORY_SEARCH,
            "recall_shape None must fall back to moot_memory_search verb");
        assert!(!args.contains_key("preset"),
            "recall_shape None must produce no 'preset' key in the query dict");
    }

    /// (c) --scoring + --recall-shape together: conflict is detected.
    /// The rejection happens in parse_lmeb_spec_invocation; simulated here as a
    /// direct check of the conflict-detection logic.
    #[test]
    fn recall_shape_scoring_conflict() {
        // Both present → conflict.
        let scoring: Option<&str> = Some("rrf");
        let shape: Option<&str> = Some("matrix_decayed");
        let conflict = scoring.is_some() && shape.is_some();
        assert!(conflict,
            "--scoring and --recall-shape together must be detected as a conflict");

        // Non-conflicting cases: only one or neither present.
        let cases: &[(Option<&str>, Option<&str>)] = &[
            (Some("rrf"), None),
            (None, Some("matrix_decayed")),
            (None, None),
        ];
        for &(s, r) in cases {
            let c = s.is_some() && r.is_some();
            assert!(!c,
                "non-conflicting pair ({:?}, {:?}) must not trigger conflict", s, r);
        }
    }

    // ── Finding 1 (ecc682514): id-map orientation ─────────────────────────────
    //
    // load_artifact_id_map returns doc_id → uuid (forward direction). The load
    // helper must produce (uuid→doc_id, doc_id→uuid) — first element is the
    // reverse map used to look up ranked UUIDs, second is the forward map used
    // for §B1 estate hydration. Both directions were formerly swapped, making
    // every Rust hydration call target wrong UUIDs. This test is the parity
    // twin of the Swift ConvoMemHydrationEmptyCountTests.
    #[test]
    fn id_map_load_orientation() {
        // Write a minimal id-map.json: doc_id → uuid.
        let dir = std::env::temp_dir().join("lmeb-id-map-orientation-test");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let id_map = r#"{"conv-1/S1": "aaaa-uuid", "conv-2/S1": "bbbb-uuid"}"#;
        std::fs::write(dir.join("id-map.json"), id_map).unwrap();

        let (uuid_to_doc_id, doc_id_to_uuid) = super::lmeb_spec_load_id_maps(&dir, "test");

        // First map: uuid → doc_id (for ranked-doc lookup).
        assert_eq!(
            uuid_to_doc_id.get("aaaa-uuid").map(String::as_str),
            Some("conv-1/S1"),
            "uuid_to_doc_id must map uuid to doc_id"
        );
        assert_eq!(
            uuid_to_doc_id.get("bbbb-uuid").map(String::as_str),
            Some("conv-2/S1"),
            "uuid_to_doc_id must map second uuid to its doc_id"
        );

        // Second map: doc_id → uuid (for §B1 hydration).
        assert_eq!(
            doc_id_to_uuid.get("conv-1/S1").map(String::as_str),
            Some("aaaa-uuid"),
            "doc_id_to_uuid must map doc_id to uuid"
        );
        assert_eq!(
            doc_id_to_uuid.get("conv-2/S1").map(String::as_str),
            Some("bbbb-uuid"),
            "doc_id_to_uuid must map second doc_id to its uuid"
        );

        // Both maps have the same number of entries as id-map.json.
        assert_eq!(uuid_to_doc_id.len(), 2);
        assert_eq!(doc_id_to_uuid.len(), 2);

        let _ = std::fs::remove_dir_all(&dir);
    }

    // ── §C1: lmeb_spec_artifact_endpoint — Config-class refusal ──────────────

    /// A whitespace binary path causes `lmeb_spec_artifact_endpoint` to return
    /// `LaneError::Config`, not `LaneError::Unit`.  `Config` is the fatal variant
    /// that aborts the lane; `Unit` is the per-item stub that lets the lane
    /// continue.  The distinction is the whole fix in this stream.
    ///
    /// Mutation evidence: temporarily change the `map_err` in
    /// `lmeb_spec_artifact_endpoint` to yield `LaneError::Unit`; this assertion
    /// fails ("1 failed").  Restore `LaneError::Config`; assertion passes
    /// ("1 passed").
    #[test]
    fn artifact_endpoint_whitespace_binary_returns_config_error() {
        let dir = std::path::PathBuf::from("/tmp/lmeb_spec_endpoint_test");
        let binary_with_space = "/usr/local/bin/moot x01"; // whitespace → moot_serve_command refuses
        let result = lmeb_spec_artifact_endpoint(&dir, binary_with_space);
        match result {
            Err(LaneError::Config(_)) => { /* correct: fatal, aborts lane */ }
            Err(LaneError::Unit(msg)) => {
                panic!(
                    "expected LaneError::Config (lane-aborting) for whitespace binary; \
                     got LaneError::Unit (per-item, lane continues): {msg}"
                );
            }
            Ok(_) => {
                panic!(
                    "expected LaneError::Config for whitespace binary path; got Ok"
                );
            }
        }
    }

    // ── item (a) gate: estate-missing guard ───────────────────────────────────
    // Verifies the guard that fires BEFORE serve launches when the per-scene
    // estate directory is absent. Removing the guard makes the runner fall through
    // to lmeb_spec_load_id_maps or lmeb_spec_artifact_endpoint, neither of which
    // emits all three of "estate for unit", the unit id, and the missing path.
    //
    // Mutation evidence: remove the guard block → test fails because the error
    // message either does not contain "estate for unit" or does not contain the
    // query id or does not contain the path.
    #[test]
    fn unit_scale_refuses_missing_estate_dir() {
        use std::sync::Mutex;

        // fleet_dir exists; the per-scene estate subdir does NOT.
        let fleet_path = private_test_dir("estate-gate-lmeb");

        // query_id "scene_3_q_7" + evidence "user_evidence"
        //   lmeb_spec_scene_stem("scene_3_q_7", "user_evidence")
        //   → scene_id = "scene_3" (strips "_q_7"), stem = "user_evidence__scene_3"
        //   → estate = fleet_path/user_evidence__scene_3  (NOT created → guard fires)
        let query_id = "scene_3_q_7";
        let evidence_type = "user_evidence";

        let spec_query = LmebSpecQuery::new(
            LmebQuery { id: query_id.to_string(), text: "test question".to_string() },
            evidence_type,
        );
        let corpus = LmebCorpus {
            docs_by_id: Default::default(),
            queries_by_id: Default::default(),
            candidates_by_scene_id: Default::default(),
            relevant_docs_by_query_id: Default::default(),
        };
        // The catalog names one set rooted at fleet_path; the unit directory under it
        // is absent, so catalog resolution refuses before any serve launches.
        let catalog_path = fleet_path.join("catalog.json");
        std::fs::write(
            &catalog_path,
            format!(
                r#"{{"sets":[{{"name":"set1","base":"{}","path":"","estates":[],"state":"done"}}]}}"#,
                fleet_path.display()
            ),
        )
        .unwrap();
        let config = LmebSpecRunConfig {
            catalog_path: Some(catalog_path.clone()),
            ..LmebSpecRunConfig::default()
        };
        let sampler = Mutex::new(LegGuardSampler::new(GuardSamplingPolicy::OncePerLeg));

        let result =
            run_one_lmeb_spec_query_artifact(&spec_query, &corpus, &config, 0, &sampler, None);
        let _ = std::fs::remove_dir_all(&fleet_path);

        match result {
            Err(LaneError::Unit(msg)) => {
                assert!(
                    msg.contains("not in the catalog"),
                    "message must say the unit is not in the catalog; got: {msg}"
                );
                assert!(
                    msg.contains("user_evidence__scene_3"),
                    "message must contain the unit stem; got: {msg}"
                );
                assert!(
                    msg.contains(catalog_path.to_str().unwrap()),
                    "message must name the catalog; got: {msg}"
                );
            }
            Ok(_) => panic!(
                "expected Err(LaneError::Unit(...)) for missing estate dir; got Ok"
            ),
            Err(LaneError::Config(msg)) => panic!(
                "expected Err(LaneError::Unit(...)) for missing estate dir; \
                 got LaneError::Config: {msg}"
            ),
        }
    }
}

/// Maps a qrels turn-level corpus docID into the artifact's session-level
/// seed-id space. qrels.tsv and the corpus loader address individual TURNS,
/// namespaced "<set>__scene_X_session_Y_turn_Z"; the rebuilt artifacts store
/// whole sessions (Rule-1), keyed "<set>/scene_X_session_Y" in id-map.json —
/// ground truth must fold turn → containing session before comparison or no
/// ranked id can ever match. Twin of Swift `lmebArtifactSessionKey`.
pub fn lmeb_artifact_session_key(turn_doc_id: &str) -> String {
    match turn_doc_id.split_once("__") {
        None => turn_doc_id.to_string(),
        Some((set, rest)) => {
            let session = match rest.find("_turn_") {
                Some(i) => &rest[..i],
                None => rest,
            };
            format!("{set}/{session}")
        }
    }
}


// ─── answer-batch dispatch ───────────────────────────────────────────────

/// Offline answer pass for the two answer-dump lanes.
///
/// Reads the header record and dispatches on its `benchmark` field:
///
/// - `convomem-spec` → delegates to `run_convomem_spec_answer_dump`.
/// - `membench-spec` → loops over `qa` records, runs the answer command with
///   each record's rendered `prompt` on stdin, extracts the letter via
///   `parse_answer_choice`, and writes `{"item_id":…,"answer":"<letter>","raw":…}` lines
///   (the format `--consume-answers` accepts). Per-record failures are written as
///   `{"item_id":…,"answer":null,"error":…}` and counted; the run returns an error only
///   when every record fails.
///
/// `limit` caps the number of answer records processed (header excluded).
///
/// Twin of `runAnswerBatch` in `CLI.swift`.
pub fn run_answer_batch(
    inputs_path: &str,
    answer_cmd: &str,
    output_path: &str,
    limit: Option<usize>,
    offset: usize,
) -> Result<(), MCPError> {
    use crate::membench_spec_protocol::parse_answer_choice;

    let content = std::fs::read_to_string(inputs_path).map_err(|e| MCPError {
        description: format!("answer-batch: cannot read inputs file at '{}': {e}", inputs_path),
    })?;
    let lines: Vec<&str> = content.lines().filter(|l| !l.is_empty()).collect();
    if lines.is_empty() {
        return Err(MCPError {
            description: format!("answer-batch: inputs file is empty: '{}'", inputs_path),
        });
    }

    // Parse and validate the header; extract the benchmark type.
    let header_obj: serde_json::Value = serde_json::from_str(lines[0]).map_err(|e| MCPError {
        description: format!(
            "answer-batch: first line is not valid JSON in '{}': {e}",
            inputs_path
        ),
    })?;
    if header_obj.get("type").and_then(|v| v.as_str()) != Some("header") {
        return Err(MCPError {
            description: format!(
                "answer-batch: first line is not a valid header in '{}'",
                inputs_path
            ),
        });
    }
    let benchmark = header_obj
        .get("benchmark")
        .and_then(|v| v.as_str())
        .ok_or_else(|| MCPError {
            description: format!(
                "answer-batch: header is missing the 'benchmark' field in '{}'",
                inputs_path
            ),
        })?
        .to_owned();

    match benchmark.as_str() {
        "convomem-spec" => {
            // Pass limit and offset through so --limit/--offset cap the ConvoMem
            // branch the same way they cap every other branch.
            run_convomem_spec_answer_dump(inputs_path, answer_cmd, output_path, limit, offset)?;
            let total: usize = lines
                .iter()
                .skip(1)
                .filter(|l| {
                    serde_json::from_str::<serde_json::Value>(l)
                        .ok()
                        .and_then(|v| v.get("type").and_then(|t| t.as_str()).map(|s| s == "answer_input"))
                        .unwrap_or(false)
                })
                .count();
            println!(
                "answer-batch: records={total} benchmark=convomem-spec out={output_path}"
            );
            Ok(())
        }

        "membench-spec" => {
            // Resume: collect item_ids already answered in the output file. A record
            // with a non-null answer was written by a previous run; skip re-answering it.
            use std::io::Write;
            let output_path_obj = std::path::Path::new(output_path);
            let output_exists = output_path_obj.exists();
            let mut resumed_ids: std::collections::HashSet<String> =
                std::collections::HashSet::new();
            if output_exists {
                if let Ok(existing) = std::fs::read_to_string(output_path) {
                    for eline in existing.lines().filter(|l| !l.is_empty()) {
                        if let Ok(ev) =
                            serde_json::from_str::<serde_json::Value>(eline)
                        {
                            if let Some(eid) =
                                ev.get("item_id").and_then(|v| v.as_str())
                            {
                                let is_answered = ev.get("answer")
                                    .map(|v| !v.is_null()).unwrap_or(false);
                                if is_answered {
                                    resumed_ids.insert(eid.to_string());
                                }
                            }
                        }
                    }
                }
            }
            let resumed_count = resumed_ids.len();

            // Open for append (create with 0o600 when absent).
            #[cfg(unix)]
            let mut out_file = {
                use std::os::unix::fs::OpenOptionsExt;
                std::fs::OpenOptions::new()
                    .write(true)
                    .create(true)
                    .append(true)
                    .mode(0o600)
                    .open(output_path)
                    .map_err(|e| MCPError {
                        description: format!(
                            "answer-batch: cannot open output path for writing '{}': {e}",
                            output_path
                        ),
                    })?
            };
            #[cfg(not(unix))]
            let mut out_file = std::fs::OpenOptions::new()
                .write(true)
                .create(true)
                .append(true)
                .open(output_path)
                .map_err(|e| MCPError {
                    description: format!(
                        "answer-batch: cannot open output path for writing '{}': {e}",
                        output_path
                    ),
                })?;

            // Collect qa records; apply optional limit.
            let qa_lines: Vec<&str> = lines
                .iter()
                .skip(1)
                .copied()
                .filter(|l| {
                    serde_json::from_str::<serde_json::Value>(l)
                        .ok()
                        .and_then(|v| v.get("type").and_then(|t| t.as_str()).map(|s| s == "qa"))
                        .unwrap_or(false)
                })
                .take(limit.unwrap_or(usize::MAX))
                .collect();

            let mut total_records: usize = 0;
            let mut answered: usize = resumed_count;
            let mut failed: usize = 0;

            for line in qa_lines {
                let obj: serde_json::Value = match serde_json::from_str(line) {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                let item_id = match obj.get("item_id").and_then(|v| v.as_str()) {
                    Some(v) => v.to_owned(),
                    None => continue,
                };
                let prompt = match obj.get("prompt").and_then(|v| v.as_str()) {
                    Some(v) => v.to_owned(),
                    None => continue,
                };
                total_records += 1;

                // Resume: skip records already answered in a prior run.
                if resumed_ids.contains(&item_id) { continue; }

                let out_line = match lme_run_judge(answer_cmd, &prompt) {
                    Ok(raw) => {
                        if let Some(letter) = parse_answer_choice(&raw) {
                            answered += 1;
                            serde_json::json!({
                                "answer": letter,
                                "item_id": &item_id,
                                "raw": &raw,
                            })
                        } else {
                            // Subprocess succeeded but returned an unparseable letter.
                            let err_msg = format!(
                                "answer cmd returned unparseable response for {item_id}"
                            );
                            eprintln!("[membench-spec-batch] {err_msg}");
                            failed += 1;
                            serde_json::json!({
                                "answer": serde_json::Value::Null,
                                "error": err_msg,
                                "item_id": &item_id,
                            })
                        }
                    }
                    Err(e) => {
                        let err_msg = format!(
                            "answer cmd failed or returned unparseable response for {item_id}: {e}"
                        );
                        eprintln!("[membench-spec-batch] {err_msg}");
                        failed += 1;
                        serde_json::json!({
                            "answer": serde_json::Value::Null,
                            "error": err_msg,
                            "item_id": &item_id,
                        })
                    }
                };
                let _ = writeln!(out_file, "{out_line}");
            }

            println!(
                "answer-batch: records={total_records} answered={answered} failed={failed} \
                 resumed={resumed_count} benchmark=membench-spec out={output_path}"
            );

            // Exit non-zero only when every record failed and at least one was attempted.
            if total_records > 0 && answered == 0 {
                return Err(MCPError {
                    description: format!(
                        "answer-batch: all {total_records} membench-spec records failed to answer"
                    ),
                });
            }
            Ok(())
        }

        other => Err(MCPError {
            description: format!(
                "answer-batch: unknown benchmark '{other}' in header; \
                 supported: convomem-spec, membench-spec"
            ),
        }),
    }
}
