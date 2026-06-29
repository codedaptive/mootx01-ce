//! Tests for the Rust `VectorStore` -- persistence-kit-backed CRUD over
//! the `vectors` table. Parallel to the Swift `VectorStoreTests`.
//!
//! Lane F: schema uses `item_id` (renamed from `drawer_id`),
//! `vector_index`, `kind`, `dim`, `payload`, `scale`.
//! UNIQUE(item_id, vector_index, model_id).
//!
//! All tests that previously used `drawer_id` / `vectors_for_drawer`
//! now use `item_id` / `vectors_for_item` per the Lane F rename.

use engram_lib::Engram;
use std::sync::Arc;
use persistence_kit::{inmemory::InMemoryStorage, Storage};
use uuid::Uuid;
use vectorkit::VectorStore;

const FILED_AT_1: i64 = 1_700_000_000;
const FILED_AT_2: i64 = 1_700_000_100;
const FILED_AT_3: i64 = 1_700_000_200;

fn fresh_store() -> VectorStore {
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    VectorStore::open(storage).expect("open")
}

#[test]
fn add_get_round_trip_preserves_engram_bytes() {
    let store = fresh_store();
    let engram = Engram::new(0xDEAD_BEEF_CAFE_BABE,
                             0x0123_4567_89AB_CDEF,
                             0xFFFF_0000_FFFF_0000,
                             0x0000_FFFF_0000_FFFF);
    store
        .add_vector("item-A", &engram, "minilm", "1.0.0", FILED_AT_1)
        .expect("add");

    let fetched = store
        .get_vector("item-A", "minilm")
        .expect("get");
    assert_eq!(fetched, Some(engram));
}

#[test]
fn get_vector_returns_none_for_unknown_item() {
    let store = fresh_store();
    let result = store.get_vector("never-existed", "minilm").expect("get");
    assert_eq!(result, None);
}

#[test]
fn multiple_models_stored_for_same_item() {
    let store = fresh_store();
    let minilm = Engram::new(0x1111, 0x2222, 0x3333, 0x4444);
    let gemma  = Engram::new(0xAAAA, 0xBBBB, 0xCCCC, 0xDDDD);
    store.add_vector("item-X", &minilm, "minilm", "1.0.0", FILED_AT_1)
         .expect("add minilm");
    store.add_vector("item-X", &gemma, "gemma", "300m", FILED_AT_1)
         .expect("add gemma");

    assert_eq!(store.get_vector("item-X", "minilm").unwrap(), Some(minilm));
    assert_eq!(store.get_vector("item-X", "gemma").unwrap(), Some(gemma));
}

#[test]
fn vectors_for_item_returns_all_ordered_by_filed_at_ascending() {
    let store = fresh_store();
    let e1 = Engram::new(1, 0, 0, 0);
    let e2 = Engram::new(2, 0, 0, 0);
    let e3 = Engram::new(3, 0, 0, 0);

    // Insert out of chronological order to exercise the ORDER BY.
    store.add_vector("item-Y", &e2, "mB", "1", FILED_AT_2).expect("add e2");
    store.add_vector("item-Y", &e3, "mC", "1", FILED_AT_3).expect("add e3");
    store.add_vector("item-Y", &e1, "mA", "1", FILED_AT_1).expect("add e1");

    let all = store.vectors_for_item("item-Y").expect("list");
    assert_eq!(all.len(), 3);
    let engrams: Vec<Engram> = all.iter().map(|r| r.engram).collect();
    assert_eq!(engrams, vec![e1, e2, e3]);
    let models: Vec<&str> = all.iter().map(|r| r.model_id.as_str()).collect();
    assert_eq!(models, vec!["mA", "mB", "mC"]);
    let filed: Vec<i64> = all.iter().map(|r| r.filed_at).collect();
    assert_eq!(filed, vec![FILED_AT_1, FILED_AT_2, FILED_AT_3]);
}

#[test]
fn delete_vector_removes_row() {
    let store = fresh_store();
    let engram = Engram::new(0x42, 0, 0, 0);
    store.add_vector("item-Z", &engram, "minilm", "1.0.0", FILED_AT_1)
         .expect("add");
    store.delete_vector("item-Z", "minilm").expect("delete");

    let fetched = store.get_vector("item-Z", "minilm").expect("get");
    assert_eq!(fetched, None);
}

