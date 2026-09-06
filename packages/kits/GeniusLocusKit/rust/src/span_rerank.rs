//! The span rerank stage of the UnionBest recall path (Encoder Rerank Program,
//! contract sheet §8). Twin of Swift `SpanRerank.swift`.
//!
//! A retrieval-trained sentence encoder reranks the HEAD of the lexical (BM25)
//! candidate list by the best cosine between the query vector and the item's
//! stored int8 span vectors; the reranked head is fused back into the lexical
//! order with reciprocal-rank fusion. The stage reads two seams the estate
//! lifecycle registers per estate (`EstateCoordinator::register_span_rerank`):
//! the query-side encoder and the span-vector rows. Neither is owned here —
//! the encoder is CorpusKit's `SpanEncoder` (sheet §7), the rows are
//! SynapseKit's `vectors_v6` span rows (sheet §3) — so the coordinator types
//! them as traits and the lifecycle supplies the implementations.

use std::collections::HashMap;
use std::sync::Arc;

/// Depth of the internal lexical call (sheet §8): the BM25 list the head is cut
/// from and the fusion reorders. Fixed, and deliberately NOT the request's
/// `frontier_k` (clamped to [64, 256]): the clamp bounds the pool that enters
/// the weighted score, not the lexical order the rerank reads.
pub const LEXICAL_DEPTH: usize = 1000;

/// Head size when the estate manifest carries no `encoder_head` (sheet §7).
pub const DEFAULT_ENCODER_HEAD: usize = 30;

/// Reciprocal-rank constant, the same `k = 60` every other RRF fusion in the
/// coordinator uses (sheet §8).
pub const RRF_K: usize = 60;

/// Error from the encoder or the span-row reader. The coordinator treats any
/// error as "stage degraded, lexical order stands" (sheet §7 failure contract).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpanRerankError(pub String);

impl std::fmt::Display for SpanRerankError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "span rerank: {}", self.0)
    }
}

impl std::error::Error for SpanRerankError {}

/// The query side of a span encoder as the recall stage reads it (sheet §7
/// `SpanEncoder`, narrowed to the two members recall needs).
pub trait SpanRerankEncoding: Send + Sync {
    /// The active registry model id (sheet §1, e.g. `minilm-l6-v2-w60`). The
    /// span rows are read under this id, so a model swap re-keys the lookup.
    fn model_id(&self) -> &str;

    /// Encode one query: applies the model's query prefix, pools, and
    /// L2-normalises, so a dot product against a stored span is a cosine.
    fn encode_query(&self, text: &str) -> Result<Vec<f32>, SpanRerankError>;
}

/// One stored span vector as the recall stage reads it: the sheet §3 span row
/// without `content_version` (the drain duty's staleness key, which recall does
/// not consult — a stale row still ranks; the duty replaces it).
#[derive(Debug, Clone, PartialEq)]
pub struct SpanRerankVector {
    /// Span index within the item (0-based, span order).
    pub index: u32,
    /// The int8-quantised span vector (`dim` entries, sheet §4).
    pub int8: Vec<i8>,
    /// The per-vector dequantisation scale (sheet §4: `max_i |v_i| / 127`).
    pub scale: f32,
    /// First word of the span in the item's word list (inclusive).
    pub start_word: usize,
    /// End word of the span (exclusive).
    pub end_word: usize,
}

/// Serving-generation span rows per item (sheet §3
/// `VectorStore::span_vectors(item_ids, model_id)`). Items with no rows under
/// the model are absent from the result.
pub trait SpanVectorReading: Send + Sync {
    fn span_vectors(
        &self,
        item_ids: &[String],
        model_id: &str,
    ) -> Result<HashMap<String, Vec<SpanRerankVector>>, SpanRerankError>;
}

/// One head entry handed to the stage: the item and its 1-based lexical rank.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpanRerankInput {
    pub item_id: String,
    pub bm25_rank: usize,
}

/// One span hit: the item's best span under the active model and its cosine.
/// The span bounds ride the returned `RecallHit` so the composer can render the
/// evidence snippet (sheet §9) without re-deriving the spans.
#[derive(Debug, Clone, PartialEq)]
pub struct SpanRerankHit {
    pub item_id: String,
    pub best_span_index: u32,
    pub best_span_start: usize,
    pub best_span_end: usize,
    pub cosine: f32,
}

