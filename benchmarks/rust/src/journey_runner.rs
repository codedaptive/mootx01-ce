//! journey_runner.rs — the journey lane's live runner. Twin of Swift
//! `JourneyRunner.swift`.
//!
//! SHAPE OF THE LANE. Two sub-corpora, two different measurements:
//!
//!   PRECISE-MISS is a SINGLE query. The target and a lexically denser decoy
//!     both sit in the estate; the score is whether the target outranks the
//!     decoy. There is no journey to walk — one search answers it.
//!
//!   VAGUE-NARROW is the JOURNEY. A vague question cannot be answered by one
//!     query, so the agent walks four steps: survey the space, pivot from an
//!     anchor into its neighbourhood, winnow to a candidate, hydrate the
//!     candidate's full body. That walk is what `JourneyRecorder` records and
//!     what `JourneyMetrics` scores — hops, token-turn integral, and how much
//!     full content was pulled BEFORE the terminal step (cheap steps first is
//!     the behaviour under measurement).
//!
//! SEAM. This reuses the supersession lane's plumbing rather than growing a
//! second one: the same scratch-estate provisioning (`lme_scratch_dir` /
//! `lme_endpoint_config`), the same batch seed import, the same encode
//! barrier, the same UUID attribution pass, the same guarded teardown. One
//! seam, never two paths to the same leaf.
//!
//! FAIRNESS RULE (inherited from `journey_corpus`). Every scored behaviour
//! must be achievable by any competent retrieval system. The four steps use
//! ordinary recall verbs and an anchor pivot; nothing here needs a
//! moot-specific feature.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Instant;

use serde::{Deserialize, Serialize};

use crate::config::ResultFormat;
use crate::encode_barrier::wait_for_encode_drain;
use crate::journey_corpus::JourneyCorpus;
use crate::journey_driver::{batch_hydrate_args, near_pivot_search_args, HydrationDepth};
use crate::journey_metrics::{JourneyMetrics, JourneyStep};
use crate::journey_recorder::JourneyRecorder;
use crate::json_value::JsonValue;
use crate::longmemeval_runner::{lme_endpoint_config, LmeShape};
use crate::mcp_client::{MCPClient, MCPError, ToolCaller};
use crate::run_environment::{RunEnvironment, BENCHMARK_PROTOCOL_VERSION};
use crate::scratch_posture::ScratchEstatePosture;
use crate::seed_export::{emit_seed_json, seed_id_map, write_seed_file, SeedFileRecord};

// ─────────────────────────────────────────────────────────────────────────────
// Configuration
// ─────────────────────────────────────────────────────────────────────────────

/// Backend persistence shape for the journey estate. Twin of Swift
/// `JourneyEstateShape`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JourneyEstateShape {
    /// Disk-backed SQLite estate. Compatible with estate cache.
    Disk,
    /// In-memory estate. Appends `--in-memory` to the serve
    /// command. Zero disk I/O; no keychain contact.
    Ram,
}

impl JourneyEstateShape {
    /// The raw string value — matches Swift's synthesized `rawValue` (the
    /// case name itself; neither case declares an explicit raw string).
    pub fn as_str(&self) -> &'static str {
        match self {
            JourneyEstateShape::Disk => "disk",
            JourneyEstateShape::Ram => "ram",
        }
    }
}

/// Configuration for one journey lane run. Twin of Swift `JourneyRunConfig`.
pub struct JourneyRunConfig {
    /// Deterministic corpus seed; appears in the record name and the report.
    pub seed: u64,
    /// Path to the mootx01 binary the lane serves.
    pub moot_binary_path: String,
    /// Scratch estate directory, created and retired by the caller.
    pub scratch_dir: PathBuf,
    /// At-rest posture. Ephemeral-encrypted by default, so a run leaves no key.
    pub posture: ScratchEstatePosture,
    /// Backend shape — disk-backed SQLite or in-memory.
    pub shape: JourneyEstateShape,
    /// Rank cutoff for "found". Ranks are 1-based, so this must be >= 1.
    pub top_k: usize,
}

// ─────────────────────────────────────────────────────────────────────────────
// Outcomes
// ─────────────────────────────────────────────────────────────────────────────

/// One PRECISE-MISS scenario's result. Twin of Swift `PreciseMissOutcome`.
/// The Swift struct carries no explicit `CodingKeys` — its JSON keys are the
/// literal (camelCase) property names — so this mirrors that with
/// `rename_all = "camelCase"` plus the one acronym rename (`scenarioID`)
/// `camelCase` cannot produce on its own.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PreciseMissOutcome {
    #[serde(rename = "scenarioID")]
    pub scenario_id: String,
    /// 1-based rank of the target, `None` when absent from the top-k reply.
    pub target_rank: Option<usize>,
    /// 1-based rank of the decoy, `None` when absent.
    pub decoy_rank: Option<usize>,
    /// True when the target was returned AND outranked the decoy. A target
    /// that is absent does not outrank anything, and a decoy that is absent
    /// while the target is present counts as outranked — the decoy losing
    /// entirely is the strongest form of the behaviour being measured.
    pub target_outranks_decoy: bool,
    /// True when the target appeared anywhere in the top-k reply.
    pub target_found: bool,
    /// Seconds for the single scored query.
    pub query_seconds: f64,
    /// The recorded walk. A precise-miss journey is ONE step, and one step
    /// still has four counts — hops 1, integral equal to that step's payload,
    /// pre-terminal full content 0. benchmarks/journey.md defines the lane as
    /// those counts; omitting them because the walk is short measured
    /// correctness where the specification asked for cost.
    pub metrics: JourneyMetrics,
    /// The step sequence itself, per §What is recorded.
    pub steps: Vec<JourneyStep>,
}

