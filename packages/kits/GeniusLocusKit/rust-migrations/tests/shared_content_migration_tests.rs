//! Resumable legacy-migration coverage (GLK shared-content 1.1, P4).
//! Rust twin of the Swift `SharedContentMigrationTests`.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::PathBuf;
use std::sync::Arc;

use corpus_kit::{
    Chunk, CorpusContentConfiguration, CorpusContentEngine, CorpusIndexUnitPolicy,
    CorpusOperatingMode, EmbeddingModelConfig,
};
use corpus_kit_providers::default_ensemble;
use genius_locus_kit::intake::LocusDrawerContentSource;
use genius_locus_kit::EstateCoordinator;
use genius_locus_kit_migrations::{
    SharedContentMigrationError, SharedContentMigrationExt, SharedContentMigrationState,
    SharedContentMigrationStore, SharedContentTrainingCapacity,
};
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::drawer_store_sqlite::SqliteDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::frames::CaptureFrame;
use persistence_kit::database_inventory::{canonical_row_encoding, capture_inventory};
use persistence_kit::dataset_store::{
    dataset_index_name, dataset_table_name, DatasetIndexDeclaration, DatasetSchema,
};
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::predicate::OrderClause;
use persistence_kit::schema::ColumnDeclaration;
use persistence_kit::{Column, Storage, TypedValue};
use substrate_types::hlc::HLC;

const NOW: i64 = 1_700_000_000_000;

#[test]
fn training_capacity_refuses_before_destructive_budget() {
    let required = SharedContentTrainingCapacity::required_bytes(98_118);
    assert!(required > 24 * 1_024 * 1_024 * 1_024);
    assert!(matches!(
        SharedContentTrainingCapacity::require_with_budget(98_118, 24 * 1_024 * 1_024 * 1_024,),
        Err(SharedContentMigrationError::InsufficientTrainingCapacity { .. })
    ));
    SharedContentTrainingCapacity::require_with_budget(2_000, 4 * 1_024 * 1_024 * 1_024)
        .expect("2k fixture fits 4 GiB budget");
}

#[test]
fn estate_format_distinguishes_unstamped_from_registered_missing_row() {
    use genius_locus_kit::estate_format::{EstateFormatError, EstateFormatStore};

    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(uuid::Uuid::new_v4()));
    let store = EstateFormatStore::new(Arc::clone(&storage));
    assert_eq!(store.read_if_present().unwrap(), None);
    storage
        .migrate(&EstateFormatStore::schema_declaration())
        .expect("register format schema without its singleton");
    assert!(matches!(
        store.read_if_present(),
        Err(EstateFormatError::Storage(_))
    ));
}

#[test]
fn below_compiled_floor_refuses_before_legacy_deletion() {
    let mut est = make_legacy_estate(&["below-floor estate remains untouched"], false, true);
    genius_locus_kit::estate_format::EstateFormatStore::new(Arc::clone(&est.storage))
        .stamp(
            genius_locus_kit::estate_format::EstateFormatVersion { major: 0, minor: 9 },
            NOW,
        )
        .expect("stamp below-floor fixture");
    let result = est
        .coord
        .run_shared_content_migration(&est.handle, NOW, default_ensemble());
    assert!(matches!(
        result,
        Err(SharedContentMigrationError::BelowCompiledFloor { .. })
    ));
    assert_eq!(est.storage.row_store().count("chunks", None).unwrap(), 1);
}

#[test]
fn future_format_refuses_before_migration_schema_or_legacy_deletion() {
    let mut est = make_legacy_estate(&["future-format estate remains untouched"], false, true);
    genius_locus_kit::estate_format::EstateFormatStore::new(Arc::clone(&est.storage))
        .stamp(
            genius_locus_kit::estate_format::EstateFormatVersion { major: 2, minor: 0 },
            NOW,
        )
        .expect("stamp future-format fixture");
    let result = est
        .coord
        .run_shared_content_migration(&est.handle, NOW, default_ensemble());
    assert!(matches!(
        result,
        Err(SharedContentMigrationError::UnsupportedFuture { .. })
    ));
    assert_eq!(est.storage.row_store().count("chunks", None).unwrap(), 1);
    assert_eq!(
        est.storage
            .current_schema_version_for("GLKSharedContentMigration")
            .unwrap(),
        0
    );
}

