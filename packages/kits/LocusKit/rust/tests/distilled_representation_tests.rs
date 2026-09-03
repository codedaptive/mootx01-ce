//! Bit-column agreement tests for the `has_current_representation` bit
//! (bit 19 of `operational_bitmap`) and the five distillation columns.
//!
//! Per SPEC_DISTILLATION_STORAGE §4 and cookbook §2.4.1: the bit and the
//! five columns (`distilled`, `distilled_pipeline_version`,
//! `distilled_token_count`, `distilled_at`, `distilled_source_digest`) are
//! ALWAYS in agreement — they travel in the SAME SQL UPDATE for every set
//! and clear path. The digest half of the currency rule is pinned here too:
//! a NULL digest is stale, and the current-rows projection excludes it.
//!
//! Twin-parity mirror of Swift `DistilledRepresentationTests` (the tests
//! added for the has_current_representation rider).
//!
//! Uses `InMemoryDrawerStore` because it is the single source of the real
//! `set_distilled_representation` / `count_undistilled` / expunge logic
//! (SQLite and Postgres wrappers delegate to it). The in-memory backend is
//! synchronous and deterministic, so these tests are fast and artifact-free.

use std::collections::BTreeMap;
use std::sync::Arc;

use locus_kit::drawer::Drawer;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::schema::{schema, KIT_ID, SCHEMA_VERSION};
use persistence_kit::predicate::StoragePredicate;
use persistence_kit::schema::{SchemaDeclaration, TableDeclaration};
use persistence_kit::sqlite::SqliteStorage;
use persistence_kit::storage::{BackendConfiguration, EstateConfiguration};
use persistence_kit::types::{Column, TypedValue};
use persistence_kit::Storage;
use uuid::Uuid;

const NOW: i64 = 1_700_000_000;
const PIPELINE_V1: &str = "p1";
const PIPELINE_V2: &str = "p2";
const DIGEST: &str = "digest-of-content";
const TEST_PARENT: &str = "00000000-0000-4000-8000-000000000001";
const DIGEST_COLUMN: &str = "distilled_source_digest";

fn new_store() -> InMemoryDrawerStore {
    InMemoryDrawerStore::new(NOW, None).expect("store init")
}

fn make_id() -> String {
    Uuid::new_v4().to_string()
}

fn sample_drawer(id: &str) -> Drawer {
    let mut d = Drawer::new(
        id,
        "The quarterly planning meeting moved to Thursday. Sarah sends invites Monday.",
        TEST_PARENT,
        "bilby",
        NOW,
        "test-v1",
    );
    // udc_code is required by the gate for expunge paths.
    d.udc_code = "001".to_string();
    d
}

