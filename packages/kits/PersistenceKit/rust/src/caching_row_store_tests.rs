//! Tests for CachingRowStore and CacheInvalidator.
//! Mirrors CachingRowStoreTests.swift — both ports must agree on all behaviors.
//!
//! Each test proves cache hit/miss by inserting a row into the backing store,
//! populating the cache via query, deleting directly from backing (bypassing
//! CachingRowStore), then querying again. A non-empty second result proves a
//! cache hit; an empty result proves the row was not cached (or was evicted).

use crate::cache_config::EstateCacheConfig;
use crate::cache_invalidator::CacheInvalidator;
use crate::caching_row_store::CachingRowStore;
use crate::inmemory::InMemoryStorage;
use crate::observer::StorageEvent;
use crate::predicate::StoragePredicate;
use crate::row_store::RowStore;
use crate::schema::{ColumnDeclaration, SchemaDeclaration, TableDeclaration};
use crate::storage::{BackendConfiguration, EstateConfiguration, Storage};
use crate::types::{Column, TypedValue};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

// ─────────────────────────────────────────────────────────────────
// Fixtures
// ─────────────────────────────────────────────────────────────────

fn make_schema() -> SchemaDeclaration {
    SchemaDeclaration::new(
        "CacheTest",
        1,
        vec![TableDeclaration::new(
            "things",
            vec![
                ColumnDeclaration::uuid("id"),
                ColumnDeclaration::text("name").nullable(),
                ColumnDeclaration::int("provenance").nullable(),
            ],
            vec!["id".to_string()],
        )],
    )
}

fn make_storage() -> InMemoryStorage {
    let id = uuid::Uuid::new_v4();
    let storage = InMemoryStorage::new(EstateConfiguration::new(
        id,
        BackendConfiguration::InMemory,
    ));
    storage.open(&make_schema()).expect("schema open");
    storage
}

fn make_caching(
    backing: Arc<dyn RowStore>,
    ceiling_bytes: i64,
    threshold: i32,
) -> Arc<CachingRowStore> {
    Arc::new(CachingRowStore::new(
        backing,
        EstateCacheConfig::new(true, ceiling_bytes, threshold),
    ))
}

/// Encode a sensitivity level into a provenance column value.
/// level = (raw >> 4) & 0x7  →  raw = level << 4
fn provenance(level: i64) -> TypedValue {
    TypedValue::Int(level << 4)
}

fn id_predicate(id: uuid::Uuid) -> StoragePredicate {
    StoragePredicate::Eq(
        Column::new("things", "id"),
        TypedValue::Uuid(id),
    )
}

fn row(id: uuid::Uuid, name: &str) -> BTreeMap<String, TypedValue> {
    let mut m = BTreeMap::new();
    m.insert("id".to_string(), TypedValue::Uuid(id));
    m.insert("name".to_string(), TypedValue::Text(name.to_string()));
    m
}

fn row_with_provenance(id: uuid::Uuid, name: &str, level: i64) -> BTreeMap<String, TypedValue> {
    let mut m = row(id, name);
    m.insert("provenance".to_string(), provenance(level));
    m
}

// ─────────────────────────────────────────────────────────────────
// Cache miss / hit
// ─────────────────────────────────────────────────────────────────

#[test]
fn cache_miss_falls_through_to_backing() {
    let storage = make_storage();
    let backing = storage.row_store();
    let caching = make_caching(backing.clone(), 10_000_000, 2);

    let id = uuid::Uuid::new_v4();
    backing.insert("things", row(id, "alice")).unwrap();

    let rows = caching
        .query("things", Some(&id_predicate(id)), &[], None, None)
        .unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].get("name"), Some(&TypedValue::Text("alice".to_string())));
}

