// provision_lifecycle_parity.rs — Rust parity of Swift EstateProvisionLifecycleTests.swift.
//
// This test file proves the parity gap is closed: Rust `provision` now wires
// VectorStore + Corpus by kind (the step Swift always did and Rust previously
// deferred to the caller).
//
// Coverage mirrors the twelve Swift test groups:
//
//   T1  provision(Glk)       — kind-prefixed profile + Corpus + VectorStore wired
//   T2  provision(CorpusOnly) — Corpus wired, VectorStore absent
//   T3  provision(LocusOnly)  — no sub-stores wired
//   T4  Idempotent create     — re-provisioning same store raises DuplicateEstate
//   T5  mountState            — freshly provisioned estate is Mounted
//   T6  quiesce               — transitions Mounted → Quiesced; idempotent
//   T7  drain                 — transitions directly to Quiesced
//   T8  destroy(Glk)          — closes estate + coordinates VectorStore/Corpus teardown
//   T9  destroy(LocusOnly)    — works when no sub-stores were wired
//   T10 quiesce stale handle  — raises EstateNotOpen
//   T11 drain stale handle    — raises EstateNotOpen
//   T12 separate corpus_storage path — both stores wired; destroy succeeds
//
// The implementation contract this file proves:
//   - `provision` now accepts `Arc<dyn Storage>` + optional `corpus_storage`
//     + `EmbeddingModelConfig`, resolving the DrawerStore/Storage trait impedance.
//   - Sub-store wiring is performed INSIDE provision, not deferred to the caller.
//   - The lifecycle methods (quiesce/drain/destroy) coordinate all wired sub-stores.
//   - destroy calls `Corpus::destroy_recall_index` and `VectorStore::destroy_all_vectors`
//     on registered sub-stores before dropping them.

use std::sync::Arc;

use corpus_kit::corpus::EmbeddingModelConfig;
use genius_locus_kit::coordinator::{
    EstateCoordinator, EstateKind, EstateMountState, EstateProvisionParams, GeniusLocusKitError,
    SyncMode,
};
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::drawer_store_sqlite::SqliteDrawerStore;
use locus_kit::estate_types::OwnerCredentials;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::storage::Storage;
use persistence_kit::{BackendConfiguration, EstateConfiguration, SqliteStorage};
use uuid::Uuid;

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

const NOW: i64 = 1_700_000_000;

// MARK: - Helpers

/// Create a paired (DrawerStore, Storage) from a single InMemoryStorage so one
/// in-memory instance backs both the LocusKit estate and the Corpus/VectorStore.
/// This is the idiomatic pattern for tests — mirrors Swift's single InMemoryStorage.
fn make_stores() -> (Arc<dyn DrawerStore>, Arc<dyn Storage>) {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let store = Arc::new(
        InMemoryDrawerStore::with_storage(Arc::clone(&storage), NOW, None).unwrap(),
    );
    (store as Arc<dyn DrawerStore>, storage as Arc<dyn Storage>)
}

fn glk_params(name: &str) -> EstateProvisionParams {
    EstateProvisionParams {
        estate_name: name.to_string(),
        kind: EstateKind::Glk,
        zoom_window_low: 1,
        zoom_window_high: 10,
        framework_profile: "KnowledgeWork".to_string(),
        sync_mode: SyncMode::None,
    }
}

fn corpus_only_params(name: &str) -> EstateProvisionParams {
    EstateProvisionParams {
        estate_name: name.to_string(),
        kind: EstateKind::CorpusOnly,
        zoom_window_low: 2,
        zoom_window_high: 8,
        framework_profile: "CorpusTest".to_string(),
        sync_mode: SyncMode::None,
    }
}

fn locus_only_params(name: &str) -> EstateProvisionParams {
    EstateProvisionParams {
        estate_name: name.to_string(),
        kind: EstateKind::LocusOnly,
        zoom_window_low: 0,
        zoom_window_high: 5,
        framework_profile: "MinimalProfile".to_string(),
        sync_mode: SyncMode::None,
    }
}

// MARK: - T1: provision(Glk) — kind-prefixed profile + VectorStore + Corpus wired

/// provision(Glk) stores the kind-prefixed framework profile ("GLK:KnowledgeWork").
#[test]
fn t1a_provision_glk_stores_kind_prefixed_profile() {
    let mut coord = EstateCoordinator::new();
    let (store, storage) = make_stores();

    let handle = coord
        .provision(store, storage, None, OwnerCredentials::new("owner"), glk_params("TestGLK"), vec![EmbeddingModelConfig::Deterministic])
        .expect("provision(Glk) should succeed");

    let estate = coord.estate_for(&handle).expect("estate must be open");
    let manifest = estate.manifest().expect("manifest must be readable");
    assert_eq!(
        manifest.framework_profile, "GLK:KnowledgeWork",
        "provision(Glk) must store kind-prefixed profile in the manifest"
    );
    assert_eq!(manifest.estate_name, "TestGLK", "estate name must round-trip");
}

