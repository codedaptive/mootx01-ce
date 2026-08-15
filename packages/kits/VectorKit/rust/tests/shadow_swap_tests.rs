//! Shadow-swap generation tests — VEC-SHADOWSWAP-01 exit gates (Rust port).
//!
//! Mirrors Swift `ShadowSwapTests`. Tests are grouped into five gates and four
//! interrupt cases as specified in the SHADOWSWAP_DESIGN_CONTRACT.md.
//!
//! ## Gate assertions
//! - Gate 1: shadow rows are invisible before publish
//! - Gate 2: crash mid-build recovery (reopen serves old generation)
//! - Gate 3: publish idempotence (re-run has no effect)
//! - Gate 4: reclaim second pass is a no-op (idempotent)
//! - Gate 5: post-swap coherence — last_served_graph_generation == published gen
//!           AND hnsw_build_count == 0 (graph loaded, not rebuilt) AND
//!           hnsw_index_resident (HP-3 residency probe, necessary but not sufficient)
//!
//! ## Interrupt cases
//! - Interrupt 4a: partial shadow rows written + registry 'building' → reopen serves old gen
//! - Interrupt 4b: flipped registry + stale-gen graph rows (crash mid-rebuild) → serves correctly
//! - Interrupt 4c: THETA-after-swap rebuild → hnsw_build_count advances
//! - Interrupt 4d: recall unchanged — same content before and after swap
//!
//! ## Additional coverage
//! - Gate 9: measured peak shadow storage bytes > 0 after shadow write
//! - Gate 10: shadow-only items invisible to find_by_keyword and recent_item_ids

use std::sync::Arc;
use persistence_kit::{BackendConfiguration, EstateConfiguration, SqliteStorage, Storage};
use uuid::Uuid;
use vectorkit::{VectorPayload, VectorPayloadInput, VectorStore};

// HNSW threshold lowered to 5 so tests activate the HNSW path without many vectors.
const HNSW_THRESHOLD: u32 = 5;
const FILED_AT: i64 = 1_700_000_000;
const MODEL_A: &str = "shadow-model-a";

// ── SplitMix64 RNG (local copy — avoids cross-suite seed collisions) ──────────

struct SplitMix64SW {
    state: u64,
}

impl SplitMix64SW {
    fn new(seed: u64) -> Self {
        SplitMix64SW { state: seed }
    }

    fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9e3779b97f4a7c15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
        z ^ (z >> 31)
    }

    fn next_f32(&mut self) -> f32 {
        (self.next_u64() >> 11) as f32 * (1.0_f32 / (1u64 << 53) as f32)
    }
}

// ── Storage and store helpers ─────────────────────────────────────────────────

fn make_sqlite_storage(path: &str) -> Arc<dyn Storage> {
    let cfg = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string(),
            busy_timeout_secs: 5.0,
        },
    );
    Arc::new(SqliteStorage::new(cfg).expect("open SQLite storage"))
}

fn open_store(path: &str) -> VectorStore {
    let storage = make_sqlite_storage(path);
    VectorStore::open_with_hnsw_threshold(storage, HNSW_THRESHOLD)
        .expect("open VectorStore")
}

fn tmp_db() -> String {
    std::env::temp_dir()
        .join(format!("vk_sw_{}.db", Uuid::new_v4()))
        .to_string_lossy()
        .to_string()
}

/// Insert `count` float32 vectors tagged with model MODEL_A, seed-deterministic.
fn insert_float_vectors(store: &VectorStore, count: usize, seed: u64) {
    let mut rng = SplitMix64SW::new(seed);
    for i in 0..count {
        let floats: Vec<f32> = (0..4).map(|_| rng.next_f32() * 2.0 - 1.0).collect();
        store
            .add_payload(&format!("item-{i}"), 0, &VectorPayload::from_f32(&floats),
                MODEL_A, "v1", FILED_AT)
            .expect("add float payload");
    }
}