#[test]
fn malformed_registered_format_fails_closed_before_destructive_work() {
    let mut est = make_legacy_estate(&["malformed-format estate remains untouched"], false, true);
    genius_locus_kit::estate_format::EstateFormatStore::new(Arc::clone(&est.storage))
        .stamp(
            genius_locus_kit::estate_format::EstateFormatVersion::CURRENT,
            NOW,
        )
        .expect("stamp current-format fixture");
    rusqlite::Connection::open(&est.path)
        .expect("open raw probe")
        .execute(
            "UPDATE glk_estate_format SET major = 'malformed' WHERE id = 'estate-format'",
            [],
        )
        .expect("corrupt registered format row");

    let result = est
        .coord
        .run_shared_content_migration(&est.handle, NOW, default_ensemble());
    assert!(matches!(
        result,
        Err(SharedContentMigrationError::StorageFailure {
            state: SharedContentMigrationState::Discovered,
            ..
        })
    ));
    assert_eq!(est.storage.row_store().count("chunks", None).unwrap(), 1);
    assert_eq!(
        est.storage
            .current_schema_version_for("GLKSharedContentMigration")
            .unwrap(),
        0
    );
}

#[test]
fn current_format_without_migration_record_does_not_dark_attached_corpus() {
    let backing = Arc::new(InMemoryStorage::with_estate(uuid::Uuid::new_v4()));
    backing
        .migrate(&corpus_kit::attached_declaration())
        .expect("install current attached schema");
    genius_locus_kit::estate_format::EstateFormatStore::new(backing.clone())
        .stamp(
            genius_locus_kit::estate_format::EstateFormatVersion::CURRENT,
            NOW,
        )
        .expect("stamp current format");
    let storage: Arc<dyn Storage> = backing;

    assert!(!EstateCoordinator::shared_content_lane_must_stay_dark(
        &storage, None
    ));
    assert!(
        SharedContentMigrationStore::new(storage)
            .load()
            .expect("read optional migration record")
            .is_none(),
        "current-format estates do not need a historical migration record"
    );
}

fn cap_frame(content: &str) -> CaptureFrame {
    CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "scm",
        LatticeAnchor::udc("004"),
        "scm-test",
        "scm-v1",
    )
}

struct LegacyEstate {
    coord: EstateCoordinator,
    handle: genius_locus_kit::handle::EstateHandle,
    storage: Arc<dyn Storage>,
    drawer_ids: Vec<String>,
    path: PathBuf,
}