/// The per-estate registration the coordinator reads: the encoder, the span
/// rows, and the head size (`encoder_head`, sheet §7).
pub struct SpanRerankSource {
    pub encoder: Arc<dyn SpanRerankEncoding>,
    pub store: Arc<dyn SpanVectorReading>,
    pub head: usize,
}

/// One entry of the fused lexical list: the item, its reciprocal-rank score,
/// and its span hit when the head produced one.
#[derive(Debug, Clone, PartialEq)]
pub struct FusedLexicalEntry {
    pub id: String,
    pub score: f32,
    pub hit: Option<SpanRerankHit>,
}

/// Cosine between a unit float query `u` and a stored int8 span (sheet §4):
/// `Σ u_i × q_i × scale`, no renormalisation — the quantisation error is
/// accepted by ruling. f32 accumulation in index order, the same operation
/// order as the Swift twin and the fixture generator, so the two ports produce
/// identical cosines for identical rows.
pub fn dot_query(u: &[f32], q: &[i8], scale: f32) -> f32 {
    let mut acc: f32 = 0.0;
    for i in 0..u.len().min(q.len()) {
        acc += (u[i] * f32::from(q[i])) * scale;
    }
    acc
}

/// Rerank the lexical head by the best span cosine per item.
///
/// Encodes the query once, reads the span rows for every head item under the
/// encoder's model id, and keeps the best (highest-cosine) span per item; an
/// item with no rows under the active model produces no hit and keeps its
/// lexical rank in `fuse`. Returned hits are in span-rank order: cosine
/// descending, ties by `bm25_rank` ascending (sheet §8), so the array index is
/// the hit's span rank. Twin of Swift `SpanRerankStage.spanRerank`.
pub fn span_rerank(
    head: &[SpanRerankInput],
    query: &str,
    encoder: &dyn SpanRerankEncoding,
    store: &dyn SpanVectorReading,
) -> Result<Vec<SpanRerankHit>, SpanRerankError> {
    if head.is_empty() {
        return Ok(Vec::new());
    }
    let query_vector = encoder.encode_query(query)?;
    if query_vector.is_empty() {
        return Ok(Vec::new());
    }
    let ids: Vec<String> = head.iter().map(|h| h.item_id.clone()).collect();
    let rows = store.span_vectors(&ids, encoder.model_id())?;
    let mut hits: Vec<(SpanRerankHit, usize)> = Vec::new();
    for input in head {
        let Some(spans) = rows.get(&input.item_id) else { continue };
        let mut best: Option<SpanRerankHit> = None;
        for span in spans {
            // A row whose dimension disagrees with the query vector is not this
            // model's row; it cannot be scored and is skipped.
            if span.int8.len() != query_vector.len() {
                continue;
            }
            let cosine = dot_query(&query_vector, &span.int8, span.scale);
            // Strictly greater keeps the lowest span index on an exact tie, so
            // both ports pick the same span.
            if best.as_ref().map_or(true, |b| cosine > b.cosine) {
                best = Some(SpanRerankHit {
                    item_id: input.item_id.clone(),
                    best_span_index: span.index,
                    best_span_start: span.start_word,
                    best_span_end: span.end_word,
                    cosine,
                });
            }
        }
        if let Some(best) = best {
            hits.push((best, input.bm25_rank));
        }
    }
    hits.sort_by(|a, b| {
        b.0.cosine
            .partial_cmp(&a.0.cosine)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.1.cmp(&b.1))
    });
    Ok(hits.into_iter().map(|(hit, _)| hit).collect())
}

/// Fuse the lexical order with the span hits (sheet §8): reciprocal-rank fusion
/// with `k = RRF_K`, `score = 1/(k + bm25_rank) + w/(k + span_rank)`, where
/// `span_rank` runs over the hits only (their slice order) and an item without
/// a hit keeps `1/(k + bm25_rank)`. Sorted by score descending, ties by
/// `bm25_rank` ascending. `span_weight` is `w` (1.0 by ruling; the shape key
/// `dense:<model_id>` scales it). Twin of Swift `SpanRerankStage.fuse`.
pub fn fuse(bm25_order: &[String], hits: &[SpanRerankHit], span_weight: f32) -> Vec<FusedLexicalEntry> {
    let mut hit_by_id: HashMap<&str, (&SpanRerankHit, usize)> = HashMap::new();
    for (index, hit) in hits.iter().enumerate() {
        hit_by_id.entry(hit.item_id.as_str()).or_insert((hit, index + 1));
    }
    let k = RRF_K as f32;
    let mut fused: Vec<(FusedLexicalEntry, usize)> = Vec::with_capacity(bm25_order.len());
    for (index, id) in bm25_order.iter().enumerate() {
        let bm25_rank = index + 1;
        let mut score = 1.0 / (k + bm25_rank as f32);
        let mut hit = None;
        if let Some((h, span_rank)) = hit_by_id.get(id.as_str()) {
            score += span_weight / (k + *span_rank as f32);
            hit = Some((*h).clone());
        }
        fused.push((FusedLexicalEntry { id: id.clone(), score, hit }, bm25_rank));
    }
    fused.sort_by(|a, b| {
        b.0.score
            .partial_cmp(&a.0.score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.1.cmp(&b.1))
    });
    fused.into_iter().map(|(entry, _)| entry).collect()
}

