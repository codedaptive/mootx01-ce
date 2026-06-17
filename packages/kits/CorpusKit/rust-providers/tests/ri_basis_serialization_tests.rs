//! Cross-port basis-serialization conformance gate for `RandomIndexingProvider`
//! (mission 6a-i).
//!
//! Reads the canonical fixture emitted by the Swift leg (the canonical source):
//!   `Tests/SharedVectors/ri_basis_blob.json`
//! and asserts:
//!   (a) `serialize_basis()` of the SAME trained state produces bytes
//!       byte-identical to the Swift-emitted blob, AND
//!   (b) `from_serialized_basis(blob)` reconstructs a provider whose
//!       embeddings reproduce the fixture's pinned bit patterns exactly.
//!
//! Any divergence means the byte format, the map key ordering, the float
//! bit-pattern encoding, or the embed pipeline has drifted between ports.
//! Fix the port that diverged, not the test.
//!
//! The fixture is embedded at compile time with `include_bytes!` — the same
//! hermetic pattern used by the existing conformance suites. base64 is decoded
//! by a tiny inline decoder (no external crate — C-1 doctrine).

use corpus_kit_providers::RandomIndexingProvider;
use serde::Deserialize;
use vectorkit::EmbeddingProvider;

mod basis_fixture;
use basis_fixture::{decode_base64, BasisEmbeddingEntry};

const FIXTURE: &[u8] = include_bytes!("../../Tests/SharedVectors/ri_basis_blob.json");

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RIBasisFixture {
    blob_base64: String,
    corpus: Vec<Vec<String>>,
    embeddings: Vec<BasisEmbeddingEntry>,
}

fn load() -> RIBasisFixture {
    serde_json::from_slice(FIXTURE).expect("ri_basis_blob.json must be valid JSON")
}

/// Train an RI provider on the fixture corpus (the canonical training state).
fn trained_from_fixture(f: &RIBasisFixture) -> RandomIndexingProvider {
    use corpus_kit_providers::RI_WINDOW;
    let mut p = RandomIndexingProvider::new();
    for doc in &f.corpus {
        let terms: Vec<&str> = doc.iter().map(String::as_str).collect();
        p.train(&terms, RI_WINDOW);
    }
    p
}

#[test]
fn rust_serialize_matches_swift_blob_byte_for_byte() {
    let f = load();
    let expected = decode_base64(&f.blob_base64);
    let actual = trained_from_fixture(&f).serialize_basis();
    assert_eq!(
        actual.len(),
        expected.len(),
        "RI blob length mismatch: Rust={} Swift={}",
        actual.len(),
        expected.len()
    );
    assert_eq!(
        actual, expected,
        "RI serialize_basis() must be byte-identical to the Swift-emitted blob"
    );
}

#[test]
fn rust_deserialize_reproduces_fixture_embeddings() {
    let f = load();
    let blob = decode_base64(&f.blob_base64);
    let restored =
        RandomIndexingProvider::from_serialized_basis(&blob).expect("blob must deserialize");

    for entry in &f.embeddings {
        let floats = restored
            .embed_float(&entry.text)
            .expect("embed_float must not error");
        let bits: Vec<u32> = floats.iter().map(|x| x.to_bits()).collect();
        assert_eq!(
            bits, entry.float_bits,
            "float bits mismatch for text '{}'",
            entry.text
        );

        let engram = restored.embed(&entry.text).expect("embed must not error");
        assert_eq!(engram.block0, entry.block0, "block0 for '{}'", entry.text);
        assert_eq!(engram.block1, entry.block1, "block1 for '{}'", entry.text);
        assert_eq!(engram.block2, entry.block2, "block2 for '{}'", entry.text);
        assert_eq!(engram.block3, entry.block3, "block3 for '{}'", entry.text);
    }
}

#[test]
fn unknown_version_blob_is_rejected_not_panicked() {
    let f = load();
    let mut blob = decode_base64(&f.blob_base64);
    blob[4] = 0xFF; // corrupt the version byte
    use corpus_kit_providers::BasisCodecError;
    // RandomIndexingProvider is not Debug, so match the Result directly rather
    // than unwrap_err() (which would require the Ok type to be Debug).
    match RandomIndexingProvider::from_serialized_basis(&blob) {
        Err(BasisCodecError::UnsupportedVersion(_)) => {}
        Err(other) => panic!("expected UnsupportedVersion, got {other:?}"),
        Ok(_) => panic!("expected an error for an unknown format version"),
    }
}