#[test]
fn model_and_version_round_trip() {
    let store = fresh_store();
    let engram = Engram::new(0xAA, 0xBB, 0xCC, 0xDD);
    store
        .add_vector("item-V", &engram, "minilm-v6", "1.0.0-alpha.3", FILED_AT_1)
        .expect("add");

    let rows = store.vectors_for_item("item-V").expect("list");
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].item_id, "item-V");
    assert_eq!(rows[0].vector_index, 0);
    assert_eq!(rows[0].model_id, "minilm-v6");
    assert_eq!(rows[0].model_version, "1.0.0-alpha.3");
    assert_eq!(rows[0].engram, engram);
    assert_eq!(rows[0].filed_at, FILED_AT_1);
}

#[test]
fn add_vector_upserts_on_same_item_and_model() {
    let store = fresh_store();
    let first  = Engram::new(1, 2, 3, 4);
    let second = Engram::new(5, 6, 7, 8);

    store.add_vector("item-UP", &first, "minilm", "1.0.0", FILED_AT_1)
         .expect("add first");
    store.add_vector("item-UP", &second, "minilm", "1.0.1", FILED_AT_2)
         .expect("add second");

    // The conflict path UPDATEs in place; the stored engram is the
    // most recent one and only one row exists for this item.
    assert_eq!(store.get_vector("item-UP", "minilm").unwrap(), Some(second));
    let rows = store.vectors_for_item("item-UP").expect("list");
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].engram, second);
    assert_eq!(rows[0].model_version, "1.0.1");
}

#[test]
fn fresh_store_returns_empty_for_unknown_item() {
    let store = fresh_store();
    let rows = store.vectors_for_item("no-such-item").expect("list");
    assert!(rows.is_empty());
}

// ---------------------------------------------------------------------------
// VEC-04 — find_nearest / find_by_keyword
// ---------------------------------------------------------------------------

/// Seed a 4-row corpus. Hamming distance from the zero probe equals
/// popcount(engram), so expected sort order is alpha < bravo < charlie < delta.
fn seed_corpus(store: &VectorStore, model_id: &str) {
    let entries: &[(&str, u64)] = &[
        ("alpha-doc",   0x1),
        ("bravo-doc",   0x3),
        ("charlie-doc", 0x7),
        ("delta-doc",   0xF),
    ];
    for (item, bits) in entries {
        let engram = Engram::new(*bits, 0, 0, 0);
        store
            .add_vector(item, &engram, model_id, "1.0.0", FILED_AT_1)
            .expect("seed add_vector");
    }
}

#[test]
fn find_nearest_returns_k_results_sorted_by_distance_ascending() {
    let store = fresh_store();
    seed_corpus(&store, "minilm");
    let probe = Engram::new(0, 0, 0, 0);

    let matches = store
        .find_nearest(&probe, "minilm", 2)
        .expect("find_nearest");
    assert_eq!(matches.len(), 2);
    let ids: Vec<&str> = matches.iter().map(|m| m.item_id.as_str()).collect();
    assert_eq!(ids, vec!["alpha-doc", "bravo-doc"]);
    let distances: Vec<i32> = matches.iter().map(|m| m.distance).collect();
    assert_eq!(distances, vec![1, 2]);
    for i in 1..matches.len() {
        assert!(matches[i - 1].distance <= matches[i].distance);
    }
}

#[test]
fn find_nearest_with_k_larger_than_corpus_returns_all_rows() {
    let store = fresh_store();
    seed_corpus(&store, "minilm");
    let probe = Engram::new(0, 0, 0, 0);

    let matches = store
        .find_nearest(&probe, "minilm", 10)
        .expect("find_nearest");
    assert_eq!(matches.len(), 4);
    let ids: Vec<&str> = matches.iter().map(|m| m.item_id.as_str()).collect();
    assert_eq!(ids, vec!["alpha-doc", "bravo-doc", "charlie-doc", "delta-doc"]);
    let distances: Vec<i32> = matches.iter().map(|m| m.distance).collect();
    assert_eq!(distances, vec![1, 2, 3, 4]);
}

