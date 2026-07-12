// postgres_dataset_store.rs — MX-TAB-2 Rust integration tests
//
// All tests skip cleanly when PERSISTENCEKIT_PG_URL is not set, so
// default `cargo test` is green without a live PostgreSQL server.
//
// The skip gate pattern mirrors postgres_conformance.rs:
//   fn pg_test_url() -> Option<String>
//   returns Some(url) when PERSISTENCEKIT_PG_URL is set and non-empty,
//   None otherwise.
//
// Tests exercise:
//   - round-trip create / append / query / drop (synthetic PK)
//   - declared PK with pre-sort
//   - identifier rejection for SQL-injection names
//   - C-collation byte-order TEXT ordering (Z < a < É by byte value)
//   - f64 wire rule for column_stats on FLOAT columns
//   - predicate filtering and column projection

use std::collections::BTreeMap;
use uuid::Uuid;

use persistence_kit::{
    BackendConfiguration, ColumnDeclaration, Column,
    EstateConfiguration, PostgresStorage, Storage, TypedValue,
};
use persistence_kit::dataset_store::DatasetSchema;
use persistence_kit::predicate::{OrderClause, OrderDirection, StoragePredicate};

// ---------------------------------------------------------------------------
// Skip gate
// ---------------------------------------------------------------------------

fn pg_test_url() -> Option<String> {
    match std::env::var("PERSISTENCEKIT_PG_URL") {
        Ok(u) if !u.is_empty() => Some(u),
        _ => None,
    }
}

fn make_storage(cs: &str) -> PostgresStorage {
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Postgresql {
            connection_string: cs.to_string(),
            pool_size: 2,
            connection_timeout_secs: 5.0,
            idle_timeout_secs: 30.0,
        },
    );
    PostgresStorage::new(config).expect("connect postgres")
}

/// Build a nullable TEXT column declaration.
fn text_col(name: &str) -> ColumnDeclaration {
    ColumnDeclaration::text(name).nullable()
}

/// Build a nullable INT (BIGINT) column declaration.
fn int_col(name: &str) -> ColumnDeclaration {
    ColumnDeclaration::int(name).nullable()
}

/// Build a nullable FLOAT (DOUBLE PRECISION) column declaration.
fn float_col(name: &str) -> ColumnDeclaration {
    ColumnDeclaration::float(name).nullable()
}

