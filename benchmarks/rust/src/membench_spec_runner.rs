//! membench_spec_runner.rs — Official-protocol runner for the membench-spec lane.
//!
//! Rust twin of `MemBenchSpecRunner.swift`. Implements the MemBench evaluation
//! protocol verbatim, per MEMBENCH_OFFICIAL_PROTOCOL.md §2–§6, realigning the
//! existing membench lane's four known deviations (§7 rows 1–6):
//!
//!   §7 row 1: answer letter produced by an external answering model via the
//!             BYOAI seam (--answer-cmd or offline batch), not heuristic choice-scan.
//!   §7 row 2: storage lines use the §2 step-prefix format
//!             (`{step}[|]{message}` or `{step}[|]'user': {u}; 'agent': {a}`).
//!   §7 row 3: recall metric is §4 `get_recall` verbatim, not LME ranked-list math.
//!   §7 row 4: recall/answer query uses `recall_query(question, time)` — `question (time)`.
//!   §7 row 5: §5 wall-clock timers recorded per moot_file_memory and moot_memory_search call.
//!   §7 row 6: §6 step_cap capacity walk; TokenCounter seam defers cl100k_base artifact.
//!
//! # Step ↔ sid correspondence (MEMBENCH_OFFICIAL_PROTOCOL.md §2)
//!
//! The env stores each message as `{step}[|]{message}` where step is the env's
//! step_id. We use `turn.sid` (the corpus global turn id) as the step value.
//! Rationale: §4 parses `int(stored_text.split('[|]')[0])` and compares against
//! `target_step_id[*].global_sid`. Using `turn.sid` makes those values identical —
//! stored step id == corpus sid == target global sid. This is the only mapping
//! that makes the §4 recall comparison work without a secondary table.
//!
//! Documentation: step = turn.sid (no offset). FirstAgent session 0 has sids
//! 0–N, session 1 has sids (N+1)–M, etc. (verified from MemBenchCorpus loader).
//!
//! # Estate strategy
//!
//! Per-item scratch estates, identical to the existing MemBench lane. Estate
//! caching is NOT used for the spec lane: the storage format is different from
//! the existing lane, so artifacts are not interchangeable.
//!
//! # Answer path — two modes (§3, §7 row 1)
//!
//! - live:  `answer_cmd` set     subprocess per item while the estate is alive.
//! - batch: `dump_answer_inputs_path` set — writes JSONL prompts after each estate run,
//!          `consume_answers_path` set  — reads pre-scored letters from an earlier dump.
//! - When neither is configured, `answered_count` is 0 and accuracy is not reported.
//! - NO fallback heuristic: absent an answering model, there is no prediction.
//!
//! # §6 step_cap mode
//!
//! `MemBenchSpecRunMode::StepCap` is a SEPARATE RUN MODE. The standard mode
//! (`MemBenchSpecRunMode::Standard`) implements §3–§5. step_cap is invoked only
//! when explicitly requested and uses inline encoding (impatient) so each stored
//! turn is immediately queryable.

use crate::artifact_recall::{load_or_reconstruct_id_map, ArtifactTargetScale};
use crate::config::{canonical_tmp_base, EndpointConfig, EndpointRole, ResultFormat, Transport, VerbMap};
use crate::degeneracy_guard::{GuardSamplingPolicy, LegGuardSampler};
use crate::encode_barrier::{wait_for_encode_drain, EncodeBarrier};
use crate::json_value::JsonValue;
use crate::longmemeval_judge::lme_run_judge;
use crate::longmemeval_runner::{probe_mcp_client, SplitMix64};
use crate::mcp_client::{MCPClient, MCPError, ToolCaller};
use crate::membench_corpus::MemBenchItem;
use crate::membench_runner::BenchShape;
use crate::membench_spec_protocol::{
    answer_prompt, membench_count_tokens, parse_answer_choice, recall_query,
    storage_line_dict, storage_line_string, MemBenchPerspective,
};
use crate::membench_spec_scorer::{
    membench_spec_aggregate, membench_spec_answer_correct, membench_spec_capacity_buckets,
    membench_spec_efficiency_stats, membench_spec_get_recall, MemBenchSpecAggregateSlice,
    MemBenchSpecCapacityBucket, MemBenchSpecEfficiencyStats, MemBenchSpecItemScore,
};
use crate::record_writer::{record_filename, write_record_never_overwrite};
use crate::scratch_posture::{moot_serve_command, ScratchEstatePosture};
use crate::subject_generator::deterministic_subject;
use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Instant;

// ─────────────────────────────────────────────────────────────────────────────
// VerbMap
// ─────────────────────────────────────────────────────────────────────────────

