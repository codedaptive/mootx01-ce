// anomaly_sweep_duty_parity.rs
//
// The incremental anomaly-sweep duty (§ DUTY_LIFECYCLE): a room is owed a
// scoring until it is scored, and again only after a write touches it. Twin
// of `anomalyDutyScoresOnlyTouchedRooms` in AnomalyFlagSweepTests.swift, on
// the same cohort content so both ports flag the same outlier.

use std::sync::Arc;

use corpus_kit::corpus::EmbeddingModelConfig;
use genius_locus_kit::brain::duty_queue::DutyKind;
use genius_locus_kit::coordinator::{EstateCoordinator, EstateKind, EstateLifetime, EstateProvisionParams, SyncMode};
use genius_locus_kit::handle::EstateHandle;
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::frames::CaptureFrame;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::storage::Storage;
use uuid::Uuid;

const NOW: i64 = 1_750_000_000_000;
const WING: &str = "Agentic Memory";
const ROOM: &str = "test-cohort";

const COHORT: [&str; 5] = [
    "Project Falcon deadline moved to March. Falcon deploy target is the staging cluster. Maria owns the Falcon rollout checklist.",
    "Project Falcon deadline moved to March. Falcon deploy target is the staging cluster. Maria owns the Falcon rollout list.",
    "Project Falcon deadline moved to March. Falcon deploy target is the staging cluster. Maria owns the Falcon deployment checklist.",
    "Project Falcon deadline was moved to March. Falcon deploy target is the staging cluster. Maria owns the Falcon rollout checklist.",
    "Project Falcon deadline moved to March. Falcon deploy target is the staging cluster. Maria controls the Falcon rollout checklist.",
];
const OUTLIER: &str =
    "Banana pudding recipe: vanilla wafers layered with custard and sliced bananas. Refrigerate overnight before serving.";

fn provision() -> (EstateCoordinator, EstateHandle) {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::with_storage(Arc::clone(&storage), NOW, None).unwrap());
    let storage_dyn: Arc<dyn Storage> = storage;
    let mut coord = EstateCoordinator::new();
    let params = EstateProvisionParams {
        estate_name: "Anomaly Duty Test Estate".to_string(),
        kind: EstateKind::Glk,
        zoom_window_low: 1,
        zoom_window_high: 10,
        framework_profile: "KnowledgeWork".to_string(),
        sync_mode: SyncMode::None,
        lifetime: EstateLifetime::Durable,
    };
    let handle = coord
        .provision(store, storage_dyn, None, OwnerCredentials::new("anomaly-duty"), params,
            vec![EmbeddingModelConfig::Deterministic])
        .expect("provision");
    (coord, handle)
}

fn capture(coord: &EstateCoordinator, handle: &EstateHandle, content: &str) -> String {
    let frame = CaptureFrame::new(content, CaptureChannel::Typed, ROOM, LatticeAnchor::udc("000"),
        "anomaly-duty", "test-embed-v1");
    coord.capture(handle, frame, NOW).expect("capture").id
}

#[test]
fn anomaly_duty_scores_only_touched_rooms() {
    let (coord, handle) = provision();
    for content in COHORT {
        capture(&coord, &handle, content);
    }
    let outlier = capture(&coord, &handle, OUTLIER);

    // Never scored: the room is owed.
    let owed_before = coord.anomaly_sweep_owed_rooms(&handle, NOW).expect("owed");
    assert!(owed_before.iter().any(|(w, r)| w == WING && r == ROOM), "{owed_before:?}");
    assert_eq!(coord.duty_debt(&handle, DutyKind::AnomalySweep).expect("debt"), owed_before.len());

    // One batch wide enough for every owed room scores them all and flags the outlier.
    let scored = coord.run_anomaly_sweep_batch(&handle, owed_before.len(), NOW).expect("batch");
    assert_eq!(scored, owed_before.len());
    let estate = coord.estate_for(&handle).expect("estate");
    let flagged: Vec<String> = estate
        .drawers_in_wing_room(WING, ROOM)
        .expect("room")
        .into_iter()
        .filter(|d| d.is_anomalous())
        .map(|d| d.id)
        .collect();
    assert_eq!(flagged, vec![outlier]);

    // Scored and untouched: nothing owed.
    assert_eq!(coord.duty_debt(&handle, DutyKind::AnomalySweep).expect("debt"), 0);

    // A write into the room makes exactly that room owed again.
    capture(&coord, &handle, COHORT[0]);
    let owed_after = coord.anomaly_sweep_owed_rooms(&handle, NOW + 1).expect("owed");
    assert_eq!(owed_after, vec![(WING.to_string(), ROOM.to_string())]);
}
