//! Tests for the hash-on-write decorator (NT-P2).
//!
//! Verifies:
//!   (a) insert to hashable table emits dirty-chain event
//!   (b) upsert to hashable table emits dirty-chain event
//!   (c) insert to non-hashable table does not fire the hook
//!   (d) no-parent-chain path skips emission but stores the hash
//!   (e) read operations pass through unchanged
//!   (f) hashable field defaults to false
//!   (g) DirtyChainEvent can be constructed, dispatched, and received

use persistence_kit::hashing_row_store::{HashOnWriteConfig, HashingRowStore};
use persistence_kit::observer::{DirtyChainEvent, DirtyChainHub};
use persistence_kit::row_store::RowStore;
use persistence_kit::schema::{ColumnDeclaration, SchemaDeclaration, TableDeclaration};
use persistence_kit::storage::{BackendConfiguration, EstateConfiguration, Storage};
use persistence_kit::types::TypedValue;
use persistence_kit::inmemory::InMemoryStorage;
use std::collections::{BTreeMap, HashSet};
use std::sync::Arc;
use substrate_types::content_hash::ContentHash;

/// Creates a deterministic ContentHash for testing.
fn test_hash(_table: &str, row_key: uuid::Uuid, _values: &BTreeMap<String, TypedValue>) -> ContentHash {
    let uuid_bytes = row_key.as_bytes();
    let mut bytes = [0u8; 32];
    for i in 0..32 {
        bytes[i] = uuid_bytes[i % 16];
    }
    ContentHash::new(bytes)
}

fn fixed_parent_ids() -> (uuid::Uuid, uuid::Uuid) {
    (
        uuid::Uuid::parse_str("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa").unwrap(),
        uuid::Uuid::parse_str("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb").unwrap(),
    )
}

fn test_parent_chain(_table: &str, _row_key: uuid::Uuid) -> Option<(uuid::Uuid, uuid::Uuid)> {
    Some(fixed_parent_ids())
}

fn no_parent_chain(_table: &str, _row_key: uuid::Uuid) -> Option<(uuid::Uuid, uuid::Uuid)> {
    None
}

fn make_storage() -> InMemoryStorage {
    InMemoryStorage::new(EstateConfiguration::new(
        uuid::Uuid::new_v4(),
        BackendConfiguration::InMemory,
    ))
}

fn open_hashable_schema(storage: &InMemoryStorage) {
    let schema = SchemaDeclaration::new(
        "HashTest",
        1,
        vec![
            TableDeclaration::new(
                "hashable_items",
                vec![
                    ColumnDeclaration::uuid("id"),
                    ColumnDeclaration::text("content"),
                    ColumnDeclaration::blob("content_hash").nullable(),
                ],
                vec!["id".to_string()],
            ).hashable(),
            TableDeclaration::new(
                "plain_items",
                vec![
                    ColumnDeclaration::uuid("id"),
                    ColumnDeclaration::text("content"),
                ],
                vec!["id".to_string()],
            ),
        ],
    );
    storage.open(&schema).unwrap();
}

// MARK: - Part 2: DirtyChainEvent construction

#[test]
fn dirty_chain_event_construction() {
    let row_id = uuid::Uuid::new_v4();
    let parent_id = uuid::Uuid::new_v4();
    let grandparent_id = uuid::Uuid::new_v4();
    let hash = ContentHash::new([0xAB; 32]);

    let event = DirtyChainEvent {
        changed_row_id: row_id,
        parent_node_id: parent_id,
        grandparent_node_id: grandparent_id,
        content_hash: hash.clone(),
        table: "drawers".to_string(),
    };

    assert_eq!(event.changed_row_id, row_id);
    assert_eq!(event.parent_node_id, parent_id);
    assert_eq!(event.grandparent_node_id, grandparent_id);
    assert_eq!(event.content_hash, hash);
    assert_eq!(event.table, "drawers");
}

// MARK: - Part 2: DirtyChainHub delivery

