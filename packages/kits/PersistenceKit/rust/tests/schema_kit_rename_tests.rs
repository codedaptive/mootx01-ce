//! `Storage::rename_schema_kit` (SPEC I-7a) on the SQLite and in-memory
//! backends. Rust twin of the Swift `SchemaKitRenameTests` in
//! PersistenceKitSQLiteTests and PersistenceKitInMemoryTests.
//!
//! The SQLite replay probe is a migration step that inserts one row into a
//! probe table: one row means the ladder ran once, at the original open; a
//! second row means it replayed. That replay is the failure the rename
//! exists to prevent.

use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{
    BackendConfiguration, ColumnDeclaration, EstateConfiguration, Migration, SchemaDeclaration,
    SchemaKitRenameOutcome, SchemaOperation, SqliteStorage, Storage, TableDeclaration,
};
use uuid::Uuid;

fn sqlite_storage() -> SqliteStorage {
    let path = std::env::temp_dir().join(format!("pk_rename_{}.sqlite", Uuid::new_v4()));
    SqliteStorage::new(EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string_lossy().into_owned(),
            busy_timeout_secs: 5.0,
        },
    ))
    .expect("sqlite storage")
}

/// A three-version ladder under `kit_id`. The 2 → 3 step inserts one probe
/// row, so the probe table's row count is the number of times the ladder
/// has run on this file.
fn ladder(kit_id: &str) -> SchemaDeclaration {
    SchemaDeclaration::new(
        kit_id,
        3,
        vec![TableDeclaration::new(
            "rename_probe",
            vec![ColumnDeclaration::uuid("id"), ColumnDeclaration::text("note")],
            vec!["id".to_string()],
        )],
    )
    .with_migrations(vec![
        Migration { from_version: 0, to_version: 1, operations: vec![] },
        Migration { from_version: 1, to_version: 2, operations: vec![] },
        Migration {
            from_version: 2,
            to_version: 3,
            operations: vec![SchemaOperation::Custom {
                sqlite: Some(format!(
                    "INSERT INTO \"rename_probe\" (\"id\", \"note\") VALUES ('{}', 'ladder ran')",
                    Uuid::new_v4()
                )),
                postgresql: None,
            }],
        },
    ])
}

fn probe_rows(storage: &dyn Storage) -> usize {
    storage
        .row_store()
        .query("rename_probe", None, &[], None, None)
        .expect("query probe")
        .len()
}

#[test]
fn sqlite_row_moves_with_its_version_and_second_call_is_no_op() {
    let storage = sqlite_storage();
    storage.open(&ladder("OldKit")).expect("open");
    assert_eq!(storage.current_schema_version_for("OldKit").unwrap(), 3);
    assert_eq!(probe_rows(&storage), 1);

    let first = storage.rename_schema_kit("OldKit", "NewKit").expect("rename");
    assert_eq!(first, SchemaKitRenameOutcome::Renamed { version: 3 });
    assert_eq!(storage.current_schema_version_for("NewKit").unwrap(), 3);
    assert_eq!(storage.current_schema_version_for("OldKit").unwrap(), 0);

    let second = storage.rename_schema_kit("OldKit", "NewKit").expect("rename again");
    assert_eq!(second, SchemaKitRenameOutcome::NoRow);
    assert_eq!(storage.current_schema_version_for("NewKit").unwrap(), 3);
}

#[test]
fn sqlite_store_opened_under_the_new_id_does_not_replay_its_ladder() {
    let storage = sqlite_storage();
    storage.open(&ladder("OldKit")).expect("open");
    assert_eq!(probe_rows(&storage), 1);
    storage.rename_schema_kit("OldKit", "NewKit").expect("rename");

    // The renamed store finds its row and runs nothing.
    storage.open(&ladder("NewKit")).expect("open under new id");
    assert_eq!(probe_rows(&storage), 1);
    assert_eq!(storage.current_schema_version_for("NewKit").unwrap(), 3);

    // Control: an id with no row replays from version 0.
    storage.open(&ladder("UnrenamedKit")).expect("open under a third id");
    assert_eq!(probe_rows(&storage), 2);
}