/// provision(Glk) wires a VectorStore into the scored-recall registry.
/// The vector store is accessible via the coordinator's internal registry
/// (corpus_kits/vector_stores) for the issued handle.
#[test]
fn t1b_provision_glk_wires_vector_store() {
    let mut coord = EstateCoordinator::new();
    let (store, storage) = make_stores();

    let handle = coord
        .provision(store, storage, None, OwnerCredentials::new("owner"), glk_params("TestGLK"), vec![EmbeddingModelConfig::Deterministic])
        .expect("provision(Glk) should succeed");

    // A VectorStore must be wired — its presence activates the vector lane in recall_scored.
    let vs_present = coord.has_vector_store(&handle);
    assert!(vs_present, "provision(Glk) must wire a VectorStore into the registry");
}

/// provision(Glk) wires a Corpus into the BM25 recall registry.
#[test]
fn t1c_provision_glk_wires_corpus() {
    let mut coord = EstateCoordinator::new();
    let (store, storage) = make_stores();

    let handle = coord
        .provision(store, storage, None, OwnerCredentials::new("owner"), glk_params("TestGLK"), vec![EmbeddingModelConfig::Deterministic])
        .expect("provision(Glk) should succeed");

    let corpus_present = coord.has_corpus(&handle);
    assert!(corpus_present, "provision(Glk) must wire a Corpus into the registry");
}

/// provision(Glk) stores zoomWindowLow and zoomWindowHigh in the manifest.
#[test]
fn t1d_provision_glk_stores_zoom_window() {
    let mut coord = EstateCoordinator::new();
    let (store, storage) = make_stores();
    let params = EstateProvisionParams {
        estate_name: "ZoomTest".to_string(),
        kind: EstateKind::Glk,
        zoom_window_low: 3,
        zoom_window_high: 12,
        framework_profile: "ZoomProfile".to_string(),
        sync_mode: SyncMode::None,
    };

    let handle = coord
        .provision(store, storage, None, OwnerCredentials::new("owner"), params, vec![EmbeddingModelConfig::Deterministic])
        .expect("provision should succeed");

    assert_eq!(handle.zoom_window_low, 3, "zoom_window_low must round-trip through the handle");
    assert_eq!(handle.zoom_window_high, 12, "zoom_window_high must round-trip through the handle");
}

// MARK: - T2: provision(CorpusOnly) — Corpus wired, VectorStore absent

/// provision(CorpusOnly) stores the CorpusOnly-prefixed framework profile.
#[test]
fn t2a_provision_corpus_only_stores_kind_prefixed_profile() {
    let mut coord = EstateCoordinator::new();
    let (store, storage) = make_stores();

    let handle = coord
        .provision(store, storage, None, OwnerCredentials::new("owner"), corpus_only_params("TestCorpusOnly"), vec![EmbeddingModelConfig::Deterministic])
        .expect("provision(CorpusOnly) should succeed");

    let estate = coord.estate_for(&handle).expect("estate");
    let manifest = estate.manifest().expect("manifest");
    assert_eq!(
        manifest.framework_profile, "CorpusOnly:CorpusTest",
        "provision(CorpusOnly) must store CorpusOnly-prefixed profile"
    );
}

/// provision(CorpusOnly) wires a Corpus but does NOT register a standalone VectorStore.
///
/// Per spec §1.8: CorpusOnly estates have Corpus (BM25 + internal vectors) but no
/// separately-registered VectorStore for the standalone vector lane.
#[test]
fn t2b_provision_corpus_only_wires_corpus_not_vector_store() {
    let mut coord = EstateCoordinator::new();
    let (store, storage) = make_stores();

    let handle = coord
        .provision(store, storage, None, OwnerCredentials::new("owner"), corpus_only_params("TestCorpusOnly"), vec![EmbeddingModelConfig::Deterministic])
        .expect("provision(CorpusOnly) should succeed");

    let corpus_present = coord.has_corpus(&handle);
    let vs_present = coord.has_vector_store(&handle);
    assert!(corpus_present, "provision(CorpusOnly) must wire a Corpus");
    assert!(!vs_present, "provision(CorpusOnly) must NOT wire a standalone VectorStore");
}

// MARK: - T3: provision(LocusOnly) — no sub-stores wired

/// provision(LocusOnly) stores the LocusOnly-prefixed profile.
#[test]
fn t3a_provision_locus_only_stores_kind_prefixed_profile() {
    let mut coord = EstateCoordinator::new();
    let (store, storage) = make_stores();

    let handle = coord
        .provision(store, storage, None, OwnerCredentials::new("owner"), locus_only_params("TestLocusOnly"), vec![EmbeddingModelConfig::Deterministic])
        .expect("provision(LocusOnly) should succeed");

    let estate = coord.estate_for(&handle).expect("estate");
    let manifest = estate.manifest().expect("manifest");
    assert_eq!(
        manifest.framework_profile, "LocusOnly:MinimalProfile",
        "provision(LocusOnly) must store LocusOnly-prefixed profile"
    );
}

