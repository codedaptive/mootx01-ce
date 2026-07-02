// corrupt_readback_tests.rs
//
// Verifies that the Rust SQLite backend returns StorageError::CorruptStoredValue
// when a stored TEXT value cannot be parsed to its declared column type.
//
// Strategy: write a valid row via the public RowStore API, then corrupt the
// stored value directly via a raw rusqlite connection (bypassing the kit's
// value codec), then attempt a read-back and assert the structured error —
// not a nil UUID, not timestamp 0, not any silently wrong value.
//
// The type-tolerant decode path (valid value in the wrong column affinity)
// is distinct from parse failure and is NOT changed by this fix; only the
// TEXT→UUID and TEXT→Timestamp parse-failure paths now return errors.

use persistence_kit::{
    BackendConfiguration, ColumnDeclaration, ColumnType, EstateConfiguration,
    SchemaDeclaration, SqliteStorage, Storage, StorageError, StoragePredicate, TableDeclaration,
    TypedValue,
};
use rusqlite::Connection;
use std::collections::BTreeMap;
use uuid::Uuid;

// ─────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────

fn make_sqlite(path: &str) -> SqliteStorage {
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string(),
            busy_timeout_secs: 5.0,
        },
    );
    SqliteStorage::new(config).expect("open sqlite storage")
}

fn uuid_schema(kit_id: &str) -> SchemaDeclaration {
    SchemaDeclaration::new(
        kit_id,
        1,
        vec![TableDeclaration::new(
            "items",
            vec![
                ColumnDeclaration::uuid("row_id"),
                ColumnDeclaration::uuid("ref_id"), // the column we corrupt
                ColumnDeclaration::text("label"),
            ],
            vec!["row_id".to_string()],
        )],
    )
}

fn timestamp_schema(kit_id: &str) -> SchemaDeclaration {
    SchemaDeclaration::new(
        kit_id,
        1,
        vec![TableDeclaration::new(
            "events",
            vec![
                ColumnDeclaration::uuid("row_id"),
                ColumnDeclaration::new("captured_at", ColumnType::Timestamp),
            ],
            vec!["row_id".to_string()],
        )],
    )
}

/// Execute arbitrary SQL directly against the SQLite file, bypassing the kit.
/// Used exclusively to corrupt stored values for negative-path testing.
fn raw_exec(path: &str, sql: &str) {
    let conn = Connection::open(path).expect("raw open");
    conn.execute_batch(sql).expect("raw exec");
}

// ─────────────────────────────────────────────────────────────────────
// UUID corruption
// ─────────────────────────────────────────────────────────────────────

#[test]
fn corrupt_uuid_column_returns_corrupt_stored_value() {
    let path = std::env::temp_dir()
        .join(format!("corrupt_uuid_{}.sqlite", Uuid::new_v4()))
        .to_string_lossy()
        .into_owned();

    let row_id = Uuid::new_v4();
    let ref_id = Uuid::new_v4();

    // Write a valid row.
    {
        let storage = make_sqlite(&path);
        storage.open(&uuid_schema("uuid-corrupt-test")).expect("open schema");
        let rs = Storage::row_store(&storage);
        let mut values = BTreeMap::new();
        values.insert("row_id".to_string(), TypedValue::Uuid(row_id));
        values.insert("ref_id".to_string(), TypedValue::Uuid(ref_id));
        values.insert("label".to_string(), TypedValue::Text("valid".to_string()));
        rs.insert("items", values).expect("insert");
    } // storage drops and connection closes

    // Verify clean round-trip before corruption.
    {
        let storage = make_sqlite(&path);
        storage.open(&uuid_schema("uuid-corrupt-test")).expect("open schema");
        let rs = Storage::row_store(&storage);
        let pred = StoragePredicate::Eq(
            persistence_kit::Column::new("items", "row_id"),
            TypedValue::Uuid(row_id),
        );
        let rows = rs.query("items", Some(&pred), &[], None, None).expect("query");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].get("ref_id"), Some(&TypedValue::Uuid(ref_id)));
    }

    // Corrupt the ref_id column.
    raw_exec(
        &path,
        &format!(
            "UPDATE \"items\" SET \"ref_id\" = 'NOT-A-UUID' WHERE \"row_id\" = '{}'",
            row_id.to_string().to_uppercase()
        ),
    );

    // Read-back must fail with CorruptStoredValue, not return TypedValue::Uuid(Uuid::nil()).
    let storage = make_sqlite(&path);
    storage.open(&uuid_schema("uuid-corrupt-test")).expect("open schema");
    let rs = Storage::row_store(&storage);
    let pred = StoragePredicate::Eq(
        persistence_kit::Column::new("items", "row_id"),
        TypedValue::Uuid(row_id),
    );
    let result = rs.query("items", Some(&pred), &[], None, None);
    match result {
        Err(StorageError::CorruptStoredValue { table, column, stored_text }) => {
            assert_eq!(table, "items");
            assert_eq!(column, "ref_id");
            assert_eq!(stored_text, "NOT-A-UUID");
        }
        Err(other) => panic!("expected CorruptStoredValue, got: {:?}", other),
        Ok(rows) => panic!(
            "expected Err(CorruptStoredValue) but got Ok with {} rows: {:?}",
            rows.len(),
            rows.first().and_then(|r| r.get("ref_id"))
        ),
    }
}

