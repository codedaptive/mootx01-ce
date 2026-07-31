//! Mission MXE-BB: chunked basis persistence — Rust tests for the multi-part
//! write+read path that lifts the 1 GB SQLite single-bind ceiling (ee#49).
//! Rust mirror of Swift's `BasisChunkedPersistenceTests`.
//!
//! ## What is tested
//!
//!   1. Single-part round-trip: a basis that fits within the chunk limit is
//!      stored as exactly one row (part_index 0) and loads back intact.
//!   2. Multi-part round-trip: a basis larger than the chunk limit is split
//!      into multiple rows and reassembled byte-for-byte on load.
//!   3. Part-count correctness: the number of rows stored equals
//!      ceil(basis_bytes / chunk_byte_limit).
//!   4. Upsert replaces all parts: a second upsert with a different byte count
//!      deletes the old rows and writes only the new ones; no orphaned parts.
//!   5. Upsert from N to M parts: the part set is exactly the new set.
//!   6. delete_all removes all rows including multi-part bases.
//!   7. Metadata consistency: every part row carries the same trained_at_secs
//!      and trained_chunk_count as the first row.
//!   8. Empty basis: stored as a single empty row (part_index 0), loads back
//!      as an empty Vec.
//!   9. Transaction-scoped upsert_into works correctly for multi-part bases.
//!  10. Multiple provider keys coexist: each loads its own basis.
//!  11. Close and reopen on the same file (SQLite primitive-form decode).
//!
//! All tests use a `chunk_byte_limit` of 16 bytes (via `BasisStore::with_chunk_limit`)
//! so the multi-part path is exercised without allocating large blobs.

use corpus_kit::{BasisStore, PersistedBasis};
use persistence_kit::{
    BackendConfiguration, Column, EstateConfiguration, IsolationLevel, OrderClause,
    SqliteStorage, Storage, StoragePredicate, TypedValue,
};
use std::sync::{Arc, Mutex, OnceLock};
use uuid::Uuid;

const TEST_CHUNK_LIMIT: usize = 16;
const NOW_SECS: i64 = 1_750_000_000;
const MODEL_ID: &str = "test-model-v1";
const MODEL_VERSION: &str = "1.0.0";

// Process-wide lock: SQLite scratch files must not race.
static GLOBAL_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
fn global_lock() -> std::sync::MutexGuard<'static, ()> {
    match GLOBAL_LOCK.get_or_init(|| Mutex::new(())).lock() {
        Ok(g) => g,
        Err(p) => p.into_inner(),
    }
}

fn scratch_path() -> String {
    std::env::temp_dir()
        .join(format!("corpuskit-chunks-{}.sqlite3", Uuid::new_v4()))
        .to_string_lossy()
        .into_owned()
}

fn open_storage(path: &str) -> Arc<dyn Storage> {
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string(),
            busy_timeout_secs: 5.0,
        },
    );
    Arc::new(SqliteStorage::new(config).expect("open sqlite"))
}

fn migrate_and_store(storage: &Arc<dyn Storage>) -> BasisStore {
    storage
        .migrate(&BasisStore::schema_declaration())
        .expect("migrate");
    BasisStore::with_chunk_limit(storage.clone(), TEST_CHUNK_LIMIT)
}

/// Deterministic byte pattern: position mod 251 (a prime) so each chunk
/// has a distinct and checkable byte sequence, cheap to generate.
fn make_basis(size: usize) -> Vec<u8> {
    (0..size).map(|i| (i % 251) as u8).collect()
}

fn make_row(basis: Vec<u8>, chunk_count: usize) -> PersistedBasis {
    PersistedBasis {
        model_id: MODEL_ID.to_string(),
        model_version: MODEL_VERSION.to_string(),
        basis,
        trained_at_secs: NOW_SECS,
        trained_chunk_count: chunk_count,
    }
}

// ── §1 Single-part round-trip ──

#[test]
fn single_part_round_trip() {
    let _g = global_lock();
    let path = scratch_path();
    let storage = open_storage(&path);
    let store = migrate_and_store(&storage);

    // 10 bytes < TEST_CHUNK_LIMIT (16) → exactly one part row.
    let basis = make_basis(10);
    let row = make_row(basis.clone(), 3);
    store.upsert(&row).expect("upsert");

    let loaded = store
        .load(MODEL_ID, MODEL_VERSION)
        .expect("load")
        .expect("basis must exist");
    assert_eq!(loaded.basis, basis, "single-part basis must round-trip byte-for-byte");
    assert_eq!(loaded.trained_chunk_count, 3);
    assert_eq!(loaded.trained_at_secs, NOW_SECS);
}

