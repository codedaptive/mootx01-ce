//! Gauntlet runner — drives a full gauntlet run against live scratch backends.
//!
//! Port of `GauntletRunner.swift` (Phase 2.2). Loads the corpus into the moot
//! backend, dreams the estate, enforces the DegeneracyGuard, scores every
//! needle under every column, and assembles the report.
//!
//! ASYNC → SYNC ASYMMETRY (documented, not approximated):
//!   The Swift runner is `async` throughout, using `Task` for concurrent
//!   baseline + moot loading. The Rust port uses the synchronous `MCPClient`
//!   with a blocking `ToolCaller` trait — concurrent loading becomes sequential.
//!   This is a documented asymmetry between the ports, not a defect: the Rust
//!   leg ships the synchronous transport at parity; async actors are an
//!   Apple-platform concern. Performance is equivalent because the gauntlet's
//!   single-estate design serialises queries anyway, and load time is dominated
//!   by the batch import (one MCP call) rather than the wall-clock difference
//!   between concurrent and sequential load.
//!
//! MOOT-ONLY CORE: the runner is moot-only (no injected baseline). A two-endpoint
//! Rust lane can be built by an extension crate that passes a second MCPClient
//! through a wrapper struct — the same injection pattern as Swift's
//! `GauntletBaseline`. Core never names a concrete baseline product.

use std::collections::BTreeMap;
use std::time::Instant;

use crate::config::{EndpointConfig, EndpointRole, ResultFormat, Transport, VerbMap};
use crate::degeneracy_guard::{DegeneracyGuard, Verdict};
use crate::encode_barrier::wait_for_encode_drain;
use crate::gauntlet_corpus::{GauntletCorpus, GauntletRecord, Needle};
use crate::gauntlet_report::{GauntletRunReport, RetainedFailure, StrategyResult};
use crate::gauntlet_scorer::{GauntletScorer, NeedleScore, ScoredItem};
use crate::json_value::JsonValue;
use crate::mcp_client::{MCPClient, MCPError, ToolCaller};
use crate::mcp_result::normalized_content_order;
use crate::seed_export::{
    emit_seed_json, write_seed_file, SeedFileRecord, SeedPathMode, synthetic_event_time,
};
use crate::timing_capture::fetch_timing_report;

// ─────────────────────────────────────────────────────────────────────────────
// Scratch-backend safety gate
// ─────────────────────────────────────────────────────────────────────────────

/// Requirement that a benchmark endpoint's stdio command must satisfy.
/// Twin of Swift `ScratchRequirement`.
///
/// Single-case by design: `Flag` covers the only requirement variant in use
/// (`--db /tmp/...`), and the enum is the extension point if new constraint
/// kinds are added. Preserving the enum (rather than inlining the string)
/// keeps the Swift and Rust call signatures in twin parity —
/// `assert_scratch_backend(endpoint, requirement)` reads identically in both
/// ports regardless of how many cases the enum eventually carries.
#[derive(Debug)]
pub enum ScratchRequirement {
    /// The command must pass this flag with a following `/tmp/...` path token.
    Flag(&'static str),
}

/// The moot endpoint's scratch requirement: `--db` pointing at a `/tmp`
/// directory, which attaches a transient record. Twin of Swift
/// `mootScratchRequirement`.
pub const MOOT_SCRATCH_REQUIREMENT: ScratchRequirement =
    ScratchRequirement::Flag(crate::scratch_posture::MOOT_SERVE_DATABASE_FLAG);

/// Asserts that `endpoint`'s stdio command satisfies the scratch requirement.
/// Panics (aborting before any write) when the required flag is absent or its
/// path is not under `/tmp`. The `/tmp` prefix is the contamination guard that
/// keeps the gauntlet off any real (non-scratch) data store.
///
/// Twin of Swift `assertScratchBackend(_:requirement:)` in `GauntletCLI.swift`.
pub fn assert_scratch_backend(endpoint: &EndpointConfig, requirement: &ScratchRequirement) {
    let Transport::Stdio { command } = &endpoint.transport else {
        panic!(
            "[gauntlet] FATAL: gauntlet requires stdio backends; '{}' is not stdio",
            endpoint.name
        )
    };
    match requirement {
        ScratchRequirement::Flag(flag) => {
            assert!(
                command.contains(flag),
                "[gauntlet] FATAL: backend '{}' must use the {} FLAG (never a bare env var); \
                 refusing to write. command={command}",
                endpoint.name,
                flag
            );
            assert!(
                scratch_path_is_tmp(flag, command),
                "[gauntlet] FATAL: backend '{}' {} must point at a /tmp scratch path; \
                 refusing to write. command={command}",
                endpoint.name,
                flag
            );
        }
    }
}

/// True when the token following `flag` in the whitespace-split command begins
/// with `/tmp` or a path below it. Twin of Swift `scratchPathIsTmp(afterFlag:in:)`.
///
/// Accepts both `/tmp/…` (the logical path) and its canonical form (e.g.
/// `/private/tmp/…` on macOS, where `/tmp` is a symlink). Uses
/// `canonical_tmp_base()` for the same reason `membench_scratch_dir` does —
/// a literal `/tmp` prefix check rejected every legitimate path (Wave-3 G3).
pub fn scratch_path_is_tmp(flag: &str, command: &str) -> bool {
    let parts: Vec<&str> = command.split_ascii_whitespace().collect();
    let Some(i) = parts.iter().position(|t| *t == flag) else { return false };
    let Some(path) = parts.get(i + 1) else { return false };
    // Accept the logical "/tmp" prefix (as typed by the scratch-dir helpers).
    let logical_ok = *path == "/tmp" || path.starts_with("/tmp/");
    if logical_ok { return true; }
    // Accept the canonical form (e.g. "/private/tmp/" on macOS).
    let canonical_base = crate::config::canonical_tmp_base();
    let canonical_str = canonical_base.to_string_lossy();
    let canonical_exact = canonical_str.as_ref() == *path;
    let canonical_prefix = {
        let prefix = if canonical_str.ends_with('/') {
            canonical_str.into_owned()
        } else {
            format!("{}/", canonical_str)
        };
        path.starts_with(prefix.as_str())
    };
    canonical_exact || canonical_prefix
}

// ─────────────────────────────────────────────────────────────────────────────
// MootScoring
// ─────────────────────────────────────────────────────────────────────────────

/// A mootx01 `moot_memory_search` scoring strategy. The raw value is the
/// `scoring` MCP argument. Mirrors Swift `MootScoring`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MootScoring {
    Raw,
    Rrf,
    MatrixAware,
}

impl MootScoring {
    pub fn all_cases() -> [MootScoring; 3] {
        [MootScoring::Raw, MootScoring::Rrf, MootScoring::MatrixAware]
    }