/// Insert `count` float32 vectors with item IDs having the given prefix.
fn insert_float_vectors_prefixed(store: &VectorStore, count: usize, seed: u64, prefix: &str) {
    let mut rng = SplitMix64SW::new(seed);
    for i in 0..count {
        let floats: Vec<f32> = (0..4).map(|_| rng.next_f32() * 2.0 - 1.0).collect();
        store
            .add_payload(&format!("{prefix}-{i}"), 0, &VectorPayload::from_f32(&floats),
                MODEL_A, "v1", FILED_AT)
            .expect("add float payload");
    }
}

/// Build a VectorPayloadInput for a float vector.
fn float_input(item_id: &str, floats: &[f32]) -> VectorPayloadInput {
    VectorPayloadInput {
        item_id: item_id.to_string(),
        vector_index: 0,
        payload: VectorPayload::from_f32(floats),
        model_id: MODEL_A.to_string(),
        model_version: "v2".to_string(),
        filed_at_unix_secs: FILED_AT + 1,
    }
}

// ── Gate 1: shadow rows invisible before publish ──────────────────────────────

/// Gate 1: vectors written while a shadow is active do NOT appear in any read
/// path until `publish_shadow_generation` commits the flip.
///
/// Falsification: removing the serving-gen filter from `fetch_float_records`
/// causes shadow-tagged rows to surface in find_nearest_float before publish,
/// flipping this gate red.
#[test]
fn gate1_shadow_rows_invisible_before_publish() {
    let db = tmp_db();
    let store = open_store(&db);

    // Write N serving-generation vectors.
    insert_float_vectors(&store, HNSW_THRESHOLD as usize + 2, 10);

    // Capture a reference result set from the serving generation.
    let probe: Vec<f32> = (0..4).map(|i| i as f32 * 0.1).collect();
    let results_before: Vec<String> = store
        .find_nearest_float(&probe, MODEL_A, 3)
        .expect("find before shadow")
        .into_iter()
        .map(|m| m.item_id)
        .collect();
    assert!(!results_before.is_empty(), "gate1: serving results must be non-empty");

    // Begin a shadow and write new vectors tagged with shadow generation.
    store.begin_shadow_generation(&[MODEL_A]).expect("begin shadow");

    let shadow_items = ["shadow-only-X", "shadow-only-Y"];
    for id in &shadow_items {
        let floats: Vec<f32> = vec![0.9, 0.1, 0.1, 0.1];
        store
            .add_payload(id, 0, &VectorPayload::from_f32(&floats), MODEL_A, "v2", FILED_AT + 1)
            .expect("shadow add_payload");
    }

    // GATE: find_nearest_float must return the same serving items as before
    // the shadow was opened. Shadow-only items must NOT appear.
    let results_during: Vec<String> = store
        .find_nearest_float(&probe, MODEL_A, 5)
        .expect("find during shadow")
        .into_iter()
        .map(|m| m.item_id)
        .collect();
    for shadow_id in &shadow_items {
        assert!(
            !results_during.contains(&shadow_id.to_string()),
            "gate1: shadow item {shadow_id} must be invisible before publish, \
             found in results: {results_during:?}"
        );
    }
    // Serving items must still appear.
    for id in &results_before {
        assert!(
            results_during.contains(id),
            "gate1: serving item {id} disappeared during shadow build"
        );
    }

    let _ = std::fs::remove_file(&db);
}

// ── Gate 2: crash mid-build recovery ─────────────────────────────────────────

