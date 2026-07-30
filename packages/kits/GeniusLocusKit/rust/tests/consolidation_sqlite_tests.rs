// consolidation_sqlite_tests.rs — Wave-2 consolidation cycle on a SQLite
// (durable) estate backend.
//
// Proves that the parity gap is closed: Parts 1 and 2 of the
// rust-consolidation-persistence mission added the four consolidation method
// delegations to SqliteDrawerStore (and PostgresDrawerStore), so the same
// consolidation paths that work in-memory now also work on a WAL-mode SQLite
// estate.
//
// Coverage:
//   T-SQ1  act + constituent marking on SQLite estate
//   T-SQ2  fold-in on SQLite estate
//   T-SQ3  defrag (expunge + reconsolidate) on SQLite estate
//
// Construction pattern mirrors provision_lifecycle_parity.rs helpers:
//   - SqliteDrawerStore::from_path with a unique temp path
//   - cleanup_sqlite_file for WAL and SHM sidecars

use std::sync::Arc;

use genius_locus_kit::brain::consolidation_cycle::ConsolidationConfig;
use genius_locus_kit::EstateCoordinator;
use locus_kit::drawer_operational::{CaptureChannel, DrawerFeatureFlags};
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_sqlite::SqliteDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::frames::CaptureFrame;
use corpus_kit::{CorpusContentEngine, EmbeddingModelConfig};
use persistence_kit::inmemory::InMemoryStorage;
use uuid::Uuid;
use vectorkit::vector_store::VectorStore;

const NOW: i64 = 1_700_000_000;
const DAY: i64 = 86_400;

/// Cluster bodies that will form a vague item — same fixtures as the
/// in-memory consolidation_cycle_tests.
const CLUSTER_BODIES: [&str; 4] = [
    "Project Falcon deadline moved to March. Falcon deploy target is the staging cluster. Maria owns the Falcon rollout checklist.",
    "Project Falcon deadline moved to March. Falcon deploy target is the staging cluster. Maria owns the Falcon rollout checklist now.",
    "Project Falcon deadline moved to March again. Falcon deploy target is the staging cluster. Maria owns the Falcon rollout checklist.",
    "Project Falcon deadline moved to March. Falcon deploy target remains the staging cluster. Maria owns the Falcon rollout checklist.",
];

const DISTINCT_BODIES: [&str; 2] = [
    "Grandmother's lasagna recipe uses fresh basil. The oven runs hot at 400 degrees. Sunday dinners start at six.",
    "The telescope needs a new focuser knob. Jupiter rises after midnight this week. Collimation drifts in cold air.",
];

/// Build a SQLite estate store at a unique temp path. Returns (store, path)
/// for cleanup after the test. Mirrors provision_lifecycle_parity.rs.
fn make_sqlite_drawer_store() -> (SqliteDrawerStore, std::path::PathBuf) {
    let path = std::env::temp_dir()
        .join(format!("glk-consol-sqlite-{}.sqlite", Uuid::new_v4()));
    let store = SqliteDrawerStore::from_path(path.to_string_lossy().as_ref(), NOW, None, 5.0)
        .expect("SqliteDrawerStore::from_path must succeed");
    (store, path)
}

/// Remove a SQLite file and its WAL/SHM sidecars.
fn cleanup_sqlite_file(path: &std::path::Path) {
    let _ = std::fs::remove_file(path);
    let _ = std::fs::remove_file(format!("{}-wal", path.display()));
    let _ = std::fs::remove_file(format!("{}-shm", path.display()));
}

/// Open an in-memory VectorStore (not persisted; vector similarity uses the
/// in-memory path in these tests — the focus is LocusKit SQLite persistence).
fn make_inmem_vector_store() -> Arc<VectorStore> {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    Arc::new(VectorStore::open(storage).expect("VectorStore::open"))
}

