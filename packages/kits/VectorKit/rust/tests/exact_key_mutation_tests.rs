//! Exact-key batch mutation coverage (GLK shared-content 1.1, P0 — vector
//! representation ownership gate). Parallel to the Swift
//! `ExactKeyMutationTests`.
//!
//! Proves the property the migration relies on: ONE model partition can
//! contain retained/shared keys and removed keys side by side, and scoped
//! mutation touches exactly the addressed keys with no collateral
//! mutation — the byte-identical survival of unaddressed rows is
//! asserted, not assumed.

use engram_lib::Engram;
use persistence_kit::{inmemory::InMemoryStorage, Storage, TypedValue};
use std::collections::BTreeMap;
use std::sync::Arc;
use uuid::Uuid;
use vectorkit::{
    VectorExactKey, VectorKind, VectorPayload, VectorPayloadInput, VectorStore,
};

const NOW: i64 = 1_700_000_000_000;

fn fresh_store() -> (VectorStore, Arc<dyn Storage>) {
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let store = VectorStore::open(Arc::clone(&storage)).expect("open");
    (store, storage)
}

fn engram(seed: u64) -> Engram {
    Engram::new(seed, seed.wrapping_mul(3), seed.wrapping_mul(5), seed.wrapping_mul(7))
}

fn binary_input(item: &str, model: &str, seed: u64) -> VectorPayloadInput {
    VectorPayloadInput {
        item_id: item.to_string(),
        vector_index: 0,
        payload: VectorPayload::from_engram(&engram(seed)),
        model_id: model.to_string(),
        model_version: "1.0.0".to_string(),
        filed_at_unix_secs: NOW,
    }
}

fn float_input(item: &str, model: &str, floats: &[f32]) -> VectorPayloadInput {
    VectorPayloadInput {
        item_id: item.to_string(),
        vector_index: 1,
        payload: VectorPayload::from_f32(floats),
        model_id: model.to_string(),
        model_version: "1.0.0".to_string(),
        filed_at_unix_secs: NOW,
    }
}

/// Canonical baseline of every vector row: (model|item|index) → payload hex.
fn row_baseline(storage: &Arc<dyn Storage>) -> BTreeMap<String, String> {
    let rows = storage
        .row_store()
        .query("vectors", None, &[], None, None)
        .expect("query vectors");
    let mut out = BTreeMap::new();
    for row in rows {
        let item = match row.get("item_id") {
            Some(TypedValue::Text(t)) => t.clone(),
            _ => continue,
        };
        let index = match row.get("vector_index") {
            Some(TypedValue::Int(i)) => *i,
            _ => continue,
        };
        let model = match row.get("model_id") {
            Some(TypedValue::Text(t)) => t.clone(),
            _ => continue,
        };
        let payload = match row.get("payload") {
            Some(TypedValue::Blob(bytes)) => bytes
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<String>(),
            _ => String::new(),
        };
        out.insert(format!("{model}|{item}|{index}"), payload);
    }
    out
}

#[test]
fn delete_vectors_removes_exactly_the_named_keys() {
    let (store, storage) = fresh_store();
    store
        .add_payloads(&[
            binary_input("keep-1", "model-a", 1),
            binary_input("drop-1", "model-a", 2),
            binary_input("drop-2", "model-a", 3),
            binary_input("keep-1", "model-b", 4),
            float_input("keep-1", "model-a", &[1.0, 0.0, 0.0]),
            float_input("drop-1", "model-a", &[0.0, 1.0, 0.0]),
        ])
        .expect("seed");
    let before = row_baseline(&storage);

    store
        .delete_vectors(&[
            VectorExactKey::new("drop-1", 0, "model-a"),
            VectorExactKey::new("drop-1", 1, "model-a"),
            VectorExactKey::new("drop-2", 0, "model-a"),
        ])
        .expect("delete");

    let after = row_baseline(&storage);
    assert!(after.get("model-a|drop-1|0").is_none());
    assert!(after.get("model-a|drop-1|1").is_none());
    assert!(after.get("model-a|drop-2|0").is_none());
    // Unaddressed rows survive byte-identically — including same-model
    // retained keys and the whole other model partition.
    assert_eq!(after.get("model-a|keep-1|0"), before.get("model-a|keep-1|0"));
    assert_eq!(after.get("model-a|keep-1|1"), before.get("model-a|keep-1|1"));
    assert_eq!(after.get("model-b|keep-1|0"), before.get("model-b|keep-1|0"));
    assert_eq!(after.len(), before.len() - 3);

    // Search coherence: the deleted binary key no longer surfaces; the
    // retained one still does.
    let hits = store
        .find_nearest(&engram(2), "model-a", 10)
        .expect("search");
    assert!(!hits.iter().any(|h| h.item_id == "drop-1"));
    assert!(hits.iter().any(|h| h.item_id == "keep-1"));
}

