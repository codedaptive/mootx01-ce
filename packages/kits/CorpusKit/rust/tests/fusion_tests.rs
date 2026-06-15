// Fusion integration tests and HybridRecall conformance gate.
//
// Verifies:
//   1. `fuse_scored` (re-exported) produces correct N-lane results.
//   2. Tie-break: equal fused scores → item_id ASC (universal rule).
//   3. Per-lane raw scores flow through to FusedHit.per_lane.
//   4. HybridRecall conformance: the refactored `recall` produces the
//      same ranking as the documented RRF formula for the standard
//      two-lane config (vector_weight=0.6, keyword_weight=0.4, rrf_k=60).
//
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

use corpus_kit::{fuse, fuse_scored, LaneTag};
use corpus_kit::{recall, BM25Index, BundleStore, Chunk, HybridRecallConfiguration};
use corpus_kit_providers::DeterministicTokenizer;
use engram_lib::Engram;
use intellectus_lib::Intellectus;
use persistence_kit::{inmemory::InMemoryStorage, Storage};
use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex, OnceLock};
use substrate_types::hlc::HLC;
use uuid::Uuid;
use vectorkit::VectorStore;

// Process-wide serialisation lock: shared with hybrid_recall_tests.rs and
// corpuskit_telemetry_tests.rs to prevent concurrent telemetry-enabled tests
// from leaking metrics into a capturing sink.
static GLOBAL_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

fn global_lock() -> std::sync::MutexGuard<'static, ()> {
    let mutex = GLOBAL_LOCK.get_or_init(|| Mutex::new(()));
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poison) => poison.into_inner(),
    }
}

// ─── fuse_scored: arbitrary N-lane ───────────────────────────────────────────

#[test]
fn fusion_n_lane_arbitrary_weights() {
    // Three lanes with equal weights.
    // item-x is rank 1 in all three → accumulates the most.
    // item-y is rank 2 in binaryDense + lateInteraction.
    // item-z is rank 2 in sparse only.
    let mut scored: HashMap<LaneTag, Vec<(String, f32)>> = HashMap::new();
    scored.insert(
        LaneTag::BinaryDense,
        vec![
            ("item-x".to_string(), 5.0),
            ("item-y".to_string(), 3.0),
        ],
    );
    scored.insert(
        LaneTag::Sparse,
        vec![
            ("item-x".to_string(), 4.0),
            ("item-z".to_string(), 2.0),
        ],
    );
    scored.insert(
        LaneTag::LateInteraction,
        vec![
            ("item-x".to_string(), 6.0),
            ("item-y".to_string(), 2.5),
        ],
    );
    let weights = {
        let mut m = HashMap::new();
        m.insert(LaneTag::BinaryDense, 1.0_f32);
        m.insert(LaneTag::Sparse, 1.0_f32);
        m.insert(LaneTag::LateInteraction, 1.0_f32);
        m
    };
    let hits = fuse_scored(&scored, &weights, 60.0);
    assert_eq!(hits.len(), 3, "three distinct items");
    assert_eq!(hits[0].item_id, "item-x", "item-x in all three lanes ranks first");

    // item-y is in two lanes at rank 2, item-z is in one lane at rank 2.
    // item-y score: 1/62 + 1/62 = 2/62; item-z score: 1/62 → y > z.
    let item_y = hits.iter().find(|h| h.item_id == "item-y").unwrap();
    let item_z = hits.iter().find(|h| h.item_id == "item-z").unwrap();
    assert!(
        item_y.fused_score > item_z.fused_score,
        "item-y (two lanes) beats item-z (one lane)"
    );
}

// ─── Tie-break ────────────────────────────────────────────────────────────────

#[test]
fn fusion_tie_break_item_id_ascending() {
    // Force identical fused scores by assigning the same rank in the same
    // lane to two items via the primary `fuse` entry point.
    let mut ranked: HashMap<LaneTag, Vec<(String, usize)>> = HashMap::new();
    ranked.insert(
        LaneTag::Sparse,
        vec![
            ("zzz-item".to_string(), 1),
            ("aaa-item".to_string(), 1),
        ],
    );
    let weights = {
        let mut m = HashMap::new();
        m.insert(LaneTag::Sparse, 1.0_f32);
        m
    };
    let hits = fuse(&ranked, None, &weights, 60.0);
    assert_eq!(hits.len(), 2);
    // Both have identical fused scores; tie-break = item_id ASC.
    assert_eq!(hits[0].item_id, "aaa-item");
    assert_eq!(hits[1].item_id, "zzz-item");
}

// ─── Per-lane scores ──────────────────────────────────────────────────────────

