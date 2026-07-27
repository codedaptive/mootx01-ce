//! locomo_runner.rs — live harness driving mootx01 for LoCoMo benchmarking.
//!
//! Rust twin of `LoCoMoRunner.swift`. Implements the per-CONVERSATION estate
//! strategy that differs from the per-question LME approach:
//!
//! - LME model:    1 question  → 1 scratch estate → ingest haystack → 1 query
//! - LoCoMo model: 1 conversation → 1 scratch estate → ingest all turns → N queries
//!
//! Re-ingesting 700+ turns per question (×1,542 = ~1M writes) is impractical.
//! Per-conversation estates pay O(10) estate provisions instead of O(1,542),
//! with full turn isolation between conversations.
//!
//! # Estate lifecycle per conversation
//!
//! 1. Create scratch dir under `/tmp/locomo-bench-<seed>-<conv_index>`.
//! 2. Launch mootx01 via `MCPClient` pointing at that dir.
//! 3. Ingest all turns (n=true for inline encoding barrier).
//! 4. Run DegeneracyGuard probe once per estate.
//! 5. Issue one query per selected question in this conversation.
//! 6. Disconnect client, tear down scratch dir.
//!
//! # Encode barrier
//!
//! The `encode_barrier` field in `LoCoMoRunConfig` controls how the harness
//! synchronizes with the background encoding queue:
//!   - `Drain` (default): write without inline encoding, then poll
//!     `moot_drain_status` after all ingest completes.
//!   - `Impatient`: write with `impatient: true` — inline encoding per write.
//!     Correct key (the old key "n" was silently ignored).
//!   - `None`: no barrier; documents the background-encoding race.
//! Origin: LME-01 finding (COMPLETION_LME-01.md).

use crate::config::{EndpointConfig, EndpointRole, ResultFormat, Transport, VerbMap};
use crate::degeneracy_guard::DegeneracyGuard;
use crate::encode_barrier::{EncodeBarrier, wait_for_encode_drain};
use crate::json_value::JsonValue;
use crate::locomo_corpus::{LoCoMoCorpus, LoCoMoQuestion};
use crate::locomo_scorer::{LoCoMoManifestEntry, LoCoMoQuestionResult};
use crate::longmemeval_runner::{probe_mcp_client, SplitMix64};
use crate::mcp_client::{MCPClient, MCPError, ToolCaller};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Instant;

// ─────────────────────────────────────────────────────────────────────────────
// Run configuration
// ─────────────────────────────────────────────────────────────────────────────

/// Configuration for one LoCoMo run. Constructed by main.rs from CLI flags.
pub struct LoCoMoRunConfig {
    pub moot_binary: String,
    pub seed: u64,
    pub limit: Option<usize>,
    /// Skip this many questions from the seeded-shuffled list (for batched runs).
    pub offset: usize,
    pub label: Option<String>,
    pub out_dir: Option<PathBuf>,
    /// Encode-queue synchronization strategy. Default EncodeBarrier::Drain.
    pub encode_barrier: EncodeBarrier,
}

// ─────────────────────────────────────────────────────────────────────────────
// Verb map for LoCoMo
// ─────────────────────────────────────────────────────────────────────────────

