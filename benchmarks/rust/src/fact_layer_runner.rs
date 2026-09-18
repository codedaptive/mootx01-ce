//! fact_layer_runner.rs — drives the fact-layer supersession capability cell.
//! Rust twin of `FactLayerRunner.swift`.
//!
//! INTERNAL CAPABILITY CELL — OUTSIDE THE FAIRNESS-RULE COMPARATIVE LANE.
//!
//! This runner exercises the structured-fact lifecycle:
//!   1. File all fact versions in chronological order via `moot_file_fact`.
//!   2. Retire all non-current versions via `moot_retire_fact`.
//!   3. Query via `moot_fact_search` and score whether the current version
//!      appears in results and whether retired versions are surfaced.
//!
//! Ground truth is keyed on the fact UUIDs returned by `moot_file_fact`,
//! NOT drawer UUIDs. A retired fact that surfaces above the current one
//! is a contamination event; a retired fact that does not surface is
//! the correct outcome.
//!
//! No drain barrier: `moot_file_fact` and `moot_retire_fact` are synchronous
//! structured operations — they do not queue embedding jobs, so the
//! encode-drain cycle that guards the memory lane does not apply here.

use crate::config::ResultFormat;
use crate::fact_layer_corpus::{FactLayerCorpus, FactQuery, FactRecord};
use crate::json_value::JsonValue;
use crate::longmemeval_runner::{lme_endpoint_config, LmeShape};
use crate::mcp_client::{MCPClient, MCPError, ToolCaller};
use crate::scratch_posture::ScratchEstatePosture;
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::time::Instant;

// ─────────────────────────────────────────────────────────────────────────────
// Config
// ─────────────────────────────────────────────────────────────────────────────