#[test]
fn fusion_per_lane_scores_flow_through() {
    let mut scored: HashMap<LaneTag, Vec<(String, f32)>> = HashMap::new();
    scored.insert(LaneTag::BinaryDense, vec![("item-p".to_string(), 9.0)]);
    scored.insert(LaneTag::Sparse, vec![("item-p".to_string(), 4.5)]);
    let weights = {
        let mut m = HashMap::new();
        m.insert(LaneTag::BinaryDense, 0.6_f32);
        m.insert(LaneTag::Sparse, 0.4_f32);
        m
    };
    let hits = fuse_scored(&scored, &weights, 60.0);
    assert_eq!(hits.len(), 1);
    let dense = hits[0].per_lane.get(&LaneTag::BinaryDense).copied().unwrap_or(0.0);
    let sparse = hits[0].per_lane.get(&LaneTag::Sparse).copied().unwrap_or(0.0);
    assert!((dense - 9.0).abs() < 1e-5, "dense raw score");
    assert!((sparse - 4.5).abs() < 1e-5, "sparse raw score");
}

// ─── HybridRecall conformance ─────────────────────────────────────────────────
//
// Pin the documented RRF formula for the standard two-lane config
// (vector_weight=0.6, keyword_weight=0.4, rrf_k=60):
//
//   item-A: vector rank 1, keyword rank 2 → fused = 0.6/61 + 0.4/62
//   item-B: vector rank 2, keyword rank 1 → fused = 0.6/62 + 0.4/61
//   item-C: vector rank 3 only            → fused = 0.6/63
//
// Expected order: item-A > item-B > item-C.
// (0.6*62 + 0.4*61) / (61*62) vs (0.6*61 + 0.4*62) / (61*62)
// numerators: 37.2+24.4=61.6 vs 36.6+24.8=61.4 → A > B, not a tie.

#[test]
fn hybrid_recall_rrf_formula_conformance() {
    let rrf_k: f32 = 60.0;
    let vw: f32 = 0.6;
    let kw: f32 = 0.4;

    let score_a = vw / (rrf_k + 1.0) + kw / (rrf_k + 2.0);
    let score_b = vw / (rrf_k + 2.0) + kw / (rrf_k + 1.0);
    let score_c = vw / (rrf_k + 3.0);

    let mut ranked: HashMap<LaneTag, Vec<(String, usize)>> = HashMap::new();
    ranked.insert(
        LaneTag::BinaryDense,
        vec![
            ("item-A".to_string(), 1),
            ("item-B".to_string(), 2),
            ("item-C".to_string(), 3),
        ],
    );
    ranked.insert(
        LaneTag::Sparse,
        vec![
            ("item-B".to_string(), 1),
            ("item-A".to_string(), 2),
        ],
    );
    let weights = {
        let mut m = HashMap::new();
        m.insert(LaneTag::BinaryDense, vw);
        m.insert(LaneTag::Sparse, kw);
        m
    };
    let hits = fuse(&ranked, None, &weights, rrf_k);
    assert_eq!(hits.len(), 3);

    let eps = 1e-5_f32;
    let hit_a = hits.iter().find(|h| h.item_id == "item-A").unwrap();
    let hit_b = hits.iter().find(|h| h.item_id == "item-B").unwrap();
    let hit_c = hits.iter().find(|h| h.item_id == "item-C").unwrap();

    assert!((hit_a.fused_score - score_a).abs() < eps, "item-A formula");
    assert!((hit_b.fused_score - score_b).abs() < eps, "item-B formula");
    assert!((hit_c.fused_score - score_c).abs() < eps, "item-C formula");

    // Order: item-A > item-B > item-C.
    assert_eq!(hits[0].item_id, "item-A");
    assert_eq!(hits[1].item_id, "item-B");
    assert_eq!(hits[2].item_id, "item-C");
}

// ─── HybridRecall end-to-end conformance (InMemory) ──────────────────────────
//
// Runs the refactored HybridRecall.recall end-to-end and verifies
// the same behavioral contract as the Swift SQLite conformance test:
//   - three chunks, "alpha document" has best vector proximity AND best
//     keyword match for query "alpha" → it must rank first.
//   - results are score descending.
//   - top result has a non-nil vector_score (it contributed a vector hit).
//
// Uses InMemoryStorage (no SQLite on the Rust side for integration tests;
// the Swift test covers SQLite). The lock prevents telemetry leakage.

