//! Tests for CachingRowStore and CacheInvalidator.
//! Mirrors CachingRowStoreTests.swift — both ports must agree on all behaviors.
//!
//! Cache-miss/hit and sensitivity tests prove cache behaviour by inserting a
//! row into the backing store, populating the cache via query, deleting directly
//! from backing (bypassing CachingRowStore), then querying again. A non-empty
//! second result proves a cache hit; an empty result proves miss or eviction.
//! Write-through (update/delete/upsert via CachingRowStore) and observer-driven
//! invalidation tests work differently: they mutate through the caching layer or
//! fire a change event and verify the cache is cleared without backing-store deletion.

use crate::cache_config::EstateCacheConfig;
use crate::cache_invalidator::CacheInvalidator;
use crate::caching_row_store::{CachingRowStore, ParentChainProvider};
use crate::inmemory::InMemoryStorage;
use crate::observer::StorageEvent;
use crate::predicate::StoragePredicate;
use crate::row_store::RowStore;
use crate::schema::{ColumnDeclaration, SchemaDeclaration, TableDeclaration};
use crate::storage::{BackendConfiguration, EstateConfiguration, Storage};
use crate::types::{Column, RowHandle, TypedValue};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;
use substrate_types::{AsOfCoordinate, HLC};

// ─────────────────────────────────────────────────────────────────
// Fixtures
// ─────────────────────────────────────────────────────────────────