#[test]
fn dirty_chain_hub_delivers_events() {
    let hub = Arc::new(DirtyChainHub::new());
    let rx = hub.subscribe();

    let event = DirtyChainEvent {
        changed_row_id: uuid::Uuid::new_v4(),
        parent_node_id: uuid::Uuid::new_v4(),
        grandparent_node_id: uuid::Uuid::new_v4(),
        content_hash: ContentHash::new([0x01; 32]),
        table: "test".to_string(),
    };

    hub.emit(event.clone());

    let received = rx.recv().unwrap();
    assert_eq!(received.changed_row_id, event.changed_row_id);
    assert_eq!(received.table, "test");
}

// MARK: - Part 1: Hash-on-write hook behavior

#[test]
fn insert_to_hashable_table_emits_dirty_chain() {
    let storage = make_storage();
    open_hashable_schema(&storage);

    let hub = Arc::new(DirtyChainHub::new());
    let rx = hub.subscribe();

    let config = HashOnWriteConfig {
        hashable_tables: HashSet::from(["hashable_items".to_string()]),
        hash_provider: Box::new(test_hash),
        parent_chain_provider: Box::new(test_parent_chain),
    };

    let hashing_store = HashingRowStore::new(
        storage.row_store(),
        config,
        Some(hub),
    );

    let id = uuid::Uuid::new_v4();
    let mut values = BTreeMap::new();
    values.insert("id".to_string(), TypedValue::Uuid(id));
    values.insert("content".to_string(), TypedValue::Text("hello".to_string()));

    let handle = hashing_store.insert("hashable_items", values).unwrap();
    assert_eq!(handle.key, id);

    let event = rx.recv().unwrap();
    assert_eq!(event.changed_row_id, id);
    assert_eq!(event.table, "hashable_items");
    let (expected_parent, expected_grandparent) = fixed_parent_ids();
    assert_eq!(event.parent_node_id, expected_parent);
    assert_eq!(event.grandparent_node_id, expected_grandparent);

    // Verify content_hash was persisted on the row.
    let rows = hashing_store.query("hashable_items", None, &[], None, None).unwrap();
    assert_eq!(rows.len(), 1);
    match rows[0].get("content_hash") {
        Some(TypedValue::Blob(bytes)) => assert_eq!(bytes.len(), 32, "ContentHash should be 32 bytes"),
        other => panic!("content_hash column missing or wrong type: {:?}", other),
    }
}

#[test]
fn insert_to_non_hashable_table_does_not_emit() {
    let storage = make_storage();
    open_hashable_schema(&storage);

    let hub = Arc::new(DirtyChainHub::new());
    let rx = hub.subscribe();

    let config = HashOnWriteConfig {
        hashable_tables: HashSet::from(["hashable_items".to_string()]),
        hash_provider: Box::new(test_hash),
        parent_chain_provider: Box::new(test_parent_chain),
    };

    let hashing_store = HashingRowStore::new(
        storage.row_store(),
        config,
        Some(hub),
    );

    let id = uuid::Uuid::new_v4();
    let mut values = BTreeMap::new();
    values.insert("id".to_string(), TypedValue::Uuid(id));
    values.insert("content".to_string(), TypedValue::Text("world".to_string()));

    hashing_store.insert("plain_items", values).unwrap();

    // Channel should be empty — no event emitted.
    assert!(rx.try_recv().is_err(), "Non-hashable table should not fire the hook");
}

#[test]
fn upsert_to_hashable_table_emits_dirty_chain() {
    let storage = make_storage();
    let schema = SchemaDeclaration::new(
        "HashTest",
        1,
        vec![TableDeclaration::new(
            "items",
            vec![
                ColumnDeclaration::uuid("id"),
                ColumnDeclaration::text("name"),
                ColumnDeclaration::blob("content_hash").nullable(),
            ],
            vec!["id".to_string()],
        ).hashable()],
    );
    storage.open(&schema).unwrap();

    let hub = Arc::new(DirtyChainHub::new());
    let rx = hub.subscribe();

    let config = HashOnWriteConfig {
        hashable_tables: HashSet::from(["items".to_string()]),
        hash_provider: Box::new(test_hash),
        parent_chain_provider: Box::new(test_parent_chain),
    };

    let hashing_store = HashingRowStore::new(
        storage.row_store(),
        config,
        Some(hub),
    );

    let id = uuid::Uuid::new_v4();
    let mut values = BTreeMap::new();
    values.insert("id".to_string(), TypedValue::Uuid(id));
    values.insert("name".to_string(), TypedValue::Text("original".to_string()));

    hashing_store.upsert("items", values, &["id".to_string()]).unwrap();
    let event = rx.recv().unwrap();
    assert_eq!(event.changed_row_id, id);

    // Upsert again (update path).
    let mut values2 = BTreeMap::new();
    values2.insert("id".to_string(), TypedValue::Uuid(id));
    values2.insert("name".to_string(), TypedValue::Text("updated".to_string()));
    hashing_store.upsert("items", values2, &["id".to_string()]).unwrap();
    let event2 = rx.recv().unwrap();
    assert_eq!(event2.changed_row_id, id);
}

