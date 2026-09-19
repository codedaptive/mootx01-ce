//! capturespread_runner.rs — harness lane `capturespread` (Part B / P2a).
//! Twin of Swift `CaptureSpreadRunner.swift`.
//!
//! LANE SHAPE
//!
//!   ONE persistent estate for the whole run (same design as the supersession
//!   lane). All corpus records are ingested in chronological (captureDate)
//!   order, the matrix is dreamed, and all probes are queried. Per-question
//!   provisioning would make capture-timing effects unmeasurable — the matrix
//!   priors are zero without an audit trail.
//!
//!   Three build variants (--variant); see `CaptureSpreadVariant` in corpus.rs:
//!     spread:   each record's capture_date populated → distinct HLC filedAt
//!               values → matrix decay projection sees real age differences.
//!     burst:    capture_date omitted → all records receive the batch wall-clock
//!               → null-control cell (T-side spread alone).
//!     splitcap: capture_date = designed (O-side alive) + event_time = T0
//!               constant (T-side killed) → isolates the O projection alone.
//!               Comparing splitcap decayed-vs-balanced against v1 burst
//!               decayed-vs-balanced (T-side alone) completes the decomposition.
//!
//!   Queries: moot_recall_shaped (preset selectable via --recall-shape).
//!
//!   Two probe classes (reported separately):
//!     current_value:    gold = fresh cluster record IDs. Decay should help.
//!     what_was_before:  gold = stale cluster record IDs. Over-decay guard.
//!
//! ASYNC → SYNC ASYMMETRY (documented, not approximated)
//!   Swift runner is async with Task-concurrent baseline + moot loading.
//!   The Rust port uses synchronous MCPClient — requests are serial. This
//!   matches the documented pattern in gauntlet_runner.rs and
//!   supersession_runner.rs: the single-estate design serialises queries
//!   anyway, so the wall-clock difference between concurrent and sequential
//!   load is dominated by the batch import call.
//!
//! ANOMALY SWEEP SEAM
//!   Swift estate seam `MOOT_BENCH_RUN_ANOMALY_SWEEP` is ported here. When the
//!   env var is "1", triggers an extra `moot_dream(associates=all)` after cache
//!   restore and before queries; hard-fails if meta.status != "completed".
//!
//! ACCURACY METRICS
//!   any@k, all@k, MRR per probe class. Per-probe result + aggregate.
//!   Accuracy files carry figures + identity only; NO timing (register rule).

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};

use crate::artifact_manifest::{make_artifact_provenance, ArtifactProvenance};
use crate::capturespread_corpus::{
    capture_spread_seed_records, generate_capture_spread_corpus, CaptureSpreadCorpus,
    CaptureSpreadProbe, CaptureSpreadVariant,
};
use crate::config::{EndpointConfig, EndpointRole, ResultFormat, Transport, VerbMap};
use crate::encode_barrier::{wait_for_encode_drain, EncodeBarrier};
use crate::estate_cache::{
    estate_cache_entry_path, restore_estate_cache_entry, save_estate_cache_entry, EstateCacheMode,
};
use crate::json_value::JsonValue;
use crate::longmemeval_runner::discover_moot_binary;
use crate::longmemeval_scorer::{lme_recall_all, lme_recall_any, lme_session_mrr};
use crate::mcp_client::{MCPClient, MCPError, ToolCaller};
use crate::record_writer::{record_filename, resolve_run_serial, write_record_never_overwrite};
use crate::run_environment::IdentityEnvironment;
use crate::scratch_posture::{moot_serve_command, ScratchEstatePosture};
use crate::seed_export::{emit_seed_json, seed_id_map, write_seed_file, SeedPathMode};

// ─────────────────────────────────────────────────────────────────────────────
// Output types (all Serde-serialisable for JSON report)
// ─────────────────────────────────────────────────────────────────────────────

/// Accuracy scores for one probe. Twin of Swift `CaptureSpreadProbeResult`.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptureSpreadProbeResult {
    pub probe_id: String,
    pub topic_index: usize,
    pub probe_class: String,
    pub cache_hit: bool,
    /// Ranked record IDs returned by moot_recall_shaped (top-20 max stored).
    pub ranked_record_ids: Vec<String>,
    pub gold_ids: Vec<String>,
    pub raw_ranked_count: usize,
    pub recall_any_at_k: f64,
    pub recall_all_at_k: f64,
    pub mrr: f64,
}

/// Per-class aggregate summary. Twin of Swift `CaptureSpreadClassAggregate`.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptureSpreadClassAggregate {
    pub probe_class: String,
    pub probe_count: usize,
    pub mean_recall_any_at_k: f64,
    pub mean_recall_all_at_k: f64,
    pub mean_mrr: f64,
}