fn make_legacy_estate(
    contents: &[&str],
    include_orphan: bool,
    seed_protected: bool,
) -> LegacyEstate {
    // SQLite-backed like the Swift twin: the Rust BM25 sidecar persists in
    // the estate FILE, so a verification engine built after the migration
    // sees the rebuilt postings (an InMemory estate's sidecar is
    // per-connection by design).
    let mut coord = EstateCoordinator::new();
    let path = std::env::temp_dir().join(format!("glk-scm-{}.sqlite", uuid::Uuid::new_v4()));
    let sqlite_store =
        SqliteDrawerStore::from_path(path.to_string_lossy().as_ref(), NOW, None, 5.0)
            .expect("SqliteDrawerStore::from_path");
    let store: Arc<dyn DrawerStore> = Arc::new(sqlite_store);
    let storage: Arc<dyn Storage> = store.storage().expect("sqlite store exposes storage");
    let handle = coord
        .open(store, OwnerCredentials::new("scm-owner"), 0, 100)
        .expect("open");

    let mut drawer_ids = Vec::new();
    for content in contents {
        let drawer = coord
            .capture(&handle, cap_frame(content), NOW)
            .expect("capture");
        drawer_ids.push(drawer.id);
    }

    // Overlay the legacy copy lane.
    storage
        .migrate(&corpus_kit::BundleStore::schema_declaration())
        .expect("legacy chunks schema");
    storage
        .migrate(&corpus_kit::removed_source_store::RemovedSourceStore::schema_declaration())
        .expect("legacy removed_sources schema");
    storage
        .migrate(&vectorkit::VectorStore::schema_declaration())
        .expect("vectors schema");
    let row_store = storage.row_store();
    for (index, content) in contents.iter().enumerate() {
        let chunk_id = Chunk::derive_id(&drawer_ids[index], 0, content);
        let mut chunk: BTreeMap<String, TypedValue> = BTreeMap::new();
        chunk.insert("id".into(), TypedValue::Uuid(chunk_id));
        chunk.insert(
            "source_id".into(),
            TypedValue::Text(drawer_ids[index].clone()),
        );
        chunk.insert("start_offset".into(), TypedValue::Int(0));
        chunk.insert("length".into(), TypedValue::Int(content.len() as i64));
        chunk.insert("text".into(), TypedValue::Text(content.to_string()));
        chunk.insert(
            "hlc".into(),
            TypedValue::Hlc(HLC {
                physical_time: (index + 1) as i64,
                logical_count: 0,
                node_id: 1,
            }),
        );
        chunk.insert("metadata".into(), TypedValue::Json(b"{}".to_vec()));
        chunk.insert("created_at".into(), TypedValue::Timestamp(NOW));
        chunk.insert("ext".into(), TypedValue::Null);
        row_store.insert("chunks", chunk).expect("insert chunk");

        let mut vector: BTreeMap<String, TypedValue> = BTreeMap::new();
        vector.insert("id".into(), TypedValue::Uuid(uuid::Uuid::new_v4()));
        vector.insert(
            "item_id".into(),
            TypedValue::Text(chunk_id.to_string().to_uppercase()),
        );
        vector.insert("vector_index".into(), TypedValue::Int(0));
        vector.insert(
            "model_id".into(),
            TypedValue::Text("corpus-deterministic-v1".into()),
        );
        vector.insert("model_version".into(), TypedValue::Text("1.0.0".into()));
        vector.insert("kind".into(), TypedValue::Int(0));
        vector.insert("dim".into(), TypedValue::Int(256));
        vector.insert(
            "payload".into(),
            TypedValue::Blob(vec![(index + 1) as u8; 32]),
        );
        vector.insert("scale".into(), TypedValue::Null);
        vector.insert("filed_at".into(), TypedValue::Timestamp(NOW));
        row_store.insert("vectors", vector).expect("insert vector");
    }
    if include_orphan {
        let orphan_id = Chunk::derive_id("ghost-drawer", 0, "orphaned text");
        let mut chunk: BTreeMap<String, TypedValue> = BTreeMap::new();
        chunk.insert("id".into(), TypedValue::Uuid(orphan_id));
        chunk.insert("source_id".into(), TypedValue::Text("ghost-drawer".into()));
        chunk.insert("start_offset".into(), TypedValue::Int(0));
        chunk.insert("length".into(), TypedValue::Int(13));
        chunk.insert("text".into(), TypedValue::Text("orphaned text".into()));
        chunk.insert(
            "hlc".into(),
            TypedValue::Hlc(HLC {
                physical_time: 99,
                logical_count: 0,
                node_id: 1,
            }),
        );
        chunk.insert("metadata".into(), TypedValue::Json(b"{}".to_vec()));
        chunk.insert("created_at".into(), TypedValue::Timestamp(NOW));
        chunk.insert("ext".into(), TypedValue::Null);
        row_store.insert("chunks", chunk).expect("insert orphan");
    }
    if seed_protected {
        let mut vector: BTreeMap<String, TypedValue> = BTreeMap::new();
        vector.insert("id".into(), TypedValue::Uuid(uuid::Uuid::new_v4()));
        vector.insert("item_id".into(), TypedValue::Text(drawer_ids[0].clone()));
        vector.insert("vector_index".into(), TypedValue::Int(0));
        vector.insert(
            "model_id".into(),
            TypedValue::Text("unrelated-lane-v1".into()),
        );
        vector.insert("model_version".into(), TypedValue::Text("1.0.0".into()));
        vector.insert("kind".into(), TypedValue::Int(0));
        vector.insert("dim".into(), TypedValue::Int(256));
        vector.insert("payload".into(), TypedValue::Blob(vec![0xEE; 32]));
        vector.insert("scale".into(), TypedValue::Null);
        vector.insert("filed_at".into(), TypedValue::Timestamp(NOW));
        row_store
            .insert("vectors", vector)
            .expect("insert protected");
    }
    LegacyEstate {
        coord,
        handle,
        storage,
        drawer_ids,
        path,
    }
}

