// Runs the backend-agnostic conformance suite against the SQLite backend.
// Each factory() call opens a fresh temp-file database.

mod conformance;

use conformance::{run_all, vector_fixtures, Factory};
use persistence_kit::{BackendConfiguration, EstateConfiguration, SqliteStorage, Storage};
use rusqlite::Connection;
use uuid::Uuid;

#[test]
fn sqlite_conformance() {
    let factory: Factory = Box::new(|| {
        let path = std::env::temp_dir().join(format!("pk_conf_{}.sqlite", Uuid::new_v4()));
        let config = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: path.to_string_lossy().into_owned(),
                busy_timeout_secs: 5.0,
            },
        );
        Box::new(SqliteStorage::new(config).expect("open sqlite storage")) as Box<dyn Storage>
    });
    run_all("SQLite", &factory);
    vector_fixtures("SQLite", &factory);
}

#[test]
fn migration_ledger_writes_canonical_text_and_normalizes_legacy_timestamps() {
    let path = std::env::temp_dir().join(format!("pk_migration_ledger_{}.sqlite", Uuid::new_v4()));
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string_lossy().into_owned(),
            busy_timeout_secs: 5.0,
        },
    );
    let schema = persistence_kit::SchemaDeclaration::new("TestKit", 1, vec![]);

    let writer = SqliteStorage::new(config.clone()).expect("writer storage");
    writer.open(&schema).expect("writer schema open");
    drop(writer);
    let conn = Connection::open(&path).expect("raw writer read");
    let written: (String, String) = conn
        .query_row(
            "SELECT typeof(\"applied_at\"), \"applied_at\" FROM \"_storagekit_migrations\" WHERE \"kit_id\" = 'TestKit'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("written ledger row");
    assert!(
        written.0 == "text"
            && written.1.contains('T')
            && written.1.ends_with('Z')
            && written.1 != "1970-01-01T00:00:00.000Z",
        "new migration rows must be current canonical ISO-8601 TEXT; got {:?}",
        written
    );
    conn.execute_batch(
        "DROP TABLE \"_storagekit_migrations\";
         CREATE TABLE \"_storagekit_migrations\" (
             \"kit_id\" TEXT NOT NULL,
             \"version\" INTEGER NOT NULL,
             \"applied_at\" INTEGER NOT NULL,
             PRIMARY KEY (\"kit_id\")
         );
         INSERT INTO \"_storagekit_migrations\" (\"kit_id\", \"version\", \"applied_at\")
         VALUES ('TestKit', 1, 1700000123456);",
    )
    .expect("seed integer legacy migration table");
    drop(conn);

    let integer_legacy = SqliteStorage::new(config.clone()).expect("integer legacy storage");
    assert_eq!(
        integer_legacy.current_schema_version_for("TestKit").expect("legacy version read"),
        1,
        "version reader must accept a legacy INTEGER applied_at value"
    );
    integer_legacy.open(&schema).expect("normalize integer legacy timestamp");
    drop(integer_legacy);
    let conn = Connection::open(&path).expect("read normalized integer");
    let normalized_integer: (String, String) = conn
        .query_row(
            "SELECT typeof(\"applied_at\"), \"applied_at\" FROM \"_storagekit_migrations\" WHERE \"kit_id\" = 'TestKit'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("normalized integer ledger row");
    assert_eq!(
        normalized_integer,
        ("text".to_string(), "2023-11-14T22:15:23.456Z".to_string()),
        "schema application must normalize the legacy INTEGER timestamp once"
    );
    conn.execute(
        "UPDATE \"_storagekit_migrations\" SET \"applied_at\" = '1970-01-01T00:00:00.000Z' WHERE \"kit_id\" = 'TestKit'",
        [],
    )
    .expect("seed Rust epoch sentinel");
    drop(conn);

    let sentinel_legacy = SqliteStorage::new(config.clone()).expect("sentinel legacy storage");
    sentinel_legacy.open(&schema).expect("normalize sentinel timestamp");
    drop(sentinel_legacy);
    let conn = Connection::open(&path).expect("read normalized sentinel");
    let normalized_sentinel: (String, String) = conn
        .query_row(
            "SELECT typeof(\"applied_at\"), \"applied_at\" FROM \"_storagekit_migrations\" WHERE \"kit_id\" = 'TestKit'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("normalized sentinel ledger row");
    assert!(
        normalized_sentinel.0 == "text" && normalized_sentinel.1 != "1970-01-01T00:00:00.000Z",
        "the Rust epoch sentinel must be replaced once; got {:?}",
        normalized_sentinel
    );
    conn.execute(
        "UPDATE \"_storagekit_migrations\" SET \"applied_at\" = '2024-02-03T04:05:06.789Z' WHERE \"kit_id\" = 'TestKit'",
        [],
    )
    .expect("seed canonical timestamp");
    drop(conn);

    let canonical = SqliteStorage::new(config).expect("canonical storage");
    canonical.open(&schema).expect("reopen canonical timestamp");
    drop(canonical);
    let conn = Connection::open(&path).expect("read canonical timestamp");
    let preserved: String = conn
        .query_row(
            "SELECT \"applied_at\" FROM \"_storagekit_migrations\" WHERE \"kit_id\" = 'TestKit'",
            [],
            |row| row.get(0),
        )
        .expect("preserved canonical ledger row");
    assert_eq!(preserved, "2024-02-03T04:05:06.789Z");
    drop(conn);
    std::fs::remove_file(path).expect("remove migration-ledger fixture");
}

// ─────────────────────────────────────────────────────────────────────
// Audit-log reason round-trip tests for the SQLite backend.
// These tests verify that the nullable `reason` column persists and
// reads back through audit_log().append(…) → decode_audit(…) with fidelity.
// ─────────────────────────────────────────────────────────────────────

use persistence_kit::{AuditEvent, Storage as _};
use substrate_types::hlc::HLC;

fn make_sqlite_audit_storage() -> SqliteStorage {
    let path = std::env::temp_dir()
        .join(format!("pk_audit_reason_{}.sqlite", Uuid::new_v4()));
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string_lossy().into_owned(),
            busy_timeout_secs: 5.0,
        },
    );
    let storage = SqliteStorage::new(config).expect("open sqlite storage");
    let schema = persistence_kit::SchemaDeclaration::new("reason-test", 1, vec![]);
    storage.open(&schema).expect("open schema");
    storage
}