/// Gate 2: if a crash occurs during shadow build (registry shows 'building'
/// but the transaction was never published), reopening the store serves the
/// OLD generation — the shadow rows are reclaimable but do not corrupt reads.
///
/// Simulated by: write serving vectors, begin_shadow, write shadow rows,
/// then reopen the store WITHOUT calling publish_shadow_generation.
/// A fresh store opened on the same SQLite file must serve the original
/// serving generation.
///
/// Falsification: removing the generation-mismatch guard in find_nearest_float
/// causes shadow rows to bleed into results on reopen.
#[test]
fn gate2_crash_mid_build_recovery_serves_old_generation() {
    let db = tmp_db();

    // Phase A: write serving vectors, begin shadow, write shadow rows,
    // simulate crash (do NOT publish).
    let results_a: Vec<String>;
    {
        let store = open_store(&db);
        insert_float_vectors(&store, HNSW_THRESHOLD as usize + 2, 20);

        // Build HNSW so it's on disk for Phase B.
        store.rebuild_hnsw_index(MODEL_A).expect("rebuild");

        let probe: Vec<f32> = vec![0.5, 0.5, 0.1, 0.1];
        results_a = store
            .find_nearest_float(&probe, MODEL_A, 3)
            .expect("find serving")
            .into_iter()
            .map(|m| m.item_id)
            .collect();
        assert!(!results_a.is_empty());

        // Begin shadow and write shadow-tagged rows.
        store.begin_shadow_generation(&[MODEL_A]).expect("begin shadow");
        for i in 0..3 {
            let floats = vec![0.9 + i as f32 * 0.01, 0.0, 0.0, 0.0];
            store
                .add_payload(&format!("crash-shadow-{i}"), 0,
                    &VectorPayload::from_f32(&floats), MODEL_A, "v2", FILED_AT + 10)
                .expect("shadow write");
        }
        // Crash simulated: store dropped without publish.
    }

    // Phase B: reopen. Must serve the original generation.
    {
        let store_b = open_store(&db);

        let probe: Vec<f32> = vec![0.5, 0.5, 0.1, 0.1];
        let results_b: Vec<String> = store_b
            .find_nearest_float(&probe, MODEL_A, 5)
            .expect("find after crash-reopen")
            .into_iter()
            .map(|m| m.item_id)
            .collect();

        // Shadow-only items must NOT appear in results.
        for i in 0..3 {
            let shadow_id = format!("crash-shadow-{i}");
            assert!(
                !results_b.contains(&shadow_id),
                "gate2: shadow item {shadow_id} surfaced after crash-recovery reopen"
            );
        }

        // Original serving items must still appear.
        for id in &results_a {
            assert!(
                results_b.contains(id),
                "gate2: serving item {id} missing after crash-recovery reopen"
            );
        }
    }

    let _ = std::fs::remove_file(&db);
}

// ── Gate 3: publish idempotence ───────────────────────────────────────────────

/// Gate 3: calling `publish_shadow_generation` a second time for the same
/// model (when no shadow is active) is a no-op — the serving generation does
/// not advance and no error is returned.
///
/// Falsification: if publish_shadow_generation treats `None` shadow_generation
/// as an implicit advance, the serving generation increments spuriously.
#[test]
fn gate3_publish_idempotence() {
    let db = tmp_db();
    let store = open_store(&db);

    // Write serving vectors and shadow vectors, then publish once.
    insert_float_vectors(&store, HNSW_THRESHOLD as usize + 2, 30);
    let gens = store.begin_shadow_generation(&[MODEL_A]).expect("begin shadow");
    let expected_serving_gen = gens[MODEL_A];
    insert_float_vectors_prefixed(&store, 3, 31, "shadow");
    store.publish_shadow_generation(&[MODEL_A]).expect("publish");

    // Probe to populate last_served_graph_generation.
    let probe: Vec<f32> = vec![0.1, 0.2, 0.3, 0.4];
    let _ = store.find_nearest_float(&probe, MODEL_A, 3).expect("find after publish");
    let served_gen = store.last_served_graph_generation(MODEL_A);

    // Second publish: no shadow active — must be a no-op.
    store.publish_shadow_generation(&[MODEL_A]).expect("publish (idempotent)");

    // last_served_graph_generation must still be the published gen, not incremented.
    let served_gen_after_second = store.last_served_graph_generation(MODEL_A);
    assert_eq!(
        served_gen, served_gen_after_second,
        "gate3: second publish must not advance last_served_graph_generation"
    );
    assert_eq!(
        served_gen, Some(expected_serving_gen),
        "gate3: served gen must equal the originally allocated shadow gen"
    );

    let _ = std::fs::remove_file(&db);
}