#[test]
fn no_parent_chain_skips_emission_but_stores_hash() {
    let storage = make_storage();
    let schema = SchemaDeclaration::new(
        "HashTest",
        1,
        vec![TableDeclaration::new(
            "items",
            vec![
                ColumnDeclaration::uuid("id"),
                ColumnDeclaration::text("name"),
                ColumnDeclaration::blob("content_hash").nullable(),
            ],
            vec!["id".to_string()],
        ).hashable()],
    );
    storage.open(&schema).unwrap();

    let hub = Arc::new(DirtyChainHub::new());
    let rx = hub.subscribe();

    let config = HashOnWriteConfig {
        hashable_tables: HashSet::from(["items".to_string()]),
        hash_provider: Box::new(test_hash),
        parent_chain_provider: Box::new(no_parent_chain),
    };

    let hashing_store = HashingRowStore::new(
        storage.row_store(),
        config,
        Some(hub),
    );

    let id = uuid::Uuid::new_v4();
    let mut values = BTreeMap::new();
    values.insert("id".to_string(), TypedValue::Uuid(id));
    values.insert("name".to_string(), TypedValue::Text("orphan".to_string()));

    hashing_store.insert("items", values).unwrap();

    assert!(rx.try_recv().is_err(), "No parent chain should skip dirty-chain emission");

    // Hash should still be stored on the row even without parent chain.
    let rows = hashing_store.query("items", None, &[], None, None).unwrap();
    assert_eq!(rows.len(), 1);
    match rows[0].get("content_hash") {
        Some(TypedValue::Blob(bytes)) => assert_eq!(bytes.len(), 32, "ContentHash should be 32 bytes even without parent chain"),
        other => panic!("content_hash column missing — hash should be stored regardless of parent chain: {:?}", other),
    }
}

#[test]
fn hashable_field_defaults_false() {
    let table = TableDeclaration::new(
        "test",
        vec![ColumnDeclaration::uuid("id")],
        vec!["id".to_string()],
    );
    assert!(!table.hashable);

    let hashable_table = TableDeclaration::new(
        "test",
        vec![ColumnDeclaration::uuid("id")],
        vec!["id".to_string()],
    ).hashable();
    assert!(hashable_table.hashable);
}

#[test]
fn read_operations_pass_through() {
    let storage = make_storage();
    let schema = SchemaDeclaration::new(
        "HashTest",
        1,
        vec![TableDeclaration::new(
            "items",
            vec![
                ColumnDeclaration::uuid("id"),
                ColumnDeclaration::text("name"),
                ColumnDeclaration::blob("content_hash").nullable(),
            ],
            vec!["id".to_string()],
        ).hashable()],
    );
    storage.open(&schema).unwrap();

    let config = HashOnWriteConfig {
        hashable_tables: HashSet::from(["items".to_string()]),
        hash_provider: Box::new(test_hash),
        parent_chain_provider: Box::new(test_parent_chain),
    };

    let hashing_store = HashingRowStore::new(
        storage.row_store(),
        config,
        None,
    );

    let id = uuid::Uuid::new_v4();
    let mut values = BTreeMap::new();
    values.insert("id".to_string(), TypedValue::Uuid(id));
    values.insert("name".to_string(), TypedValue::Text("hello".to_string()));

    hashing_store.insert("items", values).unwrap();

    let rows = hashing_store.query("items", None, &[], None, None).unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].get("name"), Some(&TypedValue::Text("hello".to_string())));

    let count = hashing_store.count("items", None).unwrap();
    assert_eq!(count, 1);
}
