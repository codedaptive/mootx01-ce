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
//!   7. The capsule's pairs are the frozen literals, and the new ids are what
//!      the vector tier's stores declare.
//!   8. On a SQLite estate a pre-rename runtime left behind, the renamed
//!      store's ladder finds its row after the capsule and nothing runs;
//!      without the capsule the ladder replays from version 0: v5→v6
//!      rebuilds `vectors` and folds every row's generation to 0, and the
//!      ledger keeps a duplicate row under the old id (the failure, observed).

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

// ---------------------------------------------------------------------------
// §8 The renamed store opens the migrated estate without replaying
// ---------------------------------------------------------------------------

/// What the renamed store's open leaves behind on the fixture estate.
#[derive(Debug, PartialEq, Eq)]
struct VectorState {
    rows: usize,
    generation: i64,
    new_version: i32,
    old_version: i32,
}

/// Build a SQLite estate that a pre-rename runtime left behind: the vector
/// tables at their current layout, one `vectors` row at generation 3, and
/// the ledger row under the OLD id. Then (optionally) run the capsule, apply
/// the renamed store's schema, and report the `vectors` row count, that
/// row's generation, and the ledger versions under the NEW and the OLD id.
fn sqlite_vector_state_after_wire(migrate_first: bool) -> VectorState {
    use locus_kit::drawer_store_sqlite::SqliteDrawerStore;
    use persistence_kit::TypedValue;
    use std::collections::BTreeMap;

    let pairs = STORAGE_LEDGER_KIT_ID_RENAMES;
    let dir = std::env::temp_dir().join(format!("glk-mig15-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).expect("temp dir");
    let path = dir.join("estate.sqlite");
    let store = Arc::new(
        SqliteDrawerStore::from_path(&path.to_string_lossy(), NOW, None, 5.0)
            .expect("SqliteDrawerStore::from_path"),
    );
    let storage: Arc<dyn Storage> = store.storage().expect("storage");

    // The current vector layout, recorded under the pre-rename id.
    let current = synapsekit::VectorStore::schema_declaration();
    let legacy = SchemaDeclaration {
        kit_id: pairs.vector_store.from.to_string(),
        ..current.clone()
    };
    storage.migrate(&legacy).expect("legacy vector schema");
    let mut row: BTreeMap<String, TypedValue> = BTreeMap::new();
    row.insert("id".into(), TypedValue::Uuid(uuid::Uuid::new_v4()));
    row.insert("item_id".into(), TypedValue::Text("item-1".into()));
    row.insert("vector_index".into(), TypedValue::Int(0));
    row.insert("model_id".into(), TypedValue::Text("model-1".into()));
    row.insert("model_version".into(), TypedValue::Text("1".into()));
    row.insert("kind".into(), TypedValue::Int(0));
    row.insert("dim".into(), TypedValue::Int(4));
    row.insert("payload".into(), TypedValue::Blob(vec![0, 1, 2, 3]));
    row.insert("scale".into(), TypedValue::Null);
    row.insert("filed_at".into(), TypedValue::Timestamp(NOW));
    row.insert("ext".into(), TypedValue::Null);
    row.insert("generation".into(), TypedValue::Int(3));
    storage.row_store().insert("vectors", row).expect("insert vector row");
    EstateFormatStore::new(Arc::clone(&storage))
        .stamp(EstateFormatVersion::V1_4, NOW)
        .expect("stamp v1_4");

    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(
            Arc::clone(&store) as Arc<dyn DrawerStore>,
            OwnerCredentials::new("mig15-sqlite-owner"),
            0,
            100,
        )
        .expect("EstateCoordinator::open");
    if migrate_first {
        coord
            .run_storage_ledger_kit_id_migration(&handle, NOW)
            .expect("capsule");
    }
    // The renamed store's open: its ladder applied under the new id.
    storage.migrate(&current).expect("current vector schema");
    let vectors = storage
        .row_store()
        .query("vectors", None, &[], None, None)
        .expect("query vectors");
    let generation = match vectors.first().and_then(|r| r.values.get("generation")) {
        Some(TypedValue::Int(v)) => *v,
        _ => -1,
    };
    VectorState {
        rows: vectors.len(),
        generation,
        new_version: storage
            .current_schema_version_for(pairs.vector_store.to)
            .expect("ledger version (new id)"),
        old_version: storage
            .current_schema_version_for(pairs.vector_store.from)
            .expect("ledger version (old id)"),
    }
}

/// The vector ladder is applied by `storage.migrate(&VectorStore::
/// schema_declaration())` at wire time. On a SQLite estate whose ledger
/// still says `VectorKit`, that call finds no `SynapseKit` row and replays
/// from version 0 against the v6 layout: the v5→v6 step rebuilds `vectors`
/// through a copy table that resets every row's `generation` to 0 (a
/// shadow-generation row is folded into the serving generation), and the
/// ledger gains a duplicate row under the old id. After the capsule the row
/// is found at v6 and nothing runs.
#[test]
fn renamed_store_opens_migrated_sqlite_estate_without_replaying_its_ladder() {
    let v6 = synapsekit::VectorStore::schema_declaration().version;
    let migrated = sqlite_vector_state_after_wire(true);
    assert_eq!(
        migrated,
        VectorState { rows: 1, generation: 3, new_version: v6, old_version: 0 },
        "after the capsule the renamed store finds its row and runs nothing"
    );

    // Control: the same estate wired without the capsule replays. This is
    // the failure the capsule exists to prevent, observed.
    let replayed = sqlite_vector_state_after_wire(false);
    assert_eq!(
        replayed,
        VectorState { rows: 1, generation: 0, new_version: v6, old_version: v6 },
        "without the capsule the ladder replays: generation folded to 0, duplicate ledger row"
    );
}

// ---------------------------------------------------------------------------
// §7 The pairs are frozen literals and the new ids are the stores' ids
// ---------------------------------------------------------------------------

#[test]
fn pairs_target_the_declared_store_ids() {
    let pairs = STORAGE_LEDGER_KIT_ID_RENAMES;
    // A later rename of the tier breaks this pin on purpose: it needs its
    // own capsule, not an edit to this one.
    assert_eq!(synapsekit::VectorStore::schema_declaration().kit_id, pairs.vector_store.to);
    assert_eq!(
        synapsekit::VectorRepresentationClaims::schema_declaration().kit_id,
        pairs.representation_claims.to
    );
}