#[test]
fn find_nearest_on_empty_store_returns_empty() {
    let store = fresh_store();
    let probe = Engram::new(0xFFFF, 0, 0, 0);
    let matches = store
        .find_nearest(&probe, "minilm", 5)
        .expect("find_nearest");
    assert!(matches.is_empty());
}

#[test]
fn find_nearest_indices_map_to_correct_item_ids() {
    let store = fresh_store();
    seed_corpus(&store, "minilm");
    let probe = Engram::new(0, 0, 0, 0);

    let matches = store
        .find_nearest(&probe, "minilm", 4)
        .expect("find_nearest");
    assert_eq!(matches.len(), 4);
    for m in &matches {
        let stored = store
            .get_vector(&m.item_id, "minilm")
            .expect("get_vector")
            .expect("row must exist");
        let computed = engram_lib::EngramLib::distance(&probe, &stored);
        assert_eq!(
            m.distance as u32, computed,
            "item {}: distance mismatch", m.item_id
        );
        assert_eq!(m.model_id, "minilm");
    }
}

#[test]
fn find_nearest_equal_distance_tiebreak_by_item_id_ascending() {
    let store = fresh_store();
    // Two items with the same Hamming distance from the zero probe.
    // Both have popcount 1: bit 0 vs bit 1.
    store.add_vector("yyy-item", &Engram::new(0x1, 0, 0, 0), "m", "1", FILED_AT_1).unwrap();
    store.add_vector("aaa-item", &Engram::new(0x2, 0, 0, 0), "m", "1", FILED_AT_1).unwrap();
    let probe = Engram::new(0, 0, 0, 0);
    let matches = store.find_nearest(&probe, "m", 2).unwrap();
    assert_eq!(matches.len(), 2);
    assert_eq!(matches[0].item_id, "aaa-item");
    assert_eq!(matches[1].item_id, "yyy-item");
}

#[test]
fn find_by_keyword_returns_matching_items() {
    let store = fresh_store();
    seed_corpus(&store, "minilm");
    let hits = store.find_by_keyword("alpha", 10).expect("find_by_keyword");
    assert_eq!(hits, vec!["alpha-doc".to_string()]);
}

#[test]
fn find_by_keyword_returns_empty_for_no_match() {
    let store = fresh_store();
    seed_corpus(&store, "minilm");
    let hits = store.find_by_keyword("zebra", 10).expect("find_by_keyword");
    assert!(hits.is_empty());
}

#[test]
fn hybrid_find_nearest_and_find_by_keyword_overlap() {
    let store = fresh_store();
    seed_corpus(&store, "minilm");
    let probe = Engram::new(0, 0, 0, 0);

    let nearest = store
        .find_nearest(&probe, "minilm", 4)
        .expect("find_nearest");
    let keyword = store.find_by_keyword("alpha", 10).expect("find_by_keyword");

    assert!(nearest.iter().any(|m| m.item_id == "alpha-doc"));
    assert!(keyword.contains(&"alpha-doc".to_string()));
}

// ---------------------------------------------------------------------------
// SQLite round-trip test (real on-disk backend)
// ---------------------------------------------------------------------------
// This test validates that the schema serialises and deserialises correctly
// through a real SQLite file. InMemory hid the reopen decode bugs previously.

#[test]
fn sqlite_round_trip_fresh_schema() {
    use std::path::PathBuf;
    use persistence_kit::{BackendConfiguration, EstateConfiguration, SqliteStorage};

    let dir = std::env::temp_dir();
    let db_path: PathBuf = dir.join(format!("vk_lane_f_test_{}.db", Uuid::new_v4()));
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

    // --- write phase ---
    {
        let store = VectorStore::open(make_storage()).expect("open store for write");
        let e1 = Engram::new(0xCAFE_BABE_DEAD_BEEF, 0x1, 0x2, 0x3);
        let e2 = Engram::new(0x0, 0xFFFF_FFFF, 0x0, 0xAAAA_BBBB);
        store.add_vector("item-sql-1", &e1, "test-model", "1.0", FILED_AT_1).unwrap();
        store.add_vector("item-sql-2", &e2, "test-model", "1.0", FILED_AT_2).unwrap();
    }

    // --- read phase (reopen) ---
    {
        // Calling open() again on an existing schema is idempotent (CREATE IF NOT EXISTS).
        let store = VectorStore::open(make_storage()).expect("open store for read");

        let e1 = Engram::new(0xCAFE_BABE_DEAD_BEEF, 0x1, 0x2, 0x3);
        let e2 = Engram::new(0x0, 0xFFFF_FFFF, 0x0, 0xAAAA_BBBB);

        assert_eq!(store.get_vector("item-sql-1", "test-model").unwrap(), Some(e1));
        assert_eq!(store.get_vector("item-sql-2", "test-model").unwrap(), Some(e2));
        assert_eq!(store.get_vector("item-sql-1", "other-model").unwrap(), None);

        // vectors_for_item — row present with correct fields
        let all_1 = store.vectors_for_item("item-sql-1").unwrap();
        assert_eq!(all_1.len(), 1);
        assert_eq!(all_1[0].item_id, "item-sql-1");
        assert_eq!(all_1[0].vector_index, 0);
    }

    // Clean up temp file.
    let _ = std::fs::remove_file(&db_path);
}

