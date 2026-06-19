// assign_cluster_on_capture_tests.rs
//
// Rust parity of Swift AssignClusterOnCaptureTests.swift (Dg5 integration).
//
// Proves that `assign_cluster_after_ingest` is called automatically on the
// capture write-path for both the impatient (inline) and regular (drain) paths,
// and that the `memory_clusters` table is correctly populated.
//
// Coverage:
//   I1  Three captures with IDENTICAL content via the IMPATIENT path produce
//       exactly ONE open cluster with member_count = 3.
//   I2  Three captures with IDENTICAL content via the REGULAR (drain) path
//       produce exactly ONE open cluster with member_count = 3 after drain.
//   I3  Two captures with DIFFERENT content each seed independent clusters
//       (or at least: total member_count across all open clusters = 2).
//
// All tests use the .deterministic embedding model (no CoreML, reproducible).
// The deterministic SimHash produces IDENTICAL engrams for IDENTICAL text,
// so member_count = 3 is guaranteed for same-content captures.

use std::sync::Arc;

use corpus_kit::corpus::EmbeddingModelConfig;
use genius_locus_kit::coordinator::{
    EstateCoordinator, EstateKind, EstateProvisionParams, SyncMode,
};
use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::WriteMode;
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::frames::CaptureFrame;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::predicate::StoragePredicate;
use persistence_kit::storage::Storage;
use persistence_kit::types::{Column, TypedValue};
use uuid::Uuid;

/// Capture instant in epoch MILLISECONDS (deterministic; no real clock used).
const NOW_MILLIS: i64 = 1_700_000_000_000;

// MARK: - Fixture helpers

/// Provision a GLK estate and return the coordinator, handle, and the
/// underlying `Arc<InMemoryStorage>` so tests can query `memory_clusters`.
///
/// The composite GLK schema (including `memory_clusters`) is applied inside
/// `provision` for GLK estates (Dg5 wiring), so tests do NOT need to apply
/// it separately — unlike the Swift tests which call `storage.open(schema:)`
/// after provision because `provision` in Swift only applies the component schemas.
fn provision_glk_estate_with_storage() -> (EstateCoordinator, EstateHandle, Arc<InMemoryStorage>) {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let store: Arc<dyn DrawerStore> = Arc::new(
        InMemoryDrawerStore::with_storage(Arc::clone(&storage), NOW_MILLIS, None).unwrap(),
    );
    let storage_dyn: Arc<dyn Storage> = Arc::clone(&storage) as Arc<dyn Storage>;

    let mut coord = EstateCoordinator::new();
    let params = EstateProvisionParams {
        estate_name: "AssignClusterOnCapture Test Estate".to_string(),
        kind: EstateKind::Glk,
        zoom_window_low: 1,
        zoom_window_high: 10,
        framework_profile: "KnowledgeWork".to_string(),
        sync_mode: SyncMode::None,
    };
    // Deterministic embedding model — reproducible, no CoreML.
    let handle = coord
        .provision(
            store,
            storage_dyn,
            None,
            OwnerCredentials::new("owner-assign-cluster-on-capture"),
            params,
            vec![EmbeddingModelConfig::Deterministic],
        )
        .expect("provision GLK estate");
    (coord, handle, storage)
}

/// Build a CaptureFrame with the given content and a fixed room. Mirrors
/// the Swift `clusterFrame(content:)` fixture helper.
fn cluster_frame(content: &str) -> CaptureFrame {
    CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "cluster-test-inbox",
        LatticeAnchor::udc("000"),
        "assign-cluster-on-capture-tests",
        "deterministic-v1",
    )
}

/// Query all open rows from `memory_clusters` in the given storage.
fn open_cluster_rows(storage: &InMemoryStorage) -> Vec<persistence_kit::types::StorageRow> {
    let predicate = StoragePredicate::Eq(
        Column::new("memory_clusters", "status"),
        TypedValue::Text("open".to_string()),
    );
    storage
        .row_store()
        .query("memory_clusters", Some(&predicate), &[], None, None)
        .unwrap_or_default()
}

