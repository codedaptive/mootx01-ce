// t5_encode_settled_parity.rs — Finding 3 regression gate
// (PERF_W1_DRAIN_RIDER_2026-07-28): the T5 detached-drainer exit check must
// key on the ENCODE drain only.
//
// The subject-backfill and span-encode drain entries count rows by an
// eligibility predicate; rows that never transit the encode queue (a bare
// capture on a corpus-less estate, or an estate-wide activation of a new
// encoder model) leave those entries non-idle with no encode work
// outstanding. A finisher polling until ALL drains idle could then hold the
// encode DrainLease to its full max wait, wedging the next serve session's
// encode queue — so the T5 gate keys on the encode drain alone. (The
// wing-seed hints themselves ride the encode
// stream since DISTILL_SEED_STALL and settle under a normal drain.)
//
// Gate under test: `DrainStatus::encode_settled` — true iff the
// "corpus_encode" drain is idle or absent, regardless of every other drain.
// Swift twin: `DrainStatus.encodeSettled` (GeniusLocusKit/DrainStatus.swift).

use genius_locus_kit::DrainStatus;

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

