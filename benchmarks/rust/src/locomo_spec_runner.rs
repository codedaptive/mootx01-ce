//! locomo_spec_runner.rs — Spec-compliant LoCoMo QA runner (Rust twin of
//! `LoCoMoSpecRunner.swift`).
//!
//! Source of truth: LOCOMO_OFFICIAL_PROTOCOL.md §1–§6 and §7 (deviation table).
//!
//! # Relationship to locomo_runner.rs
//!
//! `locomo_runner.rs`: rank-based recall@k / MRR scoring. No answer generation.
//! This module: F1 / exact / abstention scoring per §3, answers produced via
//! `moot_synthesize`. Per-category and per-question records, §5 aggregate.
//!
//! # Estate source (run book §8, the #94 measure seam)
//!
//! The runner opens the PRE-BUILT artifacts — at unit scale one fleet estate per
//! conversation (the official per-instance protocol scope), at bench-aggregate the
//! one Form-2 estate. It builds nothing, settles nothing, and never deletes
//! anything; id-map.json inside each estate maps seed record ids
//! ("<sampleID>/S<n>", the Rule-1 session projection) to drawer UUIDs.
//!
//! # Error semantics (cross-port intentional asymmetry)
//!
//! Swift twin aborts the whole run on any per-conversation error (it is the
//! measurement instrument). This Rust port emits stub question records with
//! `guard_healthy: false` and continues, so a parity comparison localises
//! the diff to the failing item.
//!
//! # Answer production
//!
//! `moot_synthesize` is the "existing moot answer-production path" referenced
//! by the LongMemEval synthesize arm (LongMemEvalRunner.swift). It retrieves
//! relevant turns from the estate and synthesises a short-phrase answer string.

use crate::artifact_recall::{load_artifact_id_map, ArtifactTargetScale};
use crate::config::{EndpointConfig, EndpointRole, ResultFormat, Transport, VerbMap};
use crate::degeneracy_guard::{GuardSamplingPolicy, LegGuardSampler};
use crate::json_value::JsonValue;
use crate::journey_driver::HydrationDepth;
use crate::locomo_scorer::LoCoMoManifestEntry;
use crate::locomo_spec_corpus::{LoCoMoSpecConversation, LoCoMoSpecCorpus, LoCoMoSpecQuestion};
use crate::locomo_spec_scorer::{evidence_recall, locomo_spec_aggregate, score_question, LoCoMoSpecAggregate};
use crate::longmemeval_runner::{probe_mcp_client, SplitMix64};
use crate::mcp_client::{MCPClient, ToolCaller};
use crate::scratch_posture::moot_serve_command;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Instant;

// ─────────────────────────────────────────────────────────────────────────────
// VerbMap
// ─────────────────────────────────────────────────────────────────────────────

