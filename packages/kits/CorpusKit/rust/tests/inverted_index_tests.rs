// inverted_index_tests.rs
//
// Conformance tests for Lane D: InvertedIndex (WAND / BMW), BM25Weighting,
// and InvertedIndexStore (SQLite round-trip).
//
// Test vectors from retrieval algorithms reference §2.9 (SPARSE-1..4).
// InvertedIndexStore tests use real rusqlite SQLite connections (never InMemory).

use corpus_kit::{
    Algorithm, BM25Parameters, BM25Weighting, ImpactPosting, InvertedIndex,
    InvertedIndexStore, QUANT_SCALE, TermFreqTable, quantize_impact,
};
use std::collections::HashMap;

// MARK: — Helpers

fn make_index(raw: Vec<(u32, Vec<(&str, i32)>)>, num_docs: usize) -> InvertedIndex {
    let mut postings: HashMap<u32, Vec<ImpactPosting>> = HashMap::new();
    for (term_id, pairs) in raw {
        postings.insert(
            term_id,
            pairs.into_iter()
                .map(|(id, imp)| ImpactPosting { item_id: id.to_owned(), impact: imp })
                .collect(),
        );
    }
    InvertedIndex::new(postings, num_docs)
}

fn bm25_query(term_ids: &[u32]) -> Vec<(u32, i32)> {
    term_ids.iter().map(|&id| (id, QUANT_SCALE)).collect()
}

fn open_sqlite_store() -> InvertedIndexStore {
    let conn = rusqlite::Connection::open_in_memory().expect("open in-memory SQLite");
    InvertedIndexStore::open(conn).expect("open InvertedIndexStore")
}

// MARK: — SPARSE-1: WAND and BMW top-2 match exhaustive scan

/// SPARSE-1: WAND and BMW top-2 match exhaustive scan on arbitrary SPLADE-style
/// weights. Expected: doc2(500.0) and doc3(500.0), doc2 first (smaller item_id).
#[test]
fn sparse1_wand_top_k_matches_exhaustive() {
    let index = make_index(
        vec![
            (0, vec![("doc1", 300), ("doc2", 100), ("doc4", 200)]),
            (1, vec![("doc2", 400), ("doc3", 500), ("doc4", 100)]),
            (2, vec![("doc1", 50),  ("doc3", 150)]),
        ],
        4,
    );
    let query = bm25_query(&[0, 1]);

    let wand = index.top_k(&query, 2, Algorithm::Wand);
    let bmw  = index.top_k(&query, 2, Algorithm::BlockMaxWand);
    let scan = index.exhaustive_scan(&query, 2);

    for (label, hits) in [("WAND", &wand), ("BMW", &bmw), ("exhaustive", &scan)] {
        assert_eq!(hits.len(), 2, "{label}: expected 2 results");
        assert_eq!(hits[0].item_id, "doc2", "{label}: doc2 must be first (tie-break)");
        assert_eq!(hits[1].item_id, "doc3", "{label}: doc3 must be second");
        // score = (100+400) / QUANT_SCALE = 500.0
        assert!(
            (hits[0].impact - 500.0).abs() < 0.01,
            "{label}: doc2 score ≈ 500, got {}",
            hits[0].impact
        );
        assert!(
            (hits[1].impact - 500.0).abs() < 0.01,
            "{label}: doc3 score ≈ 500, got {}",
            hits[1].impact
        );
    }

    let wand_ids: Vec<&str> = wand.iter().map(|h| h.item_id.as_str()).collect();
    let bmw_ids:  Vec<&str> = bmw.iter().map(|h| h.item_id.as_str()).collect();
    let scan_ids: Vec<&str> = scan.iter().map(|h| h.item_id.as_str()).collect();
    assert_eq!(wand_ids, scan_ids, "WAND must match exhaustive");
    assert_eq!(bmw_ids,  scan_ids, "BMW must match exhaustive");
}

// MARK: — SPARSE-2: tie-break k=1

