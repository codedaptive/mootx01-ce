//! Lane D (in-house float lane) tests for the Rust `VectorStore`.
//! Parallel to the Swift `FloatLaneStoreTests`.
//!
//! Covers:
//!   • `embed_float` on the EmbeddingProvider (override + default opt-out)
//!   • float vector round-trip through the store (write → find_nearest_float)
//!   • find_nearest_float exactness vs a hand-computed small case
//!   • resident float index rebuild after a fresh store opens on the same
//!     storage (process-restart simulation; the float lane has no sidecar so
//!     it rebuilds from the `vectors` table, the source of truth)
//!   • the deterministic cross-language rank-identity fixture
//!
//! Float determinism note (arch spec §6): the float lane is reproducible
//! within one build/config but NOT four-way bit-identical. These tests assert
//! RANK order, never bit-identical cosine values. The rank fixture below is
//! the Rust half of the Swift-vs-Rust rank-identity gate; the Swift half is
//! `FloatRankFixture` in Tests/VectorKitTests/FloatLaneStoreTests.swift and
//! MUST stay byte-for-byte in sync.

use std::sync::Arc;
use persistence_kit::{inmemory::InMemoryStorage, Storage};
use uuid::Uuid;
use vectorkit::{EmbeddingProvider, FloatSimHashEmbeddingProvider, VectorPayload, VectorStore};

const FILED_AT: i64 = 1_700_000_000;

fn fresh_store() -> VectorStore {
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    VectorStore::open(storage).expect("open")
}

fn add_float(store: &VectorStore, item_id: &str, floats: &[f32], model_id: &str) {
    let payload = VectorPayload::from_f32(floats);
    store
        .add_payload(item_id, 0, &payload, model_id, "1", FILED_AT)
        .expect("add float payload");
}

// ── Shared cross-language rank fixture ──────────────────────────────────────

/// Five 4-d vectors plus a probe; cosine ranking is unambiguous (no ties) so
/// Swift and Rust MUST produce the identical item-ID order. Keep in sync with
/// the Swift `FloatRankFixture`.
///
/// Probe = [1, 1, 0, 0]. Expected cosine-nearest order:
///   v_ab=[2,2,0,0] cos 1.000 · v_a=[1,0,0,0] cos 0.707 ·
///   v_ad=[3,0,0,1] cos 0.671 · v_d=[0,0,0,5] cos 0.000 ·
///   v_neg=[-1,-1,0,0] cos -1.000  →  ab, a, ad, d, neg
const RANK_MODEL: &str = "rank-model";
const RANK_PROBE: [f32; 4] = [1.0, 1.0, 0.0, 0.0];
const RANK_EXPECTED_ORDER: [&str; 5] = ["v_ab", "v_a", "v_ad", "v_d", "v_neg"];
/// FARTHEST (anti-similarity) order — the most DISSIMILAR first. Distances are
/// all distinct (no ties), so this is the exact reverse of
/// `RANK_EXPECTED_ORDER`. Keep in sync with the Swift
/// `FloatRankFixture.expectedFarthestOrder`.
const RANK_EXPECTED_FARTHEST_ORDER: [&str; 5] = ["v_neg", "v_d", "v_ad", "v_a", "v_ab"];
fn rank_vectors() -> Vec<(&'static str, Vec<f32>)> {
    vec![
        ("v_a", vec![1.0, 0.0, 0.0, 0.0]),
        ("v_ab", vec![2.0, 2.0, 0.0, 0.0]),
        ("v_ad", vec![3.0, 0.0, 0.0, 1.0]),
        ("v_d", vec![0.0, 0.0, 0.0, 5.0]),
        ("v_neg", vec![-1.0, -1.0, 0.0, 0.0]),
    ]
}

// ── embed_float ─────────────────────────────────────────────────────────────

#[test]
fn embed_float_returns_pooled_vector() {
    let pooled = vec![0.25_f32, -0.5, 0.75, 1.0];
    let p = pooled.clone();
    let provider = FloatSimHashEmbeddingProvider::new("p", "1", 7, move |_| Ok(p.clone()));
    let out = provider.embed_float("hello").expect("embed_float");
    assert_eq!(out, pooled);
}

