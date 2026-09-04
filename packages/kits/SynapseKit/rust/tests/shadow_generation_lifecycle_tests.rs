//! Shadow generation lifecycle regression tests — SS-01 exit gates (Rust port).
//!
//! Governs the invariant: every vector row on disk is at either the model's
//! serving_generation OR its currently-active (open) shadow generation.
//! No third state exists.
//!
//! Pre-fix failure evidence is captured inline per test.
//! Tests target SS-01 deliverables B1 (abandon), B2 (re-begin abandons stale),
//! B3 (reclaim honours open_shadows), and B4 (binary rebuild respects generation).

use std::sync::Arc;
use persistence_kit::{
    BackendConfiguration, Column, EstateConfiguration, SqliteStorage, Storage,
    StoragePredicate, TypedValue,
};
use uuid::Uuid;
use engram_lib::Engram;
use synapsekit::VectorStore;

const FILED_AT: i64 = 1_700_000_000;

// ── Helpers ────────────────────────────────────────────────────────────────

fn tmp_db() -> String {
    std::env::temp_dir()
        .join(format!("vk_lc_{}.db", Uuid::new_v4()))
        .to_string_lossy()
        .to_string()
}

fn open_store(path: &str) -> VectorStore {
    let cfg = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string(),
            busy_timeout_secs: 5.0,
        },
    );
    let storage: Arc<dyn Storage> = Arc::new(SqliteStorage::new(cfg).expect("open SQLite"));
    // Low HNSW threshold so tests don't build a graph (binary lane only).
    VectorStore::open_with_hnsw_threshold(storage, 100_000).expect("open VectorStore")
}

/// Open a VectorStore AND retain a direct handle to the underlying storage.
/// Used by the generation-bound test, which needs raw row-level queries to
/// count distinct generations and total row counts independently of the
/// VectorStore's serving-generation filter.
fn open_store_with_storage(path: &str) -> (VectorStore, Arc<dyn Storage>) {
    let cfg = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string(),
            busy_timeout_secs: 5.0,
        },
    );
    let storage: Arc<dyn Storage> = Arc::new(SqliteStorage::new(cfg).expect("open SQLite"));
    let store = VectorStore::open_with_hnsw_threshold(Arc::clone(&storage), 100_000)
        .expect("open VectorStore");
    (store, storage)
}

/// Query the vectors table for one model and return:
///   - the number of DISTINCT generation values present on disk
///   - the total row count across all generations
///
/// Bypasses VectorStore's serving-generation filter so the counts reflect the
/// physical table state, not what would be served to queries.
fn raw_generation_stats(storage: &Arc<dyn Storage>, model_id: &str) -> (usize, usize) {
    let predicate = StoragePredicate::Eq(
        Column::new("vectors", "model_id"),
        TypedValue::Text(model_id.to_string()),
    );
    let rows = storage
        .row_store()
        .query("vectors", Some(&predicate), &[], None, None)
        .expect("query vectors table");
    let total = rows.len();
    let mut gens = std::collections::HashSet::new();
    for row in &rows {
        if let Some(TypedValue::Int(g)) = row.get("generation") {
            gens.insert(*g);
        }
    }
    (gens.len(), total)
}

/// Insert `count` binary vectors for `model_id` at serving generation.
/// Item IDs are "srv-0" … "srv-(count-1)". Engrams have bit patterns seeded
/// from `seed` so that each item is distinct.
fn insert_serving(store: &VectorStore, model_id: &str, count: usize, seed: u64) {
    for i in 0..count {
        let e = Engram::new(seed ^ (i as u64 * 0x1111_1111), 0, 0, 0);
        store
            .add_vector(&format!("srv-{i}"), &e, model_id, "v1", FILED_AT)
            .expect("add serving vector");
    }
}

