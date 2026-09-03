//! Verification fixture for the GLK 1.1 → 1.2 index-composition-column migration.
//! Rust twin of Swift `IndexCompositionColumnMigrationTests.swift`.
//!
//! Tests:
//!   1. v1_1-stamped estate with pre-v3 (version 2) schema: after migration the
//!      composition_policy column is present and writable via store API.
//!   2. Idempotence: calling the capsule twice on the same estate is a no-op.
//!   3. Full chain from v1_0 through the compiled catalog ends at the current
//!      format, v1_3 — the 1.2 → 1.3 capsule runs after this one.
//!      (Gated on feature = "migration-v1-0-to-v1-1" being enabled — only when
//!       the v1_1_to_v1_2 test crate is built with the floor-1-0 feature.)

use std::sync::Arc;

use corpus_kit::{CorpusIndexState, CorpusIndexStateStore};
use genius_locus_kit::estate_format::{EstateFormatStore, EstateFormatVersion};
use genius_locus_kit::EstateCoordinator;
use genius_locus_kit_migrations::{
    IndexCompositionColumnMigrationExt, IndexCompositionColumnMigrationError,
};
#[cfg(feature = "migration-v1-0-to-v1-1")]
use genius_locus_kit_migrations::{compiled_floor, DistilledSourceDigestColumnMigrationExt};
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::OwnerCredentials;
use persistence_kit::schema::{ColumnDeclaration, SchemaDeclaration, TableDeclaration};
use persistence_kit::Storage;

const NOW: i64 = 1_756_000_000_000; // millis

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build a corpus_index_state schema at version 2 (no
/// composition_policy column). Applying this to storage before migrate-to-v3
/// simulates an estate written before the corpus_index_state ladder reached version 3.
fn version2_index_state_schema() -> SchemaDeclaration {
    SchemaDeclaration::new(
        "CorpusKitIndexState",
        2,
        vec![
            TableDeclaration::new(
                "corpus_index_state",
                vec![
                    ColumnDeclaration::text("content_id"),
                    ColumnDeclaration::int("revision"),
                    ColumnDeclaration::text("digest"),
                    ColumnDeclaration::int("index_version"),
                    ColumnDeclaration::text("applied_cursor").nullable(),
                    ColumnDeclaration::timestamp("updated_at"),
                    // No composition_policy column: this is the pre-v3 layout.
                    ColumnDeclaration::bitmap("operational_bitmap"),
                ],
                vec!["content_id".to_string()],
            ),
            TableDeclaration::new(
                "corpus_bitmap_generation",
                vec![
                    ColumnDeclaration::int("singleton_id"),
                    ColumnDeclaration::int("basis_generation")
                        .with_default(persistence_kit::TypedValue::Int(0)),
                ],
                vec!["singleton_id".to_string()],
            ),
        ],
    )
    // No migrations list: this declaration is the stable v2 snapshot applied
    // directly, not upgraded through the ladder.
}

/// Open an in-memory estate stamped at `stamp_version`, with the pre-v3
/// corpus_index_state schema (v2 — no composition_policy). Returns the
/// coordinator, handle, and underlying storage Arc for direct schema inspection.
fn make_version2_estate(
    stamp_version: EstateFormatVersion,
) -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle, Arc<dyn Storage>) {
    let store = InMemoryDrawerStore::new(NOW, None).expect("InMemoryDrawerStore::new");
    let storage: Arc<dyn Storage> = store
        .storage()
        .expect("InMemoryDrawerStore exposes storage");

    // Apply the pre-v3 corpus_index_state schema (v2) directly so the
    // table exists but lacks composition_policy. The coordinator's open()
    // will not add this table because CorpusKit schemas are applied lazily
    // by the corpus subsystem, not by the base estate open.
    storage
        .migrate(&version2_index_state_schema())
        .expect("apply pre-v3 schema");

    // Stamp the requested estate-format version.
    EstateFormatStore::new(Arc::clone(&storage))
        .stamp(stamp_version, NOW)
        .expect("stamp estate format");

    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(
            Arc::new(store),
            OwnerCredentials::new("mig12-test-owner"),
            0,
            100,
        )
        .expect("EstateCoordinator::open");

    (coord, handle, storage)
}

// ---------------------------------------------------------------------------
// §1 Core fix: v1_1-stamped estate gains composition_policy column
// ---------------------------------------------------------------------------