#[test]
fn embed_float_empty_input_returns_empty() {
    let provider =
        FloatSimHashEmbeddingProvider::new("p", "1", 7, |_| Ok(vec![1.0_f32, 2.0, 3.0]));
    let out = provider.embed_float("").expect("embed_float");
    assert!(out.is_empty());
}

#[test]
fn embed_float_default_opt_out_errors() {
    // A provider that does NOT override embed_float falls through to the
    // trait default, which returns Err — the float lane is opt-in.
    struct BinaryOnly;
    impl EmbeddingProvider for BinaryOnly {
        fn model_id(&self) -> &str {
            "binary-only"
        }
        fn model_version(&self) -> &str {
            "1"
        }
        fn embed(&self, _text: &str) -> Result<engram_lib::Engram, vectorkit::VectorKitError> {
            Ok(engram_lib::Engram::ZERO)
        }
    }
    let provider = BinaryOnly;
    assert!(provider.embed_float("anything").is_err());
}

// ── Round-trip + exactness ──────────────────────────────────────────────────

#[test]
fn float_round_trips_through_store_and_ranks_by_cosine() {
    let store = fresh_store();
    add_float(&store, "near", &[1.0, 0.0, 0.0], "m");
    add_float(&store, "far", &[0.0, 1.0, 0.0], "m");

    let matches = store
        .find_nearest_float(&[1.0, 0.0, 0.0], "m", 2)
        .expect("find_nearest_float");
    assert_eq!(matches.len(), 2);
    assert_eq!(matches[0].item_id, "near");
    assert_eq!(matches[1].item_id, "far");
    // Exactness: nearest is an exact direction match → distance 0; orthogonal
    // → cosine distance 1.0 → ×10_000 = 10000.
    assert_eq!(matches[0].distance, 0);
    assert_eq!(matches[1].distance, 10_000);
}

#[test]
fn find_nearest_float_exactness_hand_computed() {
    let store = fresh_store();
    // Probe [3,4,0], ‖probe‖=5.
    //   a=[3,4,0] identical → cos 1.000 → dist 0
    //   b=[4,3,0] cos 24/25=0.96 → dist 0.04 → ×1e4 = 400
    //   c=[0,0,1] orthogonal → cos 0 → dist 1.0 → 10000
    add_float(&store, "a", &[3.0, 4.0, 0.0], "m");
    add_float(&store, "b", &[4.0, 3.0, 0.0], "m");
    add_float(&store, "c", &[0.0, 0.0, 1.0], "m");

    let matches = store
        .find_nearest_float(&[3.0, 4.0, 0.0], "m", 3)
        .expect("find_nearest_float");
    let ids: Vec<&str> = matches.iter().map(|m| m.item_id.as_str()).collect();
    assert_eq!(ids, vec!["a", "b", "c"]);
    assert_eq!(matches[0].distance, 0);
    assert_eq!(matches[1].distance, 400);
    assert_eq!(matches[2].distance, 10_000);
}

#[test]
fn find_nearest_float_is_model_scoped() {
    let store = fresh_store();
    add_float(&store, "in", &[1.0, 0.0], "model-a");
    add_float(&store, "out", &[1.0, 0.0], "model-b"); // same vector, other model
    let matches = store
        .find_nearest_float(&[1.0, 0.0], "model-a", 5)
        .expect("find_nearest_float");
    assert_eq!(matches.len(), 1);
    assert_eq!(matches[0].item_id, "in");
}

// ── Reload after reopen ─────────────────────────────────────────────────────

#[test]
fn float_index_rebuilds_on_fresh_store_over_same_storage() {
    // Share one Storage across two VectorStores: the second is a
    // "process restart" — it has no resident float state and must rebuild
    // the float index from the `vectors` table on first find_nearest_float.
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    {
        let store1 = VectorStore::open(storage.clone()).expect("open 1");
        add_float(&store1, "near", &[1.0, 0.0, 0.0], "m");
        add_float(&store1, "far", &[0.0, 0.0, 1.0], "m");
    }
    // store2 starts with float_index_built = false → lazy rebuild from table.
    let store2 = VectorStore::new(storage, None);
    let matches = store2
        .find_nearest_float(&[1.0, 0.0, 0.0], "m", 2)
        .expect("find_nearest_float after reopen");
    assert_eq!(matches.len(), 2);
    assert_eq!(matches[0].item_id, "near");
    assert_eq!(matches[1].item_id, "far");
}

