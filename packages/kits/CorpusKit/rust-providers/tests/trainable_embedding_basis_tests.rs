//! Mission 6a-ii-α: cross-port conformance for the trainable-basis seam.
//!
//! Asserts that driving training THROUGH the seam — `train_on_corpus` then
//! `serialize_basis` (the `TrainableEmbeddingBasis` trait) — reproduces the
//! 6a-i committed Swift canonical basis blob BYTE-FOR-BYTE, for RI/PPMI/LSA/NMF.
//! Swift is the canonical source; this Rust leg asserts byte-identity. This is
//! the proof that the seam routes training identically to the direct 6a-i API
//! on both ports, so the same trained state is produced wherever the seam runs.
//!
//! Also exercises `EmbeddingModelConfig::reconstruct`: the trainable cases
//! round-trip a basis blob to embeddings identical to the trained provider's,
//! and the non-trainable cases (Deterministic / FDC) return
//! `CorpusKitError::NotTrainable` rather than panicking. Named-model cases
//! (MiniLM/MPNet/EmbeddingGemma) are not exercised in this file.
//!
//! Fixtures are embedded with `include_bytes!` (hermetic, no I/O at test time);
//! base64 is decoded by the shared inline decoder in `basis_fixture` (C-1: no
//! external crate).

use corpus_kit::{CorpusKitError, EmbeddingModelConfig, TrainableEmbeddingBasis};
use corpus_kit_providers::{
    LsaProvider, NmfProvider, PpmiProvider, RandomIndexingProvider, LSA_PROJECTION_SEED,
    NMF_FACTORIZATION_SEED, NMF_PROJECTION_SEED, PPMI_PROJECTION_SEED, RI_PROJECTION_SEED,
};
use serde::Deserialize;
use vectorkit::EmbeddingProvider;

mod basis_fixture;
use basis_fixture::decode_base64;

const RI_FIXTURE: &[u8] = include_bytes!("../../Tests/SharedVectors/ri_basis_blob.json");
const PPMI_FIXTURE: &[u8] = include_bytes!("../../Tests/SharedVectors/ppmi_basis_blob.json");
const LSA_FIXTURE: &[u8] = include_bytes!("../../Tests/SharedVectors/lsa_basis_blob.json");
const NMF_FIXTURE: &[u8] = include_bytes!("../../Tests/SharedVectors/nmf_basis_blob.json");

/// RI/PPMI fixtures store the training corpus as token arrays.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ArrayCorpusFixture {
    blob_base64: String,
    corpus: Vec<Vec<String>>,
}

/// LSA/NMF fixtures store the training corpus as raw document strings.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StringCorpusFixture {
    blob_base64: String,
    corpus: Vec<String>,
}

// ── §1 Seam honesty: train_on_corpus → serialize_basis == 6a-i Swift blob ──

#[test]
fn ri_seam_matches_swift_blob_byte_for_byte() {
    let f: ArrayCorpusFixture =
        serde_json::from_slice(RI_FIXTURE).expect("ri_basis_blob.json valid");
    // RI fixture corpus is token arrays; join to raw texts. default_keyword_tokens
    // tokenizes these back to the identical arrays (space-separated ASCII words).
    let texts: Vec<String> = f.corpus.iter().map(|d| d.join(" ")).collect();
    let text_refs: Vec<&str> = texts.iter().map(String::as_str).collect();

    // The shared fixture pins the historical 1.0 provider envelope
    // (mirrors the Swift twin's modelVersion: "1.0.0" pinning).
    let mut p = RandomIndexingProvider::with_parameters(
        "random-indexing-v1", "1.0.0", RI_PROJECTION_SEED);
    TrainableEmbeddingBasis::train_on_corpus(&mut p, &text_refs);
    let blob = TrainableEmbeddingBasis::serialize_basis(&p);
    assert_eq!(
        blob,
        decode_base64(&f.blob_base64),
        "RI seam blob must be byte-identical to the 6a-i Swift canonical blob"
    );
}

