//! SYN-1: the .vec sidecar freshness check must count the SAME row set the
//! sidecar is built from — serving-generation binary rows — not every binary
//! row in the table.
//!
//! After a shadow swap publishes, the superseded generation's rows stay in the
//! `vectors` table as 'pending-reclaim' until reclaim_superseded_generations
//! runs. The sidecar (rebuilt by publish) holds only the new serving rows. A
//! freshness check that counts all binary rows sees 2N against a sidecar
//! live_count of N and reports the sidecar stale on every open of such an
//! estate. This port already counts with the serving-generation predicate
//! (`binary_row_count(&gen_pred)`); this test pins that contract so the two
//! ports stay aligned. Twin: Tests/SynapseKitTests/SidecarFreshnessTests.swift.

use engram_lib::Engram;
use persistence_kit::{
    BackendConfiguration, Column, EstateConfiguration, SqliteStorage, Storage, StoragePredicate,
    TypedValue,
};
use std::sync::Arc;
use synapsekit::engine::mih::MIHBandCount;
use synapsekit::{VectorKind, VectorPayload, VectorStore};
use uuid::Uuid;

const MODEL: &str = "sidecar-freshness";
const FILED_AT: i64 = 1_700_000_000;

/// Distinct fingerprints: old-i lives in block0, new-i in block3, so the two
/// generations never collide on distance and the probe (new-0) ranks the
/// serving rows unambiguously.
fn old_engram(i: u64) -> Engram { Engram::new(0x0101 << i, 0, 0, 0) }
fn new_engram(i: u64) -> Engram { Engram::new(0, 0, 0, 0x8080 << i) }

fn write(store: &VectorStore, item_id: &str, engram: &Engram) {
    store
        .add_payload(item_id, 0, &VectorPayload::from_engram(engram), MODEL, "v1", FILED_AT)
        .expect("add_payload");
}

/// Reopen after publish (superseded rows pending reclaim): the sidecar is
/// current, so the new store loads it without a rebuild and serves exactly the
/// serving-generation rows.
#[test]
fn reopen_after_publish_does_not_rebuild_the_sidecar() {
    let db = std::env::temp_dir().join(format!("synapsekit-sidecar-freshness-{}.db", Uuid::new_v4()));
    let sidecar = db.with_extension("vectors.vec");
    let cfg = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite { path: db.to_string_lossy().to_string(), busy_timeout_secs: 5.0 },
    );
    let storage: Arc<dyn Storage> = Arc::new(SqliteStorage::new(cfg).expect("open SQLite"));
    storage.open(&VectorStore::schema_declaration()).expect("open schema");

    // Store A: 5 serving rows (generation 0), then a shadow swap that publishes
    // 5 new rows. Publish rebuilds the resident array from the new serving rows
    // and rewrites the sidecar; the gen-0 rows remain as 'pending-reclaim'.
    let store_a = VectorStore::new_with_threshold(
        Arc::clone(&storage), Some(sidecar.clone()), 50_000, MIHBandCount::M16);
    for i in 0..5u64 { write(&store_a, &format!("old-{i}"), &old_engram(i)); }
    store_a.begin_shadow_generation(&[MODEL]).expect("begin shadow");
    for i in 0..5u64 { write(&store_a, &format!("new-{i}"), &new_engram(i)); }
    store_a.publish_shadow_generation(&[MODEL]).expect("publish shadow");
    store_a.flush().expect("flush");
    drop(store_a);

    // Precondition: both generations are physically present (10 binary rows).
    let all_binary = storage
        .row_store()
        .query(
            "vectors",
            Some(&StoragePredicate::Eq(Column::new("vectors", "kind"), TypedValue::Int(VectorKind::Binary.raw()))),
            &[], None, None,
        )
        .expect("query");
    assert_eq!(all_binary.len(), 10, "precondition: superseded rows must still be pending reclaim");

    // Store B: a fresh open over the same table and sidecar.
    let store_b = VectorStore::new_with_threshold(
        Arc::clone(&storage), Some(sidecar.clone()), 50_000, MIHBandCount::M16);
    let hits = store_b.find_nearest(&new_engram(0), MODEL, 10).expect("find_nearest");
    let mut ids: Vec<String> = hits.iter().map(|m| m.item_id.clone()).collect();
    ids.sort();
    let expected: Vec<String> = (0..5).map(|i| format!("new-{i}")).collect();
    assert_eq!(ids, expected, "reopen must serve exactly the serving-generation rows");
    assert_eq!(
        store_b.sidecar_rebuild_count(), 0,
        "sidecar was current (live_count 5 == 5 serving-generation binary rows) but was rebuilt: the freshness count must apply the serving-generation predicate"
    );

    let _ = std::fs::remove_file(&sidecar);
    let _ = std::fs::remove_file(&db);
}
