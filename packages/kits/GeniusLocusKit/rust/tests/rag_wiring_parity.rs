// rag_wiring_parity.rs — conformance gate for the GLK_RAG_WIRING_001
// Rust parity changes.
//
// Mirrors `RAGWiringTests.swift`. Covers:
//
// 1. ExternalCorpus::hybrid_recall routes through the canonical-content engine and
//    returns results for ingested content.
// 2. ExternalCorpus::hybrid_recall returns empty vecs for empty-content
//    entries.
// 3. ExternalCorpus::hybrid_recall on an empty engine returns empty results.
// 4. VectorSimilaritySignal with pre-populated vectors emits real
//    AssociateFrames for pairs within the proximity threshold.
// 5. VectorSimilaritySignal does not emit AssociateFrames for distant pairs.

use std::sync::Arc;

use genius_locus_kit::{ExternalCorpus, ExternalEntry, VectorSimilaritySignal};
use genius_locus_kit::{SchedulerNoopDispatcher, SerialLaneScheduler};
use genius_locus_kit::SchedulerSignalRouteOutcome as SignalRouteOutcome;
use genius_locus_kit::SchedulerSignalTrigger as SignalTrigger;

use corpus_kit::{CorpusContentEngine, EmbeddingModelConfig};
use persistence_kit::inmemory::InMemoryStorage;
use queuekit::{PersistenceKitBackend, QueueBackend, QueueKit};
use substrate_types::hlc::HLCGenerator;
use substrate_types::Fingerprint256;
use vectorkit::VectorStore;

const T0_MILLIS: i64 = 1_700_000_000_000;
const T0_NANOS: i64 = T0_MILLIS * 1_000_000;
const NANOS_PER_SEC: i64 = 1_000_000_000;

fn make_storage() -> Arc<InMemoryStorage> {
    Arc::new(InMemoryStorage::with_estate(uuid::Uuid::new_v4()))
}

fn make_vector_store() -> Arc<VectorStore> {
    // Use VectorStore::open to apply the vectors schema on the InMemoryStorage.
    Arc::new(VectorStore::open(make_storage()).expect("VectorStore::open"))
}

fn inmem_signals_queue() -> (QueueKit<Box<dyn QueueBackend>>, HLCGenerator) {
    let store_id = uuid::Uuid::from_u128(0x5348_4544_5545_5245_0000_0000_0000_0003);
    let storage = std::sync::Arc::new(InMemoryStorage::with_estate(store_id));
    PersistenceKitBackend::open_schema(storage.as_ref())
        .expect("InMemoryStorage open_schema cannot fail");
    let backend = PersistenceKitBackend::new(storage);
    let queue: QueueKit<Box<dyn QueueBackend>> =
        QueueKit::new(Box::new(backend) as Box<dyn QueueBackend>);
    (queue, HLCGenerator::new(1))
}

fn fire_spec(
    spec: genius_locus_kit::SchedulerSignalSpec,
) -> genius_locus_kit::SchedulerSignalReport {
    let cadence = match &spec.trigger {
        SignalTrigger::Interval { seconds } => seconds.as_secs(),
        _ => panic!("expected interval trigger"),
    };
    let (queue, hlc) = inmem_signals_queue();
    let mut scheduler = SerialLaneScheduler::new(
        "rag-test".to_string(),
        SchedulerNoopDispatcher,
        queue,
        None,
        hlc,
    );
    let id = scheduler.register(spec, T0_NANOS);
    scheduler.tick(T0_NANOS + (cadence as i64 + 1) * NANOS_PER_SEC);
    scheduler
        .report()
        .into_iter()
        .find(|r| r.signal_id == id)
        .expect("registered signal appears in report")
}

// MARK: - ExternalCorpus parity tests