fn protected_payload(storage: &Arc<dyn Storage>, item_id: &str) -> Option<Vec<u8>> {
    let rows = storage
        .row_store()
        .query("vectors", None, &[], None, None)
        .ok()?;
    for row in rows {
        if let (
            Some(TypedValue::Text(item)),
            Some(TypedValue::Text(model)),
            Some(TypedValue::Blob(payload)),
        ) = (row.get("item_id"), row.get("model_id"), row.get("payload"))
        {
            if item == item_id && model == "unrelated-lane-v1" {
                return Some(payload.clone());
            }
        }
    }
    None
}

#[test]
fn fresh_estate_bypasses_and_never_creates_legacy_tables() {
    let mut coord = EstateCoordinator::new();
    let backing = Arc::new(InMemoryStorage::with_estate(uuid::Uuid::new_v4()));
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::with_storage(Arc::clone(&backing), NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new("scm-fresh"), 0, 100)
        .expect("open");
    let report = coord
        .run_shared_content_migration(&handle, NOW, default_ensemble())
        .expect("fresh migration");
    assert_eq!(report.state, SharedContentMigrationState::Complete);
    assert_eq!(report.legacy_chunk_count, 0);
    let storage: Arc<dyn Storage> = backing;
    storage
        .migrate(&corpus_kit::attached_declaration())
        .expect("install current attached schema");
    assert!(!EstateCoordinator::shared_content_lane_must_stay_dark(
        &storage, None
    ));
    let reopened = coord
        .run_shared_content_migration(&handle, NOW, default_ensemble())
        .expect("current-format reopen");
    assert_eq!(reopened.state, SharedContentMigrationState::Complete);
    assert!(storage.row_store().count("chunks", None).is_err());
}

#[test]
fn legacy_estate_migrates_selectively_and_verifies() {
    let contents = [
        "The migration must keep this drawer intact.",
        "A second drawer with distinct content for recall.",
        "Third drawer about physical page reclamation.",
    ];
    let mut est = make_legacy_estate(&contents, false, true);
    let protected_before =
        protected_payload(&est.storage, &est.drawer_ids[0]).expect("protected row");

    let report = est
        .coord
        .run_shared_content_migration(&est.handle, NOW, default_ensemble())
        .expect("migration");
    assert_eq!(report.state, SharedContentMigrationState::ReclaimPending);
    assert_eq!(report.legacy_chunk_count, 3);
    assert_eq!(report.legacy_vector_key_count, 3);
    assert_eq!(report.rebuilt_content_count, 3);

    assert!(est.storage.row_store().count("chunks", None).is_err());
    assert!(est
        .storage
        .row_store()
        .count("corpus_metadata", None)
        .is_err());

    // Drawer-keyed rows exist; protected row survived byte-identically.
    assert_eq!(
        protected_payload(&est.storage, &est.drawer_ids[0]),
        Some(protected_before)
    );

    // Rebuilt lane hydrates directly: BM25 hits ARE drawer IDs.
    let estate = est.coord.estate_for(&est.handle).unwrap().clone();
    let engine = CorpusContentEngine::open(
        Arc::clone(&est.storage),
        CorpusContentConfiguration::new(
            CorpusOperatingMode::Attached,
            CorpusIndexUnitPolicy::WholeContent,
        )
        .unwrap(),
        Arc::new(LocusDrawerContentSource::new(estate)),
        vec![EmbeddingModelConfig::Deterministic],
    )
    .expect("engine");
    let hits = engine.bm25_top_k("page reclamation", 5).expect("bm25");
    assert_eq!(
        hits.first().map(|(id, _)| id.as_str()),
        Some(est.drawer_ids[2].as_str())
    );

    // Idempotent re-run, then reclaim completion.
    let rerun = est
        .coord
        .run_shared_content_migration(&est.handle, NOW, default_ensemble())
        .expect("re-run");
    assert_eq!(rerun.state, SharedContentMigrationState::ReclaimPending);
    let status_before = est.coord.shared_content_reclaim_status(&est.handle);
    assert_eq!(
        status_before.state,
        Some(SharedContentMigrationState::ReclaimPending)
    );
    // Reclaim completion runs the PHYSICAL reclamation (WAL checkpoint +
    // VACUUM): the retired legacy tables' pages must actually leave the
    // filesystem, and the status surface must report the outcome.
    let maintenance = est
        .coord
        .complete_shared_content_reclaim(&est.handle, NOW)
        .expect("reclaim complete")
        .expect("maintenance report");
    assert!(maintenance.performed);
    assert_eq!(maintenance.backend, "sqlite");
    assert_eq!(maintenance.freelist_pages_after, 0);
    assert!(maintenance.reclaimed_bytes > 0);
    assert!(
        maintenance.file_size_bytes_after + maintenance.wal_bytes_after
            < maintenance.file_size_bytes_before + maintenance.wal_bytes_before
    );
    assert_eq!(
        est.coord.shared_content_migration_state(&est.handle),
        Some(SharedContentMigrationState::Complete)
    );
    let status_after = est.coord.shared_content_reclaim_status(&est.handle);
    assert_eq!(
        status_after.state,
        Some(SharedContentMigrationState::Complete)
    );
    assert_eq!(
        status_after.reclaimed_bytes,
        Some(maintenance.reclaimed_bytes)
    );

    // Recall still works over the vacuumed file: the reclamation freed
    // pages, never derived state.
    let post_hits = engine.bm25_top_k("page reclamation", 5).expect("bm25");
    assert_eq!(
        post_hits.first().map(|(id, _)| id.as_str()),
        Some(est.drawer_ids[2].as_str())
    );
}

