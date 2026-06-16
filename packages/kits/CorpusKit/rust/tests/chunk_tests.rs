// Tests for corpus-kit core types (Chunk, ScoredChunk, CorpusKitError).
// Uses substrate's HLC directly -- the Chunk struct embeds the
// substrate value, no flat-field decomposition.

use corpus_kit::{Chunk, CorpusKitError, ScoredChunk};
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
use substrate_types::hlc::HLC;
use uuid::Uuid;

#[test]
fn chunk_embeds_substrate_hlc_directly() {
    let hlc = HLC {
        physical_time: 1234,
        logical_count: 5,
        node_id: 7,
    };
    let mut metadata = BTreeMap::new();
    metadata.insert("source".into(), "test".into());
    let chunk = Chunk::new(
        Uuid::new_v4(),
        "src-1",
        0,
        12,
        "hello world!",
        hlc,
        metadata.clone(),
    );
    assert_eq!(chunk.hlc, hlc);
    assert_eq!(chunk.hlc.physical_time, 1234);
    assert_eq!(chunk.hlc.logical_count, 5);
    assert_eq!(chunk.hlc.node_id, 7);
    assert_eq!(chunk.metadata, metadata);
}

#[test]
fn scored_chunk_with_subscores() {
    let hlc = HLC {
        physical_time: 1,
        logical_count: 0,
        node_id: 1,
    };
    let chunk = Chunk::new(Uuid::new_v4(), "src-1", 0, 4, "test", hlc, BTreeMap::new());
    let scored = ScoredChunk::new(chunk.clone(), 0.5).with_subscores(Some(0.3), Some(0.2));
    assert_eq!(scored.score, 0.5);
    assert_eq!(scored.vector_score, Some(0.3));
    assert_eq!(scored.keyword_score, Some(0.2));
}

#[test]
fn error_display_carries_message() {
    let e = CorpusKitError::EncodingFailure("oops".into());
    assert_eq!(format!("{}", e), "encoding failure: oops");
    let e2 = CorpusKitError::StoreUnavailable("db down".into());
    assert_eq!(format!("{}", e2), "store unavailable: db down");
}

#[test]
fn derive_id_matches_cross_language_ground_truth() {
    // RFC 4122 v5 UUIDs computed by the reference (Python uuid5 /
    // Swift deriveID) over the same namespace and name encoding.
    // Asserting the same literals here and in the Swift parity test
    // guarantees byte-identity across the ports by construction.
    assert_eq!(
        Chunk::derive_id("doc-A", 0, "hello world").to_string(),
        "e12ecb90-0ba9-588d-8d83-c0266f6aa2d5"
    );
    assert_eq!(
        Chunk::derive_id("doc-A", 800, "second").to_string(),
        "6f3a935a-cd10-5083-b143-f330be4d81da"
    );
    assert_eq!(
        Chunk::derive_id("src-E", 0, "original").to_string(),
        "dc121d31-5fec-5404-9208-01a11d044191"
    );
}

#[test]
fn derive_id_is_content_sensitive() {
    assert_ne!(
        Chunk::derive_id("doc-A", 0, "x"),
        Chunk::derive_id("doc-A", 1, "x")
    );
    assert_ne!(
        Chunk::derive_id("doc-A", 0, "x"),
        Chunk::derive_id("doc-A", 0, "y")
    );
}
