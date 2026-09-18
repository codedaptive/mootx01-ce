// brain/span_encode_duty.rs — Rust mirror of `SpanEncodeDuty.swift`.
//
// Drain duty for the `span-encode` standing signal (signal 13, REM-ALPHA, 30 s).
// Encodes drawers with bit 27 clear into int8 span vectors and writes them
// to `vectors_v6` (contract §3).
//
// The duty reads drawers whose bit 27 is clear, windows their content with
// CorpusKit's `spanner`, encodes through the registered CorpusKit
// `SpanEncoder`, quantises with SubstrateKernel `int8_vec` (contract §4) and
// writes SynapseKit `SpanVectorInput` rows. `encode_batch_with` takes the
// estate and the store as trait objects so the tests run on fakes; the
// production seams at the bottom of this file are the real estate and store.
// The float values a fake encoder produces may differ from the Swift port;
// the int8 rows, span ordering and bit-27 semantics must match.

/// Outcome of one `encode_batch_with` invocation.
/// Mirrors Swift `SpanEncodeBatchResult`.
use std::sync::Arc;

use corpus_kit::encoder::{spanner, EncoderModelSpec, SpanEncoder};
use locus_kit::estate::Estate;
use substrate_kernel::int8_vec;
use synapsekit::vector_store::{SpanVectorInput, VectorStore};
use crate::span_content_version::span_content_version;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SpanEncodeBatchResult {
    /// Drawers whose span rows were written and bit 27 set.
    pub encoded: usize,
    /// Drawers skipped: empty content, or the drawer was erased or rewritten
    /// between the pending read and the span write (the liveness recheck).
    pub skipped: usize,
    /// Drawers whose encoding failed (bit 27 stays clear for retry).
    pub failed: usize,
}

/// Default batch size (drawers per signal fire). Mirrors
/// Swift `SpanEncodeDuty.defaultBatchSize`.
pub const DEFAULT_BATCH_SIZE: usize = 64;

//
// corpus_kit crate and remove this block.

/// Where the duty writes span rows; the production writer is the estate's
/// SynapseKit store (`VectorStoreSpanWriter` below).
pub trait SpanVectorWriter: Send + Sync {
    fn write_span_vectors(
        &self,
        item_id: &str,
        model_id: &str,
        model_version: &str,
        spans: &[SpanVectorInput],
    ) -> Result<(), String>;
}

/// Bit-27 read/mark seam over the estate (production: `EstateSpanContext`).
/// Tests inject a fake; production wraps `Estate::pending_span_encode_batch`
/// and `Estate::set_span_indexed`.
pub trait SpanEncodeContext: Send + Sync {
    /// Return up to `limit` drawer IDs + content tuples with bit 27 clear.
    fn pending_span_encode_batch(&self, limit: usize) -> Result<Vec<(String, String)>, String>;
    /// Set or clear bit 27 (`span_indexed`) for one drawer.
    fn set_span_indexed(&self, drawer_id: &str, indexed: bool) -> Result<(), String>;
    /// The drawer's content as stored NOW, or `None` when the drawer is
    /// missing or tombstoned. Read immediately before the span write so an
    /// erase or content write that landed after the pending snapshot is
    /// honoured (the liveness recheck). Mirrors Swift
    /// `SpanEncodeEstateContext.liveSpanEncodeContent(drawerID:)`.
    fn live_span_encode_content(&self, drawer_id: &str) -> Result<Option<String>, String>;
}

// MARK: - Core duty

