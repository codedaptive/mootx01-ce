//! Cross-language bit-identity gate for `FDCProvider` (honest semantic fusion, signal #5).
//!
//! Reads the canonical fixture emitted by the Swift leg:
//!   `Tests/SharedVectors/fdc_canonical_vectors.json`
//! Swift is the canonical source; Rust deserializes the same JSON and
//! asserts bit-for-bit equality on:
//!   - Node-vector float-bit patterns for 16 probe FDC codes.
//!   - Embedding Engram blocks (block0..block3) for 8 probe texts.
//!   - Float-vector bit patterns for probe texts.
//!
//! Any divergence means the FNV-1a seed, SplitMix64 advance, LCG draw,
//! l2_normalize, or float_simhash::project has drifted between ports.
//! Fix the port that diverged, not the test.
//!
//! ## Why inline binary rather than a runtime path
//!
//! The fixture is embedded at compile time with `include_bytes!` — the same
//! pattern used by `ppmi_conformance_tests.rs`, `random_indexing_tests.rs`,
//! and `embedding_conformance_tests.rs`. This removes any runtime path
//! dependency and makes the test hermetic.

use corpus_kit_providers::{fdc_node_vector, FDCProvider, FDC_DIMENSION, FDC_PROJECTION_SEED};
use serde::Deserialize;
use vectorkit::EmbeddingProvider;

// The canonical file is emitted by the Swift leg's `FdcConformanceTests` test
// into Tests/SharedVectors/. Embedded at compile time — two directories up
// from rust-providers/tests/.
const FIXTURE: &[u8] =
    include_bytes!("../../Tests/SharedVectors/fdc_canonical_vectors.json");

// MARK: - Canonical file model (mirrors Swift Codable structs in FdcProviderTests.swift)

/// One probe FDC code and its expected node-vector float bit patterns.
/// Mirrors Swift `FdcNodeVectorEntry`.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NodeVectorEntry {
    code: String,
    float_bits: Vec<u32>,
}

/// One probe text and its expected embedding outputs.
/// Mirrors Swift `FdcEmbeddingEntry`.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EmbeddingVectorEntry {
    text: String,
    block0: u64,
    block1: u64,
    block2: u64,
    block3: u64,
    float_bits: Vec<u32>,
}

/// Root canonical file struct. Mirrors Swift `FdcCanonicalFile`.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CanonicalFile {
    node_vectors: Vec<NodeVectorEntry>,
    embedding_vectors: Vec<EmbeddingVectorEntry>,
}

// MARK: - Fixture loader

fn load_fixture() -> CanonicalFile {
    serde_json::from_slice(FIXTURE)
        .expect("fdc_canonical_vectors.json must be valid JSON with the expected shape")
}

// MARK: - Node vector conformance

/// For each probe FDC code, verify Rust produces the bit-identical float
/// vector as the Swift canonical source.
///
/// A mismatch here means one of:
///   - FNV-1a seed differs (different constants or byte interpretation).
///   - SplitMix64 step count differs (should be exactly 1 advance before LCG).
///   - LCG constants (multiplier or increment) differ.
///   - l2_normalize diverges from the Swift scalar kernel.
#[test]
fn node_vectors_bit_identical_to_swift() {
    let f = load_fixture();
    assert!(
        !f.node_vectors.is_empty(),
        "fixture must contain at least one node vector entry"
    );

    for entry in &f.node_vectors {
        let rust_vec = fdc_node_vector(&entry.code);

        assert_eq!(
            rust_vec.len(),
            FDC_DIMENSION,
            "node vector for {:?} must have dimension {FDC_DIMENSION}",
            entry.code
        );
        assert_eq!(
            rust_vec.len(),
            entry.float_bits.len(),
            "dimension mismatch between Rust ({}) and canonical ({}) for code {:?}",
            rust_vec.len(),
            entry.float_bits.len(),
            entry.code
        );

        for (i, (&rust_float, &canonical_bits)) in
            rust_vec.iter().zip(entry.float_bits.iter()).enumerate()
        {
            let rust_bits = rust_float.to_bits();
            let canonical_float = f32::from_bits(canonical_bits);
            let code = entry.code.as_str();
            assert_eq!(
                rust_bits,
                canonical_bits,
                "node vector BIT MISMATCH for code {code:?} at dimension {i}: \
                 Rust {rust_bits} (= {rust_float}) != canonical {canonical_bits} \
                 (= {canonical_float}). Check FNV64 seed, SplitMix64 step count, \
                 LCG constants, or l2_normalize.",
            );
        }
    }
}

// MARK: - Embedding vector conformance