// MARK: - Activation seams
//
// What puts the stage live when an estate's `embedding_provider` is
// `"encoder"` (contract sheet §7/§8): the CorpusKit `SpanEncoder` becomes the
// query seam, the estate's SynapseKit `VectorStore` becomes the span-row
// reader, and the LocusKit `encoder_models` row becomes the CorpusKit spec the
// factory loads. `EstateCoordinator::activate_span_encoder` composes them.
// Mirrors Swift `SpanRerankActivation.swift`.

/// CorpusKit `SpanEncoder` as the stage's query seam.
pub struct SpanEncoderQuerySeam(pub Arc<dyn corpus_kit::encoder::SpanEncoder>);

impl SpanRerankEncoding for SpanEncoderQuerySeam {
    fn model_id(&self) -> &str {
        &self.0.spec().model_id
    }

    fn encode_query(&self, text: &str) -> Result<Vec<f32>, SpanRerankError> {
        self.0.encode_query(text).map_err(|e| SpanRerankError(e.to_string()))
    }
}

/// SynapseKit's span rows as the stage reads them (sheet §3 rows, serving
/// generation only). `content_version` is the duty's staleness key and is not
/// consulted by recall, so it does not travel.
pub struct SynapseSpanVectorReader(pub Arc<synapsekit::vector_store::VectorStore>);

impl SpanVectorReading for SynapseSpanVectorReader {
    fn span_vectors(
        &self,
        item_ids: &[String],
        model_id: &str,
    ) -> Result<HashMap<String, Vec<SpanRerankVector>>, SpanRerankError> {
        let refs: Vec<&str> = item_ids.iter().map(String::as_str).collect();
        let rows = self
            .0
            .span_vectors(&refs, model_id)
            .map_err(|e| SpanRerankError(format!("{e:?}")))?;
        Ok(rows
            .into_iter()
            .map(|(id, rows)| {
                let rows = rows
                    .into_iter()
                    .map(|r| SpanRerankVector {
                        index: r.index,
                        int8: r.int8,
                        scale: r.scale,
                        start_word: r.start_word,
                        end_word: r.end_word,
                    })
                    .collect();
                (id, rows)
            })
            .collect())
    }
}

/// The `encoder_models` registry row as the encoder contract reads it, field
/// for field. `is_active` is the registry's own state (which row is serving)
/// and is not part of the model contract, so it does not travel. The row's
/// i64 counts are clamped at zero on the way to usize.
pub fn encoder_spec_from_row(
    row: &locus_kit::encoder_model_store::EncoderModelRow,
) -> corpus_kit::encoder::EncoderModelSpec {
    fn count(v: i64) -> usize {
        usize::try_from(v.max(0)).unwrap_or(0)
    }
    corpus_kit::encoder::EncoderModelSpec {
        model_id: row.model_id.clone(),
        model_version: row.model_version.clone(),
        dim: count(row.dim),
        query_prefix: row.query_prefix.clone(),
        doc_prefix: row.doc_prefix.clone(),
        pooling: match row.pooling {
            locus_kit::encoder_model_store::Pooling::Cls => corpus_kit::encoder::Pooling::Cls,
            locus_kit::encoder_model_store::Pooling::Mean => corpus_kit::encoder::Pooling::Mean,
        },
        tokenizer_hash: row.tokenizer_hash.clone(),
        window_words: count(row.window_words),
        overlap_divisor: count(row.overlap_divisor),
        max_spans: count(row.max_spans),
        max_sequence: count(row.max_sequence),
    }
}
