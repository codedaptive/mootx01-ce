//! lme_spec_runner.rs — Spec-compliant LongMemEval runner (Rust twin of
//! `LMESpecRunner.swift`).
//!
//! # Estate source (run book §8, the #94 measure seam)
//!
//! The runner opens the PRE-BUILT artifacts — at unit scale one fleet estate per
//! question (the official per-instance protocol scope, unit stem = question_id),
//! at bench-aggregate the one Form-2 estate with questions run serially.
//! It builds nothing, settles nothing, and never deletes anything; id-map.json
//! inside each estate maps seed record ids (raw session ids, e.g.
//! "3722ea11_2") to drawer UUIDs.
//!
//! # Protocol conformance
//!
//!   §6 row 2 fix: ALL 500 instances (including abstentions) flow through the
//!                 full ask path; `LmeSpecCorpus` loads them;
//!                 `LmeSpecQuestion::is_abstention()` is used only for
//!                 judge-prompt selection (§2) and the §4 abstention accuracy
//!                 sub-metric.
//!
//!   §6 row 1 fix: The judge receives a §2 anscheck prompt (from
//!                 `lme_spec_grader::anscheck_prompt`) NOT the evidence-payload
//!                 prompt from `longmemeval_judge`. §3 call parameters
//!                 (model, n=1, temperature=0, max_tokens=10) are recorded in
//!                 every judge-input dump line.
//!
//!   §6 row 3 fix: §4 aggregation (per-type, task-averaged, overall, abstention
//!                 accuracy) is implemented via `lme_spec_aggregate`.
//!
//!   §6 row 4:     Hypothesis = `moot_synthesize` output (the estate's native
//!                 answer text). Official hypothesis records JSONL
//!                 `{"question_id":…,"hypothesis":…}` are written alongside
//!                 the harness report.
//!
//! # Judging seam (BYOAI posture, no vendor SDK)
//!
//!   1. Inline:  `judge_cmd` is `Some` → `lme_run_judge` subprocess seam is
//!               called per question; §3 verdict rule applied; verdicts
//!               aggregated §4.
//!   2. Dump:    `dump_judge_inputs_path` is `Some` → anscheck prompts written
//!               to JSONL; operator runs judge externally; `lme_spec_run_judge_batch`
//!               consumes output.
//!   3. Neither: run records `judged_count: 0`; aggregate is absent from report.
//!
//! Do NOT wire CLI entry points. Expose `run_lme_spec` and
//! `lme_spec_run_judge_batch`; the orchestrator (main.rs) wires the lane.

use crate::artifact_recall::{load_artifact_id_map, ArtifactTargetScale};
use crate::degeneracy_guard::{GuardSamplingPolicy, LegGuardSampler};
use crate::json_value::JsonValue;
use crate::lme_spec_corpus::LmeSpecQuestion;
use crate::lme_spec_grader::{
    anscheck_prompt, lme_spec_aggregate, lme_spec_verdict, LmeSpecVerdictRecord,
};
use crate::longmemeval_judge::lme_run_judge;
use crate::longmemeval_runner::{lme_verb_map, probe_mcp_client, SplitMix64};
use crate::mcp_client::{MCPClient, ToolCaller};
use crate::record_writer::{record_filename, write_record_never_overwrite};
use crate::scratch_posture::{moot_serve_command, LaneError};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::io::Write as IoWrite;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

// ─────────────────────────────────────────────────────────────────────────────
// Run configuration
// ─────────────────────────────────────────────────────────────────────────────

/// Configuration for one lme-spec run. Built from CLI arguments in the caller.
///
/// Mirrors `LmeSpecRunConfig` (Swift) conventions with the lme-spec-specific
/// additions: `judge_model` (§3 model identity), `dump_judge_inputs_path`
/// (offline judge seam).
pub struct LmeSpecRunConfig {
    // ── Dataset ───────────────────────────────────────────────────────────────
    /// Path to the mootx01 binary (stdio MCP server launched per question).
    pub moot_binary: String,
    /// Path to the LongMemEval variant JSON (e.g. longmemeval_m_cleaned.json).
    pub dataset_path: PathBuf,
    /// Variant name: "s", "m", or "oracle". Recorded in the report arm label.
    pub variant: String,

    // ── Question selection ────────────────────────────────────────────────────
    /// Maximum questions to run. None = all questions in the spec corpus (500).
    pub limit: Option<usize>,
    /// Skip this many questions from the seeded-shuffled list.
    pub offset: usize,
    /// Seed for deterministic question shuffling (SplitMix64 Fisher-Yates).
    pub seed: u64,

    // ── Output ────────────────────────────────────────────────────────────────
    /// Directory for the report and params sidecar. None = current directory.
    pub out_dir: Option<PathBuf>,
    /// Human-readable label, e.g. "lme-spec-m-seed42".
    pub run_label: String,
    /// RecordWriter serial tying report to params sidecar.
    pub run_serial: String,

    // ── Judge seam ────────────────────────────────────────────────────────────
    /// Where to write the JSONL dump of anscheck prompts for offline judging.
    /// None = do not write a dump file.
    pub dump_judge_inputs_path: Option<String>,
    /// Shell command for inline judging (e.g. "claude -p" or "./judge.sh").
    /// None = no inline judging.
    /// SECURITY: this field may carry API keys; only boolean presence is recorded.
    pub judge_cmd: Option<String>,
    /// §3 model identifier recorded in judge-input lines and verdict records.
    pub judge_model: String,

    // ── Artifact estate seam (run book §8) ───────────────────────────────────
    /// Which artifact scale the run opens. unit (default) opens one fleet estate
    /// per question (unit stem = question_id); bench-aggregate opens the one
    /// Form-2 estate serially. completeAggregate is REFUSED for this lane.
    pub target_scale: ArtifactTargetScale,
    /// Path to the dataset's catalog.json (required at unit scale). The catalog
    /// resolves each question_id to its estate directory across primary and
    /// secondary bases.
    pub catalog_path: Option<PathBuf>,
    /// The Form-2 estate directory. Required at bench-aggregate scale.
    pub estate_dir: Option<PathBuf>,
    /// Parallelism cap. bench-aggregate forces 1; unit scale uses this value.
    pub parallel_units: usize,
    /// Guard probe sampling policy.
    pub guard_sampling_policy: GuardSamplingPolicy,
    /// SHA-256 of the corpus fixture file. "unknown" when unreadable.
    pub corpus_digest: String,
    /// Binary identity for the §6 required report fields
    /// (BENCHMARK_METHOD.md §6; STEP7_FINDINGS.md F1). Collected at the CLI
    /// layer; None for library/test callers. Twin of Swift (2026-08-18 doctrine).
    pub run_environment: Option<crate::run_environment::IdentityEnvironment>,
    // ── Answer-input dump seam (reader-model flow) ────────────────────────────
    /// Where to write the JSONL dump of answer inputs (memory texts + question).
    /// When set, the runner calls moot_memory_search, hydrates the top-K drawer
    /// texts via moot_memory_get, and writes one answer_input line per question.
    /// The hypothesis_digest (moot_synthesize output) is included for reference
    /// but is NOT the hypothesis; a reader model reads the memory_texts instead.
    /// None = do not write an answer-input dump.
    pub dump_answer_inputs_path: Option<String>,
    /// Number of drawer texts to hydrate per question via moot_memory_get.
    /// Default 10 matches the convomem-spec answerHydrationDepth default.
    pub answer_hydration_depth: usize,
    /// Depth tier passed as the `depth` argument to `moot_memory_get` during
    /// answer-input hydration. `Distilled` is the production shape — the reader
    /// sees what a real caller would receive. `Full` is the comparison arm for
    /// ablation. Default: `Distilled`.
    pub answer_hydration_tier: crate::journey_driver::HydrationDepth,
}

// ─────────────────────────────────────────────────────────────────────────────
// Artifact estate endpoint
// ─────────────────────────────────────────────────────────────────────────────

