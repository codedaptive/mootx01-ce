//! corpus_counts_migration_convergence_tests.rs — Rust twin of
//! CorpusCountsMigrationConvergenceTests.swift (CORPUS-COUNTS-01).
//!
//! Two scenarios mirror the Swift suite:
//!
//!   A. **Migration CREATE-only invariant (ee#49):** Opening a v3 estate with the
//!      v4 schema triggers the v3→v4 migration, which is CREATE-only. The legacy
//!      `corpus_provider_vocab` rows must be PRESENT immediately after the migration
//!      (the open path is bulk-transform-free) and ABSENT only after the explicit
//!      upgrade ops (DELETE vocab, UPDATE counts to empty blob, reindex latch).
//!      The `doc_count`/`vocab_size` anchors survive the blob zero; the reindex
//!      manifest key is set.
//!
//!   B. **Fresh v4 ↔ migrated v4 convergence:** A freshly opened v4 estate and a
//!      v3→v4-migrated estate both receive the same term payloads. `load_term_payloads`
//!      must return identical results, proving the two code paths share one
//!      read-layer.
//!
//! Uses file-backed SQLite (never InMemory): the migration ladder runs only
//! through SqliteStorage, so InMemory cannot exercise it.

use corpus_kit::corpus_provider_counts_store::{CorpusProviderCountsStore, PersistedCounts};
use corpus_kit::reindex_latch::{reindex_required, REINDEX_MANIFEST_KEY};
use persistence_kit::predicate::StoragePredicate;
use persistence_kit::schema::{ColumnDeclaration, SchemaDeclaration, TableDeclaration};
use persistence_kit::storage::{BackendConfiguration, EstateConfiguration, Storage};
use persistence_kit::sqlite::SqliteStorage;
use persistence_kit::types::{Column, TypedValue};
use queuekit::facade::QueueKit;
use queuekit::persistencekit::PersistenceKitBackend;
use persistence_kit::inmemory::InMemoryStorage;
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, OnceLock};
use uuid::Uuid;

// ─── Global lock ────────────────────────────────────────────────────────────

/// SQLite scratch files must not race in-process. Single mutex is sufficient
/// because all tests in this file share one SQLite-per-test and the files are
/// always distinct UUIDs.
static GLOBAL_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

fn global_lock() -> std::sync::MutexGuard<'static, ()> {
    match GLOBAL_LOCK.get_or_init(|| Mutex::new(())).lock() {
        Ok(g) => g,
        Err(p) => p.into_inner(),
    }
}

// ─── Deterministic time constant ────────────────────────────────────────────

/// Epoch-milliseconds passed to reindex_required. Never SystemTime::now()
/// (determinism mandate).
const NOW_MILLIS: i64 = 1_755_500_000_000;

/// Epoch-seconds for counts rows. Never SystemTime::now().
const NOW_SECS: i64 = 1_755_500_000;

// ─── Schema helpers ──────────────────────────────────────────────────────────

/// The `corpus_provider_counts` table declaration. Mirrors
/// `CorpusProviderCountsStore::schema_declaration`'s first table.
fn counts_table() -> TableDeclaration {
    TableDeclaration::new(
        "corpus_provider_counts",
        vec![
            ColumnDeclaration::text("model_id"),
            ColumnDeclaration::text("model_version"),
            ColumnDeclaration::blob("counts"),
            ColumnDeclaration::int("doc_count"),
            ColumnDeclaration::int("vocab_size"),
            ColumnDeclaration::timestamp("updated_at"),
            ColumnDeclaration::json("ext").nullable(),
        ],
        vec!["model_id".to_string(), "model_version".to_string()],
    )
}