/// Open an in-memory Corpus (needed for the cross-kit vector delete path in
/// defrag/expunge).
fn make_inmem_corpus() -> Arc<CorpusContentEngine> {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    Arc::new(
        CorpusContentEngine::standalone_on(storage, vec![EmbeddingModelConfig::Deterministic])
            .expect("Corpus::open"),
    )
}

/// Open a SQLite-backed estate with in-memory VectorStore and Corpus.
/// Returns (coord, handle, estate_path) so the caller can run assertions
/// and then clean up the SQLite file.
fn open_sqlite_estate() -> (EstateCoordinator, genius_locus_kit::EstateHandle, std::path::PathBuf) {
    let (sqlite_store, path) = make_sqlite_drawer_store();
    let store: Arc<dyn DrawerStore> = Arc::new(sqlite_store);
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(store, OwnerCredentials::new("owner-sqlite-consol"), 0, 100)
        .expect("open SQLite estate");
    let vs = make_inmem_vector_store();
    coord.register_vector_store(&handle, vs);
    let corpus = make_inmem_corpus();
    coord.register_corpus(&handle, corpus);
    (coord, handle, path)
}

fn capture_at(
    coord: &EstateCoordinator,
    handle: &genius_locus_kit::EstateHandle,
    body: &str,
    at: i64,
) -> String {
    let frame = CaptureFrame::new(
        body,
        CaptureChannel::Typed,
        "inbox",
        LatticeAnchor::udc("000"),
        "test-sqlite-consol",
        "test-model-v1",
    );
    coord.capture(handle, frame, at).expect("capture").id
}

/// Capture the fixture corpus on a SQLite estate, distill, sweep 91 days
/// later, and return the estate handle + cluster IDs + aged timestamp +
/// produced count for reuse across tests.
fn consolidated_sqlite_estate() -> (
    EstateCoordinator,
    genius_locus_kit::EstateHandle,
    Vec<String>,
    i64,
    usize,
    std::path::PathBuf,
) {
    let (coord, handle, path) = open_sqlite_estate();
    let mut cluster_ids = Vec::new();
    for (i, body) in CLUSTER_BODIES.iter().enumerate() {
        cluster_ids.push(capture_at(&coord, &handle, body, NOW + i as i64));
    }
    for (i, body) in DISTINCT_BODIES.iter().enumerate() {
        let _ = capture_at(&coord, &handle, body, NOW + 100 + i as i64);
    }
    coord
        .distill_items_sweep(&handle, NOW, None)
        .expect("distill sweep");
    let aged = NOW + 91 * DAY;
    let produced = coord
        .consolidation_sweep(&handle, aged, &ConsolidationConfig::default(), None)
        .expect("consolidation sweep on SQLite estate");
    (coord, handle, cluster_ids, aged, produced, path)
}

/// T-SQ1: consolidation act on SQLite estate marks constituents with bit-21
/// and produces exactly one vague item from the similar cluster.
///
/// This is the primary parity test: proves that Parts 1/2 of the mission
/// (adding consolidate_transactionally et al. to SqliteDrawerStore) resolve
/// the parity gap. Before the fix, this test would panic with
/// Err(DatabaseUnavailable) from the trait default.
#[test]
fn t_sq1_sweep_consolidates_cluster_on_sqlite_estate() {
    let (coord, handle, cluster_ids, _aged, produced, path) = consolidated_sqlite_estate();

    assert_eq!(produced, 1, "exactly the one similar cluster consolidates");

    // AC-5 surface: each constituent is still fetchable, non-vague, bit-21 set.
    for cid in &cluster_ids {
        let rows = coord
            .get_drawers(&handle, &[cid.as_str()])
            .expect("get constituent from SQLite store");
        let d = rows.first().expect("constituent row must be present");
        assert_ne!(
            d.operational_bitmap & DrawerFeatureFlags::REPRESENTED_BY_VAGUE,
            0,
            "constituent {cid} must have bit-21 (REPRESENTED_BY_VAGUE) set"
        );
        assert_eq!(
            d.operational_bitmap & DrawerFeatureFlags::IS_VAGUE,
            0,
            "constituent {cid} must NOT have bit-20 (IS_VAGUE)"
        );
        assert!(!d.content.is_empty(), "constituent content must be preserved");
    }

    cleanup_sqlite_file(&path);
}