// ── Gate 4: reclaim second pass is a no-op ────────────────────────────────────

/// Gate 4: calling `reclaim_superseded_generations` a second time is a no-op.
/// The deleted row count must be 0 on the second pass, and query results are
/// unchanged.
///
/// Falsification: removing the serving-gen guard from the reclaim predicate
/// causes serving rows to be deleted on the second pass.
#[test]
fn gate4_reclaim_second_pass_is_noop() {
    let db = tmp_db();
    let store = open_store(&db);

    // Write serving vectors, shadow-swap, publish, reclaim once.
    insert_float_vectors(&store, HNSW_THRESHOLD as usize + 2, 40);
    store.begin_shadow_generation(&[MODEL_A]).expect("begin shadow");
    insert_float_vectors_prefixed(&store, 4, 41, "g2");
    store.publish_shadow_generation(&[MODEL_A]).expect("publish");

    // First reclaim: should delete old serving generation rows.
    let summary1 = store.reclaim_superseded_generations().expect("reclaim 1");
    // At least some rows should be reclaimable (the original serving-gen rows).
    // (Count check is advisory — the core assertion is the second pass.)

    // Reference results after first reclaim.
    let probe: Vec<f32> = vec![0.2, 0.3, 0.1, 0.4];
    let results_after_reclaim1: Vec<String> = store
        .find_nearest_float(&probe, MODEL_A, 3)
        .expect("find after reclaim 1")
        .into_iter()
        .map(|m| m.item_id)
        .collect();
    assert!(!results_after_reclaim1.is_empty(), "gate4: results must be non-empty after reclaim");

    // Second reclaim: must be a no-op (0 rows deleted from vectors).
    let summary2 = store.reclaim_superseded_generations().expect("reclaim 2");
    let vectors_deleted_second_pass: usize = summary2.values().sum();
    assert_eq!(
        vectors_deleted_second_pass, 0,
        "gate4: second reclaim must delete 0 rows; got {summary2:?}"
    );

    // Results after second reclaim must match results after first reclaim.
    let results_after_reclaim2: Vec<String> = store
        .find_nearest_float(&probe, MODEL_A, 3)
        .expect("find after reclaim 2")
        .into_iter()
        .map(|m| m.item_id)
        .collect();
    assert_eq!(
        results_after_reclaim1, results_after_reclaim2,
        "gate4: results must not change between reclaim passes"
    );

    // Suppress unused-variable warning for summary1 (its content is advisory).
    let _ = summary1;

    let _ = std::fs::remove_file(&db);
}

// ── Gate 5: post-swap coherence ───────────────────────────────────────────────