/// For each probe text, verify Rust produces the bit-identical float vector
/// and bit-identical Engram blocks as the Swift canonical source.
///
/// An empty `float_bits` in the fixture means the Swift side returned `[]`
/// (UNRESOLVED text or empty input). The Rust side must also return `vec![]`
/// and `Engram::ZERO`.
///
/// A mismatch here (when non-empty) means the ancestor path computation,
/// level weights, accumulation, l2_normalize, or float_simhash::project
/// diverges between ports.
#[test]
fn embedding_vectors_bit_identical_to_swift() {
    let f = load_fixture();
    assert!(
        !f.embedding_vectors.is_empty(),
        "fixture must contain at least one embedding vector entry"
    );

    let provider = FDCProvider::default_provider();

    for entry in &f.embedding_vectors {
        // Float lane conformance.
        let rust_vec = provider
            .embed_float(&entry.text)
            .expect("embed_float must not return Err");

        if entry.float_bits.is_empty() {
            // Swift returned [] — Rust must also return [].
            assert!(
                rust_vec.is_empty(),
                "text {:?}: Swift returned empty float vector (UNRESOLVED) but \
                 Rust returned {} values",
                entry.text,
                rust_vec.len(),
            );
        } else {
            // Swift returned a real vector — Rust must match bit-for-bit.
            assert_eq!(
                rust_vec.len(),
                entry.float_bits.len(),
                "text {:?}: float vector length mismatch: Rust {} vs canonical {}",
                entry.text,
                rust_vec.len(),
                entry.float_bits.len(),
            );

            for (i, (&rust_float, &canonical_bits)) in
                rust_vec.iter().zip(entry.float_bits.iter()).enumerate()
            {
                let rust_bits = rust_float.to_bits();
                let canonical_float = f32::from_bits(canonical_bits);
                assert_eq!(
                    rust_bits,
                    canonical_bits,
                    "embedding float BIT MISMATCH for text {:?} at dimension {i}: \
                     Rust {rust_bits} (= {rust_float}) != canonical {canonical_bits} \
                     (= {canonical_float}). Check ancestor path, level weights, \
                     accumulation, l2_normalize, or float_simhash::project.",
                    entry.text,
                );
            }
        }

        // Engram (binary lane) conformance.
        let rust_engram = provider
            .embed(&entry.text)
            .expect("embed must not return Err");

        // block0..block3 must match.
        // Engram is a type alias for Fingerprint256 which has public
        // fields `block0`, `block1`, `block2`, `block3`.
        assert_eq!(
            rust_engram.block0,
            entry.block0,
            "text {:?}: Engram block0 mismatch: Rust {} vs canonical {}",
            entry.text,
            rust_engram.block0,
            entry.block0,
        );
        assert_eq!(
            rust_engram.block1,
            entry.block1,
            "text {:?}: Engram block1 mismatch: Rust {} vs canonical {}",
            entry.text,
            rust_engram.block1,
            entry.block1,
        );
        assert_eq!(
            rust_engram.block2,
            entry.block2,
            "text {:?}: Engram block2 mismatch: Rust {} vs canonical {}",
            entry.text,
            rust_engram.block2,
            entry.block2,
        );
        assert_eq!(
            rust_engram.block3,
            entry.block3,
            "text {:?}: Engram block3 mismatch: Rust {} vs canonical {}",
            entry.text,
            rust_engram.block3,
            entry.block3,
        );
    }
}

// MARK: - Parameter sanity

/// Verify the Rust FDC_DIMENSION and FDC_PROJECTION_SEED constants match
/// the Swift-emitted fixture. A constant drift is caught here without
/// having to inspect a failing bit comparison in the vector tests.
#[test]
fn constants_match_fixture_probe_lengths() {
    let f = load_fixture();

    // Every node vector entry must have exactly FDC_DIMENSION float bits.
    for entry in &f.node_vectors {
        assert_eq!(
            entry.float_bits.len(),
            FDC_DIMENSION,
            "fixture node vector for {:?} has {} bits but FDC_DIMENSION = {}; \
             constants have drifted",
            entry.code,
            entry.float_bits.len(),
            FDC_DIMENSION,
        );
    }

    // Every non-empty embedding float_bits must have exactly FDC_DIMENSION bits.
    for entry in &f.embedding_vectors {
        if !entry.float_bits.is_empty() {
            assert_eq!(
                entry.float_bits.len(),
                FDC_DIMENSION,
                "fixture embedding for {:?} has {} bits but FDC_DIMENSION = {}; \
                 constants have drifted",
                entry.text,
                entry.float_bits.len(),
                FDC_DIMENSION,
            );
        }
    }
}

/// Verify the projection seed constant is the expected magic value ("FDC_V1_P").
#[test]
fn projection_seed_ascii_magic() {
    // 0x4644_435F_5631_5F50 encodes "FDC_V1_P" in ASCII, big-endian.
    let expected: u64 = 0x4644_435F_5631_5F50;
    assert_eq!(
        FDC_PROJECTION_SEED, expected,
        "FDC_PROJECTION_SEED must be the 'FDC_V1_P' magic constant"
    );
}
