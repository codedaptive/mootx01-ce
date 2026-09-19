//! timing_lane_runner.rs — C2 (benchmark reset 2026-08-13): the timing lane.
//!
//! Rust twin of `TimingLaneRunner.swift`. Measures write/ingest timing against
//! a single growing estate:
//!   - Builds a synthetic corpus monotonically: 2k → 10k → 100k rows.
//!   - At each checkpoint, takes k measured single-row writes per column
//!     (background + impatient).
//!   - Reports four metrics per write: ACCEPT (client stopwatch), INGEST
//!     (audit-derived via moot_timing_report), CYCLE (four tiers, audit-derived),
//!     READ (client stopwatch for moot_memory_search).
//!   - Uses since_ms watermarks so per-write timing signals are not polluted
//!     by landscape ingest events.
//!
//! Shape: "disk" only — timing numbers on an in-memory estate cannot be
//! compared to disk ones; the lane hardcodes Disk.
//!
//! k-row drift: the same estate is reused across k repeats. Each measured
//! write adds one row to the haystack. This drift is acceptable for encode-time
//! research; the report documents it as `haystack_drift_per_repeat`.
//!
//! C4 seam: `fetch_timing_report_since` passes the since_ms watermark to
//! `moot_timing_report` so per-write signals exclude landscape ingest events.

use crate::config::{EndpointConfig, EndpointRole, ResultFormat, Transport, VerbMap};
use crate::encode_barrier::wait_for_encode_drain;
use crate::json_value::JsonValue;
use crate::longmemeval_runner::SplitMix64;
use crate::mcp_client::{MCPClient, ToolCaller};
use crate::run_environment::RunEnvironment;
use crate::scratch_posture::{moot_serve_command, ScratchEstatePosture};
use crate::seed_export::{emit_seed_json, synthetic_event_time, write_seed_file, SeedFileRecord};
use crate::subject_generator::deterministic_subject;
// fetch_timing_report_since_watermark is defined locally below — the C4 seam's
// existing fetch_timing_report (in timing_capture.rs) takes no since_ms arg.
use serde::Serialize;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Instant;

// ─────────────────────────────────────────────────────────────────────────────
// Report structs (byte-compatible field names with Swift twin)
// ─────────────────────────────────────────────────────────────────────────────

/// A p50/p95 pair for one timing metric, in milliseconds.
///
/// Field names use snake_case in JSON (byte-compatible with Swift twin).
#[derive(Debug, Clone, Serialize)]
pub struct TimingStatPair {
    pub p50_ms: f64,
    pub p95_ms: f64,
}

/// Results for one measurement column (background or impatient) at one size.
#[derive(Debug, Clone, Serialize)]
///
/// Audit-derived fields are OPTIONAL and omitted from the JSON when no sample
/// was collected. Zero is a legitimate measured latency, so it must never
/// double as "not measured" — the four audit-derived metrics all read 0 when
/// the product binary lacks `moot_timing_report`, and a reader cannot tell
/// that from a fast estate. Absent says what happened; 0 lies about it.
pub struct TimingColumnResult {
    /// Client-stopwatch time from before moot_file_memory to after.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accept_ms: Option<TimingStatPair>,
    /// Audit-derived encode time (ingest_exact from moot_timing_report).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ingest_ms: Option<TimingStatPair>,
    /// Audit-derived cycle — vector tier (encode fingerprint + vector).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cycle_vector_ms: Option<TimingStatPair>,
    /// Audit-derived cycle — novel-token tier.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cycle_novel_ms: Option<TimingStatPair>,
    /// Audit-derived cycle — dreamt tier.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cycle_dreamt_ms: Option<TimingStatPair>,
    /// Client-stopwatch time for one moot_memory_search recall query.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub read_ms: Option<TimingStatPair>,
    /// Raw moot_timing_report texts for each repeat, for post-hoc diagnosis.
    pub raw_timing_reports: Vec<String>,
}

/// Results at one haystack size (both measurement columns).
#[derive(Debug, Clone, Serialize)]
pub struct TimingLaneSizeResult {
    /// Row count in the estate when the checkpoint was reached (before the
    /// k measured writes).
    pub haystack_size: usize,
    /// How many rows the haystack grows across k repeats (always 2 * repeats).
    pub haystack_drift_per_repeat: usize,
    /// Background writes: default queue posture (no impatient: true).
    pub background: TimingColumnResult,
    /// Impatient writes: impatient: true inline encoding.
    pub impatient: TimingColumnResult,
}