#[test]
fn cache_miss_populates_hot_tier() {
    let storage = make_storage();
    let backing = storage.row_store();
    let caching = make_caching(backing.clone(), 10_000_000, 2);

    let id = uuid::Uuid::new_v4();
    let pred = id_predicate(id);
    backing.insert("things", row(id, "bob")).unwrap();

    // First query: miss → populates
    caching.query("things", Some(&pred), &[], None, None).unwrap();

    // Delete from backing directly (bypasses CachingRowStore)
    backing.delete("things", &pred).unwrap();

    // Second query: cache hit → returns pre-delete snapshot
    let hit = caching
        .query("things", Some(&pred), &[], None, None)
        .unwrap();
    assert_eq!(hit.len(), 1, "second query should hit the cache");
    assert_eq!(hit[0].get("name"), Some(&TypedValue::Text("bob".to_string())));
}

#[test]
fn cache_hit_matches_backing_result() {
    let storage = make_storage();
    let backing = storage.row_store();
    let caching = make_caching(backing.clone(), 10_000_000, 2);

    let id = uuid::Uuid::new_v4();
    let pred = id_predicate(id);
    backing.insert("things", row(id, "charlie")).unwrap();

    let from_backing = caching
        .query("things", Some(&pred), &[], None, None)
        .unwrap();
    let from_cache = caching
        .query("things", Some(&pred), &[], None, None)
        .unwrap();

    assert_eq!(from_backing.len(), from_cache.len());
    assert_eq!(from_backing[0].get("name"), from_cache[0].get("name"));
}

// ─────────────────────────────────────────────────────────────────
// Sensitivity gate
// ─────────────────────────────────────────────────────────────────

#[test]
fn no_provenance_column_admitted() {
    let storage = make_storage();
    let backing = storage.row_store();
    let caching = make_caching(backing.clone(), 10_000_000, 0);

    let id = uuid::Uuid::new_v4();
    let pred = id_predicate(id);
    // No provenance key in values → absent → admitted
    let mut values = BTreeMap::new();
    values.insert("id".to_string(), TypedValue::Uuid(id));
    values.insert("name".to_string(), TypedValue::Text("x".to_string()));
    backing.insert("things", values).unwrap();

    caching.query("things", Some(&pred), &[], None, None).unwrap();
    backing.delete("things", &pred).unwrap();
    let hit = caching
        .query("things", Some(&pred), &[], None, None)
        .unwrap();
    assert_eq!(hit.len(), 1, "absent provenance → admitted to cache");
}

#[test]
fn provenance_at_threshold_admitted() {
    let storage = make_storage();
    let backing = storage.row_store();
    let caching = make_caching(backing.clone(), 10_000_000, 1);

    let id = uuid::Uuid::new_v4();
    let pred = id_predicate(id);
    backing
        .insert("things", row_with_provenance(id, "y", 1))
        .unwrap();

    caching.query("things", Some(&pred), &[], None, None).unwrap();
    backing.delete("things", &pred).unwrap();
    let hit = caching
        .query("things", Some(&pred), &[], None, None)
        .unwrap();
    assert_eq!(hit.len(), 1, "level == threshold → admitted");
}

#[test]
fn provenance_above_threshold_rejected() {
    let storage = make_storage();
    let backing = storage.row_store();
    // threshold=0 → only Normal (level 0) admitted; Elevated (level 1) rejected
    let caching = make_caching(backing.clone(), 10_000_000, 0);

    let id = uuid::Uuid::new_v4();
    let pred = id_predicate(id);
    backing
        .insert("things", row_with_provenance(id, "elevated", 1))
        .unwrap();

    caching.query("things", Some(&pred), &[], None, None).unwrap();
    backing.delete("things", &pred).unwrap();

    let miss = caching
        .query("things", Some(&pred), &[], None, None)
        .unwrap();
    assert_eq!(miss.len(), 0, "level > threshold → not cached");
}

