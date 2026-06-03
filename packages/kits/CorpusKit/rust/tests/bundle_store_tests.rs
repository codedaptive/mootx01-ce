// Tests for BundleStore (persistence-kit-backed chunks table).

use corpus_kit::{BundleStore, Chunk};
use persistence_kit::{inmemory::InMemoryStorage, Storage};
use std::collections::BTreeMap;
use std::sync::Arc;
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_types::hlc::HLC;
use uuid::Uuid;

fn make_store() -> BundleStore {
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    BundleStore::open(storage).expect("open bundle store")
}

fn sample_chunk(source: &str, offset: usize, text: &str, ts: i64) -> Chunk {
    let hlc = HLC {
        physical_time: ts,
        logical_count: 0,
        node_id: 1,
    };
    let mut metadata = BTreeMap::new();
    metadata.insert("kind".into(), "test".into());
    Chunk::new(
        Uuid::new_v4(),
        source,
        offset,
        text.len(),
        text,
        hlc,
        metadata,
    )
}

#[test]
fn insert_and_get_roundtrip() {
    let store = make_store();
    let c = sample_chunk("src-A", 0, "hello world", 100);
    let target_id = c.id;
    store.insert(&[c.clone()]).expect("insert");
    let fetched = store.get(target_id).expect("get").expect("must exist");
    assert_eq!(fetched.id, target_id);
    assert_eq!(fetched.source_id, "src-A");
    assert_eq!(fetched.text, "hello world");
    assert_eq!(fetched.start_offset, 0);
    assert_eq!(fetched.length, "hello world".len());
}

#[test]
fn get_returns_none_for_unknown_id() {
    let store = make_store();
    let result = store.get(Uuid::new_v4()).expect("get");
    assert!(result.is_none());
}

#[test]
fn chunks_for_source_orders_by_start_offset_ascending() {
    let store = make_store();
    let c1 = sample_chunk("src-B", 200, "second", 200);
    let c2 = sample_chunk("src-B", 0, "first", 100);
    let c3 = sample_chunk("src-B", 100, "middle", 150);
    store.insert(&[c1, c2, c3]).expect("insert");
    let ordered = store.chunks_for_source("src-B").expect("query");
    assert_eq!(ordered.len(), 3);
    assert_eq!(ordered[0].text, "first");
    assert_eq!(ordered[1].text, "middle");
    assert_eq!(ordered[2].text, "second");
}

#[test]
fn get_many_returns_requested_chunks() {
    let store = make_store();
    let c1 = sample_chunk("src-C", 0, "alpha", 1);
    let c2 = sample_chunk("src-C", 10, "beta", 2);
    let c3 = sample_chunk("src-C", 20, "gamma", 3);
    let ids = vec![c1.id, c3.id];
    store.insert(&[c1, c2, c3]).expect("insert");
    let fetched = store.get_many(&ids).expect("get_many");
    assert_eq!(fetched.len(), 2);
    let texts: std::collections::HashSet<&str> = fetched.iter().map(|c| c.text.as_str()).collect();
    assert!(texts.contains("alpha"));
    assert!(texts.contains("gamma"));
    assert!(!texts.contains("beta"));
}

#[test]
fn insert_idempotent_on_duplicate_id() {
    // The chunks table is append-only and content-addressed by id.
    // A second insert of the same id, even with different content, is
    // a silent no-op: the first write wins and the stored row is not
    // mutated. This is the invariant the sync layer's AppendOnly
    // conflict policy relies on.
    let store = make_store();
    let c1 = sample_chunk("src-E", 0, "original", 1);
    let id = c1.id;
    store.insert(&[c1]).expect("first insert");

    let dup = Chunk::new(
        id,
        "src-E",
        0,
        12,
        "changed text",
        HLC {
            physical_time: 200,
            logical_count: 0,
            node_id: 1,
        },
        BTreeMap::new(),
    );
    store
        .insert(&[dup])
        .expect("second insert is a no-op, not an error");

    assert_eq!(store.count().expect("count"), 1);
    let fetched = store.get(id).expect("get").expect("must exist");
    assert_eq!(fetched.text, "original");
}

#[test]
fn metadata_roundtrips_through_json() {
    let store = make_store();
    let hlc = HLC {
        physical_time: 1,
        logical_count: 0,
        node_id: 1,
    };
    let mut metadata = BTreeMap::new();
    metadata.insert("k1".into(), "v1".into());
    metadata.insert("k2".into(), "v2 with spaces".into());
    let c = Chunk::new(
        Uuid::new_v4(),
        "src-meta",
        0,
        4,
        "test",
        hlc,
        metadata.clone(),
    );
    let id = c.id;
    store.insert(&[c]).expect("insert");
    let fetched = store.get(id).expect("get").expect("must exist");
    assert_eq!(fetched.metadata, metadata);
}

#[test]
fn all_chunks_returns_all_inserted() {
    let store = make_store();
    let c1 = sample_chunk("src-F", 0, "one", 1);
    let c2 = sample_chunk("src-G", 0, "two", 2);
    let c3 = sample_chunk("src-H", 0, "three", 3);
    store.insert(&[c1, c2, c3]).expect("insert");
    let all = store.all_chunks().expect("all");
    assert_eq!(all.len(), 3);
}