#[test]
fn hybrid_recall_returns_results_for_ingested_content() {
    let corpus = CorpusContentEngine::standalone_on(make_storage(), vec![EmbeddingModelConfig::Deterministic])
        .expect("Corpus::open");

    // Ingest documents matching the corpus entries.
    corpus
        .ingest("the quick brown fox jumps", "entry-0", T0_MILLIS)
        .expect("ingest entry-0");
    corpus
        .ingest("pack my box with liquor jugs", "entry-1", T0_MILLIS)
        .expect("ingest entry-1");

    let external = ExternalCorpus::new(
        "test",
        vec![
            ExternalEntry::new("e0", "quick brown fox", vec![]),
            ExternalEntry::new("e1", "liquor jugs", vec![]),
        ],
    );

    let results = external
        .hybrid_recall(&corpus, 5, T0_MILLIS)
        .expect("hybrid_recall");

    assert_eq!(results.len(), 2, "one result list per entry");
    assert!(!results[0].is_empty(), "entry-0 should match ingested content");
    assert!(!results[1].is_empty(), "entry-1 should match ingested content");

    for hit in &results[0] {
        assert!(hit.score > 0.0, "fused score must be positive");
    }
}

#[test]
fn hybrid_recall_skips_empty_content_entries() {
    let corpus = CorpusContentEngine::standalone_on(make_storage(), vec![EmbeddingModelConfig::Deterministic])
        .expect("Corpus::open");

    let external = ExternalCorpus::new(
        "partial",
        vec![
            ExternalEntry::new("e1", "non-empty", vec![]),
            ExternalEntry::new("e2", "", vec![]),
            ExternalEntry::new("e3", "   ", vec![]),
        ],
    );

    let results = external
        .hybrid_recall(&corpus, 5, T0_MILLIS)
        .expect("hybrid_recall");

    assert_eq!(results.len(), 3, "results are index-aligned with entries");
    assert!(results[1].is_empty(), "empty content → empty result");
    assert!(results[2].is_empty(), "whitespace-only → empty result");
}

#[test]
fn hybrid_recall_on_empty_corpus_returns_empty_results() {
    let corpus = CorpusContentEngine::standalone_on(make_storage(), vec![EmbeddingModelConfig::Deterministic])
        .expect("Corpus::open");
    // No documents ingested.

    let external = ExternalCorpus::new(
        "no-match",
        vec![ExternalEntry::new("x1", "content with no match", vec![])],
    );

    let results = external
        .hybrid_recall(&corpus, 5, T0_MILLIS)
        .expect("hybrid_recall");

    assert_eq!(results.len(), 1);
    assert!(results[0].is_empty(), "empty corpus → no matching content");
}

// MARK: - VectorSimilaritySignal parity tests

#[test]
fn signal_emits_real_associate_frames_for_vectors_in_proximity() {
    let store = make_vector_store();

    // Two drawer IDs with identical engrams (Hamming distance 0 < 64).
    let close_engram = Fingerprint256::ZERO;

    store
        .add_vector("drawer-A", &close_engram, "test-v1", "1.0", 0)
        .expect("add drawer-A");
    store
        .add_vector("drawer-B", &close_engram, "test-v1", "1.0", 0)
        .expect("add drawer-B");

    let spec = VectorSimilaritySignal::spec(
        Arc::clone(&store),
        "test-v1".to_string(),
        VectorSimilaritySignal::DEFAULT_PROXIMITY_THRESHOLD,
        None,
        None, // edge_checker: None for this parity test
    );
    let report = fire_spec(spec);

    // At least 1 associate + 1 diagnostic for the close pair.
    assert!(
        report.emission_count >= 2,
        "must emit at least one AssociateFrame plus a diagnostic"
    );

    let associate_count = report
        .recent_outcomes
        .iter()
        .filter(|o| {
            matches!(
                o,
                SignalRouteOutcome::Routed { verb }
                | SignalRouteOutcome::RoutedButVerbStubbed { verb }
                if verb == "associate"
            )
        })
        .count();
    assert!(associate_count >= 1, "must emit at least one associate for close vectors");
    assert_eq!(report.recent_diagnostics.len(), 1);
    assert_eq!(
        report.recent_diagnostics[0].title,
        "vector_similarity.scan.summary"
    );
}