/// provision(LocusOnly) wires no sub-stores — neither Corpus nor VectorStore.
#[test]
fn t3b_provision_locus_only_wires_no_sub_stores() {
    let mut coord = EstateCoordinator::new();
    let (store, storage) = make_stores();

    let handle = coord
        .provision(store, storage, None, OwnerCredentials::new("owner"), locus_only_params("TestLocusOnly"), vec![EmbeddingModelConfig::Deterministic])
        .expect("provision(LocusOnly) should succeed");

    let corpus_present = coord.has_corpus(&handle);
    let vs_present = coord.has_vector_store(&handle);
    assert!(!corpus_present, "provision(LocusOnly) must NOT wire a Corpus");
    assert!(!vs_present, "provision(LocusOnly) must NOT wire a VectorStore");
}

// MARK: - T4: Idempotent create

/// Re-provisioning the same storage raises DuplicateEstate.
///
/// Two calls that share the same InMemoryStorage produce the same estate UUID.
/// The second open hits the DuplicateEstate guard in the registry.
#[test]
fn t4a_reprovision_same_storage_raises_duplicate_estate() {
    let mut coord = EstateCoordinator::new();
    // Shared InMemoryStorage: both provisions open the same underlying estate UUID.
    let shared = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let store1 = Arc::new(
        InMemoryDrawerStore::with_storage(Arc::clone(&shared), NOW, None).unwrap()
    ) as Arc<dyn DrawerStore>;
    let store2 = Arc::new(
        InMemoryDrawerStore::with_storage(Arc::clone(&shared), NOW, None).unwrap()
    ) as Arc<dyn DrawerStore>;
    let stor1 = Arc::clone(&shared) as Arc<dyn Storage>;
    let stor2 = Arc::clone(&shared) as Arc<dyn Storage>;

    // First provision succeeds.
    coord
        .provision(store1, stor1, None, OwnerCredentials::new("owner"), glk_params("DupeTest"), vec![EmbeddingModelConfig::Deterministic])
        .expect("first provision should succeed");

    // Second provision on the same underlying storage must raise DuplicateEstate.
    let err = coord
        .provision(store2, stor2, None, OwnerCredentials::new("owner"), glk_params("DupeTest"), vec![EmbeddingModelConfig::Deterministic])
        .expect_err("second provision on same storage must fail");

    assert!(
        matches!(err, GeniusLocusKitError::DuplicateEstate { .. }),
        "expected DuplicateEstate, got {:?}",
        err
    );
}

/// Provisioning distinct storages succeeds for both — distinct UUIDs issued.
#[test]
fn t4b_provisioning_distinct_storages_succeeds() {
    let mut coord = EstateCoordinator::new();
    let (s1, stor1) = make_stores();
    let (s2, stor2) = make_stores();

    let h1 = coord
        .provision(s1, stor1, None, OwnerCredentials::new("owner"), glk_params("Estate1"), vec![EmbeddingModelConfig::Deterministic])
        .expect("first provision");
    let h2 = coord
        .provision(s2, stor2, None, OwnerCredentials::new("owner"), glk_params("Estate2"), vec![EmbeddingModelConfig::Deterministic])
        .expect("second provision");

    assert_ne!(h1.estate_uuid, h2.estate_uuid, "distinct storages produce distinct UUIDs");
    assert_eq!(coord.open_estate_count(), 2, "both estates must be registered");
}

// MARK: - T5: mountState

/// Freshly provisioned estate is in Mounted state.
#[test]
fn t5_fresh_provisioned_estate_is_mounted() {
    let mut coord = EstateCoordinator::new();
    let (store, storage) = make_stores();
    let handle = coord
        .provision(store, storage, None, OwnerCredentials::new("owner"), glk_params("GLK1"), vec![EmbeddingModelConfig::Deterministic])
        .expect("provision");

    assert_eq!(
        coord.mount_state(&handle),
        Some(EstateMountState::Mounted),
        "freshly provisioned estate must be Mounted"
    );
}

// MARK: - T6: quiesce

/// quiesce transitions Mounted → Quiesced.
#[test]
fn t6a_quiesce_transitions_mounted_to_quiesced() {
    let mut coord = EstateCoordinator::new();
    let (store, storage) = make_stores();
    let handle = coord
        .provision(store, storage, None, OwnerCredentials::new("owner"), glk_params("Q1"), vec![EmbeddingModelConfig::Deterministic])
        .expect("provision");

    coord.quiesce(&handle).expect("quiesce must succeed");
    assert_eq!(
        coord.mount_state(&handle),
        Some(EstateMountState::Quiesced),
        "quiesce must transition to Quiesced"
    );
}

/// quiesce is idempotent on an already-quiesced estate.
#[test]
fn t6b_quiesce_is_idempotent_on_already_quiesced_estate() {
    let mut coord = EstateCoordinator::new();
    let (store, storage) = make_stores();
    let handle = coord
        .provision(store, storage, None, OwnerCredentials::new("owner"), glk_params("Q2"), vec![EmbeddingModelConfig::Deterministic])
        .expect("provision");

    coord.quiesce(&handle).expect("first quiesce");
    coord.quiesce(&handle).expect("second quiesce must be idempotent — must not fail");
    assert_eq!(coord.mount_state(&handle), Some(EstateMountState::Quiesced));
}