#[test]
fn sqlite_both_ids_present_is_a_conflict_that_changes_nothing() {
    let storage = sqlite_storage();
    storage.open(&SchemaDeclaration::new("OldKit", 1, vec![])).expect("open old");
    storage.open(&SchemaDeclaration::new("NewKit", 2, vec![])).expect("open new");

    let outcome = storage.rename_schema_kit("OldKit", "NewKit").expect("rename");
    assert_eq!(
        outcome,
        SchemaKitRenameOutcome::Conflict { old_version: 1, new_version: 2 }
    );
    assert_eq!(storage.current_schema_version_for("OldKit").unwrap(), 1);
    assert_eq!(storage.current_schema_version_for("NewKit").unwrap(), 2);
}

#[test]
fn sqlite_other_rows_are_untouched() {
    let storage = sqlite_storage();
    storage.open(&SchemaDeclaration::new("OldKit", 4, vec![])).expect("open old");
    storage.open(&SchemaDeclaration::new("Bystander", 7, vec![])).expect("open bystander");
    storage.rename_schema_kit("OldKit", "NewKit").expect("rename");
    assert_eq!(storage.current_schema_version_for("Bystander").unwrap(), 7);
    assert_eq!(storage.current_schema_version_for("NewKit").unwrap(), 4);
}

#[test]
fn inmemory_entry_moves_with_its_version_and_second_call_is_no_op() {
    let storage = InMemoryStorage::with_estate(Uuid::new_v4());
    storage.open(&SchemaDeclaration::new("OldKit", 3, vec![])).expect("open");

    let first = storage.rename_schema_kit("OldKit", "NewKit").expect("rename");
    assert_eq!(first, SchemaKitRenameOutcome::Renamed { version: 3 });
    assert_eq!(storage.current_schema_version_for("NewKit").unwrap(), 3);
    assert_eq!(storage.current_schema_version_for("OldKit").unwrap(), 0);

    let second = storage.rename_schema_kit("OldKit", "NewKit").expect("rename again");
    assert_eq!(second, SchemaKitRenameOutcome::NoRow);
    assert_eq!(storage.current_schema_version_for("NewKit").unwrap(), 3);
}

#[test]
fn inmemory_both_ids_present_is_a_conflict_that_changes_nothing() {
    let storage = InMemoryStorage::with_estate(Uuid::new_v4());
    storage.open(&SchemaDeclaration::new("OldKit", 1, vec![])).expect("open old");
    storage.open(&SchemaDeclaration::new("NewKit", 2, vec![])).expect("open new");

    let outcome = storage.rename_schema_kit("OldKit", "NewKit").expect("rename");
    assert_eq!(
        outcome,
        SchemaKitRenameOutcome::Conflict { old_version: 1, new_version: 2 }
    );
    assert_eq!(storage.current_schema_version_for("OldKit").unwrap(), 1);
    assert_eq!(storage.current_schema_version_for("NewKit").unwrap(), 2);
}

#[test]
fn inmemory_other_entries_and_the_global_maximum_are_untouched() {
    let storage = InMemoryStorage::with_estate(Uuid::new_v4());
    storage.open(&SchemaDeclaration::new("OldKit", 4, vec![])).expect("open old");
    storage.open(&SchemaDeclaration::new("Bystander", 7, vec![])).expect("open bystander");
    storage.rename_schema_kit("OldKit", "NewKit").expect("rename");
    assert_eq!(storage.current_schema_version_for("Bystander").unwrap(), 7);
    assert_eq!(storage.current_schema_version_for("NewKit").unwrap(), 4);
    assert_eq!(storage.current_schema_version().unwrap(), 7);
}