#[test]
fn sqlite_audit_reason_some_round_trips() {
    // A supplied reason must survive the INSERT → decode_audit path unchanged.
    let storage = make_sqlite_audit_storage();
    let log = storage.audit_log();
    let event = AuditEvent {
        event_id: Uuid::new_v4(),
        estate_uuid: Uuid::new_v4(),
        row_id: Uuid::new_v4(),
        hlc: HLC { physical_time: 1_000_000, logical_count: 0, node_id: 1 },
        verb: "expunge".into(),
        before_adjective: None,
        before_operational: None,
        before_provenance: None,
        after_adjective: 1,
        after_operational: 2,
        after_provenance: 3,
        before_lattice_anchor: None,
        after_lattice_anchor: 0,
        before_lattice_qid: None,
        after_lattice_qid: 0,
        actor: "test-actor".into(),
        reason: Some("GDPR erasure request #42".into()),
    };
    log.append(event).unwrap();
    let events = log.iterate(None, None, 10).unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(
        events[0].reason.as_deref(),
        Some("GDPR erasure request #42"),
        "reason should round-trip through SQLite audit storage"
    );
}

#[test]
fn sqlite_audit_reason_none_round_trips() {
    // A None reason must be stored as NULL and read back as None.
    let storage = make_sqlite_audit_storage();
    let log = storage.audit_log();
    let event = AuditEvent {
        event_id: Uuid::new_v4(),
        estate_uuid: Uuid::new_v4(),
        row_id: Uuid::new_v4(),
        hlc: HLC { physical_time: 2_000_000, logical_count: 0, node_id: 1 },
        verb: "mutate".into(),
        before_adjective: None,
        before_operational: None,
        before_provenance: None,
        after_adjective: 4,
        after_operational: 5,
        after_provenance: 6,
        before_lattice_anchor: None,
        after_lattice_anchor: 0,
        before_lattice_qid: None,
        after_lattice_qid: 0,
        actor: "test-actor".into(),
        reason: None,
    };
    log.append(event).unwrap();
    let events = log.iterate(None, None, 10).unwrap();
    assert_eq!(events.len(), 1);
    assert!(
        events[0].reason.is_none(),
        "reason should be None when not supplied; got {:?}",
        events[0].reason
    );
}

