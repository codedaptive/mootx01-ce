//! Wiring tests: each Rust backend conditionally wraps `row_store()` with
//! `CachingRowStore` when `EstateConfiguration.cache_config.enabled` is true
//! and returns the plain backing store when false (the default).
//!
//! Mirrors the intent of PK-CACHE-C1 (Swift backends). Cross-port parity
//! means both the enabled and disabled paths behave identically to the Swift
//! versions from the caller's perspective.
//!
//! Behavioral proof: a CachingRowStore is in use when a second `row_store()`
//! handle deletes a row from the shared backing state, yet an earlier handle
//! still returns a stale cache hit. Without the cache the deletion is
//! immediately visible to all handles because they read straight through to
//! the shared state.

use crate::cache_config::EstateCacheConfig;
use crate::encryption::EstateEncryptionConfig;
use crate::inmemory::InMemoryStorage;
use crate::predicate::StoragePredicate;
use crate::schema::{ColumnDeclaration, SchemaDeclaration, TableDeclaration};
use crate::sqlite::SqliteStorage;
use crate::storage::{BackendConfiguration, EstateConfiguration, Storage};
use crate::types::{Column, TypedValue};
use std::collections::BTreeMap;
use uuid::Uuid;

// ─────────────────────────────────────────────────────────────────
// Shared fixtures
// ─────────────────────────────────────────────────────────────────

fn wiring_schema() -> SchemaDeclaration {
    SchemaDeclaration::new(
        "WiringTest",
        1,
        vec![TableDeclaration::new(
            "items",
            vec![
                ColumnDeclaration::uuid("id"),
                ColumnDeclaration::text("label").nullable(),
            ],
            vec!["id".to_string()],
        )],
    )
}

fn item_row(id: Uuid, label: &str) -> BTreeMap<String, TypedValue> {
    let mut m = BTreeMap::new();
    m.insert("id".to_string(), TypedValue::Uuid(id));
    m.insert("label".to_string(), TypedValue::Text(label.to_string()));
    m
}

fn id_predicate(id: Uuid) -> StoragePredicate {
    StoragePredicate::Eq(Column::new("items", "id"), TypedValue::Uuid(id))
}

// ─────────────────────────────────────────────────────────────────
// InMemoryStorage wiring tests
// ─────────────────────────────────────────────────────────────────

fn make_inmemory(cache_enabled: bool) -> InMemoryStorage {
    let config = EstateConfiguration {
        estate_id: Uuid::new_v4(),
        backend: BackendConfiguration::InMemory,
        // Plaintext mode: the cache-wiring tests do not exercise encryption.
        encryption_config: EstateEncryptionConfig::plaintext(),
        // When enabled: 10 MiB ceiling, sensitivity threshold 2 (max non-Secret).
        // When disabled: disabled() is the zero-change default.
        cache_config: if cache_enabled {
            EstateCacheConfig::new(true, 10_000_000, 2)
        } else {
            EstateCacheConfig::disabled()
        },
        // HMM is the default and the only valid choice on Rust.
        novel_token_tagger: crate::storage::NovelTokenTaggerChoice::Hmm,
    };
    let storage = InMemoryStorage::new(config);
    storage.open(&wiring_schema()).expect("inmemory schema open");
    storage
}

/// Disabled: deletion via a second handle is immediately visible to the first
/// handle — no caching is in effect.
#[test]
fn inmemory_disabled_no_caching() {
    let storage = make_inmemory(false);
    let store_a = storage.row_store();
    let store_b = storage.row_store();

    let id = Uuid::new_v4();
    store_a.insert("items", item_row(id, "alpha")).unwrap();

    // Populate: query via store_a fills any potential cache.
    let found = store_a
        .query("items", Some(&id_predicate(id)), &[], None, None)
        .unwrap();
    assert_eq!(found.len(), 1);

    // Delete via store_b — goes to backing state.
    store_b
        .delete("items", &id_predicate(id))
        .unwrap();

    // Without a cache, store_a reads straight through and sees the deletion.
    let after_delete = store_a
        .query("items", Some(&id_predicate(id)), &[], None, None)
        .unwrap();
    assert_eq!(after_delete.len(), 0, "disabled: deletion must be immediately visible");
}

/// Enabled: deletion via a second handle does NOT invalidate the first handle's
/// cache — a stale hit proves CachingRowStore is wired.
#[test]
fn inmemory_enabled_caches_rows() {
    let storage = make_inmemory(true);
    let store_a = storage.row_store(); // CachingRowStore #1, empty cache
    let store_b = storage.row_store(); // CachingRowStore #2, separate empty cache

    let id = Uuid::new_v4();
    store_a.insert("items", item_row(id, "beta")).unwrap();

    // First query via store_a: cache miss → backing store → admits to cache #1.
    let found = store_a
        .query("items", Some(&id_predicate(id)), &[], None, None)
        .unwrap();
    assert_eq!(found.len(), 1);

    // Delete via store_b: goes to backing (shared state). Cache #1 is NOT
    // invalidated because store_b has no knowledge of store_a's cache.
    store_b
        .delete("items", &id_predicate(id))
        .unwrap();

    // Second query via store_a: cache #1 still holds the row → stale hit.
    // This proves CachingRowStore is wired: a plain RowStore would return 0.
    let stale = store_a
        .query("items", Some(&id_predicate(id)), &[], None, None)
        .unwrap();
    assert_eq!(stale.len(), 1, "enabled: stale cache hit proves CachingRowStore is wired");
}