#[test]
fn reclaim_compacts_large_inventory_before_vacuum() {
    let mut est = make_legacy_estate(&["inventory compaction fixture"], false, false);
    est.coord
        .run_shared_content_migration(&est.handle, NOW, default_ensemble())
        .expect("migration");

    // Inflate the durable evidence row enough that trimming it after VACUUM
    // necessarily creates observable freelist pages. This models the 59.7 MB
    // record seen in the 98k-Drawer qualification estate without making the
    // fast suite carry a million entries.
    let store = SharedContentMigrationStore::new(Arc::clone(&est.storage));
    let mut record = store.load().expect("load record").expect("record");
    let padding = "x".repeat(120);
    record.legacy_chunk_ids = (0..25_000)
        .map(|index| format!("chunk-{index:08}-{padding}"))
        .collect();
    record.legacy_vector_keys = (0..25_000)
        .map(|index| format!("vector-{index:08}-{padding}"))
        .collect();
    store.save(&record, NOW).expect("save inflated record");

    let report = est
        .coord
        .complete_shared_content_reclaim(&est.handle, NOW)
        .expect("reclaim")
        .expect("maintenance report");
    assert_eq!(report.freelist_pages_after, 0);

    let completed = store.load().expect("load completed").expect("record");
    assert_eq!(completed.legacy_chunk_count, Some(25_000));
    assert_eq!(completed.legacy_vector_key_count, Some(25_000));
    assert!(completed.legacy_chunk_ids.is_empty());
    assert!(completed.legacy_vector_keys.is_empty());

    // The post-maintenance completion save must not recreate the removed
    // inventory as freelist. This assertion failed on the pinned RC even
    // though MaintenanceReport itself claimed freelist_pages_after == 0.
    let connection = rusqlite::Connection::open(&est.path).expect("open probe");
    let actual_freelist: i64 = connection
        .query_row("PRAGMA freelist_count", [], |row| row.get(0))
        .expect("freelist probe");
    assert_eq!(actual_freelist, 0);
}

