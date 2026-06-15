// Tests for the Chunker.

use corpus_kit::{chunk, ChunkerConfiguration};
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

#[test]
fn chunker_short_input_is_one_chunk() {
    let mut hlc = HLCGenerator::new(1);
    let config = ChunkerConfiguration::new(800, 100, true);
    let chunks = chunk("Hello world.", "src-1", config, &mut hlc, 1_000);
    assert_eq!(chunks.len(), 1);
    assert_eq!(chunks[0].source_id, "src-1");
    assert_eq!(chunks[0].start_offset, 0);
    assert_eq!(chunks[0].text, "Hello world.");
}

#[test]
fn chunker_splits_when_target_exceeded() {
    // Three sentences of ~40 chars each; target 60 forces splits.
    let text =
        "Alpha sentence number one. Bravo sentence number two. Charlie sentence number three.";
    let mut hlc = HLCGenerator::new(1);
    let config = ChunkerConfiguration::new(60, 10, true);
    let chunks = chunk(text, "src-2", config, &mut hlc, 1_000);
    assert!(
        chunks.len() >= 2,
        "expected at least 2 chunks, got {}",
        chunks.len()
    );
    // Every chunk should be non-empty and carry the source id.
    for c in &chunks {
        assert!(!c.text.is_empty());
        assert_eq!(c.source_id, "src-2");
    }
}

#[test]
fn chunker_respects_sentence_disabled() {
    let text = "no sentence boundaries here just one giant line";
    let mut hlc = HLCGenerator::new(1);
    let config = ChunkerConfiguration::new(20, 0, false);
    let chunks = chunk(text, "src-3", config, &mut hlc, 1_000);
    // With respect_sentences=false the whole text is one segment;
    // since buf_len + seg_len <= target check only triggers on
    // buffer.is_empty path, the entire input lands in one chunk.
    assert_eq!(chunks.len(), 1);
    assert_eq!(chunks[0].text, text);
}

#[test]
fn chunker_hlc_advances_per_chunk() {
    let text = "First. Second. Third. Fourth. Fifth.";
    let mut hlc = HLCGenerator::new(1);
    let config = ChunkerConfiguration::new(10, 2, true);
    let chunks = chunk(text, "src-4", config, &mut hlc, 1_000);
    assert!(chunks.len() >= 2);
    // HLCs should be monotonically non-decreasing on physical time
    // or strictly increasing on logical count when physical_time
    // ties (deterministic per the HLCGenerator contract).
    for i in 1..chunks.len() {
        let prev = chunks[i - 1].hlc;
        let cur = chunks[i].hlc;
        let prev_key = (prev.physical_time, prev.logical_count);
        let cur_key = (cur.physical_time, cur.logical_count);
        assert!(
            cur_key >= prev_key,
            "HLCs must not regress: {:?} -> {:?}",
            prev_key,
            cur_key
        );
    }
}

#[test]
fn chunker_empty_input_emits_no_chunks() {
    let mut hlc = HLCGenerator::new(1);
    let config = ChunkerConfiguration::default();
    let chunks = chunk("", "src-5", config, &mut hlc, 1_000);
    assert!(chunks.is_empty());
}