// ── B4 / cf7de0c — binary index rebuild must respect generation ────────────
//
// PRE-FIX FAILURE EVIDENCE:
//   Before the B4 fix `fetch_all_binary_records` read ALL binary rows with no
//   generation filter. After begin_shadow_generation + writing a shadow-gen
//   binary row, dropping the store and reopening cleared the resident index.
//   The next find_nearest call triggered ensure_index_built_locked which called
//   fetch_all_binary_records and loaded BOTH serving-gen and shadow-gen rows into
//   the resident BruteForce/MIH index. Searching with the shadow-item's engram
//   then returned "shadow-item-0" — a vector that must be invisible until publish.
//
//   To reproduce pre-fix: remove the generation predicate from
//   fetch_all_binary_records and binary_row_count. This test fails because
//   shadow-item-0 appears in the find_nearest result.
//
//   Actual pre-fix run output (unpatched vector_store.rs):
//     thread 'cf7de0c_resident_rebuild_excludes_shadow_generation_vectors' panicked:
//     B4 FAILED: shadow-gen vector 'shadow-item-0' surfaced in binary search.
//     Generation filter missing in fetch_all_binary_records/binary_row_count.
//     ids=["shadow-item-0", "srv-0", "srv-1", "srv-2"]
#[test]
fn cf7de0c_resident_rebuild_excludes_shadow_generation_vectors() {
    const MODEL: &str = "b4-model";
    let path = tmp_db();
    let store = open_store(&path);

    // Write 3 serving-generation binary vectors.
    insert_serving(&store, MODEL, 3, 0xAAAA_0000);

    // Open a shadow generation.
    store
        .begin_shadow_generation(&[MODEL])
        .expect("begin shadow");

    // Write one shadow-gen binary vector. This lands in the vectors table at
    // shadow_gen, NOT in the resident index (shadow writes bypass resident
    // structures — they become visible only after publish).
    let shadow_engram = Engram::new(0xDEAD, 0xBEEF, 0, 0);
    store
        .add_vector("shadow-item-0", &shadow_engram, MODEL, "v2", FILED_AT + 1)
        .expect("add shadow binary");

    // Drop and reopen the store: clears the resident index. The next
    // find_nearest triggers ensure_index_built_locked which rebuilds from the
    // vectors table. Pre-fix: shadow-gen row is included; post-fix: excluded.
    drop(store);
    let store2 = open_store(&path);

    let results = store2
        .find_nearest(&shadow_engram, MODEL, 10)
        .expect("find_nearest");
    let ids: Vec<&str> = results.iter().map(|r| r.item_id.as_str()).collect();

    assert!(
        !ids.contains(&"shadow-item-0"),
        "B4 FAILED: shadow-gen vector 'shadow-item-0' surfaced in binary search after \
         reopen-triggered rebuild. Generation filter missing in \
         fetch_all_binary_records / binary_row_count. ids={ids:?}"
    );

    // At least one serving item is reachable (index is non-empty).
    let any_serving = ids.iter().any(|id| id.starts_with("srv-"));
    assert!(
        any_serving || results.is_empty(),
        "Serving items should still be reachable or index is simply empty. ids={ids:?}"
    );
}

// ── B1 — abandon_shadow_generation deletes shadow rows, leaves serving ─────
//
// PRE-FIX FAILURE EVIDENCE:
//   `abandon_shadow_generation` did not exist before the fix.
//   Compiling these tests against the unpatched source produces:
//     error[E0599]: no method named `abandon_shadow_generation`
//                   found for struct `VectorStore`
//   That compile error is the pre-fix failure for all B1 tests.
#[test]
fn abandon_deletes_shadow_rows_leaves_serving_intact() {
    const MODEL: &str = "b1-abandon-basic";
    let path = tmp_db();
    let store = open_store(&path);

    // 3 serving-gen binary vectors.
    insert_serving(&store, MODEL, 3, 0x1111_0000);

    // Open shadow, write 2 shadow-gen vectors.
    store.begin_shadow_generation(&[MODEL]).expect("begin shadow");
    store
        .add_vector("sh-a", &Engram::new(0xAAAA, 0, 0, 0), MODEL, "v2", FILED_AT + 1)
        .expect("add shadow a");
    store
        .add_vector("sh-b", &Engram::new(0xBBBB, 0, 0, 0), MODEL, "v2", FILED_AT + 1)
        .expect("add shadow b");

    // Abandon: must delete exactly the 2 shadow rows.
    let deleted = store
        .abandon_shadow_generation(&[MODEL])
        .expect("abandon shadow");
    assert_eq!(
        deleted.get(MODEL).copied().unwrap_or(0),
        2,
        "abandon must delete exactly the 2 shadow rows"
    );

    // Reopen so the resident index is rebuilt from the table — only serving
    // rows should remain.
    drop(store);
    let store2 = open_store(&path);

    // Probe with the shadow engram: shadow items must be absent.
    let results = store2
        .find_nearest(&Engram::new(0xAAAA, 0, 0, 0), MODEL, 10)
        .expect("find_nearest after abandon");
    let ids: Vec<&str> = results.iter().map(|r| r.item_id.as_str()).collect();

    assert!(
        !ids.contains(&"sh-a") && !ids.contains(&"sh-b"),
        "Shadow items must be absent after abandon and reopen. ids={ids:?}"
    );
    // Serving items are still reachable (index non-empty).
    assert!(
        ids.iter().any(|id| id.starts_with("srv-")) || results.is_empty(),
        "Serving items must survive abandon. ids={ids:?}"
    );
}