#[test]
fn mx_tabular_backing_table_and_handle_survive_migration_reclaim_and_reopen() {
    use genius_locus_kit::dataset_signatures::compute_dataset_signatures;
    use locus_kit::dataset_handle::{DatasetColumnSummary, DatasetHandleContent};

    let mut est = make_legacy_estate(&["ordinary drawer beside a protected dataset"], false, true);
    let dataset_id = uuid::Uuid::new_v4();
    let table_name = dataset_table_name(dataset_id);
    let index_name = dataset_index_name(dataset_id, "label");
    let dataset_store = est.storage.dataset_store().expect("dataset store");
    let schema = DatasetSchema {
        columns: vec![
            ColumnDeclaration::int("id"),
            ColumnDeclaration::text("label"),
            ColumnDeclaration::float("score").nullable(),
            ColumnDeclaration::text("note").nullable(),
        ],
        primary_key_column: Some("id".into()),
    };
    dataset_store
        .create_dataset(
            dataset_id,
            &schema,
            &[DatasetIndexDeclaration {
                column: "label".into(),
                unique: false,
            }],
        )
        .expect("create dataset");
    let mut row2 = BTreeMap::new();
    row2.insert("id".into(), TypedValue::Int(2));
    row2.insert("label".into(), TypedValue::Text("beta".into()));
    row2.insert("score".into(), TypedValue::Float(2.5));
    row2.insert("note".into(), TypedValue::Null);
    let mut row1 = BTreeMap::new();
    row1.insert("id".into(), TypedValue::Int(1));
    row1.insert("label".into(), TypedValue::Text("alpha".into()));
    row1.insert("score".into(), TypedValue::Float(1.25));
    row1.insert("note".into(), TypedValue::Text("kept".into()));
    dataset_store
        .append_rows(dataset_id, &[row2, row1])
        .expect("append dataset rows");

    let estate = est.coord.estate_for(&est.handle).unwrap().clone();
    let summaries = vec![
        DatasetColumnSummary {
            name: "id".into(),
            data_type: "INTEGER".into(),
        },
        DatasetColumnSummary {
            name: "label".into(),
            data_type: "TEXT".into(),
        },
        DatasetColumnSummary {
            name: "score".into(),
            data_type: "REAL".into(),
        },
        DatasetColumnSummary {
            name: "note".into(),
            data_type: "TEXT".into(),
        },
    ];
    let handle = estate
        .capture_dataset_handle(
            dataset_id,
            summaries.clone(),
            2,
            "migration preservation fixture",
            None,
            "datasets",
            "SharedContentMigrationTests",
            0,
            "004",
            NOW,
        )
        .expect("capture dataset handle");
    let order = [OrderClause::ascending(Column::new("", "id"))];
    let rows_before = dataset_store
        .query_rows(dataset_id, None, &order, None, None, None)
        .expect("rows before");
    let row_snapshot = |rows: &[persistence_kit::StorageRow]| -> Vec<String> {
        let excluded = BTreeSet::new();
        rows.iter()
            .map(|row| canonical_row_encoding(row, &excluded))
            .collect()
    };
    let rows_before_snapshot = row_snapshot(&rows_before);
    let mut stats_before = HashMap::new();
    for column in &summaries {
        stats_before.insert(
            column.name.clone(),
            dataset_store
                .column_stats(dataset_id, &column.name)
                .expect("stats before"),
        );
    }
    let signed =
        compute_dataset_signatures(&estate, &handle.id, &summaries, &stats_before, &rows_before)
            .expect("dataset signatures");
    let handle_json_before = signed.content.clone();
    let decoded = DatasetHandleContent::decode(&handle_json_before).expect("decode handle");
    assert!(decoded.table_signature.is_some());
    assert_eq!(decoded.column_signatures.as_ref().map(|m| m.len()), Some(4));

    fn ddl(path: &std::path::Path, table: &str, index: &str) -> Vec<(String, String, String)> {
        let conn = rusqlite::Connection::open(path).expect("open ddl connection");
        let mut statement = conn
            .prepare(
                "SELECT type, name, sql FROM sqlite_master \
                 WHERE name = ?1 OR name = ?2 ORDER BY name",
            )
            .expect("prepare ddl query");
        statement
            .query_map([table, index], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?))
            })
            .expect("query ddl")
            .collect::<Result<Vec<_>, _>>()
            .expect("collect ddl")
    }
    let ddl_before = ddl(&est.path, &table_name, &index_name);
    assert_eq!(ddl_before.len(), 2);

    est.coord
        .run_shared_content_migration(&est.handle, NOW, default_ensemble())
        .expect("migration");
    est.coord
        .complete_shared_content_reclaim(&est.handle, NOW)
        .expect("reclaim");
    let dataset_vectors = est
        .storage
        .row_store()
        .query(
            "vectors",
            Some(&persistence_kit::StoragePredicate::Eq(
                Column::new("vectors", "item_id"),
                TypedValue::Text(handle.id.clone()),
            )),
            &[],
            None,
            None,
        )
        .expect("dataset vectors");
    assert!(
        dataset_vectors.is_empty(),
        "dataset handle JSON must never be vectorized"
    );

    let reopened_store: Arc<dyn DrawerStore> = Arc::new(
        SqliteDrawerStore::from_path(est.path.to_string_lossy().as_ref(), NOW, None, 5.0)
            .expect("reopen drawer store"),
    );
    let reopened_storage = reopened_store.storage().expect("reopened storage");
    let reopened_dataset = reopened_storage
        .dataset_store()
        .expect("reopened dataset store");
    let rows_after = reopened_dataset
        .query_rows(dataset_id, None, &order, None, None, None)
        .expect("rows after");
    assert_eq!(row_snapshot(&rows_after), rows_before_snapshot);
    for column in &summaries {
        assert_eq!(
            reopened_dataset
                .column_stats(dataset_id, &column.name)
                .expect("stats after"),
            stats_before[&column.name],
        );
    }
    assert_eq!(ddl(&est.path, &table_name, &index_name), ddl_before);
    let mut reopened_coord = EstateCoordinator::new();
    let reopened_handle = reopened_coord
        .open(reopened_store, OwnerCredentials::new("scm-owner"), 0, 100)
        .expect("reopen estate");
    let reopened_drawer = reopened_coord
        .estate_for(&reopened_handle)
        .unwrap()
        .drawer_by_id(&handle.id)
        .expect("read handle")
        .expect("handle exists");
    assert_eq!(reopened_drawer.content, handle_json_before);
}

