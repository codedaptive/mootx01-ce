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
//! - VerbMap location: `"benchmark/lmeb"` (not `"benchmark/longmemeval"`).
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
//! - `MOOTX01_DATA_DIR` is injected into the command so the backend is always
//!   pointing at the scratch dir, never the operator's real estate.

use crate::config::{EndpointConfig, EndpointRole, ResultFormat, Transport, VerbMap};
use crate::degeneracy_guard::DegeneracyGuard;
use crate::encode_barrier::{EncodeBarrier, wait_for_encode_drain};
use crate::estate_cache::{
    default_cache_dir, estate_cache_entry_path, moot_binary_fingerprint,
    restore_estate_cache_entry, save_estate_cache_entry, EstateCacheMode,
};
use crate::json_value::JsonValue;
use crate::lmeb_corpus::{LmebCorpus, LmebQuery};
use crate::lmeb_scorer::LmebQueryResult;
use crate::longmemeval_runner::{probe_mcp_client, SplitMix64};
use crate::mcp_client::{MCPClient, MCPError, ToolCaller};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::Instant;

// ─────────────────────────────────────────────────────────────────────────────
// Run configuration
// ─────────────────────────────────────────────────────────────────────────────

/// Configuration for one LMEB run. Constructed by main.rs from CLI flags.
pub struct LmebRunConfig {
    pub moot_binary: String,
    pub seed: u64,
    pub limit: Option<usize>,
    pub offset: usize,
    pub label: Option<String>,
    pub out_dir: Option<PathBuf>,
    /// Encode-queue synchronization strategy. Default EncodeBarrier::Drain.
    pub encode_barrier: EncodeBarrier,
    /// Estate snapshot reuse mode. Default EstateCacheMode::Off.
    pub estate_cache: EstateCacheMode,
    /// Cache root directory. None = <out-dir>/estate-cache (or <cwd>/estate-cache).
    pub cache_dir: Option<PathBuf>,
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
/// `location: "benchmark/lmeb"` scopes all writes to the LMEB namespace —
/// distinct from the longmemeval namespace so the two benchmarks never share
/// content when run against the same binary.
pub fn lmeb_verb_map() -> VerbMap {
    let mut constant_args = BTreeMap::new();
    constant_args.insert("location".to_string(), "benchmark/lmeb".to_string());
    VerbMap::new(
        "moot_file_memory",
        "moot_memory_search",
        None, // list: not used
        None, // fetch: not used
        None, // content_arg: defaults to "content"
        None, // query_arg: defaults to "query"
        Some(constant_args),
        Some(ResultFormat::MootText),
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// Scratch dir management
// ─────────────────────────────────────────────────────────────────────────────

/// Creates a fresh scratch directory for one LMEB query's mootx01 instance.
/// Path: `/tmp/lmeb-bench-<seed_hex>-<query_index_hex>`.
///
/// The deterministic naming ensures each query has a unique path even across
/// retries, and the `/tmp/lmeb-bench-` prefix enables guarded teardown.
/// Twin of Swift `lmebScratchDir()` (UUID suffix variant; here seed+index for
/// determinism matching `lme_scratch_dir`).
pub fn lmeb_scratch_dir(seed: u64, query_index: usize) -> Result<PathBuf, MCPError> {
    let name = format!("lmeb-bench-{seed:016x}-{query_index:08x}");
    let path = PathBuf::from("/tmp").join(&name);
    std::fs::create_dir_all(&path).map_err(|e| MCPError {
        description: format!("lmeb_scratch_dir: failed to create {}: {e}", path.display()),
    })?;
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
/// Command form: `MOOTX01_DATA_DIR=<scratch> <binary> serve`. The MCPClient
/// splits on whitespace and runs via `/usr/bin/env`, which resolves the env-var
/// prefix natively.
pub fn lmeb_endpoint_config(scratch_dir: &Path, moot_binary: &str) -> EndpointConfig {
    let data_dir = scratch_dir.to_string_lossy();
    let command = format!("MOOTX01_DATA_DIR={data_dir} {moot_binary} serve");
    EndpointConfig {
        name: "mootx01-lmeb".to_string(),
        transport: Transport::Stdio { command },
        auth: None,
        verb_map: lmeb_verb_map(),
        role: EndpointRole::Both,
    }
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
/// Twin of the inner loop in Swift `runLMEBQueries(queries:corpus:config:)`.
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
) -> Result<LmebQueryResult, MCPError> {
    // ── Cache restore attempt (when cache mode is Reuse) ──────────────────────
    // Try to restore a previously-snapshotted estate for this query. On hit,
    // skip ingest and drain entirely. On miss, fall through to normal ingest.
    let cache_restore: Option<(PathBuf, Vec<LmebManifestEntry>)> =
        cache_entry.and_then(|entry| {
            restore_estate_cache_entry(entry, || {
                lmeb_scratch_dir(seed, query_index).map_err(|e| e.description.clone())
            })
        });

    let (scratch, mut uuid_to_doc_id, skip_ingest, cache_hit): (PathBuf, HashMap<String, String>, bool, Option<bool>) =
        if let Some((s, manifest)) = cache_restore {
            let map: HashMap<String, String> = manifest
                .into_iter()
                .map(|e| (e.uuid, e.doc_id))
                .collect();
            (s, map, true, Some(true))
        } else {
            let is_cache_miss = cache_entry.is_some();
            let s = lmeb_scratch_dir(seed, query_index)?;
            (s, HashMap::new(), false, if is_cache_miss { Some(false) } else { None })
        };

    let verb_map = lmeb_verb_map();
    let endpoint = lmeb_endpoint_config(&scratch, moot_binary);
    let guard = DegeneracyGuard::new();

    let mut client = MCPClient::new(endpoint);
    client.connect().map_err(|e| {
        let _ = lmeb_guarded_teardown(&scratch);
        e
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

    if !skip_ingest {
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
    }

    let write_mean_latency = if write_latencies.is_empty() {
        0.0
    } else {
        write_latencies.iter().sum::<f64>() / write_latencies.len() as f64
    };

    // ── Drain barrier (EncodeBarrier::Drain mode; skipped on cache hit) ───────
    // Wait for background encoding to drain before issuing any recall query.
    // On a cache hit the estate is already committed — no drain needed.
    if !skip_ingest && encode_barrier == EncodeBarrier::Drain {
        wait_for_encode_drain(&mut client, &format!("lmeb {}", query.id), 300.0);
    }

    // ── Snapshot to cache (on cache miss, after drain) ────────────────────────
    // Estate is fully committed at this point — safe to snapshot.
    if !skip_ingest {
        if let Some(entry) = cache_entry {
            let manifest_vec: Vec<LmebManifestEntry> = uuid_to_doc_id
                .iter()
                .map(|(uuid, doc_id)| LmebManifestEntry {
                    uuid: uuid.clone(),
                    doc_id: doc_id.clone(),
                })
                .collect();
            save_estate_cache_entry(&scratch, &manifest_vec, entry);
        }
    }

    // ── Probe for degeneracy guard ────────────────────────────────────────────
    let probe_rankings = probe_mcp_client(&mut client, &verb_map);
    let guard_verdict = guard.classify(&probe_rankings);
    let guard_healthy = guard_verdict.discriminant() == "healthy";
    let guard_diagnostic = if guard_healthy {
        None
    } else {
        Some(guard_verdict.diagnostic().to_string())
    };

    // ── Query via moot_memory_search ──────────────────────────────────────────
    let query_start = Instant::now();
    let (returned_uuids, payload_text): (Vec<String>, Option<String>) = if guard_healthy {
        let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
        args.insert(
            verb_map.query_arg.clone(),
            JsonValue::String(query.text.clone()),
        );
        match client.call_tool(&verb_map.query, args, &verb_map.result_format) {
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
    // UUIDs not in the manifest are dropped (conservative: unmappable hits never
    // earn credit — same policy as LME's UUID→session mapping).
    let mut seen_doc_ids: HashSet<String> = HashSet::new();
    let mut retrieved_doc_ids: Vec<String> = Vec::new();
    for uuid in &returned_uuids {
        if let Some(doc_id) = uuid_to_doc_id.get(uuid) {
            if seen_doc_ids.insert(doc_id.clone()) {
                retrieved_doc_ids.push(doc_id.clone());
            }
        }
    }

    // ── Teardown ──────────────────────────────────────────────────────────────
    client.disconnect();
    if let Err(e) = lmeb_guarded_teardown(&scratch) {
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
        docs_ingested,
        write_mean_latency_seconds: write_mean_latency,
        payload_text,
        cache_hit,
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Top-level query runner
// ─────────────────────────────────────────────────────────────────────────────

/// Runs the LMEB harness over a set of queries.
///
/// Applies seeded shuffle → offset → limit slice, then runs each query
/// sequentially. Progress is printed to stderr.
///
/// Twin of Swift `runLMEBQueries(queries:corpus:config:)`.
pub fn run_lmeb_queries(
    queries: &[LmebQuery],
    corpus: &LmebCorpus,
    config: &LmebRunConfig,
) -> Vec<LmebQueryResult> {
    // ── Shuffle + slice ───────────────────────────────────────────────────────
    let mut indices: Vec<usize> = (0..queries.len()).collect();
    let mut rng = SplitMix64::new(config.seed);
    rng.shuffle(&mut indices);

    // Apply offset then limit.
    let sliced: Vec<usize> = indices
        .into_iter()
        .skip(config.offset)
        .take(config.limit.unwrap_or(usize::MAX))
        .collect();

    let total = sliced.len();
    let mut results: Vec<LmebQueryResult> = Vec::with_capacity(total);

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

    for (progress_index, query_index) in sliced.iter().enumerate() {
        let query = &queries[*query_index];
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
        let cache_entry_opt: Option<PathBuf> = if config.estate_cache == EstateCacheMode::Reuse {
            Some(estate_cache_entry_path(
                &resolved_cache_dir,
                "lmeb",
                "",
                config.seed,
                config.encode_barrier,
                &binary_fingerprint,
                &query.id,
            ))
        } else {
            None
        };

        match run_one_lmeb_query(
            query,
            candidate_doc_ids,
            relevant_doc_ids,
            corpus,
            &config.moot_binary,
            config.seed,
            *query_index,
            config.encode_barrier,
            cache_entry_opt.as_deref(),
        ) {
            Ok(result) => {
                let guard_str = if result.guard_healthy { "healthy" } else { "GUARD_FAIL" };
                eprintln!(
                    "  guard={guard_str} docs_ingested={} retrieved={} query_ms={:.0}",
                    result.docs_ingested,
                    result.retrieved_doc_ids.len(),
                    result.query_latency_seconds * 1000.0,
                );
                results.push(result);
            }
            Err(e) => {
                eprintln!("  ERROR (skipping): {}", e.description);
                // Emit a guard-excluded result so the query shows in corpus_stats.
                results.push(LmebQueryResult {
                    query_id: query.id.clone(),
                    query_latency_seconds: 0.0,
                    retrieved_doc_ids: vec![],
                    relevant_doc_ids: corpus.relevant_docs(&query.id).iter().cloned().collect(),
                    guard_healthy: false,
                    guard_diagnostic: Some(e.description),
                    docs_ingested: 0,
                    write_mean_latency_seconds: 0.0,
                    payload_text: None,
                    cache_hit: None,
                });
            }
        }
    }

    results
}