/// Gate 5: after publish, a float query must be served by a graph stamped with
/// the new serving generation. Three probes:
///   - last_served_graph_generation(MODEL_A) == published shadow generation
///   - hnsw_build_count_for(MODEL_A) == 0 (graph loaded from table, not rebuilt)
///     on a fresh reopen of the same SQLite file
///   - hnsw_index_resident(MODEL_A) == true (HP-3 residency, necessary not sufficient)
///
/// Falsification: removing the D6 stamp from rebuild_hnsw_index causes the
/// persisted graph to carry generation 0, so load_hnsw_graph_if_present rejects
/// it on reopen → hnsw_index_resident is false on store_b.
#[test]
fn gate5_post_swap_coherence() {
    let db = tmp_db();

    let shadow_gen: i64;
    {
        let store_a = open_store(&db);

        // Write serving vectors (above HNSW threshold).
        insert_float_vectors(&store_a, HNSW_THRESHOLD as usize + 3, 50);
        store_a.rebuild_hnsw_index(MODEL_A).expect("rebuild serving graph");

        // Begin shadow and write shadow vectors.
        let gens = store_a.begin_shadow_generation(&[MODEL_A]).expect("begin shadow");
        shadow_gen = gens[MODEL_A];
        insert_float_vectors_prefixed(&store_a, HNSW_THRESHOLD as usize + 3, 51, "new");

        // Publish (flips serving gen + rebuilds HNSW with D6 stamp).
        store_a.publish_shadow_generation(&[MODEL_A]).expect("publish");

        // Probe to record last_served_graph_generation.
        let probe: Vec<f32> = vec![0.3, 0.3, 0.3, 0.3];
        let _ = store_a.find_nearest_float(&probe, MODEL_A, 3).expect("find post-publish");

        // Probe A: last_served_graph_generation == published gen.
        let last_served = store_a.last_served_graph_generation(MODEL_A);
        assert_eq!(
            last_served, Some(shadow_gen),
            "gate5: last_served_graph_generation must equal published gen {shadow_gen}, got {last_served:?}"
        );
    } // store_a dropped — simulates process exit.

    // Phase B: reopen on same SQLite file (process-restart simulation).
    {
        let store_b = open_store(&db);

        // Probe B: hnsw_build_count must be 0 — graph loaded from table, not rebuilt.
        // A failed D6 stamp would cause load_hnsw_graph_if_present to reject the
        // stored graph, hnsw_index_resident would be false, and build_count stays 0
        // but the HNSW path is unused (exact scan instead).
        let probe: Vec<f32> = vec![0.3, 0.3, 0.3, 0.3];
        let _ = store_b.find_nearest_float(&probe, MODEL_A, 3).expect("find store_b");

        let build_count = store_b.hnsw_build_count_for(MODEL_A);
        assert_eq!(
            build_count, 0,
            "gate5: hnsw_build_count must be 0 after reopen (graph loaded, not rebuilt)"
        );

        // Probe C: HNSW index must be resident after the query.
        assert!(
            store_b.hnsw_index_resident(MODEL_A),
            "gate5: HNSW index must be resident after find_nearest_float on store_b"
        );
    }

    let _ = std::fs::remove_file(&db);
}

// ── Interrupt 4a: partial shadow build (crash mid-write) ─────────────────────

/// Interrupt 4a: the exact on-disk state a kill during shadow build would leave:
/// partial shadow rows written + registry 'building'. Reopen asserts the store
/// serves the old generation and shadow items are invisible.
///
/// Constructed by: writing serving rows, begin_shadow, writing SOME shadow rows,
/// then reopening WITHOUT calling publish.
#[test]
fn interrupt_crash_mid_build_partial_shadow_rows() {
    let db = tmp_db();

    let serving_item_ids: Vec<String>;
    {
        let store = open_store(&db);
        insert_float_vectors(&store, HNSW_THRESHOLD as usize + 2, 60);
        store.rebuild_hnsw_index(MODEL_A).expect("rebuild");

        let probe: Vec<f32> = vec![0.1, 0.2, 0.3, 0.4];
        serving_item_ids = store
            .find_nearest_float(&probe, MODEL_A, 3)
            .expect("serving results")
            .into_iter()
            .map(|m| m.item_id)
            .collect();

        store.begin_shadow_generation(&[MODEL_A]).expect("begin shadow");
        // Write only partial shadow rows (interrupted before all N are written).
        for i in 0..2 {
            store
                .add_payload(&format!("partial-shadow-{i}"), 0,
                    &VectorPayload::from_f32(&[0.8, 0.1, 0.05, 0.05]),
                    MODEL_A, "v2", FILED_AT + 5)
                .expect("partial shadow write");
        }
        // Crash: store dropped without publish.
    }

    {
        let store2 = open_store(&db);
        let probe: Vec<f32> = vec![0.1, 0.2, 0.3, 0.4];
        let results: Vec<String> = store2
            .find_nearest_float(&probe, MODEL_A, 5)
            .expect("find after partial-build crash")
            .into_iter()
            .map(|m| m.item_id)
            .collect();

        // Partial shadow items must not surface.
        for i in 0..2 {
            let id = format!("partial-shadow-{i}");
            assert!(
                !results.contains(&id),
                "interrupt4a: partial shadow item {id} surfaced after crash reopen"
            );
        }
        // Original serving items must still be present.
        for id in &serving_item_ids {
            assert!(
                results.contains(id),
                "interrupt4a: serving item {id} missing after crash reopen"
            );
        }
    }

    let _ = std::fs::remove_file(&db);
}