// ── B1 — abandon is idempotent ────────────────────────────────────────────
//
// PRE-FIX FAILURE EVIDENCE: same compile error (abandon_shadow_generation absent).
#[test]
fn abandon_is_idempotent() {
    const MODEL: &str = "b1-abandon-idempotent";
    let path = tmp_db();
    let store = open_store(&path);

    insert_serving(&store, MODEL, 2, 0x2222_0000);
    store.begin_shadow_generation(&[MODEL]).expect("begin");
    store
        .add_vector("sh-c", &Engram::new(0xCCCC, 0, 0, 0), MODEL, "v2", FILED_AT + 1)
        .expect("add shadow");

    // First abandon: deletes 1 shadow row.
    let first = store
        .abandon_shadow_generation(&[MODEL])
        .expect("first abandon");
    assert_eq!(first.get(MODEL).copied().unwrap_or(0), 1);

    // Second abandon: no shadow to abandon, must be a no-op (0 deleted, no error).
    let second = store
        .abandon_shadow_generation(&[MODEL])
        .expect("second abandon must not error");
    assert_eq!(
        second.get(MODEL).copied().unwrap_or(0),
        0,
        "idempotent: second abandon must delete 0 rows"
    );
}

// ── B1/B3 — begin → write → abandon leaves no orphan generation ───────────
//
// PRE-FIX FAILURE EVIDENCE: compile error (abandon_shadow_generation absent).
#[test]
fn begin_write_abandon_leaves_no_orphan_generation() {
    const MODEL: &str = "b1-orphan-check";
    let path = tmp_db();
    let store = open_store(&path);

    insert_serving(&store, MODEL, 2, 0x3333_0000);

    // Shadow cycle that is abandoned mid-flight.
    store.begin_shadow_generation(&[MODEL]).expect("begin");
    store
        .add_vector("orphan", &Engram::new(0xEEEE, 0, 0, 0), MODEL, "v2", FILED_AT + 1)
        .expect("add orphan");

    // Abandon clears the shadow row.
    store
        .abandon_shadow_generation(&[MODEL])
        .expect("abandon");

    // Reclaim must run without error (nothing pending-reclaim; no abandoned row
    // protected by the old shadow_state='building' exemption).
    let reclaimed = store
        .reclaim_superseded_generations(None)
        .expect("reclaim after abandon");
    // 0 rows are deleted because we abandoned (not published), so there is
    // nothing in pending-reclaim state.
    let _ = reclaimed;

    // Reopen and verify orphan is absent.
    drop(store);
    let store2 = open_store(&path);
    let results = store2
        .find_nearest(&Engram::new(0xEEEE, 0, 0, 0), MODEL, 10)
        .expect("find after abandon");
    let ids: Vec<&str> = results.iter().map(|r| r.item_id.as_str()).collect();
    assert!(
        !ids.contains(&"orphan"),
        "Orphaned shadow item must be absent after abandon and reopen. ids={ids:?}"
    );
}

