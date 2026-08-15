//! HNSW graph persistence tests — VEC-HNSW-01 exit gates (Rust port).
//!
//! Covers the four contractual exit gates defined in the mission spec:
//!
//!   HP-1 (gates A + B): After rebuild, assert `hnsw_graph` row count > 0 (gate A)
//!     and that a fresh store opened on the same SQLite estate loads the graph
//!     without rebuilding (`hnsw_build_count == 0`, gate B). Results must match.
//!
//!   HP-2 (gate D): A store with no persisted graph (hnsw_graph table empty) falls
//!     back to exact scan immediately. No inline build fires on the query path;
//!     `hnsw_build_count` stays at 0.
//!
//!   HP-3 (gate C): Tombstone a vector while the graph is on disk. Reopen a fresh
//!     store. Assert the deleted item is NOT returned as a live neighbour.
//!
//! HNSW threshold is set to 10 so tests activate the HNSW path without 5,000 vectors.
//! SplitMix64HP (local struct, seed-per-test) ensures deterministic corpora without
//! colliding with the unit-test seeds in hnsw_index.rs.
//! Cross-port determinism NOT required (Rust and Swift graphs legitimately differ).

use std::sync::Arc;
use persistence_kit::{BackendConfiguration, EstateConfiguration, SqliteStorage};
use persistence_kit::Storage;
use uuid::Uuid;
use vectorkit::{VectorPayload, VectorStore};

const MODEL_ID: &str = "hnsw-persist-model";
// HNSW threshold lowered to 10 so tests activate the HNSW path without 5,000 vectors.
const HNSW_THRESHOLD: u32 = 10;
// Number of vectors inserted in HP-1 and HP-3 (above threshold).
const N: usize = 20;
const FILED_AT: i64 = 1_700_000_000;

// ── SplitMix64HP RNG (local copy — avoids cross-suite seed collisions) ────────

struct SplitMix64HP {
    state: u64,
}

