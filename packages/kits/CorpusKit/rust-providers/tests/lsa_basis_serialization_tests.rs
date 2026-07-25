//! Cross-port basis-serialization conformance gate for `LsaProvider`
//! (mission 6a-i). Asserts byte-identical serialize, embed reproduction, AND
//! training-document-embedding reproduction (which exercises the U factor that
//! Rust now retains so its blob matches Swift's full-SVDResult layout).

use corpus_kit_providers::LsaProvider;
use serde::Deserialize;

mod basis_fixture;
use basis_fixture::{decode_base64, BasisEmbeddingEntry};

const FIXTURE: &[u8] = include_bytes!("../../Tests/SharedVectors/lsa_basis_blob.json");

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LsaBasisFixture {
    blob_base64: String,
    corpus: Vec<String>,
    embeddings: Vec<BasisEmbeddingEntry>,
    doc0_float_bits: Vec<u32>,
}

fn load() -> LsaBasisFixture {
    serde_json::from_slice(FIXTURE).expect("lsa_basis_blob.json must be valid JSON")
}

fn trained_from_fixture(f: &LsaBasisFixture) -> LsaProvider {
    use corpus_kit_providers::LSA_PROJECTION_SEED;
    // rank=3, sweeps=30 — identical to the Swift fixture builder.
    // The shared fixture pins the historical 1.0 provider envelope
    // (mirrors the Swift twin's modelVersion: "1.0.0" pinning).
    let mut p = LsaProvider::with_parameters("lsa-v1", "1.0.0", 3, 30, LSA_PROJECTION_SEED);
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
    assert_eq!(actual.len(), expected.len(), "LSA blob length mismatch");
    assert_eq!(
        actual, expected,
        "LSA serialize_basis() must be byte-identical to the Swift-emitted blob"
    );
}

#[test]
fn rust_deserialize_reproduces_fixture_embeddings() {
    let f = load();
    let blob = decode_base64(&f.blob_base64);
    let restored = LsaProvider::from_serialized_basis(&blob).expect("blob must deserialize");

    for entry in &f.embeddings {
        // The loop always computes float bits via embed_float(...).unwrap_or_default()
        // and compares them to the fixture; empty text yields an empty vector, so
        // float_bits are [] — matched by the fixture entry.
        let floats = restored.embed_float(&entry.text).unwrap_or_default();
        let bits: Vec<u32> = floats.iter().map(|x| x.to_bits()).collect();
        assert_eq!(bits, entry.float_bits, "float bits for '{}'", entry.text);
    }

    // Training-document embedding for doc 0 (exercises U retention).
    let doc0 = restored.document_embedding(0).unwrap_or_default();
    let doc0_bits: Vec<u32> = doc0.iter().map(|x| x.to_bits()).collect();
    assert_eq!(
        doc0_bits, f.doc0_float_bits,
        "doc-0 embedding must match Swift after deserialize"
    );
}