// ─────────────────────────────────────────────────────────────────────
// StorageIntrospection tests for the SQLite backend.
// ─────────────────────────────────────────────────────────────────────

use persistence_kit::{
    ColumnDeclaration, SchemaDeclaration, StorageIntrospection, TableDeclaration,
};

fn make_sqlite_introspect() -> SqliteStorage {
    let path = std::env::temp_dir()
        .join(format!("pk_introspect_{}.sqlite", Uuid::new_v4()));
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string_lossy().into_owned(),
            busy_timeout_secs: 5.0,
        },
    );
    let storage = SqliteStorage::new(config).expect("open sqlite storage");
    let schema = SchemaDeclaration::new(
        "introspect-test",
        1,
        vec![TableDeclaration::new(
            "items",
            vec![
                ColumnDeclaration::uuid("id"),
                ColumnDeclaration::text("label"),
            ],
            vec!["id".into()],
        )],
    );
    storage.open(&schema).expect("open schema");
    storage
}

#[test]
fn sqlite_introspection_logical_size_non_negative() {
    let storage = make_sqlite_introspect();
    let stats = storage.stats(0).unwrap();
    assert!(stats.logical_size_bytes >= 0, "logicalSizeBytes must be non-negative");
}

#[test]
fn sqlite_introspection_page_size_is_power_of_two() {
    // SQLite page sizes are always a power of two in [512, 65536].
    let storage = make_sqlite_introspect();
    let stats = storage.stats(0).unwrap();
    let ps = stats.page_size.expect("SQLite backend must supply page_size");
    assert!(ps > 0, "page_size must be positive");
    assert_eq!(ps & (ps - 1), 0, "page_size must be a power of two");
}

#[test]
fn sqlite_introspection_page_count_positive() {
    let storage = make_sqlite_introspect();
    let stats = storage.stats(0).unwrap();
    let pc = stats.page_count.expect("SQLite backend must supply page_count");
    assert!(pc > 0, "page_count must be positive after open");
}

#[test]
fn sqlite_introspection_size_equals_page_count_times_page_size() {
    // logical_size_bytes = page_count * page_size.
    let storage = make_sqlite_introspect();
    let stats = storage.stats(0).unwrap();
    let ps = stats.page_size.expect("page_size") as i64;
    let pc = stats.page_count.expect("page_count") as i64;
    assert_eq!(
        stats.logical_size_bytes,
        pc * ps,
        "logical_size_bytes must equal page_count * page_size"
    );
}

#[test]
fn sqlite_introspection_freelist_page_count_non_negative() {
    let storage = make_sqlite_introspect();
    let stats = storage.stats(0).unwrap();
    let fl = stats.freelist_page_count.expect("freelist_page_count");
    assert!(fl >= 0, "freelist_page_count must be non-negative");
}

#[test]
fn sqlite_introspection_wal_frame_count_non_negative() {
    // WAL mode is set at open; wal_frame_count must be present and >= 0.
    let storage = make_sqlite_introspect();
    let stats = storage.stats(0).unwrap();
    let wfc = stats.wal_frame_count.expect("wal_frame_count must be present in WAL mode");
    assert!(wfc >= 0, "wal_frame_count must be non-negative");
}

