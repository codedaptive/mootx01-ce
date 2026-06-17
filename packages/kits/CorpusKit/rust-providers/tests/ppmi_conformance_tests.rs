//! Cross-language bit-identity gate for `PpmiProvider` (ADR-010 Decision B, signal #3).
//!
//! Reads the canonical fixture emitted by the Swift leg:
//!   `Tests/SharedVectors/ppmi_canonical_vectors.json`
//! Swift is the canonical source; Rust deserializes the same JSON and
//! asserts bit-for-bit equality on:
//!   - Raw (unnormalised) PPMI context vector float-bit patterns for probe terms.
//!   - Document embedding Engram blocks (block0..block3) for probe texts.
//!   - Float-vector bit patterns for probe texts.
//!
//! Any divergence means the PPMI weight computation, the index vector
//! machinery, the L2 normalisation, or the FloatSimHash projection has
//! drifted between ports.  Fix the port that diverged, not the test.
//!
//! ## Why inline binary rather than a runtime path
//!
//! The fixture is embedded at compile time with `include_bytes!` — the same
//! pattern used by `random_indexing_tests.rs` and `embedding_conformance_tests.rs`.
//! This removes any runtime path dependency and makes the test hermetic.

use corpus_kit_providers::{PpmiProvider, PPMI_DIMENSION, PPMI_PROJECTION_SEED, PPMI_WINDOW};
use serde::Deserialize;
use vectorkit::EmbeddingProvider;

// The canonical file is emitted by the Swift leg's `emitCanonicalIfRequested`
// test into Tests/SharedVectors/. Embedded at compile time — two directories
// up from rust-providers/tests/.
const FIXTURE: &[u8] =
    include_bytes!("../../Tests/SharedVectors/ppmi_canonical_vectors.json");

