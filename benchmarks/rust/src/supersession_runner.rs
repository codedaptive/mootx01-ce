//! supersession_runner.rs — drives the supersession / contradiction lane.
//! Twin of Swift `SupersessionRunner.swift`.
//!
//! Shape, and how it differs from every other lane in this harness:
//!
//!   ONE estate for the whole run. The other lanes provision a fresh scratch
//!   estate per question, which is correct for pure retrieval but makes
//!   history-dependent behaviour unmeasurable — matrix priors are 0.0 without
//!   an audit trail to compute them from. Here the whole timeline is ingested
//!   into a single estate, in chronological order, and only then is anything
//!   asked. That is the condition a deployed memory system actually runs in.
//!
//!   Ingest carries `event_time`, so the estate's timeline matches the
//!   corpus's fiction rather than collapsing to ingestion order.
//!
//! SCORED BEHAVIOURS
//!
//!   1. Current-over-stale. For each chain, does the still-true version
//!      outrank every superseded version of the same fact? This is the
//!      question the public benchmarks do not ask: they score "was the right
//!      item found", which a system passes while also returning two stale
//!      contradictions of it.
//!   2. Stale contamination@k. How many superseded versions ride along in
//!      the top k. A consumer pasting top-k into a prompt gets every one.
//!   3. Contradiction detection. For claim pairs that cannot both be true and
//!      carry NO temporal ordering, recency cannot help; the correct
//!      behaviour is to surface the conflict.

use crate::degeneracy_guard::{GuardSamplingPolicy, LegGuardSampler};
use crate::encode_barrier::wait_for_encode_drain;
use crate::json_value::JsonValue;
use crate::longmemeval_runner::{lme_endpoint_config, LmeShape};
use crate::mcp_client::{MCPClient, MCPError, ToolCaller};
use crate::scratch_posture::ScratchEstatePosture;
use crate::supersession_corpus::SupersessionCorpus;
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::time::Instant;

/// Per-query outcome. Twin of Swift `SupersessionQueryResult`.
pub struct SupersessionQueryResult {
    pub query_id: String,
    /// Rank of the current version, 1-based. None when it never appeared.
    pub current_rank: Option<usize>,
    /// Ranks of superseded versions that appeared, 1-based.
    pub stale_ranks: Vec<usize>,
    /// True when the current version outranks every stale version present.
    pub current_wins: bool,
    /// Superseded versions inside the top-k window.
    pub stale_in_top_k: usize,
    pub latency_seconds: f64,
    /// False when the degeneracy guard refused this query (C5).
    /// Guard-refused results are excluded from scoring. Twin of Swift field.
    pub guard_healthy: bool,
}

/// Run configuration. Twin of Swift `SupersessionRunConfig`.
pub struct SupersessionRunConfig {
    pub moot_binary_path: String,
    pub seed: u64,
    pub entity_count: usize,
    pub versions_per_chain: usize,
    pub contradiction_count: usize,
    /// Contamination window. 10 mirrors the recall@10 cut-off used elsewhere.
    pub top_k: usize,
    /// RecallShape preset, or None for plain `moot_memory_search`.
    pub recall_shape: Option<String>,
    pub scratch_dir: PathBuf,
    /// Scratch posture. Ephemeral by default — see `run_supersession_lane`.
    pub posture: ScratchEstatePosture,
    /// Run the contradiction sweep (scored behaviour 3). On by default;
    /// `--skip-contradictions` turns it off for ranking-only runs.
    pub contradiction_sweep: bool,
    /// Run `moot_dream` after the drain barrier and before the ranking
    /// queries. This is the UN-STARVING step: moot_dream rebuilds and
    /// registers the estate's MatrixTier from the audit log (keyed off
    /// eventTime, so the corpus's fictional timeline drives the temporal
    /// matrix), which is the ONLY thing that makes the fieldFit /
    /// coOccurrence / temporal score columns non-zero — and with them the
    /// temporal / connection / field / preference presets measurable.
    /// On by default; `--skip-dream` produces the virgin-estate comparison
    /// cell. The two cells are different estate states and every published
    /// figure names which one it is. Twin of Swift `dreamBeforeQueries`.
    pub dream_before_queries: bool,
    /// Typed proving tier: after everything else, file one KGFact per corpus
    /// record (anchored to its ingest drawer) and score the TYPED proving
    /// lane against the planted pairs — the measurement the lexical hunter's
    /// 0/10 baseline motivated. Off by default; `--structured-tier`.
    /// Twin of Swift `structuredTier`.
    pub structured_tier: bool,
    /// How the corpus is loaded into the estate. `Batch` (the default, ruling
    /// 8D5B8053): emit seed-file schema v1 → one `moot_json_import` → the
    /// encode barrier → attribution pass. `Live` is the retained slow lane
    /// (per-record `moot_file_memory`) for periodic equivalence re-proving.
    /// Twin of Swift `seedPath`.
    pub seed_path: crate::seed_export::SeedPathMode,
    /// When true, thread `explain: true` into each recall call and parse the
    /// RecallExplainer output into a `LaneCapture` returned in the outcome.
    /// Twin of Swift `laneCapture`.
    pub lane_capture: bool,
    /// Persistence backend shape (C1). `Disk` uses the default SQLite-backed
    /// estate; `Ram` passes `--in-memory` to the serve command so the estate lives
    /// entirely in process memory. Twin of Swift `shape: LMEShape`.
    pub shape: LmeShape,
    /// Guard sampling policy (C5). `OncePerLeg` probes on the first query
    /// and caches the verdict; `PerUnit` probes every query. Twin of Swift
    /// `guardSamplingPolicy`.
    pub guard_sampling_policy: GuardSamplingPolicy,
    /// Deterministic bench clock epoch for replay runs. When `Some`, passed as
    /// `MOOT_BENCH_EPOCH_NOW=<value>` in the serve environment so temporal
    /// scores and `filedAt` stamps are identical across runs with the same seed.
    /// Derive with `bench_clock_epoch_iso(seed)`. `None` means wall-clock
    /// (production default). Twin of Swift `benchClockEpoch`.
    pub bench_clock_epoch: Option<String>,
}

/// Projects supersession corpus records (in the caller's order — file order
/// is ingestion order) onto seed-file records. Pure. Wing is omitted so the
/// import files into the same default wing ("Agentic Memory") the live
/// `moot_file_memory` path uses; the room mirrors the live `location`. Twin
/// of the Swift `supersessionSeedRecords(from:)`.
pub fn supersession_seed_records(
    records: &[&crate::supersession_corpus::SupersessionRecord],
) -> Vec<crate::seed_export::SeedFileRecord> {
    records
        .iter()
        .map(|record| {
            let mut seed = crate::seed_export::SeedFileRecord::new(
                &record.id,
                &record.content,
                &record.event_time,
                &format!("supersession/{}", record.attribute),
            );
            // filedAt follows capture_date when the corpus provides one
            // (contradiction pairs: shared event_time, +1s filing), else the
            // event instant — twin of the Swift
            // `captureDate: record.captureDate ?? record.eventTime`.
            seed.capture_date = Some(
                record
                    .capture_date
                    .clone()
                    .unwrap_or_else(|| record.event_time.clone()),
            );
            seed
        })
        .collect()
}

/// Everything one supersession lane run produces. Twin of Swift
/// `SupersessionLaneOutcome`.
pub struct SupersessionLaneOutcome {
    pub query_results: Vec<SupersessionQueryResult>,
    pub contradiction: Option<SupersessionContradictionOutcome>,
    /// Typed proving tier, when it ran.
    pub structured: Option<StructuredTierOutcome>,
    /// MXE-CT3 P4 tiered scoring (purpose runs + synthesis exactly-once +
    /// decoys), when the contradiction sweep ran.
    pub tiered: Option<TieredScoringOutcome>,
    /// Per-query, per-lane score snapshots when `lane_capture` was active.
    /// None when the flag was off. Twin of Swift `laneCapture`.
    pub lane_capture: Option<crate::replay_lane::LaneCapture>,
}

/// The typed proving lane scored against the planted pairs. Two figures:
/// the recency-unresolvable pairs must prove (target: all of them), and
/// zero PROVEN pairs outside the planted set — the supersession CHAINS
/// (same coordinate, DIFFERENT event times) must resolve as historical
/// succession, never as proof. Twin of Swift `StructuredTierOutcome`.
pub struct StructuredTierOutcome {
    /// Planted pairs (the proven-planted denominator).
    pub planted_count: usize,
    /// Planted pairs that surfaced as PROVEN blocks.
    pub proven_planted: usize,
    /// PROVEN pairs whose two source drawers are NOT a planted pair —
    /// the false-proof figure; any non-zero value here is a false proof.
    pub proven_outside_planted: usize,
    /// The report's own `proven:` count line.
    pub proven_reported: usize,
    /// The report's `historical:` count (the chains, resolved by time).
    pub historical_reported: usize,
    /// The report's `coverage: projected/scanned` figures.
    pub coverage_projected: usize,
    pub coverage_scanned: usize,
    /// Wall time of the fact filing + lens call.
    pub tier_seconds: f64,
}

/// One PROVEN block's source-drawer UUID pair. Twin of Swift
/// `ReportedProvenPair`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReportedProvenPair {
    pub a: String,
    pub b: String,
}

/// Counts + pairs parsed from the typed conflict-projection section.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ParsedTypedSection {
    pub proven: usize,
    pub historical: usize,
    pub projected: usize,
    pub scanned: usize,
    pub pairs: Vec<ReportedProvenPair>,
}

/// Parses the typed section (M0 §7) out of a contradiction-surface
/// report: the `proven:`/`historical:`/`coverage:` count lines plus the
/// source-drawer UUID pair under each `PROVEN` block (dense-row first
/// tokens). Redacted (`[restricted]`) and secret blocks carry no ids and
/// parse as counts only. Twin of Swift `parseTypedConflictSection`.
pub fn parse_typed_conflict_section(text: &str) -> ParsedTypedSection {
    let mut out = ParsedTypedSection::default();
    let mut current_block_ids: Vec<String> = Vec::new();
    let mut in_block = false;
    fn close_block(ids: &mut Vec<String>, pairs: &mut Vec<ReportedProvenPair>) {
        if ids.len() == 2 {
            pairs.push(ReportedProvenPair { a: ids[0].clone(), b: ids[1].clone() });
        }
        ids.clear();
    }
    for raw_line in text.split('\n') {
        let line = raw_line.trim();
        if let Some(n) = line.strip_prefix("proven: ").and_then(|v| v.parse().ok()) {
            out.proven = n;
        } else if let Some(n) = line.strip_prefix("historical: ").and_then(|v| v.parse().ok()) {
            out.historical = n;
        } else if let Some(rest) = line.strip_prefix("coverage: ") {
            let parts: Vec<&str> = rest.split('/').collect();
            if parts.len() == 2 {
                if let (Ok(p), Ok(s)) = (parts[0].parse(), parts[1].parse()) {
                    out.projected = p;
                    out.scanned = s;
                }
            }
        } else if line.starts_with("PROVEN ") {
            close_block(&mut current_block_ids, &mut out.pairs);
            in_block = true;
        } else if in_block {
            // Inside a block: detail lines are `key: value`; the two
            // dense rows open with the drawer UUID followed by the ` · `
            // separator. Any non-detail, non-dense line ends the block.
            if line.contains(" · ") {
                if let Some(first) = line.split(' ').next() {
                    current_block_ids.push(first.to_string());
                }
            } else if !line.contains(": ") {
                close_block(&mut current_block_ids, &mut out.pairs);
                in_block = false;
            }
        }
    }
    close_block(&mut current_block_ids, &mut out.pairs);
    out
}