/// Assert that bit 19 and the `distilled` column agree for `drawer_id`.
fn assert_bit_column_agree(store: &InMemoryDrawerStore, drawer_id: &str, expect_populated: bool) {
    let d = store
        .get_drawer(drawer_id)
        .expect("get_drawer")
        .unwrap_or_else(|| panic!("drawer {drawer_id} must exist"));
    let bit = d.has_current_representation();
    let col = d.distilled.is_some();
    assert_eq!(
        d.distilled_source_digest.is_some(),
        expect_populated,
        "distilled_source_digest travels with the quad for drawer {drawer_id}"
    );
    assert_eq!(
        bit, expect_populated,
        "bit 19 should be {} for drawer {}: operational_bitmap={:#x}",
        expect_populated, drawer_id, d.operational_bitmap
    );
    assert_eq!(
        col, expect_populated,
        "distilled column should be {} for drawer {}",
        if expect_populated { "populated" } else { "nil" },
        drawer_id
    );
    assert_eq!(
        bit, col,
        "§4 invariant violated: bit 19 and distilled column disagree for drawer {}",
        drawer_id
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[test]
fn fresh_row_bit_19_clear() {
    // A freshly inserted drawer must have bit 19 clear (cookbook §2.4.1).
    let store = new_store();
    let id = make_id();
    store.add_drawer(&sample_drawer(&id), NOW).expect("add");
    assert_bit_column_agree(&store, &id, false);
}

#[test]
fn set_distilled_representation_sets_bit_19() {
    // After set_distilled_representation, bit 19 must be set alongside the
    // four populated columns (§4 invariant: same-statement write).
    let store = new_store();
    let id = make_id();
    store.add_drawer(&sample_drawer(&id), NOW).expect("add");
    let n = store
        .set_distilled_representation(&id, "some rendering", PIPELINE_V1, DIGEST, 3, NOW + 100)
        .expect("set_distilled");
    assert_eq!(n, 1, "should have updated exactly one row");
    assert_bit_column_agree(&store, &id, true);
}

#[test]
fn set_distilled_representation_unknown_id_returns_zero() {
    // Calling set_distilled_representation on a non-existent row must return 0
    // (mirrors Swift guard-let early return when row not found).
    let store = new_store();
    let missing = make_id();
    let n = store
        .set_distilled_representation(&missing, "x", PIPELINE_V1, DIGEST, 1, NOW)
        .expect("set_distilled on missing row");
    assert_eq!(n, 0);
}

#[test]
fn expunge_clears_bit_19_on_head_drawer() {
    // expunge_gated must clear bit 19 alongside the four NULL columns on the
    // head drawer (cookbook §2.4.1 — same-statement clear).
    let store = new_store();
    let id = make_id();
    store.add_drawer(&sample_drawer(&id), NOW).expect("add");
    store
        .set_distilled_representation(&id, "rendering", PIPELINE_V1, DIGEST, 2, NOW + 100)
        .expect("set_distilled");
    assert_bit_column_agree(&store, &id, true);

    store
        .expunge_gated(&id, "test", None, NOW + 200, false)
        .expect("expunge_gated");
    assert_bit_column_agree(&store, &id, false);
}

#[test]
fn bit_19_lifecycle_set_clear_reset() {
    // Full lifecycle: insert (clear) → distill (set) → expunge (clear).
    let store = new_store();
    let id = make_id();
    store.add_drawer(&sample_drawer(&id), NOW).expect("add");

    // Insert: clear.
    assert_bit_column_agree(&store, &id, false);

    // Distill: set.
    store
        .set_distilled_representation(&id, "rendering one", PIPELINE_V1, DIGEST, 2, NOW + 100)
        .expect("set_distilled");
    assert_bit_column_agree(&store, &id, true);

    // Expunge: clear again.
    store
        .expunge_gated(&id, "test", None, NOW + 200, false)
        .expect("expunge");
    assert_bit_column_agree(&store, &id, false);
}

#[test]
fn count_undistilled_bitmap_predicate_counts_correctly() {
    // count_undistilled uses BitmaskNone(bit19). Verify result correctness
    // on a 3-drawer fixture: 2 undistilled, 1 distilled.
    let store = new_store();
    let u1 = make_id();
    let u2 = make_id();
    let d1 = make_id();
    for id in [&u1, &u2, &d1] {
        store.add_drawer(&sample_drawer(id), NOW).expect("add");
    }
    store
        .set_distilled_representation(&d1, "rendered d1", PIPELINE_V1, DIGEST, 2, NOW + 100)
        .expect("set");

    // u1 and u2 have bit 19 clear → counted as undistilled.
    // d1 has bit 19 set and pipelineVersion matches → not counted.
    let count = store.count_undistilled(PIPELINE_V1).expect("count");
    assert_eq!(count, 2, "2 drawers with bit 19 clear should be undistilled");

    // Distill u1: only u2 remains.
    store
        .set_distilled_representation(&u1, "rendered u1", PIPELINE_V1, DIGEST, 1, NOW + 200)
        .expect("set");
    let count_after = store.count_undistilled(PIPELINE_V1).expect("count");
    assert_eq!(count_after, 1, "after distilling u1, only u2 should remain");
}

#[test]
fn count_undistilled_version_mismatch_still_counts() {
    // A drawer with bit 19 set but under a different pipeline version must
    // count as undistilled (the version-mismatch branch of the OR predicate).
    let store = new_store();
    let id = make_id();
    store.add_drawer(&sample_drawer(&id), NOW).expect("add");
    store
        .set_distilled_representation(&id, "p1 rendering", PIPELINE_V1, DIGEST, 2, NOW + 100)
        .expect("set");

    // Under p1: drawer is current → not undistilled.
    let count_p1 = store.count_undistilled(PIPELINE_V1).expect("count");
    assert_eq!(count_p1, 0, "p1 match: not undistilled");

    // Under p2: drawer has bit 19 set, but pipelineVersion is p1 not p2
    // → the version-mismatch branch fires → counted as undistilled.
    let count_p2 = store.count_undistilled(PIPELINE_V2).expect("count");
    assert_eq!(count_p2, 1, "p2 mismatch: must be counted as needing redistillation");
}

#[test]
fn bit_19_and_column_always_agree_through_full_cycle() {
    // §4 invariant: bit and column always have the same truth value, verified
    // through set, re-set with new version, and final expunge.
    let store = new_store();
    let id = make_id();
    store.add_drawer(&sample_drawer(&id), NOW).expect("add");

    // Initial: both clear.
    assert_bit_column_agree(&store, &id, false);

    // Set under p1: both populated.
    store
        .set_distilled_representation(&id, "first rendering", PIPELINE_V1, DIGEST, 3, NOW + 100)
        .expect("set");
    assert_bit_column_agree(&store, &id, true);

    // Re-distill under p2: still both populated.
    store
        .set_distilled_representation(&id, "second rendering", PIPELINE_V2, DIGEST, 4, NOW + 200)
        .expect("re-set");
    assert_bit_column_agree(&store, &id, true);

    // Expunge: both clear.
    store
        .expunge_gated(&id, "test", None, NOW + 300, false)
        .expect("expunge");
    assert_bit_column_agree(&store, &id, false);
}

/// NULL the digest column on one row directly at the row-store layer —
/// the shape of every representation written before the column existed.
fn null_digest(store: &InMemoryDrawerStore, drawer_id: &str) {
    let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
    values.insert(DIGEST_COLUMN.to_string(), TypedValue::Null);
    store
        .storage()
        .expect("InMemoryDrawerStore exposes storage")
        .row_store()
        .update(
            "drawers",
            values,
            &StoragePredicate::Eq(Column::new("drawers", "id"), TypedValue::Text(drawer_id.to_string())),
        )
        .expect("null the digest column");
}

#[test]
fn set_distilled_representation_rejects_empty_digest() {
    // The digest is part of the atomic five-column write; an empty digest
    // would store a representation the currency rule can never prove current.
    let store = new_store();
    let id = make_id();
    store.add_drawer(&sample_drawer(&id), NOW).expect("add");
    let result = store.set_distilled_representation(&id, "rendering", PIPELINE_V1, "", 2, NOW + 100);
    assert!(result.is_err(), "an empty source digest must be rejected");
    assert_bit_column_agree(&store, &id, false);
}

#[test]
fn count_undistilled_null_digest_counts_as_stale() {
    // A representation stamped with the current converter but carrying no
    // digest (written before the column existed) is stale by definition.
    let store = new_store();
    let id = make_id();
    store.add_drawer(&sample_drawer(&id), NOW).expect("add");
    store
        .set_distilled_representation(&id, "rendering", PIPELINE_V1, DIGEST, 2, NOW + 100)
        .expect("set");
    assert_eq!(store.count_undistilled(PIPELINE_V1).expect("count"), 0, "digest present: current");

    null_digest(&store, &id);
    assert_eq!(
        store.count_undistilled(PIPELINE_V1).expect("count"),
        1,
        "NULL digest under the current converter must count as undistilled"
    );
}

#[test]
fn drawers_with_representations_lists_only_current_rows() {
    // Three represented drawers: current (id + digest), converter mismatch,
    // NULL digest. Only the current one is a candidate for the reindex probe.
    let store = new_store();
    let current = make_id();
    let mismatch = make_id();
    let no_digest = make_id();
    for id in [&current, &mismatch, &no_digest] {
        store.add_drawer(&sample_drawer(id), NOW).expect("add");
    }
    store
        .set_distilled_representation(&current, "current", PIPELINE_V1, DIGEST, 1, NOW + 100)
        .expect("set current");
    store
        .set_distilled_representation(&mismatch, "old converter", PIPELINE_V2, DIGEST, 1, NOW + 100)
        .expect("set mismatch");
    store
        .set_distilled_representation(&no_digest, "pre-digest row", PIPELINE_V1, DIGEST, 1, NOW + 100)
        .expect("set no_digest");
    null_digest(&store, &no_digest);

    let rows = store.drawers_with_representations(PIPELINE_V1).expect("projection");
    assert_eq!(rows.len(), 1, "only the current row is listed: {rows:?}");
    assert_eq!(rows[0].0, current);
    assert_eq!(rows[0].1, NOW + 100);
}

/// The live LocusKit declaration with the drawers table rolled back to its
/// v17 layout: no `distilled_source_digest` column, version 17, and no
/// migrations list. Applying this to a fresh SQLite file simulates a
/// populated estate written before the column existed.
fn version17_schema() -> SchemaDeclaration {
    let live = schema();
    let tables = live
        .tables
        .iter()
        .map(|table| {
            if table.name != "drawers" {
                return table.clone();
            }
            let mut rolled = table.clone();
            rolled.columns.retain(|c| c.name != DIGEST_COLUMN);
            rolled
        })
        .collect::<Vec<TableDeclaration>>();
    SchemaDeclaration {
        kit_id: live.kit_id.clone(),
        version: 17,
        tables,
        indices: live.indices.clone(),
        migrations: Vec::new(),
    }
}

#[test]
fn opening_a_v17_sqlite_estate_adds_the_digest_column() {
    // The v17 → v18 ladder entry is what every host open replays and what
    // the estate-format 1.3 capsule replays; SQLite is the backend where a
    // missing column is observable (an UPDATE naming it fails).
    let path = std::env::temp_dir()
        .join(format!("locuskit-v17-ladder-{}.sqlite", Uuid::new_v4()))
        .display()
        .to_string();
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite { path: path.clone(), busy_timeout_secs: 5.0 },
    );
    let storage: Arc<dyn Storage> = Arc::new(SqliteStorage::new(config).expect("sqlite"));
    storage.open(&version17_schema()).expect("apply the v17 layout");
    assert_eq!(storage.current_schema_version_for(KIT_ID).expect("version"), 17);

    // Seed one row through the row store so the UPDATE below has a target.
    let id = Uuid::new_v4().to_string();
    let mut row: BTreeMap<String, TypedValue> = BTreeMap::new();
    row.insert("id".to_string(), TypedValue::Text(id.clone()));
    row.insert("content".to_string(), TypedValue::Text("v17 row".to_string()));
    row.insert("parent_node_id".to_string(), TypedValue::Text(TEST_PARENT.to_string()));
    row.insert("addedBy".to_string(), TypedValue::Text("bilby".to_string()));
    row.insert("filedAt".to_string(), TypedValue::Timestamp(NOW));
    row.insert("eventTime".to_string(), TypedValue::Timestamp(NOW));
    row.insert("embeddingModelID".to_string(), TypedValue::Text("test-v1".to_string()));
    row.insert("lineageID".to_string(), TypedValue::Text(Uuid::new_v4().to_string()));
    storage.row_store().insert("drawers", row).expect("seed v17 row");

    let digest_update = || {
        let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
        values.insert(DIGEST_COLUMN.to_string(), TypedValue::Text(DIGEST.to_string()));
        storage.row_store().update(
            "drawers",
            values,
            &StoragePredicate::Eq(Column::new("drawers", "id"), TypedValue::Text(id.clone())),
        )
    };
    assert!(digest_update().is_err(), "the v17 layout has no digest column");

    // Replaying the live ladder adds the column and records v18.
    storage.open(&schema()).expect("replay the ladder");
    assert_eq!(storage.current_schema_version_for(KIT_ID).expect("version"), SCHEMA_VERSION);
    assert_eq!(digest_update().expect("digest write after the ladder"), 1);

    // Idempotent: a second open neither fails nor changes the version.
    storage.open(&schema()).expect("second replay");
    assert_eq!(storage.current_schema_version_for(KIT_ID).expect("version"), SCHEMA_VERSION);
    let _ = std::fs::remove_file(&path);
}