/// The `corpus_provider_count_references` table declaration. Mirrors the second
/// table in `CorpusProviderCountsStore::schema_declaration`.
fn references_table() -> TableDeclaration {
    TableDeclaration::new(
        "corpus_provider_count_references",
        vec![
            ColumnDeclaration::text("model_id"),
            ColumnDeclaration::text("model_version"),
            ColumnDeclaration::text("content_id"),
            ColumnDeclaration::int("revision"),
            ColumnDeclaration::text("digest"),
            ColumnDeclaration::timestamp("updated_at"),
            ColumnDeclaration::json("ext").nullable(),
        ],
        vec![
            "model_id".to_string(),
            "model_version".to_string(),
            "content_id".to_string(),
        ],
    )
}

/// The v3 text-keyed vocab table. Created by the v2→v3 migration; superseded
/// by the v4 integer-keyed pair, but NOT dropped in the open path (ee#49).
fn vocab_table() -> TableDeclaration {
    TableDeclaration::new(
        "corpus_provider_vocab",
        vec![
            ColumnDeclaration::text("model_id"),
            ColumnDeclaration::text("model_version"),
            ColumnDeclaration::text("term"),
            ColumnDeclaration::blob("vector"),
            ColumnDeclaration::json("ext").nullable(),
        ],
        vec![
            "model_id".to_string(),
            "model_version".to_string(),
            "term".to_string(),
        ],
    )
}

/// A minimal key-value `manifest` table, needed so `reindex_required` can write
/// the latch key. The real estate carries this table as part of the LocusKit
/// schema; tests include it explicitly in their combined schema.
fn manifest_table() -> TableDeclaration {
    TableDeclaration::new(
        "manifest",
        vec![ColumnDeclaration::text("key"), ColumnDeclaration::text("value")],
        vec!["key".to_string()],
    )
}

/// A v3 schema declaration: three corpus tables + the manifest table.
///
/// Named "CorpusKitCounts" — the SAME name as `CorpusProviderCountsStore::
/// schema_declaration()` — so that when the v4 schema is subsequently opened on
/// the same file, the migration ladder detects the recorded version (3) and
/// applies the v3→v4 step (CREATE only, never DROP).
fn v3_schema() -> SchemaDeclaration {
    SchemaDeclaration::new(
        "CorpusKitCounts",
        3,
        vec![counts_table(), references_table(), vocab_table(), manifest_table()],
    )
}

// ─── Storage helpers ─────────────────────────────────────────────────────────

/// Temporary SQLite path, unique per call (UUID suffix).
fn scratch_path() -> String {
    std::env::temp_dir()
        .join(format!("corpuskit-conv-{}.sqlite3", Uuid::new_v4()))
        .to_string_lossy()
        .into_owned()
}

/// Open a file-backed SQLite storage instance at `path`. Does NOT run any
/// migration — callers call `storage.migrate(schema)` explicitly.
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

/// An in-memory QueueKit backed by PersistenceKitBackend. The convergence tests
/// use in-memory queues — they test store-layer semantics, not queue durability.
fn in_memory_queue() -> QueueKit<PersistenceKitBackend> {
    let cfg = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    let st: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(cfg));
    PersistenceKitBackend::open_schema(st.as_ref()).expect("open queue schema");
    let backend = PersistenceKitBackend::new(st);
    QueueKit::new(backend)
}

/// Read the reindex manifest latch value from the `manifest` table in
/// `storage`. Returns `Some("1")` when set, `None` when absent.
fn read_manifest_flag(storage: &dyn Storage) -> Option<String> {
    let key_col = Column::new("manifest", "key");
    let rows = storage
        .row_store()
        .query(
            "manifest",
            Some(&StoragePredicate::Eq(
                key_col,
                TypedValue::Text(REINDEX_MANIFEST_KEY.to_string()),
            )),
            &[],
            None,
            None,
        )
        .expect("query manifest");
    rows.into_iter().next().and_then(|row| {
        if let Some(TypedValue::Text(v)) = row.get("value") {
            Some(v.clone())
        } else {
            None
        }
    })
}

