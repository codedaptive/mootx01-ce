//! longmemeval_runner.rs — live harness driving mootx01 for LongMemEval benchmarking.
//!
//! Rust twin of `LongMemEvalRunner.swift`. Mirrors the Swift per-question loop:
//! create an isolated scratch dir → launch mootx01 pointing at it → ingest all
//! haystack turns → run degeneracy probe → query the actual question → teardown.
//!
//! Each question gets a dedicated mootx01 process so the haystack is fresh per
//! question — same isolation guarantee as the Swift runner.
//!
//! # Layout
//!
//! `run_lme_questions(questions, config)` is the main entry point. Callers
//! (main.rs) load the corpus, shuffle it with `SplitMix64`, slice to `limit`,
//! then pass the slice here.

use crate::config::{EndpointConfig, EndpointRole, Transport, VerbMap};
use crate::config::ResultFormat;
use crate::degeneracy_guard::LegGuardSampler;
use crate::encode_barrier::{EncodeBarrier, wait_for_encode_drain};
use crate::scratch_posture::{moot_serve_command, LaneError, ScratchEstatePosture};
use crate::estate_cache::{
    estate_cache_entry_path, restore_estate_cache_entry, EstateCacheMode,
};
use crate::json_value::JsonValue;
use crate::longmemeval_corpus::LmeCorpus;
/// Default judge-payload hydration depth when `--judge-hydration-depth` is
/// not given. Ten covers recall@10, the deepest cut-off the lane scores.
/// Twin of Swift `lmeDefaultJudgePayloadHydrationDepth`.
pub const LME_DEFAULT_JUDGE_PAYLOAD_HYDRATION_DEPTH: usize = 10;

use crate::longmemeval_judge::{
    lme_grade_judge_answer, lme_judge_prompt, lme_parse_verdict, lme_run_judge,
    lme_verdict_prompt, LmeJudgeGrading,
};
use crate::longmemeval_scorer::{LmeManifestEntry, LmeQuestionResult};
use crate::reranker::apply_rerank;
use crate::mcp_client::{MCPClient, MCPError, ToolCaller};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Instant;

// ─────────────────────────────────────────────────────────────────────────────
// Recall arm
// ─────────────────────────────────────────────────────────────────────────────

/// Which recall arm(s) the LME token-efficiency benchmark exercises.
/// Twin of Swift `LMEArm`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LmeArm {
    /// Only the exact-recall arm — `moot_memory_search` with full content payload.
    Exact,
    /// Only the dense-recall arm — `moot_recall_distilled` with distilled factoid payload.
    Dense,
    /// Both arms per question, same estate, same ingest (default).
    Both,
}

// ─────────────────────────────────────────────────────────────────────────────
// Run configuration
// ─────────────────────────────────────────────────────────────────────────────

/// Configuration for one LME run.  Constructed by main.rs from CLI flags.

/// How the exact arm drives the recall surface. Twin of Swift
/// `ExactRecallStrategy`. `Auto` (default) follows the program's documented
/// client protocol: relevance-ordered search, escalating to
/// moot_recall_precise when the response reports "discrimination: low".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExactRecallStrategy {
    Search,
    Relevance,
    Precise,
    Auto,
    /// `moot_recall_shaped` — the signed-weight fusion engine, steered by a
    /// RecallShape preset (`--recall-shape`). Twin of Swift `.shaped`.
    Shaped,
}

impl ExactRecallStrategy {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "search" => Some(Self::Search),
            "relevance" => Some(Self::Relevance),
            "precise" => Some(Self::Precise),
            "auto" => Some(Self::Auto),
            "shaped" => Some(Self::Shaped),
            _ => None,
        }
    }
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Search => "search",
            Self::Relevance => "relevance",
            Self::Precise => "precise",
            Self::Auto => "auto",
            Self::Shaped => "shaped",
        }
    }
}

/// Ingest granularity: what one filed document is. Used by the locomo-spec
/// lane, whose seeding is methodology-defining (its `--granularity` flag
/// selects the estate shape). Twin of Swift `IngestGranularity`. THE TWO
/// CELLS ARE NOT COMPARABLE: ranking among tens of thousands of turns and
/// ranking among tens of session documents are different tasks, so every
/// published cell names its granularity.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IngestGranularity {
    /// One document per conversational turn (this harness's original shape).
    Turn,
    /// One document per session — all of a session's turns joined into a
    /// single document ("role: content" lines; the field convention).
    Session,
}

impl IngestGranularity {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "turn" => Some(Self::Turn),
            "session" => Some(Self::Session),
            _ => None,
        }
    }
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Turn => "turn",
            Self::Session => "session",
        }
    }
}

/// The `moot_recall_shaped` preset roster. Each steers the fusion
/// differently — which one wins is an empirical question the ablation lane
/// answers. Twin of Swift `lmeRecallShapePresets`.
pub const LME_RECALL_SHAPE_PRESETS: [&str; 20] = [
    "balanced", "precise", "conceptual", "broad", "lexical", "not_lexical",
    "associative", "consensus", "ri_forward", "ppmi_forward", "lsa_forward",
    "nmf_forward", "fast", "structural", "temporal", "connection", "field",
    "preference", "anti_redundant", "session_hybrid",
];

/// Backend shape for the scratch estate. C1.
///
/// `Disk` (default): standard SQLite-backed PersistenceKit estate.
/// `Ram`: appends `--in-memory` to the mootx01 serve command, selecting
/// PersistenceKit's InMemory backend. Faster but volatile — the
/// estate vanishes on server exit. Incompatible with `--estate-cache reuse`
/// or `require` (rejected at parse time: no snapshot to restore).
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LmeShape {
    Disk,
    Ram,
}

impl Default for LmeShape {
    fn default() -> Self { LmeShape::Disk }
}

impl LmeShape {
    /// Convert to the raw string used in report JSON and CLI.
    pub fn as_str(&self) -> &'static str {
        match self { LmeShape::Disk => "disk", LmeShape::Ram => "ram" }
    }
}

pub struct LmeRunConfig {
    pub moot_binary: String,
    pub variant: String,
    pub seed: u64,
    pub limit: Option<usize>,
    pub label: Option<String>,
    pub out_dir: Option<PathBuf>,
    /// Which recall arm(s) to benchmark. Default LmeArm::Both.
    pub arm: LmeArm,
    /// Optional judge command for LLM-judged QA mode.
    /// When set, the harness runs the command subprocess per arm per question
    /// (prompt on stdin, answer on stdout) and grades against the gold answer.
    /// Off by default (None).
    pub judge_cmd: Option<String>,
    /// How judge answers are graded. `Substring` is deterministic and free;
    /// `Verdict` spends a second judge call per answer and matches the protocol
    /// published leaderboard numbers use. Recorded in the report — the two
    /// modes are not comparable to each other.
    pub judge_grading: LmeJudgeGrading,
    /// How many ranked hits are hydrated to full content for the judge.
    ///
    /// THIS PARAMETER MOVES THE ACCURACY NUMBER and must be recorded in any
    /// judged cell: recall is scored over SESSIONS while the judge reads
    /// DRAWERS, so a session scores a hit as soon as any of its turns ranks
    /// while the answer-bearing turn can sit far deeper.
    pub judge_hydration_depth: usize,
    /// Encode-queue synchronization strategy. Default EncodeBarrier::Drain.
    /// Controls how the harness waits for background encoding to complete before
    /// issuing recall queries — prevents background-encoding races from producing
    /// artificially low recall scores.
    pub encode_barrier: EncodeBarrier,
    /// Estate snapshot reuse mode. Default EstateCacheMode::Off.
    pub estate_cache: EstateCacheMode,
    /// Exact-arm retrieval strategy (--exact-strategy). See ExactRecallStrategy.
    pub exact_strategy: ExactRecallStrategy,
    /// RecallShape preset for `--exact-strategy shaped`. None uses the
    /// product default preset. Twin of Swift `LMERunConfig.recallShape`.
    pub recall_shape: Option<String>,
    /// Cache root directory. None = <out-dir>/estate-cache (or <cwd>/estate-cache).
    pub cache_dir: Option<PathBuf>,
    /// At-rest posture for scratch estates. Default PlaintextTransient: the
    /// transient record is plaintext (no keychain contact). --estate-mode encrypted selects
    /// EncryptedEphemeral (temporal in-process key). Recorded in the report
    /// JSON as "estate_encryption".
    pub scratch_posture: ScratchEstatePosture,
    /// When true, run each question twice: first as the ORGANIC cell (immediately
    /// after ingest + drain barrier), then trigger moot_reindex, wait for the
    /// corpus_encode drain to converge, and re-run identical queries as the
    /// SETTLED cell. Off by default. Twin of Swift LMERunConfig.settle.
    pub settle: bool,
    // MARK: Rerank (additive — W2-rerank)
    /// Optional command for post-retrieval reranking. When set, the top
    /// `RERANK_WINDOW_SIZE` hits from the exact arm are handed to this command
    /// before scoring. Mirrors `judge_cmd`: reads a numbered prompt on stdin,
    /// writes a permutation of candidate numbers on stdout (exit 0).
    ///
    /// PRESENCE ONLY in the report (`rerank_cmd_set`). Never log, hash, or
    /// derive any value from this field — it may carry API keys.
    pub rerank_cmd: Option<String>,
    // MARK: Synthesize arm (PR-08 D3)
    /// When true, run `moot_synthesize` per question as a fourth answer-payload
    /// mode beside preview / distilled / full-hydrated. Additive — does not
    /// affect retrieval scoring. Off by default. Twin of Swift
    /// `LMERunConfig.synthesizeArm`.
    pub synthesize_arm: bool,
    /// Partition of the seeded-shuffled question list (`--slice`). Applied
    /// AFTER the Fisher-Yates shuffle and BEFORE the limit, so
    /// `--slice dev --limit 10` returns the first 10 questions of the 50-question
    /// dev half — it does not take 10 from the full set and then filter.
    ///
    /// Accepted values:
    ///   `Some("dev")`     — first 50 shuffled questions (historical tuning slice)
    ///   `Some("holdout")` — everything after the first 50 shuffled questions
    ///   `None`            — full shuffled set (default, today's behaviour)
    ///
    /// The boundary is hard-coded at 50 (`LME_DEV_SLICE_SIZE`). Twin of Swift
    /// `LMERunConfig.slice`. Recorded in every run_parameters block.
    pub slice: Option<String>,
    /// --ids: pinned debug-subset unit IDs (None = whole corpus). Validated
    /// against the loaded corpus at the CLI layer before the runner is invoked.
    pub unit_ids: Option<std::collections::HashSet<String>>,
    /// Optional retrieval-call override (environment seam; twin of Swift
    /// RetrievalCallSpec). None = the verb map's standard query.
    pub retrieval_call: Option<crate::retrieval_call_spec::RetrievalCallSpec>,
    /// Payload-economics shape-variant arm (--payload-arm /
    /// MOOT_BENCH_PAYLOAD_ARM; twin of Swift `payloadArm`). Applied to the
    /// seam-routed result's text_blocks so judged-output row text carries
    /// the arm's field subset. None = full ruled payload.
    pub payload_arm: Option<crate::payload_arm::PayloadArm>,
    /// Seed-path namespace of the artifacts this run restores (`--seed-path`,
    /// default batch). Addresses the estate-cache key's `seedpath_` segment
    /// only — a batch-built and a live-built estate are different estate
    /// shapes and live in different cache namespaces.
    /// Twin of Swift `LMERunConfig.seedPath`.
    pub seed_path: crate::seed_export::SeedPathMode,
    /// Path to write the pre-judge JSONL dump (`--dump-judge-inputs`).
    /// When set, a header line is written before the question loop and one
    /// question line per question after payload hydration. The file can then
    /// be post-processed offline with `judge-batch` — no estate or mootx01
    /// binary is required. Twin of Swift `LMERunConfig.dumpJudgeInputsPath`.
    pub dump_judge_inputs_path: Option<String>,
    /// Guard probe sampling policy for this leg. Default `OncePerLeg` probes on the
    /// first question only. Use `PerUnit` only for debugging.
    /// Twin of Swift `LMERunConfig.guardSamplingPolicy`.
    pub guard_sampling_policy: crate::degeneracy_guard::GuardSamplingPolicy,
    /// SHA-256 of the corpus fixture (B2 provenance). Computed once at
    /// main.rs load time; "unknown" never validates.
    pub corpus_digest: String,
    /// Backend shape for the scratch estate. `Disk` (default) = standard
    /// SQLite estate; `Ram` = PersistenceKit InMemory backend. C1.
    /// Rejected at parse time when combined with estate_cache Reuse or Require.
    pub shape: LmeShape,
    /// Maximum number of questions to run concurrently (fresh-per-question only).
    /// 1 = serial (default when not specified). The shared-estate path always
    /// runs serially — it shares one estate across all questions. C6.
    /// Default: max(1, 80% of logical cores).
    pub parallel_units: usize,
}