#[test]
fn ppmi_seam_matches_swift_blob_byte_for_byte() {
    let f: ArrayCorpusFixture =
        serde_json::from_slice(PPMI_FIXTURE).expect("ppmi_basis_blob.json valid");
    let texts: Vec<String> = f.corpus.iter().map(|d| d.join(" ")).collect();
    let text_refs: Vec<&str> = texts.iter().map(String::as_str).collect();

    // The shared fixture pins the historical 1.0 provider envelope
    // (mirrors the Swift twin's modelVersion: "1.0.0" pinning).
    let mut p = PpmiProvider::with_parameters("ppmi-v1", "1.0.0", PPMI_PROJECTION_SEED);
    TrainableEmbeddingBasis::train_on_corpus(&mut p, &text_refs);
    let blob = TrainableEmbeddingBasis::serialize_basis(&p);
    assert_eq!(
        blob,
        decode_base64(&f.blob_base64),
        "PPMI seam blob must be byte-identical to the 6a-i Swift canonical blob"
    );
}

#[test]
fn lsa_seam_matches_swift_blob_byte_for_byte() {
    let f: StringCorpusFixture =
        serde_json::from_slice(LSA_FIXTURE).expect("lsa_basis_blob.json valid");
    let text_refs: Vec<&str> = f.corpus.iter().map(String::as_str).collect();

    // rank=3, sweeps=30 — construction config matching the 6a-i fixture builder.
    // train_on_corpus governs only the train+finalize SEQUENCE.
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

#[test]
fn nmf_seam_matches_swift_blob_byte_for_byte() {
    let f: StringCorpusFixture =
        serde_json::from_slice(NMF_FIXTURE).expect("nmf_basis_blob.json valid");
    let text_refs: Vec<&str> = f.corpus.iter().map(String::as_str).collect();

    // rank=3, iterations=100 — construction config matching the 6a-i fixture builder.
    // The shared fixture pins the historical 1.0 provider envelope
    // (mirrors the Swift twin's modelVersion: "1.0.0" pinning).
    let mut p = NmfProvider::with_parameters(
        "nmf-v1", "1.0.0", 3, 100, NMF_FACTORIZATION_SEED, NMF_PROJECTION_SEED);
    TrainableEmbeddingBasis::train_on_corpus(&mut p, &text_refs);
    let blob = TrainableEmbeddingBasis::serialize_basis(&p);
    assert_eq!(
        blob,
        decode_base64(&f.blob_base64),
        "NMF seam blob must be byte-identical to the 6a-i Swift canonical blob"
    );
}

// ── §2 EmbeddingModelConfig::reconstruct dispatch ──

#[test]
fn reconstruct_round_trips_ri_embeddings() {
    let f: ArrayCorpusFixture =
        serde_json::from_slice(RI_FIXTURE).expect("ri_basis_blob.json valid");
    let texts: Vec<String> = f.corpus.iter().map(|d| d.join(" ")).collect();
    let text_refs: Vec<&str> = texts.iter().map(String::as_str).collect();

    let mut trained = RandomIndexingProvider::new();
    TrainableEmbeddingBasis::train_on_corpus(&mut trained, &text_refs);
    let blob = TrainableEmbeddingBasis::serialize_basis(&trained);
    let trained_probe = trained.embed_float("car engine").unwrap();

    let model = EmbeddingModelConfig::RandomIndexing {
        provider: Box::new(trained),
    };
    let restored = model.reconstruct(&blob).expect("reconstruct must succeed");
    let restored_probe = restored.embed_float("car engine").unwrap();

    let a: Vec<u32> = trained_probe.iter().map(|x| x.to_bits()).collect();
    let b: Vec<u32> = restored_probe.iter().map(|x| x.to_bits()).collect();
    assert_eq!(a, b, "reconstructed RI embeddings must match the trained provider");
}

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

#[test]
fn reconstruct_non_trainable_returns_not_trainable() {
    // The Ok payload is `Box<dyn EmbeddingProvider>` (not Debug), so assert on
    // the Err arm directly rather than debug-formatting the whole Result.

    // Deterministic: no trainable basis.
    match EmbeddingModelConfig::Deterministic.reconstruct(&[0, 1, 2, 3]) {
        Err(CorpusKitError::NotTrainable(_)) => {}
        Err(other) => panic!("expected NotTrainable for Deterministic, got {other:?}"),
        Ok(_) => panic!("expected NotTrainable for Deterministic, got Ok"),
    }
    // FDC: carries an embedding provider but is stateless — not trainable.
    let fdc = EmbeddingModelConfig::Fdc {
        provider: Box::new(corpus_kit_providers::FDCProvider::default_provider()),
    };
    match fdc.reconstruct(&[0, 1, 2, 3]) {
        Err(CorpusKitError::NotTrainable(_)) => {}
        Err(other) => panic!("expected NotTrainable for FDC, got {other:?}"),
        Ok(_) => panic!("expected NotTrainable for FDC, got Ok"),
    }
}

// ── §3 capability detection ──

#[test]
fn is_trainable_flags() {
    let ri = EmbeddingModelConfig::RandomIndexing {
        provider: Box::new(RandomIndexingProvider::new()),
    };
    assert!(ri.is_trainable());

    let ppmi = EmbeddingModelConfig::Ppmi {
        provider: Box::new(PpmiProvider::new()),
    };
    assert!(ppmi.is_trainable());

    let lsa = EmbeddingModelConfig::Lsa {
        provider: Box::new(LsaProvider::new(3, 30, LSA_PROJECTION_SEED)),
    };
    assert!(lsa.is_trainable());

    let nmf = EmbeddingModelConfig::Nmf {
        provider: Box::new(NmfProvider::new(3, 100, NMF_FACTORIZATION_SEED, NMF_PROJECTION_SEED)),
    };
    assert!(nmf.is_trainable());

    assert!(!EmbeddingModelConfig::Deterministic.is_trainable());
    let fdc = EmbeddingModelConfig::Fdc {
        provider: Box::new(corpus_kit_providers::FDCProvider::default_provider()),
    };
    assert!(!fdc.is_trainable());
}

// ── §4 Maintained-counts seam (incremental-counts change set, P3) ──
//
// Drives the counts seam THROUGH the trait: `add_to_counts` per chunk grows the
// maintained vocabulary anchor, and `serialize_counts` → `restore_counts` resumes
// that anchor in a fresh provider. Each conformer routes the uniform methods to
// its own accumulation (RI/PPMI fold term sequences; LSA/NMF fold documents via
// the lightweight anchor). The Swift twin
// (`TrainableEmbeddingBasisTests.swift`, "counts seam") asserts the same shape.

const COUNTS_CORPUS: &[&str] = &[
    "car engine drive road vehicle",
    "vehicle road transport car fuel",
    "engine fuel combustion power car",
    "dog bark run fetch animal",
    "animal run cat dog pet",
];

/// Fold the corpus through `add_to_counts`, then assert the anchor survives a
/// `serialize_counts` → `restore_counts` round trip on a fresh provider.
fn assert_counts_seam_round_trips<P>(mut trained: P, mut fresh: P)
where
    P: TrainableEmbeddingBasis,
{
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

    // A truncated blob is rejected, never a panic.
    assert!(
        fresh.restore_counts(&blob[..blob.len() / 2]).is_err(),
        "truncated counts blob must error"
    );
}

#[test]
fn ri_counts_seam_round_trips() {
    assert_counts_seam_round_trips(
        RandomIndexingProvider::new(),
        RandomIndexingProvider::new(),
    );
}

#[test]
fn ppmi_counts_seam_round_trips() {
    assert_counts_seam_round_trips(PpmiProvider::new(), PpmiProvider::new());
}

#[test]
fn lsa_counts_seam_round_trips() {
    assert_counts_seam_round_trips(
        LsaProvider::new(3, 30, LSA_PROJECTION_SEED),
        LsaProvider::new(3, 30, LSA_PROJECTION_SEED),
    );
}

#[test]
fn nmf_counts_seam_round_trips() {
    assert_counts_seam_round_trips(
        NmfProvider::new(3, 100, NMF_FACTORIZATION_SEED, NMF_PROJECTION_SEED),
        NmfProvider::new(3, 100, NMF_FACTORIZATION_SEED, NMF_PROJECTION_SEED),
    );
}

/// The lightweight LSA/NMF anchor grows vocab + document count WITHOUT retaining
/// the per-document TF rows (it bounds maintained state to O(vocab)). Document
/// count must equal the number of non-empty chunks folded.
#[test]
fn lsa_nmf_anchor_tracks_document_count() {
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