/// SPARSE-2: same index, k=1. doc2 must win (tie-break by smaller item_id).
#[test]
fn sparse2_tie_break_k1() {
    let index = make_index(
        vec![
            (0, vec![("doc1", 300), ("doc2", 100), ("doc4", 200)]),
            (1, vec![("doc2", 400), ("doc3", 500), ("doc4", 100)]),
            (2, vec![("doc1", 50),  ("doc3", 150)]),
        ],
        4,
    );
    let query = bm25_query(&[0, 1]);

    for alg in [Algorithm::Wand, Algorithm::BlockMaxWand] {
        let hits = index.top_k(&query, 1, alg);
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].item_id, "doc2", "doc2 must win k=1 tie");
    }
}

// MARK: — SPARSE-3: BM25 weighting + full flow

/// SPARSE-3: BM25 quantized impacts + correct top-2 from the full flow.
/// WAND / exhaustive must agree; doc1 (cat+dog) ranks first.
#[test]
fn sparse3_bm25_weighting_full_flow() {
    let params = BM25Parameters::new(1.2, 0.75);
    let mut term_freqs = TermFreqTable::new();

    let mut cat = HashMap::new();
    cat.insert("doc1".to_owned(), 2usize);
    cat.insert("doc2".to_owned(), 1);
    term_freqs.insert("cat".to_owned(), cat);

    let mut dog = HashMap::new();
    dog.insert("doc1".to_owned(), 1usize);
    dog.insert("doc3".to_owned(), 3);
    term_freqs.insert("dog".to_owned(), dog);

    let mut bird = HashMap::new();
    bird.insert("doc2".to_owned(), 1usize);
    bird.insert("doc3".to_owned(), 1);
    term_freqs.insert("bird".to_owned(), bird);

    let doc_lengths: HashMap<String, usize> = [
        ("doc1".to_owned(), 3usize),
        ("doc2".to_owned(), 2),
        ("doc3".to_owned(), 4),
    ]
    .into_iter()
    .collect();

    let (index, tm) = BM25Weighting::build(&term_freqs, &doc_lengths, params);
    let cat_id = *tm.get("cat").unwrap();
    let dog_id = *tm.get("dog").unwrap();
    let query = vec![(cat_id, QUANT_SCALE), (dog_id, QUANT_SCALE)];

    let wand = index.top_k(&query, 2, Algorithm::Wand);
    let scan = index.exhaustive_scan(&query, 2);

    let wand_ids: Vec<&str> = wand.iter().map(|h| h.item_id.as_str()).collect();
    let scan_ids: Vec<&str> = scan.iter().map(|h| h.item_id.as_str()).collect();
    assert_eq!(wand_ids, scan_ids, "WAND top-2 must match exhaustive for SPARSE-3");
    assert_eq!(wand_ids[0], "doc1", "doc1 (cat+dog) must rank first");
}

// MARK: — SPARSE-4: BMW == WAND == exhaustive, larger index