// ---------------------------------------------------------------------------
// Cross-restart conformance: find_nearest survives a drop-and-reopen over the
// SAME on-disk SQLite file (A-11). Parallel to the Swift
// `findNearestSurvivesReopenSQLite` (Tests/VectorKitTests/VectorStoreTests).
// ---------------------------------------------------------------------------
// The deliverable the SQLite backend exists for: after the writing store is
// dropped (nothing stays resident), a NEW VectorStore on the same file must
// rebuild the resident binary array from the durable `vectors` table on first
// search, so find_nearest returns the persisted vector at distance 0. This is
// the test that would have caught the dark-recall-on-reopen bug — the SQLite
// backend hands `id` back as Text and `filed_at` as Int, which the row
// decoders must tolerate (decode_stored_vector_light), or find_nearest sees
// an empty array on reopen.

#[test]
fn find_nearest_survives_reopen_sqlite() {
    use std::path::PathBuf;
    use persistence_kit::{BackendConfiguration, EstateConfiguration, SqliteStorage};

    let dir = std::env::temp_dir();
    let db_path: PathBuf = dir.join(format!("vk_reopen_find_{}.db", Uuid::new_v4()));
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

    let engram = Engram::new(
        0xDEAD_BEEF_CAFE_BABE,
        0x0123_4567_89AB_CDEF,
        0xFFFF_0000_FFFF_0000,
        0x0000_FFFF_0000_FFFF,
    );

    // Session 1: write a vector over a real SQLite estate, then drop the store
    // so nothing stays resident.
    {
        let store = VectorStore::open(make_storage()).expect("open store for write");
        store
            .add_vector("drawer-reopen", &engram, "minilm", "1.0.0", FILED_AT_1)
            .expect("add");
    }

    // Session 2: a brand-new VectorStore over the SAME on-disk estate. The
    // persisted vector must decode from the SQLite read-back primitives, or
    // find_nearest returns nothing.
    {
        let store = VectorStore::open(make_storage()).expect("open store for read");
        let matches = store.find_nearest(&engram, "minilm", 5).expect("find_nearest");
        // The reopened store rebuilt the resident array from the table and
        // ranks the identical probe at Hamming distance 0.
        assert!(
            matches
                .iter()
                .any(|m| m.item_id == "drawer-reopen" && m.distance == 0),
            "find_nearest over a reopened SQLite estate must surface the persisted vector at distance 0; got {matches:?}"
        );
    }

    let _ = std::fs::remove_file(&db_path);
}

// ---------------------------------------------------------------------------
// Cross-restart conformance WITH a .vec sidecar (A-11). The resident array is
// persisted to the sidecar via flush() and reloaded on reopen. No table rebuild
// is required when the sidecar parses successfully and live_count (recomputed
// from the tombstone bitmap) matches the table row count (sidecar_rebuild_count
// stays 0). Either way, the reopened find_nearest top-k is identical.
// ---------------------------------------------------------------------------

