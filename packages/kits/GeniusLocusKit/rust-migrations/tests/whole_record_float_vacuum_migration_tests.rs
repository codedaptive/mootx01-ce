//! Verification fixture for the GLK 1.6 → 1.7 whole-record float vacuum
//! migration. Rust twin of Swift `WholeRecordFloatVacuumMigrationTests.swift`.
//!
//! Fixture: an estate stamped V1_6 whose `vectors` table carries binary rows
//! (kind 0), whole-record float rows (kind 1) and Arctic span rows (kind 2),
//! one `hnsw_graph` row, and the corpus-kit representation claims on lanes
//! 0 and 1.
//!
//! Tests:
//!   1. After the capsule: kind 1 and the graph rows are gone, the kind 0
//!      and kind 2 counts are unchanged, the lane-1 claim is released and
//!      the lane-0 claim kept, the estate is stamped V1_7, the report carries
//!      the counts, and the binary lane returns the same ordered ids as
//!      before.
//!   2. Idempotence: a second run deletes nothing, releases nothing and
//!      leaves the stamp at V1_7.
//!   3. The format value is pinned: CURRENT is V1_7.
//!   4. On a SQLite estate the `.vec` sidecar is rewritten by the capsule and
//!      a fresh store loads it without a rebuild.
//!   5. V1_5-stamped estate: the chain runs the 1.5 → 1.6 capsule and then
//!      this one, ending at V1_7 (gated on feature = "migration-v1-5-to-v1-6").
//!   6. StorageUnavailable: an unregistered handle returns the error variant.
//!   7. With the `whole-record-dense` feature an estate whose manifest names a
//!      whole-record provider keeps its rows and is still stamped V1_7; the
//!      span encoder value vacuums like the default ensemble.

use std::collections::BTreeMap;
use std::sync::Arc;

use corpus_kit::CLAIMS_CONSUMER;
use engram_lib::Engram;
use genius_locus_kit::estate_format::{EstateFormatStore, EstateFormatVersion};
use genius_locus_kit::EstateCoordinator;
use genius_locus_kit_migrations::{
    WholeRecordFloatVacuumMigrationError, WholeRecordFloatVacuumMigrationExt,
    WholeRecordFloatVacuumMigrationReport,
};
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::OwnerCredentials;
use persistence_kit::{Column, Storage, StoragePredicate, TypedValue};
use synapsekit::engine::payload::{VectorKind, VectorPayload};
use synapsekit::{SpanVectorInput, VectorRepresentationClaims, VectorRepresentationKey, VectorStore};

const NOW: i64 = 1_756_000_000_000; // millis
const MODEL: &str = "corpus-deterministic-v1";
const VERSION: &str = "1.0.0";

fn binary_payload(fill: u8) -> VectorPayload {
    VectorPayload {
        kind: VectorKind::Binary,
        dim: 256,
        bytes: vec![fill; 32],
        scale: None,
    }
}

fn span(index: u32, int8: Vec<i8>) -> SpanVectorInput {
    SpanVectorInput {
        index,
        int8,
        scale: 1.0,
        start_word: 0,
        end_word: 3,
        content_version: "cv".to_string(),
    }
}

