//! Tests for the import/migration-scale bulk ingest path (TASK #24).
//!
//! Parallel to the Swift `BulkIngestTests`. The acceptance contract:
//! import-scale ingestion must be bounded in both reachable modes —
//! sidecar-less bulk import avoids a per-row full-index rebuild, and
//! sidecar-backed import avoids a per-row whole-sidecar rewrite plus per-row
//! index rebuild. The fix is the batch `add_payloads` API (one sidecar write
//! + one index build per batch) and the write-behind single-add path
//! (deferred sidecar flush, persisted by `flush()`).

use engram_lib::Engram;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;
use persistence_kit::{
    BackendConfiguration, EstateConfiguration, SqliteStorage, Storage,
};
use persistence_kit::inmemory::InMemoryStorage;
use uuid::Uuid;
use vectorkit::engine::payload::VectorPayload;
use vectorkit::{VectorPayloadInput, VectorStore};

const FILED_AT: i64 = 1_700_000_000;

/// Deterministic binary engram for index i. Spreads bits across all four
/// blocks so distances are non-trivial and the corpus is well separated.
fn engram(i: usize) -> Engram {
    let u = (i as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15);
    Engram::new(u, u ^ 0xFFFF_0000_FFFF_0000, (u << 1) | 1, !u)
}

fn binary_input(i: usize) -> VectorPayloadInput {
    VectorPayloadInput {
        item_id: format!("chunk-{i}"),
        vector_index: 0,
        payload: VectorPayload::from_engram(&engram(i)),
        model_id: "minilm".to_string(),
        model_version: "1.0.0".to_string(),
        filed_at_unix_secs: FILED_AT,
    }
}

fn sqlite_storage(path: &str) -> Arc<dyn Storage> {
    let cfg = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string(),
            busy_timeout_secs: 5.0,
        },
    );
    Arc::new(SqliteStorage::new(cfg).expect("open SQLite"))
}

fn open_schema(storage: &Arc<dyn Storage>) {
    storage
        .open(&VectorStore::schema_declaration())
        .expect("open schema");
}

fn tmp_db() -> PathBuf {
    std::env::temp_dir().join(format!("vk_bulk_{}.db", Uuid::new_v4()))
}

fn tmp_vec() -> PathBuf {
    std::env::temp_dir().join(format!("vk_bulk_{}.vec", Uuid::new_v4()))
}

// ── (a) O(n²)-shape regression: sidecar writes are O(batches), not O(N) ──────

/// Import N=2000 binary vectors sidecar-backed through the batch API and
/// assert the sidecar was written O(batches) times, not O(N). The OLD code
/// shape (per-row tombstone+append) wrote the whole sidecar twice per row →
/// ~4000 writes for N=2000; the batch path writes a small constant. This is
/// the test that FAILS against the old shape: the per-row count grows linearly
/// with N, so `writes <= 3` cannot hold for N=2000.
#[test]
fn bulk_import_sidecar_write_count_is_bounded_by_batches() {
    let db = tmp_db();
    let side = tmp_vec();
    let storage = sqlite_storage(&db.to_string_lossy());
    open_schema(&storage);
    let store = VectorStore::new(storage, Some(side.clone()));

    let n = 2000usize;
    let batch: Vec<VectorPayloadInput> = (0..n).map(binary_input).collect();

    let start = Instant::now();
    store.add_payloads(&batch).expect("add_payloads");
    let elapsed = start.elapsed();

    let writes = store.sidecar_write_count();
    assert!(
        writes <= 3,
        "sidecar written {writes} times for one batch of {n} — expected O(batches), per-row shape would be ~{}",
        2 * n
    );
    assert!(elapsed.as_secs() < 60, "N={n} bulk ingest took {elapsed:?}");
    println!(
        "[BULK-INGEST] N={n} sidecar-backed batch: writes={writes} elapsed={:.3}s",
        elapsed.as_secs_f64()
    );

    // Correctness: exact self-match ranks distance 0.
    let matches = store.find_nearest(&engram(7), "minilm", 1).expect("find");
    assert_eq!(matches.first().map(|m| m.item_id.as_str()), Some("chunk-7"));
    assert_eq!(matches.first().map(|m| m.distance), Some(0));

    let _ = std::fs::remove_file(&db);
    let _ = std::fs::remove_file(&side);
}

