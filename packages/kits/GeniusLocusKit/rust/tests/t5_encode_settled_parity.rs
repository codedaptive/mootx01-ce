// t5_encode_settled_parity.rs — Finding 3 regression gate
// (PERF_W1_DRAIN_RIDER_2026-07-28): the T5 detached-drainer exit check must
// key on the ENCODE drain only.
//
// The "distillation" drain entry counts rows that only a `moot_distill`
// sweep or the hourly standing signal can distill — system-provisioned
// drawers (wing seeds, AI_Charter_Hint) never transit the encode queue, so
// the drain-stage rider never fires for them and the entry does not settle
// under the `mootx01 drain` command. A finisher polling until ALL drains
// idle therefore never exits, holds the encode DrainLease to its full max
// wait, and wedges the next serve session's encode queue (pending > 0,
// in_flight = 0, indefinitely).
//
// Gate under test: `DrainStatus::encode_settled` — true iff the
// "corpus_encode" drain is idle or absent, regardless of every other drain.
// Swift twin: DistillationDrainStageTests "Finding 3 regression" section
// (DrainStatus.encodeSettled).

use std::sync::Arc;

use genius_locus_kit::{DrainStatus, EstateCoordinator};
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::frames::CaptureFrame;
use persistence_kit::inmemory::InMemoryStorage;
use uuid::Uuid;

const NOW: i64 = 1_700_000_000;

fn status(name: &str, pending: usize, in_flight: usize) -> DrainStatus {
    DrainStatus {
        name: name.to_string(),
        pending,
        in_flight,
        detail: None,
    }
}

/// The Finding 3 shape: encode idle, distillation pending (system drawers
/// counted undistilled on an otherwise-drained estate). The gate must open —
/// distillation pending must not hold the T5 finisher or its lease.
#[test]
fn non_idle_distillation_drain_does_not_block_t5_exit() {
    let statuses = vec![
        status(DrainStatus::CORPUS_ENCODE_NAME, 0, 0),
        status("distillation", 7, 0),
    ];
    assert!(
        DrainStatus::encode_settled(&statuses),
        "distillation pending must not hold the T5 finisher or its lease"
    );
}

/// Encode work on either frontier keeps the gate closed.
#[test]
fn encode_work_on_either_frontier_keeps_gate_closed() {
    let pending = vec![
        status(DrainStatus::CORPUS_ENCODE_NAME, 3, 0),
        status("distillation", 0, 0),
    ];
    let in_flight = vec![status(DrainStatus::CORPUS_ENCODE_NAME, 0, 1)];
    assert!(!DrainStatus::encode_settled(&pending));
    assert!(!DrainStatus::encode_settled(&in_flight));
}

/// A bare estate (no corpus registered → no encode drain listed) reads
/// settled, even while its distillation entry is non-idle.
#[test]
fn absent_encode_drain_reads_settled() {
    assert!(DrainStatus::encode_settled(&[]));
    assert!(DrainStatus::encode_settled(&[status("distillation", 7, 0)]));
}

/// Live estate: captured-but-undistilled rows make the distillation drain
/// non-idle while no encode work exists — `drain_statuses` output must open
/// the T5 gate on exactly this estate.
#[test]
fn live_estate_with_undistilled_rows_opens_t5_gate() {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::with_storage(storage, NOW, None).unwrap());
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(store, OwnerCredentials::new("owner-t5-gate-tests"), 0, 100)
        .expect("open estate");

    // A bare capture is the same shape as Finding 3's system drawers: the row
    // exists but never transits the encode queue, so only a sweep can distill
    // it and the distillation entry stays non-idle.
    let frame = CaptureFrame::new(
        "This fact stands alone and remains undistilled.",
        CaptureChannel::Typed,
        "notes",
        LatticeAnchor::udc("004"),
        "test-actor",
        "minilm-v6",
    );
    coord.capture(&handle, frame, NOW).expect("capture drawer");

    let statuses = coord.drain_statuses(&handle).expect("drain_statuses");
    let distill = statuses
        .iter()
        .find(|s| s.name == "distillation")
        .expect("the distillation drain must be reported on every estate");
    assert!(
        distill.is_draining(),
        "precondition: the Finding 3 shape is present"
    );
    assert!(
        DrainStatus::encode_settled(&statuses),
        "the T5 finisher must exit (releasing the encode lease) on this estate"
    );
}
