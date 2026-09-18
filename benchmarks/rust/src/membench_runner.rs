//! membench_runner.rs — live harness driving mootx01 for MemBench benchmarking.
//!
//! Rust twin of `MemBenchRunner.swift`. Implements the PER-ITEM estate strategy
//! (parallel to the LME per-question model):
//!
//! - LME model:     1 question → 1 scratch estate → ingest haystack → 1 query
//! - MemBench model: 1 item   → 1 scratch estate → ingest all sessions → 1 query
//!
//! Each item's conversation is independent — items do not share sessions —
//! so per-item estate isolation is the correct granularity.
//!
//! # Estate lifecycle per item
//!
//! 1. Create scratch dir under `/tmp/membench-bench-<seed>-<item_index>`.
//! 2. Launch mootx01 via `MCPClient` pointing at that dir.
//! 3. Ingest all turns from all sessions (impatient or drain barrier mode).
//! 4. Trigger `moot_dream` (full association sweep).
//! 5. Run DegeneracyGuard probe.
//! 6. Issue one query with the item's QA question.
//! 7. Disconnect client, tear down scratch dir.
//!
//! # Encode barrier
//!
//! The `encode_barrier` field in `MemBenchRunConfig` controls encode synchronization:
//!   - `Drain` (default): poll `moot_drain_status` after all ingest completes.
//!   - `Impatient`: per-turn `impatient: true` inline encoding.
//!   - `None`: no barrier — documents the background-encoding race.

use crate::config::{EndpointConfig, EndpointRole, ResultFormat, Transport, VerbMap};
use crate::degeneracy_guard::LegGuardSampler;
use crate::encode_barrier::{EncodeBarrier, wait_for_encode_drain};
use crate::json_value::JsonValue;
use crate::membench_corpus::MemBenchItem;
use crate::membench_scorer::{MemBenchItemResult, MemBenchManifestEntry};
use crate::longmemeval_runner::{discover_moot_binary, probe_mcp_client, SplitMix64};
use crate::timing_capture::LegTimingSampler;
use crate::mcp_client::{MCPClient, ToolCaller};
use crate::scratch_posture::{moot_serve_command, ScratchEstatePosture};
use crate::seed_export::SeedPathMode;
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::time::Instant;

// ─────────────────────────────────────────────────────────────────────────────
// Verbmap for mootx01 in MemBench mode
// ─────────────────────────────────────────────────────────────────────────────

/// Standard mootx01 VerbMap for MemBench ingestion + recall queries.
/// Location "benchmarks/membench" mirrors the Swift runner.
///
/// Twin of Swift `memBenchMootVerbMap`.