/// Process one span-encode drain batch.
///
/// Mirrors Swift `SpanEncodeDuty._encodeBatch(context:encoder:writer:limit:now:)`.
/// - Encoder `None` → skip (no rows written, bits stay clear).
/// - Per-drawer failure → non-fatal; `failed` count incremented, bit 27 stays clear.
pub fn encode_batch_with(
    context: &dyn SpanEncodeContext,
    encoder: Option<&dyn SpanEncoder>,
    writer: &dyn SpanVectorWriter,
    limit: usize,
) -> Result<SpanEncodeBatchResult, String> {
    let encoder = match encoder {
        Some(e) => e,
        None => {
            // Encoder nil: log and return zero. Matches Swift `guard encoder` branch.
            // (No OSLog in Rust; callers log if needed.)
            return Ok(SpanEncodeBatchResult { encoded: 0, skipped: 0, failed: 0 });
        }
    };

    let pending = context.pending_span_encode_batch(limit)?;
    if pending.is_empty() {
        return Ok(SpanEncodeBatchResult { encoded: 0, skipped: 0, failed: 0 });
    }

    let spec = encoder.spec();
    let mut encoded = 0usize;
    let mut skipped = 0usize;
    let mut failed = 0usize;

    // ADR-028 E1: the encoder sees the batch once. Every drawer's spans are
    // planned first and their texts laid end to end in drawer order; one
    // `encode_spans` call covers them all (the encoder batches the list
    // itself) and the vectors are dealt back to each drawer by its range.
    // The vectors are exactly what one call per drawer produces; only the
    // number of round trips through the model changes.
    struct Plan<'a> {
        drawer_id: &'a str,
        content: &'a str,
        bounds: Vec<(usize, usize)>,
        range: std::ops::Range<usize>,
    }
    let mut plans: Vec<Plan<'_>> = Vec::new();
    let mut all_texts: Vec<String> = Vec::new();
    for (drawer_id, content) in &pending {
        let plan = if content.is_empty() { None } else { span_plan(content, spec) };
        let Some((bounds, texts)) = plan else {
            skipped += 1;
            continue;
        };
        let start = all_texts.len();
        all_texts.extend(texts);
        plans.push(Plan { drawer_id, content, bounds, range: start..all_texts.len() });
    }

    // One batch call. When the batch as a whole fails, every drawer is
    // encoded on its own below, so one bad drawer costs itself, not the
    // batch.
    let batch_vectors: Option<Vec<Vec<f32>>> = if all_texts.is_empty() {
        None
    } else {
        let refs: Vec<&str> = all_texts.iter().map(String::as_str).collect();
        match encoder.encode_spans(&refs) {
            Ok(vectors) if vectors.len() == all_texts.len() => Some(vectors),
            _ => None,
        }
    };

    for plan in &plans {
        let drawer_id = plan.drawer_id;
        let content = plan.content;
        let vectors: Vec<Vec<f32>> = match &batch_vectors {
            Some(vectors) => vectors[plan.range.clone()].to_vec(),
            None => {
                let refs: Vec<&str> =
                    all_texts[plan.range.clone()].iter().map(String::as_str).collect();
                match encoder.encode_spans(&refs) {
                    Ok(vectors) if vectors.len() == plan.bounds.len() => vectors,
                    _ => {
                        failed += 1;
                        continue;
                    }
                }
            }
        };
        let inputs = span_inputs(content, &plan.bounds, &vectors);
        // SECURITY: liveness recheck (destruction contract). The
        // pending snapshot was read before this drawer was encoded;
        // an erase or a content write that landed in between must
        // not be undone by a span write that recreates
        // content-derived rows for a tombstoned drawer, or stamps
        // spans of the old text with a content version the drawer
        // no longer has. Skip when the drawer is gone or tombstoned,
        // or when its current content no longer hashes to the
        // version stamped on the spans; bit 27 stays clear, so a
        // rewritten drawer is re-encoded on the next pump from its
        // current content. Mirrors the Swift `_encodeBatch` guard.
        let encoded_version = span_content_version(content);
        let live = match context.live_span_encode_content(drawer_id) {
            Ok(live) => live,
            Err(_) => {
                failed += 1;
                continue;
            }
        };
        match live {
            Some(live_content) if span_content_version(&live_content) == encoded_version => {}
            _ => {
                skipped += 1;
                continue;
            }
        }
        // Write span vectors, then set bit 27.
        let write_result = writer.write_span_vectors(
            drawer_id, &spec.model_id, &spec.model_version, &inputs);
        match write_result {
            Ok(()) => {
                match context.set_span_indexed(drawer_id, true) {
                    Ok(()) => encoded += 1,
                    Err(_) => failed += 1,
                }
            }
            Err(_) => failed += 1,
        }
    }

    Ok(SpanEncodeBatchResult { encoded, skipped, failed })
}

// MARK: - Internal helpers

/// The span plan for one drawer: the word bounds of each span and the text
/// the encoder sees for it. `None` when the content has no words or yields
/// no spans.
fn span_plan(content: &str, spec: &EncoderModelSpec) -> Option<(Vec<(usize, usize)>, Vec<String>)> {
    let words = spanner::words(content);
    if words.is_empty() {
        return None;
    }
    let bounds = spanner::spans(
        words.len(), spec.window_words, spec.overlap_divisor, spec.max_spans);
    if bounds.is_empty() {
        return None;
    }
    // The encoder applies the model's document prefix itself (contract sheet
    // §7: prefixes belong to the contract layer, never to callers).
    let texts: Vec<String> = bounds
        .iter()
        .map(|(start, end)| words[*start..*end].join(" "))
        .collect();
    Some((bounds, texts))
}