fn make_schema() -> SchemaDeclaration {
    SchemaDeclaration::new(
        "CacheTest",
        1,
        vec![
            TableDeclaration::new(
                "things",
                vec![
                    ColumnDeclaration::uuid("id"),
                    ColumnDeclaration::text("name").nullable(),
                    ColumnDeclaration::int("provenance").nullable(),
                ],
                vec!["id".to_string()],
            ),
            TableDeclaration::new(
                "nodes",
                vec![
                    ColumnDeclaration::uuid("id"),
                    ColumnDeclaration::text("merkle_root").nullable(),
                ],
                vec!["id".to_string()],
            ),
        ],
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

/// Encode a sensitivity ordinal into the provenance bitmap column value.
/// Ordinals: 0=Normal, 1=Elevated, 2=Restricted, 3=Secret — matching the
/// `Sensitivity` cases in LocusKit's Provenance.swift. Sensitivity lives in
/// bits 30–35 of the provenance bitmap (scale-gapped per cookbook §2.5 v0.6:
/// Normal=0, Elevated=16, Restricted=32, Secret=48).
fn provenance(level: i64) -> TypedValue {
    TypedValue::Int((level * 16) << 30)  // ordinal → scale-gapped raw at bits 30–35
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

#[test]
fn old_bit_position_treated_as_normal_admitted() {
    // Regression: before the fix, the gate decoded (raw >> 4) & 0x7 (bits [5:4]).
    // A value of 3 << 4 = 48 would have looked like Secret and been rejected.
    // After the fix the gate reads bits 30–35; value 48 in the low bits leaves
    // bits 30–35 as 0 (Normal, ordinal 0), so the row is admitted.
    let storage = make_storage();
    let backing = storage.row_store();
    let caching = make_caching(backing.clone(), 10_000_000, 2);

    let id = uuid::Uuid::new_v4();
    let pred = id_predicate(id);

    // Old-style encoding: secret level at bits [5:4], NOT at bits 30–35
    let old_style_secret = TypedValue::Int(3_i64 << 4); // 48, bits 30–35 = 0 (Normal)
    let mut values = row(id, "old-encoding");
    values.insert("provenance".to_string(), old_style_secret);
    backing.insert("things", values).unwrap();

    caching.query("things", Some(&pred), &[], None, None).unwrap();
    backing.delete("things", &pred).unwrap();

    // bits 30–35 are 0 (Normal) → ordinal 0 ≤ threshold 2 → admitted
    let result = caching
        .query("things", Some(&pred), &[], None, None)
        .unwrap();
    assert_eq!(
        result.len(), 1,
        "bits 30–35 are 0 (Normal) at old-style encoding; row must be admitted"
    );
}

#[test]
fn secret_at_correct_bits_always_rejected() {
    // Regression: verify the gate reads the right bit field. Secret raw = 48;
    // at bits 30–35 that is 48_i64 << 30. Must be rejected at any threshold.
    let storage = make_storage();
    let backing = storage.row_store();
    let caching = make_caching(backing.clone(), 10_000_000, 2);

    let id = uuid::Uuid::new_v4();
    let pred = id_predicate(id);

    let correct_secret = TypedValue::Int(48_i64 << 30); // Secret at bits 30–35
    let mut values = row(id, "secret-at-correct-bits");
    values.insert("provenance".to_string(), correct_secret);
    backing.insert("things", values).unwrap();

    caching.query("things", Some(&pred), &[], None, None).unwrap();
    backing.delete("things", &pred).unwrap();

    let result = caching
        .query("things", Some(&pred), &[], None, None)
        .unwrap();
    assert_eq!(
        result.len(), 0,
        "Secret encoded at bits 30–35 must never be admitted to the cache"
    );
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

// ─────────────────────────────────────────────────────────────────
// Temporal cache key isolation (Part 1)
// ─────────────────────────────────────────────────────────────────

fn node_id_predicate(id: uuid::Uuid) -> StoragePredicate {
    StoragePredicate::Eq(
        Column::new("nodes", "id"),
        TypedValue::Uuid(id),
    )
}

fn node_row(id: uuid::Uuid, merkle_root: &str) -> BTreeMap<String, TypedValue> {
    let mut m = BTreeMap::new();
    m.insert("id".to_string(), TypedValue::Uuid(id));
    m.insert("merkle_root".to_string(), TypedValue::Text(merkle_root.to_string()));
    m
}

#[test]
fn present_and_as_of_are_distinct_cache_entries() {
    let storage = make_storage();
    let backing = storage.row_store();
    let caching = make_caching(backing.clone(), 10_000_000, 2);

    let id = uuid::Uuid::new_v4();
    let pred = id_predicate(id);
    let hlc = HLC::new(1000, 0, 1);
    backing.insert("things", row(id, "live")).unwrap();

    // Present query: populates cache under .Present coordinate
    let present = caching
        .query("things", Some(&pred), &[], None, None)
        .unwrap();
    assert_eq!(present.len(), 1);
    assert_eq!(present[0].get("name"), Some(&TypedValue::Text("live".to_string())));

    // As-of query: feature-gated, so it returns an error.
    // The present cache entry must NOT be returned for an as-of query.
    let as_of_result = caching.query_as_of(
        "things", Some(&pred), &[], None, None,
        Some(AsOfCoordinate::AsOf(hlc)),
    );
    assert!(
        as_of_result.is_err(),
        "as-of query should hit backing (feature-gated), not return the present cache entry"
    );
    let err_msg = format!("{:?}", as_of_result.unwrap_err());
    assert!(err_msg.contains("FeatureGated"), "expected FeatureGated error, got: {}", err_msg);
}

#[test]
fn repeated_present_queries_hit_cache() {
    let storage = make_storage();
    let backing = storage.row_store();
    let caching = make_caching(backing.clone(), 10_000_000, 2);

    let id = uuid::Uuid::new_v4();
    let pred = id_predicate(id);
    backing.insert("things", row(id, "cached")).unwrap();

    // First: miss → populate
    caching.query("things", Some(&pred), &[], None, None).unwrap();

    // Delete from backing (bypass cache)
    backing.delete("things", &pred).unwrap();

    // Second: hit → returns pre-delete value
    let hit = caching
        .query("things", Some(&pred), &[], None, None)
        .unwrap();
    assert_eq!(hit.len(), 1);
    assert_eq!(hit[0].get("name"), Some(&TypedValue::Text("cached".to_string())));
}

#[test]
fn write_invalidates_only_present_entries() {
    let storage = make_storage();
    let backing = storage.row_store();
    let caching = make_caching(backing.clone(), 10_000_000, 2);

    let id = uuid::Uuid::new_v4();
    let pred = id_predicate(id);
    backing.insert("things", row(id, "value")).unwrap();

    // Populate present cache entry
    caching.query("things", Some(&pred), &[], None, None).unwrap();

    // Update through CachingRowStore → invalidates present entry
    let mut update_vals = BTreeMap::new();
    update_vals.insert("name".to_string(), TypedValue::Text("new".to_string()));
    caching.update("things", update_vals, &pred).unwrap();

    // Present entry was invalidated → falls through to backing
    let after = caching
        .query("things", Some(&pred), &[], None, None)
        .unwrap();
    assert_eq!(after.len(), 1);
    assert_eq!(after[0].get("name"), Some(&TypedValue::Text("new".to_string())));
}

#[test]
fn nil_as_of_is_present_query() {
    let storage = make_storage();
    let backing = storage.row_store();
    let caching = make_caching(backing.clone(), 10_000_000, 2);

    let id = uuid::Uuid::new_v4();
    let pred = id_predicate(id);
    backing.insert("things", row(id, "live")).unwrap();

    // None as_of → present query → populates cache
    let rows = caching
        .query_as_of("things", Some(&pred), &[], None, None, None)
        .unwrap();
    assert_eq!(rows.len(), 1);

    // Delete from backing
    backing.delete("things", &pred).unwrap();

    // Non-temporal query should hit the same cache entry
    let hit = caching
        .query("things", Some(&pred), &[], None, None)
        .unwrap();
    assert_eq!(hit.len(), 1, "None as_of and base query share the .Present cache entry");
}

#[test]
fn present_as_of_is_base_query() {
    let storage = make_storage();
    let backing = storage.row_store();
    let caching = make_caching(backing.clone(), 10_000_000, 2);

    let id = uuid::Uuid::new_v4();
    let pred = id_predicate(id);
    backing.insert("things", row(id, "live")).unwrap();

    // Populate via base query (no as_of)
    caching.query("things", Some(&pred), &[], None, None).unwrap();

    // Delete from backing
    backing.delete("things", &pred).unwrap();

    // Explicit Present as_of should hit the same entry
    let hit = caching
        .query_as_of("things", Some(&pred), &[], None, None, Some(AsOfCoordinate::Present))
        .unwrap();
    assert_eq!(hit.len(), 1, ".Present as_of shares the base query cache entry");
}

// ─────────────────────────────────────────────────────────────────
// Parent-chain invalidation (Part 2)
// ─────────────────────────────────────────────────────────────────

#[test]
fn write_evicts_parent_chain() {
    let storage = make_storage();
    let backing = storage.row_store();

    let room_id = uuid::Uuid::new_v4();
    let wing_id = uuid::Uuid::new_v4();

    // Parent-chain callback: for any write, returns room and wing
    // as parents whose cached aggregates should be invalidated.
    let provider: ParentChainProvider = Box::new(move |_table, _key| {
        vec![
            RowHandle::new("nodes", room_id),
            RowHandle::new("nodes", wing_id),
        ]
    });

    let caching = Arc::new(CachingRowStore::with_parent_chain(
        backing.clone(),
        EstateCacheConfig::new(true, 10_000_000, 2),
        provider,
    ));

    // Insert parent nodes and populate their cache entries
    backing.insert("nodes", node_row(room_id, "room-hash")).unwrap();
    backing.insert("nodes", node_row(wing_id, "wing-hash")).unwrap();

    let room_pred = node_id_predicate(room_id);
    let wing_pred = node_id_predicate(wing_id);

    caching.query("nodes", Some(&room_pred), &[], None, None).unwrap();
    caching.query("nodes", Some(&wing_pred), &[], None, None).unwrap();

    // Update parent node values in backing directly (simulating a
    // re-computed Merkle root that hasn't gone through CachingRowStore)
    let mut room_update = BTreeMap::new();
    room_update.insert("merkle_root".to_string(), TypedValue::Text("room-hash-v2".to_string()));
    backing.update("nodes", room_update, &room_pred).unwrap();

    let mut wing_update = BTreeMap::new();
    wing_update.insert("merkle_root".to_string(), TypedValue::Text("wing-hash-v2".to_string()));
    backing.update("nodes", wing_update, &wing_pred).unwrap();

    // Insert a child row through CachingRowStore — triggers parent-chain
    // callback which evicts room and wing cache entries
    let child_id = uuid::Uuid::new_v4();
    caching.insert("things", row(child_id, "child")).unwrap();

    // Room and wing cache entries should be evicted; next query falls
    // through to backing store which has the updated values
    let room_after = caching
        .query("nodes", Some(&room_pred), &[], None, None)
        .unwrap();
    assert_eq!(room_after.len(), 1);
    assert_eq!(
        room_after[0].get("merkle_root"),
        Some(&TypedValue::Text("room-hash-v2".to_string())),
        "room cache entry evicted by parent-chain invalidation"
    );

    let wing_after = caching
        .query("nodes", Some(&wing_pred), &[], None, None)
        .unwrap();
    assert_eq!(wing_after.len(), 1);
    assert_eq!(
        wing_after[0].get("merkle_root"),
        Some(&TypedValue::Text("wing-hash-v2".to_string())),
        "wing cache entry evicted by parent-chain invalidation"
    );
}

#[test]
fn write_without_callback_no_chain_invalidation() {
    let storage = make_storage();
    let backing = storage.row_store();

    // No parent-chain provider — backward-compatible behavior
    let caching = make_caching(backing.clone(), 10_000_000, 2);

    let node_id = uuid::Uuid::new_v4();
    backing.insert("nodes", node_row(node_id, "hash-v1")).unwrap();
    let node_pred = node_id_predicate(node_id);

    // Populate node cache entry
    caching.query("nodes", Some(&node_pred), &[], None, None).unwrap();

    // Insert a child row (no callback registered)
    let child_id = uuid::Uuid::new_v4();
    caching.insert("things", row(child_id, "child")).unwrap();

    // Delete node from backing to test whether cache entry survives
    backing.delete("nodes", &node_pred).unwrap();

    // Node cache entry should still be present (not evicted)
    let node_after = caching
        .query("nodes", Some(&node_pred), &[], None, None)
        .unwrap();
    assert_eq!(node_after.len(), 1, "no callback → node cache entry survives");
    assert_eq!(
        node_after[0].get("merkle_root"),
        Some(&TypedValue::Text("hash-v1".to_string()))
    );
}

#[test]
fn external_invalidation_fires_parent_chain() {
    let storage = make_storage();
    let backing = storage.row_store();

    let room_id = uuid::Uuid::new_v4();
    let provider: ParentChainProvider = Box::new(move |_table, _key| {
        vec![RowHandle::new("nodes", room_id)]
    });

    let caching = Arc::new(CachingRowStore::with_parent_chain(
        backing.clone(),
        EstateCacheConfig::new(true, 10_000_000, 2),
        provider,
    ));

    // Insert and cache the room node
    backing.insert("nodes", node_row(room_id, "hash")).unwrap();
    let room_pred = node_id_predicate(room_id);
    caching.query("nodes", Some(&room_pred), &[], None, None).unwrap();

    // Update room in backing directly
    let mut update = BTreeMap::new();
    update.insert("merkle_root".to_string(), TypedValue::Text("hash-v2".to_string()));
    backing.update("nodes", update, &room_pred).unwrap();

    // External invalidation (simulating CacheInvalidator path)
    let child_id = uuid::Uuid::new_v4();
    caching.invalidate("things", Some(child_id));

    // Room cache should be evicted
    let room_after = caching
        .query("nodes", Some(&room_pred), &[], None, None)
        .unwrap();
    assert_eq!(
        room_after[0].get("merkle_root"),
        Some(&TypedValue::Text("hash-v2".to_string())),
        "external invalidation also fires parent-chain callback"
    );
}

#[test]
fn all_backends_temporal_key_isolation() {
    // InMemory backend test (SQLite and PostgreSQL are structurally
    // identical because CachingRowStore is the same decorator over any
    // RowStore — the backend does not affect cache key logic).
    let storage = make_storage();
    let backing = storage.row_store();
    let caching = make_caching(backing.clone(), 10_000_000, 2);

    let id = uuid::Uuid::new_v4();
    let pred = id_predicate(id);
    backing.insert("things", row(id, "val")).unwrap();

    // Populate .Present entry
    let present = caching
        .query("things", Some(&pred), &[], None, None)
        .unwrap();
    assert_eq!(present.len(), 1);

    // Delete from backing
    backing.delete("things", &pred).unwrap();

    // .Present cache hit
    let hit = caching
        .query("things", Some(&pred), &[], None, None)
        .unwrap();
    assert_eq!(hit.len(), 1, "present cache entry survives backing delete");

    // .AsOf query goes to backing (gated) — does NOT return the present entry
    let as_of_result = caching.query_as_of(
        "things", Some(&pred), &[], None, None,
        Some(AsOfCoordinate::AsOf(HLC::new(500, 0, 1))),
    );
    assert!(as_of_result.is_err(), "as-of query hits backing store, not the present cache entry");
}
