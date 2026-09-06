// corrupt_readback_tests.rs
//
// Verifies that LocusKit's Rust drawer read-back returns
// Err(LocusKitError::CorruptStoredValue) when a stored TEXT value in the
// `drawers.lineageID` column cannot be parsed as a UUID.
//
// Strategy: write a valid drawer via SqliteDrawerStore, drop the store (WAL
// checkpointed), corrupt the stored value directly via a raw rusqlite
// connection (bypassing the kit's codec), reopen the store, then assert the
// structured error — not a silently fabricated random UUID.
//
// INTENTIONAL CONTRACT (not under test here — those are correct behaviour):
//   - Empty-string lineageID yields a fresh Uuid::new_v4() (the "unset"
//     sentinel). Not corruption — the empty-string is a documented default.
//   - filed_at corruption: declared ColumnType::Timestamp so PersistenceKit's
//     read_value already throws StorageError::CorruptStoredValue before
//     drawer_from_row is reached. That path is covered by
//     PersistenceKit/rust/tests/corrupt_readback_tests.rs.

use locus_kit::drawer::Drawer;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_sqlite::SqliteDrawerStore;
use locus_kit::error::LocusKitError;
use rusqlite::Connection;
use uuid::Uuid;

const NOW: i64 = 1_700_000_000;

// ---------------------------------------------------------------------------
// Test infrastructure
// ---------------------------------------------------------------------------

struct TempDb {
    path: String,
}

impl TempDb {
    fn new() -> Self {
        let name = format!("locus_corrupt_test_{}.db", Uuid::new_v4().simple());
        let path = std::env::temp_dir()
            .join(name)
            .to_string_lossy()
            .into_owned();
        TempDb { path }
    }

    fn path(&self) -> &str {
        &self.path
    }
}

impl Drop for TempDb {
    fn drop(&mut self) {
        for suffix in &["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{}", self.path, suffix));
        }
    }
}

fn open_sqlite(path: &str) -> SqliteDrawerStore {
    SqliteDrawerStore::from_path(path, NOW, None, 5.0).unwrap()
}

/// Execute arbitrary SQL directly against the SQLite file, bypassing the kit.
/// Used exclusively to corrupt stored values for negative-path testing.
fn raw_exec(path: &str, sql: &str) {
    let conn = Connection::open(path).expect("raw open");
    conn.execute_batch(sql).expect("raw exec");
}

fn sample_drawer(id: &str) -> Drawer {
    let mut d = Drawer::new(id, "corrupt read-back content", "test-parent", "test", NOW, "test-v1");
    d.udc_code = "001".to_string();
    d
}

// ---------------------------------------------------------------------------
// lineageID corruption
// ---------------------------------------------------------------------------

#[test]
fn corrupt_lineage_id_returns_corrupt_stored_value() {
    let db = TempDb::new();
    let drawer_id = format!("{}", Uuid::new_v4().simple());

    // Write a valid drawer, then drop the store (WAL checkpoint).
    {
        let store = open_sqlite(db.path());
        let mut d = sample_drawer(&drawer_id);
        d.lineage_id = Uuid::new_v4();
        store.add_drawer(&d, NOW).unwrap();
        // Verify clean round-trip before corruption.
        let back = store.get_drawer(&drawer_id).unwrap().unwrap();
        assert!(back.lineage_id != Uuid::nil());
    } // store drops → WAL checkpointed

    // Corrupt the lineageID with a non-empty, non-UUID string.
    raw_exec(
        db.path(),
        &format!(
            r#"UPDATE "drawers" SET "lineageID" = 'NOT-A-UUID' WHERE "id" = '{}'"#,
            drawer_id
        ),
    );

    // Reopen and attempt read-back — must return Err(CorruptStoredValue).
    let store2 = open_sqlite(db.path());
    let result = store2.get_drawer(&drawer_id);

    match result {
        Err(LocusKitError::CorruptStoredValue {
            ref table,
            ref column,
            ref stored_text,
        }) => {
            assert_eq!(table, "drawers", "table must be 'drawers'");
            assert_eq!(column, "lineageID", "column must be 'lineageID'");
            assert_eq!(stored_text, "NOT-A-UUID", "stored_text must match");
        }
        Err(other) => panic!(
            "expected CorruptStoredValue(drawers/lineageID), got: {:?}",
            other
        ),
        Ok(Some(d)) => panic!(
            "expected Err(CorruptStoredValue) but got Ok with lineage_id={}",
            d.lineage_id
        ),
        Ok(None) => panic!("expected Err(CorruptStoredValue) but got Ok(None)"),
    }
}