/// Top-level timing lane report. Written to `<out>/timing-report-seed<S>.json`.
#[derive(Debug, Serialize)]
pub struct TimingLaneReport {
    /// The estate schema the harness was built against, stamped into every
    /// report so the results record can carry the column without anyone typing
    /// it (BENCHMARK_PROTOCOL §9). Twin of Swift `estateSchemaVersion`.
    pub estate_schema_version: String,
    pub benchmark_protocol_version: &'static str,
    pub run_environment: RunEnvironment,
    pub seed: u64,
    pub repeats: usize,
    /// Always "disk" for this lane.
    pub shape: &'static str,
    /// At-rest posture: always "plaintext-optout" for this lane.
    pub estate_encryption: &'static str,
    pub results: Vec<TimingLaneSizeResult>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Timing report parsers
// ─────────────────────────────────────────────────────────────────────────────

/// Extracts the `watermark_ms: N` value from a moot_timing_report text.
/// Returns 0 when the line is absent (safe fallback: over-counts, never
/// under-counts). Twin of Swift `parseWatermarkMs(from:)`.
pub fn parse_watermark_ms(text: &str) -> i64 {
    for line in text.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("watermark_ms:") {
            if let Ok(v) = rest.trim().parse::<i64>() {
                return v;
            }
        }
    }
    0
}

/// Extracts the p50 value (milliseconds) for a named metric from a timing
/// report text. Expected line form: "  <prefix>: n=N, p50=Xms, p95=Yms".
/// Returns None when the line is absent or unparseable.
/// Twin of Swift `parseTimingP50Ms(prefix:from:)`.
fn parse_timing_p50_ms(prefix: &str, text: &str) -> Option<f64> {
    for line in text.lines() {
        let trimmed = line.trim();
        if !trimmed.starts_with(prefix) {
            continue;
        }
        // Find "p50=" in the rest of the line.
        let p50_pos = trimmed.find("p50=")?;
        let after_p50 = &trimmed[p50_pos + 4..];
        // Value ends at next comma or whitespace.
        let raw: String = after_p50
            .chars()
            .take_while(|c| !c.is_whitespace() && *c != ',')
            .collect();
        // Strip trailing "ms".
        let stripped = raw.strip_suffix("ms").unwrap_or(&raw);
        return stripped.parse::<f64>().ok();
    }
    None
}

// ─────────────────────────────────────────────────────────────────────────────
// C4 seam — since_ms variant
// ─────────────────────────────────────────────────────────────────────────────

/// Calls `moot_timing_report` with a `since_ms` watermark and returns the
/// rendered report text. Errors swallowed into None — timing capture must
/// not abort a measurement run.
///
/// The watermark isolates the audit window so landscape ingest events do not
/// pollute per-write INGEST/CYCLE numbers. Twin of Swift
/// `fetchTimingReportSince(client:sinceMs:)`.
pub fn fetch_timing_report_since_watermark(
    client: &mut dyn ToolCaller,
    since_ms: i64,
) -> Option<String> {
    let mut args = BTreeMap::new();
    args.insert("since_ms".to_string(), JsonValue::Number(since_ms as f64));
    let result = client
        .call_tool(crate::aria_v2_surface::TIMING_REPORT, args, &ResultFormat::MootV2)
        .ok()?;
    let text = result.text_blocks.join("\n");
    if text.is_empty() { None } else { Some(text) }
}

/// Preflight: the product binary must actually expose `moot_timing_report`.
///
/// Why this is a hard failure and not a warning. INGEST and the three CYCLE
/// tiers are derived ENTIRELY from that tool. When it is absent — an older
/// installed binary is the ordinary case, since the tool shipped 2026-08-13 —
/// every fetch returns None, no samples accumulate, and the lane reports the
/// four audit-derived metrics as missing. A landscape run costs an hour;
/// discovering it was unmeasurable afterwards costs the hour twice.
///
/// Twin of Swift `assertTimingToolAvailable(client:mootBinaryPath:)`.
pub fn assert_timing_tool_available(
    client: &mut dyn ToolCaller,
    moot_binary_path: &std::path::Path,
) -> Result<(), String> {
    if fetch_timing_report_since_watermark(client, 0).is_some() {
        return Ok(());
    }
    Err(format!(
        "timing: the product binary does not expose moot_timing_report, so \
         INGEST and all three CYCLE tiers cannot be measured.\n  binary: {}\n\
         The tool shipped 2026-08-13; an installed binary older than that \
         predates it. Build the current binary and pass it with \
         --mootx01-binary <path>, or install it, then re-run.",
        moot_binary_path.display()
    ))
}

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic corpus
// ─────────────────────────────────────────────────────────────────────────────

