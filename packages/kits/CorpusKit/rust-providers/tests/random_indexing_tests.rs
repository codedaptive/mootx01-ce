//! Rust leg of the cross-language bit-identity gate for
//! `RandomIndexingProvider` (honest semantic fusion, signal #2).
//!
//! Reads the SAME canonical fixture the Swift leg emits:
//!   `Tests/SharedVectors/ri_canonical_vectors.json`
//! Swift is the canonical source; Rust deserializes the same JSON and
//! asserts bit-for-bit equality on:
//!   - Index vector nonzero positions and signs for probe terms.
//!   - Raw (unnormalised) context vector float-bit patterns after
//!     training on the pinned mini-corpus.
//!   - Document embedding Engram blocks (block0..block3) and
//!     float-vector bit patterns for probe texts.
//!
//! Any divergence in these assertions means the PRNG sequence, the FNV
//! seed, the context accumulation, the L2 normalisation, or the
//! FloatSimHash projection has drifted between ports. Fix the port that
//! diverged, not the test.
//!
//! ## Why inline binary rather than a runtime path
//!
//! The fixture is embedded at compile time with `include_bytes!` — the
//! same pattern used by `embedding_conformance_tests.rs` and the BM25
//! conformance test. This removes any runtime path dependency and makes
//! the test hermetic (it passes even when run from a different CWD).

use corpus_kit_providers::{
    RandomIndexingProvider, RI_DIMENSION, RI_NONZEROS, RI_PROJECTION_SEED, RI_WINDOW,
    ri_index_vector,
};
use serde::Deserialize;
use vectorkit::EmbeddingProvider;

// The canonical file is emitted by the Swift leg's
// `emitCanonicalIfRequested` test into Tests/SharedVectors/. Embedded
// at compile time — two directories up from rust-providers/tests/.
const FIXTURE: &[u8] =
    include_bytes!("../../Tests/SharedVectors/ri_canonical_vectors.json");

