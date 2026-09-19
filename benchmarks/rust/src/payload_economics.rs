//! payload_economics.rs — the payload-economics and synthesis-payload
//! internal lanes (run book §9; benchmarks/payload-economics.md,
//! benchmarks/synthesis-payload.md). Rust twin of
//! `PayloadEconomicsRunner.swift`.
//!
//! A MOOTx01-authored instrument over the frozen lme-s corpus and the
//! selected port's Form-2 lme-s artifact. Scoring is mechanical and
//! deterministic — no judge anywhere in the loop (operator ruling,
//! 2026-08-28):
//!
//!   tokens read              (utf8_byte_count + 3) / 4   [lme_estimate_tokens]
//!   evidence hit rate        has_answer turn text, normalized substring
//!                            [lme_evidence_hit] — the fetched cleaned
//!                            fixtures (longmemeval_s_cleaned.json) carry
//!                            has_answer; a corpus without the field
//!                            yields None
//!   answer presence rate     gold answer text, normalized substring
//!                            [lme_gold_answer_in_payload] — always available
//!   per-1000-token figures   rate ÷ mean tokens × 1000 — the comparison
//!                            figures the definitions name
//!
//! Result surfaces per question, all over ONE read-only serve on the
//! artifact estate (the artifact-recall open pattern — the lane never
//! provisions, settles, or tears down). The definition's payload shapes
//! map onto the ARIA surface as follows (the report's `shape_mapping`
//! field records this mapping in every artifact):
//!
//!   Preview       exact arm       moot_memory_search — the ruled candidate
//!                                 rows: a short extract per returned row
//!   Full content  full_content    moot_memory_get {ids, depth: full} over
//!                                 the exact arm's returned ids — the
//!                                 complete body of each returned row,
//!                                 rendered from the SAME frozen retrieval
//!   Compressed    dense arm       moot_recall_distilled — the store-reduced
//!                                 form of the returned content
//!   Synthesis     synthesize      moot_synthesize — store-generated digest
//!                                 (--synthesize-arm; the synthesis-payload
//!                                 lane is this runner with the arm on)
//!
//! naked|<id>[,<id>...] prepares one arm per run: the artifact is cloned
//! copy-on-write to `<--arm-scratch-root>/<estate>-arm-<slug>`, exactly the
//! seam the artifact-cache restore path uses), the clone is served frozen,
//! and the clone is removed after the serve exits, also on error. The
//! artifact is never written. Without the flag the artifact is served in
//! place with whatever set it holds. Either way the report records
//!
//! Retrieval hit@k / MRR are computed for the exact and dense arms through
//! the artifact id-map fold (id-map.json keys are raw lme-s session ids),
//! so the report also shows the retrieval effectiveness the payload rides
//! on. The synth arm returns prose, not ranked ids — it carries token and
//! evidence figures only. full_content rides the exact arm's ranked list
//! (it batch-hydrates the exact arm's returned ids), so it carries no
//! retrieval figures of its own either.
//!
//! --payload-arm v0..v5 (PayloadArm) post-processes payload text
//! harness-side before token/evidence measurement, exactly as in the
//! longmemeval lane. Dense-row grammar lines are stripped per arm;
//! non-row payloads pass through unchanged, so the arm is safe to apply
//! uniformly to every payload kind.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};

use crate::artifact_recall::{
    apply_artifact_limit, artifact_map_ranked_uuids, artifact_reverse_id_map,
    load_artifact_id_map, load_artifact_recall_questions, partition_artifact_questions,
    score_artifact_question, ArtifactDataset, ArtifactRecallQuestion,
};
use crate::config::{EndpointConfig, EndpointRole, ResultFormat, Transport, VerbMap};
use crate::estate_cache::{
    estate_database_path,
};
use crate::journey_driver::{batch_hydrate_args, HydrationDepth};
use crate::json_value::JsonValue;
use crate::longmemeval_corpus::{load_corpus, LmeQuestion};
use crate::longmemeval_token_efficiency::{
    lme_estimate_tokens, lme_evidence_hit, lme_gold_answer_in_payload,
};
use crate::mcp_client::{MCPClient, MCPError, ToolCaller};
use crate::payload_arm::PayloadArm;
use crate::run_environment::file_sha256_hex;
use crate::scratch_posture::moot_serve_command;

// ─────────────────────────────────────────────────────────────────────────────
// Config
// ─────────────────────────────────────────────────────────────────────────────