/// One synthetic timing record.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TimingSeedRecord {
    pub id: String,
    pub content: String,
    pub event_time: String,
    pub room: String,
}

/// Generates a deterministic batch of synthetic timing records.
/// Record content encodes seed + index so every row is unique and
/// deterministic. Twin of Swift `timingLaneRecords(from:to:seed:)`.
pub fn timing_lane_records(from: usize, to: usize, seed: u64) -> Vec<TimingSeedRecord> {
    let mut rng = SplitMix64::new(
        seed.wrapping_add((from as u64).wrapping_mul(6_364_136_223_846_793_005)),
    );
    let mut records = Vec::with_capacity(to - from);
    for i in from..to {
        let a = rng.next_u64();
        let b = rng.next_u64();
        // UUID-format id (version 4, variant bits set): deterministic.
        let id = format!(
            "{:08x}-{:04x}-{:04x}-{:04x}-{:012x}",
            (a >> 32) as u32,
            (a >> 16) as u16,
            ((a as u16) & 0x0FFF) | 0x4000,
            ((b >> 48) as u16 & 0x3FFF) | 0x8000,
            b & 0x0000_FFFF_FFFF_FFFF,
        );
        let content = format!(
            "Timing benchmark entry index={} seed={}. \
             This synthetic memory record measures write latency on a growing \
             estate of {} prior rows. Content length targets realistic encode \
             overhead including the embedding path. Entry checksum: {}.",
            i, seed, i, a ^ b
        );
        records.push(TimingSeedRecord {
            id,
            content,
            event_time: synthetic_event_time(i),
            room: "timing/bench".to_string(),
        });
    }
    records
}