#[test]
fn find_nearest_survives_reopen_sqlite_with_sidecar() {
    use std::path::PathBuf;
    use persistence_kit::{BackendConfiguration, EstateConfiguration, SqliteStorage};

    let dir = std::env::temp_dir();
    let stamp = Uuid::new_v4();
    let db_path: PathBuf = dir.join(format!("vk_reopen_sidecar_{stamp}.db"));
    let sidecar_path: PathBuf = dir.join(format!("vk_reopen_sidecar_{stamp}.vec"));
    let path_str = db_path.to_string_lossy().to_string();

    let make_storage = || -> Arc<dyn Storage> {
        let cfg = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: path_str.clone(),
                busy_timeout_secs: 5.0,
            },
        );
        let storage = SqliteStorage::new(cfg).expect("open SQLite");
        // `new()` (sidecar path) does not open the schema; do it explicitly so
        // the `vectors` table exists before the store writes.
        storage
            .open(&VectorStore::schema_declaration())
            .expect("open schema");
        Arc::new(storage)
    };

    let e_a = Engram::new(0xAAAA_AAAA_AAAA_AAAA, 0x1, 0x2, 0x3);
    let e_b = Engram::new(0x0, 0xFFFF_FFFF_FFFF_FFFF, 0x0, 0xBBBB_CCCC_DDDD_EEEE);

    // Pre-close ranking captured from the writing session, to assert the
    // reopened session is identical.
    let pre_close: Vec<(String, i32)>;

    // Session 1: write two vectors WITH a sidecar, flush so the sidecar is
    // persisted, then drop the store.
    {
        let store = VectorStore::new(make_storage(), Some(sidecar_path.clone()));
        store
            .add_vector("alpha", &e_a, "minilm", "1.0.0", FILED_AT_1)
            .expect("add alpha");
        store
            .add_vector("beta", &e_b, "minilm", "1.0.0", FILED_AT_2)
            .expect("add beta");
        store.flush().expect("flush sidecar");
        let matches = store.find_nearest(&e_a, "minilm", 5).expect("find_nearest");
        pre_close = matches
            .iter()
            .map(|m| (m.item_id.clone(), m.distance))
            .collect();
    }

    // Session 2: a new store on the SAME db AND the SAME sidecar. Because the
    // sidecar live_count matches the table row count, the array loads from the
    // sidecar with no rebuild (sidecar_rebuild_count stays 0).
    {
        let store = VectorStore::new(make_storage(), Some(sidecar_path.clone()));
        let matches = store.find_nearest(&e_a, "minilm", 5).expect("find_nearest reopen");
        let post: Vec<(String, i32)> = matches
            .iter()
            .map(|m| (m.item_id.clone(), m.distance))
            .collect();
        // Resident arrays + nearest results identical to before close.
        assert_eq!(post, pre_close, "reopened top-k must equal pre-close top-k");
        // The identical probe ranks at distance 0.
        assert!(post.iter().any(|(id, d)| id == "alpha" && *d == 0));
        // Loaded from the current sidecar — no table rebuild was needed.
        assert_eq!(
            store.sidecar_rebuild_count(),
            0,
            "a current sidecar must load without a table rebuild"
        );
    }

    let _ = std::fs::remove_file(&db_path);
    let _ = std::fs::remove_file(&sidecar_path);
}

// F3: default_sidecar_path derives a `.vec` path beside the SQLite database, and
// returns None for non-file (in-memory) backends. Mirrors the Swift
// VectorStore.defaultSidecarURL assertions.
#[test]
fn default_sidecar_path_derives_vec_beside_sqlite_and_none_for_inmemory() {
    use persistence_kit::{BackendConfiguration, EstateConfiguration, SqliteStorage};
    use std::path::PathBuf;

    // SQLite backend → `<estate>.vectors.vec` beside the database file.
    let db_path = std::env::temp_dir().join(format!("vk_sidecar_path_{}.sqlite", Uuid::new_v4()));
    let cfg = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: db_path.to_string_lossy().to_string(),
            busy_timeout_secs: 5.0,
        },
    );
    let sqlite: Arc<dyn Storage> = Arc::new(SqliteStorage::new(cfg).expect("open SQLite"));
    let derived = VectorStore::default_sidecar_path(&sqlite).expect("sqlite backend yields a sidecar path");
    let expected: PathBuf = db_path.with_extension("vectors.vec");
    assert_eq!(derived, expected);
    assert_eq!(derived.extension().and_then(|e| e.to_str()), Some("vec"));

    // In-memory backend → no local sidecar (rebuilds from table each open).
    let mem: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    assert!(VectorStore::default_sidecar_path(&mem).is_none());
}