/// The payload-lane invocation, parsed by `run_payload_economics` (main.rs).
/// Twin of Swift `PayloadLaneConfig`.
pub struct PayloadLaneConfig {
    /// The selected port's Form-2 lme-s artifact estate (fixed dependency;
    /// the lane takes no SCALE — run book §9).
    pub estate_dir: PathBuf,
    /// The seeding pipeline's 3rd-person unscoped questions.jsonl
    /// (lme-s adapter shape; sample_id == official question_id).
    pub questions_path: PathBuf,
    /// Official LongMemEval data dir — source of gold answers and, where
    /// present, has_answer evidence annotations.
    pub data_dir: PathBuf,
    /// Corpus variant ("s" for the frozen lme-s corpus).
    pub variant: String,
    /// True = the synthesis-payload lane: adds the moot_synthesize digest arm.
    pub synthesize_arm: bool,
    /// Optional `limit` forwarded to moot_synthesize (recorded in the report).
    pub synthesize_limit: Option<usize>,
    /// Optional harness-side payload shape variant (v0..v5).
    pub payload_arm: Option<PayloadArm>,
    /// Question cap (0 = all).
    pub limit: usize,
    /// Retrieval result limit AND the k of hit@k.
    pub top_k: usize,
    /// Report output path.
    pub out_path: PathBuf,
    /// mootx01 binary path.
    pub moot_binary: String,
}

// ─────────────────────────────────────────────────────────────────────────────
// Pure aggregation
// ─────────────────────────────────────────────────────────────────────────────

/// Per-question, per-arm measurement retained for aggregation and the
/// inspectability tail. Twin of Swift `PayloadArmSample`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PayloadArmSample {
    /// Estimated payload tokens.
    pub tokens: usize,
    /// has_answer evidence present in the payload. None = the question
    /// carries no annotation (unknown, never a miss).
    pub evidence_hit: Option<bool>,
    /// Gold answer text present in the payload.
    pub answer_present: bool,
    /// Retrieval hit@k through the id-map fold. None for the synth arm
    /// (prose, no ranked ids).
    pub hit_at_k: Option<bool>,
    /// Retrieval reciprocal rank. None for the synth arm.
    pub reciprocal_rank: Option<f64>,
}

/// One arm's aggregated cell, as published in the report. Twin of Swift
/// `PayloadArmCell`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PayloadArmCell {
    pub n: usize,
    pub mean_tokens: f64,
    /// None when no question carried a has_answer annotation.
    pub evidence_hit_rate: Option<f64>,
    /// Evidence hits per 1000 tokens. None when evidence_hit_rate is None
    /// or mean_tokens is 0.
    pub evidence_hits_per_1k_tokens: Option<f64>,
    pub answer_presence_rate: f64,
    /// Answer presence per 1000 tokens. None when mean_tokens is 0.
    pub answer_presence_per_1k_tokens: Option<f64>,
    /// None for the synth arm.
    pub hit_at_k: Option<f64>,
    pub mrr: Option<f64>,
}