/// Returns the VerbMap for the LoCoMo harness.
///
/// `location: "benchmark/locomo"` is the write constant — all conversation
/// memories are filed in the locomo wing, isolated from the operator's real
/// memories and from other benchmark runs.
///
/// Twin of Swift `loCoMoMootVerbMap`.
pub fn locomo_verb_map() -> VerbMap {
    let mut constant_args = BTreeMap::new();
    constant_args.insert("location".to_string(), "benchmark/locomo".to_string());
    VerbMap::new(
        "moot_file_memory",
        "moot_memory_search",
        None, // list: not used in LoCoMo
        None, // fetch: not used in LoCoMo
        None, // content_arg: defaults to "content"
        None, // query_arg: defaults to "query"
        Some(constant_args),
        Some(ResultFormat::MootText),
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// Scratch dir management
// ─────────────────────────────────────────────────────────────────────────────

/// Creates a fresh scratch directory for one conversation's mootx01 instance.
/// Path: `/tmp/locomo-bench-<seed_hex>-<conv_index_hex>`.
///
/// The deterministic naming ensures each conversation has a unique path
/// even across retries, and the fixed prefix enables guarded teardown.
///
/// Twin of Swift `loCoMoScratchDir()`.
pub fn locomo_scratch_dir(seed: u64, conv_index: usize) -> Result<PathBuf, MCPError> {
    let name = format!("locomo-bench-{seed:016x}-{conv_index:08x}");
    let path = PathBuf::from("/tmp").join(&name);
    std::fs::create_dir_all(&path).map_err(|e| MCPError {
        description: format!("failed to create scratch dir {}: {e}", path.display()),
    })?;
    Ok(path)
}

/// Removes a scratch directory created by `locomo_scratch_dir`.
///
/// Guard: path must begin with `/tmp/locomo-bench-` (the prefix assigned in
/// `locomo_scratch_dir`). Any other prefix is refused — this prevents a
/// misconfigured path from deleting real data.
///
/// Twin of Swift `loCoMoGuardedTeardown(_:)`.
pub fn locomo_guarded_teardown(path: &Path) -> Result<(), MCPError> {
    let path_str = path.to_string_lossy();
    if !path_str.starts_with("/tmp/locomo-bench-") {
        return Err(MCPError {
            description: format!(
                "SAFETY: locomo_guarded_teardown refused to delete '{}' — \
                 path must have the /tmp/locomo-bench- prefix. \
                 Only directories created by locomo_scratch_dir() may be torn down.",
                path.display()
            ),
        });
    }
    if path.exists() {
        std::fs::remove_dir_all(path).map_err(|e| MCPError {
            description: format!("teardown failed for {}: {e}", path.display()),
        })?;
    }
    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────
// Endpoint config construction
// ─────────────────────────────────────────────────────────────────────────────

/// Builds an `EndpointConfig` for the LoCoMo harness pointing at `scratch_dir`.
///
/// Command form: `MOOTX01_DATA_DIR=<scratch> <binary> serve`.
///
/// Twin of Swift `loCoMoEndpointConfig(scratchDir:mootBinaryPath:)`.
pub fn locomo_endpoint_config(scratch_dir: &Path, moot_binary: &str) -> EndpointConfig {
    let data_dir = scratch_dir.to_string_lossy();
    let command = format!("MOOTX01_DATA_DIR={data_dir} {moot_binary} serve");
    EndpointConfig {
        name: "mootx01-locomo".to_string(),
        transport: Transport::Stdio { command },
        auth: None,
        verb_map: locomo_verb_map(),
        role: EndpointRole::Both,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-turn ingest helper
// ─────────────────────────────────────────────────────────────────────────────

/// Ingest one conversation turn via `moot_file_memory`, returning (uuid, latency_s).
/// Content format: `"speaker: text"` (matches LoCoMo transcript convention).
///
/// The `encode_barrier` parameter controls inline encoding per the EncodeBarrier mode.
/// Impatient mode adds `impatient: true` (correct key — the old key "n" was silently
/// ignored by mootx01's `moot_file_memory` handler).
fn ingest_turn(
    client: &mut MCPClient,
    verb_map: &VerbMap,
    content: &str,
    encode_barrier: EncodeBarrier,
) -> Result<(String, f64), MCPError> {
    let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
    args.insert(
        verb_map.content_arg.clone(),
        JsonValue::String(content.to_string()),
    );
    // Constant args (location header).
    for (k, v) in &verb_map.constant_args {
        args.insert(k.clone(), JsonValue::String(v.clone()));
    }
    // Impatient mode: inline encoding per write. Correct key is "impatient" —
    // the old key "n" was silently ignored. Origin: LME-01 correctness finding.
    if encode_barrier == EncodeBarrier::Impatient {
        args.insert("impatient".to_string(), JsonValue::Bool(true));
    }
    let start = Instant::now();
    let result = client.call_tool(&verb_map.write, args, &verb_map.result_format)?;
    let elapsed = start.elapsed().as_secs_f64();
    let uuid = result
        .write_assigned_id
        .ok_or_else(|| MCPError {
            description: "moot_file_memory returned no UUID".to_string(),
        })?;
    Ok((uuid, elapsed))
}

// ─────────────────────────────────────────────────────────────────────────────
// Top-level conversation runner
// ─────────────────────────────────────────────────────────────────────────────

/// Runs the LoCoMo harness over a slice of questions.
///
/// Per-conversation estate strategy:
///   1. Shuffle the question list with `SplitMix64(seed)`.
///   2. Apply offset and limit.
///   3. Group selected questions by `conversation_index`.
///   4. For each conversation (ascending index order):
///      a. Provision a fresh scratch estate.
///      b. Ingest all turns from that conversation (n=true).
///      c. Run DegeneracyGuard probe (once per estate).
///      d. Issue one query per selected question.
///      e. Teardown.
///   5. Return results in conversation-group order (deterministic with seed).
///
/// Twin of Swift `runLoCoMoQuestions(questions:conversations:config:)`.
pub fn run_locomo_questions(corpus: &LoCoMoCorpus, config: &LoCoMoRunConfig) -> Vec<LoCoMoQuestionResult> {
    // ── Shuffle and slice ─────────────────────────────────────────────────────
    let mut indices: Vec<usize> = (0..corpus.questions.len()).collect();
    let mut rng = SplitMix64::new(config.seed);
    rng.shuffle(&mut indices);

    // Apply offset.
    if config.offset > 0 {
        indices = indices.into_iter().skip(config.offset).collect();
    }
    // Apply limit.
    if let Some(limit) = config.limit {
        indices.truncate(limit);
    }

    // ── Group by conversation index ───────────────────────────────────────────
    let mut by_conv: BTreeMap<usize, Vec<&LoCoMoQuestion>> = BTreeMap::new();
    for &qi in &indices {
        let q = &corpus.questions[qi];
        by_conv.entry(q.conversation_index).or_default().push(q);
    }

    let total = indices.len();
    let mut all_results: Vec<LoCoMoQuestionResult> = Vec::with_capacity(total);

    // ── Process conversations in ascending index order ────────────────────────
    for (&conv_index, conv_questions) in &by_conv {
        let conversation = &corpus.conversations[conv_index];
        let all_turns = conversation.all_turns();

        eprintln!(
            "[locomo] conv={} ({} questions, {} turns)",
            conversation.sample_id,
            conv_questions.len(),
            all_turns.len()
        );

        // ── Provision scratch estate ──────────────────────────────────────────
        let scratch = match locomo_scratch_dir(config.seed, conv_index) {
            Ok(p) => p,
            Err(e) => {
                eprintln!("  [locomo] scratch dir error for conv {conv_index}: {}", e.description);
                // Emit guard-excluded results for all questions in this conversation.
                for q in conv_questions {
                    all_results.push(LoCoMoQuestionResult {
                        question_id: q.question_id.clone(),
                        category_label: q.category_label().to_string(),
                        category: q.category,
                        query_latency_seconds: 0.0,
                        retrieved_uuids: vec![],
                        manifest: vec![],
                        evidence_dia_ids: q.evidence.clone(),
                        guard_healthy: false,
                        guard_diagnostic: Some(e.description.clone()),
                        turns_ingested: 0,
                        write_mean_latency_seconds: 0.0,
                        payload_text: None,
                    });
                }
                continue;
            }
        };

        let verb_map = locomo_verb_map();
        let endpoint = locomo_endpoint_config(&scratch, &config.moot_binary);
        let mut client = MCPClient::new(endpoint);
        if let Err(e) = client.connect() {
            eprintln!("  [locomo] connect error for conv {conv_index}: {}", e.description);
            let _ = locomo_guarded_teardown(&scratch);
            for q in conv_questions {
                all_results.push(LoCoMoQuestionResult {
                    question_id: q.question_id.clone(),
                    category_label: q.category_label().to_string(),
                    category: q.category,
                    query_latency_seconds: 0.0,
                    retrieved_uuids: vec![],
                    manifest: vec![],
                    evidence_dia_ids: q.evidence.clone(),
                    guard_healthy: false,
                    guard_diagnostic: Some(e.description.clone()),
                    turns_ingested: 0,
                    write_mean_latency_seconds: 0.0,
                    payload_text: None,
                });
            }
            continue;
        }

        // ── Ingest all turns ──────────────────────────────────────────────────
        let mut manifest: Vec<LoCoMoManifestEntry> = Vec::with_capacity(all_turns.len());
        let mut write_latencies: Vec<f64> = Vec::with_capacity(all_turns.len());
        let mut ingest_error: Option<String> = None;

        'ingest: for (session_number, turn) in &all_turns {
            // Content format: "speaker: text" — matches LoCoMo transcript convention.
            let content = format!("{}: {}", turn.speaker, turn.text);
            match ingest_turn(&mut client, &verb_map, &content, config.encode_barrier) {
                Ok((uuid, latency)) => {
                    // Derive 0-based turn index within the session.
                    let turn_index = manifest
                        .iter()
                        .filter(|e| e.session_number == *session_number)
                        .count();
                    manifest.push(LoCoMoManifestEntry {
                        uuid,
                        dia_id: turn.dia_id.clone(),
                        session_number: *session_number,
                        turn_index,
                        speaker: turn.speaker.clone(),
                    });
                    write_latencies.push(latency);
                }
                Err(e) => {
                    eprintln!(
                        "  [locomo] ingest error for conv {} turn {}: {}",
                        conversation.sample_id, turn.dia_id, e.description
                    );
                    ingest_error = Some(e.description);
                    break 'ingest;
                }
            }
        }

        let write_mean = if write_latencies.is_empty() {
            0.0
        } else {
            write_latencies.iter().sum::<f64>() / write_latencies.len() as f64
        };

        // ── Drain barrier (EncodeBarrier::Drain mode) ─────────────────────────
        // Wait for background encoding to drain before issuing any recall query.
        if config.encode_barrier == EncodeBarrier::Drain {
            wait_for_encode_drain(
                &mut client,
                &format!("locomo conv-{}", conv_index),
                300.0,
            );
        }

        // ── DegeneracyGuard probe (once per estate) ───────────────────────────
        let guard = DegeneracyGuard::new();
        let probe_rankings = probe_mcp_client(&mut client, &verb_map);
        let guard_verdict = guard.classify(&probe_rankings);
        let guard_healthy = guard_verdict.discriminant() == "healthy";
        let guard_diagnostic = if let Some(err) = &ingest_error {
            // Ingest failure supersedes guard verdict.
            Some(format!("ingest_error: {err}"))
        } else if guard_healthy {
            None
        } else {
            Some(guard_verdict.diagnostic().to_string())
        };
        let effective_guard_healthy = ingest_error.is_none() && guard_healthy;

        eprintln!(
            "  guard={} turns={} write_mean_ms={:.0}",
            if effective_guard_healthy { "healthy" } else { "GUARD_FAIL" },
            manifest.len(),
            write_mean * 1000.0
        );

        // ── Query each selected question ──────────────────────────────────────
        for q in conv_questions {
            let (retrieved_uuids, query_latency, payload_text) = if effective_guard_healthy {
                let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
                args.insert(
                    verb_map.query_arg.clone(),
                    JsonValue::String(q.question.clone()),
                );
                // Include constant args (location filter).
                for (k, v) in &verb_map.constant_args {
                    args.insert(k.clone(), JsonValue::String(v.clone()));
                }
                let start = Instant::now();
                let (uuids, raw_payload) = match client.call_tool(&verb_map.query, args, &verb_map.result_format) {
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
                            "  [locomo] query error for {}: {}",
                            q.question_id, e.description
                        );
                        (vec![], None)
                    }
                };
                let latency = start.elapsed().as_secs_f64();
                eprintln!(
                    "  q={} cat={} query_ms={:.0}",
                    q.question_id, q.category_label(), latency * 1000.0
                );
                (uuids, latency, raw_payload)
            } else {
                (vec![], 0.0, None)
            };

            all_results.push(LoCoMoQuestionResult {
                question_id: q.question_id.clone(),
                category_label: q.category_label().to_string(),
                category: q.category,
                query_latency_seconds: query_latency,
                retrieved_uuids,
                manifest: manifest.clone(),
                evidence_dia_ids: q.evidence.clone(),
                guard_healthy: effective_guard_healthy,
                guard_diagnostic: guard_diagnostic.clone(),
                turns_ingested: manifest.len(),
                write_mean_latency_seconds: write_mean,
                payload_text,
            });
        }

        // ── Teardown ──────────────────────────────────────────────────────────
        client.disconnect();
        if let Err(e) = locomo_guarded_teardown(&scratch) {
            eprintln!(
                "  [locomo] teardown warning for conv {}: {}",
                conversation.sample_id, e.description
            );
        }
    }

    all_results
}
