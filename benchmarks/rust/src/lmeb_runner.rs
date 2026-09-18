//! lmeb_runner.rs — live harness driving mootx01 for LMEB/ConvoMem benchmarking.
//!
//! Rust twin of `LMEBRunner.swift`. Mirrors the Swift per-query loop:
//! create an isolated scratch dir → launch mootx01 pointing at it →
//! ingest candidate documents via live MCP write (n=true inline-encoding
//! barrier on every write) → probe for degeneracy → query the question →
//! map UUID→docID via manifest → teardown.
//!
//! Each query gets a dedicated mootx01 process with a fresh estate —
//! matching the Swift "fresh-per-query" default.
//!
//! # Key differences from `longmemeval_runner.rs`
//!
//! - Scratch dir prefix: `/tmp/lmeb-bench-` (not `/tmp/lme-bench-`).
//! - VerbMap location: `"benchmarks/lmeb"` (not `"benchmarks/longmemeval"`).
//! - Ground truth: SET of doc IDs (no session/turn structure).
//! - Candidate pool: per-query (10–168 docs), not all 500k.
//! - Ingest: single doc text per `moot_file_memory` call.
//! - Manifest: UUID → docID (not session/turn/index).
//! - `encode_barrier` in `LmebRunConfig` controls how the harness synchronizes
//!   with background encoding (same modes as LME/LoCoMo runners).
//!
//! # Safety guarantees
//!
//! - `lmeb_scratch_dir()` names dirs `/tmp/lmeb-bench-<seed_hex>-<query_idx_hex>`.
//! - `lmeb_guarded_teardown()` refuses any path without the `/tmp/lmeb-bench-`
//!   prefix — mirrors the guard in `lme_guarded_teardown`.
//! - `--db <scratch_dir>` is passed to `moot serve` so the backend attaches
//!   a transient catalog record at the scratch dir, never the operator's estate.

use crate::config::{EndpointConfig, EndpointRole, ResultFormat, Transport, VerbMap};
use crate::degeneracy_guard::LegGuardSampler;
use crate::encode_barrier::{EncodeBarrier, wait_for_encode_drain};
use crate::scratch_posture::{moot_serve_command, LaneError, ScratchEstatePosture};
use crate::estate_cache::{ estate_cache_entry_path,
    restore_estate_cache_entry, save_estate_cache_entry, EstateCacheMode,
};
use crate::json_value::JsonValue;
use crate::lmeb_corpus::{LmebCorpus, LmebQuery};
use crate::lmeb_scorer::LmebQueryResult;
use crate::longmemeval_runner::{probe_mcp_client, SplitMix64};
use crate::mcp_client::{MCPClient, MCPError, ToolCaller};
use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Instant;

// ─────────────────────────────────────────────────────────────────────────────
// Estate shape (C1)
// ─────────────────────────────────────────────────────────────────────────────

/// Storage shape for LMEB scratch estates.
///
/// Mirrors Swift `BenchRunShape` in LMEBRunner.swift. The shape is recorded
/// in the run report alongside `encode_barrier` and `parallel_units`.
///
/// - `Disk` (default): normal on-disk SQLite estate. Compatible with estate cache.
/// - `Ram`: in-RAM estate (`--in-memory`). No cache permitted;
///   combining with `--estate-cache reuse|require` is rejected at the CLI level.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BenchRunShape {
    /// On-disk SQLite estate (default). Compatible with estate cache.
    Disk,
    /// In-RAM estate (`--in-memory`). Ephemeral; cache forbidden.
    Ram,
}

impl BenchRunShape {
    /// Returns the string representation written to the run report JSON.
    pub fn as_str(self) -> &'static str {
        match self {
            BenchRunShape::Disk => "disk",
            BenchRunShape::Ram => "ram",
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Estate grouping shape (C10-LMEB, Shape 3)
// ─────────────────────────────────────────────────────────────────────────────

/// Grouping topology for LMEB scratch estates.
///
/// Orthogonal to `BenchRunShape` (disk/ram axis). Controls how the corpus is
/// partitioned into estates.
///
/// Twin of Swift `LMEBEstateShape` in `LMEBRunner.swift`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LmebEstateShape {
    /// One fresh estate per query. Published per-item isolation protocol (default).
    PerQuery,
    /// One estate per scene_id group. Shape 3, a labelled deviation from the
    /// published protocol. Conflict key: `scene_id` (per-lane data analysis).
    Consolidated,
}

impl LmebEstateShape {
    /// Returns the string representation written to the report JSON's `estate_shape` field.
    /// Byte-identical to Swift `LMEBEstateShape.rawValue`.
    pub fn as_str(self) -> &'static str {
        match self {
            LmebEstateShape::PerQuery     => "per-query",
            LmebEstateShape::Consolidated => "consolidated-shape3",
        }
    }

