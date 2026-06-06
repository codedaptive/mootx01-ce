// Tests for BM25Index.

use corpus_kit::{BM25Index, BM25Parameters};
use corpus_kit_providers::DeterministicTokenizer;
use std::sync::Arc;
use uuid::Uuid;

fn make_index() -> BM25Index {
    BM25Index::new(Arc::new(DeterministicTokenizer::new()))
}

/// Tokenise a query with the same tokenizer the test index uses.
fn tokens(idx: &BM25Index, query: &str) -> Vec<String> {
    idx.tokenize_query(query)
}

#[test]
fn empty_index_returns_empty_results() {
    let idx = make_index();
    assert_eq!(idx.document_count(), 0);
    assert!(idx.top_k(10, &tokens(&idx, "anything")).is_empty());
}

#[test]
fn single_document_match() {
    let mut idx = make_index();
    let id = Uuid::new_v4();
    idx.index_documents(vec![(id, "the quick brown fox jumps over the lazy dog")]);
    let toks = tokens(&idx, "quick fox");
    let results = idx.top_k(10, &toks);
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
    let toks = tokens(&idx, "alpha");
    let results = idx.top_k(3, &toks);
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
    let toks = tokens(&idx, "keyword");
    let results = idx.top_k(2, &toks);
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
    assert!(idx.top_k(10, &tokens(&idx, "removable")).is_empty());
}

#[test]
fn custom_bm25_parameters() {
    let tok = Arc::new(DeterministicTokenizer::new());
    let mut idx = BM25Index::with_parameters(tok, BM25Parameters::new(2.0, 0.5));
    let id = Uuid::new_v4();
    idx.index_documents(vec![(id, "custom parameters test")]);
    let toks = tokens(&idx, "custom");
    let results = idx.top_k(5, &toks);
    assert_eq!(results.len(), 1);
}

#[test]
fn query_with_no_matching_terms_returns_empty() {
    let mut idx = make_index();
    idx.index_documents(vec![(Uuid::new_v4(), "alpha beta gamma")]);
    let toks = tokens(&idx, "zeta");
    let results = idx.top_k(10, &toks);
    assert!(results.is_empty());
}

#[test]
fn empty_query_returns_empty_results() {
    let mut idx = make_index();
    idx.index_documents(vec![(Uuid::new_v4(), "alpha beta")]);
    let toks = tokens(&idx, "");
    let results = idx.top_k(10, &toks);
    assert!(results.is_empty());
}
