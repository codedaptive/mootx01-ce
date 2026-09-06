#![cfg(feature = "dense-families")]
// Dense-family test — compiled only when --features dense-families.
// Off by default (plan 70BC55F3, 2026-09-05). See Cargo.toml.
//! Cross-port conformance for the distributional pooling contract of the
//! three families whose vectors used to collapse onto the corpus mean:
//! random-indexing-v1, ppmi-v1, nmf-v1.
//!
//! Reads the canonical fixture emitted by the Swift leg (the canonical source):
//!   `Tests/SharedVectors/dense_pooling_vectors.json`
//! and asserts, per family:
//!   (a) SPREAD — the mean pairwise cosine between the document vectors is
//!       below the fixture's ceiling (0.5) AND reproduces the Swift-measured
//!       value bit-for-bit (the vectors it is computed from are pinned);
//!   (b) SELF-QUERY — each document's opening sentence ranks that document
//!       first (strictly nearest);
//!   (c) ONE POOLING FUNCTION — for the same text, `embed_pair` (the document
//!       path) and `embed_float` (the query path) return identical bits;
//!   and that every document / query vector is bit-identical to the Swift pin.
//!
//! Swift twin: Tests/CorpusKitTests/DensePoolingConformanceTests.swift

use corpus_kit::TrainableEmbeddingBasis;
use corpus_kit_providers::{NmfProvider, PpmiProvider, RandomIndexingProvider};
use serde::Deserialize;
use substrate_kernel::float_vec_ops;
use synapsekit::EmbeddingProvider;