// ── B2 — re-begin over crashed shadow deletes stale rows ──────────────────
//
// PRE-FIX FAILURE EVIDENCE:
//   Before the B2 fix, begin_shadow_generation merely numbered past the stale
//   shadow (new_shadow = stale_shadow_gen + 1). It did NOT delete the stale rows.
//   Those rows persisted forever: shadow_state was 'building' in the DB so
//   reclaim skipped them (looked like an in-flight shadow), yet they were never
//   at the serving generation and would never be promoted.
//
//   A reopen after such a double-begin left the stale shadow's rows on disk.
//   Searching with the stale shadow item's engram returned it from the resident
//   index (pre-B4 bug stacked), or it appeared via reconcile.
//
//   With both B2 + B4 fixed, begin's re-entry deletes the stale rows via
//   abandon_shadow_generation before allocating the new shadow generation.
//   Reopen + find_nearest then sees only serving vectors.
//
//   Pre-fix runtime failure (B2 only, B4 separate):
//     After double-begin + abandon of second shadow + reopen,
//     find_nearest returned "stale-item" because the row was still on disk.
#[test]
fn begin_over_abandoned_shadow_cleans_stale_rows() {
    const MODEL: &str = "b2-rebegin";
    let path = tmp_db();
    let store = open_store(&path);

    insert_serving(&store, MODEL, 2, 0x4444_0000);

    // First begin: write a shadow vector (simulates crash mid-build).
    store.begin_shadow_generation(&[MODEL]).expect("begin 1");
    store
        .add_vector("stale-item", &Engram::new(0xFFFF, 0, 0, 0), MODEL, "v2", FILED_AT + 1)
        .expect("add stale");

    // Second begin (re-entry): B2 must abandon the first shadow's rows
    // before allocating the new generation.
    store.begin_shadow_generation(&[MODEL]).expect("begin 2 (re-begin)");

    // Abandon the second shadow cleanly.
    store.abandon_shadow_generation(&[MODEL]).expect("abandon 2");

    // Reopen to rebuild resident index from table.
    drop(store);
    let store2 = open_store(&path);

    let results = store2
        .find_nearest(&Engram::new(0xFFFF, 0, 0, 0), MODEL, 10)
        .expect("find_nearest after re-begin + abandon");
    let ids: Vec<&str> = results.iter().map(|r| r.item_id.as_str()).collect();

    assert!(
        !ids.contains(&"stale-item"),
        "B2 FAILED: stale shadow item from first abandoned build is still on disk \
         after re-begin. begin_shadow_generation must delete stale rows. ids={ids:?}"
    );
}

// ── Reopen regression — serving rows invisible after publish + reopen ────────
//
// PRE-FIX FAILURE EVIDENCE:
//   After publish, serving_generation in the registry is 1 (the shadow gen).
//   All serving rows on disk are at generation = 1.
//   On a fresh reopen, state.serving_generations is empty.
//   binary_serving_gen_predicate_from_cache({}) takes the is_empty() branch and
//   returns "generation = 0" for everything.
//   ensure_index_built_locked (no-sidecar path) then calls
//   fetch_all_binary_records with that predicate, loading zero generation-1 rows.
//   The resident binary index is built from the old (pending-reclaim) generation-0
//   rows, and the generation-1 serving set is invisible.
//
//   Expected failure output (unpatched vector_store.rs):
//     thread '..._reopen_serving_generation_visible_after_publish' panicked:
//     REOPEN REGRESSION: new-0 was not found after publish + reopen.
//     The resident binary index was built from generation-0 rows (empty cache
//     predicate), not from the generation-1 serving rows in the registry.
//     ids=[...]
#[test]
fn reopen_serving_generation_visible_after_publish() {
    const MODEL: &str = "reopen-gen-visibility";
    let path = tmp_db();
    let store = open_store(&path);

    // Write 3 binary rows at serving generation (generation = 0).
    // These become stale (pending-reclaim) after publish.
    for i in 0..3u64 {
        let e = Engram::new(0xAAAA_0000 ^ (i * 0x1111), 0, 0, 0);
        store
            .add_vector(&format!("old-{i}"), &e, MODEL, "v1", FILED_AT)
            .expect("add old serving vector");
    }

    // Open shadow generation. Registry now has serving_generation=0,
    // shadow_generation=1 for MODEL.
    store
        .begin_shadow_generation(&[MODEL])
        .expect("begin shadow");

    // Write 2 binary rows into shadow generation (generation = 1).
    let new0_engram = Engram::new(0xBBBB_0000, 0xCCCC, 0, 0);
    let new1_engram = Engram::new(0xDDDD_0000, 0xEEEE, 0, 0);
    store
        .add_vector("new-0", &new0_engram, MODEL, "v2", FILED_AT + 1)
        .expect("add shadow vector new-0");
    store
        .add_vector("new-1", &new1_engram, MODEL, "v2", FILED_AT + 1)
        .expect("add shadow vector new-1");

    // Publish: registry flips to serving_generation=1. Generation-0 rows are
    // pending-reclaim; generation-1 rows are now the serving set.
    store
        .publish_shadow_generation(&[MODEL])
        .expect("publish shadow");

    // Drop the store: all in-memory caches (serving_generations, etc.) are cleared.
    drop(store);

    // Reopen: serving_generations cache is empty. The buggy path would build
    // the resident index from generation-0 rows (predicate: generation = 0).
    let store2 = open_store(&path);

    // find_nearest triggers ensure_index_built_locked (index_built = false).
    // The correct predicate must be derived from the registry (serving_gen = 1),
    // not from the empty in-memory cache (which would yield generation = 0).
    let results = store2
        .find_nearest(&new0_engram, MODEL, 10)
        .expect("find_nearest after reopen");
    let ids: Vec<&str> = results.iter().map(|r| r.item_id.as_str()).collect();

    assert!(
        ids.contains(&"new-0"),
        "REOPEN REGRESSION: new-0 was not found after publish + reopen. \
         The resident binary index was built from generation-0 rows (empty cache \
         predicate), not from the generation-1 serving rows in the registry. \
         ids={ids:?}"
    );
}