// ── §2 Multi-part round-trip ──

#[test]
fn multi_part_round_trip() {
    let _g = global_lock();
    let path = scratch_path();
    let storage = open_storage(&path);
    let store = migrate_and_store(&storage);

    // 50 bytes > TEST_CHUNK_LIMIT (16) → 4 parts: [16, 16, 16, 2].
    let basis = make_basis(50);
    let row = make_row(basis.clone(), 7);
    store.upsert(&row).expect("upsert");

    let loaded = store
        .load(MODEL_ID, MODEL_VERSION)
        .expect("load")
        .expect("basis must exist");
    assert_eq!(loaded.basis, basis, "multi-part basis must reassemble byte-for-byte");
    assert_eq!(loaded.trained_chunk_count, 7);
}

// ── §3 Part-count correctness ──

#[test]
fn part_count_is_correct() {
    let _g = global_lock();
    let path = scratch_path();
    let storage = open_storage(&path);
    let store = migrate_and_store(&storage);

    // 48 bytes / 16 bytes per chunk = exactly 3 parts.
    let row = make_row(make_basis(48), 1);
    store.upsert(&row).expect("upsert");

    // Count the rows directly to verify the part structure.
    let predicate = StoragePredicate::And(vec![
        StoragePredicate::Eq(
            Column::new("corpus_provider_basis", "model_id"),
            TypedValue::Text(MODEL_ID.to_string()),
        ),
        StoragePredicate::Eq(
            Column::new("corpus_provider_basis", "model_version"),
            TypedValue::Text(MODEL_VERSION.to_string()),
        ),
    ]);
    let order_by = [OrderClause::ascending(Column::new("corpus_provider_basis", "part_index"))];
    let rows = storage
        .row_store()
        .query("corpus_provider_basis", Some(&predicate), &order_by, None, None)
        .expect("query");

    assert_eq!(rows.len(), 3, "48 bytes / 16 bytes per chunk must produce exactly 3 rows");

    // Verify part_index sequence is 0, 1, 2.
    for (expected_idx, row) in rows.iter().enumerate() {
        match row.get("part_index") {
            Some(TypedValue::Int(idx)) => {
                assert_eq!(
                    *idx, expected_idx as i64,
                    "part_index on row {} must equal {}, got {}",
                    expected_idx, expected_idx, idx
                );
            }
            other => panic!(
                "part_index on row {} must be Int, got {:?}",
                expected_idx, other
            ),
        }
    }
}

// ── §4 Upsert replaces all parts (no orphans from smaller new basis) ──

#[test]
fn upsert_replaces_all_parts() {
    let _g = global_lock();
    let path = scratch_path();
    let storage = open_storage(&path);
    let store = migrate_and_store(&storage);

    // First upsert: 50 bytes → 4 parts.
    store.upsert(&make_row(make_basis(50), 5)).expect("upsert-1");

    // Second upsert for the SAME key: 20 bytes → 2 parts.
    let new_basis = make_basis(20);
    store
        .upsert(&PersistedBasis {
            model_id: MODEL_ID.to_string(),
            model_version: MODEL_VERSION.to_string(),
            basis: new_basis.clone(),
            trained_at_secs: NOW_SECS + 60,
            trained_chunk_count: 8,
        })
        .expect("upsert-2");

    let predicate = StoragePredicate::And(vec![
        StoragePredicate::Eq(
            Column::new("corpus_provider_basis", "model_id"),
            TypedValue::Text(MODEL_ID.to_string()),
        ),
        StoragePredicate::Eq(
            Column::new("corpus_provider_basis", "model_version"),
            TypedValue::Text(MODEL_VERSION.to_string()),
        ),
    ]);
    let rows = storage
        .row_store()
        .query("corpus_provider_basis", Some(&predicate), &[], None, None)
        .expect("query");
    assert_eq!(
        rows.len(), 2,
        "second upsert (20 bytes) must replace 4-part old basis with 2 new rows"
    );

    let loaded = store
        .load(MODEL_ID, MODEL_VERSION)
        .expect("load")
        .expect("basis must exist");
    assert_eq!(loaded.basis, new_basis, "loaded basis must equal the new basis");
    assert_eq!(loaded.trained_chunk_count, 8);
}

// ── §5 Upsert from N to M parts (larger new basis) ──