impl SplitMix64HP {
    fn new(seed: u64) -> Self {
        SplitMix64HP { state: seed }
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

// ── Storage helpers ───────────────────────────────────────────────────────────

/// Construct a SQLite-backed storage for the given file path.
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

/// Open a VectorStore with HNSW threshold 10 on the given SQLite file.
/// Opens the schema on the storage (idempotent for subsequent opens on same DB).
fn open_store(path: &str) -> VectorStore {
    let storage = make_sqlite_storage(path);
    VectorStore::open_with_hnsw_threshold(storage, HNSW_THRESHOLD)
        .expect("open VectorStore")
}

/// Insert `count` random 4-d float vectors into `store` for MODEL_ID.
/// Uses SplitMix64HP with `seed` so the corpus is deterministic.
fn insert_random_float_vectors(store: &VectorStore, count: usize, seed: u64) {
    let mut rng = SplitMix64HP::new(seed);
    for i in 0..count {
        let floats: Vec<f32> = (0..4).map(|_| rng.next_f32() * 2.0 - 1.0).collect();
        let payload = VectorPayload::from_f32(&floats);
        store
            .add_payload(
                &format!("item-{}", i),
                0,
                &payload,
                MODEL_ID,
                "1",
                FILED_AT,
            )
            .expect("add float payload");
    }
}

// ── HC regression tests (VH-01 Findings A, B, C) ─────────────────────────────
//
// These tests are designed to FAIL against the pre-fix code and PASS after.
// See MISSION_VH_01.md Part 6 for the regression coverage specification.

// ── HC-A-1: cache coherence — deleted vector not returned after rebuild ────────

/// HC-A-1 (VH-01 Finding A REGRESSION): after rebuilding the HNSW graph and
/// then deleting a vector, `find_nearest_float` must NOT return the deleted item.
///
/// Without the fix, `delete_vector` cleared `float_indices[model_id]` but left
/// `hnsw_indices[model_id]` resident. The next `find_nearest_float` routed through
/// the stale HNSW graph, which still owned item-1's raw vector bytes, and returned
/// it as a live result.
///
/// With the fix, `_invalidate_hnsw_lane` evicts `hnsw_indices[model_id]` alongside
/// `float_indices[model_id]`. The next query reloads from `hnsw_graph`; item-1's
/// placeholder tombstone is excluded because its float bytes are gone from `vectors`.
///
/// NOTE — partial discrimination: the Rust port's 8 HNSW lane-invalidation call
/// sites were already correct before the VH-01 fixes were applied. This test passes
/// on both pre-fix and post-fix Rust code. It is retained as a parity safeguard so
/// a future regression in the Rust invalidation path would be caught, but it does
/// not isolate a Rust-specific Finding A defect.
#[test]
fn hca1_deleted_vector_not_returned_after_rebuild() {
    let db_path = std::env::temp_dir()
        .join(format!("vk_hca1_{}.db", Uuid::new_v4()))
        .to_string_lossy()
        .to_string();

    let victim_id = "item-1";

    // Build the HNSW graph so it is resident in memory.
    let store = open_store(&db_path);
    insert_random_float_vectors(&store, N, 0xCAFE_BABE_1234_5678);

    // THETA rebuild: builds graph in memory AND persists to hnsw_graph.
    store.rebuild_hnsw_index(MODEL_ID).expect("rebuild");

    // Verify HNSW is resident (baseline).
    assert!(
        store.hnsw_index_resident(MODEL_ID),
        "HC-A-1 setup: HNSW must be resident after rebuild"
    );

    // Delete item-1 from the estate. The fix: this must evict hnsw_indices[MODEL_ID].
    store
        .delete_vector(victim_id, MODEL_ID)
        .expect("delete vector");

    // Probe near item-1's direction to maximise chance it would appear if
    // the stale HNSW graph is still resident.
    let mut rng = SplitMix64HP::new(0xCAFE_BABE_1234_5678);
    // Skip item-0's 4 floats.
    for _ in 0..4 { rng.next_f32(); }
    let probe: Vec<f32> = (0..4).map(|_| rng.next_f32() * 2.0 - 1.0).collect();

    let results: Vec<String> = store
        .find_nearest_float(&probe, MODEL_ID, N)
        .expect("find nearest")
        .into_iter()
        .map(|m| m.item_id)
        .collect();

    assert!(
        !results.contains(&victim_id.to_string()),
        "HC-A-1 (VH-01 Finding A REGRESSION): deleted '{}' must NOT appear in find_nearest_float; \
         the HNSW graph must be evicted on delete_vector. Got: {:?}",
        victim_id, results
    );

    let _ = std::fs::remove_file(&db_path);
}

// ── HC-A-2: destroy_all_vectors leaves no HNSW graph resident ────────────────

/// HC-A-2 (VH-01 Finding A REGRESSION): after `destroy_all_vectors`, a subsequent
/// `find_nearest_float` must return empty results.
///
/// Without the fix, `destroy_all_vectors` cleared `float_indices` but not
/// `hnsw_indices`. The HNSW graph remained resident and could serve items from
/// a logically-empty estate.
///
/// With the fix, `destroy_all_vectors` clears `hnsw_indices`, `live_float_counts`,
/// `hnsw_graph_dirty`, AND deletes every persisted `hnsw_graph` row.
#[test]
fn hca2_destroy_all_vectors_leaves_no_graph() {
    let db_path = std::env::temp_dir()
        .join(format!("vk_hca2_{}.db", Uuid::new_v4()))
        .to_string_lossy()
        .to_string();

    let store = open_store(&db_path);
    insert_random_float_vectors(&store, N, 0xDEAD_BEEF_CAFE_BABE);
    store.rebuild_hnsw_index(MODEL_ID).expect("rebuild");

    assert!(
        store.hnsw_index_resident(MODEL_ID),
        "HC-A-2 setup: HNSW must be resident after rebuild"
    );

    // Full teardown.
    store.destroy_all_vectors().expect("destroy all vectors");

    let mut rng = SplitMix64HP::new(111);
    let probe: Vec<f32> = (0..4).map(|_| rng.next_f32() * 2.0 - 1.0).collect();
    let results = store
        .find_nearest_float(&probe, MODEL_ID, N)
        .expect("find nearest after destroy");

    assert!(
        results.is_empty(),
        "HC-A-2 (VH-01 Finding A REGRESSION): find_nearest_float must return empty after destroy_all_vectors; \
         the HNSW graph must be fully torn down. Got {} results.",
        results.len()
    );

    let _ = std::fs::remove_file(&db_path);
}

// ── HC-B-1: entry-point repair — tombstone sequence never suppresses recall ────

/// HC-B-1 (VH-01 Finding B REGRESSION): tombstoning each node in sequence must
/// never suppress recall of remaining live nodes.
///
/// Without the fix, tombstoning the entry-point node left `entry_point` pointing
/// at the tombstoned node. `search_layer` entered at the dead seed, found no valid
/// greedy hops, and returned zero results — while `live_count > 0`.
///
/// With the fix, `repair_entry_point()` is called immediately after tombstoning.
/// It scans for the best remaining live node and promotes it, so search always
/// starts from a valid seed.
#[test]
fn hcb1_tombstone_sequence_never_suppresses_recall() {
    use vectorkit::engine::HNSWIndex;

    let mut idx = HNSWIndex::new(42);
    let model_id = "hcb1-model";

    idx.insert("a".to_string(), model_id.to_string(), vec![1.0, 0.0, 0.0]);
    idx.insert("b".to_string(), model_id.to_string(), vec![0.0, 1.0, 0.0]);
    idx.insert("c".to_string(), model_id.to_string(), vec![0.0, 0.0, 1.0]);

    let baseline = idx.search(&[1.0, 0.0, 0.0], model_id, 3).expect("baseline");
    assert!(!baseline.is_empty(), "HC-B-1 baseline: search must return results before any tombstone");

    // Tombstone "a" — "b" and "c" must remain reachable.
    idx.tombstone("a");
    let r1 = idx.search(&[0.0, 1.0, 0.0], model_id, 3).expect("search after tomb a");
    assert!(
        !r1.is_empty(),
        "HC-B-1 (VH-01 Finding B REGRESSION): after tombstoning 'a', live nodes must be reachable; \
         entry-point repair must have promoted a live seed. Got empty."
    );
    assert!(
        !r1.iter().any(|m| m.item_id == "a"),
        "HC-B-1: tombstoned 'a' must not appear in results"
    );

    // Tombstone "b" — only "c" remains.
    idx.tombstone("b");
    let r2 = idx.search(&[0.0, 0.0, 1.0], model_id, 3).expect("search after tomb b");
    assert!(
        !r2.is_empty(),
        "HC-B-1 (VH-01 Finding B REGRESSION): after tombstoning 'a' and 'b', 'c' must be reachable. Got empty."
    );
    assert_eq!(
        r2.iter().map(|m| m.item_id.as_str()).collect::<Vec<_>>(),
        vec!["c"],
        "HC-B-1: 'c' must be the sole result after 'a' and 'b' are tombstoned"
    );

    // All tombstoned — search must return empty.
    idx.tombstone("c");
    let r3 = idx.search(&[0.0, 0.0, 1.0], model_id, 3).expect("search after all tombstoned");
    assert!(
        r3.is_empty(),
        "HC-B-1: all nodes tombstoned — search must return empty. Got {:?}.",
        r3.iter().map(|m| &m.item_id).collect::<Vec<_>>()
    );
}

// ── HC-B-2: upsert does not suppress recall ───────────────────────────────────

/// HC-B-2 (VH-01 Finding B REGRESSION): calling `insert` on an existing item ID
/// (upsert) tombstones the old node. At least one upsert in a sequence will
/// tombstone the current entry point. Post-fix, search must stay non-empty after
/// every upsert because `repair_entry_point()` maintains a live seed.
#[test]
fn hcb2_upsert_does_not_suppress_recall() {
    use vectorkit::engine::HNSWIndex;

    let mut idx = HNSWIndex::new(42);
    let model_id = "hcb2-model";

    idx.insert("a".to_string(), model_id.to_string(), vec![1.0, 0.0, 0.0]);
    idx.insert("b".to_string(), model_id.to_string(), vec![0.0, 1.0, 0.0]);
    idx.insert("c".to_string(), model_id.to_string(), vec![0.0, 0.0, 1.0]);

    let upserts: &[(&str, Vec<f32>)] = &[
        ("a", vec![-1.0,  0.0,  0.0]),
        ("b", vec![ 0.0, -1.0,  0.0]),
        ("c", vec![ 0.0,  0.0, -1.0]),
    ];

    for (id, vec) in upserts {
        idx.insert(id.to_string(), model_id.to_string(), vec.clone());

        let live = idx.live_count();
        assert!(live >= 1, "HC-B-2 invariant: live_count must be >= 1 after upserting {}", id);

        let results = idx.search(&[1.0, 0.0, 0.0], model_id, 3).expect("search after upsert");
        assert!(
            !results.is_empty(),
            "HC-B-2 (VH-01 Finding B REGRESSION): after upserting '{}', search must return non-empty; \
             live_count={}, got empty — entry-point repair must maintain a live seed.",
            id, live
        );
    }
}

// ── HC-C-1: layer > HNSW_MAX_PERSISTED_LAYER rejects whole graph ──────────────

/// HC-C-1 (VH-01 Finding C REGRESSION): a row with `layer = HNSW_MAX_PERSISTED_LAYER + 1`
/// must cause the whole graph to be rejected. `has_graph()` must be false.
///
/// Without the fix, the row was processed; `has_graph()` would be true (wrong).
/// With the fix, Phase-0 rejects → `has_graph()` false.
#[test]
fn hcc1_huge_layer_rejected() {
    use vectorkit::engine::HNSWIndex;
    use vectorkit::engine::hnsw_index::HNSW_MAX_PERSISTED_LAYER;

    let mut idx = HNSWIndex::new(42);
    let model_id = "hcc1-model";

    let bad_row = vectorkit::GraphRow {
        node_idx:        0,
        node_id:         "x".to_string(),
        layer:           HNSW_MAX_PERSISTED_LAYER + 1,  // 33 — one above the cap
        neighbours_blob: Vec::new(),
    };

    let mut node_bytes = std::collections::HashMap::new();
    node_bytes.insert(0i32, ("x".to_string(), vec![0u8, 0, 0x80, 0x3f]));

    let rows = vec![bad_row];
    idx.load_from_graph_rows(&rows, &node_bytes, model_id);

    assert!(
        !idx.has_graph(),
        "HC-C-1 (VH-01 Finding C REGRESSION): row with layer={} (> max {}) must reject whole graph; \
         has_graph() must be false.",
        HNSW_MAX_PERSISTED_LAYER + 1, HNSW_MAX_PERSISTED_LAYER
    );
}

// ── HC-C-2: negative node_idx rejects whole graph ────────────────────────────

/// HC-C-2 (VH-01 Finding C REGRESSION): a row with `node_idx = -1` must reject
/// the whole graph. `has_graph()` must be false.
///
/// Without the fix, a negative i32 was used in downstream array lookups.
/// With the fix, Phase-0 checks `node_idx < 0` → rejects whole graph.
///
/// NOTE — partial discrimination: `node_bytes` is intentionally empty so the test
/// focuses on the Phase-0 guard. Pre-fix code would have reached the `node_bytes`
/// lookup for node_idx=-1, found nothing, and `continue`d — also leaving
/// `has_graph()=false`, but for the wrong reason (nodeBytes miss, not Phase-0 guard).
/// Both pre-fix and post-fix produce the same observable result for this input; the
/// guard versus the nodeBytes miss are indistinguishable from the outside. The
/// truly discriminating scenario requires nodeBytes[-1] to be populated, but i32
/// sign limitations make a negative key in a HashMap<i32, _> unusual in test code.
/// HC-F1 provides the F1/F7 discriminating test with a missing index-0 and live
/// index-1 and index-2.
#[test]
fn hcc2_negative_node_idx_rejected() {
    use vectorkit::engine::HNSWIndex;

    let mut idx = HNSWIndex::new(42);
    let model_id = "hcc2-model";

    let bad_row = vectorkit::GraphRow {
        node_idx:        -1,
        node_id:         "x".to_string(),
        layer:           0,
        neighbours_blob: Vec::new(),
    };

    let node_bytes = std::collections::HashMap::new();
    let rows = vec![bad_row];
    idx.load_from_graph_rows(&rows, &node_bytes, model_id);

    assert!(
        !idx.has_graph(),
        "HC-C-2 (VH-01 Finding C REGRESSION): row with node_idx=-1 must reject whole graph; has_graph() must be false."
    );
}

// ── HC-C-3: misaligned blob rejects whole graph ───────────────────────────────

/// HC-C-3 (VH-01 Finding C REGRESSION): a row whose `neighbours_blob` length is
/// not divisible by 4 must reject the whole graph.
///
/// Without the fix, `decode_neighbours` read as many 4-byte chunks as fit,
/// discarding the tail byte. No graph-level guard existed. `has_graph()` true.
/// With the fix, Phase-0 checks `blob_len % 4 != 0` → rejects.
#[test]
fn hcc3_misaligned_blob_rejected() {
    use vectorkit::engine::HNSWIndex;

    let mut idx = HNSWIndex::new(42);
    let model_id = "hcc3-model";

    let bad_row = vectorkit::GraphRow {
        node_idx:        0,
        node_id:         "x".to_string(),
        layer:           0,
        neighbours_blob: vec![0, 0, 0, 0, 0xFF],  // 5 bytes — not divisible by 4
    };

    let mut node_bytes = std::collections::HashMap::new();
    node_bytes.insert(0i32, ("x".to_string(), vec![0u8, 0, 0x80, 0x3f]));
    let rows = vec![bad_row];
    idx.load_from_graph_rows(&rows, &node_bytes, model_id);

    assert!(
        !idx.has_graph(),
        "HC-C-3 (VH-01 Finding C REGRESSION): 5-byte blob (misaligned) must reject whole graph; has_graph() must be false."
    );
}

// ── HC-C-4: oversized blob rejects whole graph ────────────────────────────────

/// HC-C-4 (VH-01 Finding C REGRESSION): a row whose `neighbours_blob` encodes more
/// than `HNSW_M0` neighbours must reject the whole graph.
///
/// Without the fix, `decode_neighbours` decoded `blob_len / 4` with no cap.
/// `has_graph()` would be true (wrong).
/// With the fix, Phase-0 checks `blob_len > HNSW_M0 * 4` → rejects.
#[test]
fn hcc4_oversized_blob_rejected() {
    use vectorkit::engine::HNSWIndex;
    use vectorkit::engine::hnsw_index::HNSW_M0;

    let mut idx = HNSWIndex::new(42);
    let model_id = "hcc4-model";

    // HNSW_M0 = 32 → max blob = 128 bytes. Use 132 bytes (33 Int32 entries).
    let oversized_blob = vec![0u8; (HNSW_M0 + 1) * 4];
    let bad_row = vectorkit::GraphRow {
        node_idx:        0,
        node_id:         "x".to_string(),
        layer:           0,
        neighbours_blob: oversized_blob,
    };

    let mut node_bytes = std::collections::HashMap::new();
    node_bytes.insert(0i32, ("x".to_string(), vec![0u8, 0, 0x80, 0x3f]));
    let rows = vec![bad_row];
    idx.load_from_graph_rows(&rows, &node_bytes, model_id);

    assert!(
        !idx.has_graph(),
        "HC-C-4 (VH-01 Finding C REGRESSION): {}-byte blob (> {} max) must reject whole graph; has_graph() must be false.",
        (HNSW_M0 + 1) * 4, HNSW_M0 * 4
    );
}

// ── HC-F1: tombstone at compact index 0 does not suppress search ─────────────

/// HC-F1 (VH-01 F1 discriminating): when nodeIdx=0 is absent from node_bytes
/// (deleted from `vectors` before reload), `load_from_graph_rows` must insert a
/// placeholder tombstone at compact index 0, NOT `continue` past it.
///
/// Without the F1 fix: `continue` shifts all subsequent compact indices down by one,
///   mis-wiring every neighbour edge. Neighbour "node 2" would address whatever
///   happened to land at index 1 after the skip.
///
/// With the F1 fix: a tombstone placeholder preserves compact addressing.
///   Entry-point election skips tombstones → `has_graph()` is true and search
///   returns live nodes.
///
/// NOTE: Rust is immune to the F7 stride regression that affected Swift (Rust
/// derives stride from `node_bytes`, the nodeIdx→bytes map, not the nodes Vec),
/// so search succeeds without a separate stride fix in Rust.
#[test]
fn hcf1_tombstone_at_compact_index_zero_does_not_suppress_search() {
    use vectorkit::engine::HNSWIndex;

    let mut idx = HNSWIndex::new(42);
    let model_id = "hcf1-model";

    // nodeIdx=0 absent from node_bytes — deleted from `vectors` before reload.
    // nodeIdx=1 and nodeIdx=2 are live 1-dimensional float vectors.
    let mut node_bytes = std::collections::HashMap::new();
    node_bytes.insert(1i32, ("live-b".to_string(), vec![0x00u8, 0x00, 0x80, 0x3f]));  // 1.0f LE
    node_bytes.insert(2i32, ("live-c".to_string(), vec![0x00u8, 0x00, 0x00, 0x3f]));  // 0.5f LE

    let rows = vec![
        vectorkit::GraphRow {
            node_idx:        0,
            node_id:         "deleted-a".to_string(),
            layer:           0,
            // Neighbours: [1, 2] in old nodeIdx space (LE i32).
            neighbours_blob: vec![0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00],
        },
        vectorkit::GraphRow {
            node_idx:        1,
            node_id:         "live-b".to_string(),
            layer:           0,
            neighbours_blob: vec![0x00, 0x00, 0x00, 0x00],  // neighbour: nodeIdx=0
        },
        vectorkit::GraphRow {
            node_idx:        2,
            node_id:         "live-c".to_string(),
            layer:           0,
            neighbours_blob: vec![0x00, 0x00, 0x00, 0x00],
        },
    ];

    idx.load_from_graph_rows(&rows, &node_bytes, model_id);

    assert!(
        idx.has_graph(),
        "HC-F1 Rust: graph must load with a tombstone placeholder at compact index 0"
    );

    // Rust is immune to F7 (stride from node_bytes map, not nodes Vec).
    // Search must return live nodes regardless of tombstone at index 0.
    let results = idx.search(&[1.0_f32], model_id, 5).expect("search must not fail");
    assert!(
        !results.is_empty(),
        "HC-F1 Rust REGRESSION (F1): search must return live nodes when compact index 0 \
         is a tombstone placeholder. Without F1, `continue` mis-wires neighbour edges."
    );
    assert!(
        !results.iter().any(|m| m.item_id == "deleted-a"),
        "HC-F1 Rust: the tombstone placeholder must not appear in search results"
    );
}

// ── HC-F2b: empty reload clears state ─────────────────────────────────────────

/// HC-F2b (VH-01 F2b discriminating): after loading a valid graph, calling
/// `load_from_graph_rows(&[], &{}, model_id)` must reset all state so that
/// `has_graph()` returns false.
///
/// Without the F2b fix: the empty-rows guard (`if rows.is_empty() { return }`) fired
///   before `self.clear()` → entryPoint/nodes survived → `has_graph()` stayed true.
///
/// With the F2b fix: `self.clear()` runs BEFORE the empty-rows check (matching
///   Swift's F2b reset block). An empty reload leaves a clean, empty index.
#[test]
fn hcf2b_empty_reload_clears_state() {
    use vectorkit::engine::HNSWIndex;

    let mut idx = HNSWIndex::new(42);
    let model_id = "hcf2b-model";

    // Step 1: load a valid 2-node graph.
    let mut node_bytes = std::collections::HashMap::new();
    node_bytes.insert(0i32, ("x".to_string(), vec![0x00u8, 0x00, 0x80, 0x3f]));
    node_bytes.insert(1i32, ("y".to_string(), vec![0x00u8, 0x00, 0x00, 0x3f]));

    let rows = vec![
        vectorkit::GraphRow { node_idx: 0, node_id: "x".to_string(), layer: 0,
                              neighbours_blob: vec![0x01, 0x00, 0x00, 0x00] },
        vectorkit::GraphRow { node_idx: 1, node_id: "y".to_string(), layer: 0,
                              neighbours_blob: vec![0x00, 0x00, 0x00, 0x00] },
    ];
    idx.load_from_graph_rows(&rows, &node_bytes, model_id);
    assert!(idx.has_graph(), "HC-F2b setup: graph must be resident after valid load");

    // Step 2: reload with empty rows.
    // Pre-fix F2b: early return without self.clear() → stale state → has_graph=true.
    // Post-fix F2b: self.clear() before empty guard → clean empty index → has_graph=false.
    let empty: Vec<vectorkit::GraphRow> = vec![];
    let empty_bytes: std::collections::HashMap<i32, (String, Vec<u8>)> = std::collections::HashMap::new();
    idx.load_from_graph_rows(&empty, &empty_bytes, model_id);

    assert!(
        !idx.has_graph(),
        "HC-F2b Rust REGRESSION: load_from_graph_rows(&[]) must reset all state; \
         has_graph() must be false after an empty reload on a previously-populated index."
    );
}

// ── HC-F2a: two-load sequence then full tombstone — no crash ──────────────────

/// HC-F2a (VH-01 F2a+F2b discriminating): after loading a 3-node graph and then
/// reloading with a 1-node graph, tombstoning the remaining node must cleanly set
/// `has_graph()=false` without accessing out-of-bounds memory.
///
/// Without F2b: the second `load_from_graph_rows` would APPEND the 1 new node to
///   the existing 3 (nodes never cleared). `tombstone("x")` would set nodes[3]
///   tombstoned while old nodes [0–2] remained live → `repair_entry_point` would
///   find a stale live entry → `has_graph()` stayed true (wrong).
///
/// Without F2a: if a stale entryPoint pointed past `nodes.len()` after a two-load
///   sequence, `repair_entry_point()` would access nodes[ep] out of bounds.
///   The F2a bounds guard prevents this panic.
///
/// With both fixes: second load fully resets state and rebuilds with 1 node;
///   `tombstone("x")` triggers a clean repair → `has_graph()=false`.
#[test]
fn hcf2a_two_load_sequence_then_tombstone_all_no_crash() {
    use vectorkit::engine::HNSWIndex;

    let mut idx = HNSWIndex::new(42);
    let model_id = "hcf2a-model";

    // Step 1: load a 3-node graph.
    let mut bytes3 = std::collections::HashMap::new();
    bytes3.insert(0i32, ("a".to_string(), vec![0x00u8, 0x00, 0x80, 0x3f]));
    bytes3.insert(1i32, ("b".to_string(), vec![0x00u8, 0x00, 0x00, 0x3f]));
    bytes3.insert(2i32, ("c".to_string(), vec![0x00u8, 0x00, 0x80, 0x3e]));

    let rows3 = vec![
        vectorkit::GraphRow { node_idx: 0, node_id: "a".to_string(), layer: 0,
                              neighbours_blob: vec![0x01, 0x00, 0x00, 0x00] },
        vectorkit::GraphRow { node_idx: 1, node_id: "b".to_string(), layer: 0,
                              neighbours_blob: vec![0x00, 0x00, 0x00, 0x00] },
        vectorkit::GraphRow { node_idx: 2, node_id: "c".to_string(), layer: 0,
                              neighbours_blob: vec![0x00, 0x00, 0x00, 0x00] },
    ];
    idx.load_from_graph_rows(&rows3, &bytes3, model_id);
    assert!(idx.has_graph(), "HC-F2a setup: 3-node graph must be resident");

    // Step 2: reload with a 1-node graph. F2b ensures self.clear() runs first.
    let mut bytes1 = std::collections::HashMap::new();
    bytes1.insert(0i32, ("x".to_string(), vec![0x00u8, 0x00, 0x80, 0x3f]));

    let rows1 = vec![
        vectorkit::GraphRow { node_idx: 0, node_id: "x".to_string(), layer: 0,
                              neighbours_blob: vec![] },
    ];
    idx.load_from_graph_rows(&rows1, &bytes1, model_id);
    assert!(idx.has_graph(), "HC-F2a: 1-node graph must be resident after second load");

    // Step 3: tombstone the only live node. repair_entry_point must not panic (F2a)
    // and has_graph() must become false (F2b guarantee).
    idx.tombstone("x");

    assert!(
        !idx.has_graph(),
        "HC-F2a Rust REGRESSION (F2a+F2b): after tombstoning the only node in the \
         second (smaller) load, has_graph() must be false. Without F2b, stale nodes \
         from the first load survive and keep has_graph() true."
    );
}

// ── HC-F3-store: store-layer corrupt row falls back to exact scan ─────────────

/// HC-F3-store (VH-01 F3 store-layer discriminating): verifies the F3 fix at the
/// Rust STORE layer (`query_hnsw_graph_rows`).
///
/// Without F3: the row-decode loop used `continue` on bad rows — one invalid row
///   was silently skipped and the remaining valid rows formed a partial graph.
///   `hnsw_index_resident` would return `true` (wrong).
///
/// With F3: the row-decode loop uses `return Ok(Vec::new())` on any invalid row —
///   one bad row abandons the WHOLE load. `hnsw_index_resident` stays `false`;
///   `find_nearest_float` falls back to exact scan and returns correct results.
///
/// The bad row is written directly to the `hnsw_graph` SQLite table via the
/// storage `RowStore`, exercising the store-layer decode path.
#[test]
fn hcf3_store_layer_corrupt_row_falls_back_to_exact_scan() {
    use vectorkit::engine::hnsw_index::HNSW_MAX_PERSISTED_LAYER;
    use persistence_kit::TypedValue;
    use std::collections::BTreeMap;

    // Use MODEL_ID ("hnsw-persist-model") so insert_random_float_vectors inserts
    // into the same partition that rebuild_hnsw_index and find_nearest_float query.
    let db_path = std::env::temp_dir()
        .join(format!("vk_hcf3_{}.db", Uuid::new_v4()))
        .to_string_lossy()
        .to_string();

    // Retain an Arc reference so we can insert rows directly into hnsw_graph.
    let storage = make_sqlite_storage(&db_path);
    let store = VectorStore::open_with_hnsw_threshold(storage.clone(), HNSW_THRESHOLD)
        .expect("open store");

    // Insert N items and rebuild to persist the graph for MODEL_ID.
    insert_random_float_vectors(&store, N, 0xF3_CAFE_BABE_1234);
    store.rebuild_hnsw_index(MODEL_ID).expect("rebuild");
    assert!(
        store.hnsw_index_resident(MODEL_ID),
        "HC-F3 setup: HNSW must be resident after rebuild"
    );

    // Poison: insert one bad hnsw_graph row directly into storage.
    // node_idx=99999 avoids primary-key conflict with the valid rows [0..N-1].
    // layer = HNSW_MAX_PERSISTED_LAYER + 1 triggers the F3 bounds check at the
    // store-layer decode loop: `row.layer > HNSW_MAX_PERSISTED_LAYER` → returns
    // `Ok(Vec::new())` (post-fix) instead of `continue` (pre-fix).
    let mut values = BTreeMap::new();
    values.insert("model_id".to_string(),   TypedValue::Text(MODEL_ID.to_string()));
    values.insert("node_idx".to_string(),   TypedValue::Int(99_999));
    values.insert("node_id".to_string(),    TypedValue::Text("_poison_".to_string()));
    values.insert("layer".to_string(),      TypedValue::Int((HNSW_MAX_PERSISTED_LAYER + 1) as i64));
    values.insert("neighbours".to_string(), TypedValue::Blob(vec![]));
    storage.row_store().insert("hnsw_graph", values)
        .expect("insert poison row");

    // delete_vector evicts the resident HNSW lane without touching hnsw_graph rows.
    // The next find_nearest_float must reload from hnsw_graph — where it encounters
    // the poison row.
    store.delete_vector("item-1", MODEL_ID).expect("delete vector");

    // Probe with a fresh vector.
    // 0xDEAD_BEEF_1234_5678 is a 64-bit seed; the probe only needs to be
    // deterministic and distinct from the corpus seed (0xF3_CAFE_BABE_1234).
    let mut rng = SplitMix64HP::new(0xDEAD_BEEF_1234_5678);
    let probe: Vec<f32> = (0..4).map(|_| rng.next_f32() * 2.0 - 1.0).collect();

    let results = store
        .find_nearest_float(&probe, MODEL_ID, N)
        .expect("find nearest");

    // Post-fix F3: poison row → return Ok(Vec::new()) → load abandoned →
    //   hnsw_index_resident=false → exact scan used.
    // Pre-fix F3: poison row skipped with `continue` → partial graph loaded →
    //   hnsw_index_resident=true (wrong).
    assert!(
        !store.hnsw_index_resident(MODEL_ID),
        "HC-F3 Rust REGRESSION (F3 store-layer): poison hnsw_graph row (layer={}) \
         must cause the WHOLE graph load to be abandoned. Pre-fix: `continue` skips \
         the bad row and loads a partial graph (resident=true). Post-fix: \
         `return Ok(Vec::new())` abandons the load (resident=false).",
        HNSW_MAX_PERSISTED_LAYER + 1
    );
    assert!(
        !results.is_empty(),
        "HC-F3 Rust: exact scan fallback must return results from the remaining {} items",
        N - 1
    );
    assert!(
        !results.iter().any(|m| m.item_id == "item-1"),
        "HC-F3 Rust: deleted item-1 must not appear in exact scan results"
    );

    let _ = std::fs::remove_file(&db_path);
}

// ── HP-1: exit gates A and B ──────────────────────────────────────────────────

/// HP-1: After THETA rebuild, `hnsw_graph` has rows (gate A). A fresh store
/// opened on the same SQLite file loads the graph without rebuilding
/// (`hnsw_build_count == 0`, gate B) and returns results matching the original.
#[test]
fn hp1_persist_and_restart_proof() {
    let db_path = std::env::temp_dir()
        .join(format!("vk_hp1_{}.db", Uuid::new_v4()))
        .to_string_lossy()
        .to_string();

    // ── Phase A: build and persist ────────────────────────────────────────────
    let query_floats: Vec<f32>;
    let results_a: Vec<String>;
    {
        let store_a = open_store(&db_path);
        insert_random_float_vectors(&store_a, N, 42);

        // THETA rebuild: re-inserts all vectors into a fresh HNSWIndex and persists.
        store_a.rebuild_hnsw_index(MODEL_ID).expect("rebuild");

        // Gate A: hnsw_graph table must have rows after rebuild.
        let row_count = store_a
            .hnsw_graph_row_count(MODEL_ID)
            .expect("row count");
        assert!(
            row_count > 0,
            "HP-1 gate A: hnsw_graph row count should be > 0 after rebuild, got 0"
        );

        // build_count on store_a should be 1 from the rebuild above.
        let build_count_a = store_a.hnsw_build_count_for(MODEL_ID);
        assert_eq!(build_count_a, 1, "HP-1: build count on store_a should be 1 after rebuild");

        // Run a query to capture reference results.
        let mut rng = SplitMix64HP::new(999);
        let q: Vec<f32> = (0..4).map(|_| rng.next_f32() * 2.0 - 1.0).collect();
        query_floats = q.clone();
        results_a = store_a
            .find_nearest_float(&q, MODEL_ID, 3)
            .expect("find nearest store_a")
            .into_iter()
            .map(|m| m.item_id)
            .collect();
        assert!(!results_a.is_empty(), "HP-1: results_a should be non-empty");
    } // store_a dropped — simulates process exit.

    // ── Phase B: reopen on same SQLite file (process-restart simulation) ──────
    {
        let store_b = open_store(&db_path);

        // Gate B: build count must be 0 — the graph was LOADED, not rebuilt.
        let build_count_b = store_b.hnsw_build_count_for(MODEL_ID);
        assert_eq!(
            build_count_b, 0,
            "HP-1 gate B: hnsw_build_count should be 0 after restart (load, not rebuild)"
        );

        // Results from store_b must match store_a.
        let results_b: Vec<String> = store_b
            .find_nearest_float(&query_floats, MODEL_ID, 3)
            .expect("find nearest store_b")
            .into_iter()
            .map(|m| m.item_id)
            .collect();

        assert_eq!(
            results_a, results_b,
            "HP-1 gate B: results must match across restart"
        );
    }

    let _ = std::fs::remove_file(&db_path);
}

// ── HP-2: exit gate D — fallback proof ────────────────────────────────────────

/// HP-2: A store with no persisted graph (hnsw_graph table empty) falls back
/// to exact scan immediately. `hnsw_build_count` stays 0 — no inline build
/// fires on the query path.
#[test]
fn hp2_absent_graph_fallback_proof() {
    let db_path = std::env::temp_dir()
        .join(format!("vk_hp2_{}.db", Uuid::new_v4()))
        .to_string_lossy()
        .to_string();

    let store = open_store(&db_path);
    // Insert enough vectors to cross the threshold (HNSW_THRESHOLD = 10).
    insert_random_float_vectors(&store, N, 77);

    // Do NOT call rebuild_hnsw_index. The hnsw_graph table is empty.
    let row_count = store
        .hnsw_graph_row_count(MODEL_ID)
        .expect("row count");
    assert_eq!(row_count, 0, "HP-2: hnsw_graph table should be empty before any rebuild");

    // Query should succeed via exact scan fallback — no panic, results non-empty.
    let mut rng = SplitMix64HP::new(888);
    let q: Vec<f32> = (0..4).map(|_| rng.next_f32() * 2.0 - 1.0).collect();
    let results = store
        .find_nearest_float(&q, MODEL_ID, 3)
        .expect("find nearest (fallback path)");
    assert!(!results.is_empty(), "HP-2: exact-scan fallback should return results");

    // Gate D: no inline build should have fired on the query path.
    let build_count = store.hnsw_build_count_for(MODEL_ID);
    assert_eq!(
        build_count, 0,
        "HP-2 gate D: hnsw_build_count should be 0 — no inline build on query path"
    );

    let _ = std::fs::remove_file(&db_path);
}

// ── HP-3: exit gate C — delete-resurrection proof ─────────────────────────────

/// HP-3: Tombstone a vector while the graph is on disk. Reopen a fresh store.
/// The deleted item must NOT appear in search results (graph load excludes
/// nodes whose float vector is absent from the `vectors` table).
#[test]
fn hp3_delete_resurrection_proof() {
    let db_path = std::env::temp_dir()
        .join(format!("vk_hp3_{}.db", Uuid::new_v4()))
        .to_string_lossy()
        .to_string();

    let victim_id = "item-1";

    // ── Phase A: build, persist, then delete the victim ───────────────────────
    {
        let store_a = open_store(&db_path);
        insert_random_float_vectors(&store_a, N, 55);

        // Rebuild and persist the graph.
        store_a.rebuild_hnsw_index(MODEL_ID).expect("rebuild");

        // Delete the victim from the vectors table.
        store_a
            .delete_vector(victim_id, MODEL_ID)
            .expect("delete vector");
    } // store_a dropped — simulates process exit.

    // ── Phase B: reopen and verify victim is excluded ─────────────────────────
    {
        let store_b = open_store(&db_path);

        // Query with k = N to maximise recall and catch any resurrection.
        let mut rng = SplitMix64HP::new(777);
        let q: Vec<f32> = (0..4).map(|_| rng.next_f32() * 2.0 - 1.0).collect();
        let results: Vec<String> = store_b
            .find_nearest_float(&q, MODEL_ID, N)
            .expect("find nearest store_b")
            .into_iter()
            .map(|m| m.item_id)
            .collect();

        assert!(
            !results.contains(&victim_id.to_string()),
            "HP-3 gate C: deleted item '{}' must NOT appear in results after restart; got {:?}",
            victim_id,
            results
        );

        // Pin the PATH, positively: a graph must be RESIDENT after the query —
        // build count 0 alone is satisfied by the fallback scan too (HP-2's
        // premise), so it cannot distinguish loaded-graph from fallback.
        assert!(
            store_b.hnsw_index_resident(MODEL_ID),
            "HP-3 path pin: an HNSW graph must be resident after the query — otherwise the exclusion came from the fallback scan"
        );
        // And no rebuild produced it: resident + build count 0 = loaded.
        assert_eq!(
            store_b.hnsw_build_count_for(MODEL_ID),
            0,
            "HP-3 path pin: the resident graph must come from loaded rows, never a rebuild"
        );
    }

    let _ = std::fs::remove_file(&db_path);
}