#[test]
fn provenance_secret_always_rejected() {
    let storage = make_storage();
    let backing = storage.row_store();
    // Even at maximum threshold=2, Secret (level 3) is always excluded
    let caching = make_caching(backing.clone(), 10_000_000, 2);

    let id = uuid::Uuid::new_v4();
    let pred = id_predicate(id);
    backing
        .insert("things", row_with_provenance(id, "secret", 3))
        .unwrap();

    caching.query("things", Some(&pred), &[], None, None).unwrap();
    backing.delete("things", &pred).unwrap();

    let miss = caching
        .query("things", Some(&pred), &[], None, None)
        .unwrap();
    assert_eq!(miss.len(), 0, "Secret always excluded from cache");
}

#[test]
fn unparseable_provenance_fails_closed() {
    let storage = make_storage();
    let backing = storage.row_store();
    let caching = make_caching(backing.clone(), 10_000_000, 2);

    let id = uuid::Uuid::new_v4();
    let pred = id_predicate(id);

    // TypedValue::Text for provenance is unparseable as Int64 → fail closed
    let mut values = row(id, "bad");
    values.insert(
        "provenance".to_string(),
        TypedValue::Text("not-an-int".to_string()),
    );
    backing.insert("things", values).unwrap();

    caching.query("things", Some(&pred), &[], None, None).unwrap();
    backing.delete("things", &pred).unwrap();

    let miss = caching
        .query("things", Some(&pred), &[], None, None)
        .unwrap();
    assert_eq!(miss.len(), 0, "unparseable provenance → fail closed");
}

// ─────────────────────────────────────────────────────────────────
// Write-through invalidation
// ─────────────────────────────────────────────────────────────────

#[test]
fn update_invalidates_cache_entry() {
    let storage = make_storage();
    let backing = storage.row_store();
    let caching = make_caching(backing.clone(), 10_000_000, 2);

    let id = uuid::Uuid::new_v4();
    let pred = id_predicate(id);
    backing.insert("things", row(id, "before")).unwrap();

    caching.query("things", Some(&pred), &[], None, None).unwrap();

    let mut update_vals = BTreeMap::new();
    update_vals.insert("name".to_string(), TypedValue::Text("after".to_string()));
    caching.update("things", update_vals, &pred).unwrap();

    let updated = caching
        .query("things", Some(&pred), &[], None, None)
        .unwrap();
    assert_eq!(updated.len(), 1);
    assert_eq!(
        updated[0].get("name"),
        Some(&TypedValue::Text("after".to_string()))
    );
}

#[test]
fn delete_invalidates_cache_entry() {
    let storage = make_storage();
    let backing = storage.row_store();
    let caching = make_caching(backing.clone(), 10_000_000, 2);

    let id = uuid::Uuid::new_v4();
    let pred = id_predicate(id);
    backing.insert("things", row(id, "exists")).unwrap();

    caching.query("things", Some(&pred), &[], None, None).unwrap();
    caching.delete("things", &pred).unwrap();

    let after = caching
        .query("things", Some(&pred), &[], None, None)
        .unwrap();
    assert_eq!(after.len(), 0, "deleted row must not be returned from cache");
}

#[test]
fn upsert_invalidates_cache_entry() {
    let storage = make_storage();
    let backing = storage.row_store();
    let caching = make_caching(backing.clone(), 10_000_000, 2);

    let id = uuid::Uuid::new_v4();
    let pred = id_predicate(id);
    backing.insert("things", row(id, "initial")).unwrap();

    caching.query("things", Some(&pred), &[], None, None).unwrap();

    let updated_row = row(id, "updated");
    caching
        .upsert("things", updated_row, &["id".to_string()])
        .unwrap();

    let after = caching
        .query("things", Some(&pred), &[], None, None)
        .unwrap();
    assert_eq!(after.len(), 1);
    assert_eq!(
        after[0].get("name"),
        Some(&TypedValue::Text("updated".to_string()))
    );
}

// ─────────────────────────────────────────────────────────────────
// StorageObserver-driven invalidation
// ─────────────────────────────────────────────────────────────────

