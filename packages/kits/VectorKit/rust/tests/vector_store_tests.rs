//! Tests for the Rust `VectorStore` -- persistence-kit-backed CRUD over
//! the `vectors` table. Parallel to the Swift `VectorStoreTests`.
//! Per spec I-4 every stored vector is tagged with the model ID and
//! version that produced it; the round-trip and multi-model tests
//! below enforce that invariant.
//!
//! Refactored 2026-05-19 (Rust mission 6): each test now backs the
//! store with an `InMemoryStorage` from persistence-kit. The previous
//! tempfile + SQLite path is gone; the SQLite backend lands in a
//! follow-on R-mission and slots in additively against the same
//! tests.
//!
//! `filed_at` is now `i64` Unix epoch seconds, mirroring
//! persistence-kit's `TypedValue::Timestamp(i64)`. The Swift side also
//! moved off ISO8601-text-storage as part of this mission.

use engram_lib::Engram;
use std::sync::Arc;
use persistence_kit::{inmemory::InMemoryStorage, Storage};
use uuid::Uuid;
use vectorkit::VectorStore;

const FILED_AT_1: i64 = 1_700_000_000;
const FILED_AT_2: i64 = 1_700_000_100;
const FILED_AT_3: i64 = 1_700_000_200;

fn fresh_store() -> VectorStore {
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    VectorStore::open(storage).expect("open")
}

#[test]
fn add_get_round_trip_preserves_engram_bytes() {
    let store = fresh_store();
    let engram = Engram::new(0xDEAD_BEEF_CAFE_BABE,
                             0x0123_4567_89AB_CDEF,
                             0xFFFF_0000_FFFF_0000,
                             0x0000_FFFF_0000_FFFF);
    store
        .add_vector("drawer-A", &engram, "minilm", "1.0.0", FILED_AT_1)
        .expect("add");

    let fetched = store
        .get_vector("drawer-A", "minilm")
        .expect("get");
    assert_eq!(fetched, Some(engram));
}

#[test]
fn get_vector_returns_none_for_unknown_drawer() {
    let store = fresh_store();
    let result = store.get_vector("never-existed", "minilm").expect("get");
    assert_eq!(result, None);
}

#[test]
fn multiple_models_stored_for_same_drawer() {
    let store = fresh_store();
    let minilm = Engram::new(0x1111, 0x2222, 0x3333, 0x4444);
    let gemma  = Engram::new(0xAAAA, 0xBBBB, 0xCCCC, 0xDDDD);
    store.add_vector("drawer-X", &minilm, "minilm", "1.0.0", FILED_AT_1)
         .expect("add minilm");
    store.add_vector("drawer-X", &gemma, "gemma", "300m", FILED_AT_1)
         .expect("add gemma");

    assert_eq!(store.get_vector("drawer-X", "minilm").unwrap(), Some(minilm));
    assert_eq!(store.get_vector("drawer-X", "gemma").unwrap(), Some(gemma));
}

#[test]
fn vectors_for_drawer_returns_all_ordered_by_filed_at_ascending() {
    let store = fresh_store();
    let e1 = Engram::new(1, 0, 0, 0);
    let e2 = Engram::new(2, 0, 0, 0);
    let e3 = Engram::new(3, 0, 0, 0);

    // Insert out of chronological order to exercise the ORDER BY.
    store.add_vector("drawer-Y", &e2, "mB", "1", FILED_AT_2).expect("add e2");
    store.add_vector("drawer-Y", &e3, "mC", "1", FILED_AT_3).expect("add e3");
    store.add_vector("drawer-Y", &e1, "mA", "1", FILED_AT_1).expect("add e1");

    let all = store.vectors_for_drawer("drawer-Y").expect("list");
    assert_eq!(all.len(), 3);
    let engrams: Vec<Engram> = all.iter().map(|r| r.engram).collect();
    assert_eq!(engrams, vec![e1, e2, e3]);
    let models: Vec<&str> = all.iter().map(|r| r.model_id.as_str()).collect();
    assert_eq!(models, vec!["mA", "mB", "mC"]);
    let filed: Vec<i64> = all.iter().map(|r| r.filed_at).collect();
    assert_eq!(filed, vec![FILED_AT_1, FILED_AT_2, FILED_AT_3]);
}

#[test]
fn delete_vector_removes_row() {
    let store = fresh_store();
    let engram = Engram::new(0x42, 0, 0, 0);
    store.add_vector("drawer-Z", &engram, "minilm", "1.0.0", FILED_AT_1)
         .expect("add");
    store.delete_vector("drawer-Z", "minilm").expect("delete");

    let fetched = store.get_vector("drawer-Z", "minilm").expect("get");
    assert_eq!(fetched, None);
}

#[test]
fn model_and_version_round_trip() {
    let store = fresh_store();
    let engram = Engram::new(0xAA, 0xBB, 0xCC, 0xDD);
    store
        .add_vector("drawer-V", &engram, "minilm-v6", "1.0.0-alpha.3", FILED_AT_1)
        .expect("add");

    let rows = store.vectors_for_drawer("drawer-V").expect("list");
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].drawer_id, "drawer-V");
    assert_eq!(rows[0].model_id, "minilm-v6");
    assert_eq!(rows[0].model_version, "1.0.0-alpha.3");
    assert_eq!(rows[0].engram, engram);
    assert_eq!(rows[0].filed_at, FILED_AT_1);
}