/// Builds an EndpointConfig pointing at a pre-built artifact estate.
///
/// READ-ONLY use: the lane only calls moot_synthesize (and the guard probe tool).
/// Deliberately NOT routed through assertScratchBackend — the estate is a
/// durable artifact, not a scratch dir; same posture as ArtifactRecallRunner.
///
/// Command: `MOOTX01_FROZEN=1 MOOTX01_SUBJECT_RIDER=0 <binary> serve --db <estate>`
/// Builds the serve command for a pre-built lme-spec artifact estate. Returns
/// `LaneError::Config` when `moot_serve_command` refuses the path (e.g.
/// whitespace) so callers can propagate the refusal as a fatal lane abort
/// rather than absorbing it into a per-question guard-excluded stub.
fn lme_spec_artifact_endpoint(estate_dir: &Path, moot_binary: &str) -> Result<crate::config::EndpointConfig, LaneError> {
    use crate::config::{EndpointRole, Transport};
    let data_dir = estate_dir.to_string_lossy();
    // Transient record (--db <dir>) is plaintext by rule; no env prefix needed.
    let command = moot_serve_command(moot_binary, Path::new(&*data_dir), false, &["MOOTX01_FROZEN=1", "MOOTX01_SUBJECT_RIDER=0"], None)
        .map_err(|e| LaneError::Config(e.to_string()))?;
    Ok(crate::config::EndpointConfig {
        name: "mootx01-lme-spec".to_string(),
        transport: Transport::Stdio { command },
        auth: None,
        verb_map: lme_verb_map(),
        role: EndpointRole::Both,
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// JSONL line builders
// ─────────────────────────────────────────────────────────────────────────────

/// Builds one official §1 hypothesis JSONL line: `{"hypothesis":…,"question_id":…}`.
///
/// Keys are sorted (alphabetical: `hypothesis` before `question_id`) to match
/// the Swift twin's `JSONSerialization.sortedKeys` output.
///
/// An empty hypothesis is written as `""` rather than omitting the record —
/// every question must appear so the line count equals the question count.
fn lme_spec_hypothesis_line(question_id: &str, hypothesis: Option<&str>) -> Option<String> {
    let mut obj: BTreeMap<&str, &str> = BTreeMap::new();
    let hyp_str = hypothesis.unwrap_or("");
    obj.insert("hypothesis", hyp_str);
    obj.insert("question_id", question_id);
    match serde_json::to_string(&obj) {
        Ok(s) => Some(s + "\n"),
        Err(_) => None,
    }
}

/// Builds one judge-input dump JSONL line.
///
/// Keys are alphabetically sorted to match the Swift twin's `.sortedKeys` output.
/// Schema: anscheck_prompt, base_question_type, hypothesis, is_abstention,
/// max_tokens (§3: 10), model (§3), n (§3: 1), question_id, temperature (§3: 0),
/// type ("question").
fn lme_spec_judge_input_line(
    question_id: &str,
    base_question_type: &str,
    is_abstention: bool,
    hypothesis: &str,
    anscheck_prompt_text: &str,
    judge_model: &str,
    retrieved_drawer_ids: &[String],
) -> Option<String> {
    use serde_json::Value;
    let mut obj: BTreeMap<&str, Value> = BTreeMap::new();
    obj.insert(
        "anscheck_prompt",
        Value::String(anscheck_prompt_text.to_owned()),
    );
    obj.insert(
        "base_question_type",
        Value::String(base_question_type.to_owned()),
    );
    obj.insert("hypothesis", Value::String(hypothesis.to_owned()));
    obj.insert("is_abstention", Value::Bool(is_abstention));
    obj.insert(
        "max_tokens",
        Value::Number(serde_json::Number::from(10u64)),
    );
    obj.insert("model", Value::String(judge_model.to_owned()));
    obj.insert("n", Value::Number(serde_json::Number::from(1u64)));
    obj.insert("question_id", Value::String(question_id.to_owned()));
    // Drawer UUIDs from moot_synthesize; recorded for artifact-recall scoring.
    obj.insert(
        "retrieved_drawer_ids",
        Value::Array(retrieved_drawer_ids.iter().map(|s| Value::String(s.clone())).collect()),
    );
    obj.insert(
        "temperature",
        Value::Number(serde_json::Number::from(0u64)),
    );
    obj.insert("type", Value::String("question".to_owned()));
    match serde_json::to_string(&obj) {
        Ok(s) => Some(s + "\n"),
        Err(_) => None,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-question result
// ─────────────────────────────────────────────────────────────────────────────

/// The result of running the lme-spec harness for one question.
pub struct LmeSpecPerQuestionResult {
    pub question_id: String,
    pub base_question_type: String,
    pub is_abstention: bool,
    pub hypothesis: Option<String>,
    pub verdict_record: Option<LmeSpecVerdictRecord>,
    pub guard_healthy: bool,
    pub guard_diagnostic: Option<String>,
    pub cache_hit: Option<bool>,
    pub turns_ingested: usize,
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-question report row (serializable)
//
// Mirrors LMESpecReportPerQuestionRow in LMESpecRunner.swift.
// Wire key order follows declaration order under serde's default snake_case.
// ─────────────────────────────────────────────────────────────────────────────

/// Serializable verdict nested inside a per-question report row.
///
/// Wire keys: judge_model, label (serde default snake_case).
/// Matches LMESpecReportVerdict from LMESpecRunner.swift for JSON round-trip.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LmeSpecReportVerdict {
    pub judge_model: String,
    pub label: bool,
}

/// Serializable verdict record nested inside a per-question report row.
///
/// Wire keys: question_id, base_question_type, verdict (serde default snake_case).
/// Matches LMESpecReportVerdictRecord from LMESpecRunner.swift for JSON round-trip.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LmeSpecReportVerdictRecord {
    pub question_id: String,
    pub base_question_type: String,
    pub verdict: LmeSpecReportVerdict,
}

/// Per-question result row for the lme-spec run report.
///
/// Carries the raw per-question signal (guard health, hypothesis, verdict) that
/// the main loop accumulates. Wire keys follow declaration order under serde's
/// default snake_case. Matches LMESpecReportPerQuestionRow from LMESpecRunner.swift
/// for JSON round-trip.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LmeSpecReportPerQuestionRow {
    pub question_id: String,
    pub base_question_type: String,
    pub is_abstention: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hypothesis: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub verdict_record: Option<LmeSpecReportVerdictRecord>,
    pub guard_healthy: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub guard_diagnostic: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_hit: Option<bool>,
    pub turns_ingested: usize,
}

// ─────────────────────────────────────────────────────────────────────────────
// Report structs (serializable)
// ─────────────────────────────────────────────────────────────────────────────

/// Per-type accuracy entry for the §4 aggregation (always six entries in fixed order).
///
/// Matches `LMESpecReportPerType` from LMESpecRunner.swift for JSON round-trip.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LmeSpecReportPerType {
    #[serde(rename = "question_type")]
    pub question_type: String,
    /// Mean label over instances of this type, rounded 4dp. 0.0 when count is 0.
    pub accuracy: f64,
    pub count: usize,
}

/// Run parameters sidecar for lme-spec records.
///
/// The judge command itself (which may carry API keys) is never recorded —
/// only boolean presence (`judge_cmd_set`) is stored per the secrecy law that
/// applies to all judge/rerank commands in this codebase.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LmeSpecReportParams {
    pub variant: String,
    pub seed: u64,
    pub limit: Option<usize>,
    pub offset: usize,
    #[serde(rename = "judge_model")]
    pub judge_model: String,
    /// True when a judge command was configured. Command itself is never recorded.
    #[serde(rename = "judge_cmd_set")]
    pub judge_cmd_set: bool,
    /// True when a dump file path was configured for offline judging.
    #[serde(rename = "dump_judge_inputs_set")]
    pub dump_judge_inputs_set: bool,
    /// Artifact target scale ("unit" | "bench-aggregate").
    pub target_scale: String,
    /// Internal only — never emitted: a run is a run; width is not a
    /// property of accuracy figures.
    #[serde(skip_serializing)]
    #[serde(default)]
    pub parallel_units: usize,
}

/// The lme-spec run report.
///
/// `task_averaged_accuracy`, `overall_accuracy`, `abstention_accuracy` are
/// present only when `judged_count > 0`. When no judge is attached the run
/// records `judged_count: 0` and these fields are omitted from the JSON report.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LmeSpecReport {
    // ── Protocol conformance (§4) ─────────────────────────────────────────────
    /// Per-type accuracy in the fixed §4 order. Always six entries.
    #[serde(rename = "per_type")]
    pub per_type: Vec<LmeSpecReportPerType>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "task_averaged_accuracy")]
    pub task_averaged_accuracy: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "overall_accuracy")]
    pub overall_accuracy: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "abstention_accuracy")]
    pub abstention_accuracy: Option<f64>,
    #[serde(rename = "abstention_count")]
    pub abstention_count: usize,
    #[serde(rename = "judge_models")]
    pub judge_models: Vec<String>,
    #[serde(rename = "judged_count")]
    pub judged_count: usize,

    // ── Run identity ─────────────────────────────────────────────────────────
    #[serde(rename = "run_id")]
    pub run_id: String,
    #[serde(rename = "run_label")]
    pub run_label: String,
    pub variant: String,
    #[serde(rename = "generated_at")]
    pub generated_at: String,
    pub port: String,

    // ── Run metadata ─────────────────────────────────────────────────────────
    pub seed: u64,
    #[serde(rename = "estate_mode")]
    pub estate_mode: String,
    /// Artifact target scale ("artifact-unit" | "artifact-aggregate").
    pub target_scale: String,
    #[serde(rename = "total_questions")]
    pub total_questions: usize,
    /// Internal only — never emitted: a run is a run; width is not a
    /// property of accuracy figures.
    #[serde(skip_serializing)]
    #[serde(default)]
    pub parallel_units: usize,
    /// Binary and protocol identity (2026-08-18 doctrine: accuracy lane emits only
    /// the three identity fields; full machine profile is the timing lane's concern).
    /// Collected at the CLI layer; None for library/test callers. Twin of Swift.
    #[serde(rename = "run_environment", skip_serializing_if = "Option::is_none")]
    #[serde(default)]
    pub run_environment: Option<crate::run_environment::IdentityEnvironment>,

    // ── Dream drain status (item 8) ───────────────────────────────────────────
    /// `dreaming` lane pending count captured once at run start.
    /// 0 when the lane is absent or idle.
    #[serde(rename = "dream_pending")]
    #[serde(default)]
    pub dream_pending: u64,
    /// 1 when the `dreaming` lane was actively draining at run start; 0 otherwise.
    #[serde(rename = "dream_draining")]
    #[serde(default)]
    pub dream_draining: u64,

    // ── Per-question results ──────────────────────────────────────────────────
    /// Per-question result rows carrying the guard health, hypothesis, and verdict
    /// for each evaluated question. Always present; populated from the main loop.
    /// Positioned last in the key order per the wire-contract for this field.
    #[serde(rename = "per_question_results")]
    #[serde(default)]
    pub per_question_results: Vec<LmeSpecReportPerQuestionRow>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Offline judge-batch (consume path)
