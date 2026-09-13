// row_key_public_api_agreement_tests.rs
//
// Gate: public deterministic_row_key returns THE SAME value the SQLite
// backend assigns as the RowKey of a single-column TEXT-PK row.
//
// Rust twin of RowKeyDerivationAgreementTests.swift (LocusKit test target).
// Introduced in KGFACT_AUDIT Unit 1 when deterministic_row_key was
// documented as public API with a four-point contract. Prior file-header
// comment in row_key_derivation.rs named RowKeyDerivationCrossCheckTests.swift
// as the gate; that file never existed. This file, together with its Swift
// twin, IS the gate.
//
// What it proves: contract point 1 — "the returned value IS the RowKey the
// storage layer assigns to a single-column TEXT-primary-key row carrying that
// id, in every backend." Exercised here against the SQLite backend.

use persistence_kit::{
    deterministic_row_key, BackendConfiguration, ColumnDeclaration, EstateConfiguration,
    SchemaDeclaration, SqliteStorage, Storage, TableDeclaration, TypedValue,
};
use std::collections::BTreeMap;
use uuid::Uuid;

fn make_kg_facts_storage() -> SqliteStorage {
    let path = std::env::temp_dir().join(format!(
        "pk_rowkey_agreement_{}.sqlite",
        Uuid::new_v4()
    ));
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string_lossy().into_owned(),
            busy_timeout_secs: 5.0,
        },
    );
    let storage = SqliteStorage::new(config).expect("open sqlite storage");
    // Minimal kg_facts-shaped schema: TEXT primary key named "id".
    let schema = SchemaDeclaration::new(
        "test-rowkey-agreement",
        1,
        vec![TableDeclaration::new(
            "kg_facts",
            vec![
                ColumnDeclaration::text("id"),
                ColumnDeclaration::text("note"),
            ],
            vec!["id".to_string()],
        )],
    );
    storage.open(&schema).expect("open kg_facts schema");
    storage
}

/// Contract point 1 + 3: a non-UUID kg_facts id — the RowKey the SQLite
/// backend assigns equals deterministic_row_key of the same id.
#[test]
fn non_uuid_id_agreement() {
    let storage = make_kg_facts_storage();
    let id = "fact-not-a-uuid-1";
    let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
    values.insert("id".to_string(), TypedValue::Text(id.to_string()));
    values.insert("note".to_string(), TypedValue::Text("gate".to_string()));
    let handle = storage
        .row_store()
        .insert("kg_facts", values)
        .expect("insert kg_facts row");
    let derived = deterministic_row_key(id);
    assert_eq!(
        handle.key, derived,
        "kg_facts RowKey for non-UUID id must equal deterministic_row_key"
    );
}

/// Contract point 1 + 2: a UUID-shaped kg_facts id — the RowKey the SQLite
/// backend assigns equals that UUID (deterministic_row_key passes it through).
#[test]
fn uuid_id_agreement() {
    let storage = make_kg_facts_storage();
    let id = Uuid::new_v4();
    let id_str = id.to_string();
    let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
    values.insert("id".to_string(), TypedValue::Text(id_str.clone()));
    values.insert("note".to_string(), TypedValue::Text("gate".to_string()));
    let handle = storage
        .row_store()
        .insert("kg_facts", values)
        .expect("insert kg_facts row");
    let derived = deterministic_row_key(&id_str);
    assert_eq!(
        handle.key, derived,
        "kg_facts RowKey for UUID-shaped id must equal deterministic_row_key"
    );
    assert_eq!(
        handle.key, id,
        "deterministic_row_key passes a UUID-shaped string through unchanged"
    );
}
