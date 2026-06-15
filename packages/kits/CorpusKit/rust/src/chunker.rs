//! Sentence-aware chunking. Sentence segmentation is delegated to
//! `eidetic_lib::segmenter::sentences`, which centralizes the FDC
//! encoder mandate's sentence-segmentation stage alongside the rest
//! of the linguistic pipeline (tokenizer / normalizer / stemmer /
//! word_class). The default chunk size matches the substrate
//! reference (800-character target, 100 overlap).

use crate::chunk::Chunk;
use eidetic_lib::segmenter;
use std::collections::BTreeMap;
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_types::hlc::HLCGenerator;

#[derive(Debug, Clone, Copy)]
pub struct ChunkerConfiguration {
    pub target_chars: usize,
    pub overlap_chars: usize,
    pub respect_sentences: bool,
}

impl ChunkerConfiguration {
    pub fn new(target_chars: usize, overlap_chars: usize, respect_sentences: bool) -> Self {
        let target = target_chars.max(1);
        let overlap = overlap_chars.min(target.saturating_sub(1));
        ChunkerConfiguration {
            target_chars: target,
            overlap_chars: overlap,
            respect_sentences,
        }
    }
}

impl Default for ChunkerConfiguration {
    fn default() -> Self {
        ChunkerConfiguration::new(800, 100, true)
    }
}

/// Split text into chunks per the configuration. Each chunk
/// carries the source identifier, the character start offset, and
/// an HLC tag assigned in order from `hlc_generator`.
///
/// `now_millis` is supplied by the caller (test-time
/// determinism); production callers pass the current Unix epoch
/// in milliseconds. The HLC generator advances on each chunk
/// emission.
pub fn chunk(
    text: &str,
    source_id: &str,
    config: ChunkerConfiguration,
    hlc_generator: &mut HLCGenerator,
    now_millis: i64,
) -> Vec<Chunk> {
    let segments: Vec<String> = if config.respect_sentences {
        segmenter::sentences(text)
    } else {
        vec![text.to_string()]
    };

    let mut chunks: Vec<Chunk> = Vec::new();
    let mut buffer = String::new();
    let mut buffer_start: usize = 0;
    let mut current_offset: usize = 0;

    for segment in segments {
        let seg_len = segment.chars().count();
        if buffer.is_empty() {
            buffer_start = current_offset;
        }
        let buf_len = buffer.chars().count();
        if buf_len + seg_len <= config.target_chars || buffer.is_empty() {
            buffer.push_str(&segment);
        } else {
            flush(
                &mut chunks,
                &mut buffer,
                &mut buffer_start,
                source_id,
                config,
                hlc_generator,
                now_millis,
            );
            if buffer.is_empty() {
                buffer_start = current_offset;
            }
            buffer.push_str(&segment);
        }
        current_offset += seg_len;
        if buffer.chars().count() >= config.target_chars {
            flush(
                &mut chunks,
                &mut buffer,
                &mut buffer_start,
                source_id,
                config,
                hlc_generator,
                now_millis,
            );
        }
    }

    if !buffer.is_empty() {
        let hlc = hlc_generator.send(now_millis);
        chunks.push(Chunk::content_addressed(
            source_id,
            buffer_start,
            buffer.chars().count(),
            buffer.clone(),
            hlc,
            BTreeMap::new(),
        ));
    }
    chunks
}

fn flush(
    chunks: &mut Vec<Chunk>,
    buffer: &mut String,
    buffer_start: &mut usize,
    source_id: &str,
    config: ChunkerConfiguration,
    hlc_generator: &mut HLCGenerator,
    now_millis: i64,
) {
    if buffer.is_empty() {
        return;
    }
    let buf_len = buffer.chars().count();
    let hlc = hlc_generator.send(now_millis);
    chunks.push(Chunk::content_addressed(
        source_id,
        *buffer_start,
        buf_len,
        buffer.clone(),
        hlc,
        BTreeMap::new(),
    ));
    // Begin next buffer at (current end) minus overlap.
    let overlap = config.overlap_chars.min(buf_len);
    let next_start = *buffer_start + buf_len - overlap;
    if overlap > 0 {
        let drop_count = buf_len - overlap;
        let new_buffer: String = buffer.chars().skip(drop_count).collect();
        *buffer = new_buffer;
    } else {
        buffer.clear();
    }
    *buffer_start = next_start;
}

/// Convenience wrapper around `chunk` for callers without their
/// own HLC generator. Builds an in-place generator with `node_id`
/// equal to 1.
pub fn chunk_with_default_hlc(
    text: &str,
    source_id: &str,
    config: ChunkerConfiguration,
    now_millis: i64,
) -> Vec<Chunk> {
    let mut hlc_generator = HLCGenerator::new(1);
    chunk(text, source_id, config, &mut hlc_generator, now_millis)
}