/// One VAGUE-NARROW cluster's journey result. Twin of Swift
/// `VagueNarrowOutcome` (also no explicit `CodingKeys`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct VagueNarrowOutcome {
    #[serde(rename = "clusterID")]
    pub cluster_id: String,
    /// True when the cluster's answer-carrying member was reached by the
    /// winnow step — the step the journey exists to land on.
    pub true_found: bool,
    /// 1-based rank of the true member within the winnow reply, `None` when
    /// absent.
    pub true_rank: Option<usize>,
    /// True when the terminal hydrate returned the true member's body.
    pub hydrated_true_member: bool,
    /// The recorded four-step walk, scored by `JourneyMetrics`.
    pub metrics: JourneyMetrics,
    /// Seconds across all four steps.
    pub steps: Vec<JourneyStep>,
    pub journey_seconds: f64,
}

/// Everything one journey run produced. Twin of Swift `JourneyLaneOutcome`.
pub struct JourneyLaneOutcome {
    pub precise_miss: Vec<PreciseMissOutcome>,
    pub vague_narrow: Vec<VagueNarrowOutcome>,
    /// Records actually seeded, from the import receipt rather than the plan.
    pub seeded_records: usize,
}

// ─────────────────────────────────────────────────────────────────────────────
// Seed records
// ─────────────────────────────────────────────────────────────────────────────

/// Converts both sub-corpora into seed-file records.
///
/// Rooms separate the sub-corpora so a survey over one cannot be answered by a
/// stray hit in the other: `precise-miss` and `vague-narrow`. Within a room
/// the records are indistinguishable by metadata — the target, the decoy and
/// the fillers differ only in content, which is the point. Putting the answer
/// in the metadata would measure the harness's labelling, not the product's
/// recall. Twin of Swift `journeySeedRecords(from:)`.
pub fn journey_seed_records(corpus: &JourneyCorpus) -> Vec<SeedFileRecord> {
    let mut out: Vec<SeedFileRecord> = Vec::with_capacity(
        corpus.precise_miss.records.len() + corpus.vague_narrow.records.len(),
    );
    for r in &corpus.precise_miss.records {
        out.push(SeedFileRecord::new(&r.id, &r.content, &r.event_time, "precise-miss"));
    }
    for r in &corpus.vague_narrow.records {
        out.push(SeedFileRecord::new(&r.id, &r.content, &r.event_time, "vague-narrow"));
    }
    // Chronological, id as tiebreak — same rule as the supersession lane. All
    // records in a scenario share an instant by design, so an unstable sort
    // would file them in an order that differs between runs and between legs.
    out.sort_by(|a, b| a.event_time.cmp(&b.event_time).then_with(|| a.id.cmp(&b.id)));
    out
}

// ─────────────────────────────────────────────────────────────────────────────
// Lane
// ─────────────────────────────────────────────────────────────────────────────

/// Pure PRECISE-MISS decision: does the target outrank the decoy? Extracted
/// from the per-scenario loop so the truth table is unit-testable without a
/// live server. Twin of the Swift `switch (targetRank, decoyRank)` inline in
/// `runJourneyLane`.
///
/// Target absent -> it outranks nothing. Decoy absent with target present ->
/// the strongest form of the measured behaviour.
fn target_outranks_decoy(target_rank: Option<usize>, decoy_rank: Option<usize>) -> bool {
    match (target_rank, decoy_rank) {
        (Some(t), Some(d)) => t < d,
        (Some(_), None) => true,
        _ => false,
    }
}

/// 1-based rank of `record_id` within a reply's ordered UUIDs, or `None` when
/// the record has no attributed UUID or the UUID is absent from the reply.
fn rank_of(
    record_id: &str,
    ordered_ids: &[String],
    uuid_by_record_id: &BTreeMap<String, String>,
) -> Option<usize> {
    let uuid = uuid_by_record_id.get(record_id)?;
    ordered_ids.iter().position(|id| id == uuid).map(|i| i + 1)
}