    /// The `scoring` MCP argument value. Mirrors Swift `rawValue`.
    pub fn raw_value(self) -> &'static str {
        match self {
            MootScoring::Raw         => "raw",
            MootScoring::Rrf         => "rrf",
            MootScoring::MatrixAware => "matrixAware",
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// GauntletColumn
// ─────────────────────────────────────────────────────────────────────────────

/// One backend column the runner evaluates. Mirrors Swift `GauntletColumn`.
///
/// Three column kinds:
///   1. An injected baseline backend's search (`is_mootx01 == false`).
///   2. mootx01 `moot_memory_search` under a named scoring strategy.
///   3. mootx01 `moot_recall_precise` under a named reduction composition.
#[derive(Debug, Clone)]
pub struct GauntletColumn {
    pub name: String,
    pub is_mootx01: bool,
    /// The `moot_memory_search` scoring strategy, when this is a search column.
    pub scoring: Option<MootScoring>,
    /// The named reduction composition, when this is a precise-recall ablation
    /// column. Mutually exclusive with `scoring`.
    pub composition: Option<String>,
}

impl GauntletColumn {
    /// True when this column calls `moot_recall_precise` rather than
    /// `moot_memory_search`. Mirrors Swift `usesPreciseTool`.
    pub fn uses_precise_tool(&self) -> bool {
        self.composition.is_some()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

/// The PreciseRecall recipe tool exposed by ARIA_MCP. Mirrors Swift
/// `GauntletRunner.preciseRecallToolName`.
pub const PRECISE_RECALL_TOOL_NAME: &str = crate::aria_v2_surface::RECALL_PRECISE;

/// Fixed ISO8601 instant the gauntlet dreams at so the dreaming cycle is
/// reproducible run-to-run alongside the rest of the deterministic harness.
/// Mirrors Swift `GauntletRunner.dreamInstant`.
pub const DREAM_INSTANT: &str = "2026-06-11T00:00:00Z";

/// Coarse-pool width requested for every precise-recall (composition) column.
/// Wide enough to admit the whole searchable frontier of a gauntlet corpus so
/// the precise pool MEMBERSHIP is stable run-to-run. The backend clamps to the
/// available candidates, so an over-wide value is harmless. Mirrors Swift
/// `GauntletRunner.precisePoolWidth`.
pub const PRECISE_POOL_WIDTH: usize = 500;

/// The reduction-ablation grid: one column per named composition through
/// `moot_recall_precise`. Names MUST match `NeuronKit.CompositionGrid.all`
/// (the executor side) exactly. The `CompositionGridSyncTests` documents the
/// expected set; if the kit grid changes, update this list and that test.
/// Mirrors Swift `GauntletRunner.compositionNames`.
pub const COMPOSITION_NAMES: &[&str] = &[
    "text", "hamming", "matrix", "lattice", "tokenExact", "bm25",
    // "vector" removed: probe-verified byte-identical to "hamming".
    // GLK's RecallScoreVector.vector IS normalized Hamming similarity —
    // one lane, two names. "dense-fused" (below) is the TRUE float lane
    // that replaces the removed "vector" alias: cosine over the pooled
    // float embedding (Lane D), not the lossy 256-bit SimHash projection.
    "hamming+tokenExact", "hamming+text", "text+matrix", "lattice+hamming",
    "text+tokenExact", "text+mmr",
    // T3 temporal (current-over-superseded), T4 assembly (split-fact
    // expansion), T5 association (matrix-weighted) — the structural signals.
    "temporalState", "temporalText", "temporal", "text+temporal",
    "text+assembly", "tokenExact+assembly",
    "matrix-weighted", "matrix+hamming",
    // T2/T5 semantic: the TRUE float-embedding dense lane (cosine over the
    // pooled vector), the dense column W6 removed when it deleted the
    // "vector" alias. Ranks an answer above a near-duplicate of the question.
    "dense-fused",
    "weighted-all",
];

// ─────────────────────────────────────────────────────────────────────────────
// columns() helper
// ─────────────────────────────────────────────────────────────────────────────

/// Every column evaluated, in fixed order: (optional baseline), three
/// `moot_memory_search` strategy columns, then the composition ablation grid.
/// Mirrors Swift `GauntletRunner.columns(baselineName:)`.
pub fn columns(baseline_name: Option<&str>) -> Vec<GauntletColumn> {
    let mut cols: Vec<GauntletColumn> = Vec::new();
    if let Some(name) = baseline_name {
        cols.push(GauntletColumn {
            name: name.to_string(),
            is_mootx01: false,
            scoring: None,
            composition: None,
        });
    }
    for s in MootScoring::all_cases() {
        cols.push(GauntletColumn {
            name: format!("mootx01:{}", s.raw_value()),
            is_mootx01: true,
            scoring: Some(s),
            composition: None,
        });
    }
    for &comp in COMPOSITION_NAMES {
        cols.push(GauntletColumn {
            name: format!("precise:{}", comp),
            is_mootx01: true,
            scoring: None,
            composition: Some(comp.to_string()),
        });
    }
    cols
}

// ─────────────────────────────────────────────────────────────────────────────
// GauntletRunner
// ─────────────────────────────────────────────────────────────────────────────

/// Configuration for one gauntlet run. Mirrors Swift `GauntletRunner`.
pub struct GauntletRunConfig {
    pub moot_verb_map: VerbMap,
    pub corpus: GauntletCorpus,
    pub scorer: GauntletScorer,
    pub run_label: String,
    /// Max results per query (must be ≥ deepest k so found@k is observable).
    pub search_limit: usize,
    /// When true, skip the moot load + dream (use persisted estate).
    pub reuse_moot: bool,
    /// When true, skip the precise-recall composition columns (~25 min savings).
    pub quick_mode: bool,
    /// How the mootx01 estate is seeded (batch = default).
    pub seed_path: SeedPathMode,
    /// Scratch directory for the batch seed file. Required when
    /// `seed_path == Batch && !reuse_moot`.
    pub scratch_dir: Option<String>,
    /// Load-marker file path beside the moot backend's data (for reuse logic).
    pub moot_marker: Option<String>,
}

/// Thrown when the DegeneracyGuard refuses a backend. Mirrors Swift
/// `GauntletGuardRefusal`.
#[derive(Debug)]
pub struct GauntletGuardRefusal {
    pub backend: String,
    pub diagnostic: String,
}

impl std::fmt::Display for GauntletGuardRefusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "[DegeneracyGuard] REFUSED gauntlet for '{}': {}",
            self.backend, self.diagnostic
        )
    }
}

/// Runs a full gauntlet against a live moot backend. Returns a
/// `GauntletRunReport` on success, `GauntletGuardRefusal` when the
/// DegeneracyGuard refuses the backend.
///
/// ASYNC → SYNC: this function is synchronous; the Swift equivalent is async.
/// See the module-level doc for the rationale.
pub fn run_gauntlet(
    client: &mut MCPClient,
    config: &GauntletRunConfig,
) -> Result<GauntletRunReport, Box<dyn std::error::Error>> {
    let corpus = &config.corpus;
    let scorer = &config.scorer;
    let verb_map = &config.moot_verb_map;

    // ── 1. LOAD ────────────────────────────────────────────────────────────
    // Load the corpus into the moot backend via the chosen seed path — UNLESS
    // the backend already holds this corpus (reuse_moot). The baseline column
    // is always live in the Swift port; in the Rust moot-only core there is no
    // baseline to load.
    if !config.reuse_moot {
        load_corpus_into_moot(client, corpus, verb_map, config)?;
        // Write the reuse marker after a fresh load so the next run can reuse.
        if let Some(marker_path) = &config.moot_marker {
            write_load_marker(marker_path, corpus.seed, corpus.records.len());
        }
    } else {
        eprintln!(
            "gauntlet: reusing persisted mootx01 estate — mootx01 load + dream skipped."
        );
    }

    // ── 1b. DREAM ─────────────────────────────────────────────────────────
    // Dream the estate once after load so the matrix recall lanes carry signal.
    // Skipped when reuse_moot is active (the matrix persists across restarts).
    if !config.reuse_moot {
        dream_moot_estate(client, verb_map)?;
    }

    // ── C4: capture timing report ─────────────────────────────────────────
    // Capture moot_timing_report immediately after the estate is settled (after
    // load + dream, before needle scoring). Errors are swallowed into None
    // so a missing tool never aborts the run.
    let captured_timing_report: Option<String> = fetch_timing_report(client);

    // ── 2. GUARD ──────────────────────────────────────────────────────────
    // Probe the moot backend with ≥3 distinct needle queries and enforce the
    // DegeneracyGuard. A non-healthy verdict returns GauntletGuardRefusal.
    // C5: the guard runs once per run (structurally once-per-run — one shared
    // estate, so there is no per-unit sampling decision).
    let guard = DegeneracyGuard::new();
    let probes = guard_probes(&corpus.needles);
    let mut moot_rankings: Vec<Vec<String>> = Vec::new();
    for q in &probes {
        let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
        args.insert(verb_map.query_arg.clone(), JsonValue::String(q.clone()));
        args.insert("limit".to_string(), JsonValue::Number(config.search_limit as f64));
        let result = client.call_tool(&verb_map.query, args, &verb_map.result_format)?;
        // result.items is Vec<MCPResultItem>; pass it directly to normalized_content_order.
        moot_rankings.push(normalized_content_order(&result.items));
    }
    let moot_verdict = guard.classify(&moot_rankings);
    if !matches!(moot_verdict, Verdict::Healthy) {
        return Err(Box::new(GauntletGuardRefusal {
            backend: "mootx01".to_string(),
            diagnostic: moot_verdict.diagnostic().to_string(),
        }));
    }

    // ── 3. SCORE ──────────────────────────────────────────────────────────
    // Score every needle under every column. Serial: the gauntlet reuses one
    // mootx01 process and one MCP connection for the entire run. C6: parallel
    // units stays 1 (concurrent MCP calls to a single stdio connection are not
    // safe, and spawning per-column processes defeats the single-estate design).
    let all_columns = columns(None); // moot-only core
    let run_columns: Vec<&GauntletColumn> = if config.quick_mode {
        all_columns.iter().filter(|c| !c.uses_precise_tool()).collect()
    } else {
        all_columns.iter().collect()
    };
    if config.quick_mode {
        eprintln!(
            "QUICK MODE — precise ablation grid skipped (composition columns omitted)"
        );
    }

    let mut strategy_results: Vec<StrategyResult> = Vec::new();
    let mut retained: Vec<RetainedFailure> = Vec::new();

    for column in &run_columns {
        let mut scores: Vec<NeedleScore> = Vec::new();
        for needle in &corpus.needles {
            let (items, latency, bytes, request, response) =
                query_needle(client, needle, column, verb_map, config.search_limit)?;

            let distractor_contents = distractor_content_map(needle, corpus);
            let partner_content = split_partner_content(needle, corpus);

            let score = scorer.score(
                needle,
                &items,
                &distractor_contents,
                partner_content.as_deref(),
                latency,
                bytes,
            );

            // Retain worst-case failures (not found at deepest k, or incomplete).
            let deepest_k = scorer.k_values.iter().max().copied().unwrap_or(10);
            let not_found = !score.found_at_k.get(&deepest_k).copied().unwrap_or(false);
            let incomplete = score.completeness < 1.0;
            if not_found || incomplete {
                let reason = if not_found {
                    format!("not found@{}", deepest_k)
                } else {
                    "incomplete (fetched record ≠ verbatim)".to_string()
                };
                // Severity: missing rank is worst; otherwise deeper rank is worse;
                // incomplete-but-found is least bad.
                let severity = score
                    .rank
                    .map(|r| r as f64)
                    .unwrap_or(config.search_limit as f64 + 1.0);
                retained.push(RetainedFailure {
                    strategy_name: column.name.clone(),
                    needle_id: needle.id.clone(),
                    tier: needle.tier,
                    query: needle.query.clone(),
                    request,
                    response,
                    reason,
                    severity,
                });
            }
            scores.push(score);
        }
        strategy_results.push(StrategyResult::build(
            column.name.clone(),
            column.is_mootx01,
            scores,
            &scorer.k_values,
        ));
    }

    // Worst 10 by descending severity.
    retained.sort_by(|a, b| {
        b.severity
            .partial_cmp(&a.severity)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    let worst = retained.into_iter().take(10).collect();

    let report = GauntletRunReport {
        seed: corpus.seed,
        run_label: config.run_label.clone(),
        k_values: scorer.k_values.clone(),
        distractors_per_needle: corpus.distractors_per_needle,
        tier_counts: corpus.tier_counts.clone(),
        strategies: strategy_results,
        worst_failures: worst,
        guard_healthy: true,
        quick_mode: config.quick_mode,
        header_epilogue: String::new(),
        git_sha: "unknown".to_string(),
        git_dirty_count: None,
        run_timestamp: String::new(),
        columns_run: run_columns.iter().map(|c| c.name.clone()).collect(),
        composition_list_version: COMPOSITION_NAMES.iter().map(|s| s.to_string()).collect(),
        run_environment: None,
        shape: "disk".to_string(),
        guard_sampling: "once".to_string(),
        // C6: parallel units always 1 for the gauntlet.
        parallel_units: 1,
        // C4: wire the captured timing report. "once-per-run" label distinguishes
        // the gauntlet's single-estate pattern from per-unit-estate lanes.
        timing_report: captured_timing_report,
        timing_sampling: "once-per-run".to_string(),
        // BENCHMARK_PROTOCOL §9: estate schema version recorded in every report
        // so the historical table can carry the column.
        estate_schema_version: crate::artifact_manifest::CURRENT_ESTATE_SCHEMA_VERSION
            .to_string(),
    };
    Ok(report)
}

// ─────────────────────────────────────────────────────────────────────────────
// load helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Seeds the corpus into the moot backend via the chosen seed path.
/// Batch path (ruling 8D5B8053): emit schema v1 JSON → one `moot_json_import`
/// → `wait_for_encode_drain` barrier → ready for dream.
/// Live path: pipelined `moot_file_memory` with impatient=true (retained for
/// periodic equivalence re-proving against the batch path).
fn load_corpus_into_moot(
    client: &mut MCPClient,
    corpus: &GauntletCorpus,
    verb_map: &VerbMap,
    config: &GauntletRunConfig,
) -> Result<(), MCPError> {
    match config.seed_path {
        SeedPathMode::Batch => {
            // Batch seeding (ruling 8D5B8053): emit one seed JSON file →
            // one `moot_json_import` → `wait_for_encode_drain` barrier.
            let dir = config.scratch_dir.as_ref().ok_or_else(|| MCPError {
                description: "gauntlet batch seed path requires a scratch directory \
                              (pass scratch_dir to GauntletRunConfig)"
                    .to_string(),
            })?;
            let seed_records = gauntlet_seed_records(&corpus.records);
            let name = format!("gauntlet-{}", corpus.seed);
            let data = emit_seed_json(&name, &seed_records, &[], &[]);
            // write_seed_file returns MCPError on failure; propagate as-is.
            let seed_path = write_seed_file(&data, std::path::Path::new(dir), &name)?;

            let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
            args.insert(
                "path".to_string(),
                JsonValue::String(seed_path.to_string_lossy().to_string()),
            );
            let import_result =
                client.call_tool(crate::aria_v2_surface::JSON_IMPORT, args, &verb_map.result_format)?;
            // v2: drawer count is in structuredContent.data.drawers_written, not text.
            if import_result.drawers_written != Some(seed_records.len() as i64) {
                return Err(MCPError {
                    description: format!(
                        "gauntlet: moot_json_import did not confirm {} drawers — got: {}",
                        seed_records.len(),
                        import_result.drawers_written
                            .map(|n| n.to_string())
                            .unwrap_or_else(|| "(no structured data)".to_string())
                    ),
                });
            }
            // Drain barrier: import encodes during the call; the barrier confirms
            // the encode queue is idle before dream runs.
            let label = format!("gauntlet seed={}", corpus.seed);
            wait_for_encode_drain(client, &label, 300.0);
        }

        SeedPathMode::Live => {
            // Live path (retained for equivalence re-proving): pipelined
            // moot_file_memory calls with impatient=true so each drawer is
            // encoded inline before the call returns.
            for record in &corpus.records {
                let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
                args.insert(
                    verb_map.content_arg.clone(),
                    JsonValue::String(record.content.clone()),
                );
                args.insert(
                    "subject".to_string(),
                    JsonValue::String(deterministic_subject(&record.content)),
                );
                args.insert("location".to_string(), JsonValue::String(record.location.clone()));
                args.insert("impatient".to_string(), JsonValue::Bool(true));
                for (k, v) in &verb_map.constant_args {
                    if k != "location" {
                        args.insert(k.clone(), JsonValue::String(v.clone()));
                    }
                }
                client.call_tool(&verb_map.write, args, &verb_map.result_format)?;
            }
        }
    }
    Ok(())
}

/// Projects gauntlet corpus records onto seed-file schema v1 records. Pure —
/// no network calls, deterministic. Mirrors Swift
/// `GauntletRunner.gauntletSeedRecords(from:)`.
///
/// - `id`: the record's stable corpus id (unique across the file).
/// - `room`: the record's `location` string verbatim — the per-record T5
///   scatter location the live path passed as `"location"`.
/// - `wing`: omitted (None → importer default "Agentic Memory").
/// - `event_time`: synthesised deterministically — base 2026-01-01T00:00:00Z
///   plus a per-record +1 s offset. All times precede DREAM_INSTANT
///   (2026-06-11T00:00:00Z) so every record is in the estate's past.
pub fn gauntlet_seed_records(records: &[GauntletRecord]) -> Vec<SeedFileRecord> {
    records
        .iter()
        .enumerate()
        .map(|(idx, record)| SeedFileRecord {
            id: record.id.clone(),
            content: record.content.clone(),
            // Schema v1.2: capture_date absent for gauntlet records (burst path).
            // The gauntlet lane does not exercise capture-spread timing.
            capture_date: None,
            event_time: synthetic_event_time(idx),
            // room = location verbatim: the per-record attribution set when the
            // live seed path passed `location` to moot_file_memory. Required; the
            // batch path preserves it through the seed-file `room` field.
            room: record.location.clone(),
            wing: None,
            kind: None,
            sensitivity: None,
            exportability: None,
        })
        .collect()
}

/// A deterministic subject derived from content (mirrors the Swift live-path
/// `deterministicSubject`). Used only on the live seed path.
fn deterministic_subject(content: &str) -> String {
    content
        .split_whitespace()
        .next()
        .unwrap_or("subject")
        .to_string()
}

// ─────────────────────────────────────────────────────────────────────────────
// dream helper
// ─────────────────────────────────────────────────────────────────────────────

/// Dreams the moot estate once, after load and before any query, so the matrix
/// recall lanes carry signal. Uses the fixed `DREAM_INSTANT` for reproducibility.
/// Mirrors Swift `GauntletRunner.dreamMootEstate()`.
fn dream_moot_estate(client: &mut MCPClient, verb_map: &VerbMap) -> Result<(), MCPError> {
    let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
    args.insert("now".to_string(), JsonValue::String(DREAM_INSTANT.to_string()));
    client.call_tool(crate::aria_v2_surface::DREAM, args, &verb_map.result_format)?;
    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────
// query helper
// ─────────────────────────────────────────────────────────────────────────────

/// Issues one needle's query to one column's backend and returns the parsed
/// result items, latency, byte size, and the full request + response strings.
/// Mirrors Swift `GauntletRunner.query(needle:column:)`.
///
/// ASYNC → SYNC: Swift awaits the call; Rust blocks synchronously on the
/// same stdio-transport MCPClient.
fn query_needle(
    client: &mut MCPClient,
    needle: &Needle,
    column: &GauntletColumn,
    verb_map: &VerbMap,
    search_limit: usize,
) -> Result<(Vec<ScoredItem>, f64, usize, String, String), MCPError> {
    let start = Instant::now();
    let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
    let tool_name: String;

    if column.uses_precise_tool() {
        // PreciseRecall recipe tool: composition ablation column.
        // DETERMINISM: request a wide coarse pool so the precise reduce sees a
        // STABLE candidate set. The backend clamps to available candidates, so
        // an over-wide value is harmless. A narrow pool admits DIFFERENT equal-
        // score boundary candidates run-to-run (the leaderboard noise).
        tool_name = PRECISE_RECALL_TOOL_NAME.to_string();
        args.insert(
            verb_map.query_arg.clone(),
            JsonValue::String(needle.query.clone()),
        );
        args.insert("limit".to_string(), JsonValue::Number(search_limit as f64));
        args.insert(
            "composition".to_string(),
            JsonValue::String(column.composition.clone().unwrap()),
        );
        args.insert(
            "pool".to_string(),
            JsonValue::Number(PRECISE_POOL_WIDTH as f64),
        );
    } else {
        // moot_memory_search under a named scoring strategy.
        tool_name = verb_map.query.clone();
        args.insert(
            verb_map.query_arg.clone(),
            JsonValue::String(needle.query.clone()),
        );
        args.insert(
            "scoring".to_string(),
            JsonValue::String(column.scoring.unwrap().raw_value().to_string()),
        );
        args.insert("limit".to_string(), JsonValue::Number(search_limit as f64));
    }

    let result = client.call_tool(&tool_name, args.clone(), &verb_map.result_format)?;
    let latency = start.elapsed().as_secs_f64();

    let items: Vec<ScoredItem> = result
        .items
        .iter()
        .map(|i| ScoredItem { id: i.id.clone(), content: i.content.clone() })
        .collect();
    let response_text = result.text_blocks.join("\n");
    let bytes = response_text.len();
    let request = render_request(&tool_name, &args);

    Ok((items, latency, bytes, request, response_text))
}

/// Renders a compact request string for the failure appendix. Mirrors Swift
/// `GauntletRunner.renderRequest(tool:args:)`.
///
/// Determinism guarantee: `args` is a `BTreeMap` (sorted by key), and the
/// top-level fields are emitted in a fixed order (`tool` then `arguments`).
/// Two calls with identical inputs always produce an identical byte sequence.
pub(crate) fn render_request(tool: &str, args: &BTreeMap<String, JsonValue>) -> String {
    // Compact JSON: {"tool":"...","arguments":{...}}
    let mut parts: Vec<String> = Vec::new();
    parts.push(format!("\"tool\":\"{}\"", tool));
    let arg_parts: Vec<String> = args
        .iter()
        .map(|(k, v)| {
            let vs = match v {
                JsonValue::String(s) => format!("\"{}\"", s),
                JsonValue::Number(n) => format!("{}", n),
                JsonValue::Bool(b) => format!("{}", b),
                _ => "null".to_string(),
            };
            format!("\"{}\":{}", k, vs)
        })
        .collect();
    parts.push(format!("\"arguments\":{{{}}}", arg_parts.join(",")));
    format!("{{{}}}", parts.join(","))
}

// ─────────────────────────────────────────────────────────────────────────────
// Guard helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Picks three distinct needle queries spread across the corpus to drive the
/// DegeneracyGuard's query-invariance probe. Spread (first, middle, last)
/// maximises the chance the three target different subjects so a healthy
/// backend returns visibly different rankings. Mirrors Swift
/// `GauntletRunner.guardProbes(from:)`.
pub fn guard_probes(needles: &[Needle]) -> Vec<String> {
    if needles.is_empty() { return Vec::new(); }
    if needles.len() < 3 {
        return needles.iter().map(|n| n.query.clone()).collect();
    }
    let first = needles.first().unwrap().query.clone();
    let middle = needles[needles.len() / 2].query.clone();
    let last = needles.last().unwrap().query.clone();
    vec![first, middle, last]
}

// ─────────────────────────────────────────────────────────────────────────────
// Corpus query helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Builds the distractor id → verbatim content map for one needle.
fn distractor_content_map(
    needle: &Needle,
    corpus: &GauntletCorpus,
) -> std::collections::HashMap<String, String> {
    let ids: std::collections::HashSet<&str> =
        needle.distractor_ids.iter().map(String::as_str).collect();
    corpus
        .records
        .iter()
        .filter(|r| ids.contains(r.id.as_str()))
        .map(|r| (r.id.clone(), r.content.clone()))
        .collect()
}

/// Returns the verbatim content of a needle's split partner, if any.
fn split_partner_content(needle: &Needle, corpus: &GauntletCorpus) -> Option<String> {
    let pid = needle.split_partner_id.as_ref()?;
    corpus
        .records
        .iter()
        .find(|r| &r.id == pid)
        .map(|r| r.content.clone())
}

// ─────────────────────────────────────────────────────────────────────────────
// Load marker helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Writes a load-marker beside the moot backend's scratch data after a fresh
/// load so the next run can reuse. Matches the Swift `writeMarker(_:)` content
/// format: `"<seed>\n<record_count>\n"`.
pub fn write_load_marker(path: &str, seed: u64, record_count: usize) {
    let contents = format!("{}\n{}\n", seed, record_count);
    if let Err(e) = std::fs::write(path, contents.as_bytes()) {
        eprintln!(
            "gauntlet: could not write load-marker {}: {} \
             (reuse fast-path unavailable next run)",
            path, e
        );
    }
}

/// Returns true when the marker exists and records exactly this seed and record
/// count. Any mismatch reads as false → caller loads fresh. Mirrors Swift
/// `loadMarkerMatches(_:seed:recordCount:)`.
pub fn load_marker_matches(path: &str, seed: u64, record_count: usize) -> bool {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(_) => return false,
    };
    let mut lines = text.lines();
    let seed_line = lines.next().unwrap_or("");
    let count_line = lines.next().unwrap_or("");
    seed_line == seed.to_string() && count_line == record_count.to_string()
}

// ─────────────────────────────────────────────────────────────────────────────
// Git provenance helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Runs `git rev-parse HEAD` and returns the 40-char SHA. Returns "unknown"
/// when git is absent or the directory has no history. Mirrors Swift
/// `captureGitSHA()`.
pub fn capture_git_sha() -> String {
    let output = std::process::Command::new("git")
        .args(["rev-parse", "HEAD"])
        .stderr(std::process::Stdio::null())
        .output();
    match output {
        Err(_) => {
            eprintln!(
                "gauntlet provenance: git not available — SHA recorded as 'unknown'"
            );
            "unknown".to_string()
        }
        Ok(out) if !out.status.success() => {
            eprintln!(
                "gauntlet provenance: git rev-parse HEAD failed — SHA recorded as 'unknown'"
            );
            "unknown".to_string()
        }
        Ok(out) => {
            let sha = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if sha.is_empty() { "unknown".to_string() } else { sha }
        }
    }
}

/// Counts dirty (modified/staged/untracked) paths. Returns -1 when git is
/// unavailable. Mirrors Swift `captureGitDirtyCount()`.
pub fn capture_git_dirty_count() -> i32 {
    let output = std::process::Command::new("git")
        .args(["status", "--porcelain"])
        .stderr(std::process::Stdio::null())
        .output();
    match output {
        Err(_) => -1,
        Ok(out) if !out.status.success() => -1,
        Ok(out) => {
            let text = String::from_utf8_lossy(&out.stdout);
            text.lines().count() as i32
        }
    }
}

// GauntletGuardRefusal implements std::error::Error so run_gauntlet can return
// it as Box<dyn Error>. Verdict::diagnostic() is already defined on the enum.
impl std::error::Error for GauntletGuardRefusal {}

// ─────────────────────────────────────────────────────────────────────────────
// Verb map and endpoint config
// ─────────────────────────────────────────────────────────────────────────────

/// VerbMap for the gauntlet lane. Uses moot_file_memory (ingest) and
/// moot_memory_search (search), filing into the dedicated
/// "benchmarks/gauntlet" location so the gauntlet estate is isolated from
/// other benchmark lanes that may run on the same mootx01 instance.
/// Mirrors Swift `GauntletRunner.mootVerbMap`.
pub fn gauntlet_verb_map() -> VerbMap {
    let mut constant_args = BTreeMap::new();
    // Tag all seeded drawers to the gauntlet wing so searches are scoped —
    // this prevents cross-lane contamination when the moot estate is shared.
    constant_args.insert("location".to_string(), "benchmarks/gauntlet".to_string());
    VerbMap::new(
        crate::aria_v2_surface::FILE_MEMORY,
        crate::aria_v2_surface::MEMORY_SEARCH,
        None,                            // list: not used by the gauntlet runner
        None,                            // fetch: not used by the gauntlet runner
        None,                            // content_arg: defaults to "content"
        None,                            // query_arg: defaults to "query"
        Some(constant_args),
        Some(ResultFormat::MootV2),
    )
}

/// TRUST BOUNDARY (#21, 2026-08-15): `Transport::Stdio`'s `command` is one
/// shell-like string that [`crate::mcp_client::MCPClient::launch_stdio`]
/// splits on ASCII whitespace before handing the tokens to `/usr/bin/env`.
/// That split is intentional for *operator*-supplied endpoint commands
/// (`env VAR=val cmd --flag`), but `gauntlet_endpoint_config` builds its
/// command by interpolating `scratch_dir` — a path that can come from
/// `--scratch-dir` or a caller-computed default and is not guaranteed
/// whitespace-free. If `scratch_dir` (or the binary path) ever contained
/// an embedded space, the interpolated string would split into extra
/// tokens, and `env`'s own parsing treats the first token that doesn't
/// look like `VAR=val` as the program to exec — silently redirecting the
/// launch to that token instead of `moot_binary`. This validates both
/// inputs are single, unambiguous tokens before they are ever embedded,
/// and resolves `moot_binary` to its canonical absolute path (symlinks
/// followed, `.`/`..` gone) so the token that reaches `env` is the exact
/// path this function verified rather than a caller-supplied string that
/// could still be re-pointed between resolution and launch by something
/// else writable in its lookup path. Refusal is a `panic!`, matching this
/// crate's existing FATAL-error convention for run-invalidating conditions
/// that a per-item skip cannot recover from (see `membench_runner.rs`'s
/// provenance-mismatch panic) — the alternative, returning `Result`, would
/// change this function's signature and ripple into `main.rs`, which is
/// out of scope for this mission.
///
/// EndpointConfig that launches a fresh mootx01 serve process with the gauntlet
/// scratch estate. Mirrors Swift `GauntletCLI.scratchEndpointConfig`.
///
/// # Arguments
/// * `scratch_dir` — data directory for the moot estate (passed as `--db`).
/// * `moot_binary` — path to the mootx01 binary.
/// * `use_inmemory_backend` — when true, appends `--in-memory` to the serve command (C1/Ram shape).
///
/// # Panics
/// Refuses (panics) when `moot_binary` does not resolve to a real file, or
/// when the resolved binary path or `scratch_dir` contains whitespace that
/// would let the interpolated stdio command tokenize into more than the
/// intended `env`-assignment + binary + `serve` sequence.
pub fn gauntlet_endpoint_config(
    scratch_dir: &str,
    moot_binary: &str,
    use_inmemory_backend: bool,
) -> Result<EndpointConfig, String> {
    // Resolve the intended binary explicitly — canonicalize follows symlinks
    // and normalizes `.`/`..`, so the path embedded in the launch command is
    // the definitive target, not whatever a relative or symlinked input
    // happened to name. Returns Err rather than panicking so the error
    // propagates through the CLI chain to exit 1.
    let resolved_binary = std::fs::canonicalize(moot_binary)
        .map_err(|e| format!("[gauntlet] mootx01 binary '{}' did not resolve to a real file: {e}", moot_binary))?
        .to_string_lossy()
        .into_owned();
    // moot_serve_command validates whitespace in both binary and scratch_dir
    // and returns Err rather than panicking.

    // MOOTX01_VAULT=1 ensures the vault-gated moot_json_import is available;
    // --db attaches the scratch directory as a transient record and
    // --in-memory selects the Ram shape (C1), matching lme_endpoint_config.
    let command = crate::scratch_posture::moot_serve_command(
        &resolved_binary, std::path::Path::new(&scratch_dir), use_inmemory_backend, &["MOOTX01_VAULT=1"], None)
        .map_err(|e| e.to_string())?;
    let endpoint = EndpointConfig {
        name: "mootx01-gauntlet".to_string(),
        transport: Transport::Stdio { command },
        auth: None,
        verb_map: gauntlet_verb_map(),
        role: EndpointRole::Both,
    };
    // Post-build contamination guard: the assembled command must select a
    // /tmp scratch directory via --db. Mirrors Swift GauntletCLI.swift's
    // `assertScratchBackend(endpoint, requirement: mootScratchRequirement)`.
    assert_scratch_backend(&endpoint, &MOOT_SCRATCH_REQUIREMENT);
    Ok(endpoint)
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gauntlet_corpus::{GauntletGenerator, GauntletProfile, Needle, NoiseTier};

    fn make_corpus_needles(n: usize) -> Vec<Needle> {
        (0..n).map(|i| Needle {
            id: format!("n{:04}", i),
            query: format!("query about subject {}", i),
            content: format!("Content for needle {}.", i),
            tier: NoiseTier::Lexical,
            location: format!("Wing{}/room-{}", i, i),
            distractor_ids: Vec::new(),
            split_partner_id: None,
            expected_rank: 1,
        }).collect()
    }

    // ── guard_probes ──────────────────────────────────────────────────────────

    #[test]
    fn guard_probes_empty() {
        let probes = guard_probes(&[]);
        assert!(probes.is_empty());
    }

    #[test]
    fn guard_probes_fewer_than_3() {
        let needles = make_corpus_needles(2);
        let probes = guard_probes(&needles);
        assert_eq!(probes.len(), 2);
    }

    #[test]
    fn guard_probes_picks_first_middle_last() {
        let needles = make_corpus_needles(5);
        let probes = guard_probes(&needles);
        assert_eq!(probes.len(), 3);
        assert_eq!(probes[0], needles[0].query);
        assert_eq!(probes[1], needles[2].query); // middle = index 2 of 5
        assert_eq!(probes[2], needles[4].query);
    }

    // ── gauntlet_seed_records ─────────────────────────────────────────────────

    #[test]
    fn seed_records_preserve_id_content_location() {
        let profile = GauntletProfile::even_mix(1, 1);
        let corpus = GauntletGenerator::new(profile).generate(42);
        let seed_records = gauntlet_seed_records(&corpus.records);
        assert_eq!(seed_records.len(), corpus.records.len());
        for (orig, sr) in corpus.records.iter().zip(seed_records.iter()) {
            assert_eq!(sr.id, orig.id);
            assert_eq!(sr.content, orig.content);
            assert_eq!(sr.room.as_str(), orig.location.as_str());
        }
    }

    #[test]
    fn seed_records_event_times_are_ordered() {
        let profile = GauntletProfile::even_mix(1, 1);
        let corpus = GauntletGenerator::new(profile).generate(42);
        let seed_records = gauntlet_seed_records(&corpus.records);
        // Each record's event_time is 1 second after the previous one.
        // Verify the times are strictly increasing (lexicographic order of ISO8601
        // is chronological order for same-day times).
        for w in seed_records.windows(2) {
            assert!(w[0].event_time < w[1].event_time,
                "event_times must be strictly increasing: {} < {}",
                w[0].event_time, w[1].event_time);
        }
    }

    #[test]
    fn seed_records_event_times_precede_dream_instant() {
        let profile = GauntletProfile::even_mix(2, 2);
        let corpus = GauntletGenerator::new(profile).generate(42);
        let seed_records = gauntlet_seed_records(&corpus.records);
        for sr in &seed_records {
            assert!(
                sr.event_time.as_str() < DREAM_INSTANT,
                "event_time {} must precede dream instant {}",
                sr.event_time, DREAM_INSTANT
            );
        }
    }

    // ── columns() ─────────────────────────────────────────────────────────────

    #[test]
    fn columns_count_without_baseline() {
        let cols = columns(None);
        // 3 scoring + 21 composition = 24 total.
        assert_eq!(cols.len(), 3 + COMPOSITION_NAMES.len());
    }

    #[test]
    fn columns_first_three_are_search_strategies() {
        let cols = columns(None);
        let names: Vec<&str> = cols.iter().take(3).map(|c| c.name.as_str()).collect();
        assert_eq!(names, &["mootx01:raw", "mootx01:rrf", "mootx01:matrixAware"]);
    }

    #[test]
    fn columns_remaining_are_precise_compositions() {
        let cols = columns(None);
        for col in cols.iter().skip(3) {
            assert!(col.name.starts_with("precise:"), "expected precise: prefix, got {}", col.name);
            assert!(col.uses_precise_tool());
        }
    }

    #[test]
    fn columns_with_baseline_prepends_it() {
        let cols = columns(Some("my-baseline"));
        assert_eq!(cols[0].name, "my-baseline");
        assert!(!cols[0].is_mootx01);
    }

    // ── COMPOSITION_NAMES count ───────────────────────────────────────────────

    #[test]
    fn composition_names_count_matches_swift() {
        // Swift GauntletRunner.compositionNames has 22 entries (verified by
        // direct count at port time: 6 singles, 6 combos, 6 structural,
        // 2 temporal-assembly, 2 weighted, + dense-fused + weighted-all).
        // Pinning this count guards against accidental additions or removals.
        assert_eq!(COMPOSITION_NAMES.len(), 22);
    }

    // ── load_marker_matches ───────────────────────────────────────────────────

    #[test]
    fn load_marker_matches_correct_values() {
        let path = format!("/tmp/gauntlet-runner-test-marker-{}", std::process::id());
        write_load_marker(&path, 42, 10);
        assert!(load_marker_matches(&path, 42, 10));
        assert!(!load_marker_matches(&path, 43, 10)); // wrong seed
        assert!(!load_marker_matches(&path, 42, 11)); // wrong count
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn load_marker_matches_missing_file_returns_false() {
        assert!(!load_marker_matches("/tmp/does-not-exist-gauntlet", 42, 10));
    }

    // ── gauntlet_endpoint_config (#21 regression) ────────────────────────────

    #[test]
    fn endpoint_config_embeds_the_resolved_binary_and_scratch_dir() {
        // No hijack attempt — a normal scratch dir and a real binary path
        // must still produce a working Stdio command with the canonicalized
        // binary embedded (proves the fix does not regress the happy path).
        let endpoint = gauntlet_endpoint_config("/tmp/gauntlet-scratch-normal", "/bin/cat", false)
            .expect("valid scratch path and binary must succeed");
        let Transport::Stdio { command } = endpoint.transport else {
            panic!("expected Stdio transport");
        };
        let resolved = std::fs::canonicalize("/bin/cat").expect("/bin/cat must resolve on the test machine");
        assert!(
            command.contains(resolved.to_string_lossy().as_ref()),
            "command must embed the canonicalized binary path, got: {command}"
        );
        assert!(command.ends_with(" serve --db /tmp/gauntlet-scratch-normal"),
            "the scratch dir is selected by --db after the serve subcommand, got: {command}");
    }

    #[test]
    fn endpoint_config_refuses_a_scratch_dir_with_a_decoy_token() {
        // #21: a scratch path seeded with what looks like a second program
        // name (simulating a decoy binary an attacker could place adjacent
        // to a legitimately-named directory) must not silently become part
        // of the launched command — gauntlet_endpoint_config must refuse
        // rather than build a command whose tokenization `env` could
        // re-interpret as launching the decoy instead of the resolved
        // mootx01 binary.
        let decoy_scratch = "/tmp/gauntlet-scratch-real evil-decoy-binary";
        // gauntlet_endpoint_config now returns Result<_, String> instead of panicking;
        // verify the whitespace error is returned as Err, not a panic.
        let outcome = gauntlet_endpoint_config(decoy_scratch, "/bin/cat", false);
        assert!(
            outcome.is_err(),
            "a scratch dir containing whitespace (decoy-token injection) must refuse to launch, not build a command"
        );
    }

    #[test]
    fn endpoint_config_refuses_an_unresolvable_binary() {
        // A binary path that does not resolve to a real file must never be
        // embedded into the launch command — refuse rather than launch
        // whatever `env`/the shell happens to find at that name.
        // gauntlet_endpoint_config now returns Result<_, String> instead of panicking;
        // verify the unresolvable binary is returned as Err, not a panic.
        let outcome = gauntlet_endpoint_config("/tmp/gauntlet-scratch-normal", "/no/such/mootx01-binary", false);
        assert!(outcome.is_err(), "an unresolvable binary path must refuse to launch");
    }

    // ── assert_scratch_backend / scratch_path_is_tmp ──────────────────────────

    #[test]
    fn scratch_path_is_tmp_accepts_valid_tmp_paths() {
        // A command with --db /tmp/<name> must pass.
        assert!(scratch_path_is_tmp("--db", "/bin/cat serve --db /tmp/gauntlet-scratch"),
            "--db /tmp/... must pass");
        // --db /tmp itself (root) must also pass.
        assert!(scratch_path_is_tmp("--db", "/bin/cat serve --db /tmp"),
            "--db /tmp must pass");
    }

    #[test]
    fn scratch_path_is_tmp_rejects_non_tmp_paths() {
        // A command whose --db points outside /tmp must be refused.
        assert!(!scratch_path_is_tmp("--db", "/bin/cat serve --db /var/moot/estates"),
            "--db /var/... must be rejected");
        // /tmp-prefixed but not under /tmp (evil-twin attack) must be rejected.
        assert!(!scratch_path_is_tmp("--db", "/bin/cat serve --db /tmp.evil/estates"),
            "/tmp.evil prefix must be rejected");
        // Missing --db altogether must be rejected.
        assert!(!scratch_path_is_tmp("--db", "/bin/cat serve --in-memory"),
            "absent --db must be rejected");
    }

    #[test]
    fn assert_scratch_backend_accepts_valid_gauntlet_endpoint() {
        // gauntlet_endpoint_config with a /tmp scratch dir must pass the
        // post-build contamination guard without panicking.
        let endpoint = gauntlet_endpoint_config("/tmp/gauntlet-scratch-ok", "/bin/cat", false)
            .expect("valid scratch path and binary must succeed");
        // Must not panic:
        assert_scratch_backend(&endpoint, &MOOT_SCRATCH_REQUIREMENT);
    }

    #[test]
    fn endpoint_config_error_propagates_as_err_not_panic() {
        // W4: gauntlet_endpoint_config now returns Result<EndpointConfig, String>
        // instead of panicking. Verifies that a bad input (whitespace in scratch_dir)
        // is returned as Err, not a panic (which would exit 101).
        // The CLI path: run_gauntlet_cmd propagates with `?` and main() matches
        // Err(msg) → eprintln! + ExitCode::FAILURE (exit 1).
        let outcome = gauntlet_endpoint_config("/tmp/path with spaces", "/bin/cat", false);
        assert!(
            outcome.is_err(),
            "whitespace in scratch_dir must return Err, not panic — so the CLI exits 1, not 101"
        );
        let err_msg = outcome.unwrap_err();
        assert!(
            err_msg.contains("whitespace") || err_msg.contains("WhitespaceInPath"),
            "Err message must describe the refusal reason: {err_msg}"
        );
    }

    #[test]
    fn cli_exits_1_not_101_on_whitespace_scratch_dir() {
        // X4 CLI boundary test: the built binary must exit 1 (thrown error caught by
        // benchmarkerMain / main Err branch), not 101 (panic / abort).
        // Uses `gauntlet --binary /bin/cat --scratch-dir "/tmp/path with spaces"`.
        // The scratch-dir whitespace triggers ScratchPostureError::WhitespaceInPath
        // which propagates through run_gauntlet_cmd as Err(msg) → exit 1.
        let crate_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        let binary = crate_dir.join("target/debug/mcp-benchmarker-rs");
        if !binary.exists() {
            // Binary may not be pre-built in some CI environments; skip rather than fail.
            eprintln!("[X4] skipping CLI boundary test — binary not found at {}", binary.display());
            return;
        }
        let output = std::process::Command::new(&binary)
            .args(["gauntlet", "--binary", "/bin/cat", "--scratch-dir", "/tmp/path with spaces"])
            .output()
            .expect("failed to launch mcp-benchmarker-rs");
        assert_eq!(
            output.status.code(),
            Some(1),
            "whitespace scratch-dir must exit 1 (not 101/134): exit={:?}",
            output.status.code()
        );
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            !stderr.contains("panicked at"),
            "exit must come from Err propagation, not a panic: stderr={stderr}"
        );
        assert!(
            stderr.contains("whitespace") || stderr.contains("WhitespaceInPath"),
            "stderr must describe the refusal reason: {stderr}"
        );
    }

    #[test]
    fn assert_scratch_backend_rejects_non_tmp_endpoint() {
        // An endpoint whose --db is not under /tmp must panic.
        // We build the endpoint config manually to bypass gauntlet_endpoint_config's
        // own guards (which also refuse the path — this test exercises assert_scratch_backend
        // directly, mirroring GauntletSafetyTests.swift).
        let command = "/bin/cat serve --db /var/moot/real-estate".to_string();
        let endpoint = EndpointConfig {
            name: "mootx01-test".to_string(),
            transport: Transport::Stdio { command },
            auth: None,
            verb_map: gauntlet_verb_map(),
            role: EndpointRole::Both,
        };
        let outcome = std::panic::catch_unwind(|| {
            assert_scratch_backend(&endpoint, &MOOT_SCRATCH_REQUIREMENT);
        });
        assert!(outcome.is_err(),
            "a non-/tmp --db path must be refused by assert_scratch_backend");
    }

    // ── render_request determinism ───────────────────────────────────────────

    /// Asserts the EXACT byte sequence produced by render_request, not just that
    /// it parses to the same object. Parsing back to the same object is precisely
    /// the check that cannot see key-order non-determinism.
    ///
    /// Uses more than two argument keys: a two-key map has only two orderings and
    /// a broken encoder passes half the time (reads as a flake, not a defect).
    /// Asserts the EXACT byte sequence produced by render_request, not just that
    /// it parses to the same object. Parsing back to the same object is precisely
    /// the check that cannot see key-order non-determinism.
    ///
    /// Uses more than two argument keys: a two-key map has only two orderings and
    /// a broken encoder passes half the time (reads as a flake, not a defect).
    #[test]
    fn render_request_exact_bytes_three_args() {
        let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
        args.insert("scoring".to_string(), JsonValue::String("matrixAware".to_string()));
        args.insert("limit".to_string(), JsonValue::Number(20.0));
        args.insert("query".to_string(), JsonValue::String("What is the archive level?".to_string()));
        // BTreeMap iterates in sorted key order: limit, query, scoring.
        // Top-level fields are hardcoded: tool first, arguments second.
        let result = render_request("moot_memory_search", &args);
        assert_eq!(
            result,
            r#"{"tool":"moot_memory_search","arguments":{"limit":20,"query":"What is the archive level?","scoring":"matrixAware"}}"#,
            "render_request must produce a byte-identical string for identical inputs"
        );
    }

    #[test]
    fn render_request_exact_bytes_tool_first() {
        // Regression for the top-level key order: tool must always precede arguments.
        let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
        args.insert("wing".to_string(), JsonValue::String("Agentic Memory".to_string()));
        args.insert("ordering".to_string(), JsonValue::String("byRelevanceDesc".to_string()));
        args.insert("query".to_string(), JsonValue::String("What did we decide about storage?".to_string()));
        args.insert("limit".to_string(), JsonValue::Number(5.0));
        // Sorted arg keys: limit, ordering, query, wing.
        let result = render_request("moot_recall_precise", &args);
        assert_eq!(
            result,
            r#"{"tool":"moot_recall_precise","arguments":{"limit":5,"ordering":"byRelevanceDesc","query":"What did we decide about storage?","wing":"Agentic Memory"}}"#,
            "tool key must appear before arguments key regardless of insertion order"
        );
    }
}
