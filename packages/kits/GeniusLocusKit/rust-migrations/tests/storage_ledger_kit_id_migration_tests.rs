//! Verification fixture for the GLK 1.4 → 1.5 storage-ledger kit-id
//! migration. Rust twin of Swift `StorageLedgerKitIDMigrationTests.swift`.
//!
//! Tests:
//!   1. V1_4-stamped estate carrying the two old rows: after the capsule the
//!      rows carry the new ids at the same versions, the old ids have no
//!      row, a bystander row is untouched, and the estate is stamped V1_5.
//!   2. Idempotence: a second run reports `NoRow` for both pairs and leaves
//!      the stamp at V1_5.
//!   3. An estate with no vector rows: `NoRow` for both pairs, nothing
//!      created, stamped V1_5.
//!   4. Rows under both ids: both left as they are and reported as
//!      `Conflict`; the stamp still advances.
//!   5. StorageUnavailable: an unregistered handle returns the error variant.
//!   6. Full chain from V1_0 carrying the old rows ends at V1_5 (the rewrite
//!      runs before the 1.0→1.1 capsule, which opens the vector store).
//!      (Gated on feature = "migration-v1-0-to-v1-1".)
//!   7. The capsule's pairs are the frozen literals.

use std::sync::Arc;

use genius_locus_kit::estate_format::{EstateFormatStore, EstateFormatVersion};
use genius_locus_kit::EstateCoordinator;
use genius_locus_kit_migrations::{
    StorageLedgerKitIdMigrationError, StorageLedgerKitIdMigrationExt,
    StorageLedgerKitIdMigrationReport, StorageLedgerKitIdRename, STORAGE_LEDGER_KIT_ID_RENAMES,
};
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::OwnerCredentials;
use persistence_kit::{SchemaDeclaration, SchemaKitRenameOutcome, Storage};

const NOW: i64 = 1_756_000_000_000; // millis

/// Record a schema-version ledger row for `kit_id` at `version` without
/// declaring any table: the same row the vector tier's stores leave behind
/// when they open an estate.
fn seed_ledger(storage: &Arc<dyn Storage>, kit_id: &str, version: i32) {
    storage
        .migrate(&SchemaDeclaration::new(kit_id, version, vec![]))
        .expect("seed ledger row");
}

fn version(storage: &Arc<dyn Storage>, kit_id: &str) -> i32 {
    storage
        .current_schema_version_for(kit_id)
        .expect("read ledger version")
}

/// Open an in-memory estate stamped at `stamp_version`, carrying the old
/// vector-tier ledger rows when `with_old_rows`.
fn make_estate(
    stamp_version: EstateFormatVersion,
    with_old_rows: bool,
) -> (
    EstateCoordinator,
    genius_locus_kit::handle::EstateHandle,
    Arc<dyn Storage>,
) {
    let store = Arc::new(InMemoryDrawerStore::new(NOW, None).expect("InMemoryDrawerStore::new"));
    let storage: Arc<dyn Storage> = store
        .storage()
        .expect("InMemoryDrawerStore exposes storage");
    let pairs = STORAGE_LEDGER_KIT_ID_RENAMES;
    if with_old_rows {
        seed_ledger(&storage, pairs.vector_store.from, 6);
        seed_ledger(&storage, pairs.representation_claims.from, 1);
    }
    EstateFormatStore::new(Arc::clone(&storage))
        .stamp(stamp_version, NOW)
        .expect("stamp estate format");
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(
            Arc::clone(&store) as Arc<dyn DrawerStore>,
            OwnerCredentials::new("mig15-test-owner"),
            0,
            100,
        )
        .expect("EstateCoordinator::open");
    (coord, handle, storage)
}

fn read_stamp(storage: &Arc<dyn Storage>) -> EstateFormatVersion {
    EstateFormatStore::new(Arc::clone(storage))
        .read_if_present()
        .expect("read format version")
        .expect("version must be set")
}

// ---------------------------------------------------------------------------
// §1 Core: the rows move, nothing else changes, V1_5 stamped
// ---------------------------------------------------------------------------

#[test]
fn v1_4_estate_rows_move_to_their_new_ids() {
    let pairs = STORAGE_LEDGER_KIT_ID_RENAMES;
    let (coord, handle, storage) = make_estate(EstateFormatVersion::V1_4, true);
    seed_ledger(&storage, "Bystander", 9);
    let locus_before = version(&storage, "LocusKit");
    assert_eq!(version(&storage, pairs.vector_store.from), 6);
    assert_eq!(version(&storage, pairs.representation_claims.from), 1);
    assert_eq!(version(&storage, pairs.vector_store.to), 0);

    let report = coord
        .run_storage_ledger_kit_id_migration(&handle, NOW)
        .expect("migration must succeed on a v1_4 estate");

    assert_eq!(
        report,
        StorageLedgerKitIdMigrationReport {
            vector_store: SchemaKitRenameOutcome::Renamed { version: 6 },
            representation_claims: SchemaKitRenameOutcome::Renamed { version: 1 },
        }
    );
    assert_eq!(read_stamp(&storage), EstateFormatVersion::V1_5);
    assert_eq!(read_stamp(&storage), EstateFormatVersion::CURRENT);
    assert_eq!(version(&storage, pairs.vector_store.to), 6);
    assert_eq!(version(&storage, pairs.representation_claims.to), 1);
    assert_eq!(version(&storage, pairs.vector_store.from), 0);
    assert_eq!(version(&storage, pairs.representation_claims.from), 0);
    assert_eq!(version(&storage, "Bystander"), 9);
    assert_eq!(version(&storage, "LocusKit"), locus_before);
}