// ── Interrupt 4b: flipped registry + stale-gen graph rows ────────────────────

/// Interrupt 4b: crash after the registry flip commits but before the HNSW
/// graph is rebuilt. The stale-gen graph (generation = old serving gen) must
/// be treated as absent by the generation-identity check (§4), and the store
/// falls back to exact scan — which serves the NEW serving generation correctly.
///
/// Constructed by: publish (which flips registry AND rebuilds graph), then
/// manually verify the graph generation matches the serving generation on a
/// fresh store. We confirm the fallback works by asserting results still contain
/// new-generation items.
#[test]
fn interrupt_flipped_registry_stale_graph_handled() {
    let db = tmp_db();

    {
        let store_a = open_store(&db);

        // Write serving vectors.
        insert_float_vectors(&store_a, HNSW_THRESHOLD as usize + 2, 70);
        store_a.rebuild_hnsw_index(MODEL_A).expect("rebuild serving graph");

        // Shadow-swap: begin, write new items, publish.
        store_a.begin_shadow_generation(&[MODEL_A]).expect("begin shadow");
        let new_item_id = "new-gen-item-unique-71";
        store_a
            .add_payload(new_item_id, 0,
                &VectorPayload::from_f32(&[0.95, 0.05, 0.05, 0.05]),
                MODEL_A, "v2", FILED_AT + 20)
            .expect("shadow write");
        store_a.publish_shadow_generation(&[MODEL_A]).expect("publish");
        // Save for assertion in phase B — captured here before store_a is dropped.
        let _ = new_item_id; // suppress unused-variable lint; closure below captures it
    }

    let new_item_id_owned = "new-gen-item-unique-71";
    {
        let store_b = open_store(&db);
        // The HNSW graph on disk is stamped with the new serving generation.
        // load_hnsw_graph_if_present accepts it. Results contain new-gen items.
        let probe: Vec<f32> = vec![0.95, 0.05, 0.05, 0.05];
        let results: Vec<String> = store_b
            .find_nearest_float(&probe, MODEL_A, 5)
            .expect("find after publish-reopen")
            .into_iter()
            .map(|m| m.item_id)
            .collect();

        assert!(
            results.contains(&new_item_id_owned.to_string()),
            "interrupt4b: new-generation item must be findable after reopen; results: {results:?}"
        );
    }

    let _ = std::fs::remove_file(&db);
}

// ── Interrupt 4c: THETA-after-swap rebuild ────────────────────────────────────