/// SPARSE-4: BMW == WAND == exhaustive on a 20-doc corpus across 3 terms.
#[test]
fn sparse4_bmw_wand_exhaustive_agree() {
    // Use zero-padded doc IDs so lexicographic sort matches document order.
    let docs: Vec<String> = (1..=20).map(|i| format!("doc{:02}", i)).collect();

    // term0: all 20 docs, impact decreasing from 200 by 5 steps.
    let term0: Vec<ImpactPosting> = docs
        .iter()
        .enumerate()
        .map(|(i, d)| ImpactPosting { item_id: d.clone(), impact: 200 - (i as i32) * 5 })
        .collect();

    // term1: docs 1–15 with increasing impact.
    let term1: Vec<ImpactPosting> = docs[0..15]
        .iter()
        .enumerate()
        .map(|(i, d)| ImpactPosting { item_id: d.clone(), impact: 50 + (i as i32) * 3 })
        .collect();

    // term2: docs 5–20 with flat impact.
    let term2: Vec<ImpactPosting> = docs[4..20]
        .iter()
        .map(|d| ImpactPosting { item_id: d.clone(), impact: 75 })
        .collect();

    let mut postings: HashMap<u32, Vec<ImpactPosting>> = HashMap::new();
    postings.insert(0, term0);
    postings.insert(1, term1);
    postings.insert(2, term2);
    let index = InvertedIndex::new(postings, 20);

    let query = vec![(0u32, 100i32), (1u32, 80i32), (2u32, 120i32)];
    let k = 5;

    let wand = index.top_k(&query, k, Algorithm::Wand);
    let bmw  = index.top_k(&query, k, Algorithm::BlockMaxWand);
    let scan = index.exhaustive_scan(&query, k);

    assert_eq!(wand.len(), k, "WAND must return k results");
    assert_eq!(bmw.len(),  k, "BMW must return k results");
    assert_eq!(scan.len(), k, "Exhaustive must return k results");

    let wand_ids: Vec<&str> = wand.iter().map(|h| h.item_id.as_str()).collect();
    let bmw_ids:  Vec<&str> = bmw.iter().map(|h| h.item_id.as_str()).collect();
    let scan_ids: Vec<&str> = scan.iter().map(|h| h.item_id.as_str()).collect();

    assert_eq!(wand_ids, scan_ids, "WAND must match exhaustive");
    assert_eq!(bmw_ids,  scan_ids, "BMW must match exhaustive");

    for i in 0..k {
        let diff = (wand[i].impact - scan[i].impact).abs();
        assert!(
            diff < 0.01,
            "Score mismatch at rank {}: WAND={}, scan={}",
            i, wand[i].impact, scan[i].impact
        );
    }
}

// MARK: — InvertedIndex edge cases

#[test]
fn empty_query_returns_empty() {
    let index = make_index(vec![(0, vec![("doc1", 100)])], 1);
    assert!(index.top_k(&[], 5, Algorithm::Wand).is_empty());
    assert!(index.top_k(&[], 5, Algorithm::BlockMaxWand).is_empty());
    assert!(index.exhaustive_scan(&[], 5).is_empty());
}

#[test]
fn k_zero_returns_empty() {
    let index = make_index(vec![(0, vec![("doc1", 100)])], 1);
    assert!(index.top_k(&bm25_query(&[0]), 0, Algorithm::Wand).is_empty());
}

#[test]
fn unknown_term_returns_empty() {
    let index = make_index(vec![(0, vec![("doc1", 100)])], 1);
    assert!(index.top_k(&bm25_query(&[99]), 5, Algorithm::Wand).is_empty());
}

#[test]
fn id_tie_break_smaller_wins() {
    // Two docs with identical impact → "apple" beats "zebra".
    let index = make_index(vec![(0, vec![("apple", 100), ("zebra", 100)])], 2);
    let hits = index.top_k(&bm25_query(&[0]), 1, Algorithm::BlockMaxWand);
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].item_id, "apple", "smaller item_id must win tie");
}

// MARK: — quantize_impact round-half-to-even (banker's rounding)
//
// quantize_impact(v) = round_half_even(v * QUANT_SCALE) where QUANT_SCALE = 100.
// So quantize_impact(0.025) = round_half_even(2.5) = 2  (even).
//    quantize_impact(0.035) = round_half_even(3.5) = 4  (even).
//    quantize_impact(0.005) = round_half_even(0.5) = 0  (even).

#[test]
fn quantize_round_half_to_even() {
    // 2.5 scaled-half → nearest even 2.
    assert_eq!(quantize_impact(0.025), 2,  "round-half-to-even: 2.5 → 2");
    // 3.5 scaled-half → nearest even 4.
    assert_eq!(quantize_impact(0.035), 4,  "round-half-to-even: 3.5 → 4");
    // 0.5 scaled-half → nearest even 0.
    assert_eq!(quantize_impact(0.005), 0,  "round-half-to-even: 0.5 → 0");
    // -0.5 scaled-half → nearest even 0 (magnitude rounding).
    assert_eq!(quantize_impact(-0.005), 0, "round-half-to-even: -0.5 → 0");
    // Exact integers scale cleanly.
    assert_eq!(quantize_impact(1.0), 100);
    assert_eq!(quantize_impact(0.0), 0);
    // Normal rounding (no tie): 0.024 → 2, 0.026 → 3.
    assert_eq!(quantize_impact(0.024), 2);
    assert_eq!(quantize_impact(0.026), 3);
}

