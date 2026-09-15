//! The `run_migration_chain` entry gate: the chain reads the persisted
//! estate format before any capsule runs and dispatches from it, the Rust
//! twin of `GLKMigrationCatalog.prepare` (Swift) and of the
//! `GLKMigrationCatalogTests` that pin it.
//!
//! Tests:
//!   1. A stamp above CURRENT is refused with `UnsupportedFuture` and the
//!      stamp is untouched.
//!   2. A stamp below the compiled floor is refused with
//!      `BelowCompiledFloor` and the stamp is untouched (a build whose floor
//!      is above 1.0; under `migration-floor-1-0` nothing is below the floor).
//!   3. A current estate is a no-op: `Ok`, stamp unchanged.
//!   4. An unstamped estate is stamped current and no capsule runs.
//!   5. Every refusal is an error a caller can print (`Display`).
//!   6. Every `Ok` leaves the estate stamped CURRENT: the postcondition
//!      `refresh_after_chain` records in the manifest.

use std::sync::Arc;

use corpus_kit_providers::default_ensemble;
use genius_locus_kit::estate_format::{EstateFormatStore, EstateFormatVersion};
use genius_locus_kit::EstateCoordinator;
// `compiled_floor` is read only by the below-floor test, which a 1.0 floor
// compiles out (nothing sits below 1.0).
#[cfg(not(feature = "migration-v1-0-to-v1-1"))]
use genius_locus_kit_migrations::compiled_floor;
use genius_locus_kit_migrations::{MigrationChainError, MigrationChainExt};
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::OwnerCredentials;
use persistence_kit::Storage;

const NOW: i64 = 1_756_000_000_000; // millis

/// Open an in-memory estate, stamped at `stamp` when given.
fn make_estate(
    stamp: Option<EstateFormatVersion>,
) -> (
    EstateCoordinator,
    genius_locus_kit::handle::EstateHandle,
    Arc<dyn Storage>,
) {
    let store = Arc::new(InMemoryDrawerStore::new(NOW, None).expect("InMemoryDrawerStore::new"));
    let storage: Arc<dyn Storage> = store
        .storage()
        .expect("InMemoryDrawerStore exposes storage");
    if let Some(version) = stamp {
        EstateFormatStore::new(Arc::clone(&storage))
            .stamp(version, NOW)
            .expect("stamp estate format");
    }
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(
            Arc::clone(&store) as Arc<dyn DrawerStore>,
            OwnerCredentials::new("chain-test-owner"),
            0,
            100,
        )
        .expect("EstateCoordinator::open");
    (coord, handle, storage)
}

fn read_stamp(storage: &Arc<dyn Storage>) -> Option<EstateFormatVersion> {
    EstateFormatStore::new(Arc::clone(storage))
        .read_if_present()
        .expect("read estate format")
}

// ---------------------------------------------------------------------------
// §1 A future format is refused before any capsule runs
// ---------------------------------------------------------------------------

#[test]
fn future_format_is_refused_and_left_untouched() {
    let future = EstateFormatVersion { major: 9, minor: 9 };
    let (mut coord, handle, storage) = make_estate(Some(future));
    let error = coord
        .run_migration_chain(&handle, NOW, default_ensemble())
        .expect_err("a stamp above CURRENT must be refused");
    assert_eq!(
        error,
        MigrationChainError::UnsupportedFuture { found: future, current: EstateFormatVersion::CURRENT }
    );
    assert_eq!(read_stamp(&storage), Some(future), "a refusal writes nothing");
    assert!(error.to_string().contains("9.9"), "Display names the found format: {error}");
}

// ---------------------------------------------------------------------------
// §2 A stamp below the compiled floor is refused (floors above 1.0 only)
// ---------------------------------------------------------------------------

#[cfg(not(feature = "migration-v1-0-to-v1-1"))]
#[test]
fn below_compiled_floor_is_refused_and_left_untouched() {
    let floor = compiled_floor().expect("this test runs with a floor compiled");
    assert!(
        EstateFormatVersion::V1_0 < floor,
        "the 1.0 stamp must sit below the compiled floor for this test; floor is {floor}"
    );
    let (mut coord, handle, storage) = make_estate(Some(EstateFormatVersion::V1_0));
    let error = coord
        .run_migration_chain(&handle, NOW, default_ensemble())
        .expect_err("a stamp below the compiled floor must be refused");
    assert_eq!(
        error,
        MigrationChainError::BelowCompiledFloor { found: EstateFormatVersion::V1_0, floor }
    );
    assert_eq!(
        read_stamp(&storage),
        Some(EstateFormatVersion::V1_0),
        "a refused estate keeps its stamp; no capsule stamped over it"
    );
    assert!(error.to_string().contains("below"), "Display names the refusal: {error}");
}