#[test]
fn valid_uuid_still_round_trips_correctly() {
    let path = std::env::temp_dir()
        .join(format!("valid_uuid_{}.sqlite", Uuid::new_v4()))
        .to_string_lossy()
        .into_owned();

    let row_id = Uuid::new_v4();
    let ref_id = Uuid::new_v4();

    let storage = make_sqlite(&path);
    storage.open(&uuid_schema("uuid-valid-test")).expect("open schema");
    let rs = Storage::row_store(&storage);
    let mut values = BTreeMap::new();
    values.insert("row_id".to_string(), TypedValue::Uuid(row_id));
    values.insert("ref_id".to_string(), TypedValue::Uuid(ref_id));
    values.insert("label".to_string(), TypedValue::Text("ok".to_string()));
    rs.insert("items", values).expect("insert");

    let pred = StoragePredicate::Eq(
        persistence_kit::Column::new("items", "row_id"),
        TypedValue::Uuid(row_id),
    );
    let rows = rs
        .query("items", Some(&pred), &[], None, None)
        .expect("query");
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].get("ref_id"), Some(&TypedValue::Uuid(ref_id)));
}

// ─────────────────────────────────────────────────────────────────────
// Timestamp corruption
// ─────────────────────────────────────────────────────────────────────

#[test]
fn corrupt_timestamp_column_returns_corrupt_stored_value() {
    let path = std::env::temp_dir()
        .join(format!("corrupt_ts_{}.sqlite", Uuid::new_v4()))
        .to_string_lossy()
        .into_owned();

    let row_id = Uuid::new_v4();

    // Write a valid row with a real ISO-8601 timestamp.
    {
        let storage = make_sqlite(&path);
        storage.open(&timestamp_schema("ts-corrupt-test")).expect("open schema");
        let rs = Storage::row_store(&storage);
        let mut values = BTreeMap::new();
        values.insert("row_id".to_string(), TypedValue::Uuid(row_id));
        // 2023-11-14T22:13:20Z in Unix seconds
        values.insert("captured_at".to_string(), TypedValue::Timestamp(1_700_000_000));
        rs.insert("events", values).expect("insert");
    }

    // Corrupt the timestamp.
    raw_exec(
        &path,
        &format!(
            "UPDATE \"events\" SET \"captured_at\" = 'definitely-not-a-date' WHERE \"row_id\" = '{}'",
            row_id.to_string().to_uppercase()
        ),
    );

    // Read-back must fail with CorruptStoredValue, not return TypedValue::Timestamp(0).
    let storage = make_sqlite(&path);
    storage.open(&timestamp_schema("ts-corrupt-test")).expect("open schema");
    let rs = Storage::row_store(&storage);
    let pred = StoragePredicate::Eq(
        persistence_kit::Column::new("events", "row_id"),
        TypedValue::Uuid(row_id),
    );
    let result = rs.query("events", Some(&pred), &[], None, None);
    match result {
        Err(StorageError::CorruptStoredValue { table, column, stored_text }) => {
            assert_eq!(table, "events");
            assert_eq!(column, "captured_at");
            assert_eq!(stored_text, "definitely-not-a-date");
        }
        Err(other) => panic!("expected CorruptStoredValue, got: {:?}", other),
        Ok(rows) => panic!(
            "expected Err(CorruptStoredValue) but got Ok with {} rows: {:?}",
            rows.len(),
            rows.first().and_then(|r| r.get("captured_at"))
        ),
    }
}