/// Full run report. Twin of Swift `CaptureSpreadReport`.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptureSpreadReport {
    pub run_id: String,
    pub seed: u64,
    pub variant: String,
    pub recall_shape: String,
    pub top_k: usize,
    pub probe_topic_count: usize,
    pub distractor_count: usize,
    pub total_records: usize,
    pub total_probes: usize,
    pub mootx01_version: String,
    pub all_cache_hits: bool,
    pub probe_results: Vec<CaptureSpreadProbeResult>,
    pub current_value_aggregate: CaptureSpreadClassAggregate,
    pub what_was_before_aggregate: CaptureSpreadClassAggregate,
    pub overall_aggregate: CaptureSpreadClassAggregate,
}

/// Manifest entry carried in the estate cache. Maps corpus record ID →
/// drawer UUID. Twin of Swift `CaptureSpreadManifestEntry`.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptureSpreadManifestEntry {
    pub record_id: String,
    pub drawer_uuid: String,
}

// ─────────────────────────────────────────────────────────────────────────────
// Scratch estate lifecycle
// ─────────────────────────────────────────────────────────────────────────────

/// Creates a fresh scratch directory under `/tmp/capturespread-bench-<pid_hex>`.
/// The PID-based suffix is guaranteed whitespace-free so the path is safe to
/// embed in the stdio launch command. Twin of Swift `captureSpreadScratchDir`.
pub fn capturespread_scratch_dir(posture: ScratchEstatePosture) -> Result<PathBuf, String> {
    let name = format!("capturespread-bench-{:08x}", std::process::id());
    let path = Path::new("/tmp").join(name);
    std::fs::create_dir_all(&path)
        .map_err(|e| format!("captureSpreadScratchDir: could not create {}: {e}", path.display()))?;
    // The posture is the record's: a transient record is plaintext by rule.
    let _ = posture;
    Ok(path)
}

/// Deletes the scratch directory. Refuses any path that does not begin with
/// `/tmp/capturespread-bench-`. Twin of Swift `captureSpreadGuardedTeardown`.
fn capturespread_guarded_teardown(path: &Path) -> Result<(), String> {
    let s = path.to_string_lossy();
    if !s.starts_with("/tmp/capturespread-bench-") {
        return Err(format!(
            "SAFETY: capturespread_guarded_teardown refused to delete '{}' — \
             path must have the /tmp/capturespread-bench- prefix",
            path.display()
        ));
    }
    std::fs::remove_dir_all(path)
        .map_err(|e| format!("teardown of {} failed: {e}", path.display()))
}

// ─────────────────────────────────────────────────────────────────────────────
// Endpoint config
// ─────────────────────────────────────────────────────────────────────────────

