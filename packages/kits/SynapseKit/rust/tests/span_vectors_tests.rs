//! Encoder span rows in the vectors table (ENCODER_RERANK_CONTRACT §3):
//! write_span_vectors / span_vectors / delete_span_vectors /
//! reclaim_retired_vector_rows. Twin of Swift `SpanVectorStoreTests`.
//!
//! Failure modes pinned:
//!   1. Round trip: 3 spans written under one item come back in index order
//!      with their i8 bytes, scale and ext bounds intact.
//!   2. Replace, never append: a second write with 2 spans leaves exactly 2
//!      rows; a rejected write leaves the prior set in place.
//!   3. Reclaim: retired-model rows and non-serving generations go; serving
//!      rows of a live model survive.

use persistence_kit::predicate::StoragePredicate;
use persistence_kit::types::TypedValue;
use persistence_kit::{inmemory::InMemoryStorage, Storage};
use std::collections::BTreeMap;
use std::sync::Arc;
use synapsekit::engine::payload::VectorPayload;
use synapsekit::{SpanVectorInput, VectorStore};
use uuid::Uuid;

/// The store and the storage it wraps (the same `Arc`), so a test can write
/// a raw row the public API never produces.
fn make_store() -> (VectorStore, Arc<dyn Storage>) {
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    storage.open(&VectorStore::schema_declaration()).expect("open schema");
    (VectorStore::new(Arc::clone(&storage), None), storage)
}

fn span(index: u32, int8: Vec<i8>, scale: f32, start: usize, end: usize) -> SpanVectorInput {
    SpanVectorInput {
        index,
        int8,
        scale,
        start_word: start,
        end_word: end,
        content_version: format!("cv-{index}"),
    }
}

const NOW: i64 = 1_757_000_000_000;

#[test]
fn three_spans_round_trip_in_index_order() {
    let (store, _storage) = make_store();
    let spans = vec![
        span(2, vec![127, -127, 0, 5], 0.0078, 60, 120),
        span(0, vec![1, -1, 2, -2], 0.5, 0, 60),
        span(1, vec![-128, 127, 64, -64], 0.25, 30, 90),
    ];
    store
        .write_span_vectors("item-a", "minilm-l6-v2-w60", "r1", &spans, NOW)
        .expect("write");
    let rows = store
        .span_vectors(&["item-a", "item-missing"], "minilm-l6-v2-w60")
        .expect("read");
    assert_eq!(rows.keys().cloned().collect::<Vec<_>>(), vec!["item-a".to_string()]);
    let got = &rows["item-a"];
    assert_eq!(got.iter().map(|r| r.index).collect::<Vec<_>>(), vec![0, 1, 2]);
    assert_eq!(got[1].int8, vec![-128, 127, 64, -64], "two's-complement bytes survive the BLOB");
    assert_eq!(got[1].scale, 0.25);
    assert_eq!((got[2].start_word, got[2].end_word), (60, 120));
    assert_eq!(got[2].content_version, "cv-2");
    assert!(store.span_vectors(&["item-a"], "minilm-l6-v2-w150").unwrap().is_empty());
}

#[test]
fn second_write_replaces_never_appends() {
    let (store, _storage) = make_store();
    let model = "minilm-l6-v2-w60";
    store
        .write_span_vectors(
            "item-b",
            model,
            "r1",
            &[
                span(0, vec![1, 2], 1.0, 0, 60),
                span(1, vec![3, 4], 1.0, 30, 90),
                span(2, vec![5, 6], 1.0, 60, 100),
            ],
            NOW,
        )
        .unwrap();
    store
        .write_span_vectors(
            "item-b",
            model,
            "r1",
            &[span(0, vec![9, 9], 2.0, 0, 40), span(1, vec![8, 8], 2.0, 20, 55)],
            NOW,
        )
        .unwrap();
    let got = store.span_vectors(&["item-b"], model).unwrap().remove("item-b").unwrap();
    assert_eq!(got.len(), 2, "stale span 2 must not survive the replace");
    assert_eq!(got.iter().map(|r| r.int8.clone()).collect::<Vec<_>>(), vec![vec![9, 9], vec![8, 8]]);
    assert_eq!(got.iter().map(|r| r.end_word).collect::<Vec<_>>(), vec![40, 55]);
    // Malformed input (mixed dims) is rejected before any row changes.
    let err = store.write_span_vectors(
        "item-b",
        model,
        "r1",
        &[span(0, vec![1, 2], 1.0, 0, 60), span(1, vec![1, 2, 3], 1.0, 30, 90)],
        NOW,
    );
    assert!(err.is_err());
    let after = store.span_vectors(&["item-b"], model).unwrap().remove("item-b").unwrap();
    assert_eq!(after.len(), 2, "a rejected write leaves the prior span set in place");
    store.delete_span_vectors("item-b", model).unwrap();
    assert!(store.span_vectors(&["item-b"], model).unwrap().is_empty());
}

#[test]
fn reclaim_removes_retired_and_non_serving_rows_only() {
    let (store, raw) = make_store();
    let f = |v: &[f32]| VectorPayload::from_f32(v);
    store.add_payload("i1", 0, &f(&[1.0, 0.0]), "live-v1", "1", NOW).unwrap();
    store.add_payload("i2", 0, &f(&[0.0, 1.0]), "live-v1", "1", NOW).unwrap();
    store.add_payload("i1", 0, &f(&[1.0, 0.0]), "lsa-v1", "1", NOW).unwrap();
    store.add_payload("i2", 0, &f(&[0.0, 1.0]), "fdc-v1", "1", NOW).unwrap();
    // A non-serving generation row for the live model, written raw
    // (generation 7 while the model serves generation 0).
    let mut values = BTreeMap::new();
    values.insert("id".to_string(), TypedValue::Uuid(Uuid::new_v4()));
    values.insert("item_id".to_string(), TypedValue::Text("i3".into()));
    values.insert("vector_index".to_string(), TypedValue::Int(0));
    values.insert("model_id".to_string(), TypedValue::Text("live-v1".into()));
    values.insert("model_version".to_string(), TypedValue::Text("1".into()));
    values.insert("kind".to_string(), TypedValue::Int(1));
    values.insert("dim".to_string(), TypedValue::Int(2));
    values.insert("payload".to_string(), TypedValue::Blob(f(&[1.0, 1.0]).bytes));
    values.insert("scale".to_string(), TypedValue::Null);
    values.insert("filed_at".to_string(), TypedValue::Timestamp(NOW));
    values.insert("generation".to_string(), TypedValue::Int(7));
    raw.row_store().insert("vectors", values).unwrap();

    let (retired, non_serving) = store
        .reclaim_retired_vector_rows(&["lsa-v1", "nmf-v1", "ppmi-v1", "fdc-v1"])
        .unwrap();
    assert_eq!(retired, 2);
    assert_eq!(non_serving, 1);
    let remaining = raw
        .row_store()
        .query_projected("vectors", &["model_id", "generation"], Some(&StoragePredicate::IsTrue), &[], None, None)
        .unwrap();
    assert_eq!(remaining.len(), 2);
    for row in &remaining {
        assert_eq!(row.get("model_id"), Some(&TypedValue::Text("live-v1".into())));
        assert_eq!(row.get("generation"), Some(&TypedValue::Int(0)));
    }
}