/// Scores the typed section's PROVEN pairs against the planted pairs,
/// through the same UUID attribution map the lexical scorer uses. Twin
/// of Swift `scoreStructuredTier`.
pub fn score_structured_tier(
    planted: &[crate::supersession_corpus::ContradictionPair],
    uuid_by_record_id: &BTreeMap<String, String>,
    parsed: &ParsedTypedSection,
    tier_seconds: f64,
) -> StructuredTierOutcome {
    let mut planted_sets: Vec<std::collections::BTreeSet<String>> = Vec::new();
    for pair in planted {
        match (
            uuid_by_record_id.get(&pair.left_record_id),
            uuid_by_record_id.get(&pair.right_record_id),
        ) {
            (Some(l), Some(r)) => {
                planted_sets.push([l.clone(), r.clone()].into_iter().collect())
            }
            _ => planted_sets.push(std::collections::BTreeSet::new()),
        }
    }
    let pair_set = |p: &ReportedProvenPair| -> std::collections::BTreeSet<String> {
        [p.a.clone(), p.b.clone()].into_iter().collect()
    };
    let mut proven_planted = 0;
    for set in planted_sets.iter().filter(|s| !s.is_empty()) {
        if parsed.pairs.iter().any(|p| &pair_set(p) == set) {
            proven_planted += 1;
        }
    }
    let outside = parsed
        .pairs
        .iter()
        .filter(|p| !planted_sets.contains(&pair_set(p)))
        .count();
    StructuredTierOutcome {
        planted_count: planted.len(),
        proven_planted,
        proven_outside_planted: outside,
        proven_reported: parsed.proven,
        historical_reported: parsed.historical,
        coverage_projected: parsed.projected,
        coverage_scanned: parsed.scanned,
        tier_seconds,
    }
}

/// The contradiction sweep's outcome against the planted pairs. Twin of
/// Swift `SupersessionContradictionOutcome`.
pub struct SupersessionContradictionOutcome {
    /// Planted pairs in the corpus (the denominator).
    pub planted_count: usize,
    /// Planted pairs the hunter surfaced at ANY tier, either drawer order.
    pub detected_any_tier: usize,
    /// Planted pairs surfaced at the PROPOSED tier (auto-recorded edges).
    pub detected_proposed: usize,
    /// Reported pairs whose two drawers are NOT a planted pair. NOT labelled
    /// false positives: superseded chain versions genuinely conflict too —
    /// they are just resolvable by recency, which the planted pairs are not.
    pub flagged_outside_planted: usize,
    /// Wall time of the sweep call.
    pub hunt_seconds: f64,
}

/// One reported pair from the hunt output. Twin of Swift
/// `ReportedContradictionPair`; `tier` is "proposed" or "candidate".
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReportedContradictionPair {
    pub a: String,
    pub b: String,
    pub tier: String,
}

/// Parses `moot_hunt_contradictions` plain-text output into reported drawer
/// pairs. Recognized lines (leading whitespace ignored):
///   `PROPOSED <a> contradicts <b> (<cue>, score S, tunnel T)`
///   `CANDIDATE <a> vs <b> (<cue>, score S)`
/// Anything else (headers, snippets, guidance) is skipped. Twin of Swift
/// `parseHuntContradictionsReport(_:)`.
pub fn parse_hunt_contradictions_report(text: &str) -> Vec<ReportedContradictionPair> {
    let mut pairs: Vec<ReportedContradictionPair> = Vec::new();
    for raw_line in text.split('\n') {
        let line = raw_line.trim();
        if let Some(rest) = line.strip_prefix("PROPOSED ") {
            let mut parts = rest.splitn(2, " contradicts ");
            let (Some(a), Some(b_rest)) = (parts.next(), parts.next()) else { continue };
            let b = b_rest.split(" (").next().unwrap_or(b_rest);
            pairs.push(ReportedContradictionPair {
                a: a.to_string(),
                b: b.to_string(),
                tier: "proposed".to_string(),
            });
        } else if let Some(rest) = line.strip_prefix("CANDIDATE ") {
            let mut parts = rest.splitn(2, " vs ");
            let (Some(a), Some(b_rest)) = (parts.next(), parts.next()) else { continue };
            let b = b_rest.split(" (").next().unwrap_or(b_rest);
            pairs.push(ReportedContradictionPair {
                a: a.to_string(),
                b: b.to_string(),
                tier: "candidate".to_string(),
            });
        }
    }
    pairs
}

/// Scores the hunter's reported pairs against the planted pairs. Mapping is
/// through the write-assigned drawer UUIDs captured at ingest; a planted pair
/// whose records never got a UUID counts as undetected (truthful). Twin of
/// Swift `scoreContradictionSweep(...)`.
pub fn score_contradiction_sweep(
    planted: &[crate::supersession_corpus::ContradictionPair],
    uuid_by_record_id: &std::collections::BTreeMap<String, String>,
    reported: &[ReportedContradictionPair],
    hunt_seconds: f64,
) -> SupersessionContradictionOutcome {
    use std::collections::BTreeSet;
    // Unordered planted UUID pairs (empty set = unmappable, never matches).
    let planted_sets: Vec<BTreeSet<String>> = planted
        .iter()
        .map(|pair| {
            match (
                uuid_by_record_id.get(&pair.left_record_id),
                uuid_by_record_id.get(&pair.right_record_id),
            ) {
                (Some(l), Some(r)) => BTreeSet::from([l.clone(), r.clone()]),
                _ => BTreeSet::new(),
            }
        })
        .collect();
    let reported_sets: Vec<(BTreeSet<String>, &str)> = reported
        .iter()
        .map(|r| (BTreeSet::from([r.a.clone(), r.b.clone()]), r.tier.as_str()))
        .collect();
    let mut detected_any = 0usize;
    let mut detected_proposed = 0usize;
    for set in planted_sets.iter().filter(|s| !s.is_empty()) {
        let hits: Vec<&(BTreeSet<String>, &str)> =
            reported_sets.iter().filter(|(rs, _)| rs == set).collect();
        if !hits.is_empty() {
            detected_any += 1;
        }
        if hits.iter().any(|(_, tier)| *tier == "proposed") {
            detected_proposed += 1;
        }
    }
    let flagged_outside = reported_sets
        .iter()
        .filter(|(rs, _)| !planted_sets.contains(rs))
        .count();
    SupersessionContradictionOutcome {
        planted_count: planted.len(),
        detected_any_tier: detected_any,
        detected_proposed,
        flagged_outside_planted: flagged_outside,
        hunt_seconds,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tiered report parsing (MXE-CT3 P4)
// ─────────────────────────────────────────────────────────────────────────────

/// Per-lane counts parsed from a synthesis digest's `lane:` line. Twin of
/// Swift `ParsedTierLaneCounts`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ParsedTierLaneCounts {
    pub fetched: usize,
    pub returned: usize,
    pub promoted_away: usize,
    pub backfilled: usize,
}

/// One parsed tier section. Twin of Swift `ParsedTierSection`.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ParsedTierSection {
    pub pairs: Vec<ReportedProvenPair>,
    pub counts: Option<ParsedTierLaneCounts>,
    pub present: bool,
}

/// One `label=seconds` entry from the digest's `lane_seconds:` line. Twin of
/// Swift `ParsedLaneSeconds`.
#[derive(Debug, Clone, PartialEq)]
pub struct ParsedLaneSeconds {
    pub label: String,
    pub seconds: f64,
}

/// Everything parsed out of a tiered report (synthesis digest or single-tier
/// purpose report). Twin of Swift `ParsedTieredReport`.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ParsedTieredReport {
    pub tier1: ParsedTierSection,
    pub tier2: ParsedTierSection,
    pub tier3: ParsedTierSection,
    pub lane_seconds: Vec<ParsedLaneSeconds>,
    pub synthesis_wall_seconds: Option<f64>,
}

impl ParsedTieredReport {
    pub fn section(&self, tier: usize) -> &ParsedTierSection {
        match tier {
            1 => &self.tier1,
            2 => &self.tier2,
            _ => &self.tier3,
        }
    }
    fn section_mut(&mut self, tier: usize) -> &mut ParsedTierSection {
        match tier {
            1 => &mut self.tier1,
            2 => &mut self.tier2,
            _ => &mut self.tier3,
        }
    }
}

/// Parses the MXE-CT3 tiered sections out of a `moot_hunt_contradictions`
/// report — either the synthesis digest appended to the legacy sweep report
/// (tier absent/"all") or a single-tier purpose report.
///
/// Line formats are pinned against the ONE shared renderer both surfaces
/// route through — recipe_tools.rs `tiered_section_lines` (:291-388) and its
/// Swift twin RecipeTools.swift `tieredSectionLines` (:1368-1424); see the
/// Swift twin `parseTieredSections` for the line inventory. Tolerant of the
/// legacy report prefix: everything before the first tier header is ignored,
/// which also keeps the legacy `PROPOSED`/`CANDIDATE` lines and the typed
/// conflict-projection section out of this parser.
pub fn parse_tiered_sections(text: &str) -> ParsedTieredReport {
    // Header strings must match the renderer byte for byte (the em dash is
    // part of the wire contract — recipe_tools::TIER1_HEADER etc.).
    const TIER1_HEADER: &str = "TIER 1 — CONTRADICTION (proven)";
    const TIER2_HEADER: &str = "TIER 2 — CONFLICT CANDIDATE";
    const TIER3_HEADER: &str = "TIER 3 — DIVERGENCE";

    let mut report = ParsedTieredReport::default();
    let mut current_tier: Option<usize> = None;
    let mut pending_tier1_ids: Vec<String> = Vec::new();

    fn close_tier1_block(pending: &mut Vec<String>, report: &mut ParsedTieredReport) {
        if pending.len() == 2 {
            report.tier1.pairs.push(ReportedProvenPair {
                a: pending[0].clone(),
                b: pending[1].clone(),
            });
        }
        pending.clear();
    }

    for raw_line in text.split('\n') {
        let line = raw_line.trim();
        if line == TIER1_HEADER || line == TIER2_HEADER || line == TIER3_HEADER {
            close_tier1_block(&mut pending_tier1_ids, &mut report);
            let tier = if line == TIER1_HEADER {
                1
            } else if line == TIER2_HEADER {
                2
            } else {
                3
            };
            current_tier = Some(tier);
            report.section_mut(tier).present = true;
            continue;
        }
        if let Some(rest) = line.strip_prefix("lane_seconds: ") {
            close_tier1_block(&mut pending_tier1_ids, &mut report);
            current_tier = None;
            for part in rest.split(' ') {
                let mut kv = part.splitn(2, '=');
                if let (Some(label), Some(value)) = (kv.next(), kv.next()) {
                    if let Ok(seconds) = value.parse::<f64>() {
                        report.lane_seconds.push(ParsedLaneSeconds {
                            label: label.to_string(),
                            seconds,
                        });
                    }
                }
            }
            continue;
        }
        if let Some(rest) = line.strip_prefix("synthesis_wall_seconds: ") {
            close_tier1_block(&mut pending_tier1_ids, &mut report);
            current_tier = None;
            report.synthesis_wall_seconds = rest.parse::<f64>().ok();
            continue;
        }
        let Some(tier) = current_tier else { continue };
        if let Some(rest) = line.strip_prefix("lane: ") {
            // "lane: fetched F, returned R, promotedAway P, backfilled B"
            let mut values: std::collections::BTreeMap<&str, usize> =
                std::collections::BTreeMap::new();
            for field in rest.split(", ") {
                let parts: Vec<&str> = field.split(' ').collect();
                if parts.len() == 2 {
                    if let Ok(n) = parts[1].parse::<usize>() {
                        values.insert(parts[0], n);
                    }
                }
            }
            if let (Some(&f), Some(&r), Some(&p), Some(&b)) = (
                values.get("fetched"),
                values.get("returned"),
                values.get("promotedAway"),
                values.get("backfilled"),
            ) {
                report.section_mut(tier).counts = Some(ParsedTierLaneCounts {
                    fetched: f,
                    returned: r,
                    promoted_away: p,
                    backfilled: b,
                });
            }
            continue;
        }
        match tier {
            1 => {
                if line.starts_with("PROVEN ") {
                    // A new block opens; ids follow as dense rows.
                    close_tier1_block(&mut pending_tier1_ids, &mut report);
                } else if line.starts_with("a conflicting claim exists") {
                    // Restricted finding: coordinate digest only, no ids.
                    close_tier1_block(&mut pending_tier1_ids, &mut report);
                } else if line.contains(" · ") {
                    // Dense row: the drawer UUID is the first token (same
                    // contract parse_typed_conflict_section reads).
                    if let Some(first) = line.split(' ').next() {
                        pending_tier1_ids.push(first.to_string());
                    }
                }
            }
            _ => {
                // Tier 2/3 finding: `<a> vs <b> (<cueKind>, score S)`.
                let mut parts = line.splitn(2, " vs ");
                if let (Some(a), Some(b_rest)) = (parts.next(), parts.next()) {
                    let b = b_rest.split(" (").next().unwrap_or(b_rest);
                    report.section_mut(tier).pairs.push(ReportedProvenPair {
                        a: a.to_string(),
                        b: b.to_string(),
                    });
                }
            }
        }
    }
    close_tier1_block(&mut pending_tier1_ids, &mut report);
    report
}

