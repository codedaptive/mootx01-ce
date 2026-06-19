// find_nearest_distilled_parity.rs — conformance gate for DG3.
//
// Parity of `FindNearestDistilledTests.swift`. Covers:
//  T1 — Happy path: vector filed under "distillation-features-v1"
//       is returned when the probe Engram matches.
//  T2 — Stale handle: VerbDispatchError::EstateNotOpen after close.
//  T3 — No VectorStore registered: VerbDispatchError::Verb(NotSupportedByEstate).
//  T4 — limit = 0: empty Vec, no error.

use std::sync::Arc;

use genius_locus_kit::{EstateCoordinator, VerbDispatchError, VerbError};
use locus_kit::{
    drawer_store::DrawerStore, drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::OwnerCredentials,
};
use persistence_kit::inmemory::InMemoryStorage;
use substrate_types::Fingerprint256;
use vectorkit::VectorStore;

const NOW: i64 = 1_700_000_000;

fn open_one() -> (EstateCoordinator, genius_locus_kit::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new("owner-dg3-rust-tests"), 0, 100)
        .expect("open");
    (coord, handle)
}

/// Build a VectorStore on a fresh InMemoryStorage, apply the vectors schema,
/// and return it ready for `add_vector` calls.
fn make_vector_store() -> Arc<VectorStore> {
    let storage = Arc::new(InMemoryStorage::with_estate(uuid::Uuid::new_v4()));
    Arc::new(VectorStore::open(storage).expect("VectorStore::open"))
}

// MARK: - T1: Happy path

/// Open an estate, register a VectorStore, file one vector under
/// "distillation-features-v1" with the zero Fingerprint256 probe.
/// `find_nearest_distilled` with the same probe must return the filed item.
#[test]
fn find_nearest_distilled_returns_matching_vector() {
    let (mut coord, h) = open_one();
    let store = make_vector_store();

    let probe = Fingerprint256::ZERO;
    store
        .add_vector("distilled-item-1", &probe, "distillation-features-v1", "1.0", NOW)
        .expect("add_vector");

    coord.register_vector_store(&h, store);

    let results = coord
        .find_nearest_distilled(&h, &probe, 5)
        .expect("find_nearest_distilled");

    assert!(!results.is_empty(), "must return the filed vector for a matching probe");
    assert_eq!(
        results[0].item_id, "distilled-item-1",
        "nearest result must be the item whose Engram matches the probe (Hamming 0)"
    );
}

// MARK: - T2: Stale handle

/// After `close`, the handle is stale. `find_nearest_distilled` must return
/// `VerbDispatchError::EstateNotOpen` — parity of the Swift estateNotOpen contract.
#[test]
fn find_nearest_distilled_on_stale_handle_returns_estate_not_open() {
    let (mut coord, h) = open_one();
    coord.close(&h).expect("close");

    let err = coord
        .find_nearest_distilled(&h, &Fingerprint256::ZERO, 1)
        .expect_err("must fail on stale handle");

    assert!(
        matches!(err, VerbDispatchError::EstateNotOpen { .. }),
        "expected EstateNotOpen, got {:?}",
        err
    );
}

// MARK: - T3: No VectorStore registered

/// An estate with no VectorStore registered returns
/// `VerbDispatchError::Verb(VerbError::NotSupportedByEstate)`.
/// Parity of the Swift `VerbError.notSupportedByEstate` path.
#[test]
fn find_nearest_distilled_without_vector_store_returns_not_supported() {
    let (coord, h) = open_one();
    // Deliberately do NOT register a VectorStore.

    let err = coord
        .find_nearest_distilled(&h, &Fingerprint256::ZERO, 1)
        .expect_err("must fail without VectorStore");

    match err {
        VerbDispatchError::Verb(VerbError::NotSupportedByEstate { ref verb }) => {
            assert_eq!(verb, "find_nearest_distilled", "verb label must match");
        }
        other => panic!(
            "expected Verb(NotSupportedByEstate), got {:?}",
            other
        ),
    }
}

// MARK: - T4: limit = 0

/// `limit = 0` returns an empty Vec without error. The inner
/// `VectorStore::find_nearest` guards `k > 0` and returns early.
#[test]
fn find_nearest_distilled_with_limit_zero_returns_empty() {
    let (mut coord, h) = open_one();
    let store = make_vector_store();

    store
        .add_vector("distilled-item-limit0", &Fingerprint256::ZERO, "distillation-features-v1", "1.0", NOW)
        .expect("add_vector");

    coord.register_vector_store(&h, store);

    let results = coord
        .find_nearest_distilled(&h, &Fingerprint256::ZERO, 0)
        .expect("limit=0 must not error");

    assert!(results.is_empty(), "limit=0 must return empty Vec");
}