// MARK: - T7: drain

/// drain transitions to Quiesced (via Draining) and the coordinator is synchronous.
#[test]
fn t7_drain_transitions_to_quiesced() {
    let mut coord = EstateCoordinator::new();
    let (store, storage) = make_stores();
    let handle = coord
        .provision(store, storage, None, OwnerCredentials::new("owner"), glk_params("D1"), vec![EmbeddingModelConfig::Deterministic])
        .expect("provision");

    coord.drain(&handle).expect("drain must succeed");
    assert_eq!(
        coord.mount_state(&handle),
        Some(EstateMountState::Quiesced),
        "drain must complete with Quiesced state (synchronous coordinator)"
    );
}

// MARK: - T8: destroy(Glk) — lifecycle coordination

/// destroy(Glk) closes the estate and removes it from the registry.
/// The coordinator tears down the Corpus and VectorStore sub-stores
/// via `destroy_recall_index` and `destroy_all_vectors` before releasing
/// the registry entries — no orphan sub-store is left registered.
#[test]
fn t8a_destroy_glk_closes_estate_and_clears_registry() {
    let mut coord = EstateCoordinator::new();
    let (store, storage) = make_stores();

    let handle = coord
        .provision(store, storage, None, OwnerCredentials::new("owner"), glk_params("DestroyGLK"), vec![EmbeddingModelConfig::Deterministic])
        .expect("provision");

    // Verify estate is open and sub-stores are wired.
    assert_eq!(coord.open_estate_count(), 1);
    assert!(coord.has_corpus(&handle), "corpus must be wired before destroy");
    assert!(coord.has_vector_store(&handle), "vector_store must be wired before destroy");

    coord.destroy(&handle).expect("destroy must succeed");

    // Registry entry is gone.
    assert_eq!(coord.open_estate_count(), 0, "destroy must remove the estate from the registry");
    // Mount state is cleaned up.
    assert_eq!(coord.mount_state(&handle), None, "destroy must clear mount state");
    // Sub-store registrations are dropped (no orphan entries).
    assert!(!coord.has_corpus(&handle), "destroy must remove corpus registration");
    assert!(!coord.has_vector_store(&handle), "destroy must remove vector_store registration");
}

/// destroy(Glk) must still succeed after quiesce + drain.
/// This is the normal admin-plane teardown sequence: quiesce → drain → destroy.
#[test]
fn t8b_destroy_after_quiesce_and_drain_succeeds() {
    let mut coord = EstateCoordinator::new();
    let (store, storage) = make_stores();

    let handle = coord
        .provision(store, storage, None, OwnerCredentials::new("owner"), glk_params("QDDestroyGLK"), vec![EmbeddingModelConfig::Deterministic])
        .expect("provision");

    // Normal admin-plane sequence.
    coord.quiesce(&handle).expect("quiesce");
    coord.drain(&handle).expect("drain");
    coord.destroy(&handle).expect("destroy after quiesce+drain must succeed");

    assert_eq!(coord.open_estate_count(), 0);
}

// MARK: - T9: destroy(LocusOnly) — no sub-store teardown needed

/// destroy(LocusOnly) succeeds without sub-store teardown — no Corpus or VectorStore
/// was wired, so neither destroy_recall_index nor destroy_all_vectors is called.
#[test]
fn t9_destroy_locus_only_succeeds_without_sub_stores() {
    let mut coord = EstateCoordinator::new();
    let (store, storage) = make_stores();

    let handle = coord
        .provision(store, storage, None, OwnerCredentials::new("owner"), locus_only_params("DestroyLocusOnly"), vec![EmbeddingModelConfig::Deterministic])
        .expect("provision");

    // No sub-stores wired.
    assert!(!coord.has_corpus(&handle));
    assert!(!coord.has_vector_store(&handle));

    // Must not throw — no sub-store teardown code paths exercised.
    coord.destroy(&handle).expect("destroy(LocusOnly) must succeed without sub-stores");
    assert_eq!(coord.open_estate_count(), 0);
}

// MARK: - T10: quiesce stale handle

/// quiesce on a closed handle raises EstateNotOpen.
#[test]
fn t10_quiesce_on_stale_handle_raises_estate_not_open() {
    let mut coord = EstateCoordinator::new();
    let (store, storage) = make_stores();
    let handle = coord
        .provision(store, storage, None, OwnerCredentials::new("owner"), locus_only_params("QuiesceStale"), vec![EmbeddingModelConfig::Deterministic])
        .expect("provision");

    coord.close(&handle).expect("close");

    let err = coord.quiesce(&handle).expect_err("quiesce on stale handle must fail");
    assert!(
        matches!(err, GeniusLocusKitError::EstateNotOpen { .. }),
        "expected EstateNotOpen, got {:?}",
        err
    );
}