// ─────────────────────────────────────────────────────────────────────────────
// Tiered scoring (MXE-CT3 P4)
// ─────────────────────────────────────────────────────────────────────────────

/// Unordered LOWERCASED UUID sets for the planted pairs. All tiered matching
/// is case-insensitive: Swift `UUID.uuidString` is UPPERCASE while Rust's
/// `Uuid::to_string()` is lowercase (precedent c95910dff), so both sides of
/// every comparison are lowercased before matching. An unmappable pair
/// yields an empty set, which never matches. Twin of Swift
/// `lowercasedPlantedSets`.
pub fn lowercased_planted_sets(
    planted: &[crate::supersession_corpus::ContradictionPair],
    uuid_by_record_id: &BTreeMap<String, String>,
) -> Vec<std::collections::BTreeSet<String>> {
    planted
        .iter()
        .map(|pair| {
            match (
                uuid_by_record_id.get(&pair.left_record_id),
                uuid_by_record_id.get(&pair.right_record_id),
            ) {
                (Some(l), Some(r)) => {
                    [l.to_lowercase(), r.to_lowercase()].into_iter().collect()
                }
                _ => std::collections::BTreeSet::new(),
            }
        })
        .collect()
}

fn lowercased_pair_set(pair: &ReportedProvenPair) -> std::collections::BTreeSet<String> {
    [pair.a.to_lowercase(), pair.b.to_lowercase()].into_iter().collect()
}

/// Counts planted pairs present (either drawer order, case-insensitive) in
/// a list of reported pairs — the per-tier purpose-run recall numerator.
/// Twin of Swift `countDetectedPlanted`.
pub fn count_detected_planted(
    planted: &[crate::supersession_corpus::ContradictionPair],
    uuid_by_record_id: &BTreeMap<String, String>,
    reported_pairs: &[ReportedProvenPair],
) -> usize {
    let reported_sets: Vec<std::collections::BTreeSet<String>> =
        reported_pairs.iter().map(lowercased_pair_set).collect();
    lowercased_planted_sets(planted, uuid_by_record_id)
        .iter()
        .filter(|s| !s.is_empty() && reported_sets.contains(s))
        .count()
}

/// Counts synthesis dedup failures: planted pairs (word-valued AND
/// divergence) appearing in MORE than one tier section of the synthesis
/// digest. The synthesis contract is exactly-once at the highest applicable
/// tier (promote-to-highest + backfill), so any pair in two sections is a
/// tier-inflation / dedup failure. Absence from all sections is undetected,
/// not inflation. Twin of Swift `countTierInflation`.
pub fn count_tier_inflation(
    planted: &[crate::supersession_corpus::ContradictionPair],
    uuid_by_record_id: &BTreeMap<String, String>,
    synthesis: &ParsedTieredReport,
) -> usize {
    let section_sets: Vec<Vec<std::collections::BTreeSet<String>>> = [1usize, 2, 3]
        .iter()
        .map(|&tier| {
            synthesis
                .section(tier)
                .pairs
                .iter()
                .map(lowercased_pair_set)
                .collect()
        })
        .collect();
    lowercased_planted_sets(planted, uuid_by_record_id)
        .iter()
        .filter(|set| {
            !set.is_empty()
                && section_sets.iter().filter(|s| s.contains(set)).count() > 1
        })
        .count()
}

/// Decoy hit counts, split by severity. Twin of Swift `DecoyHitCounts`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DecoyHitCounts {
    /// Marker-supersession and distinct-entity decoys flagged anywhere that
    /// counts (tier sections, legacy PROPOSED). MUST be 0.
    pub hard: usize,
    /// Unit-equivalent decoys flagged — the known limitation (the lexical
    /// digit cue cannot equate "90s" and "1.5min"), reported separately and
    /// never as a hard failure.
    pub known_limitation: usize,
}

/// Scores the planted decoys against every tiered report from the run plus
/// the legacy sweep's reported pairs. Hit surfaces pinned as in the Swift
/// twin `countDecoyHits`: tier sections (any report) and legacy PROPOSED
/// lines count; legacy CANDIDATE lines (borderline adjudication feed) and
/// typed-section HISTORICAL lines (correct classification for the marker
/// shape) do not.
pub fn count_decoy_hits(
    decoys: &[crate::supersession_corpus::DecoyPair],
    uuid_by_record_id: &BTreeMap<String, String>,
    tiered_reports: &[&ParsedTieredReport],
    legacy_reported: &[ReportedContradictionPair],
) -> DecoyHitCounts {
    let mut flagged_sets: Vec<std::collections::BTreeSet<String>> = Vec::new();
    for report in tiered_reports {
        for tier in 1..=3usize {
            flagged_sets.extend(report.section(tier).pairs.iter().map(lowercased_pair_set));
        }
    }
    flagged_sets.extend(
        legacy_reported
            .iter()
            .filter(|r| r.tier == "proposed")
            .map(|r| {
                [r.a.to_lowercase(), r.b.to_lowercase()]
                    .into_iter()
                    .collect::<std::collections::BTreeSet<String>>()
            }),
    );

    let mut hard = 0usize;
    let mut known_limitation = 0usize;
    for decoy in decoys {
        let (Some(l), Some(r)) = (
            uuid_by_record_id.get(&decoy.left_record_id),
            uuid_by_record_id.get(&decoy.right_record_id),
        ) else {
            continue;
        };
        let set: std::collections::BTreeSet<String> =
            [l.to_lowercase(), r.to_lowercase()].into_iter().collect();
        if !flagged_sets.contains(&set) {
            continue;
        }
        if decoy.kind == crate::supersession_corpus::DECOY_KIND_UNIT_EQUIVALENT {
            known_limitation += 1;
        } else {
            hard += 1;
        }
    }
    DecoyHitCounts { hard, known_limitation }
}

/// Everything the P4 tiered scoring produced. Twin of Swift
/// `TieredScoringOutcome` — see that type's field docs.
pub struct TieredScoringOutcome {
    pub tier2_planted_count: usize,
    pub tier2_detected: usize,
    pub tier2_purpose_seconds: f64,
    pub tier3_planted_count: usize,
    pub tier3_detected: usize,
    pub tier3_purpose_seconds: f64,
    /// Tier-1 figures are None unless --structured-tier ran: the typed lane
    /// has no material before fact filing.
    pub tier1_planted_count: Option<usize>,
    pub tier1_detected: Option<usize>,
    pub tier1_purpose_seconds: Option<f64>,
    pub decoy_hits: DecoyHitCounts,
    pub tier_inflation: usize,
    /// Parsed from the synthesis digest's `lane_seconds:` line.
    pub lane_seconds: Vec<ParsedLaneSeconds>,
    /// Parsed from the synthesis digest's `synthesis_wall_seconds:` line.
    pub synthesis_wall_seconds: Option<f64>,
}

/// Returns the current UTC wall-clock as an ISO8601 string (YYYY-MM-DDTHH:MM:SSZ).
///
/// Uses only `std::time` — no chrono dependency. Civil-date decomposition
/// from the Howard Hinnant algorithm. Called for lane-capture timestamps
/// only (diagnostic path) — never on the benchmark hot path.
fn current_iso8601_for_capture() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;
    let z    = secs / 86400 + 719_468;
    let era  = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe  = z - era * 146_097;
    let yoe  = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y0   = yoe + era * 400;
    let doy  = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp   = (5 * doy + 2) / 153;
    let d    = doy - (153 * mp + 2) / 5 + 1;
    let m    = if mp < 10 { mp + 3 } else { mp - 9 };
    let y    = if m <= 2 { y0 + 1 } else { y0 };
    let rem  = (secs % 86_400 + 86_400) as u64 % 86_400;
    let h    = rem / 3_600;
    let min  = (rem % 3_600) / 60;
    let sec  = rem % 60;
    format!("{y:04}-{m:02}-{d:02}T{h:02}:{min:02}:{sec:02}Z")
}