/// Runs the journey lane against a live server and returns both sub-corpora's
/// outcomes.
///
/// # Errors
/// Returns `MCPError` when the estate cannot be seeded, when the encode queue
/// does not settle, or when the UUID attribution pass is incomplete. Each of
/// those would otherwise produce a plausible-looking wrong number.
///
/// Twin of Swift `runJourneyLane(corpus:config:)`.
pub fn run_journey_lane(
    corpus: &JourneyCorpus,
    config: &JourneyRunConfig,
) -> Result<JourneyLaneOutcome, MCPError> {
    let lme_shape = match config.shape {
        JourneyEstateShape::Ram => LmeShape::Ram,
        JourneyEstateShape::Disk => LmeShape::Disk,
    };
    let endpoint = lme_endpoint_config(
        &config.scratch_dir, &config.moot_binary_path, config.posture, lme_shape, None)
        .map_err(|e| MCPError { description: e })?;
    let mut client = MCPClient::new(endpoint);
    client.connect()?;

    // ── Seed ──────────────────────────────────────────────────────────────
    let seed_records = journey_seed_records(corpus);
    let seed_name = format!("journey-{}", config.seed);
    let seed_data = emit_seed_json(&seed_name, &seed_records, &[], &[]);
    let seed_path = write_seed_file(&seed_data, &config.scratch_dir, &seed_name)?;
    let mut import_args: BTreeMap<String, JsonValue> = BTreeMap::new();
    import_args.insert(
        "path".to_string(),
        JsonValue::String(seed_path.to_string_lossy().into_owned()),
    );
    // return_id_map: the reply carries a second text block holding the
    // record-id -> drawer-UUID map. The importer mints the ids, so it is the
    // only source that is both exact and total (see seed_id_map).
    import_args.insert("return_id_map".to_string(), JsonValue::Bool(true));
    let imported = client.call_tool(crate::aria_v2_surface::JSON_IMPORT, import_args, &ResultFormat::MootV2)?;
    // v2: drawer count is in structuredContent.data.drawers_written, not text.
    if imported.drawers_written != Some(seed_records.len() as i64) {
        return Err(MCPError {
            description: format!(
                "journey: moot_json_import did not confirm {} drawers — refusing to \
                 score an unseeded estate. Got: {}",
                seed_records.len(),
                imported.drawers_written
                    .map(|n| n.to_string())
                    .unwrap_or_else(|| "(no structured data)".to_string())
            ),
        });
    }

    // ── Barrier ───────────────────────────────────────────────────────────
    // Querying a partially-indexed estate returns understated rankings with
    // no visible signal — a wrong number that reads like a right one.
    let barrier =
        wait_for_encode_drain(&mut client, &format!("journey seed={}", config.seed), 300.0);
    if !barrier.converged {
        return Err(MCPError {
            description: "journey: encode drain did not converge within 300s — refusing \
                 to query a partially-indexed estate. Re-run on an unloaded machine."
                .to_string(),
        });
    }

    // ── Attribution ───────────────────────────────────────────────────────
    // The corpus-id -> drawer-UUID map comes from the import receipt's id_map
    // block. Scoring needs it in both directions: forward to know which UUID
    // is the target, reverse to name what a reply returned. `seed_id_map`
    // errors on a short map, so a partial map can never be scored.
    let uuid_by_record_id: BTreeMap<String, String> = seed_id_map(
        &imported.text_blocks,
        seed_records.len(),
        &format!("journey seed={}", config.seed),
    )?
    .into_iter()
    .collect();
    let mut record_id_by_uuid: BTreeMap<String, String> = BTreeMap::new();
    for (record_id, uuid) in &uuid_by_record_id {
        record_id_by_uuid.insert(uuid.clone(), record_id.clone());
    }

    // ── PRECISE-MISS: one query per scenario ────────────────────────────────
    let mut precise_miss: Vec<PreciseMissOutcome> =
        Vec::with_capacity(corpus.precise_miss.scenarios.len());
    for scenario in &corpus.precise_miss.scenarios {
        let started = Instant::now();
        let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
        args.insert("query".to_string(), JsonValue::String(scenario.question.clone()));
        args.insert("limit".to_string(), JsonValue::Number(config.top_k as f64));
        let reply = client.call_tool(crate::aria_v2_surface::MEMORY_SEARCH, args, &ResultFormat::MootV2)?;
        let seconds = started.elapsed().as_secs_f64();
        // Captured before `ordered_ids` moves the reply.
        let reply_text = reply.text_blocks.join("\n");
        let ids = reply.ordered_ids;
        let target_rank = rank_of(&scenario.target_record_id, &ids, &uuid_by_record_id);
        let decoy_rank = rank_of(&scenario.decoy_record_id, &ids, &uuid_by_record_id);
        let outranks = target_outranks_decoy(target_rank, decoy_rank);
        // One step, and it IS the terminal step: the single search answers
        // the question. hydrated_full_content is false — a dense recall reply
        // is not a full-body fetch.
        let mut pm_recorder = JourneyRecorder::new();
        pm_recorder.append("recall", &reply_text, false, true);
        precise_miss.push(PreciseMissOutcome {
            scenario_id: scenario.id.clone(),
            target_rank,
            decoy_rank,
            target_outranks_decoy: outranks,
            target_found: target_rank.is_some(),
            query_seconds: seconds,
            metrics: pm_recorder.metrics(),
            steps: pm_recorder.current_steps().to_vec(),
        });
    }

    // ── VAGUE-NARROW: the four-step journey per cluster ─────────────────────
    let mut vague_narrow: Vec<VagueNarrowOutcome> =
        Vec::with_capacity(corpus.vague_narrow.clusters.len());
    // Winnow narrows to a third of the survey width, floored at one. The
    // journey's value is landing on the answer with a SMALLER reply, so the
    // winnow step must actually narrow; querying at survey width again would
    // score the same reply twice and call the second one progress.
    let winnow_limit = std::cmp::max(1, config.top_k / 3);

    for cluster in &corpus.vague_narrow.clusters {
        let started = Instant::now();
        let mut recorder = JourneyRecorder::new();

        // 1. SURVEY — broad recall on the vague question.
        let mut survey_args: BTreeMap<String, JsonValue> = BTreeMap::new();
        survey_args.insert("query".to_string(), JsonValue::String(cluster.question.clone()));
        survey_args.insert("limit".to_string(), JsonValue::Number(config.top_k as f64));
        let survey =
            client.call_tool(crate::aria_v2_surface::MEMORY_SEARCH, survey_args, &ResultFormat::MootV2)?;
        recorder.append("survey", &survey.text_blocks.join("\n"), false, false);

        // 2. PIVOT — anchor on the survey's top hit and explore its
        //    neighbourhood. `near` is a different code path from text recall,
        //    which is why the pivot is worth measuring separately. With no
        //    survey hit there is nothing to anchor on, and the journey is
        //    recorded as the short walk it actually was rather than being
        //    padded with a synthetic step.
        if let Some(anchor) = survey.ordered_ids.first() {
            let mut extra: BTreeMap<String, JsonValue> = BTreeMap::new();
            extra.insert("limit".to_string(), JsonValue::Number(config.top_k as f64));
            let pivot_args = near_pivot_search_args(anchor, extra);
            let pivot =
                client.call_tool(crate::aria_v2_surface::MEMORY_SEARCH, pivot_args, &ResultFormat::MootV2)?;
            recorder.append("pivot", &pivot.text_blocks.join("\n"), false, false);
        }

        // 3. WINNOW — narrow to the candidate that answers the question.
        let mut winnow_args: BTreeMap<String, JsonValue> = BTreeMap::new();
        winnow_args.insert("query".to_string(), JsonValue::String(cluster.question.clone()));
        winnow_args.insert("limit".to_string(), JsonValue::Number(winnow_limit as f64));
        let winnow =
            client.call_tool(crate::aria_v2_surface::MEMORY_SEARCH, winnow_args, &ResultFormat::MootV2)?;
        let winnow_ids = winnow.ordered_ids.clone();
        recorder.append("winnow", &winnow.text_blocks.join("\n"), false, false);

        // 4. HYDRATE — pull the full body of the winnowed candidate. This is
        //    the terminal step and the only one that pays for full content.
        let mut hydrated_true = false;
        if let Some(candidate) = winnow_ids.first() {
            let hydrate_args =
                batch_hydrate_args(&[candidate.as_str()], HydrationDepth::Full, BTreeMap::new());
            let hydrate =
                client.call_tool(crate::aria_v2_surface::MEMORY_GET, hydrate_args, &ResultFormat::MootV2)?;
            recorder.append("hydrate", &hydrate.text_blocks.join("\n"), true, true);
            hydrated_true = record_id_by_uuid.get(candidate).map(String::as_str)
                == Some(cluster.true_id.as_str());
        }

        let true_rank = rank_of(&cluster.true_id, &winnow_ids, &uuid_by_record_id);
        vague_narrow.push(VagueNarrowOutcome {
            cluster_id: cluster.id.clone(),
            true_found: true_rank.is_some(),
            true_rank,
            hydrated_true_member: hydrated_true,
            metrics: recorder.metrics(),
            steps: recorder.current_steps().to_vec(),
            journey_seconds: started.elapsed().as_secs_f64(),
        });
    }

    Ok(JourneyLaneOutcome {
        precise_miss,
        vague_narrow,
        seeded_records: seed_records.len(),
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Report
// ─────────────────────────────────────────────────────────────────────────────

/// Aggregate figures for the PRECISE-MISS sub-corpus. Twin of Swift
/// `PreciseMissAggregate` — the Swift struct declares explicit snake_case
/// `CodingKeys`, which the plain (already snake_case) Rust field names
/// reproduce without any `rename` attribute.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PreciseMissAggregate {
    pub scenarios: usize,
    // THE LANE'S METRICS, per benchmarks/journey.md §Metrics: four integer
    // counts over the step sequence. A precise-miss journey is one step, which
    // makes hops 1 and the pre-terminal count 0 by construction — that is the
    // measurement, not a reason to omit it.
    pub mean_hops: f64,
    pub mean_token_turn_integral: f64,
    pub mean_pre_terminal_full_content_tokens: f64,
    pub mean_total_payload_tokens: f64,
    // Supporting correctness figures, NOT what the definition says the lane
    // measures.
    pub target_over_decoy_rate: f64,
    pub target_found_rate: f64,
    /// Mean 1-based rank of the target across scenarios where it was found.
    pub mean_target_rank: Option<f64>,
    pub query_p50_seconds: f64,
}

/// Aggregate figures for the VAGUE-NARROW sub-corpus. Twin of Swift
/// `VagueNarrowAggregate` (explicit snake_case `CodingKeys`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct VagueNarrowAggregate {
    pub clusters: usize,
    /// The lane's headline: how often the journey landed on the answer.
    pub true_found_rate: f64,
    pub hydrated_true_rate: f64,
    pub mean_true_rank: Option<f64>,
    pub mean_hops: f64,
    /// Mean token-turn integral — the cost of the walk, not just its success.
    pub mean_token_turn_integral: f64,
    /// Mean full-content tokens pulled BEFORE the terminal step. Cheap steps
    /// first is the behaviour under measurement, so a nonzero mean here is a
    /// finding rather than noise.
    pub mean_pre_terminal_full_content_tokens: f64,
    /// The fourth count from §Metrics, absent until 2026-08-18.
    pub mean_total_payload_tokens: f64,
    pub journey_p50_seconds: f64,
}

/// What this run covered, per the §6 required-field rule. A report that
/// cannot answer "how much of the benchmark is this?" is the defect that cost
/// eight days on LMEB and MemBench. Twin of Swift `JourneyCoverage` (explicit
/// snake_case `CodingKeys`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct JourneyCoverage {
    pub precise_miss_scenarios: usize,
    pub vague_narrow_clusters: usize,
    pub members_per_cluster: usize,
    pub records_seeded: usize,
    pub shape: String,
    pub estate_posture: String,
}