/// A deterministic 8-byte mock vector for a given term index. The real
/// providers use 8192-byte vectors (RI: 2048 × f32); 8 bytes is enough for
/// round-trip identity tests.
fn term_vector(seed: u8) -> Vec<u8> {
    vec![seed; 8]
}

// ─── Test A ──────────────────────────────────────────────────────────────────

/// Test A — migration is CREATE-only (ee#49); upgrade ops clear legacy rows,
/// preserve growth anchors, and set the reindex latch.
///
/// Steps:
///   1. Open v3 estate. Write 3 legacy vocab rows + one counts row
///      (doc_count=42, vocab_size=17, counts=b"legacy").
///   2. Close; re-open with v4 schema. Migration runs (CREATE-only).
///   3. Assert vocab rows are STILL PRESENT immediately after migration —
///      the open path does NOT bulk-transform.
///   4. Apply upgrade ops:
///      a. DELETE all rows from corpus_provider_vocab.
///      b. UPDATE corpus_provider_counts SET counts = b"".
///      c. Call reindex_required() (reindex latch).
///   5. Assert:
///      - vocab table: empty.
///      - v4 term payloads: empty (upgrade did not write any).
///      - growth anchors (doc_count=42, vocab_size=17): preserved.
///      - manifest latch "corpus_reindex_required": "1".
#[test]
fn migration_clears_vocab_preserves_anchors_and_sets_latch() {
    let _guard = global_lock();
    let path = scratch_path();

    // ── Step 1: open v3, write legacy data ───────────────────────────────────
    {
        let st = open_storage(&path);
        st.migrate(&v3_schema()).expect("v3 migrate");

        let rs = st.row_store();

        // Three legacy vocab rows for model "random-indexing-v1" / "1.0.0".
        for (i, term) in ["alpha", "beta", "gamma"].iter().enumerate() {
            let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
            values.insert("model_id".into(), TypedValue::Text("random-indexing-v1".into()));
            values.insert("model_version".into(), TypedValue::Text("1.0.0".into()));
            values.insert("term".into(), TypedValue::Text(term.to_string()));
            values.insert("vector".into(), TypedValue::Blob(term_vector(i as u8)));
            rs.upsert(
                "corpus_provider_vocab",
                values,
                &["model_id".into(), "model_version".into(), "term".into()],
            )
            .expect("insert vocab row");
        }

        // One counts row: opaque blob + anchors.
        let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
        values.insert("model_id".into(), TypedValue::Text("random-indexing-v1".into()));
        values.insert("model_version".into(), TypedValue::Text("1.0.0".into()));
        values.insert("counts".into(), TypedValue::Blob(b"legacy".to_vec()));
        values.insert("doc_count".into(), TypedValue::Int(42));
        values.insert("vocab_size".into(), TypedValue::Int(17));
        values.insert("updated_at".into(), TypedValue::Timestamp(NOW_SECS));
        rs.upsert(
            "corpus_provider_counts",
            values,
            &["model_id".into(), "model_version".into()],
        )
        .expect("insert counts row");

        let _ = st.close();
    }

    // ── Step 2: re-open with v4 schema — migration runs ──────────────────────
    let st = open_storage(&path);
    // The v4 schema carries the v3→v4 migration (CREATE corpus_provider_term_dictionary
    // + corpus_provider_term_payload). PersistenceKit detects the recorded version (3)
    // and applies the migration — a CREATE-only step.
    st.migrate(&CorpusProviderCountsStore::schema_declaration())
        .expect("v4 migrate");

    // ── Step 3: ee#49 invariant — vocab rows must still be present ───────────
    let vocab_rows_after_migration = st
        .row_store()
        .query("corpus_provider_vocab", None, &[], None, None)
        .expect("query vocab after migration");
    assert_eq!(
        vocab_rows_after_migration.len(),
        3,
        "v3→v4 migration is CREATE-only: legacy vocab rows must be present immediately \
         after migration (bulk transform belongs in mootx01 upgrade, not the open path — ee#49)"
    );

    // ── Step 4: apply upgrade ops ─────────────────────────────────────────────

    let rs = st.row_store();

    // 4a. DELETE all rows from corpus_provider_vocab.
    let vocab_deleted = rs
        .delete("corpus_provider_vocab", &StoragePredicate::IsTrue)
        .expect("delete vocab");
    assert_eq!(
        vocab_deleted, 3,
        "DELETE must clear all 3 legacy vocab rows"
    );

    // 4b. UPDATE corpus_provider_counts SET counts = b"" (zero the stale blob).
    let mut zero: BTreeMap<String, TypedValue> = BTreeMap::new();
    zero.insert("counts".into(), TypedValue::Blob(vec![]));
    let counts_updated = rs
        .update("corpus_provider_counts", zero, &StoragePredicate::IsTrue)
        .expect("zero counts blob");
    assert_eq!(
        counts_updated, 1,
        "UPDATE must touch exactly the one counts row"
    );

    // 4c. Call the reindex latch. In-memory queue — the latch enqueues a marker
    //     and writes to the manifest table. If the enqueue fails (never here),
    //     the manifest key is left clear and the deferral message is printed.
    let queue = in_memory_queue();
    reindex_required(&queue, st.as_ref(), NOW_MILLIS)
        .expect("reindex_required must not fail");

    // ── Step 5: assert final state ────────────────────────────────────────────

    // 5a. Vocab table must be empty.
    let vocab_after = rs
        .query("corpus_provider_vocab", None, &[], None, None)
        .expect("query vocab after upgrade");
    assert!(
        vocab_after.is_empty(),
        "vocab table must be empty after upgrade ops; found {} rows",
        vocab_after.len()
    );

    // 5b. V4 term payloads must be empty (upgrade does not write any).
    let store = CorpusProviderCountsStore::new(st.clone());
    let v4_terms = store.load_term_payloads("random-indexing-v1")
        .expect("load_term_payloads");
    assert!(
        v4_terms.is_empty(),
        "no v4 term payloads must exist after upgrade (they are written by the next reindex, \
         not by the migration or upgrade step)"
    );

    // 5c. Growth anchors must be preserved (UPDATE touched only the counts column).
    let anchor = store
        .growth_anchor("random-indexing-v1", "1.0.0")
        .expect("growth_anchor")
        .expect("counts row must still exist after upgrade");
    assert_eq!(
        anchor.document_count, 42,
        "doc_count anchor must survive counts blob zero"
    );
    assert_eq!(
        anchor.vocab_size, 17,
        "vocab_size anchor must survive counts blob zero"
    );

    // 5d. Reindex manifest latch must be "1".
    let flag = read_manifest_flag(st.as_ref());
    assert_eq!(
        flag.as_deref(),
        Some("1"),
        "reindex manifest key must be '1' after reindex_required; got {:?}",
        flag
    );

    let _ = st.close();
    let _ = std::fs::remove_file(&path);
}