pub fn membench_verb_map() -> VerbMap {
    let mut constant_args = BTreeMap::new();
    constant_args.insert("location".to_string(), "benchmarks/membench".to_string());
    VerbMap::new(
        crate::aria_v2_surface::FILE_MEMORY,
        crate::aria_v2_surface::MEMORY_SEARCH,
        None, // list: not used in MemBench
        None, // fetch: not used in MemBench
        None, // content_arg: defaults to "content"
        None, // query_arg: defaults to "query"
        Some(constant_args),
        Some(ResultFormat::MootV2),
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// Storage backend shape (C1)
// ─────────────────────────────────────────────────────────────────────────────

/// Storage backend shape for scratch estates.
///
/// - `Disk` (default): standard SQLite backend; artifact snapshots (B6) can be
///   taken and restored.
/// - `Ram`: appends `--in-memory` to the serve command. No SQLite file is
///   written, so estate-cache modes `Reuse` and `Require` are rejected at
///   parse time (incompatible — no disk artifact exists to snapshot or restore).
///
/// Twin of Swift `BenchShape`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BenchShape {
    Disk,
    Ram,
}

impl BenchShape {
    /// Parse an optional CLI value. `None` or `"disk"` → `Disk`; `"ram"` → `Ram`.
    pub fn parse(raw: Option<&str>) -> Result<Self, String> {
        match raw {
            None | Some("disk") => Ok(Self::Disk),
            Some("ram") => Ok(Self::Ram),
            Some(other) => Err(format!(
                "--shape must be 'disk' or 'ram'; got '{other}'"
            )),
        }
    }

    /// Serialisation string written to the report JSON `"shape"` field.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Disk => "disk",
            Self::Ram => "ram",
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Capacity tier (C11)
// ─────────────────────────────────────────────────────────────────────────────

/// Token-volume capacity tier for a MemBench run.
///
/// `Baseline` (default) runs the standard per-item protocol.
/// `TenK` and `HundredK` grow each item's estate with conflict-free filler from
/// the C10 grouper until the target token volume is reached or the filler pool
/// is exhausted — whichever comes first. The report always carries the *achieved*
/// token count, never the target, so shortfalls are visible.
///
/// Twin of Swift `CapacityTier`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CapacityTier {
    /// Standard per-item run; no filler, no capacity fields in the report.
    Baseline,
    /// Target estate size ≈ 10 000 tokens (UTF-8 ceiling-4 estimator).
    TenK,
    /// Target estate size ≈ 100 000 tokens.
    HundredK,
}

impl CapacityTier {
    /// Parse an optional CLI `--capacity-tier` value.
    /// `None` or `"baseline"` → `Baseline`; `"10k"` → `TenK`; `"100k"` → `HundredK`.
    pub fn parse(raw: Option<&str>) -> Result<Self, String> {
        match raw {
            None | Some("baseline") => Ok(Self::Baseline),
            Some("10k") => Ok(Self::TenK),
            Some("100k") => Ok(Self::HundredK),
            Some(other) => Err(format!(
                "--capacity-tier must be 'baseline', '10k', or '100k'; got '{other}'"
            )),
        }
    }

    /// Target token count for this tier. `None` for baseline.
    pub fn target_tokens(self) -> Option<usize> {
        match self {
            Self::Baseline => None,
            Self::TenK => Some(10_000),
            Self::HundredK => Some(100_000),
        }
    }

    /// Report label string (mirrors `CapacityTier.reportLabel` in Swift).
    pub fn report_label(self) -> &'static str {
        match self {
            Self::Baseline => "baseline",
            Self::TenK => "10k",
            Self::HundredK => "100k",
        }
    }

    /// Estate shape label for the report JSON. `None` for baseline.
    pub fn estate_shape_label(self) -> Option<&'static str> {
        match self {
            Self::Baseline => None,
            Self::TenK => Some("per-item-capacity-10k"),
            Self::HundredK => Some("per-item-capacity-100k"),
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Estate grouping mode (C10)
// ─────────────────────────────────────────────────────────────────────────────

/// Controls whether items run in independent per-item estates (Shape 1 protocol)
/// or share a consolidated estate grouped by conflict key (Shape 3 protocol).
///
/// Twin of Swift `EstateGroupingMode`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EstateGroupingMode {
    /// Each item provisions its own scratch estate. Default per-item MemBench protocol.
    PerItem,
    /// Items are grouped by conflict key (question text) using greedy round-robin,
    /// then all items in a group share one estate. Every figure produced under this
    /// mode carries `estate_shape: "consolidated-shape3"` and `protocol_deviation: true`
    /// in the report JSON, because it departs from the published per-item protocol.
    ConsolidatedShape3,
}

impl EstateGroupingMode {
    /// Parse an optional CLI value.
    /// `None` or `"per-item"` → `PerItem`; `"consolidated"` → `ConsolidatedShape3`.
    pub fn parse(raw: Option<&str>) -> Result<Self, String> {
        match raw {
            None | Some("per-item") => Ok(Self::PerItem),
            Some("consolidated") => Ok(Self::ConsolidatedShape3),
            Some(other) => Err(format!(
                "--estate-grouping must be 'per-item' or 'consolidated'; got '{other}'"
            )),
        }
    }

    /// Raw value for the `--estate-grouping` CLI flag.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::PerItem => "per-item",
            Self::ConsolidatedShape3 => "consolidated",
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Run config
// ─────────────────────────────────────────────────────────────────────────────

/// Configuration for one MemBench run.
///
/// Twin of Swift `MemBenchRunConfig`.
pub struct MemBenchRunConfig {
    /// Path to the mootx01 binary.
    pub moot_binary_path: PathBuf,
    /// Root MemData directory.
    pub data_dir: PathBuf,
    /// Agent perspective ("FirstAgent" or "ThirdAgent").
    pub agent: String,
    /// Maximum number of items to run. `None` = all loaded items.
    pub limit: Option<usize>,
    /// Skip this many items from the seeded-shuffled list.
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
    /// Seed for deterministic item shuffling.
    pub seed: u64,
    /// Output directory for the report.
    pub out_dir: Option<PathBuf>,
    /// Run label for the report filename and header.
    pub run_label: String,
    /// Encode-queue synchronization strategy.
    pub encode_barrier: EncodeBarrier,
    /// At-rest posture for scratch estates.
    pub scratch_posture: ScratchEstatePosture,
    /// Optional category filter. Applied before offset/limit.
    pub category_filter: Option<String>,
    /// Seed-path mode (--seed-path, default batch). `Batch` names the
    /// restore-only artifact namespace (batch estates are prebuilt by the
    /// seeding pipeline; a batch cache miss is fatal). `Live` is the
    /// per-turn `moot_file_memory` build path, retained for periodic
    /// equivalence re-proving. Twin of Swift `MemBenchRunConfig.seedPath`.
    pub seed_path: SeedPathMode,
    /// Guard probe sampling policy for this leg. Default `OncePerLeg` probes on the
    /// first item only. Use `PerUnit` only for debugging.
    /// Twin of Swift `MemBenchRunConfig.guardSamplingPolicy`.
    pub guard_sampling_policy: crate::degeneracy_guard::GuardSamplingPolicy,
    /// Estate snapshot reuse mode (B6 — membench was the one lane with no
    /// artifact reuse at all). Twin of Swift `MemBenchRunConfig.estateCache`.
    pub estate_cache: crate::estate_cache::EstateCacheMode,
    /// Cache root directory. None = <out_dir>/estate-cache (or <cwd>/estate-cache).
    pub cache_dir: Option<PathBuf>,
    /// SHA-256 of the corpus fixture inputs (B2 provenance). "unknown" never
    /// validates.
    pub corpus_digest: String,
    /// Storage backend shape for scratch estates (C1). Default `Disk`.
    /// `Ram` appends `--in-memory`; incompatible with estate-cache
    /// `Reuse`/`Require` (no disk artifact to snapshot or restore).
    pub shape: BenchShape,
    /// Number of items to process concurrently (C6). `1` = serial (previous behaviour).
    /// Default: 80% of available logical cores, minimum 1.
    pub parallel_units: usize,
    /// C10: estate grouping mode — per-item (default) or consolidated Shape 3.
    /// Consolidated mode groups items by conflict key (question text) and runs
    /// each group in a shared estate. Reports carry protocol-deviation labels.
    pub estate_grouping: EstateGroupingMode,
    /// C11: capacity tier — baseline (default), 10k, or 100k tokens.
    /// Non-baseline tiers grow each item's estate with conflict-free filler from
    /// the C10 grouper before querying. Reports carry achieved token stats.
    pub capacity_tier: CapacityTier,
}

// ─────────────────────────────────────────────────────────────────────────────
// Scratch estate management
// ─────────────────────────────────────────────────────────────────────────────

/// Creates and returns a fresh, hardened scratch directory under
/// `/tmp/membench-bench-<seed>-<index>`. The path is canonicalized and checked
/// for symlinks before it is returned; callers receive the canonical form.
///
/// Hardening added in E3:
/// - After `create_dir_all`, `symlink_metadata` (lstat-equivalent) verifies the
///   created entry is a real directory, not a symlink an attacker raced to place.
/// - `canonicalize` resolves any remaining `..` components and returns the
///   resolved path, which `membench_guarded_teardown` then checks on the same
///   canonical form.
///
/// Twin of Swift `memBenchScratchDir(posture:)`.
fn membench_scratch_dir(
    seed: u64,
    item_index: usize,
    posture: ScratchEstatePosture,
) -> Result<PathBuf, String> {
    let path = PathBuf::from(format!("/tmp/membench-bench-{}-{}", seed, item_index));
    // Remove any leftover from a previous crashed run at this index.
    if path.exists() {
        std::fs::remove_dir_all(&path)
            .map_err(|e| format!("membench_scratch_dir: could not remove stale dir {}: {e}", path.display()))?;
    }
    std::fs::create_dir_all(&path)
        .map_err(|e| format!("membench_scratch_dir: could not create {}: {e}", path.display()))?;

    // Reject symlinked paths: an attacker could race to replace the just-created
    // directory with a symlink pointing at real data. `symlink_metadata` is the
    // lstat equivalent — it does NOT follow symlinks, so a symlink entry is
    // visible here even though `create_dir_all` would have followed it.
    let lstat = std::fs::symlink_metadata(&path)
        .map_err(|e| format!("membench_scratch_dir: cannot stat {}: {e}", path.display()))?;
    if lstat.file_type().is_symlink() {
        return Err(format!(
            "membench_scratch_dir: SAFETY: '{}' is a symlink — refusing to use as scratch estate",
            path.display()
        ));
    }

    // Canonicalize to resolve any lingering `..` components and hand callers the
    // real path. The teardown guard then checks this canonical form.
    let canonical = std::fs::canonicalize(&path)
        .map_err(|e| format!("membench_scratch_dir: cannot canonicalize {}: {e}", path.display()))?;
    // Compare against the canonicalized temp base, never a literal "/tmp/"
    // prefix: macOS resolves /tmp to /private/tmp, so the literal check
    // rejected every legitimate directory (Wave-3 G3).
    let expected = crate::config::canonical_tmp_base()
        .join(format!("membench-bench-{}-{}", seed, item_index));
    if canonical != expected {
        return Err(format!(
            "membench_scratch_dir: SAFETY: canonicalized path '{}' is not the expected scratch dir '{}'",
            canonical.display(),
            expected.display()
        ));
    }

    // The posture is the record's: a transient record is plaintext by rule.
    let _ = posture;
    Ok(canonical)
}

/// Removes a scratch directory created by `membench_scratch_dir`. Refuses any
/// path without the `/tmp/membench-bench-` prefix AND refuses symlinks — belt
/// and suspenders on top of `membench_scratch_dir`'s creation-time checks.
///
/// Twin of Swift `memBenchGuardedTeardown(_:)`.
fn membench_guarded_teardown(path: &Path) {
    // Prefix built from the canonicalized temp base (Wave-3 G3): callers
    // hold canonical paths (/private/tmp/… on macOS), so a literal "/tmp/"
    // prefix check would refuse every legitimate teardown.
    let expected_prefix = crate::config::canonical_tmp_base()
        .join("membench-bench-")
        .to_string_lossy()
        .into_owned();
    let path_str = path.to_string_lossy();
    if !path_str.starts_with(&expected_prefix) {
        eprintln!(
            "[membench] SAFETY: guarded teardown refused '{}' — \
             path must have the {} prefix",
            path_str, expected_prefix
        );
        return;
    }
    // Refuse to tear down a symlink even after canonicalization (belt and
    // suspenders — the canonical path should never be a symlink itself, but
    // if it somehow is, we refuse rather than following it to real data).
    if let Ok(meta) = std::fs::symlink_metadata(path) {
        if meta.file_type().is_symlink() {
            eprintln!(
                "[membench] SAFETY: guarded teardown refused symlink '{}'",
                path_str
            );
            return;
        }
    }
    if let Err(e) = std::fs::remove_dir_all(path) {
        eprintln!("[membench] teardown warning: could not remove {}: {e}", path_str);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// EndpointConfig builder
// ─────────────────────────────────────────────────────────────────────────────

/// Builds an `EndpointConfig` for mootx01 pointing at a MemBench scratch estate.
///
/// Twin of Swift `memBenchEndpointConfig(scratchDir:mootBinaryPath:posture:)`.
fn membench_endpoint_config(
    scratch_dir: &Path,
    binary: &Path,
    posture: ScratchEstatePosture,
    shape: BenchShape,
) -> Result<EndpointConfig, String> {
    // The posture is the record's. RAM shape serves the InMemory backend
    // (--in-memory) — no SQLite file is written, no keychain contact.
    let _ = posture;
    let command = moot_serve_command(
        &binary.display().to_string(), scratch_dir, shape == BenchShape::Ram, crate::scratch_posture::SCRATCH_SERVE_ENV, None)
        .map_err(|e| e.to_string())?;
    Ok(EndpointConfig {
        name: "mootx01-membench".to_string(),
        transport: Transport::Stdio { command },
        auth: None,
        verb_map: membench_verb_map(),
        role: EndpointRole::Target,
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Runner
// ─────────────────────────────────────────────────────────────────────────────

/// Runs the MemBench harness against the loaded item list. Returns per-item results.
///
/// Per-item estate strategy (mirrors the LME per-question model):
///   1. Apply category filter.
///   2. Seeded shuffle then offset + limit.
///   3. For each item: provision estate → ingest turns → drain → dream → guard → query → teardown.
///      Items run concurrently up to `config.parallel_units` threads (C6).
///
/// Results are collected by original index and sorted before return so the report
/// is byte-deterministic regardless of thread completion order.
///
/// Twin of Swift `runMemBenchItems(items:config:)`.
pub fn run_membench_items(
    items: &[MemBenchItem],
    config: &MemBenchRunConfig,
) -> Result<(Vec<MemBenchItemResult>, Option<String>), String> {

    // Category filter before shuffle/offset/limit.
    let filtered: Vec<&MemBenchItem> = match &config.category_filter {
        Some(cat) => items.iter().filter(|i| &i.category == cat).collect(),
        None => items.iter().collect(),
    };

    // Seeded shuffle.
    let mut rng = SplitMix64::new(config.seed);
    let mut indices: Vec<usize> = (0..filtered.len()).collect();
    // --ids pinned subset (before shuffle: same file → same units always).
    if let Some(ids) = &config.unit_ids {
        indices.retain(|&i| ids.contains(&filtered[i].item_id));
    }
    rng.shuffle(&mut indices);

    // Apply offset + limit.
    let sliced: Vec<usize> = indices
        .into_iter()
        .skip(config.offset)
        .take(config.limit.unwrap_or(usize::MAX))
        .collect();

    // One sampler for the entire leg: probes on the first item, caches the
    // verdict for the rest. Wrapped in Mutex so worker threads can call probe()
    // concurrently (C6). Under the default OncePerLeg policy, only the first
    // thread actually issues MCP calls (the slow path); all subsequent threads
    // get a fast lock acquisition → cache hit → lock release. Under PerUnit
    // policy (debugging only), each thread holds the lock while probing, which
    // serialises guard probes — acceptable because PerUnit is never used in
    // production runs.
    let shared_guard_sampler =
        std::sync::Mutex::new(LegGuardSampler::new(config.guard_sampling_policy));
    // C4: one timing sampler for the entire leg. Shared by reference across
    // worker threads — LegTimingSampler is Sync (interior Mutex). Captures
    // moot_timing_report from the first settled estate; all subsequent items
    // return the cached text at zero MCP cost.
    let timing_sampler = LegTimingSampler::new();

    // B6: cache setup — one provenance per run (B2), key without a binary
    // fingerprint (B3), snapshot after settle (B4), clone restore (B5).
    let run_provenance = crate::artifact_manifest::make_artifact_provenance(
        "membench",
        // Keyed on the agent, twin of the Swift lane (variant: config.agent).
        &config.agent,
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
            Some(config.moot_binary_path.to_str().unwrap_or_default()),
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

    // Results indexed by run position for byte-deterministic ordering (C6).
    let indexed_results: std::sync::Mutex<Vec<Option<MemBenchItemResult>>> =
        std::sync::Mutex::new((0..sliced.len()).map(|_| None).collect());

    // Work queue: each worker pops the next run_index until empty.
    let work_queue: std::sync::Mutex<std::collections::VecDeque<usize>> =
        std::sync::Mutex::new(std::collections::VecDeque::from_iter(0..sliced.len()));

    let effective_parallel = config.parallel_units.max(1);
    eprintln!(
        "[membench] running {} items with parallel_units={}",
        sliced.len(),
        effective_parallel
    );

    // Error channel: if any thread encounters a fatal endpoint config error,
    // it stores the message here. After the scope we propagate as Err.
    let endpoint_error: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);
    std::thread::scope(|s| {
        for _ in 0..effective_parallel {
            s.spawn(|| {
                // Each worker thread gets its own verb_map clone (not Send).
                let verb_map = membench_verb_map();

                loop {
                    // Pop the next run_index atomically.
                    let run_index = { work_queue.lock().unwrap().pop_front() };
                    let Some(run_index) = run_index else { break };

                    let item = filtered[sliced[run_index]];
                    eprintln!(
                        "[membench] item={} (#{}/{})",
                        item.item_id,
                        run_index + 1,
                        sliced.len()
                    );

                    // B6 cache restore attempt: on a hit the restored estate is SETTLED
                    // (ingest + drain + dream + retrain at build, B4) and the manifest
                    // comes from the snapshot — ingest and settle are skipped entirely.
                    let mut cache_entry_for_snapshot: Option<PathBuf> = None;
                    let mut restored_manifest: Option<Vec<MemBenchManifestEntry>> = None;
                    let scratch_dir: PathBuf;
                    if config.estate_cache != crate::estate_cache::EstateCacheMode::Off {
                        let cache_entry = crate::estate_cache::estate_cache_entry_path(
                            &resolved_cache_dir,
                            "membench",
                            // ThirdAgent estates must not share a key with
                            // FirstAgent — and the Swift port keys on the
                            // agent, so the ports address the SAME namespace.
                            &config.agent,
                            config.seed,
                            config.encode_barrier,
                            config.scratch_posture,
                            config.seed_path,
                            &item.item_id,
                        );
                        match crate::estate_cache::restore_estate_cache_entry(
                            &cache_entry,
                            &run_provenance,
                            || {
                                membench_scratch_dir(config.seed, run_index, config.scratch_posture)
                            },
                        ) {
                            Ok(Some((restored, hit))) => {
                                scratch_dir = restored;
                                restored_manifest = Some(hit);
                            }
                            Ok(None) => {
                                // B7: measure-only mode never builds — a miss is fatal.
                                // panic! (not a per-item skip) is membench's uniform
                                // FATAL shape — both poison the whole leg, and a leg
                                // that mixes provenances must not produce a report.
                                if config.estate_cache
                                    == crate::estate_cache::EstateCacheMode::Require
                                {
                                    panic!(
                                        "{}",
                                        crate::estate_cache::artifact_required_error(&cache_entry)
                                    );
                                }
                                // The batch namespace is restore-only: batch estates are
                                // prebuilt artifacts (the seeding pipeline owns building),
                                // so a batch miss is fatal. Only the live-equivalence
                                // build path remains in this harness.
                                if config.seed_path == SeedPathMode::Batch {
                                    panic!(
                                        "{}",
                                        crate::estate_cache::artifact_required_error(&cache_entry)
                                    );
                                }
                                match membench_scratch_dir(
                                    config.seed,
                                    run_index,
                                    config.scratch_posture,
                                ) {
                                    Ok(d) => scratch_dir = d,
                                    Err(e) => {
                                        eprintln!(
                                            "[membench] scratch dir error for item {}: {e}",
                                            item.item_id
                                        );
                                        continue;
                                    }
                                }
                                cache_entry_for_snapshot = Some(cache_entry);
                            }
                            Err(e) => {
                                // B2 provenance mismatch is a HARD FAIL for the whole run.
                                panic!("[membench] FATAL provenance mismatch: {e}");
                            }
                        }
                    } else {
                        // The batch namespace is restore-only (prebuilt artifacts);
                        // with the cache off only the live-equivalence build can run.
                        if config.seed_path == SeedPathMode::Batch {
                            panic!(
                                "the membench lane has no batch build: batch estates are \
                                 prebuilt artifacts restored via --estate-cache require. \
                                 Use --seed-path live for the live-equivalence build."
                            );
                        }
                        match membench_scratch_dir(config.seed, run_index, config.scratch_posture) {
                            Ok(d) => scratch_dir = d,
                            Err(e) => {
                                eprintln!(
                                    "[membench] scratch dir error for item {}: {e}",
                                    item.item_id
                                );
                                continue;
                            }
                        }
                    }
                    let skip_ingest = restored_manifest.is_some();

                    let endpoint = match membench_endpoint_config(
                        &scratch_dir,
                        &config.moot_binary_path,
                        config.scratch_posture,
                        config.shape,
                    ) {
                        Ok(ep) => ep,
                        Err(e) => {
                            *endpoint_error.lock().unwrap() = Some(format!("membench: endpoint config error: {e}"));
                            return;
                        }
                    };
                    // Belt-and-suspenders: verify --db points into /tmp before connecting.
                    // Twin of Swift `assertScratchBackend(_:requirement:)` in MemBenchRunner.
                    crate::gauntlet_runner::assert_scratch_backend(
                        &endpoint, &crate::gauntlet_runner::MOOT_SCRATCH_REQUIREMENT,
                    );
                    let mut client = MCPClient::new(endpoint);
                    if let Err(e) = client.connect() {
                        eprintln!(
                            "[membench] connect error for item {}: {}",
                            item.item_id, e.description
                        );
                        membench_guarded_teardown(&scratch_dir);
                        continue;
                    }

                    // Ingest all turns from all sessions via per-turn moot_file_memory
                    // (the live-equivalence build — the only build path in this harness;
                    // batch estates are prebuilt artifacts and restore-only).
                    let mut manifest: Vec<MemBenchManifestEntry> = Vec::new();
                    let mut write_times: Vec<f64> = Vec::new();
                    let mut ingest_error: Option<String> = None;
                    // Total records ingested; the manifest length after live ingest.
                    let ingest_count: usize;

                    if skip_ingest {
                        // B6 cache hit: manifest comes from the snapshot; no ingest.
                        manifest = restored_manifest.unwrap_or_default();
                        ingest_count = manifest.len();
                    } else {
                        'ingest: for session in &item.sessions {
                            for turn in &session.turns {
                                // Content format: "user: <text>\nassistant: <text>"
                                // Same format as the Swift twin for embedding consistency.
                                let content = format!(
                                    "user: {}\nassistant: {}",
                                    turn.user_message, turn.assistant_message
                                );
                                let mut args: BTreeMap<String, JsonValue> =
                                    BTreeMap::new();
                                args.insert(
                                    verb_map.content_arg.clone(),
                                    JsonValue::String(content.clone()),
                                );
                                args.insert(
                                    "subject".to_string(),
                                    JsonValue::String(
                                        crate::subject_generator::deterministic_subject(
                                            &content,
                                        ),
                                    ),
                                );
                                for (k, v) in &verb_map.constant_args {
                                    args.insert(
                                        k.clone(),
                                        JsonValue::String(v.clone()),
                                    );
                                }
                                if config.encode_barrier == EncodeBarrier::Impatient {
                                    args.insert(
                                        "impatient".to_string(),
                                        JsonValue::Bool(true),
                                    );
                                }

                                let write_start = Instant::now();
                                match client.call_tool(
                                    &verb_map.write,
                                    args,
                                    &verb_map.result_format,
                                ) {
                                    Ok(result) => {
                                        write_times
                                            .push(write_start.elapsed().as_secs_f64());
                                        if let Some(uuid) = result.write_assigned_id {
                                            manifest.push(MemBenchManifestEntry {
                                                uuid,
                                                sid: turn.sid.to_string(),
                                                session_index: session.session_index,
                                            });
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
                        ingest_count = manifest.len();

                        // Drain barrier: poll moot_drain_status after full item ingest.
                        if config.encode_barrier == EncodeBarrier::Drain {
                            // 120-second timeout matches the locomo runner default.
                            wait_for_encode_drain(
                                &mut client,
                                &format!("membench item={}", item.item_id),
                                120.0,
                            );
                        }

                        // ── Settle, then snapshot (B4/B6) ─────────────────────────
                        // dream + basis retrain + drain, so the artifact (and every
                        // fresh measurement) is a settled estate
                        // (BENCHMARK_PROTOCOL.md §4). One moot_dream per estate per
                        // the 2026-08-05 every-cognition-layer ruling, satisfied at
                        // build time; a restored artifact is settled by construction
                        // and is NOT re-dreamt.
                        //
                        // Fitness gate (BH-02 findings #8 and #10b): two booleans track
                        // whether the estate may be written to the artifact cache. Both
                        // start true and are set false on the corresponding settle failure:
                        //   - settle_dream_ok: false when moot_dream returns an error
                        //   - settle_reindex_ok: false when moot_reindex returns an error
                        // A partial or unsettled estate must never become a cached artifact;
                        // a later run restoring it would silently measure a broken baseline.
                        // Unlike longmemeval_runner.rs and lmeb_runner.rs (which use `?` so
                        // any settle failure returns early before the save), membench_runner
                        // logs settle errors and continues to allow the measurement to
                        // complete — the gate here is the structural enforcement that prevents
                        // a logged-and-continued failure from silently reaching the cache.
                        // Adding a new settle step: extend estate_is_fit_to_cache's signature
                        // rather than adding a separate boolean check at the save site.
                        if ingest_error.is_none() {
                            let mut settle_dream_ok = true;
                            let mut settle_reindex_ok = true;
                            let mut dream_args: BTreeMap<String, JsonValue> = BTreeMap::new();
                            dream_args.insert(
                                "associates".to_string(),
                                JsonValue::String("all".to_string()),
                            );
                            if let Err(e) = client.call_tool(
                                crate::aria_v2_surface::DREAM,
                                dream_args,
                                &ResultFormat::MootV2,
                            ) {
                                eprintln!(
                                    "[membench] settle dream failed for item {}: {}",
                                    item.item_id, e.description
                                );
                                settle_dream_ok = false;
                            }
                            if let Err(e) = client.call_tool(
                                crate::aria_v2_surface::REINDEX,
                                BTreeMap::new(),
                                &ResultFormat::MootV2,
                            ) {
                                eprintln!(
                                    "[membench] settle reindex failed for item {}: {}",
                                    item.item_id, e.description
                                );
                                settle_reindex_ok = false;
                            }
                            wait_for_encode_drain(
                                &mut client,
                                &format!("membench settle-for-snapshot item={}", item.item_id),
                                300.0,
                            );

                            // C4: capture timing report while the settled estate's MCP
                            // client is still alive. The sampler caches the first result —
                            // all subsequent items pay zero MCP cost.
                            timing_sampler.capture(|| crate::timing_capture::fetch_timing_report(&mut client));

                            // Snapshot only when the estate is fit: no ingest error, dream
                            // OK, reindex OK. An unfit estate is never written to cache so a
                            // future restore cannot silently inherit a broken baseline.
                            // `ingest_error` is borrowed here (not consumed — that happens at
                            // line ~909 via `if let Some(err) = ingest_error`, after this block).
                            if let Some(ref entry) = cache_entry_for_snapshot {
                                if crate::locomo_runner::estate_is_fit_to_cache(
                                    &ingest_error,
                                    settle_dream_ok,
                                    settle_reindex_ok,
                                ) {
                                    crate::estate_cache::save_estate_cache_entry(
                                        &scratch_dir,
                                        &manifest,
                                        &run_provenance,
                                        entry,
                                    );
                                } else {
                                    eprintln!(
                                        "[membench] cache write skipped for item {}: estate unfit \
                                         (ingest error or settle failure — see log above)",
                                        item.item_id
                                    );
                                }
                            }
                        }
                    } // end if !skip_ingest

                    if let Some(err) = ingest_error {
                        eprintln!("[membench] item={} {err}", item.item_id);
                        let _ = client.disconnect();
                        membench_guarded_teardown(&scratch_dir);
                        continue;
                    }

                    let write_mean = if write_times.is_empty() {
                        0.0
                    } else {
                        write_times.iter().sum::<f64>() / write_times.len() as f64
                    };

                    // DegeneracyGuard probe, delegated to the leg sampler behind a
                    // Mutex. Under OncePerLeg (default), only the first thread issues
                    // actual MCP probe calls (slow path); subsequent threads get a
                    // fast lock → cache hit → unlock. Under PerUnit (debugging only),
                    // threads serialise through this lock while probing.
                    let (guard_healthy, guard_diagnostic, _was_probed) = {
                        let mut sampler = shared_guard_sampler.lock().unwrap();
                        sampler.probe(|| probe_mcp_client(&mut client, &verb_map))
                    };

                    // Issue the QA question through the retrieval seam.
                    let (door_tool, door_args) = crate::retrieval_call_spec::seam_call(
                        &verb_map, config.retrieval_call.as_ref(), &item.qa.question);

                    let query_start = Instant::now();
                    let (retrieved_uuids, payload_text) = match client.call_tool(
                        &door_tool,
                        door_args,
                        &verb_map.result_format,
                    ).map(|r| crate::payload_arm::strip_tool_result(config.payload_arm, r)) {
                        Ok(result) => {
                            let text = if result.text_blocks.is_empty() {
                                None
                            } else {
                                Some(result.text_blocks.join("\n"))
                            };
                            (result.ordered_ids, text)
                        }
                        Err(e) => {
                            eprintln!(
                                "[membench] query error for item {}: {}",
                                item.item_id, e.description
                            );
                            (Vec::new(), None)
                        }
                    };
                    let query_latency = query_start.elapsed().as_secs_f64();

                    let evidence_sids = item.evidence_sids();

                    let _ = client.disconnect();
                    membench_guarded_teardown(&scratch_dir);

                    // Store by run_index for deterministic ordering at collection time.
                    indexed_results.lock().unwrap()[run_index] = Some(MemBenchItemResult {
                        item_id: item.item_id.clone(),
                        category: item.category.clone(),
                        question: item.qa.question.clone(),
                        query_latency_seconds: query_latency,
                        retrieved_uuids,
                        manifest,
                        evidence_sids,
                        guard_healthy,
                        guard_diagnostic,
                        guard_sampling_mode: config.guard_sampling_policy,
                        turns_ingested: ingest_count,
                        write_mean_latency_seconds: write_mean,
                        payload_text,
                        // C9: carry choices and ground_truth through so the scorer can
                        // apply select_multiple_choice_prediction without a corpus lookup.
                        choices: item.qa.choices.clone(),
                        ground_truth: item.qa.ground_truth.clone(),
                    });
                }
            });
        }
    });

    // Propagate any endpoint-config refusal (e.g. whitespace in scratch path).
    // The thread stored the message; we return Err so main() exits 1 not 101.
    if let Some(err) = endpoint_error.into_inner().unwrap() {
        return Err(err);
    }

    // Collect results in original run_index order (Some = processed, None = skipped).
    let results = indexed_results
        .into_inner()
        .unwrap()
        .into_iter()
        .flatten()
        .collect();
    Ok((results, timing_sampler.text()))
}

// ────────────────────────────────────────────────────────────────────────────
// C10 — conflict key and grouping
// ─────────────────────────────────────────────────────────────────────────────

/// Returns the conflict key for Shape 3 grouping: the item's QA question text.
/// Items with identical question text are mutually conflicting — sharing an estate
/// would cause the query to surface evidence from the wrong item's sessions.
///
/// Twin of Swift `memBenchConflictKey(_:)`.
pub fn membench_conflict_key(item: &MemBenchItem) -> &str {
    &item.qa.question
}

/// Groups items into non-overlapping lists using greedy round-robin on conflict key.
/// Item N of a given key value is assigned to group N (0-indexed), guaranteeing no
/// group ever contains two items with the same question text.
///
/// Group count equals the maximum occurrence count of any single conflict key value.
///
/// Twin of Swift `memBenchGroupItemsByConflictKey(_:)`.
pub fn membench_group_items_by_conflict_key<'a>(
    items: &'a [MemBenchItem],
) -> Vec<Vec<&'a MemBenchItem>> {
    let refs: Vec<&MemBenchItem> = items.iter().collect();
    membench_group_refs(&refs)
}

/// Internal grouper that accepts an already-filtered/shuffled/sliced reference slice.
fn membench_group_refs<'a>(items: &[&'a MemBenchItem]) -> Vec<Vec<&'a MemBenchItem>> {
    let mut key_count: HashMap<&str, usize> = HashMap::new();
    let mut groups: Vec<Vec<&'a MemBenchItem>> = Vec::new();
    for &item in items {
        let key = membench_conflict_key(item);
        let group_index = *key_count.get(key).unwrap_or(&0);
        *key_count.entry(key).or_insert(0) += 1;
        while groups.len() <= group_index {
            groups.push(Vec::new());
        }
        groups[group_index].push(item);
    }
    groups
}

// ─────────────────────────────────────────────────────────────────────────────
// C10 — consolidated estate runner
// ─────────────────────────────────────────────────────────────────────────────

/// Runs the MemBench harness in consolidated estate mode (Shape 3).
///
/// Groups items by conflict key using greedy round-robin, then runs each group
/// in a shared estate. All items in a group share one estate — ingest, settle,
/// and teardown happen once per group. Per-item manifests are built during ingest
/// so only that item's UUID→sid entries are present when scoring.
///
/// Uses the LIVE PATH only: no batch seed file, direct per-turn `moot_file_memory`.
/// Groups are processed serially; the guard sampler and timing sampler are shared
/// across all groups.
///
/// Returns `(results, timing_report_text, items_per_group)`.
///
/// Twin of Swift `runMemBenchItemsConsolidated(items:config:)`.
pub fn run_membench_items_consolidated(
    items: &[MemBenchItem],
    config: &MemBenchRunConfig,
) -> Result<(Vec<MemBenchItemResult>, Option<String>, Vec<usize>), String> {
    // Category filter before shuffle/offset/limit.
    let filtered: Vec<&MemBenchItem> = match &config.category_filter {
        Some(cat) => items.iter().filter(|i| &i.category == cat).collect(),
        None => items.iter().collect(),
    };

    // Seeded shuffle — same deterministic order as per-item mode.
    let mut rng = SplitMix64::new(config.seed);
    let mut indices: Vec<usize> = (0..filtered.len()).collect();
    rng.shuffle(&mut indices);

    // Apply offset + limit.
    let sliced: Vec<&MemBenchItem> = indices
        .into_iter()
        .skip(config.offset)
        .take(config.limit.unwrap_or(usize::MAX))
        .map(|i| filtered[i])
        .collect();

    // Group by conflict key using greedy round-robin.
    let groups = membench_group_refs(&sliced);
    let items_per_group: Vec<usize> = groups.iter().map(|g| g.len()).collect();
    let total_groups = groups.len();

    let guard_sampler = std::sync::Mutex::new(LegGuardSampler::new(config.guard_sampling_policy));
    let timing_sampler = LegTimingSampler::new();
    let verb_map = membench_verb_map();

    eprintln!(
        "[membench-consolidated] {} items → {} groups",
        sliced.len(),
        total_groups
    );

    let mut all_results: Vec<(usize, MemBenchItemResult)> = Vec::new();
    let mut ordinal_base: usize = 0;

    for (group_index, group) in groups.iter().enumerate() {
        let mut group_results = run_one_membench_group(
            group,
            group_index,
            total_groups,
            ordinal_base,
            config,
            &guard_sampler,
            &timing_sampler,
            &verb_map,
        )?;
        ordinal_base += group.len();
        all_results.append(&mut group_results);
    }

    // Restore original item order by ordinal.
    all_results.sort_by_key(|&(ordinal, _)| ordinal);
    let results = all_results.into_iter().map(|(_, r)| r).collect();

    Ok((results, timing_sampler.text(), items_per_group))
}

/// Provisions one shared estate for all items in `group`, ingests their sessions
/// via the live path, settles the estate, runs the guard probe, then issues one
/// recall query per item using that item's per-item manifest.
///
/// Returns `(ordinal, MemBenchItemResult)` pairs. Items that fail at the query
/// step are included with empty `retrieved_uuids` rather than skipped, so the
/// ordinal sequence stays intact.
///
/// Twin of Swift `runOneMemBenchGroup(group:groupIndex:totalGroups:ordinalBase:config:...)`.
fn run_one_membench_group(
    group: &[&MemBenchItem],
    group_index: usize,
    total_groups: usize,
    ordinal_base: usize,
    config: &MemBenchRunConfig,
    guard_sampler: &std::sync::Mutex<LegGuardSampler>,
    timing_sampler: &LegTimingSampler,
    verb_map: &VerbMap,
) -> Result<Vec<(usize, MemBenchItemResult)>, String> {
    if group.is_empty() {
        return Ok(Vec::new());
    }

    eprintln!(
        "[membench-consolidated] group {}/{}: {} items",
        group_index + 1,
        total_groups,
        group.len()
    );

    // Provision one shared estate for the whole group.
    // Reuse the per-item scratch dir function with group_index as the identifier.
    let scratch_dir = match membench_scratch_dir(config.seed, group_index, config.scratch_posture) {
        Ok(d) => d,
        Err(e) => {
            eprintln!(
                "[membench-consolidated] scratch dir error for group {}: {e}",
                group_index
            );
            return Ok(Vec::new());
        }
    };

    let endpoint = match membench_endpoint_config(
        &scratch_dir,
        &config.moot_binary_path,
        config.scratch_posture,
        config.shape,
    ) {
        Ok(ep) => ep,
        Err(e) => return Err(format!("membench: endpoint config error: {e}")),
    };
    // Belt-and-suspenders: verify --db points into /tmp before connecting.
    // Twin of Swift `assertScratchBackend(_:requirement:)` in MemBenchRunner.
    crate::gauntlet_runner::assert_scratch_backend(
        &endpoint, &crate::gauntlet_runner::MOOT_SCRATCH_REQUIREMENT,
    );
    let mut client = MCPClient::new(endpoint);
    if let Err(e) = client.connect() {
        eprintln!(
            "[membench-consolidated] connect error for group {}: {}",
            group_index, e.description
        );
        membench_guarded_teardown(&scratch_dir);
        return Ok(Vec::new());
    }

    // Live-path ingest all items' sessions. Track per-item manifests and write times.
    let n = group.len();
    let mut per_item_manifests: Vec<Vec<MemBenchManifestEntry>> = vec![Vec::new(); n];
    let mut per_item_write_times: Vec<Vec<f64>> = vec![Vec::new(); n];
    let mut per_item_ingest_counts: Vec<usize> = vec![0usize; n];
    let mut ingest_error: Option<String> = None;

    'group_ingest: for (item_idx, &item) in group.iter().enumerate() {
        for session in &item.sessions {
            for turn in &session.turns {
                // Content format mirrors the per-item live path for embedding consistency.
                let content = format!(
                    "user: {}\nassistant: {}",
                    turn.user_message, turn.assistant_message
                );
                let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
                args.insert(
                    verb_map.content_arg.clone(),
                    JsonValue::String(content.clone()),
                );
                args.insert(
                    "subject".to_string(),
                    JsonValue::String(
                        crate::subject_generator::deterministic_subject(&content),
                    ),
                );
                for (k, v) in &verb_map.constant_args {
                    args.insert(k.clone(), JsonValue::String(v.clone()));
                }
                if config.encode_barrier == EncodeBarrier::Impatient {
                    args.insert("impatient".to_string(), JsonValue::Bool(true));
                }

                let write_start = Instant::now();
                match client.call_tool(&verb_map.write, args, &verb_map.result_format) {
                    Ok(result) => {
                        per_item_write_times[item_idx].push(write_start.elapsed().as_secs_f64());
                        if let Some(uuid) = result.write_assigned_id {
                            // Each UUID is recorded only in the manifest for the item
                            // that wrote it. Other items' UUIDs are absent from this
                            // manifest, so lme_ranked_sessions silently skips them when
                            // scoring — this rank degradation is what Shape 3 measures.
                            per_item_manifests[item_idx].push(MemBenchManifestEntry {
                                uuid,
                                sid: turn.sid.to_string(),
                                session_index: session.session_index,
                            });
                        }
                        per_item_ingest_counts[item_idx] += 1;
                    }
                    Err(e) => {
                        ingest_error = Some(format!(
                            "group {} item {} sid={}: {}",
                            group_index, item.item_id, turn.sid, e.description
                        ));
                        break 'group_ingest;
                    }
                }
            }
        }
    }

    if let Some(err) = ingest_error {
        eprintln!("[membench-consolidated] ingest error: {err}");
        let _ = client.disconnect();
        membench_guarded_teardown(&scratch_dir);
        return Ok(Vec::new());
    }

    // Drain barrier after full group ingest.
    if config.encode_barrier == EncodeBarrier::Drain {
        wait_for_encode_drain(
            &mut client,
            &format!("membench-consolidated group={}", group_index),
            120.0,
        );
    }

    // Settle: dream + reindex + post-settle drain. Same protocol as per-item mode.
    let mut dream_args: BTreeMap<String, JsonValue> = BTreeMap::new();
    dream_args.insert("associates".to_string(), JsonValue::String("all".to_string()));
    if let Err(e) = client.call_tool(crate::aria_v2_surface::DREAM, dream_args, &ResultFormat::MootV2) {
        eprintln!(
            "[membench-consolidated] settle dream failed for group {}: {}",
            group_index, e.description
        );
    }
    if let Err(e) = client.call_tool(crate::aria_v2_surface::REINDEX, BTreeMap::new(), &ResultFormat::MootV2) {
        eprintln!(
            "[membench-consolidated] settle reindex failed for group {}: {}",
            group_index, e.description
        );
    }
    wait_for_encode_drain(
        &mut client,
        &format!("membench-consolidated settle group={}", group_index),
        300.0,
    );

    // C4: capture timing report from the first settled estate.
    timing_sampler.capture(|| crate::timing_capture::fetch_timing_report(&mut client));

    // Guard probe for this group's estate, delegated to the shared sampler.
    let (guard_healthy, guard_diagnostic, _was_probed) = {
        let mut sampler = guard_sampler.lock().unwrap();
        sampler.probe(|| probe_mcp_client(&mut client, verb_map))
    };

    // Per-item queries using each item's own sub-manifest.
    let mut results: Vec<(usize, MemBenchItemResult)> = Vec::new();
    for (item_idx, &item) in group.iter().enumerate() {
        let (door_tool, door_args) = crate::retrieval_call_spec::seam_call(
            &verb_map, config.retrieval_call.as_ref(), &item.qa.question);

        let query_start = Instant::now();
        let (retrieved_uuids, payload_text) = match client.call_tool(
            &door_tool,
            door_args,
            &verb_map.result_format,
        ).map(|r| crate::payload_arm::strip_tool_result(config.payload_arm, r)) {
            Ok(result) => {
                let text = if result.text_blocks.is_empty() {
                    None
                } else {
                    Some(result.text_blocks.join("\n"))
                };
                (result.ordered_ids, text)
            }
            Err(e) => {
                eprintln!(
                    "[membench-consolidated] query error group {} item {}: {}",
                    group_index, item.item_id, e.description
                );
                (Vec::new(), None)
            }
        };
        let query_latency = query_start.elapsed().as_secs_f64();

        let write_times = &per_item_write_times[item_idx];
        let write_mean = if write_times.is_empty() {
            0.0
        } else {
            write_times.iter().sum::<f64>() / write_times.len() as f64
        };

        let evidence_sids = item.evidence_sids();
        let ordinal = ordinal_base + item_idx;

        results.push((
            ordinal,
            MemBenchItemResult {
                item_id: item.item_id.clone(),
                category: item.category.clone(),
                question: item.qa.question.clone(),
                query_latency_seconds: query_latency,
                retrieved_uuids,
                // Only this item's own UUID→sid entries — other items' UUIDs absent.
                manifest: per_item_manifests[item_idx].clone(),
                evidence_sids,
                guard_healthy,
                guard_diagnostic: guard_diagnostic.clone(),
                guard_sampling_mode: config.guard_sampling_policy,
                turns_ingested: per_item_ingest_counts[item_idx],
                write_mean_latency_seconds: write_mean,
                payload_text,
                choices: item.qa.choices.clone(),
                ground_truth: item.qa.ground_truth.clone(),
            },
        ));
    }

    let _ = client.disconnect();
    membench_guarded_teardown(&scratch_dir);

    Ok(results)
}

// ─────────────────────────────────────────────────────────────────────────────
// C11 — Token count helper
// ─────────────────────────────────────────────────────────────────────────────

/// Estimates the total token count of a MemBench item's session corpus.
///
/// Content format mirrors the live-path ingest string ("user: …\nassistant: …"),
/// matching the estate-write path exactly. Uses `lme_estimate_tokens` (UTF-8
/// ceiling-4), the same estimator used by LME-03 token efficiency.
///
/// Twin of Swift `memBenchItemTokenCount`.
pub fn membench_item_token_count(item: &MemBenchItem) -> usize {
    use crate::longmemeval_token_efficiency::lme_estimate_tokens;
    let mut total = 0usize;
    for session in &item.sessions {
        for turn in &session.turns {
            let content = format!("user: {}\nassistant: {}", turn.user_message, turn.assistant_message);
            total += lme_estimate_tokens(&content);
        }
    }
    total
}

// ─────────────────────────────────────────────────────────────────────────────
// C11 — Capacity tier runner
// ─────────────────────────────────────────────────────────────────────────────

/// Runs MemBench in capacity-tier mode, growing each item's estate to approximately
/// `target_tokens` with conflict-free filler before the query.
///
/// Strategy mirrors the Swift twin (`runMemBenchItemsCapacityTier`):
///   1. Filter, shuffle, offset/limit — same discipline as the per-item runner.
///   2. Group ALL filtered items by conflict key (C10 grouper).
///   3. For each item X, fill from X's group (excluding X) until target_tokens
///      is reached or the pool is exhausted — never pad beyond the pool.
///   4. Ingest X's sessions + filler sessions into a fresh per-item estate.
///      Only X's UUID→sid manifest is tracked; filler UUIDs are absent.
///   5. Settle, guard probe, query X's QA question.
///
/// Estate cache is NOT used: filler composition depends on the full corpus and
/// grouping, not a single item_id key.
///
/// Returns `(results, timing_report, achieved_tokens_per_item, items_per_estate)`.
///
/// Twin of Swift `runMemBenchItemsCapacityTier`.
pub fn run_membench_items_capacity_tier(
    items: &[MemBenchItem],
    config: &MemBenchRunConfig,
    target_tokens: usize,
) -> Result<(Vec<MemBenchItemResult>, Option<String>, Vec<usize>, Vec<usize>), String> {
    use crate::membench_scorer::MemBenchManifestEntry;
    use std::collections::VecDeque;
    use std::sync::Mutex;

    // Category filter.
    let all_filtered: Vec<&MemBenchItem> = if let Some(ref cat) = config.category_filter {
        items.iter().filter(|it| &it.category == cat).collect()
    } else {
        items.iter().collect()
    };

    // Seeded shuffle + offset/limit — same discipline as per-item runner.
    let mut rng = SplitMix64::new(config.seed);
    let mut shuffled: Vec<&MemBenchItem> = all_filtered.clone();
    rng.shuffle(&mut shuffled);
    let after_offset: Vec<&MemBenchItem> = shuffled.into_iter().skip(config.offset).collect();
    let selected: Vec<&MemBenchItem> = match config.limit {
        Some(lim) => after_offset.into_iter().take(lim).collect(),
        None => after_offset,
    };
    let n = selected.len();

    // Group ALL filtered items so the filler pool reflects the full corpus.
    // Items not in `selected` can still appear as fillers for items that are.
    let all_filtered_owned: Vec<MemBenchItem> = all_filtered.iter().map(|&it| it.clone()).collect();
    let all_groups: Vec<Vec<&MemBenchItem>> = membench_group_items_by_conflict_key(&all_filtered_owned);

    // item_id → group index (built once, read-only during the parallel phase).
    let mut item_group_idx: HashMap<String, usize> = HashMap::new();
    for (gi, g) in all_groups.iter().enumerate() {
        for it in g { item_group_idx.insert(it.item_id.clone(), gi); }
    }

    // Pre-compute token counts for all filtered items (read-only during parallel phase).
    let mut token_counts: HashMap<String, usize> = HashMap::new();
    for it in &all_filtered_owned {
        token_counts.insert(it.item_id.clone(), membench_item_token_count(it));
    }

    // Parallel execution — same work-queue + pre-sized result vec as the per-item runner.
    let verb_map = membench_verb_map();
    let work_queue: Mutex<VecDeque<usize>> = Mutex::new((0..n).collect());
    // Each slot holds Option<(result, achieved_tokens, items_in_estate)>.
    let slot_storage: Mutex<Vec<Option<(MemBenchItemResult, usize, usize)>>> =
        Mutex::new((0..n).map(|_| None).collect());
    let shared_guard_sampler = Mutex::new(LegGuardSampler::new(config.guard_sampling_policy));
    let timing_sampler = LegTimingSampler::new();
    let tier_label = config.capacity_tier.report_label();

    // Error channel: capture the first endpoint-config refusal so the thread
    // can return cleanly instead of panicking, propagated as Err after the scope.
    let endpoint_error: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

    std::thread::scope(|scope| {
        let handles: Vec<_> = (0..config.parallel_units).map(|_| {
            scope.spawn(|| {
                loop {
                    let idx = {
                        let mut q = work_queue.lock().unwrap();
                        match q.pop_front() { Some(i) => i, None => return }
                    };
                    let item = selected[idx];
                    let group_idx = item_group_idx.get(&item.item_id).copied().unwrap_or(0);
                    let group = &all_groups[group_idx];

                    // Filler pool: items in X's conflict-key group excluding X itself.
                    // All guaranteed to have a different question (no competing answers).
                    // .copied() turns &&MemBenchItem (from iter over Vec<&MemBenchItem>) into &MemBenchItem.
                    let filler_pool: Vec<&MemBenchItem> = group.iter()
                        .copied()
                        .filter(|it| it.item_id != item.item_id)
                        .collect();

                    // Greedy fill: accumulate X's token count, add fillers until target.
                    let base_tokens = token_counts.get(&item.item_id).copied()
                        .unwrap_or_else(|| membench_item_token_count(item));
                    let mut achieved_tokens = base_tokens;
                    let mut selected_fillers: Vec<&MemBenchItem> = vec![];
                    for filler in &filler_pool {
                        let ft = token_counts.get(&filler.item_id).copied()
                            .unwrap_or_else(|| membench_item_token_count(filler));
                        selected_fillers.push(filler);
                        achieved_tokens += ft;
                        if achieved_tokens >= target_tokens { break; }
                    }
                    let items_in_estate = 1 + selected_fillers.len();

                    eprintln!("[membench-cap{tier_label}] item={} (#{}/{n})", item.item_id, idx + 1);

                    // Fresh per-item scratch estate — capacity-tier estates are never cached.
                    let scratch_dir = match membench_scratch_dir(
                        config.seed, idx, config.scratch_posture)
                    {
                        Ok(d) => d,
                        Err(e) => {
                            eprintln!(
                                "[membench-cap{tier_label}] scratch dir error item={}: {}",
                                item.item_id, e
                            );
                            return;
                        }
                    };
                    let endpoint = match membench_endpoint_config(
                        &scratch_dir, &config.moot_binary_path,
                        config.scratch_posture, config.shape,
                    ) {
                        Ok(ep) => ep,
                        Err(e) => {
                            *endpoint_error.lock().unwrap() = Some(
                                format!("membench: endpoint config error: {e}")
                            );
                            return;
                        }
                    };
                    // Belt-and-suspenders: verify --db points into /tmp before connecting.
                    // Twin of Swift `assertScratchBackend(_:requirement:)` in MemBenchRunner.
                    crate::gauntlet_runner::assert_scratch_backend(
                        &endpoint, &crate::gauntlet_runner::MOOT_SCRATCH_REQUIREMENT,
                    );
                    let mut client = MCPClient::new(endpoint);
                    if let Err(e) = client.connect() {
                        eprintln!(
                            "[membench-cap{tier_label}] connect error item={}: {}",
                            item.item_id, e.description
                        );
                        membench_guarded_teardown(&scratch_dir);
                        return;
                    }

                    let mut manifest: Vec<MemBenchManifestEntry> = vec![];
                    let mut write_times: Vec<f64> = vec![];
                    let mut ingest_error: Option<String> = None;

                    // Ingest a single item's turns. `track` controls whether UUIDs are
                    // added to the manifest (true for X, false for fillers).
                    // Filler UUIDs absent from X's manifest; lme_ranked_sessions skips
                    // them silently — rank degradation is exactly what capacity tier measures.
                    macro_rules! ingest_one {
                        ($target:expr, $track:expr) => {
                            'item_ingest: {
                                for session in &$target.sessions {
                                    for turn in &session.turns {
                                        let content = format!(
                                            "user: {}\nassistant: {}",
                                            turn.user_message, turn.assistant_message
                                        );
                                        let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
                                        args.insert(
                                            verb_map.content_arg.clone(),
                                            JsonValue::String(content.clone()),
                                        );
                                        args.insert(
                                            "subject".to_string(),
                                            JsonValue::String(
                                                crate::subject_generator::deterministic_subject(&content),
                                            ),
                                        );
                                        for (k, v) in &verb_map.constant_args {
                                            args.insert(k.clone(), JsonValue::String(v.clone()));
                                        }
                                        if config.encode_barrier == EncodeBarrier::Impatient {
                                            args.insert(
                                                "impatient".to_string(), JsonValue::Bool(true),
                                            );
                                        }
                                        let t0 = Instant::now();
                                        match client.call_tool(
                                            &verb_map.write, args, &verb_map.result_format,
                                        ) {
                                            Ok(result) => {
                                                write_times.push(t0.elapsed().as_secs_f64());
                                                if $track {
                                                    if let Some(uuid) = result.write_assigned_id {
                                                        manifest.push(MemBenchManifestEntry {
                                                            uuid,
                                                            sid: turn.sid.to_string(),
                                                            session_index: session.session_index,
                                                        });
                                                    }
                                                }
                                            }
                                            Err(e) => {
                                                ingest_error = Some(format!(
                                                    "item={} sid={}: {}",
                                                    $target.item_id, turn.sid, e.description
                                                ));
                                                break 'item_ingest;
                                            }
                                        }
                                    }
                                }
                            }
                        };
                    }

                    // Ingest X's sessions (manifest tracked), then fillers (no manifest).
                    ingest_one!(item, true);
                    if ingest_error.is_none() {
                        for filler in &selected_fillers {
                            if ingest_error.is_some() { break; }
                            ingest_one!(filler, false);
                        }
                    }

                    if let Some(err) = ingest_error {
                        eprintln!("[membench-cap{tier_label}] ingest error: {err}");
                        let _ = client.disconnect();
                        membench_guarded_teardown(&scratch_dir);
                        return;
                    }

                    // Encode barrier (drain or impatient).
                    if config.encode_barrier == EncodeBarrier::Drain {
                        wait_for_encode_drain(
                            &mut client,
                            &format!("membench-cap{tier_label} item={}", item.item_id),
                            120.0,
                        );
                    }

                    // Settle: dream + reindex + post-settle drain.
                    let mut dream_args: BTreeMap<String, JsonValue> = BTreeMap::new();
                    dream_args.insert(
                        "associates".to_string(), JsonValue::String("all".to_string()),
                    );
                    if let Err(e) = client.call_tool(
                        crate::aria_v2_surface::DREAM, dream_args, &ResultFormat::MootV2,
                    ) {
                        eprintln!(
                            "[membench-cap{tier_label}] dream failed item={}: {}",
                            item.item_id, e.description
                        );
                    }
                    if let Err(e) = client.call_tool(
                        crate::aria_v2_surface::REINDEX, BTreeMap::new(), &ResultFormat::MootV2,
                    ) {
                        eprintln!(
                            "[membench-cap{tier_label}] reindex failed item={}: {}",
                            item.item_id, e.description
                        );
                    }
                    wait_for_encode_drain(
                        &mut client,
                        &format!("membench-cap{tier_label} settle item={}", item.item_id),
                        300.0,
                    );

                    // Timing capture — sampler caches the first result per leg.
                    timing_sampler.capture(|| {
                        crate::timing_capture::fetch_timing_report(&mut client)
                    });

                    // DegeneracyGuard probe — sampler caches the first verdict per leg.
                    let (guard_healthy, guard_diagnostic, _) = {
                        let mut sampler = shared_guard_sampler.lock().unwrap();
                        sampler.probe(|| probe_mcp_client(&mut client, &verb_map))
                    };

                    // Query X's QA question against the filled estate.
                    let mut query_args: BTreeMap<String, JsonValue> = BTreeMap::new();
                    query_args.insert(
                        verb_map.query_arg.clone(),
                        JsonValue::String(item.qa.question.clone()),
                    );
                    for (k, v) in &verb_map.constant_args {
                        query_args.insert(k.clone(), JsonValue::String(v.clone()));
                    }
                    let t_query = Instant::now();
                    let (retrieved_uuids, payload_text) = match client.call_tool(
                        &verb_map.query, query_args, &verb_map.result_format,
                    ) {
                        Ok(result) => {
                            let text = if result.text_blocks.is_empty() { None }
                                       else { Some(result.text_blocks.join("\n")) };
                            (result.ordered_ids, text)
                        }
                        Err(e) => {
                            eprintln!(
                                "[membench-cap{tier_label}] query error item={}: {}",
                                item.item_id, e.description
                            );
                            (Vec::new(), None)
                        }
                    };
                    let query_latency = t_query.elapsed().as_secs_f64();

                    let write_mean = if write_times.is_empty() { 0.0 }
                    else { write_times.iter().sum::<f64>() / write_times.len() as f64 };
                    let turns_ingested = manifest.len();
                    let evidence_sids = item.evidence_sids();

                    let result = MemBenchItemResult {
                        item_id: item.item_id.clone(),
                        category: item.category.clone(),
                        question: item.qa.question.clone(),
                        query_latency_seconds: query_latency,
                        retrieved_uuids,
                        // Only X's own manifest — filler UUIDs absent.
                        // turns_ingested = manifest.len() mirrors the per-item convention.
                        turns_ingested,
                        manifest,
                        evidence_sids,
                        guard_healthy,
                        guard_diagnostic,
                        guard_sampling_mode: config.guard_sampling_policy,
                        write_mean_latency_seconds: write_mean,
                        payload_text,
                        choices: item.qa.choices.clone(),
                        ground_truth: item.qa.ground_truth.clone(),
                    };

                    let _ = client.disconnect();
                    membench_guarded_teardown(&scratch_dir);

                    slot_storage.lock().unwrap()[idx] = Some((result, achieved_tokens, items_in_estate));
                }
            })
        }).collect();
        for h in handles { h.join().unwrap(); }
    });

    // Propagate endpoint-config refusal: if any thread stored an error, the
    // run_membench caller reaches eprintln! + ExitCode::FAILURE, not a panic.
    if let Some(err) = endpoint_error.into_inner().unwrap() {
        return Err(err);
    }

    let slots = slot_storage.into_inner().unwrap();
    let timing_text = timing_sampler.text();
    let mut results: Vec<MemBenchItemResult> = Vec::with_capacity(n);
    let mut achieved: Vec<usize> = Vec::with_capacity(n);
    let mut per_estate: Vec<usize> = Vec::with_capacity(n);
    for slot in slots.into_iter().flatten() {
        results.push(slot.0);
        achieved.push(slot.1);
        per_estate.push(slot.2);
    }
    Ok((results, timing_text, achieved, per_estate))
}
// ─────────────────────────────────────────────────────────────────────────────
// Dead-code suppression for unused import
// ─────────────────────────────────────────────────────────────────────────────

// `discover_moot_binary` is re-exported from this module so CLI callers can use
// the same resolution logic as the Swift runner. Re-use the import to keep the
// public surface symmetric.
#[allow(dead_code)]
fn _ensure_discover_import() -> Option<String> {
    discover_moot_binary()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scratch_posture::ScratchEstatePosture;

    // Wave-3 G3 twins of the locomo_runner scratch tests: containment is
    // checked against the canonicalized temp base, never a "/tmp/…" literal.

    #[test]
    fn scratch_dir_succeeds_under_real_temp_base() {
        let dir = membench_scratch_dir(0xB3B3_0003, 5, ScratchEstatePosture::PlaintextTransient)
            .expect("a legitimate scratch dir must be accepted on macOS and Linux alike");
        assert!(dir.starts_with(crate::config::canonical_tmp_base()));
        membench_guarded_teardown(&dir);
        assert!(!dir.exists(), "teardown must remove the dir");
    }

    #[test]
    fn scratch_dir_survives_preplaced_symlink_without_following_it() {
        let seed: u64 = 0xB3B3_0004;
        let link = std::path::PathBuf::from(format!("/tmp/membench-bench-{}-9", seed));
        let real_target = std::env::temp_dir().join(format!("membench-symlink-target-{seed:x}"));
        let _ = std::fs::remove_file(&link);
        let _ = std::fs::remove_dir_all(&link);
        std::fs::create_dir_all(&real_target).expect("create symlink target");
        #[cfg(unix)]
        std::os::unix::fs::symlink(&real_target, &link).expect("pre-place symlink");

        // membench's crash-leftover policy REMOVES any pre-existing entry
        // before creating the scratch dir, so a pre-placed symlink is
        // deleted (link only — never followed) and replaced by a real
        // directory. The safety property is: the target's contents are
        // untouched and the returned path is a real dir, not the link.
        let marker = real_target.join("marker.txt");
        std::fs::write(&marker, b"untouched").expect("write marker");

        let dir = membench_scratch_dir(seed, 9, ScratchEstatePosture::PlaintextTransient)
            .expect("pre-placed symlink is removed, then a real dir is created");
        assert!(
            !std::fs::symlink_metadata(&dir).unwrap().file_type().is_symlink(),
            "returned scratch path must be a real directory"
        );
        assert!(
            marker.exists(),
            "the symlink's target contents must be untouched by leftover removal"
        );

        membench_guarded_teardown(&dir);
        let _ = std::fs::remove_file(&link);
        let _ = std::fs::remove_dir_all(&real_target);
    }

    // ── C10 — EstateGroupingMode and grouping ──────────────────────────────────

    fn make_item_with_question(question: &str, item_id: &str) -> MemBenchItem {
        use crate::membench_corpus::{MemBenchItem, MemBenchQA};
        MemBenchItem {
            item_id: item_id.to_string(),
            category: "simple".to_string(),
            agent: "FirstAgent".to_string(),
            topic_key: "test".to_string(),
            tid: 0,
            sessions: vec![],
            qa: MemBenchQA {
                qid: 0,
                question: question.to_string(),
                answer: "a".to_string(),
                target_step_id: vec![],
                choices: Default::default(),
                ground_truth: "A".to_string(),
                time: "".to_string(),
            },
        }
    }

    #[test]
    fn c10_conflict_key_is_question_text() {
        let item = make_item_with_question("What is X?", "item/0");
        assert_eq!(membench_conflict_key(&item), "What is X?");
    }

    #[test]
    fn c10_parse_nil_gives_per_item() {
        assert_eq!(EstateGroupingMode::parse(None).unwrap(), EstateGroupingMode::PerItem);
    }

    #[test]
    fn c10_parse_per_item_explicit() {
        assert_eq!(
            EstateGroupingMode::parse(Some("per-item")).unwrap(),
            EstateGroupingMode::PerItem
        );
    }

    #[test]
    fn c10_parse_consolidated_gives_consolidated_shape3() {
        assert_eq!(
            EstateGroupingMode::parse(Some("consolidated")).unwrap(),
            EstateGroupingMode::ConsolidatedShape3
        );
    }

    #[test]
    fn c10_parse_invalid_returns_err() {
        let err = EstateGroupingMode::parse(Some("shape3")).unwrap_err();
        assert!(err.contains("'shape3'"), "error should mention the bad value: {err}");
    }

    #[test]
    fn c10_as_str_round_trips() {
        assert_eq!(EstateGroupingMode::PerItem.as_str(), "per-item");
        assert_eq!(EstateGroupingMode::ConsolidatedShape3.as_str(), "consolidated");
    }

    #[test]
    fn c10_group_all_distinct_keys_gives_one_group() {
        let items = vec![
            make_item_with_question("Q1", "item/0"),
            make_item_with_question("Q2", "item/1"),
            make_item_with_question("Q3", "item/2"),
        ];
        let groups = membench_group_items_by_conflict_key(&items);
        assert_eq!(groups.len(), 1, "all distinct keys → 1 group");
        assert_eq!(groups[0].len(), 3);
    }

    #[test]
    fn c10_group_all_same_key_gives_n_groups() {
        let items = vec![
            make_item_with_question("same", "item/0"),
            make_item_with_question("same", "item/1"),
            make_item_with_question("same", "item/2"),
        ];
        let groups = membench_group_items_by_conflict_key(&items);
        assert_eq!(groups.len(), 3, "all same key → N groups of 1");
        for g in &groups {
            assert_eq!(g.len(), 1);
        }
    }

    #[test]
    fn c10_group_greedy_round_robin() {
        // Q1 appears twice → 2 groups. Q2 and Q3 appear once → go to group 0.
        let items = vec![
            make_item_with_question("Q1", "item/0"),  // group 0 (first Q1)
            make_item_with_question("Q2", "item/1"),  // group 0
            make_item_with_question("Q1", "item/2"),  // group 1 (second Q1)
            make_item_with_question("Q3", "item/3"),  // group 0
        ];
        let groups = membench_group_items_by_conflict_key(&items);
        assert_eq!(groups.len(), 2);
        let g0_ids: Vec<&str> = groups[0].iter().map(|i| i.item_id.as_str()).collect();
        let g1_ids: Vec<&str> = groups[1].iter().map(|i| i.item_id.as_str()).collect();
        assert_eq!(g0_ids, vec!["item/0", "item/1", "item/3"]);
        assert_eq!(g1_ids, vec!["item/2"]);
    }

    #[test]
    fn c10_grouping_is_deterministic() {
        let items: Vec<_> = (0..6)
            .map(|i| make_item_with_question(&format!("Q{}", i % 3), &format!("item/{i}")))
            .collect();
        let groups1 = membench_group_items_by_conflict_key(&items);
        let groups2 = membench_group_items_by_conflict_key(&items);
        let ids1: Vec<Vec<&str>> = groups1.iter()
            .map(|g| g.iter().map(|i| i.item_id.as_str()).collect())
            .collect();
        let ids2: Vec<Vec<&str>> = groups2.iter()
            .map(|g| g.iter().map(|i| i.item_id.as_str()).collect())
            .collect();
        assert_eq!(ids1, ids2, "grouping must be deterministic");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // C11 — CapacityTier and membench_item_token_count unit tests
    // ─────────────────────────────────────────────────────────────────────────

    #[test]
    fn c11_capacity_tier_parse_none_gives_baseline() {
        assert_eq!(CapacityTier::parse(None).unwrap(), CapacityTier::Baseline);
    }

    #[test]
    fn c11_capacity_tier_parse_baseline_explicit() {
        assert_eq!(CapacityTier::parse(Some("baseline")).unwrap(), CapacityTier::Baseline);
    }

    #[test]
    fn c11_capacity_tier_parse_10k() {
        assert_eq!(CapacityTier::parse(Some("10k")).unwrap(), CapacityTier::TenK);
    }

    #[test]
    fn c11_capacity_tier_parse_100k() {
        assert_eq!(CapacityTier::parse(Some("100k")).unwrap(), CapacityTier::HundredK);
    }

    #[test]
    fn c11_capacity_tier_parse_invalid_errors() {
        assert!(CapacityTier::parse(Some("50k")).is_err());
    }

    #[test]
    fn c11_target_tokens_baseline_is_none() {
        assert_eq!(CapacityTier::Baseline.target_tokens(), None);
    }

    #[test]
    fn c11_target_tokens_10k_is_10000() {
        assert_eq!(CapacityTier::TenK.target_tokens(), Some(10_000));
    }

    #[test]
    fn c11_target_tokens_100k_is_100000() {
        assert_eq!(CapacityTier::HundredK.target_tokens(), Some(100_000));
    }

    #[test]
    fn c11_estate_shape_label_baseline_is_none() {
        assert!(CapacityTier::Baseline.estate_shape_label().is_none());
    }

    #[test]
    fn c11_estate_shape_label_10k() {
        assert_eq!(
            CapacityTier::TenK.estate_shape_label(),
            Some("per-item-capacity-10k")
        );
    }

    #[test]
    fn c11_estate_shape_label_100k() {
        assert_eq!(
            CapacityTier::HundredK.estate_shape_label(),
            Some("per-item-capacity-100k")
        );
    }

    #[test]
    fn c11_token_count_empty_item_is_zero() {
        // Item with no sessions → token count must be 0.
        let item = make_item_with_question("q", "item/c11/0");
        // make_item_with_question produces an item with no sessions (sessions: vec![]).
        assert_eq!(membench_item_token_count(&item), 0);
    }

    #[test]
    fn c11_token_count_single_turn_matches_formula() {
        // Formula: lme_estimate_tokens = (utf8_bytes + 3) / 4
        // Content = "user: hello\nassistant: world" → 29 bytes → (29+3)/4 = 8
        use crate::membench_corpus::{MemBenchItem, MemBenchQA, MemBenchSession, MemBenchTurn};
        let content = "user: hello\nassistant: world";
        let expected = (content.len() + 3) / 4;
        let turn = MemBenchTurn {
            sid: 1,
            user_message: "hello".to_string(),
            assistant_message: "world".to_string(),
            time: "".to_string(),
            place: "".to_string(),
        };
        let session = MemBenchSession { session_index: 0, turns: vec![turn] };
        let item = MemBenchItem {
            item_id: "item/c11/1".to_string(),
            category: "simple".to_string(),
            agent: "FirstAgent".to_string(),
            topic_key: "test".to_string(),
            tid: 0,
            sessions: vec![session],
            qa: MemBenchQA {
                qid: 0,
                question: "q".to_string(),
                answer: "a".to_string(),
                target_step_id: vec![],
                choices: Default::default(),
                ground_truth: "A".to_string(),
                time: "".to_string(),
            },
        };
        assert_eq!(membench_item_token_count(&item), expected,
            "token count must match (utf8_bytes+3)/4 formula; content len={}", content.len());
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// B4/BH-02 settle-gate tests — MemBench per-item lane
// ─────────────────────────────────────────────────────────────────────────────

/// Pins the B4/BH-02 settle-gate fix for the MemBench per-item lane: when
/// `moot_dream` fails during the settle sequence, the artifact must NOT be written
/// to the estate cache. Before BH-02 was closed in this lane, the dream failure
/// was logged but no fitness flag was set, so the save at the gate checked only
/// `ingest_error.is_none()` — true here, so the save happened. The fix introduces
/// `settle_dream_ok` / `settle_reindex_ok` booleans and gates the save with
/// `estate_is_fit_to_cache`. This test verifies the observable difference: pre-fix
/// the test FAILS (artifact IS written), post-fix the test PASSES (artifact absent).
#[cfg(test)]
mod membench_settle_gate_tests {
    use super::{
        run_membench_items, BenchShape, CapacityTier, EstateGroupingMode, MemBenchRunConfig,
    };
    use crate::degeneracy_guard::GuardSamplingPolicy;
    use crate::encode_barrier::EncodeBarrier;
    use crate::estate_cache::EstateCacheMode;
    use crate::membench_corpus::{MemBenchItem, MemBenchQA, MemBenchSession, MemBenchTurn};
    use crate::scratch_posture::ScratchEstatePosture;
    use crate::seed_export::SeedPathMode;
    use std::io::Write;
    use std::path::PathBuf;

    /// Writes a mock MCP server that:
    ///   - Responds to `initialize` with the MCP protocol-version handshake.
    ///   - Responds to `moot_file_memory` with a "filed memory <UUID>" text block
    ///     so the runner's UUID extraction succeeds and ingest is treated as ok.
    ///   - Responds to `moot_dream` with a JSON-RPC error, simulating a settle
    ///     failure that must prevent the artifact from being cached.
    ///   - Responds to every other tool call with an ok content block.
    ///
    /// Uses the same PID-unique private-directory pattern as the LME tracking mock
    /// to keep parallel test invocations isolated.
    fn write_membench_failing_dream_mock() -> PathBuf {
        let base = std::env::temp_dir();
        let mut mock_dir = None;
        for attempt in 0u32..1000 {
            let candidate = base.join(format!(
                "mb-dream-fail-mock-{}-{attempt}",
                std::process::id()
            ));
            match std::fs::create_dir(&candidate) {
                Ok(()) => { mock_dir = Some(candidate); break; }
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(e) => panic!("cannot create membench mock dir: {e}"),
            }
        }
        let mock_dir = mock_dir.expect("no free membench mock dir in 1000 attempts");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&mock_dir, std::fs::Permissions::from_mode(0o700))
                .expect("chmod membench mock dir");
        }
        let script_path = mock_dir.join("mock.sh");
        // UUID format is 8-4-4-4-12 hex (validated by leading_uuid in mcp_result.rs).
        // The "filed memory <UUID>" line is what the runner's UUID extractor matches.
        //
        // moot_drain_status: the drain barrier parser is strict — "ok" is Unparseable
        // and causes process::exit(1). Return "drains: none" which the parser maps to
        // NoLanes. The grace window (4 consecutive no-lanes + 2s) then accepts idle.
        // The settle drain after moot_reindex is unconditional on this path; the
        // ~2s grace wait is the expected test latency for the pre-fix failure branch.
        let script = r#"#!/bin/sh
first=1
while IFS= read -r line; do
  if [ "$first" = "1" ]; then
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05"}}'
    first=0
  else
    name=$(echo "$line" | sed 's/.*"name":"\([^"]*\)".*/\1/')
    if [ "$name" = "moot_dream" ]; then
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"settle dream failed: mock injection"}}'
    elif [ "$name" = "moot_file_memory" ]; then
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"filed memory 12345678-1234-1234-1234-123456789abc"}]}}'
    elif [ "$name" = "moot_drain_status" ]; then
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"drains: none"}]}}'
    else
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"ok"}]}}'
    fi
  fi