/// A v1_1-stamped estate with the pre-v3 schema gets the composition_policy
/// column added by the capsule. The column is then writable via the store API.
#[test]
fn v1_1_estate_gains_composition_policy_column() {
    let (coord, handle, storage) = make_version2_estate(EstateFormatVersion::V1_1);

    coord
        .run_index_composition_column_migration(&handle, NOW)
        .expect("migration must succeed on v1_1 estate");

    // Verify the estate is now stamped V1_2.
    let stamped = EstateFormatStore::new(Arc::clone(&storage))
        .read_if_present()
        .expect("read format version")
        .expect("version must be set");
    assert_eq!(stamped, EstateFormatVersion::V1_2, "estate must be stamped V1_2");

    // Verify the column is present by writing a row with a composition_policy value
    // via the store API. Any "no such column" failure surfaces here as a panic.
    let store = CorpusIndexStateStore::new(Arc::clone(&storage));
    let state = CorpusIndexState {
        content_id: "drawer:rust-mig12-test".to_string(),
        revision: 1,
        digest: "abc123".to_string(),
        index_version: 1,
        applied_cursor: None,
        updated_at_millis: NOW,
        operational_bitmap: 0,
        composition_policy_id: "policy-v1".to_string(),
    };
    store
        .advance(&state)
        .expect("advance must succeed — composition_policy column must exist");

    // Read back and verify round-trip.
    let read = store
        .state("drawer:rust-mig12-test")
        .expect("state must succeed")
        .expect("row must exist");
    assert_eq!(read.composition_policy_id, "policy-v1");
}

// ---------------------------------------------------------------------------
// §2 Idempotence: second call is a no-op
// ---------------------------------------------------------------------------

#[test]
fn capsule_is_idempotent() {
    let (coord, handle, storage) = make_version2_estate(EstateFormatVersion::V1_1);

    coord
        .run_index_composition_column_migration(&handle, NOW)
        .expect("first call must succeed");

    // Second call on the already-migrated estate must also succeed without error.
    coord
        .run_index_composition_column_migration(&handle, NOW)
        .expect("second call must be idempotent");

    let stamped = EstateFormatStore::new(Arc::clone(&storage))
        .read_if_present()
        .expect("read format version")
        .expect("version must be set");
    assert_eq!(stamped, EstateFormatVersion::V1_2);
}

// ---------------------------------------------------------------------------
// §3 StorageUnavailable: unregistered handle returns the correct error variant
// ---------------------------------------------------------------------------

#[test]
fn unregistered_handle_returns_storage_unavailable() {
    let coord = EstateCoordinator::new();
    // Build a fake handle that was never registered in this coordinator.
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

    let result = coord.run_index_composition_column_migration(&unregistered_handle, NOW);
    assert!(
        matches!(result, Err(IndexCompositionColumnMigrationError::StorageUnavailable { .. })),
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
    use genius_locus_kit_migrations::SharedContentMigrationExt;

    let (mut coord, handle, storage) = make_version2_estate(EstateFormatVersion::V1_0);

    // Confirm compiled floor covers V1_0.
    assert_eq!(compiled_floor(), Some(EstateFormatVersion::V1_0));

    // Run the v1_0 → v1_1 capsule (SharedContentMigration). This estate has
    // no legacy chunks, so it completes immediately and stamps V1_1 explicitly.
    coord
        .run_shared_content_migration(&handle, NOW, default_ensemble())
        .expect("SCM must succeed on empty v1_0 estate");

    // Verify stamp is V1_1 before applying the 1.1→1.2 capsule.
    // If SCM stamped current (V1_2), the ordering invariant is broken.
    let after_scm = EstateFormatStore::new(Arc::clone(&storage))
        .read_if_present()
        .expect("read format")
        .expect("version set");
    assert_eq!(after_scm, EstateFormatVersion::V1_1, "SCM must stamp V1_1, not V1_2");

    // Run the v1_1 → v1_2 capsule.
    coord
        .run_index_composition_column_migration(&handle, NOW)
        .expect("index composition column migration must succeed");

    let after_icm = EstateFormatStore::new(Arc::clone(&storage))
        .read_if_present()
        .expect("read format")
        .expect("version set");
    assert_eq!(after_icm, EstateFormatVersion::V1_2, "the 1.1→1.2 capsule stamps V1_2, not current");

    // Run the v1_2 → v1_3 capsule: the chain ends at the current format.
    coord
        .run_distilled_source_digest_column_migration(&handle, NOW)
        .expect("distilled source digest column migration must succeed");
    let final_stamp = EstateFormatStore::new(Arc::clone(&storage))
        .read_if_present()
        .expect("read format")
        .expect("version set");
    assert_eq!(final_stamp, EstateFormatVersion::V1_3, "estate must be stamped V1_3 after full chain");
    assert_eq!(final_stamp, EstateFormatVersion::CURRENT);

    // Verify corpus_index_state is writable (composition_policy column present).
    let store = CorpusIndexStateStore::new(Arc::clone(&storage));
    let state = CorpusIndexState {
        content_id: "drawer:chain-test".to_string(),
        revision: 1,
        digest: "def456".to_string(),
        index_version: 1,
        applied_cursor: None,
        updated_at_millis: NOW,
        operational_bitmap: 0,
        composition_policy_id: String::new(),
    };
    store
        .advance(&state)
        .expect("advance after full chain — composition_policy must be present");
}
