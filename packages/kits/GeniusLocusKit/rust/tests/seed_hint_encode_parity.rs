// seed_hint_encode_parity.rs — seeded-hint encode routing.
//
// The seven seeded AI_Charter_Hint wing drawers go through the encode path
// INLINE (`seed_default_wings` indexes them in place, the same transform a
// queued drawer gets at drain), so:
//
//   • every hint is in the corpus index the moment provision returns, and
//     the encode drain is settled with nothing pending;
//   • re-running seed_default_wings on an already-converged estate does
//     NOTHING — no queue work (idempotent open);
//   • a seeded hint is recallable via BM25 (the estate_verbs `seed_wing`
//     "recallable like any other drawer" promise, defect 2).
//
// Swift twin: SeedHintEncodeTests.swift.

use std::sync::Arc;

use corpus_kit::corpus::EmbeddingModelConfig;
use corpus_kit::encoder::{EncoderError, EncoderModelSpec, Pooling, SpanEncoder};
use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::{
    EstateCoordinator, EstateKind, EstateLifetime, EstateProvisionParams, SyncMode,
};
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::OwnerCredentials;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::storage::Storage;
use uuid::Uuid;

const NOW: i64 = 1_700_000_000_000; // millis since epoch

struct DrainSpanEncoder {
    spec: EncoderModelSpec,
}

impl DrainSpanEncoder {
    fn new() -> Self {
        Self { spec: EncoderModelSpec {
            model_id: "drain-span-model".to_string(),
            model_version: "v1".to_string(),
            dim: 4,
            query_prefix: "Q:".to_string(),
            doc_prefix: "D:".to_string(),
            pooling: Pooling::Mean,
            tokenizer_hash: "fixture".to_string(),
            window_words: 3,
            overlap_divisor: 2,
            max_spans: 4,
            max_sequence: 512,
        }}
    }
}

impl SpanEncoder for DrainSpanEncoder {
    fn spec(&self) -> &EncoderModelSpec { &self.spec }
    fn encode_query(&self, _text: &str) -> Result<Vec<f32>, EncoderError> {
        Ok(vec![1.0, 0.0, 0.0, 0.0])
    }
    fn encode_spans(&self, spans: &[&str]) -> Result<Vec<Vec<f32>>, EncoderError> {
        Ok(spans.iter().map(|_| vec![1.0, 0.0, 0.0, 0.0]).collect())
    }
}

/// Provision a GLK estate (mounts Corpus + VectorStore + the encode queue).
/// Same fixture as encode_intake_parity.rs; provision seeds the 7 default
/// wings AND settles their hint drawers inline (facts + index + fingerprint).
fn provision_glk_estate() -> (EstateCoordinator, EstateHandle) {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let store: Arc<dyn DrawerStore> = Arc::new(
        InMemoryDrawerStore::with_storage(Arc::clone(&storage), NOW, None).unwrap(),
    );
    let storage_dyn: Arc<dyn Storage> = storage;

    let mut coord = EstateCoordinator::new();
    let params = EstateProvisionParams {
        estate_name: "Seed Hint Encode Test Estate".to_string(),
        kind: EstateKind::Glk,
        zoom_window_low: 1,
        zoom_window_high: 10,
        framework_profile: "KnowledgeWork".to_string(),
        sync_mode: SyncMode::None,
        lifetime: EstateLifetime::Durable,
    };
    let handle = coord
        .provision(
            store,
            storage_dyn,
            None,
            OwnerCredentials::new("owner-seed-hint-tests"),
            params,
            vec![EmbeddingModelConfig::Deterministic],
        )
        .expect("provision GLK estate");
    (coord, handle)
}

/// The number of seeded charter drawers that have no corpus index row —
/// zero once seeding has indexed every hint inline.
fn unindexed_hint_count(coord: &EstateCoordinator, handle: &EstateHandle) -> usize {
    let corpus = coord.corpus_for(handle).expect("corpus registered");
    let indexed: std::collections::HashSet<String> = corpus
        .all_index_states()
        .expect("all_index_states")
        .into_iter()
        .map(|s| s.content_id)
        .collect();
    (0..locus_kit::default_wings::DEFAULT_WINGS.len())
        .map(locus_kit::default_wings::charter_drawer_id)
        .filter(|id| !indexed.contains(id))
        .count()
}

