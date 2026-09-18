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

/// F4: a reanchor that moves a drawer to another room owes BOTH rooms a
/// rescoring — the room it joined (visible to the audit-fold, which resolves
/// a touched row's CURRENT parent at fold time) and the room it left (only
/// recoverable at the `reanchor` call site, since a pure room move leaves
/// `LatticeAnchor` — the only before/after state the audit event itself
/// carries — byte-identical). Before the fix, only the destination room was
/// ever owed; the source room's cohort silently went unscored after every
/// member it used to influence was gone. Twin of Swift
/// `anomalySweepOwesBothRoomsAfterMoveAndOwesRoomAfterExpunge`'s move half.
///
/// The destination room is seeded with a capture before the move (matching
/// the Swift fixture's workaround): `room_level_fingerprints` only lists a
/// room once something has been captured into it, so a never-captured room
/// cannot appear in the owed list regardless of this fix.
#[test]
fn anomaly_duty_owes_both_rooms_after_a_cross_room_move() {
    const DEST_ROOM: &str = "test-cohort-dest";
    let (coord, handle) = provision();
    for content in COHORT {
        capture(&coord, &handle, content);
    }
    let moved = capture(&coord, &handle, OUTLIER);

    // Seed the destination room so it is a known (already-scored) room, then
    // settle every current debt so the assertion below observes ONLY the
    // dirtying the move itself causes.
    let dest_frame = CaptureFrame::new(
        "seed content for the destination room", CaptureChannel::Typed, DEST_ROOM,
        LatticeAnchor::udc("000"), "anomaly-duty", "test-embed-v1");
    coord.capture(&handle, dest_frame, NOW).expect("seed capture");
    let owed_before_move = coord.anomaly_sweep_owed_rooms(&handle, NOW).expect("owed");
    let settled = coord
        .run_anomaly_sweep_batch(&handle, owed_before_move.len(), NOW)
        .expect("settle batch");
    assert_eq!(settled, owed_before_move.len(), "precondition: every room starts scored");
    assert_eq!(coord.duty_debt(&handle, DutyKind::AnomalySweep).expect("debt"), 0);

    // Move the outlier drawer from ROOM into DEST_ROOM.
    coord
        .reanchor(&handle, &moved, Some(DEST_ROOM), Some(WING), None)
        .expect("reanchor");

    let owed_after_move = coord.anomaly_sweep_owed_rooms(&handle, NOW + 1).expect("owed");
    assert!(
        owed_after_move.iter().any(|(w, r)| w == WING && r == ROOM),
        "the source room must be owed a rescoring — {owed_after_move:?}"
    );
    assert!(
        owed_after_move.iter().any(|(w, r)| w == WING && r == DEST_ROOM),
        "the destination room must be owed a rescoring — {owed_after_move:?}"
    );
}

/// The resident scores rooms with the coordinator lock released: the batch
/// is three phases, and the middle one (`anomaly_sweep_score`) takes only
/// the work the prepare phase handed out, never the coordinator. Proves the
/// split form pays exactly what the inline batch pays: the same rooms
/// scored, the same outlier flagged, the same debt settled to zero. Twin of
/// the Swift resident's detached `scoreRoom` loop.
#[test]
fn anomaly_sweep_split_phases_pay_the_same_as_the_inline_batch() {
    let (coord, handle) = provision();
    for content in COHORT {
        capture(&coord, &handle, content);
    }
    let outlier = capture(&coord, &handle, OUTLIER);
    let owed = coord.anomaly_sweep_owed_rooms(&handle, NOW).expect("owed");
    assert!(owed.iter().any(|(w, r)| w == WING && r == ROOM), "{owed:?}");

    let work = coord.anomaly_sweep_prepare(&handle, owed.len(), NOW).expect("prepare");
    assert_eq!(work.rooms, owed, "prepare hands out exactly the owed rooms");
    // Nothing here touches `coord`: the scoring runs on the cloned estate.
    let scored = genius_locus_kit::brain::anomaly_flag_sweep::anomaly_sweep_score(&work, NOW).expect("score");
    assert_eq!(scored, owed, "every prepared room is scored, in order");
    assert_eq!(coord.anomaly_sweep_settle(&handle, &scored, NOW).expect("settle"), owed.len());

    let estate = coord.estate_for(&handle).expect("estate");
    let flagged: Vec<String> = estate
        .drawers_in_wing_room(WING, ROOM)
        .expect("room")
        .into_iter()
        .filter(|d| d.is_anomalous())
        .map(|d| d.id)
        .collect();
    assert_eq!(flagged, vec![outlier], "the split form flags the same outlier as the batch");
    assert_eq!(coord.duty_debt(&handle, DutyKind::AnomalySweep).expect("debt"), 0, "settle clears the debt");
}