#[test]
fn valid_timestamp_still_round_trips_correctly() {
    let path = std::env::temp_dir()
        .join(format!("valid_ts_{}.sqlite", Uuid::new_v4()))
        .to_string_lossy()
        .into_owned();

    let row_id = Uuid::new_v4();
    // 2023-11-14T22:13:20Z
    let original_secs: i64 = 1_700_000_000;

    let storage = make_sqlite(&path);
    storage.open(&timestamp_schema("ts-valid-test")).expect("open schema");
    let rs = Storage::row_store(&storage);
    let mut values = BTreeMap::new();
    values.insert("row_id".to_string(), TypedValue::Uuid(row_id));
    values.insert("captured_at".to_string(), TypedValue::Timestamp(original_secs));
    rs.insert("events", values).expect("insert");

    let pred = StoragePredicate::Eq(
        persistence_kit::Column::new("events", "row_id"),
        TypedValue::Uuid(row_id),
    );
    let rows = rs
        .query("events", Some(&pred), &[], None, None)
        .expect("query");
    assert_eq!(rows.len(), 1);
    assert_eq!(
        rows[0].get("captured_at"),
        Some(&TypedValue::Timestamp(original_secs))
    );
}

// ─────────────────────────────────────────────────────────────────────
// Audit UUID corruption
// ─────────────────────────────────────────────────────────────────────

#[test]
fn corrupt_audit_event_id_returns_error_not_nil_uuid() {
    use persistence_kit::{AuditEvent};
    use substrate_types::hlc::HLC;

    let path = std::env::temp_dir()
        .join(format!("corrupt_audit_{}.sqlite", Uuid::new_v4()))
        .to_string_lossy()
        .into_owned();

    let row_id = Uuid::new_v4();
    let estate_id = Uuid::new_v4();

    // Write a valid audit event.
    {
        let storage = make_sqlite(&path);
        storage.open(&SchemaDeclaration::new("audit-corrupt-test", 1, vec![])).expect("open");
        let al = Storage::audit_log(&storage);
        let event = AuditEvent {
            event_id: Uuid::new_v4(),
            hlc: HLC { physical_time: 1000, logical_count: 1, node_id: 1 },
            estate_uuid: estate_id,
            row_id,
            verb: "store".to_string(),
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
            actor: "test".to_string(),
            reason: None,
        };
        al.append(event).expect("append");
    }

    // Corrupt the event_id.
    raw_exec(
        &path,
        "UPDATE \"_storagekit_audit\" SET \"event_id\" = 'BAD-UUID'",
    );

    // iterate must fail — not return an event with Uuid::nil().
    let storage = make_sqlite(&path);
    storage.open(&SchemaDeclaration::new("audit-corrupt-test", 1, vec![])).expect("open");
    let al = Storage::audit_log(&storage);
    let result = al.iterate(None, None, 100);
    assert!(
        result.is_err(),
        "expected Err but got Ok with {} events",
        result.unwrap().len()
    );
    // Confirm it is a backend error (rusqlite InvalidColumnType) rather than
    // a silent success. The exact error variant is BackendError because
    // rusqlite wraps the InvalidColumnType before map_sql_err converts it.
    match result.unwrap_err() {
        StorageError::BackendError { .. } => { /* correct — rusqlite invalid column type */ }
        other => panic!("expected BackendError(rusqlite), got: {:?}", other),
    }
}
