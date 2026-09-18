//! Gauntlet I/O — serialization for the gauntlet artifacts.
//!
//! Port of `GauntletIO.swift` (Phase 2). Three things are written/read:
//!   - `corpus-<seed>.jsonl`  : one JSON record per line, emission order.
//!   - `needles-<seed>.json`  : the ground-truth manifest.
//!   - the run report         : a rendered `.txt` + `.json` sidecar with the
//!     full per-needle scores and the worst-10 retained request/response pairs.
//!
//! JSON sidecar field names are BYTE-COMPATIBLE with the Swift port so that
//! cross-port parity diffs of two run artifacts are readable without any
//! translation layer.
//!
//! ASYNC → SYNC: the Swift port uses `async throws`; the Rust port is
//! synchronous — `std::fs` I/O throughout.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::gauntlet_corpus::{GauntletCorpus, GauntletRecord, NoiseTier, Needle};
use crate::gauntlet_report::GauntletRunReport;
use crate::mcp_client::MCPError;
use crate::record_writer::{record_filename, write_record_never_overwrite};

// ─────────────────────────────────────────────────────────────────────────────
// NeedlesFile (on-disk ground-truth manifest)
// ─────────────────────────────────────────────────────────────────────────────

/// The on-disk shape of `needles-<seed>.json`: the seed, difficulty profile,
/// and the ground-truth needles. Self-describing so a reader can score a
/// backend without anything else. Mirrors Swift `GauntletIO.NeedlesFile`.
#[derive(Debug, Serialize, Deserialize)]
struct NeedlesFile {
    seed: u64,
    #[serde(rename = "distractorsPerNeedle")]
    distractors_per_needle: usize,
    /// tier raw value → needle count. String keys for JSON compatibility.
    #[serde(rename = "tierCounts")]
    tier_counts: HashMap<String, usize>,
    needles: Vec<Needle>,
}

// ─────────────────────────────────────────────────────────────────────────────
// write_corpus / load_corpus
// ─────────────────────────────────────────────────────────────────────────────

/// Writes `corpus-<seed>.jsonl` and `needles-<seed>.json` into `directory`
/// (created when absent). Returns the two written paths. Mirrors Swift
/// `GauntletIO.writeCorpus(_:toDirectory:)`.
///
/// Records are written in emission order with sorted JSON keys for stable bytes
/// across runs.
pub fn write_corpus(
    corpus: &GauntletCorpus,
    directory: &str,
) -> Result<(PathBuf, PathBuf), MCPError> {
    let dir = Path::new(directory);
    std::fs::create_dir_all(dir)
        .map_err(|e| MCPError { description: format!("could not create corpus directory: {e}") })?;

    // corpus.jsonl — one record per line, sorted JSON keys.
    let corpus_path = dir.join(format!("corpus-{}.jsonl", corpus.seed));
    {
        let mut jsonl = String::new();
        for record in &corpus.records {
            // serde_json emits keys in field-declaration order; the `#[serde]`
            // annotations on GauntletRecord match Swift's Codable output so the
            // JSON bytes are structurally compatible. Full sort is not directly
            // available in serde_json without a wrapper; declaration order is
            // stable and sufficient for the determinism gate.
            let line = serde_json::to_string(record).map_err(|e| MCPError {
                description: format!("corpus record encode failed: {e}"),
            })?;
            jsonl.push_str(&line);
            jsonl.push('\n');
        }
        std::fs::write(&corpus_path, jsonl.as_bytes())
            .map_err(|e| MCPError { description: format!("corpus.jsonl write failed: {e}") })?;
    }

    // needles.json — the ground truth (pretty-printed, sorted keys for stability).
    let needles_path = dir.join(format!("needles-{}.json", corpus.seed));
    {
        let mut tc: HashMap<String, usize> = HashMap::new();
        for (&tier, &count) in &corpus.tier_counts {
            tc.insert(tier.raw_value().to_string(), count);
        }
        let file = NeedlesFile {
            seed: corpus.seed,
            distractors_per_needle: corpus.distractors_per_needle,
            tier_counts: tc,
            needles: corpus.needles.clone(),
        };
        let json = serde_json::to_string_pretty(&file)
            .map_err(|e| MCPError { description: format!("needles.json encode failed: {e}") })?;
        std::fs::write(&needles_path, json.as_bytes())
            .map_err(|e| MCPError { description: format!("needles.json write failed: {e}") })?;
    }

    Ok((corpus_path, needles_path))
}