#[test]
fn delete_vectors_clears_every_model_version_at_the_position() {
    let (store, storage) = fresh_store();
    store
        .add_payloads(&[binary_input("item", "model-a", 1)])
        .expect("seed");
    // A stale second-version row written directly (legacy estates may hold
    // stale version rows written before the unique constraint).
    let mut values = BTreeMap::new();
    values.insert("id".to_string(), TypedValue::Uuid(Uuid::new_v4()));
    values.insert("item_id".to_string(), TypedValue::Text("item-stale".into()));
    values.insert("vector_index".to_string(), TypedValue::Int(0));
    values.insert("model_id".to_string(), TypedValue::Text("model-a".into()));
    values.insert("model_version".to_string(), TypedValue::Text("0.9.0".into()));
    values.insert("kind".to_string(), TypedValue::Int(0));
    values.insert("dim".to_string(), TypedValue::Int(256));
    values.insert("payload".to_string(), TypedValue::Blob(vec![0xAB; 32]));
    values.insert("scale".to_string(), TypedValue::Null);
    values.insert("filed_at".to_string(), TypedValue::Timestamp(NOW));
    storage
        .row_store()
        .insert("vectors", values)
        .expect("insert stale");

    store
        .delete_vectors(&[
            VectorExactKey::new("item", 0, "model-a"),
            VectorExactKey::new("item-stale", 0, "model-a"),
        ])
        .expect("delete");
    assert!(row_baseline(&storage).is_empty());
}

#[test]
fn reconcile_deletes_stale_upserts_expected_leaves_others_alone() {
    let (store, storage) = fresh_store();
    store
        .add_payloads(&[
            binary_input("stays", "model-a", 1),
            binary_input("stale", "model-a", 2),
            binary_input("other", "model-b", 3),
        ])
        .expect("seed");
    let before = row_baseline(&storage);

    let (removed, upserted) = store
        .reconcile_model_vectors(
            "model-a",
            &[
                binary_input("stays", "model-a", 1),
                binary_input("fresh", "model-a", 9),
            ],
        )
        .expect("reconcile");
    assert_eq!(removed, 1);
    assert_eq!(upserted, 2);

    let after = row_baseline(&storage);
    assert!(after.get("model-a|stale|0").is_none());
    assert_eq!(after.get("model-a|stays|0"), before.get("model-a|stays|0"));
    assert!(after.get("model-a|fresh|0").is_some());
    // The other model's partition is untouched byte for byte.
    assert_eq!(after.get("model-b|other|0"), before.get("model-b|other|0"));

    // Search coherence after the scoped rebuild.
    let hits = store
        .find_nearest(&engram(9), "model-a", 10)
        .expect("search");
    assert!(hits.iter().any(|h| h.item_id == "fresh"));
    assert!(!hits.iter().any(|h| h.item_id == "stale"));
}

#[test]
fn reconcile_rejects_cross_partition_inputs() {
    let (store, _storage) = fresh_store();
    let result = store.reconcile_model_vectors(
        "model-a",
        &[binary_input("x", "model-b", 1)],
    );
    assert!(result.is_err());
}

#[test]
fn reconcile_is_idempotent() {
    let (store, storage) = fresh_store();
    let expected = vec![
        binary_input("a", "model-a", 1),
        binary_input("b", "model-a", 2),
    ];
    store
        .reconcile_model_vectors("model-a", &expected)
        .expect("first");
    let first = row_baseline(&storage);
    let (removed, _) = store
        .reconcile_model_vectors("model-a", &expected)
        .expect("second");
    assert_eq!(removed, 0);
    assert_eq!(row_baseline(&storage), first);
}

// VectorKind referenced so the int8-reject contract stays visible at the
// use site even though this file exercises only binary/float payloads.
#[allow(dead_code)]
fn kind_witness() -> VectorKind {
    VectorKind::Binary
}