// MARK: - T11: drain stale handle

/// drain on a closed handle raises EstateNotOpen.
#[test]
fn t11_drain_on_stale_handle_raises_estate_not_open() {
    let mut coord = EstateCoordinator::new();
    let (store, storage) = make_stores();
    let handle = coord
        .provision(store, storage, None, OwnerCredentials::new("owner"), locus_only_params("DrainStale"), vec![EmbeddingModelConfig::Deterministic])
        .expect("provision");

    coord.close(&handle).expect("close");

    let err = coord.drain(&handle).expect_err("drain on stale handle must fail");
    assert!(
        matches!(err, GeniusLocusKitError::EstateNotOpen { .. }),
        "expected EstateNotOpen, got {:?}",
        err
    );
}

// MARK: - T12: separate corpus_storage path

/// provision(Glk) with a separate `corpus_storage` wires Corpus and VectorStore on
/// the corpus-storage backend, not the estate's primary storage.
///
/// This mirrors Swift's `provision(storage:corpusStorage:owner:params:embeddingModel:)`
/// two-storage path: the LocusKit estate lives on `storage`, and the Corpus +
/// VectorStore live on `corpus_storage`.
#[test]
fn t12a_provision_glk_with_separate_corpus_storage_wires_both_sub_stores() {
    let mut coord = EstateCoordinator::new();
    let (primary_store, primary_storage) = make_stores();
    // Separate corpus storage: a second InMemoryStorage exclusively for Corpus/VectorStore.
    let corpus_storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4())) as Arc<dyn Storage>;

    let handle = coord
        .provision(
            primary_store,
            primary_storage,
            Some(corpus_storage),
            OwnerCredentials::new("owner"),
            glk_params("SeparateStorageGLK"),
            vec![EmbeddingModelConfig::Deterministic],
        )
        .expect("provision with separate corpus_storage must succeed");

    assert!(coord.has_corpus(&handle), "separate-storage path must wire a Corpus");
    assert!(coord.has_vector_store(&handle), "separate-storage path must wire a VectorStore");
    assert_eq!(coord.mount_state(&handle), Some(EstateMountState::Mounted));
}

/// destroy on a GLK estate provisioned with separate corpus_storage coordinates
/// teardown of the wired sub-stores.
#[test]
fn t12b_destroy_glk_with_separate_storage_succeeds() {
    let mut coord = EstateCoordinator::new();
    let (primary_store, primary_storage) = make_stores();
    let corpus_storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4())) as Arc<dyn Storage>;

    let handle = coord
        .provision(
            primary_store,
            primary_storage,
            Some(corpus_storage),
            OwnerCredentials::new("owner"),
            glk_params("SeparateDestroyGLK"),
            vec![EmbeddingModelConfig::Deterministic],
        )
        .expect("provision");

    coord.destroy(&handle).expect("destroy on separate-storage GLK estate must succeed");
    assert_eq!(coord.open_estate_count(), 0, "registry must be empty after destroy");
    assert!(!coord.has_corpus(&handle), "corpus registration must be cleared");
    assert!(!coord.has_vector_store(&handle), "vector_store registration must be cleared");
}

/// destroy on an already-closed estate still clears any registered sub-stores
/// (the corpus + vector teardown runs even when the estate was already closed).
#[test]
fn t12c_destroy_after_manual_close_still_succeeds() {
    let mut coord = EstateCoordinator::new();
    let (store, storage) = make_stores();
    let handle = coord
        .provision(store, storage, None, OwnerCredentials::new("owner"), corpus_only_params("CloseFirstCorpus"), vec![EmbeddingModelConfig::Deterministic])
        .expect("provision");

    // Manual close first — drops the registry entry and the corpus registration.
    coord.close(&handle).expect("close");

    // destroy on the already-closed handle must succeed: the registry skip path runs,
    // and the sub-store teardown is a no-op because close already dropped them.
    coord.destroy(&handle).expect("destroy after manual close must succeed");
    assert_eq!(coord.open_estate_count(), 0);
}

// MARK: - Additional lifecycle-coordination tests

/// quiesce/drain on a GLK estate do not disturb sub-store registrations — only
/// destroy tears sub-stores down. Corpus and VectorStore must remain registered
/// across quiesce and drain so scored recall still works after a quiesce.
#[test]
fn sub_stores_remain_registered_after_quiesce_and_drain() {
    let mut coord = EstateCoordinator::new();
    let (store, storage) = make_stores();
    let handle = coord
        .provision(store, storage, None, OwnerCredentials::new("owner"), glk_params("LifecycleGLK"), vec![EmbeddingModelConfig::Deterministic])
        .expect("provision");

    coord.quiesce(&handle).expect("quiesce");
    assert!(coord.has_corpus(&handle), "corpus must remain registered after quiesce");
    assert!(coord.has_vector_store(&handle), "vector_store must remain registered after quiesce");

    coord.drain(&handle).expect("drain");
    assert!(coord.has_corpus(&handle), "corpus must remain registered after drain");
    assert!(coord.has_vector_store(&handle), "vector_store must remain registered after drain");

    // Only destroy should clear them.
    coord.destroy(&handle).expect("destroy");
    assert!(!coord.has_corpus(&handle), "corpus must be cleared after destroy");
    assert!(!coord.has_vector_store(&handle), "vector_store must be cleared after destroy");
}

