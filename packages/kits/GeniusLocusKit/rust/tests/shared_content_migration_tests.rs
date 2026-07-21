//! Resumable legacy-migration coverage (GLK shared-content 1.1, P4).
//! Rust twin of the Swift `SharedContentMigrationTests`.

use std::collections::BTreeMap;
use std::sync::Arc;

use corpus_kit::{Chunk, CorpusContentConfiguration, CorpusContentEngine,
    CorpusIndexUnitPolicy, CorpusOperatingMode, EmbeddingModelConfig};
use genius_locus_kit::intake::LocusDrawerContentSource;
use genius_locus_kit::shared_content_migration::{
    SharedContentMigrationError, SharedContentMigrationState,
};
use genius_locus_kit::EstateCoordinator;
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::drawer_store_sqlite::SqliteDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::frames::CaptureFrame;
use persistence_kit::database_inventory::capture_inventory;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{Storage, TypedValue};
use substrate_types::hlc::HLC;

const NOW: i64 = 1_700_000_000_000;

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
}

fn make_legacy_estate(contents: &[&str], include_orphan: bool, seed_protected: bool) -> LegacyEstate {
    // SQLite-backed like the Swift twin: the Rust BM25 sidecar persists in
    // the estate FILE, so a verification engine built after the migration
    // sees the rebuilt postings (an InMemory estate's sidecar is
    // per-connection by design).
    let mut coord = EstateCoordinator::new();
    let path = std::env::temp_dir()
        .join(format!("glk-scm-{}.sqlite", uuid::Uuid::new_v4()));
    let sqlite_store = SqliteDrawerStore::from_path(
        path.to_string_lossy().as_ref(), NOW, None, 5.0)
        .expect("SqliteDrawerStore::from_path");
    let store: Arc<dyn DrawerStore> = Arc::new(sqlite_store);
    let storage: Arc<dyn Storage> = store.storage().expect("sqlite store exposes storage");
    let handle = coord
        .open(store, OwnerCredentials::new("scm-owner"), 0, 100)
        .expect("open");

    let mut drawer_ids = Vec::new();
    for content in contents {
        let drawer = coord.capture(&handle, cap_frame(content), NOW).expect("capture");
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
        chunk.insert("source_id".into(), TypedValue::Text(drawer_ids[index].clone()));
        chunk.insert("start_offset".into(), TypedValue::Int(0));
        chunk.insert("length".into(), TypedValue::Int(content.len() as i64));
        chunk.insert("text".into(), TypedValue::Text(content.to_string()));
        chunk.insert("hlc".into(), TypedValue::Hlc(HLC {
            physical_time: (index + 1) as i64, logical_count: 0, node_id: 1 }));
        chunk.insert("metadata".into(), TypedValue::Json(b"{}".to_vec()));
        chunk.insert("created_at".into(), TypedValue::Timestamp(NOW));
        chunk.insert("ext".into(), TypedValue::Null);
        row_store.insert("chunks", chunk).expect("insert chunk");

        let mut vector: BTreeMap<String, TypedValue> = BTreeMap::new();
        vector.insert("id".into(), TypedValue::Uuid(uuid::Uuid::new_v4()));
        vector.insert("item_id".into(),
            TypedValue::Text(chunk_id.to_string().to_uppercase()));
        vector.insert("vector_index".into(), TypedValue::Int(0));
        vector.insert("model_id".into(), TypedValue::Text("corpus-deterministic-v1".into()));
        vector.insert("model_version".into(), TypedValue::Text("1.0.0".into()));
        vector.insert("kind".into(), TypedValue::Int(0));
        vector.insert("dim".into(), TypedValue::Int(256));
        vector.insert("payload".into(), TypedValue::Blob(vec![(index + 1) as u8; 32]));
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
        chunk.insert("hlc".into(), TypedValue::Hlc(HLC {
            physical_time: 99, logical_count: 0, node_id: 1 }));
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
        vector.insert("model_id".into(), TypedValue::Text("unrelated-lane-v1".into()));
        vector.insert("model_version".into(), TypedValue::Text("1.0.0".into()));
        vector.insert("kind".into(), TypedValue::Int(0));
        vector.insert("dim".into(), TypedValue::Int(256));
        vector.insert("payload".into(), TypedValue::Blob(vec![0xEE; 32]));
        vector.insert("scale".into(), TypedValue::Null);
        vector.insert("filed_at".into(), TypedValue::Timestamp(NOW));
        row_store.insert("vectors", vector).expect("insert protected");
    }
    LegacyEstate { coord, handle, storage, drawer_ids }
}

