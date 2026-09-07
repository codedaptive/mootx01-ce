//! Verification fixture for the GLK 1.5 → 1.6 index-composition column-drop
//! migration. Rust twin of Swift `IndexCompositionColumnDropMigrationTests.swift`.
//!
//! Tests:
//!   1. V1_5-stamped estate whose ledger records CorpusKitIndexState at v3
//!      and whose checkpoint row carries the column: after the capsule the
//!      column is gone, the row's other fields are intact, the ledger reads
//!      v4 and the estate is stamped V1_6.
//!   2. The same on an estate with NO CorpusKitIndexState ledger row (the
//!      composite-declaration shape every provisioned estate has): the
//!      ladder replays from version 0 and still drops the column.
//!   3. Idempotence: a second run leaves the ledger at v4 and the stamp at
//!      V1_6, and the row survives.
//!   4. StorageUnavailable: an unregistered handle returns the error variant.
//!   5. On a SQLite estate the column is physically gone (PRAGMA table_info)
//!      and the row survives; a second ladder replay does not error.
//!   6. V1_4-stamped estate: the chain runs the 1.4→1.5 capsule, this one and
//!      the 1.6→1.7 capsule, ending at CURRENT (gated on feature =
//!      "migration-v1-4-to-v1-5").

use std::collections::BTreeMap;
use std::sync::Arc;

use corpus_kit::index_state_store::CorpusIndexStateStore;
use genius_locus_kit::estate_format::{EstateFormatStore, EstateFormatVersion};
use genius_locus_kit::EstateCoordinator;
use genius_locus_kit_migrations::{
    IndexCompositionColumnDropMigrationError, IndexCompositionColumnDropMigrationExt,
    IndexCompositionColumnDropMigrationReport,
};
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::OwnerCredentials;
use persistence_kit::{
    ColumnDeclaration, SchemaDeclaration, Storage, StorageRow, TableDeclaration, TypedValue,
};

const NOW: i64 = 1_756_000_000_000; // millis
const POLICY: &str = "lex=original;dense=original";

fn checkpoint_kit_id() -> String {
    CorpusIndexStateStore::schema_declaration().kit_id
}

/// The v3 checkpoint layout: the current declaration's tables plus the
/// retired column, recorded under `kit_id` at version 3 with no migrations,
/// exactly what a populated estate carries before the capsule runs.
fn legacy_checkpoint_declaration(kit_id: &str) -> SchemaDeclaration {
    let current = CorpusIndexStateStore::schema_declaration();
    let tables: Vec<TableDeclaration> = current
        .tables
        .iter()
        .map(|table| {
            if table.name != "corpus_index_state" {
                return table.clone();
            }
            let mut columns = table.columns.clone();
            columns.push(
                ColumnDeclaration::text("composition_policy")
                    .with_default(TypedValue::Text(String::new())),
            );
            TableDeclaration::new(&table.name, columns, table.primary_key.clone())
        })
        .collect();
    SchemaDeclaration::new(kit_id, 3, tables)
}

/// One checkpoint row carrying a policy id in the retired column.
fn insert_legacy_checkpoint(storage: &Arc<dyn Storage>) {
    let mut row: BTreeMap<String, TypedValue> = BTreeMap::new();
    row.insert("content_id".into(), TypedValue::Text("content-1".into()));
    row.insert("revision".into(), TypedValue::Int(2));
    row.insert("digest".into(), TypedValue::Text("digest-1".into()));
    row.insert("index_version".into(), TypedValue::Int(7));
    row.insert("applied_cursor".into(), TypedValue::Null);
    row.insert("updated_at".into(), TypedValue::Timestamp(NOW));
    row.insert("operational_bitmap".into(), TypedValue::Bitmap(3));
    row.insert("composition_policy".into(), TypedValue::Text(POLICY.into()));
    storage
        .row_store()
        .insert("corpus_index_state", row)
        .expect("insert legacy checkpoint row");
}

/// The one checkpoint row, as the row store reads it back.
fn checkpoint_row(storage: &Arc<dyn Storage>) -> StorageRow {
    let rows = storage
        .row_store()
        .query("corpus_index_state", None, &[], None, None)
        .expect("query corpus_index_state");
    assert_eq!(rows.len(), 1, "exactly one checkpoint row");
    rows.into_iter().next().unwrap()
}