// MARK: - Canonical file model (mirrors Swift Codable structs)

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct IndexVectorEntry {
    term: String,
    nonzero_positions: Vec<usize>,
    signs: Vec<i32>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ContextVectorEntry {
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
    ri_d: usize,
    ri_k: usize,
    ri_w: usize,
    projection_seed: u64,
    corpus: Vec<Vec<String>>,
    index_vectors: Vec<IndexVectorEntry>,
    context_vectors: Vec<ContextVectorEntry>,
    document_embeddings: Vec<DocumentEmbeddingEntry>,
}

// MARK: - Load the fixture once (lazy initialization)

fn load_fixture() -> CanonicalFile {
    serde_json::from_slice(FIXTURE).expect("ri_canonical_vectors.json must be valid JSON")
}

// MARK: - Parameter conformance

/// The fixture parameters must match the Rust constants.
///
/// If this test fails, either the constants in `random_indexing.rs` have
/// drifted from the Swift port, or the fixture was emitted with different
/// parameters. Regenerate the fixture after any intentional parameter change.
#[test]
fn canonical_parameters_match_constants() {
    let f = load_fixture();
    assert_eq!(f.ri_d, RI_DIMENSION, "fixture riD must match RI_DIMENSION");
    assert_eq!(f.ri_k, RI_NONZEROS, "fixture riK must match RI_NONZEROS");
    assert_eq!(f.ri_w, RI_WINDOW, "fixture riW must match RI_WINDOW");
    assert_eq!(
        f.projection_seed, RI_PROJECTION_SEED,
        "fixture projectionSeed must match RI_PROJECTION_SEED"
    );
}

// MARK: - Index vector conformance

/// For each probe term in the fixture, verify that the Rust
/// `ri_index_vector` produces the same nonzero positions and signs as
/// the Swift port. Any divergence points to a FNV hash or SplitMix64
/// PRNG difference between ports.
#[test]
fn canonical_index_vectors_match_swift() {
    let f = load_fixture();
    for entry in &f.index_vectors {
        let v = ri_index_vector(&entry.term);

        // Collect Rust nonzero positions and signs.
        let rust_positions: Vec<usize> = v
            .iter()
            .enumerate()
            .filter(|(_, &x)| x != 0.0)
            .map(|(i, _)| i)
            .collect();
        let rust_signs: Vec<i32> = v
            .iter()
            .filter(|&&x| x != 0.0)
            .map(|&x| if x > 0.0 { 1 } else { -1 })
            .collect();

        assert_eq!(
            rust_positions, entry.nonzero_positions,
            "index vector positions mismatch for term '{}': Rust={rust_positions:?} Swift={:?}",
            entry.term, entry.nonzero_positions
        );
        assert_eq!(
            rust_signs, entry.signs,
            "index vector signs mismatch for term '{}': Rust={rust_signs:?} Swift={:?}",
            entry.term, entry.signs
        );
    }
}

// MARK: - Context vector conformance

/// After training on the canonical mini-corpus, verify that the Rust port
/// produces bit-identical raw context vectors to the Swift port.
///
/// Comparison is at the IEEE-754 bit level (UInt32 / u32 bit patterns)
/// to catch any floating-point accumulation differences. Both ports use
/// the same scalar accumulation loop so divergence would indicate a logic
/// error, not a platform transcendental difference.
#[test]
fn canonical_context_vectors_match_swift() {
    let f = load_fixture();

    // Build and train the provider on the canonical corpus.
    let mut provider = RandomIndexingProvider::new();
    for doc in &f.corpus {
        let terms: Vec<&str> = doc.iter().map(String::as_str).collect();
        provider.train(&terms, RI_WINDOW);
    }

    for entry in &f.context_vectors {
        let cv = provider
            .context_vector_for_term(&entry.term)
            .unwrap_or_else(|| panic!("'{}' must be in vocab after training on canonical corpus", entry.term));

        assert_eq!(
            cv.len(),
            entry.float_bits.len(),
            "context vector length mismatch for term '{}'",
            entry.term
        );

        let rust_bits: Vec<u32> = cv.iter().map(|&x| x.to_bits()).collect();
        assert_eq!(
            rust_bits, entry.float_bits,
            "context vector float bits mismatch for term '{}'\n\
             Rust (first 16): {:?}\n\
             Swift (first 16): {:?}",
            entry.term,
            &rust_bits[..rust_bits.len().min(16)],
            &entry.float_bits[..entry.float_bits.len().min(16)]
        );
    }
}

// MARK: - Document embedding conformance

/// After training on the canonical mini-corpus, verify that the Rust port
/// produces bit-identical document embeddings (Engram blocks + float vector
/// bit patterns) for the canonical probe texts.
///
/// This is the primary cross-port gate: any divergence in FNV seeding,
/// SplitMix64 draws, context accumulation, L2 normalisation, or
/// FloatSimHash projection will be caught here.
#[test]
fn canonical_document_embeddings_match_swift() {
    let f = load_fixture();

    let mut provider = RandomIndexingProvider::new();
    for doc in &f.corpus {
        let terms: Vec<&str> = doc.iter().map(String::as_str).collect();
        provider.train(&terms, RI_WINDOW);
    }

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

// MARK: - Additional behavioural tests (mirrors Swift §1–4)

#[test]
fn embed_empty_returns_zero_engram_conformance() {
    let provider = RandomIndexingProvider::new();
    use engram_lib::Engram;
    assert_eq!(provider.embed("").unwrap(), Engram::ZERO);
}

#[test]
fn semantic_relatedness_holds_after_training() {
    let corpus = vec![
        vec!["car", "engine", "drive", "road", "vehicle"],
        vec!["vehicle", "road", "transport", "car", "fuel"],
        vec!["engine", "fuel", "combustion", "power", "car"],
        vec!["dog", "bark", "run", "fetch", "animal"],
        vec!["animal", "run", "cat", "dog", "pet"],
    ];

    let mut provider = RandomIndexingProvider::new();
    for doc in &corpus {
        provider.train(doc, RI_WINDOW);
    }

    let car = provider.embed_float("car").unwrap();
    let vehicle = provider.embed_float("vehicle").unwrap();
    let dog = provider.embed_float("dog").unwrap();

    assert!(!car.is_empty() && !vehicle.is_empty() && !dog.is_empty());

    let car_vehicle_sim: f32 = car.iter().zip(vehicle.iter()).map(|(&a, &b)| a * b).sum();
    let car_dog_sim: f32 = car.iter().zip(dog.iter()).map(|(&a, &b)| a * b).sum();

    // car and vehicle share context (both appear with "road", "engine", etc.);
    // car and dog share no meaningful context in this corpus.
    assert!(
        car_vehicle_sim > car_dog_sim,
        "car↔vehicle ({car_vehicle_sim}) must be closer than car↔dog ({car_dog_sim})"
    );
}