// ---------------------------------------------------------------------------
// §2 Idempotence
// ---------------------------------------------------------------------------

#[test]
fn capsule_is_idempotent() {
    let pairs = STORAGE_LEDGER_KIT_ID_RENAMES;
    let (coord, handle, storage) = make_estate(EstateFormatVersion::V1_4, true);
    coord
        .run_storage_ledger_kit_id_migration(&handle, NOW)
        .expect("first call must succeed");
    let second = coord
        .run_storage_ledger_kit_id_migration(&handle, NOW)
        .expect("second call must be idempotent");
    assert_eq!(
        second,
        StorageLedgerKitIdMigrationReport {
            vector_store: SchemaKitRenameOutcome::NoRow,
            representation_claims: SchemaKitRenameOutcome::NoRow,
        }
    );
    assert_eq!(read_stamp(&storage), EstateFormatVersion::V1_5);
    assert_eq!(version(&storage, pairs.vector_store.to), 6);
    assert_eq!(version(&storage, pairs.representation_claims.to), 1);
}

// ---------------------------------------------------------------------------
// §3 No vector rows: nothing created, still stamped
// ---------------------------------------------------------------------------

#[test]
fn estate_without_vector_rows_is_stamped_without_change() {
    let pairs = STORAGE_LEDGER_KIT_ID_RENAMES;
    let (coord, handle, storage) = make_estate(EstateFormatVersion::V1_4, false);
    let report = coord
        .run_storage_ledger_kit_id_migration(&handle, NOW)
        .expect("migration must succeed on an estate without vector rows");
    assert_eq!(
        report,
        StorageLedgerKitIdMigrationReport {
            vector_store: SchemaKitRenameOutcome::NoRow,
            representation_claims: SchemaKitRenameOutcome::NoRow,
        }
    );
    assert_eq!(read_stamp(&storage), EstateFormatVersion::V1_5);
    assert_eq!(version(&storage, pairs.vector_store.to), 0);
    assert_eq!(version(&storage, pairs.vector_store.from), 0);
    assert_eq!(version(&storage, pairs.representation_claims.to), 0);
    assert_eq!(version(&storage, pairs.representation_claims.from), 0);
}

// ---------------------------------------------------------------------------
// §4 Rows under both ids are reported and left alone
// ---------------------------------------------------------------------------

#[test]
fn rows_under_both_ids_are_a_conflict_left_in_place() {
    let pairs = STORAGE_LEDGER_KIT_ID_RENAMES;
    let (coord, handle, storage) = make_estate(EstateFormatVersion::V1_4, true);
    seed_ledger(&storage, pairs.vector_store.to, 6);

    let report = coord
        .rewrite_storage_ledger_kit_ids(&handle)
        .expect("rewrite must succeed");
    assert_eq!(
        report.vector_store,
        SchemaKitRenameOutcome::Conflict { old_version: 6, new_version: 6 }
    );
    assert_eq!(
        report.representation_claims,
        SchemaKitRenameOutcome::Renamed { version: 1 }
    );
    assert_eq!(version(&storage, pairs.vector_store.from), 6);
    assert_eq!(version(&storage, pairs.vector_store.to), 6);

    // The stamp still advances: the conflict is reported, never a refusal.
    coord
        .run_storage_ledger_kit_id_migration(&handle, NOW)
        .expect("migration must succeed with a reported conflict");
    assert_eq!(read_stamp(&storage), EstateFormatVersion::V1_5);
}

// ---------------------------------------------------------------------------
// §5 StorageUnavailable
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
    let result = coord.run_storage_ledger_kit_id_migration(&unregistered_handle, NOW);
    assert!(
        matches!(result, Err(StorageLedgerKitIdMigrationError::StorageUnavailable { .. })),
        "expected StorageUnavailable, got {result:?}"
    );
}

// ---------------------------------------------------------------------------
// §6 Full chain from V1_0 (only when migration-floor-1-0 is enabled)
// ---------------------------------------------------------------------------

#[cfg(feature = "migration-v1-0-to-v1-1")]
#[test]
fn v1_0_estate_with_old_rows_runs_full_chain_to_v1_5() {
    use corpus_kit_providers::default_ensemble;
    use genius_locus_kit_migrations::{compiled_floor, MigrationChainExt};

    let pairs = STORAGE_LEDGER_KIT_ID_RENAMES;
    let (mut coord, handle, storage) = make_estate(EstateFormatVersion::V1_0, true);
    assert_eq!(compiled_floor(), Some(EstateFormatVersion::V1_0));
    coord
        .run_migration_chain(&handle, NOW, default_ensemble())
        .expect("full chain must succeed on an empty v1_0 estate");
    assert_eq!(read_stamp(&storage), EstateFormatVersion::V1_5, "full chain must end at V1_5");
    assert_eq!(read_stamp(&storage), EstateFormatVersion::CURRENT);
    assert!(version(&storage, pairs.vector_store.to) >= 6);
    assert!(version(&storage, pairs.representation_claims.to) >= 1);
}

// ---------------------------------------------------------------------------
// §7 The pairs are frozen literals
// ---------------------------------------------------------------------------

#[test]
fn pairs_are_frozen_literals() {
    let pairs = STORAGE_LEDGER_KIT_ID_RENAMES;
    assert_eq!(
        pairs.vector_store,
        StorageLedgerKitIdRename { from: "VectorKit", to: "SynapseKit" }
    );
    assert_eq!(
        pairs.representation_claims,
        StorageLedgerKitIdRename { from: "VectorKitClaims", to: "SynapseKitClaims" }
    );
}