// ---------------------------------------------------------------------------
// §3 A current estate is a no-op
// ---------------------------------------------------------------------------

#[test]
fn current_estate_is_a_no_op() {
    let (mut coord, handle, storage) = make_estate(Some(EstateFormatVersion::CURRENT));
    coord
        .run_migration_chain(&handle, NOW, default_ensemble())
        .expect("a current estate needs no capsule");
    assert_eq!(read_stamp(&storage), Some(EstateFormatVersion::CURRENT));
}

// ---------------------------------------------------------------------------
// §4 An unstamped estate is stamped current
// ---------------------------------------------------------------------------

#[test]
fn unstamped_estate_is_stamped_current() {
    let (mut coord, handle, storage) = make_estate(None);
    assert_eq!(read_stamp(&storage), None, "precondition: no stamp");
    coord
        .run_migration_chain(&handle, NOW, default_ensemble())
        .expect("an unstamped estate is a fresh bare open");
    assert_eq!(
        read_stamp(&storage),
        Some(EstateFormatVersion::CURRENT),
        "a fresh estate is born at the current format, as the Swift catalog stamps it"
    );
}

// ---------------------------------------------------------------------------
// §6 Every Ok leaves the estate at CURRENT
// ---------------------------------------------------------------------------

/// `refresh_after_chain` records `EstateFormatVersion::CURRENT` without
/// re-reading the stamp, on the strength of this postcondition: whatever path
/// the chain took to `Ok`, the estate is at CURRENT afterwards. The Swift twin
/// reads `GLKMigrationPreparation.format`, which every success path sets to
/// `.current`; this test is what makes the Rust shortcut a fact rather than a
/// claim.
#[test]
fn a_chain_that_returns_ok_leaves_the_estate_current() {
    for stamp in [None, Some(EstateFormatVersion::CURRENT)] {
        let (mut coord, handle, storage) = make_estate(stamp);
        coord
            .run_migration_chain(&handle, NOW, default_ensemble())
            .expect("an unstamped or current estate returns Ok");
        assert_eq!(read_stamp(&storage), Some(EstateFormatVersion::CURRENT), "stamp {stamp:?} -> Ok -> CURRENT");
    }
    // A historical stamp one step below CURRENT runs the last capsule, which
    // writes the CURRENT stamp as the chain's final write.
    #[cfg(feature = "migration-v1-6-to-v1-7")]
    {
        let (mut coord, handle, storage) = make_estate(Some(EstateFormatVersion::V1_6));
        coord
            .run_migration_chain(&handle, NOW, default_ensemble())
            .expect("the 1.6 -> 1.7 capsule runs on an in-memory estate");
        assert_eq!(read_stamp(&storage), Some(EstateFormatVersion::CURRENT));
    }
    // An estate stamped exactly V1_7 ends at CURRENT with `fact_extraction`
    // seeded: the seeded key is what shows the chain invoked the 1.7 -> 1.8
    // capsule rather than stamping on its own. Whether the chain skipped the
    // 1.6 -> 1.7 vacuum on the way is not observable on this bare fixture;
    // that guard is gated by whole_record_float_vacuum_migration_tests §8.
    #[cfg(feature = "migration-v1-7-to-v1-8")]
    {
        let (mut coord, handle, storage) = make_estate(Some(EstateFormatVersion::V1_7));
        let before = coord
            .estate_for(&handle)
            .expect("estate_for")
            .meta(genius_locus_kit::EstatePreferenceKey::FactExtraction.as_str())
            .expect("meta");
        assert!(before.is_none(), "precondition: key absent before the chain runs");
        coord
            .run_migration_chain(&handle, NOW, default_ensemble())
            .expect("the 1.7 -> 1.8 capsule runs on a V1_7 estate");
        assert_eq!(
            read_stamp(&storage),
            Some(EstateFormatVersion::CURRENT),
            "V1_7 -> chain -> CURRENT",
        );
        let seeded = coord
            .estate_for(&handle)
            .expect("estate_for")
            .meta(genius_locus_kit::EstatePreferenceKey::FactExtraction.as_str())
            .expect("meta");
        assert_eq!(
            seeded.as_deref(),
            Some("on"),
            "the chain ran the 1.7 -> 1.8 capsule, which seeds the key"
        );
    }
}
