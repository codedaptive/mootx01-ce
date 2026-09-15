//! LSA-specific seam tests, extracted from `trainable_embedding_basis_tests.rs`.
//!
//! Gated on the `lsa` feature (ruling 2026-09-07). Asserts that the LSA seam
//! — `train_on_corpus`, `serialize_basis`, `reconstruct` — produces bit-identical
//! results to the 6a-i Swift canonical basis blob, and that the counts-seam
//! round-trips correctly.

use corpus_kit::{EmbeddingModelConfig, TrainableEmbeddingBasis};
use corpus_kit_providers::{LsaProvider, LSA_PROJECTION_SEED};
use serde::Deserialize;
use synapsekit::EmbeddingProvider;

mod basis_fixture;
use basis_fixture::decode_base64;

const LSA_FIXTURE: &[u8] = include_bytes!("../../Tests/SharedVectors/lsa_basis_blob.json");

/// LSA/NMF fixtures store the training corpus as raw document strings.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StringCorpusFixture {
    blob_base64: String,
    corpus: Vec<String>,
}

const COUNTS_CORPUS: &[&str] = &[
    "car engine drive road vehicle",
    "vehicle road transport car fuel",
    "engine fuel combustion power car",
    "dog bark run fetch animal",
    "animal run cat dog pet",
];

// ── §1 Seam honesty: train_on_corpus → serialize_basis == 6a-i Swift blob ──

#[test]
fn lsa_seam_matches_swift_blob_byte_for_byte() {
    let f: StringCorpusFixture =
        serde_json::from_slice(LSA_FIXTURE).expect("lsa_basis_blob.json valid");
    let text_refs: Vec<&str> = f.corpus.iter().map(String::as_str).collect();

    // rank=3, sweeps=30 — construction config matching the 6a-i fixture builder.
    // The shared fixture pins the historical 1.0 provider envelope
    // (mirrors the Swift twin's modelVersion: "1.0.0" pinning).
    let mut p = LsaProvider::with_parameters("lsa-v1", "1.0.0", 3, 30, LSA_PROJECTION_SEED);
    TrainableEmbeddingBasis::train_on_corpus(&mut p, &text_refs);
    let blob = TrainableEmbeddingBasis::serialize_basis(&p);
    assert_eq!(
        blob,
        decode_base64(&f.blob_base64),
        "LSA seam blob must be byte-identical to the 6a-i Swift canonical blob"
    );
}

// ── §2 EmbeddingModelConfig::reconstruct dispatch ──

#[test]
fn reconstruct_round_trips_lsa_embeddings() {
    let f: StringCorpusFixture =
        serde_json::from_slice(LSA_FIXTURE).expect("lsa_basis_blob.json valid");
    let text_refs: Vec<&str> = f.corpus.iter().map(String::as_str).collect();

    let mut trained = LsaProvider::new(3, 30, LSA_PROJECTION_SEED);
    TrainableEmbeddingBasis::train_on_corpus(&mut trained, &text_refs);
    let blob = TrainableEmbeddingBasis::serialize_basis(&trained);
    let trained_probe = trained.embed_float("car engine").unwrap();

    let model = EmbeddingModelConfig::Lsa {
        provider: Box::new(trained),
    };
    let restored = model.reconstruct(&blob).expect("reconstruct must succeed");
    let restored_probe = restored.embed_float("car engine").unwrap();

    let a: Vec<u32> = trained_probe.iter().map(|x| x.to_bits()).collect();
    let b: Vec<u32> = restored_probe.iter().map(|x| x.to_bits()).collect();
    assert_eq!(a, b, "reconstructed LSA embeddings must match the trained provider");
}

// ── §3 Counts seam round-trip ──

#[test]
fn lsa_counts_seam_round_trips() {
    let mut trained = LsaProvider::new(3, 30, LSA_PROJECTION_SEED);
    let mut fresh = LsaProvider::new(3, 30, LSA_PROJECTION_SEED);
    for chunk in COUNTS_CORPUS {
        trained.add_to_counts(chunk);
    }
    let vocab = trained.counts_vocabulary_size();
    assert!(vocab > 0, "add_to_counts must grow the maintained vocabulary");
    let blob = trained.serialize_counts();
    fresh
        .restore_counts(&blob)
        .expect("restore_counts must accept a well-formed counts blob");
    assert_eq!(
        fresh.counts_vocabulary_size(),
        vocab,
        "restored maintained vocabulary size must match the source"
    );
    assert!(
        fresh.restore_counts(&blob[..blob.len() / 2]).is_err(),
        "truncated counts blob must error"
    );
}

// ── §4 Lightweight anchor tracks document count ──

/// The lightweight LSA anchor grows vocab + document count WITHOUT retaining
/// the per-document TF rows (it bounds maintained state to O(vocab)). Document
/// count must equal the number of non-empty chunks folded.
#[test]
fn lsa_anchor_tracks_document_count() {
    let mut lsa = LsaProvider::new(3, 30, LSA_PROJECTION_SEED);
    for chunk in COUNTS_CORPUS {
        lsa.add_to_counts(chunk);
    }
    assert_eq!(
        lsa.document_count(),
        COUNTS_CORPUS.len(),
        "anchor must bump document_count once per non-empty chunk"
    );
}