#[test]
fn add_vector_upserts_on_same_drawer_and_model() {
    let store = fresh_store();
    let first  = Engram::new(1, 2, 3, 4);
    let second = Engram::new(5, 6, 7, 8);

    store.add_vector("drawer-UP", &first, "minilm", "1.0.0", FILED_AT_1)
         .expect("add first");
    store.add_vector("drawer-UP", &second, "minilm", "1.0.1", FILED_AT_2)
         .expect("add second");

    // The conflict path UPDATEs in place; the stored engram is the
    // most recent one and only one row exists for this drawer.
    assert_eq!(store.get_vector("drawer-UP", "minilm").unwrap(),
               Some(second));
    let rows = store.vectors_for_drawer("drawer-UP").expect("list");
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].engram, second);
    assert_eq!(rows[0].model_version, "1.0.1");
}

#[test]
fn fresh_store_returns_empty_for_unknown_drawer() {
    let store = fresh_store();
    let rows = store.vectors_for_drawer("no-such-drawer").expect("list");
    assert!(rows.is_empty());
}

// ---------------------------------------------------------------------------
// VEC-04 — find_nearest / find_by_keyword
// ---------------------------------------------------------------------------

/// Helper: seed the same 4-row corpus the Swift tests use. Hamming
/// distance from the zero probe equals popcount(engram), so the
/// expected sort order is alpha (1) < bravo (2) < charlie (3) <
/// delta (4).
fn seed_corpus(store: &VectorStore, model_id: &str) {
    let entries: &[(&str, u64)] = &[
        ("alpha-doc",   0x1),
        ("bravo-doc",   0x3),
        ("charlie-doc", 0x7),
        ("delta-doc",   0xF),
    ];
    for (drawer, bits) in entries {
        let engram = Engram::new(*bits, 0, 0, 0);
        store
            .add_vector(drawer, &engram, model_id, "1.0.0", FILED_AT_1)
            .expect("seed add_vector");
    }
}

#[test]
fn find_nearest_returns_k_results_sorted_by_distance_ascending() {
    let store = fresh_store();
    seed_corpus(&store, "minilm");
    let probe = Engram::new(0, 0, 0, 0);

    let matches = store
        .find_nearest(&probe, "minilm", 2)
        .expect("find_nearest");
    assert_eq!(matches.len(), 2);
    let ids: Vec<&str> = matches.iter().map(|m| m.drawer_id.as_str()).collect();
    assert_eq!(ids, vec!["alpha-doc", "bravo-doc"]);
    let distances: Vec<i32> = matches.iter().map(|m| m.distance).collect();
    assert_eq!(distances, vec![1, 2]);
    for i in 1..matches.len() {
        assert!(matches[i - 1].distance <= matches[i].distance);
    }
}

#[test]
fn find_nearest_with_k_larger_than_corpus_returns_all_rows() {
    let store = fresh_store();
    seed_corpus(&store, "minilm");
    let probe = Engram::new(0, 0, 0, 0);

    let matches = store
        .find_nearest(&probe, "minilm", 10)
        .expect("find_nearest");
    assert_eq!(matches.len(), 4);
    let ids: Vec<&str> = matches.iter().map(|m| m.drawer_id.as_str()).collect();
    assert_eq!(ids, vec!["alpha-doc", "bravo-doc", "charlie-doc", "delta-doc"]);
    let distances: Vec<i32> = matches.iter().map(|m| m.distance).collect();
    assert_eq!(distances, vec![1, 2, 3, 4]);
}

#[test]
fn find_nearest_on_empty_store_returns_empty() {
    let store = fresh_store();
    let probe = Engram::new(0xFFFF, 0, 0, 0);
    let matches = store
        .find_nearest(&probe, "minilm", 5)
        .expect("find_nearest");
    assert!(matches.is_empty());
}

#[test]
fn find_nearest_indices_map_to_correct_drawer_ids() {
    let store = fresh_store();
    seed_corpus(&store, "minilm");
    let probe = Engram::new(0, 0, 0, 0);

    let matches = store
        .find_nearest(&probe, "minilm", 4)
        .expect("find_nearest");
    assert_eq!(matches.len(), 4);
    for m in &matches {
        let stored = store
            .get_vector(&m.drawer_id, "minilm")
            .expect("get_vector")
            .expect("row must exist");
        let computed = engram_lib::EngramLib::distance(&probe, &stored);
        assert_eq!(
            m.distance as u32, computed,
            "drawer {}: distance mismatch", m.drawer_id
        );
        assert_eq!(m.model_id, "minilm");
    }
}

#[test]
fn find_by_keyword_returns_matching_drawers() {
    let store = fresh_store();
    seed_corpus(&store, "minilm");
    let hits = store.find_by_keyword("alpha", 10).expect("find_by_keyword");
    assert_eq!(hits, vec!["alpha-doc".to_string()]);
}

#[test]
fn find_by_keyword_returns_empty_for_no_match() {
    let store = fresh_store();
    seed_corpus(&store, "minilm");
    let hits = store.find_by_keyword("zebra", 10).expect("find_by_keyword");
    assert!(hits.is_empty());
}

#[test]
fn hybrid_find_nearest_and_find_by_keyword_overlap() {
    let store = fresh_store();
    seed_corpus(&store, "minilm");
    let probe = Engram::new(0, 0, 0, 0);

    let nearest = store
        .find_nearest(&probe, "minilm", 4)
        .expect("find_nearest");
    let keyword = store.find_by_keyword("alpha", 10).expect("find_by_keyword");

    assert!(nearest.iter().any(|m| m.drawer_id == "alpha-doc"));
    assert!(keyword.contains(&"alpha-doc".to_string()));
}