done
"#;
        let mut f = std::fs::File::create(&script_path)
            .expect("create membench failing-dream mock script");
        f.write_all(script.as_bytes()).expect("write membench mock script");
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

    /// Returns a minimal MemBenchItem with one session and one turn. The single
    /// turn triggers exactly one `moot_file_memory` call on the Live ingest path,
    /// which the mock answers with a synthetic UUID. The item carries no evidence
    /// sids so retrieval scoring is trivially vacuous.
    fn make_minimal_item() -> MemBenchItem {
        use std::collections::HashMap;
        MemBenchItem {
            item_id: "FirstAgent/simple/roles/0".to_string(),
            category: "simple".to_string(),
            agent: "FirstAgent".to_string(),
            topic_key: "roles".to_string(),
            tid: 0,
            sessions: vec![MemBenchSession {
                session_index: 0,
                turns: vec![MemBenchTurn {
                    sid: 1,
                    user_message: "Hello?".to_string(),
                    assistant_message: "World!".to_string(),
                    time: "2024-01-01T00:00:00Z".to_string(),
                    place: "here".to_string(),
                }],
            }],
            qa: MemBenchQA {
                qid: 1,
                question: "What role did you play?".to_string(),
                answer: "FirstAgent".to_string(),
                target_step_id: vec![],
                choices: HashMap::from([
                    ("A".to_string(), "FirstAgent".to_string()),
                    ("B".to_string(), "other".to_string()),
                ]),
                ground_truth: "A".to_string(),
                time: "2024-01-01T00:00:00Z".to_string(),
            },
        }
    }

    /// BH-02 discriminating test for the MemBench per-item lane: a moot_dream
    /// failure during the settle sequence must prevent the artifact from being
    /// written to the artifact cache. Pre-fix, the dream failure was logged but
    /// the save still executed because `ingest_error.is_none()` was the only gate.
    /// Post-fix, `settle_dream_ok = false` makes `estate_is_fit_to_cache` return
    /// false and the save is skipped.
    ///
    /// PRE-FIX EXPECTED RESULT: test FAILS — cache_entry/estate IS written.
    /// POST-FIX EXPECTED RESULT: test PASSES — cache_entry/estate absent.
    #[test]
    fn settle_dream_failure_blocks_cache_write() {
        let pid = std::process::id();
        let base = std::env::temp_dir();
        // Dedicated cache root for this test run, created before the runner starts.
        // The runner derives the exact entry path from the config + item_id; we
        // replicate that derivation to know what to assert on.
        let cache_root = base.join(format!("mb-settle-cache-{pid}"));
        let _ = std::fs::remove_dir_all(&cache_root);
        std::fs::create_dir_all(&cache_root).expect("create test cache root");
        // This test drives the lane with the estate cache ENABLED, so the drift
        // gate applies to it exactly as it does to a real run. Write a receipt
        // whose validated-source mtime is 0, which every binary is newer than:
        // the test is about the settle gate, and it should neither depend on
        // the drift gate's state nor be able to bypass it.
        std::fs::write(
            cache_root.join(crate::drift_gate_receipt::RECEIPT_FILENAME),
            "1970-01-01T00:00:00Z\ntest-fixture\n0\n",
        )
        .expect("write drift-gate receipt for test cache root");

        let script = write_membench_failing_dream_mock();
        // The script is chmod 755 and has a shebang — invoked directly, no sh prefix.
        let mock_binary = script.clone();

        let item = make_minimal_item();
        let seed: u64 = 0xB304_DEAD;
        let config = MemBenchRunConfig {
            unit_ids: None,
            retrieval_call: None,
            payload_arm: None,
            moot_binary_path: mock_binary,
            data_dir: base.join("nonexistent-membench-data"),
            agent: "FirstAgent".to_string(),
            limit: Some(1),
            offset: 0,
            seed,
            out_dir: None,
            run_label: "settle-gate-test".to_string(),
            // Impatient mode: no post-ingest moot_drain_status polling between ingest
            // and the settle dream call. The settle drain (after reindex) still runs
            // unconditionally; the mock responds with ok causing ~2s grace-window wait.
            encode_barrier: EncodeBarrier::Impatient,
            scratch_posture: ScratchEstatePosture::PlaintextTransient,
            category_filter: None,
            seed_path: SeedPathMode::Live, // one moot_file_memory per turn; no batch import
            guard_sampling_policy: GuardSamplingPolicy::OncePerLeg,
            estate_cache: EstateCacheMode::Reuse, // enables the save path under test
            cache_dir: Some(cache_root.clone()),
            corpus_digest: "test-settle-gate".to_string(),
            shape: BenchShape::Disk,
            parallel_units: 1, // serial; avoids race conditions in a unit test
            estate_grouping: EstateGroupingMode::PerItem,
            capacity_tier: CapacityTier::Baseline,
        };

        // Replicate the cache-entry path derivation so we know exactly which
        // directory the runner would write to. This mirrors estate_cache_entry_path's
        // own logic (benchmark="membench", variant=agent).
        let cache_entry = crate::estate_cache::estate_cache_entry_path(
            &cache_root,
            "membench",
            &config.agent,
            seed,
            config.encode_barrier,
            config.scratch_posture,
            config.seed_path,
            &item.item_id,
        );

        let (results, _timing) = run_membench_items(&[item], &config)
            .expect("run_membench_items must not fail in unit test context");

        // Clean up mock dir before asserting so temp dirs don't accumulate on failure.
        let _ = std::fs::remove_dir_all(script.parent().expect("mock script has a parent dir"));

        // One result must be returned — the item ran, just with a dream failure.
        assert_eq!(results.len(), 1, "one item must produce one result");

        // Primary assertion: the cache entry must contain no artifact. Pre-fix, this
        // assertion fails because the save executed despite the dream failure.
        // Post-fix, the fitness gate blocks the save and the entry stays absent.
        assert!(
            !cache_entry.join("estate").exists(),
            "cache_entry/estate must not exist after a dream failure (pre-fix: \
             this assertion fails because save executed despite settle failure; \
             post-fix: fitness gate blocks save); found: {}",
            cache_entry.join("estate").display()
        );
        assert!(
            !cache_entry.join("manifest.json").exists(),
            "cache_entry/manifest.json must not exist after a dream failure"
        );

        // Cleanup.
        let _ = std::fs::remove_dir_all(&cache_root);
    }
}