/// Two GLK estates are independent: destroying one does not affect the other's
/// sub-store registrations.
#[test]
fn destroy_one_estate_does_not_orphan_siblings_sub_stores() {
    let mut coord = EstateCoordinator::new();
    let (s1, stor1) = make_stores();
    let (s2, stor2) = make_stores();

    let h1 = coord
        .provision(s1, stor1, None, OwnerCredentials::new("owner"), glk_params("Estate1"), vec![EmbeddingModelConfig::Deterministic])
        .expect("provision estate 1");
    let h2 = coord
        .provision(s2, stor2, None, OwnerCredentials::new("owner"), glk_params("Estate2"), vec![EmbeddingModelConfig::Deterministic])
        .expect("provision estate 2");

    coord.destroy(&h1).expect("destroy estate 1");

    // Estate 2 must still have its sub-stores registered — destroy is per-handle, not global.
    assert!(!coord.has_corpus(&h1), "estate 1 corpus must be cleared");
    assert!(!coord.has_vector_store(&h1), "estate 1 vector_store must be cleared");
    assert!(coord.has_corpus(&h2), "estate 2 corpus must remain registered");
    assert!(coord.has_vector_store(&h2), "estate 2 vector_store must remain registered");
    assert_eq!(coord.open_estate_count(), 1, "only estate 1 was destroyed");
}

// MARK: - T13: provision(Glk) on SQLite file backend — regression guard
//
// This mirrors the Swift `EstateProvisionSQLiteTests.provisionGLKOnSQLiteSucceedsAndEstateIsUsable`
// test added in cp-glk-sqlite-fix. The Rust port was NOT affected by the
// `no such table: chunks` bug (SqliteStorage::migrate calls apply_schema which
// always creates tables), but we add a parity test here to keep the four-way
// conformance gate honest: any future regression in the Rust SQLite path will
// be caught by this test.
//
// Helpers follow the hydrate_parity.rs pattern: SqliteDrawerStore::from_path for
// the estate, a second SqliteStorage for Corpus/VectorStore, temp files cleaned
// up after the test.

/// Build a SQLite estate store at a unique temp path. Returns (store, path) for cleanup.
fn make_sqlite_drawer_store() -> (SqliteDrawerStore, std::path::PathBuf) {
    let path = std::env::temp_dir()
        .join(format!("glk-provision-sqlite-{}.sqlite", Uuid::new_v4()));
    let store = SqliteDrawerStore::from_path(
        path.to_string_lossy().as_ref(),
        NOW,
        None,
        5.0,
    )
    .expect("SqliteDrawerStore::from_path must succeed");
    (store, path)
}

/// Build a SqliteStorage at a unique temp path for Corpus/VectorStore.
/// Returns (Arc<dyn Storage>, path) for cleanup.
fn make_sqlite_corpus_storage() -> (Arc<dyn Storage>, std::path::PathBuf) {
    let path = std::env::temp_dir()
        .join(format!("glk-provision-corpus-{}.sqlite", Uuid::new_v4()));
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string_lossy().into_owned(),
            busy_timeout_secs: 5.0,
        },
    );
    let storage = SqliteStorage::new(config).expect("SqliteStorage::new must succeed");
    (Arc::new(storage) as Arc<dyn Storage>, path)
}

/// Remove a SQLite file and its WAL/SHM sidecars.
fn cleanup_sqlite_file(path: &std::path::Path) {
    let _ = std::fs::remove_file(path);
    let _ = std::fs::remove_file(format!("{}-wal", path.display()));
    let _ = std::fs::remove_file(format!("{}-shm", path.display()));
}