/// Run configuration for the fact-layer cell. Twin of Swift `FactLayerRunConfig`.
pub struct FactLayerRunConfig {
    pub moot_binary_path: String,
    pub seed: u64,
    pub fact_count: usize,
    pub versions_per_fact: usize,
    pub scratch_dir: PathBuf,
    /// Scratch posture — always ephemeral to avoid orphaned key material.
    pub posture: ScratchEstatePosture,
    /// C1: backend shape — Disk (SQLite) or Ram (InMemory). Default is Disk.
    /// Ram appends --in-memory to the serve command
    /// so the estate bypasses disk I/O. Same injection as the LME lane.
    pub shape: LmeShape,
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-query result
// ─────────────────────────────────────────────────────────────────────────────

/// Per-query scoring outcome. Twin of Swift `FactLayerQueryResult`.
pub struct FactLayerQueryResult {
    pub query_id: String,
    /// True when the current-version fact UUID appears anywhere in search results.
    pub current_fact_found: bool,
    /// Ranks (1-based) of retired fact UUIDs that appeared in results.
    /// Non-empty means the retire call did not suppress a stale version.
    pub retired_fact_ranks: Vec<usize>,
    /// Rank (1-based) of the current fact UUID in results, None if absent.
    pub current_fact_rank: Option<usize>,
    /// True when the current version outranks every surfaced retired version.
    /// False when the current version is absent OR any retired version ranks higher.
    pub current_wins: bool,
    pub latency_seconds: f64,
}

// ─────────────────────────────────────────────────────────────────────────────
// Runner output
// ─────────────────────────────────────────────────────────────────────────────

/// Complete outcome of one fact-layer run. Twin of Swift `FactLayerCellOutcome`.
pub struct FactLayerCellOutcome {
    pub query_results: Vec<FactLayerQueryResult>,
    /// UUID map keyed on harness-assigned fact ID: harness id → product UUID.
    /// Product UUIDs are assigned by `moot_file_fact` at filing time.
    pub product_uuid_by_fact_id: HashMap<String, String>,
    /// Facts whose `moot_file_fact` call returned no parseable UUID.
    /// These are excluded from scoring — the harness could not track them.
    pub unfiled_fact_ids: Vec<String>,
    /// C4: wall-clock seconds covering the ingest phase (Steps 1+2 combined:
    /// moot_file_fact filing + moot_retire_fact retirements). Captured at the
    /// only available settle point — no drain/dream step in this cell because
    /// moot_file_fact and moot_retire_fact are synchronous structured operations.
    pub ingest_elapsed_seconds: f64,
}

// ─────────────────────────────────────────────────────────────────────────────
// Scoring
// ─────────────────────────────────────────────────────────────────────────────

/// Aggregate scores for the fact-layer cell. Twin of Swift `FactLayerScores`.
pub struct FactLayerScores {
    pub query_count: usize,
    /// Fraction of queries where the current fact UUID appeared in results.
    pub current_found_rate: f64,
    /// Fraction of queries where the current fact UUID outranked every
    /// surfaced retired version (or no retired versions surfaced).
    pub current_win_rate: f64,
    /// Mean retired-fact contamination per query (retired fact UUIDs
    /// appearing in search results). 0.0 means no stale facts surfaced.
    pub mean_retired_per_query: f64,
    pub p50_latency_seconds: f64,
}

/// Computes aggregate fact-layer scores from per-query results.
/// Twin of Swift `scoreFactLayer(_:)`.
pub fn score_fact_layer(results: &[FactLayerQueryResult]) -> FactLayerScores {
    let n = results.len().max(1);
    let found = results.iter().filter(|r| r.current_fact_found).count();
    let wins = results.iter().filter(|r| r.current_wins).count();
    let total_retired: usize = results.iter().map(|r| r.retired_fact_ranks.len()).sum();
    let mut latencies: Vec<f64> = results.iter().map(|r| r.latency_seconds).collect();
    latencies.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let p50 = if latencies.is_empty() {
        0.0
    } else {
        latencies[latencies.len() / 2]
    };
    FactLayerScores {
        query_count: results.len(),
        current_found_rate: found as f64 / n as f64,
        current_win_rate: wins as f64 / n as f64,
        mean_retired_per_query: total_retired as f64 / n as f64,
        p50_latency_seconds: p50,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Runner
// ─────────────────────────────────────────────────────────────────────────────

/// Drives the full fact-layer lifecycle against one ephemeral estate:
///   1. File all fact versions (chronological order) via `moot_file_fact`.
///   2. Map harness IDs to product-assigned UUIDs.
///   3. Retire all non-current versions via `moot_retire_fact`.
///   4. Query with `moot_fact_search` and score.
///
/// No drain barrier: `moot_file_fact` and `moot_retire_fact` are synchronous
/// structured operations — no embedding queue, no encode-drain needed.
/// If the product changes this contract, add a drain barrier here.
///
/// The estate is ALWAYS ephemeral so no Keychain material is orphaned.
/// Twin of Swift `runFactLayerCell(corpus:config:)`.
pub fn run_fact_layer_cell(
    corpus: &FactLayerCorpus,
    config: &FactLayerRunConfig,
) -> Result<FactLayerCellOutcome, MCPError> {
    // C1: pass config.shape so Ram appends --in-memory to the serve command.
    // Twin of Swift's shape pass-through.
    let endpoint = lme_endpoint_config(&config.scratch_dir, &config.moot_binary_path,
                                       config.posture, config.shape, None)
        .map_err(|e| MCPError { description: e })?;
    let mut client = MCPClient::new(endpoint);
    client.connect()?;

    // C4: ingest timing — capture wall time for Steps 1+2 combined.
    // No drain/dream settle point: moot_file_fact and moot_retire_fact are
    // synchronous structured operations that do not queue embedding jobs.
    let ingest_start = Instant::now();

    // ── Step 1: File all facts, chronologically ───────────────────────────
    // Sort by event_time with id as tiebreak, matching the supersession lane.
    let mut ordered: Vec<&FactRecord> = corpus.facts.iter().collect();
    ordered.sort_by(|a, b| {
        a.event_time.cmp(&b.event_time).then_with(|| a.id.cmp(&b.id))
    });

    // harness fact id → product-assigned UUID from `moot_file_fact`
    let mut product_uuid_by_fact_id: HashMap<String, String> = HashMap::new();
    let mut unfiled_fact_ids: Vec<String> = Vec::new();

    for fact in &ordered {
        let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
        args.insert("subject".to_string(), JsonValue::String(fact.subject.clone()));
        args.insert("predicate".to_string(), JsonValue::String(fact.predicate.clone()));
        args.insert("object".to_string(), JsonValue::String(fact.object.clone()));
        // source_id is OMITTED on purpose: MXE-KH made the write reject
        // any source_id naming no real drawer (a synthetic provenance
        // string here failed all 120 files on 2026-08-04). Omitted means
        // "filed sourceless"; writer provenance rides addedBy, stamped
        // by the server. Twin of the Swift runner's omission.
        // Ignored by the scorer — only the UUID matters.

        let result = client.call_tool(crate::aria_v2_surface::FILE_FACT, args, &ResultFormat::MootV2)?;

        // `moot_file_fact` returns "filed fact <UUID>: [subject] predicate [object]".
        // The Rust `parse_moot_text` only handles "filed memory " prefix; extract
        // the UUID from text_blocks directly (matching Swift's `factFileUUID`).
        if let Some(uuid) = fact_file_uuid(&result.text_blocks) {
            product_uuid_by_fact_id.insert(fact.id.clone(), uuid);
        } else {
            unfiled_fact_ids.push(fact.id.clone());
        }
    }

    // ── Step 2: Retire non-current versions ──────────────────────────────
    // Every non-current version is retired so only the current version answers
    // queries. A failed retire is a harness error, not a product error —
    // record it in the contamination count but do not abort the run.
    let mut retire_failures: Vec<String> = Vec::new();
    for fact in corpus.facts.iter().filter(|f| !f.is_current) {
        let Some(uuid) = product_uuid_by_fact_id.get(&fact.id) else { continue };
        // v2: moot_retire_fact uses `fact_id` key (v1 used `id`).
        let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
        args.insert("fact_id".to_string(), JsonValue::String(uuid.clone()));
        let result = client.call_tool(crate::aria_v2_surface::RETIRE_FACT, args, &ResultFormat::MootV2)?;
        // A non-error response from moot_retire_fact is sufficient.
        let resp_text = result.text_blocks.join("\n").to_lowercase();
        if resp_text.contains("error") {
            retire_failures.push(fact.id.clone());
        }
    }
    if !retire_failures.is_empty() {
        // Log failures but continue — partial retirement still produces a
        // measurable number; the retire-contamination count will reflect it.
        let sample: Vec<&str> = retire_failures.iter().take(5).map(String::as_str).collect();
        eprintln!(
            "[fact-layer] WARNING: {} retire call(s) reported errors: {}{}",
            retire_failures.len(),
            sample.join(", "),
            if retire_failures.len() > 5 { "..." } else { "" }
        );
    }

    // C4: close the ingest timing window. Steps 1+2 (file + retire) are the
    // ingest phase; there is no subsequent drain/dream settle point for this cell.
    let ingest_elapsed_seconds = ingest_start.elapsed().as_secs_f64();

    // ── Step 3: Query and score ───────────────────────────────────────────
    let mut query_results: Vec<FactLayerQueryResult> = Vec::new();

    for query in &corpus.queries {
        let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
        args.insert("query".to_string(), JsonValue::String(query.question.clone()));

        let start = Instant::now();
        let result = client.call_tool(crate::aria_v2_surface::FACT_SEARCH, args, &ResultFormat::MootV2)?;
        let latency = start.elapsed().as_secs_f64();

        // `moot_fact_search` result lines: "<UUID>  [subject] predicate [object]..."
        // parse_moot_text collects UUID-leading lines into ordered_ids.
        let ranked = &result.ordered_ids;

        score_query(query, ranked, &product_uuid_by_fact_id, latency, &mut query_results);
    }

    Ok(FactLayerCellOutcome {
        query_results,
        product_uuid_by_fact_id,
        unfiled_fact_ids,
        ingest_elapsed_seconds,
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Scores one query against the ranked result list and appends to `out`.
/// Extracted so it can be unit-tested without a live estate.
fn score_query(
    query: &FactQuery,
    ranked: &[String],
    product_uuid_by_fact_id: &HashMap<String, String>,
    latency_seconds: f64,
    out: &mut Vec<FactLayerQueryResult>,
) {
    // Map corpus harness IDs to product UUIDs for comparison.
    let current_uuid = product_uuid_by_fact_id.get(&query.current_fact_id).cloned();
    let retired_uuids: std::collections::HashSet<String> = query
        .retired_fact_ids
        .iter()
        .filter_map(|rid| product_uuid_by_fact_id.get(rid).cloned())
        .collect();

    let current_rank = current_uuid.as_ref().and_then(|cu| {
        ranked.iter().position(|u| u == cu).map(|i| i + 1)
    });
    let retired_ranks: Vec<usize> = ranked
        .iter()
        .enumerate()
        .filter_map(|(i, u)| {
            if retired_uuids.contains(u) { Some(i + 1) } else { None }
        })
        .collect();

    let current_wins = match current_rank {
        None => false,
        Some(cr) => retired_ranks.iter().all(|&rr| cr < rr),
    };

    out.push(FactLayerQueryResult {
        query_id: query.id.clone(),
        current_fact_found: current_rank.is_some(),
        retired_fact_ranks: retired_ranks,
        current_fact_rank: current_rank,
        current_wins,
        latency_seconds,
    });
}

/// Extracts the UUID from a `moot_file_fact` response.
///
/// The response format is:
///   `filed fact <UUID>: [<subject>] <predicate> [<object>]`
///
/// The generic `parse_moot_text` only handles "filed memory " prefix;
/// this helper covers the fact-specific "filed fact " prefix.
/// Twin of Swift `factFileUUID(from:)`.
fn fact_file_uuid(text_blocks: &[String]) -> Option<String> {
    let prefix = "filed fact ";
    for block in text_blocks {
        for raw_line in block.split('\n') {
            let line = raw_line.trim().to_lowercase();
            if !line.starts_with(prefix) {
                continue;
            }
            // Token after "filed fact " is "<UUID>:"; strip the colon.
            let after = raw_line.trim()["filed fact ".len()..].trim_start();
            if let Some(token) = after.split(':').next() {
                let token = token.trim();
                if is_uuid(token) {
                    return Some(token.to_string());
                }
            }
        }
    }
    None
}

/// Validates a canonical 8-4-4-4-12 hex UUID, case-insensitive.
/// Mirrors the same check in `mcp_result.rs` — duplicated here to avoid
/// a private-fn dependency, keeping the module self-contained.
fn is_uuid(s: &str) -> bool {
    let groups = [8usize, 4, 4, 4, 12];
    let parts: Vec<&str> = s.split('-').collect();
    if parts.len() != groups.len() {
        return false;
    }
    for (part, &len) in parts.iter().zip(groups.iter()) {
        if part.len() != len || !part.bytes().all(|b| b.is_ascii_hexdigit()) {
            return false;
        }
    }
    true
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn make_query(current: &str, retired: &[&str]) -> FactQuery {
        FactQuery {
            id: "q0".to_string(),
            question: "Test question?".to_string(),
            subject: "Alice X 0".to_string(),
            predicate: "employer".to_string(),
            current_fact_id: current.to_string(),
            retired_fact_ids: retired.iter().map(|s| s.to_string()).collect(),
        }
    }

    fn uuid_map(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
    }

    /// UUID extractor: "filed fact <UUID>: ..." → Some(uuid).
    #[test]
    fn fact_file_uuid_extracts_correctly() {
        let blocks = vec![
            "filed fact 7CF35028-84BE-40D0-A8CB-7FCFE8EB6018: [Alice X 0] employer [Acme Robotics]"
                .to_string(),
        ];
        assert_eq!(
            fact_file_uuid(&blocks),
            Some("7CF35028-84BE-40D0-A8CB-7FCFE8EB6018".to_string())
        );
    }

    /// UUID extractor: no match → None.
    #[test]
    fn fact_file_uuid_none_on_no_match() {
        let blocks = vec!["filed memory 7CF35028-84BE-40D0-A8CB-7FCFE8EB6018".to_string()];
        assert_eq!(fact_file_uuid(&blocks), None);
    }

    /// score_query: current UUID first in results → current_wins=true.
    #[test]
    fn score_query_current_wins_when_first() {
        let current_uuid = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA";
        let retired_uuid = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB";
        let query = make_query("fact-0-v1", &["fact-0-v0"]);
        let uuid_map = uuid_map(&[("fact-0-v1", current_uuid), ("fact-0-v0", retired_uuid)]);
        let ranked = vec![current_uuid.to_string(), retired_uuid.to_string()];
        let mut results = Vec::new();
        score_query(&query, &ranked, &uuid_map, 0.1, &mut results);
        let r = &results[0];
        assert!(r.current_fact_found);
        assert!(r.current_wins);
        assert_eq!(r.current_fact_rank, Some(1));
        assert_eq!(r.retired_fact_ranks, vec![2]);
    }

    /// score_query: retired UUID first → current_wins=false.
    #[test]
    fn score_query_current_loses_when_retired_ranks_higher() {
        let current_uuid = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA";
        let retired_uuid = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB";
        let query = make_query("fact-0-v1", &["fact-0-v0"]);
        let uuid_map = uuid_map(&[("fact-0-v1", current_uuid), ("fact-0-v0", retired_uuid)]);
        let ranked = vec![retired_uuid.to_string(), current_uuid.to_string()];
        let mut results = Vec::new();
        score_query(&query, &ranked, &uuid_map, 0.1, &mut results);
        let r = &results[0];
        assert!(r.current_fact_found);
        assert!(!r.current_wins);
    }

    /// score_query: current absent → current_fact_found=false, current_wins=false.
    #[test]
    fn score_query_current_absent() {
        let current_uuid = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA";
        let query = make_query("fact-0-v1", &[]);
        let uuid_map = uuid_map(&[("fact-0-v1", current_uuid)]);
        let ranked = vec!["CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC".to_string()];
        let mut results = Vec::new();
        score_query(&query, &ranked, &uuid_map, 0.1, &mut results);
        let r = &results[0];
        assert!(!r.current_fact_found);
        assert!(!r.current_wins);
        assert!(r.current_fact_rank.is_none());
    }

    /// score_fact_layer: 3 queries, all winning → current_win_rate = 1.0.
    #[test]
    fn score_fact_layer_all_wins() {
        let results: Vec<FactLayerQueryResult> = (0..3)
            .map(|i| FactLayerQueryResult {
                query_id: format!("q{i}"),
                current_fact_found: true,
                retired_fact_ranks: vec![],
                current_fact_rank: Some(1),
                current_wins: true,
                latency_seconds: 0.1 * (i + 1) as f64,
            })
            .collect();
        let scores = score_fact_layer(&results);
        assert_eq!(scores.query_count, 3);
        assert!((scores.current_win_rate - 1.0).abs() < 1e-9);
        assert!((scores.mean_retired_per_query - 0.0).abs() < 1e-9);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // FactLayer drain contract
    //
    // moot_file_fact and moot_retire_fact are synchronous structured operations
    // that do not enqueue embedding jobs. The runner therefore runs NO drain
    // barrier. Two tests enforce this — twin of FactLayerDrainContractTests.swift.
    // ─────────────────────────────────────────────────────────────────────────

    /// Verifies that the production code in `fact_layer_runner.rs` never calls
    /// `moot_drain_status`.
    ///
    /// `moot_file_fact` and `moot_retire_fact` are synchronous structured
    /// operations that do not enqueue embedding jobs, so the encode-drain cycle
    /// that guards the memory lane does not apply here. If this test fails, a
    /// drain barrier was added to the runner — which implies fact writes now
    /// enqueue encode work. In that case: add `wait_for_encode_drain` to
    /// `run_fact_layer_cell`, update the runner's doc-comment, and remove this
    /// assertion.
    ///
    /// `include_str!` embeds the file at compile time. The test-boundary split
    /// on `#[cfg(test)]` isolates production code so this test's own assertion
    /// message (which contains crate::aria_v2_surface::DRAIN_STATUS) does not trip the check.
    #[test]
    fn fact_layer_runner_never_calls_drain_status() {
        let source = include_str!("fact_layer_runner.rs");
        // Isolate production code: everything before the #[cfg(test)] section.
        // The assertion message below contains crate::aria_v2_surface::DRAIN_STATUS as a string
        // literal; splitting here prevents the test from falsely tripping on itself.
        let test_boundary = source.find("#[cfg(test)]").unwrap_or(source.len());
        let production_code = &source[..test_boundary];
        assert!(
            !production_code.contains(crate::aria_v2_surface::DRAIN_STATUS),
            "fact_layer_runner production code must never call moot_drain_status — \
            moot_file_fact and moot_retire_fact are synchronous structured operations \
            that do not enqueue embedding jobs. Add a drain barrier to \
            run_fact_layer_cell and remove this assertion if the product changes \
            this contract."
        );
    }

    /// Verifies that `parse_drain_response` correctly identifies both empty-queue
    /// shapes as non-active, and correctly identifies non-zero counts as active.
    ///
    /// These are the only drain-status shapes relevant to the FactLayer contract:
    ///
    /// - `"drains: none"` — no encode lane registered. Expected on a fresh estate
    ///   where fact writes have been issued and no embedding was ever enqueued.
    ///   Parses as `NoLanes` — no work outstanding.
    ///
    /// - All lanes idle with `pending == 0` and `in_flight == 0` — no encode work
    ///   outstanding. Expected when a corpus lane is registered but fact writes
    ///   produced no embedding jobs. Parses as `Idle` — no work outstanding.
    ///
    /// - `pending > 0` or `in_flight > 0` — encode work outstanding. This is what
    ///   the parser returns if fact writes HAD enqueued embedding jobs. NEVER
    ///   expected after `moot_file_fact` or `moot_retire_fact`. Verified here to
    ///   confirm the parser CAN detect a contract violation.
    #[test]
    fn drain_response_after_fact_writes_is_not_draining() {
        use crate::encode_barrier::{parse_drain_response, DrainParseResult};

        // Shape A: no encode lane registered. Correct outcome on an estate where
        // fact writes have been issued and no embedding was ever enqueued.
        assert_eq!(parse_drain_response("drains: none"), DrainParseResult::NoLanes);

        // Shape B, all-idle: corpus lane registered, pending == 0, in_flight == 0.
        // Correct when no fact-write encode jobs were ever queued.
        let all_idle = "drains: 1\n  corpus_encode: idle \u{2014} pending: 0, in_flight: 0";
        assert_eq!(parse_drain_response(all_idle), DrainParseResult::Idle);

        // Non-zero pending: encode work outstanding. This result means fact writes
        // enqueued embedding jobs — a contract violation. Verified here so the
        // detection path is confirmed to work before a live regression could occur.
        let pending_work = "drains: 1\n  corpus_encode: draining \u{2014} pending: 1, in_flight: 0";
        assert_eq!(parse_drain_response(pending_work), DrainParseResult::Draining);

        // Non-zero in_flight: encode work in progress. Same contract violation.
        let in_flight_work = "drains: 1\n  corpus_encode: idle \u{2014} pending: 0, in_flight: 1";
        assert_eq!(parse_drain_response(in_flight_work), DrainParseResult::Draining);
    }
}