/// The journey lane's report. Twin of Swift `JourneyReport` (explicit
/// snake_case `CodingKeys`; `topK` -> `"k"` is the one rename Rust's already
/// snake_case field names cannot produce on their own).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JourneyReport {
    /// The estate schema the harness was built against, stamped into every
    /// report so the results record can carry the column without anyone typing
    /// it (BENCHMARK_PROTOCOL §9). Twin of Swift `estateSchemaVersion`.
    pub estate_schema_version: String,
    pub benchmark_protocol_version: String,
    pub run_environment: RunEnvironment,
    pub seed: u64,
    #[serde(rename = "k")]
    pub top_k: usize,
    pub coverage: JourneyCoverage,
    pub precise_miss_aggregate: PreciseMissAggregate,
    pub vague_narrow_aggregate: VagueNarrowAggregate,
    pub precise_miss: Vec<PreciseMissOutcome>,
    pub vague_narrow: Vec<VagueNarrowOutcome>,
}

/// Returns the p50 of `values`, or 0 when empty.
///
/// Nearest-rank on the sorted values: with an even count this takes the upper
/// of the two middles rather than averaging them, matching how the other
/// lanes report p50 so figures stay comparable across the suite. Twin of
/// Swift `journeyP50(_:)`.
pub fn journey_p50(values: &[f64]) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let mut sorted: Vec<f64> = values.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
    sorted[std::cmp::min(sorted.len() - 1, sorted.len() / 2)]
}