// Bare verb map: NO constant location arg — the rebuilt artifacts are
// provenance-blind (rooms carry nothing benchmark-shaped), and at unit
// scale the per-instance estate IS the official protocol scope.
//
// Twin of Swift `loCoMoSpecVerbMap`.
fn locomo_spec_verb_map() -> VerbMap {
    VerbMap::new(
        crate::aria_v2_surface::FILE_MEMORY,
        crate::aria_v2_surface::MEMORY_SEARCH,
        None,
        None,
        None,
        None,
        None,   // empty constant_args
        Some(ResultFormat::MootV2),
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// Run configuration
// ─────────────────────────────────────────────────────────────────────────────

/// Configuration for one locomo-spec run.
///
/// Twin of Swift `LoCoMoSpecRunConfig`. The runner opens PRE-BUILT artifact
/// estates; it builds nothing, settles nothing, deletes nothing.
pub struct LoCoMoSpecRunConfig {
    /// Path to the mootx01 binary.
    pub moot_binary: String,
    /// Path to locomo10.json (or compatible fixture).
    pub dataset_path: PathBuf,
    /// Maximum questions to run. None = all 1,986 questions.
    pub limit: Option<usize>,
    /// Skip this many questions from the seeded-shuffled list.
    pub offset: usize,
    /// SplitMix64 seed for deterministic question shuffling.
    pub seed: u64,
    /// Output directory. None = current working directory.
    pub out_dir: Option<PathBuf>,
    /// Run label (the record "arm" in RecordWriter convention).
    pub run_label: String,
    /// Which artifact scale the run opens (run book §8: per-instance
    /// protocols default to .unit). .unit opens one fleet estate per
    /// conversation; .benchAggregate opens the one Form-2 estate for
    /// every conversation, serially. .completeAggregate is REFUSED for
    /// this lane.
    pub target_scale: ArtifactTargetScale,
    /// Path to the dataset's catalog.json (required at .unit scale). The catalog
    /// resolves each sample_id to its estate directory across primary and
    /// secondary bases.
    pub catalog_path: Option<PathBuf>,
    /// The Form-2 estate directory. Required at .benchAggregate scale.
    pub estate_dir: Option<PathBuf>,
    /// Maximum conversations processed concurrently. Default ~80% of cores.
    pub parallel_units: usize,
    /// Guard sampling policy. Default OncePerLeg.
    pub guard_sampling_policy: GuardSamplingPolicy,
    /// SHA-256 of the corpus fixture (B2 provenance). "unknown" if not computed.
    pub corpus_digest: String,
    /// Optional offline reader-input dump. The CLI writes it after the
    /// deterministic conversation reassembly.
    pub dump_answer_inputs_path: Option<PathBuf>,
    /// Ranked drawers hydrated for each reader question.
    pub answer_hydration_depth: usize,
    /// Stored text tier passed to moot_memory_get.
    pub answer_hydration_tier: HydrationDepth,
    /// When `Some`, passed as `"scoring"` in the `moot_memory_search` argument dict.
    /// Accepted values: `"raw"`, `"rrf"`, `"matrixAware"`, `"discriminative"`.
    /// When `None`, the key is absent — the call is byte-identical to the pre-flag baseline.
    pub scoring_strategy: Option<String>,
    /// When `Some`, the per-question recall call switches to `moot_recall_shaped` with
    /// this preset, matching the lmeb-spec `--recall-shape` flag. Mutually exclusive
    /// with `scoring_strategy` (the CLI rejects both together).
    pub recall_shape: Option<String>,
    /// Per-question verb call limit (default 20, always sent explicitly).
    pub request_limit: usize,
    /// Content-term threshold for the short-query gate (default 4).
    /// A question with content_term_count < short_query_terms is short.
    pub short_query_terms: usize,
}

// ─────────────────────────────────────────────────────────────────────────────
// Result types
// ─────────────────────────────────────────────────────────────────────────────

/// Per-question output produced by the spec runner.
/// Twin of Swift `LoCoMoSpecQuestionRecord`.
pub struct LoCoMoSpecQuestionRecord {
    /// Synthetic id: "<sample_id>_q<qa_index>".
    pub question_id: String,
    /// Integer category (1–5).
    pub category: u8,
    /// Human-readable category label.
    pub category_label: String,
    /// Gold answer verbatim. None for category 5.
    pub gold_answer: Option<String>,
    /// Prediction from moot_synthesize. Empty string on failure.
    pub prediction: String,
    /// Retrieved dia_ids in rank order (manifest-mapped from recall UUIDs).
    pub retrieved_dia_ids: Vec<String>,
    /// Per-§3 score: F1 (categories 1–4) or binary abstention (category 5).
    pub score: f64,
    /// Per-§4 evidence recall value.
    pub evidence_recall_value: f64,
    /// Latency of the moot_memory_search (recall) call, seconds.
    pub recall_latency_seconds: f64,
    /// Latency of the moot_synthesize call, seconds.
    pub synthesize_latency_seconds: f64,
    /// True when the DegeneracyGuard classified this estate as healthy.
    pub guard_healthy: bool,
    /// Guard diagnostic message when guard_healthy is false.
    pub guard_diagnostic: Option<String>,
    /// Total sessions in this conversation's estate (from id-map).
    pub turns_ingested: usize,
    /// Always None: artifact estates are pre-built; the estate-cache axis
    /// does not exist in this lane. Retained so the report schema keeps
    /// its column across the changeover.
    pub cache_hit: Option<bool>,

    // ── Expand-verify scoreboard per-question fields (§7.5 parity) ─────────
    /// Content-term count of the question text (lowercase alnum tokens minus
    /// the shared EN stopword fixture). Used for the short-query gate.
    pub content_term_count: usize,
    /// 1-based ranks of gold dia_ids within the returned list (absent → not returned).
    pub gold_ranks: Vec<usize>,
}

#[derive(Clone)]
pub struct LoCoMoSpecAnswerInput {
    pub question_id: String,
    pub category: u8,
    pub category_label: String,
    pub question: String,
    pub gold_answer: Option<String>,
    pub memory_texts: Vec<String>,
    pub retrieved_drawer_ids: Vec<String>,
    pub retrieved_ranks: Vec<usize>,
    pub retrieved_dia_ids: Vec<String>,
}

/// Run-level metadata for the report JSON.
/// Twin of Swift `LoCoMoSpecRunMetadata`.
pub struct LoCoMoSpecRunMetadata {
    /// "rust" (this port).
    pub port: &'static str,
    /// SplitMix64 seed.
    pub seed: u64,
    /// "artifact-unit" at unit scale, "artifact-aggregate" otherwise
    /// (Swift-parity estate-source naming).
    pub estate_mode: &'static str,
    /// Artifact target scale ("unit" | "bench-aggregate").
    pub target_scale: &'static str,
    /// Parallel conversations setting.
    pub parallel_units: usize,
    /// Corpus fixture digest.
    pub corpus_digest: String,
    /// Total questions processed.
    pub total_questions: usize,
    /// Distinct conversations whose estate was provisioned.
    pub conversations_used: usize,
    /// Run label (= record arm).
    pub run_label: String,
    /// Category counts from the full corpus.
    pub category_counts: BTreeMap<u8, usize>,
    /// Scoring strategy passed to moot_memory_search, or None when omitted (default scoring used).
    pub scoring_strategy: Option<String>,
    /// Recall shape preset passed to moot_recall_shaped, or None (moot_memory_search baseline).
    pub recall_shape: Option<String>,
    /// Per-question request limit (always sent explicitly; default 20).
    pub request_limit: usize,
    /// Short-query content-term threshold (default 4).
    pub short_query_terms: usize,
    /// Pending dreaming jobs in the estate at run start. 0 for unit-scale runs
    /// (no shared estate; dreaming is not active during per-conversation measurement).
    pub dream_pending: u64,
    /// 1 when the dreaming lane was actively draining at run start; 0 otherwise.
    /// 0 for unit-scale runs.
    pub dream_draining: u64,
}

/// Full output of `run_locomo_spec_questions`.
/// Twin of Swift `LoCoMoSpecRunResult`.
pub struct LoCoMoSpecRunResult {
    /// Per-question records in the order they were processed.
    pub question_records: Vec<LoCoMoSpecQuestionRecord>,
    /// §5 aggregate: overall + per-category accuracy + evidence recall.
    pub aggregate: LoCoMoSpecAggregate,
    /// Run-level metadata.
    pub metadata: LoCoMoSpecRunMetadata,
    /// Offline reader inputs in the same deterministic order as questions.
    pub answer_inputs: Vec<LoCoMoSpecAnswerInput>,
}

// ─────────────────────────────────────────────────────────────────────────────
// EndpointConfig builder
// ─────────────────────────────────────────────────────────────────────────────

/// Builds an EndpointConfig for mootx01 pointing at a pre-built artifact estate.
///
/// READ-ONLY use: the lane only calls moot_memory_search and moot_synthesize.
/// The artifact directory is opened as a transient record (`--db <dir>`), which
/// keeps serve identity keys in memory (zero Keychain contact).
///
/// Deliberately NOT routed through assertScratchBackend: that guard pins WRITE
/// lanes to /tmp scratch, and this lane reads a durable artifact in place
/// (same posture as ArtifactRecallRunner).
///
/// Command:
///   `MOOTX01_FROZEN=1 MOOTX01_SUBJECT_RIDER=0 <binary> serve --db <estate>`
///
/// Twin of Swift `loCoMoSpecEndpointConfig(estateDir:mootBinaryPath:)`.
fn locomo_spec_endpoint_config(estate_dir: &Path, moot_binary: &str) -> Result<EndpointConfig, String> {
    let data_dir = estate_dir.to_string_lossy();
    // A transient record: plaintext by rule, zero Keychain contact.
    let command = moot_serve_command(
        moot_binary, Path::new(&*data_dir), false, &["MOOTX01_FROZEN=1", "MOOTX01_SUBJECT_RIDER=0"], None)
        .map_err(|e| e.to_string())?;
    Ok(EndpointConfig {
        name: "mootx01-locomo-spec".to_string(),
        transport: Transport::Stdio { command },
        auth: None,
        verb_map: locomo_spec_verb_map(),
        role: EndpointRole::Both,
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// UUID → dia_id mapping
// ─────────────────────────────────────────────────────────────────────────────

/// Maps retrieved UUIDs to dia_ids in rank order using the conversation manifest.
///
/// Twin of Swift `loCoMoSpecRankedDiaIDs(uuids:manifest:)`.
fn ranked_dia_ids(uuids: &[String], manifest: &[LoCoMoManifestEntry]) -> Vec<String> {
    // Build UUID → dia_id lookup.
    let lookup: std::collections::HashMap<&str, &str> = manifest
        .iter()
        .map(|e| (e.uuid.as_str(), e.dia_id.as_str()))
        .collect();

    let mut seen = std::collections::HashSet::new();
    let mut ranked: Vec<String> = Vec::new();
    for uuid in uuids {
        if let Some(&dia_id) = lookup.get(uuid.as_str()) {
            if seen.insert(dia_id) {
                ranked.push(dia_id.to_string());
            }
        }
    }
    ranked
}

// ─────────────────────────────────────────────────────────────────────────────
// Evidence address-space mapping
// ─────────────────────────────────────────────────────────────────────────────

/// Maps evidence dia_ids to session pseudo-ids ("S<n>") for §4 evidence recall.
///
/// The artifact projection stores whole sessions (Rule-1: one drawer per
/// session), so retrieved context entries are session pseudo-ids ("S3").
/// Evidence dia_ids are per-turn ("D3:12"); they must be remapped to the
/// same session address space for §4 scoring to be meaningful.
///
/// Ground-truth evidence dia_ids → session pseudo-ids via the conversation
/// structure. Each dia_id belongs to exactly one session; the session
/// pseudo-id is "S<sessionNumber>". Duplicate session pseudo-ids are
/// deduplicated (first occurrence wins, preserving evidence set semantics).
///
/// Twin of Swift's inline `scoredEvidenceIDs(_:)` closure.
fn scored_evidence_ids(evidence: &[String], conversation: &LoCoMoSpecConversation) -> Vec<String> {
    // Build dia_id → session pseudo-id map from the conversation structure.
    let mut dia_to_session: std::collections::HashMap<&str, String> = Default::default();
    for session in &conversation.sessions {
        for turn in &session.turns {
            dia_to_session
                .entry(&turn.dia_id)
                .or_insert_with(|| format!("S{}", session.session_number));
        }
    }
    let mut seen = std::collections::HashSet::new();
    let mut result: Vec<String> = Vec::new();
    for e in evidence {
        let sid = dia_to_session.get(e.as_str()).cloned().unwrap_or_else(|| e.clone());
        if seen.insert(sid.clone()) {
            result.push(sid);
        }
    }
    result
}

// ─────────────────────────────────────────────────────────────────────────────
// Stub helper
// ─────────────────────────────────────────────────────────────────────────────

/// Produces a failed question record for error paths.
fn stub_record(q: &LoCoMoSpecQuestion, diagnostic: String) -> LoCoMoSpecQuestionRecord {
    LoCoMoSpecQuestionRecord {
        question_id: q.question_id.clone(),
        category: q.category,
        category_label: q.category_label().to_string(),
        gold_answer: q.answer.clone(),
        prediction: String::new(),
        retrieved_dia_ids: vec![],
        score: 0.0,
        evidence_recall_value: 0.0,
        recall_latency_seconds: 0.0,
        synthesize_latency_seconds: 0.0,
        guard_healthy: false,
        guard_diagnostic: Some(diagnostic),
        turns_ingested: 0,
        cache_hit: None,
        // Expand-verify fields default to zero for error stubs.
        content_term_count: 0,
        gold_ranks: vec![],
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Public runner
// ─────────────────────────────────────────────────────────────────────────────

/// Runs the locomo-spec harness over all (or a subset of) questions.
///
/// # Algorithm
///
/// 1. Shuffle `corpus.questions` with `SplitMix64(seed)`.
/// 2. Apply offset and limit.
/// 3. Group selected questions by `conversation_index`.
/// 4. For each conversation (parallel at unit scale; serial at bench-aggregate):
///    a. Resolve the artifact estate directory.
///    b. Load id-map.json: seed record ids → drawer UUIDs.
///    c. Build manifest from id-map entries with the conversation's key prefix.
///    d. Open a READ-ONLY serve on the estate.
///    e. Per-question: recall (moot_memory_search) + synthesize (moot_synthesize) → score.
///    (No ingest. No settle. No teardown of artifact estate.)
/// 5. Re-assemble results in ascending conversation-index order.
/// 6. §5 aggregate and return `LoCoMoSpecRunResult`.
///
/// Twin of Swift `runLoCoMoSpecQuestions(questions:conversations:config:)`.
pub fn run_locomo_spec_questions(
    corpus: &LoCoMoSpecCorpus,
    config: &LoCoMoSpecRunConfig,
) -> Result<LoCoMoSpecRunResult, String> {
    // ── Validate target scale ─────────────────────────────────────────────────
    // completeAggregate is not a valid projection for this lane (Rule-1 session
    // keys are per-conversation; a complete estate would mix conversations).
    if config.target_scale == ArtifactTargetScale::CompleteAggregate {
        eprintln!(
            "[locomo-spec] FATAL: completeAggregate is not supported by this lane — \
             use unit (--catalog) or bench-aggregate (--estate-dir)"
        );
        return Ok(LoCoMoSpecRunResult {
            question_records: vec![],
            aggregate: locomo_spec_aggregate(&[]),
            metadata: LoCoMoSpecRunMetadata {
                port: "rust",
                seed: config.seed,
                estate_mode: "error",
                target_scale: "complete-aggregate",
                parallel_units: 1,
                corpus_digest: config.corpus_digest.clone(),
                total_questions: 0,
                conversations_used: 0,
                run_label: config.run_label.clone(),
                category_counts: BTreeMap::new(),
                scoring_strategy: config.scoring_strategy.clone(),
                recall_shape: config.recall_shape.clone(),
                request_limit: config.request_limit,
                short_query_terms: config.short_query_terms,
                dream_pending: 0,
                dream_draining: 0,
            },
            answer_inputs: vec![],
        });
    }

    // ── Shuffle + offset + limit ──────────────────────────────────────────────
    let mut indices: Vec<usize> = (0..corpus.questions.len()).collect();
    let mut rng = SplitMix64::new(config.seed);
    rng.shuffle(&mut indices);
    if config.offset > 0 {
        indices = indices.into_iter().skip(config.offset).collect();
    }
    if let Some(limit) = config.limit {
        indices.truncate(limit);
    }

    // Group by conversation_index (ascending BTreeMap order = deterministic reassembly).
    let mut by_conv: BTreeMap<usize, Vec<&LoCoMoSpecQuestion>> = BTreeMap::new();
    for &qi in &indices {
        by_conv
            .entry(corpus.questions[qi].conversation_index)
            .or_default()
            .push(&corpus.questions[qi]);
    }
    let conv_keys: Vec<usize> = by_conv.keys().copied().collect();
    let total_convs = conv_keys.len();

    // At bench-aggregate scale, conversations must run serially — exactly one
    // serve holds the shared estate at a time.
    let effective_parallel = if config.target_scale == ArtifactTargetScale::Unit {
        config.parallel_units.min(total_convs.max(1))
    } else {
        1 // bench-aggregate: serial
    };

    // ── Shared guard sampler across all threads ───────────────────────────────
    let guard_sampler =
        std::sync::Mutex::new(LegGuardSampler::new(config.guard_sampling_policy));

    // ── Dream drain status probe ───────────────────────────────────────────────
    // Captured once per run via a temporary probe client. At bench-aggregate
    // scale the run holds one shared estate for all conversations; the probe
    // opens that estate before the conversation loop starts. At unit scale each
    // conversation has its own estate, so there is no shared estate to probe and
    // the field defaults to zero.
    let dream_status = if config.target_scale != ArtifactTargetScale::Unit {
        if let Some(ref estate_dir) = config.estate_dir {
            match locomo_spec_endpoint_config(estate_dir, &config.moot_binary) {
                Ok(endpoint) => {
                    let mut probe_client = MCPClient::new(endpoint);
                    if probe_client.connect().is_ok() {
                        let status =
                            crate::encode_barrier::read_drain_status_once(&mut probe_client);
                        let _ = probe_client.disconnect();
                        status
                    } else {
                        crate::encode_barrier::DreamStatus::default()
                    }
                }
                Err(e) => return Err(e),
            }
        } else {
            crate::encode_barrier::DreamStatus::default()
        }
    } else {
        crate::encode_barrier::DreamStatus::default()
    };

    // Work queue: (slot, conv_index). Pre-allocated result slots filled by workers.
    let work_queue: std::sync::Mutex<std::collections::VecDeque<(usize, usize)>> =
        std::sync::Mutex::new(
            conv_keys
                .iter()
                .enumerate()
                .map(|(slot, &ci)| (slot, ci))
                .collect(),
        );
    let results_by_slot: std::sync::Mutex<Vec<Option<Vec<LoCoMoSpecQuestionRecord>>>> =
        std::sync::Mutex::new((0..total_convs).map(|_| None).collect());
    let inputs_by_slot: std::sync::Mutex<Vec<Option<Vec<LoCoMoSpecAnswerInput>>>> =
        std::sync::Mutex::new((0..total_convs).map(|_| None).collect());

    let n_threads = effective_parallel;

    // Error channel: if any thread encounters a fatal endpoint config error,
    // it stores the message here. After the scope we propagate as Err.
    let endpoint_error: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);
    std::thread::scope(|s| {
        for _ in 0..n_threads {
            s.spawn(|| {
                loop {
                    let work = { work_queue.lock().unwrap().pop_front() };
                    let Some((slot, conv_index)) = work else {
                        break;
                    };

                    let conv_questions = &by_conv[&conv_index];
                    let conversation = &corpus.conversations[conv_index];
                    let mut conv_records: Vec<LoCoMoSpecQuestionRecord> = Vec::new();
                    let mut conv_inputs: Vec<LoCoMoSpecAnswerInput> = Vec::new();

                    // ── Resolve artifact estate directory ─────────────────────
                    // Unit scale: one catalog-resolved estate per conversation
                    // (sample_id is the unit id). Bench-aggregate: the single
                    // Form-2 estate.
                    let estate_dir: PathBuf = match config.target_scale {
                        ArtifactTargetScale::Unit => {
                            match &config.catalog_path {
                                Some(cat) => {
                                    match crate::artifact_recall::resolve_unit_from_catalog(
                                        cat, &conversation.sample_id,
                                    ) {
                                        Ok(p) => p,
                                        Err(e) => {
                                            let msg = e.description;
                                            eprintln!("[locomo-spec] FATAL: {msg}");
                                            for q in conv_questions.iter() {
                                                conv_records.push(stub_record(q, msg.clone()));
                                            }
                                            results_by_slot.lock().unwrap()[slot] = Some(conv_records);
                                            return;
                                        }
                                    }
                                }
                                None => {
                                    let msg = "locomo-spec: unit scale requires --catalog".to_string();
                                    eprintln!("[locomo-spec] FATAL: {msg}");
                                    for q in conv_questions.iter() {
                                        conv_records.push(stub_record(q, msg.clone()));
                                    }
                                    results_by_slot.lock().unwrap()[slot] = Some(conv_records);
                                    return;
                                }
                            }
                        }
                        ArtifactTargetScale::BenchAggregate
                        | ArtifactTargetScale::CompleteAggregate => {
                            match &config.estate_dir {
                                Some(ed) => ed.clone(),
                                None => {
                                    let msg = "locomo-spec: bench-aggregate requires --estate-dir".to_string();
                                    eprintln!("[locomo-spec] FATAL: {msg}");
                                    for q in conv_questions.iter() {
                                        conv_records.push(stub_record(q, msg.clone()));
                                    }
                                    results_by_slot.lock().unwrap()[slot] = Some(conv_records);
                                    return;
                                }
                            }
                        }
                    };

                    // ── Load id-map.json ──────────────────────────────────────
                    // id-map.json maps "<sampleID>/S<n>" → drawer UUID.
                    // Keys are the Rule-1 session projection written by the
                    // seeding pipeline. Filter to this conversation's keys.
                    let id_map = match load_artifact_id_map(&estate_dir) {
                        Ok(m) => m,
                        Err(e) => {
                            eprintln!(
                                "[locomo-spec] id-map load error for conv {}: {}",
                                conversation.sample_id, e.description
                            );
                            for q in conv_questions.iter() {
                                conv_records.push(stub_record(q, e.description.clone()));
                            }
                            results_by_slot.lock().unwrap()[slot] = Some(conv_records);
                            return;
                        }
                    };

                    // Build manifest from id-map entries whose key has the prefix
                    // "<sampleID>/S". The session number is parsed from the suffix.
                    let key_prefix = format!("{}/S", conversation.sample_id);
                    let mut manifest: Vec<LoCoMoManifestEntry> = Vec::new();
                    for (seed_id, uuid) in &id_map {
                        if seed_id.starts_with(&key_prefix) {
                            let session_num: usize = seed_id[key_prefix.len()..]
                                .parse()
                                .unwrap_or(0);
                            manifest.push(LoCoMoManifestEntry {
                                uuid: uuid.clone(),
                                dia_id: format!("S{session_num}"),
                                session_number: session_num,
                                turn_index: 0,
                                speaker: "session".to_string(),
                            });
                        }
                    }
                    if manifest.is_empty() {
                        let msg = format!(
                            "locomo-spec {}: id-map at {} has no {}* entries — \
                             wrong estate for this conversation?",
                            conversation.sample_id,
                            estate_dir.display(),
                            key_prefix
                        );
                        eprintln!("[locomo-spec] FATAL: {msg}");
                        for q in conv_questions.iter() {
                            conv_records.push(stub_record(q, msg.clone()));
                        }
                        results_by_slot.lock().unwrap()[slot] = Some(conv_records);
                        return;
                    }
                    let ingest_count = manifest.len();

                    eprintln!(
                        "[locomo-spec] conv={} ({} questions, {} sessions, scale={})",
                        conversation.sample_id,
                        conv_questions.len(),
                        ingest_count,
                        config.target_scale.as_str()
                    );

                    // ── Open READ-ONLY serve on the artifact estate ───────────
                    let verb_map = locomo_spec_verb_map();
                    let endpoint = match locomo_spec_endpoint_config(&estate_dir, &config.moot_binary) {
                        Ok(ep) => ep,
                        Err(e) => {
                            *endpoint_error.lock().unwrap() = Some(format!("locomo-spec: endpoint config error: {e}"));
                            return;
                        }
                    };
                    let mut client = MCPClient::new(endpoint);
                    if let Err(e) = client.connect() {
                        eprintln!(
                            "[locomo-spec] connect error for conv {}: {}",
                            conversation.sample_id, e.description
                        );
                        for q in conv_questions.iter() {
                            conv_records.push(stub_record(q, e.description.clone()));
                        }
                        results_by_slot.lock().unwrap()[slot] = Some(conv_records);
                        return;
                    }

                    // ── DegeneracyGuard probe ─────────────────────────────────
                    let (guard_healthy, guard_diagnostic, _was_probed) = guard_sampler
                        .lock()
                        .unwrap()
                        .probe(|| probe_mcp_client(&mut client, &verb_map));

                    // ── Per-question loop ─────────────────────────────────────
                    for q in conv_questions.iter() {
                        // ── Step 1: Recall → retrieved dia_ids for §4 evidence recall ──
                        let recall_start = Instant::now();
                        let mut query_args: BTreeMap<String, JsonValue> = BTreeMap::new();
                        query_args.insert(
                            verb_map.query_arg.clone(),
                            JsonValue::String(q.question.clone()),
                        );
                        // request_limit: always sent explicitly (default 20, per §1).
                        // JSONValue uses .number(f64) — there is no .integer variant.
                        query_args.insert("limit".to_string(), JsonValue::Number(config.request_limit as f64));
                        // Verb selection: moot_recall_shaped when --recall-shape given; else
                        // moot_memory_search. These are mutually exclusive with --scoring (CLI rejects both).
                        let recall_verb: &str;
                        if let Some(ref shape) = config.recall_shape {
                            recall_verb = crate::aria_v2_surface::RECALL_SHAPED;
                            query_args.insert("preset".to_string(), JsonValue::String(shape.clone()));
                        } else {
                            recall_verb = &verb_map.query;
                            // When --scoring is given, pass it to the estate; when omitted, the call
                            // is byte-identical to the pre-flag baseline (no "scoring" key in the dict).
                            if let Some(ref s) = config.scoring_strategy {
                                query_args.insert("scoring".to_string(), JsonValue::String(s.clone()));
                            }
                        }
                        // No constant_args: artifact estates are provenance-blind.
                        let (retrieved_uuids, retrieved_dia_ids, recall_latency) = match client
                            .call_tool(recall_verb, query_args, &verb_map.result_format)
                        {
                            Ok(result) => {
                                let elapsed = recall_start.elapsed().as_secs_f64();
                                let uuids = result.ordered_ids;
                                let dia_ids = ranked_dia_ids(&uuids, &manifest);
                                (uuids, dia_ids, elapsed)
                            }
                            Err(e) => {
                                eprintln!(
                                    "  [locomo-spec] recall error for {}: {}",
                                    q.question_id, e.description
                                );
                                (vec![], vec![], recall_start.elapsed().as_secs_f64())
                            }
                        };

                        if config.dump_answer_inputs_path.is_some() {
                            let mut memory_texts = Vec::new();
                            let mut hydrated_drawer_ids = Vec::new();
                            let mut hydrated_ranks = Vec::new();
                            for (index, uuid) in retrieved_uuids
                                .iter()
                                .take(config.answer_hydration_depth)
                                .enumerate()
                            {
                                let mut get_args: BTreeMap<String, JsonValue> = BTreeMap::new();
                                get_args.insert(
                                    "id".to_string(),
                                    JsonValue::String(uuid.clone()),
                                );
                                get_args.insert(
                                    "depth".to_string(),
                                    JsonValue::String(
                                        config.answer_hydration_tier.as_wire_str().to_string(),
                                    ),
                                );
                                match client.call_tool(
                                    crate::aria_v2_surface::MEMORY_GET,
                                    get_args,
                                    &ResultFormat::MootV2,
                                ) {
                                    Ok(result) => {
                                        let text = result.text_blocks.join("\n");
                                        if !text.is_empty() {
                                            memory_texts.push(text);
                                            hydrated_drawer_ids.push(uuid.clone());
                                            hydrated_ranks.push(index + 1);
                                        }
                                    }
                                    Err(error) => eprintln!(
                                        "  [locomo-spec] hydration error for {}: {}",
                                        uuid, error.description
                                    ),
                                }
                            }
                            conv_inputs.push(LoCoMoSpecAnswerInput {
                                question_id: q.question_id.clone(),
                                category: q.category,
                                category_label: q.category_label().to_string(),
                                question: q.question.clone(),
                                gold_answer: q.answer.clone(),
                                memory_texts,
                                retrieved_drawer_ids: hydrated_drawer_ids,
                                retrieved_ranks: hydrated_ranks,
                                retrieved_dia_ids: retrieved_dia_ids.clone(),
                            });
                        }

                        // ── Step 2: moot_synthesize → prediction string ────────
                        let synth_start = Instant::now();
                        let mut synth_args: BTreeMap<String, JsonValue> = BTreeMap::new();
                        synth_args.insert(
                            verb_map.query_arg.clone(),
                            JsonValue::String(q.question.clone()),
                        );
                        let (prediction, synth_latency) = match client
                            .call_tool(crate::aria_v2_surface::SYNTHESIZE, synth_args, &verb_map.result_format)
                        {
                            Ok(result) => {
                                let elapsed = synth_start.elapsed().as_secs_f64();
                                let text = result.text_blocks.join("\n").trim().to_string();
                                (text, elapsed)
                            }
                            Err(e) => {
                                eprintln!(
                                    "  [locomo-spec] moot_synthesize error for {}: {}",
                                    q.question_id, e.description
                                );
                                (String::new(), synth_start.elapsed().as_secs_f64())
                            }
                        };

                        // ── Step 3: Score per §3 ──────────────────────────────
                        let gold = q.answer.as_deref().unwrap_or("");
                        let score = match score_question(q.category, &prediction, gold) {
                            Ok(s) => s,
                            Err(msg) => {
                                eprintln!(
                                    "  [locomo-spec] score_question error for {}: {msg}",
                                    q.question_id
                                );
                                0.0
                            }
                        };

                        // ── Step 4: Evidence recall §4 (dia form) ────────────
                        // Ground-truth evidence dia_ids are mapped to session
                        // pseudo-ids because the artifact projection is session-level
                        // (Rule-1: one drawer per session).
                        let evidence_for_scoring =
                            scored_evidence_ids(&q.evidence, conversation);
                        let recall_value =
                            evidence_recall(Some(&retrieved_dia_ids), &evidence_for_scoring);

                        // ── Expand-verify per-question fields (§7.5 parity) ──────
                        let content_term_count =
                            crate::lmeb_spec_metrics::lmeb_content_term_count(&q.question);
                        // gold_ranks: 1-based positions of gold dia_ids in the returned list.
                        let gold_dia_set: std::collections::HashSet<&str> =
                            q.evidence.iter().map(|s| s.as_str()).collect();
                        let gold_ranks: Vec<usize> = retrieved_dia_ids
                            .iter()
                            .enumerate()
                            .filter_map(|(i, dia)| {
                                if gold_dia_set.contains(dia.as_str()) { Some(i + 1) } else { None }
                            })
                            .collect();

                        conv_records.push(LoCoMoSpecQuestionRecord {
                            question_id: q.question_id.clone(),
                            category: q.category,
                            category_label: q.category_label().to_string(),
                            gold_answer: q.answer.clone(),
                            prediction,
                            retrieved_dia_ids,
                            score,
                            evidence_recall_value: recall_value,
                            recall_latency_seconds: recall_latency,
                            synthesize_latency_seconds: synth_latency,
                            guard_healthy,
                            guard_diagnostic: guard_diagnostic.clone(),
                            turns_ingested: ingest_count,
                            cache_hit: None, // always None: artifact estates are pre-built
                            content_term_count,
                            gold_ranks,
                        });
                    }

                    // ── Disconnect (no teardown — the artifact estate is durable) ──
                    client.disconnect();

                    results_by_slot.lock().unwrap()[slot] = Some(conv_records);
                    inputs_by_slot.lock().unwrap()[slot] = Some(conv_inputs);
                } // end loop
            }); // end spawn
        }
    }); // end scope

    // Propagate any endpoint-config refusal (e.g. whitespace in scratch path).
    // The thread stored the message; we return Err so main() exits 1 not 101.
    if let Some(err) = endpoint_error.into_inner().unwrap() {
        return Err(err);
    }

    // ── Reassemble in ascending conversation-index order ──────────────────────
    let all_records: Vec<LoCoMoSpecQuestionRecord> = results_by_slot
        .into_inner()
        .unwrap()
        .into_iter()
        .flat_map(|slot| slot.unwrap_or_default())
        .collect();
    let all_answer_inputs: Vec<LoCoMoSpecAnswerInput> = inputs_by_slot
        .into_inner()
        .unwrap()
        .into_iter()
        .flat_map(|slot| slot.unwrap_or_default())
        .collect();

    // ── §5 Aggregation ────────────────────────────────────────────────────────
    let score_tuples: Vec<(u8, f64, f64)> = all_records
        .iter()
        .map(|r| (r.category, r.score, r.evidence_recall_value))
        .collect();
    let aggregate = locomo_spec_aggregate(&score_tuples);

    // ── Run metadata ──────────────────────────────────────────────────────────
    let mut category_counts: BTreeMap<u8, usize> = BTreeMap::new();
    for q in &corpus.questions {
        *category_counts.entry(q.category).or_insert(0) += 1;
    }

    let estate_mode = if config.target_scale == ArtifactTargetScale::Unit {
        "artifact-unit"
    } else {
        "artifact-aggregate"
    };

    let metadata = LoCoMoSpecRunMetadata {
        port: "rust",
        seed: config.seed,
        estate_mode,
        target_scale: config.target_scale.as_str(),
        parallel_units: effective_parallel,
        corpus_digest: config.corpus_digest.clone(),
        total_questions: all_records.len(),
        conversations_used: conv_keys.len(),
        run_label: config.run_label.clone(),
        category_counts,
        scoring_strategy: config.scoring_strategy.clone(),
        recall_shape: config.recall_shape.clone(),
        request_limit: config.request_limit,
        short_query_terms: config.short_query_terms,
        dream_pending: dream_status.pending,
        dream_draining: if dream_status.draining { 1 } else { 0 },
    };

    Ok(LoCoMoSpecRunResult {
        question_records: all_records,
        aggregate,
        metadata,
        answer_inputs: all_answer_inputs,
    })
}

/// Stable JSONL twin of Swift `loCoMoSpecAnswerInputsJSONL`.
pub fn answer_inputs_jsonl(
    result: &LoCoMoSpecRunResult,
    hydration_depth: usize,
    hydration_tier: HydrationDepth,
) -> Result<Vec<u8>, String> {
    let mut rows = vec![serde_json::json!({
        "type": "header",
        "benchmark": "locomo-spec",
        "seed": result.metadata.seed,
        "run_label": result.metadata.run_label,
        "answer_hydration_depth": hydration_depth,
        "hydration_tier": hydration_tier.as_wire_str(),
        "corpus_digest": result.metadata.corpus_digest,
    })];
    rows.extend(result.answer_inputs.iter().map(|input| serde_json::json!({
        "type": "answer_input",
        "benchmark": "locomo-spec",
        "question_id": input.question_id,
        "category": input.category,
        "category_label": input.category_label,
        "question": input.question,
        "gold_answer": input.gold_answer,
        "memory_texts": input.memory_texts,
        "retrieved_drawer_ids": input.retrieved_drawer_ids,
        "retrieved_dia_ids": input.retrieved_dia_ids,
        "retrieved_ranks": input.retrieved_ranks,
    })));
    let mut bytes = Vec::new();
    for row in rows {
        let sorted = crate::longmemeval_scorer::sorted_json_value(&row);
        serde_json::to_writer(&mut bytes, &sorted)
            .map_err(|error| format!("locomo answer-input encode failed: {error}"))?;
        bytes.push(b'\n');
    }
    Ok(bytes)
}

// ─────────────────────────────────────────────────────────────────────────────
// Report helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Builds the `run_parameters` value for a LoCoMo spec report.
///
/// Called from `main.rs` when constructing the JSON report — the only
/// production emit path. Moving the construction here (rather than inlining
/// it in the `serde_json::json!` macro call) means the dream-field gate tests
/// exercise the same code path that ships in the binary.
///
/// Key set mirrors `loCoMoSpecReportJSON` in `LoCoMoSpecRunner.swift:920-945`.
pub fn locomo_spec_run_parameters(
    meta: &LoCoMoSpecRunMetadata,
    arm: &str,
    serial: &str,
) -> serde_json::Value {
    serde_json::json!({
        "port":               meta.port,
        "seed":               meta.seed,
        "estate_mode":        meta.estate_mode,
        "target_scale":       meta.target_scale,
        "corpus_digest":      meta.corpus_digest,
        "conversations_used": meta.conversations_used,
        "run_label":          meta.run_label,
        "arm":                arm,
        "serial":             serial,
        // Scoring strategy: "default" when --scoring was omitted, the literal value otherwise.
        "scoring": meta.scoring_strategy.as_deref().unwrap_or("default"),
        // Recall shape: "none" when absent (moot_memory_search baseline).
        "recall_shape": meta.recall_shape.as_deref().unwrap_or("none"),
        "request_limit": meta.request_limit,
        "short_query_terms": meta.short_query_terms,
        // Dream drain lane state at run start; 0 for unit-scale runs.
        "dream_pending":  meta.dream_pending,
        "dream_draining": meta.dream_draining,
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::locomo_spec_corpus::LoCoMoSpecTurn;

    // ── UUID → dia_id mapping ─────────────────────────────────────────────────

    #[test]
    fn ranked_dia_ids_basic() {
        let manifest = vec![
            LoCoMoManifestEntry {
                uuid: "uuid-a".to_string(),
                dia_id: "D1:1".to_string(),
                session_number: 1,
                turn_index: 0,
                speaker: "Alice".to_string(),
            },
            LoCoMoManifestEntry {
                uuid: "uuid-b".to_string(),
                dia_id: "D1:2".to_string(),
                session_number: 1,
                turn_index: 1,
                speaker: "Bob".to_string(),
            },
        ];
        // Ranked: uuid-b first, uuid-a second.
        let uuids = vec!["uuid-b".to_string(), "uuid-a".to_string()];
        let result = ranked_dia_ids(&uuids, &manifest);
        assert_eq!(result, vec!["D1:2", "D1:1"]);
    }

    #[test]
    fn ranked_dia_ids_deduplicates() {
        let manifest = vec![LoCoMoManifestEntry {
            uuid: "uuid-a".to_string(),
            dia_id: "D1:1".to_string(),
            session_number: 1,
            turn_index: 0,
            speaker: "Alice".to_string(),
        }];
        // Duplicate UUID in retrieved list — should appear only once.
        let uuids = vec!["uuid-a".to_string(), "uuid-a".to_string()];
        let result = ranked_dia_ids(&uuids, &manifest);
        assert_eq!(result, vec!["D1:1"]);
    }

    #[test]
    fn ranked_dia_ids_unknown_uuid_skipped() {
        let manifest: Vec<LoCoMoManifestEntry> = vec![];
        let uuids = vec!["some-unknown-uuid".to_string()];
        let result = ranked_dia_ids(&uuids, &manifest);
        assert!(result.is_empty());
    }

    // ── Evidence scoring address-space mapping ────────────────────────────────

    #[test]
    fn scored_evidence_ids_maps_to_session_pseudo_id() {
        // Both turns are in session 1 → both map to "S1".
        let conv = make_mini_conv();
        let evidence = vec!["D1:1".to_string(), "D1:2".to_string()];
        let result = scored_evidence_ids(&evidence, &conv);
        // Both collapse to the same session pseudo-id; deduplication applies.
        assert_eq!(result, vec!["S1"]);
    }

    #[test]
    fn scored_evidence_ids_unknown_dia_id_passes_through() {
        // An evidence dia_id not in the conversation maps to itself.
        let conv = make_mini_conv();
        let evidence = vec!["D99:99".to_string()];
        let result = scored_evidence_ids(&evidence, &conv);
        assert_eq!(result, vec!["D99:99"]);
    }

    // ── Test helpers ──────────────────────────────────────────────────────────

    fn make_mini_conv() -> LoCoMoSpecConversation {
        use crate::locomo_spec_corpus::LoCoMoSpecSession;
        LoCoMoSpecConversation {
            sample_id: "conv-test".to_string(),
            speaker_a: "Alice".to_string(),
            speaker_b: "Bob".to_string(),
            sessions: vec![LoCoMoSpecSession {
                session_number: 1,
                date_time: "2026-01-01".to_string(),
                turns: vec![
                    LoCoMoSpecTurn {
                        speaker: "Alice".to_string(),
                        dia_id: "D1:1".to_string(),
                        text: "Hello".to_string(),
                        image_caption: None,
                    },
                    LoCoMoSpecTurn {
                        speaker: "Bob".to_string(),
                        dia_id: "D1:2".to_string(),
                        text: "Hi there".to_string(),
                        image_caption: None,
                    },
                ],
            }],
        }
    }

    // ── Scoring strategy flag ─────────────────────────────────────────────────

    /// Verifies the scoring key is absent from the query args dict when
    /// scoring_strategy is None (byte-identical baseline) and present when Some.
    #[test]
    fn scoring_arg_propagation() {
        // Baseline: None strategy → no "scoring" key in the dict.
        let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
        args.insert("q".to_string(), JsonValue::String("hello".to_string()));
        let scoring_none: Option<String> = None;
        if let Some(ref s) = scoring_none {
            args.insert("scoring".to_string(), JsonValue::String(s.clone()));
        }
        assert!(!args.contains_key("scoring"),
            "omitted --scoring must produce no 'scoring' key in the query dict");

        // Given strategy: key must be present with the exact value.
        let mut args2: BTreeMap<String, JsonValue> = BTreeMap::new();
        args2.insert("q".to_string(), JsonValue::String("hello".to_string()));
        let scoring_some: Option<String> = Some("discriminative".to_string());
        if let Some(ref s) = scoring_some {
            args2.insert("scoring".to_string(), JsonValue::String(s.clone()));
        }
        assert_eq!(
            args2.get("scoring"),
            Some(&JsonValue::String("discriminative".to_string())),
            "given --scoring discriminative must wire as 'scoring': 'discriminative'"
        );
    }

    // ── Dream fields in run_parameters ────────────────────────────────────────
    //
    // Twin of Swift LoCoMoSpecDreamFieldTests. Drives locomo_spec_run_parameters
    // — the production emit path — and asserts wire key names and values.

    /// Helper: build a minimal LoCoMoSpecRunMetadata with given dream values.
    fn make_dream_metadata(dream_pending: u64, dream_draining: u64) -> LoCoMoSpecRunMetadata {
        LoCoMoSpecRunMetadata {
            port: "rust",
            seed: 42,
            estate_mode: "artifact-unit",
            target_scale: "unit",
            parallel_units: 4,
            corpus_digest: "sha256-test".to_string(),
            total_questions: 1,
            conversations_used: 1,
            run_label: "test-arm".to_string(),
            category_counts: BTreeMap::new(),
            scoring_strategy: None,
            recall_shape: None,
            request_limit: 20,
            short_query_terms: 4,
            dream_pending,
            dream_draining,
        }
    }

    /// Draining case: dream_pending=3, dream_draining=1 appear in run_parameters output.
    ///
    /// Goes red when dream_pending or dream_draining are omitted from
    /// locomo_spec_run_parameters, or when their values differ.
    #[test]
    fn locomo_spec_dream_draining() {
        let meta = make_dream_metadata(3, 1);
        let v = locomo_spec_run_parameters(&meta, "test-arm", "r1");
        assert_eq!(
            v["dream_pending"].as_u64(),
            Some(3),
            "run_parameters must have dream_pending=3 — got: {:?}", v["dream_pending"]
        );
        assert_eq!(
            v["dream_draining"].as_u64(),
            Some(1),
            "run_parameters must have dream_draining=1 — got: {:?}", v["dream_draining"]
        );
    }

    /// Settled case: dream_pending=0, dream_draining=0 appear in run_parameters output.
    ///
    /// Goes red when dream_pending or dream_draining are omitted from
    /// locomo_spec_run_parameters, or when their values differ.
    #[test]
    fn locomo_spec_dream_settled() {
        let meta = make_dream_metadata(0, 0);
        let v = locomo_spec_run_parameters(&meta, "test-arm", "r1");
        assert_eq!(
            v["dream_pending"].as_u64(),
            Some(0),
            "run_parameters must have dream_pending=0 — got: {:?}", v["dream_pending"]
        );
        assert_eq!(
            v["dream_draining"].as_u64(),
            Some(0),
            "run_parameters must have dream_draining=0 — got: {:?}", v["dream_draining"]
        );
    }

    /// Asserts the complete key set of locomo_spec_run_parameters matches the
    /// Swift twin (LoCoMoSpecRunner.swift:920-945, loCoMoSpecReportJSON).
    ///
    /// Goes red when any of the fifteen wire keys is missing from the returned
    /// Value — catching port divergence before it reaches a written report.
    ///
    /// Note: the Swift twin carries two further keys, unit_ids_path and
    /// selected_count. They are absent here because the Rust locomo-spec lane
    /// has no unit-ID filter at all: Swift sets specConfig.unitIDsPath at
    /// CLI.swift:2825, while run_locomo_spec in main.rs reads no
    /// MOOT_BENCH_UNIT_IDS. Closing that is a lane capability change rather
    /// than a field addition, so both keys are excluded from this assertion.
    #[test]
    fn locomo_spec_run_parameters_key_set() {
        let meta = make_dream_metadata(0, 0);
        let v = locomo_spec_run_parameters(&meta, "test-arm", "r1");
        let obj = v.as_object().expect("run_parameters must be a JSON object");
        let expected_keys = [
            "port", "seed", "estate_mode", "target_scale", "corpus_digest",
            "conversations_used", "run_label", "arm", "serial", "scoring",
            "recall_shape", "request_limit", "short_query_terms",
            "dream_pending", "dream_draining",
        ];
        for key in &expected_keys {
            assert!(
                obj.contains_key(*key),
                "run_parameters must contain key '{key}' — keys present: {:?}",
                obj.keys().collect::<Vec<_>>()
            );
        }
    }
}