// ─────────────────────────────────────────────────────────────────────────────
// Percentile helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Computes p50 and p95 from a sample slice using the nearest-rank method.
///
/// Returns None on empty input — never (0, 0) — so "not measured" stays
/// distinguishable from "measured at zero": the (0, 0) shape lets a run
/// with no `moot_timing_report` publish four fabricated zero metrics
/// beside real ones. The serialiser omits a None field.
/// Twin of Swift `computeStatPair(samples:)`.
fn compute_stat_pair(samples: &[f64]) -> Option<TimingStatPair> {
    if samples.is_empty() {
        return None;
    }
    let mut sorted = samples.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let n = sorted.len();
    // nearest-rank: ceil(q * N) gives the 1-indexed rank; subtract 1 for 0-index.
    let p50_idx = ((0.50_f64 * n as f64).ceil() as usize).max(1).min(n) - 1;
    let p95_idx = ((0.95_f64 * n as f64).ceil() as usize).max(1).min(n) - 1;
    Some(TimingStatPair {
        p50_ms: sorted[p50_idx],
        p95_ms: sorted[p95_idx],
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Estate provisioner
// ─────────────────────────────────────────────────────────────────────────────

/// At-rest encryption posture — always plaintextOptOut for the timing lane.
const TIMING_POSTURE: ScratchEstatePosture = ScratchEstatePosture::PlaintextTransient;

/// Creates the scratch directory for the timing estate under
/// `/tmp/timing-lane-bench-<seed>`. Mirrors the lme-bench- convention.
fn timing_scratch_dir(seed: u64) -> Result<PathBuf, String> {
    let path = PathBuf::from(format!("/tmp/timing-lane-bench-{}", seed));
    // Remove any stale directory from a previous run.
    if path.exists() {
        std::fs::remove_dir_all(&path)
            .map_err(|e| format!("timing_scratch_dir: remove stale dir failed: {e}"))?;
    }
    std::fs::create_dir_all(&path)
        .map_err(|e| format!("timing_scratch_dir: create dir failed: {e}"))?;

    // Symlink guard (mirrors membench_runner pattern).
    let lstat = std::fs::symlink_metadata(&path)
        .map_err(|e| format!("timing_scratch_dir: stat failed: {e}"))?;
    if lstat.file_type().is_symlink() {
        return Err(format!(
            "timing_scratch_dir: SAFETY: '{}' is a symlink — refusing",
            path.display()
        ));
    }

    let canonical = std::fs::canonicalize(&path)
        .map_err(|e| format!("timing_scratch_dir: canonicalize failed: {e}"))?;

    Ok(canonical)
}

/// Tears down the timing scratch directory, refusing any non-timing path.
fn timing_guarded_teardown(path: &Path) {
    let expected_prefix = crate::config::canonical_tmp_base()
        .join("timing-lane-bench-")
        .to_string_lossy()
        .into_owned();
    let path_str = path.to_string_lossy();
    if !path_str.starts_with(&expected_prefix) {
        eprintln!(
            "[timing] SAFETY: teardown refused '{}' — must start with {}",
            path_str, expected_prefix
        );
        return;
    }
    if let Err(e) = std::fs::remove_dir_all(path) {
        eprintln!("[timing] teardown warning: {e}");
    }
}

/// Standard VerbMap for the timing lane: moot_file_memory writes,
/// moot_memory_search reads, location "timing/bench".
fn timing_verb_map() -> VerbMap {
    let mut constant_args = BTreeMap::new();
    constant_args.insert("location".to_string(), "timing/bench".to_string());
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

/// Builds an EndpointConfig for mootx01 pointing at the timing estate.
fn timing_endpoint_config(scratch_dir: &Path, binary: &Path) -> Result<EndpointConfig, String> {
    let command = moot_serve_command(
        &binary.display().to_string(), scratch_dir, false,
        &["MOOTX01_VAULT=1", "MOOTX01_SUBJECT_RIDER=0"], None)
        .map_err(|e| format!("timing: serve command error: {}", e))?;
    let endpoint = EndpointConfig {
        name: "mootx01-timing".to_string(),
        transport: Transport::Stdio { command },
        auth: None,
        verb_map: timing_verb_map(),
        role: EndpointRole::Target,
    };
    // Belt-and-suspenders: assert_scratch_backend verifies the scratch constraint
    // (--db must point at /tmp) after the command is assembled.
    // Swift timing lanes reach the guard through `lmeEndpointConfig`; this lane builds
    // its own endpoint, so the check lives here.
    // Covers the timing lane's own endpoint, separate from lme_endpoint_config.
    crate::gauntlet_runner::assert_scratch_backend(
        &endpoint, &crate::gauntlet_runner::MOOT_SCRATCH_REQUIREMENT,
    );
    Ok(endpoint)
}

// ─────────────────────────────────────────────────────────────────────────────
// Landscape builder
// ─────────────────────────────────────────────────────────────────────────────

/// Ingests `count` synthetic rows via the batch seed path (moot_json_import)
/// and waits for the encode drain to settle.
///
/// ONE import for the whole segment, then ONE drain. The importer writes a bulk
/// seed in a single transaction up to ImportPolicy::BULK_WINDOW (125,000 rows)
/// and does not wait for encoding — the corpus drain worker fans that across
/// every core. Splitting the segment into chunks with a barrier between them
/// serializes exactly the work the product parallelizes, and republishes the
/// resident vector index once per barrier.
///
/// Twin of Swift `buildLandscapeSegment(client:scratchDir:from:count:seed:label:)`.
fn build_landscape_segment(
    client: &mut MCPClient,
    scratch_dir: &Path,
    from: usize,
    count: usize,
    seed: u64,
    label: &str,
) -> Result<(), String> {
    if count == 0 {
        return Ok(());
    }
    let records = timing_lane_records(from, from + count, seed);
    let seed_records: Vec<SeedFileRecord> = records
        .iter()
        .map(|r| SeedFileRecord::new(&r.id, &r.content, &r.event_time, &r.room))
        .collect();
    let seed_name = format!("timing-landscape-{}", label);
    let seed_data = emit_seed_json(&seed_name, &seed_records, &[], &[]);
    let seed_path = write_seed_file(&seed_data, scratch_dir, &seed_name)
        .map_err(|e| format!("timing: seed write failed: {}", e.description))?;

    let mut import_args = BTreeMap::new();
    import_args.insert("path".to_string(), JsonValue::String(seed_path.to_string_lossy().into_owned()));
    // Operator decision (operator ruling 2026-08-17): the landscape imports in background
    // encode speed. The flag sets the embed fan-out width — foreground takes
    // every logical core, background about a quarter — so the encode yields the
    // machine rather than saturating it while a landscape of this size drains.
    // v2: `mode` arg removed from moot_json_import (v2 manages encode scheduling internally).
    let import_result = client
        .call_tool(crate::aria_v2_surface::JSON_IMPORT, import_args, &ResultFormat::MootV2)
        .map_err(|e| format!("timing: moot_json_import failed: {}", e.description))?;
    // v2: drawer count is in structuredContent.data.drawers_written, not text.
    if import_result.drawers_written != Some(records.len() as i64) {
        return Err(format!(
            "timing: moot_json_import did not confirm {} drawers for segment {} — got: {}",
            records.len(),
            label,
            import_result.drawers_written
                .map(|n| n.to_string())
                .unwrap_or_else(|| "(no structured data)".to_string())
        ));
    }

    // Drain barrier: encode-queue must be idle before measuring the baseline watermark.
    wait_for_encode_drain(client, &format!("timing-landscape-{}", label), 300.0);

    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────
// Column runner
// ─────────────────────────────────────────────────────────────────────────────

/// Runs k measured single-row writes for one column (background or impatient).
///
/// Per-write sequence:
///   1. ACCEPT: wall-clock stopwatch around moot_file_memory.
///   2. Drain (background only): wait_for_encode_drain ensures the audit log
///      entry is committed before the timing report is pulled.
///   3. INGEST + CYCLE: moot_timing_report(since_ms: watermark).
///      Watermark advances to the new watermark_ms after each write.
///   4. READ: wall-clock stopwatch around moot_memory_search.
///
/// Twin of Swift `runTimingColumn(client:repeats:useImpatient:watermarkMs:nextRecordIndex:seed:)`.
fn run_timing_column(
    client: &mut MCPClient,
    repeats: usize,
    use_impatient: bool,
    watermark_ms: &mut i64,
    next_record_index: &mut usize,
    seed: u64,
) -> TimingColumnResult {
    let mut accept_samples: Vec<f64>       = Vec::with_capacity(repeats);
    let mut ingest_samples: Vec<f64>       = Vec::with_capacity(repeats);
    let mut cycle_vector_samples: Vec<f64> = Vec::with_capacity(repeats);
    let mut cycle_novel_samples: Vec<f64>  = Vec::with_capacity(repeats);
    let mut cycle_dreamt_samples: Vec<f64> = Vec::with_capacity(repeats);
    let mut read_samples: Vec<f64>         = Vec::with_capacity(repeats);
    let mut raw_reports: Vec<String>       = Vec::with_capacity(repeats);

    for _ in 0..repeats {
        let record_index = *next_record_index;
        *next_record_index += 1;

        let records = timing_lane_records(record_index, record_index + 1, seed);
        let record = match records.into_iter().next() {
            Some(r) => r,
            None => continue,
        };

        // ── ACCEPT: write with stopwatch ──────────────────────────────────
        let subject = deterministic_subject(&record.content);
        let mut write_args = BTreeMap::new();
        write_args.insert("content".to_string(), JsonValue::String(record.content.clone()));
        write_args.insert("subject".to_string(), JsonValue::String(subject));
        write_args.insert("location".to_string(), JsonValue::String(record.room.clone()));
        if use_impatient {
            write_args.insert("impatient".to_string(), JsonValue::Bool(true));
        }
        let accept_start = Instant::now();
        let _ = client.call_tool(crate::aria_v2_surface::FILE_MEMORY, write_args, &ResultFormat::MootV2);
        let accept_ms = accept_start.elapsed().as_secs_f64() * 1000.0;
        accept_samples.push(accept_ms);

        // ── Drain barrier (background only) ───────────────────────────────
        if !use_impatient {
            wait_for_encode_drain(
                client,
                &format!("timing-column-bg-{}", record_index),
                300.0,
            );
        }

        // ── INGEST + CYCLE: timing report with since_ms watermark ─────────
        if let Some(text) = fetch_timing_report_since_watermark(client, *watermark_ms) {
            raw_reports.push(text.clone());
            let new_watermark = parse_watermark_ms(&text);
            if new_watermark > *watermark_ms {
                *watermark_ms = new_watermark;
            }
            if let Some(ms) = parse_timing_p50_ms("ingest_exact:", &text)   { ingest_samples.push(ms); }
            if let Some(ms) = parse_timing_p50_ms("cycle_vector:", &text)   { cycle_vector_samples.push(ms); }
            if let Some(ms) = parse_timing_p50_ms("cycle_novel:", &text)    { cycle_novel_samples.push(ms); }
            if let Some(ms) = parse_timing_p50_ms("cycle_dreamt:", &text)   { cycle_dreamt_samples.push(ms); }
        }

        // ── READ: recall query with stopwatch ─────────────────────────────
        let query_text: String = record
            .content
            .split('.')
            .next()
            .unwrap_or("timing benchmark")
            .to_string();
        // v2: scope key for moot_memory_search is `wing` (v1 used `location`).
        let mut read_args = BTreeMap::new();
        read_args.insert("query".to_string(), JsonValue::String(query_text));
        read_args.insert("wing".to_string(), JsonValue::String(record.room.clone()));
        let read_start = Instant::now();
        let _ = client.call_tool(crate::aria_v2_surface::MEMORY_SEARCH, read_args, &ResultFormat::MootV2);
        let read_ms = read_start.elapsed().as_secs_f64() * 1000.0;
        read_samples.push(read_ms);
    }

    TimingColumnResult {
        accept_ms:       compute_stat_pair(&accept_samples),
        ingest_ms:       compute_stat_pair(&ingest_samples),
        cycle_vector_ms: compute_stat_pair(&cycle_vector_samples),
        cycle_novel_ms:  compute_stat_pair(&cycle_novel_samples),
        cycle_dreamt_ms: compute_stat_pair(&cycle_dreamt_samples),
        read_ms:         compute_stat_pair(&read_samples),
        raw_timing_reports: raw_reports,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Main entry point
// ─────────────────────────────────────────────────────────────────────────────

/// Configuration for one timing lane run.
pub struct TimingLaneConfig {
    /// Path to the mootx01 binary.
    pub moot_binary_path: PathBuf,
    /// Corpus seed.
    pub seed: u64,
    /// k — measured writes per column per checkpoint.
    pub repeats: usize,
    /// Output directory for the report.
    pub out_dir: Option<PathBuf>,
    /// Machine posture ("quiet", "contended", or "unspecified").
    pub run_mode: String,
    /// Landscape checkpoints, ascending. Default 2k/10k/100k; `--sizes`
    /// overrides so the lane can be exercised without a 100,000-row build.
    pub sizes: Vec<usize>,
    /// Run serial from `--run-id`, shared with this pass's params sidecar.
    /// `None` falls back to a UTC stamp, matching the Swift leg.
    pub run_id: Option<String>,
}

/// Runs the timing lane: provision one estate, build the landscape in three
/// monotonic steps, and take k measurements at each checkpoint.
///
/// Twin of Swift `runTiming(_:)`.
pub fn run_timing_lane(config: &TimingLaneConfig) -> Result<(), String> {
    // Provision scratch estate.
    let scratch_dir = timing_scratch_dir(config.seed)?;
    let endpoint_cfg = timing_endpoint_config(&scratch_dir, &config.moot_binary_path)?;
    let mut client = MCPClient::new(endpoint_cfg);
    client
        .connect()
        .map_err(|e| format!("timing: connect failed: {}", e.description))?;

    eprintln!("[timing] estate: {}", scratch_dir.display());

    // Preflight BEFORE the landscape build — an unmeasurable run must cost
    // seconds, not the hour a full 2k/10k/100k landscape takes.
    assert_timing_tool_available(&mut client, &config.moot_binary_path)?;

    // Landscape checkpoints: monotonic build from the configured sizes.
    let checkpoints: Vec<(usize, usize)> = {
        // Build monotonically: each segment starts where the previous ended,
        // so a checkpoint's delta is its size minus the size before it.
        let mut out: Vec<(usize, usize)> = Vec::with_capacity(config.sizes.len());
        let mut previous = 0usize;
        for &size in &config.sizes {
            out.push((size, size - previous));
            previous = size;
        }
        out
    };

    let mut landscape_rows_built = 0usize;
    let mut size_results: Vec<TimingLaneSizeResult> = Vec::new();

    for (target_size, segment_count) in checkpoints {
        eprintln!(
            "[timing] building landscape to {} rows (adding {})...",
            target_size, segment_count
        );

        build_landscape_segment(
            &mut client,
            &scratch_dir,
            landscape_rows_built,
            segment_count,
            config.seed,
            &target_size.to_string(),
        )?;
        landscape_rows_built += segment_count;

        // Baseline watermark: full-history timing report after landscape drain.
        let mut watermark_ms: i64 = {
            let mut args = BTreeMap::new();
            args.insert("since_ms".to_string(), JsonValue::Number(0.0));
            let baseline = client
                .call_tool(crate::aria_v2_surface::TIMING_REPORT, args, &ResultFormat::MootV2)
                .ok()
                .map(|r| r.text_blocks.join("\n"))
                .as_deref()
                .map(parse_watermark_ms)
                .unwrap_or(0);
            baseline
        };

        eprintln!(
            "[timing] checkpoint {}: watermark={}ms",
            target_size, watermark_ms
        );

        // Background column.
        eprintln!(
            "[timing] measuring {} background writes at {}...",
            config.repeats, target_size
        );
        let mut next_record_index = landscape_rows_built;
        let background_result = run_timing_column(
            &mut client,
            config.repeats,
            false, // background
            &mut watermark_ms,
            &mut next_record_index,
            config.seed,
        );
        // Impatient column. next_record_index continues from where background left off.
        eprintln!(
            "[timing] measuring {} impatient writes at {}...",
            config.repeats, target_size
        );
        let impatient_result = run_timing_column(
            &mut client,
            config.repeats,
            true, // impatient
            &mut watermark_ms,
            &mut next_record_index,
            config.seed,
        );
        landscape_rows_built = next_record_index;

        let drift = 2 * config.repeats;
        size_results.push(TimingLaneSizeResult {
            haystack_size: target_size,
            haystack_drift_per_repeat: drift,
            background: background_result,
            impatient: impatient_result,
        });

        eprintln!(
            "[timing] checkpoint {} done (estate now ~{} rows)",
            target_size, landscape_rows_built
        );
    }

    // Disconnect + teardown.
    client.disconnect();
    timing_guarded_teardown(&scratch_dir);

    // Emit JSON report.
    let run_env = RunEnvironment::collect_with_run_mode(
        Some(&config.moot_binary_path.to_string_lossy()),
        &config.run_mode,
    );
    let report = TimingLaneReport {
        estate_schema_version: crate::artifact_manifest::CURRENT_ESTATE_SCHEMA_VERSION.to_string(),
        benchmark_protocol_version: "v0.1",
        run_environment: run_env,
        seed: config.seed,
        repeats: config.repeats,
        shape: "disk",
        estate_encryption: "plaintext-optout",
        results: size_results,
    };

    // `<test>-<arm>-<serial>`: the arm is the storage posture. The at-rest
    // difference between plaintext and encrypted is itself a reported figure,
    // so the two postures are separate records and must not share a name.
    // The Rust leg measures TIMING_POSTURE only (plaintext-optout); the Swift
    // leg carries both postures. Naming the arm from the constant keeps this
    // leg's records explicit about which posture they hold.
    let serial = match &config.run_id {
        Some(id) if !id.is_empty() => id.clone(),
        _ => crate::record_writer::resolve_run_serial(&[]),
    };
    let report_filename = crate::record_writer::record_filename(
        "timing",
        &format!("{TIMING_POSTURE:?}").to_lowercase(),
        &serial,
        "",
        "json",
    );
    let report_path = match &config.out_dir {
        Some(dir) => {
            std::fs::create_dir_all(dir)
                .map_err(|e| format!("timing: could not create out_dir: {e}"))?;
            dir.join(&report_filename)
        }
        None => PathBuf::from(&report_filename),
    };

    let json = serde_json::to_vec_pretty(&report)
        .map_err(|e| format!("timing: JSON encode failed: {e}"))?;
    std::fs::write(&report_path, &json)
        .map_err(|e| format!("timing: report write failed: {e}"))?;

    eprintln!("[timing] report written to {}", report_path.display());

    // A metric with no samples prints "n/a", never a number. The stderr
    // summary is what an operator reads first, so it must not imply a
    // measurement the report does not contain. Twin of Swift `fmt`.

    fn fmt(pair: &Option<TimingStatPair>) -> String {
        match pair {
            Some(p) => format!("p50={:.1}ms p95={:.1}ms", p.p50_ms, p.p95_ms),
            None => "n/a".to_string(),
        }
    }
    for result in &report.results {
        eprintln!(
            "[timing] size={:<6}  background accept {}  impatient accept {}",
            result.haystack_size,
            fmt(&result.background.accept_ms),
            fmt(&result.impatient.accept_ms),
        );
        eprintln!(
            "[timing]            background ingest {}  cycle_vector {}",
            fmt(&result.background.ingest_ms),
            fmt(&result.background.cycle_vector_ms),
        );
        eprintln!(
            "[timing]            background read {}",
            fmt(&result.background.read_ms),
        );
    }

    // ── Posture-equivalence loop ───────────────────────────────────────────
    // Provisions a fresh small estate (POSTURE_EQUIV_DEFAULT_ROWS rows,
    // POSTURE_EQUIV_DEFAULT_PROBES probes), converts it to an encrypted twin,
    // and compares ranked recall results exactly across both postures. A
    // divergence indicates that at-rest encryption changed retrieval ordering.
    //
    // Runs after the timing report is written and the timing summary is printed.
    // A failure here does NOT abort the timing run — the timing data is already
    // safe on disk. The equivalence artifact is a separate file.
    {
        use crate::posture_equivalence_runner::{
            PostureEquivConfig, POSTURE_EQUIV_DEFAULT_PROBES, POSTURE_EQUIV_DEFAULT_ROWS,
        };
        let equiv_config = PostureEquivConfig {
            moot_binary_path: config.moot_binary_path.clone(),
            seed: config.seed,
            row_count: POSTURE_EQUIV_DEFAULT_ROWS,
            probe_count: POSTURE_EQUIV_DEFAULT_PROBES,
            out_dir: config.out_dir.clone(),
            run_id: config.run_id.clone(),
        };
        if let Err(e) = crate::posture_equivalence_runner::run_posture_equivalence_loop(&equiv_config) {
            eprintln!(
                "[posture-equivalence] loop failed (timing report is unaffected): {}",
                e
            );
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_watermark_ms_standard() {
        let text = "timing report (audit-derived, since_ms=0):\n  \
                    ingest_exact: n=2000, p50=1ms, p95=3ms\n  \
                    watermark_ms: 98765\n";
        assert_eq!(parse_watermark_ms(text), 98765);
    }

    #[test]
    fn parse_watermark_ms_absent() {
        assert_eq!(parse_watermark_ms("no watermark here"), 0);
    }

    #[test]
    fn parse_timing_p50_ingest_exact() {
        let text = "  ingest_exact: n=1, p50=4ms, p95=4ms\n  \
                    cycle_vector: n=1, p50=12ms, p95=12ms\n  \
                    watermark_ms: 100\n";
        assert_eq!(parse_timing_p50_ms("ingest_exact:", text), Some(4.0));
        assert_eq!(parse_timing_p50_ms("cycle_vector:", text), Some(12.0));
        assert_eq!(parse_timing_p50_ms("cycle_novel:", text), None);
    }

    #[test]
    fn compute_stat_pair_basic() {
        let samples = vec![10.0, 20.0, 30.0, 40.0, 50.0];
        let pair = compute_stat_pair(&samples).expect("non-empty");
        // p50 = ceil(0.5 * 5) = 3rd sample (1-indexed) = index 2 = 30.0
        assert_eq!(pair.p50_ms, 30.0);
        // p95 = ceil(0.95 * 5) = 5th sample (1-indexed) = index 4 = 50.0
        assert_eq!(pair.p95_ms, 50.0);
    }

    #[test]
    fn compute_stat_pair_single() {
        let pair = compute_stat_pair(&[42.0]).expect("non-empty");
        assert_eq!(pair.p50_ms, 42.0);
        assert_eq!(pair.p95_ms, 42.0);
    }

    #[test]
    fn compute_stat_pair_empty() {
        // None, never (0, 0): a zeroed pair is indistinguishable from a real
        // measurement of zero, which is how an unmeasurable run published
        // four fabricated metrics.
        assert!(compute_stat_pair(&[]).is_none());
    }

    #[test]
    fn timing_lane_records_deterministic() {
        let a = timing_lane_records(0, 3, 42);
        let b = timing_lane_records(0, 3, 42);
        assert_eq!(a.len(), 3);
        for (ra, rb) in a.iter().zip(b.iter()) {
            assert_eq!(ra.id, rb.id);
            assert_eq!(ra.content, rb.content);
        }
        // Distinct seed → different content.
        let c = timing_lane_records(0, 3, 43);
        assert_ne!(a[0].id, c[0].id);
        // Cross-port golden pin: the Swift twin asserts this same id for
        // seed 42 record 0, so the two corpus generators cannot silently
        // diverge (truncating casts, rng constants, uuid bit layout).
        assert_eq!(a[0].id, "bdd73226-2feb-4e95-a8ef-e333b266f103");
    }

    #[test]
    fn timing_lane_records_unique_ids() {
        let records = timing_lane_records(0, 10, 99);
        let ids: std::collections::HashSet<&str> = records.iter().map(|r| r.id.as_str()).collect();
        assert_eq!(ids.len(), 10, "all IDs must be distinct");
    }
}
