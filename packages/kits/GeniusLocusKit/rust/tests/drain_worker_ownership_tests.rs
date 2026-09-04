//! A coordinator released without `close` leaves no engine alive. The
//! on_encoded rider and the drain worker both hold the engine weakly, so the
//! coordinator's registration is the last owner and releasing it stops the
//! worker. This is the shape of a host that opens an estate, captures, and
//! lets the coordinator go; an orphaned worker would keep indexing under the
//! composition policy that engine was opened with.

use std::sync::Arc;
use std::time::{Duration, Instant};

use corpus_kit::corpus::EmbeddingModelConfig;
use genius_locus_kit::coordinator::{
    EstateCoordinator, EstateKind, EstateLifetime, EstateProvisionParams, SyncMode,
};
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::frames::CaptureFrame;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::storage::Storage;
use uuid::Uuid;

const NOW: i64 = 1_700_000_000_000;

fn eventually(limit: Duration, done: impl Fn() -> bool) -> bool {
    let start = Instant::now();
    while start.elapsed() < limit {
        if done() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    done()
}

#[test]
fn releasing_the_coordinator_without_close_stops_the_engines_drain_worker() {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::with_storage(Arc::clone(&storage), NOW, None).unwrap());
    let storage: Arc<dyn Storage> = storage;
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .provision(
            Arc::clone(&store),
            Arc::clone(&storage),
            None,
            OwnerCredentials::new("owner-drain-ownership"),
            EstateProvisionParams {
                estate_name: "drain-ownership".to_string(),
                kind: EstateKind::Glk,
                zoom_window_low: 1,
                zoom_window_high: 10,
                framework_profile: "KnowledgeWork".to_string(),
                sync_mode: SyncMode::None,
                lifetime: EstateLifetime::Durable,
            },
            vec![EmbeddingModelConfig::Deterministic],
        )
        .expect("provision");
    // A capture enqueues an encode job, so the rider and the worker are both
    // live when the coordinator goes.
    let frame = CaptureFrame::new(
        "a capture whose encode job may still be in flight",
        CaptureChannel::Typed,
        "drain-ownership-tests",
        LatticeAnchor::udc("000"),
        "drain-ownership-tests",
        "test-model-v1",
    );
    coord.capture(&handle, frame, NOW).expect("capture");
    let weak = Arc::downgrade(&coord.corpus_for(&handle).expect("engine wired"));
    drop(coord);
    assert!(
        eventually(Duration::from_secs(5), || weak.upgrade().is_none()),
        "neither the on_encoded rider nor the drain worker may keep the engine alive once the coordinator is released"
    );
}