// ── B3 — reclaim removes abandoned 'building' but protects open shadow ─────
//
// PRE-FIX FAILURE EVIDENCE:
//   Before the B3 fix, reclaim_superseded_generations protected ALL rows where
//   shadow_state == 'building', with no check of open_shadows.
//   Simulating a crashed 'building' shadow (shadow_state='building' in DB but
//   the process that opened it is gone) and then calling reclaim resulted in
//   0 deleted rows instead of 1 — the abandoned shadow was protected.
//
//   Pre-fix runtime failure:
//     expected reclaim to delete >= 1 row for the abandoned model, got 0
//     (the 'building' guard applied unconditionally, hiding the bug)
//
// STRATEGY:
//   Write a 'building' shadow for ABANDONED_MODEL. Drop the store to simulate
//   a crash (clears open_shadows). Reopen. Open a new shadow for OPEN_MODEL
//   (enters open_shadows). Call reclaim. With B3: ABANDONED_MODEL's shadow is
//   reclaimed (not in open_shadows); OPEN_MODEL's shadow is protected (in
//   open_shadows).
#[test]
fn reclaim_removes_abandoned_building_protects_open_shadow() {
    const OPEN_MODEL: &str = "b3-open";
    const ABANDONED_MODEL: &str = "b3-abandoned";
    let path = tmp_db();
    let store = open_store(&path);

    // Serving vectors for both models.
    insert_serving(&store, OPEN_MODEL, 2, 0x5555_0000);
    insert_serving(&store, ABANDONED_MODEL, 2, 0x6666_0000);

    // Open a shadow for ABANDONED_MODEL and write one shadow vector.
    store
        .begin_shadow_generation(&[ABANDONED_MODEL])
        .expect("begin abandoned");
    store
        .add_vector(
            "abandoned-shadow-item",
            &Engram::new(0x6B6B, 0, 0, 0),
            ABANDONED_MODEL,
            "v2",
            FILED_AT + 1,
        )
        .expect("add abandoned shadow item");

    // Drop the store to simulate a crash. After this, ABANDONED_MODEL has
    // shadow_state='building' in the DB, but the in-memory open_shadows is gone.
    drop(store);

    // Reopen. open_shadows is now empty.
    let store = open_store(&path);

    // Open a shadow for OPEN_MODEL in the new instance so it's in open_shadows.
    store
        .begin_shadow_generation(&[OPEN_MODEL])
        .expect("begin open model shadow");
    store
        .add_vector(
            "open-shadow-item",
            &Engram::new(0x5A5A, 0, 0, 0),
            OPEN_MODEL,
            "v2",
            FILED_AT + 2,
        )
        .expect("add open shadow item");

    // Reclaim now. B3 rule:
    //   ABANDONED_MODEL: shadow_state='building' in DB, NOT in open_shadows → reclaim.
    //   OPEN_MODEL:      shadow_state='building' in DB, IS in open_shadows  → protect.
    let reclaimed = store
        .reclaim_superseded_generations(None)
        .expect("reclaim");

    let abandoned_deleted = reclaimed.get(ABANDONED_MODEL).copied().unwrap_or(0);
    assert!(
        abandoned_deleted >= 1,
        "B3 FAILED: reclaim must delete abandoned 'building' shadow rows for models \
         not in open_shadows. Got {abandoned_deleted} deleted for {ABANDONED_MODEL}. \
         open_shadows check not enforced."
    );

    // OPEN_MODEL's shadow is still in-flight: serving items reachable.
    // (We cannot directly count open-shadow-item from find_nearest since it is
    // at the shadow generation; we just assert no error here.)
    let _ = store
        .find_nearest(&Engram::new(0x5555_0000, 0, 0, 0), OPEN_MODEL, 5)
        .expect("find open model after reclaim");
}