fn protected_payload(storage: &Arc<dyn Storage>, item_id: &str) -> Option<Vec<u8>> {
    let rows = storage
        .row_store()
        .query("vectors", None, &[], None, None)
        .ok()?;
    for row in rows {
        if let (Some(TypedValue::Text(item)), Some(TypedValue::Text(model)), Some(TypedValue::Blob(payload))) =
            (row.get("item_id"), row.get("model_id"), row.get("payload"))
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
    let store: Arc<dyn DrawerStore> = Arc::new(
        InMemoryDrawerStore::with_storage(Arc::clone(&backing), NOW, None).unwrap(),
    );
    let handle = coord
        .open(store, OwnerCredentials::new("scm-fresh"), 0, 100)
        .expect("open");
    let report = coord
        .run_shared_content_migration(&handle, NOW)
        .expect("fresh migration");
    assert_eq!(report.state, SharedContentMigrationState::Complete);
    assert_eq!(report.legacy_chunk_count, 0);
    let storage: Arc<dyn Storage> = backing;
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
        .run_shared_content_migration(&est.handle, NOW)
        .expect("migration");
    assert_eq!(report.state, SharedContentMigrationState::ReclaimPending);
    assert_eq!(report.legacy_chunk_count, 3);
    assert_eq!(report.legacy_vector_key_count, 3);
    assert_eq!(report.rebuilt_content_count, 3);

    assert!(est.storage.row_store().count("chunks", None).is_err());
    assert!(est.storage.row_store().count("corpus_metadata", None).is_err());

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
    assert_eq!(hits.first().map(|(id, _)| id.as_str()),
               Some(est.drawer_ids[2].as_str()));

    // Idempotent re-run, then reclaim completion.
    let rerun = est
        .coord
        .run_shared_content_migration(&est.handle, NOW)
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
    assert_eq!(status_after.state, Some(SharedContentMigrationState::Complete));
    assert_eq!(status_after.reclaimed_bytes, Some(maintenance.reclaimed_bytes));

    // Recall still works over the vacuumed file: the reclamation freed
    // pages, never derived state.
    let post_hits = engine.bm25_top_k("page reclamation", 5).expect("bm25");
    assert_eq!(post_hits.first().map(|(id, _)| id.as_str()),
               Some(est.drawer_ids[2].as_str()));
}

#[test]
fn orphaned_legacy_source_stops_dark_before_any_deletion() {
    let mut est = make_legacy_estate(&["Content with a valid drawer."], true, true);
    let result = est.coord.run_shared_content_migration(&est.handle, NOW);
    assert!(matches!(
        result,
        Err(SharedContentMigrationError::OrphanedLegacySources { .. })
    ));
    assert_eq!(est.storage.row_store().count("chunks", None).unwrap(), 2);
    assert!(EstateCoordinator::shared_content_lane_must_stay_dark(&est.storage));
}

#[test]
fn fault_after_every_state_resumes_to_the_same_outcome() {
    let contents = ["Resume drawer one.", "Resume drawer two."];

    let mut reference = make_legacy_estate(&contents, false, true);
    let reference_report = reference
        .coord
        .run_shared_content_migration(&reference.handle, NOW)
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
        let interrupted = est.coord.run_shared_content_migration(&est.handle, NOW);
        assert!(
            matches!(
                interrupted,
                Err(SharedContentMigrationError::InjectedFault { .. })
            ),
            "fault after {fault:?} must interrupt"
        );
        let resumed = est
            .coord
            .run_shared_content_migration(&est.handle, NOW)
            .expect("resume");
        assert_eq!(resumed.state, reference_report.state,
                   "fault after {fault:?} must resume to the reference state");
        assert_eq!(resumed.legacy_chunk_count, reference_report.legacy_chunk_count);
        assert_eq!(resumed.rebuilt_content_count, reference_report.rebuilt_content_count);
        let inventory = capture_inventory(
            &est.storage,
            &["vectors", "corpus_index_state"],
            &BTreeMap::new(),
        )
        .expect("inventory");
        let counts: Vec<usize> = inventory.iter().map(|i| i.row_count).collect();
        let reference_counts: Vec<usize> =
            reference_inventory.iter().map(|i| i.row_count).collect();
        assert_eq!(counts, reference_counts,
                   "fault after {fault:?}: row populations must match the uninterrupted run");
    }
}

#[test]
fn legacy_estate_keeps_corpus_lane_dark_until_migrated() {
    let mut est = make_legacy_estate(&["Dark lane drawer."], false, false);
    assert!(EstateCoordinator::shared_content_lane_must_stay_dark(&est.storage));
    est.coord
        .run_shared_content_migration(&est.handle, NOW)
        .expect("migration");
    assert!(!EstateCoordinator::shared_content_lane_must_stay_dark(&est.storage));
}
