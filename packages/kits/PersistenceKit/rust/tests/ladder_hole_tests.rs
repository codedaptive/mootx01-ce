//! The runner's refusal for a stored version its ladder has no hop for, and
//! the repair surface for an estate stamped current while a hop was skipped.
//! Twin of Swift `LadderHoleTests`.

use persistence_kit::schema::{
    ColumnDeclaration, LadderColumn, Migration, SchemaDeclaration, SchemaOperation, TableDeclaration,
};
use persistence_kit::sqlite::SqliteStorage;
use persistence_kit::storage::{BackendConfiguration, EstateConfiguration};
use persistence_kit::{Storage, StorageError};
use uuid::Uuid;

struct TempDb {
    path: String,
}

impl TempDb {
    fn new() -> Self {
        let name = format!("ladder_hole_{}.db", Uuid::new_v4().simple());
        TempDb { path: std::env::temp_dir().join(name).to_string_lossy().into_owned() }
    }
}

impl Drop for TempDb {
    fn drop(&mut self) {
        for suffix in &["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{}", self.path, suffix));
        }
    }
}

fn open(path: &str) -> SqliteStorage {
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite { path: path.to_string(), busy_timeout_secs: 5.0 },
    );
    SqliteStorage::new(config).expect("sqlite storage")
}

fn things() -> TableDeclaration {
    TableDeclaration {
        name: "things".to_string(),
        columns: vec![ColumnDeclaration::text("id"), ColumnDeclaration::text("name")],
        primary_key: vec!["id".to_string()],
        unique_constraints: Vec::new(),
        generated_columns: Vec::new(),
        append_only: false,
        hashable: false,
    }
}

fn kit(version: i32, hops: Vec<Migration>) -> SchemaDeclaration {
    SchemaDeclaration::new("HoleKit", version, vec![things()]).with_migrations(hops)
}

fn add_column(name: &str) -> SchemaOperation {
    SchemaOperation::AddColumn { table: "things".to_string(), column: ColumnDeclaration::text(name).nullable() }
}

fn two_hops() -> Vec<Migration> {
    vec![
        Migration { from_version: 10, to_version: 19, operations: vec![add_column("a")] },
        Migration { from_version: 19, to_version: 20, operations: vec![add_column("b")] },
    ]
}

fn column(name: &str) -> LadderColumn {
    LadderColumn { table: "things".to_string(), column: name.to_string() }
}

#[test]
fn a_hole_is_a_nonzero_stored_version_inside_the_ladder_with_no_hop() {
    let ladder = kit(20, two_hops());
    assert!(!ladder.ladder_has_hole(0), "fresh is never a hole");
    assert!(!ladder.ladder_has_hole(10));
    assert!(!ladder.ladder_has_hole(19));
    assert!(!ladder.ladder_has_hole(20), "current is never a hole");
    assert!(!ladder.ladder_has_hole(21), "newer than declared is not a hole");
    for inside in 11..=18 {
        assert!(ladder.ladder_has_hole(inside), "{inside} has no hop");
    }
    assert!(!ladder.ladder_has_hole(3), "below every hop is the base-CREATE convention");
    assert!(!kit(4, Vec::new()).ladder_has_hole(2), "no ladder, no hole");
}

#[test]
fn ladder_columns_are_every_add_column_from_the_hop_up_once_each() {
    let ladder = kit(
        20,
        vec![
            Migration { from_version: 10, to_version: 19, operations: vec![add_column("a"), add_column("a")] },
            Migration {
                from_version: 19,
                to_version: 20,
                operations: vec![
                    add_column("b"),
                    SchemaOperation::DropColumn { table: "things".to_string(), column_name: "z".to_string() },
                ],
            },
        ],
    );
    assert_eq!(ladder.ladder_columns(10), vec![column("a"), column("b")]);
    assert_eq!(ladder.ladder_columns(19), vec![column("b")]);
}

#[test]
fn opening_at_a_hole_is_refused_and_the_ledger_is_left_where_it_was() {
    let db = TempDb::new();
    {
        // Stamp 12 with a ladder-less declaration: no hop, no hole.
        let stamp = open(&db.path);
        stamp.open(&kit(12, Vec::new())).expect("stamp 12");
        assert_eq!(stamp.current_schema_version_for("HoleKit").unwrap(), 12);
        stamp.close().unwrap();
    }
    let storage = open(&db.path);
    let ladder = kit(20, two_hops());
    match storage.open(&ladder) {
        Err(StorageError::MigrationFailed { version, .. }) => assert_eq!(version, 12),
        other => panic!("expected a ladder-hole refusal, got {other:?}"),
    }
    // Nothing moved: the ledger still says 12 and the hop's column was never
    // added — so the estate cannot read as current without it.
    assert_eq!(storage.current_schema_version_for("HoleKit").unwrap(), 12);
    assert_eq!(storage.missing_ladder_columns(&ladder, 10).unwrap().len(), 2);
}

#[test]
fn a_stored_version_below_every_hop_still_opens_by_the_base_create_convention() {
    let db = TempDb::new();
    {
        let stamp = open(&db.path);
        stamp.open(&kit(1, Vec::new())).expect("stamp 1");
        stamp.close().unwrap();
    }
    let storage = open(&db.path);
    let ladder = kit(3, vec![Migration { from_version: 2, to_version: 3, operations: vec![add_column("late")] }]);
    storage.open(&ladder).expect("opens");
    assert_eq!(storage.current_schema_version_for("HoleKit").unwrap(), 3);
    assert!(storage.missing_ladder_columns(&ladder, 2).unwrap().is_empty());
}

#[test]
fn an_estate_stamped_current_without_its_objects_is_repaired_by_replaying_the_ladder() {
    let db = TempDb::new();
    let ladder = kit(20, two_hops());
    {
        // The pre-fix runner's outcome: ledger 20, `things` without a or b.
        let stamp = open(&db.path);
        stamp.open(&kit(20, Vec::new())).expect("stamp 20");
        stamp.close().unwrap();
    }
    let storage = open(&db.path);
    storage.open(&ladder).expect("current: nothing to migrate");
    assert_eq!(storage.missing_ladder_columns(&ladder, 10).unwrap(), vec![column("a"), column("b")]);
    storage.replay_ladder(&ladder, 10).expect("replay");
    assert!(storage.missing_ladder_columns(&ladder, 10).unwrap().is_empty());
    assert_eq!(storage.current_schema_version_for("HoleKit").unwrap(), 20, "the ledger is not touched by a replay");
    // A second replay on the healthy estate is a no-op.
    storage.replay_ladder(&ladder, 10).expect("replay again");
    assert!(storage.missing_ladder_columns(&ladder, 10).unwrap().is_empty());
}