/// Prepare `storage` as a populated estate: the v3 checkpoint table with one
/// row, recorded under CorpusKitIndexState when `with_ledger_row`, or under a
/// composite-style id otherwise (no CorpusKitIndexState row).
fn seed_checkpoint_table(storage: &Arc<dyn Storage>, with_ledger_row: bool) {
    let kit_id = if with_ledger_row {
        checkpoint_kit_id()
    } else {
        "CompositeFixture".to_string()
    };
    storage
        .migrate(&legacy_checkpoint_declaration(&kit_id))
        .expect("legacy checkpoint schema");
    insert_legacy_checkpoint(storage);
}

/// Open an in-memory estate stamped at `stamp_version`, carrying the v3
/// checkpoint table and one row.
fn make_estate(
    stamp_version: EstateFormatVersion,
    with_ledger_row: bool,
) -> (
    EstateCoordinator,
    genius_locus_kit::handle::EstateHandle,
    Arc<dyn Storage>,
) {
    let store = Arc::new(InMemoryDrawerStore::new(NOW, None).expect("InMemoryDrawerStore::new"));
    let storage: Arc<dyn Storage> = store
        .storage()
        .expect("InMemoryDrawerStore exposes storage");
    seed_checkpoint_table(&storage, with_ledger_row);
    EstateFormatStore::new(Arc::clone(&storage))
        .stamp(stamp_version, NOW)
        .expect("stamp estate format");
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(
            Arc::clone(&store) as Arc<dyn DrawerStore>,
            OwnerCredentials::new("mig16-test-owner"),
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

fn ledger_version(storage: &Arc<dyn Storage>) -> i32 {
    storage
        .current_schema_version_for(&checkpoint_kit_id())
        .expect("read ledger version")
}

fn assert_row_intact_without_column(row: &StorageRow) {
    assert!(row.get("composition_policy").is_none(), "column must be gone: {row:?}");
    assert_eq!(row.get("content_id"), Some(&TypedValue::Text("content-1".into())));
    assert_eq!(row.get("revision"), Some(&TypedValue::Int(2)));
    assert_eq!(row.get("digest"), Some(&TypedValue::Text("digest-1".into())));
    assert_eq!(row.get("index_version"), Some(&TypedValue::Int(7)));
    assert_eq!(row.get("operational_bitmap"), Some(&TypedValue::Bitmap(3)));
}

// ---------------------------------------------------------------------------
// §1 Ledger at v3: the column goes, the row stays, V1_6 stamped
// ---------------------------------------------------------------------------

#[test]
fn v1_5_estate_with_ledger_row_drops_the_column() {
    let (coord, handle, storage) = make_estate(EstateFormatVersion::V1_5, true);
    assert_eq!(ledger_version(&storage), 3);
    assert_eq!(
        checkpoint_row(&storage).get("composition_policy"),
        Some(&TypedValue::Text(POLICY.into()))
    );

    let report = coord
        .run_index_composition_column_drop_migration(&handle, NOW)
        .expect("migration must succeed on a v1_5 estate");

    let expected_version = CorpusIndexStateStore::schema_declaration().version;
    assert_eq!(
        report,
        IndexCompositionColumnDropMigrationReport {
            checkpoint_schema_version: expected_version,
            format: EstateFormatVersion::V1_6,
        }
    );
    // The capsule alone stamps V1_6; the chain's 1.6 → 1.7 step stamps CURRENT.
    assert_eq!(read_stamp(&storage), EstateFormatVersion::V1_6);
    assert_eq!(ledger_version(&storage), expected_version);
    assert_row_intact_without_column(&checkpoint_row(&storage));
}

// ---------------------------------------------------------------------------
// §2 No ledger row (composite shape): the ladder replays from 0
// ---------------------------------------------------------------------------

#[test]
fn v1_5_estate_without_ledger_row_drops_the_column() {
    let (coord, handle, storage) = make_estate(EstateFormatVersion::V1_5, false);
    assert_eq!(ledger_version(&storage), 0);

    coord
        .run_index_composition_column_drop_migration(&handle, NOW)
        .expect("migration must succeed without a checkpoint ledger row");

    assert_eq!(read_stamp(&storage), EstateFormatVersion::V1_6);
    assert_eq!(
        ledger_version(&storage),
        CorpusIndexStateStore::schema_declaration().version
    );
    assert_row_intact_without_column(&checkpoint_row(&storage));
}

// ---------------------------------------------------------------------------
// §3 Idempotence
// ---------------------------------------------------------------------------

#[test]
fn capsule_is_idempotent() {
    let (coord, handle, storage) = make_estate(EstateFormatVersion::V1_5, true);
    let first = coord
        .run_index_composition_column_drop_migration(&handle, NOW)
        .expect("first run");
    let second = coord
        .run_index_composition_column_drop_migration(&handle, NOW)
        .expect("second run");
    assert_eq!(first, second);
    assert_eq!(read_stamp(&storage), EstateFormatVersion::V1_6);
    assert_row_intact_without_column(&checkpoint_row(&storage));
}

// ---------------------------------------------------------------------------
// §4 StorageUnavailable
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
    let result = coord.run_index_composition_column_drop_migration(&unregistered_handle, NOW);
    assert!(
        matches!(
            result,
            Err(IndexCompositionColumnDropMigrationError::StorageUnavailable { .. })
        ),
        "expected StorageUnavailable, got {result:?}"
    );
}

// ---------------------------------------------------------------------------
// §5 SQLite: the column is physically gone and the row survives
// ---------------------------------------------------------------------------

#[test]
fn sqlite_estate_loses_the_column_and_keeps_the_row() {
    use locus_kit::drawer_store_sqlite::SqliteDrawerStore;

    let dir = std::env::temp_dir().join(format!("glk-mig16-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).expect("temp dir");
    let path = dir.join("estate.sqlite");
    let store = Arc::new(
        SqliteDrawerStore::from_path(&path.to_string_lossy(), NOW, None, 5.0)
            .expect("SqliteDrawerStore::from_path"),
    );
    let storage: Arc<dyn Storage> = store.storage().expect("storage");
    seed_checkpoint_table(&storage, false);
    EstateFormatStore::new(Arc::clone(&storage))
        .stamp(EstateFormatVersion::V1_5, NOW)
        .expect("stamp");
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(
            Arc::clone(&store) as Arc<dyn DrawerStore>,
            OwnerCredentials::new("mig16-test-owner"),
            0,
            100,
        )
        .expect("EstateCoordinator::open");

    let columns_before = sqlite_columns(&path);
    assert!(columns_before.iter().any(|c| c == "composition_policy"));

    coord
        .run_index_composition_column_drop_migration(&handle, NOW)
        .expect("migration must succeed on a SQLite estate");

    let columns_after = sqlite_columns(&path);
    assert!(
        !columns_after.iter().any(|c| c == "composition_policy"),
        "column must be dropped: {columns_after:?}"
    );
    assert_row_intact_without_column(&checkpoint_row(&storage));
    assert_eq!(read_stamp(&storage), EstateFormatVersion::V1_6);

    // A second replay of the ladder is a no-op: DropColumn on an absent
    // column does not error (the AddColumn rule in reverse).
    storage
        .migrate(&CorpusIndexStateStore::schema_declaration())
        .expect("second ladder replay");
    coord
        .run_index_composition_column_drop_migration(&handle, NOW)
        .expect("second capsule run");
    assert_row_intact_without_column(&checkpoint_row(&storage));
}

/// The column names of corpus_index_state, read through a separate
/// connection so the assertion does not depend on the kit's own row reads.
fn sqlite_columns(path: &std::path::Path) -> Vec<String> {
    let conn = rusqlite::Connection::open(path).expect("open sqlite");
    let mut stmt = conn
        .prepare("PRAGMA table_info(\"corpus_index_state\")")
        .expect("pragma");
    let names = stmt
        .query_map([], |row| row.get::<_, String>(1))
        .expect("query")
        .collect::<Result<Vec<_>, _>>()
        .expect("collect");
    names
}

// ---------------------------------------------------------------------------
// §6 Chain from V1_4 ends at CURRENT (only when the 1.4→1.5 capsule is compiled)
// ---------------------------------------------------------------------------

#[cfg(feature = "migration-v1-4-to-v1-5")]
#[test]
fn v1_4_estate_runs_both_capsules_to_current() {
    use corpus_kit_providers::default_ensemble;
    use genius_locus_kit_migrations::MigrationChainExt;

    let (mut coord, handle, storage) = make_estate(EstateFormatVersion::V1_4, true);
    coord
        .run_migration_chain(&handle, NOW, default_ensemble())
        .expect("chain from V1_4");
    assert_eq!(read_stamp(&storage), EstateFormatVersion::V1_7);
    assert_eq!(read_stamp(&storage), EstateFormatVersion::CURRENT);
    assert_row_intact_without_column(&checkpoint_row(&storage));
}
