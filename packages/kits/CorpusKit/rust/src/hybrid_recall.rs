//! Hybrid retrieval: vector kNN + BM25 keyword scoring fused via
//! Reciprocal Rank Fusion (RRF). Mirror of Swift's `HybridRecall`.

use crate::bm25_index::BM25Index;
use crate::bundle_store::BundleStore;
use crate::chunk::ScoredChunk;
use crate::error::{CorpusKitError, CorpusKitResult};
use engram_lib::Engram;
use std::collections::HashMap;
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
/// The vector pass filters to `model_id` so cross-model
/// comparisons cannot occur. The keyword pass uses the
/// pre-indexed `BM25Index`. Both candidate sets are fused via
/// RRF; the resulting top-`limit` ids are hydrated through the
/// `bundle_store`.
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
    let candidate_k = (limit * 4).max(32);

    let vector_results = vector_store
        .find_nearest(probe, model_id, candidate_k)
        .map_err(|e| CorpusKitError::StoreUnavailable(format!("{:?}", e)))?;
    let keyword_results = bm25.search(query, candidate_k);

    // (vectorScore, keywordScore, fusedScore) per uuid
    let mut fused: HashMap<Uuid, (f64, f64, f64)> = HashMap::new();

    for (rank, hit) in vector_results.iter().enumerate() {
        let Ok(uuid) = Uuid::parse_str(&hit.drawer_id) else {
            continue;
        };
        let rrf = 1.0 / (config.rrf_k + (rank as f64 + 1.0));
        let contribution = rrf * config.vector_weight;
        let entry = fused.entry(uuid).or_insert((0.0, 0.0, 0.0));
        entry.0 = hit.distance as f64;
        entry.2 += contribution;
    }
    for (rank, (id, score)) in keyword_results.iter().enumerate() {
        let rrf = 1.0 / (config.rrf_k + (rank as f64 + 1.0));
        let contribution = rrf * config.keyword_weight;
        let entry = fused.entry(*id).or_insert((0.0, 0.0, 0.0));
        entry.1 = *score;
        entry.2 += contribution;
    }

    let mut ranked: Vec<(Uuid, f64, f64, f64)> = fused
        .into_iter()
        .map(|(id, (v, k, f))| (id, v, k, f))
        .collect();
    ranked.sort_by(|a, b| {
        b.3.partial_cmp(&a.3)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.0.to_string().cmp(&b.0.to_string()))
    });
    ranked.truncate(limit);

    let ids: Vec<Uuid> = ranked.iter().map(|e| e.0).collect();
    let chunks = bundle_store.get_many(&ids)?;
    let by_id: HashMap<Uuid, _> = chunks.into_iter().map(|c| (c.id, c)).collect();

    let mut out = Vec::with_capacity(ranked.len());
    for (id, vector_score, keyword_score, fused_score) in ranked {
        let Some(chunk) = by_id.get(&id) else {
            continue;
        };
        out.push(
            ScoredChunk::new(chunk.clone(), fused_score as f32).with_subscores(
                if vector_score == 0.0 {
                    None
                } else {
                    Some(vector_score as f32)
                },
                if keyword_score == 0.0 {
                    None
                } else {
                    Some(keyword_score as f32)
                },
            ),
        );
    }
    Ok(out)
}