/// Stringifies the scratch posture the way Swift's default string
/// interpolation of a `RawRepresentable` enum without a `CustomStringConvertible`
/// override does: the CASE NAME (e.g. `"plaintextOptOut"`), not the raw value
/// (`"plaintext-optout"`, what `ScratchEstatePosture::as_str()` returns
/// elsewhere in this crate for the `estate_encryption` report key). Journey's
/// `"\(config.posture)"` in `JourneyRunner.swift` is exactly this case-name
/// interpolation — a quirk, but the one the Swift leg actually ships, and
/// SPEC-BEFORE-REALITY means this mirrors it rather than "fixing" it to the
/// rawValue.
fn posture_case_name(posture: ScratchEstatePosture) -> &'static str {
    match posture {
        ScratchEstatePosture::PlaintextTransient => "plaintextOptOut",
        ScratchEstatePosture::EncryptedEphemeral => "encryptedEphemeral",
    }
}

/// Builds the report from a lane outcome. Twin of Swift
/// `buildJourneyReport(corpus:outcome:config:runEnvironment:)`.
pub fn build_journey_report(
    corpus: &JourneyCorpus,
    outcome: &JourneyLaneOutcome,
    config: &JourneyRunConfig,
    run_environment: RunEnvironment,
) -> JourneyReport {
    let pm = &outcome.precise_miss;
    let vn = &outcome.vague_narrow;
    let pm_count = std::cmp::max(1, pm.len()) as f64;
    let vn_count = std::cmp::max(1, vn.len()) as f64;

    let found_target_ranks: Vec<f64> =
        pm.iter().filter_map(|o| o.target_rank).map(|r| r as f64).collect();
    let found_true_ranks: Vec<f64> =
        vn.iter().filter_map(|o| o.true_rank).map(|r| r as f64).collect();

    let pm_mean = |f: &dyn Fn(&PreciseMissOutcome) -> i64| -> f64 {
        if pm.is_empty() { 0.0 } else { pm.iter().map(f).sum::<i64>() as f64 / pm_count }
    };
    let pm_agg = PreciseMissAggregate {
        scenarios: pm.len(),
        mean_hops: pm_mean(&|o| o.metrics.hops),
        mean_token_turn_integral: pm_mean(&|o| o.metrics.token_turn_integral),
        mean_pre_terminal_full_content_tokens:
            pm_mean(&|o| o.metrics.pre_terminal_full_content_tokens),
        mean_total_payload_tokens: pm_mean(&|o| o.metrics.total_payload_tokens),
        target_over_decoy_rate: if pm.is_empty() {
            0.0
        } else {
            pm.iter().filter(|o| o.target_outranks_decoy).count() as f64 / pm_count
        },
        target_found_rate: if pm.is_empty() {
            0.0
        } else {
            pm.iter().filter(|o| o.target_found).count() as f64 / pm_count
        },
        mean_target_rank: if found_target_ranks.is_empty() {
            None
        } else {
            Some(found_target_ranks.iter().sum::<f64>() / found_target_ranks.len() as f64)
        },
        query_p50_seconds: journey_p50(&pm.iter().map(|o| o.query_seconds).collect::<Vec<_>>()),
    };

    let vn_agg = VagueNarrowAggregate {
        clusters: vn.len(),
        true_found_rate: if vn.is_empty() {
            0.0
        } else {
            vn.iter().filter(|o| o.true_found).count() as f64 / vn_count
        },
        hydrated_true_rate: if vn.is_empty() {
            0.0
        } else {
            vn.iter().filter(|o| o.hydrated_true_member).count() as f64 / vn_count
        },
        mean_true_rank: if found_true_ranks.is_empty() {
            None
        } else {
            Some(found_true_ranks.iter().sum::<f64>() / found_true_ranks.len() as f64)
        },
        mean_hops: if vn.is_empty() {
            0.0
        } else {
            vn.iter().map(|o| o.metrics.hops).sum::<i64>() as f64 / vn_count
        },
        mean_token_turn_integral: if vn.is_empty() {
            0.0
        } else {
            vn.iter().map(|o| o.metrics.token_turn_integral).sum::<i64>() as f64 / vn_count
        },
        mean_pre_terminal_full_content_tokens: if vn.is_empty() {
            0.0
        } else {
            vn.iter().map(|o| o.metrics.pre_terminal_full_content_tokens).sum::<i64>() as f64
                / vn_count
        },
        mean_total_payload_tokens: if vn.is_empty() {
            0.0
        } else {
            vn.iter().map(|o| o.metrics.total_payload_tokens).sum::<i64>() as f64 / vn_count
        },
        journey_p50_seconds: journey_p50(
            &vn.iter().map(|o| o.journey_seconds).collect::<Vec<_>>(),
        ),
    };

    JourneyReport {
        estate_schema_version: crate::artifact_manifest::CURRENT_ESTATE_SCHEMA_VERSION.to_string(),
        benchmark_protocol_version: BENCHMARK_PROTOCOL_VERSION.to_string(),
        run_environment,
        seed: config.seed,
        top_k: config.top_k,
        coverage: JourneyCoverage {
            precise_miss_scenarios: corpus.precise_miss.scenarios.len(),
            vague_narrow_clusters: corpus.vague_narrow.clusters.len(),
            members_per_cluster: corpus.vague_narrow.members_per_cluster as usize,
            records_seeded: outcome.seeded_records,
            shape: config.shape.as_str().to_string(),
            estate_posture: posture_case_name(config.posture).to_string(),
        },
        precise_miss_aggregate: pm_agg,
        vague_narrow_aggregate: vn_agg,
        precise_miss: pm.clone(),
        vague_narrow: vn.clone(),
    }
}

