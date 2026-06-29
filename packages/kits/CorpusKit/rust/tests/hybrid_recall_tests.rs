// Tests for HybridRecall + CorpusKitSync manifest.
//
// INTELLECTUS LOCK: Tests that call bundle_store.insert (which emits
// corpuskit.ingest.* metrics) or recall (which emits corpuskit.recall.*
// metrics) hold GLOBAL_LOCK for their entire duration. The manifest test
// does not touch emit-capable functions and does not need the lock.

use corpus_kit::{
    recall, default_keyword_tokens, BundleStore, Chunk, CorpusKitSync,
    HybridRecallConfiguration, InvertedIndexStore,
};
use engram_lib::Engram;
use intellectus_lib::Intellectus;
use persistence_kit::{inmemory::InMemoryStorage, Storage};
use rusqlite::Connection;
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, OnceLock};
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
use convergence_kit::{ConflictPolicy, SyncDirection};
use substrate_types::hlc::HLC;
use uuid::Uuid;
use vectorkit::VectorStore;

// Process-wide serialisation lock shared with corpuskit_telemetry_tests.rs
// and bundle_store_tests.rs. All tests that call BundleStore::insert or
// recall hold this lock for their entire duration so that concurrent
// telemetry tests cannot see their emissions in a capturing sink.
static GLOBAL_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

fn global_lock() -> std::sync::MutexGuard<'static, ()> {
    let mutex = GLOBAL_LOCK.get_or_init(|| Mutex::new(()));
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poison) => poison.into_inner(),
    }
}

#[test]
fn ragkitsync_manifest_shape_matches_swift() {
    // Does not call insert or recall — no lock required.
    let manifest = CorpusKitSync::manifest("test-zone");
    assert_eq!(manifest.kit_id, "CorpusKit");
    assert_eq!(manifest.schema_version, 1);
    assert_eq!(manifest.zone_identifier, "test-zone");
    assert_eq!(manifest.tables.len(), 1);
    let chunks_table = &manifest.tables[0];
    assert_eq!(chunks_table.name, "chunks");
    assert_eq!(chunks_table.primary_key_column, "id");
    assert_eq!(chunks_table.direction, SyncDirection::Bidirectional);
    assert_eq!(chunks_table.conflict_policy, ConflictPolicy::AppendOnly);
}

#[test]
fn hybrid_recall_merges_vector_and_keyword_hits() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);

    // Two storages with shared chunk ids: one for vector store,
    // one for bundle store. The item_id in vectorstore is the
    // chunk's UUID string (Lane F rename: drawer_id → item_id).
    let vector_storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let vector_store = VectorStore::open(vector_storage).expect("vector store");
    let bundle_storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let bundle_store = BundleStore::open(bundle_storage).expect("bundle store");

    // Build a deterministic corpus of three chunks.
    let texts = ["alpha document", "beta document", "gamma document"];
    let mut chunks: Vec<Chunk> = Vec::new();
    for (i, text) in texts.iter().enumerate() {
        let hlc = HLC {
            physical_time: i as i64,
            logical_count: 0,
            node_id: 1,
        };
        chunks.push(Chunk::new(
            Uuid::new_v4(),
            "src-1",
            i * 100,
            text.len(),
            *text,
            hlc,
            BTreeMap::new(),
        ));
    }
    bundle_store.insert(&chunks).expect("insert chunks");

    // Index keyword lane (InvertedIndexStore, SQLite-backed) over the chunks.
    // InMemory storage → in-memory SQLite connection for the sidecar.
    let inverted_index = InvertedIndexStore::open(Connection::open_in_memory().expect("conn"))
        .expect("open inverted index");
    for chunk in &chunks {
        let tokens = default_keyword_tokens(chunk.text.as_str());
        inverted_index.index(&chunk.id.to_string(), &tokens, "").expect("index chunk");
    }

    // Seed VectorStore with engrams whose Hamming distance to the
    // probe corresponds to chunk index: chunk 0 closest, chunk 2
    // farthest. Drawer id = chunk.id.to_string() per the join
    // convention.
    let engrams = [
        Engram::new(0x1, 0, 0, 0),
        Engram::new(0x3, 0, 0, 0),
        Engram::new(0x7, 0, 0, 0),
    ];
    for (chunk, eng) in chunks.iter().zip(engrams.iter()) {
        vector_store
            .add_vector(&chunk.id.to_string(), eng, "test-model", "1.0", 0)
            .expect("add_vector");
    }
    let probe = Engram::new(0, 0, 0, 0);

    let results = recall(
        &probe,
        "alpha",
        "test-model",
        3,
        &vector_store,
        &inverted_index,
        &bundle_store,
        HybridRecallConfiguration::default(),
    )
    .expect("recall");

    // Three chunks indexed, expect three returned.
    assert_eq!(results.len(), 3);
    // The chunk containing "alpha" should rank first (keyword match
    // plus the closest vector distance both point at chunk 0).
    assert_eq!(results[0].chunk.text, "alpha document");
    // chunk 0 contributes a vector hit; only vector_score is asserted.
    // The keyword subscore is not asserted in this test.
    assert!(results[0].vector_score.is_some());
}