/// Both modes produce identical results for a simple insert + query sequence.
#[test]
fn inmemory_both_modes_produce_identical_query_results() {
    for enabled in [false, true] {
        let storage = make_inmemory(enabled);
        let store = storage.row_store();
        let id = Uuid::new_v4();

        store.insert("items", item_row(id, "gamma")).unwrap();
        let rows = store
            .query("items", Some(&id_predicate(id)), &[], None, None)
            .unwrap();
        assert_eq!(rows.len(), 1, "enabled={enabled}: insert+query must return 1 row");
        assert_eq!(
            rows[0].get("label"),
            Some(&TypedValue::Text("gamma".to_string())),
            "enabled={enabled}: label must match"
        );
    }
}

/// Count is consistent whether cache is on or off.
#[test]
fn inmemory_count_consistent_across_modes() {
    for enabled in [false, true] {
        let storage = make_inmemory(enabled);
        let store = storage.row_store();

        for i in 0..3u32 {
            store
                .insert("items", item_row(Uuid::new_v4(), &format!("item-{i}")))
                .unwrap();
        }
        let n = store.count("items", None).unwrap();
        assert_eq!(n, 3, "enabled={enabled}: count must be 3 after 3 inserts");
    }
}

// ─────────────────────────────────────────────────────────────────
// SqliteStorage wiring tests
// ─────────────────────────────────────────────────────────────────

fn make_sqlite(cache_enabled: bool) -> SqliteStorage {
    let path = std::env::temp_dir()
        .join(format!("pk_wire_{}.sqlite", Uuid::new_v4()));
    let config = EstateConfiguration {
        estate_id: Uuid::new_v4(),
        backend: BackendConfiguration::Sqlite {
            path: path.to_string_lossy().into_owned(),
            busy_timeout_secs: 5.0,
        },
        // Plaintext mode: the cache-wiring tests do not exercise encryption.
        encryption_config: EstateEncryptionConfig::plaintext(),
        cache_config: if cache_enabled {
            EstateCacheConfig::new(true, 10_000_000, 2)
        } else {
            EstateCacheConfig::disabled()
        },
        // HMM is the default and the only valid choice on Rust.
        novel_token_tagger: crate::storage::NovelTokenTaggerChoice::Hmm,
    };
    let storage = SqliteStorage::new(config).expect("sqlite open");
    storage.open(&wiring_schema()).expect("sqlite schema open");
    storage
}

/// Disabled: deletion is immediately visible (no cache layer).
#[test]
fn sqlite_disabled_no_caching() {
    let storage = make_sqlite(false);
    let store_a = storage.row_store();
    let store_b = storage.row_store();

    let id = Uuid::new_v4();
    store_a.insert("items", item_row(id, "alpha")).unwrap();
    store_a
        .query("items", Some(&id_predicate(id)), &[], None, None)
        .unwrap();

    store_b.delete("items", &id_predicate(id)).unwrap();

    let after = store_a
        .query("items", Some(&id_predicate(id)), &[], None, None)
        .unwrap();
    assert_eq!(after.len(), 0, "sqlite disabled: deletion must be immediately visible");
}

/// Enabled: stale cache hit proves CachingRowStore is wired.
#[test]
fn sqlite_enabled_caches_rows() {
    let storage = make_sqlite(true);
    let store_a = storage.row_store(); // CachingRowStore #1
    let store_b = storage.row_store(); // CachingRowStore #2, separate cache

    let id = Uuid::new_v4();
    store_a.insert("items", item_row(id, "beta")).unwrap();

    // Cache miss → populates cache #1.
    store_a
        .query("items", Some(&id_predicate(id)), &[], None, None)
        .unwrap();

    // Delete via store_b → backing state updated; cache #1 unaware.
    store_b.delete("items", &id_predicate(id)).unwrap();

    let stale = store_a
        .query("items", Some(&id_predicate(id)), &[], None, None)
        .unwrap();
    assert_eq!(stale.len(), 1, "sqlite enabled: stale cache hit proves CachingRowStore is wired");
}

/// Insert + query results are identical in both modes.
#[test]
fn sqlite_both_modes_produce_identical_query_results() {
    for enabled in [false, true] {
        let storage = make_sqlite(enabled);
        let store = storage.row_store();
        let id = Uuid::new_v4();

        store.insert("items", item_row(id, "gamma")).unwrap();
        let rows = store
            .query("items", Some(&id_predicate(id)), &[], None, None)
            .unwrap();
        assert_eq!(rows.len(), 1, "sqlite enabled={enabled}: must return 1 row");
        assert_eq!(
            rows[0].get("label"),
            Some(&TypedValue::Text("gamma".to_string())),
            "sqlite enabled={enabled}: label must match"
        );
    }
}

/// Count is consistent whether cache is on or off (mirrors InMemory parity test).
#[test]
fn sqlite_count_consistent_across_modes() {
    for enabled in [false, true] {
        let storage = make_sqlite(enabled);
        let store = storage.row_store();

        for i in 0..3u32 {
            store
                .insert("items", item_row(Uuid::new_v4(), &format!("item-{i}")))
                .unwrap();
        }
        let n = store.count("items", None).unwrap();
        assert_eq!(n, 3, "sqlite enabled={enabled}: count must be 3 after 3 inserts");
    }
}
