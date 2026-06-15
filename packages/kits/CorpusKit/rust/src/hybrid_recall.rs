//! Hybrid retrieval: vector kNN + BM25 keyword scoring fused via
//! Reciprocal Rank Fusion (RRF). Mirror of Swift's `HybridRecall`.
//!
//! LANE-E2: the two-lane RRF logic is now delegated to
//! `engine::fusion::fuse` instead of being reimplemented inline.
//! `recall` builds per-lane ranked lists and raw-score maps, then
//! calls `fuse`. The ranking output is bit-identical to the previous
//! implementation for the same inputs (verified by hybrid_recall_tests).
//!
//! CORPUSKIT_REPORT_001 (cp-corpuskit-report): added IntellectusLib
//! self-report telemetry to `recall`. The `report!` macro calls are
//! placed at the operation boundary, after the result is assembled,
//! so mathematical behaviour is unchanged. When monitoring is
//! disabled (the default), the macro expands to a single
//! `AtomicBool::load + branch` — zero allocation, no clock.

use crate::bm25_index::BM25Index;
use crate::bundle_store::BundleStore;
use crate::chunk::ScoredChunk;
use crate::engine::fusion::fuse;
use crate::engine::sparse_types::LaneTag;
use crate::error::{CorpusKitError, CorpusKitResult};
use engram_lib::Engram;
use intellectus_lib::{report, StatSample};
use std::collections::HashMap;
use std::time::{SystemTime, UNIX_EPOCH};
use uuid::Uuid;
use vectorkit::VectorStore;

#[derive(Debug, Clone, Copy)]
pub struct HybridRecallConfiguration {
    pub vector_weight: f64,
    pub keyword_weight: f64,
    /// RRF constant (Cormack et al. recommend 60).
    pub rrf_k: f64,
    /// Optional MMR diversification lambda. `None` disables MMR.
    pub mmr_lambda: Option<f64>,
}

impl Default for HybridRecallConfiguration {
    fn default() -> Self {
        HybridRecallConfiguration {
            vector_weight: 0.6,
            keyword_weight: 0.4,
            rrf_k: 60.0,
            mmr_lambda: None,
        }
    }
}

