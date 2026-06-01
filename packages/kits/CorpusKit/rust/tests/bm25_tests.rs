// Tests for BM25Index.

use corpus_kit::{BM25Index, BM25Parameters};
use corpus_kit_providers::DeterministicTokenizer;
use std::sync::Arc;
use uuid::Uuid;

fn make_index() -> BM25Index {
    BM25Index::new(Arc::new(DeterministicTokenizer::new()))
}

#[test]
fn empty_index_returns_empty_results() {
    let idx = make_index();
    assert_eq!(idx.document_count(), 0);
    assert!(idx.search("anything", 10).is_empty());
}

#[test]
fn single_document_match() {
    let mut idx = make_index();
    let id = Uuid::new_v4();
    idx.index_documents(vec![(id, "the quick brown fox jumps over the lazy dog")]);
    let results = idx.search("quick fox", 10);
    assert_eq!(results.len(), 1);
    assert_eq!(results[0].0, id);
    assert!(results[0].1 > 0.0);
}

#[test]
fn multiple_docs_rank_by_relevance() {
    let mut idx = make_index();
    let a = Uuid::new_v4();
    let b = Uuid::new_v4();
    let c = Uuid::new_v4();
    idx.index_documents(vec![
        (a, "alpha beta gamma delta"),
        (b, "alpha alpha alpha alpha"),
        (c, "epsilon zeta eta theta"),
    ]);
    let results = idx.search("alpha", 3);
    assert_eq!(results.len(), 2);
    // Document b has 4 occurrences of "alpha" so it must come first.
    assert_eq!(results[0].0, b);
    assert_eq!(results[1].0, a);
}

#[test]
fn search_with_limit() {
    let mut idx = make_index();
    for i in 0..5 {
        let text = format!("keyword document {}", i);
        idx.index_documents(vec![(Uuid::new_v4(), text.as_str())]);
    }
    let results = idx.search("keyword", 2);
    assert_eq!(results.len(), 2);
}

#[test]
fn remove_drops_document_from_results() {
    let mut idx = make_index();
    let id = Uuid::new_v4();
    idx.index_documents(vec![(id, "removable content here")]);
    assert_eq!(idx.document_count(), 1);
    idx.remove(id);
    assert_eq!(idx.document_count(), 0);
    assert!(idx.search("removable", 10).is_empty());
}

#[test]
fn custom_bm25_parameters() {
    let tok = Arc::new(DeterministicTokenizer::new());
    let mut idx = BM25Index::with_parameters(tok, BM25Parameters::new(2.0, 0.5));
    let id = Uuid::new_v4();
    idx.index_documents(vec![(id, "custom parameters test")]);
    let results = idx.search("custom", 5);
    assert_eq!(results.len(), 1);
}

#[test]
fn query_with_no_matching_terms_returns_empty() {
    let mut idx = make_index();
    idx.index_documents(vec![(Uuid::new_v4(), "alpha beta gamma")]);
    let results = idx.search("zeta", 10);
    assert!(results.is_empty());
}

#[test]
fn empty_query_returns_empty_results() {
    let mut idx = make_index();
    idx.index_documents(vec![(Uuid::new_v4(), "alpha beta")]);
    let results = idx.search("", 10);
    assert!(results.is_empty());
}