#[test]
fn hybrid_recall_conformance_end_to_end() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);

    let vector_storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let vector_store = VectorStore::open(vector_storage).expect("vector store");
    let bundle_storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let bundle_store = BundleStore::open(bundle_storage).expect("bundle store");

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

    let tokenizer = Arc::new(DeterministicTokenizer::new());
    let mut bm25 = BM25Index::new(tokenizer);
    bm25.index_documents(chunks.iter().map(|c| (c.id, c.text.as_str())));

    // Probe is all-zeros; Hamming distances are popcount(engram) = 1, 2, 3.
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

    assert_eq!(results.len(), 3, "all three chunks returned");
    assert_eq!(
        results[0].chunk.text, "alpha document",
        "alpha document ranks first (best vector proximity + keyword match)"
    );
    // Results are score descending.
    assert!(results[0].score >= results[1].score);
    assert!(results[1].score >= results[2].score);
    // Top result should expose a non-None vector_score.
    assert!(results[0].vector_score.is_some(), "vector_score non-nil for top result");
}

// ─── W2: Duplicate item in lane deduplicates to first (best-rank) occurrence ──

/// A lane list containing the same item_id twice must produce the same fused
/// score as a deduplicated list with that item appearing once. The second
/// occurrence must NOT double-count the RRF contribution.
#[test]
fn duplicate_item_in_lane_deduplicates_to_first_occurrence() {
    let mut with_duplicate: HashMap<LaneTag, Vec<(String, usize)>> = HashMap::new();
    with_duplicate.insert(
        LaneTag::Sparse,
        vec![
            ("item-x".to_string(), 1),
            ("item-x".to_string(), 2), // duplicate; must be ignored
        ],
    );
    let mut without_duplicate: HashMap<LaneTag, Vec<(String, usize)>> = HashMap::new();
    without_duplicate.insert(
        LaneTag::Sparse,
        vec![("item-x".to_string(), 1)],
    );
    let weights = {
        let mut m = HashMap::new();
        m.insert(LaneTag::Sparse, 1.0_f32);
        m
    };
    let hits_dup    = fuse(&with_duplicate,    None, &weights, 60.0);
    let hits_no_dup = fuse(&without_duplicate, None, &weights, 60.0);

    assert_eq!(hits_dup.len(), 1, "item-x deduped to one result");
    assert_eq!(hits_no_dup.len(), 1);
    let eps = 1e-6_f32;
    assert!(
        (hits_dup[0].fused_score - hits_no_dup[0].fused_score).abs() < eps,
        "fused score with duplicate ({}) must equal score without duplicate ({})",
        hits_dup[0].fused_score, hits_no_dup[0].fused_score
    );
}

// ─── W3: Distance-0 recall produces non-None vector_score ─────────────────────

/// When the probe Engram is identical to a stored engram (Hamming distance 0),
/// vector_score in ScoredChunk must be Some(0.0), not None.
/// Previously the nil-for-zero convention mapped distance-0 to None.
#[test]
fn distance_zero_probe_produces_non_none_vector_score() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);

    let vector_storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let vector_store = VectorStore::open(vector_storage).expect("vector store");
    let bundle_storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let bundle_store = BundleStore::open(bundle_storage).expect("bundle store");

    let now_hlc = HLC { physical_time: 0, logical_count: 0, node_id: 1 };
    let chunk = Chunk::new(
        Uuid::new_v4(),
        "src-d0",
        0,
        14,
        "distance zero",
        now_hlc,
        BTreeMap::new(),
    );
    bundle_store.insert(&[chunk.clone()]).expect("insert chunk");

    let tokenizer = Arc::new(DeterministicTokenizer::new());
    let mut bm25 = BM25Index::new(tokenizer);
    bm25.index_documents(std::iter::once((chunk.id, chunk.text.as_str())));

    // Store the engram and use the IDENTICAL engram as the probe → distance 0.
    let stored_engram = Engram::new(0xCAFE_BABE, 0, 0, 0);
    vector_store
        .add_vector(&chunk.id.to_string(), &stored_engram, "test-model", "1.0", 0)
        .expect("add_vector");

    let probe = stored_engram; // identical → distance 0
    let results = recall(
        &probe,
        "distance zero",
        "test-model",
        5,
        &vector_store,
        &bm25,
        &bundle_store,
        HybridRecallConfiguration::default(),
    )
    .expect("recall");

    assert_eq!(results.len(), 1, "one chunk in corpus, one result expected");
    // vector_score must be Some: distance-0 is the best possible match, not a miss.
    assert!(
        results[0].vector_score.is_some(),
        "distance-0 match must produce Some(vector_score), got None"
    );
    // The raw Hamming distance is 0 → raw score is 0.0.
    if let Some(vs) = results[0].vector_score {
        assert!(
            vs.abs() < 1e-6,
            "distance-0 raw vector_score must be 0.0, got {}",
            vs
        );
    }
}