#[test]
fn observer_event_invalidates_cache_entry() {
    let storage = make_storage();
    let backing = storage.row_store();
    let observer = storage.observer();
    let caching = make_caching(backing.clone(), 10_000_000, 2);

    let id = uuid::Uuid::new_v4();
    let pred = id_predicate(id);
    backing.insert("things", row(id, "cached")).unwrap();

    // Populate cache
    caching.query("things", Some(&pred), &[], None, None).unwrap();

    // Subscribe before the write so no events are missed
    let mut events = BTreeSet::new();
    events.insert(StorageEvent::Delete);
    let receiver = observer.observe("things", events).unwrap();
    let invalidator = CacheInvalidator::new(caching.clone(), receiver);

    // Delete directly via backing store (bypasses CachingRowStore)
    backing.delete("things", &pred).unwrap();

    // Drain pending events synchronously (Rust uses mpsc, no async needed)
    let count = invalidator.process_pending();
    assert_eq!(count, 1, "one delete event should have been processed");

    // Cache should be invalidated; backing has nothing → returns empty
    let after = caching
        .query("things", Some(&pred), &[], None, None)
        .unwrap();
    assert_eq!(after.len(), 0, "observer-driven invalidation cleared the cache");
}

// ─────────────────────────────────────────────────────────────────
// LRU eviction
// ─────────────────────────────────────────────────────────────────

#[test]
fn lru_eviction_fires_on_ceiling_exceeded() {
    let storage = make_storage();
    let backing = storage.row_store();

    // Row estimate: 64 overhead + "id"(2)+8 + UUID(24) + "name"(4)+8 + "alice"(5)+16 = 131
    // Ceiling = 200 → first row admitted, second evicts first.
    let caching = Arc::new(CachingRowStore::new(
        backing.clone(),
        EstateCacheConfig::new(true, 200, 2),
    ));

    let id_a = uuid::Uuid::new_v4();
    let id_b = uuid::Uuid::new_v4();
    let pred_a = id_predicate(id_a);
    let pred_b = id_predicate(id_b);

    backing.insert("things", row(id_a, "alice")).unwrap();
    backing.insert("things", row(id_b, "bob")).unwrap();

    // Populate A (LRU = A)
    caching.query("things", Some(&pred_a), &[], None, None).unwrap();
    // Populate B → ceiling exceeded → A evicted, B cached
    caching.query("things", Some(&pred_b), &[], None, None).unwrap();

    // Delete both from backing to distinguish cache hit from backing hit
    backing.delete("things", &pred_a).unwrap();
    backing.delete("things", &pred_b).unwrap();

    // B: still in cache → hit
    let result_b = caching
        .query("things", Some(&pred_b), &[], None, None)
        .unwrap();
    assert_eq!(result_b.len(), 1, "B was admitted last; still in cache");

    // A: evicted → miss → backing has nothing → empty
    let result_a = caching
        .query("things", Some(&pred_a), &[], None, None)
        .unwrap();
    assert_eq!(result_a.len(), 0, "A was evicted by LRU; backing returns nothing");
}

#[test]
fn evicted_row_falls_through_to_backing() {
    let storage = make_storage();
    let backing = storage.row_store();
    let caching = Arc::new(CachingRowStore::new(
        backing.clone(),
        EstateCacheConfig::new(true, 200, 2),
    ));

    let id_a = uuid::Uuid::new_v4();
    let id_b = uuid::Uuid::new_v4();
    let pred_a = id_predicate(id_a);
    let pred_b = id_predicate(id_b);

    backing.insert("things", row(id_a, "first")).unwrap();
    backing.insert("things", row(id_b, "second")).unwrap();

    // Populate A, then B. A gets evicted. Backing still has both rows.
    caching.query("things", Some(&pred_a), &[], None, None).unwrap();
    caching.query("things", Some(&pred_b), &[], None, None).unwrap();

    // A was evicted but the backing store still has it → fall through returns it
    let result_a = caching
        .query("things", Some(&pred_a), &[], None, None)
        .unwrap();
    assert_eq!(result_a.len(), 1, "evicted row still readable via backing store");
    assert_eq!(
        result_a[0].get("name"),
        Some(&TypedValue::Text("first".to_string()))
    );
}