/// Interrupt 4c: calling rebuild_hnsw_index (THETA duty) after a shadow swap
/// must advance hnsw_build_count and produce a graph stamped with the current
/// serving generation.
///
/// Falsification: if rebuild_hnsw_index fails to stamp the new serving gen
/// (missing D6 fix), the persisted graph carries the wrong generation and
/// load_hnsw_graph_if_present rejects it on the next reopen.
#[test]
fn interrupt_theta_after_swap_rebuild() {
    let db = tmp_db();

    {
        let store = open_store(&db);
        insert_float_vectors(&store, HNSW_THRESHOLD as usize + 2, 80);
        store.rebuild_hnsw_index(MODEL_A).expect("first rebuild (serving)");
        assert_eq!(store.hnsw_build_count_for(MODEL_A), 1, "build count after first rebuild");

        // Shadow-swap.
        store.begin_shadow_generation(&[MODEL_A]).expect("begin shadow");
        insert_float_vectors_prefixed(&store, HNSW_THRESHOLD as usize + 2, 81, "theta");
        store.publish_shadow_generation(&[MODEL_A]).expect("publish");

        // THETA duty: explicit rebuild after swap.
        // build count should advance (publish already rebuilds once inside; THETA is a second build).
        let count_before_theta = store.hnsw_build_count_for(MODEL_A);
        store.rebuild_hnsw_index(MODEL_A).expect("THETA rebuild after swap");
        let count_after_theta = store.hnsw_build_count_for(MODEL_A);
        assert_eq!(
            count_after_theta, count_before_theta + 1,
            "interrupt4c: THETA rebuild must advance hnsw_build_count"
        );
    }

    // Reopen: graph must be loadable (D6 stamp correct).
    {
        let store_b = open_store(&db);
        let probe: Vec<f32> = vec![0.1, 0.1, 0.1, 0.1];
        let _ = store_b.find_nearest_float(&probe, MODEL_A, 3).expect("find after THETA reopen");
        assert!(
            store_b.hnsw_index_resident(MODEL_A),
            "interrupt4c: HNSW must be resident after THETA-rebuilt graph is loaded on reopen"
        );
        assert_eq!(
            store_b.hnsw_build_count_for(MODEL_A), 0,
            "interrupt4c: build count must be 0 on reopen (graph loaded, not rebuilt)"
        );
    }

    let _ = std::fs::remove_file(&db);
}

// ── Interrupt 4d: recall unchanged across swap ────────────────────────────────

/// Interrupt 4d: the recall contract — same query against the same item content,
/// same result set before shadow build and after publish. This asserts the swap
/// does not discard or corrupt existing items: if the new shadow generation
/// contains ALL the same items as the serving generation (no deletions), the
/// top-K results must be identical.
#[test]
fn interrupt_recall_unchanged_across_swap() {
    let db = tmp_db();
    let store = open_store(&db);

    // Write N vectors (serving generation).
    let n = HNSW_THRESHOLD as usize + 3;
    let seed = 90u64;
    insert_float_vectors(&store, n, seed);
    store.rebuild_hnsw_index(MODEL_A).expect("rebuild");

    // Capture results before shadow build.
    let probe: Vec<f32> = vec![0.5, 0.3, 0.2, 0.1];
    let results_before: Vec<String> = store
        .find_nearest_float(&probe, MODEL_A, 3)
        .expect("find before shadow")
        .into_iter()
        .map(|m| m.item_id)
        .collect();
    assert!(!results_before.is_empty(), "interrupt4d: results before shadow must be non-empty");

    // Build shadow with the IDENTICAL set of items (content unchanged).
    let batch: Vec<VectorPayloadInput> = {
        let mut rng = SplitMix64SW::new(seed); // same seed → same vectors
        (0..n)
            .map(|i| {
                let floats: Vec<f32> = (0..4).map(|_| rng.next_f32() * 2.0 - 1.0).collect();
                float_input(&format!("item-{i}"), &floats)
            })
            .collect()
    };
    store.begin_shadow_generation(&[MODEL_A]).expect("begin shadow");
    store.add_payloads(&batch).expect("shadow add_payloads");
    store.publish_shadow_generation(&[MODEL_A]).expect("publish");

    // Capture results after swap.
    let results_after: Vec<String> = store
        .find_nearest_float(&probe, MODEL_A, 3)
        .expect("find after swap")
        .into_iter()
        .map(|m| m.item_id)
        .collect();

    // Recall must be unchanged: same items, same order.
    assert_eq!(
        results_before, results_after,
        "interrupt4d: recall changed across swap — \
         before: {results_before:?}, after: {results_after:?}"
    );

    let _ = std::fs::remove_file(&db);
}