#[test]
fn signal_does_not_emit_associates_for_distant_vectors() {
    let store = make_vector_store();

    // Two drawer IDs with maximum Hamming distance (256).
    let zero = Fingerprint256::ZERO;
    let max = Fingerprint256::new(u64::MAX, u64::MAX, u64::MAX, u64::MAX);

    store
        .add_vector("far-A", &zero, "test-v1", "1.0", 0)
        .expect("add far-A");
    store
        .add_vector("far-B", &max, "test-v1", "1.0", 0)
        .expect("add far-B");

    // Default threshold is 64; distance 256 > 64 → no pairs.
    let spec = VectorSimilaritySignal::spec(
        Arc::clone(&store),
        "test-v1".to_string(),
        VectorSimilaritySignal::DEFAULT_PROXIMITY_THRESHOLD,
        None,
        None, // edge_checker: None for this parity test
    );
    let report = fire_spec(spec);

    // Only the scan-summary diagnostic; no associate emissions.
    assert_eq!(
        report.emission_count, 1,
        "distant vectors must produce only the scan-summary diagnostic"
    );
    let associate_count = report
        .recent_outcomes
        .iter()
        .filter(|o| {
            matches!(
                o,
                SignalRouteOutcome::Routed { verb }
                | SignalRouteOutcome::RoutedButVerbStubbed { verb }
                if verb == "associate"
            )
        })
        .count();
    assert_eq!(associate_count, 0, "no associates for distant vectors");
}

// MARK: - corpus-lane parity (mirrors Swift corpusLaneEmitsDrawerLevelAssociations)

/// Production shared-content estates key corpus vectors directly by Drawer
/// ID. This test proves the signal's corpus lane emits one Drawer-level
/// association for two semantically near Drawers without an identity remap.
#[test]
fn corpus_lane_emits_drawer_level_associations() {
    // Token-bag provider: sums a per-token deterministic vector so sentences
    // sharing most tokens land near each other in engram space — the
    // semantic property production's distributional ensemble provides (the
    // whole-text Deterministic hash does not).
    let provider = vectorkit::FloatSimHashEmbeddingProvider::new(
        "assoc-token-bag-v1",
        "1.0",
        0xC0FF_EE01,
        |text: &str| {
            let mut acc = vec![0.0f32; 32];
            for token in text
                .to_lowercase()
                .split(|c: char| !c.is_ascii_alphanumeric())
                .filter(|t| !t.is_empty())
            {
                let mut h = token.bytes().fold(14_695_981_039_346_656_037u64, |a, b| {
                    (a ^ u64::from(b)).wrapping_mul(1_099_511_628_211)
                });
                for slot in acc.iter_mut() {
                    h = h
                        .wrapping_mul(6_364_136_223_846_793_005)
                        .wrapping_add(1_442_695_040_888_963_407);
                    let mantissa = (h >> 40) as f32 / (1u64 << 24) as f32;
                    *slot += mantissa * 2.0 - 1.0;
                }
            }
            Ok(acc)
        },
    );
    // Fdc is the plain pass-through provider slot (stateless, no training) —
    // the vehicle for injecting the token-bag provider.
    let corpus = Arc::new(
        CorpusContentEngine::standalone_on(
            make_storage(),
            vec![EmbeddingModelConfig::Fdc { provider: Box::new(provider) }],
        )
        .expect("CorpusContentEngine::standalone_on"),
    );

    // Cross-drawer near pair (one shared token universe) …
    corpus
        .ingest("the api timeout is 30 seconds", "drawer-A", T0_MILLIS)
        .expect("ingest A");
    corpus
        .ingest("the api timeout is 90 seconds", "drawer-B", T0_MILLIS)
        .expect("ingest B");
    // … and a far drawer in a disjoint token universe.
    corpus
        .ingest("zebra quagga okapi giraffe pronghorn", "drawer-C", T0_MILLIS)
        .expect("ingest C");

    // "test-v1" matches no corpus row — the drawer-keyed lane is empty by
    // construction; only the corpus lane can find pairs.
    let spec = VectorSimilaritySignal::spec(
        corpus.shared_vector_store(),
        "test-v1".to_string(),
        VectorSimilaritySignal::DEFAULT_PROXIMITY_THRESHOLD,
        Some(Arc::clone(&corpus)),
        None, // edge_checker: None for this parity test
    );
    let report = fire_spec(spec);

    let associate_count = report
        .recent_outcomes
        .iter()
        .filter(|o| {
            matches!(
                o,
                SignalRouteOutcome::Routed { verb }
                | SignalRouteOutcome::RoutedButVerbStubbed { verb }
                if verb == "associate"
            )
        })
        .count();
    assert_eq!(
        associate_count, 1,
        "exactly one drawer-level associate: the A/B pair emits, the same-drawer C pair collapses"
    );
    // 1 associate + 1 scan-summary diagnostic.
    assert_eq!(report.emission_count, 2);
    assert_eq!(report.recent_diagnostics.len(), 1);
}