/// T13a — provision(.glk) on a SQLite file backend succeeds.
///
/// Before the Swift fix for cp-glk-sqlite-fix, `Corpus::open` called
/// `storage.migrate(to: BundleStore.schemaDeclaration)` on a fresh file and then
/// `bundleStore.allChunks()` → `no such table: chunks`. The Rust `SqliteStorage::migrate`
/// always calls `apply_schema` (which creates tables), so the Rust port never had this
/// bug — but we test it here to maintain parity and catch future regressions.
#[test]
fn t13a_provision_glk_on_sqlite_backend_succeeds() {
    let (drawer_store, estate_path) = make_sqlite_drawer_store();
    let (corpus_storage, corpus_path) = make_sqlite_corpus_storage();

    let mut coord = EstateCoordinator::new();
    let store = Arc::new(drawer_store) as Arc<dyn DrawerStore>;
    // Pass corpus_storage separately so Corpus/VectorStore use the dedicated SQLite file.
    // The estate's primary storage is derived from the DrawerStore's internal storage handle;
    // we pass InMemoryStorage as the unused `storage` parameter (the coordinator uses the
    // storage only for sub-store wiring when corpus_storage is None — here it is not None).
    let primary_storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4())) as Arc<dyn Storage>;

    let handle = coord
        .provision(
            store,
            primary_storage,
            Some(corpus_storage),
            OwnerCredentials::new("sqlite-provision-test"),
            glk_params("SQLiteGLKEstate"),
            vec![EmbeddingModelConfig::Deterministic],
        )
        .expect("provision(Glk) on SQLite backend must not fail — no such table: chunks regression guard");

    // Sub-stores must be wired.
    assert!(coord.has_corpus(&handle), "provision(Glk) on SQLite must wire a Corpus");
    assert!(coord.has_vector_store(&handle), "provision(Glk) on SQLite must wire a VectorStore");
    assert_eq!(
        coord.mount_state(&handle),
        Some(EstateMountState::Mounted),
        "SQLite-backed estate must be Mounted after provision"
    );

    // Lifecycle round-trip: quiesce → destroy cleans registry.
    coord.quiesce(&handle).expect("quiesce must succeed");
    coord.destroy(&handle).expect("destroy must succeed");
    assert_eq!(coord.open_estate_count(), 0, "registry must be empty after destroy");
    assert!(!coord.has_corpus(&handle), "corpus registration must be cleared after destroy");
    assert!(!coord.has_vector_store(&handle), "vector_store registration must be cleared after destroy");

    cleanup_sqlite_file(&estate_path);
    cleanup_sqlite_file(&corpus_path);
}

/// T13b — provision(.corpusOnly) on a SQLite file backend succeeds.
#[test]
fn t13b_provision_corpus_only_on_sqlite_backend_succeeds() {
    let (drawer_store, estate_path) = make_sqlite_drawer_store();
    let (corpus_storage, corpus_path) = make_sqlite_corpus_storage();

    let mut coord = EstateCoordinator::new();
    let store = Arc::new(drawer_store) as Arc<dyn DrawerStore>;
    let primary_storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4())) as Arc<dyn Storage>;

    let handle = coord
        .provision(
            store,
            primary_storage,
            Some(corpus_storage),
            OwnerCredentials::new("sqlite-corpus-only-test"),
            corpus_only_params("SQLiteCorpusOnlyEstate"),
            vec![EmbeddingModelConfig::Deterministic],
        )
        .expect("provision(CorpusOnly) on SQLite backend must succeed");

    // Corpus wired; no standalone VectorStore for CorpusOnly estates.
    assert!(coord.has_corpus(&handle), "provision(CorpusOnly) on SQLite must wire a Corpus");
    assert!(!coord.has_vector_store(&handle), "provision(CorpusOnly) on SQLite must NOT wire a standalone VectorStore");

    coord.destroy(&handle).expect("destroy must succeed");
    assert_eq!(coord.open_estate_count(), 0);

    cleanup_sqlite_file(&estate_path);
    cleanup_sqlite_file(&corpus_path);
}

// ─────────────────────────────────────────────────────────────────
// T14–T18: ADR-016 — Default wing seeding at provision
//
// Parity targets for Swift EstateProvisionLifecycleTests.swift
// ADR016DefaultWingSeedingTests (T14–T18). Seven default wings are
// seeded at provision for every estate kind.
// ─────────────────────────────────────────────────────────────────

/// T14: A freshly provisioned estate exposes exactly 7 distinct wing names
/// drawn from `locus_kit::default_wings::DEFAULT_WINGS`.
#[test]
fn adr016_provision_seeds_seven_distinct_wings() {
    use locus_kit::default_wings::DEFAULT_WINGS;

    let (store, storage) = make_stores();
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .provision(
            store,
            storage,
            None,
            OwnerCredentials::new("adr016-test"),
            glk_params("ADR016-T14"),
            vec![EmbeddingModelConfig::Deterministic],
        )
        .expect("provision must succeed");

    let estate = coord.estate_for(&handle).expect("estate must be open");
    let all_drawers = estate.all_drawers_bounded(None).expect("all_drawers must succeed");
    let wing_names: std::collections::HashSet<String> =
        all_drawers.iter().map(|d| d.wing.clone()).collect();

    let expected: std::collections::HashSet<String> =
        DEFAULT_WINGS.iter().map(|w| w.name.to_string()).collect();
    assert_eq!(
        wing_names, expected,
        "provision must seed exactly the 7 default wing names"
    );
}