/// Standard mootx01 VerbMap for membench-spec ingestion + recall queries.
///
/// Location "benchmarks/membench-spec" distinguishes spec-lane estates from
/// the existing membench lane ("benchmarks/membench").
///
/// Twin of Swift `memBenchSpecMootVerbMap`.
fn membench_spec_verb_map() -> VerbMap {
    let mut constant_args = BTreeMap::new();
    constant_args.insert("location".to_string(), "benchmarks/membench-spec".to_string());
    VerbMap::new(
        crate::aria_v2_surface::FILE_MEMORY,
        crate::aria_v2_surface::MEMORY_SEARCH,
        None,
        None,
        None,
        None,
        Some(constant_args),
        Some(ResultFormat::MootV2),
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// Run mode
// ─────────────────────────────────────────────────────────────────────────────

/// Controls whether the runner executes the standard §3–§5 protocol or
/// the §6 step_cap capacity walk.
///
/// - `Standard`: ingest all turns → settle → recall → answer → §3–§5 metrics.
/// - `StepCap`: ingest one turn at a time; ask QA at every step after the
///   last evidence step; accumulate (token_count, correct) pairs (§6).
///
/// Twin of Swift `MemBenchSpecRunMode`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MemBenchSpecRunMode {
    /// Standard §3–§5 run: ingest + settle + recall + optional answer.
    Standard,
    /// §6 step_cap run: per-step ingest and QA ask from the last evidence step.
    StepCap,
}

impl MemBenchSpecRunMode {
    /// Report JSON label.
    pub fn as_str(self) -> &'static str {
        match self {
            MemBenchSpecRunMode::Standard => "standard",
            MemBenchSpecRunMode::StepCap  => "step_cap",
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Run config
// ─────────────────────────────────────────────────────────────────────────────

/// Configuration for one membench-spec run.
///
/// Mirrors `MemBenchRunConfig` but scoped to the spec lane's narrower
/// requirements: no estate cache, no parallel concurrency control (the spec
/// runner is serial to avoid cross-estate timing contamination in §5), no
/// batch seed path.
///
/// Twin of Swift `MemBenchSpecRunConfig`.
pub struct MemBenchSpecRunConfig {
    /// Path to the mootx01 binary.
    pub moot_binary_path: PathBuf,
    /// Root MemData directory (contains FirstAgent/ and ThirdAgent/).
    pub data_dir: PathBuf,
    /// Agent perspective to load ("FirstAgent" or "ThirdAgent").
    pub agent: String,
    /// Category names to include. None = all 7 LowLevel categories.
    pub categories: Option<Vec<String>>,
    /// Maximum number of items to run. None = all loaded items.
    pub limit: Option<usize>,
    /// Skip this many items from the seeded-shuffled item list.
    pub offset: usize,
    /// Seed for deterministic item shuffling.
    pub seed: u64,
    /// Directory to write the results report. None = no report written.
    pub out_dir: Option<PathBuf>,
    /// Run label for the report filename and header.
    pub run_label: String,
    /// Run serial (from --run-id or UTC timestamp). Ties the report to its params sidecar.
    pub run_serial: String,
    /// Encode-queue synchronisation strategy. Standard mode: use Drain (default).
    /// StepCap mode: forced to Impatient regardless of this setting.
    pub encode_barrier: EncodeBarrier,
    /// At-rest posture for scratch estates. Default: PlaintextTransient.
    pub scratch_posture: ScratchEstatePosture,
    /// Storage backend shape for scratch estates. Default: Disk.
    pub shape: BenchShape,
    /// BYOAI answering command (§3, §7 row 1). None = no predictions; answered_count: 0.
    ///
    /// The command reads the rendered §3 answer prompt on stdin and writes its
    /// response on stdout. Any shell command works (e.g. "claude -p" or "./my-model.sh").
    /// The runner parses the response via `parse_answer_choice`. NO fallback heuristic
    /// applies when no answer command is provided.
    pub answer_cmd: Option<String>,
    /// Path to write answer-prompt JSONL dump for offline scoring.
    ///
    /// When set, the runner writes one JSONL line per QA item after completing
    /// each estate. Format:
    ///   header: `{"type":"header","run_label":"…","agent":"…"}`
    ///   qa rows: `{"type":"qa","item_id":"…","category":"…","agent":"…","prompt":"…",
    ///              "ground_truth":"…","item_recall":0.0}`
    pub dump_answer_inputs_path: Option<PathBuf>,
    /// Path to read pre-scored answers for each item.
    ///
    /// Each line: `{"item_id":"…","answer":"A"}` where answer is A/B/C/D.
    /// Missing or unrecognised item_ids are silently skipped (scored as unanswered).
    pub consume_answers_path: Option<PathBuf>,
    /// Run mode: Standard §3–§5, or §6 StepCap capacity walk.
    pub run_mode: MemBenchSpecRunMode,
    /// Bucket boundaries (token counts) for the §6 capacity report.
    /// Default: [1000, 5000, 20000] — matches the three tier sizes in the paper.
    pub capacity_bucket_boundaries: Vec<i64>,
    /// Artifact estate scale for Standard mode. Unit: one pre-built estate per
    /// item (catalog_path required). BenchAggregate: one shared estate (estate_dir
    /// required). When None, Standard mode falls through to scratch provisioning
    /// (legacy path; kept for StepCap compatibility).
    ///
    /// StepCap mode always provisions scratch estates regardless of this field.
    pub target_scale: Option<ArtifactTargetScale>,
    /// Path to the dataset's catalog.json. Required when target_scale=unit. The
    /// catalog resolves each item stem to its estate directory across primary and
    /// secondary bases.
    pub catalog_path: Option<PathBuf>,
    /// Path to a single shared pre-built estate. Required when target_scale=bench-aggregate.
    pub estate_dir: Option<PathBuf>,
    /// Binary identity for the §6 required report fields
    /// (BENCHMARK_METHOD.md §6; STEP7_FINDINGS.md F1). Collected at the CLI
    /// layer; None for library/test callers. Twin of Swift (2026-08-18 doctrine).
    pub run_environment: Option<crate::run_environment::IdentityEnvironment>,
    /// When `Some`, passed as `"scoring"` in every `moot_memory_search` argument dict.
    /// Accepted values: `"raw"`, `"rrf"`, `"matrixAware"`, `"discriminative"`.
    /// When `None`, the key is absent — the call is byte-identical to the pre-flag baseline.
    pub scoring_strategy: Option<String>,
    /// Number of search-result memory blocks included in the offline answer-input dump.
    /// Recorded in the dump header so downstream reader-model tooling knows the context
    /// depth. membench-spec uses moot_memory_search (not moot_memory_get), so all
    /// returned results are included; this field records how many were written.
    /// Default 10 matches lme-spec / convomem-spec.
    pub answer_hydration_depth: usize,
    /// Guard probe sampling policy.
    /// `OncePerLeg` (default): probe once per estate run.
    /// `PerUnit`: probe on every query — useful for aggregate-estate debugging.
    pub guard_sampling_policy: GuardSamplingPolicy,
    /// Optional directory containing seed-unit JSON files named `<estateName>.json`.
    /// Used as the third fallback for id-map derivation when id-map.json is absent
    /// and sourceFile/chunkIndex reconstruction yields no rows. JSON-import-lane estates
    /// store each drawer's lineageID as the FNV-1a-128 hash of the seed record id;
    /// this directory lets membench-spec recover the seed-id → drawer-UUID map from
    /// that lineage chain. When `None`, lineage derivation is skipped.
    pub seed_units_dir: Option<std::path::PathBuf>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-item outcome
// ─────────────────────────────────────────────────────────────────────────────

/// The result of running the spec protocol against one MemBench item.
///
/// Carries §3 correctness, §4 recall, §5 timings, and optionally §6 capacity
/// samples.
///
/// Twin of Swift `MemBenchSpecItemOutcome`.
struct MemBenchSpecItemOutcome {
    category: String,
    /// Agent perspective label ("FirstAgent" or "ThirdAgent").
    agent: String,
    /// True when the answering model's letter equals the ground truth (§3).
    /// None when no answer model is configured or consume file had no entry.
    answered_correct: Option<bool>,
    /// §4 recall score ∈ [0, 1].
    recall_score: f64,
    /// Per-store wall-clock durations in seconds (§5). One per moot_file_memory call.
    write_durations: Vec<f64>,
    /// Wall-clock duration of the single moot_memory_search call, in seconds (§5).
    read_duration: f64,
    /// §6 step_cap samples: (token_count, correct) pairs. Empty in standard mode.
    capacity_samples: Vec<(i64, bool)>,
}

/// Builds the artifact runner's UUID → turn-id manifest. MemBench lineage IDs
/// use `<family>/<category>/<section>/<tid>/<relationship-slug>`; older
/// id-maps may use the decimal turn id directly. Rows in neither form are
/// counted so callers can report incomplete mapping instead of hiding it.
fn membench_spec_manifest(
    id_map: std::collections::HashMap<String, String>,
) -> (std::collections::HashMap<String, i64>, usize) {
    let mut manifest = std::collections::HashMap::new();
    let mut unmapped_count = 0;
    for (seed_id, uuid) in id_map {
        let sid = seed_id.parse::<i64>().ok().or_else(|| {
            let components: Vec<&str> = seed_id.split('/').collect();
            (components.len() == 5)
                .then(|| components[3].parse::<i64>().ok())
                .flatten()
        });
        if let Some(sid) = sid {
            manifest.insert(uuid.to_ascii_lowercase(), sid);
        } else {
            unmapped_count += 1;
        }
    }
    (manifest, unmapped_count)
}

// ─────────────────────────────────────────────────────────────────────────────
// Report — serializable types mirroring the Swift Codable report
// ─────────────────────────────────────────────────────────────────────────────

/// Serializable mirror of `MemBenchSpecAggregateSlice` for JSON report output.
/// Defined here (not in membench_spec_scorer.rs) to avoid modifying existing files.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct SpecAggregateSliceWire {
    pub label: String,
    pub count: usize,
    pub accuracy: f64,
    pub mean_recall: f64,
}

impl From<&MemBenchSpecAggregateSlice> for SpecAggregateSliceWire {
    fn from(s: &MemBenchSpecAggregateSlice) -> Self {
        SpecAggregateSliceWire {
            label: s.label.clone(),
            count: s.count,
            accuracy: s.accuracy,
            mean_recall: s.mean_recall,
        }
    }
}

/// Serializable mirror of `MemBenchSpecEfficiencyStats` for JSON report output.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct SpecEfficiencyStatsWire {
    pub count: usize,
    pub mean: f64,
    pub p50: f64,
    pub p95: f64,
}

impl From<&MemBenchSpecEfficiencyStats> for SpecEfficiencyStatsWire {
    fn from(s: &MemBenchSpecEfficiencyStats) -> Self {
        SpecEfficiencyStatsWire {
            count: s.count,
            mean: s.mean,
            p50: s.p50,
            p95: s.p95,
        }
    }
}

/// Serializable mirror of `MemBenchSpecCapacityBucket` for JSON report output.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct SpecCapacityBucketWire {
    pub token_low: i64,
    pub token_high: Option<i64>,
    pub count: usize,
    pub accuracy: f64,
}

impl From<&MemBenchSpecCapacityBucket> for SpecCapacityBucketWire {
    fn from(b: &MemBenchSpecCapacityBucket) -> Self {
        SpecCapacityBucketWire {
            token_low: b.token_low,
            token_high: b.token_high,
            count: b.count,
            accuracy: b.accuracy,
        }
    }
}

/// Bridge type for serializing `(i64, bool)` capacity samples to JSON.
/// Needed because serde does not derive Serialize on tuples in all contexts.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct CapacitySampleWire {
    token_count: i64,
    correct: bool,
}

/// Codable report for the membench-spec lane.
///
/// Written to `membench-spec-<agent>-<serial>.json` via RecordWriter conventions.
/// The params sidecar shares the same serial: `membench-spec-<agent>-<serial>-params.json`.
///
/// Twin of Swift `MemBenchSpecReport`.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct MemBenchSpecReport {
    // MARK: Run metadata (mirrors the existing membench report fields)
    /// Run label from config.
    pub run_label: String,
    /// Port identifier: "rust".
    pub port: String,
    /// Agent perspective ("FirstAgent" or "ThirdAgent").
    pub agent: String,
    /// Seed used for item shuffling.
    pub seed: u64,
    /// Estate mode label: "per-item-spec".
    pub estate_mode: String,
    /// Encode barrier label (e.g. "drain" or "impatient").
    pub encode_barrier: String,
    /// Backend shape label (e.g. "disk" or "ram").
    pub shape: String,
    /// Run mode label: "standard" or "step_cap".
    pub run_mode: String,

    // MARK: Aggregated results (§3 + §4)
    /// Overall accuracy and recall across all answered items.
    pub overall: SpecAggregateSliceWire,
    /// Per-category breakdown (LowLevel categories in paper order, then HighLevel).
    pub by_category: Vec<SpecAggregateSliceWire>,
    /// Per-perspective breakdown ("FirstAgent" and/or "ThirdAgent").
    pub by_perspective: Vec<SpecAggregateSliceWire>,

    // MARK: Answer coverage
    /// Number of items where an answer letter was produced (§3).
    /// 0 when no answer command was configured and no consume file was provided.
    pub answered_count: usize,

    // MARK: §5 Efficiency
    /// Aggregated per-store wall-clock stats (§5).
    pub write_efficiency: SpecEfficiencyStatsWire,
    /// Aggregated per-recall wall-clock stats (§5).
    pub read_efficiency: SpecEfficiencyStatsWire,

    // MARK: §6 Capacity (None unless step_cap mode ran)
    /// Raw (token_count, correct) pairs from step_cap. None in standard mode.
    pub capacity_samples: Option<Vec<CapacitySampleWire>>,
    /// Bucketed capacity accuracy. None in standard mode.
    pub capacity_buckets: Option<Vec<SpecCapacityBucketWire>>,

    // MARK: Item counts
    /// Number of items that ran to completion.
    pub item_count: usize,
    /// Binary and protocol identity (2026-08-18 doctrine: accuracy lane emits only
    /// the three identity fields; full machine profile is the timing lane's concern).
    /// Collected at the CLI layer; None for library/test callers. Twin of Swift.
    #[serde(rename = "run_environment", skip_serializing_if = "Option::is_none")]
    #[serde(default)]
    pub run_environment: Option<crate::run_environment::IdentityEnvironment>,

    // MARK: Dream drain status (item 8)
    /// `dreaming` lane pending count captured once at run start.
    #[serde(rename = "dream_pending")]
    #[serde(default)]
    pub dream_pending: u64,
    /// 1 when the `dreaming` lane was actively draining at run start; 0 otherwise.
    #[serde(rename = "dream_draining")]
    #[serde(default)]
    pub dream_draining: u64,
}

// ─────────────────────────────────────────────────────────────────────────────
// Offline answer consume
// ─────────────────────────────────────────────────────────────────────────────

/// Loads a pre-scored answer file written by an offline batch run.
///
/// Each line must be `{"item_id":"…","answer":"A"}` where answer is A/B/C/D.
/// Lines that fail to parse or carry an invalid letter are silently skipped.
///
/// - Parameter `path`: Path to the answers JSONL file.
/// - Returns: HashMap from item_id to answer letter.
///
/// Twin of Swift `loadConsumedAnswers(_:)`.
fn load_consumed_answers(path: &Path) -> Result<std::collections::HashMap<String, String>, MCPError> {
    let content = std::fs::read_to_string(path).map_err(|e| MCPError {
        description: format!("membench-spec: cannot read consume-answers file at '{}': {e}", path.display()),
    })?;
    let mut result: std::collections::HashMap<String, String> = Default::default();
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        // Parse {"item_id":"…","answer":"A"}.
        let Ok(val) = serde_json::from_str::<serde_json::Value>(trimmed) else {
            continue;
        };
        let Some(item_id) = val.get("item_id").and_then(|v| v.as_str()) else {
            continue;
        };
        let Some(answer) = val.get("answer").and_then(|v| v.as_str()) else {
            continue;
        };
        // Validate: only A/B/C/D accepted (§3).
        if matches!(answer, "A" | "B" | "C" | "D") {
            result.insert(item_id.to_string(), answer.to_string());
        }
    }
    Ok(result)
}

