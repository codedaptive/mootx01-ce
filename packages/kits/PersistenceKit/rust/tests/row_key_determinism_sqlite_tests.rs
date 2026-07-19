// row_key_determinism_sqlite_tests.rs
//
// Gap 5 fix verification — sqlite.rs::extract_row_key.
//
// Rust twin of PersistenceKitSQLiteTests/RowKeyDeterminismMoneyTests.swift.
// See that file's header for the full gap-5 writeup. THE MONEY TEST: two
// INDEPENDENT SQLite databases (two separate temp files — the direct model
// of two federation spokes) writing a row with the SAME single-column
// `.text` primary-key VALUE must resolve to the SAME internal `RowKey`.
//
// Before gap 5, Rust's `sqlite.rs::extract_row_key` had NO `.text` handling
// at all (unlike Swift's SQLiteStorage.extractRowKey, which already parsed
// UUID-shaped strings) — so BOTH the UUID-shaped and non-UUID cases were
// broken on this backend pre-fix, unlike the Swift/InMemory asymmetry.

use persistence_kit::{
    BackendConfiguration, ColumnDeclaration, EstateConfiguration, SchemaDeclaration,
    SqliteStorage, Storage, TableDeclaration, TypedValue,
};
use std::collections::BTreeMap;
use uuid::Uuid;

fn make_widgets_storage() -> SqliteStorage {
    let path = std::env::temp_dir().join(format!("pk_gap5_rowkey_{}.sqlite", Uuid::new_v4()));
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string_lossy().into_owned(),
            busy_timeout_secs: 5.0,
        },
    );
    let storage = SqliteStorage::new(config).expect("open sqlite storage");
    let schema = SchemaDeclaration::new(
        "test-kit",
        1,
        vec![TableDeclaration::new(
            "widgets",
            vec![
                ColumnDeclaration::text("id"),
                ColumnDeclaration::text("note"),
            ],
            vec!["id".to_string()],
        )],
    );
    storage.open(&schema).expect("open widgets schema");
    storage
}

#[test]
fn same_uuid_shaped_text_pk_resolves_same_key_across_databases() {
    let storage_a = make_widgets_storage();
    let storage_b = make_widgets_storage();
    let id_value = Uuid::new_v4().to_string();

    let mut values_a: BTreeMap<String, TypedValue> = BTreeMap::new();
    values_a.insert("id".to_string(), TypedValue::Text(id_value.clone()));
    values_a.insert("note".to_string(), TypedValue::Text("from A".to_string()));
    let handle_a = storage_a
        .row_store()
        .upsert("widgets", values_a, &["id".to_string()])
        .expect("upsert A");

    let mut values_b: BTreeMap<String, TypedValue> = BTreeMap::new();
    values_b.insert("id".to_string(), TypedValue::Text(id_value));
    values_b.insert("note".to_string(), TypedValue::Text("from B".to_string()));
    let handle_b = storage_b
        .row_store()
        .upsert("widgets", values_b, &["id".to_string()])
        .expect("upsert B");

    assert_eq!(
        handle_a.key, handle_b.key,
        "two independent SQLite databases must resolve the SAME RowKey for the same UUID-shaped .text PK value"
    );
}

/// THE MONEY TEST: genuinely non-UUID id.
#[test]
fn same_non_uuid_text_pk_resolves_same_key_across_databases() {
    let storage_a = make_widgets_storage();
    let storage_b = make_widgets_storage();
    let id_value = "widget-alpha";

    let mut values_a: BTreeMap<String, TypedValue> = BTreeMap::new();
    values_a.insert("id".to_string(), TypedValue::Text(id_value.to_string()));
    values_a.insert("note".to_string(), TypedValue::Text("from A".to_string()));
    let handle_a = storage_a
        .row_store()
        .upsert("widgets", values_a, &["id".to_string()])
        .expect("upsert A");

    let mut values_b: BTreeMap<String, TypedValue> = BTreeMap::new();
    values_b.insert("id".to_string(), TypedValue::Text(id_value.to_string()));
    values_b.insert("note".to_string(), TypedValue::Text("from B".to_string()));
    let handle_b = storage_b
        .row_store()
        .upsert("widgets", values_b, &["id".to_string()])
        .expect("upsert B");

    assert_eq!(
        handle_a.key, handle_b.key,
        "gap 5 money test: two independent SQLite databases must resolve the SAME RowKey for the same non-UUID .text PK value"
    );
    assert_eq!(
        handle_a.key.to_string(),
        "5653f1d5-d5de-5b4f-a820-e6ba150a14e2"
    );
}

#[test]
fn uuid_typed_pk_is_unaffected() {
    let path = std::env::temp_dir().join(format!("pk_gap5_rowkey_uuid_{}.sqlite", Uuid::new_v4()));
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string_lossy().into_owned(),
            busy_timeout_secs: 5.0,
        },
    );
    let storage = SqliteStorage::new(config).expect("open sqlite storage");
    let schema = SchemaDeclaration::new(
        "test-kit",
        1,
        vec![TableDeclaration::new(
            "items",
            vec![
                ColumnDeclaration::uuid("id"),
                ColumnDeclaration::text("note"),
            ],
            vec!["id".to_string()],
        )],
    );
    storage.open(&schema).expect("open items schema");

    let id = Uuid::new_v4();
    let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
    values.insert("id".to_string(), TypedValue::Uuid(id));
    values.insert("note".to_string(), TypedValue::Text("x".to_string()));
    let handle = storage
        .row_store()
        .upsert("items", values, &["id".to_string()])
        .expect("upsert");

    assert_eq!(handle.key, id, "a .uuid PK's value IS the RowKey — unchanged by gap 5");
}