    /// Parses a CLI flag value ("per-query" or "consolidated").
    /// Returns Err for unrecognized values.
    pub fn parse(s: &str) -> Result<Self, String> {
        match s {
            "per-query"    => Ok(LmebEstateShape::PerQuery),
            "consolidated" => Ok(LmebEstateShape::Consolidated),
            other => Err(format!("--estate-shape must be 'per-query' or 'consolidated'; got '{other}'")),
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Scene ID extraction and grouping (C10-LMEB)
// ─────────────────────────────────────────────────────────────────────────────

/// Extracts the `scene_id` from an LMEB query ID by stripping the trailing `_q_N` suffix.
///
/// Query IDs follow the pattern `scene_X_q_N` (e.g. `"scene_42_q_0"`). The scene_id
/// is everything before the LAST `"_q_"` marker. When no marker is found, `query_id`
/// is returned unchanged (safe fallback).
///
/// Twin of Swift `lmebSceneID(from:)` in `LMEBRunner.swift`. Uses `rfind` to locate
/// the last occurrence of `_q_`, mirroring Swift's `.backwards` option.
pub fn lmeb_scene_id_from_query_id(query_id: &str) -> &str {
    // rfind returns the byte offset of the last occurrence.
    if let Some(pos) = query_id.rfind("_q_") {
        &query_id[..pos]
    } else {
        query_id
    }
}

/// Groups a flat list of queries by `scene_id`.
///
/// Returns a `Vec<(scene_id, Vec<query>)>` sorted by `scene_id` for deterministic
/// estate-building order. Within each group, queries are sorted by `id`.
///
/// Twin of Swift `lmebGroupQueriesByScene(_:)` in `LMEBRunner.swift`.
pub fn lmeb_group_queries_by_scene(
    queries: &[LmebQuery],
) -> Vec<(String, Vec<LmebQuery>)> {
    use std::collections::BTreeMap;
    let mut by_scene: BTreeMap<String, Vec<LmebQuery>> = BTreeMap::new();
    for q in queries {
        let sid = lmeb_scene_id_from_query_id(&q.id).to_string();
        by_scene.entry(sid).or_default().push(q.clone());
    }
    let mut groups: Vec<(String, Vec<LmebQuery>)> = by_scene.into_iter().collect();
    for (_, qs) in &mut groups {
        qs.sort_by(|a, b| a.id.cmp(&b.id));
    }
    groups
}

// ─────────────────────────────────────────────────────────────────────────────
// Run configuration
// ─────────────────────────────────────────────────────────────────────────────

/// Configuration for one LMEB run. Constructed by main.rs from CLI flags.
pub struct LmebRunConfig {
    pub moot_binary: String,
    pub seed: u64,
    pub limit: Option<usize>,
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
    // OMISSION NOTICE (W4-lmeb-accuracy): The Swift twin added judge accuracy
    // plumbing here — `judge_cmd: Option<String>`, `judge_grading: LmeJudgeGrading`,
    // and `judge_hydration_depth: usize`. The Rust leg does not yet carry these
    // fields. When porting: add the three fields here, wire judge calls into
    // `run_lmeb_queries` after the UUID→docID mapping step (mirroring the Swift
    // implementation), and update LmebQueryResult / LmebReport in lmeb_scorer.rs.
    // The Rust longmemeval_judge module already has `lme_run_judge`, `lme_grade_judge_answer`,
    // `LmeJudgeGrading`, `lme_verdict_prompt`, and `lme_parse_verdict` — reuse them.
    // Secrecy rule: judge_cmd text is NEVER written to any report field; only
    // judge_cmd_set (bool) is emitted (matching the Swift contract).
    /// Seed-file loading strategy. `Batch` (default) emits a schema v1 seed file
    /// and calls `moot_json_import` once per query; `Live` retains the original
    /// per-doc `moot_file_memory` loop for periodic equivalence re-proving.
    /// Twin of Swift `LMEBRunConfig.seedPath`.
    pub seed_path: crate::seed_export::SeedPathMode,
    /// Path to write the pre-judge JSONL dump (`--dump-judge-inputs`).
    /// When set, a header line is written before the query loop and one
    /// query line per question after retrieval. The file can be post-processed
    /// offline with `judge-batch`. Twin of Swift `LMEBRunConfig.dumpJudgeInputsPath`.
    pub dump_judge_inputs_path: Option<String>,
    /// Guard probe sampling policy for this leg. Default `OncePerLeg` probes on the
    /// first query only. Use `PerUnit` only for debugging.
    /// Twin of Swift `LMEBRunConfig.guardSamplingPolicy`.
    pub guard_sampling_policy: crate::degeneracy_guard::GuardSamplingPolicy,
    /// SHA-256 digest of the corpus fixture inputs (B2 provenance). Computed
    /// once at main.rs load time; "unknown" never validates.
    pub corpus_digest: String,
    // MARK: Estate shape (additive — C1)
    /// Storage shape of scratch estates. Default `Disk`. `Ram` appends
    /// `--in-memory`; incompatible with estate cache reuse/require.
    pub shape: BenchRunShape,
    // MARK: Parallelism (additive — C6)
    /// Effective parallel-unit count. 1 = serial (default). Each unit owns its
    /// own scratch dir, MCPClient, and mootx01 process. Results are written to
    /// index-keyed slots and sorted by original index so report ordering is
    /// byte-deterministic regardless of thread completion order.
    pub parallel_units: usize,
    // MARK: Estate grouping shape (additive — C10-LMEB, Shape 3)
    /// Estate grouping topology. Default `PerQuery`: one estate per query
    /// (published per-item isolation protocol). `Consolidated`: one estate per
    /// scene_id group (Shape 3 deviation). Recorded in the report JSON as "estate_shape".
    /// Twin of Swift `LMEBRunConfig.estateShape`.
    pub estate_shape: LmebEstateShape,
}

// ─────────────────────────────────────────────────────────────────────────────
// Manifest entry for estate cache serialization
// ─────────────────────────────────────────────────────────────────────────────

/// Serializable per-document manifest entry for the LMEB estate cache.
///
/// LMEB uses an inline `HashMap<String, String>` (uuid → doc_id) during running.
/// This struct lets the cache serialize and restore that mapping via JSON.
///
/// Not in lmeb_scorer.rs because it is runner-internal (scoring does not
/// need the manifest format; only the runner and cache layer do).
#[derive(Debug, serde::Serialize, serde::Deserialize)]
struct LmebManifestEntry {
    uuid: String,
    doc_id: String,
}

// ─────────────────────────────────────────────────────────────────────────────
// VerbMap
// ─────────────────────────────────────────────────────────────────────────────

/// Returns the VerbMap for the LMEB harness.
///
/// `location: "benchmarks/lmeb"` scopes all writes to the LMEB namespace —
/// distinct from the longmemeval namespace so the two benchmarks never share
/// content when run against the same binary.

pub fn lmeb_verb_map() -> VerbMap {
    let mut constant_args = BTreeMap::new();
    constant_args.insert("location".to_string(), "benchmarks/lmeb".to_string());
    VerbMap::new(
        crate::aria_v2_surface::FILE_MEMORY,
        crate::aria_v2_surface::MEMORY_SEARCH,
        None, // list: not used
        None, // fetch: not used
        None, // content_arg: defaults to "content"
        None, // query_arg: defaults to "query"
        Some(constant_args),
        Some(ResultFormat::MootV2),
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// Batch seed builder for LMEB
// ─────────────────────────────────────────────────────────────────────────────

/// Builds the full seed record list for one LMEB query in CANDIDATE INGEST ORDER.
///
/// Mirrors `lmebSeedRecords(candidateDocIDs:corpus:baseOffset:)` in
/// `LMEBRunner.swift` exactly — same record ID scheme (docID), same content
/// format (doc.text verbatim), same event-time assignment — so the two ports
/// produce byte-identical seed files for the same input.
///
/// Docs absent from `corpus.docs_by_id` are silently skipped (same as the live
/// `ingest_doc` call site). Record IDs are doc IDs directly — already unique
/// within the candidate pool and human-readable for debugging.
///
/// Event times: deterministic +1 s per record from `"2026-01-01T00:00:00Z"` +
/// `base_offset` via `synthetic_event_time`. Room constant is `"benchmarks/lmeb"`
/// (from `lmeb_verb_map()`'s location arg). Wing is omitted (None) — records land
/// in the default Agentic Memory wing matching the live path.
pub fn lmeb_seed_records(
    candidate_doc_ids: &[String],
    corpus: &LmebCorpus,
    base_offset: usize,
) -> Vec<crate::seed_export::SeedFileRecord> {
    use crate::seed_export::{synthetic_event_time, SeedFileRecord};
    const ROOM: &str = "benchmarks/lmeb";

    candidate_doc_ids
        .iter()
        .enumerate()
        .filter_map(|(i, doc_id)| {
            corpus.docs_by_id.get(doc_id).map(|doc| {
                SeedFileRecord::new(doc_id, &doc.text, &synthetic_event_time(base_offset + i), ROOM)
            })
        })
        .collect()
}

// ─────────────────────────────────────────────────────────────────────────────
// Scratch dir management
// ─────────────────────────────────────────────────────────────────────────────

/// Creates a fresh scratch directory for one LMEB query's mootx01 instance.
/// Path: `/tmp/lmeb-bench-<seed_hex>-<query_index_hex>`.
///
/// The deterministic naming ensures each query has a unique path even across
/// retries, and the `/tmp/lmeb-bench-` prefix enables guarded teardown.
/// Twin of Swift `lmebScratchDir(posture:)` (UUID suffix variant; here
/// seed+index for determinism matching `lme_scratch_dir`).
///
/// `posture` decides the at-rest encryption of the estate this dir will hold
/// and rides on the serve command (see scratch_posture.rs). No default on purpose: every call site
/// decides posture explicitly.
pub fn lmeb_scratch_dir(
    seed: u64,
    query_index: usize,
    posture: ScratchEstatePosture,
) -> Result<PathBuf, MCPError> {
    let name = format!("lmeb-bench-{seed:016x}-{query_index:08x}");
    let path = PathBuf::from("/tmp").join(&name);
    std::fs::create_dir_all(&path).map_err(|e| MCPError {
        description: format!("lmeb_scratch_dir: failed to create {}: {e}", path.display()),
    })?;
    // The posture is the record's: a transient record is plaintext by rule.
    let _ = posture;
    Ok(path)
}

/// Removes a scratch directory created by `lmeb_scratch_dir`.
///
/// Guard: path must begin with `/tmp/lmeb-bench-`. Any other prefix is
/// refused — prevents a misconfigured path from deleting real data.
/// Twin of Swift `lmebGuardedTeardown(_:)`.
pub fn lmeb_guarded_teardown(path: &Path) -> Result<(), MCPError> {
    let path_str = path.to_string_lossy();
    if !path_str.starts_with("/tmp/lmeb-bench-") {
        return Err(MCPError {
            description: format!(
                "SAFETY: lmeb_guarded_teardown refused to delete '{}' — \
                 path must have the /tmp/lmeb-bench- prefix. \
                 Only directories created by lmeb_scratch_dir() may be torn down by this guard.",
                path.display()
            ),
        });
    }
    if path.exists() {
        std::fs::remove_dir_all(path).map_err(|e| MCPError {
            description: format!("lmeb_guarded_teardown: failed for {}: {e}", path.display()),
        })?;
    }
    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────
// Endpoint config
// ─────────────────────────────────────────────────────────────────────────────

/// Builds an `EndpointConfig` for the LMEB harness pointing at `scratch_dir`.
///
/// Command form: `[KEY=VALUE …] <binary> serve --db <scratch_dir> [--in-memory]`.
/// `MCPClient` splits on whitespace and runs via `/usr/bin/env`, which resolves
/// `KEY=VALUE` prefix tokens natively.
///
/// When `shape == Ram`, appends `--in-memory` so mootx01 selects
/// PersistenceKit's InMemory backend. No on-disk SQLite file is created; the
/// estate is ephemeral and cannot be snapshotted — `--estate-cache reuse|require`
/// is incompatible with RAM shape and is rejected at the CLI level before this
/// function is ever reached. Twin of Swift `lmebEndpointConfig(scratchDir:...shape:)`.
pub fn lmeb_endpoint_config(
    scratch_dir: &Path,
    moot_binary: &str,
    posture: ScratchEstatePosture,
    shape: BenchRunShape,
) -> Result<EndpointConfig, String> {
    let data_dir = scratch_dir.to_string_lossy();
    // RAM shape serves the InMemory backend (--in-memory); Disk shape is the
    // SQLite file the transient record names. The posture is the record's.
    let _ = posture;
    // MOOTX01_VAULT=1: the batch seed path calls the vault-gated `moot_json_import`.
    // Vault defaults ON (any value but "0"), so this is defensive — it pins the tool
    // available even when the harness runs in a shell whose environment carries a
    // vault-off override. Twin of `lme_endpoint_config` and `lmebEndpointConfig`.
    let command = moot_serve_command(moot_binary, Path::new(&*data_dir), shape == BenchRunShape::Ram, crate::scratch_posture::SCRATCH_SERVE_ENV, None)
        .map_err(|e| e.to_string())?;
    Ok(EndpointConfig {
        name: "mootx01-lmeb".to_string(),
        transport: Transport::Stdio { command },
        auth: None,
        verb_map: lmeb_verb_map(),
        role: EndpointRole::Both,
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Single-doc ingest
// ─────────────────────────────────────────────────────────────────────────────

/// Ingests one corpus document via `moot_file_memory`, returning `(uuid, latency_s)`.
///
/// The `encode_barrier` parameter controls inline encoding per the EncodeBarrier mode.
/// Impatient mode adds `impatient: true` (correct key — the old key "n" was silently
/// ignored by mootx01's `moot_file_memory` handler in AriaMcpKit ToolDispatch.swift).
fn ingest_doc(
    client: &mut MCPClient,
    verb_map: &VerbMap,
    doc_text: &str,
    encode_barrier: EncodeBarrier,
) -> Result<(String, f64), MCPError> {
    let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
    args.insert(
        verb_map.content_arg.clone(),
        JsonValue::String(doc_text.to_string()),
    );
    // Subject required at the moot file_memory boundary (PR-02): deterministic
    // first-sentence extraction (PR-07 deterministicSubject algorithm).
    args.insert(
        "subject".to_string(),
        JsonValue::String(crate::subject_generator::deterministic_subject(doc_text)),
    );
    // Constant args (location header).
    for (k, v) in &verb_map.constant_args {
        args.insert(k.clone(), JsonValue::String(v.clone()));
    }
    // Impatient mode: inline encoding per write. Correct key is "impatient" —
    // the old key "n" was silently ignored by the moot_file_memory handler.
    if encode_barrier == EncodeBarrier::Impatient {
        args.insert("impatient".to_string(), JsonValue::Bool(true));
    }

    let start = Instant::now();
    let result = client.call_tool(&verb_map.write, args, &verb_map.result_format)?;
    let elapsed = start.elapsed().as_secs_f64();

    let uuid = result.write_assigned_id.ok_or_else(|| MCPError {
        description: "moot_file_memory returned no UUID".to_string(),
    })?;
    Ok((uuid, elapsed))
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-query run
// ─────────────────────────────────────────────────────────────────────────────

/// Runs the LMEB harness for a single query: create scratch dir → launch
/// mootx01 → ingest candidate docs → probe → query → map UUIDs → teardown.
///
/// `cache_entry`: when `Some`, the runner checks for a cached estate first.
///   On hit: restores the snapshot and skips ingest + drain.
///   On miss: ingests normally and saves a snapshot after drain.
///   `None` disables caching for this query (--estate-cache off).
///
/// Returns `Err` only for unrecoverable setup failures (scratch dir, binary
/// launch). Guard failures are encoded as `LmebQueryResult.guard_healthy = false`.
///
/// Thread safety (C6): `sampler` is wrapped in `Mutex<LegGuardSampler>` so
/// multiple threads can share a single leg-level sampler safely. The lock is
/// held only for the `probe()` call and the `policy` read — both are cheap
/// because `OncePerLeg` (the default) only does real MCP work on the FIRST
/// call and returns the cached verdict immediately on all subsequent calls.
///
/// Twin of Swift `runOneLMEBQuery(idx:total:...)` in `LMEBRunner.swift`.
#[allow(clippy::too_many_arguments)]
fn run_one_lmeb_query(
    query: &LmebQuery,
    candidate_doc_ids: &[String],
    relevant_doc_ids: HashSet<String>,
    corpus: &LmebCorpus,
    moot_binary: &str,
    seed: u64,
    query_index: usize,
    encode_barrier: EncodeBarrier,
    cache_entry: Option<&Path>,
    scratch_posture: ScratchEstatePosture,
    seed_path_mode: crate::seed_export::SeedPathMode,
    // Leg-level guard sampler: shared across all query threads in a run.
    // Wrapped in Mutex so parallel threads can call probe() safely without
    // data races. Lock is released immediately after the call.
    sampler: &Mutex<LegGuardSampler>,
    // C4: leg-level timing sampler — captures the audit-derived timing
    // report on the leg's first freshly-settled estate (interior Mutex).
    timing_sampler: &crate::timing_capture::LegTimingSampler,
    // B2: the run's expected provenance — validated hard on artifact restore.
    run_provenance: &crate::artifact_manifest::ArtifactProvenance,
    // B7: measure-only mode — a cache miss is a hard error, never a build.
    require_artifact: bool,
    // C1: estate storage shape. Forwarded to lmeb_endpoint_config.
    shape: BenchRunShape,
    // Environment seam: optional retrieval-call override.
    retrieval_call: Option<&crate::retrieval_call_spec::RetrievalCallSpec>,
    // Payload-economics shape-variant arm; strips seam-result text_blocks.
    payload_arm: Option<crate::payload_arm::PayloadArm>,
) -> Result<LmebQueryResult, LaneError> {
    // ── Cache restore attempt (when cache mode is Reuse) ──────────────────────
    // Try to restore a previously-snapshotted estate for this query. On hit,
    // skip ingest and drain entirely. On miss, fall through to normal ingest.
    let cache_restore: Option<(PathBuf, Vec<LmebManifestEntry>)> = match cache_entry {
        Some(entry) => restore_estate_cache_entry(entry, run_provenance, || {
            lmeb_scratch_dir(seed, query_index, scratch_posture)
                .map_err(|e| e.description.clone())
        })
        // B2 provenance mismatch is a HARD FAIL — propagate; never silently
        // rebuild a unit whose artifact declares different inputs.
        .map_err(|e| MCPError { description: e })?,
        None => None,
    };

    let (scratch, mut uuid_to_doc_id, skip_ingest, cache_hit): (PathBuf, HashMap<String, String>, bool, Option<bool>) =
        if let Some((s, manifest)) = cache_restore {
            let map: HashMap<String, String> = manifest
                .into_iter()
                .map(|e| (e.uuid, e.doc_id))
                .collect();
            (s, map, true, Some(true))
        } else {
            let is_cache_miss = cache_entry.is_some();
            // B7: measure-only mode never builds — a miss is fatal.
            if is_cache_miss && require_artifact {
                return Err(LaneError::Unit(crate::estate_cache::artifact_required_error(
                    cache_entry.expect("miss implies Some"),
                )));
            }
            let s = lmeb_scratch_dir(seed, query_index, scratch_posture)?;
            (s, HashMap::new(), false, if is_cache_miss { Some(false) } else { None })
        };

    let verb_map = lmeb_verb_map();
    // A path/posture configuration failure is fatal for the whole lane (LaneError::Config);
    // all other errors from this point on are per-unit (LaneError::Unit via From<MCPError>).
    let endpoint = lmeb_endpoint_config(&scratch, moot_binary, scratch_posture, shape)
        .map_err(|e| LaneError::Config(format!("{e}")))?;
    // Belt-and-suspenders: verify --db points into /tmp before connecting.
    // Twin of Swift `assertScratchBackend(_:requirement:)` in LMEBRunner.
    crate::gauntlet_runner::assert_scratch_backend(
        &endpoint, &crate::gauntlet_runner::MOOT_SCRATCH_REQUIREMENT,
    );

    let mut client = MCPClient::new(endpoint);
    client.connect().map_err(|e| {
        let _ = crate::key_residue::retire_scratch_estate(&scratch, lmeb_guarded_teardown);
        LaneError::Unit(e.description)
    })?;

    // ── Ingest candidate docs (skip on cache hit) ─────────────────────────────
    let mut write_latencies: Vec<f64> = Vec::new();
    let mut docs_ingested: usize = if skip_ingest {
        // On cache hit, docs_ingested reflects the estate's actual content
        // (manifest was populated during the original ingest run).
        uuid_to_doc_id.len()
    } else {
        0
    };
    // Lane evidence for the report: None when the barrier did not run.
    let mut drain_lane_observed: Option<bool> = None;

    if !skip_ingest {
        match seed_path_mode {
            crate::seed_export::SeedPathMode::Batch => {
                // ── Batch path: emit seed file → moot_json_import (return_id_map) → drain → id-map ranked attribution ──
                // One vault-gated import call replaces N per-doc `moot_file_memory` calls.
                let seed_records = lmeb_seed_records(candidate_doc_ids, corpus, 0);
                let seed_data = crate::seed_export::emit_seed_json(
                    &format!("lmeb-{}", query.id),
                    &seed_records,
                    &[],
                    &[],
                );
                // Write seed to the per-query scratch dir — owner-only permissions
                // (set by write_seed_file) prevent world-readable exposure during
                // the import window. Sanitize query.id for filesystem safety.
                let seed_path_buf = crate::seed_export::write_seed_file(
                    &seed_data,
                    &scratch,
                    &format!("lmeb-seed-{}", query.id.replace('/', "_")),
                )?;

                let mut import_args: BTreeMap<String, JsonValue> = BTreeMap::new();
                import_args.insert(
                    "path".to_string(),
                    JsonValue::String(seed_path_buf.to_string_lossy().into_owned()),
                );
                // v2: `mode` arg removed from moot_json_import (v2 manages encode scheduling internally).
                // The importer names the drawer each candidate doc became.
                // Nothing else can: the candidate pool is scoped per-query
                // (10–168 docs), but across a full LMEB run this room can
                // exceed the 200-row listing cap, and a content search cannot
                // be made exact because ranking decides what comes back.
                import_args.insert("return_id_map".to_string(), JsonValue::Bool(true));

                let import_result = client
                    .call_tool(crate::aria_v2_surface::JSON_IMPORT, import_args, &verb_map.result_format)?;
                let batch_id_map = crate::seed_export::seed_id_map(
                    &import_result.text_blocks,
                    seed_records.len(),
                    &format!("lmeb {}", query.id),
                )?;
                // v2: drawer count is in structuredContent.data.drawers_written, not text.
                if import_result.drawers_written != Some(seed_records.len() as i64) {
                    return Err(LaneError::Unit(format!(
                        "[lmeb] batch import receipt mismatch for {}: \
                         expected {} drawers, got {}",
                        query.id,
                        seed_records.len(),
                        import_result.drawers_written
                            .map(|n| n.to_string())
                            .unwrap_or_else(|| "(no structured data)".to_string())
                    )));
                }
                docs_ingested = seed_records.len();
                let _ = std::fs::remove_file(&seed_path_buf);

                // Drain barrier before building the manifest.
                if encode_barrier == EncodeBarrier::Drain {
                    let outcome = wait_for_encode_drain(
                        &mut client,
                        &format!("lmeb {}", query.id),
                        300.0,
                    );
                    drain_lane_observed = Some(outcome.lane_observed);
                }

                // Full manifest from the importer's id map: EVERY candidate doc,
                // not only the qrel-relevant ones.
                //
                // Needle-only manifests were the defect: any retrieved doc the
                // manifest couldn't map disappeared from the ranked list, collapsing
                // rank gaps and overstating recall@k and nDCG. With a complete
                // manifest, an unmapped UUID lands as a NUL-prefixed placeholder
                // that keeps its rank slot instead of vanishing.
                for record in &seed_records {
                    let uuid = batch_id_map.get(&record.id).ok_or_else(|| MCPError {
                        description: format!(
                            "lmeb {}: the import id map has no drawer for record \"{}\" \
                             — refusing to score with an incomplete manifest",
                            query.id, record.id
                        ),
                    })?;
                    // record.id IS the doc_id (lmeb_seed_records sets id = doc_id).
                    uuid_to_doc_id.insert(uuid.clone(), record.id.clone());
                }
            }
            crate::seed_export::SeedPathMode::Live => {
                // ── Live path: verbatim per-doc moot_file_memory loop ─────────────────────
                // Retained for periodic equivalence re-proving against the batch path.
                'ingest: for doc_id in candidate_doc_ids {
                    let doc = match corpus.docs_by_id.get(doc_id) {
                        Some(d) => d,
                        None => {
                            // Candidate doc absent from loaded corpus (cross-evidence-type ID
                            // or filtered load). Skip gracefully — treated as unretrieved.
                            continue;
                        }
                    };
                    match ingest_doc(&mut client, &verb_map, &doc.text, encode_barrier) {
                        Ok((uuid, latency)) => {
                            uuid_to_doc_id.insert(uuid, doc_id.clone());
                            write_latencies.push(latency);
                            docs_ingested += 1;
                        }
                        Err(e) => {
                            eprintln!(
                                "  [lmeb] ingest error for {} doc {}: {}",
                                query.id, doc_id, e.description
                            );
                            break 'ingest;
                        }
                    }
                }
                // Drain barrier for the live path.
                if encode_barrier == EncodeBarrier::Drain {
                    let outcome = wait_for_encode_drain(
                        &mut client,
                        &format!("lmeb {}", query.id),
                        300.0,
                    );
                    drain_lane_observed = Some(outcome.lane_observed);
                }
            }
        }
    }

    let write_mean_latency = if write_latencies.is_empty() {
        0.0
    } else {
        write_latencies.iter().sum::<f64>() / write_latencies.len() as f64
    };

    // ── Snapshot to cache (on cache miss, after drain) ────────────────────────
    // ── Settle, then snapshot (B4, benchmark reset 2026-08-13) ────────────────
    // The artifact is BY DEFINITION a settled estate: import → drain → dream →
    // basis retrain → snapshot (BENCHMARK_PROTOCOL.md §4). Supersedes the
    // "protocol-neutral cache entries" ruling (H7's defect: dream re-ran on
    // every restore). Protocol v2 is satisfied at BUILD time; a restored
    // artifact is settled by construction and is NOT re-dreamt. Swift twin:
    // LMEBRunner.swift settle block.
    if !skip_ingest {
        let mut dream_args: BTreeMap<String, JsonValue> = BTreeMap::new();
        dream_args.insert("associates".to_string(), JsonValue::String("all".to_string()));
        client.call_tool(crate::aria_v2_surface::DREAM, dream_args, &crate::config::ResultFormat::MootV2)?;
        // Basis retrain (CYCLE tier 3), then drain the re-encode.
        client.call_tool(
            crate::aria_v2_surface::REINDEX,
            BTreeMap::new(),
            &crate::config::ResultFormat::MootV2,
        )?;
        let _ = wait_for_encode_drain(
            &mut client,
            &format!("lmeb settle-for-snapshot q={}", query.id),
            300.0,
        );

        // C4: capture the audit-derived timing report (INGEST samples + the
        // four CYCLE tiers) once per leg, while this settled estate is still
        // alive. Sampled like the C5 guard; the report labels the sampling.
        // Swift twin: LMEBRunner.swift settle block.
        let _ = timing_sampler
            .capture(|| crate::timing_capture::fetch_timing_report(&mut client));

        // Snapshot: the estate is SETTLED — future runs restore a
        // measurement-ready artifact. Only written on cache miss.
        //
        // Settle-gate invariant (B4/BH-02 findings #10b): the two settle calls
        // above use `?`, so a dream or reindex failure returns from this function
        // before the save is reached. An unsettled estate can never be written to
        // the artifact cache from this lane. This is why there is no boolean
        // fitness flag here: the error already propagates, making such a flag
        // permanently true — decorative safety that misleads the next reader into
        // thinking the gate is discretionary. Converting either call from `?` to a
        // logged-and-continue form would reopen exactly the hole that
        // membench_runner.rs's explicit fitness gate exists to close; do not do that.
        if let Some(entry) = cache_entry {
            let manifest_vec: Vec<LmebManifestEntry> = uuid_to_doc_id
                .iter()
                .map(|(uuid, doc_id)| LmebManifestEntry {
                    uuid: uuid.clone(),
                    doc_id: doc_id.clone(),
                })
                .collect();
            save_estate_cache_entry(&scratch, &manifest_vec, &run_provenance, entry);
        }
    }

    // ── Probe for degeneracy guard ────────────────────────────────────────────
    // Delegated to the leg sampler: probes on the first query only (OncePerLeg
    // default); caches the verdict for all subsequent queries at zero MCP cost.
    // The Mutex lock is held only for the duration of probe() — cheap because
    // OncePerLeg returns the cached verdict immediately after the first call.
    let (guard_healthy, guard_diagnostic, _was_probed) = sampler
        .lock()
        .unwrap()
        .probe(|| probe_mcp_client(&mut client, &verb_map));

    // ── Query via moot_memory_search ──────────────────────────────────────────
    let query_start = Instant::now();
    let (returned_uuids, payload_text): (Vec<String>, Option<String>) = if guard_healthy {
        let (door_tool, door_args) = crate::retrieval_call_spec::seam_call(
            &verb_map, retrieval_call, &query.text);
        match client.call_tool(&door_tool, door_args, &verb_map.result_format)
            .map(|r| crate::payload_arm::strip_tool_result(payload_arm, r)) {
            Ok(result) => {
                let payload = if result.text_blocks.is_empty() {
                    None
                } else {
                    Some(result.text_blocks.join("\n"))
                };
                (result.ordered_ids, payload)
            },
            Err(e) => {
                eprintln!(
                    "  [lmeb] query error for {}: {}",
                    query.id, e.description
                );
                (vec![], None)
            }
        }
    } else {
        (vec![], None)
    };
    let query_latency_seconds = query_start.elapsed().as_secs_f64();

    // ── Map UUID → docID ──────────────────────────────────────────────────────
    // Unmapped UUIDs keep their rank slot as NUL-prefixed placeholders — dropping
    // them is wrong in the generous direction (collapses rank gaps and overstates
    // recall@k and nDCG). With a complete manifest, no placeholder is ever emitted.
    let (retrieved_doc_ids, _) =
        crate::lmeb_scorer::lmeb_ranked_docs_audited(&returned_uuids, &uuid_to_doc_id);

    // ── Teardown ──────────────────────────────────────────────────────────────
    client.disconnect();
    // Retirement = teardown + zero-residual-key verification.
    if let Err(e) = crate::key_residue::retire_scratch_estate(&scratch, lmeb_guarded_teardown) {
        eprintln!(
            "  [lmeb] teardown warning for {}: {}",
            query.id, e.description
        );
    }

    Ok(LmebQueryResult {
        query_id: query.id.clone(),
        query_latency_seconds,
        retrieved_doc_ids,
        relevant_doc_ids,
        guard_healthy,
        guard_diagnostic,
        // Read policy through the Mutex; cheap (no MCP work).
        guard_sampling_mode: sampler.lock().unwrap().policy,
        docs_ingested,
        write_mean_latency_seconds: write_mean_latency,
        payload_text,
        cache_hit,
        drain_lane_observed,
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Top-level query runner
// ─────────────────────────────────────────────────────────────────────────────

/// Runs the LMEB harness over a set of queries.
///
/// Applies seeded shuffle → offset → limit slice, then dispatches queries
/// with bounded parallelism controlled by `config.parallel_units`.
///
/// Parallelism (C6): when `parallel_units > 1`, queries run as independent
/// threads (up to `parallel_units` concurrently) via `std::thread::scope`.
/// Each thread owns its own scratch dir, MCPClient, and mootx01 process.
/// Results are written to index-keyed slots and sorted by original index
/// after all threads complete, so report ordering is byte-deterministic
/// regardless of thread completion order. Per-unit stderr lines carry
/// the query id; interleaving is acceptable.
///
/// Twin of Swift `runLMEBQueries(queries:corpus:config:)`.
pub fn run_lmeb_queries(
    queries: &[LmebQuery],
    corpus: &LmebCorpus,
    config: &LmebRunConfig,
) -> Result<(Vec<LmebQueryResult>, Option<String>), String> {
    // ── Shuffle + slice ───────────────────────────────────────────────────────
    let mut indices: Vec<usize> = (0..queries.len()).collect();
    // --ids pinned subset (before shuffle: same file → same units always).
    if let Some(ids) = &config.unit_ids {
        indices.retain(|&i| ids.contains(&queries[i].id));
    }
    let mut rng = SplitMix64::new(config.seed);
    rng.shuffle(&mut indices);

    // Apply offset then limit.
    let sliced: Vec<usize> = indices
        .into_iter()
        .skip(config.offset)
        .take(config.limit.unwrap_or(usize::MAX))
        .collect();

    let total = sliced.len();

    // ── Estate cache setup (once per run) ────────────────────────────────────
    // B2: one provenance per run — every unit of a leg shares the declared
    // dependency set; only the unit id varies (it lives in the entry path).
    let run_provenance = Arc::new(crate::artifact_manifest::make_artifact_provenance(
        "lmeb",
        "",
        config.seed,
        config.encode_barrier.as_str(),
        config.scratch_posture.as_str(),
        config.seed_path.as_str(),
        &config.corpus_digest,
    ));
    // Drift gate: refuse before any scratch estate is written when the gate's
    // evidence does not cover the binary this lane resolved.
    let resolved_cache_dir = Arc::new(
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
        }),
    );

    // Write JSONL header once per run, before the parallel dispatch.
    // LMEB has no variant or dense arm; those fields are null/0 in the header.
    if let Some(dump_path) = &config.dump_judge_inputs_path {
        use std::io::Write;
        let header = serde_json::json!({
            "type": "header",
            "benchmark": "lmeb",
            "variant": null,
            "seed": config.seed,
            "run_label": config.label.as_deref().unwrap_or(""),
            "arm": "exact",
            "judge_hydration_depth": 0,
        });
        if let Ok(mut f) = std::fs::File::create(dump_path) {
            let _ = writeln!(f, "{header}");
        }
    }

    // One sampler for the entire leg: probes on the first query; caches the
    // verdict for all subsequent queries. Wrapped in Arc<Mutex> so all parallel
    // threads share a single leg-level sampler safely. Lock is held only for
    // the probe() call and the policy read — both are cheap (OncePerLeg
    // returns the cached verdict immediately after the first call).
    let guard_sampler = Arc::new(Mutex::new(LegGuardSampler::new(config.guard_sampling_policy)));
    // C4: one timing sampler per leg — captures the audit-derived timing
    // report on the first freshly-settled estate (interior Mutex, so no
    // outer Mutex needed). Swift twin: LegTimingSampler actor.
    let timing_sampler = Arc::new(crate::timing_capture::LegTimingSampler::new());

    // ── Parallel dispatch (C6) ────────────────────────────────────────────────
    // Work queue: (progress_index, query_index) pairs popped by worker threads.
    // Results written to index-keyed slots; sorted by progress_index after join.
    //
    // Error semantics (cross-port asymmetry, intentional): a per-query error
    // here writes a stub result (guard_healthy=false) and CONTINUES, so a
    // parity run localizes the diff to the failing item. The Swift twin
    // aborts the whole run instead (throwing task group) — it is the
    // measurement instrument and refuses to produce a report with holes.
    let work_queue: Arc<Mutex<VecDeque<(usize, usize)>>> = Arc::new(Mutex::new(
        sliced.iter().enumerate().map(|(pi, &qi)| (pi, qi)).collect(),
    ));
    // Result slots: one per query, initialized to None. Each worker fills its
    // slot; the main thread collects after all workers finish.
    let result_slots: Arc<Mutex<Vec<Option<LmebQueryResult>>>> =
        Arc::new(Mutex::new((0..total).map(|_| None).collect()));
    // Dump file: concurrent appends serialized via Mutex<File>.
    let dump_file: Arc<Mutex<Option<std::fs::File>>> = Arc::new(Mutex::new(
        config.dump_judge_inputs_path.as_ref().and_then(|p| {
            std::fs::OpenOptions::new().append(true).open(p).ok()
        }),
    ));

    // Clamp workers to the work-item count (matches LME/LoCoMo): with a small
    // --limit, spare threads would spawn only to find an empty queue and exit.
    let effective_workers = config.parallel_units.min(sliced.len().max(1));
    // Error channel: if any thread encounters a fatal endpoint config error,
    // it stores the message here and breaks without emitting a result.
    // After the scope we propagate as Err so main() exits 1 not 0.
    let config_err: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    std::thread::scope(|s| {
        for _ in 0..effective_workers {
            let work_queue = Arc::clone(&work_queue);
            let result_slots = Arc::clone(&result_slots);
            let guard_sampler = Arc::clone(&guard_sampler);
            let timing_sampler = Arc::clone(&timing_sampler);
            let run_provenance = Arc::clone(&run_provenance);
            let resolved_cache_dir = Arc::clone(&resolved_cache_dir);
            let dump_file = Arc::clone(&dump_file);
            let config_err = Arc::clone(&config_err);

            s.spawn(move || {
                loop {
                    // Pop the next (progress_index, query_index) from the shared queue.
                    let (progress_index, query_index) = match work_queue.lock().unwrap().pop_front() {
                        Some(item) => item,
                        None => break, // Queue exhausted — this worker is done.
                    };

                    let query = &queries[query_index];
                    let candidate_doc_ids = corpus.candidate_docs(&query.id);
                    let relevant_doc_ids: HashSet<String> =
                        corpus.relevant_docs(&query.id).iter().cloned().collect();

                    eprintln!(
                        "[lmeb] {}/{}: {} ({} candidates, {} relevant)",
                        progress_index + 1,
                        total,
                        query.id,
                        candidate_doc_ids.len(),
                        relevant_doc_ids.len()
                    );

                    // Compute cache entry path for this query (only when cache mode is Reuse).
                    let cache_entry_opt: Option<PathBuf> = if config.estate_cache != EstateCacheMode::Off {
                        Some(estate_cache_entry_path(
                            &resolved_cache_dir,
                            "lmeb",
                            "",
                            config.seed,
                            config.encode_barrier,
                            config.scratch_posture,
                            config.seed_path,
                            &query.id,
                        ))
                    } else {
                        None
                    };

                    let query_result = match run_one_lmeb_query(
                        query,
                        candidate_doc_ids,
                        relevant_doc_ids.clone(),
                        corpus,
                        &config.moot_binary,
                        config.seed,
                        query_index,
                        config.encode_barrier,
                        cache_entry_opt.as_deref(),
                        config.scratch_posture,
                        config.seed_path,
                        &guard_sampler,
                        &timing_sampler,
                        &run_provenance,
                        config.estate_cache == EstateCacheMode::Require,
                        config.shape,
                        config.retrieval_call.as_ref(),
                        config.payload_arm,
                    ) {
                        Ok(result) => {
                            let guard_str = if result.guard_healthy { "healthy" } else { "GUARD_FAIL" };
                            eprintln!(
                                "  [lmeb] {}/{} guard={guard_str} docs_ingested={} retrieved={} query_ms={:.0}",
                                progress_index + 1,
                                total,
                                result.docs_ingested,
                                result.retrieved_doc_ids.len(),
                                result.query_latency_seconds * 1000.0,
                            );
                            // Append query line to the pre-judge JSONL dump.
                            // Concurrent appends are serialized via Mutex<File>.
                            if let Ok(mut guard) = dump_file.lock() {
                                if let Some(ref mut f) = *guard {
                                    use std::io::Write;
                                    let mut rel_sorted: Vec<&String> = result.relevant_doc_ids.iter().collect();
                                    rel_sorted.sort();
                                    let gold_answer = rel_sorted
                                        .iter()
                                        .map(|s| s.as_str())
                                        .collect::<Vec<_>>()
                                        .join(",");
                                    let exact_tokens = result.payload_text.as_deref()
                                        .map(crate::longmemeval_token_efficiency::lme_estimate_tokens);
                                    let line = serde_json::json!({
                                        "type": "question",
                                        "question_id": &result.query_id,
                                        "question": &query.text,
                                        "gold_answer": gold_answer,
                                        "exact_payload": &result.payload_text,
                                        "exact_payload_tokens": exact_tokens,
                                        "dense_payload": null,
                                        "dense_payload_tokens": null,
                                    });
                                    let _ = writeln!(f, "{line}");
                                }
                            }
                            result
                        }
                        Err(e) => {
                            // Config errors (e.g. whitespace in path) abort the lane — propagate
                            // via the channel and stop this thread without filling a result slot.
                            // Unit errors produce guard-excluded stubs and continue.
                            match e {
                                LaneError::Config(msg) => {
                                    *config_err.lock().unwrap() = Some(msg);
                                    break;
                                }
                                LaneError::Unit(desc) => {
                                    eprintln!("  [lmeb] {}/{} ERROR (skipping): {}", progress_index + 1, total, desc);
                                    // Emit a guard-excluded result so the query shows in corpus_stats.
                                    LmebQueryResult {
                                        query_id: query.id.clone(),
                                        query_latency_seconds: 0.0,
                                        retrieved_doc_ids: vec![],
                                        relevant_doc_ids: corpus.relevant_docs(&query.id).iter().cloned().collect(),
                                        guard_healthy: false,
                                        guard_diagnostic: Some(desc),
                                        guard_sampling_mode: config.guard_sampling_policy,
                                        docs_ingested: 0,
                                        write_mean_latency_seconds: 0.0,
                                        payload_text: None,
                                        cache_hit: None,
                                        drain_lane_observed: None,
                                    }
                                }
                            }
                        }
                    };

                    // Write to the index-keyed result slot so results can be sorted
                    // by progress_index (original query order) after all threads finish.
                    result_slots.lock().unwrap()[progress_index] = Some(query_result);
                }
            });
        }
    });

    // Propagate any endpoint-config refusal. The thread stored the message and
    // broke without filling its result slot — check BEFORE collecting slots
    // (a None slot would panic the expect below).
    if let Some(err) = config_err.lock().unwrap().take() {
        return Err(err);
    }

    // Collect results in progress_index order: restores byte-deterministic ordering
    // regardless of which threads completed first. The guard binding keeps the
    // MutexGuard alive past the iterator (E0597: a tail-position temporary
    // borrowing a local cannot outlive the function otherwise).
    let mut guard = result_slots.lock().unwrap();
    let results: Vec<LmebQueryResult> = guard
        .iter_mut()
        .map(|slot| slot.take().expect("all slots filled by worker threads"))
        .collect();
    drop(guard);
    // C4: the leg's sampled timing report rides back beside the results —
    // None when every unit restored from cache or the capture failed.
    Ok((results, timing_sampler.text()))
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests — LMEB seed builder
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod lmeb_seed_builder_tests {
    use super::lmeb_seed_records;
    use crate::lmeb_corpus::{LmebCorpus, LmebDoc};

    fn make_corpus(docs: &[(&str, &str)]) -> LmebCorpus {
        let docs_by_id = docs
            .iter()
            .map(|(id, text)| {
                (id.to_string(), LmebDoc {
                    id: id.to_string(),
                    text: text.to_string(),
                    title: id.to_string(),
                })
            })
            .collect();
        LmebCorpus {
            docs_by_id,
            queries_by_id: Default::default(),
            candidates_by_scene_id: Default::default(),
            relevant_docs_by_query_id: Default::default(),
        }
    }

    #[test]
    fn order_preserved_and_count_matches() {
        let corpus = make_corpus(&[("doc-A", "Content A."), ("doc-B", "Content B."), ("doc-C", "Content C.")]);
        let ids: Vec<String> = ["doc-A", "doc-B", "doc-C"].iter().map(|s| s.to_string()).collect();
        let records = lmeb_seed_records(&ids, &corpus, 0);
        assert_eq!(records.len(), 3);
        assert_eq!(records[0].id, "doc-A");
        assert_eq!(records[1].id, "doc-B");
        assert_eq!(records[2].id, "doc-C");
    }

    #[test]
    fn content_mirrors_doc_text() {
        let corpus = make_corpus(&[("doc-A", "Content A."), ("doc-B", "Content B.")]);
        let ids: Vec<String> = ["doc-A", "doc-B"].iter().map(|s| s.to_string()).collect();
        let records = lmeb_seed_records(&ids, &corpus, 0);
        assert_eq!(records[0].content, "Content A.");
        assert_eq!(records[1].content, "Content B.");
    }

    #[test]
    fn room_is_lmeb_constant() {
        let corpus = make_corpus(&[("doc-A", "Text.")]);
        let ids = vec!["doc-A".to_string()];
        let records = lmeb_seed_records(&ids, &corpus, 0);
        assert_eq!(records[0].room, "benchmarks/lmeb");
    }

    #[test]
    fn ids_are_unique_and_equal_doc_ids() {
        let corpus = make_corpus(&[("doc-A", "A"), ("doc-B", "B"), ("doc-C", "C")]);
        let ids: Vec<String> = ["doc-A", "doc-B", "doc-C"].iter().map(|s| s.to_string()).collect();
        let records = lmeb_seed_records(&ids, &corpus, 0);
        let unique: std::collections::HashSet<&str> = records.iter().map(|r| r.id.as_str()).collect();
        assert_eq!(unique.len(), records.len());
        // Record IDs are the doc IDs.
        for (r, doc_id) in records.iter().zip(ids.iter()) {
            assert_eq!(&r.id, doc_id);
        }
    }

    #[test]
    fn event_times_unique_and_start_at_base() {
        let corpus = make_corpus(&[("doc-A", "A"), ("doc-B", "B"), ("doc-C", "C")]);
        let ids: Vec<String> = ["doc-A", "doc-B", "doc-C"].iter().map(|s| s.to_string()).collect();
        let records = lmeb_seed_records(&ids, &corpus, 0);
        let times: Vec<&str> = records.iter().map(|r| r.event_time.as_str()).collect();
        let unique: std::collections::HashSet<&str> = times.iter().copied().collect();
        assert_eq!(unique.len(), times.len(), "event times must be unique");
        assert_eq!(times[0], "2026-01-01T00:00:00Z");
    }

    #[test]
    fn wing_is_none() {
        let corpus = make_corpus(&[("doc-A", "A")]);
        let records = lmeb_seed_records(&["doc-A".to_string()], &corpus, 0);
        assert!(records[0].wing.is_none());
    }

    #[test]
    fn missing_doc_silently_skipped() {
        let corpus = make_corpus(&[("doc-A", "A"), ("doc-B", "B")]);
        let ids: Vec<String> = ["doc-A", "doc-MISSING", "doc-B"].iter().map(|s| s.to_string()).collect();
        let records = lmeb_seed_records(&ids, &corpus, 0);
        assert_eq!(records.len(), 2);
        assert!(!records.iter().any(|r| r.id == "doc-MISSING"));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Consolidated runner — Shape 3 (C10-LMEB)
// ─────────────────────────────────────────────────────────────────────────────

/// RAII guard that retires a consolidated-mode scene's scratch estate
/// (teardown + zero-residual-key verification, via [`crate::key_residue::retire_scratch_estate`])
/// no matter how [`run_one_lmeb_scene`] exits. See #23 in that function's
/// doc comment for why this exists: `run_one_lmeb_scene` has multiple `?`
/// exit points between estate creation and estate retirement, and before
/// this guard only two of them tore the estate down.
///
/// Declaration order matters: this guard must be bound BEFORE the
/// `MCPClient` local in `run_one_lmeb_scene` so it drops AFTER the client.
/// Rust drops locals in reverse declaration order, and `MCPClient`'s own
/// `Drop` impl disconnects the launched `mootx01 serve` process — teardown
/// must run after that disconnect, not before, or the scratch dir's SQLite
/// files can still be held open by the (still-running) child process.
struct SceneScratchGuard {
    scratch: PathBuf,
}

impl Drop for SceneScratchGuard {
    fn drop(&mut self) {
        if let Err(e) = crate::key_residue::retire_scratch_estate(&self.scratch, lmeb_guarded_teardown) {
            eprintln!(
                "[lmeb-s3] teardown warning for scratch {}: {}",
                self.scratch.display(),
                e.description
            );
        }
    }
}

/// Runs the LMEB harness for one scene group in consolidated mode.
///
/// Creates a single scratch estate, ingests the union of ALL evidence types'
/// candidate docs for the scene (batch path only — consolidated mode does not
/// support the live path), settles the estate with the B4 protocol, then
/// issues EVERY query in `scene_queries` against the shared settled estate.
///
/// `scene_index` is the 0-based position of this scene in the sorted scene
/// list; it is used to create a unique scratch dir name and for progress
/// logging.
///
/// Returns one `LmebQueryResult` per query in `scene_queries` (same order as
/// the input slice).
///
/// Error semantics: returns `Err` for unrecoverable setup failures (scratch
/// dir creation, MCP launch, import receipt mismatch). The caller translates
/// these into guard-excluded stub results so the overall run completes rather
/// than aborting — the same strategy the per-query runner uses for scene-level
/// errors.
///
/// Twin of Swift `runOneLMEBScene(sceneID:sceneQueries:corpus:config:...)` in
/// `LMEBRunner.swift`.
///
/// #23 fix (2026-08-15): `run_one_lmeb_scene` has several `?`-propagated exit
/// points between "scratch dir created" and "results assembled" (seed file
/// write, `moot_json_import`, the import id-map lookup, the per-record
/// manifest build, `moot_dream`, `moot_reindex`) that used to leave the
/// scene's scratch estate on disk — only the connect failure and the
/// import-receipt-mismatch paths called `retire_scratch_estate` explicitly,
/// and every other early return skipped it. [`SceneScratchGuard`] below
/// replaces the scattered explicit calls with one `Drop`-based cleanup that
/// fires on every exit — success, an explicit `return Err(...)`, or any `?`
/// — matching the discipline `ScratchPosture.swift`/`KeyResidue.swift`
/// already enforce on the Swift leg, and the same shape LoCoMo's teardown
/// already leans on structurally (declaration-order Drop). A future error
/// path added to this function inherits the cleanup for free instead of
/// needing its own explicit teardown call.
#[allow(clippy::too_many_arguments)]
fn run_one_lmeb_scene(
    scene_id: &str,
    scene_queries: &[LmebQuery],
    corpus: &LmebCorpus,
    config: &LmebRunConfig,
    // Leg-level guard sampler: shared across all scenes in the run.
    // Interior Mutex means &self suffices; no outer Mutex needed here,
    // but we accept a &Mutex to match the per-query interface shape.
    sampler: &Mutex<LegGuardSampler>,
    // C4: leg-level timing sampler — captures once for the leg's first
    // freshly-settled estate (interior Mutex, so &self).
    timing_sampler: &crate::timing_capture::LegTimingSampler,
    scene_index: usize,
    total_scenes: usize,
) -> Result<Vec<LmebQueryResult>, LaneError> {
    // Collect the UNION of all candidate doc IDs across all queries in this scene.
    // Iteration order: scene_queries is id-sorted (guaranteed by the grouping step).
    // Set deduplication with first-seen insertion order — mirrors Swift's
    // `seenDocIDs.insert(docID).inserted` pattern.
    let mut all_candidate_doc_ids: Vec<String> = Vec::new();
    let mut seen_doc_ids: HashSet<String> = HashSet::new();
    for query in scene_queries {
        for doc_id in corpus.candidate_docs(&query.id) {
            if seen_doc_ids.insert(doc_id.clone()) {
                all_candidate_doc_ids.push(doc_id.clone());
            }
        }
    }

    // Scene-level scratch dir. `scene_index` provides uniqueness within the run,
    // mirroring `query_index` in the per-query path. The /tmp/lmeb-bench- prefix
    // is required by `lmeb_guarded_teardown`.
    let scratch = lmeb_scratch_dir(config.seed, scene_index, config.scratch_posture)?;
    // Bound immediately after the scratch dir exists and BEFORE `client` below —
    // see SceneScratchGuard's doc comment for why the ordering is load-bearing.
    // From here on, every exit from this function (success or any `?`) retires
    // the scratch estate exactly once.
    let _scratch_guard = SceneScratchGuard { scratch: scratch.clone() };
    let verb_map = lmeb_verb_map();
    // A path/posture configuration failure is fatal for the whole lane (LaneError::Config).
    let endpoint = lmeb_endpoint_config(&scratch, &config.moot_binary, config.scratch_posture, config.shape)
        .map_err(|e| LaneError::Config(format!("{e}")))?;
    // Belt-and-suspenders: verify --db points into /tmp before connecting.
    // Twin of Swift `assertScratchBackend(_:requirement:)` in LMEBRunner.
    crate::gauntlet_runner::assert_scratch_backend(
        &endpoint, &crate::gauntlet_runner::MOOT_SCRATCH_REQUIREMENT,
    );

    let mut client = MCPClient::new(endpoint);
    client.connect()?;

    // Build seed records for the scene's full candidate pool (union of all
    // evidence types' candidates for this scene) and batch-ingest in one call.
    let seed_records = lmeb_seed_records(&all_candidate_doc_ids, corpus, 0);
    let seed_data = crate::seed_export::emit_seed_json(
        &format!("lmeb-scene-{scene_id}"),
        &seed_records,
        &[],
        &[],
    );
    // Sanitize scene_id for filesystem safety (forward-slashes in scene IDs
    // are not expected but guarded defensively).
    let seed_path_buf = crate::seed_export::write_seed_file(
        &seed_data,
        &scratch,
        &format!("lmeb-scene-{}", scene_id.replace('/', "_")),
    )?;

    let mut import_args: BTreeMap<String, JsonValue> = BTreeMap::new();
    import_args.insert(
        "path".to_string(),
        JsonValue::String(seed_path_buf.to_string_lossy().into_owned()),
    );
    // v2: `mode` arg removed from moot_json_import (v2 manages encode scheduling internally).
    // Full manifest: UUID→docID covering every ingested doc, not only qrel-relevant
    // ones. Matches the per-query batch path contract (C13 fix — needle-only manifests
    // collapse rank gaps and overstate recall).
    import_args.insert("return_id_map".to_string(), JsonValue::Bool(true));

    let import_result = client.call_tool(crate::aria_v2_surface::JSON_IMPORT, import_args, &verb_map.result_format)?;
    let batch_id_map = crate::seed_export::seed_id_map(
        &import_result.text_blocks,
        seed_records.len(),
        &format!("lmeb-s3 scene {scene_id}"),
    )?;
    // v2: drawer count is in structuredContent.data.drawers_written, not text.
    // No explicit disconnect/teardown here — `client` and `_scratch_guard`
    // both drop when this `return` unwinds the function, in that order
    // (declaration order), which is the same disconnect-then-retire
    // sequence the old explicit calls performed.
    if import_result.drawers_written != Some(seed_records.len() as i64) {
        return Err(LaneError::Unit(format!(
            "[lmeb-s3] scene {scene_id}: moot_json_import receipt does not confirm \
             {} drawers — got: {}",
            seed_records.len(),
            import_result.drawers_written
                .map(|n| n.to_string())
                .unwrap_or_else(|| "(no structured data)".to_string())
        )));
    }
    // Clean up the seed file now that the import is complete.
    let _ = std::fs::remove_file(&seed_path_buf);

    // Build the full-scene UUID→docID manifest: every candidate doc → its UUID.
    // No needle-only manifest: the full-scene manifest covers ALL docs ingested,
    // so no UUID can arrive unmapped. Twin of the per-query batch path.
    let mut uuid_to_doc_id: HashMap<String, String> = HashMap::new();
    for record in &seed_records {
        let uuid = batch_id_map.get(&record.id).ok_or_else(|| MCPError {
            description: format!(
                "lmeb-s3 scene {scene_id}: import id map has no drawer for record \"{}\" \
                 — refusing to score with an incomplete manifest",
                record.id
            ),
        })?;
        // record.id IS the doc_id (lmeb_seed_records sets id = doc_id).
        uuid_to_doc_id.insert(uuid.clone(), record.id.clone());
    }

    // Encode drain before settle (matches per-query drain placement).
    let mut drain_lane_observed: Option<bool> = None;
    if config.encode_barrier == EncodeBarrier::Drain {
        let outcome = wait_for_encode_drain(
            &mut client,
            &format!("lmeb-s3 scene={scene_id}"),
            300.0,
        );
        drain_lane_observed = Some(outcome.lane_observed);
    }

    // B4 settle protocol: dream → reindex → drain. The settled estate is the
    // defined Shape 3 measurement artifact. Twin of the per-query settle block.
    let mut dream_args: BTreeMap<String, JsonValue> = BTreeMap::new();
    dream_args.insert("associates".to_string(), JsonValue::String("all".to_string()));
    client.call_tool(crate::aria_v2_surface::DREAM, dream_args, &crate::config::ResultFormat::MootV2)?;
    client.call_tool(
        crate::aria_v2_surface::REINDEX,
        BTreeMap::new(),
        &crate::config::ResultFormat::MootV2,
    )?;
    let _ = wait_for_encode_drain(
        &mut client,
        &format!("lmeb-s3 settle scene={scene_id}"),
        300.0,
    );

    // C4: capture the audit-derived timing report once per leg (the first
    // freshly-settled estate). LegTimingSampler caches after the first capture.
    let _ = timing_sampler.capture(|| crate::timing_capture::fetch_timing_report(&mut client));

    // DegeneracyGuard probe: once per leg (OncePerLeg default). Shared sampler
    // records the verdict; all subsequent calls return the cached result at
    // near-zero cost. Lock is held only for the probe() call.
    let (guard_healthy, guard_diagnostic, _was_probed) = sampler
        .lock()
        .unwrap()
        .probe(|| probe_mcp_client(&mut client, &verb_map));

    // Issue every query in the scene against the shared settled estate.
    let total_docs = uuid_to_doc_id.len();
    let guard_sampling_mode = sampler.lock().unwrap().policy;
    let mut results: Vec<LmebQueryResult> = Vec::with_capacity(scene_queries.len());
    for query in scene_queries {
        let relevant_doc_ids: HashSet<String> =
            corpus.relevant_docs(&query.id).iter().cloned().collect();

        let (returned_uuids, payload_text): (Vec<String>, Option<String>) = if guard_healthy {
            let (door_tool, door_args) = crate::retrieval_call_spec::seam_call(
                &verb_map, config.retrieval_call.as_ref(), &query.text);
            let query_start = Instant::now();
            match client.call_tool(&door_tool, door_args, &verb_map.result_format)
                .map(|r| crate::payload_arm::strip_tool_result(config.payload_arm, r)) {
                Ok(result) => {
                    let _elapsed = query_start.elapsed().as_secs_f64();
                    let payload = if result.text_blocks.is_empty() {
                        None
                    } else {
                        Some(result.text_blocks.join("\n"))
                    };
                    (result.ordered_ids, payload)
                }
                Err(e) => {
                    eprintln!("[lmeb-s3] query error for {}: {}", query.id, e.description);
                    (vec![], None)
                }
            }
        } else {
            (vec![], None)
        };

        // Map returned UUIDs → doc IDs. Full-scene manifest ensures no placeholder
        // is emitted for docs belonging to this scene.
        let (retrieved_doc_ids, _) =
            crate::lmeb_scorer::lmeb_ranked_docs_audited(&returned_uuids, &uuid_to_doc_id);

        eprintln!(
            "[lmeb-s3] scene {}/{} q={}: {} docs in estate, guard={}, retrieved {} docs",
            scene_index + 1,
            total_scenes,
            query.id,
            total_docs,
            if guard_healthy { "healthy" } else { "EXCLUDED" },
            retrieved_doc_ids.len()
        );

        results.push(LmebQueryResult {
            query_id: query.id.clone(),
            // Consolidated mode issues queries sequentially but does not
            // record per-query latency — set to 0.0 (no Instant wrapping each
            // call in the loop; latency measurement is not a Shape 3 deliverable).
            query_latency_seconds: 0.0,
            retrieved_doc_ids,
            relevant_doc_ids,
            guard_healthy,
            guard_diagnostic: guard_diagnostic.clone(),
            guard_sampling_mode,
            // docs_ingested = total docs in the scene estate (not per-query candidate count).
            docs_ingested: total_docs,
            // write_mean_latency_seconds = 0.0: batch seed path; no per-doc timing.
            write_mean_latency_seconds: 0.0,
            payload_text,
            // cache_hit = None: consolidated mode does not use the estate cache.
            cache_hit: None,
            // drain_lane_observed: scene-level drain outcome, shared by all queries.
            drain_lane_observed,
        });
    }

    // Teardown happens via `client`'s and `_scratch_guard`'s `Drop` impls as
    // this function returns (disconnect, then retire) — see SceneScratchGuard.
    Ok(results)
}

/// Runs the LMEB harness over a set of queries in consolidated (Shape 3) mode.
///
/// Applies the same shuffle + offset + limit slice as `run_lmeb_queries`, then
/// groups the sliced queries by `scene_id` and runs one estate per scene group.
/// All queries for a scene share a single settled estate, so cross-scene
/// competition is impossible by construction.
///
/// Shape 3 protocol deviation label: every figure produced under consolidated
/// mode carries `protocol_deviation: true` in the report JSON (Shape 3 contract
/// §c). This function returns `LmebSceneGroupStats` so the report builder can
/// populate the `group_count`, `group_size_min`, `group_size_max`, and
/// `group_size_median` fields.
///
/// Error semantics: scene-level errors (connect failure, import receipt
/// mismatch) produce guard-excluded stub results for all queries in that scene
/// and continue — the overall run never aborts from a single failing scene.
/// Stub results show `guard_healthy = false` and empty retrieved lists.
///
/// Twin of Swift `runLMEBConsolidatedQueries(queries:corpus:config:)` in
/// `LMEBRunner.swift`.
pub fn run_lmeb_consolidated_queries(
    queries: &[LmebQuery],
    corpus: &LmebCorpus,
    config: &LmebRunConfig,
) -> Result<(Vec<LmebQueryResult>, Option<String>, crate::lmeb_scorer::LmebSceneGroupStats), String> {
    // Shuffle + slice — byte-identical algorithm to run_lmeb_queries (SplitMix64,
    // fleet-standard Fisher-Yates over index list → skip offset → take limit).
    let mut indices: Vec<usize> = (0..queries.len()).collect();
    let mut rng = SplitMix64::new(config.seed);
    rng.shuffle(&mut indices);

    let sliced: Vec<usize> = indices
        .into_iter()
        .skip(config.offset)
        .take(config.limit.unwrap_or(usize::MAX))
        .collect();

    // Materialise the sliced query list for grouping.
    let sliced_queries: Vec<LmebQuery> = sliced.iter().map(|&i| queries[i].clone()).collect();

    // Group by scene_id. Deterministic: sorted by scene_id, then by query.id within.
    let scene_groups = lmeb_group_queries_by_scene(&sliced_queries);
    let group_sizes: Vec<usize> = scene_groups.iter().map(|(_, qs)| qs.len()).collect();
    let group_stats = crate::lmeb_scorer::lmeb_scene_group_stats(&group_sizes);

    // Shared leg-level samplers for the serial scene loop.
    // LegGuardSampler needs Mutex wrapping (probe() takes &mut self internally).
    // LegTimingSampler has interior Mutex — no outer Mutex needed.
    let guard_sampler = Mutex::new(LegGuardSampler::new(config.guard_sampling_policy));
    let timing_sampler = crate::timing_capture::LegTimingSampler::new();

    let total_scenes = scene_groups.len();
    let mut all_results: Vec<LmebQueryResult> = Vec::with_capacity(sliced_queries.len());

    for (scene_idx, (scene_id, scene_queries)) in scene_groups.iter().enumerate() {
        match run_one_lmeb_scene(
            scene_id,
            scene_queries,
            corpus,
            config,
            &guard_sampler,
            &timing_sampler,
            scene_idx,
            total_scenes,
        ) {
            Ok(mut scene_results) => all_results.append(&mut scene_results),
            Err(e) => {
                // Config errors abort the lane immediately. Unit errors produce
                // guard-excluded stubs for all queries in this scene and continue.
                match e {
                    LaneError::Config(msg) => return Err(msg),
                    LaneError::Unit(desc) => {
                        // Scene-level unit error: stub all queries in the scene and continue.
                        eprintln!(
                            "[lmeb-s3] scene {}/{} ({scene_id}) ERROR (continuing): {}",
                            scene_idx + 1, total_scenes, desc
                        );
                        let guard_sampling_mode = guard_sampler.lock().unwrap().policy;
                        for query in scene_queries {
                            let relevant_doc_ids: HashSet<String> =
                                corpus.relevant_docs(&query.id).iter().cloned().collect();
                            all_results.push(LmebQueryResult {
                                query_id: query.id.clone(),
                                query_latency_seconds: 0.0,
                                retrieved_doc_ids: vec![],
                                relevant_doc_ids,
                                guard_healthy: false,
                                guard_diagnostic: Some(desc.clone()),
                                guard_sampling_mode,
                                docs_ingested: 0,
                                write_mean_latency_seconds: 0.0,
                                payload_text: None,
                                cache_hit: None,
                                drain_lane_observed: None,
                            });
                        }
                    }
                }
            }
        }
    }

    // C4: the leg's sampled timing report rides back beside the results.
    Ok((all_results, timing_sampler.text(), group_stats))
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests — scene ID extraction and grouping (C10-LMEB)
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod lmeb_shape3_tests {
    use super::{lmeb_group_queries_by_scene, lmeb_scene_id_from_query_id};
    use crate::lmeb_corpus::LmebQuery;

    fn make_query(id: &str) -> LmebQuery {
        LmebQuery {
            id: id.to_string(),
            text: format!("What is {id}?"),
        }
    }

    // ── lmeb_scene_id_from_query_id ───────────────────────────────────────────

    #[test]
    fn scene_id_basic() {
        assert_eq!(lmeb_scene_id_from_query_id("scene_42_q_0"), "scene_42");
    }

    #[test]
    fn scene_id_no_marker_passthrough() {
        assert_eq!(lmeb_scene_id_from_query_id("no-marker-here"), "no-marker-here");
    }

    #[test]
    fn scene_id_last_marker_wins() {
        // When the query ID itself contains _q_ earlier, rfind selects the LAST one.
        assert_eq!(lmeb_scene_id_from_query_id("scene_1_q_extra_q_0"), "scene_1_q_extra");
    }

    #[test]
    fn scene_id_empty_string() {
        assert_eq!(lmeb_scene_id_from_query_id(""), "");
    }

    // ── lmeb_group_queries_by_scene ───────────────────────────────────────────

    #[test]
    fn group_two_scenes() {
        let queries = vec![make_query("scene_1_q_0"), make_query("scene_2_q_0")];
        let groups = lmeb_group_queries_by_scene(&queries);
        assert_eq!(groups.len(), 2);
        assert_eq!(groups[0].0, "scene_1");
        assert_eq!(groups[1].0, "scene_2");
    }

    #[test]
    fn group_one_scene() {
        let queries = vec![
            make_query("scene_5_q_0"),
            make_query("scene_5_q_1"),
            make_query("scene_5_q_2"),
        ];
        let groups = lmeb_group_queries_by_scene(&queries);
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].0, "scene_5");
        assert_eq!(groups[0].1.len(), 3);
    }

    #[test]
    fn group_lexicographic_sort() {
        // Reversed input: scene_b before scene_a after grouping.
        let queries = vec![make_query("scene_b_q_0"), make_query("scene_a_q_0")];
        let groups = lmeb_group_queries_by_scene(&queries);
        assert_eq!(groups[0].0, "scene_a");
        assert_eq!(groups[1].0, "scene_b");
    }

    #[test]
    fn group_within_group_sort_by_id() {
        // Queries within a scene are sorted by id.
        let queries = vec![
            make_query("scene_3_q_1"),
            make_query("scene_3_q_0"),
            make_query("scene_3_q_2"),
        ];
        let groups = lmeb_group_queries_by_scene(&queries);
        assert_eq!(groups[0].1[0].id, "scene_3_q_0");
        assert_eq!(groups[0].1[1].id, "scene_3_q_1");
        assert_eq!(groups[0].1[2].id, "scene_3_q_2");
    }

    #[test]
    fn group_empty_input() {
        let groups = lmeb_group_queries_by_scene(&[]);
        assert!(groups.is_empty());
    }

    // ── run_one_lmeb_scene scratch-estate cleanup (#23 regression) ──────────

    /// #23 root-cause coverage: `SceneScratchGuard` is what makes cleanup
    /// exit-agnostic. Before this guard existed, ONLY the connect-failure
    /// and import-receipt-mismatch branches called `retire_scratch_estate`
    /// explicitly — `write_seed_file`, `moot_json_import`, the id-map
    /// lookup, the per-record manifest build, `moot_dream`, and
    /// `moot_reindex` all had `?` exits with no cleanup at all. Driving each
    /// of those live-MCP failure points needs a real mootx01 process, which
    /// this offline unit test suite does not have; testing the guard
    /// directly proves the mechanism that now covers every one of them
    /// uniformly, including the ones no single hand-picked failure branch
    /// could exercise here. `SceneScratchGuard` did not exist pre-fix, so
    /// this test both fails to compile against pre-fix code and fails at
    /// runtime against any version that reverts the guard back to
    /// scattered per-branch teardown calls.
    #[test]
    fn scene_scratch_guard_retires_on_drop_regardless_of_exit_reason() {
        use crate::scratch_posture::ScratchEstatePosture;

        let seed: u64 = 0xFEED_0024;
        let scene_index: usize = 1;
        let dir = super::lmeb_scratch_dir(seed, scene_index, ScratchEstatePosture::PlaintextTransient)
            .expect("lmeb_scratch_dir must create the scratch dir");
        assert!(dir.exists(), "precondition: scratch dir must exist before the guard is bound");

        {
            let _guard = super::SceneScratchGuard { scratch: dir.clone() };
            assert!(dir.exists(), "the guard must not remove the scratch dir while it is alive");
            // Guard drops here at scope exit — matching what happens on ANY
            // `?` early return, an explicit `return Err(...)`, or a normal
            // `Ok(...)` return from run_one_lmeb_scene.
        }

        assert!(
            !dir.exists(),
            "SceneScratchGuard::drop must retire the scratch estate — found residue at {}",
            dir.display()
        );
    }

    /// #23 integration coverage: the earliest live-process failure point in
    /// `run_one_lmeb_scene` (an unresolvable `moot_binary`, so
    /// `MCPClient::connect()` fails fast with no live mootx01 server
    /// needed) must still leave no scratch residue end-to-end through the
    /// real function, not just through the guard in isolation. This
    /// specific branch already called `retire_scratch_estate` explicitly
    /// before this fix (see `scene_scratch_guard_retires_on_drop_regardless_of_exit_reason`
    /// above for the branches that did not); this test guards against a
    /// regression in the refactor from scattered explicit calls to the
    /// guard-based design, not the original gap.
    #[test]
    fn scene_error_path_leaves_no_scratch_residue() {
        use crate::degeneracy_guard::{GuardSamplingPolicy, LegGuardSampler};
        use crate::estate_cache::EstateCacheMode;
        use crate::encode_barrier::EncodeBarrier;
        use crate::lmeb_corpus::LmebCorpus;
        use crate::scratch_posture::ScratchEstatePosture;
        use super::{BenchRunShape, LmebEstateShape, LmebRunConfig};
        use std::sync::Mutex;

        let seed: u64 = 0xFEED_0023;
        let scene_index: usize = 0;
        // Mirrors lmeb_scratch_dir's naming exactly so the test can assert on
        // the directory without depending on run_one_lmeb_scene's return
        // value (it returns Err, not the scratch path).
        let expected_scratch = std::path::PathBuf::from(
            format!("/tmp/lmeb-bench-{seed:016x}-{scene_index:08x}"),
        );
        let _ = std::fs::remove_dir_all(&expected_scratch);

        let corpus = LmebCorpus {
            docs_by_id: Default::default(),
            queries_by_id: Default::default(),
            candidates_by_scene_id: Default::default(),
            relevant_docs_by_query_id: Default::default(),
        };
        let scene_queries = [make_query("scene_0023_q_0")];
        let config = LmebRunConfig {
            unit_ids: None,
            retrieval_call: None,
            payload_arm: None,
            moot_binary: "/no/such/mootx01-binary-for-lmeb-shape3-test".to_string(),
            seed,
            limit: None,
            offset: 0,
            label: None,
            out_dir: None,
            encode_barrier: EncodeBarrier::Drain,
            estate_cache: EstateCacheMode::Off,
            cache_dir: None,
            scratch_posture: ScratchEstatePosture::PlaintextTransient,
            seed_path: crate::seed_export::SeedPathMode::Batch,
            dump_judge_inputs_path: None,
            guard_sampling_policy: GuardSamplingPolicy::OncePerLeg,
            corpus_digest: "test".to_string(),
            shape: BenchRunShape::Disk,
            parallel_units: 1,
            estate_shape: LmebEstateShape::Consolidated,
        };
        let sampler = Mutex::new(LegGuardSampler::new(config.guard_sampling_policy));
        let timing_sampler = crate::timing_capture::LegTimingSampler::new();

        let result = super::run_one_lmeb_scene(
            "scene_0023",
            &scene_queries,
            &corpus,
            &config,
            &sampler,
            &timing_sampler,
            scene_index,
            1,
        );

        assert!(result.is_err(), "an unresolvable binary must fail scene setup");
        assert!(
            !expected_scratch.exists(),
            "SceneScratchGuard must have retired {} on the error path — found residue",
            expected_scratch.display()
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// B4/BH-02 settle-gate tests — LMEB lane
// ─────────────────────────────────────────────────────────────────────────────

/// Pins the settle-gate invariant for the LMEB per-query path: when `moot_dream`
/// returns a JSON-RPC error, `run_one_lmeb_query` must propagate the error (via
/// `?`) and leave the artifact cache entry absent — no `estate/` and no
/// `manifest.json`. The invariant is `?` propagation in the settle block; this
/// test ensures a future refactor from `?` to logged-and-continue cannot land
/// silently. Already-gated lanes are expected to PASS both before and after any
/// membench-lane gate change because the protection mechanism (error propagation)
/// is independent of any boolean fitness flag.
#[cfg(test)]
mod lmeb_settle_gate_tests {
    use super::{run_one_lmeb_query, LaneError};
    use crate::degeneracy_guard::{GuardSamplingPolicy, LegGuardSampler};
    use crate::encode_barrier::EncodeBarrier;
    use crate::lmeb_corpus::{LmebCorpus, LmebQuery};
    use crate::scratch_posture::ScratchEstatePosture;
    use std::collections::HashSet;
    use std::io::Write;
    use std::path::PathBuf;
    use std::sync::Mutex;

    /// Writes a mock MCP server that returns a JSON-RPC error for `moot_dream`
    /// and an ok content block for every other tool call. The mock lives in a
    /// private PID-unique directory (0700) so parallel test invocations cannot
    /// interfere. Returns the script path; callers remove the parent directory
    /// after the test completes.
    fn write_failing_dream_mock() -> PathBuf {
        let base = std::env::temp_dir();
        let mut mock_dir = None;
        for attempt in 0u32..1000 {
            let candidate = base.join(format!(
                "lmeb-dream-fail-mock-{}-{attempt}", std::process::id()
            ));
            match std::fs::create_dir(&candidate) {
                Ok(()) => { mock_dir = Some(candidate); break; }
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(e) => panic!("cannot create lmeb mock dir: {e}"),
            }
        }
        let mock_dir = mock_dir.expect("no free lmeb mock dir in 1000 attempts");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&mock_dir, std::fs::Permissions::from_mode(0o700))
                .expect("chmod lmeb mock dir");
        }
        let script_path = mock_dir.join("mock.sh");
        // Returns a JSON-RPC error for moot_dream; all other tools return ok.
        // The loop reads one JSON-RPC request per line and writes one response.
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
    else
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"ok"}]}}'
    fi
  fi
done
"#;
        let mut f = std::fs::File::create(&script_path).expect("create lmeb failing-dream mock");
        f.write_all(script.as_bytes()).expect("write lmeb mock script");
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

    /// B4/BH-02 discriminating test for the LMEB per-query lane: a moot_dream
    /// failure during the settle sequence must cause run_one_lmeb_query to return
    /// Err (via ? propagation) and must leave the cache_entry directory absent.
    /// Already-gated by ? propagation — this test is expected to PASS both before
    /// and after the membench-lane fix because this lane was never broken; the test
    /// pins the invariant so it cannot be silently broken by a future refactor.
    #[test]
    fn settle_dream_failure_blocks_cache_write() {
        let pid = std::process::id();
        let base = std::env::temp_dir();
        // Non-existent directory → restore_estate_cache_entry sees no estate/ → miss
        // → build path → dream fails → Err propagated → nothing written to cache_entry.
        let cache_entry = base.join(format!("lmeb-dream-fail-entry-{pid}"));
        let _ = std::fs::remove_dir_all(&cache_entry);

        let script = write_failing_dream_mock();
        // The script is chmod 755 and has a shebang — invoked directly, no sh prefix.
        let mock_binary = script.to_string_lossy().into_owned();

        let run_prov = crate::artifact_manifest::make_artifact_provenance(
            "lmeb", "", 1, "impatient", "plaintext-optout", "live", "test-digest",
        );
        let empty_corpus = LmebCorpus {
            docs_by_id: Default::default(),
            queries_by_id: Default::default(),
            candidates_by_scene_id: Default::default(),
            relevant_docs_by_query_id: Default::default(),
        };
        let query = LmebQuery {
            id: "scene_0000_q_0".to_string(),
            text: "what is this?".to_string(),
        };
        let sampler = Mutex::new(LegGuardSampler::new(GuardSamplingPolicy::OncePerLeg));
        let timing_sampler = crate::timing_capture::LegTimingSampler::new();

        // Empty candidate_doc_ids + Live mode: no moot_file_memory calls (ingest loop
        // doesn't execute). Impatient barrier: no post-ingest moot_drain_status polling.
        // The first tool call after initialize is moot_dream, which fails.
        let result: Result<_, LaneError> = run_one_lmeb_query(
            &query,
            &[],                                    // candidate_doc_ids — empty
            HashSet::new(),                         // relevant_doc_ids — empty
            &empty_corpus,
            &mock_binary,
            1u64,                                   // seed
            0usize,                                 // query_index
            EncodeBarrier::Impatient,               // no post-ingest drain polling
            Some(cache_entry.as_path()),            // cache_entry — triggers build path
            ScratchEstatePosture::PlaintextTransient,
            crate::seed_export::SeedPathMode::Live, // no moot_json_import needed
            &sampler,
            &timing_sampler,
            &run_prov,
            false,                                  // require_artifact
            super::BenchRunShape::Disk,
            None,                                   // retrieval_call — standard path
            None,                                   // payload_arm — full ruled payload
        );

        let _ = std::fs::remove_dir_all(script.parent().expect("mock script has a parent dir"));

        // Primary assertion: ? propagation must deliver the Err to the caller.
        // If this ever becomes Ok, the ? was replaced with logged-and-continue and
        // the second assertion is now the only safety net against silent caching.
        assert!(
            result.is_err(),
            "run_one_lmeb_query must return Err when moot_dream fails (? propagation); \
             an Ok here means the settle calls were changed to logged-and-continue"
        );

        // Secondary assertion: the cache entry must be absent — no unsettled estate
        // must reach the artifact cache from this lane.
        assert!(
            !cache_entry.join("estate").exists(),
            "cache_entry/estate must not exist after a dream failure; \
             found: {}",
            cache_entry.join("estate").display()
        );
        assert!(
            !cache_entry.join("manifest.json").exists(),
            "cache_entry/manifest.json must not exist after a dream failure"
        );

        let _ = std::fs::remove_dir_all(&cache_entry);
    }
}