// MARK: — InvertedIndexStore SQLite round-trip tests

fn tokens(words: &[&str]) -> Vec<String> {
    words.iter().map(|s| s.to_string()).collect()
}

#[test]
fn store_index_and_query() {
    let store = open_sqlite_store();

    store.index("item-1", &tokens(&["cat", "cat", "dog"]),           "2026-01-01").unwrap();
    store.index("item-2", &tokens(&["cat", "bird"]),                  "2026-01-01").unwrap();
    store.index("item-3", &tokens(&["dog", "dog", "dog", "bird"]),    "2026-01-01").unwrap();

    let hits = store.top_k(&tokens(&["cat", "dog"]), 2, BM25Parameters::default(), Algorithm::BlockMaxWand);

    assert_eq!(hits.len(), 2, "should return 2 hits");
    // item-1 has both cat(×2)+dog(×1) → ranks first.
    assert_eq!(hits[0].item_id, "item-1", "item-1 (cat+dog) must rank first");
    assert!(hits[0].impact > 0.0, "score must be positive");
}

#[test]
fn store_remove_drops_doc() {
    let store = open_sqlite_store();

    store.index("ephemeral", &tokens(&["unique", "rare", "keyword"]), "2026-01-01").unwrap();
    assert_eq!(store.document_count(), 1);

    let before = store.top_k(&tokens(&["unique"]), 5, BM25Parameters::default(), Algorithm::Wand);
    assert!(!before.is_empty(), "should find doc before removal");

    store.remove("ephemeral").unwrap();
    assert_eq!(store.document_count(), 0);

    let after = store.top_k(&tokens(&["unique"]), 5, BM25Parameters::default(), Algorithm::Wand);
    assert!(after.is_empty(), "should not find removed doc");
}

#[test]
fn store_reindex_replaces_content() {
    let store = open_sqlite_store();

    store.index("mutable", &tokens(&["original", "content"]),            "2026-01-01").unwrap();
    let before = store.top_k(&tokens(&["original"]), 5, BM25Parameters::default(), Algorithm::Wand);
    assert!(!before.is_empty(), "original must be findable");

    store.index("mutable", &tokens(&["completely", "different", "text"]), "2026-01-01").unwrap();

    let after_old = store.top_k(&tokens(&["original"]), 5, BM25Parameters::default(), Algorithm::Wand);
    assert!(after_old.is_empty(), "original must be gone after re-index");

    let after_new = store.top_k(&tokens(&["different"]), 5, BM25Parameters::default(), Algorithm::Wand);
    assert!(!after_new.is_empty(), "new term must be findable after re-index");

    assert_eq!(store.document_count(), 1, "doc count must stay 1 after re-index");
}

#[test]
fn store_close_reopen_retains_state() {
    // Use a temp file path so we can reopen across two store sessions.
    let tmp_path = std::env::temp_dir()
        .join(format!("iix_roundtrip_{}.sqlite", uuid::Uuid::new_v4()));

    // Session 1: index two documents.
    {
        let conn = rusqlite::Connection::open(&tmp_path).expect("open");
        let store = InvertedIndexStore::open(conn).expect("open store");
        store.index("persistent-1", &tokens(&["persistent", "data", "storage"]),     "2026-01-01").unwrap();
        store.index("persistent-2", &tokens(&["data", "analysis", "machine"]),        "2026-01-01").unwrap();
    }

    // Session 2: reopen and verify state persisted.
    {
        let conn = rusqlite::Connection::open(&tmp_path).expect("reopen");
        let store = InvertedIndexStore::open(conn).expect("reopen store");
        assert_eq!(store.document_count(), 2, "state must persist across reopen");
        let hits = store.top_k(&tokens(&["data"]), 5, BM25Parameters::default(), Algorithm::Wand);
        assert!(!hits.is_empty(), "persisted index must answer queries after reopen");
    }

    let _ = std::fs::remove_file(tmp_path);
}

