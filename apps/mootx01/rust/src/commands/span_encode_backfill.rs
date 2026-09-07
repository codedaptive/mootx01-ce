//! The span-encode batch function `mootx01 upgrade` runs (ENCODER_RERANK
//! CONTRACT §10, §12): for every drawer whose bit 27 (`SPAN_INDEXED`) is
//! clear, cut the content into spans, encode them with the ACTIVE registry
//! model, quantise to int8, write the span rows, set the bit. This is the
//! same per-batch sequence the resident's REM-ALPHA `spanEncode` duty
//! (`brain::span_encode_duty`) performs on a live estate; the upgrade runs
//! it here over a CLOSED estate's storage, after the maintenance open has
//! finished, so no coordinator or daemon has to be alive for the backfill.
//! Twin of Swift `SpanEncodeBackfill.swift`.
//!
//! Contract names this helper codes against:
//!   - corpus-kit `EncoderModelSpec`, `SpanEncoder::encode_spans`,
//!     `encoder::spanner::{words, spans}` (§7);
//!   - corpus-kit-providers `SpanEncoderFactory::make(spec, model_dir)`,
//!     `model_dir_for(model_id, data_dir) -> Option<PathBuf>` (§7, bundling).
//!
//! The seed row is now constructed through
//! `EstateCoordinator::seed_default_encoder_model_in` (ruling 2026-09-04:
//! seeding belongs to provision and serve; the upgrade backfill is one of the
//! two authorised seeders, alongside the GLK activation path at open). This
//! keeps the one construction site for the seed row in the Rust port.
//!
//! Failure contract (§7): no active row, a missing model directory, a vocab
//! hash mismatch, or a load failure is a clean skip: recall stays
//! lexical-only, the caller prints one line, nothing is written.

use std::path::Path;
use std::sync::Arc;

use corpus_kit::encoder::spanner;
use corpus_kit::encoder::{EncoderModelSpec as EncoderSpec, Pooling as EncoderPooling, SpanEncoder};
use corpus_kit_providers::{model_dir_for, SpanEncoderFactory};
use genius_locus_kit::EstateCoordinator;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::encoder_model_store::{EncoderModelStore, Pooling};
use persistence_kit::predicate::StoragePredicate;
use persistence_kit::types::{Column, TypedValue};
use persistence_kit::Storage;
use substrate_kernel::int8_vec;
use synapsekit::{SpanVectorInput, VectorStore};

/// What the backfill did. Mirrors Swift `SpanEncodeReport`.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum SpanEncodeReport {
    /// `encoder_models` has no active row: lexical-only estate.
    NoActiveModel,
    /// An active row exists but the encoder could not be built (directory,
    /// vocab hash, or load); the reason is the one line the caller prints.
    ModelUnavailable(String),
    /// Drawers and span rows written, and how many drawers still owe spans.
    Encoded { drawers: usize, spans: usize, remaining: usize },
}

/// Drawers per encode call: the default `encoder_batch` outside iOS (§7).
pub(crate) const BATCH_SIZE: usize = 64;

