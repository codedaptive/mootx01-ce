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
use crate::degeneracy_guard::DegeneracyGuard;
use crate::encode_barrier::{EncodeBarrier, wait_for_encode_drain};
use crate::scratch_posture::{apply_scratch_posture, ScratchEstatePosture};
use crate::estate_cache::{
    default_cache_dir, estate_cache_entry_path, moot_binary_fingerprint,
    restore_estate_cache_entry, save_estate_cache_entry, EstateCacheMode,
};
use crate::json_value::JsonValue;
use crate::longmemeval_corpus::{LmeCorpus, LmeTurn};
use crate::longmemeval_judge::{lme_grade_judge_answer, lme_judge_prompt, lme_run_judge};
use crate::longmemeval_scorer::{LmeManifestEntry, LmeQuestionResult};
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
}

impl ExactRecallStrategy {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "search" => Some(Self::Search),
            "relevance" => Some(Self::Relevance),
            "precise" => Some(Self::Precise),
            "auto" => Some(Self::Auto),
            _ => None,
        }
    }
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Search => "search",
            Self::Relevance => "relevance",
            Self::Precise => "precise",
            Self::Auto => "auto",
        }
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
    /// Encode-queue synchronization strategy. Default EncodeBarrier::Drain.
    /// Controls how the harness waits for background encoding to complete before
    /// issuing recall queries — prevents background-encoding races from producing
    /// artificially low recall scores.
    pub encode_barrier: EncodeBarrier,
    /// Estate snapshot reuse mode. Default EstateCacheMode::Off.
    pub estate_cache: EstateCacheMode,
    /// Exact-arm retrieval strategy (--exact-strategy). See ExactRecallStrategy.
    pub exact_strategy: ExactRecallStrategy,
    /// Cache root directory. None = <out-dir>/estate-cache (or <cwd>/estate-cache).
    pub cache_dir: Option<PathBuf>,
    /// At-rest posture for scratch estates. Default PlaintextOptOut: writes
    /// mootx01's `no-encrypt` marker into each scratch data dir before serve
    /// launch (no keychain contact). --no-plaintext-scratch selects
    /// EncryptedDefault. Recorded in the report JSON as "estate_encryption".
    pub scratch_posture: ScratchEstatePosture,
    /// When true, run each question twice: first as the ORGANIC cell (immediately
    /// after ingest + drain barrier), then trigger moot_reindex, wait for the
    /// corpus_encode drain to converge, and re-run identical queries as the
    /// SETTLED cell. Off by default. Twin of Swift LMERunConfig.settle.
    pub settle: bool,
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
/// `location: "benchmark/longmemeval"` is the write constant — all haystack
/// memories are filed in the benchmark wing so they are isolated from
/// the operator's real memories and from other benchmark runs.
pub fn lme_verb_map() -> VerbMap {
    let mut constant_args = BTreeMap::new();
    constant_args.insert("location".to_string(), "benchmark/longmemeval".to_string());
    VerbMap::new(
        "moot_file_memory",
        "moot_memory_search",
        None,                                 // list: not used in LME
        None,                                 // fetch: not used in LME
        None,                                 // content_arg: defaults to "content"
        None,                                 // query_arg: defaults to "query"
        Some(constant_args),
        Some(ResultFormat::MootText),
    )
}