// MARK: — BM25Index routing tests (refactored path)

#[test]
fn bm25_index_higher_tf_ranks_first() {
    use corpus_kit::BM25Index;
    use corpus_kit_providers::DeterministicTokenizer;
    use std::sync::Arc;
    use uuid::Uuid;

    let tok = Arc::new(DeterministicTokenizer::new());
    let mut idx = BM25Index::new(tok);
    let id1 = Uuid::new_v4();
    let id2 = Uuid::new_v4();

    idx.index_documents(vec![
        (id1, "cat cat cat cat cat"),
        (id2, "cat and one other thing"),
    ]);

    let tokens = idx.tokenize_query("cat");
    let results = idx.top_k(5, &tokens);

    assert!(!results.is_empty(), "should return results");
    assert_eq!(results[0].0, id1, "higher TF doc must rank first via engine");
}

#[test]
fn bm25_index_remove_clears_doc() {
    use corpus_kit::BM25Index;
    use corpus_kit_providers::DeterministicTokenizer;
    use std::sync::Arc;
    use uuid::Uuid;

    let tok = Arc::new(DeterministicTokenizer::new());
    let mut idx = BM25Index::new(tok);
    let id = Uuid::new_v4();

    idx.index_documents(vec![(id, "ephemeral rare term content")]);
    assert_eq!(idx.document_count(), 1);

    idx.remove(id);
    assert_eq!(idx.document_count(), 0);

    let toks = idx.tokenize_query("ephemeral");
    assert!(idx.top_k(5, &toks).is_empty(), "removed doc must not appear");
}

// MARK: — k > N: all three algorithms agree and return N results

/// k>N: WAND == BMW == exhaustive when k much larger than corpus.
/// Requesting k=1000 results from a 3-doc corpus must return exactly 3
/// results and all algorithms must agree on ordering.
#[test]
fn k_larger_than_corpus_returns_all_docs_and_algorithms_agree() {
    let index = make_index(
        vec![
            (0, vec![("alpha", 300), ("beta", 200), ("gamma", 100)]),
            (1, vec![("alpha", 150), ("gamma", 250)]),
        ],
        3, // numDocs
    );
    let query = bm25_query(&[0, 1]);
    let k: usize = 1000;

    let wand_hits = index.top_k(&query, k, Algorithm::Wand);
    let bmw_hits  = index.top_k(&query, k, Algorithm::BlockMaxWand);
    let scan_hits = index.exhaustive_scan(&query, k);

    // All three must return exactly 3 docs (corpus size), not 1000.
    assert_eq!(wand_hits.len(), 3, "WAND k=1000 on 3-doc corpus must return 3");
    assert_eq!(bmw_hits.len(),  3, "BMW k=1000 on 3-doc corpus must return 3");
    assert_eq!(scan_hits.len(), 3, "Exhaustive k=1000 on 3-doc corpus must return 3");

    // All three must agree on the ordered item list.
    let wand_ids: Vec<&str> = wand_hits.iter().map(|h| h.item_id.as_str()).collect();
    let bmw_ids:  Vec<&str> = bmw_hits.iter().map(|h| h.item_id.as_str()).collect();
    let scan_ids: Vec<&str> = scan_hits.iter().map(|h| h.item_id.as_str()).collect();
    assert_eq!(wand_ids, bmw_ids,  "WAND and BMW must produce identical ordered item IDs for k>N");
    assert_eq!(wand_ids, scan_ids, "WAND and exhaustive must produce identical ordered item IDs for k>N");

    // Scores must match within float rounding tolerance.
    for i in 0..3 {
        assert!(
            (wand_hits[i].impact - scan_hits[i].impact).abs() < 0.01,
            "Score mismatch at rank {} for k>N: WAND={} exhaustive={}",
            i, wand_hits[i].impact, scan_hits[i].impact
        );
    }
}