/// T-SQ2: fold-in reconsolidation on SQLite estate enlarges the vague
/// lineage to include the fifth neighbour.
#[test]
fn t_sq2_fold_in_enlarges_vague_lineage_on_sqlite_estate() {
    let (coord, handle, cluster_ids, aged, produced, path) = consolidated_sqlite_estate();
    assert_eq!(produced, 1);

    let fifth = capture_at(
        &coord,
        &handle,
        "Project Falcon deadline moved to March. Falcon deploy target is the staging cluster. Maria still owns the Falcon rollout checklist.",
        NOW + 200,
    );
    coord
        .distill_items_sweep(&handle, aged + 3_600, None)
        .expect("distill fifth on SQLite");

    // Explicit D4 ceiling — matches the in-memory twin in consolidation_cycle_tests.
    let mut config = ConsolidationConfig::default();
    config.hamming_ceiling = Some(90);
    let report = coord
        .consolidation_sweep_report(&handle, aged + 92 * DAY, &config, None)
        .expect("fold sweep on SQLite estate");
    assert_eq!(report.fold_ins, 1, "the neighbour folds in on the SQLite estate");

    let v2 = coord
        .vague_recall(&handle, "Project Falcon rollout checklist", 8, 8, 32)
        .expect("vague recall after fold-in on SQLite");
    assert_eq!(v2.vague_hits.len(), 1, "exactly one ACTIVE vague version");
    let got: std::collections::BTreeSet<&str> =
        v2.constituents.iter().map(|d| d.id.as_str()).collect();
    let mut want: Vec<&str> = cluster_ids.iter().map(|s| s.as_str()).collect();
    want.push(fifth.as_str());
    let want: std::collections::BTreeSet<&str> = want.into_iter().collect();
    assert_eq!(got, want, "enlarged constituent set hydrates on SQLite estate");

    cleanup_sqlite_file(&path);
}

/// T-SQ3: defrag (expunge prior vague + reconsolidate) on SQLite estate
/// produces a fresh vague item without orphaned constituents.
#[test]
fn t_sq3_defrag_recomposes_without_orphans_on_sqlite_estate() {
    let (coord, handle, cluster_ids, aged, produced, path) = consolidated_sqlite_estate();
    assert_eq!(produced, 1);

    let hit = coord
        .vague_recall(&handle, "Project Falcon rollout checklist", 8, 8, 32)
        .expect("initial recall on SQLite");
    let vague_id = hit.vague_hits.first().expect("vague hit").id.clone();

    let report = coord
        .defrag_vague_item(&handle, &vague_id, aged + DAY, &ConsolidationConfig::default())
        .expect("defrag on SQLite estate");
    assert_eq!(
        report.new_vague_items, 1,
        "defrag must produce exactly one new vague item on SQLite"
    );

    let rebuilt = coord
        .vague_recall(&handle, "Project Falcon rollout checklist", 8, 8, 32)
        .expect("recall after defrag on SQLite");
    assert_eq!(rebuilt.vague_hits.len(), 1);
    assert_ne!(
        rebuilt.vague_hits[0].id, vague_id,
        "drifted vague item must have been expunged"
    );
    let got: std::collections::BTreeSet<&str> =
        rebuilt.constituents.iter().map(|d| d.id.as_str()).collect();
    let want: std::collections::BTreeSet<&str> =
        cluster_ids.iter().map(|s| s.as_str()).collect();
    assert_eq!(got, want, "constituents represented by the rebuilt item on SQLite");

    cleanup_sqlite_file(&path);
}