/// Ingests the whole corpus into ONE estate in chronological order, then runs
/// every query against the settled estate, then (unless skipped) runs the
/// contradiction sweep — strictly AFTER the ranking queries, because the
/// hunter records PROPOSED tunnels and the ranking measurement must not see
/// estate mutations it would not see in a ranking-only run.
pub fn run_supersession_lane(
    corpus: &SupersessionCorpus,
    config: &SupersessionRunConfig,
) -> Result<SupersessionLaneOutcome, MCPError> {
    // Reuses the LME lane's scratch-estate plumbing: the same posture marker,
    // the same /tmp/lme-bench-* prefix its guarded teardown contracts on.
    // EPHEMERAL posture, always, by default. The estate's SQLCipher key is
    // minted in the serve process's memory and dies with it — no Keychain
    // item, no on-disk key, so a benchmark run cannot leave residue behind.
    // Accumulating orphaned keys is a real system-stability hazard, not just
    // untidiness ( operator ruling 2026-07-31), and a lane that provisions estates in
    // bulk is exactly where that accumulates.
    // C1: shape is configurable (--shape ram routes the served process to the
    // InMemory backend); default remains the real disk path.
    let endpoint = lme_endpoint_config(&config.scratch_dir, &config.moot_binary_path,
                                       config.posture, config.shape,
                                       config.bench_clock_epoch.as_deref())
        .map_err(|e| MCPError { description: e })?;
    let mut client = MCPClient::new(endpoint);
    client.connect()?;

    // ── Ingest, chronologically ───────────────────────────────────────────
    // Sorted by event_time with the record id as tiebreak, so both legs file
    // ties (same-instant records: every chain's v0, every contradiction
    // pair) in one deterministic order. Filing a chain out of order would
    // test the harness's sorting rather than the product's temporal
    // handling.
    let mut ordered: Vec<&crate::supersession_corpus::SupersessionRecord> =
        corpus.records.iter().collect();
    ordered.sort_by(|a, b| {
        a.event_time
            .cmp(&b.event_time)
            .then_with(|| a.id.cmp(&b.id))
    });
    // Corpus record id → the drawer UUID the product assigned on write. The
    // contradiction sweep reports drawer UUIDs, so this map is how a reported
    // pair is attributed back to a planted pair. The batch path fills it from
    // the import receipt's id_map block; the live path fills it from each
    // write's response.
    let mut uuid_by_record_id: BTreeMap<String, String> = BTreeMap::new();
    let seed_records = supersession_seed_records(&ordered);
    match config.seed_path {
        crate::seed_export::SeedPathMode::Batch => {
            // Batch seeding (ruling 8D5B8053): emit schema v1 in chronological
            // order (file order IS ingestion order) and load it with ONE
            // `moot_json_import`. Zero per-record writes, zero per-item drains.
            let seed_name = format!("supersession-{}", config.seed);
            let seed_data =
                crate::seed_export::emit_seed_json(&seed_name, &seed_records, &[], &[]);
            let seed_path =
                crate::seed_export::write_seed_file(&seed_data, &config.scratch_dir, &seed_name)?;
            let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
            args.insert(
                "path".to_string(),
                JsonValue::String(seed_path.to_string_lossy().into_owned()),
            );
            // return_id_map: the reply carries a second text block holding
            // the record-id -> drawer-UUID map (see seed_id_map).
            args.insert("return_id_map".to_string(), JsonValue::Bool(true));
            let imported = client.call_tool(
                crate::aria_v2_surface::JSON_IMPORT,
                args,
                &crate::config::ResultFormat::MootV2,
            )?;
            // v2: drawer count is in structuredContent.data.drawers_written, not text.
            // Anything other than the expected count (validation failure,
            // collision, vault-off) is a hard failure — a partially seeded
            // estate must never be scored.
            if imported.drawers_written != Some(seed_records.len() as i64) {
                return Err(MCPError {
                    description: format!(
                        "supersession: moot_json_import did not confirm {} drawers — \
                         refusing to score an unseeded estate. Got: {}",
                        seed_records.len(),
                        imported.drawers_written
                            .map(|n| n.to_string())
                            .unwrap_or_else(|| "(no structured data)".to_string())
                    ),
                });
            }
            // The import receipt's id_map names a drawer for every seeded
            // record; seed_id_map errors on a short map rather than let a
            // partial map score. Twin of the Swift block.
            uuid_by_record_id = crate::seed_export::seed_id_map(
                &imported.text_blocks,
                seed_records.len(),
                &format!("supersession seed={}", config.seed),
            )?
            .into_iter()
            .collect();
        }
        crate::seed_export::SeedPathMode::Live => {
            // Retained slow lane for periodic equivalence re-proving:
            // per-record live capture, exactly the pre-batch protocol.
            for record in &ordered {
                let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
                args.insert("content".to_string(), JsonValue::String(record.content.clone()));
                // Subject required at the moot file_memory boundary (PR-02): deterministic
                // first-sentence extraction (PR-07 deterministicSubject algorithm).
                args.insert("subject".to_string(), JsonValue::String(crate::subject_generator::deterministic_subject(&record.content)));
                args.insert(
                    "location".to_string(),
                    JsonValue::String(format!("supersession/{}", record.attribute)),
                );
                args.insert(
                    "event_time".to_string(),
                    JsonValue::String(record.event_time.clone()),
                );
                let written = client.call_tool(
                    crate::aria_v2_surface::FILE_MEMORY,
                    args,
                    &crate::config::ResultFormat::MootV2,
                )?;
                if let Some(uuid) = written.write_assigned_id {
                    uuid_by_record_id.insert(record.id.clone(), uuid);
                }
            }
        }
    }

    // Settle the encode queue and assert that it settled: querying a
    // partially-indexed estate returns real-looking but understated rankings
    // with no visible signal. The shared encode barrier handles both polling
    // and the fresh-estate grace window; a run whose drain did not converge
    // fails loudly rather than publishing a silently wrong number.
    let barrier_outcome = wait_for_encode_drain(&mut client, "supersession seed", 300.0);
    if !barrier_outcome.converged {
        return Err(MCPError {
            description: "supersession: encode drain did not converge within 300s — refusing to \
                         query a partially-indexed estate. Re-run on an unloaded machine."
                .to_string(),
        });
    }

    // Record the import timestamp (encode converged + UUID map built) for
    // lane-capture clock-delta correlation. Empty string when capture is off
    // so no allocation is needed on the hot path.
    let import_timestamp = if config.lane_capture {
        current_iso8601_for_capture()
    } else {
        String::new()
    };

    // Accumulates per-query lane snapshots when lane capture is active.
    let mut query_snapshots: Vec<crate::replay_lane::QueryLaneSnapshot> = Vec::new();

    // Deterministic in-fiction `now` for dream and hunt: one day past the
    // corpus's last event, so temporal math runs on the corpus's timeline and
    // the output is a pure function of the estate, not the wall clock.
    let fiction_now: String = {
        let last_event = corpus
            .records
            .iter()
            .map(|r| r.event_time.as_str())
            .max()
            .unwrap_or("2026-01-01T00:00:00Z");
        crate::supersession_corpus::epoch_seconds_from_iso8601(last_event)
            .map(|s| crate::supersession_corpus::iso8601_from_epoch_seconds(s + 86_400))
            .unwrap_or_else(|| last_event.to_string())
    };

    // MXE-CT3 P4: section size for the tiered digest and the purpose runs —
    // sized to cover every planted tiered pair (word-valued + divergence) so
    // recall is not capped by the section window, clamped to the MCP
    // boundary's 1...50 domain. Twin of the Swift `purposeTopK`.
    let planted_tiered_total = corpus.contradictions.len() + corpus.divergences.len();
    let purpose_top_k = planted_tiered_total.clamp(1, 50);

    let mut contradiction: Option<SupersessionContradictionOutcome> = None;
    let mut synthesis_parsed: Option<ParsedTieredReport> = None;
    let mut legacy_reported_pairs: Vec<ReportedContradictionPair> = Vec::new();

    // ── Dream (the un-starving step) ──────────────────────────────────────
    // In dream mode the SCORED HUNT RUNS FIRST: moot_dream runs its own
    // internal hunt sweep whose proposals dedup durably, so a scored hunt
    // AFTER dream would see its planted pairs as already-settled and report
    // no ids — silently undercounting detection. Hunting first captures the
    // PROPOSED ids on a virgin estate; dream's internal hunt then dedups
    // against them, which is harmless. The ranking queries thereafter run
    // against the DREAMED estate — matrix priors registered, dream-derived
    // tunnels present — which is the deployed steady state this lane exists
    // to measure. `--skip-dream` preserves the virgin-estate cell with the
    // original order (queries first, hunt last). Twin of the Swift branch.
    if config.dream_before_queries {
        // Scored hunt runs whenever ANY tiered class was planted: contradictions,
        // divergences, OR decoys. A run with --contradictions 0 --divergences 5
        // must still score the divergence class. Twin of the Swift branch.
        if config.contradiction_sweep
            && (!corpus.contradictions.is_empty()
                || !corpus.divergences.is_empty()
                || !corpus.decoys.is_empty())
        {
            let scored = run_scored_hunt(
                &mut client, corpus, &uuid_by_record_id, &fiction_now, purpose_top_k,
            )?;
            contradiction = Some(scored.0);
            synthesis_parsed = Some(scored.1);
            legacy_reported_pairs = scored.2;
        }
        let mut dream_args: BTreeMap<String, JsonValue> = BTreeMap::new();
        dream_args.insert("now".to_string(), JsonValue::String(fiction_now.clone()));
        // Protocol v2: full-coverage association sweep rides the dream.
        dream_args.insert("associates".to_string(), JsonValue::String("all".to_string()));
        let dream_result = client.call_tool(
            crate::aria_v2_surface::DREAM,
            dream_args,
            &crate::config::ResultFormat::MootV2,
        )?;
        // v2: "matrix rebuilt" text is absent; assert meta.status == "completed"
        // (weaker — matrix rebuild not independently confirmable on v2).
        if dream_result.meta_status.as_deref() != Some("completed") {
            return Err(MCPError {
                description: format!(
                    "supersession: moot_dream did not complete (meta.status: {}) — \
                     the matrix-steering presets cannot be claimed measurable.",
                    dream_result.meta_status.as_deref().unwrap_or("nil")
                ),
            });
        }
    }

    // ── Query ─────────────────────────────────────────────────────────────
    // One guard sampler for the entire estate: probes on the first query and
    // caches the verdict (OncePerLeg default). The supersession lane uses a
    // single shared estate rather than provisioning per-query, so one probe
    // at the start of the ranking pass is the correct sampling unit. Any
    // frozen/degenerate result from the estate is caught and the entire run
    // is excluded from the scored aggregate. Twin of Swift `LegGuardSampler`.
    let mut guard_sampler = LegGuardSampler::new(config.guard_sampling_policy);
    let mut results: Vec<SupersessionQueryResult> = Vec::new();
    // Content prefix → record id, so a ranked hit can be attributed back to
    // the corpus record that produced it. Ids are assigned by the product on
    // write, so matching happens on content. 80 chars matches the Swift leg.
    // Drawer UUID (lowercased) → record id, so a ranked hit is attributed
    // back to the corpus record that produced it. Both seed paths fill
    // `uuid_by_record_id` (live: write responses; batch: the attribution
    // pass), and every recall-family reply row leads with the drawer UUID —
    // so UUID attribution is exact on both paths, where the previous
    // content-prefix line matching depended on the reply carrying
    // content-derived text (true for live-filed subjects, false for batch
    // rows, which render "(no subject)"). Lowercased on both sides: Swift
    // renders UUIDs uppercase, Rust lowercase (precedent c95910dff). Twin
    // of the Swift `recordIDByUUID` block.
    let record_id_by_uuid: HashMap<String, String> = uuid_by_record_id
        .iter()
        .map(|(record_id, uuid)| (uuid.to_lowercase(), record_id.clone()))
        .collect();

    for query in &corpus.queries {
        // Degeneracy guard probe (C5): three fixed queries that should return
        // distinct rankings on a functional estate. OncePerLeg (default) runs
        // this on the first query only and caches the verdict; PerUnit probes
        // every query. Results with guard_healthy=false are excluded from
        // scoring. Twin of Swift guard probe block.
        let (guard_healthy, _guard_diagnostic, _was_probed) = guard_sampler.probe(|| {
            let probe_queries = ["time", "version", "fact"];
            probe_queries.iter().map(|&q| {
                let mut probe_args: BTreeMap<String, JsonValue> = BTreeMap::new();
                probe_args.insert("query".to_string(), JsonValue::String(q.to_string()));
                match client.call_tool(
                    crate::aria_v2_surface::MEMORY_SEARCH,
                    probe_args,
                    &crate::config::ResultFormat::MootV2,
                ) {
                    Ok(r) => r.ordered_ids,
                    Err(_) => vec![], // silenced: < 2 responses → guard stays Healthy
                }
            }).collect()
        });

        let start = Instant::now();
        let query_ts = if config.lane_capture { current_iso8601_for_capture() } else { String::new() };
        let verb = if config.recall_shape.is_none() {
            crate::aria_v2_surface::MEMORY_SEARCH
        } else {
            crate::aria_v2_surface::RECALL_SHAPED
        };
        let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
        args.insert("query".to_string(), JsonValue::String(query.question.clone()));
        if let Some(ref shape) = config.recall_shape {
            args.insert("preset".to_string(), JsonValue::String(shape.clone()));
        }
        // Thread explain: true when lane capture is active so RecallExplainer
        // appends per-hit score lines to the text output.
        if config.lane_capture {
            args.insert("explain".to_string(), JsonValue::Bool(true));
        }
        let result = client.call_tool(verb, args, &crate::config::ResultFormat::MootV2)?;
        let latency = start.elapsed().as_secs_f64();

        // Parse per-hit lane scores from the explain output when active.
        if config.lane_capture {
            query_snapshots.push(crate::replay_lane::parse_lane_capture_lines(
                &result.text_blocks, &query.id, &query_ts));
        }

        // Attribute each ranked reply UUID back to a corpus record.
        let ranked_ids: Vec<String> = result
            .ordered_ids
            .iter()
            .filter_map(|uuid| record_id_by_uuid.get(&uuid.to_lowercase()).cloned())
            .collect();

        let current_rank = ranked_ids
            .iter()
            .position(|id| *id == query.current_record_id)
            .map(|i| i + 1);
        let stale_ranks: Vec<usize> = query
            .superseded_record_ids
            .iter()
            .filter_map(|sid| ranked_ids.iter().position(|id| id == sid).map(|i| i + 1))
            .collect();
        // A current version that never appears cannot win, however few stale
        // versions surfaced — absence is a loss, not a bye.
        let current_wins = match current_rank {
            Some(cr) => stale_ranks.iter().all(|&sr| cr < sr),
            None => false,
        };
        let stale_in_top_k = stale_ranks.iter().filter(|&&r| r <= config.top_k).count();
        results.push(SupersessionQueryResult {
            query_id: query.id.clone(),
            current_rank,
            stale_ranks,
            current_wins,
            stale_in_top_k,
            latency_seconds: latency,
            guard_healthy,
        });
    }

    // ── Contradiction sweep, virgin-estate mode ───────────────────────────
    // Without dream, the sweep runs AFTER every ranking query so the ranking
    // measurement never sees the hunter's tunnel writes.
    // Gate: any tiered class planted (contradictions, divergences, or decoys).
    if !config.dream_before_queries
        && config.contradiction_sweep
        && (!corpus.contradictions.is_empty()
            || !corpus.divergences.is_empty()
            || !corpus.decoys.is_empty())
    {
        let scored = run_scored_hunt(
            &mut client, corpus, &uuid_by_record_id, &fiction_now, purpose_top_k,
        )?;
        contradiction = Some(scored.0);
        synthesis_parsed = Some(scored.1);
        legacy_reported_pairs = scored.2;
    }

    // ── MXE-CT3 P4: tier-2/3 purpose runs ─────────────────────────────────
    // Single-tier calls are READ-ONLY purpose searches (nothing filed, no
    // tunnel writes — recipe_tools run_hunt_contradictions single-tier arm),
    // so running them here — after dream in dream mode, after the ranking
    // queries in both modes — is safe: they cannot mutate the estate, so
    // neither the ranking measurement nor the scored sweep can see anything
    // it would not see in a run without them. The hunt-before-dream ordering
    // above is untouched. Gated on the scored hunt having run: the purpose
    // runs ride the same --skip-contradictions switch, and their planted
    // classes are attributed through the same UUID map. Twin of the Swift
    // block.
    let mut tier2_purpose: Option<(ParsedTieredReport, f64)> = None;
    let mut tier3_purpose: Option<(ParsedTieredReport, f64)> = None;
    if synthesis_parsed.is_some() {
        tier2_purpose = Some(run_purpose_search(&mut client, &fiction_now, 2, purpose_top_k)?);
        tier3_purpose = Some(run_purpose_search(&mut client, &fiction_now, 3, purpose_top_k)?);
    }

    // ── Structured (typed) proving tier ───────────────────────────────────
    // Runs LAST: filing KGFacts mutates the estate, and neither the ranking
    // queries nor the lexical sweep may see those writes. One fact per
    // corpus record, anchored to the record's ingest drawer via source_id —
    // the anchor is what gives the typed lane its validity instants (drawer
    // event times) and its dense-row attribution (proven-planted scoring maps
    // PROVEN source UUIDs back to planted pairs). The chains file too, on
    // purpose: same coordinate at DIFFERENT instants must resolve as
    // historical succession, never proof — that discrimination IS the
    // false-proof measurement.
    let mut structured: Option<StructuredTierOutcome> = None;
    if config.structured_tier {
        let tier_start = std::time::Instant::now();
        for record in &ordered {
            let Some(drawer_uuid) = uuid_by_record_id.get(&record.id) else { continue };
            let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
            args.insert("subject".to_string(), JsonValue::String(record.entity.clone()));
            args.insert("predicate".to_string(), JsonValue::String(record.attribute.clone()));
            args.insert("object".to_string(), JsonValue::String(record.value.clone()));
            args.insert("source_id".to_string(), JsonValue::String(drawer_uuid.clone()));
            client.call_tool(crate::aria_v2_surface::FILE_FACT, args, &crate::config::ResultFormat::MootV2)?;
        }
        let lens_result = client.call_tool(
            crate::aria_v2_surface::LENS_CONTRADICTION,
            BTreeMap::new(),
            &crate::config::ResultFormat::MootV2,
        )?;
        let tier_seconds = tier_start.elapsed().as_secs_f64();
        let lens_text = lens_result.text_blocks.join("\n");
        if !lens_text.contains("proven: ") {
            return Err(MCPError {
                description: format!(
                    "supersession: moot_lens_contradiction returned no typed \
                     conflict-projection section — the structured tier cannot be \
                     scored. Response: {}",
                    &lens_text.chars().take(300).collect::<String>()
                ),
            });
        }
        structured = Some(score_structured_tier(
            &corpus.contradictions,
            &uuid_by_record_id,
            &parse_typed_conflict_section(&lens_text),
            tier_seconds,
        ));
    }

    // ── MXE-CT3 P4: tier-1 purpose run ────────────────────────────────────
    // Runs AFTER the fact filing above so the typed lane has material —
    // before --structured-tier files KGFacts there is nothing for tier 1 to
    // prove, and a purpose run against the factless estate would score a
    // structural 0 and label it measured. The call is UNCONDITIONAL inside
    // this branch (f0ede71f2 precedent: a coverage call gated on incidental
    // state silently skips on the alternate path) — only the two deliberate
    // switches gate it: --structured-tier (material exists) and the
    // contradiction sweep having run (the tiered scoring lane is active).
    // Twin of the Swift block.
    let mut tier1_purpose: Option<(ParsedTieredReport, f64)> = None;
    if config.structured_tier && synthesis_parsed.is_some() {
        tier1_purpose = Some(run_purpose_search(&mut client, &fiction_now, 1, purpose_top_k)?);
    }

    // ── MXE-CT3 P4: assemble the tiered scoring outcome ───────────────────
    // Per-tier recall of each tier's planted class: tier 2 ← the word-valued
    // pairs (wordExclusion cue), tier 3 ← the digit-divergence pairs
    // (valueDivergence cue), tier 1 ← the word-valued pairs proven by the
    // typed lane after fact filing (the F18/F19 structured-tier path).
    let mut tiered: Option<TieredScoringOutcome> = None;
    if let (Some(synthesis), Some(t2), Some(t3)) =
        (&synthesis_parsed, &tier2_purpose, &tier3_purpose)
    {
        let mut tiered_reports: Vec<&ParsedTieredReport> = vec![synthesis, &t2.0, &t3.0];
        if let Some(t1) = &tier1_purpose {
            tiered_reports.push(&t1.0);
        }
        let decoy_hits = count_decoy_hits(
            &corpus.decoys,
            &uuid_by_record_id,
            &tiered_reports,
            &legacy_reported_pairs,
        );
        let planted_all: Vec<crate::supersession_corpus::ContradictionPair> = corpus
            .contradictions
            .iter()
            .chain(corpus.divergences.iter())
            .cloned()
            .collect();
        tiered = Some(TieredScoringOutcome {
            tier2_planted_count: corpus.contradictions.len(),
            tier2_detected: count_detected_planted(
                &corpus.contradictions, &uuid_by_record_id, &t2.0.tier2.pairs),
            tier2_purpose_seconds: t2.1,
            tier3_planted_count: corpus.divergences.len(),
            tier3_detected: count_detected_planted(
                &corpus.divergences, &uuid_by_record_id, &t3.0.tier3.pairs),
            tier3_purpose_seconds: t3.1,
            tier1_planted_count: tier1_purpose.as_ref().map(|_| corpus.contradictions.len()),
            tier1_detected: tier1_purpose.as_ref().map(|t1| {
                count_detected_planted(
                    &corpus.contradictions, &uuid_by_record_id, &t1.0.tier1.pairs)
            }),
            tier1_purpose_seconds: tier1_purpose.as_ref().map(|t1| t1.1),
            decoy_hits,
            tier_inflation: count_tier_inflation(
                &planted_all, &uuid_by_record_id, synthesis),
            lane_seconds: synthesis.lane_seconds.clone(),
            synthesis_wall_seconds: synthesis.synthesis_wall_seconds,
        });
    }

    client.disconnect();

    let lane_capture_result = if config.lane_capture {
        Some(crate::replay_lane::LaneCapture {
            import_timestamp,
            snapshots: query_snapshots,
        })
    } else {
        None
    };

    Ok(SupersessionLaneOutcome {
        query_results: results,
        contradiction,
        structured,
        tiered,
        lane_capture: lane_capture_result,
    })
}

