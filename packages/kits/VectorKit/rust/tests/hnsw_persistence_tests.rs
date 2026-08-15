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