#[test]
fn sqlite_introspection_postgres_fields_are_none() {
    // PostgreSQL-specific fields must be None for the SQLite backend.
    let storage = make_sqlite_introspect();
    let stats = storage.stats(0).unwrap();
    assert_eq!(stats.cache_hit_ratio, None, "cache_hit_ratio must be None for SQLite");
    assert_eq!(stats.transaction_commit_count, None, "transaction_commit_count must be None for SQLite");
    assert_eq!(stats.transaction_rollback_count, None, "transaction_rollback_count must be None for SQLite");
    assert_eq!(stats.deadlock_count, None, "deadlock_count must be None for SQLite");
}

#[test]
fn sqlite_introspection_inmemory_fields_are_none() {
    // InMemory-specific fields must be None for the SQLite backend.
    let storage = make_sqlite_introspect();
    let stats = storage.stats(0).unwrap();
    assert_eq!(stats.row_count, None, "row_count must be None for SQLite");
    assert_eq!(stats.blob_count, None, "blob_count must be None for SQLite");
}

#[test]
fn sqlite_introspection_captured_at_matches_input() {
    let storage = make_sqlite_introspect();
    let now = 1_700_000_000_i64;
    let stats = storage.stats(now).unwrap();
    assert_eq!(stats.captured_at_secs, now);
}

// ─────────────────────────────────────────────────────────────────────
// Part 1 regression test: schema merge on `migrate`.
//
// When a second `migrate()` call adds a new table (e.g. GeniusLocusKitMatrix
// adding `matrix_snapshot` to an open estate storage), the original schema's
// column-type metadata must remain intact. Before the fix, `apply_schema`
// replaced `inner.schema` unconditionally, erasing the first schema's
// type hints; after the fix, `inner.schema` accumulates all tables via merge.
//
// The test simulates the exact GLK pattern: open with a "drawer" schema
// containing a timestamp column, then migrate in a second "matrix" schema
// with a separate table. After migration, a drawer round-trip must decode
// the timestamp column as `TypedValue::Timestamp` (not `TypedValue::Text`).
// ─────────────────────────────────────────────────────────────────────

#[test]
fn migrate_preserves_primary_schema_timestamp_columns() {
    use persistence_kit::{
        ColumnDeclaration, RowStore as _, SchemaDeclaration, Storage as _,
        StorageError, TableDeclaration, TypedValue,
    };
    use std::collections::BTreeMap;

    // Open a fresh SQLite file.
    let path = std::env::temp_dir()
        .join(format!("pk_schema_merge_{}.sqlite", Uuid::new_v4()));
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string_lossy().into_owned(),
            busy_timeout_secs: 5.0,
        },
    );
    let storage = SqliteStorage::new(config).expect("open sqlite storage");

    // Primary schema: a table with a timestamp column (`filed_at`).
    // This represents the LocusKit drawer schema opened at estate provision.
    let primary_schema = SchemaDeclaration::new(
        "LocusKit",
        1,
        vec![TableDeclaration::new(
            "drawers",
            vec![
                ColumnDeclaration::uuid("row_id"),
                ColumnDeclaration::timestamp("filed_at"),
                ColumnDeclaration::text("content"),
            ],
            vec!["row_id".to_string()],
        )],
    );
    storage.open(&primary_schema).expect("open primary schema");

    // Insert a row with a Timestamp value so we can read it back.
    let now_secs: i64 = 1_700_000_000;
    let mut row: BTreeMap<String, TypedValue> = BTreeMap::new();
    row.insert("row_id".into(), TypedValue::Uuid(Uuid::new_v4()));
    row.insert("filed_at".into(), TypedValue::Timestamp(now_secs));
    row.insert("content".into(), TypedValue::Text("hello".into()));
    let handle = storage.row_store().insert("drawers", row).expect("insert drawer row");

    // Secondary schema: a different table (the matrix snapshot table) with no
    // timestamp columns. This simulates the GeniusLocusKitMatrix `migrate` call
    // that previously replaced `inner.schema` and erased the drawer type hints.
    let secondary_schema = SchemaDeclaration::new(
        "GeniusLocusKitMatrix",
        1,
        vec![TableDeclaration::new(
            "matrix_snapshot",
            vec![
                ColumnDeclaration::text("estate_id"),
                ColumnDeclaration::int("schema_version"),
                ColumnDeclaration::blob("snapshot"),
            ],
            vec!["estate_id".to_string()],
        )],
    );
    storage.migrate(&secondary_schema).expect("migrate secondary schema");

    // After migration: the drawer row must still decode `filed_at` as Timestamp.
    // Before the merge fix, `inner.schema` was the matrix schema only, so
    // `table_column_type("drawers", "filed_at")` returned None and the value
    // decoded as TypedValue::Text (the raw SQLite ISO8601 string).
    let rows = storage
        .row_store()
        .query("drawers", None, &[], Some(10), None)
        .expect("query after migrate");
    assert_eq!(rows.len(), 1, "expected one drawer row after migrate");
    let filed_at = rows[0].values.get("filed_at").expect("filed_at must be present");
    assert!(
        matches!(filed_at, TypedValue::Timestamp(_)),
        "filed_at must decode as Timestamp after migrate, got {:?}",
        filed_at
    );
    // Sanity-check the round-trip value.
    if let TypedValue::Timestamp(ts) = filed_at {
        assert_eq!(*ts, now_secs, "Timestamp round-trip must be exact");
    }
}