/// One scored contradiction sweep against the planted pairs. Position in the
/// lane depends on the dream mode — see `run_supersession_lane`. Passes
/// `top_k` so the appended synthesis digest sections can hold every planted
/// pair (the legacy report lines the legacy parser reads are unaffected by
/// top_k — it shapes only the tiered digest). Also returns the parsed
/// synthesis digest and the legacy reported pairs for the P4 tiered scoring.
/// Twin of the Swift `runScoredHunt` closure.
fn run_scored_hunt(
    client: &mut MCPClient,
    corpus: &SupersessionCorpus,
    uuid_by_record_id: &BTreeMap<String, String>,
    fiction_now: &str,
    top_k: usize,
) -> Result<
    (SupersessionContradictionOutcome, ParsedTieredReport, Vec<ReportedContradictionPair>),
    MCPError,
> {
    let mut hunt_args: BTreeMap<String, JsonValue> = BTreeMap::new();
    hunt_args.insert("now".to_string(), JsonValue::String(fiction_now.to_string()));
    // Integral f64s serialize through serde_json as integers (json_value.rs
    // header), so the boundary's integer-typed top_k decodes cleanly.
    hunt_args.insert("top_k".to_string(), JsonValue::Number(top_k as f64));
    let hunt_start = Instant::now();
    let hunt_result = client.call_tool(
        crate::aria_v2_surface::HUNT_CONTRADICTIONS,
        hunt_args,
        &crate::config::ResultFormat::MootV2,
    )?;
    let hunt_seconds = hunt_start.elapsed().as_secs_f64();
    let hunt_text = hunt_result.text_blocks.join("\n");
    // "no vector index" is a hard failure for a measurement tool: a zero
    // detection rate from an unindexed estate is a plausible-looking wrong
    // number, not a result.
    if hunt_text.contains("no vector index") {
        return Err(MCPError {
            description: format!(
                "supersession: moot_hunt_contradictions reports no vector index \
                 after a converged drain — the sweep cannot be scored. \
                 Response: {}",
                hunt_text.chars().take(300).collect::<String>()
            ),
        });
    }
    let legacy_reported = parse_hunt_contradictions_report(&hunt_text);
    let outcome = score_contradiction_sweep(
        &corpus.contradictions,
        uuid_by_record_id,
        &legacy_reported,
        hunt_seconds,
    );
    Ok((outcome, parse_tiered_sections(&hunt_text), legacy_reported))
}

/// One single-tier purpose search (read-only: nothing filed, no writes).
/// The tiered sections here carry no lane counts and no timing lines
/// (synthesis-only renderer arms), so the wall clock is measured by the
/// harness around the call — the same I/O-boundary discipline the MCP layer
/// applies to its own GLK calls. Twin of the Swift `runPurposeSearch`
/// closure.
fn run_purpose_search(
    client: &mut MCPClient,
    fiction_now: &str,
    tier: usize,
    top_k: usize,
) -> Result<(ParsedTieredReport, f64), MCPError> {
    let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
    args.insert("now".to_string(), JsonValue::String(fiction_now.to_string()));
    args.insert("tier".to_string(), JsonValue::Number(tier as f64));
    args.insert("top_k".to_string(), JsonValue::Number(top_k as f64));
    let start = Instant::now();
    let result = client.call_tool(
        crate::aria_v2_surface::HUNT_CONTRADICTIONS,
        args,
        &crate::config::ResultFormat::MootV2,
    )?;
    let seconds = start.elapsed().as_secs_f64();
    let text = result.text_blocks.join("\n");
    // Same hard failure as the scored sweep: the lexical lanes need the
    // vector index (a tier-1 run never reports this).
    if text.contains("no vector index") {
        return Err(MCPError {
            description: format!(
                "supersession: tier {tier} purpose search reports no vector \
                 index after a converged drain — it cannot be scored. \
                 Response: {}",
                text.chars().take(300).collect::<String>()
            ),
        });
    }
    Ok((parse_tiered_sections(&text), seconds))
}

/// Aggregate metrics for the lane. Twin of Swift `SupersessionScores`.
pub struct SupersessionScores {
    pub query_count: usize,
    /// Fraction of chains where the current version outranked every stale
    /// one. The lane's headline: 1.0 means the store never surfaced an
    /// outdated fact above the truth.
    pub current_win_rate: f64,
    /// Fraction where the current version was retrieved at all.
    pub current_found_rate: f64,
    /// Mean superseded versions inside the top-k window.
    pub mean_stale_in_top_k: f64,
    /// Mean rank of the current version among the queries that found it.
    pub mean_current_rank: f64,
    pub p50_latency_seconds: f64,
}

