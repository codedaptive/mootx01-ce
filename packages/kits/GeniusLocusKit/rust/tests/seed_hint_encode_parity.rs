// seed_hint_encode_parity.rs — DISTILL_SEED_STALL regression coverage.
//
// The seven seeded AI_Charter_Hint wing drawers go through the encode path
// INLINE (`seed_default_wings` indexes and distills them in place, the same
// transform a queued drawer gets at drain), so:
//
//   • the "distillation" drain lane reaches ZERO on a fresh estate
//     (the lane previously pinned at pending:7 forever — the benchmark
//     drain-barrier stall, probe 1 2026-07-30);
//   • re-running seed_default_wings on an already-converged estate does
//     NOTHING — no queue work, no re-distillation (idempotent open);
//   • a seeded hint is recallable via BM25 (the estate_verbs `seed_wing`
//     "recallable like any other drawer" promise, defect 2).
//
// Swift twin: SeedHintEncodeTests.swift.

use std::sync::Arc;

use corpus_kit::corpus::EmbeddingModelConfig;
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

/// Provision a GLK estate (mounts Corpus + VectorStore + the encode queue).
/// Same fixture as encode_intake_parity.rs; provision seeds the 7 default
/// wings AND settles their hint drawers inline (index + distill).
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

/// The distillation drain-lane pending count.
fn distillation_pending(coord: &mut EstateCoordinator, handle: &EstateHandle) -> usize {
    coord
        .drain_statuses(handle)
        .expect("drain_statuses")
        .iter()
        .find(|s| s.name == "distillation")
        .expect("the distillation drain must be reported on every estate")
        .pending
}

/// Fresh estate + drain: the distillation lane reaches zero (stall regression).
#[test]
fn seed_hint_fresh_estate_drains_to_zero() {
    let (mut coord, handle) = provision_glk_estate();
    // Seeding settles its hints inline, so the estate OPENS settled — the
    // lane is already at zero before anything drives the queue.
    assert_eq!(
        distillation_pending(&mut coord, &handle),
        0,
        "seeding settles inline: the lane must be zero at open, before any drain"
    );
    // Draining changes nothing (there is no seed batch to drain) and must
    // leave the lane settled.
    coord.await_encode_drain(&handle).expect("await_encode_drain");
    assert_eq!(
        distillation_pending(&mut coord, &handle),
        0,
        "the 7 seeded hints must distill at drain — a non-zero count is the probe-1 stall"
    );
    let statuses = coord.drain_statuses(&handle).expect("drain_statuses");
    assert!(
        statuses.iter().all(|s| !s.is_draining()),
        "every drain lane settles on a fresh drained estate: {statuses:?}"
    );
}

/// Re-running seed_default_wings on a converged estate enqueues nothing
/// (idempotent open).
#[test]
fn seed_hint_reseed_enqueues_nothing() {
    let (mut coord, handle) = provision_glk_estate();
    coord.await_encode_drain(&handle).expect("await_encode_drain");
    assert_eq!(distillation_pending(&mut coord, &handle), 0);

    // Simulate the estate being re-opened: the open path calls
    // seed_default_wings again. All 7 wings exist and all 7 hints carry a
    // current representation (bit 19 set, current pipeline version), so the
    // settle predicate must admit ZERO drawers — no index, no distill, and
    // (as asserted below) nothing on the queue either.
    coord
        .seed_default_wings(&handle, NOW + 60_000)
        .expect("re-seed");
    let corpus = coord.corpus_for(&handle).expect("corpus registered");
    let (pending, in_flight) = corpus.ingest_queue_depth().expect("queue depth");
    assert_eq!(
        (pending, in_flight),
        (0, 0),
        "re-seed must not re-enqueue distilled hints"
    );
    assert_eq!(distillation_pending(&mut coord, &handle), 0);
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