const FIXTURE: &[u8] = include_bytes!("../../Tests/SharedVectors/dense_pooling_vectors.json");

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FamilyFixture {
    #[serde(rename = "modelID")]
    model_id: String,
    mean_pairwise_cosine_bits: u32,
    document_vectors: Vec<Vec<u32>>,
    query_vectors: Vec<Vec<u32>>,
    self_query_ranks: Vec<usize>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Fixture {
    corpus: Vec<String>,
    queries: Vec<String>,
    spread_ceiling: f32,
    families: Vec<FamilyFixture>,
}

fn load() -> Fixture {
    serde_json::from_slice(FIXTURE).expect("dense_pooling_vectors.json must be valid JSON")
}

/// The three families under contract, trained through the seam on the
/// fixture corpus (the same call the corpus makes), in fixture order.
fn trained_families(corpus: &[String]) -> Vec<Box<dyn TrainableEmbeddingBasis>> {
    let texts: Vec<&str> = corpus.iter().map(String::as_str).collect();
    let mut ri = RandomIndexingProvider::new();
    let mut ppmi = PpmiProvider::new();
    let mut nmf = NmfProvider::default_new();
    ri.train_on_corpus(&texts);
    ppmi.train_on_corpus(&texts);
    nmf.train_on_corpus(&texts);
    vec![Box::new(ri), Box::new(ppmi), Box::new(nmf)]
}

/// Mean of cos(v_i, v_j) over all unordered pairs i < j, accumulated in
/// index order (the Swift leg accumulates in the same order).
fn mean_pairwise_cosine(vectors: &[Vec<f32>]) -> f32 {
    let mut sum = 0.0f32;
    let mut pairs = 0usize;
    for i in 0..vectors.len() {
        for j in (i + 1)..vectors.len() {
            sum += float_vec_ops::dot(&vectors[i], &vectors[j]);
            pairs += 1;
        }
    }
    if pairs == 0 {
        0.0
    } else {
        sum / pairs as f32
    }
}

/// 1-based rank of `target` among `documents` by cosine to `query`
/// (1 = strictly nearest; ties count against the target).
fn self_query_rank(query: &[f32], documents: &[Vec<f32>], target: usize) -> usize {
    let own = float_vec_ops::dot(query, &documents[target]);
    let better = documents
        .iter()
        .enumerate()
        .filter(|(index, document)| *index != target && float_vec_ops::dot(query, document) >= own)
        .count();
    better + 1
}

fn bits(v: &[f32]) -> Vec<u32> {
    v.iter().map(|x| x.to_bits()).collect()
}

struct Measured {
    documents: Vec<Vec<f32>>,
    queries: Vec<Vec<f32>>,
}

fn measure(provider: &dyn EmbeddingProvider, f: &Fixture) -> Measured {
    let documents = f
        .corpus
        .iter()
        // The document path: what the index writes.
        .map(|text| provider.embed_pair(text).expect("embed_pair").1)
        .collect();
    let queries = f
        .queries
        .iter()
        // The query path: what recall embeds.
        .map(|text| provider.embed_float(text).expect("embed_float"))
        .collect();
    Measured { documents, queries }
}

#[test]
fn spread_below_ceiling_and_pinned() {
    let f = load();
    for (family, expected) in trained_families(&f.corpus).iter().zip(&f.families) {
        let m = measure(family.as_ref(), &f);
        for v in &m.documents {
            assert!(!v.is_empty(), "{}: every fixture document must embed", expected.model_id);
        }
        let cosine = mean_pairwise_cosine(&m.documents);
        assert!(
            cosine < f.spread_ceiling,
            "{}: mean pairwise cosine {cosine} must be below {}",
            expected.model_id,
            f.spread_ceiling
        );
        assert_eq!(
            cosine.to_bits(),
            expected.mean_pairwise_cosine_bits,
            "{}: mean pairwise cosine must match the Swift pin bit-for-bit",
            expected.model_id
        );
    }
}

#[test]
fn opening_sentence_ranks_own_document_first() {
    let f = load();
    for (family, expected) in trained_families(&f.corpus).iter().zip(&f.families) {
        let m = measure(family.as_ref(), &f);
        for i in 0..f.corpus.len() {
            let rank = self_query_rank(&m.queries[i], &m.documents, i);
            assert_eq!(rank, 1, "{}: query {i} must rank its document first", expected.model_id);
            assert_eq!(rank, expected.self_query_ranks[i], "{}: rank pin", expected.model_id);
        }
    }
}

#[test]
fn document_and_query_paths_agree() {
    let f = load();
    for (family, expected) in trained_families(&f.corpus).iter().zip(&f.families) {
        for text in f.corpus.iter().chain(f.queries.iter()) {
            let via_document_path = family.embed_pair(text).expect("embed_pair").1;
            let via_query_path = family.embed_float(text).expect("embed_float");
            assert_eq!(
                bits(&via_document_path),
                bits(&via_query_path),
                "{}: embed_pair and embed_float must agree bit-for-bit",
                expected.model_id
            );
        }
    }
}

#[test]
fn vectors_match_swift_bit_for_bit() {
    let f = load();
    for (family, expected) in trained_families(&f.corpus).iter().zip(&f.families) {
        assert_eq!(family.model_id(), expected.model_id, "fixture family order");
        let m = measure(family.as_ref(), &f);
        for (i, v) in m.documents.iter().enumerate() {
            assert_eq!(bits(v), expected.document_vectors[i], "{}: document {i}", expected.model_id);
        }
        for (i, v) in m.queries.iter().enumerate() {
            assert_eq!(bits(v), expected.query_vectors[i], "{}: query {i}", expected.model_id);
        }
    }
}

#[test]
fn reconstructed_basis_pools_identically() {
    let f = load();
    for (family, expected) in trained_families(&f.corpus).iter().zip(&f.families) {
        let restored = family
            .reconstruct_basis(&family.serialize_basis())
            .expect("reconstruct_basis");
        for text in &f.queries {
            let a = family.embed_float(text).expect("embed_float");
            let b = restored.embed_float(text).expect("embed_float restored");
            assert_eq!(
                bits(&a),
                bits(&b),
                "{}: the IDF table and mean direction must travel in the basis",
                expected.model_id
            );
        }
    }
}