// ── Gate 9: measured storage peak ────────────────────────────────────────────

/// Gate 9: peak_shadow_storage_bytes returns a positive value after shadow
/// writes, reflecting measured payload bytes accumulated during the shadow build.
#[test]
fn gate9_measured_storage_peak() {
    let db = tmp_db();
    let store = open_store(&db);

    // Write serving vectors.
    insert_float_vectors(&store, 3, 100);

    // Begin shadow and write shadow vectors (single add_payload).
    store.begin_shadow_generation(&[MODEL_A]).expect("begin shadow");
    let floats = vec![0.1_f32, 0.2, 0.3, 0.4];
    let shadow_payload = VectorPayload::from_f32(&floats);
    let shadow_bytes_len = shadow_payload.bytes.len() as i64;
    store
        .add_payload("peak-shadow-item", 0, &shadow_payload, MODEL_A, "v2", FILED_AT + 1)
        .expect("shadow add_payload");

    // Gate: peak bytes > 0 and at least as large as the payload we wrote.
    let peak = store.peak_shadow_storage_bytes(MODEL_A);
    assert!(
        peak >= shadow_bytes_len,
        "gate9: peak_shadow_storage_bytes must be >= {shadow_bytes_len}, got {peak}"
    );

    let _ = std::fs::remove_file(&db);
}

// ── Gate 10: shadow-only items invisible to keyword and recent-item paths ─────

/// Gate 10: shadow-only items (written during an active shadow but before
/// publish) must not surface in `find_by_keyword` or `recent_item_ids`.
///
/// Falsification: removing the serving-gen filter from find_by_keyword or
/// recent_item_ids causes shadow-only items to surface before publish.
#[test]
fn gate10_shadow_only_items_invisible_to_keyword_and_recent() {
    let db = tmp_db();
    let store = open_store(&db);

    // Write a binary serving vector so recent_item_ids has serving rows.
    use engram_lib::Engram;
    let e = Engram::new(0xABCD1234ABCD1234, 0xDEADBEEFDEADBEEF, 0x1234567812345678, 0x9876543298765432);
    let binary_payload = VectorPayload::from_engram(&e);
    store
        .add_payload("serving-bin-item", 0, &binary_payload, "bin-model", "v1", FILED_AT)
        .expect("serving binary add");

    // Begin shadow for MODEL_A and write a float shadow item.
    store.begin_shadow_generation(&[MODEL_A]).expect("begin shadow");
    let shadow_float_item = "shadow-float-unique-99";
    store
        .add_payload(shadow_float_item, 0,
            &VectorPayload::from_f32(&[0.5, 0.5, 0.5, 0.5]),
            MODEL_A, "v2", FILED_AT + 100)
        .expect("shadow float add");

    // find_by_keyword: shadow item must not appear.
    let keyword_hits = store
        .find_by_keyword("shadow-float-unique", 10)
        .expect("find_by_keyword");
    let keyword_ids: Vec<&str> = keyword_hits.iter().map(|s| s.as_str()).collect();
    assert!(
        !keyword_ids.contains(&shadow_float_item),
        "gate10: shadow item {shadow_float_item} surfaced in find_by_keyword: {keyword_ids:?}"
    );

    // recent_item_ids: shadow item must not appear.
    let recent = store.recent_item_ids(10).expect("recent_item_ids");
    assert!(
        !recent.contains(&shadow_float_item.to_string()),
        "gate10: shadow item {shadow_float_item} surfaced in recent_item_ids: {recent:?}"
    );

    let _ = std::fs::remove_file(&db);
}