/// Returns the VerbMap for the dense recall arm of the LME token-efficiency benchmark.
///
/// Uses `moot_recall_distilled`, which:
///   - Returns distilled prose per hit (token-economical representation)
///   - Requires `moot_distill` to be called after ingest, before the first query
///     (Wave 1: replaces the retired `moot_consolidate` alias)
///   - Does NOT use a location constant arg (queries the estate-default wing)
///
/// Twin of Swift `lmeDenseMootVerbMap`.
pub fn lme_dense_verb_map() -> VerbMap {
    VerbMap::new(
        "moot_file_memory",       // same ingest tool
        "moot_recall_distilled",  // dense query tool
        None,                     // list: not used
        None,                     // fetch: not used
        None,                     // content_arg: defaults to "content"
        None,                     // query_arg: defaults to "query"
        Some(BTreeMap::new()),    // constantArgs: empty (no location needed)
        Some(ResultFormat::MootText),
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
/// `posture` decides the at-rest encryption of the estate this dir will hold:
/// PlaintextOptOut (default methodology) writes mootx01's `no-encrypt` marker
/// BEFORE any serve launch (see scratch_posture.rs). No default value on
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
    apply_scratch_posture(posture, &path)?;
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
/// The command form is `MOOTX01_DATA_DIR=<scratch> <binary> serve`. The
/// `MCPClient` splits on whitespace and runs via `/usr/bin/env`, which handles
/// the `KEY=VALUE` env-var prefix argument natively.
pub fn lme_endpoint_config(scratch_dir: &Path, moot_binary: &str) -> EndpointConfig {
    let data_dir = scratch_dir.to_string_lossy();
    let command = format!("MOOTX01_DATA_DIR={data_dir} {moot_binary} serve");
    EndpointConfig {
        name: "mootx01-lme".to_string(),
        transport: Transport::Stdio { command },
        auth: None,
        verb_map: lme_verb_map(),
        role: EndpointRole::Both,
    }
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
///   2. `/Users/bob/.mootx01/bin/mootx01` (known install location)
///   3. `which mootx01` (PATH)
pub fn discover_moot_binary() -> Option<String> {
    // 1. Explicit override.
    if let Ok(path) = std::env::var("MOOTX01_BINARY") {
        if !path.is_empty() {
            return Some(path);
        }
    }
    // 2. Known install location.
    let known = PathBuf::from("/Users/bob/.mootx01/bin/mootx01");
    if known.exists() {
        return Some(known.to_string_lossy().into_owned());
    }
    // 3. PATH.
    let output = std::process::Command::new("which")
        .arg("mootx01")
        .output()
        .ok()?;
    if output.status.success() {
        let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !path.is_empty() {
            return Some(path);
        }
    }
    None
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-question run
// ─────────────────────────────────────────────────────────────────────────────

/// Ingest one haystack turn via `moot_file_memory`, returning `(uuid, latency_s)`.
///
/// The `encode_barrier` parameter controls inline encoding:
///   - `Impatient`: adds `impatient: true` so the turn is encoded synchronously
///     before this call returns. Correct key — the old key "n" was silently
///     ignored by mootx01's `moot_file_memory` handler.
///   - `Drain` / `None`: no per-write barrier; caller is responsible for waiting
///     after all ingest completes (via `wait_for_encode_drain`).
fn ingest_turn(
    client: &mut MCPClient,
    verb_map: &VerbMap,
    content: &str,
    encode_barrier: EncodeBarrier,
) -> Result<(String, f64), MCPError> {
    let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
    args.insert(
        verb_map.content_arg.clone(),
        JsonValue::String(content.to_string()),
    );
    // Constant args (location header).
    for (k, v) in &verb_map.constant_args {
        args.insert(k.clone(), JsonValue::String(v.clone()));
    }
    // Impatient mode: inline encoding per write (synchronous, before this call
    // returns). The correct key is "impatient" — the old key "n" was silently
    // ignored by the moot_file_memory handler in AriaMcpKit ToolDispatch.swift.
    if encode_barrier == EncodeBarrier::Impatient {
        args.insert("impatient".to_string(), JsonValue::Bool(true));
    }
    let start = Instant::now();
    let result = client.call_tool(&verb_map.write, args, &verb_map.result_format)?;
    let elapsed = start.elapsed().as_secs_f64();
    let uuid = result
        .write_assigned_id
        .ok_or_else(|| MCPError {
            description: "moot_file_memory returned no UUID".to_string(),
        })?;
    Ok((uuid, elapsed))
}

/// Runs the LME harness for a single question: create scratch dir → launch
/// mootx01 → ingest haystack → probe → consolidate (dense arm) → query → teardown.
///
/// Returns `Err` only for unrecoverable setup failures (scratch dir, binary
/// launch). Guard failures are encoded as `LmeQuestionResult.guard_healthy=false`.
#[allow(clippy::too_many_arguments)]
pub fn run_one_question(
    question_id: &str,
    question_type: &str,
    question_text: &str,
    gold_answer: &str,
    haystack_session_ids: &[String],
    haystack_sessions: &[Vec<LmeTurn>],
    answer_session_ids: &[String],
    moot_binary: &str,
    seed: u64,
    question_index: usize,
    arm: &LmeArm,
    judge_cmd: Option<&str>,
    encode_barrier: EncodeBarrier,
    cache_entry: Option<&Path>,
    scratch_posture: ScratchEstatePosture,
    strategy: ExactRecallStrategy,
    settle: bool,
) -> Result<LmeQuestionResult, MCPError> {
    // ── Cache restore attempt (when cache mode is Reuse) ──────────────────────
    // Try to restore a previously-snapshotted estate for this question. On hit,
    // skip ingest and drain entirely. On miss, fall through to normal ingest.
    // The posture marker travels with the snapshot; restore asserts it matches.
    let cache_restore: Option<(PathBuf, Vec<LmeManifestEntry>)> =
        cache_entry.and_then(|entry| {
            restore_estate_cache_entry(entry, scratch_posture, || {
                lme_scratch_dir(seed, question_index, scratch_posture)
                    .map_err(|e| e.description.clone())
            })
        });

    let (scratch, mut manifest, skip_ingest, cache_hit): (PathBuf, Vec<LmeManifestEntry>, bool, Option<bool>) =
        if let Some((s, m)) = cache_restore {
            (s, m, true, Some(true))
        } else {
            let is_cache_miss = cache_entry.is_some();
            let s = lme_scratch_dir(seed, question_index, scratch_posture)?;
            (s, Vec::new(), false, if is_cache_miss { Some(false) } else { None })
        };

    let guard = DegeneracyGuard::new();
    let verb_map = lme_verb_map();
    let endpoint = lme_endpoint_config(&scratch, moot_binary);

    let mut client = MCPClient::new(endpoint);
    client.connect().map_err(|e| {
        // Teardown best-effort; original connect error is the useful signal.
        let _ = lme_guarded_teardown(&scratch);
        e
    })?;

    // ── Ingest haystack (skip on cache hit) ───────────────────────────────────
    let mut write_latencies: Vec<f64> = Vec::new();
    // On cache hit, turns_ingested reflects the manifest loaded from cache.
    let mut turns_ingested: usize = if skip_ingest { manifest.len() } else { 0 };

    if !skip_ingest {
        'sessions: for (session_index, (session_id, session_turns)) in
            haystack_session_ids.iter().zip(haystack_sessions.iter()).enumerate()
        {
            for (turn_index, turn) in session_turns.iter().enumerate() {
                // Build the content string: role-tagged turn text.
                let content = format!("[{}] {}", turn.role, turn.content);
                match ingest_turn(&mut client, &verb_map, &content, encode_barrier) {
                    Ok((uuid, latency)) => {
                        manifest.push(LmeManifestEntry {
                            uuid,
                            session_id: session_id.clone(),
                            turn_index,
                            session_index,
                            role: turn.role.clone(),
                        });
                        write_latencies.push(latency);
                        turns_ingested += 1;
                    }
                    Err(e) => {
                        // Ingest failure → short-circuit; guard will fire.
                        eprintln!(
                            "  [lme] ingest error for {question_id} session {session_id} turn {turn_index}: {}",
                            e.description
                        );
                        break 'sessions;
                    }
                }
            }
        }
    }

    let write_mean_latency = if write_latencies.is_empty() {
        0.0
    } else {
        write_latencies.iter().sum::<f64>() / write_latencies.len() as f64
    };

    // ── Drain barrier (EncodeBarrier::Drain mode; skipped on cache hit) ───────
    // After all ingest completes, wait for background encoding to drain before
    // issuing any recall query. Prevents background-encoding races that produce
    // artificially low recall scores. On a cache hit the estate is already
    // committed — no drain needed.
    // Lane evidence for the report: None when the barrier did not run.
    let mut drain_lane_observed: Option<bool> = None;
    if !skip_ingest && encode_barrier == EncodeBarrier::Drain {
        let outcome = wait_for_encode_drain(&mut client, &format!("lme {}", question_id), 300.0);
        drain_lane_observed = Some(outcome.lane_observed);
    }

    // ── Snapshot to cache (on cache miss, after drain) ────────────────────────
    // Estate is fully committed at this point — safe to snapshot.
    if !skip_ingest {
        if let Some(entry) = cache_entry {
            save_estate_cache_entry(&scratch, &manifest, entry);
        }
    }

    // ── Probe for degeneracy guard ────────────────────────────────────────────
    // Guard probes always use the exact verbMap (moot_memory_search) regardless of arm —
    // the guard verifies estate health, not arm-specific retrieval quality.
    let probe_rankings = probe_mcp_client(&mut client, &verb_map);
    let guard_verdict = guard.classify(&probe_rankings);
    let guard_healthy = guard_verdict.discriminant() == "healthy";
    let guard_diagnostic = if guard_healthy {
        None
    } else {
        Some(guard_verdict.diagnostic().to_string())
    };

    // ── Exact arm: moot_memory_search ─────────────────────────────────────────
    // ORDER IS LOAD-BEARING: the exact-arm query MUST run before any
    // moot_distill call (Wave 1 rename from moot_consolidate). Distillation
    // writes on-row representations, after which the originals no longer surface
    // in default search (proven 2026-07-27: LME q1 answer rank 2 pre-distill,
    // absent from top-20 post-distill). Distilling first contaminated the
    // exact-arm measurement on two full grids. Twin of the Swift ordering note.
    let mut exact_payload_text: Option<String> = None;
    let mut exact_query_latency: Option<f64> = None;
    let mut retrieved_uuids: Vec<String> = Vec::new();
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
                args.insert("ordering".to_string(), JsonValue::String("byRelevanceDesc".to_string()));
            }
            if strategy == ExactRecallStrategy::Precise {
                let mut pargs: BTreeMap<String, JsonValue> = BTreeMap::new();
                pargs.insert(verb_map.query_arg.clone(), JsonValue::String(question_text.to_string()));
                match client.call_tool("moot_recall_precise", pargs, &verb_map.result_format) {
                    Ok(result) => {
                        retrieved_uuids = result.ordered_ids;
                        exact_payload_text = Some(result.text_blocks.join("\n"));
                    }
                    Err(e) => eprintln!("  [lme] precise query error for {question_id}: {}", e.description),
                }
            } else {
                match client.call_tool(&verb_map.query, args, &verb_map.result_format) {
                    Ok(result) => {
                        retrieved_uuids = result.ordered_ids;
                        // Capture raw payload text for token counting in the scorer.
                        exact_payload_text = Some(result.text_blocks.join("\n"));
                    }
                    Err(e) => {
                        eprintln!(
                            "  [lme] exact query error for {question_id}: {}",
                            e.description
                        );
                    }
                }
                // Documented escalation: low discrimination -> recall_precise.
                if strategy == ExactRecallStrategy::Auto
                    && exact_payload_text.as_deref().map_or(false, |t| t.contains("discrimination: low"))
                {
                    let mut pargs: BTreeMap<String, JsonValue> = BTreeMap::new();
                    pargs.insert(verb_map.query_arg.clone(), JsonValue::String(question_text.to_string()));
                    if let Ok(result) = client.call_tool("moot_recall_precise", pargs, &verb_map.result_format) {
                        if !result.ordered_ids.is_empty() {
                            retrieved_uuids = result.ordered_ids;
                            exact_payload_text = Some(result.text_blocks.join("\n"));
                        }
                    }
                }
            }
        }
        exact_query_latency = Some(query_start.elapsed().as_secs_f64());
    }

    // ── Dense arm: distill, then moot_recall_distilled ───────────────────────
    // Runs strictly AFTER the exact arm (see ordering note above) because
    // distillation mutates what default search returns. Wave 1: calls
    // moot_distill (the canonical name); moot_consolidate retired as the alias.
    let mut dense_payload_text: Option<String> = None;
    let mut dense_query_latency: Option<f64> = None;
    if arm == &LmeArm::Dense || arm == &LmeArm::Both {
        let distill_args: BTreeMap<String, JsonValue> = BTreeMap::new();
        if let Err(e) = client.call_tool("moot_distill", distill_args, &verb_map.result_format) {
            eprintln!(
                "  [lme] distill warning for {question_id}: {}",
                e.description
            );
            // Non-fatal: dense arm query may return empty results, but we continue.
        }
        let dense_verb_map = lme_dense_verb_map();
        let dense_start = Instant::now();
        let mut dense_args: BTreeMap<String, JsonValue> = BTreeMap::new();
        dense_args.insert(
            dense_verb_map.query_arg.clone(),
            JsonValue::String(question_text.to_string()),
        );
        // No constant_args for moot_recall_distilled (no location needed).
        match client.call_tool(&dense_verb_map.query, dense_args, &dense_verb_map.result_format) {
            Ok(result) => {
                // Capture raw payload text (joined text_blocks) for token counting.
                dense_payload_text = Some(result.text_blocks.join("\n"));
            }
            Err(e) => {
                eprintln!(
                    "  [lme] dense query error for {question_id}: {}",
                    e.description
                );
                dense_payload_text = Some(String::new()); // empty payload on error
            }
        }
        dense_query_latency = Some(dense_start.elapsed().as_secs_f64());
    }

    // ── Judge mode (Part 4): optional LLM-judged QA per arm ──────────────────
    // Soft errors from the judge subprocess are logged and skipped — a judge
    // failure does not fail the question; the answer fields stay None.
    let mut exact_judge_answer: Option<String> = None;
    let mut exact_judge_correct: Option<bool> = None;
    if let Some(cmd) = judge_cmd {
        if let Some(ref payload) = exact_payload_text {
            if !payload.is_empty() {
                let prompt = lme_judge_prompt(question_text, payload);
                match lme_run_judge(cmd, &prompt) {
                    Ok(answer) => {
                        let correct = lme_grade_judge_answer(&answer, gold_answer);
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

    let mut dense_judge_answer: Option<String> = None;
    let mut dense_judge_correct: Option<bool> = None;
    if let Some(cmd) = judge_cmd {
        if let Some(ref payload) = dense_payload_text {
            if !payload.is_empty() {
                let prompt = lme_judge_prompt(question_text, payload);
                match lme_run_judge(cmd, &prompt) {
                    Ok(answer) => {
                        let correct = lme_grade_judge_answer(&answer, gold_answer);
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
        if let Err(e) = client.call_tool("moot_reindex", reindex_args, &verb_map.result_format) {
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
        if strategy == ExactRecallStrategy::Relevance || strategy == ExactRecallStrategy::Auto {
            sargs.insert(
                "ordering".to_string(),
                JsonValue::String("byRelevanceDesc".to_string()),
            );
        }
        if strategy == ExactRecallStrategy::Precise {
            let mut pargs: BTreeMap<String, JsonValue> = BTreeMap::new();
            pargs.insert(
                verb_map.query_arg.clone(),
                JsonValue::String(question_text.to_string()),
            );
            if let Ok(r) = client.call_tool("moot_recall_precise", pargs, &verb_map.result_format) {
                settled_retrieved_uuids = Some(r.ordered_ids);
            }
        } else {
            if let Ok(r) = client.call_tool(&verb_map.query, sargs, &verb_map.result_format) {
                let payload = r.text_blocks.join("\n");
                settled_retrieved_uuids = Some(r.ordered_ids);
                // Documented escalation for auto strategy.
                if strategy == ExactRecallStrategy::Auto
                    && payload.contains("discrimination: low")
                {
                    let mut pargs: BTreeMap<String, JsonValue> = BTreeMap::new();
                    pargs.insert(
                        verb_map.query_arg.clone(),
                        JsonValue::String(question_text.to_string()),
                    );
                    if let Ok(pr) = client.call_tool("moot_recall_precise", pargs, &verb_map.result_format) {
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
    if let Err(e) = lme_guarded_teardown(&scratch) {
        eprintln!(
            "  [lme] teardown warning for {question_id}: {}",
            e.description
        );
    }

    Ok(LmeQuestionResult {
        question_id: question_id.to_string(),
        question_type: question_type.to_string(),
        query_latency_seconds: exact_query_latency,
        retrieved_uuids,
        manifest,
        answer_session_ids: answer_session_ids.to_vec(),
        guard_healthy,
        guard_diagnostic,
        turns_ingested,
        write_mean_latency_seconds: write_mean_latency,
        exact_payload_text,
        dense_payload_text,
        dense_query_latency_seconds: dense_query_latency,
        exact_judge_answer,
        exact_judge_correct,
        dense_judge_answer,
        dense_judge_correct,
        cache_hit,
        drain_lane_observed,
        settled_retrieved_uuids,
        settled_query_latency_seconds,
        settled_drain_lane_observed,
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Top-level question runner
// ─────────────────────────────────────────────────────────────────────────────

/// Runs the LME harness over a slice of questions.
///
/// Questions are run in sequence (one mootx01 instance per question). Progress
/// is printed to stderr: one line per question. Returns a `Vec<LmeQuestionResult>`
/// in the same order as the input slice.
pub fn run_lme_questions(
    corpus: &LmeCorpus,
    config: &LmeRunConfig,
) -> Vec<LmeQuestionResult> {
    // ── Build the question list ───────────────────────────────────────────────
    let mut indices: Vec<usize> = (0..corpus.questions.len()).collect();
    let mut rng = SplitMix64::new(config.seed);
    rng.shuffle(&mut indices);
    if let Some(limit) = config.limit {
        indices.truncate(limit);
    }

    let total = indices.len();
    let mut results: Vec<LmeQuestionResult> = Vec::with_capacity(total);

    // ── Estate cache setup (once per run) ────────────────────────────────────
    let binary_fingerprint = if config.estate_cache == EstateCacheMode::Reuse {
        moot_binary_fingerprint(&config.moot_binary)
    } else {
        String::new()
    };
    let resolved_cache_dir = config
        .cache_dir
        .as_deref()
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| default_cache_dir(config.out_dir.as_deref()));

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
        let cache_entry_opt: Option<PathBuf> = if config.estate_cache == EstateCacheMode::Reuse {
            Some(estate_cache_entry_path(
                &resolved_cache_dir,
                "longmemeval",
                &config.variant,
                config.seed,
                config.encode_barrier,
                &binary_fingerprint,
                config.scratch_posture,
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
            &q.haystack_session_ids,
            &q.haystack_sessions,
            &q.answer_session_ids,
            &config.moot_binary,
            config.seed,
            question_index,
            &config.arm,
            config.judge_cmd.as_deref(),
            config.encode_barrier,
            cache_entry_opt.as_deref(),
            config.scratch_posture,
            config.exact_strategy,
            config.settle,
        ) {
            Ok(result) => {
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
                eprintln!("  ERROR (skipping): {}", e.description);
                // Emit a guard-excluded result so the question shows in corpus_stats.
                results.push(LmeQuestionResult {
                    question_id: q.question_id.clone(),
                    question_type: q.question_type.clone(),
                    query_latency_seconds: None,
                    retrieved_uuids: vec![],
                    manifest: vec![],
                    answer_session_ids: q.answer_session_ids.clone(),
                    guard_healthy: false,
                    guard_diagnostic: Some(e.description),
                    turns_ingested: 0,
                    write_mean_latency_seconds: 0.0,
                    exact_payload_text: None,
                    dense_payload_text: None,
                    dense_query_latency_seconds: None,
                    exact_judge_answer: None,
                    exact_judge_correct: None,
                    dense_judge_answer: None,
                    dense_judge_correct: None,
                    cache_hit: None,
                    drain_lane_observed: None,
                    settled_retrieved_uuids: None,
                    settled_query_latency_seconds: None,
                    settled_drain_lane_observed: None,
                });
            }
        }
    }

    results
}