#[test]
fn hybrid_recall_with_limit_zero_returns_empty() {
    // limit == 0 returns early before any emit-capable call — no lock required.
    let vector_storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let vector_store = VectorStore::open(vector_storage).expect("vector store");
    let bundle_storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let bundle_store = BundleStore::open(bundle_storage).expect("bundle store");
    // Empty inverted index (limit==0 returns before the keyword lane is consulted).
    let inverted_index = InvertedIndexStore::open(Connection::open_in_memory().expect("conn"))
        .expect("open inverted index");
    let probe = Engram::new(0, 0, 0, 0);
    let results = recall(
        &probe,
        "anything",
        "test-model",
        0,
        &vector_store,
        &inverted_index,
        &bundle_store,
        HybridRecallConfiguration::default(),
    )
    .expect("recall");
    assert!(results.is_empty());
}

#[test]
fn hybrid_recall_empty_corpus_returns_empty() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let vector_storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let vector_store = VectorStore::open(vector_storage).expect("vector store");
    let bundle_storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let bundle_store = BundleStore::open(bundle_storage).expect("bundle store");
    // Empty inverted index — no chunks ingested, corpus is empty.
    let inverted_index = InvertedIndexStore::open(Connection::open_in_memory().expect("conn"))
        .expect("open inverted index");
    let probe = Engram::new(0xFF, 0, 0, 0);
    let results = recall(
        &probe,
        "alpha",
        "test-model",
        5,
        &vector_store,
        &inverted_index,
        &bundle_store,
        HybridRecallConfiguration::default(),
    )
    .expect("recall");
    assert!(results.is_empty());
}

// P3-secfix: UUID canonicalization fusion contract.
//
// HybridRecall::recall() processes vector hits (item_id: String, may be
// uppercase from Apple-side exports) and keyword hits (Uuid-typed, always
// lowercase via Uuid::to_string()). The P3 fix normalizes both through
// Uuid::parse_str → to_string() so they share the same lowercase-hyphenated
// key and fuse correctly. We verify the contract against fuse() directly:
// the same UUID expressed in different cases must produce ONE FusedHit.
#[test]
fn uuid_case_mismatch_fuses_to_single_entry() {
    use corpus_kit::{fuse, LaneTag};
    use std::collections::HashMap;
    use uuid::Uuid;

    let id = Uuid::new_v4();
    // Rust canonical = lowercase hyphenated (Uuid::to_string()).
    let lower_id = id.to_string();
    // Simulate a vector hit with an uppercase UUID string (e.g. from Apple).
    let upper_id = lower_id.to_ascii_uppercase();

    // Confirm that both parse to the same UUID and re-emit the same canonical
    // lowercase form — that is what hybrid_recall.rs now does after P3-secfix.
    let canonical_vec = Uuid::parse_str(&upper_id).unwrap().to_string();
    let canonical_kw  = Uuid::parse_str(&lower_id).unwrap().to_string();
    assert_eq!(canonical_vec, canonical_kw,
        "UUID parse+to_string must yield the same lowercase key regardless of input case");

    // Feed both through fuse() using their canonical keys.
    // A single item seen in BOTH lanes must produce ONE FusedHit.
    let mut ranked_lists = HashMap::new();
    ranked_lists.insert(LaneTag::BinaryDense, vec![(canonical_vec.clone(), 1usize)]);
    ranked_lists.insert(LaneTag::Sparse, vec![(canonical_kw.clone(), 1usize)]);
    let weights = [(LaneTag::BinaryDense, 0.6f32), (LaneTag::Sparse, 0.4f32)]
        .into_iter()
        .collect::<HashMap<_, _>>();
    let fused = fuse(&ranked_lists, None, &weights, 60.0);
    assert_eq!(fused.len(), 1,
        "same UUID in both lanes must fuse to exactly one FusedHit; got {:?}", fused);
}