// ─────────────────────────────────────────────────────────────────────────────
// SplitMix64 — reproducible shuffle (twin of `GauntletRNG.swift`)
// ─────────────────────────────────────────────────────────────────────────────

/// A SplitMix64 PRNG. Implements exactly the same algorithm as Swift
/// `GauntletRNG` — same seed → same shuffle order on both legs.
///
/// Algorithm: state += 0x9E3779B97F4A7C15; two mixing rounds; `next_upto` uses
/// multiply-high ((draw * bound) >> 64) for unbiased bounded draws.
pub struct SplitMix64 {
    state: u64,
}

impl SplitMix64 {
    /// Create a generator seeded at `seed`. Twin of Swift `GauntletRNG(seed:)`.
    pub fn new(seed: u64) -> Self {
        SplitMix64 { state: seed }
    }

    /// Returns the next pseudo-random u64. Twin of Swift `GauntletRNG.next()`.
    pub fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }

    /// Returns a value in `[0, bound)` via multiply-high. Twin of Swift
    /// `GauntletRNG.next(upTo:)`.
    pub fn next_upto(&mut self, bound: u64) -> u64 {
        if bound == 0 {
            return 0;
        }
        let draw = self.next_u64();
        ((draw as u128 * bound as u128) >> 64) as u64
    }

    /// Fisher-Yates in-place shuffle. Twin of Swift `GauntletRNG.shuffled(_:)`.
    pub fn shuffle<T>(&mut self, items: &mut [T]) {
        let n = items.len();
        for i in (1..n).rev() {
            let j = self.next_upto((i + 1) as u64) as usize;
            items.swap(i, j);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Verb map for LME
// ─────────────────────────────────────────────────────────────────────────────

/// Returns the VerbMap for the LME harness.
///
/// `location: "benchmarks/longmemeval"` is the write constant — all haystack
/// memories are filed in the benchmark wing so they are isolated from
/// the operator's real memories and from other benchmark runs.
pub fn lme_verb_map() -> VerbMap {
    let mut constant_args = BTreeMap::new();
    constant_args.insert("location".to_string(), "benchmarks/longmemeval".to_string());
    VerbMap::new(
        crate::aria_v2_surface::FILE_MEMORY,
        crate::aria_v2_surface::MEMORY_SEARCH,
        None,                                 // list: not used in LME
        None,                                 // fetch: not used in LME
        None,                                 // content_arg: defaults to "content"
        None,                                 // query_arg: defaults to "query"
        Some(constant_args),
        Some(ResultFormat::MootV2),
    )
}

/// Returns the VerbMap for the dense recall arm of the LME token-efficiency benchmark.
///
/// Uses `moot_recall_distilled`, which:
///   - Returns distilled prose per hit (token-economical representation)
///   - Does NOT use a location constant arg (queries the estate-default wing)
///   - v2: no `ack` argument — the gate was removed in v2
///
/// Twin of Swift `lmeDenseMootVerbMap`.
pub fn lme_dense_verb_map() -> VerbMap {
    VerbMap::new(
        crate::aria_v2_surface::FILE_MEMORY,       // same ingest tool
        crate::aria_v2_surface::RECALL_DISTILLED,  // dense query tool
        None,                     // list: not used
        None,                     // fetch: not used
        None,                     // content_arg: defaults to "content"
        None,                     // query_arg: defaults to "query"
        // v2 has no ack gate on moot_recall_distilled — empty constant args
        Some(BTreeMap::new()),
        Some(ResultFormat::MootV2),
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// Scratch dir management
// ─────────────────────────────────────────────────────────────────────────────

/// Creates a fresh, isolated scratch directory for one question's mootx01 instance.
/// Path: `/tmp/lme-bench-<seed_hex>-<question_index_hex>`.
///
/// The deterministic naming ensures each question has a unique path even across
/// retries, and the fixed prefix enables guarded teardown.
///
/// `posture` decides the at-rest encryption of the estate this dir will hold
/// and rides on the serve command (see scratch_posture.rs). No default value on
/// purpose: every call site decides posture explicitly.
pub fn lme_scratch_dir(
    seed: u64,
    question_index: usize,
    posture: ScratchEstatePosture,
) -> Result<PathBuf, MCPError> {
    let name = format!("lme-bench-{seed:016x}-{question_index:08x}");
    let path = PathBuf::from("/tmp").join(&name);
    std::fs::create_dir_all(&path).map_err(|e| MCPError {
        description: format!("failed to create scratch dir {}: {e}", path.display()),
    })?;
    // The posture is the record's: a transient record is plaintext by rule.
    let _ = posture;
    Ok(path)
}

/// Removes a scratch directory.
///
/// Guard: path must begin with `/tmp/lme-bench-` (the prefix assigned in
/// `lme_scratch_dir`). Any other prefix is refused — this prevents a misconfigured
/// path from deleting real data.
pub fn lme_guarded_teardown(path: &Path) -> Result<(), MCPError> {
    let path_str = path.to_string_lossy();
    if !path_str.starts_with("/tmp/lme-bench-") {
        return Err(MCPError {
            description: format!(
                "teardown refused: path does not begin with /tmp/lme-bench-: {}",
                path.display()
            ),
        });
    }
    if path.exists() {
        std::fs::remove_dir_all(path).map_err(|e| MCPError {
            description: format!("teardown failed for {}: {e}", path.display()),
        })?;
    }
    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────
// Endpoint config construction
// ─────────────────────────────────────────────────────────────────────────────

/// Builds an `EndpointConfig` for the LME harness pointing at `scratch_dir`.
///
/// The command form is `[KEY=VALUE …] <binary> serve --db <scratch_dir>`.
/// `MCPClient` splits on whitespace and runs via `/usr/bin/env`, which handles
/// `KEY=VALUE` prefix tokens natively.
///
/// - `bench_clock_epoch`: When `Some(iso8601)`, prepends
///   `MOOT_BENCH_EPOCH_NOW=<iso8601>` to the serve command so the product
///   server pins its clock for the duration of the run. Used in replay lanes
///   (same seed → same `filedAt` stamps and temporal scores). `None` →
///   wall-clock (all non-replay lanes). Twin of Swift `lmeEndpointConfig`
///   `benchClockEpoch` parameter.
pub fn lme_endpoint_config(
    scratch_dir: &Path,
    moot_binary: &str,
    posture: ScratchEstatePosture,
    shape: LmeShape,
    bench_clock_epoch: Option<&str>,
) -> Result<EndpointConfig, String> {
    // The posture is the record's: a transient record is plaintext by rule.
    let _ = posture;
    let data_dir = scratch_dir.to_string_lossy();
    // Build env token list: optional epoch pin first (consumed at server
    // startup), then the standard pair (MOOTX01_VAULT=1, MOOTX01_SUBJECT_RIDER=0).
    let epoch_token: String;
    let mut env: Vec<&str> = Vec::new();
    if let Some(epoch) = bench_clock_epoch {
        epoch_token = format!("{}={}", crate::scratch_posture::MOOT_BENCH_EPOCH_NOW_ENV_KEY, epoch);
        env.push(epoch_token.as_str());
    }
    env.extend_from_slice(crate::scratch_posture::SCRATCH_SERVE_ENV);
    let command = moot_serve_command(moot_binary, Path::new(&*data_dir), shape == LmeShape::Ram, &env, None)
        .map_err(|e| e.to_string())?;
    // Belt-and-suspenders: assert_scratch_backend verifies the scratch constraint
    // (--db must point at /tmp) immediately after the command is assembled.
    // Covers every caller of lme_endpoint_config (supersession, journey, fact_layer
    // replay). Timing and posture-equivalence lanes do NOT route through this
    // function; they call their own endpoint builders which contain their own
    // assert_scratch_backend calls.
    // Twin placement of Swift `assertScratchBackend` inside `lmeEndpointConfig`.
    let endpoint = EndpointConfig {
        name: "mootx01-lme".to_string(),
        transport: Transport::Stdio { command },
        auth: None,
        verb_map: lme_verb_map(),
        role: EndpointRole::Both,
    };
    crate::gauntlet_runner::assert_scratch_backend(
        &endpoint, &crate::gauntlet_runner::MOOT_SCRATCH_REQUIREMENT,
    );
    Ok(endpoint)
}

// ─────────────────────────────────────────────────────────────────────────────
// Probe queries
// ─────────────────────────────────────────────────────────────────────────────

/// Three semantically distinct probe queries for degeneracy guard check.
/// The three topics should produce different rankings on a functional search
/// engine. If all three return the same UUID ordering, the guard fires.
const PROBE_QUERIES: [&str; 3] = [
    "what happened during our recent dinner together?",
    "can you remind me about my work project updates?",
    "what were we discussing about travel plans last month?",
];

/// Issues the three probe queries against a connected MCP client and returns
/// the UUID-ranked response for each. The ordering of the returned vec matches
/// the ordering of `PROBE_QUERIES`.
///
/// Failures (MCP errors on individual probes) are silently replaced with empty
/// rankings — the degeneracy guard treats fewer than 2 probe responses as
/// Healthy, so a connectivity failure here does not fabricate a false positive.
pub fn probe_mcp_client(client: &mut MCPClient, verb_map: &VerbMap) -> Vec<Vec<String>> {
    PROBE_QUERIES
        .iter()
        .map(|&q| {
            let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
            args.insert(
                verb_map.query_arg.clone(),
                JsonValue::String(q.to_string()),
            );
            match client.call_tool(&verb_map.query, args, &verb_map.result_format) {
                Ok(result) => result.ordered_ids,
                Err(_) => vec![],
            }
        })
        .collect()
}

// ─────────────────────────────────────────────────────────────────────────────
// Binary discovery
// ─────────────────────────────────────────────────────────────────────────────

/// Finds the mootx01 binary.
///
/// Discovery order (matches Swift `LongMemEvalRunner.discoverMootBinary()`):
///   1. `$MOOTX01_BINARY` env var
///   2. `$HOME/.mootx01/bin/mootx01` (the per-user install location)
///   3. `which mootx01` (PATH)
pub fn discover_moot_binary() -> Option<String> {
    // ISOLATION RULE ( operator ruling 2026-08-18): measurement never uses the installed
    // binary — it builds one from the CURRENT TREE and uses it in 100%
    // isolation. The old order here (env → installed ~/.mootx01/bin → PATH)
    // silently substituted a stale product for the tree under test (found by
    // the locomo-spec smoke: a pre-return_id_map install shadowed the fresh
    // tree build). Discovery now honors the explicit MOOTX01_BINARY override
    // and then looks ONLY at this repo's own build products, release before
    // debug; anything else must be passed via --binary (or built by
    // `make moot-binary`). Twin of Swift `discoverMootBinary`.
    if let Ok(path) = std::env::var("MOOTX01_BINARY") {
        if !path.is_empty() {
            return Some(path);
        }
    }
    // This repo's product build (harness cwd is benchmarks/rust or benchmarks/).
    for candidate in [
        "../../apps/mootx01/.build/release/mootx01",
        "../../apps/mootx01/.build/debug/mootx01",
        "../apps/mootx01/.build/release/mootx01",
        "../apps/mootx01/.build/debug/mootx01",
    ] {
        if std::path::Path::new(candidate).exists() {
            return Some(candidate.to_string());
        }
    }
    None
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-question run
// ─────────────────────────────────────────────────────────────────────────────

/// Runs the LME harness for a single question: restore the prebuilt estate →
/// launch mootx01 → probe → query (exact/dense arms) → teardown.
///
/// This lane MEASURES prebuilt artifacts only. Artifact building is owned by
/// the seeding pipeline (`benchmarks/seeding/`, BENCHMARK_ESTATES.md §9); a
/// missing artifact is a hard error.
///
/// Returns `Err` for unrecoverable setup failures (missing artifact, scratch
/// dir, binary launch). Guard failures are encoded as
/// `LmeQuestionResult.guard_healthy=false`.
#[allow(clippy::too_many_arguments)]
pub fn run_one_question(
    question_id: &str,
    question_type: &str,
    question_text: &str,
    gold_answer: &str,
    answer_session_ids: &[String],
    moot_binary: &str,
    seed: u64,
    question_index: usize,
    arm: &LmeArm,
    judge_cmd: Option<&str>,
    judge_grading: LmeJudgeGrading,
    judge_hydration_depth: usize,
    cache_entry: Option<&Path>,
    scratch_posture: ScratchEstatePosture,
    strategy: ExactRecallStrategy,
    recall_shape: Option<&str>,
    // Environment seam: optional retrieval-call override for the default
    // (search/relevance/auto) path; named shaped/precise stay explicit.
    retrieval_call: Option<&crate::retrieval_call_spec::RetrievalCallSpec>,
    // Payload-economics shape-variant arm; strips seam-result text_blocks.
    payload_arm: Option<crate::payload_arm::PayloadArm>,
    settle: bool,
    // Post-retrieval rerank command. When Some, the top RERANK_WINDOW_SIZE
    // exact-arm hits are handed to this command before scoring. Presence only
    // in the report — may carry API keys; never log or derive from it.
    rerank_cmd: Option<&str>,
    // Path to the pre-judge JSONL dump file. When Some, one question line is
    // appended after hydration with both arm payloads and their token counts.
    dump_judge_inputs_path: Option<&str>,
    // Leg-level guard sampler: shared across all questions in a run.
    // Enforces `GuardSamplingPolicy` — probes on the first question only (default)
    // or on every question (debugging). Wrapped in Mutex so it can be safely shared
    // across concurrent threads in the C6 parallel path (serial path locks once per call).
    sampler: &std::sync::Mutex<LegGuardSampler>,
    // C1: backend shape for the scratch estate (disk = SQLite, ram = InMemory).
    shape: LmeShape,
    // B2: the run's expected provenance — validated hard on artifact restore.
    run_provenance: &crate::artifact_manifest::ArtifactProvenance,
) -> Result<(LmeQuestionResult, bool), LaneError> {
    // ── Artifact restore (the only provisioning path) ─────────────────────────
    // Restore the prebuilt, settled estate for this question. The posture
    // marker travels with the snapshot; restore asserts it matches. A missing
    // entry or a restore miss is a hard error — this lane never builds.
    let cache_restore: Option<(PathBuf, Vec<LmeManifestEntry>)> = match cache_entry {
        Some(entry) => restore_estate_cache_entry(entry, run_provenance, || {
            lme_scratch_dir(seed, question_index, scratch_posture)
                .map_err(|e| e.description.clone())
        })
        // B2 provenance mismatch is a HARD FAIL — propagate; never silently
        // accept a unit whose artifact declares different inputs.
        .map_err(|e| LaneError::Unit(e))?,
        None => None,
    };

    let (scratch, manifest): (PathBuf, Vec<LmeManifestEntry>) = match cache_restore {
        Some((s, m)) => (s, m),
        None => {
            return Err(LaneError::Unit(match cache_entry {
                Some(entry) => crate::estate_cache::artifact_required_error(entry),
                None => "the longmemeval lane measures prebuilt artifacts and has \
                         no build path; run with --estate-cache require"
                    .to_string(),
            }));
        }
    };
    let cache_hit: Option<bool> = Some(true);
    let verb_map = lme_verb_map();
    // assert_scratch_backend is now called inside lme_endpoint_config itself,
    // so it covers run_replay and every other caller automatically.
    // A path/posture configuration failure is fatal for the whole lane (LaneError::Config).
    let endpoint = lme_endpoint_config(&scratch, moot_binary, scratch_posture, shape, None)
        .map_err(|e| LaneError::Config(format!("{e}")))?;

    let mut client = MCPClient::new(endpoint);
    client.connect().map_err(|e| {
        // Teardown best-effort; original connect error is the useful signal.
        let _ = crate::key_residue::retire_scratch_estate(&scratch, lme_guarded_teardown);
        LaneError::Unit(e.description)
    })?;

    // ── Ingested-turn accounting from the restored manifest ──────────────────
    // The estate arrives fully ingested and settled (drain → dream → basis
    // retrain happen at artifact build time in the seeding pipeline), so there
    // is no write phase here: write latency is 0 and no drain barrier runs.
    let turns_ingested: usize = manifest.len();
    let write_mean_latency: f64 = 0.0;
    let drain_lane_observed: Option<bool> = None;

    // ── Probe for degeneracy guard ────────────────────────────────────────────
    // Guard probes always use the exact verbMap (moot_memory_search) regardless of arm —
    // the guard verifies estate health, not arm-specific retrieval quality.
    // Delegated to the leg sampler: probes on the first question only (OncePerLeg
    // default); caches the verdict for all subsequent questions at zero MCP cost.
    // The sampler is behind a Mutex so the parallel path (C6) can share it safely
    // across threads; the lock is held only for the duration of the probe call.
    let (guard_healthy, guard_diagnostic, _was_probed) = {
        let mut s = sampler.lock().expect("sampler mutex poisoned");
        s.probe(|| probe_mcp_client(&mut client, &verb_map))
    };

    // ── Exact arm: moot_memory_search ─────────────────────────────────────────
    // ORDER IS LOAD-BEARING: the exact-arm query MUST run before any
    // moot_distill call. Distillation
    // writes on-row representations, after which the originals no longer surface
    // in default search (proven 2026-07-27: LME q1 answer rank 2 pre-distill,
    // absent from top-20 post-distill). Distilling first contaminated the
    // exact-arm measurement on two full grids. Twin of the Swift ordering note.
    let mut exact_payload_text: Option<String> = None;
    let mut exact_query_latency: Option<f64> = None;
    let mut retrieved_uuids: Vec<String> = Vec::new();
    // Individual text blocks parallel to retrieved_uuids — used as rerank previews.
    let mut exact_text_blocks: Vec<String> = Vec::new();
    // Set to true if the rerank command fails or produces an unparseable reply.
    let mut rerank_failed = false;
    if arm == &LmeArm::Exact || arm == &LmeArm::Both {
        let query_start = Instant::now();
        if guard_healthy {
            let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
            args.insert(
                verb_map.query_arg.clone(),
                JsonValue::String(question_text.to_string()),
            );
            // No constant_args for moot_memory_search in LME mode (location is already
            // set on the ingest constant_args, not the query).
            // Strategy per the program's documented client protocol (twin of the
            // Swift strategy comment): relevance ordering by default, escalate to
            // moot_recall_precise on "discrimination: low", or call precise directly.
            if strategy == ExactRecallStrategy::Relevance || strategy == ExactRecallStrategy::Auto {
                // v2: `ordering` arg removed from moot_memory_search; v2 defaults to byRelevanceDesc.
            }
            if strategy == ExactRecallStrategy::Shaped {
                // moot_recall_shaped: the signed-weight fusion engine. The
                // preset (when given) selects the RecallShape; without one
                // the product default applies. Twin of the Swift shaped
                // branch.
                let mut sargs: BTreeMap<String, JsonValue> = BTreeMap::new();
                sargs.insert(verb_map.query_arg.clone(), JsonValue::String(question_text.to_string()));
                if let Some(shape) = recall_shape {
                    sargs.insert("preset".to_string(), JsonValue::String(shape.to_string()));
                }
                match client.call_tool(crate::aria_v2_surface::RECALL_SHAPED, sargs, &verb_map.result_format) {
                    Ok(result) => {
                        retrieved_uuids = result.ordered_ids.clone();
                        exact_text_blocks = result.text_blocks.clone();
                        exact_payload_text = if result.text_blocks.is_empty() { None } else { Some(result.text_blocks.join("\n")) };
                    }
                    Err(e) => eprintln!("  [lme] shaped query error for {question_id}: {}", e.description),
                }
            } else if strategy == ExactRecallStrategy::Precise {
                let mut pargs: BTreeMap<String, JsonValue> = BTreeMap::new();
                pargs.insert(verb_map.query_arg.clone(), JsonValue::String(question_text.to_string()));
                match client.call_tool(crate::aria_v2_surface::RECALL_PRECISE, pargs, &verb_map.result_format) {
                    Ok(result) => {
                        retrieved_uuids = result.ordered_ids;
                        exact_text_blocks = result.text_blocks.clone();
                        exact_payload_text = if result.text_blocks.is_empty() { None } else { Some(result.text_blocks.join("\n")) };
                    }
                    Err(e) => eprintln!("  [lme] precise query error for {question_id}: {}", e.description),
                }
            } else {
                // Environment seam: an override spec replaces the default
                // query call; None is byte-identical to the verb-map path.
                let default_result = if let Some(spec) = retrieval_call {
                    let (seam_tool, seam_args) = crate::retrieval_call_spec::seam_call(
                        &verb_map, Some(spec), question_text);
                    client.call_tool(&seam_tool, seam_args, &verb_map.result_format)
                        .and_then(|r| crate::retrieval_call_spec::check_retrieval_result(r))
                        .map(|r| crate::payload_arm::strip_tool_result(payload_arm, r))
                } else {
                    client.call_tool(&verb_map.query, args, &verb_map.result_format)
                        .and_then(|r| crate::retrieval_call_spec::check_retrieval_result(r))
                };
                match default_result {
                    Ok(result) => {
                        retrieved_uuids = result.ordered_ids;
                        exact_text_blocks = result.text_blocks.clone();
                        // Capture raw payload text for token counting in the scorer.
                        exact_payload_text = if result.text_blocks.is_empty() { None } else { Some(result.text_blocks.join("\n")) };
                    }
                    Err(e) => {
                        eprintln!(
                            "  [lme] exact query error for {question_id}: {}",
                            e.description
                        );
                    }
                }
                // Documented escalation: low discrimination -> recall_precise.
                // Suppressed under a retrieval-call override: the seam call
                // IS the measured door (twin of the Swift seam branch).
                if retrieval_call.is_none()
                    && strategy == ExactRecallStrategy::Auto
                    && exact_payload_text.as_deref().map_or(false, |t| t.contains("discrimination: low"))
                {
                    let mut pargs: BTreeMap<String, JsonValue> = BTreeMap::new();
                    pargs.insert(verb_map.query_arg.clone(), JsonValue::String(question_text.to_string()));
                    if let Ok(result) = client.call_tool(crate::aria_v2_surface::RECALL_PRECISE, pargs, &verb_map.result_format) {
                        if !result.ordered_ids.is_empty() {
                            retrieved_uuids = result.ordered_ids;
                            exact_text_blocks = result.text_blocks.clone();
                            exact_payload_text = if result.text_blocks.is_empty() { None } else { Some(result.text_blocks.join("\n")) };
                        }
                    }
                }
            }
        }
        exact_query_latency = Some(query_start.elapsed().as_secs_f64());

        // Post-retrieval reranking — inserts between retrieval and scoring.
        // exact_payload_text is kept unchanged for diagnostics; only retrieved_uuids
        // is reordered so the scorer sees the reranked list.
        if let Some(cmd) = rerank_cmd {
            let (reranked, failed) = apply_rerank(cmd, question_text, &retrieved_uuids, &exact_text_blocks);
            retrieved_uuids = reranked;
            rerank_failed = failed;
        }
    }

    // ── Dense arm: moot_recall_distilled ─────────────────────────────────────
    // moot_distill is retired on the ARIA v2 surface
    // (negative_catalog_assertions absent_reason: "Retired alias.").
    // The dense arm refuses with LaneError::Config; Swift parity: throws
    // AriaV2SurfaceError.retiredOperation.
    let dense_payload_text: Option<String> = None;
    let dense_query_latency: Option<f64> = None;
    if arm == &LmeArm::Dense || arm == &LmeArm::Both {
        return Err(LaneError::Config(
            crate::aria_v2_surface::refused_distill_call(),
        ));
    }

    // ── Judge payload hydration (answer-accuracy path) ───────────────────────
    // The recall verbs return a 120-CHARACTER PREVIEW per hit (product
    // `ToolDispatch`: `content.prefix(120)`) — right for a search tool's token
    // economy, useless as judge context, because a conversational turn's answer
    // usually sits past character 120. A judge reading previews answers "I
    // don't know" even when the correct item ranked first.
    //
    // So when a judge is configured, ranked ids are hydrated to FULL content
    // via `moot_memory_get` and the judge reads that. Retrieval metrics are
    // untouched — they score the ranked id list, which this does not change.
    // A failed fetch falls back to the preview rather than dropping the hit.
    // Twin of the Swift `hydratedPayload` closure.
    // Hydration runs inline rather than through a closure: `call_tool` takes
    // `&mut self`, so two closures both holding the client would double-borrow.
    let mut exact_judge_payload = exact_payload_text.clone();
    let mut dense_judge_payload = dense_payload_text.clone();
    if judge_cmd.is_some() || dump_judge_inputs_path.is_some() {
        // Only the EXACT arm is hydrated. The dense arm's payload is the
        // distilled, token-efficient rendering from `moot_recall_distilled`,
        // and that text is the thing under test — whether a judge can still
        // answer from the distillate. Hydrating it to full content would
        // substitute the original text and collapse dense into exact.
        for (ids, slot, fallback) in [
            (&retrieved_uuids, 0usize, exact_payload_text.clone()),
        ] {
            if ids.is_empty() {
                continue;
            }
            let mut blocks: Vec<String> = Vec::new();
            for id in ids.iter().take(judge_hydration_depth) {
                let args = crate::aria_v2_surface::memory_get_args(id.as_str(), None);
                match client.call_tool(crate::aria_v2_surface::MEMORY_GET, args, &verb_map.result_format) {
                    Ok(r) => {
                        let text = r.text_blocks.join("\n");
                        if !text.is_empty() {
                            blocks.push(text);
                        }
                    }
                    Err(e) => eprintln!("  [lme] hydrate failed for {id}: {}", e.description),
                }
            }
            let hydrated = if blocks.is_empty() {
                fallback
            } else {
                Some(blocks.join("\n\n"))
            };
            if slot == 0 {
                exact_judge_payload = hydrated;
            } else {
                dense_judge_payload = hydrated;
            }
        }
    }

    // Grades one candidate answer under the run's grading mode. Verdict mode
    // spends a SECOND judge call for a correctness verdict — the protocol
    // published leaderboard figures are produced under — and falls back to
    // substring grading when the verdict is unparseable, so a chatty judge
    // degrades the grade rather than failing the question.
    let grade_answer = |answer: &str| -> bool {
        match judge_grading {
            LmeJudgeGrading::Substring => lme_grade_judge_answer(answer, gold_answer),
            LmeJudgeGrading::Verdict => {
                let Some(cmd) = judge_cmd else {
                    return lme_grade_judge_answer(answer, gold_answer);
                };
                let vp = lme_verdict_prompt(question_text, gold_answer, answer);
                match lme_run_judge(cmd, &vp).ok().and_then(|r| lme_parse_verdict(&r)) {
                    Some(v) => v,
                    None => {
                        eprintln!("  [lme] verdict unparseable for {question_id} — falling back to substring");
                        lme_grade_judge_answer(answer, gold_answer)
                    }
                }
            }
        }
    };

    // Retrieval ceiling for the judged metric: did the gold answer text even
    // reach the judge's context? See lme_gold_answer_in_payload.
    let exact_gold_reachable: Option<bool> = exact_judge_payload
        .as_deref()
        .map(|p| crate::longmemeval_token_efficiency::lme_gold_answer_in_payload(gold_answer, p));

    // ── Judge mode (Part 4): optional LLM-judged QA per arm ──────────────────
    // Soft errors from the judge subprocess are logged and skipped — a judge
    // failure does not fail the question; the answer fields stay None.
    let mut exact_judge_answer: Option<String> = None;
    let mut exact_judge_correct: Option<bool> = None;
    if let Some(cmd) = judge_cmd {
        if let Some(ref payload) = exact_judge_payload {
            if !payload.is_empty() {
                let prompt = lme_judge_prompt(question_text, payload);
                match lme_run_judge(cmd, &prompt) {
                    Ok(answer) => {
                        let correct = grade_answer(&answer);
                        exact_judge_answer = Some(answer);
                        exact_judge_correct = Some(correct);
                    }
                    Err(e) => {
                        eprintln!("  [lme] judge error (exact) for {question_id}: {e}");
                    }
                }
            }
        }
    }

    // THIRD payload mode: the raw PREVIEW payload, judged as-is. The three
    // modes form the token/quality frontier a consumer actually chooses
    // between — preview (cheapest, 120 chars/hit), distilled (mid), full
    // hydrated content (most expensive). Judging all three on the same
    // question with the same judge is the only way to say which is worth its
    // tokens. Twin of the Swift preview-judge block.
    let mut preview_judge_answer: Option<String> = None;
    let mut preview_judge_correct: Option<bool> = None;
    if let Some(cmd) = judge_cmd {
        if let Some(ref payload) = exact_payload_text {
            if !payload.is_empty() {
                let prompt = lme_judge_prompt(question_text, payload);
                match lme_run_judge(cmd, &prompt) {
                    Ok(answer) => {
                        let correct = grade_answer(&answer);
                        preview_judge_answer = Some(answer);
                        preview_judge_correct = Some(correct);
                    }
                    Err(e) => {
                        eprintln!("  [lme] judge error (preview) for {question_id}: {e}");
                    }
                }
            }
        }
    }

    let mut dense_judge_answer: Option<String> = None;
    let mut dense_judge_correct: Option<bool> = None;
    if let Some(cmd) = judge_cmd {
        if let Some(ref payload) = dense_judge_payload {
            if !payload.is_empty() {
                let prompt = lme_judge_prompt(question_text, payload);
                match lme_run_judge(cmd, &prompt) {
                    Ok(answer) => {
                        let correct = grade_answer(&answer);
                        dense_judge_answer = Some(answer);
                        dense_judge_correct = Some(correct);
                    }
                    Err(e) => {
                        eprintln!("  [lme] judge error (dense) for {question_id}: {e}");
                    }
                }
            }
        }
    }

    // ── Settle cell (--settle mode, Mission 11X-RECALL-GAP-01 Stream C) ─────
    // Runs only when --settle is set AND the exact arm ran. Triggers moot_reindex
    // to ensure every drawer is at full vector coverage, waits for the
    // corpus_encode drain to converge, then re-runs the exact-arm queries as the
    // SETTLED cell. The dense arm is NOT re-run (consolidation is not re-entrant
    // and the dense cell is not a settle target).
    let mut settled_retrieved_uuids: Option<Vec<String>> = None;
    let mut settled_query_latency_seconds: Option<f64> = None;
    let mut settled_drain_lane_observed: Option<bool> = None;
    if settle && (arm == &LmeArm::Exact || arm == &LmeArm::Both) {
        // Trigger background reindex so every drawer is at full coverage.
        let reindex_args: BTreeMap<String, JsonValue> = BTreeMap::new();
        if let Err(e) = client.call_tool(crate::aria_v2_surface::REINDEX, reindex_args, &verb_map.result_format) {
            eprintln!(
                "  [lme] settle: moot_reindex error for {question_id}: {}",
                e.description
            );
        }
        // Wait for corpus_encode drain to converge after reindex.
        let settle_outcome = wait_for_encode_drain(
            &mut client,
            &format!("lme settle {question_id}"),
            300.0,
        );
        settled_drain_lane_observed = Some(settle_outcome.lane_observed);
        // Re-run the exact-arm queries with the same strategy as the organic cell.
        let settled_query_start = Instant::now();
        let mut sargs: BTreeMap<String, JsonValue> = BTreeMap::new();
        sargs.insert(
            verb_map.query_arg.clone(),
            JsonValue::String(question_text.to_string()),
        );
        // v2: `ordering` arg removed from moot_memory_search; v2 defaults to byRelevanceDesc.
        // (The ExactRecallStrategy::Relevance / Auto branch was the only caller.)
        if strategy == ExactRecallStrategy::Precise {
            let mut pargs: BTreeMap<String, JsonValue> = BTreeMap::new();
            pargs.insert(
                verb_map.query_arg.clone(),
                JsonValue::String(question_text.to_string()),
            );
            if let Ok(r) = client.call_tool(crate::aria_v2_surface::RECALL_PRECISE, pargs, &verb_map.result_format) {
                settled_retrieved_uuids = Some(r.ordered_ids);
            }
        } else {
            let settled_result = if let Some(spec) = retrieval_call {
                let (seam_tool, seam_args) = crate::retrieval_call_spec::seam_call(
                    &verb_map, Some(spec), question_text);
                client.call_tool(&seam_tool, seam_args, &verb_map.result_format)
                    .and_then(|r| crate::retrieval_call_spec::check_retrieval_result(r))
                    .map(|r| crate::payload_arm::strip_tool_result(payload_arm, r))
            } else {
                client.call_tool(&verb_map.query, sargs, &verb_map.result_format)
                    .and_then(|r| crate::retrieval_call_spec::check_retrieval_result(r))
            };
            if let Ok(r) = settled_result {
                let payload = r.text_blocks.join("\n");
                settled_retrieved_uuids = Some(r.ordered_ids);
                // Documented escalation for auto strategy (suppressed under
                // a retrieval-call override — the seam call IS the door).
                if retrieval_call.is_none()
                    && strategy == ExactRecallStrategy::Auto
                    && payload.contains("discrimination: low")
                {
                    let mut pargs: BTreeMap<String, JsonValue> = BTreeMap::new();
                    pargs.insert(
                        verb_map.query_arg.clone(),
                        JsonValue::String(question_text.to_string()),
                    );
                    if let Ok(pr) = client.call_tool(crate::aria_v2_surface::RECALL_PRECISE, pargs, &verb_map.result_format) {
                        if !pr.ordered_ids.is_empty() {
                            settled_retrieved_uuids = Some(pr.ordered_ids);
                        }
                    }
                }
            }
        }
        settled_query_latency_seconds = Some(settled_query_start.elapsed().as_secs_f64());
    }

    // ── Teardown ──────────────────────────────────────────────────────────────
    client.disconnect();
    // Retirement = teardown + zero-residual-key verification.
    if let Err(e) = crate::key_residue::retire_scratch_estate(&scratch, lme_guarded_teardown) {
        eprintln!(
            "  [lme] teardown warning for {question_id}: {}",
            e.description
        );
    }

    // Token estimates are taken before the payload strings move into the
    // result struct.
    let exact_judge_tokens = exact_judge_payload
        .as_deref()
        .map(crate::longmemeval_token_efficiency::lme_estimate_tokens);
    let dense_judge_tokens = dense_judge_payload
        .as_deref()
        .map(crate::longmemeval_token_efficiency::lme_estimate_tokens);
    let preview_judge_tokens = exact_payload_text
        .as_deref()
        .map(crate::longmemeval_token_efficiency::lme_estimate_tokens);

    // Append question line to the pre-judge JSONL dump (before values move into result).
    // exact_payload is null when retrieval returned empty; dense_payload is null when
    // the dense arm was not run. Token counts use the same estimator as the report.
    if let Some(dump_path) = dump_judge_inputs_path {
        use std::io::Write;
        if let Ok(mut f) = std::fs::OpenOptions::new().append(true).open(dump_path) {
            let line = serde_json::json!({
                "type": "question",
                "question_id": question_id,
                "question": question_text,
                "gold_answer": gold_answer,
                "exact_payload": &exact_judge_payload,
                "exact_payload_tokens": exact_judge_tokens,
                "dense_payload": &dense_judge_payload,
                "dense_payload_tokens": dense_judge_tokens,
            });
            let _ = writeln!(f, "{line}");
        }
    }

    let result = LmeQuestionResult {
        question_id: question_id.to_string(),
        question_type: question_type.to_string(),
        query_latency_seconds: exact_query_latency,
        retrieved_uuids,
        manifest,
        answer_session_ids: answer_session_ids.to_vec(),
        guard_healthy,
        guard_diagnostic,
        guard_sampling_mode: sampler.lock().unwrap().policy,
        turns_ingested,
        write_mean_latency_seconds: write_mean_latency,
        exact_payload_text,
        dense_payload_text,
        dense_query_latency_seconds: dense_query_latency,
        exact_judge_answer,
        exact_judge_correct,
        exact_gold_reachable,
        exact_judge_tokens,
        dense_judge_tokens,
        preview_judge_answer,
        preview_judge_correct,
        preview_judge_tokens,
        dense_judge_answer,
        dense_judge_correct,
        cache_hit,
        drain_lane_observed,
        settled_retrieved_uuids,
        settled_query_latency_seconds,
        settled_drain_lane_observed,
        // Synthesize arm fields (PR-08 D3). This port does not call moot_synthesize
        // per question — the Swift leg does, at LongMemEvalRunner.swift:957-985.
        // Every field is None on every question, and that is what the report says:
        // the synthesize cell is computed from the count of non-None payloads, so
        // it reads enabled: false, question_count: 0 whether or not --synthesize-arm
        // was supplied. main.rs warns at flag-parse time that the arm is absent here.
        synthesize_payload_text: None,
        synthesize_judge_answer: None,
        synthesize_judge_correct: None,
        synthesize_judge_tokens: None,
    };
    Ok((result, rerank_failed))
}

// ─────────────────────────────────────────────────────────────────────────────
// Top-level question runner
// ─────────────────────────────────────────────────────────────────────────────

/// Size of the "dev" partition for `--slice dev|holdout`. The dev slice is
/// always the first 50 questions of the seeded shuffle; holdout is everything
/// after. This boundary is a hard constant — the historical tuning slice size.
/// Tests rely on this value; change it only with full test suite validation.
pub(crate) const LME_DEV_SLICE_SIZE: usize = 50;

/// Runs the LME harness over a slice of questions.
///
/// Questions are run in sequence (one mootx01 instance per question). Progress
/// is printed to stderr: one line per question. Returns results and the
/// run-level rerank failure count (0 when `config.rerank_cmd` is `None`).
pub fn run_lme_questions(
    corpus: &LmeCorpus,
    config: &LmeRunConfig,
) -> Result<(Vec<LmeQuestionResult>, u64, Option<String>), String> {
    // ── Build the question list: shuffle → slice → limit ─────────────────────
    // The slice partition is applied AFTER the seeded shuffle and BEFORE the
    // limit, so `--slice dev --limit 10` returns the first 10 of the dev half
    // (50 questions), not 10 of the full set filtered to dev.
    let mut indices: Vec<usize> = (0..corpus.questions.len()).collect();
    // --ids pinned subset (before shuffle: same file → same units always).
    if let Some(ids) = &config.unit_ids {
        indices.retain(|&i| ids.contains(&corpus.questions[i].question_id));
    }
    let mut rng = SplitMix64::new(config.seed);
    rng.shuffle(&mut indices);
    // Slice boundary: "dev" = first LME_DEV_SLICE_SIZE (50) shuffled questions
    // (historical tuning partition); "holdout" = everything after the first 50.
    if let Some(ref slice) = config.slice {
        match slice.as_str() {
            "dev" => {
                indices.truncate(LME_DEV_SLICE_SIZE);
            }
            "holdout" => {
                if indices.len() > LME_DEV_SLICE_SIZE {
                    indices = indices.split_off(LME_DEV_SLICE_SIZE);
                } else {
                    indices.clear();
                }
            }
            // Validated at CLI parse time; unreachable in production.
            other => unreachable!("run_lme_questions: --slice value '{other}' was not validated at parse"),
        }
    }
    if let Some(limit) = config.limit {
        indices.truncate(limit);
    }

    let total = indices.len();
    let mut results: Vec<LmeQuestionResult> = Vec::with_capacity(total);
    // Accumulated rerank failures; nil-equivalent (always 0) when rerank_cmd is None.
    let mut rerank_failures: u64 = 0;

    // ── Estate cache setup (once per run) ────────────────────────────────────
    // B2: one provenance per run — staleness is DETECTED by artifact.json
    // validation on restore, not assumed via a binary fingerprint (B3).
    let run_provenance = crate::artifact_manifest::make_artifact_provenance(
        "lme",
        &config.variant,
        config.seed,
        config.encode_barrier.as_str(),
        config.scratch_posture.as_str(),
        config.seed_path.as_str(),
        &config.corpus_digest,
    );
    // Drift gate: refuse before any scratch estate is written when the
    // gate's evidence does not cover the binary this lane resolved.
    let resolved_cache_dir: PathBuf =
        crate::estate_cache::resolved_cache_dir_enforcing_drift_gate(
            config.cache_dir.as_deref(),
            config.out_dir.as_deref(),
            Some(config.moot_binary.as_str()),
            config.estate_cache,
        )
        .unwrap_or_else(|e| {
            // These lane entry points do not return Result, and a refusal has
            // nothing meaningful to return: the run must not happen. Panic
            // rather than process::exit — exit would tear down the whole test
            // harness when a unit test drives a lane, turning one refusal into
            // an unexplained abnormal termination. A panic still exits non-zero
            // for `make`, and stays catchable in tests.
            panic!("mcp-benchmarker-rs: {e}");
        });

    // Write JSONL header once per run, before the question loop.
    // Mirrors the Swift `LongMemEvalRunner.swift` dump-judge-inputs path.
    if let Some(dump_path) = &config.dump_judge_inputs_path {
        use std::io::Write;
        let arm_str = match config.arm {
            LmeArm::Exact => "exact",
            LmeArm::Dense => "dense",
            LmeArm::Both => "both",
        };
        let header = serde_json::json!({
            "type": "header",
            "benchmark": "longmemeval",
            "variant": config.variant,
            "seed": config.seed,
            "run_label": config.label.as_deref().unwrap_or(""),
            "arm": arm_str,
            "judge_hydration_depth": config.judge_hydration_depth,
        });
        if let Ok(mut f) = std::fs::File::create(dump_path) {
            let _ = writeln!(f, "{header}");
        }
    }

    // One sampler for the entire leg: probes on the first question; caches the verdict
    // for all subsequent questions. The guard validates the binary under test —
    // a frozen-ranking binary would be frozen for every question, so caching is valid.
    // Wrapped in Mutex so the C6 parallel path can share it safely across threads;
    // the lock is held only for the duration of each probe call (sub-millisecond).
    let guard_sampler = std::sync::Mutex::new(LegGuardSampler::new(config.guard_sampling_policy));
    // C4: the leg-level timing text is captured at artifact BUILD time by the
    // seeding pipeline; this lane restores settled artifacts, so there is no
    // timing capture here and the run-level timing text is always None.
    let timing_text: Option<String> = None;

    // C6: parallel path. Gated on parallel_units > 1 (default serial when not set).
    // Uses std::thread::scope with a shared Mutex<VecDeque> work queue so N worker
    // threads pop question slots concurrently. Results go into a Mutex<Vec<Option<_>>>
    // indexed by slot so ordering is byte-deterministic after all workers finish.
    // The Rust port has no shared-estate path — the only legal source of work is
    // fresh-per-question, so no shared-estate serial-only guard is needed here.
    // Error semantics: endpoint config refusals (e.g. whitespace in scratch path)
    // propagate via config_err and abort the run (Err → main() exits 1). Per-question
    // connect/MCP errors record stub results (guard_healthy=false) and continue.
    if config.parallel_units > 1 && !indices.is_empty() {
        // (slot_index, corpus_question_index) pairs — slot drives output ordering.
        let work: std::collections::VecDeque<(usize, usize)> =
            indices.iter().copied().enumerate().collect();
        let work_queue = std::sync::Mutex::new(work);
        let out: std::sync::Mutex<Vec<Option<(LmeQuestionResult, bool)>>> =
            std::sync::Mutex::new((0..indices.len()).map(|_| None).collect());
        // Error channel: config refusal breaks the thread without filling its slot.
        // Checked after the scope before slot collection to avoid a panic on None.
        let config_err: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);
        let n_workers = config.parallel_units.min(indices.len());

        std::thread::scope(|scope| {
            for _ in 0..n_workers {
                scope.spawn(|| loop {
                    let work_item = work_queue.lock().unwrap().pop_front();
                    let (slot, q_idx) = match work_item {
                        None => break,
                        Some(item) => item,
                    };
                    let q = &corpus.questions[q_idx];
                    let cache_entry_opt: Option<PathBuf> = if config.estate_cache != EstateCacheMode::Off {
                        Some(estate_cache_entry_path(
                            &resolved_cache_dir, "lme", &config.variant, config.seed,
                            config.encode_barrier, config.scratch_posture,
                            config.seed_path, &q.question_id,
                        ))
                    } else {
                        None
                    };
                    let pair = match run_one_question(
                        &q.question_id, &q.question_type, &q.question, &q.answer,
                        &q.answer_session_ids,
                        &config.moot_binary, config.seed, q_idx,
                        &config.arm, config.judge_cmd.as_deref(), config.judge_grading,
                        config.judge_hydration_depth,
                        cache_entry_opt.as_deref(), config.scratch_posture,
                        config.exact_strategy, config.recall_shape.as_deref(),
                        config.retrieval_call.as_ref(),
                        config.payload_arm,
                        config.settle,
                        config.rerank_cmd.as_deref(),
                        config.dump_judge_inputs_path.as_deref(),
                        &guard_sampler, config.shape, &run_provenance,
                    ) {
                        Ok(r) => r,
                        Err(e) => {
                            // Config errors abort the lane — propagate via channel and stop
                            // this thread. Unit errors produce guard-excluded stubs and continue.
                            match e {
                                LaneError::Config(msg) => {
                                    *config_err.lock().unwrap() = Some(msg);
                                    break;
                                }
                                LaneError::Unit(ref desc) => eprintln!("  ERROR (skipping): {}", desc),
                            }
                            let desc = e.description().to_string();
                            (LmeQuestionResult {
                                question_id: q.question_id.clone(),
                                question_type: q.question_type.clone(),
                                query_latency_seconds: None,
                                retrieved_uuids: vec![],
                                manifest: vec![],
                                answer_session_ids: q.answer_session_ids.clone(),
                                guard_healthy: false,
                                guard_diagnostic: Some(desc),
                                guard_sampling_mode: config.guard_sampling_policy,
                                turns_ingested: 0,
                                write_mean_latency_seconds: 0.0,
                                exact_payload_text: None,
                                dense_payload_text: None,
                                dense_query_latency_seconds: None,
                                exact_judge_answer: None,
                                exact_judge_correct: None,
                                exact_gold_reachable: None,
                                exact_judge_tokens: None,
                                dense_judge_tokens: None,
                                preview_judge_answer: None,
                                preview_judge_correct: None,
                                preview_judge_tokens: None,
                                dense_judge_answer: None,
                                dense_judge_correct: None,
                                cache_hit: None,
                                drain_lane_observed: None,
                                settled_retrieved_uuids: None,
                                settled_query_latency_seconds: None,
                                settled_drain_lane_observed: None,
                                synthesize_payload_text: None,
                                synthesize_judge_answer: None,
                                synthesize_judge_correct: None,
                                synthesize_judge_tokens: None,
                            }, false)
                        }
                    };
                    out.lock().unwrap()[slot] = Some(pair);
                });
            }
        });

        // Propagate any endpoint-config refusal before collecting slots.
        // A thread that detected a config error broke without filling its slot;
        // collecting would panic on the None. Return Err here so main() exits 1.
        if let Some(err) = config_err.into_inner().unwrap() {
            return Err(err);
        }

        // Collect results in slot order — byte-deterministic regardless of
        // which threads finished first.
        for opt in out.into_inner().unwrap() {
            let (result, q_rerank_failed) = opt.expect("parallel: unfilled result slot");
            if q_rerank_failed { rerank_failures += 1; }
            results.push(result);
        }
        return Ok((results, rerank_failures, timing_text));
    }

    // Serial loop: runs when parallel_units == 1 or the question list is empty.
    for (progress_index, &question_index) in indices.iter().enumerate() {
        let q = &corpus.questions[question_index];
        eprintln!(
            "[lme] {}/{}: {} ({})",
            progress_index + 1,
            total,
            q.question_id,
            q.question_type
        );

        // Compute cache entry path for this question (only when cache mode is Reuse).
        // Variant is part of the key — different variants have different corpora.
        let cache_entry_opt: Option<PathBuf> = if config.estate_cache != EstateCacheMode::Off {
            Some(estate_cache_entry_path(
                &resolved_cache_dir,
                // "lme" matches the Swift leg's cache key so the two legs
                // name identically-shaped estates identically.
                "lme",
                &config.variant,
                config.seed,
                config.encode_barrier,
                config.scratch_posture,
                config.seed_path,
                &q.question_id,
            ))
        } else {
            None
        };

        match run_one_question(
            &q.question_id,
            &q.question_type,
            &q.question,
            &q.answer,
            &q.answer_session_ids,
            &config.moot_binary,
            config.seed,
            question_index,
            &config.arm,
            config.judge_cmd.as_deref(),
            config.judge_grading,
            config.judge_hydration_depth,
            cache_entry_opt.as_deref(),
            config.scratch_posture,
            config.exact_strategy,
            config.recall_shape.as_deref(),
            config.retrieval_call.as_ref(),
            config.payload_arm,
            config.settle,
            config.rerank_cmd.as_deref(),
            config.dump_judge_inputs_path.as_deref(),
            &guard_sampler,
            config.shape,
            &run_provenance,
        ) {
            Ok((result, q_rerank_failed)) => {
                if q_rerank_failed {
                    rerank_failures += 1;
                }
                let guard_str = if result.guard_healthy { "healthy" } else { "GUARD_FAIL" };
                let query_ms = result.query_latency_seconds
                    .map(|s| format!("{:.0}", s * 1000.0))
                    .unwrap_or_else(|| "n/a".to_string());
                eprintln!(
                    "  guard={guard_str} turns={} query_ms={query_ms}",
                    result.turns_ingested,
                );
                results.push(result);
            }
            Err(e) => {
                // Config errors abort the lane. Unit errors produce guard-excluded stubs.
                if let LaneError::Config(msg) = e {
                    return Err(msg);
                }
                let desc = e.description().to_string();
                eprintln!("  ERROR (skipping): {}", desc);
                // Emit a guard-excluded result so the question shows in corpus_stats.
                results.push(LmeQuestionResult {
                    question_id: q.question_id.clone(),
                    question_type: q.question_type.clone(),
                    query_latency_seconds: None,
                    retrieved_uuids: vec![],
                    manifest: vec![],
                    answer_session_ids: q.answer_session_ids.clone(),
                    guard_healthy: false,
                    guard_diagnostic: Some(desc),
                    guard_sampling_mode: config.guard_sampling_policy,
                    turns_ingested: 0,
                    write_mean_latency_seconds: 0.0,
                    exact_payload_text: None,
                    dense_payload_text: None,
                    dense_query_latency_seconds: None,
                    exact_judge_answer: None,
                    exact_judge_correct: None,
                    exact_gold_reachable: None,
                    exact_judge_tokens: None,
                    dense_judge_tokens: None,
                    preview_judge_answer: None,
                    preview_judge_correct: None,
                    preview_judge_tokens: None,
                    dense_judge_answer: None,
                    dense_judge_correct: None,
                    cache_hit: None,
                    drain_lane_observed: None,
                    settled_retrieved_uuids: None,
                    settled_query_latency_seconds: None,
                    settled_drain_lane_observed: None,
                    // Synthesize arm: None for error-path stubs (PR-08 D3).
                    synthesize_payload_text: None,
                    synthesize_judge_answer: None,
                    synthesize_judge_correct: None,
                    synthesize_judge_tokens: None,
                });
            }
        }
    }

    Ok((results, rerank_failures, timing_text))
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests — slice partition logic
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod slice_tests {
    use super::{SplitMix64, LME_DEV_SLICE_SIZE};

    /// Apply the same shuffle → slice → limit pipeline that `run_lme_questions`
    /// uses, operating on plain `usize` indices so no corpus fixture is needed.
    fn apply_pipeline(
        count: usize,
        seed: u64,
        slice: Option<&str>,
        limit: Option<usize>,
    ) -> Vec<usize> {
        let mut indices: Vec<usize> = (0..count).collect();
        let mut rng = SplitMix64::new(seed);
        rng.shuffle(&mut indices);
        if let Some(s) = slice {
            match s {
                "dev" => indices.truncate(LME_DEV_SLICE_SIZE),
                "holdout" => {
                    if indices.len() > LME_DEV_SLICE_SIZE {
                        indices = indices.split_off(LME_DEV_SLICE_SIZE);
                    } else {
                        indices.clear();
                    }
                }
                other => panic!("unexpected slice '{other}' in test helper"),
            }
        }
        if let Some(lim) = limit {
            indices.truncate(lim);
        }
        indices
    }

    const CORPUS_SIZE: usize = 200;
    const SEED: u64 = 20_260_725;

    #[test]
    fn dev_and_holdout_cover_full_shuffled_set() {
        let mut dev = apply_pipeline(CORPUS_SIZE, SEED, Some("dev"), None);
        let mut holdout = apply_pipeline(CORPUS_SIZE, SEED, Some("holdout"), None);
        let mut full = apply_pipeline(CORPUS_SIZE, SEED, None, None);
        dev.sort_unstable();
        holdout.sort_unstable();
        full.sort_unstable();

        let mut union = dev.clone();
        union.extend_from_slice(&holdout);
        union.sort_unstable();
        union.dedup();

        assert_eq!(union, full, "dev ∪ holdout must equal the full shuffled set");
    }

    #[test]
    fn dev_and_holdout_are_disjoint() {
        let dev_set: std::collections::HashSet<usize> =
            apply_pipeline(CORPUS_SIZE, SEED, Some("dev"), None)
                .into_iter()
                .collect();
        let holdout_set: std::collections::HashSet<usize> =
            apply_pipeline(CORPUS_SIZE, SEED, Some("holdout"), None)
                .into_iter()
                .collect();
        let intersection: Vec<&usize> = dev_set.intersection(&holdout_set).collect();
        assert!(
            intersection.is_empty(),
            "dev ∩ holdout must be empty (disjoint partition)"
        );
    }

    #[test]
    fn dev_equals_first_50_of_seeded_shuffle() {
        let dev = apply_pipeline(CORPUS_SIZE, SEED, Some("dev"), None);
        let full = apply_pipeline(CORPUS_SIZE, SEED, None, None);

        assert_eq!(dev.len(), LME_DEV_SLICE_SIZE, "dev must contain exactly 50 questions");
        assert_eq!(
            dev,
            &full[..LME_DEV_SLICE_SIZE],
            "dev must equal the first 50 of the seeded shuffle"
        );
    }

    #[test]
    fn holdout_equals_after_first_50_of_seeded_shuffle() {
        let holdout = apply_pipeline(CORPUS_SIZE, SEED, Some("holdout"), None);
        let full = apply_pipeline(CORPUS_SIZE, SEED, None, None);

        assert_eq!(
            holdout.len(),
            CORPUS_SIZE - LME_DEV_SLICE_SIZE,
            "holdout must contain corpus_size − 50 questions"
        );
        assert_eq!(
            holdout,
            &full[LME_DEV_SLICE_SIZE..],
            "holdout must equal everything after the first 50 of the seeded shuffle"
        );
    }

    #[test]
    fn dev_slice_is_deterministic_across_calls() {
        let a = apply_pipeline(CORPUS_SIZE, SEED, Some("dev"), None);
        let b = apply_pipeline(CORPUS_SIZE, SEED, Some("dev"), None);
        assert_eq!(a, b, "dev slice must be identical for the same seed");
    }

    #[test]
    fn dev_with_limit_is_prefix_of_dev_slice() {
        let dev_full = apply_pipeline(CORPUS_SIZE, SEED, Some("dev"), None);
        let dev_limited = apply_pipeline(CORPUS_SIZE, SEED, Some("dev"), Some(10));
        assert_eq!(dev_limited.len(), 10, "dev + limit:10 must yield 10 questions");
        assert_eq!(
            dev_limited,
            &dev_full[..10],
            "dev + limit:10 must equal first 10 of the dev slice"
        );
    }

    #[test]
    fn nil_slice_is_full_set() {
        let no_slice = apply_pipeline(CORPUS_SIZE, SEED, None, None);
        assert_eq!(
            no_slice.len(),
            CORPUS_SIZE,
            "omitted --slice must yield the full shuffled set"
        );
    }

    #[test]
    fn holdout_clears_when_corpus_smaller_than_dev_boundary() {
        // If the corpus is smaller than 50, the holdout partition is empty.
        let holdout = apply_pipeline(30, SEED, Some("holdout"), None);
        assert!(
            holdout.is_empty(),
            "holdout must be empty when corpus is smaller than the dev boundary (50)"
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests — no re-dream on the restore path
// ─────────────────────────────────────────────────────────────────────────────

/// Pins the B4 settled-artifact invariant: a restored artifact is settled BY
/// CONSTRUCTION (the seeding pipeline snapshots after ingest → drain → dream →
/// basis retrain), so the restore path must NOT re-run `moot_dream` or
/// `moot_reindex`. This module exercises the restore path end-to-end against
/// a tracking mock MCP server and asserts neither tool appears in the call log.
#[cfg(test)]
mod protocol_v2_tests {
    use super::{run_one_question, ExactRecallStrategy, LmeArm};
    use crate::longmemeval_judge::LmeJudgeGrading;
    use crate::scratch_posture::ScratchEstatePosture;
    use std::io::Write;
    use std::path::{Path, PathBuf};

    /// Writes a tracking mock MCP server shell script to a temp path.
    ///
    /// The server:
    ///   - Answers the `initialize` handshake with `protocolVersion`.
    ///   - For every subsequent `tools/call` message, extracts the tool `name`
    ///     from the JSON, appends `TOOL:<name>` to `log_path`, and replies with
    ///     a generic ok content block.
    ///
    /// The test inspects `log_path` after `run_one_question` returns to assert
    /// that `moot_dream` did NOT run on the restore path.
    fn write_tracking_mock(log_path: &Path) -> PathBuf {
        // Unique PRIVATE directory per call (mkdtemp-style): a PID-predictable
        // filename in the shared temp dir invited a symlink pre-place by any
        // local user — File::create would follow it and clobber or re-permission
        // the target (Wave-3 G3b). create_dir fails atomically if the candidate
        // exists (symlinks included), so the loop lands on a directory WE
        // created; 0700 keeps other users out of it.
        let base = std::env::temp_dir();
        let mut mock_dir = None;
        for attempt in 0u32..1000 {
            let candidate = base.join(format!(
                "lme-v2-mock-{}-{attempt}", std::process::id()
            ));
            match std::fs::create_dir(&candidate) {
                Ok(()) => {
                    mock_dir = Some(candidate);
                    break;
                }
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(e) => panic!("cannot create mock dir {}: {e}", candidate.display()),
            }
        }
        let mock_dir = mock_dir.expect("no free lme-v2-mock dir candidate in 1000 attempts");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let perms = std::fs::Permissions::from_mode(0o700);
            std::fs::set_permissions(&mock_dir, perms).expect("chmod mock dir");
        }
        let script_path = mock_dir.join("mock.sh");
        let log = log_path.to_string_lossy().to_string();
        // The sed pattern extracts the LAST `"name":"<value>"` pair from the
        // JSON line.  In a `tools/call` request that is always the tool name
        // inside `"params":{"name":"<tool>","arguments":{...}}`.
        let script = format!(
            r#"#!/bin/sh
LOG="{log}"
first=1
while IFS= read -r line; do
  if [ "$first" = "1" ]; then
    printf '%s\n' '{{"jsonrpc":"2.0","id":1,"result":{{"protocolVersion":"2024-11-05"}}}}'
    first=0
  else
    name=$(echo "$line" | sed 's/.*"name":"\([^"]*\)".*/\1/')
    echo "TOOL:$name" >> "$LOG"
    printf '%s\n' '{{"jsonrpc":"2.0","id":1,"result":{{"content":[{{"type":"text","text":"ok"}}]}}}}'
  fi
done
"#
        );
        let mut f = std::fs::File::create(&script_path).expect("create tracking mock script");
        f.write_all(script.as_bytes()).expect("write tracking mock script");
        drop(f);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&script_path).unwrap().permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&script_path, perms).unwrap();
        }
        script_path
    }

    /// Creates a minimal fake estate cache entry that satisfies
    /// `restore_estate_cache_entry`'s preconditions for a `PlaintextTransient` run.
    ///
    /// Layout:
    ///   `entry/estate/`            — empty estate directory
    ///   `entry/manifest.json`      — empty JSON array (no ingested turns)
    ///
    /// The restore function copies `entry/estate/` → scratch dir. An empty manifest
    /// means `turns_ingested = 0` on the restored path — correct, since the
    /// fake entry carries no haystack data.
    fn build_fake_plaintext_cache_entry(entry: &Path) {
        let estate_dir = entry.join("estate");
        std::fs::create_dir_all(&estate_dir).expect("create fake estate dir");
        // Empty manifest — zero ingested turns, but valid JSON.
        std::fs::write(entry.join("manifest.json"), b"[]")
            .expect("write empty manifest.json");
    }

    /// B2 provenance fixture matching what the fake cache entry declares.
    fn test_run_provenance() -> crate::artifact_manifest::ArtifactProvenance {
        crate::artifact_manifest::make_artifact_provenance(
            "lme", "s", 1, "drain", "plaintext-optout", "live", "test-digest",
        )
    }

    /// B4 settled-artifact invariant (benchmark reset 2026-08-13): a restored
    /// artifact is settled BY CONSTRUCTION (the snapshot is taken after
    /// ingest → drain → dream → basis retrain at artifact build time), so the
    /// restore path must NOT re-run `moot_dream` — H7's defect was exactly
    /// that dream re-ran on every restore. This pin keeps a future refactor
    /// from reintroducing a re-dream on restore.
    #[test]
    fn settled_artifact_cache_hit_does_not_redream() {
        let pid = std::process::id();
        let base = std::env::temp_dir();
        // Use PID-tagged paths so parallel cargo test invocations don't collide.
        let cache_entry = base.join(format!("lme-v2-entry-{pid}"));
        let log_path = base.join(format!("lme-v2-log-{pid}.txt"));

        // Clean up remnants from any previous failed run.
        let _ = std::fs::remove_dir_all(&cache_entry);
        let _ = std::fs::remove_file(&log_path);

        // Build the fake cache entry (estate + empty manifest).
        build_fake_plaintext_cache_entry(&cache_entry);
        // B2: the entry must declare its provenance or restore hard-fails.
        crate::artifact_manifest::write_artifact_provenance(&test_run_provenance(), &cache_entry);

        // Write the tracking mock server. The script is chmod 755 and has a shebang,
        // so it is invoked directly as the binary (no sh prefix).
        let script = write_tracking_mock(&log_path);
        let mock_binary = script.to_string_lossy().into_owned();

        // seed=1, question_index=9999 → scratch path
        // /tmp/lme-bench-0000000000000001-0000270f — unique enough for a test.
        let result = run_one_question(
            "v2-cache-hit-test",         // question_id
            "single_session_user",       // question_type
            "what did we discuss?",      // question_text
            "testing",                   // gold_answer
            &[],                         // answer_session_ids
            &mock_binary,                // moot_binary → lme_endpoint_config appends " serve"
            1u64,                        // seed
            9999usize,                   // question_index
            &LmeArm::Exact,              // arm — minimal: one query only
            None,                        // judge_cmd
            LmeJudgeGrading::Substring,  // judge_grading
            10,                          // judge_hydration_depth
            Some(cache_entry.as_path()), // cache_entry — the restore source
            ScratchEstatePosture::PlaintextTransient,
            ExactRecallStrategy::Auto,
            None,                        // recall_shape
            None,                        // retrieval_call — standard path
            None,                        // payload_arm — full ruled payload
            false,                       // settle
            None,                        // rerank_cmd
            None,                        // dump_judge_inputs_path
            &std::sync::Mutex::new(crate::degeneracy_guard::LegGuardSampler::new(
                crate::degeneracy_guard::GuardSamplingPolicy::OncePerLeg)), // sampler — C6: Mutex-wrapped
            super::LmeShape::Disk, // C1: shape — disk for this test (no backend injection)
            &test_run_provenance(), // B2 provenance — matches what the save side wrote
        );

        // Clean up BEFORE asserting so temp dirs don't accumulate on failure.
        // The mock script lives in its own private dir — remove the dir.
        let _ = std::fs::remove_dir_all(script.parent().expect("mock script has a parent dir"));
        let _ = std::fs::remove_dir_all(&cache_entry);

        // Read the tool call log (written by the mock for every tools/call after
        // initialize).  We assert before checking the result so the assertion
        // message is actionable even if run_one_question returned an error.
        let log_content = std::fs::read_to_string(&log_path).unwrap_or_default();
        let _ = std::fs::remove_file(&log_path);

        // Primary assertion: the dream must NOT re-run on a cache hit — the
        // restored artifact is settled by construction (B4). A re-dream here
        // is exactly H7's re-work defect.
        assert!(
            !log_content.contains("TOOL:moot_dream"),
            "moot_dream must NOT re-run on the cache-hit path — the artifact \
             is settled at build (snapshot after dream + retrain, B4); \
             full tool log:\n{log_content}"
        );
        // Same for the settle retrain: build-time only.
        assert!(
            !log_content.contains("TOOL:moot_reindex"),
            "moot_reindex must NOT re-run on the cache-hit path (B4 settle is \
             build-time only); full tool log:\n{log_content}"
        );

        // The run must succeed end-to-end on the restore path.
        let (qr, _) = result.expect("run_one_question must complete on cache-hit path");
        assert_eq!(
            qr.cache_hit,
            Some(true),
            "result must report cache_hit=true when a valid cache entry is provided"
        );
    }
}