/// Single-add write-behind loop: the sidecar is NOT written per row. Before
/// flush only the one-time first-use rebuild has run (O(1), independent of N);
/// flush adds at most one write. The OLD per-row shape would be ~2N writes.
#[test]
fn single_add_loop_defers_sidecar_writes_until_flush() {
    let db = tmp_db();
    let side = tmp_vec();
    let storage = sqlite_storage(&db.to_string_lossy());
    open_schema(&storage);
    let store = VectorStore::new(storage, Some(side.clone()));

    let n = 500usize;
    for i in 0..n {
        store
            .add_vector(&format!("chunk-{i}"), &engram(i), "minilm", "1.0.0", FILED_AT)
            .expect("add_vector");
    }
    let before = store.sidecar_write_count();
    assert!(
        before <= 2,
        "write-behind single-add must not write per row; got {before} for N={n} (per-row shape would be ~{})",
        2 * n
    );
    store.flush().expect("flush");
    let after = store.sidecar_write_count();
    assert!(after <= before + 1, "flush adds at most one write; got {after}");
    println!("[BULK-INGEST] single-add loop N={n}: writes before flush={before} after flush={after}");

    let _ = std::fs::remove_file(&db);
    let _ = std::fs::remove_file(&side);
}

// ── (b) Sidecar-less bulk: build once, correct ───────────────────────────────

#[test]
fn sidecarless_bulk_import_builds_once_and_is_correct() {
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    open_schema(&storage);
    // Low threshold so the batch promotes to MIH; both indexes must still
    // agree (conformance gate) and find_nearest stays exact.
    let store = VectorStore::new_with_threshold(
        storage,
        None,
        100,
        vectorkit::engine::mih::MIHBandCount::M16,
    );

    let n = 300usize;
    let batch: Vec<VectorPayloadInput> = (0..n).map(binary_input).collect();
    store.add_payloads(&batch).expect("add_payloads");

    for i in (0..n).step_by(37) {
        let m = store.find_nearest(&engram(i), "minilm", 1).expect("find");
        assert_eq!(m.first().map(|x| x.item_id.as_str()), Some(format!("chunk-{i}").as_str()));
        assert_eq!(m.first().map(|x| x.distance), Some(0));
    }
    assert_eq!(store.sidecar_write_count(), 0, "no sidecar → no writes");
}

// Memory-only deferred-index window (no sidecar): begin → SEVERAL add_payloads
// (one per simulated drain pass) → publish must rebuild the index ONCE and
// recover every vector. The path the CorpusKit ingest drain exercises in serve
// (resident array is memory-only). Mirrors Swift
// `memoryOnlyDeferredWindowMergesAllPassesOnce`.
#[test]
fn memory_only_deferred_window_merges_all_passes_once() {
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    open_schema(&storage);
    let store = VectorStore::new_with_threshold(
        storage,
        None,
        100,
        vectorkit::engine::mih::MIHBandCount::M16,
    );

    let n = 300usize;
    store.begin_deferred_index().expect("begin");
    // Three "drain passes" worth of writes inside one deferred window.
    let p1: Vec<VectorPayloadInput> = (0..100).map(binary_input).collect();
    let p2: Vec<VectorPayloadInput> = (100..200).map(binary_input).collect();
    let p3: Vec<VectorPayloadInput> = (200..n).map(binary_input).collect();
    store.add_payloads(&p1).expect("add p1");
    store.add_payloads(&p2).expect("add p2");
    store.add_payloads(&p3).expect("add p3");
    store.publish_resident_index().expect("publish");

    for i in (0..n).step_by(37) {
        let m = store.find_nearest(&engram(i), "minilm", 1).expect("find");
        assert_eq!(m.first().map(|x| x.item_id.as_str()), Some(format!("chunk-{i}").as_str()));
        assert_eq!(m.first().map(|x| x.distance), Some(0));
    }
}

// ── (c) Crash-safety: drop before flush, reopen → rebuild from table ─────────

#[test]
fn crash_before_flush_recovers_from_table() {
    let db = tmp_db();
    let side = tmp_vec();
    let n = 200usize;

    // Session 1: deferred single-add writes, DROP without flush (crash).
    {
        let storage = sqlite_storage(&db.to_string_lossy());
        open_schema(&storage);
        let store = VectorStore::new(storage, Some(side.clone()));
        for i in 0..n {
            store
                .add_vector(&format!("chunk-{i}"), &engram(i), "minilm", "1.0.0", FILED_AT)
                .expect("add_vector");
        }
        // No flush — sidecar on disk is stale (absent or short).
    }

    // Session 2: reopen. The table is durable; the resident index must
    // rebuild from it because the sidecar live-count disagrees.
    let storage = sqlite_storage(&db.to_string_lossy());
    open_schema(&storage);
    let reopened = VectorStore::new(storage, Some(side.clone()));

    let m = reopened.find_nearest(&engram(123), "minilm", 1).expect("find");
    assert_eq!(m.first().map(|x| x.item_id.as_str()), Some("chunk-123"));
    assert_eq!(m.first().map(|x| x.distance), Some(0));
    assert!(
        reopened.sidecar_rebuild_count() >= 1,
        "stale sidecar must trigger a table rebuild; got {}",
        reopened.sidecar_rebuild_count()
    );

    let mut found = 0usize;
    for i in 0..n {
        let r = reopened.find_nearest(&engram(i), "minilm", 1).expect("find");
        if r.first().map(|x| x.item_id.as_str()) == Some(format!("chunk-{i}").as_str())
            && r.first().map(|x| x.distance) == Some(0)
        {
            found += 1;
        }
    }
    assert_eq!(found, n, "recovered {found}/{n} rows from the table");

    let _ = std::fs::remove_file(&db);
    let _ = std::fs::remove_file(&side);
}

