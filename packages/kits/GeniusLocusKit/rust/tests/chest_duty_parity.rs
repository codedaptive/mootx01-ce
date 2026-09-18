// chest_duty_parity.rs — the chest re-bin duty and the per-container
// incremental anomaly sweep (ADR-026, spec § CHESTS). Twin of
// ChestDutyTests.swift on the same content.

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
use std::collections::BTreeSet;
use uuid::Uuid;

const NOW: i64 = 1_750_000_000_000;
const WING: &str = "Agentic Memory";
const ROOM: &str = "chest-duty";

fn provision() -> (EstateCoordinator, EstateHandle) {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::with_storage(Arc::clone(&storage), NOW, None).unwrap());
    let storage_dyn: Arc<dyn Storage> = storage;
    let mut coord = EstateCoordinator::new();
    let params = EstateProvisionParams {
        estate_name: "Chest Duty Test Estate".to_string(),
        kind: EstateKind::Glk,
        zoom_window_low: 1,
        zoom_window_high: 10,
        framework_profile: "KnowledgeWork".to_string(),
        sync_mode: SyncMode::None,
        lifetime: EstateLifetime::Durable,
    };
    let handle = coord
        .provision(store, storage_dyn, None, OwnerCredentials::new("chest-duty"), params,
            vec![EmbeddingModelConfig::Deterministic])
        .expect("provision");
    (coord, handle)
}

fn frame(content: &str, room: &str) -> CaptureFrame {
    CaptureFrame::new(content, CaptureChannel::Typed, room, LatticeAnchor::udc("000"), "chest-duty-tests", "minilm-v6")
}

#[test]
fn rebin_at_capacity_then_incremental_sweep() {
    let (mut coord, handle) = provision();
    let frames: Vec<CaptureFrame> = (0..500)
        .map(|i| frame(&format!("Project Falcon status note {i}: the deploy target is the staging cluster and Maria owns the rollout checklist."), ROOM))
        .collect();
    coord.capture_batch(&handle, frames, NOW).expect("batch");
    let estate = coord.estate_for(&handle).expect("estate").clone();

    // 500 drawers sit on the room itself: at capacity, one re-bin owed (the
    // provisioned estate's other rooms are small); the sweep skips a
    // container at capacity, so nothing in this room is owed a scoring yet.
    let in_room = |owed: &[genius_locus_kit::brain::anomaly_flag_sweep::AnomalyContainer]| -> BTreeSet<String> {
        owed.iter().filter(|c| c.room == ROOM).map(|c| c.node_id.to_lowercase()).collect()
    };
    assert_eq!(coord.chest_rebin_owed_rooms(&handle).unwrap(), vec![(WING.to_string(), ROOM.to_string())]);
    assert!(in_room(&coord.anomaly_sweep_owed_containers(&handle, NOW).unwrap()).is_empty());
    assert_eq!(coord.run_chest_rebin_batch(&handle, 1, NOW).unwrap(), 1);
    assert_eq!(coord.duty_debt(&handle, DutyKind::ChestRebin).unwrap(), 0);
    let chests = estate.chests_in(WING, ROOM).unwrap();
    assert_eq!(chests.iter().map(|c| c.count).collect::<Vec<_>>(), vec![250, 250]);

    // Every chest is owed a first scoring; one batch pays every owed container.
    let owed = coord.anomaly_sweep_owed_containers(&handle, NOW).unwrap();
    assert_eq!(in_room(&owed), chests.iter().map(|c| c.chest_node_id.to_lowercase()).collect::<BTreeSet<_>>());
    assert_eq!(coord.run_anomaly_sweep_batch(&handle, owed.len(), NOW).unwrap(), owed.len());
    assert_eq!(coord.duty_debt(&handle, DutyKind::AnomalySweep).unwrap(), 0);
    assert!(estate.drawers_in_wing_room(WING, ROOM).unwrap().iter().all(|d| !d.is_anomalous()), "a uniform cohort has no outlier");

    // One outlier capture owes exactly its chest; the incremental pass flags
    // it, and a whole rescore changes nothing more.
    let outlier = coord
        .capture(&handle, frame("Banana pudding recipe: vanilla wafers layered with custard and sliced bananas. Refrigerate overnight.", ROOM), NOW + 1_000)
        .unwrap();
    let owed_after = coord.anomaly_sweep_owed_containers(&handle, NOW + 1_000).unwrap();
    assert_eq!(owed_after.iter().map(|c| c.node_id.to_lowercase()).collect::<Vec<_>>(), vec![outlier.parent_node_id.to_lowercase()]);
    assert!(chests.iter().any(|c| c.chest_node_id.eq_ignore_ascii_case(&outlier.parent_node_id)), "the capture landed in a chest");
    assert_eq!(coord.run_anomaly_sweep_batch(&handle, 8, NOW + 1_000).unwrap(), 1);
    let flagged: Vec<String> = estate.drawers_in_wing_room(WING, ROOM).unwrap().into_iter().filter(|d| d.is_anomalous()).map(|d| d.id).collect();
    assert_eq!(flagged, vec![outlier.id.clone()]);
    assert_eq!(coord.anomaly_flag_sweep(&handle, 2.0, NOW + 2_000).unwrap(), 0, "the incremental sums and a whole rescore agree on every flag");

    // Moving the outlier to another room owes the chest it left and the
    // container it joined; scoring both clears the flag it no longer earns.
    // The destination is seeded first: the owed list walks the rooms the
    // container-fingerprint store knows, and a room is known once something
    // was captured into it.
    coord.capture(&handle, frame("seed for the destination room", "elsewhere"), NOW + 2_000).unwrap();
    coord.run_anomaly_sweep_batch(&handle, 8, NOW + 2_500).unwrap();
    coord.reanchor(&handle, &outlier.id, Some("elsewhere"), None, None).unwrap();
    let moved = estate.get_drawers(&[outlier.id.as_str()]).unwrap().remove(0);
    let owed_move: BTreeSet<String> = coord.anomaly_sweep_owed_containers(&handle, NOW + 3_000).unwrap().iter().map(|c| c.node_id.to_lowercase()).collect();
    assert_eq!(owed_move, [outlier.parent_node_id.to_lowercase(), moved.parent_node_id.to_lowercase()].into_iter().collect());
    assert_eq!(coord.run_anomaly_sweep_batch(&handle, 8, NOW + 3_000).unwrap(), 2);
    assert!(!estate.get_drawers(&[outlier.id.as_str()]).unwrap()[0].is_anomalous(), "alone in its new room, the drawer is not an outlier");
    assert_eq!(coord.duty_debt(&handle, DutyKind::AnomalySweep).unwrap(), 0);
}