/// Aggregates one arm's samples into its report cell. Pure — the literal
/// vector is pinned identically in the Swift twin (armCellAggregation in
/// PayloadEconomicsTests.swift). Twin of Swift `aggregatePayloadArm`.
pub fn aggregate_payload_arm(samples: &[PayloadArmSample]) -> PayloadArmCell {
    let n = samples.len();
    if n == 0 {
        return PayloadArmCell {
            n: 0,
            mean_tokens: 0.0,
            evidence_hit_rate: None,
            evidence_hits_per_1k_tokens: None,
            answer_presence_rate: 0.0,
            answer_presence_per_1k_tokens: None,
            hit_at_k: None,
            mrr: None,
        };
    }
    let mean_tokens = samples.iter().map(|s| s.tokens).sum::<usize>() as f64 / n as f64;
    let annotated: Vec<bool> = samples.iter().filter_map(|s| s.evidence_hit).collect();
    let evidence_rate: Option<f64> = if annotated.is_empty() {
        None
    } else {
        Some(annotated.iter().filter(|&&b| b).count() as f64 / annotated.len() as f64)
    };
    let answer_rate =
        samples.iter().filter(|s| s.answer_present).count() as f64 / n as f64;
    let scored: Vec<bool> = samples.iter().filter_map(|s| s.hit_at_k).collect();
    let hit_at_k: Option<f64> = if scored.is_empty() {
        None
    } else {
        Some(scored.iter().filter(|&&b| b).count() as f64 / scored.len() as f64)
    };
    let rrs: Vec<f64> = samples.iter().filter_map(|s| s.reciprocal_rank).collect();
    let mrr: Option<f64> =
        if rrs.is_empty() { None } else { Some(rrs.iter().sum::<f64>() / rrs.len() as f64) };
    let per_1k = |rate: Option<f64>| -> Option<f64> {
        match rate {
            Some(r) if mean_tokens > 0.0 => Some(r / mean_tokens * 1000.0),
            _ => None,
        }
    };
    PayloadArmCell {
        n,
        mean_tokens,
        evidence_hit_rate: evidence_rate,
        evidence_hits_per_1k_tokens: per_1k(evidence_rate),
        answer_presence_rate: answer_rate,
        answer_presence_per_1k_tokens: per_1k(Some(answer_rate)),
        hit_at_k,
        mrr,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Question join
// ─────────────────────────────────────────────────────────────────────────────

/// Extracts the evidence text for a question from its `has_answer` turns.
///
/// Walks the answer sessions in haystack order, finds all turns where
/// `LmeTurn.has_answer == true`, and joins their content with a space
/// separator.
///
/// Returns None when no `has_answer` turns are present. The fetched
/// cleaned fixtures (longmemeval_s_cleaned.json) carry the field; a
/// corpus without it yields None, meaning the evidence-hit score is
/// unavailable for this question — callers should treat it as an
/// "unknown" result rather than a miss. Twin of Swift
/// `lmeEvidenceTextForQuestion`.
pub fn lme_evidence_text_for_question(question: &LmeQuestion) -> Option<String> {
    let answer_session_set: HashSet<&str> =
        question.answer_session_ids.iter().map(String::as_str).collect();
    let mut parts: Vec<String> = Vec::new();
    for (session_id, session) in
        question.haystack_session_ids.iter().zip(question.haystack_sessions.iter())
    {
        if !answer_session_set.contains(session_id.as_str()) {
            continue;
        }
        for turn in session {
            if turn.has_answer {
                parts.push(turn.content.clone());
            }
        }
    }
    if parts.is_empty() { None } else { Some(parts.join(" ")) }
}

/// Joins the artifact questions to the official corpus by question id,
/// carrying gold answer + optional evidence text. Pure. Questions missing
/// from the official corpus are a hard error: a silent drop would score a
/// truncated set as if it were complete. Twin of Swift
/// `PayloadLaneQuestion` + `joinPayloadLaneQuestions`.
pub struct PayloadLaneQuestion {
    pub question_id: String,
    /// The 3rd-person unscoped question text asked against the estate.
    pub question: String,
    /// Gold answer text (always present in the official corpus).
    pub gold_answer: String,
    /// Joined has_answer turn text; None when unannotated.
    pub evidence_text: Option<String>,
    /// Ground-truth session ids for the retrieval fold.
    pub answer_session_ids: Vec<String>,
}

pub fn join_payload_lane_questions(
    artifact: &[ArtifactRecallQuestion],
    official: &[LmeQuestion],
) -> Result<Vec<PayloadLaneQuestion>, MCPError> {
    let mut by_id: HashMap<&str, &LmeQuestion> = HashMap::new();
    for q in official {
        by_id.insert(q.question_id.as_str(), q);
    }
    artifact
        .iter()
        .map(|aq| {
            let oq = by_id.get(aq.sample_id.as_str()).ok_or_else(|| MCPError {
                description: format!(
                    "question '{}' is in the artifact questions but not in the official \
                     corpus — the frozen corpus and the seeding projection are out of step",
                    aq.sample_id
                ),
            })?;
            Ok(PayloadLaneQuestion {
                question_id: aq.sample_id.clone(),
                question: aq.question.clone(),
                gold_answer: oq.answer.clone(),
                evidence_text: lme_evidence_text_for_question(oq),
                answer_session_ids: aq.answer_session_ids.clone(),
            })
        })
        .collect()
}

// ─────────────────────────────────────────────────────────────────────────────
// Live runner
// ─────────────────────────────────────────────────────────────────────────────

/// Measures one payload: arm-stripped, tokenized, evidence-matched. Twin of
/// the `measure` closure inside Swift `runPayloadEconomicsLane`.
fn measure_payload(
    payload_arm: Option<PayloadArm>,
    payload_blocks: &[String],
    q: &PayloadLaneQuestion,
    hit_at_k: Option<bool>,
    reciprocal_rank: Option<f64>,
) -> PayloadArmSample {
    let blocks: Vec<String> = match payload_arm {
        Some(arm) => arm.apply_text_blocks(payload_blocks),
        None => payload_blocks.to_vec(),
    };
    let text = blocks.join("\n");
    let evidence_hit =
        q.evidence_text.as_deref().map(|evidence| lme_evidence_hit(evidence, &text));
    PayloadArmSample {
        tokens: lme_estimate_tokens(&text),
        evidence_hit,
        answer_present: lme_gold_answer_in_payload(&q.gold_answer, &text),
        hit_at_k,
        reciprocal_rank,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Arm provenance
// ─────────────────────────────────────────────────────────────────────────────

/// The arm every payload report records beside `shape_mapping`. Twin of
/// Swift `PayloadArmProvenance`; the compact form is pinned byte-for-byte in
/// both ports by conformance/payload_arm_provenance_vectors.json.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PayloadArmProvenance {
    /// SHA-256 of the artifact's estate.sqlite (the bytes cloned, or served).
    pub artifact_digest: String,
}

impl PayloadArmProvenance {
    /// The report fields, merged into the report top level. serde_json's
    /// default map is ordered by key, so the encoding is sorted-key.
    pub fn report_fields(&self) -> serde_json::Map<String, serde_json::Value> {
        use serde_json::json;
        let mut m = serde_json::Map::new();
        m.insert("artifact_digest".to_string(), json!(self.artifact_digest));
        m
    }

    /// Compact, sorted-key bytes — the cross-port byte-compare form. Only
    /// strings, a bool, null and a string array appear here, so the two
    /// ports' compact encoders agree byte for byte (their pretty printers
    /// differ in colon spacing, which is why the compare runs on this form).
    pub fn compact_json(&self) -> String {
        serde_json::Value::Object(self.report_fields()).to_string()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Arm scratch
// ─────────────────────────────────────────────────────────────────────────────


// ─────────────────────────────────────────────────────────────────────────────
// Live runner
// ─────────────────────────────────────────────────────────────────────────────

/// The four sample vectors one serve produces (synth empty unless the
/// synthesis-payload lane is on). Twin of Swift `PayloadLaneSamples`.
pub struct PayloadLaneSamples {
    pub exact: Vec<PayloadArmSample>,
    pub full_content: Vec<PayloadArmSample>,
    pub dense: Vec<PayloadArmSample>,
    pub synth: Vec<PayloadArmSample>,
}

/// Runs the payload lane over the artifact estate and writes the report.
/// Twin of Swift `runPayloadEconomicsLane(config:)`.
pub fn run_payload_economics_lane(config: &PayloadLaneConfig) -> Result<(), MCPError> {
    // Load + join question sources before any process is spawned.
    let jsonl = std::fs::read_to_string(&config.questions_path).map_err(|e| MCPError {
        description: format!(
            "could not read questions at {}: {e}",
            config.questions_path.display()
        ),
    })?;
    let artifact_qs = load_artifact_recall_questions(&jsonl, ArtifactDataset::LmeS)?;
    let total_loaded = artifact_qs.len();
    // Questions without retrieval ground truth (empty answer_session_ids)
    // cannot be run at all; they are excluded from the evaluated slice.
    // This is DISTINCT from the report's `no_evidence` (computed below over
    // the evaluated slice), which per the definition counts EVALUATED
    // questions without a has_answer-annotated evidence turn (they still
    // run; they are never an evidence miss).
    let (scored_pool, no_ground_truth) = partition_artifact_questions(artifact_qs);

    let corpus_file = match config.variant.as_str() {
        "s" => "longmemeval_s_cleaned.json",
        "m" => "longmemeval_m_cleaned.json",
        other => {
            return Err(MCPError {
                description: format!(
                    "payload lanes run over the frozen lme-s corpus; got variant '{other}'"
                ),
            });
        }
    };
    let corpus = load_corpus(&config.data_dir.join(corpus_file))
        .map_err(|e| MCPError { description: e.to_string() })?;

    let limited = apply_artifact_limit(scored_pool, config.limit);
    let joined = join_payload_lane_questions(&limited, &corpus.questions)?;
    if joined.is_empty() {
        return Err(MCPError {
            description: format!(
                "no scorable questions (loaded {total_loaded}, no ground truth {no_ground_truth})"
            ),
        });
    }
    // The definition's `no_evidence`: evaluated questions with no annotated
    // evidence turn. Counted over the evaluated slice, never converted into
    // an evidence miss (the evidence-rate denominator excludes them).
    let no_evidence = joined.iter().filter(|q| q.evidence_text.is_none()).count();

    let Some(artifact_db) = estate_database_path(&config.estate_dir) else {
        return Err(MCPError {
            description: format!(
                "no estate.sqlite in {} — the payload lanes require the selected port's ready \
                 Form-2 lme-s artifact (run book §9 preparation)",
                config.estate_dir.display()
            ),
        });
    };
    let id_map = load_artifact_id_map(&config.estate_dir)?;
    let reverse = artifact_reverse_id_map(&id_map);
    // Digest of the artifact's own database, taken before any clone: the
    // report names the exact bytes the arm was prepared from.
    let artifact_digest = file_sha256_hex(&artifact_db.to_string_lossy()).ok_or_else(|| {
        MCPError { description: format!("cannot read {} for its digest", artifact_db.display()) }
    })?;

    let lane = if config.synthesize_arm { "synthesis-payload" } else { "payload-economics" };
    eprintln!(
        "[{lane}] questions={} top-k={} payload-arm={} estate={}",
        joined.len(),
        config.top_k,
        config.payload_arm.map(|a| a.as_str()).unwrap_or("none"),
        config.estate_dir.file_name().and_then(|n| n.to_str()).unwrap_or(""),
    );

    let serve_dir: &Path = &config.estate_dir;
    let provenance = PayloadArmProvenance { artifact_digest: artifact_digest.clone() };
    let samples = (|| -> Result<PayloadLaneSamples, MCPError> {

            // READ-ONLY serve — identical posture rationale to the
            // artifact-recall lane (durable plaintext artifact read in
            // place, ephemeral identity, zero Keychain contact). The clone,
            // when used, is served with the same frozen env line.
            let command = moot_serve_command(
                &config.moot_binary, &serve_dir, false, &["MOOTX01_FROZEN=1", "MOOTX01_SUBJECT_RIDER=0"], None)
                .map_err(|e| MCPError { description: e.to_string() })?;
            // Bare search verb map: NO constant location arg — the lme-s
            // artifact is the deduplicated estate, so every question
            // searches unscoped.
            let verb_map = VerbMap::new(
                crate::aria_v2_surface::FILE_MEMORY,
                crate::aria_v2_surface::MEMORY_SEARCH,
                None,
                None,
                None,
                None,
                Some(BTreeMap::new()),
                Some(ResultFormat::MootV2),
            );
            let endpoint = EndpointConfig {
                name: "mootx01-payload-lane".to_string(),
                transport: Transport::Stdio { command },
                auth: None,
                verb_map,
                role: EndpointRole::Both,
            };
            let mut client = MCPClient::new(endpoint);
            client.connect()?;
            let outcome = measure_payload_arms(&mut client, config, &joined, &reverse);
            // The serve exits before the clone is removed: disconnect kills
            // the child and waits for it.
            client.disconnect();
            outcome
    })()?;

    let exact_cell = aggregate_payload_arm(&samples.exact);
    let full_content_cell = aggregate_payload_arm(&samples.full_content);
    let dense_cell = aggregate_payload_arm(&samples.dense);
    let synth_cell =
        if config.synthesize_arm { Some(aggregate_payload_arm(&samples.synth)) } else { None };

    let report = payload_lane_report(
        config,
        lane,
        joined.len(),
        no_evidence,
        &exact_cell,
        &full_content_cell,
        &dense_cell,
        synth_cell.as_ref(),
        &provenance,
    );
    let bytes = serde_json::to_vec_pretty(&report)
        .map_err(|e| MCPError { description: format!("report serialization failed: {e}") })?;
    std::fs::write(&config.out_path, bytes).map_err(|e| MCPError {
        description: format!("could not write report to {}: {e}", config.out_path.display()),
    })?;

    eprintln!(
        "[{lane}] exact mean_tokens={:.1} dense mean_tokens={:.1} → {}",
        exact_cell.mean_tokens,
        dense_cell.mean_tokens,
        config.out_path.display()
    );
    Ok(())
}

/// Runs every question's arms over one connected serve and returns the
/// samples. Separated from `run_payload_economics_lane` so the serve's
/// disconnect and the clone's removal are sequenced explicitly around it.
fn measure_payload_arms(
    client: &mut MCPClient,
    config: &PayloadLaneConfig,
    joined: &[PayloadLaneQuestion],
    reverse: &HashMap<String, String>,
) -> Result<PayloadLaneSamples, MCPError> {
    let mut exact_samples: Vec<PayloadArmSample> = Vec::new();
    let mut full_content_samples: Vec<PayloadArmSample> = Vec::new();
    let mut dense_samples: Vec<PayloadArmSample> = Vec::new();
    let mut synth_samples: Vec<PayloadArmSample> = Vec::new();

    for q in joined {
        // The lme-s artifact is the deduplicated estate: no instance wings,
        // every question searches unscoped (run book §1.2).
        let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
        args.insert("query".to_string(), JsonValue::String(q.question.clone()));
        args.insert("limit".to_string(), JsonValue::Number(config.top_k as f64));

        let mut exact_ids: Vec<String> = Vec::new();
        for (tool, is_exact) in [(crate::aria_v2_surface::MEMORY_SEARCH, true), (crate::aria_v2_surface::RECALL_DISTILLED, false)] {
            let result = client.call_tool(tool, args.clone(), &ResultFormat::MootV2)?;
            let ranked = artifact_map_ranked_uuids(&result.ordered_ids, &reverse);
            let (hit_at_k, reciprocal_rank) =
                score_artifact_question(&ranked, &q.answer_session_ids, config.top_k);
            let sample = measure_payload(
                config.payload_arm,
                &result.text_blocks,
                q,
                Some(hit_at_k),
                Some(reciprocal_rank),
            );
            if is_exact {
                exact_ids = result.ordered_ids.clone();
                exact_samples.push(sample)
            } else {
                dense_samples.push(sample)
            }
        }

        // Full-content shape: the complete body of each row the exact arm
        // returned, batch-hydrated from the SAME frozen retrieval (the
        // definition's "rendered from the same frozen retrieval results").
        // No retrieval figures — the ranked list is the exact arm's.
        if exact_ids.is_empty() {
            full_content_samples.push(measure_payload(config.payload_arm, &[], q, None, None));
        } else {
            let id_refs: Vec<&str> = exact_ids.iter().map(String::as_str).collect();
            let hydrate = client.call_tool(
                crate::aria_v2_surface::MEMORY_GET,
                batch_hydrate_args(&id_refs, HydrationDepth::Full, BTreeMap::new()),
                &ResultFormat::MootV2,
            )?;
            full_content_samples.push(measure_payload(
                config.payload_arm,
                &hydrate.text_blocks,
                q,
                None,
                None,
            ));
        }

        if config.synthesize_arm {
            let mut synth_args: BTreeMap<String, JsonValue> = BTreeMap::new();
            synth_args.insert("query".to_string(), JsonValue::String(q.question.clone()));
            if let Some(cap) = config.synthesize_limit {
                synth_args.insert("limit".to_string(), JsonValue::Number(cap as f64));
            }
            let result =
                client.call_tool(crate::aria_v2_surface::SYNTHESIZE, synth_args, &ResultFormat::MootV2)?;
            synth_samples.push(measure_payload(
                config.payload_arm,
                &result.text_blocks,
                q,
                None,
                None,
            ));
        }
    }
    Ok(PayloadLaneSamples {
        exact: exact_samples,
        full_content: full_content_samples,
        dense: dense_samples,
        synth: synth_samples,
    })
}

/// Builds one arm's report cell object. Absent optional figures are omitted
/// from the cell entirely (never serialized as `null`), matching the Swift
/// JSONSerialization report which only inserts non-nil values.
fn cell_json(cell: &PayloadArmCell, retrieval: bool) -> serde_json::Value {
    use serde_json::json;
    let mut m = serde_json::Map::new();
    m.insert("n".to_string(), json!(cell.n));
    m.insert("mean_tokens".to_string(), json!(cell.mean_tokens));
    m.insert("answer_presence_rate".to_string(), json!(cell.answer_presence_rate));
    if let Some(v) = cell.answer_presence_per_1k_tokens {
        m.insert("answer_presence_per_1k_tokens".to_string(), json!(v));
    }
    if let Some(v) = cell.evidence_hit_rate {
        m.insert("evidence_hit_rate".to_string(), json!(v));
    }
    if let Some(v) = cell.evidence_hits_per_1k_tokens {
        m.insert("evidence_hits_per_1k_tokens".to_string(), json!(v));
    }
    if retrieval {
        if let Some(v) = cell.hit_at_k {
            m.insert("hit_at_k".to_string(), json!(v));
        }
        if let Some(v) = cell.mrr {
            m.insert("mrr".to_string(), json!(v));
        }
    }
    serde_json::Value::Object(m)
}

/// Report JSON. Arm cells are keyed by the shape names the definitions use:
/// exact = full-content retrieval payload, dense = distilled dense-row
/// payload, synthesize = store-generated digest. The `shape_mapping` field
/// records how the definition's payload shapes map onto these arm cells:
/// preview → exact (candidate rows), full_content → full_content (batch
/// hydration of the exact arm's ids), compressed → dense (distilled),
/// synthesis → synthesize (digest). Retrieval figures appear ONLY on the
/// exact and dense cells; full_content rides the exact arm's ranked list.
/// Twin of Swift
/// `payloadLaneReport(config:lane:nQuestions:noEvidence:exact:fullContent:dense:synth:provenance:)`.
#[allow(clippy::too_many_arguments)]
pub fn payload_lane_report(
    config: &PayloadLaneConfig,
    lane: &str,
    n_questions: usize,
    no_evidence: usize,
    exact: &PayloadArmCell,
    full_content: &PayloadArmCell,
    dense: &PayloadArmCell,
    synth: Option<&PayloadArmCell>,
    provenance: &PayloadArmProvenance,
) -> serde_json::Value {
    use serde_json::json;
    let mut arms = serde_json::Map::new();
    arms.insert("exact".to_string(), cell_json(exact, true));
    arms.insert("full_content".to_string(), cell_json(full_content, false));
    arms.insert("dense".to_string(), cell_json(dense, true));
    if let Some(synth_cell) = synth {
        arms.insert("synthesize".to_string(), cell_json(synth_cell, false));
    }

    let mut shape_mapping = serde_json::Map::new();
    shape_mapping.insert("preview".to_string(), json!("exact"));
    shape_mapping.insert("full_content".to_string(), json!("full_content"));
    shape_mapping.insert("compressed".to_string(), json!("dense"));
    if synth.is_some() {
        shape_mapping.insert("synthesis".to_string(), json!("synthesize"));
    }

    let mut report = serde_json::Map::new();
    report.insert("lane".to_string(), json!(lane));
    report.insert("n_questions".to_string(), json!(n_questions));
    report.insert("shape_mapping".to_string(), serde_json::Value::Object(shape_mapping));
    report.insert(
        "config".to_string(),
        json!({
            "estate_dir": config.estate_dir.display().to_string(),
            "questions": config.questions_path.display().to_string(),
            "data_dir": config.data_dir.display().to_string(),
            "variant": config.variant,
            "limit": config.limit,
            "top_k": config.top_k,
            "payload_arm": config.payload_arm.map(|a| a.as_str().to_string()).unwrap_or_default(),
            "binary": config.moot_binary,
        }),
    );
    report.insert("estate_mode".to_string(), json!("artifact-bench-aggregate"));
    report.insert("no_evidence".to_string(), json!(no_evidence));
    report.insert("arms".to_string(), serde_json::Value::Object(arms));
    for (key, value) in provenance.report_fields() {
        report.insert(key, value);
    }
    if dense.mean_tokens > 0.0 && exact.mean_tokens > 0.0 {
        report.insert(
            "dense_exact_token_ratio".to_string(),
            json!(dense.mean_tokens / exact.mean_tokens),
        );
    }
    if config.synthesize_arm {
        if let Some(cap) = config.synthesize_limit {
            report.insert("synthesize_limit".to_string(), json!(cap));
        }
    }
    serde_json::Value::Object(report)
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// LITERAL twin of the Swift `armCellAggregation` test in
    /// PayloadEconomicsTests.swift — same samples, same expected cell
    /// figures, asserted in both ports (dual-port conformance).
    ///
    /// Four samples: tokens 100/300/200/400 (mean 250); evidence annotated
    /// on two (one hit → rate 0.5); answers present on three (rate 0.75);
    /// retrieval scored on all four (two hits → 0.5; RRs 1, 0.5, 0, 0.25 →
    /// MRR 0.4375).
    #[test]
    fn payload_arm_cell_parity() {
        let cell = aggregate_payload_arm(&[
            PayloadArmSample {
                tokens: 100,
                evidence_hit: Some(true),
                answer_present: true,
                hit_at_k: Some(true),
                reciprocal_rank: Some(1.0),
            },
            PayloadArmSample {
                tokens: 300,
                evidence_hit: Some(false),
                answer_present: true,
                hit_at_k: Some(true),
                reciprocal_rank: Some(0.5),
            },
            PayloadArmSample {
                tokens: 200,
                evidence_hit: None,
                answer_present: false,
                hit_at_k: Some(false),
                reciprocal_rank: Some(0.0),
            },
            PayloadArmSample {
                tokens: 400,
                evidence_hit: None,
                answer_present: true,
                hit_at_k: Some(false),
                reciprocal_rank: Some(0.25),
            },
        ]);
        assert_eq!(cell.n, 4);
        assert_eq!(cell.mean_tokens, 250.0);
        assert_eq!(cell.evidence_hit_rate, Some(0.5));
        // 0.5 / 250 × 1000 = 2.0 evidence hits per 1k tokens.
        assert_eq!(cell.evidence_hits_per_1k_tokens, Some(2.0));
        assert_eq!(cell.answer_presence_rate, 0.75);
        // 0.75 / 250 × 1000 = 3.0.
        assert_eq!(cell.answer_presence_per_1k_tokens, Some(3.0));
        assert_eq!(cell.hit_at_k, Some(0.5));
        assert_eq!(cell.mrr, Some(0.4375));
    }

    /// Twin of the Swift `armCellNoAnnotationsAndEmpty` test: no sample
    /// carrying an evidence annotation → None rate, None per-1k; answer
    /// figures still publish. A synth-style sample carries no retrieval
    /// figures at all. Empty slice → n=0, mean 0, per-1k None.
    #[test]
    fn arm_cell_no_annotations_and_empty() {
        let cell = aggregate_payload_arm(&[PayloadArmSample {
            tokens: 8,
            evidence_hit: None,
            answer_present: true,
            hit_at_k: None,
            reciprocal_rank: None,
        }]);
        assert_eq!(cell.evidence_hit_rate, None);
        assert_eq!(cell.evidence_hits_per_1k_tokens, None);
        assert_eq!(cell.answer_presence_rate, 1.0);
        assert_eq!(cell.hit_at_k, None);
        assert_eq!(cell.mrr, None);

        let empty = aggregate_payload_arm(&[]);
        assert_eq!(empty.n, 0);
        assert_eq!(empty.mean_tokens, 0.0);
        assert_eq!(empty.answer_presence_per_1k_tokens, None);
    }

    /// Twin of the Swift `joinCarriesGoldAnswerAndFailsLoudOnMissing` test:
    /// the 3rd-person seeding question is what gets asked, the has_answer
    /// turn text flows through for the evidence figure, and a question
    /// absent from the official corpus is a hard error (never a silent
    /// drop — a truncated set must not score as complete).
    #[test]
    fn join_carries_gold_answer_and_fails_loud_on_missing() {
        let artifact_jsonl = r#"{"question_id": "q-1", "question_type": "multi-session", "persona": "Priya Calder", "question": "Where did I go?", "question_3p": "Where did Priya go?", "question_date": "2023-05-30", "answer": "Paris", "answer_session_ids": ["s-9"]}"#;
        let artifact =
            load_artifact_recall_questions(artifact_jsonl, ArtifactDataset::LmeS).expect("load");

        let corpus_json = r#"[{"question_id": "q-1", "question_type": "multi-session",
          "question": "Where did I go?", "answer": "Paris",
          "question_date": "2023/05/30 (Tue) 10:00",
          "haystack_dates": ["2023/05/29 (Mon) 09:00"],
          "haystack_session_ids": ["s-9"],
          "haystack_sessions": [[{"role": "user",
                                  "content": "I flew to Paris yesterday.",
                                  "has_answer": true}]],
          "answer_session_ids": ["s-9"]}]"#;
        let tmp = std::env::temp_dir()
            .join(format!("payload-lane-test-{}.json", std::process::id()));
        std::fs::write(&tmp, corpus_json).unwrap();
        let official = load_corpus(&tmp).expect("corpus load").questions;
        std::fs::remove_file(&tmp).ok();

        let joined = join_payload_lane_questions(&artifact, &official).expect("join");
        assert_eq!(joined.len(), 1);
        // The 3rd-person seeding question is what gets asked.
        assert_eq!(joined[0].question, "Where did Priya go?");
        assert_eq!(joined[0].gold_answer, "Paris");
        // has_answer turn text flows through for the evidence figure.
        assert_eq!(joined[0].evidence_text.as_deref(), Some("I flew to Paris yesterday."));
        assert_eq!(joined[0].answer_session_ids, vec!["s-9".to_string()]);

        // A question absent from the official corpus is a hard error, never
        // a silent drop (a truncated set must not score as complete).
        assert!(join_payload_lane_questions(&artifact, &[]).is_err());
    }
}

/// Arm scratch, provenance, report parity — twins of the Swift
/// `PayloadArmTests` suite (PayloadEconomicsTests.swift). The provenance
/// fixture is shared: conformance/payload_arm_provenance_vectors.json.
#[cfg(test)]
mod arm_tests {
    use super::*;

    static SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

    fn unique_dir(prefix: &str) -> PathBuf {
        let sequence = SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!("{prefix}-{}-{nanos}-{sequence}", std::process::id()))
    }

    /// A fixture artifact: an estate dir holding estate.sqlite with two
    /// registered minters, both active (the worst-case pre-state), plus a
    /// flat id-map.json so the lane's fail-fast checks pass.
    fn make_artifact(minted: bool) -> PathBuf {
        let dir = unique_dir("payload-arm-artifact");
        std::fs::create_dir_all(&dir).unwrap();
        let conn = estate_encryption::open_raw(&dir.join("estate.sqlite"), None).unwrap();
        let mut sql = String::from("CREATE TABLE anchor (x INTEGER);");
        if minted {
            sql.push_str(
                "CREATE TABLE adornment_minters (
                   id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '',
                   family TEXT NOT NULL DEFAULT '', model_id TEXT NOT NULL DEFAULT '',
                   model_version TEXT NOT NULL DEFAULT '', prompt_digest TEXT NOT NULL DEFAULT '',
                   parameters TEXT NOT NULL DEFAULT '', is_active INTEGER NOT NULL DEFAULT 0);
                 INSERT INTO adornment_minters(id, is_active) VALUES('apple-mint', 1);
                 INSERT INTO adornment_minters(id, is_active) VALUES('candle-mint', 1);",
            );
        }
        conn.execute_batch(&sql).unwrap();
        std::fs::write(
            dir.join("id-map.json"),
            r#"{"s-9": "00000000-0000-0000-0000-000000000009"}"#,
        )
        .unwrap();
        dir
    }

    fn make_root() -> PathBuf {
        let root = unique_dir("payload-arm-root");
        std::fs::create_dir_all(&root).unwrap();
        root
    }

    fn digest(path: &Path) -> String {
        file_sha256_hex(&path.to_string_lossy()).expect("digest")
    }

    fn dir_entries(root: &Path) -> Vec<String> {
        std::fs::read_dir(root)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().to_string())
            .collect()
    }

}