// ── (d) MIH == BruteForce after a bulk-imported corpus ───────────────────────

#[test]
fn mih_agrees_with_brute_force_after_bulk_import() {
    use vectorkit::engine::mih::MIHBandCount;

    let storage_bf: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    open_schema(&storage_bf);
    let bf = VectorStore::new_with_threshold(storage_bf, None, 1_000_000, MIHBandCount::M16);

    let storage_mih: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    open_schema(&storage_mih);
    let mih = VectorStore::new_with_threshold(storage_mih, None, 50, MIHBandCount::M16);

    let n = 400usize;
    let batch: Vec<VectorPayloadInput> = (0..n).map(binary_input).collect();
    bf.add_payloads(&batch).expect("bf add");
    mih.add_payloads(&batch).expect("mih add");

    for seed in [0usize, 11, 199, 333, 399] {
        for k in [1usize, 5, 10] {
            let a = bf.find_nearest(&engram(seed), "minilm", k).expect("bf find");
            let b = mih.find_nearest(&engram(seed), "minilm", k).expect("mih find");
            let a_ids: Vec<&str> = a.iter().map(|m| m.item_id.as_str()).collect();
            let b_ids: Vec<&str> = b.iter().map(|m| m.item_id.as_str()).collect();
            assert_eq!(a_ids, b_ids, "seed={seed} k={k} itemID order");
            let a_d: Vec<i32> = a.iter().map(|m| m.distance).collect();
            let b_d: Vec<i32> = b.iter().map(|m| m.distance).collect();
            assert_eq!(a_d, b_d, "seed={seed} k={k} distances");
        }
    }
}

// ── (e) Mixed binary + float batch ───────────────────────────────────────────

#[test]
fn mixed_binary_and_float_batch() {
    use vectorkit::engine::mih::MIHBandCount;

    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    open_schema(&storage);
    let store = VectorStore::new_with_threshold(storage, None, 1_000_000, MIHBandCount::M16);

    // Each float vector is unique (the i-th component dominates) so the
    // self-match is unambiguous under cosine + (distance, item_id) tie-break.
    let float_vec = |i: usize| -> Vec<f32> {
        let mut v = vec![0.1f32; 8];
        v[i % 8] = i as f32 + 10.0;
        v
    };

    let mut batch: Vec<VectorPayloadInput> = Vec::new();
    for i in 0..50usize {
        batch.push(binary_input(i));
        batch.push(VectorPayloadInput {
            item_id: format!("chunk-{i}"),
            vector_index: 1,
            payload: VectorPayload::from_f32(&float_vec(i)),
            model_id: "minilm".to_string(),
            model_version: "1.0.0".to_string(),
            filed_at_unix_secs: FILED_AT,
        });
    }
    store.add_payloads(&batch).expect("add_payloads");

    let bin = store.find_nearest(&engram(3), "minilm", 1).expect("find");
    assert_eq!(bin.first().map(|m| m.item_id.as_str()), Some("chunk-3"));

    let fl = store.find_nearest_float(&float_vec(3), "minilm", 3).expect("find float");
    assert!(!fl.is_empty());
    assert_eq!(fl.first().map(|m| m.item_id.as_str()), Some("chunk-3"));
}

// ── Finding 2: deferred buffer back-pressure ─────────────────────────────