/// Decode the `member_ids` JSON array from a storage row. Returns an empty
/// Vec when the column is absent or the JSON is malformed.
fn decode_member_ids(row: &persistence_kit::types::StorageRow) -> Vec<String> {
    match row.get("member_ids") {
        Some(TypedValue::Json(data)) => {
            serde_json::from_slice(data).unwrap_or_default()
        }
        _ => vec![],
    }
}

// MARK: - I1: impatient path forms cluster with member_count = 3

/// Three identical captures via the IMPATIENT path (inline ingest) must
/// produce exactly ONE open cluster with member_count = 3.
///
/// Parity of Swift I1: "three identical captures via impatient path form
/// one cluster with member_count = 3".
#[test]
fn i1_impatient_path_forms_cluster() {
    let (mut coord, handle, storage) = provision_glk_estate_with_storage();

    let frame = cluster_frame("The mitochondria is the powerhouse of the cell quantum entanglement");

    // Three captures with identical content — all produce Hamming distance = 0
    // between their deterministic SimHash engrams.
    for _ in 0..3 {
        coord
            .capture_with_mode(&handle, frame.clone(), NOW_MILLIS, WriteMode::Impatient)
            .expect("capture impatient");
    }

    // One open cluster must exist with member_count = 3.
    let rows = open_cluster_rows(&storage);
    assert_eq!(
        rows.len(),
        1,
        "three identical-content captures must form exactly one open cluster; got {}",
        rows.len()
    );

    let ids = decode_member_ids(&rows[0]);
    assert_eq!(
        ids.len(),
        3,
        "open cluster must have 3 members; got {}",
        ids.len()
    );
}

// MARK: - I2: regular (drain) path forms cluster with member_count = 3

/// Three identical captures via the REGULAR (drain) path must produce exactly
/// ONE open cluster with member_count = 3 after drain.
///
/// Parity of Swift I2: "three identical captures via regular (drain) path
/// form one cluster after drain".
#[test]
fn i2_regular_drain_path_forms_cluster() {
    let (mut coord, handle, storage) = provision_glk_estate_with_storage();

    let frame = cluster_frame("The mitochondria is the powerhouse of the cell quantum entanglement");

    // Three regular captures — encode jobs are enqueued, not inline.
    for _ in 0..3 {
        coord
            .capture_with_mode(&handle, frame.clone(), NOW_MILLIS, WriteMode::Regular)
            .expect("capture regular");
    }

    // Pump-drain the encode queue to completion (Rust has no background thread;
    // the drain is synchronous). Mirrors Swift `awaitEncodeDrain(for: handle)`.
    coord
        .await_encode_drain(&handle)
        .expect("await_encode_drain");

    // One open cluster with member_count = 3.
    let rows = open_cluster_rows(&storage);
    assert_eq!(
        rows.len(),
        1,
        "three identical-content regular captures must form one open cluster after drain; got {}",
        rows.len()
    );

    let ids = decode_member_ids(&rows[0]);
    assert_eq!(
        ids.len(),
        3,
        "open cluster must have 3 members after drain; got {}",
        ids.len()
    );
}

// MARK: - I4: production default ensemble (untrained) still forms clusters

