//! locomo_runner.rs — live harness driving mootx01 for LoCoMo benchmarking.
//!
//! Rust twin of `LoCoMoRunner.swift`. Implements the per-CONVERSATION estate
//! strategy that differs from the per-question LME approach:
//!
//! - LME model:    1 question  → 1 restored estate → 1 query
//! - LoCoMo model: 1 conversation → 1 restored estate → N queries
//!
//! This lane MEASURES prebuilt artifacts only: the seeding pipeline
//! (`benchmarks/seeding/`, BENCHMARK_ESTATES.md §9) owns artifact building.
//!
//! # Estate lifecycle per conversation
//!
//! 1. Restore the conversation's prebuilt settled estate into a scratch dir
//!    under `/tmp/locomo-bench-<seed>-<conv_index>` (a missing artifact is a
//!    hard error).
//! 2. Launch mootx01 via `MCPClient` pointing at that dir.
//! 3. Run DegeneracyGuard probe via the leg sampler (real MCP calls on the
//!    first estate only; LegGuardSampler caches the verdict for the rest of the leg).
//! 4. Issue one query per selected question in this conversation.
//! 5. Disconnect client, tear down scratch dir.
//!
//! The `encode_barrier` field in `LoCoMoRunConfig` addresses the artifact
//! namespace (the cache key's `barrier_` segment) — barriers themselves run
//! at artifact build time in the seeding pipeline.

use crate::config::{EndpointConfig, EndpointRole, ResultFormat, Transport, VerbMap};
use crate::degeneracy_guard::LegGuardSampler;
use crate::encode_barrier::EncodeBarrier;
use crate::estate_cache::{
    estate_cache_entry_path, restore_estate_cache_entry, EstateCacheMode,
};
use crate::json_value::JsonValue;
use crate::locomo_corpus::{LoCoMoCorpus, LoCoMoQuestion};
use crate::locomo_scorer::{LoCoMoManifestEntry, LoCoMoQuestionResult};
use crate::longmemeval_runner::{probe_mcp_client, SplitMix64};
use crate::mcp_client::{MCPClient, MCPError, ToolCaller};
use crate::reranker::apply_rerank;
use crate::scratch_posture::{moot_serve_command, ScratchEstatePosture};
use crate::seed_export::SeedPathMode;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Instant;

// ─────────────────────────────────────────────────────────────────────────────
// Estate shape enum (C1, benchmark reset 2026-08-13)
// ─────────────────────────────────────────────────────────────────────────────

/// Backend persistence shape for LoCoMo benchmark estates.
///
/// Twin of Swift `LoCoMoEstateShape`. Selects the mootx01 backend via the
/// `--in-memory` flag appended to the serve command.
///
/// - `Disk` (default): SQLite-backed estate. Compatible with `--estate-cache reuse|require`.
/// - `Ram`: In-memory estate (`--in-memory`). No disk writes; no keychain
///   contact. Incompatible with `--estate-cache reuse|require`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EstateShape {
    /// SQLite-backed estate (default). Compatible with estate cache.
    Disk,
    /// In-memory estate. Appends `--in-memory` to the serve command. Zero
    /// disk I/O; incompatible with `--estate-cache reuse|require`.
    Ram,
}

impl EstateShape {
    /// Raw value string used in CLI flag parsing and report JSON.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Disk => "disk",
            Self::Ram  => "ram",
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Recall strategy enum (PR-08 D1)
// ─────────────────────────────────────────────────────────────────────────────

/// Which MCP verb drives the per-question recall queries.
///
/// Twin of Swift `LoCoMoRecallStrategy`. Raw values match CLI flag strings and
/// the strategy suffix appended to run labels (`.search` produces no suffix —
/// preserving byte-stable label behaviour for all prior LoCoMo runs).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoCoMoRecallStrategy {
    /// `moot_memory_search` with the locomo location filter (default). Run label
    /// has no strategy suffix — all prior LoCoMo runs used this path and their
    /// labels remain unchanged.
    Search,
    /// `moot_recall_shaped` with optional preset. Steers the signed-weight
    /// fusion engine. Run label carries "-shaped" (and "-<preset>" when set).
    Shaped,
    /// `moot_recall_precise`. Precision-retrieval mode. Run label carries "-precise".
    Precise,
}