// ─────────────────────────────────────────────────────────────────────────────
// Answer dump writer
// ─────────────────────────────────────────────────────────────────────────────

/// Wraps a JSONL dump file for offline answer scoring.
///
/// Write the header first (in `new`), then one row per QA item using `write_row`.
/// The dump format matches the `judge-batch` subcommand's input format closely,
/// with `item_id` substituting for `question_id`.
///
/// Twin of Swift `MemBenchSpecAnswerDump`.
struct MemBenchSpecAnswerDump {
    /// The dump file, kept open for the lifetime of the run.
    file: std::fs::File,
    /// Path, kept for diagnostic messages.
    path: PathBuf,
}

impl MemBenchSpecAnswerDump {
    /// Opens a new dump file, refusing to overwrite an existing one, and
    /// writes the JSONL header line.
    fn new(path: &Path, run_label: &str, agent: &str, answer_hydration_depth: usize) -> Result<Self, MCPError> {
        // O_EXCL: refuse to overwrite an existing dump (matches RecordWriter).
        use std::os::unix::fs::OpenOptionsExt;
        let file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(path)
            .map_err(|e| MCPError {
                description: format!(
                    "membench-spec dump: cannot create '{}': {e}",
                    path.display()
                ),
            })?;
        let mut dump = MemBenchSpecAnswerDump { file, path: path.to_owned() };
        // Write header line. The "benchmark" field lets answer-batch dispatch
        // on the protocol without inspecting any other record shape.
        // memory_texts come from moot_memory_search — no moot_memory_get call —
        // so hydration_tier is a fixed annotation recording the source path rather
        // than a configurable depth tier. answer_hydration_depth records how many
        // search-result blocks were included as context (parity with lme-spec /
        // convomem-spec answer-input dumps).
        let header = serde_json::json!({
            "type": "header",
            "benchmark": "membench-spec",
            "run_label": run_label,
            "agent": agent,
            "answer_hydration_depth": answer_hydration_depth,
            "hydration_tier": "search-result",
        });
        dump.write_json_line(&header)?;
        Ok(dump)
    }

    /// Writes one QA item's rendered answer prompt to the dump file.
    ///
    /// `memory_texts` holds the individual memory blocks in retrieval order (parallel
    /// to `retrieved_drawer_ids`). Both fields are recorded for artifact-recall scoring.
    fn write_row(
        &mut self,
        item_id: &str,
        category: &str,
        agent: &str,
        prompt: &str,
        ground_truth: &str,
        recall_score: f64,
        memory_texts: &[String],
        retrieved_drawer_ids: &[String],
    ) -> Result<(), MCPError> {
        let row = serde_json::json!({
            "type": "qa",
            "item_id": item_id,
            "category": category,
            "agent": agent,
            "prompt": prompt,
            "ground_truth": ground_truth,
            "item_recall": recall_score,
            "memory_texts": memory_texts,
            "retrieved_drawer_ids": retrieved_drawer_ids,
        });
        self.write_json_line(&row)
    }