// MARK: - Canonical file model (mirrors Swift Codable structs)

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PpmiVectorEntry {
    term: String,
    float_bits: Vec<u32>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DocumentEmbeddingEntry {
    text: String,
    block0: u64,
    block1: u64,
    block2: u64,
    block3: u64,
    float_bits: Vec<u32>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CanonicalFile {
    ppmi_d: usize,
    ppmi_k: usize,
    ppmi_w: usize,
    projection_seed: u64,
    corpus: Vec<Vec<String>>,
    ppmi_vectors: Vec<PpmiVectorEntry>,
    document_embeddings: Vec<DocumentEmbeddingEntry>,
}

// MARK: - Load the fixture once

fn load_fixture() -> CanonicalFile {
    serde_json::from_slice(FIXTURE).expect("ppmi_canonical_vectors.json must be valid JSON")
}

/// Build and finalize a provider trained on the canonical corpus from the fixture.
fn build_from_fixture(f: &CanonicalFile) -> PpmiProvider {
    let mut provider = PpmiProvider::new();
    for doc in &f.corpus {
        let terms: Vec<&str> = doc.iter().map(String::as_str).collect();
        provider.train(&terms, PPMI_WINDOW);
    }
    provider.finalize();
    provider
}

// MARK: - Parameter conformance

/// The fixture parameters must match the Rust constants.
///
/// If this test fails, either the constants in `ppmi.rs` have drifted from the
/// Swift port, or the fixture was emitted with different parameters.
/// Regenerate the fixture after any intentional parameter change.
#[test]
fn canonical_parameters_match_constants() {
    let f = load_fixture();
    assert_eq!(f.ppmi_d, PPMI_DIMENSION, "fixture ppmiD must match PPMI_DIMENSION");
    assert_eq!(f.ppmi_w, PPMI_WINDOW, "fixture ppmiW must match PPMI_WINDOW");
    assert_eq!(
        f.projection_seed, PPMI_PROJECTION_SEED,
        "fixture projectionSeed must match PPMI_PROJECTION_SEED"
    );
    // ppmi_k is not a named Rust constant (it is a property of ri_index_vector
    // which the PPMI provider delegates to). Verify it matches the RI constant.
    use corpus_kit_providers::PPMI_NONZEROS;
    assert_eq!(f.ppmi_k, PPMI_NONZEROS, "fixture ppmiK must match PPMI_NONZEROS");
}

// MARK: - PPMI context vector conformance

/// After training and finalizing on the canonical corpus, verify that the
/// Rust port produces bit-identical raw PPMI context vectors to the Swift port.
///
/// Comparison is at the IEEE-754 bit level (u32 bit patterns) to catch any
/// floating-point accumulation differences between ports.
#[test]
fn canonical_ppmi_vectors_match_swift() {
    let f = load_fixture();
    let provider = build_from_fixture(&f);

    for entry in &f.ppmi_vectors {
        let cv = provider
            .ppmi_vector_for_term(&entry.term)
            .unwrap_or_else(|| {
                panic!(
                    "'{}' must be in vocab after training on canonical corpus",
                    entry.term
                )
            });

        assert_eq!(
            cv.len(),
            entry.float_bits.len(),
            "PPMI vector length mismatch for term '{}': Rust={} Swift={}",
            entry.term, cv.len(), entry.float_bits.len()
        );

        let rust_bits: Vec<u32> = cv.iter().map(|&x| x.to_bits()).collect();
        assert_eq!(
            rust_bits, entry.float_bits,
            "PPMI vector float bits mismatch for term '{}'\n\
             Rust (first 16): {:?}\n\
             Swift (first 16): {:?}",
            entry.term,
            &rust_bits[..rust_bits.len().min(16)],
            &entry.float_bits[..entry.float_bits.len().min(16)]
        );
    }
}

// MARK: - Document embedding conformance

/// After training and finalizing on the canonical corpus, verify that the
/// Rust port produces bit-identical document embeddings (Engram blocks +
/// float vector bit patterns) for the canonical probe texts.
///
/// This is the primary cross-port gate: any divergence in PPMI weight
/// computation, L2 normalisation, or FloatSimHash projection will be caught here.
#[test]
fn canonical_document_embeddings_match_swift() {
    let f = load_fixture();
    let provider = build_from_fixture(&f);

    for entry in &f.document_embeddings {
        // --- Binary Engram lane ---
        let engram = provider
            .embed(&entry.text)
            .unwrap_or_else(|e| panic!("embed failed for '{}': {e:?}", entry.text));

        assert_eq!(
            engram.block0, entry.block0,
            "Engram block0 mismatch for text '{}': Rust={} Swift={}",
            entry.text, engram.block0, entry.block0
        );
        assert_eq!(
            engram.block1, entry.block1,
            "Engram block1 mismatch for text '{}': Rust={} Swift={}",
            entry.text, engram.block1, entry.block1
        );
        assert_eq!(
            engram.block2, entry.block2,
            "Engram block2 mismatch for text '{}': Rust={} Swift={}",
            entry.text, engram.block2, entry.block2
        );
        assert_eq!(
            engram.block3, entry.block3,
            "Engram block3 mismatch for text '{}': Rust={} Swift={}",
            entry.text, engram.block3, entry.block3
        );

        // --- Float lane ---
        let floats = provider
            .embed_float(&entry.text)
            .unwrap_or_else(|e| panic!("embed_float failed for '{}': {e:?}", entry.text));

        assert_eq!(
            floats.len(),
            entry.float_bits.len(),
            "float vector length mismatch for text '{}'",
            entry.text
        );

        let rust_bits: Vec<u32> = floats.iter().map(|&x| x.to_bits()).collect();
        assert_eq!(
            rust_bits, entry.float_bits,
            "float vector bit mismatch for text '{}'\n\
             Rust (first 8): {:?}\n\
             Swift (first 8): {:?}",
            entry.text,
            &rust_bits[..rust_bits.len().min(8)],
            &entry.float_bits[..entry.float_bits.len().min(8)]
        );
    }
}
