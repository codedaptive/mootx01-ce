// Runs the backend-agnostic conformance suite against the SQLite backend.
// Each factory() call opens a fresh temp-file database.

mod conformance;

use conformance::{run_all, vector_fixtures, Factory};
use persistence_kit::{BackendConfiguration, EstateConfiguration, SqliteStorage, Storage};
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