/// Fresh estate + drain: every hint is indexed inline and the drains are settled.
#[test]
fn seed_hint_fresh_estate_drains_to_zero() {
    let (mut coord, handle) = provision_glk_estate();
    // Seeding indexes its hints inline, so the estate OPENS settled — every
    // hint has its index row before anything drives the queue.
    assert_eq!(
        unindexed_hint_count(&coord, &handle),
        0,
        "seeding indexes inline: no hint may be unindexed at open, before any drain"
    );
    // Draining changes nothing (there is no seed batch to drain) and must
    // leave the hints indexed.
    coord.await_encode_drain(&handle).expect("await_encode_drain");
    assert_eq!(
        unindexed_hint_count(&coord, &handle),
        0,
        "the 7 seeded hints must stay indexed after the drain"
    );
    let statuses = coord.drain_statuses(&handle).expect("drain_statuses");
    // The seeded hints are drawers with content and bits 27 and 28 clear, so
    // the span_encode and fact_extraction row-debt lanes are owed by
    // construction until a dreaming cycle pays them; every queue-side lane
    // settles. The span lane is rendered even though no encoder is loaded
    // (the fixture has no model directory), so a settle loop sees the debt
    // rather than an idle estate.
    let row_debt = [
        genius_locus_kit::DrainStatus::FACT_EXTRACTION_NAME,
        genius_locus_kit::DrainStatus::SPAN_ENCODE_NAME,
    ];
    assert!(
        statuses
            .iter()
            .filter(|s| !row_debt.contains(&s.name.as_str()))
            .all(|s| !s.is_draining()),
        "every queue-side drain lane settles on a fresh drained estate: {statuses:?}"
    );
    let span = statuses.iter()
        .find(|s| s.name == genius_locus_kit::DrainStatus::SPAN_ENCODE_NAME)
        .expect("span_encode lane is rendered while no encoder is loaded");
    assert_eq!(span.detail.as_deref(), Some("encoder not loaded"));
    assert!(span.pending > 0);
}

#[test]
fn registered_span_encoder_exposes_true_row_debt_without_gating_corpus_finisher() {
    let (mut coord, handle) = provision_glk_estate();
    // The encoder preference is provisioned but no encoder is loaded: the
    // lane is already present, carrying the true debt, and says so.
    let before = coord.drain_statuses(&handle).expect("drain_statuses");
    let unloaded = before.iter()
        .find(|s| s.name == genius_locus_kit::DrainStatus::SPAN_ENCODE_NAME)
        .expect("span_encode lane before an encoder is registered");
    assert_eq!(unloaded.pending, locus_kit::default_wings::DEFAULT_WINGS.len());
    assert_eq!(unloaded.detail.as_deref(), Some("encoder not loaded"));

    coord.register_span_encoder(&handle, Arc::new(DrainSpanEncoder::new()));
    let statuses = coord.drain_statuses(&handle).expect("drain_statuses");
    let span = statuses.iter()
        .find(|s| s.name == genius_locus_kit::DrainStatus::SPAN_ENCODE_NAME)
        .expect("span_encode lane");
    assert_eq!(span.pending, locus_kit::default_wings::DEFAULT_WINGS.len());
    assert_eq!(span.in_flight, 0);
    assert_eq!(span.detail.as_deref(), Some("model: drain-span-model"));
    assert!(genius_locus_kit::DrainStatus::encode_settled(&statuses));
}

/// Re-running seed_default_wings on a converged estate enqueues nothing
/// (idempotent open).
#[test]
fn seed_hint_reseed_enqueues_nothing() {
    let (mut coord, handle) = provision_glk_estate();
    coord.await_encode_drain(&handle).expect("await_encode_drain");
    assert_eq!(unindexed_hint_count(&coord, &handle), 0);

    // Simulate the estate being re-opened: the open path calls
    // seed_default_wings again. All 7 wings exist and all 7 hints are already
    // indexed, so the inline transform is a digest compare per hint and the
    // queue must see ZERO jobs.
    coord
        .seed_default_wings(&handle, NOW + 60_000)
        .expect("re-seed");
    let corpus = coord.corpus_for(&handle).expect("corpus registered");
    let (pending, in_flight) = corpus.ingest_queue_depth().expect("queue depth");
    assert_eq!(
        (pending, in_flight),
        (0, 0),
        "re-seed must not enqueue indexed hints"
    );
    assert_eq!(unindexed_hint_count(&coord, &handle), 0);
}

/// A seeded hint is recallable via BM25 (defect-2 closure).
#[test]
fn seed_hint_is_recallable_via_bm25() {
    let (mut coord, handle) = provision_glk_estate();
    coord.await_encode_drain(&handle).expect("await_encode_drain");

    // Distinctive phrase from the "User Canon" wing hint
    // (locus_kit default_wings): "standing orders".
    let corpus = coord.corpus_for(&handle).expect("corpus registered");
    let hits = corpus
        .bm25_top_k("user directives standing orders", 10)
        .expect("bm25_top_k");
    assert!(
        !hits.is_empty(),
        "the seeded User Canon hint must be BM25-recallable"
    );

    // The top hits hydrate to the hint drawer (content contains the phrase).
    let ids: Vec<&str> = hits.iter().map(|(id, _)| id.as_str()).collect();
    let estate = coord.estate_for(&handle).expect("estate");
    let drawers = estate.get_drawers(&ids).expect("get_drawers");
    assert!(
        drawers.iter().any(|d| d.content.contains("standing orders")),
        "a BM25 hit for the hint phrase must hydrate to the seeded hint drawer"
    );
}