/// Builds an EndpointConfig for a capturespread scratch estate.
///
/// TRUST BOUNDARY: the scratch dir and binary path are validated whitespace-free
/// before interpolation (same rule as gauntlet_endpoint_config). Panics on
/// violation — a whitespace-containing path would tokenize the command string
/// incorrectly and silently exec a different binary.
///
/// MOOTX01_VAULT=1 gates moot_json_import.
/// MOOTX01_SUBJECT_RIDER=0 suppresses subject expansion so recall results
/// reflect stored content only (matches the Swift runner setting).
pub fn capturespread_endpoint_config(
    scratch_dir: &Path,
    moot_binary: &str,
    posture: ScratchEstatePosture,
) -> Result<EndpointConfig, String> {
    let data_dir = scratch_dir.to_string_lossy().into_owned();
    // moot_serve_command validates whitespace in both binary and scratch_dir
    // and returns Err rather than panicking; no pre-check needed here.
    // The posture is the record's: a transient record is plaintext by rule.
    let _ = posture;
    let command = moot_serve_command(
        moot_binary, Path::new(&data_dir), false, &["MOOTX01_VAULT=1", "MOOTX01_SUBJECT_RIDER=0"], None)
        .map_err(|e| e.to_string())?;
    // Verb map: write verb is moot_file_memory (satisfies VerbMap's required field
    // even though per-record writes are not used — ingest goes through the batch
    // moot_json_import), query verb is moot_recall_shaped.
    let verb_map = VerbMap::new(
        crate::aria_v2_surface::FILE_MEMORY,
        crate::aria_v2_surface::RECALL_SHAPED,
        None,  // list: not used
        None,  // fetch: not used
        None,  // content_arg: defaults to "content"
        None,  // query_arg: defaults to "query"
        None,  // constant_args: empty (writes go via batch import)
        Some(ResultFormat::MootV2),
    );
    Ok(EndpointConfig {
        name: "mootx01-capturespread".to_string(),
        transport: Transport::Stdio { command },
        auth: None,
        verb_map,
        role: EndpointRole::Both,
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Anomaly sweep seam
// ─────────────────────────────────────────────────────────────────────────────

/// Checks `MOOT_BENCH_RUN_ANOMALY_SWEEP`; when "1", calls `moot_dream` with
/// `associates=all` and hard-fails unless the operation completed.
/// Called after cache restore and before probe queries. Twin of Swift
/// `anomalySweepSeam(client:label:)` in `EstateSeams.swift`.
///
/// v2: asserts `meta.status == "completed"`. The v1 "matrix rebuilt" text
/// signal is absent from the v2 surface; this guard is weaker — matrix
/// rebuild is not independently confirmable on v2 — but it is the strongest
/// confirmation v2 provides.
fn anomaly_sweep_seam<C: ToolCaller>(client: &mut C, label: &str) -> Result<(), MCPError> {
    if std::env::var("MOOT_BENCH_RUN_ANOMALY_SWEEP").ok().as_deref() != Some("1") {
        return Ok(());
    }
    let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
    args.insert("associates".to_string(), JsonValue::String("all".to_string()));
    let result = client.call_tool(crate::aria_v2_surface::DREAM, args, &ResultFormat::MootV2)?;
    if result.meta_status.as_deref() != Some("completed") {
        return Err(MCPError {
            description: format!(
                "MOOT_BENCH_RUN_ANOMALY_SWEEP: moot_dream did not complete for \
                 '{label}' (meta.status: {}) — refusing to score an un-dreamed estate.",
                result.meta_status.as_deref().unwrap_or("nil")
            ),
        });
    }
    eprintln!("[estate-seam] anomaly sweep confirmed on {label}");
    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────
// ISO8601 helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Converts Gregorian UTC components to a Unix epoch second.
/// Complements `capturespread_corpus::iso8601_utc` for the fiction-now
/// computation. Returns None on invalid components.
fn gregorian_to_epoch(year: u64, month: usize, day: u64, h: u64, mi: u64, s: u64) -> Option<u64> {
    let is_leap = |y: u64| y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);
    let days_in_month = [0u64, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    let mut days: u64 = 0;
    for y in 1970..year {
        days += if is_leap(y) { 366 } else { 365 };
    }
    for m in 1..month {
        days += if m == 2 && is_leap(year) { 29 } else { days_in_month[m] };
    }
    days += day.checked_sub(1)?;
    Some(days * 86_400 + h * 3_600 + mi * 60 + s)
}

/// Advances an ISO8601 UTC timestamp (e.g. `"2026-01-15T00:00:00Z"`) by one
/// day (86 400 seconds). Used to compute the fiction `now:` for `moot_dream`
/// so temporal math is a pure function of the corpus, not the wall clock.
/// Returns the input unchanged on any parse error.
fn advance_iso8601_by_one_day(iso: &str) -> String {
    (|| -> Option<String> {
        if iso.len() != 20 || !iso.ends_with('Z') {
            return None;
        }
        let y: u64 = iso[0..4].parse().ok()?;
        let mo: usize = iso[5..7].parse().ok()?;
        let d: u64 = iso[8..10].parse().ok()?;
        let h: u64 = iso[11..13].parse().ok()?;
        let mi: u64 = iso[14..16].parse().ok()?;
        let s: u64 = iso[17..19].parse().ok()?;
        let epoch = gregorian_to_epoch(y, mo, d, h, mi, s)?;
        Some(crate::capturespread_corpus::iso8601_utc(epoch + 86_400))
    })()
    .unwrap_or_else(|| iso.to_string())
}

// ─────────────────────────────────────────────────────────────────────────────
// Run configuration
// ─────────────────────────────────────────────────────────────────────────────

/// Run configuration. Twin of Swift `CaptureSpreadRunConfig`.
pub struct CaptureSpreadRunConfig {
    pub moot_binary_path: String,
    pub corpus: CaptureSpreadCorpus,
    pub variant: CaptureSpreadVariant,
    /// Named RecallShape preset. Default "matrix_decayed" (S4-C arm preset:
    /// exp-decayed O/T projections). Override via --recall-shape.
    pub recall_shape: String,
    pub top_k: usize,
    pub cache_mode: EstateCacheMode,
    pub cache_dir: PathBuf,
    pub posture: ScratchEstatePosture,
    pub out_dir: PathBuf,
    pub run_id: String,
    pub mootx01_version: String,
}

// ─────────────────────────────────────────────────────────────────────────────
// Main runner entry point
// ─────────────────────────────────────────────────────────────────────────────

/// Scores the capture-spread probe set against a settled estate. Returns the
/// full run report. Twin of Swift `runCaptureSpreadLane`.
///
/// Estate lifecycle (one estate for the whole run):
///   1. Provision scratch dir (or restore from cache).
///   2. Connect MCP client to serve process.
///   3. If fresh build: import all records → drain → dream → reindex → settle.
///   4. Anomaly sweep seam (MOOT_BENCH_RUN_ANOMALY_SWEEP).
///   5. For each probe: query via moot_recall_shaped, score.
///   6. Retire scratch dir.
pub fn run_capture_spread_lane(config: &CaptureSpreadRunConfig) -> Result<CaptureSpreadReport, String> {
    let corpus = &config.corpus;

    // Seed records sorted chronologically by corpus captureDate (ingestion order).
    // The variant controls eventTime and capture_date in the projected records;
    // sorting is always by the corpus captureDate (O-side sort key) in all variants.
    let seed_records = capture_spread_seed_records(corpus, config.variant);

    // Corpus digest used as the estate cache key component and seed file name.
    let corpus_digest = format!(
        "capturespread-seed{}-{}",
        corpus.seed,
        config.variant.as_str()
    );

    // Build artifact provenance for cache keying and validation. The lane
    // files real corpus event times — that is its fixed methodology, owned
    // by the "capturespread" benchmark name, not a keyed axis.
    let run_provenance: ArtifactProvenance = make_artifact_provenance(
        "capturespread",
        config.variant.as_str(),
        corpus.seed,
        EncodeBarrier::Drain.as_str(),
        config.posture.as_str(),
        SeedPathMode::Batch.as_str(),
        &corpus_digest,
    );

    let cache_entry = estate_cache_entry_path(
        &config.cache_dir,
        "capturespread",
        config.variant.as_str(),
        corpus.seed,
        EncodeBarrier::Drain,
        config.posture,
        SeedPathMode::Batch,
        "run",
    );

    // ── 1. Provision scratch estate (cache or fresh build) ────────────────────
    let mut uuid_by_record_id: HashMap<String, String> = HashMap::new();
    let mut cache_hit = false;

    let active_scratch_dir: PathBuf = if config.cache_mode != EstateCacheMode::Off {
        match restore_estate_cache_entry::<CaptureSpreadManifestEntry>(
            &cache_entry,
            &run_provenance,
            || capturespread_scratch_dir(config.posture),
        ) {
            Ok(Some((scratch, entries))) => {
                for entry in entries {
                    uuid_by_record_id.insert(entry.record_id, entry.drawer_uuid);
                }
                cache_hit = true;
                eprintln!(
                    "[capturespread] cache HIT: seed={} variant={}",
                    corpus.seed,
                    config.variant.as_str()
                );
                scratch
            }
            Ok(None) => {
                if config.cache_mode == EstateCacheMode::Require {
                    return Err(format!(
                        "[capturespread] --estate-cache require: no valid cache entry at {}",
                        cache_entry.display()
                    ));
                }
                eprintln!(
                    "[capturespread] fresh build: seed={} variant={} {} records",
                    corpus.seed,
                    config.variant.as_str(),
                    seed_records.len()
                );
                capturespread_scratch_dir(config.posture)
                    .map_err(|e| format!("[capturespread] scratch dir failed: {e}"))?
            }
            Err(e) => return Err(format!("[capturespread] cache restore error: {e}")),
        }
    } else {
        eprintln!(
            "[capturespread] fresh build: seed={} variant={} {} records",
            corpus.seed,
            config.variant.as_str(),
            seed_records.len()
        );
        capturespread_scratch_dir(config.posture)
            .map_err(|e| format!("[capturespread] scratch dir failed: {e}"))?
    };

    let endpoint = capturespread_endpoint_config(
        &active_scratch_dir,
        &config.moot_binary_path,
        config.posture,
    )?;
    // Belt-and-suspenders: verify --db points into /tmp before connecting.
    // Twin of Swift `assertScratchBackend(_:requirement:)` in CaptureSpreadRunner.
    crate::gauntlet_runner::assert_scratch_backend(
        &endpoint, &crate::gauntlet_runner::MOOT_SCRATCH_REQUIREMENT,
    );
    let mut client = MCPClient::new(endpoint);
    // connect() is on MCPClient, not the ToolCaller trait — call it here before
    // handing off to the generic run_queries fn.
    client.connect().map_err(|e| {
        format!("[capturespread] MCP connect failed: {}", e.description)
    })?;

    // Run queries; keep the scratch dir on failure for inspection.
    let result = run_queries(
        &mut client,
        config,
        corpus,
        &seed_records,
        &corpus_digest,
        &run_provenance,
        &cache_entry,
        &active_scratch_dir,
        &mut uuid_by_record_id,
        cache_hit,
    );

    // Tear down the scratch dir. Best-effort: teardown failure does not change
    // the runner's exit code.
    if let Err(e) = capturespread_guarded_teardown(&active_scratch_dir) {
        eprintln!("[capturespread] WARNING: teardown error: {e}");
    }

    result
}

/// Inner driver (separated so the outer function can always attempt teardown).
#[allow(clippy::too_many_arguments)]
fn run_queries<C: ToolCaller>(
    client: &mut C,
    config: &CaptureSpreadRunConfig,
    corpus: &CaptureSpreadCorpus,
    seed_records: &[crate::seed_export::SeedFileRecord],
    corpus_digest: &str,
    run_provenance: &ArtifactProvenance,
    cache_entry: &Path,
    active_scratch_dir: &Path,
    uuid_by_record_id: &mut HashMap<String, String>,
    cache_hit: bool,
) -> Result<CaptureSpreadReport, String> {
    // ── 2. Build estate when cache missed ─────────────────────────────────────
    if !cache_hit {
        // Emit one batch seed file and import via moot_json_import.
        // return_id_map: true requests the record-id → drawer-UUID map needed
        // for scoring (same pattern as gauntlet_runner.rs and
        // supersession_runner.rs).
        let seed_data = emit_seed_json(corpus_digest, seed_records, &[], &[]);
        let seed_path = write_seed_file(&seed_data, active_scratch_dir, corpus_digest)
            .map_err(|e| format!("[capturespread] seed write: {}", e.description))?;

        let mut import_args: BTreeMap<String, JsonValue> = BTreeMap::new();
        import_args.insert(
            "path".to_string(),
            JsonValue::String(seed_path.to_string_lossy().into_owned()),
        );
        // v2: `mode` arg removed from moot_json_import (v2 manages encode scheduling internally).
        import_args.insert("return_id_map".to_string(), JsonValue::Bool(true));

        let import_result = client
            .call_tool(crate::aria_v2_surface::JSON_IMPORT, import_args, &ResultFormat::MootV2)
            .map_err(|e| format!("[capturespread] moot_json_import: {}", e.description))?;

        // v2: drawer count is in structuredContent.data.drawers_written, not text.
        if import_result.drawers_written != Some(seed_records.len() as i64) {
            return Err(format!(
                "[capturespread] moot_json_import did not confirm {} drawers — \
                 refusing to score an unseeded estate. Got: {}",
                seed_records.len(),
                import_result.drawers_written
                    .map(|n| n.to_string())
                    .unwrap_or_else(|| "(no structured data)".to_string())
            ));
        }

        // Parse the record-id → drawer-UUID map from the import response.
        *uuid_by_record_id = seed_id_map(
            &import_result.text_blocks,
            seed_records.len(),
            &format!(
                "capturespread seed={} {}",
                corpus.seed,
                config.variant.as_str()
            ),
        )
        .map_err(|e| format!("{}", e.description))?;

        // Drain barrier: wait for encode queue idle before dreaming.
        let barrier = wait_for_encode_drain(
            client,
            &format!("capturespread seed={} post-import", corpus.seed),
            300.0,
        );
        if !barrier.converged {
            return Err(
                "[capturespread] encode drain did not converge within 300s — \
                 refusing to query a partially-indexed estate"
                    .to_string(),
            );
        }

        // Dream: full association + matrix rebuild. Deterministic fiction `now:` —
        // one day past the corpus's latest captureDate (the O-side clock) — so
        // temporal math is a pure function of the corpus and not the wall clock.
        // For spread/burst, capture_date == event_time so either would work. For
        // splitcap, event_time is T0 (constant) so we MUST use capture_date to
        // get the estate's actual temporal horizon (one day past the last record).
        // Burst has capture_date = None, so fall back to event_time in that case.
        let last_date = seed_records
            .iter()
            .map(|r| r.capture_date.as_deref().unwrap_or(r.event_time.as_str()))
            .max()
            .unwrap_or("2026-01-01T00:00:00Z");
        let fiction_now = advance_iso8601_by_one_day(last_date);

        let mut dream_args: BTreeMap<String, JsonValue> = BTreeMap::new();
        dream_args.insert("now".to_string(), JsonValue::String(fiction_now));
        dream_args.insert(
            "associates".to_string(),
            JsonValue::String("all".to_string()),
        );
        let dream_result = client
            .call_tool(crate::aria_v2_surface::DREAM, dream_args, &ResultFormat::MootV2)
            .map_err(|e| format!("[capturespread] moot_dream: {}", e.description))?;
        // v2: "matrix rebuilt" text is absent; assert meta.status == "completed"
        // (weaker — matrix rebuild not independently confirmable on v2).
        if dream_result.meta_status.as_deref() != Some("completed") {
            return Err(format!(
                "[capturespread] moot_dream did not complete (meta.status: {}) — \
                 refusing to score an un-dreamed estate.",
                dream_result.meta_status.as_deref().unwrap_or("nil")
            ));
        }

        // Reindex: retrain the embedding basis so the corpus's novel vocabulary
        // is not semantically dark after dreaming. Then settle with a drain.
        client
            .call_tool(crate::aria_v2_surface::REINDEX, BTreeMap::new(), &ResultFormat::MootV2)
            .map_err(|e| format!("[capturespread] moot_reindex: {}", e.description))?;

        let _ = wait_for_encode_drain(
            client,
            &format!("capturespread seed={} post-reindex", corpus.seed),
            300.0,
        );

        // Snapshot to estate cache (if enabled).
        if config.cache_mode != EstateCacheMode::Off {
            let manifest_entries: Vec<CaptureSpreadManifestEntry> = uuid_by_record_id
                .iter()
                .map(|(rid, uuid)| CaptureSpreadManifestEntry {
                    record_id: rid.clone(),
                    drawer_uuid: uuid.clone(),
                })
                .collect();
            save_estate_cache_entry(
                active_scratch_dir,
                &manifest_entries,
                run_provenance,
                cache_entry,
            );
        }

        eprintln!(
            "[capturespread] estate ready: {} records, dream confirmed, reindex complete",
            seed_records.len()
        );
    }

    // ── 3. Anomaly sweep seam (MOOT_BENCH_RUN_ANOMALY_SWEEP) ─────────────────
    anomaly_sweep_seam(
        client,
        &format!(
            "capturespread seed={} {}",
            corpus.seed,
            config.variant.as_str()
        ),
    )
    .map_err(|e| format!("{}", e.description))?;

    // Inverted map: drawer UUID (lowercased) → corpus record ID.
    // moot_recall_shaped returns UUIDs; scoring requires record IDs.
    let record_id_by_uuid: HashMap<String, String> = uuid_by_record_id
        .iter()
        .map(|(rid, uuid)| (uuid.to_lowercase(), rid.clone()))
        .collect();

    // ── 4. Query all probes ───────────────────────────────────────────────────
    let mut probe_results: Vec<CaptureSpreadProbeResult> =
        Vec::with_capacity(corpus.probes.len());

    for probe in &corpus.probes {
        let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
        args.insert(
            "query".to_string(),
            JsonValue::String(probe.query_text.clone()),
        );
        // Always supply the named preset — the lane's purpose IS to measure
        // shaped-recall behaviour. "matrix_decayed" is the default S4-C arm
        // preset (exp-decayed O/T projections). Override via --recall-shape.
        args.insert(
            "preset".to_string(),
            JsonValue::String(config.recall_shape.clone()),
        );

        let result = client
            .call_tool(crate::aria_v2_surface::RECALL_SHAPED, args, &ResultFormat::MootV2)
            .map_err(|e| {
                format!(
                    "[capturespread] moot_recall_shaped for {}: {}",
                    probe.probe_id, e.description
                )
            })?;

        let raw_ranked_count = result.ordered_ids.len();
        // Map retrieved UUIDs → corpus record IDs. Items not in the map are
        // distractors or unknown — dropped for scoring purposes.
        let ranked_record_ids: Vec<String> = result
            .ordered_ids
            .iter()
            .filter_map(|uid| record_id_by_uuid.get(&uid.to_lowercase()).cloned())
            .collect();

        let gold_set: HashSet<String> = probe.gold_ids.iter().cloned().collect();
        let recall_any = lme_recall_any(&ranked_record_ids, &gold_set, config.top_k);
        let recall_all = lme_recall_all(&ranked_record_ids, &gold_set, config.top_k);
        let mrr = lme_session_mrr(&ranked_record_ids, &gold_set);

        probe_results.push(CaptureSpreadProbeResult {
            probe_id: probe.probe_id.clone(),
            topic_index: probe.topic_index,
            probe_class: probe_class_label(probe),
            cache_hit,
            // Store at most 20 ranked IDs per probe in the report.
            ranked_record_ids: ranked_record_ids.into_iter().take(20).collect(),
            gold_ids: probe.gold_ids.clone(),
            raw_ranked_count,
            recall_any_at_k: recall_any,
            recall_all_at_k: recall_all,
            mrr,
        });
    }

    // ── 5. Aggregate ──────────────────────────────────────────────────────────
    let cv_agg = class_aggregate(&probe_results, "current_value");
    let wb_agg = class_aggregate(&probe_results, "what_was_before");
    let overall = {
        let n = probe_results.len();
        if n == 0 {
            CaptureSpreadClassAggregate {
                probe_class: "overall".to_string(),
                probe_count: 0,
                mean_recall_any_at_k: 0.0,
                mean_recall_all_at_k: 0.0,
                mean_mrr: 0.0,
            }
        } else {
            let nd = n as f64;
            CaptureSpreadClassAggregate {
                probe_class: "overall".to_string(),
                probe_count: n,
                mean_recall_any_at_k: probe_results.iter().map(|r| r.recall_any_at_k).sum::<f64>() / nd,
                mean_recall_all_at_k: probe_results.iter().map(|r| r.recall_all_at_k).sum::<f64>() / nd,
                mean_mrr: probe_results.iter().map(|r| r.mrr).sum::<f64>() / nd,
            }
        }
    };

    Ok(CaptureSpreadReport {
        run_id: config.run_id.clone(),
        seed: corpus.seed,
        variant: config.variant.as_str().to_string(),
        recall_shape: config.recall_shape.clone(),
        top_k: config.top_k,
        probe_topic_count: corpus.probe_topic_count,
        distractor_count: corpus.distractor_count,
        total_records: corpus.records.len(),
        total_probes: probe_results.len(),
        mootx01_version: config.mootx01_version.clone(),
        all_cache_hits: cache_hit,
        probe_results,
        current_value_aggregate: cv_agg,
        what_was_before_aggregate: wb_agg,
        overall_aggregate: overall,
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

fn probe_class_label(probe: &CaptureSpreadProbe) -> String {
    probe.probe_class.as_str().to_string()
}

fn class_aggregate(
    results: &[CaptureSpreadProbeResult],
    class_name: &str,
) -> CaptureSpreadClassAggregate {
    let subset: Vec<&CaptureSpreadProbeResult> =
        results.iter().filter(|r| r.probe_class == class_name).collect();
    let n = subset.len();
    if n == 0 {
        return CaptureSpreadClassAggregate {
            probe_class: class_name.to_string(),
            probe_count: 0,
            mean_recall_any_at_k: 0.0,
            mean_recall_all_at_k: 0.0,
            mean_mrr: 0.0,
        };
    }
    let nd = n as f64;
    CaptureSpreadClassAggregate {
        probe_class: class_name.to_string(),
        probe_count: n,
        mean_recall_any_at_k: subset.iter().map(|r| r.recall_any_at_k).sum::<f64>() / nd,
        mean_recall_all_at_k: subset.iter().map(|r| r.recall_all_at_k).sum::<f64>() / nd,
        mean_mrr: subset.iter().map(|r| r.mrr).sum::<f64>() / nd,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// CLI handler (called from main.rs dispatch)
// ─────────────────────────────────────────────────────────────────────────────

/// Reads the value following `--name` from `args`. Mirror of `option_value` in
/// `main.rs` (private there; reproduced here so this module compiles as a library
/// module without reaching into the binary crate's private namespace).
fn option_value<'a>(name: &str, args: &'a [String]) -> Option<&'a str> {
    let i = args.iter().position(|a| a == name)?;
    args.get(i + 1).map(String::as_str)
}

/// Runs the `capturespread` subcommand.
///
/// Options:
///   --seed <u64>                        Generate corpus with this seed (default 42).
///   --probes <int>                      Probe count (default 50).
///   --distractors <int>                 Distractor count (default 150).
///   --variant spread|burst|splitcap     Build variant (default spread).
///   --recall-shape <preset>             Named RecallShape preset (default matrix_decayed).
///   --k <int>                           Top-k for recall scoring (default 10).
///   --binary <path>                     Path to the mootx01 binary.
///   --mootx01-binary <path>             Alias for --binary.
///   --estate-cache off|reuse|require    (default off).
///   --cache-dir <dir>                   Cache directory root.
///   --out <dir>                         Output directory for report JSON.
///   --run-id <string>                   Caller-supplied run ID (optional).
///   --serial <string>                   Run serial for report filename (optional).
pub fn run_capture_spread_cmd(args: &[String]) -> Result<(), String> {
    let seed: u64 = option_value("--seed", args)
        .and_then(|s| s.parse().ok())
        .unwrap_or(42);

    let probe_count: usize = option_value("--probes", args)
        .map(|s| {
            s.parse::<i64>()
                .map_err(|_| format!("--probes: expected integer, got '{s}'"))
                .and_then(|v| {
                    if v < 1 {
                        Err(format!("--probes must be >= 1; got {v}"))
                    } else {
                        Ok(v as usize)
                    }
                })
        })
        .transpose()?
        .unwrap_or(50);

    let distractor_count: usize = option_value("--distractors", args)
        .map(|s| {
            s.parse::<i64>()
                .map_err(|_| format!("--distractors: expected integer, got '{s}'"))
                .and_then(|v| {
                    if v < 0 {
                        Err(format!("--distractors must be >= 0; got {v}"))
                    } else {
                        Ok(v as usize)
                    }
                })
        })
        .transpose()?
        .unwrap_or(150);

    let variant_str = option_value("--variant", args).unwrap_or("spread");
    let variant = match variant_str {
        "spread"   => CaptureSpreadVariant::Spread,
        "burst"    => CaptureSpreadVariant::Burst,
        "splitcap" => CaptureSpreadVariant::Splitcap,
        other => return Err(format!(
            "--variant must be 'spread', 'burst', or 'splitcap'; got '{other}'"
        )),
    };

    // "matrix_decayed" is the S4-C arm preset (exp-decayed O/T projections).
    // The spec referenced "matrixAware" as a capability label; the product preset
    // name is "matrix_decayed". Override via --recall-shape.
    let recall_shape = option_value("--recall-shape", args)
        .unwrap_or("matrix_decayed")
        .to_string();

    let top_k: usize = option_value("--k", args)
        .and_then(|s| s.parse().ok())
        .unwrap_or(10);

    let binary = option_value("--mootx01-binary", args)
        .or_else(|| option_value("--binary", args))
        .map(str::to_string)
        .or_else(discover_moot_binary)
        .ok_or_else(|| {
            "mootx01 binary not found. Pass --binary <path> or set MOOTX01_BINARY.".to_string()
        })?;

    let cache_mode = match option_value("--estate-cache", args).unwrap_or("off") {
        "off" => EstateCacheMode::Off,
        "reuse" => EstateCacheMode::Reuse,
        "require" => EstateCacheMode::Require,
        other => {
            return Err(format!(
                "--estate-cache must be 'off', 'reuse', or 'require'; got '{other}'"
            ))
        }
    };

    let out_dir = option_value("--out", args)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    let cache_dir = option_value("--cache-dir", args)
        .map(PathBuf::from)
        .unwrap_or_else(|| out_dir.join("estate-cache"));
    let run_id = option_value("--run-id", args)
        .map(str::to_string)
        .unwrap_or_else(|| format!("capturespread-seed{seed}-{variant_str}"));

    std::fs::create_dir_all(&out_dir)
        .map_err(|e| format!("could not create output directory {}: {e}", out_dir.display()))?;

    // Generate corpus deterministically from seed.
    let corpus = generate_capture_spread_corpus(seed, probe_count, distractor_count);
    eprintln!(
        "[capturespread] generated corpus seed={seed}: {} records, {} probes",
        corpus.records.len(),
        corpus.probes.len()
    );

    // Collect the mootx01 version for provenance.
    let mootx01_version = IdentityEnvironment::collect(Some(binary.as_str())).mootx01_version;

    let serial = resolve_run_serial(args);

    let config = CaptureSpreadRunConfig {
        moot_binary_path: binary,
        corpus,
        variant,
        recall_shape: recall_shape.clone(),
        top_k,
        cache_mode,
        cache_dir,
        posture: ScratchEstatePosture::PlaintextTransient,
        out_dir: out_dir.clone(),
        run_id,
        mootx01_version,
    };

    let report = run_capture_spread_lane(&config)?;

    // Serialise report to JSON (accuracy figures + identity; NO timing per the
    // benchmark register rule: timing lives in the separate timing ledger).
    let report_bytes = serde_json::to_vec_pretty(&report)
        .map_err(|e| format!("report encode failed: {e}"))?;
    let filename = record_filename("capturespread", variant_str, &serial, "", "json");
    let report_path = out_dir.join(&filename);
    write_record_never_overwrite(&report_bytes, &report_path)
        .map_err(|e| format!("report write failed: {e}"))?;

    // Print accuracy summary.
    let cv = &report.current_value_aggregate;
    let wb = &report.what_was_before_aggregate;
    let ov = &report.overall_aggregate;
    println!(
        "capturespread: seed={} variant={} shape={} k={} cacheHits={}",
        report.seed, variant_str, recall_shape, top_k, report.all_cache_hits
    );
    println!(
        "  current_value    ({} probes): any@{top_k}={:.4}  all@{top_k}={:.4}  MRR={:.4}",
        cv.probe_count, cv.mean_recall_any_at_k, cv.mean_recall_all_at_k, cv.mean_mrr
    );
    println!(
        "  what_was_before  ({} probes): any@{top_k}={:.4}  all@{top_k}={:.4}  MRR={:.4}",
        wb.probe_count, wb.mean_recall_any_at_k, wb.mean_recall_all_at_k, wb.mean_mrr
    );
    println!(
        "  overall          ({} probes): any@{top_k}={:.4}  all@{top_k}={:.4}  MRR={:.4}",
        ov.probe_count, ov.mean_recall_any_at_k, ov.mean_recall_all_at_k, ov.mean_mrr
    );
    println!("  report: {}", report_path.display());
    Ok(())
}