/// Twin of Swift `scoreSupersession(_:topK:)`.
///
/// Guard-refused results (`guard_healthy == false`) are excluded from the
/// scored aggregate — they cannot be trusted because the estate appeared
/// degenerate during the probe. The raw slice is passed through so callers
/// can compute guard_refused counts independently. Twin of Swift filter.
pub fn score_supersession(results: &[SupersessionQueryResult]) -> SupersessionScores {
    // Only score the healthy subset; guard-refused results are still in the
    // slice (for diagnostic output) but must not bias win-rate or contamination.
    let healthy: Vec<&SupersessionQueryResult> =
        results.iter().filter(|r| r.guard_healthy).collect();
    let n = healthy.len().max(1);
    let found: Vec<&&SupersessionQueryResult> =
        healthy.iter().filter(|r| r.current_rank.is_some()).collect();
    let ranks: Vec<f64> = found
        .iter()
        .filter_map(|r| r.current_rank.map(|c| c as f64))
        .collect();
    let mut lat: Vec<f64> = healthy.iter().map(|r| r.latency_seconds).collect();
    lat.sort_by(|a, b| a.partial_cmp(b).expect("latencies are finite"));
    SupersessionScores {
        query_count: healthy.len(),
        current_win_rate: healthy.iter().filter(|r| r.current_wins).count() as f64 / n as f64,
        current_found_rate: found.len() as f64 / n as f64,
        mean_stale_in_top_k: healthy.iter().map(|r| r.stale_in_top_k).sum::<usize>() as f64
            / n as f64,
        mean_current_rank: if ranks.is_empty() {
            0.0
        } else {
            ranks.iter().sum::<f64>() / ranks.len() as f64
        },
        p50_latency_seconds: if lat.is_empty() { 0.0 } else { lat[lat.len() / 2] },
    }
}