#[test]
fn ensemble_upgrade_covers_added_provider_and_stays_dark_until_then() {
    let mut est = make_legacy_estate(
        &[
            "Upgrade fixture drawer one about estates.",
            "Upgrade fixture drawer two about coverage.",
        ],
        false,
        true,
    );

    // Migrate under a ONE-provider configuration and finish reclaim.
    let small = vec![corpus_kit::corpus::EmbeddingModelConfig::Deterministic];
    let small_fp =
        CorpusContentEngine::configuration_fingerprint_for(CorpusOperatingMode::Attached, &small);
    let first = est
        .coord
        .run_shared_content_migration(&est.handle, NOW, small)
        .expect("first migration");
    assert_eq!(first.state, SharedContentMigrationState::ReclaimPending);
    est.coord
        .complete_shared_content_reclaim(&est.handle, NOW)
        .expect("reclaim");
    assert!(!EstateCoordinator::shared_content_lane_must_stay_dark(
        &est.storage,
        Some(small_fp.as_str())
    ));

    // Wire a LARGER ensemble: the completed record is NOT trusted — the
    // lane goes dark and the estate enters a follow-on upgrade.
    let big = || {
        vec![
            corpus_kit::corpus::EmbeddingModelConfig::Deterministic,
            corpus_kit::corpus::EmbeddingModelConfig::RandomIndexing {
                provider: Box::new(corpus_kit_providers::RandomIndexingProvider::new()),
            },
        ]
    };
    let big_fp =
        CorpusContentEngine::configuration_fingerprint_for(CorpusOperatingMode::Attached, &big());
    assert!(EstateCoordinator::shared_content_lane_must_stay_dark(
        &est.storage,
        Some(big_fp.as_str())
    ));

    // The upgrade trains the ADDED provider, backfills ONLY its missing
    // coverage, re-verifies, and restamps the fingerprint.
    let upgraded = est
        .coord
        .run_shared_content_migration(&est.handle, NOW, big())
        .expect("upgrade");
    assert_eq!(upgraded.state, SharedContentMigrationState::ReclaimPending);
    est.coord
        .complete_shared_content_reclaim(&est.handle, NOW)
        .expect("reclaim 2");
    assert!(!EstateCoordinator::shared_content_lane_must_stay_dark(
        &est.storage,
        Some(big_fp.as_str())
    ));

    // Every provider covers every drawer, and BM25 still serves.
    let estate = est.coord.estate_for(&est.handle).unwrap().clone();
    let engine = CorpusContentEngine::open(
        Arc::clone(&est.storage),
        CorpusContentConfiguration::new(
            CorpusOperatingMode::Attached,
            CorpusIndexUnitPolicy::WholeContent,
        )
        .unwrap(),
        Arc::new(LocusDrawerContentSource::new(estate)),
        big(),
    )
    .expect("engine");
    assert_eq!(
        engine
            .covered_count("corpus-deterministic-v1")
            .expect("count"),
        Some(est.drawer_ids.len())
    );
    assert_eq!(
        engine.covered_count("random-indexing-v1").expect("count"),
        Some(est.drawer_ids.len())
    );
    let hits = engine.bm25_top_k("coverage", 5).expect("bm25");
    assert_eq!(
        hits.first().map(|(id, _)| id.as_str()),
        Some(est.drawer_ids[1].as_str())
    );
}