/// Retrieve top-k chunks by hybrid (vector + keyword) scoring.
///
/// Both the vector pass (Hamming kNN) and keyword pass (BM25) produce
/// ranked candidate lists. These are fused using generalized RRF via
/// `engine::fusion::fuse` — the `LaneTag::BinaryDense` lane carries
/// vector hits and `LaneTag::Sparse` carries BM25 hits. The ranking
/// behaviour is identical to the previous inline implementation.
///
/// Telemetry: emits `corpuskit.recall.latency_ms`,
/// `corpuskit.recall.vector_result_count`,
/// `corpuskit.recall.keyword_result_count`, and
/// `corpuskit.recall.result_count` when monitoring is enabled
/// (off by default). All four are emitted at the operation
/// boundary after the result is assembled — they cannot affect
/// the return value. Off-path: single `AtomicBool::load + branch`
/// per call via the `report!` macro.
///
/// Mirrors Swift's `HybridRecall.recall` telemetry exactly.
// Eight parameters: probe/query/model_id/limit/config plus the three
// substrate handles (vector_store, bm25, bundle_store) are each a
// distinct input recall needs; bundling them into a struct would
// obscure the call site and diverge the signature from the Swift
// CorpusKit `recall`. Parity over the lint.
#[allow(clippy::too_many_arguments)]
pub fn recall(
    probe: &Engram,
    query: &str,
    model_id: &str,
    limit: usize,
    vector_store: &VectorStore,
    bm25: &BM25Index,
    bundle_store: &BundleStore,
    config: HybridRecallConfiguration,
) -> CorpusKitResult<Vec<ScoredChunk>> {
    if limit == 0 {
        return Ok(Vec::new());
    }
    // Capture start time before the retrieval work. The computed latency
    // is forwarded to the sink only when monitoring is enabled (inside
    // the report! macro's if-enabled guard).
    let start_ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);

    let candidate_k = (limit * 4).max(32);

    let vector_results = vector_store
        .find_nearest(probe, model_id, candidate_k)
        .map_err(|e| CorpusKitError::StoreUnavailable(format!("{:?}", e)))?;
    // Pre-tokenise using the index's own tokenizer vocabulary so top_k receives
    // compatible tokens. Mirrors Swift HybridRecall using CorpusDefaultTokenizer.
    let query_tokens = bm25.tokenize_query(query);
    let keyword_results = bm25.top_k(candidate_k, &query_tokens);

    // Capture raw counts before the vecs are consumed by the fusion loop.
    // These are emitted as telemetry metrics at the operation boundary below.
    let vector_result_count = vector_results.len();
    let keyword_result_count = keyword_results.len();

    // Build per-lane ranked inputs for the generalized Fusion engine.
    //
    // Vector lane (BinaryDense): find_nearest returns hits sorted by
    // Hamming distance ascending — index 0 = rank 1.
    // Raw score = Hamming distance (u32 cast to f32); lower = closer.
    //
    // Keyword lane (Sparse): top_k returns (id: Uuid, score: f32)
    // sorted by BM25 score descending — index 0 = rank 1.
    // Raw score = BM25 score f32.
    //
    // Both ranked lists are built as Vec<(String, usize)> using the
    // chunk UUID string as item_id — the same join key used by
    // bundle_store.get_many.

    let mut vector_ranked: Vec<(String, usize)> = Vec::new();
    let mut vector_score_map: HashMap<String, f32> = HashMap::new();
    for (idx, hit) in vector_results.iter().enumerate() {
        // Skip items whose item_id is not a valid UUID — they cannot be
        // hydrated by bundle_store and are not in the corpus.
        if Uuid::parse_str(&hit.item_id).is_err() {
            continue;
        }
        vector_ranked.push((hit.item_id.clone(), idx + 1));
        // Hamming distance as f32; lower = closer to probe.
        vector_score_map.insert(hit.item_id.clone(), hit.distance as f32);
    }

    let mut keyword_ranked: Vec<(String, usize)> = Vec::new();
    let mut keyword_score_map: HashMap<String, f32> = HashMap::new();
    for (idx, (id, score)) in keyword_results.iter().enumerate() {
        let item_id = id.to_string();
        keyword_ranked.push((item_id.clone(), idx + 1));
        keyword_score_map.insert(item_id, *score);
    }

    // Delegate fusion to engine::fusion::fuse. BinaryDense and Sparse
    // are the canonical lane names for these two retrieval paths
    // (arch spec §2.4, LaneTag definition).
    let mut ranked_lists: HashMap<LaneTag, Vec<(String, usize)>> = HashMap::new();
    ranked_lists.insert(LaneTag::BinaryDense, vector_ranked);
    ranked_lists.insert(LaneTag::Sparse, keyword_ranked);

    let mut lane_scores_map: HashMap<LaneTag, HashMap<String, f32>> = HashMap::new();
    lane_scores_map.insert(LaneTag::BinaryDense, vector_score_map);
    lane_scores_map.insert(LaneTag::Sparse, keyword_score_map);

    let mut weights: HashMap<LaneTag, f32> = HashMap::new();
    weights.insert(LaneTag::BinaryDense, config.vector_weight as f32);
    weights.insert(LaneTag::Sparse, config.keyword_weight as f32);

    let mut fused_hits = fuse(
        &ranked_lists,
        Some(&lane_scores_map),
        &weights,
        config.rrf_k as f32,
    );

    // Apply the limit. fuse returns a fully sorted list; truncate to top-k.
    fused_hits.truncate(limit);

    // Hydrate chunks from bundle_store using UUID primary keys.
    // Items whose item_id is not a valid UUID are dropped here (they
    // were included in fusion but cannot be hydrated).
    let uuids: Vec<Uuid> = fused_hits
        .iter()
        .filter_map(|h| Uuid::parse_str(&h.item_id).ok())
        .collect();
    let chunks = bundle_store.get_many(&uuids)?;
    let by_id: HashMap<Uuid, _> = chunks.into_iter().map(|c| (c.id, c)).collect();

    // Build the output list in fused-score order.
    // Per-lane raw scores from FusedHit.per_lane feed ScoredChunk
    // subscores: BinaryDense → vector_score, Sparse → keyword_score.
    let mut out = Vec::with_capacity(fused_hits.len());
    for hit in &fused_hits {
        let Ok(uuid) = Uuid::parse_str(&hit.item_id) else {
            continue;
        };
        let Some(chunk) = by_id.get(&uuid) else {
            continue;
        };
        let vector_score = hit.per_lane.get(&LaneTag::BinaryDense).copied();
        let keyword_score = hit.per_lane.get(&LaneTag::Sparse).copied();
        // vector_score: presence in per_lane[BinaryDense] determines Some/None.
        // A raw value of 0.0 (Hamming distance 0) is the BEST possible match —
        // the probe is identical to the stored engram. Mapping distance 0 to
        // None would silently discard the highest-quality vector hit, misleading
        // None-checking callers. Pass vector_score through unchanged.
        //
        // keyword_score: BM25 scores are strictly positive for any match, so
        // a zero value reliably indicates the keyword lane did not contribute.
        out.push(
            ScoredChunk::new(chunk.clone(), hit.fused_score).with_subscores(
                vector_score,
                match keyword_score {
                    Some(k) if k != 0.0 => Some(k),
                    _ => None,
                },
            ),
        );
    }

    // Emit recall telemetry at the operation boundary, after the result
    // is assembled. The report! macro evaluates the argument only when
    // monitoring is enabled; when disabled it is a single AtomicBool
    // load + branch with no allocation.
    //
    // corpuskit.recall.latency_ms: wall time for the full pipeline.
    // corpuskit.recall.vector_result_count: raw vector hits before RRF.
    // corpuskit.recall.keyword_result_count: raw keyword hits before RRF.
    // corpuskit.recall.result_count: final output count after hydration.
    // Mirrors the four Swift emit sites in HybridRecall.recall.
    let end_ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);
    let result_count = out.len();
    let vector_count = vector_result_count;
    let keyword_count = keyword_result_count;
    let model_tag = model_id.to_string();
    report!(StatSample::metric(
        "corpuskit.recall.latency_ms".to_string(),
        (end_ts - start_ts) * 1000.0,
        [("kit".to_string(), "CorpusKit".to_string()),
         ("model_id".to_string(), model_tag.clone())]
            .into_iter().collect(),
        end_ts,
    ));
    report!(StatSample::metric(
        "corpuskit.recall.vector_result_count".to_string(),
        vector_count as f64,
        [("kit".to_string(), "CorpusKit".to_string()),
         ("model_id".to_string(), model_tag.clone())]
            .into_iter().collect(),
        end_ts,
    ));
    report!(StatSample::metric(
        "corpuskit.recall.keyword_result_count".to_string(),
        keyword_count as f64,
        [("kit".to_string(), "CorpusKit".to_string()),
         ("model_id".to_string(), model_tag.clone())]
            .into_iter().collect(),
        end_ts,
    ));
    report!(StatSample::metric(
        "corpuskit.recall.result_count".to_string(),
        result_count as f64,
        [("kit".to_string(), "CorpusKit".to_string()),
         ("model_id".to_string(), model_tag)]
            .into_iter().collect(),
        end_ts,
    ));

    Ok(out)
}
