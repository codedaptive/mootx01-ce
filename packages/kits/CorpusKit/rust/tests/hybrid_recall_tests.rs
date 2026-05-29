// Tests for HybridRecall + CorpusKitSync manifest.

use engram_lib::Engram;
use corpus_kit::{recall, BM25Index, BundleStore, Chunk,
              HybridRecallConfiguration, CorpusKitSync};
use corpus_kit_providers::DeterministicTokenizer;
use std::collections::BTreeMap;
use std::sync::Arc;
use persistence_kit::{inmemory::InMemoryStorage, Storage};
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
use substrate_lib::hlc::HLC;
use convergence_kit::{ConflictPolicy, SyncDirection};
use uuid::Uuid;
use vectorkit::VectorStore;

#[test]
fn ragkitsync_manifest_shape_matches_swift() {
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
    // Two storages with shared chunk ids: one for vector store,
    // one for bundle store. The drawer_id in vectorstore is the
    // chunk's UUID string.
    let vector_storage: Arc<dyn Storage> =
        Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let vector_store = VectorStore::open(vector_storage).expect("vector store");
    let bundle_storage: Arc<dyn Storage> =
        Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let bundle_store = BundleStore::open(bundle_storage).expect("bundle store");

    // Build a deterministic corpus of three chunks.
    let texts = ["alpha document", "beta document", "gamma document"];
    let mut chunks: Vec<Chunk> = Vec::new();
    for (i, text) in texts.iter().enumerate() {
        let hlc = HLC { physical_time: i as i64, logical_count: 0, node_id: 1 };
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

    // Index BM25 over the chunks.
    let tokenizer = Arc::new(DeterministicTokenizer::new());
    let bm25 = BM25Index::new(tokenizer);
    bm25.index_documents(chunks.iter().map(|c| (c.id, c.text.as_str())));

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
        &bm25,
        &bundle_store,
        HybridRecallConfiguration::default(),
    )
    .expect("recall");

    // Three chunks indexed, expect three returned.
    assert_eq!(results.len(), 3);
    // The chunk containing "alpha" should rank first (keyword match
    // plus the closest vector distance both point at chunk 0).
    assert_eq!(results[0].chunk.text, "alpha document");
    // Each result should expose both subscores when both passes
    // contribute (for chunk 0 they do).
    assert!(results[0].vector_score.is_some());
}

#[test]
fn hybrid_recall_with_limit_zero_returns_empty() {
    let vector_storage: Arc<dyn Storage> =
        Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let vector_store = VectorStore::open(vector_storage).expect("vector store");
    let bundle_storage: Arc<dyn Storage> =
        Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let bundle_store = BundleStore::open(bundle_storage).expect("bundle store");
    let bm25 = BM25Index::new(Arc::new(DeterministicTokenizer::new()));
    let probe = Engram::new(0, 0, 0, 0);
    let results = recall(
        &probe,
        "anything",
        "test-model",
        0,
        &vector_store,
        &bm25,
        &bundle_store,
        HybridRecallConfiguration::default(),
    )
    .expect("recall");
    assert!(results.is_empty());
}

#[test]
fn hybrid_recall_empty_corpus_returns_empty() {
    let vector_storage: Arc<dyn Storage> =
        Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let vector_store = VectorStore::open(vector_storage).expect("vector store");
    let bundle_storage: Arc<dyn Storage> =
        Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let bundle_store = BundleStore::open(bundle_storage).expect("bundle store");
    let bm25 = BM25Index::new(Arc::new(DeterministicTokenizer::new()));
    let probe = Engram::new(0xFF, 0, 0, 0);
    let results = recall(
        &probe,
        "alpha",
        "test-model",
        5,
        &vector_store,
        &bm25,
        &bundle_store,
        HybridRecallConfiguration::default(),
    )
    .expect("recall");
    assert!(results.is_empty());
}