/// The span rows for one drawer from its plan and the vectors the encoder
/// returned for it, quantized to int8.
fn span_inputs(content: &str, bounds: &[(usize, usize)], vectors: &[Vec<f32>]) -> Vec<SpanVectorInput> {
    let cv = span_content_version(content);
    bounds
        .iter()
        .zip(vectors.iter())
        .enumerate()
        .map(|(idx, ((start, end), fv))| {
            let (q, scale) = int8_vec::quantize(fv);
            SpanVectorInput {
                index: idx as u32,
                int8: q,
                scale,
                start_word: *start,
                end_word: *end,
                content_version: cv.clone(),
            }
        })
        .collect()
}

// MARK: - Unit tests (Rust-side; Swift-side tests are the contract's three-test spec)


// MARK: - Production seams
//
// The estate as the duty reads and marks it, and the estate's SynapseKit
// store as the duty writes it. `EstateCoordinator::run_span_encode_batch`
// composes them once per signal fire. Mirrors Swift `EstateSpanContext` /
// `VectorStoreSpanWriter`.

/// Bit 27 = `spanIndexed` (contract sheet §5, `DrawerOperational`).
const SPAN_INDEXED_BIT: i64 = 1 << 27;

/// Page size for the pending scan; the duty stops once `limit` items are
/// collected, so a large estate never hydrates more than it will encode.
const PENDING_PAGE: usize = 200;

pub struct EstateSpanContext<'a> {
    pub estate: &'a Estate,
}

impl SpanEncodeContext for EstateSpanContext<'_> {
    fn pending_span_encode_batch(&self, limit: usize) -> Result<Vec<(String, String)>, String> {
        let mut result = Vec::new();
        let mut cursor: Option<String> = None;
        while result.len() < limit {
            let batch = self
                .estate
                .active_drawers_after(cursor.as_deref(), PENDING_PAGE)
                .map_err(|e| e.to_string())?;
            if batch.is_empty() {
                break;
            }
            for drawer in &batch {
                if drawer.content.is_empty() || drawer.operational_bitmap & SPAN_INDEXED_BIT != 0 {
                    continue;
                }
                result.push((drawer.id.clone(), drawer.content.clone()));
                if result.len() >= limit {
                    break;
                }
            }
            let short_page = batch.len() < PENDING_PAGE;
            cursor = batch.last().map(|d| d.id.clone());
            if short_page {
                break;
            }
        }
        Ok(result)
    }

    fn set_span_indexed(&self, drawer_id: &str, indexed: bool) -> Result<(), String> {
        // Bit 27 is set here and cleared by the content write and by
        // `EncoderModelStore::activate` (sheet §5); the duty never clears it.
        if !indexed {
            return Ok(());
        }
        self.estate.set_span_indexed(drawer_id).map(|_| ()).map_err(|e| e.to_string())
    }

    fn live_span_encode_content(&self, drawer_id: &str) -> Result<Option<String>, String> {
        // `drawer_by_id` returns tombstoned rows unfiltered; the tombstone
        // stamp is the erase signal, the (zeroed) content is not consulted.
        let drawer = self.estate.drawer_by_id(drawer_id).map_err(|e| e.to_string())?;
        Ok(drawer
            .filter(|d| d.tombstoned_at.is_none())
            .map(|d| d.content))
    }
}

pub struct VectorStoreSpanWriter {
    pub store: Arc<VectorStore>,
    /// `filed_at` (epoch milliseconds) for every span row written by this
    /// cycle: the signal's clock, never one read inside the duty.
    pub filed_at: i64,
}

