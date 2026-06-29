// Tests for BundleStore (persistence-kit-backed chunks table).
//
// INTELLECTUS LOCK: All tests that call store.insert (which emits
// corpuskit.ingest.* metrics via BundleStore::insert) hold GLOBAL_LOCK
// for their entire duration. This prevents concurrent telemetry tests
// from seeing spurious emissions in their capturing sinks.
//
// Lock poisoning: if a prior test panicked while holding the lock,
// `lock()` returns a PoisonError. We recover with `into_inner()` so
// subsequent tests can still run.

use corpus_kit::{BundleStore, Chunk};
use intellectus_lib::Intellectus;
use persistence_kit::{inmemory::InMemoryStorage, Storage};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, OnceLock};
use substrate_types::merkle_root::MerkleRoot;
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_types::hlc::HLC;
use uuid::Uuid;

// Process-wide serialisation lock shared with corpuskit_telemetry_tests.rs.
// All tests that call BundleStore::insert hold this lock for their entire
// duration so that concurrent enabled-path telemetry tests cannot see
// their emissions in a capturing sink.
static GLOBAL_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

fn global_lock() -> std::sync::MutexGuard<'static, ()> {
    let mutex = GLOBAL_LOCK.get_or_init(|| Mutex::new(()));
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poison) => poison.into_inner(),
    }
}

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
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let store = make_store();
    let c = sample_chunk("src-A", 0, "hello world", 100);
    let target_id = c.id;
    store.insert(std::slice::from_ref(&c)).expect("insert");
    let fetched = store.get(target_id, None).expect("get").expect("must exist");
    assert_eq!(fetched.id, target_id);
    assert_eq!(fetched.source_id, "src-A");
    assert_eq!(fetched.text, "hello world");
    assert_eq!(fetched.start_offset, 0);
    assert_eq!(fetched.length, "hello world".len());
}

#[test]
fn get_returns_none_for_unknown_id() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let store = make_store();
    let result = store.get(Uuid::new_v4(), None).expect("get");
    assert!(result.is_none());
}

#[test]
fn chunks_for_source_orders_by_start_offset_ascending() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let store = make_store();
    let c1 = sample_chunk("src-B", 200, "second", 200);
    let c2 = sample_chunk("src-B", 0, "first", 100);
    let c3 = sample_chunk("src-B", 100, "middle", 150);
    store.insert(&[c1, c2, c3]).expect("insert");
    let ordered = store.chunks_for_source("src-B", None).expect("query");
    assert_eq!(ordered.len(), 3);
    assert_eq!(ordered[0].text, "first");
    assert_eq!(ordered[1].text, "middle");
    assert_eq!(ordered[2].text, "second");
}

#[test]
fn get_many_returns_requested_chunks() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let store = make_store();
    let c1 = sample_chunk("src-C", 0, "alpha", 1);
    let c2 = sample_chunk("src-C", 10, "beta", 2);
    let c3 = sample_chunk("src-C", 20, "gamma", 3);
    let ids = vec![c1.id, c3.id];
    store.insert(&[c1, c2, c3]).expect("insert");
    let fetched = store.get_many(&ids, None).expect("get_many");
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
    let _guard = global_lock();
    Intellectus::set_enabled(false);
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

    assert_eq!(store.count(None).expect("count"), 1);
    let fetched = store.get(id, None).expect("get").expect("must exist");
    assert_eq!(fetched.text, "original");
}

#[test]
fn metadata_roundtrips_through_json() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
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
    let fetched = store.get(id, None).expect("get").expect("must exist");
    assert_eq!(fetched.metadata, metadata);
}

#[test]
fn all_chunks_returns_all_inserted() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let store = make_store();
    let c1 = sample_chunk("src-F", 0, "one", 1);
    let c2 = sample_chunk("src-G", 0, "two", 2);
    let c3 = sample_chunk("src-H", 0, "three", 3);
    store.insert(&[c1, c2, c3]).expect("insert");
    let all = store.all_chunks(None).expect("all");
    assert_eq!(all.len(), 3);
}

#[test]
fn corpus_merkle_root_empty_before_insert() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let store = make_store();
    let root = store.corpus_merkle_root("nonexistent").expect("query");
    assert_eq!(root, MerkleRoot::EMPTY);
}

#[test]
fn corpus_merkle_root_updates_after_insert() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let store = make_store();
    let c1 = sample_chunk("src-merkle", 0, "alpha", 1);
    store.insert(&[c1]).expect("insert");
    let root1 = store.corpus_merkle_root("src-merkle").expect("query");
    // After inserting one chunk, the root is no longer empty.
    assert_ne!(root1, MerkleRoot::EMPTY);

    // Insert a second chunk into the same source — root changes.
    let c2 = sample_chunk("src-merkle", 10, "beta", 2);
    store.insert(&[c2]).expect("insert");
    let root2 = store.corpus_merkle_root("src-merkle").expect("query");
    assert_ne!(root2, MerkleRoot::EMPTY);
    assert_ne!(root2, root1, "root must change when a chunk is added");
}

#[test]
fn corpus_merkle_root_differs_per_source() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let store = make_store();
    let c1 = sample_chunk("src-X", 0, "hello", 1);
    let c2 = sample_chunk("src-Y", 0, "world", 2);
    store.insert(&[c1, c2]).expect("insert");
    let root_x = store.corpus_merkle_root("src-X").expect("query");
    let root_y = store.corpus_merkle_root("src-Y").expect("query");
    assert_ne!(root_x, MerkleRoot::EMPTY);
    assert_ne!(root_y, MerkleRoot::EMPTY);
    assert_ne!(root_x, root_y, "different corpora must have different roots");
}

#[test]
fn global_corpus_merkle_root_reflects_all_corpora() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let store = make_store();
    let empty_global = store.global_corpus_merkle_root().expect("global");
    assert_eq!(empty_global, MerkleRoot::EMPTY);

    let c1 = sample_chunk("src-G1", 0, "data", 1);
    store.insert(&[c1]).expect("insert");
    let global1 = store.global_corpus_merkle_root().expect("global");
    assert_ne!(global1, MerkleRoot::EMPTY);

    // Adding a chunk to a different source changes the global root.
    let c2 = sample_chunk("src-G2", 0, "more", 2);
    store.insert(&[c2]).expect("insert");
    let global2 = store.global_corpus_merkle_root().expect("global");
    assert_ne!(global2, global1, "global root must change when a new corpus is added");
}