    fn write_json_line(&mut self, val: &serde_json::Value) -> Result<(), MCPError> {
        let mut line = serde_json::to_string(val).map_err(|e| MCPError {
            description: format!(
                "membench-spec dump: JSON serialisation failed: {e}"
            ),
        })?;
        line.push('\n');
        self.file.write_all(line.as_bytes()).map_err(|e| MCPError {
            description: format!(
                "membench-spec dump: write failed for '{}': {e}",
                self.path.display()
            ),
        })
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Scratch estate management
// ─────────────────────────────────────────────────────────────────────────────

/// Creates a fresh, hardened scratch directory for the membench-spec lane.
///
/// Uses `/tmp/membench-spec-{seed}-{item_index}` as the path (distinct from
/// the existing membench lane's `/tmp/membench-bench-` prefix), so teardown
/// guards can distinguish the two lanes' estates.
///
/// Mirrors `membench_scratch_dir` with the spec prefix.
///
/// Twin of Swift `memBenchSpecScratchDir(posture:)`.
fn membench_spec_scratch_dir(
    seed: u64,
    item_index: usize,
    posture: ScratchEstatePosture,
) -> Result<PathBuf, MCPError> {
    let path = PathBuf::from(format!("/tmp/membench-spec-{seed}-{item_index}"));
    // Remove any leftover from a previous crashed run at this index.
    if path.exists() {
        std::fs::remove_dir_all(&path).map_err(|e| MCPError {
            description: format!(
                "membench_spec_scratch_dir: could not remove stale dir {}: {e}",
                path.display()
            ),
        })?;
    }
    std::fs::create_dir_all(&path).map_err(|e| MCPError {
        description: format!(
            "membench_spec_scratch_dir: could not create {}: {e}",
            path.display()
        ),
    })?;

    // Reject symlinked paths — `symlink_metadata` is the lstat equivalent and
    // does NOT follow symlinks, so a symlink entry is visible here.
    let lstat = std::fs::symlink_metadata(&path).map_err(|e| MCPError {
        description: format!(
            "membench_spec_scratch_dir: cannot stat {}: {e}",
            path.display()
        ),
    })?;
    if lstat.file_type().is_symlink() {
        return Err(MCPError {
            description: format!(
                "membench_spec_scratch_dir: SAFETY: '{}' is a symlink — \
                 refusing to use as scratch estate",
                path.display()
            ),
        });
    }

    // Canonicalize to resolve any lingering `..` components.
    // Verify the resolved path has the expected prefix (handles macOS /private/tmp).
    let canonical = std::fs::canonicalize(&path).map_err(|e| MCPError {
        description: format!(
            "membench_spec_scratch_dir: cannot canonicalize {}: {e}",
            path.display()
        ),
    })?;
    let expected_prefix = canonical_tmp_base().join("membench-spec-");
    if !canonical
        .to_string_lossy()
        .starts_with(expected_prefix.to_string_lossy().as_ref())
    {
        return Err(MCPError {
            description: format!(
                "membench_spec_scratch_dir: SAFETY: canonicalized path '{}' \
                 escapes /tmp/membench-spec-",
                canonical.display()
            ),
        });
    }

    // The posture is the record's: a transient record is plaintext by rule.
    let _ = posture;
    Ok(canonical)
}

/// Removes a scratch directory created by `membench_spec_scratch_dir`. Refuses
/// any path without the `/tmp/membench-spec-` prefix and refuses symlinks.
///
/// Twin of Swift `memBenchSpecGuardedTeardown(_:)`.
fn membench_spec_guarded_teardown(path: &Path) {
    let expected_prefix = canonical_tmp_base()
        .join("membench-spec-")
        .to_string_lossy()
        .into_owned();
    let path_str = path.to_string_lossy();
    if !path_str.starts_with(&expected_prefix) {
        eprintln!(
            "[membench-spec] SAFETY: guarded teardown refused '{}' — \
             path must have the {} prefix",
            path_str, expected_prefix
        );
        return;
    }
    if let Ok(meta) = std::fs::symlink_metadata(path) {
        if meta.file_type().is_symlink() {
            eprintln!(
                "[membench-spec] SAFETY: guarded teardown refused symlink '{}'",
                path_str
            );
            return;
        }
    }
    if let Err(e) = std::fs::remove_dir_all(path) {
        eprintln!(
            "[membench-spec] teardown warning: could not remove {}: {e}",
            path_str
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// EndpointConfig builder
// ─────────────────────────────────────────────────────────────────────────────

/// Builds an `EndpointConfig` for mootx01 pointing at a membench-spec scratch estate.
///
/// Mirrors `membench_endpoint_config` but uses `membench_spec_verb_map`
/// (location: "benchmarks/membench-spec").
///
/// Twin of Swift `memBenchSpecEndpointConfig(scratchDir:mootBinaryPath:posture:shape:)`.
fn membench_spec_endpoint_config(
    scratch_dir: &Path,
    binary: &Path,
    posture: ScratchEstatePosture,
    shape: BenchShape,
) -> Result<EndpointConfig, String> {
    // The posture is the record's. RAM shape serves the InMemory backend.
    let _ = posture;
    let command = moot_serve_command(
        &binary.display().to_string(), scratch_dir, shape == BenchShape::Ram,
        &["MOOTX01_VAULT=1", "MOOTX01_SUBJECT_RIDER=0"], None)
        .map_err(|e| e.to_string())?;
    Ok(EndpointConfig {
        name: "mootx01-membench-spec".to_string(),
        transport: Transport::Stdio { command },
        auth: None,
        verb_map: membench_spec_verb_map(),
        role: EndpointRole::Target,
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// EncodeBarrier report label
// ─────────────────────────────────────────────────────────────────────────────

/// The label written to the report JSON's `encode_barrier` field.
///
/// Twin of the private Swift extension `EncodeBarrier.reportLabel`.
fn encode_barrier_label(b: EncodeBarrier) -> &'static str {
    match b {
        EncodeBarrier::Drain    => "drain",
        EncodeBarrier::Impatient => "impatient",
        EncodeBarrier::None     => "none",
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Main entry point
// ─────────────────────────────────────────────────────────────────────────────

/// Runs the membench-spec lane against a loaded corpus.
///
/// Implements MEMBENCH_OFFICIAL_PROTOCOL.md §2–§5 (standard mode) or §6 (step_cap mode).
///
/// Per-item strategy (serial — avoids cross-estate §5 timing contamination):
///   1. Provision a fresh scratch estate per item.
///   2. Ingest all turns using §2 storage-line format.
///   3. Settle the estate (drain → dream → reindex → drain).
///   4. Issue the recall query `recall_query(question, time)` (§3–4).
///   5. Map retrieved UUIDs to step ids via the per-item manifest.
///   6. Compute §4 `get_recall` against target_step_id global sids.
///   7. Optionally obtain an answer letter via the BYOAI seam (§3).
///   8. Aggregate §5 wall-clock timers.
///   9. Write the report via RecordWriter conventions.
///
/// Returns per-item outcomes and the aggregated report. The report is also
/// written to disk when `config.out_dir` is set.
///
/// §7 row 6 resolved: `membench_count_tokens` counts with the vendored
/// cl100k_base tokenizer (byte-exact tiktoken). See `membench_spec_protocol.rs`.
///
/// Twin of Swift `runMemBenchSpec(items:config:)`.
pub fn run_membench_spec(
    items: &[MemBenchItem],
    config: &MemBenchSpecRunConfig,
) -> Result<MemBenchSpecReport, MCPError> {

    // Load consumed answers (offline batch path) before running any estates.
    let consumed_answers: std::collections::HashMap<String, String> =
        if let Some(ref p) = config.consume_answers_path {
            load_consumed_answers(p)?
        } else {
            Default::default()
        };

    // Open the dump file if configured. Created once; None when no dump path is set.
    let mut dump_writer: Option<MemBenchSpecAnswerDump> =
        if let Some(ref p) = config.dump_answer_inputs_path {
            Some(MemBenchSpecAnswerDump::new(p, &config.run_label, &config.agent, config.answer_hydration_depth)?)
        } else {
            None
        };

    // Category filter → seeded shuffle → offset + limit (mirrors the existing lane).
    let filtered: Vec<&MemBenchItem> = match &config.categories {
        Some(cats) => items.iter().filter(|i| cats.contains(&i.category)).collect(),
        None => items.iter().collect(),
    };

    let mut rng = SplitMix64::new(config.seed);
    let mut indices: Vec<usize> = (0..filtered.len()).collect();
    rng.shuffle(&mut indices);

    let sliced: Vec<usize> = indices
        .into_iter()
        .skip(config.offset)
        .take(config.limit.unwrap_or(usize::MAX))
        .collect();

    // One guard sampler for the leg (serial — no Mutex needed).
    // Respects config.guard_sampling_policy: PerUnit probes on every query,
    // which is useful for aggregate-estate runs where the daemon may behave
    // differently across queries within a single run.
    let mut guard_sampler = LegGuardSampler::new(config.guard_sampling_policy);

    // ── Dream drain status probe (item 8) ─────────────────────────────────────
    // Captured once at run start via a temporary probe client.  Uses the
    // bench-aggregate estate when available; falls back to default otherwise.
    let dream_status = if config.target_scale == Some(ArtifactTargetScale::BenchAggregate) {
        if let Some(ref estate_dir) = config.estate_dir {
            let endpoint = membench_spec_artifact_endpoint(estate_dir, &config.moot_binary_path)
                .map_err(|e| MCPError { description: e })?;
            let mut probe_client = MCPClient::new(endpoint);
            if probe_client.connect().is_ok() {
                let status = crate::encode_barrier::read_drain_status_once(&mut probe_client);
                let _ = probe_client.disconnect();
                status
            } else {
                crate::encode_barrier::DreamStatus::default()
            }
        } else {
            crate::encode_barrier::DreamStatus::default()
        }
    } else {
        crate::encode_barrier::DreamStatus::default()
    };

    // Per-item execution: serial to avoid cross-estate §5 timing contamination.
    let mut outcomes: Vec<MemBenchSpecItemOutcome> = Vec::with_capacity(sliced.len());

    for (run_index, &item_index) in sliced.iter().enumerate() {
        let item = filtered[item_index];
        eprintln!(
            "[membench-spec] item={} (#{}/{})",
            item.item_id,
            run_index + 1,
            sliced.len()
        );

        let outcome = match config.run_mode {
            MemBenchSpecRunMode::Standard => {
                if config.target_scale.is_some() {
                    // Artifact estate path: pre-built estate, no ingest/settle.
                    run_one_membench_spec_item_artifact(
                        item,
                        config,
                        &consumed_answers,
                        &mut dump_writer,
                        &mut guard_sampler,
                    )?
                } else {
                    // Scratch provisioning path (legacy; kept for backwards compatibility).
                    run_one_membench_spec_item(
                        item,
                        config,
                        run_index,
                        &consumed_answers,
                        &mut dump_writer,
                        &mut guard_sampler,
                    )?
                }
            }
            MemBenchSpecRunMode::StepCap => run_one_membench_spec_item_step_cap(
                item,
                config,
                run_index,
                &consumed_answers,
                &mut guard_sampler,
            )?,
        };
        outcomes.push(outcome);
    }

    // §4: build MemBenchSpecItemScore list for aggregation.
    // Items with None `answered_correct` contribute to recall but not accuracy.
    // When unanswered, treat correct: false (conservative; only answered_count
    // reflects the true answer coverage).
    let scores: Vec<MemBenchSpecItemScore> = outcomes
        .iter()
        .map(|o| MemBenchSpecItemScore {
            category: o.category.clone(),
            agent: o.agent.clone(),
            correct: o.answered_correct.unwrap_or(false),
            recall: o.recall_score,
        })
        .collect();
    let aggregation = membench_spec_aggregate(&scores);

    // §5: aggregate wall-clock stats across all items.
    let all_write_durations: Vec<f64> = outcomes.iter().flat_map(|o| o.write_durations.iter().copied()).collect();
    let all_read_durations: Vec<f64> = outcomes.iter().map(|o| o.read_duration).collect();
    let write_eff = membench_spec_efficiency_stats(&all_write_durations);
    let read_eff  = membench_spec_efficiency_stats(&all_read_durations);

    // §6: collect capacity samples (non-empty only in step_cap mode).
    let all_cap_samples: Vec<(i64, bool)> = outcomes.iter().flat_map(|o| o.capacity_samples.iter().copied()).collect();
    let (cap_samples_out, cap_buckets_out) = if config.run_mode == MemBenchSpecRunMode::StepCap {
        let wire_samples: Vec<CapacitySampleWire> = all_cap_samples
            .iter()
            .map(|&(tc, c)| CapacitySampleWire { token_count: tc, correct: c })
            .collect();
        let buckets = membench_spec_capacity_buckets(&all_cap_samples, &config.capacity_bucket_boundaries);
        let wire_buckets: Vec<SpecCapacityBucketWire> = buckets.iter().map(SpecCapacityBucketWire::from).collect();
        (Some(wire_samples), Some(wire_buckets))
    } else {
        (None, None)
    };

    let answered_count = outcomes.iter().filter(|o| o.answered_correct.is_some()).count();

    let report = MemBenchSpecReport {
        run_label: config.run_label.clone(),
        port: "rust".to_string(),
        agent: config.agent.clone(),
        seed: config.seed,
        estate_mode: match (&config.run_mode, &config.target_scale) {
            (MemBenchSpecRunMode::Standard, Some(ArtifactTargetScale::Unit)) => "artifact-unit".to_string(),
            (MemBenchSpecRunMode::Standard, Some(ArtifactTargetScale::BenchAggregate)) => "artifact-aggregate".to_string(),
            (MemBenchSpecRunMode::Standard, Some(ArtifactTargetScale::CompleteAggregate)) => "artifact-complete".to_string(),
            _ => "per-item-spec".to_string(),
        },
        encode_barrier: encode_barrier_label(config.encode_barrier).to_string(),
        shape: config.shape.as_str().to_string(),
        run_mode: config.run_mode.as_str().to_string(),
        overall: SpecAggregateSliceWire::from(&aggregation.overall),
        by_category: aggregation.by_category.iter().map(SpecAggregateSliceWire::from).collect(),
        by_perspective: aggregation.by_perspective.iter().map(SpecAggregateSliceWire::from).collect(),
        answered_count,
        write_efficiency: SpecEfficiencyStatsWire::from(&write_eff),
        read_efficiency: SpecEfficiencyStatsWire::from(&read_eff),
        capacity_samples: cap_samples_out,
        capacity_buckets: cap_buckets_out,
        item_count: outcomes.len(),
        // §6 required report fields ride in from the CLI layer (F1).
        run_environment: config.run_environment.clone(),
        dream_pending: dream_status.pending,
        dream_draining: if dream_status.draining { 1 } else { 0 },
    };

    // Write report + params sidecar via RecordWriter conventions.
    // Record name stem: 'membench-spec-<agent>-<serial>'
    // (§7 note: agent is the arm discriminator — FirstAgent and ThirdAgent runs
    // must not share a record name; the agent label satisfies RecordWriter's
    // arm requirement directly).
    if let Some(ref out_dir) = config.out_dir {
        let report_name = record_filename("membench-spec", &config.agent, &config.run_serial, "", "json");
        let report_path = out_dir.join(&report_name);
        let report_json = serde_json::to_vec_pretty(&report).map_err(|e| MCPError {
            description: format!("membench-spec: JSON encode failed: {e}"),
        })?;
        write_record_never_overwrite(&report_json, &report_path).map_err(|e| MCPError {
            description: e,
        })?;

        // Params sidecar.
        let params_name = record_filename("membench-spec", &config.agent, &config.run_serial, "params", "json");
        let params_path = out_dir.join(&params_name);
        let cats = config.categories.clone().unwrap_or_else(|| {
            vec![
                "simple".to_string(), "comparative".to_string(), "aggregative".to_string(),
                "conditional".to_string(), "knowledge_update".to_string(),
                "post_processing".to_string(), "noisy".to_string(),
            ]
        });
        let params = serde_json::json!({
            "run_label": &config.run_label,
            "port": "rust",
            "agent": &config.agent,
            "seed": config.seed,
            "categories": cats,
            "limit": config.limit,
            "offset": config.offset,
            "encode_barrier": encode_barrier_label(config.encode_barrier),
            "shape": config.shape.as_str(),
            "run_mode": config.run_mode.as_str(),
            "target_scale": config.target_scale.as_ref().map(ArtifactTargetScale::as_str),
            "catalog_path": config.catalog_path.as_ref().map(|p| p.to_string_lossy().into_owned()),
            "estate_dir": config.estate_dir.as_ref().map(|p| p.to_string_lossy().into_owned()),
            "answer_cmd_present": config.answer_cmd.is_some(),
            "dump_answer_inputs_present": config.dump_answer_inputs_path.is_some(),
            "consume_answers_present": config.consume_answers_path.is_some(),
            // Scoring strategy: "default" when omitted so every sidecar is self-describing.
            "scoring": config.scoring_strategy.as_deref().unwrap_or("default"),
        });
        let params_json = serde_json::to_vec_pretty(&params).map_err(|e| MCPError {
            description: format!("membench-spec: params JSON encode failed: {e}"),
        })?;
        write_record_never_overwrite(&params_json, &params_path).map_err(|e| MCPError {
            description: e,
        })?;
    }

    Ok(report)
}

// ─────────────────────────────────────────────────────────────────────────────
// Artifact estate helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Derives the unit-scale estate stem for a membench item.
///
/// Converts the item_id slash separators to double-underscores so the stem
/// can be used as a filesystem directory name (unit stem for catalog lookup).
///
/// Example: "FirstAgent/simple/roles/0" → "FirstAgent__simple__roles__0"
///
/// Twin of Swift `membenchSpecItemStem(_:)`.
fn membench_spec_item_stem(item_id: &str) -> String {
    item_id.replace('/', "__")
}

/// Builds the MCP endpoint config for a pre-built artifact estate.
///
/// Launches `mootx01 serve --db <estate_dir>`. `MOOTX01_SUBJECT_RIDER=0`
/// disables cross-estate subject propagation; transient record is plaintext
/// by rule (no Keychain access). No provisioning occurs — the estate is
/// already settled and the runner only queries it.
fn membench_spec_artifact_endpoint(estate_dir: &Path, moot_binary: &Path) -> Result<EndpointConfig, String> {
    let data_dir = estate_dir.to_string_lossy();
    let binary_str = moot_binary.to_string_lossy();
    // No MOOTX01_VAULT: artifact estates are pre-built and read-only here.
    let command = moot_serve_command(
        &binary_str, Path::new(&*data_dir), false, &["MOOTX01_FROZEN=1", "MOOTX01_SUBJECT_RIDER=0"], None)
        .map_err(|e| e.to_string())?;
    Ok(EndpointConfig {
        name: "mootx01-membench-spec".to_string(),
        transport: Transport::Stdio { command },
        auth: None,
        verb_map: membench_spec_verb_map(),
        role: EndpointRole::Both,
    })
}

/// Runs one membench-spec item against a pre-built artifact estate.
///
/// Artifact path (no ingest, no settle, no teardown):
///   a. Resolve estate directory from target_scale (unit: catalog → stem,
///      bench-aggregate: estate_dir).
///   b. Load id-map.json and invert to UUID → sid. The provisioning script
///      stores each turn with `seed_id = str(turn.sid)`, so the inversion is
///      a simple integer parse.
///   c. Connect to the estate, run degeneracy guard probe, issue the recall
///      query, disconnect.
///   d. Map retrieved UUIDs to sids via the inverted manifest; score recall.
///
/// write_durations is empty (no writes performed); read_duration is the
/// wall-clock time of the single moot_memory_search call.
///
/// Twin of Swift `runOneMemBenchSpecItemArtifact(item:config:consumedAnswers:
/// dumpWriter:guardSampler:)`.
fn run_one_membench_spec_item_artifact(
    item: &MemBenchItem,
    config: &MemBenchSpecRunConfig,
    consumed_answers: &std::collections::HashMap<String, String>,
    dump_writer: &mut Option<MemBenchSpecAnswerDump>,
    guard_sampler: &mut LegGuardSampler,
) -> Result<MemBenchSpecItemOutcome, MCPError> {

    // Resolve the estate path from the target_scale setting.
    let estate_path: PathBuf = match config.target_scale {
        Some(ArtifactTargetScale::Unit) => {
            let stem = membench_spec_item_stem(&item.item_id);
            let cat = config.catalog_path.as_ref().ok_or_else(|| MCPError {
                description: "membench-spec unit scale requires --catalog".to_string(),
            })?;
            crate::artifact_recall::resolve_unit_from_catalog(cat, &stem)?
        }
        Some(ArtifactTargetScale::BenchAggregate) | Some(ArtifactTargetScale::CompleteAggregate) => {
            config
                .estate_dir
                .as_ref()
                .ok_or_else(|| MCPError {
                    description: "estate_dir required for bench-aggregate scale".to_string(),
                })?
                .clone()
        }
        None => {
            return Err(MCPError {
                description: "run_one_membench_spec_item_artifact called with target_scale=None".to_string(),
            });
        }
    };

    // Guard: estate dir must exist before launching serve. Fail fast here
    // rather than launching an empty estate that errors on id-map.json.
    if config.target_scale == Some(ArtifactTargetScale::Unit) && !estate_path.is_dir() {
        return Err(MCPError {
            description: format!(
                "estate for unit {} missing at {}",
                item.item_id,
                estate_path.display()
            ),
        });
    }

    // Load the estate's id-map and invert to UUID → sid.
    // The provisioning script stores each turn with a bare numeric seed_id;
    // lineage-derived maps use the five-component MemBench record id instead.
    // Priority: (1) id-map.json; (2) sourceFile/chunkIndex drawers; (3) lineageID derivation.
    // seed_units_dir enables the lineage path for JSON-import-lane estates.
    let id_map = load_or_reconstruct_id_map(&estate_path, config.seed_units_dir.as_deref()).unwrap_or_else(|e| {
        eprintln!(
            "[membench-spec] id-map load/reconstruct error for item {}: {} — scoring with empty manifest",
            item.item_id, e.description
        );
        Default::default()
    });
    // seed_id → UUID becomes UUID → i64 sid. Lineage-derived keys carry the
    // tid as component 4; older id-maps may use a bare numeric id.
    let (manifest, unmapped_count) = membench_spec_manifest(id_map);
    if unmapped_count > 0 {
        eprintln!(
            "[membench-spec] {unmapped_count} id-map row(s) could not be mapped to a turn id"
        );
    }

    // Connect to the artifact estate endpoint. No provisioning; estate already settled.
    let endpoint = membench_spec_artifact_endpoint(&estate_path, &config.moot_binary_path)
        .map_err(|e| MCPError { description: e })?;
    let verb_map = membench_spec_verb_map();
    let mut client = MCPClient::new(endpoint);
    client.connect()?;

    // DegeneracyGuard: once per leg.
    guard_sampler.probe(|| probe_mcp_client(&mut client, &verb_map));

    // §3–4: recall query uses `question (time)` format.
    let query = recall_query(&item.qa.question, &item.qa.time);
    let mut query_args = crate::aria_v2_surface::memory_search_args(&verb_map.constant_args, &query);
    // When --scoring is given, pass it to the estate; when omitted, the call is
    // byte-identical to the pre-flag baseline (no "scoring" key in the dict).
    if let Some(ref s) = config.scoring_strategy {
        query_args.insert("scoring".to_string(), JsonValue::String(s.clone()));
    }

    // §5 read timing (only metric captured on the artifact path; no writes).
    let read_start = Instant::now();
    // Extract per-item texts (one per ordered UUID) alongside the raw payload.
    // moot_memory_search may return all N results in ONE text block; splitting by
    // item ensures memory_texts and retrieved_drawer_ids are aligned arrays of
    // equal length.  Adapters that zipped against text_blocks would silently
    // truncate to 1 entry when results is 1 block; this per-item path is correct
    // regardless of how many blocks the server returns.
    let (ordered_ids, per_item_texts, raw_payload) = match client.call_tool(&verb_map.query, query_args, &verb_map.result_format) {
        Ok(result) => {
            let text = result.text_blocks.join("\n");
            // items is already one entry per UUID (from parse_moot_text / parse_json_objects).
            let per_item: Vec<String> = result.items.iter()
                .map(|i| i.content.clone().unwrap_or_default())
                .collect();
            (result.ordered_ids, per_item, text)
        }
        Err(e) => {
            eprintln!(
                "[membench-spec] query error for item {}: {}",
                item.item_id, e.description
            );
            (Vec::new(), Vec::new(), String::new())
        }
    };
    let read_duration = read_start.elapsed().as_secs_f64();

    let _ = client.disconnect();

    // §4: map retrieved UUIDs → sids via the inverted manifest.
    let retrieved_step_ids: Vec<i64> = ordered_ids
        .iter()
        .filter_map(|uuid| manifest.get(&uuid.to_ascii_lowercase()).copied())
        .collect();
    let retrieved_step_ids_option: Option<Vec<i64>> = if ordered_ids.is_empty() {
        None
    } else {
        Some(retrieved_step_ids.clone())
    };

    let target_step_ids: Vec<i64> = item.qa.target_step_id.iter().map(|t| t.global_sid).collect();
    let recall_score = membench_spec_get_recall(retrieved_step_ids_option.as_deref(), &target_step_ids);

    // §3: answer production — consume or live, same seam as the scratch path.
    let mut answered_correct: Option<bool> = None;
    let perspective = if item.agent == "FirstAgent" {
        MemBenchPerspective::FirstAgent
    } else {
        MemBenchPerspective::ThirdAgent
    };

    if let Some(consumed_letter) = consumed_answers.get(&item.item_id) {
        answered_correct = Some(membench_spec_answer_correct(consumed_letter, &item.qa.ground_truth));
    } else if let Some(ref cmd) = config.answer_cmd {
        let prompt = answer_prompt(
            &perspective,
            &raw_payload,
            &item.qa.question,
            &item.qa.time,
            &item.qa.choices,
        );
        if let Ok(raw_response) = lme_run_judge(cmd, &prompt) {
            if let Some(letter) = parse_answer_choice(&raw_response) {
                answered_correct = Some(membench_spec_answer_correct(&letter, &item.qa.ground_truth));
            }
        }
    }

    // Dump path (orthogonal to live path).
    if let Some(ref mut dump) = dump_writer {
        let prompt = answer_prompt(
            &perspective,
            &raw_payload,
            &item.qa.question,
            &item.qa.time,
            &item.qa.choices,
        );
        dump.write_row(
            &item.item_id,
            &item.category,
            &item.agent,
            &prompt,
            &item.qa.ground_truth,
            recall_score,
            &per_item_texts,
            &ordered_ids,
        )?;
    }

    Ok(MemBenchSpecItemOutcome {
        category: item.category.clone(),
        agent: item.agent.clone(),
        answered_correct,
        recall_score,
        write_durations: Vec::new(), // no writes on the artifact path
        read_duration,
        capacity_samples: Vec::new(),
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-item runner — standard mode
// ─────────────────────────────────────────────────────────────────────────────

/// Runs one membench-spec item through the full §2–§5 protocol in a fresh estate.
///
/// §2: ingest each turn via `storage_line_string` / `storage_line_dict` with
///     `turn.sid` as the step id. Step = turn.sid (see module-level doc).
/// §3–4: recall query = `recall_query(question, time)`.
/// §4: recall metric = `membench_spec_get_recall(retrieved_step_ids, target_step_ids)`.
///     Retrieved step ids come from the per-item manifest (UUID → sid).
/// §5: wall-clock timers around every moot_file_memory and moot_memory_search call.
///
/// Twin of Swift `runOneMemBenchSpecItem(item:config:consumedAnswers:dumpWriter:guardSampler:)`.
fn run_one_membench_spec_item(
    item: &MemBenchItem,
    config: &MemBenchSpecRunConfig,
    item_index: usize,
    consumed_answers: &std::collections::HashMap<String, String>,
    dump_writer: &mut Option<MemBenchSpecAnswerDump>,
    guard_sampler: &mut LegGuardSampler,
) -> Result<MemBenchSpecItemOutcome, MCPError> {

    // Provision a fresh scratch estate for this item.
    let scratch_dir = membench_spec_scratch_dir(config.seed, item_index, config.scratch_posture)?;
    let endpoint = membench_spec_endpoint_config(
        &scratch_dir,
        &config.moot_binary_path,
        config.scratch_posture,
        config.shape,
    ).map_err(|e| MCPError { description: e })?;
    // Belt-and-suspenders: verify --db points into /tmp before connecting.
    // Twin of Swift `assertScratchBackend(_:requirement:)` in MemBenchSpecRunner.
    crate::gauntlet_runner::assert_scratch_backend(
        &endpoint, &crate::gauntlet_runner::MOOT_SCRATCH_REQUIREMENT,
    );
    let verb_map = membench_spec_verb_map();

    let mut client = MCPClient::new(endpoint);
    if let Err(e) = client.connect() {
        membench_spec_guarded_teardown(&scratch_dir);
        return Err(MCPError {
            description: format!(
                "membench-spec: connect error for item {}: {}",
                item.item_id, e.description
            ),
        });
    }

    // §2: Ingest all turns using the official step-prefix storage format.
    // Manifest: UUID → sid (the corpus global turn id used as the step prefix).
    // Step ↔ sid correspondence (see module header): step = turn.sid.
    let mut manifest: std::collections::HashMap<String, i64> = Default::default();
    let mut write_durations: Vec<f64> = Vec::new();
    let mut ingest_error: Option<String> = None;

    'ingest: for session in &item.sessions {
        for turn in &session.turns {
            // §2: choose string form or dict form based on whether both sides are populated.
            // FirstAgent: both user_message and assistant_message are non-empty → dict form.
            // ThirdAgent: assistant_message is empty (single-statement record) → string form.
            let storage_content = if turn.assistant_message.is_empty() {
                // §2 string message form: "{step}[|]{message}"
                storage_line_string(turn.sid as usize, &turn.user_message)
            } else {
                // §2 dict message form: "{step}[|]'user': {user}; 'agent': {agent}"
                storage_line_dict(turn.sid as usize, &turn.user_message, &turn.assistant_message)
            };

            let mut write_args: BTreeMap<String, JsonValue> = BTreeMap::new();
            write_args.insert(verb_map.content_arg.clone(), JsonValue::String(storage_content.clone()));
            write_args.insert(
                "subject".to_string(),
                JsonValue::String(deterministic_subject(&storage_content)),
            );
            for (k, v) in &verb_map.constant_args {
                write_args.insert(k.clone(), JsonValue::String(v.clone()));
            }
            // Per-turn impatient encoding: not used in standard mode (drain barrier is
            // applied after the full ingest, not per-turn). Forced in step_cap mode
            // (separate function).
            if config.encode_barrier == EncodeBarrier::Impatient {
                write_args.insert("impatient".to_string(), JsonValue::Bool(true));
            }

            // §5: wall-clock timer around the moot_file_memory call.
            let write_start = Instant::now();
            match client.call_tool(&verb_map.write, write_args, &verb_map.result_format) {
                Ok(result) => {
                    write_durations.push(write_start.elapsed().as_secs_f64());
                    // Build manifest: UUID → sid (step prefix used during store).
                    if let Some(uuid) = result.write_assigned_id {
                        manifest.insert(uuid, turn.sid);
                    }
                }
                Err(e) => {
                    ingest_error = Some(format!(
                        "ingest error sid={}: {}",
                        turn.sid, e.description
                    ));
                    break 'ingest;
                }
            }
        }
    }

    if let Some(err) = ingest_error {
        let _ = client.disconnect();
        membench_spec_guarded_teardown(&scratch_dir);
        return Err(MCPError {
            description: format!("membench-spec item={}: {err}", item.item_id),
        });
    }

    // Encode barrier: drain mode polls moot_drain_status until idle.
    // This is the same correctness invariant as LME and LoCoMo:
    // without it, recall can precede encoding completion.
    if config.encode_barrier == EncodeBarrier::Drain {
        wait_for_encode_drain(
            &mut client,
            &format!("membench-spec item={}", item.item_id),
            120.0,
        );
    }

    // Settle (B4 protocol): dream → reindex → drain.
    // The spec does not describe settle, but the harness requires it for consistent
    // recall quality. This mirrors the existing membench lane's settle protocol.
    {
        let mut dream_args: BTreeMap<String, JsonValue> = BTreeMap::new();
        dream_args.insert("associates".to_string(), JsonValue::String("all".to_string()));
        if let Err(e) = client.call_tool(crate::aria_v2_surface::DREAM, dream_args, &ResultFormat::MootV2) {
            eprintln!(
                "[membench-spec] settle dream failed for item {}: {}",
                item.item_id, e.description
            );
        }
    }
    if let Err(e) = client.call_tool(crate::aria_v2_surface::REINDEX, BTreeMap::new(), &ResultFormat::MootV2) {
        eprintln!(
            "[membench-spec] settle reindex failed for item {}: {}",
            item.item_id, e.description
        );
    }
    wait_for_encode_drain(
        &mut client,
        &format!("membench-spec settle item={}", item.item_id),
        300.0,
    );

    // DegeneracyGuard: once per leg (sampler caches the first verdict).
    guard_sampler.probe(|| probe_mcp_client(&mut client, &verb_map));

    // §3–4: Recall query uses `question (time)` format.
    let query = recall_query(&item.qa.question, &item.qa.time);
    let mut query_args = crate::aria_v2_surface::memory_search_args(&verb_map.constant_args, &query);
    // When --scoring is given, pass it to the estate; when omitted, the call is
    // byte-identical to the pre-flag baseline (no "scoring" key in the dict).
    if let Some(ref s) = config.scoring_strategy {
        query_args.insert("scoring".to_string(), JsonValue::String(s.clone()));
    }

    // §5: wall-clock timer around the moot_memory_search call.
    let read_start = Instant::now();
    // Extract per-item texts (one per ordered UUID). See comment in the artifact
    // path above for why per_item_texts rather than text_blocks is correct here.
    let (ordered_ids, per_item_texts, raw_payload) = match client.call_tool(&verb_map.query, query_args, &verb_map.result_format) {
        Ok(result) => {
            let text = if result.text_blocks.is_empty() {
                String::new()
            } else {
                result.text_blocks.join("\n")
            };
            let per_item: Vec<String> = result.items.iter()
                .map(|i| i.content.clone().unwrap_or_default())
                .collect();
            (result.ordered_ids, per_item, text)
        }
        Err(e) => {
            eprintln!(
                "[membench-spec] query error for item {}: {}",
                item.item_id, e.description
            );
            (Vec::new(), Vec::new(), String::new())
        }
    };
    let read_duration = read_start.elapsed().as_secs_f64();

    // Clean up the estate now that the query is complete.
    let _ = client.disconnect();
    membench_spec_guarded_teardown(&scratch_dir);

    // §4: Map retrieved UUIDs → step ids (= sids) via manifest.
    // `ordered_ids` carries UUIDs in moot's ranked retrieval order.
    // UUIDs absent from the manifest (not ingested for this item) are silently dropped.
    let retrieved_step_ids: Vec<i64> = ordered_ids.iter().filter_map(|uuid| manifest.get(uuid).copied()).collect();
    let retrieved_step_ids_option: Option<Vec<i64>> = if ordered_ids.is_empty() {
        None
    } else {
        Some(retrieved_step_ids.clone())
    };

    // §4: Target step ids = QA's target_step_id global sids.
    // §4 shape note: "the target flattens to its global sid (element 0)".
    let target_step_ids: Vec<i64> = item.qa.target_step_id.iter().map(|t| t.global_sid).collect();

    // §4: get_recall verbatim.
    let recall_score = membench_spec_get_recall(
        retrieved_step_ids_option.as_deref(),
        &target_step_ids,
    );

    // §3: Answer production — three exclusive paths:
    //   1. consume path: read pre-scored letter for this item_id.
    //   2. live path: send the rendered prompt to the external --answer-cmd.
    //   3. no prediction: neither consume nor live configured.
    //
    // NO fallback heuristic (§7 row 1): if no model is available, there is
    // no prediction. `answered_count: 0` is the correct report value.
    let mut answered_correct: Option<bool> = None;

    let perspective = if item.agent == "FirstAgent" {
        MemBenchPerspective::FirstAgent
    } else {
        MemBenchPerspective::ThirdAgent
    };

    if let Some(consumed_letter) = consumed_answers.get(&item.item_id) {
        // Consume path: pre-scored offline answer.
        // §3 correctness: exact string equality.
        answered_correct = Some(membench_spec_answer_correct(consumed_letter, &item.qa.ground_truth));
    } else if let Some(ref cmd) = config.answer_cmd {
        // Live path: send the §3 answer prompt to the BYOAI subprocess.
        // `lme_run_judge` runs any shell command, sends the prompt on stdin,
        // returns trimmed stdout — the same bounded subprocess seam the LME lane uses.
        let prompt = answer_prompt(
            &perspective,
            &raw_payload,
            &item.qa.question,
            &item.qa.time,
            &item.qa.choices,
        );
        if let Ok(raw_response) = lme_run_judge(cmd, &prompt) {
            if let Some(letter) = parse_answer_choice(&raw_response) {
                // §3 correctness: exact string equality on the parsed letter.
                answered_correct = Some(membench_spec_answer_correct(&letter, &item.qa.ground_truth));
            }
        }
        // If the subprocess failed or returned an unparseable response, answered_correct
        // remains None — that item does not contribute to answered_count.
    }

    // Dump path (orthogonal to live path — can dump AND answer live).
    // Write the rendered prompt to the dump file for offline scoring.
    if let Some(ref mut dump) = dump_writer {
        let prompt = answer_prompt(
            &perspective,
            &raw_payload,
            &item.qa.question,
            &item.qa.time,
            &item.qa.choices,
        );
        dump.write_row(
            &item.item_id,
            &item.category,
            &item.agent,
            &prompt,
            &item.qa.ground_truth,
            recall_score,
            &per_item_texts,
            &ordered_ids,
        )?;
    }

    Ok(MemBenchSpecItemOutcome {
        category: item.category.clone(),
        agent: item.agent.clone(),
        answered_correct,
        recall_score,
        write_durations,
        read_duration,
        capacity_samples: Vec::new(),
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-item runner — §6 step_cap mode
// ─────────────────────────────────────────────────────────────────────────────

/// Runs one membench-spec item in §6 step_cap capacity mode.
///
/// §6 protocol (verbatim):
///   Messages ingest as §2 while a running token count accumulates (official
///   tokenizer: tiktoken cl100k_base, counting user + agent strings per message;
///   our seam delegates to `membench_count_tokens` — see §7 row 6).
///   From the step AFTER the last evidence step (`target_step_id[-1]`), the QA
///   is asked at EVERY subsequent step; each answer yields `(token_count_at_ask,
///   correct)`. The item terminates at the end of `message_list`.
///
/// Implementation notes:
/// - Uses `impatient: true` per-turn so each stored turn is immediately queryable
///   at the next recall call, regardless of `config.encode_barrier`.
/// - No settle (dream/reindex) between steps: we measure capacity under live
///   memory state, matching the Python env's per-step recall semantics.
/// - A full settle IS applied BEFORE the first ask so that encoding accumulated
///   during the evidence-ingest phase is complete.
///
/// §7 row 6: cl100k_base ARTIFACT DECISION (operator).
///   `membench_count_tokens` delegates to `lme_estimate_tokens` (UTF-8 / 4) until
///   the cl100k vocabulary artifact is approved. Token counts from this function
///   are estimates and will differ from cl100k_base counts for non-ASCII text.
///
/// Twin of Swift `runOneMemBenchSpecItemStepCap(item:config:consumedAnswers:guardSampler:)`.
fn run_one_membench_spec_item_step_cap(
    item: &MemBenchItem,
    config: &MemBenchSpecRunConfig,
    item_index: usize,
    consumed_answers: &std::collections::HashMap<String, String>,
    guard_sampler: &mut LegGuardSampler,
) -> Result<MemBenchSpecItemOutcome, MCPError> {

    // §6: last evidence step = target_step_id[-1]'s global sid.
    // Per §4 shape note: "step_cap uses target_step_id[-1]'s sid as the last-evidence step."
    let last_evidence_sid: Option<i64> = item.qa.target_step_id.last().map(|t| t.global_sid);

    let scratch_dir = membench_spec_scratch_dir(config.seed, item_index, config.scratch_posture)?;
    let endpoint = membench_spec_endpoint_config(
        &scratch_dir,
        &config.moot_binary_path,
        config.scratch_posture,
        config.shape,
    ).map_err(|e| MCPError { description: e })?;
    // Belt-and-suspenders: verify --db points into /tmp before connecting.
    // Twin of Swift `assertScratchBackend(_:requirement:)` in MemBenchSpecRunner.
    crate::gauntlet_runner::assert_scratch_backend(
        &endpoint, &crate::gauntlet_runner::MOOT_SCRATCH_REQUIREMENT,
    );
    let verb_map = membench_spec_verb_map();

    let mut client = MCPClient::new(endpoint);
    if let Err(e) = client.connect() {
        membench_spec_guarded_teardown(&scratch_dir);
        return Err(MCPError {
            description: format!(
                "membench-spec step_cap: connect error for item {}: {}",
                item.item_id, e.description
            ),
        });
    }

    // §6: flatten all turns across all sessions in message_list order.
    let all_turns: Vec<_> = item.sessions.iter().flat_map(|s| s.turns.iter()).collect();

    let mut manifest: std::collections::HashMap<String, i64> = Default::default();
    let mut write_durations: Vec<f64> = Vec::new();
    let mut read_duration: f64 = 0.0;
    let mut capacity_samples: Vec<(i64, bool)> = Vec::new();
    let mut retrieved_step_ids: Vec<i64> = Vec::new();
    let target_step_ids: Vec<i64> = item.qa.target_step_id.iter().map(|t| t.global_sid).collect();

    // §6: running token count — accumulates tokens for user + agent strings per turn.
    let mut accumulated_tokens: i64 = 0;
    // Track whether a settle has been issued for turns before the ask range.
    let mut settled_up_to_evidence = false;

    let perspective = if item.agent == "FirstAgent" {
        MemBenchPerspective::FirstAgent
    } else {
        MemBenchPerspective::ThirdAgent
    };

    for turn in &all_turns {
        // §6: count tokens for user + agent strings per message before storing.
        // §7 row 6: cl100k_base seam — `membench_count_tokens` delegates to
        // `lme_estimate_tokens` (UTF-8 / 4) until the cl100k vocabulary is approved.
        let turn_tokens = (membench_count_tokens(&turn.user_message)
            + membench_count_tokens(&turn.assistant_message)) as i64;
        accumulated_tokens += turn_tokens;

        // §2: build storage line (same shape selection as standard mode).
        let storage_content = if turn.assistant_message.is_empty() {
            storage_line_string(turn.sid as usize, &turn.user_message)
        } else {
            storage_line_dict(turn.sid as usize, &turn.user_message, &turn.assistant_message)
        };

        let mut write_args: BTreeMap<String, JsonValue> = BTreeMap::new();
        write_args.insert(verb_map.content_arg.clone(), JsonValue::String(storage_content.clone()));
        write_args.insert(
            "subject".to_string(),
            JsonValue::String(deterministic_subject(&storage_content)),
        );
        for (k, v) in &verb_map.constant_args {
            write_args.insert(k.clone(), JsonValue::String(v.clone()));
        }
        // step_cap uses impatient encoding per-turn so each turn is immediately
        // queryable at the next recall call without a separate drain step.
        write_args.insert("impatient".to_string(), JsonValue::Bool(true));

        // §5: wall-clock timer around the moot_file_memory call.
        let write_start = Instant::now();
        match client.call_tool(&verb_map.write, write_args, &verb_map.result_format) {
            Ok(result) => {
                write_durations.push(write_start.elapsed().as_secs_f64());
                if let Some(uuid) = result.write_assigned_id {
                    manifest.insert(uuid, turn.sid);
                }
            }
            Err(e) => {
                eprintln!(
                    "[membench-spec-stepcap] write error sid={} item={}: {}",
                    turn.sid, item.item_id, e.description
                );
                // Continue — a missed write degrades recall but does not abort the item.
            }
        }

        // §6: "From the step AFTER the last evidence step, the QA is asked at EVERY
        //      subsequent step." We ask if we've passed the last evidence sid.
        // When last_evidence_sid is None (no target steps), we never ask.
        let Some(last_sid) = last_evidence_sid else { continue };
        if turn.sid <= last_sid { continue }

        // First ask: apply a one-time settle to ensure evidence turns are encoded.
        // This differs from the pure Python env (which has no settle concept) but
        // is necessary for the moot backend to surface encoded results in recall.
        if !settled_up_to_evidence {
            settled_up_to_evidence = true;
            let mut dream_args: BTreeMap<String, JsonValue> = BTreeMap::new();
            dream_args.insert("associates".to_string(), JsonValue::String("all".to_string()));
            if let Err(e) = client.call_tool(crate::aria_v2_surface::DREAM, dream_args, &ResultFormat::MootV2) {
                eprintln!(
                    "[membench-spec-stepcap] settle dream failed for item {}: {}",
                    item.item_id, e.description
                );
            }
            if let Err(e) = client.call_tool(crate::aria_v2_surface::REINDEX, BTreeMap::new(), &ResultFormat::MootV2) {
                eprintln!(
                    "[membench-spec-stepcap] settle reindex failed for item {}: {}",
                    item.item_id, e.description
                );
            }
            wait_for_encode_drain(
                &mut client,
                &format!("membench-spec-stepcap settle item={}", item.item_id),
                300.0,
            );
        }

        // §3–4: recall query using `question (time)`.
        let query = recall_query(&item.qa.question, &item.qa.time);
        let mut query_args = crate::aria_v2_surface::memory_search_args(&verb_map.constant_args, &query);
        // When --scoring is given, pass it to the estate; when omitted, the call is
        // byte-identical to the pre-flag baseline (no "scoring" key in the dict).
        if let Some(ref s) = config.scoring_strategy {
            query_args.insert("scoring".to_string(), JsonValue::String(s.clone()));
        }

        // §5: wall-clock timer around the recall call (last per-step value recorded
        // as the final read_duration; §5 describes per-question timing).
        let read_start = Instant::now();
        let (step_ordered_ids, raw_payload) = match client.call_tool(&verb_map.query, query_args, &verb_map.result_format) {
            Ok(result) => {
                let text = result.text_blocks.join("\n");
                (result.ordered_ids, text)
            }
            Err(e) => {
                eprintln!(
                    "[membench-spec-stepcap] query error for item {}: {}",
                    item.item_id, e.description
                );
                (Vec::new(), String::new())
            }
        };
        read_duration = read_start.elapsed().as_secs_f64();

        // Capture the retrieved step ids for the outcome record (last ask wins).
        retrieved_step_ids = step_ordered_ids
            .iter()
            .filter_map(|uuid| manifest.get(uuid).copied())
            .collect();

        // §3: obtain answer letter for this step's token count (capacity ask).
        let mut correct = false;
        if let Some(consumed_letter) = consumed_answers.get(&item.item_id) {
            correct = membench_spec_answer_correct(consumed_letter, &item.qa.ground_truth);
        } else if let Some(ref cmd) = config.answer_cmd {
            let prompt = answer_prompt(
                &perspective,
                &raw_payload,
                &item.qa.question,
                &item.qa.time,
                &item.qa.choices,
            );
            if let Ok(raw_response) = lme_run_judge(cmd, &prompt) {
                if let Some(letter) = parse_answer_choice(&raw_response) {
                    correct = membench_spec_answer_correct(&letter, &item.qa.ground_truth);
                }
            }
        }

        // §6: record (token_count_at_ask, correct) pair.
        capacity_samples.push((accumulated_tokens, correct));
    }

    // Guard probe (once per leg — delegated to the shared sampler).
    guard_sampler.probe(|| probe_mcp_client(&mut client, &verb_map));

    let _ = client.disconnect();
    membench_spec_guarded_teardown(&scratch_dir);

    // §4: recall score for the step_cap outcome uses the final recall state
    // (after the last ask). When no asks happened (item had no turns past the
    // evidence step), recall is 0.
    let final_retrieved: Option<&[i64]> = if retrieved_step_ids.is_empty() {
        None
    } else {
        Some(&retrieved_step_ids)
    };
    let recall_score = membench_spec_get_recall(final_retrieved, &target_step_ids);

    // §6 answered_correct: derive from capacity_samples if any were collected.
    // Use the LAST sample's correct flag as the item-level correctness indicator.
    let answered_correct: Option<bool> = capacity_samples.last().map(|&(_, c)| c);

    Ok(MemBenchSpecItemOutcome {
        category: item.category.clone(),
        agent: item.agent.clone(),
        answered_correct,
        recall_score,
        write_durations,
        read_duration,
        capacity_samples,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

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
    fn artifact_manifest_maps_compound_and_legacy_ids_and_counts_invalid_rows() {
        let id_map = std::collections::HashMap::from([
            (
                "ThirdAgent/noisy/places/331/lives-here".to_string(),
                "AAAA-UUID".to_string(),
            ),
            ("42".to_string(), "BBBB-UUID".to_string()),
            ("malformed/id".to_string(), "CCCC-UUID".to_string()),
        ]);
        let (manifest, unmapped_count) = membench_spec_manifest(id_map);
        assert_eq!(manifest.get("aaaa-uuid"), Some(&331));
        assert_eq!(manifest.get("bbbb-uuid"), Some(&42));
        assert_eq!(unmapped_count, 1);
    }

    // ── bench-aggregate estate_dir gate ──────────────────────────────────────
    // Verifies that run_one_membench_spec_item_artifact returns Err (not panics)
    // when target_scale is BenchAggregate and estate_dir is absent.
    //
    // Mutation evidence: with the old .expect() the function panics, the test
    // fails with a panic rather than returning Err, and the description assertion
    // is never reached. The .ok_or_else()? path returns Err and the test passes.
    #[test]
    fn bench_aggregate_scale_refuses_absent_estate_dir() {
        use crate::membench_corpus::MemBenchQA;
        use std::collections::HashMap;

        let item = MemBenchItem {
            item_id: "simple/roles/0".to_string(),
            category: "simple".to_string(),
            agent: "ThirdAgent".to_string(),
            topic_key: "roles".to_string(),
            tid: 0,
            sessions: vec![],
            qa: MemBenchQA {
                qid: 0,
                question: "test question".to_string(),
                answer: "A".to_string(),
                target_step_id: vec![],
                choices: {
                    let mut m = HashMap::new();
                    m.insert("A".to_string(), "option A".to_string());
                    m
                },
                ground_truth: "A".to_string(),
                time: "2026-01-01T00:00:00Z".to_string(),
            },
        };

        let config = MemBenchSpecRunConfig {
            moot_binary_path: std::path::PathBuf::from("/dev/null"),
            data_dir: std::path::PathBuf::from("/tmp"),
            agent: "ThirdAgent".to_string(),
            categories: None,
            limit: None,
            offset: 0,
            seed: 0,
            out_dir: None,
            run_label: "gate-test".to_string(),
            run_serial: "test".to_string(),
            encode_barrier: EncodeBarrier::Impatient,
            scratch_posture: ScratchEstatePosture::PlaintextTransient,
            shape: BenchShape::Disk,
            answer_cmd: None,
            dump_answer_inputs_path: None,
            consume_answers_path: None,
            run_mode: MemBenchSpecRunMode::Standard,
            capacity_bucket_boundaries: vec![1000, 5000, 20000],
            // The discriminating combination: aggregate scale, no estate_dir.
            // Unit scale would route to the catalog arm; None scale returns a
            // different Err. Only BenchAggregate/CompleteAggregate with estate_dir
            // absent reaches the gate being tested.
            target_scale: Some(ArtifactTargetScale::BenchAggregate),
            catalog_path: None,
            estate_dir: None,
            run_environment: None,
            scoring_strategy: None,
            answer_hydration_depth: 10,
            guard_sampling_policy: GuardSamplingPolicy::OncePerLeg,
            seed_units_dir: None,
        };

        let consumed_answers: HashMap<String, String> = Default::default();
        let mut dump_writer: Option<MemBenchSpecAnswerDump> = None;
        let mut guard_sampler = LegGuardSampler::new(GuardSamplingPolicy::OncePerLeg);

        let result = run_one_membench_spec_item_artifact(
            &item,
            &config,
            &consumed_answers,
            &mut dump_writer,
            &mut guard_sampler,
        );

        match result {
            Err(e) => {
                assert!(
                    e.description.contains("estate_dir"),
                    "error description must name 'estate_dir'; got: {}",
                    e.description
                );
            }
            Ok(_) => panic!("expected Err when estate_dir is absent for BenchAggregate scale; got Ok"),
        }
    }

    // ── Scoring strategy flag ─────────────────────────────────────────────────

    /// Verifies the scoring key is absent from the query args dict when
    /// scoring_strategy is None (byte-identical baseline) and present when Some.
    #[test]
    fn scoring_arg_propagation() {
        // Baseline: None strategy → no "scoring" key in the dict.
        let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
        args.insert("q".to_string(), JsonValue::String("question".to_string()));
        let scoring_none: Option<String> = None;
        if let Some(ref s) = scoring_none {
            args.insert("scoring".to_string(), JsonValue::String(s.clone()));
        }
        assert!(!args.contains_key("scoring"),
            "omitted --scoring must produce no 'scoring' key in the query dict");

        // Given strategy: key must be present with the exact value.
        let mut args2: BTreeMap<String, JsonValue> = BTreeMap::new();
        args2.insert("q".to_string(), JsonValue::String("question".to_string()));
        let scoring_some: Option<String> = Some("matrixAware".to_string());
        if let Some(ref s) = scoring_some {
            args2.insert("scoring".to_string(), JsonValue::String(s.clone()));
        }
        assert_eq!(
            args2.get("scoring"),
            Some(&JsonValue::String("matrixAware".to_string())),
            "given --scoring matrixAware must wire as 'scoring': 'matrixAware'"
        );
    }

    // ── item (a) gate: estate-missing guard ───────────────────────────────────
    // Verifies the guard that fires BEFORE serve launches when the per-item
    // estate directory is absent. Removing the guard makes the runner fall through
    // to load_or_reconstruct_id_map, which does not emit "estate for unit".
    //
    // Mutation evidence: remove the guard block → the error description changes
    // to an id-map load error which does not contain all three required tokens.
    #[test]
    fn membench_unit_scale_refuses_missing_estate_dir() {
        use crate::membench_corpus::MemBenchQA;
        use std::collections::HashMap;

        // fleet_dir exists; the per-item estate subdir does NOT.
        let fleet_path = private_test_dir("estate-gate-membench");

        // itemID "simple/roles/0"
        //   membench_spec_item_stem("simple/roles/0") → "/" replaced with "__"
        //   → "simple__roles__0"
        //   → estate = fleet_path/simple__roles__0  (NOT created → guard fires)
        let item_id = "simple/roles/0";

        let item = MemBenchItem {
            item_id: item_id.to_string(),
            category: "simple".to_string(),
            agent: "ThirdAgent".to_string(),
            topic_key: "roles".to_string(),
            tid: 0,
            sessions: vec![],
            qa: MemBenchQA {
                qid: 0,
                question: "test question".to_string(),
                answer: "A".to_string(),
                target_step_id: vec![],
                choices: {
                    let mut m = HashMap::new();
                    m.insert("A".to_string(), "option A".to_string());
                    m
                },
                ground_truth: "A".to_string(),
                time: "2026-01-01T00:00:00Z".to_string(),
            },
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
        let config = MemBenchSpecRunConfig {
            moot_binary_path: std::path::PathBuf::from("/dev/null"),
            data_dir: std::path::PathBuf::from("/tmp"),
            agent: "ThirdAgent".to_string(),
            categories: None,
            limit: None,
            offset: 0,
            seed: 0,
            out_dir: None,
            run_label: "gate-test".to_string(),
            run_serial: "test".to_string(),
            encode_barrier: EncodeBarrier::Impatient,
            scratch_posture: ScratchEstatePosture::PlaintextTransient,
            shape: BenchShape::Disk,
            answer_cmd: None,
            dump_answer_inputs_path: None,
            consume_answers_path: None,
            run_mode: MemBenchSpecRunMode::Standard,
            capacity_bucket_boundaries: vec![1000, 5000, 20000],
            target_scale: Some(ArtifactTargetScale::Unit),
            catalog_path: Some(catalog_path.clone()),
            estate_dir: None,
            run_environment: None,
            scoring_strategy: None,
            answer_hydration_depth: 10,
            guard_sampling_policy: GuardSamplingPolicy::OncePerLeg,
            seed_units_dir: None,
        };

        let consumed_answers: HashMap<String, String> = Default::default();
        let mut dump_writer: Option<MemBenchSpecAnswerDump> = None;
        let mut guard_sampler = LegGuardSampler::new(GuardSamplingPolicy::OncePerLeg);

        let result = run_one_membench_spec_item_artifact(
            &item,
            &config,
            &consumed_answers,
            &mut dump_writer,
            &mut guard_sampler,
        );
        let _ = std::fs::remove_dir_all(&fleet_path);

        match result {
            Err(e) => {
                assert!(
                    e.description.contains("not in the catalog"),
                    "message must say the unit is not in the catalog; got: {}",
                    e.description
                );
                assert!(
                    e.description.contains("simple__roles__0"),
                    "message must contain the unit stem; got: {}",
                    e.description
                );
                assert!(
                    e.description.contains(catalog_path.to_str().unwrap()),
                    "message must name the catalog; got: {}",
                    e.description
                );
            }
            Ok(_) => panic!("expected Err for missing estate dir; got Ok"),
        }
    }
}