/// Write the fixture rows through the store's own writers: two binary rows
/// (kind 0, lane 0), two float rows (kind 1, lane 1), two span rows (kind 2)
/// under the Arctic model id, one raw hnsw_graph row, and the corpus-kit
/// claims on lanes 0 and 1.
fn seed_rows(storage: &Arc<dyn Storage>) {
    storage
        .migrate(&VectorStore::schema_declaration())
        .expect("vector schema");
    storage
        .migrate(&VectorRepresentationClaims::schema_declaration())
        .expect("claims schema");
    let store = VectorStore::new(Arc::clone(storage), None);
    store.add_payload("i1", 0, &binary_payload(0x0F), MODEL, VERSION, NOW).unwrap();
    store.add_payload("i2", 0, &binary_payload(0xF0), MODEL, VERSION, NOW).unwrap();
    store.add_payload("i1", 1, &VectorPayload::from_f32(&[1.0, 0.0]), MODEL, VERSION, NOW).unwrap();
    store.add_payload("i2", 1, &VectorPayload::from_f32(&[0.0, 1.0]), MODEL, VERSION, NOW).unwrap();
    store
        .write_span_vectors("i1", "arctic-embed-s-w60", "1", &[span(0, vec![1, 2]), span(1, vec![3, 4])], NOW)
        .unwrap();
    store.flush().unwrap();
    let mut graph: BTreeMap<String, TypedValue> = BTreeMap::new();
    graph.insert("model_id".into(), TypedValue::Text(MODEL.into()));
    graph.insert("node_idx".into(), TypedValue::Int(0));
    graph.insert("node_id".into(), TypedValue::Text("i1".into()));
    graph.insert("layer".into(), TypedValue::Int(0));
    graph.insert("neighbours".into(), TypedValue::Blob(vec![1, 0, 0, 0]));
    graph.insert("generation".into(), TypedValue::Int(0));
    storage.row_store().insert("hnsw_graph", graph).expect("hnsw_graph row");
    let claims = VectorRepresentationClaims::new(Arc::clone(storage));
    for lane in [0u32, 1u32] {
        claims
            .register_claim(CLAIMS_CONSUMER, &VectorRepresentationKey::new(MODEL, VERSION, lane), NOW)
            .expect("claim");
    }
}

fn kind_count(storage: &Arc<dyn Storage>, kind: i64) -> usize {
    storage
        .row_store()
        .count(
            "vectors",
            Some(&StoragePredicate::Eq(Column::new("vectors", "kind"), TypedValue::Int(kind))),
        )
        .expect("count vectors")
}

fn graph_count(storage: &Arc<dyn Storage>) -> usize {
    storage.row_store().count("hnsw_graph", None).expect("count hnsw_graph")
}

fn claim_lanes(storage: &Arc<dyn Storage>) -> Vec<u32> {
    VectorRepresentationClaims::new(Arc::clone(storage))
        .claims(CLAIMS_CONSUMER)
        .expect("claims")
        .iter()
        .map(|key| key.vector_index)
        .collect()
}

fn ordered_ids(storage: &Arc<dyn Storage>) -> Vec<String> {
    let store = VectorStore::new(Arc::clone(storage), None);
    store
        .find_nearest(&Engram::new(0x0F0F_0F0F_0F0F_0F0F, 0x0F0F_0F0F_0F0F_0F0F, 0x0F0F_0F0F_0F0F_0F0F, 0x0F0F_0F0F_0F0F_0F0F), MODEL, 10)
        .expect("find_nearest")
        .into_iter()
        .map(|m| m.item_id)
        .collect()
}

fn read_stamp(storage: &Arc<dyn Storage>) -> EstateFormatVersion {
    EstateFormatStore::new(Arc::clone(storage))
        .read_if_present()
        .expect("read format version")
        .expect("version must be set")
}

/// Open an in-memory estate stamped at `stamp_version` carrying the fixture rows.
fn make_estate(
    stamp_version: EstateFormatVersion,
) -> (
    EstateCoordinator,
    genius_locus_kit::handle::EstateHandle,
    Arc<dyn Storage>,
) {
    let store = Arc::new(InMemoryDrawerStore::new(NOW, None).expect("InMemoryDrawerStore::new"));
    let storage: Arc<dyn Storage> = store
        .storage()
        .expect("InMemoryDrawerStore exposes storage");
    seed_rows(&storage);
    EstateFormatStore::new(Arc::clone(&storage))
        .stamp(stamp_version, NOW)
        .expect("stamp estate format");
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(
            Arc::clone(&store) as Arc<dyn DrawerStore>,
            OwnerCredentials::new("mig17-test-owner"),
            0,
            100,
        )
        .expect("EstateCoordinator::open");
    (coord, handle, storage)
}

// ---------------------------------------------------------------------------
// §1 The float and graph rows go, the binary and span rows stay, V1_7 stamped
// ---------------------------------------------------------------------------