#[test]
fn orphaned_legacy_source_stops_dark_before_any_deletion() {
    let mut est = make_legacy_estate(&["Content with a valid drawer."], true, true);
    let result = est
        .coord
        .run_shared_content_migration(&est.handle, NOW, default_ensemble());
    assert!(matches!(
        result,
        Err(SharedContentMigrationError::OrphanedLegacySources { .. })
    ));
    assert_eq!(est.storage.row_store().count("chunks", None).unwrap(), 2);
    assert!(EstateCoordinator::shared_content_lane_must_stay_dark(
        &est.storage,
        None
    ));
}

#[test]
fn fault_after_every_state_resumes_to_the_same_outcome() {
    let contents = ["Resume drawer one.", "Resume drawer two."];

    let mut reference = make_legacy_estate(&contents, false, true);
    let reference_report = reference
        .coord
        .run_shared_content_migration(&reference.handle, NOW, default_ensemble())
        .expect("reference run");
    let reference_inventory = capture_inventory(
        &reference.storage,
        &["vectors", "corpus_index_state"],
        &BTreeMap::new(),
    )
    .expect("reference inventory");

    let fault_states = [
        SharedContentMigrationState::Discovered,
        SharedContentMigrationState::CanonicalValidated,
        SharedContentMigrationState::LegacyInventoryCaptured,
        SharedContentMigrationState::LegacyDerivedCleared,
        SharedContentMigrationState::LegacySchemaRetired,
        SharedContentMigrationState::DrawerIndexRebuilt,
        SharedContentMigrationState::Verified,
    ];
    for fault in fault_states {
        let mut est = make_legacy_estate(&contents, false, true);
        est.coord.set_shared_content_fault(Some(fault));
        let interrupted =
            est.coord
                .run_shared_content_migration(&est.handle, NOW, default_ensemble());
        assert!(
            matches!(
                interrupted,
                Err(SharedContentMigrationError::InjectedFault { .. })
            ),
            "fault after {fault:?} must interrupt"
        );
        let resumed = est
            .coord
            .run_shared_content_migration(&est.handle, NOW, default_ensemble())
            .expect("resume");
        assert_eq!(
            resumed.state, reference_report.state,
            "fault after {fault:?} must resume to the reference state"
        );
        assert_eq!(
            resumed.legacy_chunk_count,
            reference_report.legacy_chunk_count
        );
        assert_eq!(
            resumed.rebuilt_content_count,
            reference_report.rebuilt_content_count
        );
        let inventory = capture_inventory(
            &est.storage,
            &["vectors", "corpus_index_state"],
            &BTreeMap::new(),
        )
        .expect("inventory");
        let counts: Vec<usize> = inventory.iter().map(|i| i.row_count).collect();
        let reference_counts: Vec<usize> =
            reference_inventory.iter().map(|i| i.row_count).collect();
        assert_eq!(
            counts, reference_counts,
            "fault after {fault:?}: row populations must match the uninterrupted run"
        );
    }
}

#[test]
fn legacy_estate_keeps_corpus_lane_dark_until_migrated() {
    let mut est = make_legacy_estate(&["Dark lane drawer."], false, false);
    assert!(EstateCoordinator::shared_content_lane_must_stay_dark(
        &est.storage,
        None
    ));
    est.coord
        .run_shared_content_migration(&est.handle, NOW, default_ensemble())
        .expect("migration");
    assert!(!EstateCoordinator::shared_content_lane_must_stay_dark(
        &est.storage,
        None
    ));
}