/// Creates the single persistent scratch dir for a supersession run, under
/// the `/tmp/lme-bench-` prefix the guarded teardown contracts on. The pid
/// suffix keeps concurrent runs on one machine apart; corpus determinism
/// lives in the generator, not the path.
pub fn supersession_scratch_dir(
    seed: u64,
    posture: ScratchEstatePosture,
) -> Result<PathBuf, MCPError> {
    let name = format!("lme-bench-sup-{seed:016x}-{:08x}", std::process::id());
    let path = Path::new("/tmp").join(name);
    std::fs::create_dir_all(&path).map_err(|e| MCPError {
        description: format!("failed to create scratch dir {}: {e}", path.display()),
    })?;
    // The posture is the record's: a transient record is plaintext by rule.
    let _ = posture;
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Pins the no-lanes grace-window path that the supersession drain barrier
    /// relies on. A fast estate whose corpus lane never registers reports
    /// "drains: none" on every poll; routing through the shared barrier's
    /// state machine, four consecutive no-lanes polls past the 2-second
    /// minimum converge via the grace window rather than timing out.
    #[test]
    fn no_lanes_estate_barrier_converges_via_grace_not_hard_fail() {
        use crate::encode_barrier::{
            DrainBarrierDecision, DrainBarrierGrace, DrainBarrierState, DrainParseResult,
        };
        use std::time::{Duration, Instant};
        let base = Instant::now();
        let grace = DrainBarrierGrace { min_consecutive_no_lanes: 4, min_seconds: 2.0 };
        let mut state = DrainBarrierState::new(base, grace);
        // Three no-lanes polls: count criterion not yet met — must keep polling.
        assert_eq!(
            state.observe(DrainParseResult::NoLanes, base + Duration::from_millis(500)),
            DrainBarrierDecision::KeepPolling
        );
        assert_eq!(
            state.observe(DrainParseResult::NoLanes, base + Duration::from_millis(1000)),
            DrainBarrierDecision::KeepPolling
        );
        assert_eq!(
            state.observe(DrainParseResult::NoLanes, base + Duration::from_millis(1500)),
            DrainBarrierDecision::KeepPolling
        );
        // Fourth no-lanes poll past the 2-second minimum — grace window satisfied.
        // The barrier converges with lane_observed=false rather than failing.
        assert_eq!(
            state.observe(DrainParseResult::NoLanes, base + Duration::from_secs_f64(2.0)),
            DrainBarrierDecision::Converged { lane_observed: false }
        );
    }

    fn result(
        current_rank: Option<usize>,
        stale_ranks: Vec<usize>,
        top_k: usize,
    ) -> SupersessionQueryResult {
        let current_wins = match current_rank {
            Some(cr) => stale_ranks.iter().all(|&sr| cr < sr),
            None => false,
        };
        let stale_in_top_k = stale_ranks.iter().filter(|&&r| r <= top_k).count();
        SupersessionQueryResult {
            query_id: "q".to_string(),
            current_rank,
            stale_ranks,
            current_wins,
            stale_in_top_k,
            latency_seconds: 0.010,
            guard_healthy: true, // tests exercise scoring logic, not guard exclusion
        }
    }

    #[test]
    fn scoring_headline_and_contamination() {
        let results = vec![
            result(Some(1), vec![3, 5], 10), // win, 2 stale in top-10
            result(Some(2), vec![1], 10),    // loss: stale above current
            result(None, vec![1, 2], 10),    // loss: current absent
            result(Some(1), vec![], 10),     // win, nothing stale surfaced
        ];
        let scores = score_supersession(&results);
        assert_eq!(scores.query_count, 4);
        assert!((scores.current_win_rate - 0.5).abs() < 1e-12);
        assert!((scores.current_found_rate - 0.75).abs() < 1e-12);
        assert!((scores.mean_stale_in_top_k - 1.25).abs() < 1e-12);
        // Mean rank over found: (1 + 2 + 1) / 3.
        assert!((scores.mean_current_rank - 4.0 / 3.0).abs() < 1e-12);
    }

    #[test]
    fn absent_current_is_a_loss_not_a_bye() {
        let r = result(None, vec![], 10);
        assert!(!r.current_wins);
    }

    const SAMPLE_HUNT_OUTPUT: &str = "\
moot_hunt_contradictions: sweep complete
probesScanned: 26
pairsScreened: 40
alreadySettled: 0
proposed: 2
  PROPOSED UUID-A contradicts UUID-B (negation, score 0.91, tunnel T-1)
  PROPOSED UUID-C contradicts UUID-D (antonym, score 0.88, tunnel T-2)
Review with moot_lens_contradiction; accept/reject via moot_review_tunnel.
borderlineCandidates: 1
  CANDIDATE UUID-E vs UUID-F (negation, score 0.55)
    a: Sarah Chen 0 works at Acme Robotics.
    b: Sarah Chen 0 works at Beta Corp.
Judge each CANDIDATE pair: record with moot_link_memories; otherwise ignore.";

    #[test]
    fn hunt_parser_extracts_pairs_and_skips_prose() {
        let pairs = parse_hunt_contradictions_report(SAMPLE_HUNT_OUTPUT);
        assert_eq!(pairs.len(), 3);
        assert_eq!(pairs[0], ReportedContradictionPair {
            a: "UUID-A".to_string(), b: "UUID-B".to_string(), tier: "proposed".to_string(),
        });
        assert_eq!(pairs[1], ReportedContradictionPair {
            a: "UUID-C".to_string(), b: "UUID-D".to_string(), tier: "proposed".to_string(),
        });
        assert_eq!(pairs[2], ReportedContradictionPair {
            a: "UUID-E".to_string(), b: "UUID-F".to_string(), tier: "candidate".to_string(),
        });
    }

    #[test]
    fn hunt_parser_empty_sweep() {
        let text = "moot_hunt_contradictions: sweep complete\nproposed: 0\nborderlineCandidates: 0";
        assert!(parse_hunt_contradictions_report(text).is_empty());
    }

    #[test]
    fn contradiction_scorer_tier_and_order() {
        use crate::supersession_corpus::ContradictionPair;
        let planted = vec![
            ContradictionPair { id: "con-0".into(), left_record_id: "con-0-a".into(),
                right_record_id: "con-0-b".into(), entity: "E0".into(), attribute: "city".into() },
            ContradictionPair { id: "con-1".into(), left_record_id: "con-1-a".into(),
                right_record_id: "con-1-b".into(), entity: "E1".into(), attribute: "city".into() },
            ContradictionPair { id: "con-2".into(), left_record_id: "con-2-a".into(),
                right_record_id: "con-2-b".into(), entity: "E2".into(), attribute: "city".into() },
        ];
        let uuids: BTreeMap<String, String> = [
            ("con-0-a", "UUID-A"), ("con-0-b", "UUID-B"),
            ("con-1-a", "UUID-E"), ("con-1-b", "UUID-F"),
            ("con-2-a", "UUID-X"), ("con-2-b", "UUID-Y"),
        ].iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        // Pair 0 reported PROPOSED in REVERSED order; pair 1 CANDIDATE only;
        // pair 2 never reported. One extra pair outside the planted set.
        let reported = vec![
            ReportedContradictionPair { a: "UUID-B".into(), b: "UUID-A".into(), tier: "proposed".into() },
            ReportedContradictionPair { a: "UUID-E".into(), b: "UUID-F".into(), tier: "candidate".into() },
            ReportedContradictionPair { a: "UUID-P".into(), b: "UUID-Q".into(), tier: "candidate".into() },
        ];
        let outcome = score_contradiction_sweep(&planted, &uuids, &reported, 1.5);
        assert_eq!(outcome.planted_count, 3);
        assert_eq!(outcome.detected_any_tier, 2);
        assert_eq!(outcome.detected_proposed, 1);
        assert_eq!(outcome.flagged_outside_planted, 1);
    }

    #[test]
    fn unmappable_planted_pair_counts_as_undetected() {
        use crate::supersession_corpus::ContradictionPair;
        let planted = vec![ContradictionPair {
            id: "con-0".into(), left_record_id: "con-0-a".into(),
            right_record_id: "con-0-b".into(), entity: "E0".into(), attribute: "city".into(),
        }];
        let reported = vec![ReportedContradictionPair {
            a: "X".into(), b: "Y".into(), tier: "proposed".into(),
        }];
        let outcome =
            score_contradiction_sweep(&planted, &BTreeMap::new(), &reported, 0.1);
        assert_eq!(outcome.detected_any_tier, 0);
        assert_eq!(outcome.flagged_outside_planted, 1);
    }

    // Typed proving tier — parser + scorer for the typed section. The fixture
    // text is byte-identical to SupersessionStructuredTierTests.swift so the
    // two harness legs cannot drift in how they read a report.
    const SAMPLE_TYPED_SECTION: &str = "\
moot_lens_contradiction: legacy lines above\n\
conflicting_facts: 2 subject+predicate pair(s)\n\
proven: 3\n\
historical: 4\n\
compatible: 1\n\
unknown_or_invalid: 2\n\
coverage: 26/30\n\
  PROVEN aaaa1111\n\
    rule: dim.person.employer@1\n\
    coordinate: person:sarah chen c0|employer\n\
    values: d1hash vs d2hash\n\
    time: t:pt:100 | t:pt:100\n\
    reasons: same_coordinate, validity_overlap, values_exclusive\n\
    11111111-0000-4000-8000-000000000001 \u{b7} subject one \u{b7} fdc:343 \u{b7} qid:Q1 \u{b7} 2026-01-01T00:00:00Z\n\
    11111111-0000-4000-8000-000000000002 \u{b7} subject two \u{b7} fdc:343 \u{b7} qid:Q2 \u{b7} 2026-01-01T00:00:00Z\n\
  PROVEN bbbb2222\n\
    rule: dim.person.city@1\n\
    coordinate: person:noor haddad c1|city\n\
    values: d3hash vs d4hash\n\
    time: t:unknown | t:unknown\n\
    reasons: same_coordinate, validity_unknown, values_exclusive\n\
    22222222-0000-4000-8000-000000000003 \u{b7} subject three \u{b7} fdc:343 \u{b7} qid:Q3 \u{b7} 2026-01-02T00:00:00Z\n\
    22222222-0000-4000-8000-000000000004 \u{b7} subject four \u{b7} fdc:343 \u{b7} qid:Q4 \u{b7} 2026-01-02T00:00:00Z\n\
  a conflicting claim exists at coorddigest [restricted]\n\
  HISTORICAL cccc3333 person:x|role (same_coordinate, validity_disjoint)";

    #[test]
    fn typed_parser_reads_counts_and_proven_pairs() {
        let parsed = parse_typed_conflict_section(SAMPLE_TYPED_SECTION);
        assert_eq!(parsed.proven, 3);
        assert_eq!(parsed.historical, 4);
        assert_eq!(parsed.projected, 26);
        assert_eq!(parsed.scanned, 30);
        assert_eq!(
            parsed.pairs,
            vec![
                ReportedProvenPair {
                    a: "11111111-0000-4000-8000-000000000001".into(),
                    b: "11111111-0000-4000-8000-000000000002".into(),
                },
                ReportedProvenPair {
                    a: "22222222-0000-4000-8000-000000000003".into(),
                    b: "22222222-0000-4000-8000-000000000004".into(),
                },
            ]
        );
    }

    #[test]
    fn typed_scorer_separates_f18_from_f19() {
        use crate::supersession_corpus::ContradictionPair;
        let planted = vec![
            ContradictionPair {
                id: "con-0".into(),
                left_record_id: "con-0-a".into(),
                right_record_id: "con-0-b".into(),
                entity: "Sarah Chen C0".into(),
                attribute: "employer".into(),
            },
            // Unmappable pair (never ingested): counts as undetected.
            ContradictionPair {
                id: "con-1".into(),
                left_record_id: "con-1-a".into(),
                right_record_id: "con-1-b".into(),
                entity: "Ghost".into(),
                attribute: "city".into(),
            },
        ];
        let mut uuids = BTreeMap::new();
        uuids.insert("con-0-a".to_string(), "11111111-0000-4000-8000-000000000001".to_string());
        uuids.insert("con-0-b".to_string(), "11111111-0000-4000-8000-000000000002".to_string());
        let parsed = parse_typed_conflict_section(SAMPLE_TYPED_SECTION);
        let outcome = score_structured_tier(&planted, &uuids, &parsed, 1.5);
        assert_eq!(outcome.planted_count, 2);
        // Proven-planted: con-0 proven (order-independent set match); con-1
        // unmappable.
        assert_eq!(outcome.proven_planted, 1);
        // False proof: the second PROVEN block is not a planted pair.
        assert_eq!(outcome.proven_outside_planted, 1);
        assert_eq!(outcome.proven_reported, 3);
        assert_eq!(outcome.historical_reported, 4);
        assert_eq!(outcome.coverage_projected, 26);
        assert_eq!(outcome.coverage_scanned, 30);
    }

    /// A legacy-only report parses to zeros — the lane treats that as a
    /// hard failure upstream (it errors before scoring); the parser
    /// itself stays total.
    #[test]
    fn typed_parser_is_total_on_legacy_only_reports() {
        let parsed =
            parse_typed_conflict_section("contradicts_tunnels: none\nconflicting_facts: none");
        assert_eq!(parsed.proven, 0);
        assert!(parsed.pairs.is_empty());
    }

    // ── MXE-CT3 P4: tiered parsing and scoring ───────────────────────────
    //
    // FIXTURE PROVENANCE. The tiered blocks are hand-derived from the ONE
    // shared renderer both report surfaces route through, and pinned line
    // by line against its emitters: recipe_tools.rs tiered_section_lines
    // (:291-388 — headers :262-264, lane counts :327-330, tier-1 PROVEN
    // :346-351 + dense rows :352-360, restricted arm :339-344, tier-2/3
    // findings :362-370, timing :374-385) and the byte-identical Swift twin
    // RecipeTools.swift tieredSectionLines (:1368-1424). Fixture text is
    // byte-identical to SupersessionTieredTests.swift so the two harness
    // legs cannot drift in how they read a report. If the renderer changes,
    // these fixtures are stale and MUST be re-derived.
    const SAMPLE_SYNTHESIS_REPORT: &str = "\
moot_hunt_contradictions: sweep complete
probesScanned: 26
pairsScreened: 40
alreadySettled: 0
proposed: 1
  PROPOSED UUID-LEGACY-A contradicts UUID-LEGACY-B (word_exclusion, score 0.62, tunnel T-1)
Review with moot_lens_contradiction; accept/reject via moot_review_tunnel.
borderlineCandidates: 1
  CANDIDATE UUID-LEGACY-C vs UUID-LEGACY-D (negation_asymmetry, score 0.55)
    a: legacy snippet a
    b: legacy snippet b
proven: 1
historical: 2
coverage: 26/30
  PROVEN typed1111
    rule: dim.person.employer@1
    99999999-0000-4000-8000-000000000001 \u{b7} typed row one \u{b7} fdc:343 \u{b7} qid:Q1 \u{b7} 2026-01-01T00:00:00Z
    99999999-0000-4000-8000-000000000002 \u{b7} typed row two \u{b7} fdc:343 \u{b7} qid:Q2 \u{b7} 2026-01-01T00:00:00Z
  HISTORICAL hist2222 person:x|role (same_coordinate, validity_disjoint)
TIER 1 \u{2014} CONTRADICTION (proven)
  lane: fetched 1, returned 1, promotedAway 0, backfilled 0
  PROVEN aaaa1111 at coord-d1 (rule dim.person.employer@1)
    11111111-0000-4000-8000-000000000001 \u{b7} subject one \u{b7} fdc:343 \u{b7} qid:Q1 \u{b7} 2026-01-01T00:00:00Z
    11111111-0000-4000-8000-000000000002 \u{b7} subject two \u{b7} fdc:343 \u{b7} qid:Q2 \u{b7} 2026-01-01T00:00:00Z
  a conflicting claim exists at coord-d9 [restricted]
TIER 2 \u{2014} CONFLICT CANDIDATE
  lane: fetched 3, returned 2, promotedAway 1, backfilled 1
  UUID-B1 vs UUID-B2 (word_exclusion, score 0.62)
  UUID-C1 vs UUID-C2 (negation_asymmetry, score 0.58)
TIER 3 \u{2014} DIVERGENCE
  lane: fetched 2, returned 2, promotedAway 0, backfilled 0
  UUID-D1 vs UUID-D2 (value_divergence, score 0.875)
  UUID-E1 vs UUID-E2 (value_divergence, score 0.8)
lane_seconds: hunt=1.234 synthesis=0.567
synthesis_wall_seconds: 1.801";

    const SAMPLE_TIER3_PURPOSE_REPORT: &str = "\
moot_hunt_contradictions: tier 3 search complete
TIER 3 \u{2014} DIVERGENCE
  UUID-D1 vs UUID-D2 (value_divergence, score 0.875)";

    #[test]
    fn tiered_parser_reads_synthesis_sections_counts_pairs_and_timing() {
        let parsed = parse_tiered_sections(SAMPLE_SYNTHESIS_REPORT);
        assert!(parsed.tier1.present && parsed.tier2.present && parsed.tier3.present);
        assert_eq!(
            parsed.tier1.counts,
            Some(ParsedTierLaneCounts { fetched: 1, returned: 1, promoted_away: 0, backfilled: 0 })
        );
        assert_eq!(
            parsed.tier2.counts,
            Some(ParsedTierLaneCounts { fetched: 3, returned: 2, promoted_away: 1, backfilled: 1 })
        );
        // Tier-1 pair comes from the two dense rows under the PROVEN line;
        // the restricted line carries no ids and yields no pair.
        assert_eq!(
            parsed.tier1.pairs,
            vec![ReportedProvenPair {
                a: "11111111-0000-4000-8000-000000000001".into(),
                b: "11111111-0000-4000-8000-000000000002".into(),
            }]
        );
        assert_eq!(
            parsed.tier2.pairs,
            vec![
                ReportedProvenPair { a: "UUID-B1".into(), b: "UUID-B2".into() },
                ReportedProvenPair { a: "UUID-C1".into(), b: "UUID-C2".into() },
            ]
        );
        assert_eq!(
            parsed.tier3.pairs,
            vec![
                ReportedProvenPair { a: "UUID-D1".into(), b: "UUID-D2".into() },
                ReportedProvenPair { a: "UUID-E1".into(), b: "UUID-E2".into() },
            ]
        );
        assert_eq!(
            parsed.lane_seconds,
            vec![
                ParsedLaneSeconds { label: "hunt".into(), seconds: 1.234 },
                ParsedLaneSeconds { label: "synthesis".into(), seconds: 0.567 },
            ]
        );
        assert_eq!(parsed.synthesis_wall_seconds, Some(1.801));
    }

    #[test]
    fn tiered_parser_ignores_legacy_prefix_and_typed_section() {
        let parsed = parse_tiered_sections(SAMPLE_SYNTHESIS_REPORT);
        let all: Vec<&str> = parsed
            .tier1
            .pairs
            .iter()
            .chain(parsed.tier2.pairs.iter())
            .chain(parsed.tier3.pairs.iter())
            .flat_map(|p| [p.a.as_str(), p.b.as_str()])
            .collect();
        // The legacy PROPOSED/CANDIDATE ids and the typed section's
        // dense-row UUIDs all sit BEFORE the first tier header.
        assert!(!all.contains(&"UUID-LEGACY-A"));
        assert!(!all.contains(&"UUID-LEGACY-C"));
        assert!(!all.contains(&"99999999-0000-4000-8000-000000000001"));
    }

    #[test]
    fn tiered_parser_reads_single_tier_purpose_report() {
        let parsed = parse_tiered_sections(SAMPLE_TIER3_PURPOSE_REPORT);
        assert!(!parsed.tier1.present && !parsed.tier2.present && parsed.tier3.present);
        assert_eq!(parsed.tier3.counts, None);
        assert_eq!(
            parsed.tier3.pairs,
            vec![ReportedProvenPair { a: "UUID-D1".into(), b: "UUID-D2".into() }]
        );
        assert!(parsed.lane_seconds.is_empty());
        assert_eq!(parsed.synthesis_wall_seconds, None);
    }

    #[test]
    fn tiered_parser_is_total_on_reports_without_sections() {
        let parsed = parse_tiered_sections(
            "moot_hunt_contradictions: sweep complete\nproposed: 0\nborderlineCandidates: 0",
        );
        assert_eq!(parsed, ParsedTieredReport::default());
    }

    #[test]
    fn tiered_matching_is_case_insensitive_both_directions() {
        use crate::supersession_corpus::ContradictionPair;
        // Swift UUID.uuidString is UPPERCASE; Rust Uuid::to_string() is
        // lowercase (precedent c95910dff). Either side may carry either
        // casing; both directions must match, in either drawer order.
        let planted = vec![ContradictionPair {
            id: "con-0".into(),
            left_record_id: "con-0-a".into(),
            right_record_id: "con-0-b".into(),
            entity: "E0".into(),
            attribute: "employer".into(),
        }];
        let upper_map: BTreeMap<String, String> = [
            ("con-0-a", "AAAA1111-0000-4000-8000-000000000001"),
            ("con-0-b", "AAAA1111-0000-4000-8000-000000000002"),
        ]
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
        let lower_reported = vec![ReportedProvenPair {
            a: "aaaa1111-0000-4000-8000-000000000002".into(),
            b: "aaaa1111-0000-4000-8000-000000000001".into(),
        }];
        assert_eq!(count_detected_planted(&planted, &upper_map, &lower_reported), 1);

        let lower_map: BTreeMap<String, String> =
            upper_map.iter().map(|(k, v)| (k.clone(), v.to_lowercase())).collect();
        let upper_reported = vec![ReportedProvenPair {
            a: "AAAA1111-0000-4000-8000-000000000001".into(),
            b: "AAAA1111-0000-4000-8000-000000000002".into(),
        }];
        assert_eq!(count_detected_planted(&planted, &lower_map, &upper_reported), 1);
        // Unmappable planted pair counts as undetected.
        assert_eq!(count_detected_planted(&planted, &BTreeMap::new(), &upper_reported), 0);
    }

    fn p4_planted_with_map() -> (
        Vec<crate::supersession_corpus::ContradictionPair>,
        BTreeMap<String, String>,
    ) {
        use crate::supersession_corpus::ContradictionPair;
        let planted = vec![
            ContradictionPair {
                id: "con-0".into(),
                left_record_id: "con-0-a".into(),
                right_record_id: "con-0-b".into(),
                entity: "E0".into(),
                attribute: "employer".into(),
            },
            ContradictionPair {
                id: "div-0".into(),
                left_record_id: "div-0-a".into(),
                right_record_id: "div-0-b".into(),
                entity: "E1".into(),
                attribute: "response time".into(),
            },
        ];
        let map: BTreeMap<String, String> = [
            ("con-0-a", "UUID-B1"),
            ("con-0-b", "UUID-B2"),
            ("div-0-a", "UUID-D1"),
            ("div-0-b", "UUID-D2"),
        ]
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
        (planted, map)
    }

    #[test]
    fn exactly_once_synthesis_is_not_inflation() {
        let (planted, map) = p4_planted_with_map();
        // In the sample synthesis report con-0 sits only in tier 2 and
        // div-0 only in tier 3 — the exactly-once contract holds.
        let parsed = parse_tiered_sections(SAMPLE_SYNTHESIS_REPORT);
        assert_eq!(count_tier_inflation(&planted, &map, &parsed), 0);
        // Absence from every section is undetected, not inflation.
        assert_eq!(count_tier_inflation(&planted, &map, &ParsedTieredReport::default()), 0);
    }

    #[test]
    fn double_reported_pair_counts_as_tier_inflation() {
        let (planted, map) = p4_planted_with_map();
        let mut parsed = parse_tiered_sections(SAMPLE_SYNTHESIS_REPORT);
        // Simulate a dedup failure: the tier-2 planted pair ALSO shows up
        // in the tier-3 section (reversed order and different casing — the
        // inflation check must see through both).
        parsed.tier3.pairs.push(ReportedProvenPair { a: "uuid-b2".into(), b: "uuid-b1".into() });
        assert_eq!(count_tier_inflation(&planted, &map, &parsed), 1);
    }

    fn p4_decoy_fixture() -> (
        Vec<crate::supersession_corpus::DecoyPair>,
        BTreeMap<String, String>,
    ) {
        use crate::supersession_corpus::{
            DecoyPair, DECOY_KIND_DISTINCT_ENTITY, DECOY_KIND_MARKER_SUPERSESSION,
            DECOY_KIND_UNIT_EQUIVALENT,
        };
        let decoys = vec![
            DecoyPair {
                id: "dec-0".into(),
                left_record_id: "dec-0-a".into(),
                right_record_id: "dec-0-b".into(),
                kind: DECOY_KIND_MARKER_SUPERSESSION.into(),
            },
            DecoyPair {
                id: "dec-1".into(),
                left_record_id: "dec-1-a".into(),
                right_record_id: "dec-1-b".into(),
                kind: DECOY_KIND_DISTINCT_ENTITY.into(),
            },
            DecoyPair {
                id: "dec-2".into(),
                left_record_id: "dec-2-a".into(),
                right_record_id: "dec-2-b".into(),
                kind: DECOY_KIND_UNIT_EQUIVALENT.into(),
            },
        ];
        let map: BTreeMap<String, String> = [
            ("dec-0-a", "UUID-M1"),
            ("dec-0-b", "UUID-M2"),
            ("dec-1-a", "UUID-N1"),
            ("dec-1-b", "UUID-N2"),
            ("dec-2-a", "UUID-U1"),
            ("dec-2-b", "UUID-U2"),
        ]
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
        (decoys, map)
    }

    #[test]
    fn unit_equivalent_decoy_is_known_limitation_not_hard() {
        let (decoys, map) = p4_decoy_fixture();
        let mut report = ParsedTieredReport::default();
        report.tier3.pairs.push(ReportedProvenPair { a: "UUID-U1".into(), b: "UUID-U2".into() });
        let hits = count_decoy_hits(&decoys, &map, &[&report], &[]);
        assert_eq!(hits, DecoyHitCounts { hard: 0, known_limitation: 1 });
    }

    #[test]
    fn marker_and_distinct_entity_decoys_are_hard_hits() {
        let (decoys, map) = p4_decoy_fixture();
        // Marker decoy in a tier-2 section; distinct-entity decoy on a
        // legacy PROPOSED line (an auto-filed tunnel counts even outside
        // the tier sections).
        let mut report = ParsedTieredReport::default();
        report.tier2.pairs.push(ReportedProvenPair { a: "UUID-M2".into(), b: "UUID-M1".into() });
        let legacy = vec![ReportedContradictionPair {
            a: "UUID-N1".into(),
            b: "UUID-N2".into(),
            tier: "proposed".into(),
        }];
        let hits = count_decoy_hits(&decoys, &map, &[&report], &legacy);
        assert_eq!(hits, DecoyHitCounts { hard: 2, known_limitation: 0 });
    }

    #[test]
    fn candidate_line_is_not_a_decoy_hit() {
        let (decoys, map) = p4_decoy_fixture();
        // The borderline feed is an adjudication request to the BYOAI
        // client, not a filed finding.
        let legacy = vec![ReportedContradictionPair {
            a: "UUID-M1".into(),
            b: "UUID-M2".into(),
            tier: "candidate".into(),
        }];
        let hits = count_decoy_hits(&decoys, &map, &[], &legacy);
        assert_eq!(hits, DecoyHitCounts { hard: 0, known_limitation: 0 });
        // Unflagged decoys score zero in both rows.
        let none = count_decoy_hits(&decoys, &map, &[&ParsedTieredReport::default()], &[]);
        assert_eq!(none, DecoyHitCounts { hard: 0, known_limitation: 0 });
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Estate-mode comparison delta
// ─────────────────────────────────────────────────────────────────────────────

/// The encrypted-minus-unencrypted difference between two `SupersessionScores`
/// runs, one per posture. Printed by `--estate-mode both` so the operator can
/// see what changes when encryption is enabled, independent of what is measured.
///
/// Positive values for rate metrics mean the encrypted run scored higher.
/// Positive values for latency mean the encrypted run was slower.
/// Twin of Swift `SupersessionEstateDelta`.
pub struct SupersessionEstateDelta {
    /// Encrypted minus unencrypted: positive means encrypted performed better.
    pub current_win_rate_diff: f64,
    pub current_found_rate_diff: f64,
    /// Positive means more stale contamination in the encrypted run.
    pub mean_stale_in_top_k_diff: f64,
    /// Positive means a higher (worse) mean rank in the encrypted run.
    pub mean_current_rank_diff: f64,
    /// Latency overhead in milliseconds (encrypted minus unencrypted).
    pub query_p50_diff_ms: f64,
    /// Relative latency overhead as a percentage of the unencrypted p50.
    /// None when the unencrypted p50 is zero (division undefined).
    pub query_p50_percent_diff: Option<f64>,
}

/// Computes the encrypted-minus-unencrypted delta between two
/// `SupersessionScores`. Argument order is fixed: `unencrypted` first,
/// `encrypted` second — the result always reads as "what changed when
/// encryption was enabled," and the calling code is unambiguous about which
/// run is which.
///
/// Pure function over two `SupersessionScores` — unit-testable without a live
/// estate. Twin of Swift `computeSupersessionEstateDelta(unencrypted:encrypted:)`.
pub fn compute_supersession_estate_delta(
    unencrypted: &SupersessionScores,
    encrypted: &SupersessionScores,
) -> SupersessionEstateDelta {
    let p50_unenc = unencrypted.p50_latency_seconds * 1_000.0;
    let p50_enc   = encrypted.p50_latency_seconds   * 1_000.0;
    SupersessionEstateDelta {
        current_win_rate_diff:    encrypted.current_win_rate   - unencrypted.current_win_rate,
        current_found_rate_diff:  encrypted.current_found_rate - unencrypted.current_found_rate,
        mean_stale_in_top_k_diff: encrypted.mean_stale_in_top_k - unencrypted.mean_stale_in_top_k,
        mean_current_rank_diff:   encrypted.mean_current_rank  - unencrypted.mean_current_rank,
        query_p50_diff_ms:        p50_enc - p50_unenc,
        query_p50_percent_diff:   if p50_unenc > 0.0 {
            Some((p50_enc - p50_unenc) / p50_unenc * 100.0)
        } else {
            None
        },
    }
}

#[cfg(test)]
mod estate_delta_tests {
    use super::{compute_supersession_estate_delta, SupersessionScores};

    fn make_scores(
        current_win_rate: f64,
        current_found_rate: f64,
        mean_stale_in_top_k: f64,
        mean_current_rank: f64,
        p50_latency_seconds: f64,
    ) -> SupersessionScores {
        SupersessionScores {
            query_count: 10,
            current_win_rate,
            current_found_rate,
            mean_stale_in_top_k,
            mean_current_rank,
            p50_latency_seconds,
        }
    }

    #[test]
    fn basic_subtraction_is_encrypted_minus_unencrypted() {
        let unenc = make_scores(0.80, 0.90, 1.5, 2.0, 0.050);
        let enc   = make_scores(0.75, 0.85, 1.8, 2.3, 0.060);
        let delta = compute_supersession_estate_delta(&unenc, &enc);
        assert!((delta.current_win_rate_diff   - (-0.05)).abs() < 1e-9);
        assert!((delta.current_found_rate_diff - (-0.05)).abs() < 1e-9);
        assert!((delta.mean_stale_in_top_k_diff - 0.30).abs() < 1e-9);
        assert!((delta.mean_current_rank_diff   - 0.30).abs() < 1e-9);
    }

    #[test]
    fn p50_diff_is_in_milliseconds_not_seconds() {
        let unenc = make_scores(1.0, 1.0, 0.0, 1.0, 0.100); // 100 ms
        let enc   = make_scores(1.0, 1.0, 0.0, 1.0, 0.115); // 115 ms
        let delta = compute_supersession_estate_delta(&unenc, &enc);
        assert!(
            (delta.query_p50_diff_ms - 15.0).abs() < 1e-6,
            "expected 15.0 ms overhead, got {}",
            delta.query_p50_diff_ms
        );
    }

    #[test]
    fn p50_percent_diff_is_relative_to_unencrypted_p50() {
        let unenc = make_scores(1.0, 1.0, 0.0, 1.0, 0.100); // 100 ms
        let enc   = make_scores(1.0, 1.0, 0.0, 1.0, 0.120); // 120 ms → +20%
        let delta = compute_supersession_estate_delta(&unenc, &enc);
        let pct = delta.query_p50_percent_diff
            .expect("percent diff must be Some when unencrypted p50 > 0");
        assert!((pct - 20.0).abs() < 1e-6, "expected +20%, got {pct}");
    }

    #[test]
    fn p50_percent_diff_is_none_when_unencrypted_p50_is_zero() {
        let unenc = make_scores(1.0, 1.0, 0.0, 1.0, 0.0);    // zero
        let enc   = make_scores(1.0, 1.0, 0.0, 1.0, 0.050);
        let delta = compute_supersession_estate_delta(&unenc, &enc);
        assert!(
            delta.query_p50_percent_diff.is_none(),
            "percent diff must be None when unencrypted p50 is zero"
        );
    }

    #[test]
    fn identical_runs_produce_all_zero_delta() {
        let scores = make_scores(0.95, 1.0, 0.2, 1.1, 0.080);
        let delta  = compute_supersession_estate_delta(&scores, &scores);
        assert_eq!(delta.current_win_rate_diff,    0.0);
        assert_eq!(delta.current_found_rate_diff,  0.0);
        assert_eq!(delta.mean_stale_in_top_k_diff, 0.0);
        assert_eq!(delta.mean_current_rank_diff,   0.0);
        assert_eq!(delta.query_p50_diff_ms,        0.0);
        assert_eq!(delta.query_p50_percent_diff, Some(0.0));
    }

    #[test]
    fn argument_order_is_fixed_forward_and_backward_are_sign_negated() {
        // Swapping arguments must produce sign-negated deltas — the result's
        // sign is load-bearing for display and the function is not symmetric.
        let unenc = make_scores(0.80, 0.90, 1.0, 2.0, 0.050);
        let enc   = make_scores(0.85, 0.95, 0.8, 1.8, 0.055);
        let fwd = compute_supersession_estate_delta(&unenc, &enc);
        let bwd = compute_supersession_estate_delta(&enc,   &unenc);
        assert!((fwd.current_win_rate_diff + bwd.current_win_rate_diff).abs() < 1e-9);
        assert!((fwd.query_p50_diff_ms     + bwd.query_p50_diff_ms    ).abs() < 1e-6);
    }

    #[test]
    fn negative_delta_is_valid_not_clamped() {
        // Encrypted run is actually faster — the delta should be negative,
        // not clamped to zero.
        let unenc = make_scores(1.0, 1.0, 0.0, 1.0, 0.200);
        let enc   = make_scores(1.0, 1.0, 0.0, 1.0, 0.150);
        let delta = compute_supersession_estate_delta(&unenc, &enc);
        assert!(delta.query_p50_diff_ms < 0.0, "negative overhead must be preserved");
        assert!(
            delta.query_p50_percent_diff.unwrap() < 0.0,
            "negative percent overhead must be preserved"
        );
    }
}