/// Encode every drawer whose bit 27 is clear under the active model.
///
/// `storage` is an opened estate whose LocusKit and SynapseKit schemas are
/// current (the upgrade step opened it through the registry's maintenance
/// path first); `store` is the drawer store over the same storage;
/// `data_dir` is the mootx01 data directory the model resolver searches
/// first (the 1.2 download slot). `now_millis` stamps the span rows'
/// `filed_at`.
pub(crate) fn run(
    storage: Arc<dyn Storage>,
    store: &dyn DrawerStore,
    data_dir: &Path,
    now_millis: i64,
) -> Result<SpanEncodeReport, String> {
    let registry = EncoderModelStore::new(Arc::clone(&storage));
    // A CE 1.0.x estate arrives at format 19 with an empty registry: seed the
    // bundled model as the active row through the one construction site for the
    // seed row in the Rust port. The maintenance open seeds the registry through
    // activation once the manifest names the encoder; this call keeps the
    // backfill correct over its own storage (an estate whose embedding_provider
    // key was written after the open) and is idempotent otherwise. An estate
    // that already carries an active row keeps it; a later audition winner is
    // a row swap, not a reseed.
    EstateCoordinator::seed_default_encoder_model_in(&registry).map_err(|e| e.to_string())?;
    let Some(row) = registry.active().map_err(|e| e.to_string())? else {
        return Ok(SpanEncodeReport::NoActiveModel);
    };
    let Some(model_dir) = model_dir_for(&row.model_id, data_dir) else {
        return Ok(SpanEncodeReport::ModelUnavailable(format!(
            "no model directory for {}",
            row.model_id
        )));
    };
    let spec = EncoderSpec {
        model_id: row.model_id.clone(),
        model_version: row.model_version.clone(),
        dim: row.dim as usize,
        query_prefix: row.query_prefix.clone(),
        doc_prefix: row.doc_prefix.clone(),
        pooling: match row.pooling {
            Pooling::Mean => EncoderPooling::Mean,
            Pooling::Cls => EncoderPooling::Cls,
        },
        tokenizer_hash: row.tokenizer_hash.clone(),
        window_words: row.window_words as usize,
        overlap_divisor: row.overlap_divisor as usize,
        max_spans: row.max_spans as usize,
        max_sequence: row.max_sequence as usize,
    };
    let encoder: Box<dyn SpanEncoder> = match SpanEncoderFactory::make(&spec, &model_dir) {
        Ok(e) => e,
        Err(e) => return Ok(SpanEncodeReport::ModelUnavailable(format!("{e:?}"))),
    };

    let vectors = VectorStore::new(Arc::clone(&storage), None);
    let mut drawers_done = 0usize;
    let mut spans_written = 0usize;
    let mut cursor: Option<String> = None;
    loop {
        let batch = store
            .span_index_debt_batch(BATCH_SIZE, cursor.as_deref())
            .map_err(|e| e.to_string())?;
        if batch.is_empty() {
            break;
        }
        for drawer in &batch {
            let words = spanner::words(&drawer.content);
            let bounds = spanner::spans(
                words.len(),
                spec.window_words,
                spec.overlap_divisor,
                spec.max_spans,
            );
            let texts: Vec<String> = bounds
                .iter()
                .map(|(start, end)| words[*start..*end].join(" "))
                .collect();
            let text_refs: Vec<&str> = texts.iter().map(String::as_str).collect();
            let floats = encoder.encode_spans(&text_refs).map_err(|e| format!("{e:?}"))?;
            let content_version = content_version(&storage, &drawer.id)?;
            let inputs: Vec<SpanVectorInput> = floats
                .iter()
                .enumerate()
                .map(|(index, vector)| {
                    let (q, scale) = int8_vec::quantize(vector);
                    SpanVectorInput {
                        index: index as u32,
                        int8: q,
                        scale,
                        start_word: bounds[index].0,
                        end_word: bounds[index].1,
                        content_version: content_version.clone(),
                    }
                })
                .collect();
            vectors
                .write_span_vectors(&drawer.id, &row.model_id, &row.model_version, &inputs, now_millis)
                .map_err(|e| format!("{e:?}"))?;
            store.set_span_indexed(&drawer.id).map_err(|e| e.to_string())?;
            drawers_done += 1;
            spans_written += inputs.len();
        }
        cursor = batch.last().map(|d| d.id.clone());
    }
    let remaining = store.count_span_index_debt().map_err(|e| e.to_string())?;
    Ok(SpanEncodeReport::Encoded { drawers: drawers_done, spans: spans_written, remaining })
}

/// The drawer's `content_hash` column as lowercase hex, the span rows'
/// `content_version` (§3). `Drawer` does not carry the hash (the
/// hash-on-write hook owns the column), so it is read per row here. Empty
/// when the row predates hash-on-write; a later content write always
/// produces a hash, so a stale span set is still recognised.
fn content_version(storage: &Arc<dyn Storage>, drawer_id: &str) -> Result<String, String> {
    let rows = storage
        .row_store()
        .query_projected(
            "drawers",
            &["content_hash"],
            Some(&StoragePredicate::Eq(
                Column::new("drawers", "id"),
                TypedValue::Text(drawer_id.to_string()),
            )),
            &[],
            Some(1),
            None,
        )
        .map_err(|e| e.to_string())?;
    Ok(match rows.first().and_then(|r| r.get("content_hash")) {
        Some(TypedValue::Blob(bytes)) => bytes.iter().map(|b| format!("{b:02x}")).collect(),
        _ => String::new(),
    })
}
