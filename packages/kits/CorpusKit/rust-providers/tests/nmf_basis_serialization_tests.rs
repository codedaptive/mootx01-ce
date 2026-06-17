//! Cross-port basis-serialization conformance gate for `NmfProvider`
//! (mission 6a-i). Asserts byte-identical serialize, embed reproduction, AND
//! training-document-embedding reproduction (which exercises the H factor that
//! Rust now retains so its blob matches Swift's full-NMFFactorization layout).

use corpus_kit_providers::NmfProvider;
use serde::Deserialize;

mod basis_fixture;
use basis_fixture::{decode_base64, BasisEmbeddingEntry};

const FIXTURE: &[u8] = include_bytes!("../../Tests/SharedVectors/nmf_basis_blob.json");

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NmfBasisFixture {
    blob_base64: String,
    corpus: Vec<String>,
    embeddings: Vec<BasisEmbeddingEntry>,
    doc0_float_bits: Vec<u32>,
}

fn load() -> NmfBasisFixture {
    serde_json::from_slice(FIXTURE).expect("nmf_basis_blob.json must be valid JSON")
}

fn trained_from_fixture(f: &NmfBasisFixture) -> NmfProvider {
    use corpus_kit_providers::{NMF_FACTORIZATION_SEED, NMF_PROJECTION_SEED};
    // rank=3, iterations=100 — identical to the Swift fixture builder.
    let mut p = NmfProvider::new(3, 100, NMF_FACTORIZATION_SEED, NMF_PROJECTION_SEED);
    for doc in &f.corpus {
        p.train(doc);
    }
    p.finalize();
    p
}

#[test]
fn rust_serialize_matches_swift_blob_byte_for_byte() {
    let f = load();
    let expected = decode_base64(&f.blob_base64);
    let actual = trained_from_fixture(&f).serialize_basis();
    assert_eq!(actual.len(), expected.len(), "NMF blob length mismatch");
    assert_eq!(
        actual, expected,
        "NMF serialize_basis() must be byte-identical to the Swift-emitted blob"
    );
}

#[test]
fn rust_deserialize_reproduces_fixture_embeddings() {
    let f = load();
    let blob = decode_base64(&f.blob_base64);
    let restored = NmfProvider::from_serialized_basis(&blob).expect("blob must deserialize");

    for entry in &f.embeddings {
        // Inherent fold-in returns Option; empty/OOV text yields None → [].
        let floats = restored.embed_float_nmf(&entry.text).unwrap_or_default();
        let bits: Vec<u32> = floats.iter().map(|x| x.to_bits()).collect();
        assert_eq!(bits, entry.float_bits, "float bits for '{}'", entry.text);
    }

    // Training-document embedding for doc 0 (exercises H retention).
    let doc0 = restored.document_embedding(0).unwrap_or_default();
    let doc0_bits: Vec<u32> = doc0.iter().map(|x| x.to_bits()).collect();
    assert_eq!(
        doc0_bits, f.doc0_float_bits,
        "doc-0 embedding must match Swift after deserialize"
    );
}