/// Formats the stdout summary an operator reads first.
///
/// A metric with no samples prints "n/a", never a number: an absent mean and
/// a mean of zero are different findings, and printing zero for both hides
/// the difference behind a plausible value. Twin of Swift
/// `journeySummaryText(_:)`.
pub fn journey_summary_text(report: &JourneyReport) -> String {
    fn rank_text(v: Option<f64>) -> String {
        v.map(|x| format!("{x:.2}")).unwrap_or_else(|| "n/a".to_string())
    }
    let pm = &report.precise_miss_aggregate;
    let vn = &report.vague_narrow_aggregate;
    format!(
        "\n\
        \x20\x20\x20\x20[journey] run complete (seed {}, k={})\n\
        \x20\x20\x20\x20\x20\x20PRECISE-MISS  scenarios: {}\n\
        \x20\x20\x20\x20\x20\x20\x20\x20target over decoy:      {:.4}   <- the lane's headline\n\
        \x20\x20\x20\x20\x20\x20\x20\x20target found:           {:.4}\n\
        \x20\x20\x20\x20\x20\x20\x20\x20mean target rank:       {}\n\
        \x20\x20\x20\x20\x20\x20\x20\x20query p50:              {:.3} s\n\
        \x20\x20\x20\x20\x20\x20VAGUE-NARROW  clusters: {}\n\
        \x20\x20\x20\x20\x20\x20\x20\x20true member found:      {:.4}   <- the lane's headline\n\
        \x20\x20\x20\x20\x20\x20\x20\x20hydrated true member:   {:.4}\n\
        \x20\x20\x20\x20\x20\x20\x20\x20mean true rank:         {}\n\
        \x20\x20\x20\x20\x20\x20\x20\x20mean hops:              {:.2}\n\
        \x20\x20\x20\x20\x20\x20\x20\x20mean token-turn:        {:.1}\n\
        \x20\x20\x20\x20\x20\x20\x20\x20pre-terminal full:      {:.1}   <- cheap steps first; lower is better\n\
        \x20\x20\x20\x20\x20\x20\x20\x20journey p50:            {:.3} s\n\n",
        report.seed,
        report.top_k,
        pm.scenarios,
        pm.target_over_decoy_rate,
        pm.target_found_rate,
        rank_text(pm.mean_target_rank),
        pm.query_p50_seconds,
        vn.clusters,
        vn.true_found_rate,
        vn.hydrated_true_rate,
        rank_text(vn.mean_true_rank),
        vn.mean_hops,
        vn.mean_token_turn_integral,
        vn.mean_pre_terminal_full_content_tokens,
        vn.journey_p50_seconds,
    )
}