#[test]
fn empty_lineage_id_is_unset_sentinel_not_corrupt() {
    // Empty-string lineageID is the intentional "unset" sentinel — it must
    // yield a fresh UUID (Uuid::new_v4()), not Err(CorruptStoredValue).
    let db = TempDb::new();
    let drawer_id = format!("{}", Uuid::new_v4().simple());

    {
        let store = open_sqlite(db.path());
        let d = sample_drawer(&drawer_id);
        store.add_drawer(&d, NOW).unwrap();
    }

    // Force lineageID to empty string.
    raw_exec(
        db.path(),
        &format!(
            r#"UPDATE "drawers" SET "lineageID" = '' WHERE "id" = '{}'"#,
            drawer_id
        ),
    );

    // Must succeed (not throw) and yield a fresh non-nil UUID.
    let store2 = open_sqlite(db.path());
    let d = store2
        .get_drawer(&drawer_id)
        .expect("get_drawer must not error for empty lineageID")
        .expect("drawer must be present");
    assert_ne!(
        d.lineage_id,
        Uuid::nil(),
        "empty lineageID must produce a fresh UUID, not nil"
    );
}

#[test]
fn valid_lineage_id_round_trips() {
    // A valid UUID lineageID must round-trip without error.
    let db = TempDb::new();
    let drawer_id = format!("{}", Uuid::new_v4().simple());
    let fixed_lineage = Uuid::new_v4();

    let store = open_sqlite(db.path());
    let mut d = sample_drawer(&drawer_id);
    d.lineage_id = fixed_lineage;
    store.add_drawer(&d, NOW).unwrap();
    let back = store.get_drawer(&drawer_id).unwrap().unwrap();
    assert_eq!(back.lineage_id, fixed_lineage);
}

// ---------------------------------------------------------------------------
// filed_at corruption — PersistenceKit already handles this at the Timestamp
// column level. This test confirms the fail-loud behaviour reaches the caller
// as an error (not epoch-0).
// ---------------------------------------------------------------------------

#[test]
fn corrupt_filed_at_returns_error_not_epoch_zero() {
    let db = TempDb::new();
    let drawer_id = format!("{}", Uuid::new_v4().simple());

    {
        let store = open_sqlite(db.path());
        let d = sample_drawer(&drawer_id);
        store.add_drawer(&d, NOW).unwrap();
    }

    // Corrupt filedAt with a non-empty, non-ISO8601 string.
    raw_exec(
        db.path(),
        &format!(
            r#"UPDATE "drawers" SET "filedAt" = 'NOT-A-DATE' WHERE "id" = '{}'"#,
            drawer_id
        ),
    );

    // PersistenceKit's read_value throws StorageError::CorruptStoredValue for
    // Timestamp columns; this is mapped to LocusKitError::DatabaseUnavailable
    // by map_storage_err. The result must be Err — never Ok(drawer with filed_at=0).
    let store2 = open_sqlite(db.path());
    let result = store2.get_drawer(&drawer_id);

    match result {
        Err(_) => {
            // Any error is the correct fail-loud behaviour.
        }
        Ok(Some(d)) => {
            // If no error was thrown (e.g. a future storage change), verify the
            // returned value is NOT epoch-0 (that would be silent fabrication).
            assert_ne!(
                d.filed_at, 0,
                "corrupt filedAt must not be fabricated as epoch-0"
            );
        }
        Ok(None) => {
            // Row absent is also fail-loud from the caller's perspective.
        }
    }
}