// ─── Test B ──────────────────────────────────────────────────────────────────

/// Test B — fresh v4 estate and migrated v4 estate converge at the read layer.
///
/// Writes identical term payloads to:
///   - a fresh estate opened directly with the v4 schema, and
///   - an estate opened at v3, migrated to v4, and then written with the same data.
///
/// `load_term_payloads` must return the same (term, vector) pairs from both
/// estates, proving the two code paths share one consistent read layer.
#[test]
fn fresh_and_migrated_v4_converge() {
    let _guard = global_lock();

    let fresh_path = scratch_path();
    let migrated_path = scratch_path();

    // The shared term data: three terms for "random-indexing-v1".
    let terms: Vec<(String, Vec<u8>)> = vec![
        ("delta".to_string(), term_vector(10)),
        ("epsilon".to_string(), term_vector(11)),
        ("zeta".to_string(), term_vector(12)),
    ];

    // ── Fresh v4 estate ───────────────────────────────────────────────────────
    {
        let st = open_storage(&fresh_path);
        st.migrate(&CorpusProviderCountsStore::schema_declaration())
            .expect("fresh v4 migrate");

        let rs = st.row_store();

        // Write a counts header row so the key exists (needed for growth_anchor;
        // not required for load_term_payloads, but mirrors the migration path).
        let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
        values.insert("model_id".into(), TypedValue::Text("random-indexing-v1".into()));
        values.insert("model_version".into(), TypedValue::Text("1.0.0".into()));
        values.insert("counts".into(), TypedValue::Blob(vec![]));
        values.insert("doc_count".into(), TypedValue::Int(0));
        values.insert("vocab_size".into(), TypedValue::Int(0));
        values.insert("updated_at".into(), TypedValue::Timestamp(NOW_SECS));
        rs.upsert(
            "corpus_provider_counts",
            values,
            &["model_id".into(), "model_version".into()],
        )
        .expect("fresh v4: insert counts header");

        // Write term payloads via the v4 path.
        let store = CorpusProviderCountsStore::new(st.clone());
        store
            .replace_term_payloads_into("random-indexing-v1", &terms, &rs)
            .expect("fresh v4: replace_term_payloads_into");

        let _ = st.close();
    }

    // ── Migrated v4 estate ────────────────────────────────────────────────────
    {
        // Open at v3 with a counts row and legacy vocab.
        let st = open_storage(&migrated_path);
        st.migrate(&v3_schema()).expect("migrated: v3 migrate");

        let rs = st.row_store();

        // Write a counts row + legacy vocab (simulates a real pre-migration estate).
        let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
        values.insert("model_id".into(), TypedValue::Text("random-indexing-v1".into()));
        values.insert("model_version".into(), TypedValue::Text("1.0.0".into()));
        values.insert("counts".into(), TypedValue::Blob(b"old_blob".to_vec()));
        values.insert("doc_count".into(), TypedValue::Int(7));
        values.insert("vocab_size".into(), TypedValue::Int(3));
        values.insert("updated_at".into(), TypedValue::Timestamp(NOW_SECS));
        rs.upsert(
            "corpus_provider_counts",
            values,
            &["model_id".into(), "model_version".into()],
        )
        .expect("migrated: insert v3 counts row");

        for (i, term) in terms.iter().enumerate() {
            let mut v: BTreeMap<String, TypedValue> = BTreeMap::new();
            v.insert("model_id".into(), TypedValue::Text("random-indexing-v1".into()));
            v.insert("model_version".into(), TypedValue::Text("1.0.0".into()));
            v.insert("term".into(), TypedValue::Text(term.0.clone()));
            v.insert("vector".into(), TypedValue::Blob(term_vector(i as u8)));
            rs.upsert(
                "corpus_provider_vocab",
                v,
                &["model_id".into(), "model_version".into(), "term".into()],
            )
            .expect("migrated: insert vocab row");
        }

        let _ = st.close();
    }

    // Re-open the migrated estate with the v4 schema — migration runs.
    let st_migrated = open_storage(&migrated_path);
    st_migrated
        .migrate(&CorpusProviderCountsStore::schema_declaration())
        .expect("migrated: v4 migrate");

    // Apply upgrade ops (mirrors run_corpus_counts_migration in upgrade.rs).
    {
        let rs = st_migrated.row_store();
        rs.delete("corpus_provider_vocab", &StoragePredicate::IsTrue)
            .expect("migrated: delete vocab");
        let mut zero: BTreeMap<String, TypedValue> = BTreeMap::new();
        zero.insert("counts".into(), TypedValue::Blob(vec![]));
        rs.update("corpus_provider_counts", zero, &StoragePredicate::IsTrue)
            .expect("migrated: zero counts");

        // Write the same v4 term payloads as the fresh estate.
        let store = CorpusProviderCountsStore::new(st_migrated.clone());
        store
            .replace_term_payloads_into("random-indexing-v1", &terms, &rs)
            .expect("migrated: replace_term_payloads_into");
    }

    // ── Read-layer equivalence proof ──────────────────────────────────────────

    // Load from the fresh v4 estate.
    let st_fresh = open_storage(&fresh_path);
    st_fresh
        .migrate(&CorpusProviderCountsStore::schema_declaration())
        .expect("fresh read: migrate");
    let fresh_store = CorpusProviderCountsStore::new(st_fresh.clone());
    let mut fresh_terms = fresh_store
        .load_term_payloads("random-indexing-v1")
        .expect("fresh read: load_term_payloads");

    // Load from the migrated v4 estate.
    let migrated_store = CorpusProviderCountsStore::new(st_migrated.clone());
    let mut migrated_terms = migrated_store
        .load_term_payloads("random-indexing-v1")
        .expect("migrated read: load_term_payloads");

    // Sort both by term for stable comparison (load order is not specified).
    fresh_terms.sort_by(|a, b| a.0.cmp(&b.0));
    migrated_terms.sort_by(|a, b| a.0.cmp(&b.0));

    assert_eq!(
        fresh_terms.len(),
        migrated_terms.len(),
        "fresh v4 and migrated v4 must return the same number of terms \
         (fresh={}, migrated={})",
        fresh_terms.len(),
        migrated_terms.len()
    );
    assert_eq!(
        fresh_terms, migrated_terms,
        "fresh v4 and migrated v4 must return byte-identical term dictionaries — \
         the v4 read path is identical regardless of whether the estate was \
         freshly created or migrated from v3"
    );

    let _ = st_fresh.close();
    let _ = st_migrated.close();
    let _ = std::fs::remove_file(&fresh_path);
    let _ = std::fs::remove_file(&migrated_path);
}