/// A flood of memory-only deferred adds must trigger intermediate flushes and
/// stay correct — the buffer must NOT grow without bound.
///
/// Uses a custom `deferred_pending_limit = 100` so only 100 records are needed
/// to trigger a flush. Sends 300 records in 50-record batches → three flush
/// events occur during the deferred window. After `publish_resident_index`,
/// every seeded item must be retrievable at distance 0.
///
/// Mirrors Swift `testDeferredBufferBackPressureFlushesAndStaysCorrect`.
#[test]
fn deferred_buffer_back_pressure_bounds_memory() {
    use vectorkit::engine::mih::MIHBandCount;

    // Memory-only store with a tiny pending limit (100) so flush triggers at 101 records.
    // mih_threshold = 10_000 to keep BruteForce active (avoids MIH build overhead).
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    open_schema(&storage);
    let store = VectorStore::new_with_deferred_limit(
        storage,
        None,
        10_000,
        MIHBandCount::M16,
        100,  // flush limit: triggers after 100 records
    );

    // 300 records in batches of 50 → three batches exceed the limit;
    // three intermediate flushes should occur.
    const TOTAL: usize = 300;
    const BATCH_SIZE: usize = 50;

    store.begin_deferred_index().expect("begin");

    let mut batch_buf: Vec<VectorPayloadInput> = Vec::with_capacity(BATCH_SIZE);
    for i in 0..TOTAL {
        batch_buf.push(VectorPayloadInput {
            item_id: format!("chunk-{i}"),
            vector_index: 0,
            payload: VectorPayload::from_engram(&engram(i)),
            model_id: "minilm".to_string(),
            model_version: "1.0.0".to_string(),
            filed_at_unix_secs: FILED_AT,
        });
        if batch_buf.len() == BATCH_SIZE {
            store.add_payloads(&batch_buf).expect("add_payloads");
            batch_buf.clear();
        }
    }
    if !batch_buf.is_empty() {
        store.add_payloads(&batch_buf).expect("add_payloads final");
    }
    store.publish_resident_index().expect("publish");

    // Every 37th item must be findable at distance 0 after the flushed publish.
    for i in (0..TOTAL).step_by(37) {
        let expected_id = format!("chunk-{i}");
        let results = store.find_nearest(&engram(i), "minilm", 1).expect("find");
        assert_eq!(
            results.first().map(|h| h.item_id.as_str()),
            Some(expected_id.as_str()),
            "chunk-{i} must be findable at dist=0 after back-pressure flush"
        );
        assert_eq!(results.first().map(|h| h.distance), Some(0),
            "self-match must be distance 0");
    }
}

/// Same-itemID records survive in a deferred memory-only window and both
/// are retrievable after publish. Verifies Finding 1 (MIH collision fix)
/// works through the deferred write path as well as the immediate path.
#[test]
fn deferred_window_same_item_id_both_survive() {
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    open_schema(&storage);
    let store = VectorStore::new_no_sidecar(storage);

    store.begin_deferred_index().expect("begin");

    // Two distinct vectors under the same item_id, different vector_index.
    let batch = vec![
        VectorPayloadInput {
            item_id: "shared-item".to_string(),
            vector_index: 0,
            payload: VectorPayload::from_engram(&Engram::new(0, 0, 0, 0)),
            model_id: "test-model".to_string(),
            model_version: "1".to_string(),
            filed_at_unix_secs: FILED_AT,
        },
        VectorPayloadInput {
            item_id: "shared-item".to_string(),
            vector_index: 1,
            payload: VectorPayload::from_engram(&Engram::new(1, 0, 0, 0)),
            model_id: "test-model".to_string(),
            model_version: "1".to_string(),
            filed_at_unix_secs: FILED_AT,
        },
    ];
    store.add_payloads(&batch).expect("add_payloads");
    store.publish_resident_index().expect("publish");

    // Query with the zero-vector — both slots must be in the k=4 result.
    // vector_index=0 encodes Engram(0,0,0,0) → distance 0 to zero-probe.
    // vector_index=1 encodes Engram(1,0,0,0) → distance 1 to zero-probe.
    let zero = Engram::new(0, 0, 0, 0);
    let hits = store.find_nearest(&zero, "test-model", 4).expect("find");
    assert_eq!(hits.len(), 2, "both same-item_id entries must survive after publish");
    // Both hits share the same item_id; distinguish them by Hamming distance.
    assert_eq!(hits[0].item_id, "shared-item");
    assert_eq!(hits[0].distance, 0, "zero-vector slot must rank first (dist=0)");
    assert_eq!(hits[1].item_id, "shared-item");
    assert_eq!(hits[1].distance, 1, "one-bit-set slot must rank second (dist=1)");
}

#[test]
fn deferred_revisions_publish_only_final_model_version() {
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    open_schema(&storage);
    let store = VectorStore::new_no_sidecar(storage);

    store.begin_deferred_index().expect("begin");
    store.add_payloads(&[VectorPayloadInput {
        item_id: "versioned".to_string(),
        vector_index: 0,
        payload: VectorPayload::from_engram(&Engram::new(0, 0, 0, 0)),
        model_id: "test-model".to_string(),
        model_version: "1".to_string(),
        filed_at_unix_secs: FILED_AT,
    }]).expect("add v1");
    store.add_payloads(&[VectorPayloadInput {
        item_id: "versioned".to_string(),
        vector_index: 0,
        payload: VectorPayload::from_engram(&Engram::new(7, 0, 0, 0)),
        model_id: "test-model".to_string(),
        model_version: "2".to_string(),
        filed_at_unix_secs: FILED_AT,
    }]).expect("add v2");
    store.publish_resident_index().expect("publish");

    let hits = store
        .find_nearest(&Engram::new(7, 0, 0, 0), "test-model", 10)
        .expect("find");
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].item_id, "versioned");
    assert_eq!(hits[0].distance, 0);
}