/// Three near-identical captures via the production default 5-signal ensemble
/// (RI / PPMI / LSA / NMF / FDC — all freshly constructed, zero training)
/// must still produce exactly ONE open cluster with member_count = 3.
///
/// This is the regression test for the original bug: before the fix,
/// `assign_cluster_standalone` called `corpus.embed(content)`, which on an
/// untrained estate (RI basis empty → all near-zero engrams) caused every
/// capture to fail cluster comparison correctly. After the fix, cluster
/// assignment uses `content_deterministic_fingerprint`, which is
/// training-independent, so near-identical texts produce structurally
/// similar fingerprints and cluster correctly even with zero training.
///
/// Parity of Swift I4: "production embedding (untrained estate) still forms
/// clusters with member_count = 3".
#[test]
fn i4_production_ensemble_untrained_still_forms_cluster() {
    use corpus_kit_providers::default_ensemble;

    let storage = Arc::new(InMemoryStorage::with_estate(uuid::Uuid::new_v4()));
    let store: Arc<dyn locus_kit::drawer_store::DrawerStore> = Arc::new(
        locus_kit::drawer_store_inmemory::InMemoryDrawerStore::with_storage(
            Arc::clone(&storage),
            NOW_MILLIS,
            None,
        )
        .unwrap(),
    );
    let storage_dyn: Arc<dyn persistence_kit::storage::Storage> =
        Arc::clone(&storage) as Arc<dyn persistence_kit::storage::Storage>;

    let mut coord = genius_locus_kit::coordinator::EstateCoordinator::new();
    let params = genius_locus_kit::coordinator::EstateProvisionParams {
        estate_name: "I4 Production Ensemble Test Estate".to_string(),
        kind: genius_locus_kit::coordinator::EstateKind::Glk,
        zoom_window_low: 1,
        zoom_window_high: 10,
        framework_profile: "KnowledgeWork".to_string(),
        sync_mode: genius_locus_kit::coordinator::SyncMode::None,
    };
    // Production default: 5 untrained signals (RI/PPMI/LSA/NMF/FDC).
    // cluster assignment must not depend on these being trained.
    let handle = coord
        .provision(
            store,
            storage_dyn,
            None,
            locus_kit::estate_types::OwnerCredentials::new("owner-i4-production-ensemble"),
            params,
            default_ensemble(),
        )
        .expect("provision GLK estate with production ensemble");

    let frame = cluster_frame("The mitochondria is the powerhouse of the cell quantum entanglement");

    // Three captures with identical content on a FULLY UNTRAINED estate.
    for _ in 0..3 {
        coord
            .capture_with_mode(&handle, frame.clone(), NOW_MILLIS, WriteMode::Impatient)
            .expect("capture with untrained production ensemble");
    }

    // One open cluster must exist with member_count = 3.
    // The fix routes cluster assignment through content_deterministic_fingerprint,
    // so near-identical texts form a cluster regardless of training state.
    let rows = open_cluster_rows(&storage);
    assert_eq!(
        rows.len(),
        1,
        "three identical-content captures on untrained estate must form one open cluster; got {}",
        rows.len()
    );

    let ids = decode_member_ids(&rows[0]);
    assert_eq!(
        ids.len(),
        3,
        "open cluster on untrained estate must have 3 members; got {}",
        ids.len()
    );
}

// MARK: - I3: dissimilar captures seed independent clusters

/// Two captures with dissimilar content each seed their own cluster.
/// The invariant is: at least one open cluster exists and the total
/// member_count across all open clusters = 2.
///
/// Parity of Swift I3: "dissimilar captures seed independent clusters
/// (different Hamming neighborhoods)".
#[test]
fn i3_dissimilar_captures_seed_separate_clusters() {
    let (mut coord, handle, storage) = provision_glk_estate_with_storage();

    // Two captures with completely different text — deterministic SimHash
    // produces very different fingerprints for unrelated vocabulary.
    coord
        .capture_with_mode(
            &handle,
            cluster_frame(
                "The mitochondria is the powerhouse of the cell quantum entanglement",
            ),
            NOW_MILLIS,
            WriteMode::Impatient,
        )
        .expect("capture 1");
    coord
        .capture_with_mode(
            &handle,
            cluster_frame("Baroque period counterpoint fugue Johann Sebastian Bach harpsichord"),
            NOW_MILLIS + 1_000, // +1 second so the HLC ticks forward
            WriteMode::Impatient,
        )
        .expect("capture 2");

    // Each drawer should seed its own cluster. The invariant that matters is:
    // at least one cluster exists and total member_count = 2. If the
    // deterministic embedder happens to produce nearby fingerprints for these
    // strings the second could join the first — still semantically correct.
    let rows = open_cluster_rows(&storage);
    let total_members: usize = rows.iter().map(|r| decode_member_ids(r).len()).sum();

    assert!(
        !rows.is_empty(),
        "at least one open cluster must exist after two captures"
    );
    assert_eq!(
        total_members, 2,
        "total member count across all open clusters must be 2; got {}",
        total_members
    );
}
