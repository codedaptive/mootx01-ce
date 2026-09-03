//! Verification fixture for the GLK 1.2 → 1.3 distilled-source-digest-column
//! migration. Rust twin of Swift `DistilledSourceDigestColumnMigrationTests.swift`.
//!
//! Tests:
//!   1. v1_2-stamped estate: after the capsule the LocusKit kit version is
//!      current, the estate is stamped V1_3, and a representation write that
//!      carries a source digest round-trips through the store API.
//!   2. Idempotence: calling the capsule twice on the same estate is a no-op
//!      that leaves the stamp at V1_3.
//!   3. StorageUnavailable: an unregistered handle returns the error variant.
//!   4. Full chain from v1_0 through the compiled catalog ends at V1_3.
//!      (Gated on feature = "migration-v1-0-to-v1-1" being enabled.)

use std::sync::Arc;

use context_distill_lib::digest::source_digest;
use genius_locus_kit::estate_format::{EstateFormatStore, EstateFormatVersion};
use genius_locus_kit::EstateCoordinator;
use genius_locus_kit_migrations::{
    DistilledSourceDigestColumnMigrationError, DistilledSourceDigestColumnMigrationExt,
};
use locus_kit::drawer::Drawer;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::OwnerCredentials;
use locus_kit::schema::{schema, KIT_ID, SCHEMA_VERSION};
use persistence_kit::Storage;

const NOW: i64 = 1_756_000_000_000; // millis
const TEST_PARENT: &str = "00000000-0000-4000-8000-000000000001";
const CONTENT: &str = "Digest column round-trip after the 1.2 to 1.3 capsule.";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Open an in-memory estate stamped at `stamp_version`. Opening the drawer
/// store applies the live LocusKit declaration, which replays the v17 → v18
/// ladder entry on this storage — the same replay every host open performs;
/// the capsule replays it again (idempotent) and turns the column's presence
/// into the V1_3 stamp the catalog keys on. Returns the coordinator, handle,
/// store, and underlying storage Arc for direct inspection.
fn make_estate(
    stamp_version: EstateFormatVersion,
) -> (
    EstateCoordinator,
    genius_locus_kit::handle::EstateHandle,
    Arc<InMemoryDrawerStore>,
    Arc<dyn Storage>,
) {
    let store = Arc::new(InMemoryDrawerStore::new(NOW, None).expect("InMemoryDrawerStore::new"));
    let storage: Arc<dyn Storage> = store
        .storage()
        .expect("InMemoryDrawerStore exposes storage");

    EstateFormatStore::new(Arc::clone(&storage))
        .stamp(stamp_version, NOW)
        .expect("stamp estate format");

    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(
            Arc::clone(&store) as Arc<dyn DrawerStore>,
            OwnerCredentials::new("mig13-test-owner"),
            0,
            100,
        )
        .expect("EstateCoordinator::open");

    (coord, handle, store, storage)
}

/// File one drawer and write a representation carrying the library's source
/// digest through the store API, then read the digest back.
fn write_and_read_digest(store: &InMemoryDrawerStore, id: &str) -> Option<String> {
    let drawer = Drawer::new(id, CONTENT, TEST_PARENT, "mig13-test", NOW, "test-model-v1");
    store.add_drawer(&drawer, NOW).expect("add_drawer");
    let written = store
        .set_distilled_representation(
            id,
            "Digest column round-trip.",
            genius_locus_kit::distillation_converter_id(),
            &source_digest(CONTENT),
            4,
            NOW,
        )
        .expect("set_distilled_representation");
    assert_eq!(written, 1);
    store
        .get_drawer(id)
        .expect("get_drawer")
        .expect("drawer exists")
        .distilled_source_digest
}

fn read_stamp(storage: &Arc<dyn Storage>) -> EstateFormatVersion {
    EstateFormatStore::new(Arc::clone(storage))
        .read_if_present()
        .expect("read format version")
        .expect("version must be set")
}

// ---------------------------------------------------------------------------
// §1 Core: v1_2-stamped estate is stamped V1_3 and the digest round-trips
// ---------------------------------------------------------------------------