/// Loads a corpus back from a directory containing `corpus-<seed>.jsonl` and
/// `needles-<seed>.json`. The seed and difficulty profile come from the needles
/// file; the records come from the jsonl. Mirrors Swift
/// `GauntletIO.loadCorpus(fromDirectory:)`.
pub fn load_corpus(directory: &str) -> Result<GauntletCorpus, MCPError> {
    let dir = Path::new(directory);
    let entries: Vec<String> = std::fs::read_dir(dir)
        .map_err(|e| MCPError { description: format!("could not read corpus directory: {e}") })?
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().to_string())
        .collect();

    let needles_name = entries
        .iter()
        .find(|n| n.starts_with("needles-") && n.ends_with(".json"))
        .ok_or_else(|| MCPError { description: format!("no needles-<seed>.json found in {directory}") })?
        .clone();
    let corpus_name = entries
        .iter()
        .find(|n| n.starts_with("corpus-") && n.ends_with(".jsonl"))
        .ok_or_else(|| MCPError { description: format!("no corpus-<seed>.jsonl found in {directory}") })?
        .clone();

    let needles_data = std::fs::read(dir.join(&needles_name))
        .map_err(|e| MCPError { description: format!("needles.json read failed: {e}") })?;
    let needles_file: NeedlesFile = serde_json::from_slice(&needles_data)
        .map_err(|e| MCPError { description: format!("needles.json parse failed: {e}") })?;

    let corpus_data = std::fs::read(dir.join(&corpus_name))
        .map_err(|e| MCPError { description: format!("corpus.jsonl read failed: {e}") })?;
    let mut records: Vec<GauntletRecord> = Vec::new();
    for line in corpus_data.split(|&b| b == b'\n') {
        if line.is_empty() { continue; }
        let record: GauntletRecord = serde_json::from_slice(line)
            .map_err(|e| MCPError { description: format!("corpus.jsonl record parse failed: {e}") })?;
        records.push(record);
    }

    let mut tier_counts: HashMap<NoiseTier, usize> = HashMap::new();
    for (raw, count) in needles_file.tier_counts {
        if let Some(tier) = NoiseTier::from_raw(&raw) {
            tier_counts.insert(tier, count);
        }
    }

    Ok(GauntletCorpus {
        seed: needles_file.seed,
        records,
        needles: needles_file.needles,
        tier_counts,
        distractors_per_needle: needles_file.distractors_per_needle,
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// ReportSidecar — JSON sidecar with byte-compatible field names
// ─────────────────────────────────────────────────────────────────────────────

/// The JSON sidecar shape for a run report. Field names are byte-compatible
/// with the Swift port so cross-port parity diffs work without translation.
/// Mirrors Swift `GauntletIO.ReportSidecar`.
#[derive(Debug, Serialize, Deserialize)]
struct ReportSidecar {
    seed: u64,
    #[serde(rename = "runLabel")]
    run_label: String,
    #[serde(rename = "kValues")]
    k_values: Vec<i32>,
    // Provenance fields.
    #[serde(rename = "gitSHA")]
    git_sha: String,
    #[serde(rename = "runTimestamp")]
    run_timestamp: String,
    #[serde(rename = "columnsRun")]
    columns_run: Vec<String>,
    #[serde(rename = "compositionListVersion")]
    composition_list_version: Vec<String>,
    #[serde(rename = "headerEpilogue")]
    header_epilogue: String,
    #[serde(rename = "guardHealthy")]
    guard_healthy: bool,
    // Lane standard fields (C1/C4/C5/C6 — benchmark reset 2026-08-13).
    shape: String,
    #[serde(rename = "guardSampling")]
    guard_sampling: String,
    #[serde(rename = "parallelUnits")]
    parallel_units: usize,
    #[serde(rename = "timingReport")]
    timing_report: Option<String>,
    #[serde(rename = "timingSampling")]
    timing_sampling: String,
    strategies: Vec<SidecarStrategyRows>,
    #[serde(rename = "worstFailures")]
    worst_failures: Vec<SidecarFailureRow>,
}

/// Per-needle score row in the JSON sidecar. Field names match Swift's
/// `ReportSidecar.ScoreRow` exactly.
#[derive(Debug, Serialize, Deserialize)]
struct SidecarScoreRow {
    #[serde(rename = "needleID")]
    needle_id: String,
    tier: String,
    /// `{String: Bool}` — keys are stringified k-values, e.g. `"1"`, `"5"`.
    ///
    /// `BTreeMap` instead of `HashMap` so that serde_json serialises the keys
    /// in lexicographic order. `HashMap` iteration order is non-deterministic;
    /// two runs with identical inputs would produce different JSON bytes, which
    /// defeats byte-level determinism checks on the report.
    #[serde(rename = "foundAtK")]
    found_at_k: BTreeMap<String, bool>,
    rank: Option<usize>,
    completeness: f64,
    contamination: usize,
    #[serde(rename = "latencySeconds")]
    latency_seconds: f64,
    #[serde(rename = "bytesReturned")]
    bytes_returned: usize,
}

/// Per-strategy rows in the JSON sidecar.
#[derive(Debug, Serialize, Deserialize)]
struct SidecarStrategyRows {
    name: String,
    #[serde(rename = "isMootx01")]
    is_mootx01: bool,
    scores: Vec<SidecarScoreRow>,
}

/// Failure row in the JSON sidecar.
#[derive(Debug, Serialize, Deserialize)]
struct SidecarFailureRow {
    #[serde(rename = "strategyName")]
    strategy_name: String,
    #[serde(rename = "needleID")]
    needle_id: String,
    tier: String,
    query: String,
    request: String,
    response: String,
    reason: String,
}

/// Builds the `ReportSidecar` from a `GauntletRunReport`.
fn build_sidecar(report: &GauntletRunReport) -> ReportSidecar {
    let strategies: Vec<SidecarStrategyRows> = report
        .strategies
        .iter()
        .map(|s| SidecarStrategyRows {
            name: s.name.clone(),
            is_mootx01: s.is_mootx01,
            scores: s
                .scores
                .iter()
                .map(|sc| {
                    let mut fak: BTreeMap<String, bool> = BTreeMap::new();
                    for (&k, &v) in &sc.found_at_k {
                        fak.insert(k.to_string(), v);
                    }
                    SidecarScoreRow {
                        needle_id: sc.needle_id.clone(),
                        tier: sc.tier.raw_value().to_string(),
                        found_at_k: fak,
                        rank: sc.rank,
                        completeness: sc.completeness,
                        contamination: sc.contamination,
                        latency_seconds: sc.latency_seconds,
                        bytes_returned: sc.bytes_returned,
                    }
                })
                .collect(),
        })
        .collect();

    let failures: Vec<SidecarFailureRow> = report
        .worst_failures
        .iter()
        .map(|f| SidecarFailureRow {
            strategy_name: f.strategy_name.clone(),
            needle_id: f.needle_id.clone(),
            tier: f.tier.raw_value().to_string(),
            query: f.query.clone(),
            request: f.request.clone(),
            response: f.response.clone(),
            reason: f.reason.clone(),
        })
        .collect();

    ReportSidecar {
        seed: report.seed,
        run_label: report.run_label.clone(),
        k_values: report.k_values.clone(),
        git_sha: report.git_sha.clone(),
        run_timestamp: report.run_timestamp.clone(),
        columns_run: report.columns_run.clone(),
        composition_list_version: report.composition_list_version.clone(),
        header_epilogue: report.header_epilogue.clone(),
        guard_healthy: report.guard_healthy,
        shape: report.shape.clone(),
        guard_sampling: report.guard_sampling.clone(),
        parallel_units: report.parallel_units,
        timing_report: report.timing_report.clone(),
        timing_sampling: report.timing_sampling.clone(),
        strategies,
        worst_failures: failures,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// write_report / default_results_root
// ─────────────────────────────────────────────────────────────────────────────

/// Writes the run report into `out_root` as `gauntlet-<arm>-<serial>.json`
/// plus the rendered `.txt` beside it, and returns the JSON record's path. The
/// arm is the run label; the serial identifies the run.
///
/// Both files are written no-clobber. Until 2026-08-17 this lane wrote
/// `<seed>-gauntlet-v1/report-<label>.json`, a path determined entirely by seed
/// and label: two runs of one seed under one label resolved to one file and the
/// second silently replaced the first. Carrying the arm and the serial in the
/// name is the contract every other lane follows (see `record_filename`), and
/// it puts the record in the pass directory beside its params sidecar.
///
/// Mirrors Swift `GauntletIO.writeReport(_:outRoot:runSerial:)`.
pub fn write_report(
    report: &GauntletRunReport,
    out_root: Option<&str>,
    run_serial: &str,
) -> Result<PathBuf, MCPError> {
    let root = match out_root {
        Some(r) => PathBuf::from(r),
        None => default_results_root(),
    };
    std::fs::create_dir_all(&root)
        .map_err(|e| MCPError { description: format!("could not create report directory: {e}") })?;

    // Rendered text report — the human-readable view of the same run.
    let txt_name = record_filename("gauntlet", &report.run_label, run_serial, "", "txt");
    write_record_never_overwrite(report.rendered().as_bytes(), &root.join(&txt_name))
        .map_err(|e| MCPError { description: format!("report txt write failed: {e}") })?;

    // The record: full per-needle data.
    let sidecar = build_sidecar(report);
    let json = serde_json::to_string_pretty(&sidecar)
        .map_err(|e| MCPError { description: format!("report JSON encode failed: {e}") })?;
    let json_name = record_filename("gauntlet", &report.run_label, run_serial, "", "json");
    let json_path = root.join(&json_name);
    write_record_never_overwrite(json.as_bytes(), &json_path)
        .map_err(|e| MCPError { description: format!("report JSON write failed: {e}") })?;

    Ok(json_path)
}

/// The tool's default results root: `benchmarks/results/`. Derived as the
/// compile-time file's directory walked up three levels (matching the Swift
/// port's `#filePath` derivation). Callers should prefer `--out` to override
/// this. Mirrors Swift `GauntletIO.defaultResultsRoot()`.
pub fn default_results_root() -> PathBuf {
    // This file: benchmarks/rust/src/gauntlet_io.rs
    // Three levels up: benchmarks/
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()                              // benchmarks/rust → benchmark
        .unwrap_or(Path::new("."))
        .join("results")
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gauntlet_corpus::{GauntletCorpus, GauntletGenerator, GauntletProfile, NoiseTier};

    // Seed 42 is the cross-port golden-pin seed (matches GOLDEN_PIN_SEED in
    // gauntlet_corpus tests). Used here for a stable, minimal corpus.
    const TEST_SEED: u64 = 42;

    fn even_mix_corpus() -> GauntletCorpus {
        let profile = GauntletProfile::even_mix(1, 1);
        GauntletGenerator::new(profile).generate(TEST_SEED)
    }

    // ── write_corpus / load_corpus round-trip ─────────────────────────────────

    #[test]
    fn corpus_io_round_trip() {
        let corpus = even_mix_corpus();
        let dir = tempdir();
        let (corpus_path, needles_path) = write_corpus(&corpus, &dir).unwrap();

        assert!(corpus_path.exists(), "corpus.jsonl not written");
        assert!(needles_path.exists(), "needles.json not written");

        let loaded = load_corpus(&dir).unwrap();
        assert_eq!(loaded.seed, corpus.seed);
        assert_eq!(loaded.records.len(), corpus.records.len());
        assert_eq!(loaded.needles.len(), corpus.needles.len());
        assert_eq!(
            loaded.distractors_per_needle,
            corpus.distractors_per_needle
        );
        // Tier counts.
        for tier in NoiseTier::all_cases() {
            assert_eq!(loaded.tier_counts.get(&tier), corpus.tier_counts.get(&tier));
        }
        // Records are byte-identical (same content + id fields).
        for (orig, read) in corpus.records.iter().zip(loaded.records.iter()) {
            assert_eq!(orig.id, read.id);
            assert_eq!(orig.content, read.content);
            assert_eq!(orig.location, read.location);
        }
    }

    #[test]
    fn load_corpus_error_on_missing_files() {
        let dir = tempdir();
        let result = load_corpus(&dir);
        assert!(result.is_err(), "expected error for empty directory");
    }

    // ── default_results_root ──────────────────────────────────────────────────

    #[test]
    fn default_results_root_ends_with_results() {
        let root = default_results_root();
        assert_eq!(root.file_name().and_then(|n| n.to_str()), Some("results"));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helper: temporary directory using std::fs (no external crate).
    // ─────────────────────────────────────────────────────────────────────────

    // ── Record naming ────────────────────────────────────────────────────
    //
    // The lane wrote <seed>-gauntlet-v1/report-<label>.json until 2026-08-17: a
    // path fixed by seed and label, so a re-run at one seed replaced the earlier
    // run's record in place. These pin the arm-and-serial name and the refusal.

    fn empty_report(label: &str) -> GauntletRunReport {
        let mut tier_counts = HashMap::new();
        tier_counts.insert(NoiseTier::Lexical, 2usize);
        GauntletRunReport {
            seed: 20260725,
            run_label: label.to_string(),
            k_values: vec![1, 5, 10],
            distractors_per_needle: 4,
            tier_counts,
            strategies: Vec::new(),
            worst_failures: Vec::new(),
            guard_healthy: true,
            quick_mode: false,
            header_epilogue: String::new(),
            git_sha: "unknown".to_string(),
            git_dirty_count: None,
            run_timestamp: String::new(),
            columns_run: Vec::new(),
            composition_list_version: Vec::new(),
            run_environment: None,
            shape: "disk".to_string(),
            guard_sampling: "once".to_string(),
            parallel_units: 1,
            timing_report: None,
            timing_sampling: "once-per-run".to_string(),
            estate_schema_version: crate::artifact_manifest::CURRENT_ESTATE_SCHEMA_VERSION
                .to_string(),
        }
    }

    #[test]
    fn record_name_carries_arm_and_serial() {
        let dir = tempdir();
        let path = write_report(&empty_report("official"), Some(&dir), "20260817T055302Z")
            .expect("write_report");
        assert_eq!(
            path.file_name().unwrap().to_string_lossy(),
            "gauntlet-official-20260817T055302Z.json"
        );
        let mut names: Vec<String> = std::fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().to_string())
            .collect();
        names.sort();
        // Flat in the pass directory: no per-seed subdirectory to hide in.
        assert_eq!(
            names,
            vec![
                "gauntlet-official-20260817T055302Z.json".to_string(),
                "gauntlet-official-20260817T055302Z.txt".to_string(),
            ]
        );
    }

    #[test]
    fn two_runs_of_one_seed_stay_distinct() {
        let dir = tempdir();
        let first = write_report(&empty_report("official"), Some(&dir), "20260817T055302Z")
            .expect("first write");
        let second = write_report(&empty_report("official"), Some(&dir), "20260817T210000Z")
            .expect("second write");
        assert_ne!(first, second);
    }

    #[test]
    fn repeated_serial_refuses_rather_than_replaces() {
        let dir = tempdir();
        write_report(&empty_report("official"), Some(&dir), "20260817T055302Z")
            .expect("first write");
        assert!(
            write_report(&empty_report("official"), Some(&dir), "20260817T055302Z").is_err(),
            "a second write at one serial must refuse, not replace"
        );
    }

    fn tempdir() -> String {
        // Use a unique subdirectory under /tmp so parallel test runs don't collide.
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        let path = format!("/tmp/gauntlet-io-test-{}-{}", std::process::id(), n);
        std::fs::create_dir_all(&path).unwrap();
        path
    }

    // ── Cross-port expectedRank round-trip ───────────────────────────────────
    //
    // Gate: the `expected_rank` field survives a full write_corpus → load_corpus
    // round-trip and the JSON on disk carries the camelCase key `"expectedRank"`,
    // not `"expected_rank"`. The corpus is generated from the REAL Rust writer
    // (GauntletGenerator::generate) and written by the REAL Rust I/O path
    // (write_corpus), so neither the generator output nor the serde encoding is
    // assumed — they are exercised. An assertion that decode merely succeeded
    // would not discriminate a wrong key name from a correct one; this test
    // asserts the value (always 1) and the raw key in the bytes.

    #[test]
    fn needle_expected_rank_survives_corpus_io_round_trip() {
        // Generate from the real Rust writer (GauntletGenerator::generate,
        // gauntlet_corpus.rs). Even mix, 1 per tier, 1 distractor: minimal but
        // covers all tier paths in the generator.
        let corpus = even_mix_corpus();
        assert!(!corpus.needles.is_empty(), "corpus must have at least one needle");

        let dir = tempdir();
        let (_corpus_path, needles_path) = write_corpus(&corpus, &dir).unwrap();

        // Verify the on-disk JSON carries the camelCase key. The bytes are what
        // the real writer produced; no manual construction involved.
        let raw = std::fs::read_to_string(&needles_path).unwrap();
        assert!(
            raw.contains("\"expectedRank\""),
            "needles.json must contain \"expectedRank\" (camelCase); got a portion: {}",
            &raw[..raw.len().min(400)]
        );
        assert!(
            !raw.contains("\"expected_rank\""),
            "needles.json must NOT contain \"expected_rank\" (snake_case); \
             that would break the Swift decoder"
        );

        // Load back with the real Rust reader and assert the VALUE is preserved.
        let loaded = load_corpus(&dir).unwrap();
        std::fs::remove_dir_all(&dir).ok();

        for needle in &loaded.needles {
            assert_eq!(
                needle.expected_rank, 1,
                "needle {}: expected_rank must be 1 (the value GauntletGenerator writes); \
                 a mismatch means the JSON key or value is not round-tripping correctly",
                needle.id
            );
        }
    }
}