// ── Cross-language rank fixture (Rust half) ─────────────────────────────────

#[test]
fn rank_fixture_rust_order() {
    let store = fresh_store();
    for (id, v) in rank_vectors() {
        add_float(&store, id, &v, RANK_MODEL);
    }
    let matches = store
        .find_nearest_float(&RANK_PROBE, RANK_MODEL, 5)
        .expect("find_nearest_float");
    let ids: Vec<&str> = matches.iter().map(|m| m.item_id.as_str()).collect();
    assert_eq!(ids, RANK_EXPECTED_ORDER.to_vec());
}

#[test]
fn farthest_rank_fixture_rust_order() {
    // find_farthest_float surfaces the most DISSIMILAR rows first — the exact
    // reverse of the nearest fixture (no ties). Both languages MUST agree.
    let store = fresh_store();
    for (id, v) in rank_vectors() {
        add_float(&store, id, &v, RANK_MODEL);
    }
    let matches = store
        .find_farthest_float(&RANK_PROBE, RANK_MODEL, 5)
        .expect("find_farthest_float");
    let ids: Vec<&str> = matches.iter().map(|m| m.item_id.as_str()).collect();
    assert_eq!(ids, RANK_EXPECTED_FARTHEST_ORDER.to_vec());
}

// ---------------------------------------------------------------------------
// Cross-restart conformance for the float lane (A-11). Parallel to the Swift
// `floatIndexSurvivesReopenSQLite` (Tests/VectorKitTests/FloatLaneStoreTests).
// ---------------------------------------------------------------------------
// The float lane has no sidecar yet, so after a drop-and-reopen over a real
// on-disk SQLite file the resident float index must rebuild from the durable
// `vectors` table on first search. Both find_nearest_float and
// find_farthest_float must produce the identical ranking they produced before
// the close — which requires the float32 rows to decode correctly from the
// SQLite read-back primitives.

#[test]
fn float_index_survives_reopen_sqlite() {
    use std::path::PathBuf;
    use persistence_kit::{BackendConfiguration, EstateConfiguration, SqliteStorage};

    let dir = std::env::temp_dir();
    let db_path: PathBuf = dir.join(format!("vk_float_reopen_{}.db", Uuid::new_v4()));
    let path_str = db_path.to_string_lossy().to_string();

    let make_storage = || -> Arc<dyn Storage> {
        let cfg = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: path_str.clone(),
                busy_timeout_secs: 5.0,
            },
        );
        Arc::new(SqliteStorage::new(cfg).expect("open SQLite"))
    };

    // Session 1: write float rows over a real SQLite estate, then drop the
    // store so the resident float index is gone.
    {
        let store = VectorStore::open(make_storage()).expect("open store for write");
        add_float(&store, "near", &[1.0, 0.0, 0.0], "m");
        add_float(&store, "far", &[0.0, 0.0, 1.0], "m");
    }

    // Session 2: a brand-new store on the same file rebuilds the float index
    // from the table (the source of truth) on first search.
    {
        let store = VectorStore::open(make_storage()).expect("open store for read");

        // Nearest: probe aligned with `near`. near (cos 1.0) ranks above far
        // (cos 0.0).
        let nearest = store
            .find_nearest_float(&[1.0, 0.0, 0.0], "m", 2)
            .expect("find_nearest_float reopen");
        let near_ids: Vec<&str> = nearest.iter().map(|m| m.item_id.as_str()).collect();
        assert_eq!(near_ids, vec!["near", "far"]);

        // Farthest: the most dissimilar first — the exact reverse, no ties.
        let farthest = store
            .find_farthest_float(&[1.0, 0.0, 0.0], "m", 2)
            .expect("find_farthest_float reopen");
        let far_ids: Vec<&str> = farthest.iter().map(|m| m.item_id.as_str()).collect();
        assert_eq!(far_ids, vec!["far", "near"]);
    }

    let _ = std::fs::remove_file(&db_path);
}