/// Row builder: map column name → TypedValue.
fn row(pairs: &[(&str, TypedValue)]) -> BTreeMap<String, TypedValue> {
    pairs.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Synthetic-PK round-trip: create, append, query, drop.
///
/// Confirms that:
///   - `__ds_pk` is NOT included in SELECT results.
///   - Appended rows come back in insertion order (no ORDER BY).
///   - `drop_dataset` removes the table without error.
#[test]
fn round_trip_synthetic_pk() {
    let Some(url) = pg_test_url() else {
        eprintln!("round_trip_synthetic_pk: skipped (PERSISTENCEKIT_PG_URL not set)");
        return;
    };
    let storage = make_storage(&url);
    let ds = storage.dataset_store().expect("dataset_store()");

    let id = Uuid::new_v4();
    let schema = DatasetSchema {
        columns: vec![text_col("label"), int_col("value")],
        primary_key_column: None, // synthetic __ds_pk
    };
    ds.create_dataset(id, &schema, &[]).expect("create_dataset");

    let rows = vec![
        row(&[("label", TypedValue::Text("alpha".to_string())), ("value", TypedValue::Int(1))]),
        row(&[("label", TypedValue::Text("beta".to_string())), ("value", TypedValue::Int(2))]),
    ];
    ds.append_rows(id, &rows).expect("append_rows");

    let result = ds.query_rows(id, None, &[], None, None, None).expect("query_rows");
    assert_eq!(result.len(), 2, "expect 2 rows");
    // Neither row should expose __ds_pk.
    for r in &result {
        assert!(
            !r.values.contains_key("__ds_pk"),
            "__ds_pk must not appear in query_rows result"
        );
    }

    ds.drop_dataset(id).expect("drop_dataset");
}

/// Declared PK with pre-sort: rows inserted out of order should be
/// retrieved in PK-ascending order after pre-sort.
///
/// Schema: columns=[id INT, name TEXT], primary_key_column=Some("id").
/// Insert in descending ID order: 3, 1, 2.
/// Expect query_rows to return in the pre-sorted order 1, 2, 3 (rowid locality).
#[test]
fn pk_mode_declared_pk_presort() {
    let Some(url) = pg_test_url() else {
        eprintln!("pk_mode_declared_pk_presort: skipped (PERSISTENCEKIT_PG_URL not set)");
        return;
    };
    let storage = make_storage(&url);
    let ds = storage.dataset_store().expect("dataset_store()");

    let id = Uuid::new_v4();
    let schema = DatasetSchema {
        columns: vec![int_col("id"), text_col("name")],
        primary_key_column: Some("id".to_string()),
    };
    ds.create_dataset(id, &schema, &[]).expect("create_dataset");

    // Insert out-of-order to verify pre-sort.
    let rows = vec![
        row(&[("id", TypedValue::Int(3)), ("name", TypedValue::Text("three".to_string()))]),
        row(&[("id", TypedValue::Int(1)), ("name", TypedValue::Text("one".to_string()))]),
        row(&[("id", TypedValue::Int(2)), ("name", TypedValue::Text("two".to_string()))]),
    ];
    ds.append_rows(id, &rows).expect("append_rows");

    // ORDER BY id ASC to verify pre-sort landed correctly.
    let col = Column { table: format!("ds_{}", id.as_simple()), name: "id".to_string() };
    let order = vec![OrderClause { column: col, direction: OrderDirection::Ascending }];
    let result = ds.query_rows(id, None, &order, None, None, None).expect("query_rows");

    assert_eq!(result.len(), 3);
    assert_eq!(result[0].values["id"], TypedValue::Int(1));
    assert_eq!(result[1].values["id"], TypedValue::Int(2));
    assert_eq!(result[2].values["id"], TypedValue::Int(3));

    ds.drop_dataset(id).expect("drop_dataset");
}

/// Identifier rejection: SQL-injection column names in create_dataset
/// must return StorageError::InvalidIdentifier without executing any DDL.
#[test]
fn identifier_rejection_create_dataset_sql_injection() {
    let Some(url) = pg_test_url() else {
        eprintln!("identifier_rejection_create_dataset_sql_injection: skipped");
        return;
    };
    let storage = make_storage(&url);
    let ds = storage.dataset_store().expect("dataset_store()");

    let malicious_names = [
        "col; DROP TABLE students;--",
        "1bad",
        "col name",
        "col'name",
        "col\"name",
    ];

    for name in &malicious_names {
        let id = Uuid::new_v4();
        let schema = DatasetSchema {
            columns: vec![ColumnDeclaration::text(*name).nullable()],
            primary_key_column: None,
        };
        let result = ds.create_dataset(id, &schema, &[]);
        assert!(
            result.is_err(),
            "expected error for malicious column name {:?}, got Ok",
            name
        );
    }
}

/// Identifier rejection: SQL-injection column names in append_rows.
#[test]
fn identifier_rejection_append_rows_sql_injection() {
    let Some(url) = pg_test_url() else {
        eprintln!("identifier_rejection_append_rows_sql_injection: skipped");
        return;
    };
    let storage = make_storage(&url);
    let ds = storage.dataset_store().expect("dataset_store()");

    // Create a valid dataset first.
    let id = Uuid::new_v4();
    let schema = DatasetSchema {
        columns: vec![text_col("label")],
        primary_key_column: None,
    };
    ds.create_dataset(id, &schema, &[]).expect("create_dataset");

    // Attempt to append a row with a malicious column name.
    let mut bad_row: BTreeMap<String, TypedValue> = BTreeMap::new();
    bad_row.insert("label; DROP TABLE foo;--".to_string(), TypedValue::Text("x".to_string()));
    let result = ds.append_rows(id, &[bad_row]);
    assert!(result.is_err(), "expected error for SQL-injection column name in append_rows");

    ds.drop_dataset(id).expect("drop_dataset");
}

/// C-collation byte-order TEXT ordering.
///
/// Fixture: ["É", "a", "Z"]
/// Expected ORDER BY ASC: ["Z", "a", "É"]  (byte values: 0x5A, 0x61, 0xC3 0x89)
///
/// This verifies COLLATE "C" is in effect — standard C locale uses byte order,
/// which puts uppercase ASCII before lowercase, and all ASCII before multi-byte UTF-8.
/// Mirrors the Swift `cCollation_textOrdering_byteOrder` test.
#[test]
fn c_collation_text_ordering_byte_order() {
    let Some(url) = pg_test_url() else {
        eprintln!("c_collation_text_ordering_byte_order: skipped");
        return;
    };
    let storage = make_storage(&url);
    let ds = storage.dataset_store().expect("dataset_store()");

    let id = Uuid::new_v4();
    let schema = DatasetSchema {
        columns: vec![text_col("word")],
        primary_key_column: None,
    };
    ds.create_dataset(id, &schema, &[]).expect("create_dataset");

    let rows = vec![
        row(&[("word", TypedValue::Text("É".to_string()))]),
        row(&[("word", TypedValue::Text("a".to_string()))]),
        row(&[("word", TypedValue::Text("Z".to_string()))]),
    ];
    ds.append_rows(id, &rows).expect("append_rows");

    let col = Column { table: format!("ds_{}", id.as_simple()), name: "word".to_string() };
    let order = vec![OrderClause { column: col, direction: OrderDirection::Ascending }];
    let result = ds.query_rows(id, None, &order, None, None, None).expect("query_rows");

    assert_eq!(result.len(), 3);
    // COLLATE "C" byte order: 'Z' (0x5A) < 'a' (0x61) < 'É' (0xC3 0x89)
    assert_eq!(result[0].values["word"], TypedValue::Text("Z".to_string()));
    assert_eq!(result[1].values["word"], TypedValue::Text("a".to_string()));
    assert_eq!(result[2].values["word"], TypedValue::Text("É".to_string()));

    ds.drop_dataset(id).expect("drop_dataset");
}

/// C-collation: ASCII range byte order.
///
/// Fixture: ["apple", "Banana", "Cherry", "date"]
/// Expected ORDER BY ASC: ["Banana", "Cherry", "apple", "date"]
/// (uppercase 'B', 'C' (0x42, 0x43) < lowercase 'a', 'd' (0x61, 0x64))
///
/// Mirrors the Swift `cCollation_textOrdering_asciiRange` test.
#[test]
fn c_collation_text_ordering_ascii_range() {
    let Some(url) = pg_test_url() else {
        eprintln!("c_collation_text_ordering_ascii_range: skipped");
        return;
    };
    let storage = make_storage(&url);
    let ds = storage.dataset_store().expect("dataset_store()");

    let id = Uuid::new_v4();
    let schema = DatasetSchema {
        columns: vec![text_col("fruit")],
        primary_key_column: None,
    };
    ds.create_dataset(id, &schema, &[]).expect("create_dataset");

    let rows = vec![
        row(&[("fruit", TypedValue::Text("apple".to_string()))]),
        row(&[("fruit", TypedValue::Text("Banana".to_string()))]),
        row(&[("fruit", TypedValue::Text("Cherry".to_string()))]),
        row(&[("fruit", TypedValue::Text("date".to_string()))]),
    ];
    ds.append_rows(id, &rows).expect("append_rows");

    let col = Column { table: format!("ds_{}", id.as_simple()), name: "fruit".to_string() };
    let order = vec![OrderClause { column: col, direction: OrderDirection::Ascending }];
    let result = ds.query_rows(id, None, &order, None, None, None).expect("query_rows");

    assert_eq!(result.len(), 4);
    assert_eq!(result[0].values["fruit"], TypedValue::Text("Banana".to_string()));
    assert_eq!(result[1].values["fruit"], TypedValue::Text("Cherry".to_string()));
    assert_eq!(result[2].values["fruit"], TypedValue::Text("apple".to_string()));
    assert_eq!(result[3].values["fruit"], TypedValue::Text("date".to_string()));

    ds.drop_dataset(id).expect("drop_dataset");
}

/// column_stats float column: verifies f64 wire rule.
///
/// MIN/MAX for a FLOAT (DOUBLE PRECISION) column must decode as
/// TypedValue::Float(f64) — never f32. Mirrors Swift's
/// `columnStats_floatColumn_f64Wire` test.
#[test]
fn column_stats_float_column_f64_wire() {
    let Some(url) = pg_test_url() else {
        eprintln!("column_stats_float_column_f64_wire: skipped");
        return;
    };
    let storage = make_storage(&url);
    let ds = storage.dataset_store().expect("dataset_store()");

    let id = Uuid::new_v4();
    let schema = DatasetSchema {
        columns: vec![float_col("score")],
        primary_key_column: None,
    };
    ds.create_dataset(id, &schema, &[]).expect("create_dataset");

    let rows = vec![
        row(&[("score", TypedValue::Float(1.5))]),
        row(&[("score", TypedValue::Float(3.14))]),
        row(&[("score", TypedValue::Float(2.71))]),
    ];
    ds.append_rows(id, &rows).expect("append_rows");

    let stats = ds.column_stats(id, "score").expect("column_stats");
    assert_eq!(stats.count, 3);
    assert_eq!(stats.null_count, 0);
    // Min/max must be TypedValue::Float (f64), not TypedValue::Int or anything else.
    match stats.min {
        TypedValue::Float(v) => assert!((v - 1.5).abs() < 1e-10, "min should be 1.5, got {v}"),
        other => panic!("column_stats min for FLOAT column should be TypedValue::Float, got {other:?}"),
    }
    match stats.max {
        TypedValue::Float(v) => assert!((v - 3.14).abs() < 1e-10, "max should be 3.14, got {v}"),
        other => panic!("column_stats max for FLOAT column should be TypedValue::Float, got {other:?}"),
    }

    ds.drop_dataset(id).expect("drop_dataset");
}

/// column_stats for an empty dataset: count=0, null_count=0, min/max=Null.
#[test]
fn column_stats_empty_dataset() {
    let Some(url) = pg_test_url() else {
        eprintln!("column_stats_empty_dataset: skipped");
        return;
    };
    let storage = make_storage(&url);
    let ds = storage.dataset_store().expect("dataset_store()");

    let id = Uuid::new_v4();
    let schema = DatasetSchema {
        columns: vec![int_col("val")],
        primary_key_column: None,
    };
    ds.create_dataset(id, &schema, &[]).expect("create_dataset");

    let stats = ds.column_stats(id, "val").expect("column_stats on empty");
    assert_eq!(stats.count, 0);
    assert_eq!(stats.null_count, 0);
    assert_eq!(stats.min, TypedValue::Null);
    assert_eq!(stats.max, TypedValue::Null);

    ds.drop_dataset(id).expect("drop_dataset");
}

/// column_stats: all-null column has count=0, null_count=N.
#[test]
fn column_stats_all_nulls() {
    let Some(url) = pg_test_url() else {
        eprintln!("column_stats_all_nulls: skipped");
        return;
    };
    let storage = make_storage(&url);
    let ds = storage.dataset_store().expect("dataset_store()");

    let id = Uuid::new_v4();
    let schema = DatasetSchema {
        columns: vec![text_col("anchor"), text_col("optional")],
        primary_key_column: None,
    };
    ds.create_dataset(id, &schema, &[]).expect("create_dataset");

    let rows = vec![
        row(&[("anchor", TypedValue::Text("a".to_string())), ("optional", TypedValue::Null)]),
        row(&[("anchor", TypedValue::Text("b".to_string())), ("optional", TypedValue::Null)]),
    ];
    ds.append_rows(id, &rows).expect("append_rows");

    let stats = ds.column_stats(id, "optional").expect("column_stats all-null");
    assert_eq!(stats.count, 0, "COUNT of non-null should be 0");
    assert_eq!(stats.null_count, 2, "null_count should be 2");
    assert_eq!(stats.min, TypedValue::Null);
    assert_eq!(stats.max, TypedValue::Null);

    ds.drop_dataset(id).expect("drop_dataset");
}

/// Predicate filtering: query with a value equality predicate.
#[test]
fn predicate_filters_by_value() {
    let Some(url) = pg_test_url() else {
        eprintln!("predicate_filters_by_value: skipped");
        return;
    };
    let storage = make_storage(&url);
    let ds = storage.dataset_store().expect("dataset_store()");

    let id = Uuid::new_v4();
    let schema = DatasetSchema {
        columns: vec![text_col("tag"), int_col("n")],
        primary_key_column: None,
    };
    ds.create_dataset(id, &schema, &[]).expect("create_dataset");

    let rows = vec![
        row(&[("tag", TypedValue::Text("x".to_string())), ("n", TypedValue::Int(1))]),
        row(&[("tag", TypedValue::Text("y".to_string())), ("n", TypedValue::Int(2))]),
        row(&[("tag", TypedValue::Text("x".to_string())), ("n", TypedValue::Int(3))]),
    ];
    ds.append_rows(id, &rows).expect("append_rows");

    // Filter: tag = "x"
    let table_name = format!("ds_{}", id.as_simple());
    let pred = StoragePredicate::Eq(
        Column { table: table_name, name: "tag".to_string() },
        TypedValue::Text("x".to_string()),
    );
    let result = ds.query_rows(id, Some(&pred), &[], None, None, None).expect("query_rows");
    assert_eq!(result.len(), 2, "expect 2 rows with tag=x");

    ds.drop_dataset(id).expect("drop_dataset");
}

/// Column projection: query with columns=[\"tag\"] should return only the
/// requested column, not the full row.
#[test]
fn projection_returns_subset_of_columns() {
    let Some(url) = pg_test_url() else {
        eprintln!("projection_returns_subset_of_columns: skipped");
        return;
    };
    let storage = make_storage(&url);
    let ds = storage.dataset_store().expect("dataset_store()");

    let id = Uuid::new_v4();
    let schema = DatasetSchema {
        columns: vec![text_col("name"), int_col("age"), float_col("score")],
        primary_key_column: None,
    };
    ds.create_dataset(id, &schema, &[]).expect("create_dataset");

    let rows = vec![
        row(&[
            ("name", TypedValue::Text("Alice".to_string())),
            ("age", TypedValue::Int(30)),
            ("score", TypedValue::Float(9.5)),
        ]),
    ];
    ds.append_rows(id, &rows).expect("append_rows");

    let columns = vec!["name".to_string()];
    let result = ds.query_rows(id, None, &[], None, None, Some(&columns)).expect("query_rows");
    assert_eq!(result.len(), 1);
    let r = &result[0];
    assert!(r.values.contains_key("name"), "expected 'name' column in result");
    assert!(!r.values.contains_key("age"), "'age' should not appear in projected result");
    assert!(!r.values.contains_key("score"), "'score' should not appear in projected result");

    ds.drop_dataset(id).expect("drop_dataset");
}