impl LoCoMoRecallStrategy {
    /// CLI flag / raw value string for this strategy.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Search  => "search",
            Self::Shaped  => "shaped",
            Self::Precise => "precise",
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Run configuration
// ─────────────────────────────────────────────────────────────────────────────

/// Configuration for one LoCoMo run. Constructed by main.rs from CLI flags.
pub struct LoCoMoRunConfig {
    pub moot_binary: String,
    pub seed: u64,
    pub limit: Option<usize>,
    /// Skip this many questions from the seeded-shuffled list (for batched runs).
    pub offset: usize,
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
    pub label: Option<String>,
    pub out_dir: Option<PathBuf>,
    /// Encode-queue synchronization strategy. Default EncodeBarrier::Drain.
    pub encode_barrier: EncodeBarrier,
    /// Estate snapshot reuse mode. Default EstateCacheMode::Off.
    pub estate_cache: EstateCacheMode,
    /// Cache root directory. None = <out-dir>/estate-cache (or <cwd>/estate-cache).
    pub cache_dir: Option<PathBuf>,
    /// At-rest posture for scratch estates. Default PlaintextTransient (the
    /// transient record is plaintext; no keychain contact). Recorded in the
    /// report JSON as "estate_encryption".
    pub scratch_posture: ScratchEstatePosture,
    // MARK: Recall strategy (PR-08 D1)
    /// Which MCP verb drives the per-question recall queries. Default
    /// `Search` preserves the byte-stable label behaviour of all prior runs.
    /// Recorded in the report as "recall_strategy".
    pub strategy: LoCoMoRecallStrategy,
    /// Named RecallShape preset for `Shaped` strategy. nil uses the product
    /// default (balanced, unsteered). Ignored for `Search` and `Precise`.
    /// Recorded in the report as "recall_shape".
    pub recall_shape: Option<String>,
    // MARK: Rerank (additive — W2-rerank)
    /// Optional command for post-retrieval reranking. PRESENCE ONLY in report.
    /// May carry API keys — never log, hash, or derive from it.
    /// Twin of Swift `LoCoMoRunConfig.rerankCmd`.
    pub rerank_cmd: Option<String>,
    /// Seed-path namespace of the artifacts this run restores (`--seed-path`,
    /// default batch). Addresses the estate-cache key's `seedpath_` segment
    /// only — a batch-built and a live-built estate are different estate
    /// shapes and live in different cache namespaces.
    /// Twin of Swift `LoCoMoRunConfig.seedPath`.
    pub seed_path: SeedPathMode,
    /// Guard probe sampling policy for this leg. Default `OncePerLeg` probes on the
    /// first question only. Use `PerUnit` only for debugging.
    /// Twin of Swift `LoCoMoRunConfig.guardSamplingPolicy`.
    pub guard_sampling_policy: crate::degeneracy_guard::GuardSamplingPolicy,
    /// SHA-256 of the corpus fixture (B2 provenance). Computed once at
    /// main.rs load time; "unknown" never validates.
    pub corpus_digest: String,
    // C1/C6 additions (benchmark reset 2026-08-13) ──────────────────────────
    /// Backend persistence shape (--shape disk|ram). `Disk` (default) uses the
    /// normal SQLite backend. `Ram` appends `--in-memory` to the serve command,
    /// selecting PersistenceKit's InMemory backend. Incompatible with
    /// `--estate-cache reuse|require`.
    /// Recorded in the report JSON as `"shape"`. Twin of Swift
    /// `LoCoMoRunConfig.shape`.
    pub shape: EstateShape,
    /// Maximum conversations processed concurrently (--parallel N). Default =
    /// max(1, 80% of logical cores). 1 = serial behaviour. Each worker owns its
    /// own estate and MCP client; the per-question inner loop is serial within
    /// a conversation. Recorded in the report JSON as `"parallel_units"`.
    /// Twin of Swift `LoCoMoRunConfig.parallelConversations`.
    pub parallel_units: usize,
}

// ─────────────────────────────────────────────────────────────────────────────
// Verb map for LoCoMo
// ─────────────────────────────────────────────────────────────────────────────

/// Returns the VerbMap for the LoCoMo harness.
///
/// `location: "benchmarks/locomo"` is the write constant — all conversation
/// memories are filed in the locomo wing, isolated from the operator's real
/// memories and from other benchmark runs.
///
/// Twin of Swift `loCoMoMootVerbMap`.
pub fn locomo_verb_map() -> VerbMap {
    let mut constant_args = BTreeMap::new();
    constant_args.insert("location".to_string(), "benchmarks/locomo".to_string());
    VerbMap::new(
        crate::aria_v2_surface::FILE_MEMORY,
        crate::aria_v2_surface::MEMORY_SEARCH,
        None, // list: not used in LoCoMo
        None, // fetch: not used in LoCoMo
        None, // content_arg: defaults to "content"
        None, // query_arg: defaults to "query"
        Some(constant_args),
        Some(ResultFormat::MootV2),
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// Scratch dir management
// ─────────────────────────────────────────────────────────────────────────────

/// Creates a fresh, hardened scratch directory for one conversation's mootx01
/// instance. Path: `/tmp/locomo-bench-<seed_hex>-<conv_index_hex>`.
///
/// The deterministic naming ensures each conversation has a unique path
/// even across retries, and the fixed prefix enables guarded teardown.
///
/// Hardening added in E3 (mirrors membench_scratch_dir):
/// - `symlink_metadata` (lstat-equivalent) checks the created entry is a real
///   directory, not a symlink an attacker raced to create at the deterministic
///   path before the harness run.
/// - `canonicalize` resolves any `..` components; the canonical form is what
///   callers store and pass back to `locomo_guarded_teardown`.
///
/// `posture` decides the at-rest encryption of the estate this dir will hold
/// and rides on the serve command (see scratch_posture.rs). No default on purpose: every call site
/// decides posture explicitly.
///
/// Twin of Swift `loCoMoScratchDir(posture:)`.
pub fn locomo_scratch_dir(
    seed: u64,
    conv_index: usize,
    posture: ScratchEstatePosture,
) -> Result<PathBuf, MCPError> {
    let name = format!("locomo-bench-{seed:016x}-{conv_index:08x}");
    let path = PathBuf::from("/tmp").join(&name);
    std::fs::create_dir_all(&path).map_err(|e| MCPError {
        description: format!("failed to create scratch dir {}: {e}", path.display()),
    })?;

    // Reject symlinked paths: an attacker could race to replace the created
    // directory with a symlink. `symlink_metadata` is the lstat equivalent.
    let lstat = std::fs::symlink_metadata(&path).map_err(|e| MCPError {
        description: format!("locomo_scratch_dir: cannot stat {}: {e}", path.display()),
    })?;
    if lstat.file_type().is_symlink() {
        return Err(MCPError {
            description: format!(
                "locomo_scratch_dir: SAFETY: '{}' is a symlink — refusing to use as scratch estate",
                path.display()
            ),
        });
    }

    // Canonicalize and verify containment within the expected prefix.
    let canonical = std::fs::canonicalize(&path).map_err(|e| MCPError {
        description: format!("locomo_scratch_dir: cannot canonicalize {}: {e}", path.display()),
    })?;
    // Compare against the canonicalized temp base, never a literal "/tmp/"
    // prefix: macOS resolves /tmp to /private/tmp, so the literal check
    // rejected every legitimate directory (Wave-3 G3).
    let expected = crate::config::canonical_tmp_base().join(&name);
    if canonical != expected {
        return Err(MCPError {
            description: format!(
                "locomo_scratch_dir: SAFETY: canonicalized path '{}' is not the expected scratch dir '{}'",
                canonical.display(),
                expected.display()
            ),
        });
    }

    // The posture is the record's: a transient record is plaintext by rule.
    let _ = posture;
    Ok(canonical)
}

/// Removes a scratch directory created by `locomo_scratch_dir`.
///
/// Guard: path must begin with the canonical temp base + `locomo-bench-`
/// AND must not be a symlink.
/// Hardening added in E3: explicit symlink check on top of the prefix guard —
/// belt and suspenders mirroring membench_guarded_teardown.
///
/// Twin of Swift `loCoMoGuardedTeardown(_:)`.
pub fn locomo_guarded_teardown(path: &Path) -> Result<(), MCPError> {
    // Prefix built from the canonicalized temp base (Wave-3 G3): callers
    // hold canonical paths (/private/tmp/… on macOS), so a literal "/tmp/"
    // prefix check would refuse every legitimate teardown.
    let expected_prefix = crate::config::canonical_tmp_base()
        .join("locomo-bench-")
        .to_string_lossy()
        .into_owned();
    let path_str = path.to_string_lossy();
    if !path_str.starts_with(&expected_prefix) {
        return Err(MCPError {
            description: format!(
                "SAFETY: locomo_guarded_teardown refused to delete '{}' — \
                 path must have the {} prefix. \
                 Only directories created by locomo_scratch_dir() may be torn down.",
                path.display(),
                expected_prefix
            ),
        });
    }
    // Refuse to tear down a symlink (belt and suspenders — creation-time checks
    // should prevent this, but a second check costs nothing).
    if let Ok(meta) = std::fs::symlink_metadata(path) {
        if meta.file_type().is_symlink() {
            return Err(MCPError {
                description: format!(
                    "SAFETY: locomo_guarded_teardown refused symlink '{}' — \
                     only real directories may be torn down",
                    path.display()
                ),
            });
        }
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

/// Builds an `EndpointConfig` for the LoCoMo harness pointing at `scratch_dir`.
///
/// Command form: `[KEY=VALUE …] <binary> serve --db <scratch_dir> [--in-memory]`.
///
/// `shape` controls the backend: `Ram` appends `--in-memory` so mootx01 routes
/// PersistenceKit to the InMemory backend instead of SQLite.
///
/// Twin of Swift `loCoMoEndpointConfig(scratchDir:mootBinaryPath:posture:shape:)`.
pub fn locomo_endpoint_config(
    scratch_dir: &Path,
    moot_binary: &str,
    posture: ScratchEstatePosture,
    shape: EstateShape,
) -> Result<EndpointConfig, String> {
    // The posture is the record's: a transient record is plaintext by rule.
    let _ = posture;
    let data_dir = scratch_dir.to_string_lossy();
    let command = moot_serve_command(moot_binary, Path::new(&*data_dir), shape == EstateShape::Ram, crate::scratch_posture::SCRATCH_SERVE_ENV, None)
        .map_err(|e| e.to_string())?;
    Ok(EndpointConfig {
        name: "mootx01-locomo".to_string(),
        transport: Transport::Stdio { command },
        auth: None,
        verb_map: locomo_verb_map(),
        role: EndpointRole::Both,
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Top-level conversation runner
// ─────────────────────────────────────────────────────────────────────────────

/// Returns `true` when a freshly built estate may be written to the artifact
/// cache. Used by the membench runner's build path (the gate lives here as
/// shared build-fitness policy).
///
/// An estate is unfit to cache when any of the following conditions is true:
/// - `ingest_error` is `Some`: ingest or attribution failed, leaving the manifest
///   partial or empty (finding #8).
/// - `settle_dream_ok` is `false`: the `moot_dream` call in the settle block
///   failed, leaving the estate unsettled (finding #10b).
/// - `settle_reindex_ok` is `false`: the `moot_reindex` call in the settle block
///   failed, leaving the basis vectors stale (finding #10b).
///
/// All three conditions are checked through a single gate at the cache write site
/// rather than three separate `if`s, so every new failure reason is explicitly
/// enumerated here and the gate remains coherent as the settle protocol evolves.
///
/// Tested directly by the `estate_fit_to_cache_*` unit tests.
pub fn estate_is_fit_to_cache(
    ingest_error: &Option<String>,
    settle_dream_ok: bool,
    settle_reindex_ok: bool,
) -> bool {
    ingest_error.is_none() && settle_dream_ok && settle_reindex_ok
}

/// Runs the LoCoMo harness over a slice of questions.
///
/// Per-conversation estate strategy:
///   1. Shuffle the question list with `SplitMix64(seed)`.
///   2. Apply offset and limit.
///   3. Group selected questions by `conversation_index`.
///   4. For each conversation (ascending index order):
///      a. Restore the conversation's prebuilt settled estate (a missing
///         artifact is a hard error — this lane never builds).
///      b. Run DegeneracyGuard probe via LegGuardSampler (real call on the
///         first estate of the leg only; cached verdict for subsequent estates).
///      c. Issue one query per selected question.
///      d. Teardown.
///   5. Return results in conversation-group order (deterministic with seed).
///
/// Twin of Swift `runLoCoMoQuestions(questions:conversations:config:)`.
pub fn run_locomo_questions(corpus: &LoCoMoCorpus, config: &LoCoMoRunConfig) -> Result<(Vec<LoCoMoQuestionResult>, u64, Option<String>), String> {
    // ── Shuffle and slice ─────────────────────────────────────────────────────
    let mut indices: Vec<usize> = (0..corpus.questions.len()).collect();
    // --ids pinned subset (before shuffle: same file → same units always).
    if let Some(ids) = &config.unit_ids {
        indices.retain(|&i| ids.contains(&corpus.questions[i].question_id));
    }
    let mut rng = SplitMix64::new(config.seed);
    rng.shuffle(&mut indices);

    // Apply offset.
    if config.offset > 0 {
        indices = indices.into_iter().skip(config.offset).collect();
    }
    // Apply limit.
    if let Some(limit) = config.limit {
        indices.truncate(limit);
    }

    // ── Group by conversation index ───────────────────────────────────────────
    let mut by_conv: BTreeMap<usize, Vec<&LoCoMoQuestion>> = BTreeMap::new();
    for &qi in &indices {
        let q = &corpus.questions[qi];
        by_conv.entry(q.conversation_index).or_default().push(q);
    }


    // ── Estate cache setup (computed once, reused per conversation) ───────────
    // B2: one provenance per run — staleness is DETECTED by artifact.json
    // validation on restore, not assumed via a binary fingerprint (B3).
    let run_provenance = crate::artifact_manifest::make_artifact_provenance(
        "locomo",
        "",
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

    // ── Parallel conversation processing (C6) ────────────────────────────────
    // BTreeMap keys are already in ascending order, so conv_keys is sorted.
    // Sorted order produces byte-deterministic output when results are
    // reassembled in slot order after all workers finish.
    //
    // Error semantics (cross-port asymmetry, intentional): per-item errors
    // here record stub results (guard_healthy=false) and CONTINUE, so a
    // parity run localizes the diff to the failing item. The Swift twin
    // aborts the whole run instead (throwing task group) — it is the
    // measurement instrument and refuses to produce a report with holes.
    let conv_keys: Vec<usize> = by_conv.keys().copied().collect();
    let total_convs = conv_keys.len();

    // One guard sampler shared across all threads via Mutex. LegGuardSampler
    // takes &mut self in probe(); Mutex serializes access. The first thread to
    // probe caches the verdict; all others pay zero MCP cost.
    let guard_sampler = std::sync::Mutex::new(LegGuardSampler::new(config.guard_sampling_policy));
    // C4: the leg-level timing text is captured at artifact BUILD time by the
    // seeding pipeline; this lane restores settled artifacts, so there is no
    // timing capture here and the run-level timing text is always None.

    // Work queue: (slot, conv_index) pairs. Slot is the position in conv_keys,
    // used to write results into a pre-allocated Vec without sorting after.
    let work_queue: std::sync::Mutex<std::collections::VecDeque<(usize, usize)>> =
        std::sync::Mutex::new(
            conv_keys.iter().enumerate().map(|(slot, &ci)| (slot, ci)).collect()
        );
    // Pre-allocated result slots: filled by workers in any order.
    let results_by_slot: std::sync::Mutex<Vec<Option<(Vec<LoCoMoQuestionResult>, u64)>>> =
        std::sync::Mutex::new((0..total_convs).map(|_| None).collect());

    // Clamp thread count: no point spawning more threads than conversations.
    let n_threads = config.parallel_units.min(total_convs.max(1));

    // Error channel: if any thread encounters a fatal endpoint config error,
    // it stores the message here. After the scope we propagate as Err.
    let endpoint_error: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);
    std::thread::scope(|s| {
        for _ in 0..n_threads {
            s.spawn(|| {
                loop {
                    let work = { work_queue.lock().unwrap().pop_front() };
                    let Some((slot, conv_index)) = work else { break; };

                    let conv_questions = &by_conv[&conv_index];
                    let conversation = &corpus.conversations[conv_index];
                    let all_turns = conversation.all_turns();
                    // Per-conversation accumulators. Stored in results_by_slot[slot]
                    // at the end of the loop body (or on each error-path continue).
                    let mut conv_results: Vec<LoCoMoQuestionResult> = Vec::new();
                    let mut conv_rerank_failures: u64 = 0;

        eprintln!(
            "[locomo] conv={} ({} questions, {} turns)",
            conversation.sample_id,
            conv_questions.len(),
            all_turns.len()
        );

        // ── Provision scratch estate (cache-aware) ────────────────────────────
        // Compute the cache entry path for this conversation (keyed by sample_id).
        let cache_entry_opt: Option<PathBuf> = if config.estate_cache != EstateCacheMode::Off {
            Some(estate_cache_entry_path(
                &resolved_cache_dir,
                "locomo",
                "",
                config.seed,
                config.encode_barrier,
                config.scratch_posture,
                config.seed_path,
                &conversation.sample_id,
            ))
        } else {
            None
        };

        // Restore the prebuilt artifact. B2 provenance mismatch is a HARD FAIL: the mismatch poisons every
        // question of this conversation loudly (this per-conv loop has no
        // error channel to abort the whole run without losing prior results;
        // the loud per-question failure text ensures the run cannot be read
        // as healthy).
        let cache_restore: Option<(PathBuf, Vec<LoCoMoManifestEntry>)> = match cache_entry_opt
            .as_ref()
        {
            Some(entry) => match restore_estate_cache_entry(
                entry,
                &run_provenance,
                || {
                    locomo_scratch_dir(config.seed, conv_index, config.scratch_posture)
                        .map_err(|e| e.description.clone())
                },
            ) {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("[locomo] FATAL provenance mismatch: {e}");
                    for q in conv_questions {
                        conv_results.push(LoCoMoQuestionResult {
                            question_id: q.question_id.clone(),
                            category_label: q.category_label().to_string(),
                            category: q.category,
                            query_latency_seconds: 0.0,
                            retrieved_uuids: vec![],
                            manifest: vec![],
                            evidence_dia_ids: q.evidence.clone(),
                            guard_healthy: false,
                            guard_diagnostic: Some(e.clone()),
                            guard_sampling_mode: config.guard_sampling_policy,
                            turns_ingested: 0,
                            write_mean_latency_seconds: 0.0,
                            payload_text: None,
                            cache_hit: None,
                            drain_lane_observed: None,
                        });
                    }
                    results_by_slot.lock().unwrap()[slot] = Some((conv_results, 0));
                    continue;
                }
            },
            None => None,
        };

        // This lane MEASURES prebuilt artifacts only (the seeding pipeline owns
        // artifact building). Any non-restore is fatal for this conversation's
        // questions — loud per-question failure; this loop has no whole-run
        // error channel.
        let (scratch, manifest, conv_cache_hit): (PathBuf, Vec<LoCoMoManifestEntry>, Option<bool>) =
            match cache_restore {
                Some((s, m)) => (s, m, Some(true)),
                None => {
                    let msg = match cache_entry_opt.as_ref() {
                        Some(entry) => crate::estate_cache::artifact_required_error(entry),
                        None => "the locomo lane measures prebuilt artifacts and has \
                                 no build path; run with --estate-cache require"
                            .to_string(),
                    };
                    eprintln!("[locomo] FATAL: {msg}");
                    for q in conv_questions {
                        conv_results.push(LoCoMoQuestionResult {
                            question_id: q.question_id.clone(),
                            category_label: q.category_label().to_string(),
                            category: q.category,
                            query_latency_seconds: 0.0,
                            retrieved_uuids: vec![],
                            manifest: vec![],
                            evidence_dia_ids: q.evidence.clone(),
                            guard_healthy: false,
                            guard_diagnostic: Some(msg.clone()),
                            guard_sampling_mode: config.guard_sampling_policy,
                            turns_ingested: 0,
                            write_mean_latency_seconds: 0.0,
                            payload_text: None,
                            cache_hit: Some(false),
                            drain_lane_observed: None,
                        });
                    }
                    results_by_slot.lock().unwrap()[slot] = Some((conv_results, 0));
                    continue;
                }
            };

        let verb_map = locomo_verb_map();
        let endpoint = match locomo_endpoint_config(&scratch, &config.moot_binary, config.scratch_posture, config.shape) {
            Ok(ep) => ep,
            Err(e) => {
                *endpoint_error.lock().unwrap() = Some(format!("locomo: endpoint config error: {e}"));
                return;
            }
        };
        // Belt-and-suspenders: verify --db points into /tmp before connecting.
        // Twin of Swift `assertScratchBackend(_:requirement:)` in LoCoMoRunner.
        crate::gauntlet_runner::assert_scratch_backend(
            &endpoint, &crate::gauntlet_runner::MOOT_SCRATCH_REQUIREMENT,
        );
        let mut client = MCPClient::new(endpoint);
        if let Err(e) = client.connect() {
            eprintln!("  [locomo] connect error for conv {conv_index}: {}", e.description);
            let _ = crate::key_residue::retire_scratch_estate(&scratch, locomo_guarded_teardown);
            for q in conv_questions {
                conv_results.push(LoCoMoQuestionResult {
                    question_id: q.question_id.clone(),
                    category_label: q.category_label().to_string(),
                    category: q.category,
                    query_latency_seconds: 0.0,
                    retrieved_uuids: vec![],
                    manifest: vec![],
                    evidence_dia_ids: q.evidence.clone(),
                    guard_healthy: false,
                    guard_diagnostic: Some(e.description.clone()),
                    guard_sampling_mode: config.guard_sampling_policy,
                    turns_ingested: 0,
                    write_mean_latency_seconds: 0.0,
                    payload_text: None,
                    cache_hit: None,
                    drain_lane_observed: None,
                });
            }
            results_by_slot.lock().unwrap()[slot] = Some((conv_results, 0));
            continue;
        }

        // ── Ingested-turn accounting from the restored manifest ──────────────
        // The estate arrives fully ingested and settled (drain → dream → basis
        // retrain happen at artifact build time in the seeding pipeline), so
        // there is no write phase here: write latency is 0 and no drain
        // barrier runs.
        let ingest_error: Option<String> = None;
        let ingest_count: usize = manifest.len();
        let write_mean: f64 = 0.0;
        let drain_lane_observed: Option<bool> = None;

        // ── DegeneracyGuard probe, delegated to the leg sampler ───────────────
        // Probes on the first estate only (OncePerLeg default) and caches the
        // verdict for the rest of the leg at zero MCP cost.
        // The sampler is behind a Mutex (shared across threads); each probe call
        // holds the lock only for the duration of the actual MCP call on the
        // first probe (cache hit = lock+read+unlock, sub-microsecond).
        let (guard_healthy, sampled_diagnostic, _was_probed) =
            guard_sampler.lock().unwrap().probe(|| probe_mcp_client(&mut client, &verb_map));
        let guard_diagnostic = if let Some(err) = &ingest_error {
            // Ingest failure supersedes guard verdict.
            Some(format!("ingest_error: {err}"))
        } else {
            sampled_diagnostic
        };
        let effective_guard_healthy = ingest_error.is_none() && guard_healthy;

        eprintln!(
            "  guard={} turns={} write_mean_ms={:.0}",
            if effective_guard_healthy { "healthy" } else { "GUARD_FAIL" },
            ingest_count,
            write_mean * 1000.0
        );

        // ── Query each selected question ──────────────────────────────────────
        for q in conv_questions {
            let (mut retrieved_uuids, raw_text_blocks, query_latency, payload_text) = if effective_guard_healthy {
                // Dispatch based on the run's recall strategy (PR-08 D1).
                // - Search: moot_memory_search with location filter (default, byte-stable).
                // - Shaped: moot_recall_shaped with optional preset.
                // - Precise: moot_recall_precise.
                let (tool_name, result_format, call_args) = match config.strategy {
                    LoCoMoRecallStrategy::Search => {
                        // Environment seam: an override spec replaces the
                        // standard query call; None is byte-identical.
                        let (tool, args) = crate::retrieval_call_spec::seam_call(
                            &verb_map, config.retrieval_call.as_ref(), &q.question);
                        (tool, verb_map.result_format.clone(), args)
                    }
                    LoCoMoRecallStrategy::Shaped => {
                        let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
                        args.insert("query".to_string(), JsonValue::String(q.question.clone()));
                        if let Some(preset) = &config.recall_shape {
                            args.insert("preset".to_string(), JsonValue::String(preset.clone()));
                        }
                        (crate::aria_v2_surface::RECALL_SHAPED.to_string(), ResultFormat::MootV2, args)
                    }
                    LoCoMoRecallStrategy::Precise => {
                        let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
                        args.insert("query".to_string(), JsonValue::String(q.question.clone()));
                        (crate::aria_v2_surface::RECALL_PRECISE.to_string(), ResultFormat::MootV2, args)
                    }
                };
                let start = Instant::now();
                let (uuids, raw_text_blocks, raw_payload) = match client.call_tool(&tool_name, call_args, &result_format)
                    .map(|r| crate::payload_arm::strip_tool_result(config.payload_arm, r)) {
                    Ok(result) => {
                        let blocks = result.text_blocks.clone();
                        let payload = if result.text_blocks.is_empty() {
                            None
                        } else {
                            Some(result.text_blocks.join("\n"))
                        };
                        (result.ordered_ids, blocks, payload)
                    },
                    Err(e) => {
                        eprintln!(
                            "  [locomo] query error for {}: {}",
                            q.question_id, e.description
                        );
                        (vec![], vec![], None)
                    }
                };
                let latency = start.elapsed().as_secs_f64();
                eprintln!(
                    "  q={} cat={} query_ms={:.0}",
                    q.question_id, q.category_label(), latency * 1000.0
                );
                (uuids, raw_text_blocks, latency, raw_payload)
            } else {
                (vec![], vec![], 0.0, None)
            };

            // Post-retrieval reranking — inserts between retrieval and scoring.
            // payload_text is kept unchanged for diagnostics; only retrieved_uuids is reordered.
            if let Some(ref cmd) = config.rerank_cmd {
                let (reranked, failed) = apply_rerank(cmd, &q.question, &retrieved_uuids, &raw_text_blocks);
                retrieved_uuids = reranked;
                if failed {
                    conv_rerank_failures += 1;
                }
            }

            conv_results.push(LoCoMoQuestionResult {
                question_id: q.question_id.clone(),
                category_label: q.category_label().to_string(),
                category: q.category,
                query_latency_seconds: query_latency,
                retrieved_uuids,
                manifest: manifest.clone(),
                evidence_dia_ids: q.evidence.clone(),
                guard_healthy: effective_guard_healthy,
                guard_sampling_mode: config.guard_sampling_policy,
                guard_diagnostic: guard_diagnostic.clone(),
                turns_ingested: ingest_count,
                write_mean_latency_seconds: write_mean,
                payload_text,
                // All questions in the same conversation share the same cache_hit status:
                // the cache key is per-conversation (not per-question).
                cache_hit: conv_cache_hit,
                drain_lane_observed,
            });
        }

        // ── Teardown ──────────────────────────────────────────────────────────
        client.disconnect();
        // Retirement = teardown + zero-residual-key verification.
        if let Err(e) = crate::key_residue::retire_scratch_estate(&scratch, locomo_guarded_teardown) {
            eprintln!(
                "  [locomo] teardown warning for conv {}: {}",
                conversation.sample_id, e.description
            );
        }
        // Store this conversation's results in the pre-allocated slot so the
        // reassembly pass below can walk slots in order without sorting.
        results_by_slot.lock().unwrap()[slot] = Some((conv_results, conv_rerank_failures));
                } // closes thread `loop` (exits when work_queue is empty)
            });       // closes s.spawn closure
        }             // closes for _ in 0..n_threads
    });               // closes std::thread::scope — all workers joined here

    // Propagate any endpoint-config refusal (e.g. whitespace in scratch path).
    // The thread stored the message; we return Err so main() exits 1 not 101.
    if let Some(err) = endpoint_error.into_inner().unwrap() {
        return Err(err);
    }

    // ── Reassemble in slot order (= ascending conv_index order) ─────────────
    // conv_keys was built from a BTreeMap, so slots are already sorted by
    // conv_index. Walking slots in order gives byte-deterministic output.
    let raw_slots = results_by_slot.into_inner().unwrap();
    let mut all_results: Vec<LoCoMoQuestionResult> = Vec::with_capacity(
        raw_slots.iter().filter_map(|s| s.as_ref()).map(|(v, _)| v.len()).sum()
    );
    let mut rerank_failures: u64 = 0;
    for slot_opt in raw_slots {
        if let Some((mut conv_r, conv_f)) = slot_opt {
            all_results.append(&mut conv_r);
            rerank_failures += conv_f;
        }
    }

    // C4: the timing report is captured at artifact build time by the seeding
    // pipeline; the restore-only lane has none.
    Ok((all_results, rerank_failures, None))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scratch_posture::ScratchEstatePosture;

    // Wave-3 G3: scratch-path containment must compare against the
    // CANONICALIZED temp base. On macOS /tmp resolves to /private/tmp, so
    // the pre-fix literal "/tmp/…" comparison rejected every legitimate
    // scratch dir on the platform the overnight cells run on.

    #[test]
    fn scratch_dir_succeeds_under_real_temp_base() {
        let seed: u64 = 0xB3B3_0001;
        let dir = locomo_scratch_dir(seed, 7, ScratchEstatePosture::PlaintextTransient)
            .expect("a legitimate scratch dir must be accepted on macOS and Linux alike");
        assert!(dir.exists(), "scratch dir must exist");
        assert!(
            dir.starts_with(crate::config::canonical_tmp_base()),
            "returned path must live under the canonical temp base; got {}",
            dir.display()
        );
        locomo_guarded_teardown(&dir).expect("teardown must accept the canonical path it minted");
        assert!(!dir.exists(), "teardown must remove the dir");
    }

    #[test]
    fn scratch_dir_rejects_preplaced_symlink() {
        let seed: u64 = 0xB3B3_0002;
        let name = format!("locomo-bench-{seed:016x}-{:08x}", 3usize);
        let link = std::path::PathBuf::from("/tmp").join(&name);
        let real_target = std::env::temp_dir().join(format!("locomo-symlink-target-{seed:x}"));
        let _ = std::fs::remove_file(&link);
        let _ = std::fs::remove_dir_all(&link);
        std::fs::create_dir_all(&real_target).expect("create symlink target");
        #[cfg(unix)]
        std::os::unix::fs::symlink(&real_target, &link).expect("pre-place symlink");

        let result = locomo_scratch_dir(seed, 3, ScratchEstatePosture::PlaintextTransient);
        assert!(result.is_err(), "a pre-placed symlink at the scratch path must be rejected");

        let _ = std::fs::remove_file(&link);
        let _ = std::fs::remove_dir_all(&real_target);
    }

    #[test]
    fn guarded_teardown_refuses_paths_outside_base() {
        assert!(
            locomo_guarded_teardown(std::path::Path::new("/etc")).is_err(),
            "teardown must refuse a path outside the scratch prefix"
        );
        assert!(
            locomo_guarded_teardown(std::path::Path::new("/tmp/../etc/locomo-bench-x")).is_err(),
            "teardown must refuse a traversal path"
        );
    }

    // ── Cache-fitness gate tests (gate lives here; used by membench's build path) ──

    #[test]
    fn estate_fit_to_cache_clean_estate_is_fit() {
        // All conditions met: no ingest error, dream OK, reindex OK.
        assert!(
            estate_is_fit_to_cache(&None, true, true),
            "an estate with no errors must be fit to cache"
        );
    }

    #[test]
    fn estate_fit_to_cache_ingest_error_blocks_write() {
        // Finding #8: an ingest/attribution error must prevent the cache write.
        assert!(
            !estate_is_fit_to_cache(&Some("import id map unavailable: missing row".to_string()), true, true),
            "an ingest error must make the estate unfit to cache"
        );
    }

    #[test]
    fn estate_fit_to_cache_dream_failure_blocks_write() {
        // Finding #10(b): a settle-dream failure must prevent the cache write
        // so the cached artifact is always a settled estate.
        assert!(
            !estate_is_fit_to_cache(&None, false, true),
            "a dream failure during settle must make the estate unfit to cache"
        );
    }

    #[test]
    fn estate_fit_to_cache_reindex_failure_blocks_write() {
        // Finding #10(b): a settle-reindex failure must prevent the cache write.
        assert!(
            !estate_is_fit_to_cache(&None, true, false),
            "a reindex failure during settle must make the estate unfit to cache"
        );
    }
}
