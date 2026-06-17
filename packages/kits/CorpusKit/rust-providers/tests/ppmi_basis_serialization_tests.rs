//! Cross-port basis-serialization conformance gate for `PpmiProvider`
//! (mission 6a-i). Mirrors the RI suite: byte-identical serialize + embed
//! reproduction from the Swift-emitted canonical fixture.

use corpus_kit_providers::{PpmiProvider, PPMI_WINDOW};
use serde::Deserialize;
use vectorkit::EmbeddingProvider;

mod basis_fixture;
use basis_fixture::{decode_base64, BasisEmbeddingEntry};

const FIXTURE: &[u8] = include_bytes!("../../Tests/SharedVectors/ppmi_basis_blob.json");

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PpmiBasisFixture {
    blob_base64: String,
    corpus: Vec<Vec<String>>,
    embeddings: Vec<BasisEmbeddingEntry>,
}

fn load() -> PpmiBasisFixture {
    serde_json::from_slice(FIXTURE).expect("ppmi_basis_blob.json must be valid JSON")
}

fn trained_from_fixture(f: &PpmiBasisFixture) -> PpmiProvider {
    let mut p = PpmiProvider::new();
    for doc in &f.corpus {
        let terms: Vec<&str> = doc.iter().map(String::as_str).collect();
        p.train(&terms, PPMI_WINDOW);
    }
    p.finalize();
    p
}

#[test]
fn rust_serialize_matches_swift_blob_byte_for_byte() {
    let f = load();
    let expected = decode_base64(&f.blob_base64);
    let actual = trained_from_fixture(&f).serialize_basis();
    assert_eq!(actual.len(), expected.len(), "PPMI blob length mismatch");
    assert_eq!(
        actual, expected,
        "PPMI serialize_basis() must be byte-identical to the Swift-emitted blob"
    );
}

#[test]
fn rust_deserialize_reproduces_fixture_embeddings() {
    let f = load();
    let blob = decode_base64(&f.blob_base64);
    let restored = PpmiProvider::from_serialized_basis(&blob).expect("blob must deserialize");
    for entry in &f.embeddings {
        let floats = restored.embed_float(&entry.text).expect("embed_float");
        let bits: Vec<u32> = floats.iter().map(|x| x.to_bits()).collect();
        assert_eq!(bits, entry.float_bits, "float bits for '{}'", entry.text);
        let engram = restored.embed(&entry.text).expect("embed");
        assert_eq!(engram.block0, entry.block0, "block0 for '{}'", entry.text);
        assert_eq!(engram.block1, entry.block1, "block1 for '{}'", entry.text);
        assert_eq!(engram.block2, entry.block2, "block2 for '{}'", entry.text);
        assert_eq!(engram.block3, entry.block3, "block3 for '{}'", entry.text);
    }
}