#[test]
fn upsert_from_small_to_large() {
    let _g = global_lock();
    let path = scratch_path();
    let storage = open_storage(&path);
    let store = migrate_and_store(&storage);

    // First upsert: 20 bytes → 2 parts.
    store.upsert(&make_row(make_basis(20), 2)).expect("upsert-1");

    // Second upsert: 50 bytes → 4 parts.
    let large_basis = make_basis(50);
    store
        .upsert(&PersistedBasis {
            model_id: MODEL_ID.to_string(),
            model_version: MODEL_VERSION.to_string(),
            basis: large_basis.clone(),
            trained_at_secs: NOW_SECS + 60,
            trained_chunk_count: 10,
        })
        .expect("upsert-2");

    let predicate = StoragePredicate::And(vec![
        StoragePredicate::Eq(
            Column::new("corpus_provider_basis", "model_id"),
            TypedValue::Text(MODEL_ID.to_string()),
        ),
        StoragePredicate::Eq(
            Column::new("corpus_provider_basis", "model_version"),
            TypedValue::Text(MODEL_VERSION.to_string()),
        ),
    ]);
    let rows = storage
        .row_store()
        .query("corpus_provider_basis", Some(&predicate), &[], None, None)
        .expect("query");
    assert_eq!(rows.len(), 4, "upsert(50 bytes) after upsert(20 bytes) must produce 4 rows");

    let loaded = store.load(MODEL_ID, MODEL_VERSION).expect("load").expect("basis");
    assert_eq!(loaded.basis, large_basis);
    assert_eq!(loaded.trained_chunk_count, 10);
}

// ── §6 delete_all removes all rows including multi-part bases ──

#[test]
fn delete_all_removes_multi_part_rows() {
    let _g = global_lock();
    let path = scratch_path();
    let storage = open_storage(&path);
    let store = migrate_and_store(&storage);

    store.upsert(&PersistedBasis {
        model_id: "model-a".to_string(),
        model_version: "1".to_string(),
        basis: make_basis(50),
        trained_at_secs: NOW_SECS,
        trained_chunk_count: 1,
    }).expect("upsert model-a");
    store.upsert(&PersistedBasis {
        model_id: "model-b".to_string(),
        model_version: "1".to_string(),
        basis: make_basis(32),
        trained_at_secs: NOW_SECS,
        trained_chunk_count: 1,
    }).expect("upsert model-b");

    // Verify rows exist before delete_all.
    let before = storage
        .row_store()
        .query("corpus_provider_basis", None, &[], None, None)
        .expect("query-before");
    assert!(!before.is_empty(), "precondition: rows must exist before delete_all");

    store.delete_all().expect("delete_all");

    let after = storage
        .row_store()
        .query("corpus_provider_basis", None, &[], None, None)
        .expect("query-after");
    assert!(after.is_empty(), "delete_all must remove every row including multi-part bases");

    assert!(store.load("model-a", "1").expect("load-a").is_none());
    assert!(store.load("model-b", "1").expect("load-b").is_none());
}

// ── §7 Metadata consistency across all parts ──

#[test]
fn metadata_consistent_across_parts() {
    let _g = global_lock();
    let path = scratch_path();
    let storage = open_storage(&path);
    let store = migrate_and_store(&storage);

    // 50 bytes → 4 part rows.
    store.upsert(&make_row(make_basis(50), 42)).expect("upsert");

    let predicate = StoragePredicate::And(vec![
        StoragePredicate::Eq(
            Column::new("corpus_provider_basis", "model_id"),
            TypedValue::Text(MODEL_ID.to_string()),
        ),
        StoragePredicate::Eq(
            Column::new("corpus_provider_basis", "model_version"),
            TypedValue::Text(MODEL_VERSION.to_string()),
        ),
    ]);
    let order_by = [OrderClause::ascending(Column::new("corpus_provider_basis", "part_index"))];
    let rows = storage
        .row_store()
        .query("corpus_provider_basis", Some(&predicate), &order_by, None, None)
        .expect("query");
    assert_eq!(rows.len(), 4);

    // All rows must carry the same trained_chunk_count.
    for (idx, row) in rows.iter().enumerate() {
        match row.get("trained_chunk_count") {
            Some(TypedValue::Int(count)) => {
                assert_eq!(*count, 42, "trained_chunk_count on row {} must equal 42, got {}", idx, count);
            }
            other => panic!("trained_chunk_count on row {} is {:?}", idx, other),
        }
    }
}

// ── §8 Empty basis ──