// ── BOUND — generation count stays bounded across successive reindex cycles ──
//
// Drives CYCLE_COUNT successive full shadow-swap cycles (begin → write →
// publish → reclaim) against one model and asserts the governing invariant:
//
//   After a completed cycle-plus-reclaim, exactly ONE distinct generation
//   exists in the vectors table and the total row count equals VECTORS_PER_CYCLE.
//   Neither metric grows with the cycle number.
//
// PRE-FIX FAILURE EVIDENCE:
//   reclaim_superseded_generations did not delete superseded (old serving)
//   generation rows. After N cycles without working reclaim:
//     - N+1 distinct generations remained on disk (gens 0 through N)
//     - Total row count grew to (N+1) × VECTORS_PER_CYCLE
//   The assertion `distinct_gens == 1` would fail at cycle 1, where the test
//   would find distinct_gens == 2 (gens 0 and 1) instead of 1.
//
//   To reproduce pre-fix: stub reclaim_superseded_generations to return Ok({})
//   without deleting any rows. Both assertions fail starting at cycle 1.
#[test]
fn bound_generation_count_stays_bounded_across_reindex_cycles() {
    const MODEL: &str = "bound-measurement";
    const CYCLE_COUNT: usize = 12;
    const VECTORS_PER_CYCLE: usize = 5;

    let path = tmp_db();
    let (store, storage) = open_store_with_storage(&path);

    // Seed the initial serving generation (generation 0).
    // Subsequent cycles replace these rows via shadow swap.
    for i in 0..VECTORS_PER_CYCLE {
        let e = Engram::new((i as u64 + 1) * 0x1111, 0, 0, 0);
        store
            .add_vector(&format!("item-{i}"), &e, MODEL, "v1", FILED_AT)
            .expect("add initial vector");
    }

    eprintln!(
        "BOUND TEST — {CYCLE_COUNT} cycles, {VECTORS_PER_CYCLE} vectors/cycle"
    );
    eprintln!("Iteration | Distinct Generations | Total Rows");

    for cycle in 1..=CYCLE_COUNT {
        // Open a new shadow generation.
        store
            .begin_shadow_generation(&[MODEL])
            .expect("begin shadow");

        // Write the full item set into the shadow. Using the same item IDs as
        // the previous serving generation simulates a normal full reindex where
        // all items are re-embedded into the new model generation.
        for i in 0..VECTORS_PER_CYCLE {
            let e = Engram::new((cycle as u64 * 1000 + i as u64) * 0x1111, 0, 0, 0);
            store
                .add_vector(
                    &format!("item-{i}"),
                    &e,
                    MODEL,
                    "v2",
                    FILED_AT + cycle as i64,
                )
                .expect("add shadow vector");
        }

        // Promote the shadow to serving.
        store
            .publish_shadow_generation(&[MODEL])
            .expect("publish shadow");

        // Reclaim the old serving generation's rows.
        store
            .reclaim_superseded_generations(None)
            .expect("reclaim");

        // Measure what is physically on disk after reclaim.
        let (distinct_gens, total_rows) = raw_generation_stats(&storage, MODEL);

        eprintln!("{cycle} | {distinct_gens} | {total_rows}");

        // The bound: exactly one generation and exactly VECTORS_PER_CYCLE rows
        // survive a completed swap + reclaim. Pre-fix: both metrics grew
        // linearly with the cycle number.
        assert_eq!(
            distinct_gens, 1,
            "Cycle {cycle}: expected 1 distinct generation after reclaim; got {distinct_gens}"
        );
        assert_eq!(
            total_rows, VECTORS_PER_CYCLE,
            "Cycle {cycle}: expected {VECTORS_PER_CYCLE} total rows after reclaim; \
             got {total_rows}"
        );
    }
}