// ─────────────────────────────────────────────────────────────────────
// Audit chronological ordering (HLC_PACKED_ORDER_UNSOUND).
//
// Audit reads must return CHRONOLOGICAL (physical_time, logical_count,
// node_id) order. The packed `hlc` integer's field layout (node in the
// top byte, logical above physical) does not preserve that order, so a
// read keyed on the packed column mis-orders a same-millisecond burst
// (logical > 0) against a later write (logical 0). Mirrors the Swift
// SQLiteAuditChronologicalOrderTests.
// ─────────────────────────────────────────────────────────────────────

fn chrono_event(row_id: Uuid, hlc: HLC, verb: &str) -> AuditEvent {
    AuditEvent {
        event_id: Uuid::new_v4(),
        estate_uuid: Uuid::new_v4(),
        row_id,
        hlc,
        verb: verb.into(),
        before_adjective: None,
        before_operational: None,
        before_provenance: None,
        after_adjective: 1,
        after_operational: 2,
        after_provenance: 3,
        before_lattice_anchor: None,
        after_lattice_anchor: 0,
        before_lattice_qid: None,
        after_lattice_qid: 0,
        actor: "chrono-test".into(),
        reason: None,
    }
}

#[test]
fn sqlite_audit_same_millisecond_burst_orders_chronologically() {
    let storage = make_sqlite_audit_storage();
    let log = storage.audit_log();
    let row_id = Uuid::new_v4();
    // Node low byte 0xB1 (negative as i8) exercises the packed sign flip;
    // logical 1 at time T vs logical 0 at T+3 exercises the
    // logical-above-physical field-order defect.
    let burst = HLC { physical_time: 1_783_833_507_371, logical_count: 1, node_id: 0xB1 };
    let later = HLC { physical_time: 1_783_833_507_374, logical_count: 0, node_id: 0x08 };
    log.append(chrono_event(row_id, burst, "capture")).unwrap();
    log.append(chrono_event(row_id, later, "mutate")).unwrap();

    let all = log.iterate(None, None, 10).unwrap();
    let verbs: Vec<&str> = all.iter().map(|e| e.verb.as_str()).collect();
    assert_eq!(verbs, ["capture", "mutate"], "iterate must return chronological order");

    let for_row = log.iterate(None, Some(row_id), 10).unwrap();
    let row_verbs: Vec<&str> = for_row.iter().map(|e| e.verb.as_str()).collect();
    assert_eq!(row_verbs, ["capture", "mutate"], "per-row read must be chronological");

    // The cursor is exclusive and chronological: after the burst event,
    // only the later event remains.
    let tail = log.iterate(Some(burst), None, 10).unwrap();
    let tail_verbs: Vec<&str> = tail.iter().map(|e| e.verb.as_str()).collect();
    assert_eq!(tail_verbs, ["mutate"], "after-cursor must resume chronologically");
}