#[test]
fn empty_basis_round_trip() {
    let _g = global_lock();
    let path = scratch_path();
    let storage = open_storage(&path);
    let store = migrate_and_store(&storage);

    store.upsert(&make_row(Vec::new(), 0)).expect("upsert empty");

    let predicate = StoragePredicate::And(vec![
        StoragePredicate::Eq(
            Column::new("corpus_provider_basis", "model_id"),
            TypedValue::Text(MODEL_ID.to_string()),
        ),
        StoragePredicate::Eq(
            Column::new("corpus_provider_basis", "model_version"),
            TypedValue::Text(MODEL_VERSION.to_string()),
        ),
    ]);
    let rows = storage
        .row_store()
        .query("corpus_provider_basis", Some(&predicate), &[], None, None)
        .expect("query");
    assert_eq!(rows.len(), 1, "empty basis must produce exactly one row (part_index 0)");

    let loaded = store.load(MODEL_ID, MODEL_VERSION).expect("load").expect("basis");
    assert!(loaded.basis.is_empty(), "empty basis must round-trip as an empty Vec");
}

// ── §9 Transaction-scoped upsert_into ──

#[test]
fn transaction_scoped_upsert_into() {
    let _g = global_lock();
    let path = scratch_path();
    let storage = open_storage(&path);
    let store = migrate_and_store(&storage);

    // 50 bytes → 4 parts, written via the transaction-scoped variant.
    let basis = make_basis(50);
    let row = make_row(basis.clone(), 5);

    storage
        .transaction(IsolationLevel::Serializable, &mut |txn| {
            let rows = txn.row_store();
            store
                .upsert_into(&row, &rows)
                .map_err(|e| persistence_kit::StorageError::BackendError {
                    underlying: format!("{e:?}"),
                })
        })
        .expect("transaction");

    let loaded = store.load(MODEL_ID, MODEL_VERSION).expect("load").expect("basis");
    assert_eq!(
        loaded.basis, basis,
        "transaction-scoped upsert_into must produce the same multi-part result as standalone upsert"
    );
    assert_eq!(loaded.trained_chunk_count, 5);
}

// ── §10 Multiple provider keys coexist ──

#[test]
fn multiple_provider_keys_coexist() {
    let _g = global_lock();
    let path = scratch_path();
    let storage = open_storage(&path);
    let store = migrate_and_store(&storage);

    let basis_a = make_basis(50); // 4 parts
    let basis_b = make_basis(32); // 2 parts
    store.upsert(&PersistedBasis {
        model_id: "model-a".to_string(),
        model_version: "1".to_string(),
        basis: basis_a.clone(),
        trained_at_secs: NOW_SECS,
        trained_chunk_count: 1,
    }).expect("upsert model-a");
    store.upsert(&PersistedBasis {
        model_id: "model-b".to_string(),
        model_version: "1".to_string(),
        basis: basis_b.clone(),
        trained_at_secs: NOW_SECS,
        trained_chunk_count: 2,
    }).expect("upsert model-b");

    let loaded_a = store.load("model-a", "1").expect("load-a").expect("model-a basis");
    let loaded_b = store.load("model-b", "1").expect("load-b").expect("model-b basis");
    assert_eq!(loaded_a.basis, basis_a, "model-a basis must load correctly");
    assert_eq!(loaded_b.basis, basis_b, "model-b basis must load correctly");
    assert_eq!(loaded_a.trained_chunk_count, 1);
    assert_eq!(loaded_b.trained_chunk_count, 2);

    // Missing key returns None.
    assert!(store.load("model-c", "1").expect("load-c").is_none());
}

// ── §11 Close and reopen (SQLite primitive-form decode) ──

#[test]
fn close_and_reopen_multi_part_round_trip() {
    let _g = global_lock();
    let path = scratch_path();
    let basis = make_basis(50);

    // Write on first connection.
    {
        let s = open_storage(&path);
        let store = migrate_and_store(&s);
        store.upsert(&make_row(basis.clone(), 9)).expect("upsert");
        // `s` drops here, closing the connection.
    }

    // Read on a SECOND connection (primitive-form decode: a fresh connection
    // that did not run migrate returns TIMESTAMP columns as Text ISO8601, not
    // Timestamp(i64) — the decode must tolerate both forms, mirroring the
    // same resilience discipline as bundle_store::decode_chunk).
    let s2 = open_storage(&path);
    // No migration needed — schema was applied on first open.
    let store2 = BasisStore::with_chunk_limit(s2, TEST_CHUNK_LIMIT);
    let loaded = store2
        .load(MODEL_ID, MODEL_VERSION)
        .expect("load on reopen")
        .expect("basis must survive close+reopen");

    assert_eq!(
        loaded.basis, basis,
        "multi-part basis must survive close+reopen with SQLite primitive-form decode"
    );
    assert_eq!(loaded.trained_chunk_count, 9);
}