impl SpanVectorWriter for VectorStoreSpanWriter {
    fn write_span_vectors(
        &self,
        item_id: &str,
        model_id: &str,
        model_version: &str,
        spans: &[SpanVectorInput],
    ) -> Result<(), String> {
        self.store
            .write_span_vectors(item_id, model_id, model_version, spans, self.filed_at)
            .map_err(|e| format!("{e:?}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Fake encoder that returns identity-like float vectors.
    struct FakeEncoder {
        spec: EncoderModelSpec,
    }

    impl FakeEncoder {
        fn new() -> Self {
            FakeEncoder {
                spec: EncoderModelSpec {
                    model_id: "test-model".into(),
                    model_version: "v1".into(),
                    dim: 4,
                    query_prefix: "Q:".into(),
                    doc_prefix: "D:".into(),
                    pooling: corpus_kit::encoder::Pooling::Mean,
                    tokenizer_hash: "abc".into(),
                    window_words: 3,
                    overlap_divisor: 2,
                    max_spans: 4,
                    max_sequence: 512,
                },
            }
        }
    }

    impl SpanEncoder for FakeEncoder {
        fn spec(&self) -> &EncoderModelSpec { &self.spec }
        fn encode_query(&self, _text: &str) -> Result<Vec<f32>, corpus_kit::encoder::EncoderError> {
            Ok(vec![0.5_f32, -0.5, 0.25, -0.25])
        }
        fn encode_spans(&self, spans: &[&str]) -> Result<Vec<Vec<f32>>, corpus_kit::encoder::EncoderError> {
            // Return a simple non-zero float vector for each span.
            Ok(spans.iter().map(|_| vec![0.5_f32, -0.5, 0.25, -0.25]).collect())
        }
    }

    struct FakeWriter {
        // Mutex instead of RefCell: SpanVectorWriter requires Send + Sync.
        calls: std::sync::Mutex<Vec<(String, Vec<SpanVectorInput>)>>,
    }

    impl FakeWriter {
        fn new() -> Self { FakeWriter { calls: std::sync::Mutex::new(vec![]) } }
        fn call_count(&self) -> usize { self.calls.lock().unwrap().len() }
    }

    impl SpanVectorWriter for FakeWriter {
        fn write_span_vectors(&self, item_id: &str, _model_id: &str, _model_version: &str, spans: &[SpanVectorInput]) -> Result<(), String> {
            self.calls.lock().unwrap().push((item_id.to_string(), spans.to_vec()));
            Ok(())
        }
    }

    struct FakeContext {
        drawers: Vec<(String, String)>,
        // Mutex instead of RefCell: SpanEncodeContext requires Send + Sync.
        indexed: std::sync::Mutex<Vec<String>>,
        // The drawer state the liveness recheck sees, when it differs from
        // the pending snapshot: `None` = erased (missing or tombstoned),
        // `Some(text)` = rewritten. Drawers without an entry read back their
        // snapshot content. The pending read deliberately ignores this map:
        // it models the snapshot taken BEFORE the erase or rewrite landed.
        live_overrides: std::sync::Mutex<std::collections::HashMap<String, Option<String>>>,
    }

    impl FakeContext {
        fn new(drawers: Vec<(String, String)>) -> Self {
            FakeContext {
                drawers,
                indexed: std::sync::Mutex::new(vec![]),
                live_overrides: std::sync::Mutex::new(std::collections::HashMap::new()),
            }
        }
        fn indexed_ids(&self) -> Vec<String> { self.indexed.lock().unwrap().clone() }
        /// Erase `id` after the pending snapshot: the recheck sees no drawer.
        fn erase_after_snapshot(&self, id: &str) {
            self.live_overrides.lock().unwrap().insert(id.to_string(), None);
        }
        /// Rewrite `id` after the pending snapshot: the recheck sees `content`.
        fn rewrite_after_snapshot(&self, id: &str, content: &str) {
            self.live_overrides.lock().unwrap().insert(id.to_string(), Some(content.to_string()));
        }
    }

    impl SpanEncodeContext for FakeContext {
        fn pending_span_encode_batch(&self, limit: usize) -> Result<Vec<(String, String)>, String> {
            // Return only drawers not yet indexed (bit-27 simulation).
            let indexed = self.indexed.lock().unwrap();
            Ok(self.drawers.iter()
                .filter(|(id, _)| !indexed.contains(id))
                .take(limit)
                .cloned()
                .collect())
        }
        fn set_span_indexed(&self, drawer_id: &str, indexed: bool) -> Result<(), String> {
            if indexed {
                self.indexed.lock().unwrap().push(drawer_id.to_string());
            } else {
                self.indexed.lock().unwrap().retain(|id| id != drawer_id);
            }
            Ok(())
        }
        fn live_span_encode_content(&self, drawer_id: &str) -> Result<Option<String>, String> {
            if let Some(overridden) = self.live_overrides.lock().unwrap().get(drawer_id) {
                return Ok(overridden.clone());
            }
            Ok(self
                .drawers
                .iter()
                .find(|(id, _)| id == drawer_id)
                .map(|(_, content)| content.clone()))
        }
    }

    /// Liveness recheck: a drawer erased between the pending read and the
    /// span write gets NO span rows and keeps bit 27 clear; its four
    /// untouched siblings are encoded. Pre-fix the duty wrote rows for all
    /// five (an erased drawer's content-derived spans recreated after the
    /// erase). Twin of Swift `inFlightEraseSkipsSpanWrite`.
    #[test]
    fn in_flight_erase_skips_span_write_and_keeps_bit_clear() {
        let drawers: Vec<(String, String)> = (0..5)
            .map(|i| (format!("d-{i}"), format!("hello world foo bar baz qux quux {i}")))
            .collect();
        let context = FakeContext::new(drawers);
        context.erase_after_snapshot("d-2");
        let encoder = FakeEncoder::new();
        let writer = FakeWriter::new();

        let result = encode_batch_with(&context, Some(&encoder), &writer, 64).unwrap();

        assert_eq!(result.encoded, 4, "the four live drawers are encoded");
        assert_eq!(result.skipped, 1, "the erased drawer is skipped, not failed");
        assert_eq!(result.failed, 0);
        assert_eq!(writer.call_count(), 4, "no span write for the erased drawer");
        assert!(
            !writer.calls.lock().unwrap().iter().any(|(id, _)| id == "d-2"),
            "d-2 must have no span rows written"
        );
        assert!(!context.indexed_ids().contains(&"d-2".to_string()), "bit 27 stays clear on d-2");
    }

    /// Liveness recheck: a drawer rewritten between the pending read and the
    /// span write gets no rows from the STALE text and keeps bit 27 clear
    /// (the next pump encodes the current text). Pre-fix the duty wrote the
    /// old text's spans and set bit 27, freezing a stale span set under a
    /// content version the drawer no longer has. Twin of Swift
    /// `inFlightRewriteSkipsSpanWrite`.
    #[test]
    fn in_flight_rewrite_skips_stale_span_write() {
        let drawers = vec![
            ("d-1".to_string(), "alpha beta gamma delta epsilon zeta".to_string()),
            ("d-2".to_string(), "one two three four five six seven".to_string()),
        ];
        let context = FakeContext::new(drawers);
        context.rewrite_after_snapshot("d-2", "entirely different words now here");
        let encoder = FakeEncoder::new();
        let writer = FakeWriter::new();

        let result = encode_batch_with(&context, Some(&encoder), &writer, 64).unwrap();

        assert_eq!(result.encoded, 1);
        assert_eq!(result.skipped, 1, "the rewritten drawer is skipped this pump");
        assert_eq!(result.failed, 0);
        assert_eq!(writer.call_count(), 1);
        assert!(
            !writer.calls.lock().unwrap().iter().any(|(id, _)| id == "d-2"),
            "d-2 must not receive the stale span set"
        );
        assert!(!context.indexed_ids().contains(&"d-2".to_string()), "bit 27 stays clear on d-2");
    }

    #[test]
    fn encode_five_drawers_sets_bit_and_writes_spans() {
        let drawers: Vec<(String, String)> = (0..5)
            .map(|i| (format!("d-{i}"), format!("hello world foo bar baz qux quux {i}")))
            .collect();
        let context = FakeContext::new(drawers.clone());
        let encoder = FakeEncoder::new();
        let writer = FakeWriter::new();

        let result = encode_batch_with(&context, Some(&encoder), &writer, 64).unwrap();

        assert_eq!(result.encoded, 5);
        assert_eq!(result.skipped, 0);
        assert_eq!(result.failed, 0);
        // All five drawer IDs must have bit-27 set.
        let indexed = context.indexed_ids();
        for (id, _) in &drawers {
            assert!(indexed.contains(id), "drawer {id} must be indexed");
        }
        // Span rows must have been written for every drawer.
        assert_eq!(writer.call_count(), 5);
    }

    #[test]
    fn encoder_none_returns_zero_and_no_writes() {
        let drawers = vec![
            ("d-1".to_string(), "some content".to_string()),
        ];
        let context = FakeContext::new(drawers);
        let writer = FakeWriter::new();

        let result = encode_batch_with(&context, None, &writer, 64).unwrap();

        assert_eq!(result.encoded, 0);
        assert_eq!(result.skipped, 0);
        assert_eq!(result.failed, 0);
        assert_eq!(writer.call_count(), 0);
        assert!(context.indexed_ids().is_empty());
    }

    #[test]
    fn spanner_words_splits_correctly() {
        let words = spanner::words("Hello, World! 42");
        assert_eq!(words, vec!["hello", "world", "42"]);
    }

    #[test]
    fn quantize_zero_vector() {
        let (q, scale) = int8_vec::quantize(&[0.0, 0.0]);
        assert_eq!(q, vec![0, 0]);
        assert_eq!(scale, 1.0);
    }

    #[test]
    fn quantize_round_trips_near_127() {
        let v = vec![1.0_f32, -1.0, 0.5, -0.5];
        let (q, scale) = int8_vec::quantize(&v);
        // max_abs = 1.0, scale = 1.0/127
        assert!(scale < 0.009, "scale should be ~1/127");
        assert_eq!(q[0], 127);
        assert_eq!(q[1], -127);
    }

    // ADR-028 E1: a fake encoder that counts its calls and fails on a span
    // text carrying `poison`, so a batch holding one bad drawer fails as a
    // batch and only that drawer fails on its own. Twin of the Swift
    // `CountingEncoder`.
    struct CountingEncoder {
        spec: EncoderModelSpec,
        calls: std::sync::Mutex<usize>,
    }

    impl CountingEncoder {
        fn new() -> Self {
            CountingEncoder { spec: FakeEncoder::new().spec, calls: std::sync::Mutex::new(0) }
        }
        fn calls(&self) -> usize { *self.calls.lock().unwrap() }
    }

    impl SpanEncoder for CountingEncoder {
        fn spec(&self) -> &EncoderModelSpec { &self.spec }
        fn encode_query(&self, _text: &str) -> Result<Vec<f32>, corpus_kit::encoder::EncoderError> {
            Ok(vec![0.5_f32, -0.5, 0.25, -0.25])
        }
        fn encode_spans(&self, spans: &[&str]) -> Result<Vec<Vec<f32>>, corpus_kit::encoder::EncoderError> {
            *self.calls.lock().unwrap() += 1;
            if spans.iter().any(|s| s.contains("poison")) {
                return Err(corpus_kit::encoder::EncoderError::InferenceFailed("poisoned".into()));
            }
            Ok(spans.iter().map(|_| vec![0.5_f32, -0.5, 0.25, -0.25]).collect())
        }
    }

    #[test]
    fn batch_encodes_with_one_encoder_call() {
        let drawers: Vec<(String, String)> = (0..5)
            .map(|i| (format!("d-{i}"), format!("hello world foo bar baz qux quux {i}")))
            .collect();
        let context = FakeContext::new(drawers);
        let encoder = CountingEncoder::new();
        let writer = FakeWriter::new();

        let result = encode_batch_with(&context, Some(&encoder), &writer, 64).unwrap();

        assert_eq!(result.encoded, 5);
        assert_eq!(result.failed, 0);
        assert_eq!(encoder.calls(), 1, "the batch is one round trip through the encoder");
        assert_eq!(writer.call_count(), 5, "the vectors are dealt back to every drawer");
    }

    #[test]
    fn batch_failure_falls_back_per_drawer() {
        let mut drawers: Vec<(String, String)> = (0..5)
            .map(|i| (format!("d-{i}"), format!("hello world foo bar baz qux quux {i}")))
            .collect();
        drawers[2].1 = "this drawer holds poison words for the encoder".to_string();
        let context = FakeContext::new(drawers);
        let encoder = CountingEncoder::new();
        let writer = FakeWriter::new();

        let result = encode_batch_with(&context, Some(&encoder), &writer, 64).unwrap();

        assert_eq!(result.encoded, 4, "the four clean drawers are encoded on their own");
        assert_eq!(result.failed, 1, "the poisoned drawer alone fails");
        assert_eq!(encoder.calls(), 6, "one batch call, then one call per drawer");
        assert!(!context.indexed_ids().contains(&"d-2".to_string()), "bit 27 stays clear for retry");
        assert!(!writer.calls.lock().unwrap().iter().any(|(id, _)| id == "d-2"));
        assert_eq!(writer.call_count(), 4);
    }
}