// ─────────────────────────────────────────────────────────────────────
// V2 regression: transaction nesting via SAVEPOINT.
//
// Before the fix, any code that called begin_transaction() or append_rows()
// while already inside a transaction() block issued a second BEGIN IMMEDIATE
// on the same SQLite connection, which fails immediately with
// "cannot start a transaction within a transaction". The fix: a per-connection
// tx_depth counter in Inner drives SAVEPOINT nesting at depth ≥ 1.
//
// These two tests reproduce the exact call sequences that vault_import uses:
// an outer transaction() bracket with begin_transaction/commit_transaction
// and with append_rows called on the shared dataset store.
// ─────────────────────────────────────────────────────────────────────

fn make_sqlite_nesting_storage() -> SqliteStorage {
    let path = std::env::temp_dir()
        .join(format!("pk_nesting_{}.sqlite", Uuid::new_v4()));
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string_lossy().into_owned(),
            busy_timeout_secs: 5.0,
        },
    );
    let storage = SqliteStorage::new(config).expect("open sqlite storage");
    let schema = persistence_kit::SchemaDeclaration::new("nesting-test", 1, vec![]);
    storage.open(&schema).expect("open schema");
    storage
}

#[test]
fn sqlite_nested_begin_transaction_uses_savepoint() {
    // Verifies that begin_transaction() called inside a transaction() block
    // succeeds via SAVEPOINT (depth 0→1→2→1→0) rather than failing with
    // "cannot start a transaction within a transaction". This reproduces the
    // vault_import capture path where capture_batch calls begin_transaction
    // while already inside an outer transaction bracket.
    let storage = make_sqlite_nesting_storage();
    use persistence_kit::IsolationLevel;
    storage
        .transaction(IsolationLevel::Serializable, &mut |txn| {
            // At this point tx_depth = 1 (BEGIN IMMEDIATE was issued).
            // begin_transaction must issue SAVEPOINT tx_1 (depth 1→2),
            // not a second BEGIN IMMEDIATE.
            let rs = txn.row_store();
            rs.begin_transaction()?;
            // SAVEPOINT tx_1 is open; tx_depth = 2.
            rs.commit_transaction()?;
            // RELEASE SAVEPOINT tx_1; tx_depth = 1.
            Ok(())
        })
        .expect("begin_transaction inside transaction() must succeed via SAVEPOINT");
}

#[test]
fn sqlite_nested_append_rows_uses_savepoint() {
    // Verifies that append_rows() called inside a transaction() block
    // succeeds via SAVEPOINT. append_rows issues its own nest_begin; at
    // tx_depth = 1 (outer transaction open) it gets SAVEPOINT instead of
    // a second BEGIN IMMEDIATE, which is what broke vault_import in the
    // field ("captureBatch: cannot start a transaction within a transaction").
    use persistence_kit::dataset_store::DatasetSchema;
    use persistence_kit::ColumnDeclaration;

    let storage = make_sqlite_nesting_storage();
    let ds = storage.dataset_store().expect("dataset_store");
    let id = Uuid::new_v4();
    let schema = DatasetSchema {
        columns: vec![ColumnDeclaration::text("label").nullable()],
        primary_key_column: None,
    };
    ds.create_dataset(id, &schema, &[]).expect("create_dataset");

    let mut row_map = std::collections::BTreeMap::new();
    row_map.insert("label".to_string(), persistence_kit::TypedValue::Text("test".to_string()));
    let rows = vec![row_map];

    use persistence_kit::IsolationLevel;
    storage
        .transaction(IsolationLevel::Serializable, &mut |_txn| {
            // ds shares the same Inner Arc as storage. At tx_depth = 1,
            // append_rows must issue SAVEPOINT tx_1 instead of BEGIN IMMEDIATE.
            ds.append_rows(id, &rows)?;
            Ok(())
        })
        .expect("append_rows inside transaction() must succeed via SAVEPOINT");

    // Confirm the row landed: the outer transaction committed it.
    let result = ds
        .query_rows(id, None, &[], None, None, None)
        .expect("query_rows");
    assert_eq!(result.len(), 1, "row appended inside nested transaction must be visible after commit");
}
