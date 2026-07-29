//! Bit-column agreement tests for the `has_current_representation` bit
//! (bit 19 of `operational_bitmap`) and the four distillation columns.
//!
//! Per SPEC_DISTILLATION_STORAGE §4 and cookbook §2.4.1: the bit and the
//! four columns (`distilled`, `distilled_pipeline_version`,
//! `distilled_token_count`, `distilled_at`) are ALWAYS in agreement — they
//! travel in the SAME SQL UPDATE for every set and clear path.
//!
//! Twin-parity mirror of Swift `DistilledRepresentationTests` (the tests
//! added for the has_current_representation rider).
//!
//! Uses `InMemoryDrawerStore` because it is the single source of the real
//! `set_distilled_representation` / `count_undistilled` / expunge logic
//! (SQLite and Postgres wrappers delegate to it). The in-memory backend is
//! synchronous and deterministic, so these tests are fast and artifact-free.

use locus_kit::drawer::Drawer;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use uuid::Uuid;

const NOW: i64 = 1_700_000_000;
const PIPELINE_V1: &str = "p1";
const PIPELINE_V2: &str = "p2";
const TEST_PARENT: &str = "00000000-0000-4000-8000-000000000001";

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
        .set_distilled_representation(&id, "some rendering", PIPELINE_V1, 3, NOW + 100)
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
        .set_distilled_representation(&missing, "x", PIPELINE_V1, 1, NOW)
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
        .set_distilled_representation(&id, "rendering", PIPELINE_V1, 2, NOW + 100)
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
        .set_distilled_representation(&id, "rendering one", PIPELINE_V1, 2, NOW + 100)
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
        .set_distilled_representation(&d1, "rendered d1", PIPELINE_V1, 2, NOW + 100)
        .expect("set");

    // u1 and u2 have bit 19 clear → counted as undistilled.
    // d1 has bit 19 set and pipelineVersion matches → not counted.
    let count = store.count_undistilled(PIPELINE_V1).expect("count");
    assert_eq!(count, 2, "2 drawers with bit 19 clear should be undistilled");

    // Distill u1: only u2 remains.
    store
        .set_distilled_representation(&u1, "rendered u1", PIPELINE_V1, 1, NOW + 200)
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
        .set_distilled_representation(&id, "p1 rendering", PIPELINE_V1, 2, NOW + 100)
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
        .set_distilled_representation(&id, "first rendering", PIPELINE_V1, 3, NOW + 100)
        .expect("set");
    assert_bit_column_agree(&store, &id, true);

    // Re-distill under p2: still both populated.
    store
        .set_distilled_representation(&id, "second rendering", PIPELINE_V2, 4, NOW + 200)
        .expect("re-set");
    assert_bit_column_agree(&store, &id, true);

    // Expunge: both clear.
    store
        .expunge_gated(&id, "test", None, NOW + 300, false)
        .expect("expunge");
    assert_bit_column_agree(&store, &id, false);
}