/// delete_all must clear EVERY layout — v3 vocab AND the v4 pair (and the
/// pre-existing Rust gap: vocab itself was missing from delete_all pre-v4).
/// Wave-closing Adams CRITICAL 2. Twin of Swift deleteAllClearsEveryLayout.
#[test]
fn delete_all_clears_every_layout() {
    let path = scratch_path();
    let storage = open_storage(&path);
    storage.migrate(&CorpusProviderCountsStore::schema_declaration()).unwrap();
    let store = CorpusProviderCountsStore::new(storage.clone());
    let rs = storage.row_store();

    store.upsert(&PersistedCounts {
        model_id: "random-indexing-v1".into(),
        model_version: "1".into(),
        counts: b"blob".to_vec(),
        document_count: 1,
        vocab_size: 1,
        updated_at_secs: 1_700_000_000,
    }).unwrap();
    store.replace_vocab_into("random-indexing-v1", "1",
        &[("legacy".to_string(), vec![9u8])], &rs).unwrap();
    store.replace_term_payloads_into("random-indexing-v1",
        &[("modern".to_string(), vec![7u8])], &rs).unwrap();
    // Populated pre-state in BOTH layouts (falsification anchor).
    assert_eq!(store.load_term_payloads("random-indexing-v1").unwrap().len(), 1);
    assert_eq!(store.load_vocab("random-indexing-v1", "1").unwrap().len(), 1);

    store.delete_all().unwrap();

    assert!(store.load_term_payloads("random-indexing-v1").unwrap().is_empty(),
        "v4 payloads must not survive delete_all — stale v4 shadows the restore path");
    assert!(store.load_vocab("random-indexing-v1", "1").unwrap().is_empty(),
        "v3 vocab must not survive delete_all");
    assert_eq!(rs.count("corpus_provider_term_dictionary", None).unwrap(), 0,
        "dictionary rows must not survive delete_all");
}