#[test]
fn v1_6_estate_loses_float_and_graph_rows_and_keeps_the_rest() {
    let (coord, handle, storage) = make_estate(EstateFormatVersion::V1_6);
    assert_eq!(kind_count(&storage, 0), 2);
    assert_eq!(kind_count(&storage, 1), 2);
    assert_eq!(kind_count(&storage, 2), 2);
    assert_eq!(graph_count(&storage), 1);
    assert_eq!(claim_lanes(&storage), vec![0, 1]);
    let before = ordered_ids(&storage);
    assert_eq!(before, vec!["i1".to_string(), "i2".to_string()]);

    let report = coord
        .run_whole_record_float_vacuum_migration(&handle, NOW)
        .expect("migration must succeed on a v1_6 estate");

    assert_eq!(
        report,
        WholeRecordFloatVacuumMigrationReport {
            float_rows: 2,
            graph_rows: 1,
            claims_released: 1,
            vacuumed: true,
            format: EstateFormatVersion::V1_7,
        }
    );
    assert_eq!(kind_count(&storage, 0), 2);
    assert_eq!(kind_count(&storage, 1), 0);
    assert_eq!(kind_count(&storage, 2), 2);
    assert_eq!(graph_count(&storage), 0);
    assert_eq!(claim_lanes(&storage), vec![0]);
    assert_eq!(read_stamp(&storage), EstateFormatVersion::V1_7);
    assert_eq!(read_stamp(&storage), EstateFormatVersion::CURRENT);
    assert_eq!(ordered_ids(&storage), before);
}

// ---------------------------------------------------------------------------
// §2 Idempotence
// ---------------------------------------------------------------------------

#[test]
fn capsule_is_idempotent() {
    let (coord, handle, storage) = make_estate(EstateFormatVersion::V1_6);
    let first = coord.run_whole_record_float_vacuum_migration(&handle, NOW).unwrap();
    assert_eq!((first.float_rows, first.graph_rows, first.claims_released), (2, 1, 1));
    let second = coord.run_whole_record_float_vacuum_migration(&handle, NOW).unwrap();
    assert_eq!(
        second,
        WholeRecordFloatVacuumMigrationReport {
            float_rows: 0,
            graph_rows: 0,
            claims_released: 0,
            vacuumed: true,
            format: EstateFormatVersion::V1_7,
        }
    );
    assert_eq!(kind_count(&storage, 0), 2);
    assert_eq!(kind_count(&storage, 2), 2);
    assert_eq!(claim_lanes(&storage), vec![0]);
    assert_eq!(read_stamp(&storage), EstateFormatVersion::V1_7);
}

// ---------------------------------------------------------------------------
// §3 The format value is pinned
// ---------------------------------------------------------------------------

#[test]
fn current_format_is_v1_7() {
    assert_eq!(EstateFormatVersion::CURRENT, EstateFormatVersion::V1_7);
    assert_eq!(EstateFormatVersion::V1_7, EstateFormatVersion { major: 1, minor: 7 });
    assert!(EstateFormatVersion::V1_6 < EstateFormatVersion::V1_7);
}

// ---------------------------------------------------------------------------
// §4 SQLite: the sidecar is rewritten and a fresh store loads it as current
// ---------------------------------------------------------------------------