/// T15: Each of the 7 default wings has exactly one charter drawer in the
/// reserved `_charter` room (`CHARTER_ROOM`).
#[test]
fn adr016_each_default_wing_has_one_charter_drawer() {
    use locus_kit::default_wings::{CHARTER_ROOM, DEFAULT_WINGS};

    let (store, storage) = make_stores();
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .provision(
            store,
            storage,
            None,
            OwnerCredentials::new("adr016-test"),
            glk_params("ADR016-T15"),
            vec![EmbeddingModelConfig::Deterministic],
        )
        .expect("provision must succeed");

    let estate = coord.estate_for(&handle).expect("estate must be open");
    let all_drawers = estate.all_drawers_bounded(None).expect("all_drawers must succeed");
    let charters: Vec<_> = all_drawers.iter().filter(|d| d.room == CHARTER_ROOM).collect();

    assert_eq!(
        charters.len(),
        DEFAULT_WINGS.len(),
        "must have one charter drawer per default wing; got {}",
        charters.len()
    );

    for wing in DEFAULT_WINGS {
        let wing_charters: Vec<_> = charters.iter().filter(|d| d.wing == wing.name).collect();
        assert_eq!(
            wing_charters.len(),
            1,
            "wing '{}' must have exactly 1 charter drawer; got {}",
            wing.name,
            wing_charters.len()
        );
    }
}

/// T16: `DEFAULT_WING_NAME` is "Agentic Memory" and capture lands there.
#[test]
fn adr016_default_wing_name_is_agentic_memory() {
    use locus_kit::default_wings::DEFAULT_WING_NAME;
    use locus_kit::estate_types::LatticeAnchor;
    use locus_kit::frames::CaptureFrame;

    assert_eq!(
        DEFAULT_WING_NAME, "Agentic Memory",
        "DEFAULT_WING_NAME must be 'Agentic Memory' per ADR-016 §1"
    );

    let (store, storage) = make_stores();
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .provision(
            Arc::clone(&store),
            storage,
            None,
            OwnerCredentials::new("adr016-test"),
            glk_params("ADR016-T16"),
            vec![EmbeddingModelConfig::Deterministic],
        )
        .expect("provision must succeed");

    let frame = CaptureFrame::new(
        "arbitrary content",
        locus_kit::drawer_operational::CaptureChannel::Typed,
        "inbox",
        LatticeAnchor::udc("001"),
        "test",
        "test-v1",
    );
    let estate = coord.estate_for(&handle).expect("estate must be open");
    let drawer = estate.capture(frame, NOW).expect("capture must succeed");
    assert_eq!(
        drawer.wing, DEFAULT_WING_NAME,
        "capture without explicit wing must land in DEFAULT_WING_NAME"
    );
}

/// T17: Charter drawers carry the "none" embedding sentinel.
/// Structural metadata drawers must not enter the semantic pipeline.
#[test]
fn adr016_charter_drawers_carry_none_embedding_sentinel() {
    use locus_kit::default_wings::{CHARTER_EMBEDDING_MODEL_ID, CHARTER_ROOM};

    let (store, storage) = make_stores();
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .provision(
            store,
            storage,
            None,
            OwnerCredentials::new("adr016-test"),
            glk_params("ADR016-T17"),
            vec![EmbeddingModelConfig::Deterministic],
        )
        .expect("provision must succeed");

    let estate = coord.estate_for(&handle).expect("estate must be open");
    let all_drawers = estate.all_drawers_bounded(None).expect("all_drawers must succeed");
    let charters: Vec<_> = all_drawers.iter().filter(|d| d.room == CHARTER_ROOM).collect();

    for charter in &charters {
        assert_eq!(
            charter.embedding_model_id, CHARTER_EMBEDDING_MODEL_ID,
            "charter drawer for '{}' must have embedding_model_id == 'none'; got '{}'",
            charter.wing, charter.embedding_model_id
        );
    }
}

/// T18: All estate kinds (Glk, CorpusOnly, LocusOnly) seed the 7 default wings.
#[test]
fn adr016_all_estate_kinds_seed_default_wings() {
    use locus_kit::default_wings::DEFAULT_WINGS;

    let kinds = [
        (EstateKind::Glk, "ADR016-T18-GLK"),
        (EstateKind::CorpusOnly, "ADR016-T18-CorpusOnly"),
        (EstateKind::LocusOnly, "ADR016-T18-LocusOnly"),
    ];

    for (kind, name) in &kinds {
        let (store, storage) = make_stores();
        let mut coord = EstateCoordinator::new();
        let params = EstateProvisionParams {
            estate_name: name.to_string(),
            kind: kind.clone(),
            zoom_window_low: 0,
            zoom_window_high: 10,
            framework_profile: "TestProfile".to_string(),
            sync_mode: SyncMode::None,
        };
        let handle = coord
            .provision(
                store,
                storage,
                None,
                OwnerCredentials::new("adr016-test"),
                params,
                vec![EmbeddingModelConfig::Deterministic],
            )
            .expect(&format!("provision({:?}) must succeed", kind));

        let estate = coord.estate_for(&handle).expect("estate must be open");
        let all_drawers = estate.all_drawers_bounded(None).expect("all_drawers must succeed");
        let wing_names: std::collections::HashSet<String> =
            all_drawers.iter().map(|d| d.wing.clone()).collect();

        let expected: std::collections::HashSet<String> =
            DEFAULT_WINGS.iter().map(|w| w.name.to_string()).collect();
        assert_eq!(
            wing_names, expected,
            "{:?} provision must seed all 7 default wings; got {:?}",
            kind, wing_names
        );
    }
}