// ─────────────────────────────────────────────────────────────────────────────

/// Reads a lme-spec judge-input dump file, runs the judge for each question,
/// applies the §3 verdict rule, and returns the §4 aggregate result.
///
/// Dump file format (written by `run_lme_spec` when `dump_judge_inputs_path` is set):
///   - Line 0: header `{"type":"header","benchmark":"lme-spec",…}`
///   - Line 1…N: one per question, `{"type":"question","question_id":…,…}`
///
/// Returns `Err(String)` when the dump file is unreadable or has no valid header.
pub fn lme_spec_run_judge_batch(
    dump_path: &Path,
    judge_cmd: &str,
    judge_model: &str,
    out_dir: &Path,
) -> Result<crate::lme_spec_grader::LmeSpecAggregateResult, String> {
    let content = std::fs::read_to_string(dump_path).map_err(|e| {
        format!(
            "lme-spec judge-batch: cannot read dump file '{}': {e}",
            dump_path.display()
        )
    })?;

    let lines: Vec<&str> = content.lines().filter(|l| !l.is_empty()).collect();
    if lines.is_empty() {
        return Err(format!(
            "lme-spec judge-batch: dump file is empty: '{}'",
            dump_path.display()
        ));
    }

    // Validate header (first line).
    let header: serde_json::Value = serde_json::from_str(lines[0]).map_err(|e| {
        format!(
            "lme-spec judge-batch: first line is not valid JSON in '{}': {e}",
            dump_path.display()
        )
    })?;
    if header.get("type").and_then(|v| v.as_str()) != Some("header") {
        return Err(format!(
            "lme-spec judge-batch: first line is not a valid header object in '{}'",
            dump_path.display()
        ));
    }
    let run_label = header
        .get("run_label")
        .and_then(|v| v.as_str())
        .unwrap_or("unknown");

    let mut verdict_records: Vec<LmeSpecVerdictRecord> = Vec::new();
    let mut verdict_jsonl_lines: Vec<String> = Vec::new();

    for line in lines.iter().skip(1) {
        let obj: serde_json::Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let line_type = obj.get("type").and_then(|v| v.as_str());
        let question_id = obj.get("question_id").and_then(|v| v.as_str());
        let base_type = obj.get("base_question_type").and_then(|v| v.as_str());
        let prompt = obj.get("anscheck_prompt").and_then(|v| v.as_str());
        match (line_type, question_id, base_type, prompt) {
            (Some("question"), Some(qid), Some(bt), Some(p)) => {
                let response = match lme_run_judge(judge_cmd, p) {
                    Ok(r) => r,
                    Err(e) => {
                        eprintln!("[lme-spec judge-batch] judge failed for {qid}: {e}");
                        continue;
                    }
                };
                // §3: `label = 'yes' in eval_response.lower()` after strip.
                let verdict = lme_spec_verdict(&response, judge_model);
                verdict_records.push(LmeSpecVerdictRecord {
                    question_id: qid.to_owned(),
                    base_question_type: bt.to_owned(),
                    verdict: verdict.clone(),
                });
                use serde_json::Value as Jv;
                let mut v_obj: BTreeMap<&str, Jv> = BTreeMap::new();
                v_obj.insert("base_question_type", Jv::String(bt.to_owned()));
                v_obj.insert("judge_model", Jv::String(judge_model.to_owned()));
                v_obj.insert("label", Jv::Bool(verdict.label));
                v_obj.insert("question_id", Jv::String(qid.to_owned()));
                v_obj.insert("response", Jv::String(response));
                if let Ok(vline) = serde_json::to_string(&v_obj) {
                    verdict_jsonl_lines.push(vline);
                }
            }
            _ => continue,
        }
    }

    // Write verdict file.
    let verdict_filename = format!(
        "lme-spec-judge-verdicts-{}-{}.jsonl",
        run_label.replace('/', "_"),
        now_iso8601_compact()
    );
    let verdict_path = out_dir.join(&verdict_filename);
    let verdict_content = {
        let mut s = verdict_jsonl_lines.join("\n");
        if !verdict_jsonl_lines.is_empty() {
            s.push('\n');
        }
        s
    };
    write_owner_only_file(&verdict_path, verdict_content.as_bytes());

    Ok(lme_spec_aggregate(&verdict_records))
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Returns current UTC time as a compact ISO8601 string: "YYYYMMDDTHHMMSSz".
fn now_iso8601_compact() -> String {
    use std::time::SystemTime;
    let secs = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    gregorian_from_unix(secs, true)
}

/// Returns current UTC time as a full ISO8601 string: "YYYY-MM-DDTHH:MM:SSZ".
fn now_iso8601_full() -> String {
    use std::time::SystemTime;
    let secs = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    gregorian_from_unix(secs, false)
}

/// Converts Unix epoch seconds to a Gregorian date+time string.
/// `compact=true` → "YYYYMMDDTHHMMSSz"; `compact=false` → "YYYY-MM-DDTHH:MM:SSZ".
/// Valid for dates 1970–2100 (the range used in benchmarks).
fn gregorian_from_unix(secs: u64, compact: bool) -> String {
    let days = secs / 86400;
    let time_s = secs % 86400;
    let z = days + 719468;
    let era = z / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y_adj = if m <= 2 { y + 1 } else { y };
    let hh = time_s / 3600;
    let mm = (time_s % 3600) / 60;
    let ss = time_s % 60;
    if compact {
        format!("{y_adj:04}{m:02}{d:02}T{hh:02}{mm:02}{ss:02}z")
    } else {
        format!("{y_adj:04}-{m:02}-{d:02}T{hh:02}:{mm:02}:{ss:02}Z")
    }
}

/// Produces a pseudo-random run ID based on the current time and a stack address.
fn new_run_id() -> String {
    use std::time::SystemTime;
    let t = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let addr = &t as *const _ as u64;
    format!("{:016x}-{:016x}", t as u64, addr ^ 0xDEAD_BEEF_CAFE_0001)
}

/// Builds one answer-input JSONL line for the offline reader-model flow.
///
/// Keys are alphabetically sorted (BTreeMap) to match the Swift twin's
/// `.sortedKeys` output. Schema:
///   base_question_type, benchmark ("lme-spec"), correct_answer, hypothesis_digest,
///   is_abstention, memory_texts, question, question_date, question_id,
///   question_type, retrieved_drawer_ids, type ("answer_input").
///
/// hypothesis_digest is the moot_synthesize output for reference only; the
/// reader model reads memory_texts instead. Twin of Swift `lmeSpecAnswerInputLine`.
#[allow(clippy::too_many_arguments)]
pub(crate) fn lme_spec_answer_input_line(
    question_id: &str,
    question_type: &str,
    base_question_type: &str,
    is_abstention: bool,
    question: &str,
    question_date: &str,
    correct_answer: &str,
    memory_texts: &[String],
    retrieved_drawer_ids: &[String],
    hypothesis_digest: Option<&str>,
    answer_hydration_depth: usize,
) -> Option<String> {
    use serde_json::Value;
    let mut obj: BTreeMap<&str, Value> = BTreeMap::new();
    obj.insert("answer_hydration_depth",
        Value::Number(serde_json::Number::from(answer_hydration_depth as u64)));
    obj.insert("base_question_type", Value::String(base_question_type.to_owned()));
    obj.insert("benchmark", Value::String("lme-spec".to_owned()));
    obj.insert("correct_answer", Value::String(correct_answer.to_owned()));
    obj.insert(
        "hypothesis_digest",
        match hypothesis_digest {
            Some(s) => Value::String(s.to_owned()),
            None => Value::Null,
        },
    );
    obj.insert("is_abstention", Value::Bool(is_abstention));
    obj.insert(
        "memory_texts",
        Value::Array(memory_texts.iter().map(|t| Value::String(t.clone())).collect()),
    );
    obj.insert("question", Value::String(question.to_owned()));
    obj.insert("question_date", Value::String(question_date.to_owned()));
    obj.insert("question_id", Value::String(question_id.to_owned()));
    obj.insert("question_type", Value::String(question_type.to_owned()));
    obj.insert(
        "retrieved_drawer_ids",
        Value::Array(retrieved_drawer_ids.iter().map(|id| Value::String(id.clone())).collect()),
    );
    obj.insert("type", Value::String("answer_input".to_owned()));
    match serde_json::to_string(&obj) {
        Ok(s) => Some(s + "\n"),
        Err(_) => None,
    }
}

/// Writes bytes to a file with owner-only (0o600) permissions. Best-effort.
/// pub(crate) so lme_spec_answer_batch can share the same seam.
pub(crate) fn write_owner_only_file(path: &Path, data: &[u8]) {
    use std::fs::OpenOptions;
    use std::os::unix::fs::OpenOptionsExt;
    // O_CREAT|O_EXCL: exclusive create — fails if the path already exists or
    // if it is a symlink, preventing truncation of an existing file or
    // symlink-following attacks. Mode 0o600 restricts access to the owner.
    match OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
    {
        Ok(mut f) => {
            let _ = f.write_all(data);
        }
        Err(e) => {
            eprintln!(
                "[lme-spec] warning: could not write file '{}': {e}",
                path.display()
            );
        }
    }
}

/// Appends a string to a file that already exists. Best-effort.
fn append_to_file(path: &Path, data: &str) {
    use std::fs::OpenOptions;
    match OpenOptions::new().write(true).append(true).open(path) {
        Ok(mut f) => {
            let _ = f.write_all(data.as_bytes());
        }
        Err(e) => {
            eprintln!(
                "[lme-spec] warning: could not append to '{}': {e}",
                path.display()
            );
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-question MCP work (helper — takes &mut MCPClient)
// ─────────────────────────────────────────────────────────────────────────────
//
// Factored out so that both the fresh-per-question path (which owns the client
// locally) and the shared-estate path (which borrows a long-lived client) can
// call the same logic without aliasing lifetime issues.

/// Arguments passed to `run_question_on_client` to avoid a long parameter list.
struct QuestionWorkCtx<'a> {
    question: &'a LmeSpecQuestion,
    question_id: &'a str,
    base_question_type: &'a str,
    is_abstention: bool,
    cache_hit: Option<bool>,
    /// Non-zero only when estate was restored from cache (turns already imported).
    turns_ingested_from_cache: usize,
    guard_sampler: &'a Mutex<LegGuardSampler>,
    hypothesis_path: &'a Path,
    dump_judge_inputs_path: Option<&'a str>,
    /// SECURITY: may carry API keys; only boolean presence is recorded in reports.
    judge_cmd: Option<&'a str>,
    judge_model: &'a str,
    /// Path for the offline reader-model answer-input dump. When set, the runner
    /// calls moot_memory_search + moot_memory_get per question and writes one
    /// answer_input JSONL line. None = skip the reader-model dump path.
    dump_answer_inputs_path: Option<&'a str>,
    /// Maximum drawer texts to hydrate per question via moot_memory_get.
    answer_hydration_depth: usize,
    /// Depth tier for moot_memory_get during answer-input hydration.
    answer_hydration_tier: crate::journey_driver::HydrationDepth,
}

/// Runs `moot_synthesize`, hypothesis emission, dump line emission, and optional
/// inline judging for one question against a pre-built artifact estate.
///
/// The estate is already settled (pre-built artifacts); there is no ingest step.
///
/// Returns `(LmeSpecPerQuestionResult, optional_verdict)`. Never returns an
/// error: failures become stub records with `guard_healthy: false`.
/// Returns `(result, verdict_opt, synthesis_was_refusal)`.
/// `synthesis_was_refusal` is true when moot_synthesize returned an empty
/// response rather than raising an error — the distinction matters for counting.
fn run_question_on_client(
    client: &mut MCPClient,
    ctx: &QuestionWorkCtx<'_>,
) -> (LmeSpecPerQuestionResult, Option<LmeSpecVerdictRecord>, bool) {
    let verb_map = lme_verb_map();

    // Pre-built artifact estate: turn count comes from the id-map loaded
    // by the caller (stored in ctx.turns_ingested_from_cache).
    let turns_ingested: usize = ctx.turns_ingested_from_cache;
    let guard_healthy: bool;
    let guard_diagnostic: Option<String>;

    // No ingest: pre-built artifact estate is already settled.

    // ── Guard probe ───────────────────────────────────────────────────────────
    {
        let (gh, gd, _probed) = {
            let mut s = ctx
                .guard_sampler
                .lock()
                .expect("guard sampler mutex poisoned");
            s.probe(|| probe_mcp_client(client, &verb_map))
        };
        guard_healthy = gh;
        guard_diagnostic = gd;
    }

    // ── Hypothesis production via moot_synthesize ─────────────────────────────
    // §6 row 4: the hypothesis is the system's answer text from the estate.
    //
    // MOOT FUNCTION NEEDED: moot_synthesize — generate a direct answer to
    // a question using the estate's indexed content.
    // Suggested design:
    //   inputs:  query (String) — the question text
    //   outputs: text_blocks (joined) — the synthesized answer prose
    //   behavior: searches the estate and generates a coherent answer;
    //             must not require the gold answer or question type as context.
    // This tool is already present in production mootx01; the placeholder is
    // here to document the seam in case the tool is unavailable in a test env.
    // Drawer UUIDs from moot_synthesize — captured for artifact-recall scoring.
    let mut synth_ordered_ids: Vec<String> = Vec::new();
    let mut synthesis_was_refusal = false;
    let hypothesis: Option<String> = {
        let mut synth_args: BTreeMap<String, JsonValue> = BTreeMap::new();
        synth_args.insert(
            verb_map.query_arg.clone(),
            JsonValue::String(ctx.question.question.clone()),
        );
        match client.call_tool(crate::aria_v2_surface::SYNTHESIZE, synth_args, &verb_map.result_format) {
            Ok(result) => {
                synth_ordered_ids = result.ordered_ids.clone();
                let text = result.text_blocks.join("\n");
                if text.is_empty() {
                    // moot_synthesize returned an empty string — server refused or
                    // produced no text. Log and signal to the caller for counting.
                    eprintln!(
                        "[lme-spec] moot_synthesize empty response (refusal) for {}: \
                         text_blocks={} all empty",
                        ctx.question_id,
                        result.text_blocks.len()
                    );
                    synthesis_was_refusal = true;
                    None
                } else {
                    Some(text)
                }
            }
            Err(e) => {
                eprintln!(
                    "[lme-spec] moot_synthesize error for {}: {}",
                    ctx.question_id, e.description
                );
                None
            }
        }
    };

    // ── Write official hypothesis JSONL record (§1) ───────────────────────────
    // Every question gets a record even when hypothesis is None (written as "").
    if let Some(line) = lme_spec_hypothesis_line(ctx.question_id, hypothesis.as_deref()) {
        append_to_file(ctx.hypothesis_path, &line);
    }

    // ── Build anscheck prompt (§2) + judge + dump ─────────────────────────────
    let mut verdict_record: Option<LmeSpecVerdictRecord> = None;

    if let Some(ref hyp) = hypothesis {
        let prompt_result = anscheck_prompt(
            &ctx.question.question_type,
            ctx.question_id,
            &ctx.question.question,
            &ctx.question.answer,
            hyp,
        );

        match prompt_result {
            Ok(prompt) => {
                // Dump line for offline judging.
                if let Some(dump_path_str) = ctx.dump_judge_inputs_path {
                    if let Some(dump_line) = lme_spec_judge_input_line(
                        ctx.question_id,
                        ctx.base_question_type,
                        ctx.is_abstention,
                        hyp,
                        &prompt,
                        ctx.judge_model,
                        &synth_ordered_ids,
                    ) {
                        append_to_file(Path::new(dump_path_str), &dump_line);
                    }
                }

                // ── Answer-input dump (reader-model flow) ────────────────────
                // When --dump-answer-inputs is set: call moot_memory_search to
                // get ranked drawer IDs, hydrate the top-K texts via
                // moot_memory_get, then write one answer_input JSONL line.
                // The hypothesis_digest is included for reference only; the
                // reader model reads memory_texts to form its own answer.
                if let Some(dump_path) = ctx.dump_answer_inputs_path {
                    let mut search_args: BTreeMap<String, JsonValue> = BTreeMap::new();
                    search_args.insert(
                        verb_map.query_arg.clone(),
                        JsonValue::String(ctx.question.question.clone()),
                    );
                    let ordered_ids: Vec<String> = match client.call_tool(
                        crate::aria_v2_surface::MEMORY_SEARCH,
                        search_args,
                        &verb_map.result_format,
                    ) {
                        Ok(result) => result.ordered_ids,
                        Err(e) => {
                            eprintln!(
                                "[lme-spec] moot_memory_search error for {}: {}",
                                ctx.question_id, e.description
                            );
                            vec![]
                        }
                    };

                    let mut memory_texts: Vec<String> = Vec::new();
                    let mut hydrated_ids: Vec<String> = Vec::new();
                    for drawer_id in ordered_ids.iter().take(ctx.answer_hydration_depth) {
                        let mut get_args: BTreeMap<String, JsonValue> = BTreeMap::new();
                        get_args.insert(
                            "drawer_id".to_string(),
                            JsonValue::String(drawer_id.clone()),
                        );
                        get_args.insert(
                            "depth".to_string(),
                            JsonValue::String(ctx.answer_hydration_tier.as_wire_str().to_owned()),
                        );
                        match client.call_tool(crate::aria_v2_surface::MEMORY_GET, get_args, &verb_map.result_format) {
                            Ok(result) => {
                                if let Some(content) = crate::seed_export::memory_get_content(&result.text_blocks) {
                                    if !content.is_empty() {
                                        memory_texts.push(content);
                                        hydrated_ids.push(drawer_id.clone());
                                    }
                                }
                            }
                            Err(e) => {
                                eprintln!(
                                    "[lme-spec] moot_memory_get error for drawer {}: {}",
                                    drawer_id, e.description
                                );
                            }
                        }
                    }

                    if let Some(line) = lme_spec_answer_input_line(
                        ctx.question_id,
                        &ctx.question.question_type,
                        ctx.base_question_type,
                        ctx.is_abstention,
                        &ctx.question.question,
                        &ctx.question.question_date,
                        &ctx.question.answer,
                        &memory_texts,
                        &hydrated_ids,
                        Some(hyp),
                        ctx.answer_hydration_depth,
                    ) {
                        append_to_file(Path::new(dump_path), &line);
                    }
                }

                // Inline judging. §3 call: prompt on stdin; response on stdout.
                if let Some(cmd) = ctx.judge_cmd {
                    match lme_run_judge(cmd, &prompt) {
                        Ok(response) => {
                            // §3: `label = 'yes' in eval_response.lower()` after strip.
                            let verdict = lme_spec_verdict(&response, ctx.judge_model);
                            verdict_record = Some(LmeSpecVerdictRecord {
                                question_id: ctx.question_id.to_owned(),
                                base_question_type: ctx.base_question_type.to_owned(),
                                verdict,
                            });
                        }
                        Err(e) => {
                            eprintln!(
                                "[lme-spec] judge error for {}: {e}",
                                ctx.question_id
                            );
                        }
                    }
                }
            }
            Err(e) => {
                // anscheck_prompt returned unknownQuestionType — log and continue.
                eprintln!(
                    "[lme-spec] unknown question type '{}' for {}: {e}",
                    ctx.question.question_type, ctx.question_id
                );
            }
        }
    }

    let result = LmeSpecPerQuestionResult {
        question_id: ctx.question_id.to_owned(),
        base_question_type: ctx.base_question_type.to_owned(),
        is_abstention: ctx.is_abstention,
        hypothesis,
        verdict_record: verdict_record.clone(),
        guard_healthy,
        guard_diagnostic,
        cache_hit: ctx.cache_hit,
        turns_ingested,
    };
    (result, verdict_record, synthesis_was_refusal)
}

// ─────────────────────────────────────────────────────────────────────────────
// Main run function
// ─────────────────────────────────────────────────────────────────────────────

/// Runs the lme-spec harness against a loaded question list. Returns the run report.
///
/// For each question:
///   1. Provisions a fresh (or shared) scratch estate.
///   2. Imports haystack sessions via `moot_json_import` (batch seed path).
///   3. Runs `moot_dream` + `moot_reindex` + encode drain (estate settling).
///   4. Calls `moot_synthesize` to produce the hypothesis.
///   5. Writes official `{"question_id":…,"hypothesis":…}` JSONL line.
///   6. Builds the §2 anscheck prompt via `anscheck_prompt`.
///   7. If `dump_judge_inputs_path` is set: appends judge-input dump line.
///   8. If `judge_cmd` is set: calls `lme_run_judge`, parses §3 verdict.
///   9. Tears down the estate (fresh mode only).
///
/// After all questions: calls `lme_spec_aggregate` on collected verdicts, writes
/// report + params sidecar via `record_filename` / `write_record_never_overwrite`.
pub fn run_lme_spec(
    questions: &[LmeSpecQuestion],
    config: &LmeSpecRunConfig,
    hypothesis_output_path: Option<&Path>,
) -> Result<LmeSpecReport, String> {
    // ── Question selection (seeded shuffle → offset → limit) ──────────────────
    // SplitMix64 Fisher-Yates — identical PRNG to the existing LME lane so
    // equivalent seed+limit values produce the same question ordering.
    let mut indices: Vec<usize> = (0..questions.len()).collect();
    let mut rng = SplitMix64::new(config.seed);
    rng.shuffle(&mut indices);
    if config.offset > 0 {
        indices = indices.into_iter().skip(config.offset).collect();
    }
    if let Some(limit) = config.limit {
        indices.truncate(limit);
    }
    let sliced: Vec<&LmeSpecQuestion> = indices.iter().map(|&i| &questions[i]).collect();

    // ── Output directory ──────────────────────────────────────────────────────
    let out_dir: PathBuf = config
        .out_dir
        .clone()
        .unwrap_or_else(|| PathBuf::from("."));

    // ── Hypothesis output file (owner-only; created empty upfront) ────────────
    let hypothesis_path: PathBuf = hypothesis_output_path
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| {
            out_dir.join(record_filename(
                "lme-spec",
                &format!("hypotheses-{}", config.variant),
                &config.run_serial,
                "",
                "jsonl",
            ))
        });
    write_owner_only_file(&hypothesis_path, b"");

    // ── Judge-input dump header (written before the question loop) ────────────
    if let Some(ref dump_path) = config.dump_judge_inputs_path {
        let mut header_obj: BTreeMap<&str, serde_json::Value> = BTreeMap::new();
        header_obj.insert(
            "benchmark",
            serde_json::Value::String("lme-spec".to_owned()),
        );
        header_obj.insert(
            "judge_model",
            serde_json::Value::String(config.judge_model.clone()),
        );
        header_obj.insert(
            "run_label",
            serde_json::Value::String(config.run_label.clone()),
        );
        header_obj.insert(
            "seed",
            serde_json::Value::Number(serde_json::Number::from(config.seed)),
        );
        header_obj.insert("type", serde_json::Value::String("header".to_owned()));
        header_obj.insert(
            "variant",
            serde_json::Value::String(config.variant.clone()),
        );
        if let Ok(s) = serde_json::to_string(&header_obj) {
            write_owner_only_file(Path::new(dump_path.as_str()), (s + "\n").as_bytes());
        }
    }

    // ── Answer-input dump header (reader-model flow) ──────────────────────────
    if let Some(ref ai_dump_path) = config.dump_answer_inputs_path {
        let mut hdr: BTreeMap<&str, serde_json::Value> = BTreeMap::new();
        hdr.insert(
            "answer_hydration_depth",
            serde_json::Value::Number(serde_json::Number::from(config.answer_hydration_depth as u64)),
        );
        hdr.insert("benchmark", serde_json::Value::String("lme-spec".to_owned()));
        hdr.insert("run_label", serde_json::Value::String(config.run_label.clone()));
        hdr.insert(
            "seed",
            serde_json::Value::Number(serde_json::Number::from(config.seed)),
        );
        hdr.insert("type", serde_json::Value::String("header".to_owned()));
        hdr.insert("variant", serde_json::Value::String(config.variant.clone()));
        hdr.insert(
            "hydration_tier",
            serde_json::Value::String(config.answer_hydration_tier.as_wire_str().to_owned()),
        );
        if let Ok(s) = serde_json::to_string(&hdr) {
            write_owner_only_file(Path::new(ai_dump_path.as_str()), (s + "\n").as_bytes());
        }
    }

    // ── Guard sampler ─────────────────────────────────────────────────────────
    let guard_sampler = Mutex::new(LegGuardSampler::new(config.guard_sampling_policy));

    // ── Per-question results ──────────────────────────────────────────────────
    let mut per_question_results: Vec<LmeSpecPerQuestionResult> =
        Vec::with_capacity(sliced.len());
    let mut verdict_records: Vec<LmeSpecVerdictRecord> = Vec::new();
    // Counts moot_synthesize calls that returned an empty response.
    let mut synthesize_refusal_count: usize = 0;

    // ── Bench-aggregate: open ONE estate for all questions (serial) ───────────
    // Unit: open one fleet estate per question (no sharing).
    // At bench-aggregate scale parallelism is forced to 1 (caller enforces this
    // via config.parallel_units = 1; the loop is always serial).
    let mut shared_client: Option<MCPClient> = if config.target_scale == ArtifactTargetScale::BenchAggregate {
        let estate = config.estate_dir.as_ref()
            .ok_or("lme-spec: bench-aggregate requires estate_dir")?;
        let mut client = MCPClient::new(lme_spec_artifact_endpoint(estate, &config.moot_binary)
            .map_err(|e| e.description().to_string())?);
        // ^^ LaneError::Config propagates as String to run_lme_spec's Result<_, String>
        client.connect().map_err(|e| format!("lme-spec: bench-aggregate connect: {}", e.description))?;
        Some(client)
    } else {
        None
    };

    // ── Dream drain status probe (item 8) ─────────────────────────────────────
    // Captured once at run start using the shared client when available.
    // Non-failing: any error yields the default (pending=0, draining=false).
    let dream_status = if let Some(ref mut c) = shared_client {
        crate::encode_barrier::read_drain_status_once(c)
    } else {
        crate::encode_barrier::DreamStatus::default()
    };

    // ── Per-question serial loop ──────────────────────────────────────────────
    // TODO(parallel): unit scale supports parallel_units > 1 via thread::scope
    // following the locomo_spec_runner.rs pattern when needed. The Rust port
    // is serial for now; parallel_units is recorded in the report but not
    // enforced here.
    for (question_index, question) in sliced.iter().enumerate() {
        let question_id = &question.question_id;
        let base_question_type = question.base_question_type().to_owned();
        let is_abstention = question.is_abstention();

        eprintln!(
            "[lme-spec] q={} ({}/{}{})",
            question_id,
            question_index + 1,
            sliced.len(),
            if is_abstention { ", abs" } else { "" }
        );

        // ── Resolve artifact estate path ───────────────────────────────────────
        // Unit: one catalog-resolved estate per question (question_id is the unit id).
        // Bench-aggregate: the single shared estate opened above.
        let estate_path: PathBuf = match config.target_scale {
            ArtifactTargetScale::Unit => {
                match &config.catalog_path {
                    Some(cat) => {
                        match crate::artifact_recall::resolve_unit_from_catalog(cat, question_id) {
                            Ok(p) => p,
                            Err(e) => {
                                per_question_results.push(LmeSpecPerQuestionResult {
                                    question_id: question_id.clone(),
                                    base_question_type,
                                    is_abstention,
                                    hypothesis: None,
                                    verdict_record: None,
                                    guard_healthy: false,
                                    guard_diagnostic: Some(e.description),
                                    cache_hit: None,
                                    turns_ingested: 0,
                                });
                                continue;
                            }
                        }
                    }
                    None => {
                        per_question_results.push(LmeSpecPerQuestionResult {
                            question_id: question_id.clone(),
                            base_question_type,
                            is_abstention,
                            hypothesis: None,
                            verdict_record: None,
                            guard_healthy: false,
                            guard_diagnostic: Some("lme-spec: unit scale requires --catalog".to_string()),
                            cache_hit: None,
                            turns_ingested: 0,
                        });
                        continue;
                    }
                }
            }
            ArtifactTargetScale::BenchAggregate | ArtifactTargetScale::CompleteAggregate => {
                config.estate_dir.as_ref()
                    .cloned()
                    .unwrap_or_else(|| PathBuf::from("."))
            }
        };

        // ── Guard: estate dir must exist before launching serve ────────────────
        // Fail fast here instead of first running an empty estate that will
        // immediately error on id-map.json — the error message is clearer and
        // avoids a wasted serve subprocess launch.
        if config.target_scale == ArtifactTargetScale::Unit && !estate_path.is_dir() {
            per_question_results.push(LmeSpecPerQuestionResult {
                question_id: question_id.clone(),
                base_question_type,
                is_abstention,
                hypothesis: None,
                verdict_record: None,
                guard_healthy: false,
                guard_diagnostic: Some(format!(
                    "estate for unit {} missing at {}",
                    question_id,
                    estate_path.display()
                )),
                cache_hit: None,
                turns_ingested: 0,
            });
            continue;
        }

        // ── Load id-map to get session count ───────────────────────────────────
        // id-map.json maps seed record ids (raw session ids) to drawer UUIDs.
        let turns_ingested = match load_artifact_id_map(&estate_path) {
            Ok(m) => m.len(),
            Err(e) => {
                eprintln!("[lme-spec] id-map load error for {question_id}: {}", e.description);
                0 // continue with 0; guard will catch degenerate estate
            }
        };

        if config.target_scale == ArtifactTargetScale::Unit {
            // ── Unit path: fresh client per question ───────────────────────────
            // A LaneError::Config from lme_spec_artifact_endpoint (e.g. whitespace in the
            // binary or estate path) is a run-level refusal: propagate to run_lme_spec's
            // Result<_, String> so main() prints it on stderr and exits 1. Absorbing it
            // into a guard-excluded stub would let the run exit 0 despite a config fault.
            let endpoint = lme_spec_artifact_endpoint(&estate_path, &config.moot_binary)
                .map_err(|e| e.description().to_string())?;
            let mut client = MCPClient::new(endpoint);
            if let Err(e) = client.connect() {
                per_question_results.push(LmeSpecPerQuestionResult {
                    question_id: question_id.clone(),
                    base_question_type,
                    is_abstention,
                    hypothesis: None,
                    verdict_record: None,
                    guard_healthy: false,
                    guard_diagnostic: Some(e.description),
                    cache_hit: None,
                    turns_ingested: 0,
                });
                continue;
            }
            let ctx = QuestionWorkCtx {
                question,
                question_id,
                base_question_type: &base_question_type,
                is_abstention,
                cache_hit: None,
                turns_ingested_from_cache: turns_ingested,
                guard_sampler: &guard_sampler,
                hypothesis_path: &hypothesis_path,
                dump_judge_inputs_path: config.dump_judge_inputs_path.as_deref(),
                judge_cmd: config.judge_cmd.as_deref(),
                judge_model: &config.judge_model,
                dump_answer_inputs_path: config.dump_answer_inputs_path.as_deref(),
                answer_hydration_depth: config.answer_hydration_depth,
                answer_hydration_tier: config.answer_hydration_tier,
            };
            let (result, verdict_opt, was_refusal) = run_question_on_client(&mut client, &ctx);
            if was_refusal { synthesize_refusal_count += 1; }
            // Drop client (terminates subprocess). No estate teardown — pre-built.
            drop(client);
            if let Some(v) = verdict_opt { verdict_records.push(v); }
            per_question_results.push(result);
        } else {
            // ── Bench-aggregate path: borrow shared client ─────────────────────
            let client = shared_client.as_mut().expect(
                "lme-spec: shared_client must be Some at bench-aggregate scale",
            );
            let ctx = QuestionWorkCtx {
                question,
                question_id,
                base_question_type: &base_question_type,
                is_abstention,
                cache_hit: None,
                turns_ingested_from_cache: turns_ingested,
                guard_sampler: &guard_sampler,
                hypothesis_path: &hypothesis_path,
                dump_judge_inputs_path: config.dump_judge_inputs_path.as_deref(),
                judge_cmd: config.judge_cmd.as_deref(),
                judge_model: &config.judge_model,
                dump_answer_inputs_path: config.dump_answer_inputs_path.as_deref(),
                answer_hydration_depth: config.answer_hydration_depth,
                answer_hydration_tier: config.answer_hydration_tier,
            };
            let (result, verdict_opt, was_refusal) = run_question_on_client(client, &ctx);
            if was_refusal { synthesize_refusal_count += 1; }
            if let Some(v) = verdict_opt { verdict_records.push(v); }
            per_question_results.push(result);
        }
    } // end per-question loop

    // Drop shared client (bench-aggregate only; unit estates are already dropped).
    drop(shared_client);

    // Log synthesis refusal summary so the operator sees it before the report.
    if synthesize_refusal_count > 0 {
        eprintln!(
            "[lme-spec] WARNING: {} of {} questions received an empty hypothesis from \
             moot_synthesize (refusals)",
            synthesize_refusal_count,
            sliced.len()
        );
    }

    // ── §4 aggregation ────────────────────────────────────────────────────────
    let aggregate = lme_spec_aggregate(&verdict_records);
    let judged_count = verdict_records.len();
    // Count abstentions from the question list (not verdicts) so the field is
    // populated even when judged_count == 0.
    let abstention_count = sliced.iter().filter(|q| q.is_abstention()).count();

    // ── Build report ──────────────────────────────────────────────────────────
    let per_type_report: Vec<LmeSpecReportPerType> = aggregate
        .per_type
        .iter()
        .map(|pt| LmeSpecReportPerType {
            question_type: pt.question_type.clone(),
            accuracy: if judged_count > 0 { pt.accuracy } else { 0.0 },
            count: pt.count,
        })
        .collect();

    let report = LmeSpecReport {
        per_type: per_type_report,
        task_averaged_accuracy: if judged_count > 0 {
            Some(aggregate.task_averaged_accuracy)
        } else {
            None
        },
        overall_accuracy: if judged_count > 0 {
            Some(aggregate.overall_accuracy)
        } else {
            None
        },
        abstention_accuracy: if judged_count > 0 {
            Some(aggregate.abstention_accuracy)
        } else {
            None
        },
        abstention_count,
        judge_models: aggregate.judge_models,
        judged_count,
        run_id: new_run_id(),
        run_label: config.run_label.clone(),
        variant: config.variant.clone(),
        generated_at: now_iso8601_full(),
        port: "rust".to_owned(),
        seed: config.seed,
        estate_mode: if config.target_scale == ArtifactTargetScale::BenchAggregate {
            "artifact-aggregate".to_owned()
        } else {
            "artifact-unit".to_owned()
        },
        target_scale: config.target_scale.as_str().to_owned(),
        total_questions: sliced.len(),
        parallel_units: config.parallel_units,
        // §6 required report fields ride in from the CLI layer (F1).
        run_environment: config.run_environment.clone(),
        dream_pending: dream_status.pending,
        dream_draining: if dream_status.draining { 1 } else { 0 },
        per_question_results: per_question_results
            .iter()
            .map(|r| LmeSpecReportPerQuestionRow {
                question_id: r.question_id.clone(),
                base_question_type: r.base_question_type.clone(),
                is_abstention: r.is_abstention,
                hypothesis: r.hypothesis.clone(),
                verdict_record: r.verdict_record.as_ref().map(|vr| LmeSpecReportVerdictRecord {
                    question_id: vr.question_id.clone(),
                    base_question_type: vr.base_question_type.clone(),
                    verdict: LmeSpecReportVerdict {
                        judge_model: vr.verdict.judge_model.clone(),
                        label: vr.verdict.label,
                    },
                }),
                guard_healthy: r.guard_healthy,
                guard_diagnostic: r.guard_diagnostic.clone(),
                cache_hit: r.cache_hit,
                turns_ingested: r.turns_ingested,
            })
            .collect(),
    };

    // ── Write report + params sidecar via RecordWriter ────────────────────────
    // Record name stem: lme-spec-<variant>-<serial> (test=lme-spec, arm=variant).
    let arm = &config.variant;
    let report_filename = record_filename("lme-spec", arm, &config.run_serial, "", "json");
    let params_filename = record_filename("lme-spec", arm, &config.run_serial, "params", "json");

    let report_path = out_dir.join(&report_filename);
    let params_path = out_dir.join(&params_filename);

    let report_json = serde_json::to_vec_pretty(&report)
        .map_err(|e| format!("lme-spec: report serialization failed: {e}"))?;
    write_record_never_overwrite(&report_json, &report_path)
        .map_err(|e| format!("lme-spec: report write failed: {e}"))?;

    let params = LmeSpecReportParams {
        variant: config.variant.clone(),
        seed: config.seed,
        limit: config.limit,
        offset: config.offset,
        judge_model: config.judge_model.clone(),
        judge_cmd_set: config.judge_cmd.is_some(),
        dump_judge_inputs_set: config.dump_judge_inputs_path.is_some(),
        target_scale: config.target_scale.as_str().to_owned(),
        parallel_units: config.parallel_units,
    };
    let params_json = serde_json::to_vec_pretty(&params)
        .map_err(|e| format!("lme-spec: params serialization failed: {e}"))?;
    write_record_never_overwrite(&params_json, &params_path)
        .map_err(|e| format!("lme-spec: params write failed: {e}"))?;

    Ok(report)
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lme_spec_grader::lme_spec_aggregate;

    #[test]
    fn hypothesis_line_contains_question_id_and_hypothesis() {
        let line = lme_spec_hypothesis_line("q1", Some("the sky is blue")).unwrap();
        assert!(line.contains("\"question_id\""), "missing question_id key");
        assert!(line.contains("\"hypothesis\""), "missing hypothesis key");
        assert!(line.contains("\"q1\""), "missing question_id value");
        assert!(
            line.contains("the sky is blue"),
            "missing hypothesis value"
        );
        assert!(line.ends_with('\n'), "line must end with newline");
    }

    #[test]
    fn hypothesis_line_none_writes_empty_string() {
        let line = lme_spec_hypothesis_line("q2", None).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(line.trim()).unwrap();
        assert_eq!(parsed["hypothesis"].as_str(), Some(""));
        assert_eq!(parsed["question_id"].as_str(), Some("q2"));
    }

    #[test]
    fn hypothesis_line_keys_sorted_alphabetically() {
        // Sorted keys: "hypothesis" < "question_id" alphabetically.
        let line = lme_spec_hypothesis_line("qid", Some("answer")).unwrap();
        let h_pos = line.find("\"hypothesis\"").unwrap();
        let q_pos = line.find("\"question_id\"").unwrap();
        assert!(
            h_pos < q_pos,
            "keys must be sorted: hypothesis before question_id"
        );
    }

    // ── Judge-input dump line ─────────────────────────────────────────────────

    #[test]
    fn judge_input_line_contains_required_fields() {
        let line = lme_spec_judge_input_line(
            "qid_001",
            "multi-session",
            false,
            "my answer",
            "filled prompt",
            "gpt-4o-2024-08-06",
            &[],
        )
        .unwrap();
        let parsed: serde_json::Value = serde_json::from_str(line.trim()).unwrap();
        assert_eq!(parsed["type"].as_str(), Some("question"));
        assert_eq!(parsed["question_id"].as_str(), Some("qid_001"));
        assert_eq!(parsed["base_question_type"].as_str(), Some("multi-session"));
        assert_eq!(parsed["is_abstention"].as_bool(), Some(false));
        assert_eq!(parsed["hypothesis"].as_str(), Some("my answer"));
        assert_eq!(parsed["anscheck_prompt"].as_str(), Some("filled prompt"));
        assert_eq!(parsed["model"].as_str(), Some("gpt-4o-2024-08-06"));
        // §3 parameters.
        assert_eq!(parsed["n"].as_u64(), Some(1));
        assert_eq!(parsed["temperature"].as_u64(), Some(0));
        assert_eq!(parsed["max_tokens"].as_u64(), Some(10));
    }

    #[test]
    fn judge_input_line_abstention_flag_true() {
        let line = lme_spec_judge_input_line(
            "qid_001_abs",
            "multi-session",
            true,
            "I don't know",
            "abs prompt",
            "m",
            &[],
        )
        .unwrap();
        let parsed: serde_json::Value = serde_json::from_str(line.trim()).unwrap();
        assert_eq!(parsed["is_abstention"].as_bool(), Some(true));
    }

    #[test]
    fn judge_input_line_ends_with_newline() {
        let line = lme_spec_judge_input_line("q", "t", false, "h", "p", "m", &[]).unwrap();
        assert!(line.ends_with('\n'));
    }

    // ── Report structs ────────────────────────────────────────────────────────

    #[test]
    fn lme_spec_report_per_type_json_round_trip() {
        let pt = LmeSpecReportPerType {
            question_type: "multi-session".to_owned(),
            accuracy: 0.7500,
            count: 4,
        };
        let json = serde_json::to_string(&pt).unwrap();
        let restored: LmeSpecReportPerType = serde_json::from_str(&json).unwrap();
        assert_eq!(restored.question_type, "multi-session");
        assert_eq!(restored.accuracy, 0.75);
        assert_eq!(restored.count, 4);
    }

    #[test]
    fn lme_spec_report_params_json_round_trip() {
        let params = LmeSpecReportParams {
            variant: "m".to_owned(),
            seed: 42,
            limit: Some(10),
            offset: 0,
            judge_model: "gpt-4o-2024-08-06".to_owned(),
            judge_cmd_set: true,
            dump_judge_inputs_set: false,
            target_scale: "unit".to_owned(),
            parallel_units: 1,
        };
        let json = serde_json::to_string(&params).unwrap();
        let restored: LmeSpecReportParams = serde_json::from_str(&json).unwrap();
        assert_eq!(restored.variant, "m");
        assert_eq!(restored.seed, 42);
        assert_eq!(restored.limit, Some(10));
        assert_eq!(restored.judge_model, "gpt-4o-2024-08-06");
        assert!(restored.judge_cmd_set);
        assert!(!restored.dump_judge_inputs_set);
        assert_eq!(restored.target_scale, "unit");
    }

    #[test]
    fn lme_spec_report_optional_accuracy_fields_absent_when_no_judge() {
        // skip_serializing_if(None): these three fields must be absent when judged_count=0.
        let report = LmeSpecReport {
            per_type: vec![],
            task_averaged_accuracy: None,
            overall_accuracy: None,
            abstention_accuracy: None,
            abstention_count: 5,
            judge_models: vec![],
            judged_count: 0,
            run_id: "r1".to_owned(),
            run_label: "test".to_owned(),
            variant: "m".to_owned(),
            generated_at: "2026-01-01T00:00:00Z".to_owned(),
            port: "rust".to_owned(),
            seed: 42,
            estate_mode: "artifact-unit".to_owned(),
            target_scale: "unit".to_owned(),
            total_questions: 5,
            parallel_units: 1,
            run_environment: None,
            dream_pending: 0,
            dream_draining: 0,
            per_question_results: vec![],
        };
        let json = serde_json::to_string(&report).unwrap();
        assert!(
            !json.contains("task_averaged_accuracy"),
            "task_averaged_accuracy must be absent when judged_count=0"
        );
        assert!(
            !json.contains("overall_accuracy"),
            "overall_accuracy must be absent when judged_count=0"
        );
        assert!(
            !json.contains("abstention_accuracy"),
            "abstention_accuracy must be absent when judged_count=0"
        );
    }

    #[test]
    fn lme_spec_report_accuracy_fields_present_when_judged() {
        let report = LmeSpecReport {
            per_type: vec![],
            task_averaged_accuracy: Some(0.75),
            overall_accuracy: Some(0.80),
            abstention_accuracy: Some(0.60),
            abstention_count: 10,
            judge_models: vec!["m".to_owned()],
            judged_count: 50,
            run_id: "r2".to_owned(),
            run_label: "test2".to_owned(),
            variant: "m".to_owned(),
            generated_at: "2026-01-01T00:00:00Z".to_owned(),
            port: "rust".to_owned(),
            seed: 1,
            estate_mode: "artifact-unit".to_owned(),
            target_scale: "unit".to_owned(),
            total_questions: 50,
            parallel_units: 1,
            run_environment: None,
            dream_pending: 0,
            dream_draining: 0,
            per_question_results: vec![],
        };
        let json = serde_json::to_string(&report).unwrap();
        assert!(json.contains("task_averaged_accuracy"));
        assert!(json.contains("overall_accuracy"));
        assert!(json.contains("abstention_accuracy"));
    }

    // ── Aggregate from verdict records ────────────────────────────────────────

    #[test]
    fn aggregate_no_verdicts_produces_six_fixed_types() {
        // Empty verdict slice → six fixed types, all accuracy=0.0, count=0.
        let result = lme_spec_aggregate(&[]);
        assert_eq!(result.per_type.len(), 6, "always six fixed types per §4");
        assert_eq!(result.task_averaged_accuracy, 0.0);
        assert_eq!(result.overall_accuracy, 0.0);
    }

    #[test]
    fn abstention_detection_uses_question_id_not_type() {
        // §2: is_abstention is `'_abs' in question_id`, not in question_type.
        let abs_q = LmeSpecQuestion {
            question_id: "q1_abs".to_owned(),
            question_type: "multi-session".to_owned(),
            question: "Did X happen?".to_owned(),
            answer: "No evidence.".to_owned(),
            question_date: "2024/01/01 (Mon) 00:00".to_owned(),
            haystack_dates: vec![],
            haystack_session_ids: vec![],
            haystack_sessions: vec![],
            answer_session_ids: vec![],
        };
        let non_abs_q = LmeSpecQuestion {
            question_id: "q2".to_owned(),
            question_type: "single-session-user".to_owned(),
            question: "What is Y?".to_owned(),
            answer: "Blue.".to_owned(),
            question_date: "2024/01/01 (Mon) 00:00".to_owned(),
            haystack_dates: vec![],
            haystack_session_ids: vec![],
            haystack_sessions: vec![],
            answer_session_ids: vec![],
        };
        assert!(abs_q.is_abstention(), "q1_abs must be abstention");
        assert!(!non_abs_q.is_abstention(), "q2 must not be abstention");
        let count = [abs_q, non_abs_q]
            .iter()
            .filter(|q| q.is_abstention())
            .count();
        assert_eq!(count, 1);
    }

    // ── Gregorian conversion ──────────────────────────────────────────────────

    #[test]
    fn gregorian_epoch_zero_is_1970_01_01() {
        let s = gregorian_from_unix(0, false);
        assert_eq!(s, "1970-01-01T00:00:00Z");
    }

    #[test]
    fn gregorian_compact_format() {
        let s = gregorian_from_unix(0, true);
        assert_eq!(s, "19700101T000000z");
    }

    #[test]
    fn gregorian_known_date() {
        // Unix 1700000000 = 2023-11-14T22:13:20Z (verified externally).
        let s = gregorian_from_unix(1_700_000_000, false);
        assert_eq!(s, "2023-11-14T22:13:20Z");
    }

    // ── HYD-2: hydration-tier flag ────────────────────────────────────────────

    /// Verifies that `LmeSpecRunConfig`'s `answer_hydration_tier` defaults to
    /// `Distilled` (the production shape) and that the wire string is correct.
    #[test]
    fn lme_spec_hydration_tier_defaults_to_distilled() {
        use crate::journey_driver::HydrationDepth;
        // Build a minimal config with the default tier value.
        let tier = HydrationDepth::Distilled;
        assert_eq!(tier.as_wire_str(), "distilled",
            "default tier must wire as 'distilled' — the production shape used by moot_memory_get");
        // Full is the ablation arm.
        assert_eq!(HydrationDepth::Full.as_wire_str(), "full");
    }

    // ── per_question_results round-trip ───────────────────────────────────────

    /// A degraded row (guard_healthy=false) must survive report serialisation and
    /// be findable by question_id with the correct guard_diagnostic text.
    ///
    /// The defect under test: per_question_results was computed but never wired
    /// into LmeSpecReport, so the data was absent from every written report.
    /// This gate is written against the serialised-then-deserialised report to
    /// confirm the data reaches the wire, not merely lives in memory.
    #[test]
    fn lme_spec_per_question_results_degraded_row_round_trip() {
        let question_id = "lme_perq_degraded_01";
        let expected_diagnostic = "estate probe failed: connection refused";

        let row = LmeSpecReportPerQuestionRow {
            question_id: question_id.to_owned(),
            base_question_type: "single-session-user".to_owned(),
            is_abstention: false,
            hypothesis: None,
            verdict_record: None,
            guard_healthy: false,
            guard_diagnostic: Some(expected_diagnostic.to_owned()),
            cache_hit: None,
            turns_ingested: 0,
        };

        let report = LmeSpecReport {
            per_type: vec![],
            task_averaged_accuracy: None,
            overall_accuracy: None,
            abstention_accuracy: None,
            abstention_count: 0,
            judge_models: vec![],
            judged_count: 0,
            run_id: "r-perq-degraded".to_owned(),
            run_label: "per-question-round-trip-test".to_owned(),
            variant: "s".to_owned(),
            generated_at: "2026-09-14T00:00:00Z".to_owned(),
            port: "rust".to_owned(),
            seed: 1,
            estate_mode: "artifact-unit".to_owned(),
            target_scale: "unit".to_owned(),
            total_questions: 1,
            parallel_units: 1,
            run_environment: None,
            dream_pending: 0,
            dream_draining: 0,
            per_question_results: vec![row],
        };

        // Serialize to JSON bytes, then deserialize back.
        // The defect being tested is that data never reached the written report,
        // so we must assert against the round-tripped value, not the in-memory struct.
        let json = serde_json::to_string(&report).unwrap();
        let restored: LmeSpecReport = serde_json::from_str(&json).unwrap();

        // a. per_question_results is present and non-empty.
        assert!(
            !restored.per_question_results.is_empty(),
            "per_question_results must be non-empty after round-trip"
        );

        // b. Find the row by the literal question_id.
        let found = restored
            .per_question_results
            .iter()
            .find(|r| r.question_id == question_id);
        let degraded_row = found.expect(
            "must find row with question_id 'lme_perq_degraded_01' in per_question_results"
        );

        // c. guard_healthy is false on the degraded row.
        assert!(
            !degraded_row.guard_healthy,
            "guard_healthy must be false on the degraded row"
        );

        // d. guard_diagnostic carries the exact diagnostic text.
        assert_eq!(
            degraded_row.guard_diagnostic.as_deref(),
            Some(expected_diagnostic),
            "guard_diagnostic must equal 'estate probe failed: connection refused'"
        );
    }
}