#[test]
fn sqlite_estate_sidecar_is_rebuilt_and_loads_without_a_rebuild() {
    use locus_kit::drawer_store_sqlite::SqliteDrawerStore;
    let dir = std::env::temp_dir().join(format!("glk-mig17-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("estate.sqlite");
    let path_str = path.display().to_string();
    let store = Arc::new(SqliteDrawerStore::from_path(&path_str, NOW, None, 5.0).expect("sqlite store"));
    let storage: Arc<dyn Storage> = store.storage().expect("storage");
    seed_rows(&storage);
    EstateFormatStore::new(Arc::clone(&storage))
        .stamp(EstateFormatVersion::V1_6, NOW)
        .unwrap();
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(
            Arc::clone(&store) as Arc<dyn DrawerStore>,
            OwnerCredentials::new("mig17-sqlite-owner"),
            0,
            100,
        )
        .unwrap();
    let before = ordered_ids(&storage);

    let sidecar = VectorStore::default_sidecar_path(&storage).expect("sqlite has a sidecar path");
    let report = coord.run_whole_record_float_vacuum_migration(&handle, NOW).unwrap();
    assert_eq!((report.float_rows, report.graph_rows, report.claims_released), (2, 1, 1));
    assert!(sidecar.exists(), "the capsule rewrites the binary sidecar");

    // A fresh store over the vacuumed table finds the sidecar current: no
    // stale-sidecar rebuild, and the binary lane serves the same order.
    let fresh = VectorStore::new(Arc::clone(&storage), Some(sidecar));
    let after: Vec<String> = fresh
        .find_nearest(&Engram::new(0x0F0F_0F0F_0F0F_0F0F, 0x0F0F_0F0F_0F0F_0F0F, 0x0F0F_0F0F_0F0F_0F0F, 0x0F0F_0F0F_0F0F_0F0F), MODEL, 10)
        .unwrap()
        .into_iter()
        .map(|m| m.item_id)
        .collect();
    assert_eq!(after, before);
    assert_eq!(fresh.sidecar_rebuild_count(), 0, "the sidecar the capsule wrote is current");
    assert_eq!(kind_count(&storage, 1), 0);
    assert_eq!(read_stamp(&storage), EstateFormatVersion::V1_7);
}

// ---------------------------------------------------------------------------
// §5 Chain from V1_5 ends at V1_7
// ---------------------------------------------------------------------------

#[cfg(feature = "migration-v1-5-to-v1-6")]
#[test]
fn v1_5_estate_runs_both_capsules_to_current() {
    use genius_locus_kit_migrations::MigrationChainExt;
    let (mut coord, handle, storage) = make_estate(EstateFormatVersion::V1_5);
    coord
        .run_migration_chain(&handle, NOW, Vec::new())
        .expect("chain from v1_5");
    assert_eq!(read_stamp(&storage), EstateFormatVersion::V1_7);
    assert_eq!(kind_count(&storage, 1), 0);
    assert_eq!(graph_count(&storage), 0);
    assert_eq!(kind_count(&storage, 0), 2);
    assert_eq!(kind_count(&storage, 2), 2);
}

// ---------------------------------------------------------------------------
// §6 StorageUnavailable
// ---------------------------------------------------------------------------

#[test]
fn unregistered_handle_reports_storage_unavailable() {
    let coord = EstateCoordinator::new();
    let store = InMemoryDrawerStore::new(NOW, None).expect("InMemoryDrawerStore::new");
    let mut staging = EstateCoordinator::new();
    let stranger = staging
        .open(
            Arc::new(store),
            OwnerCredentials::new("unregistered-owner"),
            0,
            100,
        )
        .expect("open in staging coord");
    let err = coord
        .run_whole_record_float_vacuum_migration(&stranger, NOW)
        .expect_err("an unregistered handle must fail");
    assert!(matches!(err, WholeRecordFloatVacuumMigrationError::StorageUnavailable { .. }), "{err:?}");
}

// ---------------------------------------------------------------------------
// §7 The audition build keeps a whole-record provider's rows
// ---------------------------------------------------------------------------

#[cfg(feature = "whole-record-dense")]
#[test]
fn whole_record_provider_in_the_manifest_keeps_the_rows() {
    let (coord, handle, storage) = make_estate(EstateFormatVersion::V1_6);
    coord.provision_embedding_provider(&handle, "apple-nl-v1").unwrap();
    let report = coord.run_whole_record_float_vacuum_migration(&handle, NOW).unwrap();
    assert_eq!(
        report,
        WholeRecordFloatVacuumMigrationReport {
            float_rows: 0,
            graph_rows: 0,
            claims_released: 0,
            vacuumed: false,
            format: EstateFormatVersion::V1_7,
        }
    );
    assert_eq!(kind_count(&storage, 1), 2);
    assert_eq!(graph_count(&storage), 1);
    assert_eq!(claim_lanes(&storage), vec![0, 1]);
    assert_eq!(read_stamp(&storage), EstateFormatVersion::V1_7);
}

#[cfg(feature = "whole-record-dense")]
#[test]
fn span_encoder_in_the_manifest_still_vacuums() {
    let (coord, handle, storage) = make_estate(EstateFormatVersion::V1_6);
    coord
        .provision_embedding_provider(&handle, EstateCoordinator::ENCODER_PROVIDER_ID)
        .unwrap();
    let report = coord.run_whole_record_float_vacuum_migration(&handle, NOW).unwrap();
    assert!(report.vacuumed);
    assert_eq!(kind_count(&storage, 1), 0);
    assert_eq!(read_stamp(&storage), EstateFormatVersion::V1_7);
}