#[test]
fn v1_2_estate_gains_digest_column_and_stamps_v1_3() {
    let (coord, handle, store, storage) = make_estate(EstateFormatVersion::V1_2);

    coord
        .run_distilled_source_digest_column_migration(&handle, NOW)
        .expect("migration must succeed on v1_2 estate");

    assert_eq!(read_stamp(&storage), EstateFormatVersion::V1_3, "estate must be stamped V1_3");
    assert_eq!(read_stamp(&storage), EstateFormatVersion::CURRENT);
    assert_eq!(
        storage.current_schema_version_for(KIT_ID).expect("kit version"),
        SCHEMA_VERSION,
        "the LocusKit ladder must be at v18 after the capsule"
    );
    assert_eq!(schema().version, SCHEMA_VERSION);
    assert_eq!(
        write_and_read_digest(&store, "00000000-0000-4000-8000-00000000c001").as_deref(),
        Some(source_digest(CONTENT).as_str())
    );
}

// ---------------------------------------------------------------------------
// §2 Idempotence: second call is a no-op
// ---------------------------------------------------------------------------

#[test]
fn capsule_is_idempotent() {
    let (coord, handle, store, storage) = make_estate(EstateFormatVersion::V1_2);

    coord
        .run_distilled_source_digest_column_migration(&handle, NOW)
        .expect("first call must succeed");
    coord
        .run_distilled_source_digest_column_migration(&handle, NOW)
        .expect("second call must be idempotent");

    assert_eq!(read_stamp(&storage), EstateFormatVersion::V1_3);
    assert_eq!(
        write_and_read_digest(&store, "00000000-0000-4000-8000-00000000c002").as_deref(),
        Some(source_digest(CONTENT).as_str())
    );
}

// ---------------------------------------------------------------------------
// §3 StorageUnavailable: unregistered handle returns the correct error variant
// ---------------------------------------------------------------------------

#[test]
fn unregistered_handle_returns_storage_unavailable() {
    let coord = EstateCoordinator::new();
    let store = InMemoryDrawerStore::new(NOW, None).expect("InMemoryDrawerStore::new");
    let mut staging = EstateCoordinator::new();
    let unregistered_handle = staging
        .open(
            Arc::new(store),
            OwnerCredentials::new("unregistered-owner"),
            0,
            100,
        )
        .expect("open in staging coord");

    let result = coord.run_distilled_source_digest_column_migration(&unregistered_handle, NOW);
    assert!(
        matches!(result, Err(DistilledSourceDigestColumnMigrationError::StorageUnavailable { .. })),
        "expected StorageUnavailable, got {result:?}"
    );
}

// ---------------------------------------------------------------------------
// §4 Full chain from v1_0 (only when migration-floor-1-0 is enabled)
// ---------------------------------------------------------------------------

#[cfg(feature = "migration-v1-0-to-v1-1")]
#[test]
fn v1_0_estate_runs_full_chain_to_v1_3() {
    use corpus_kit_providers::default_ensemble;
    use genius_locus_kit_migrations::{compiled_floor, MigrationChainExt};

    let (mut coord, handle, store, storage) = make_estate(EstateFormatVersion::V1_0);

    // Confirm compiled floor covers V1_0.
    assert_eq!(compiled_floor(), Some(EstateFormatVersion::V1_0));

    // The whole compiled chain, as every Rust host runs it: 1.0 → 1.1 (shared
    // content, which stamps V1_1), 1.1 → 1.2 (index composition column, which
    // stamps V1_2), 1.2 → 1.3 (this capsule, which stamps V1_3).
    coord
        .run_migration_chain(&handle, NOW, default_ensemble())
        .expect("full chain must succeed on an empty v1_0 estate");

    assert_eq!(read_stamp(&storage), EstateFormatVersion::V1_3, "full chain must end at V1_3");
    assert_eq!(
        write_and_read_digest(&store, "00000000-0000-4000-8000-00000000c004").as_deref(),
        Some(source_digest(CONTENT).as_str())
    );
}