/// Encodes and writes a `JourneyReport` to a JSON file (sorted keys, never
/// overwritten). Twin of Swift's `writeRecordNeverOverwrite` call site in
/// `runJourney`, following the same pattern as `write_lmeb_report`.
pub fn write_journey_report(report: &JourneyReport, path: &Path) -> Result<(), String> {
    let json = serde_json::to_string_pretty(report)
        .map_err(|e| format!("report encode failed: {e}"))?;
    let value: serde_json::Value =
        serde_json::from_str(&json).map_err(|e| format!("report re-parse failed: {e}"))?;
    let sorted = crate::longmemeval_scorer::sorted_json_value(&value);
    let sorted_json = serde_json::to_string_pretty(&sorted)
        .map_err(|e| format!("sorted report encode failed: {e}"))?;
    crate::record_writer::write_record_never_overwrite(sorted_json.as_bytes(), path)
        .map_err(|e| format!("report write failed: {e}"))
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── journey_p50 ──────────────────────────────────────────────────────

    #[test]
    fn p50_empty_is_zero() {
        assert_eq!(journey_p50(&[]), 0.0);
    }

    #[test]
    fn p50_single_value() {
        assert_eq!(journey_p50(&[4.2]), 4.2);
    }

    #[test]
    fn p50_odd_count_takes_the_middle() {
        // sorted: [1.0, 2.0, 3.0] -> index min(2, 1) = 1 -> 2.0
        assert_eq!(journey_p50(&[3.0, 1.0, 2.0]), 2.0);
    }

    #[test]
    fn p50_even_count_takes_the_upper_middle() {
        // sorted: [1.0, 2.0, 3.0, 4.0] -> index min(3, 2) = 2 -> 3.0 (upper
        // middle, not the 2.5 average).
        assert_eq!(journey_p50(&[4.0, 2.0, 1.0, 3.0]), 3.0);
    }

    #[test]
    fn p50_unsorted_input_is_sorted_first() {
        assert_eq!(journey_p50(&[10.0, -5.0, 0.0, 2.5, 7.5, 1.0]), 2.5);
    }

    // ── target_outranks_decoy truth table ────────────────────────────────

    #[test]
    fn both_present_target_ahead_outranks() {
        assert!(target_outranks_decoy(Some(1), Some(2)));
    }

    #[test]
    fn both_present_decoy_ahead_does_not_outrank() {
        assert!(!target_outranks_decoy(Some(3), Some(1)));
    }

    #[test]
    fn target_present_decoy_absent_outranks() {
        // The strongest form of the measured behaviour: the decoy lost
        // entirely.
        assert!(target_outranks_decoy(Some(1), None));
    }

    #[test]
    fn target_absent_never_outranks_even_with_decoy_absent() {
        assert!(!target_outranks_decoy(None, None));
    }

    #[test]
    fn target_absent_decoy_present_does_not_outrank() {
        assert!(!target_outranks_decoy(None, Some(1)));
    }

    // ── journey_seed_records: room assignment + sort order ────────────────

    #[test]
    fn seed_records_split_by_room() {
        let corpus = crate::journey_corpus::generate_journey_corpus(20260725, 2, 2, 3);
        let records = journey_seed_records(&corpus);
        let pm_ids: std::collections::BTreeSet<&str> =
            corpus.precise_miss.records.iter().map(|r| r.id.as_str()).collect();
        let vn_ids: std::collections::BTreeSet<&str> =
            corpus.vague_narrow.records.iter().map(|r| r.id.as_str()).collect();
        for record in &records {
            if pm_ids.contains(record.id.as_str()) {
                assert_eq!(record.room, "precise-miss");
            } else if vn_ids.contains(record.id.as_str()) {
                assert_eq!(record.room, "vague-narrow");
            } else {
                panic!("seed record '{}' belongs to neither sub-corpus", record.id);
            }
        }
        assert_eq!(records.len(), pm_ids.len() + vn_ids.len());
    }

    #[test]
    fn seed_records_sorted_by_event_time_then_id() {
        let corpus = crate::journey_corpus::generate_journey_corpus(20260725, 3, 3, 4);
        let records = journey_seed_records(&corpus);
        for window in records.windows(2) {
            let (a, b) = (&window[0], &window[1]);
            assert!(
                (a.event_time.clone(), a.id.clone()) <= (b.event_time.clone(), b.id.clone()),
                "seed records must be sorted by (event_time, id): {} came before {}",
                a.id,
                b.id
            );
        }
    }

    #[test]
    fn seed_records_omit_optional_fields() {
        // Rooms carry the sub-corpus distinction; wing/kind/sensitivity/
        // exportability are all omitted (default wing, default kind, etc.)
        let corpus = crate::journey_corpus::generate_journey_corpus(1, 1, 0, 2);
        let records = journey_seed_records(&corpus);
        assert!(!records.is_empty());
        for record in &records {
            assert!(record.wing.is_none());
            assert!(record.kind.is_none());
            assert!(record.sensitivity.is_none());
            assert!(record.exportability.is_none());
        }
    }

    // ── posture_case_name: mirrors Swift's default enum description ───────

    #[test]
    fn posture_case_name_matches_swift_default_description() {
        assert_eq!(
            posture_case_name(ScratchEstatePosture::PlaintextTransient),
            "plaintextOptOut"
        );
        assert_eq!(
            posture_case_name(ScratchEstatePosture::EncryptedEphemeral),
            "encryptedEphemeral"
        );
        // Deliberately NOT the as_str() rawValue form used elsewhere.
        assert_ne!(
            posture_case_name(ScratchEstatePosture::PlaintextTransient),
            ScratchEstatePosture::PlaintextTransient.as_str()
        );
    }

    // ── PreciseMissOutcome / VagueNarrowOutcome JSON key shape ─────────────

    #[test]
    fn precise_miss_outcome_json_keys_match_swift_default_synthesis() {
        let outcome = PreciseMissOutcome {
            scenario_id: "pm-q-0".to_string(),
            target_rank: Some(1),
            decoy_rank: None,
            target_outranks_decoy: true,
            target_found: true,
            query_seconds: 0.01,
            metrics: JourneyMetrics {
                hops: 1,
                token_turn_integral: 30,
                pre_terminal_full_content_tokens: 0,
                total_payload_tokens: 30,
            },
            steps: vec![JourneyStep {
                verb: "recall".to_string(),
                payload_tokens: 30,
                hydrated_full_content: false,
                terminal: true,
            }],
        };
        let value = serde_json::to_value(&outcome).unwrap();
        let obj = value.as_object().unwrap();
        assert!(obj.contains_key("scenarioID"));
        assert!(obj.contains_key("targetRank"));
        assert!(obj.contains_key("decoyRank"));
        assert!(obj.contains_key("targetOutranksDecoy"));
        assert!(obj.contains_key("targetFound"));
        assert!(obj.contains_key("querySeconds"));
        // nil Option must serialize as JSON null, matching Swift's default
        // synthesized Codable behaviour for an Optional property.
        assert!(obj.get("decoyRank").unwrap().is_null());
    }

    #[test]
    fn vague_narrow_outcome_json_keys_match_swift_default_synthesis() {
        let outcome = VagueNarrowOutcome {
            cluster_id: "vn-q-0".to_string(),
            true_found: true,
            true_rank: Some(1),
            hydrated_true_member: true,
            metrics: JourneyMetrics {
                hops: 4,
                token_turn_integral: 10,
                pre_terminal_full_content_tokens: 0,
                total_payload_tokens: 4,
            },
            steps: vec![JourneyStep {
                verb: "recall".to_string(),
                payload_tokens: 4,
                hydrated_full_content: false,
                terminal: true,
            }],
            journey_seconds: 0.5,
        };
        let value = serde_json::to_value(&outcome).unwrap();
        let obj = value.as_object().unwrap();
        assert!(obj.contains_key("clusterID"));
        assert!(obj.contains_key("trueFound"));
        assert!(obj.contains_key("trueRank"));
        assert!(obj.contains_key("hydratedTrueMember"));
        assert!(obj.contains_key("metrics"));
        assert!(obj.contains_key("journeySeconds"));
        let metrics = obj.get("metrics").unwrap().as_object().unwrap();
        assert!(metrics.contains_key("hops"));
        assert!(metrics.contains_key("tokenTurnIntegral"));
        assert!(metrics.contains_key("preTerminalFullContentTokens"));
        assert!(metrics.contains_key("totalPayloadTokens"));
    }

    #[test]
    fn journey_report_json_keys_are_snake_case() {
        let report = JourneyReport {
        estate_schema_version: crate::artifact_manifest::CURRENT_ESTATE_SCHEMA_VERSION.to_string(),
            benchmark_protocol_version: BENCHMARK_PROTOCOL_VERSION.to_string(),
            run_environment: RunEnvironment::collect(None),
            seed: 1,
            top_k: 10,
            coverage: JourneyCoverage {
                precise_miss_scenarios: 0,
                vague_narrow_clusters: 0,
                members_per_cluster: 0,
                records_seeded: 0,
                shape: "ram".to_string(),
                estate_posture: "plaintextOptOut".to_string(),
            },
            precise_miss_aggregate: PreciseMissAggregate {
                scenarios: 0,
                mean_hops: 0.0,
                mean_token_turn_integral: 0.0,
                mean_pre_terminal_full_content_tokens: 0.0,
                mean_total_payload_tokens: 0.0,
                target_over_decoy_rate: 0.0,
                target_found_rate: 0.0,
                mean_target_rank: None,
                query_p50_seconds: 0.0,
            },
            vague_narrow_aggregate: VagueNarrowAggregate {
                clusters: 0,
                true_found_rate: 0.0,
                hydrated_true_rate: 0.0,
                mean_true_rank: None,
                mean_hops: 0.0,
                mean_token_turn_integral: 0.0,
                mean_pre_terminal_full_content_tokens: 0.0,
                mean_total_payload_tokens: 0.0,
                journey_p50_seconds: 0.0,
            },
            precise_miss: vec![],
            vague_narrow: vec![],
        };
        let value = serde_json::to_value(&report).unwrap();
        let obj = value.as_object().unwrap();
        assert!(obj.contains_key("benchmark_protocol_version"));
        assert!(obj.contains_key("run_environment"));
        assert!(obj.contains_key("seed"));
        assert!(obj.contains_key("k")); // topK -> "k"
        assert!(!obj.contains_key("top_k"));
        assert!(obj.contains_key("coverage"));
        assert!(obj.contains_key("precise_miss_aggregate"));
        assert!(obj.contains_key("vague_narrow_aggregate"));
        assert!(obj.contains_key("precise_miss"));
        assert!(obj.contains_key("vague_narrow"));
        let coverage = obj.get("coverage").unwrap().as_object().unwrap();
        assert!(coverage.contains_key("estate_posture"));
        assert_eq!(coverage.get("estate_posture").unwrap(), "plaintextOptOut");
    }
}
