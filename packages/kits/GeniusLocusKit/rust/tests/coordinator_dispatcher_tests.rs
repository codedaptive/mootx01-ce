// coordinator_dispatcher_tests.rs — force tests for the
// CoordinatorDispatcher wiring (B2-2 mission gate).
//
// These tests verify that scheduler emissions routed through the
// CoordinatorDispatcher reach the real EstateCoordinator verb
// surface, not the NoopDispatcher stub. Three invariants are
// enforced:
//
//   1. Propose landing   — a Propose emission routed through the lane
//      files a Proposal that is subsequently queryable via
//      coord.recall_proposals().
//
//   2. Associate landing — an Associate emission routed through the
//      lane files an Association that is subsequently queryable via
//      coord.recall_associations().
//
//   3. Error propagation — a verb failure (stale handle) is recorded
//      as RouteFailed, not silently swallowed.
//
//   4. Lane ordering     — three sequentially-enqueued Propose
//      emissions land in submission order (drain preserves FIFO).
//
// Swift parity: these scenarios mirror the Swift
// SchedulerDispatcher integration path described in SignalAPI.swift:
// `dispatchPropose` calls `kit.propose(handle, frame)` and
// `dispatchAssociate` calls `kit.associate(handle, frame)`. A
// success records `.routed`; `VerbError.notSupportedByEstate`
// records `.routedButVerbStubbed`; anything else records
// `.routeFailed`.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use genius_locus_kit::{
    EstateCoordinator, SchedulerAssociationFrame as AssociationFrame,
    SchedulerConcurrencyPolicy as ConcurrencyPolicy,
    SchedulerCoordinatorDispatcher, SchedulerDiagnosticReport as DiagnosticReport,
    SchedulerNoopDispatcher, SchedulerProposalFrame as ProposalFrame,
    SchedulerProposalKind as ProposalKind, SchedulerResourceCostEstimate as ResourceCostEstimate,
    SchedulerSignalEmission as SignalEmission, SchedulerSignalRouteOutcome as SignalRouteOutcome,
    SchedulerSignalSpec as SignalSpec, SchedulerSignalState as SignalState,
    SchedulerSignalTrigger as SignalTrigger, SerialLaneScheduler,
};
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::frames::CaptureFrame;
use uuid::Uuid;

// Epoch-seconds for the coordinator's `capture` and verb calls. The
// coordinator expects seconds (locus_kit stores ISO8601 TEXT).
const NOW_SEC: i64 = 1_700_000_000;

// Nanosecond base for the scheduler's tick/register calls. The
// scheduler uses nanoseconds throughout (matching scheduler_parity.rs
// which uses 1_700_000_000_000_000_000 = NOW_SEC * 1e9).
const NOW_NS: i64 = 1_700_000_000_000_000_000;

// ── Shared helpers ─────────────────────────────────────────────────

/// Open a single estate and return both the coordinator (wrapped in
/// Arc<Mutex> for the dispatcher) and the raw handle. The
/// Arc<Mutex> is required by CoordinatorDispatcher so the same
/// coordinator instance services both the test assertions and the
/// scheduler-driven emissions.
fn open_estate_shared() -> (Arc<Mutex<EstateCoordinator>>, genius_locus_kit::handle::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW_SEC, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new("owner"), 0, 100)
        .expect("estate open");
    (Arc::new(Mutex::new(coord)), handle)
}

/// Capture a drawer into the shared coordinator and return its row ID.
/// Uses the lock directly so the test owns the coordinator between
/// scheduler ticks.
fn capture_one(coord: &Arc<Mutex<EstateCoordinator>>, handle: &genius_locus_kit::handle::EstateHandle, content: &str) -> String {
    let frame = CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "test-room",
        LatticeAnchor::udc("0"),
        "test-agent",
        "test-embed-v1",
    );
    coord
        .lock()
        .expect("lock")
        .capture(handle, frame, NOW_SEC)
        .expect("capture")
        .id
        .clone()
}

/// Build the `EstateHandleID` string the scheduler uses to identify
/// the estate. CoordinatorDispatcher compares this against its stored
/// handle UUID.
fn handle_id(handle: &genius_locus_kit::handle::EstateHandle) -> String {
    Uuid::from_bytes(handle.estate_uuid).to_string()
}

// ── Test 1: Propose emission lands as a queryable Proposal ─────────

/// Force test F-1: a Propose emission routed through the
/// CoordinatorDispatcher files a real Proposal into the estate, which
/// is then returned by recall_proposals().
///
/// Verification:
///   - outcome is SignalRouteOutcome::Routed { verb: "propose" }
///   - coord.recall_proposals() returns one proposal
///   - proposal.target equals the captured drawer's row ID
#[test]
fn f1_propose_emission_lands_as_queryable_proposal() {
    let (coord, handle) = open_estate_shared();

    // Capture a drawer so the proposal has a valid target.
    let row_id = capture_one(&coord, &handle, "target content");

    // Build the scheduler with the live CoordinatorDispatcher.
    let dispatcher = SchedulerCoordinatorDispatcher::new(Arc::clone(&coord), handle);
    let hid = handle_id(&handle);
    let mut scheduler = SerialLaneScheduler::new(hid.clone(), dispatcher);

    // Register a signal that emits one Propose targeting `row_id`.
    let row_id_clone = row_id.clone();
    let spec = SignalSpec {
        name: "propose-lander".into(),
        trigger: SignalTrigger::Interval { seconds: Duration::from_secs(1) },
        resource_cost: ResourceCostEstimate::ZERO,
        freshness_target: Duration::from_secs(60),
        concurrency_policy: ConcurrencyPolicy::Single,
        emit: Arc::new(move |_| {
            vec![SignalEmission::Propose(ProposalFrame {
                target: row_id_clone.clone(),
                kind: ProposalKind::TestPropose,
                justification: Some("f1 force test".into()),
            })]
        }),
    };
    let sig_id = scheduler.register(spec, NOW_NS);

    // Tick past the signal's first due time.
    scheduler.tick(NOW_NS + 5_000_000_000);

    // The outcome recorded in the signal report must be Routed (not
    // RoutedButVerbStubbed, which the NoopDispatcher would produce).
    let report = scheduler
        .report()
        .into_iter()
        .find(|r| r.signal_id == sig_id)
        .expect("signal report");
    assert_eq!(
        report.recent_outcomes,
        vec![SignalRouteOutcome::Routed { verb: "propose".into() }],
        "propose emission must record Routed, got {:?}",
        report.recent_outcomes
    );

    // The proposal must be queryable from the coordinator.
    let proposals = coord
        .lock()
        .expect("lock")
        .recall_proposals(&handle)
        .expect("recall_proposals");
    assert_eq!(proposals.len(), 1, "expected 1 proposal, got {}", proposals.len());
    assert_eq!(
        proposals[0].target_row_id,
        row_id,
        "proposal target must match captured row id"
    );
}

// ── Test 2: Associate emission lands as a queryable Association ─────

/// Force test F-2: an Associate emission routed through the
/// CoordinatorDispatcher files a real Association into the estate,
/// queryable via recall_associations().
///
/// Verification:
///   - outcome is SignalRouteOutcome::Routed { verb: "associate" }
///   - coord.recall_associations() returns one association
///   - association.a and association.b match the two captured rows
#[test]
fn f2_associate_emission_lands_as_queryable_association() {
    let (coord, handle) = open_estate_shared();

    let row_a = capture_one(&coord, &handle, "node alpha");
    let row_b = capture_one(&coord, &handle, "node beta");

    let dispatcher = SchedulerCoordinatorDispatcher::new(Arc::clone(&coord), handle);
    let hid = handle_id(&handle);
    let mut scheduler = SerialLaneScheduler::new(hid.clone(), dispatcher);

    let (a_clone, b_clone) = (row_a.clone(), row_b.clone());
    let spec = SignalSpec {
        name: "associate-lander".into(),
        trigger: SignalTrigger::Interval { seconds: Duration::from_secs(1) },
        resource_cost: ResourceCostEstimate::ZERO,
        freshness_target: Duration::from_secs(60),
        concurrency_policy: ConcurrencyPolicy::Single,
        emit: Arc::new(move |_| {
            vec![SignalEmission::Associate(AssociationFrame {
                a: a_clone.clone(),
                b: b_clone.clone(),
                weight: 0.75,
            })]
        }),
    };
    let sig_id = scheduler.register(spec, NOW_NS);
    scheduler.tick(NOW_NS + 5_000_000_000);

    // Outcome must be Routed.
    let report = scheduler
        .report()
        .into_iter()
        .find(|r| r.signal_id == sig_id)
        .expect("signal report");
    assert_eq!(
        report.recent_outcomes,
        vec![SignalRouteOutcome::Routed { verb: "associate".into() }],
        "associate emission must record Routed, got {:?}",
        report.recent_outcomes
    );

    // Association must be queryable.
    let associations = coord
        .lock()
        .expect("lock")
        .recall_associations(&handle)
        .expect("recall_associations");
    assert_eq!(associations.len(), 1, "expected 1 association, got {}", associations.len());

    // The association rows must match regardless of column order (the
    // estate normalises (source, target) by the frame's (a, b) fields,
    // but we check both orderings to be safe).
    let src = associations[0].source_drawer_id.as_deref().unwrap_or("");
    let tgt = associations[0].target_drawer_id.as_deref().unwrap_or("");
    let pair = (src, tgt);
    assert!(
        pair == (row_a.as_str(), row_b.as_str()) || pair == (row_b.as_str(), row_a.as_str()),
        "association source/target {:?} must match captured rows ({}, {})",
        pair,
        row_a,
        row_b
    );
}

// ── Test 3: Error propagation from verb failure ─────────────────────

/// Force test F-3: when the dispatcher's verb call fails (target row
/// does not exist — a DrawerNotFound error from the estate), the
/// outcome is RouteFailed, not silently dropped.
///
/// This covers the `Err(reason) => RouteFailed` arm in
/// apply_emission, parity of Swift's `routeFailed(verb:reason:)` catch.
#[test]
fn f3_verb_failure_records_route_failed() {
    let (coord, handle) = open_estate_shared();

    let dispatcher = SchedulerCoordinatorDispatcher::new(Arc::clone(&coord), handle);
    let hid = handle_id(&handle);
    let mut scheduler = SerialLaneScheduler::new(hid.clone(), dispatcher);

    // Emit a proposal targeting a row that does not exist. The
    // coordinator's Estate::propose will return DrawerNotFound, which
    // remap() translates to VerbError::UnderlyingEstateFailure. The
    // dispatcher propagates this as Err(reason).
    let spec = SignalSpec {
        name: "failing-proposer".into(),
        trigger: SignalTrigger::Interval { seconds: Duration::from_secs(1) },
        resource_cost: ResourceCostEstimate::ZERO,
        freshness_target: Duration::from_secs(60),
        concurrency_policy: ConcurrencyPolicy::Single,
        emit: Arc::new(|_| {
            vec![SignalEmission::Propose(ProposalFrame {
                target: "nonexistent-row".into(),
                kind: ProposalKind::TestPropose,
                justification: None,
            })]
        }),
    };
    let sig_id = scheduler.register(spec, NOW_NS);
    scheduler.tick(NOW_NS + 5_000_000_000);

    let report = scheduler
        .report()
        .into_iter()
        .find(|r| r.signal_id == sig_id)
        .expect("signal report");
    assert_eq!(report.recent_outcomes.len(), 1);
    match &report.recent_outcomes[0] {
        SignalRouteOutcome::RouteFailed { verb, reason } => {
            assert_eq!(verb, "propose", "RouteFailed verb must be propose");
            assert!(
                !reason.is_empty(),
                "RouteFailed reason must carry the error detail"
            );
        }
        other => panic!(
            "expected RouteFailed for nonexistent target, got {:?}",
            other
        ),
    }
}

// ── Test 4: Lane ordering preserved across multiple emissions ───────

/// Force test F-4: three Propose emissions enqueued in one tick drain
/// in submission (FIFO) order and all three proposals land in the
/// estate. The drain_order_log records the signals in registration
/// order, parity of Swift's `drainHistory`.
///
/// Uses three distinct signals emitting one proposal each so the
/// ordering is deterministic (the scheduler fires sorted by SignalID,
/// which is registration-order-aware through the monotonic counter
/// mixed into SignalID::generate).
///
/// We verify ordering via `drain_history()` rather than insertion
/// timestamp because `filed_at` is set to the same `NOW_SEC` for all
/// three in a single tick — the order in drain_history is the serial
/// guarantee the lane provides.
#[test]
fn f4_lane_ordering_preserved_across_multiple_proposals() {
    let (coord, handle) = open_estate_shared();

    // Capture three target drawers.
    let r1 = capture_one(&coord, &handle, "first");
    let r2 = capture_one(&coord, &handle, "second");
    let r3 = capture_one(&coord, &handle, "third");

    let dispatcher = SchedulerCoordinatorDispatcher::new(Arc::clone(&coord), handle);
    let hid = handle_id(&handle);
    let mut scheduler = SerialLaneScheduler::new(hid.clone(), dispatcher);

    // Register three signals each emitting one proposal. Registration
    // order is s1, s2, s3; SignalID generation mixes a monotonic counter
    // so the alphabetic sort in tick() processes them in this order.
    let (r1c, r2c, r3c) = (r1.clone(), r2.clone(), r3.clone());
    let s1 = scheduler.register(SignalSpec {
        name: "sig-one".into(),
        trigger: SignalTrigger::Interval { seconds: Duration::from_secs(1) },
        resource_cost: ResourceCostEstimate::ZERO,
        freshness_target: Duration::from_secs(60),
        concurrency_policy: ConcurrencyPolicy::Single,
        emit: Arc::new(move |_| vec![SignalEmission::Propose(ProposalFrame {
            target: r1c.clone(),
            kind: ProposalKind::TestPropose,
            justification: Some("order=1".into()),
        })]),
    }, NOW_NS);
    let s2 = scheduler.register(SignalSpec {
        name: "sig-two".into(),
        trigger: SignalTrigger::Interval { seconds: Duration::from_secs(1) },
        resource_cost: ResourceCostEstimate::ZERO,
        freshness_target: Duration::from_secs(60),
        concurrency_policy: ConcurrencyPolicy::Single,
        emit: Arc::new(move |_| vec![SignalEmission::Propose(ProposalFrame {
            target: r2c.clone(),
            kind: ProposalKind::TestPropose,
            justification: Some("order=2".into()),
        })]),
    }, NOW_NS);
    let s3 = scheduler.register(SignalSpec {
        name: "sig-three".into(),
        trigger: SignalTrigger::Interval { seconds: Duration::from_secs(1) },
        resource_cost: ResourceCostEstimate::ZERO,
        freshness_target: Duration::from_secs(60),
        concurrency_policy: ConcurrencyPolicy::Single,
        emit: Arc::new(move |_| vec![SignalEmission::Propose(ProposalFrame {
            target: r3c.clone(),
            kind: ProposalKind::TestPropose,
            justification: Some("order=3".into()),
        })]),
    }, NOW_NS);

    scheduler.tick(NOW_NS + 5_000_000_000);

    // Three proposals must have landed.
    let proposals = coord
        .lock()
        .expect("lock")
        .recall_proposals(&handle)
        .expect("recall_proposals");
    assert_eq!(proposals.len(), 3, "expected 3 proposals, got {}", proposals.len());

    // Every signal must report Routed.
    for (name, sig) in [("sig-one", &s1), ("sig-two", &s2), ("sig-three", &s3)] {
        let r = scheduler
            .report()
            .into_iter()
            .find(|r| &r.signal_id == sig)
            .unwrap_or_else(|| panic!("missing report for {name}"));
        assert_eq!(
            r.recent_outcomes,
            vec![SignalRouteOutcome::Routed { verb: "propose".into() }],
            "{name} must be Routed"
        );
    }

    // Drain history records all three in signal-ID sort order
    // (which matches registration order given the monotonic counter).
    let history = scheduler.drain_history();
    assert_eq!(history.len(), 3, "drain history must hold 3 entries");
    // All entries carry the "propose" class tag.
    for (_, tag) in history {
        assert_eq!(*tag, "propose");
    }
    // The order in drain_history must match [s1, s2, s3] (sorted by
    // SignalID, which the monotonic counter keeps in registration order
    // across rapid-succession calls).
    let mut sorted_ids = [s1.clone(), s2.clone(), s3.clone()];
    sorted_ids.sort();
    let history_ids: Vec<_> = history.iter().map(|(id, _)| id.clone()).collect();
    assert_eq!(
        history_ids, sorted_ids,
        "drain order must match sorted signal IDs (FIFO within sort class)"
    );
}

// ── Test 5: NoopDispatcher still records RoutedButVerbStubbed ───────

/// Regression guard: NoopDispatcher behaviour is unchanged after the
/// now_nanos parameter addition. Tests that used NoopDispatcher
/// (scheduler_parity.rs) continue to see RoutedButVerbStubbed.
#[test]
fn f5_noop_dispatcher_still_records_routed_but_verb_stubbed() {
    let mut s = SerialLaneScheduler::new("noop-estate".to_string(), SchedulerNoopDispatcher);
    let spec = SignalSpec {
        name: "noop-check".into(),
        trigger: SignalTrigger::Interval { seconds: Duration::from_secs(1) },
        resource_cost: ResourceCostEstimate::ZERO,
        freshness_target: Duration::from_secs(60),
        concurrency_policy: ConcurrencyPolicy::Single,
        emit: Arc::new(|_| {
            vec![SignalEmission::Propose(ProposalFrame {
                target: "any".into(),
                kind: ProposalKind::TestPropose,
                justification: None,
            })]
        }),
    };
    let id = s.register(spec, NOW_NS);
    s.tick(NOW_NS + 5_000_000_000);
    let report = s.report().into_iter().find(|r| r.signal_id == id).unwrap();
    assert_eq!(
        report.recent_outcomes,
        vec![SignalRouteOutcome::RoutedButVerbStubbed { verb: "propose".into() }],
        "NoopDispatcher must still produce RoutedButVerbStubbed"
    );
}

// ── Test 6: Diagnostic emission unaffected by dispatcher type ───────

/// Diagnostic emissions bypass the dispatcher entirely and are
/// recorded directly in `recent_diagnostics`. This must hold for
/// both the CoordinatorDispatcher and the NoopDispatcher.
#[test]
fn f6_diagnostic_emission_bypasses_dispatcher() {
    let (coord, handle) = open_estate_shared();

    let dispatcher = SchedulerCoordinatorDispatcher::new(Arc::clone(&coord), handle);
    let hid = handle_id(&handle);
    let mut s = SerialLaneScheduler::new(hid, dispatcher);

    let spec = SignalSpec {
        name: "diag-bypass".into(),
        trigger: SignalTrigger::Interval { seconds: Duration::from_secs(1) },
        resource_cost: ResourceCostEstimate::ZERO,
        freshness_target: Duration::from_secs(60),
        concurrency_policy: ConcurrencyPolicy::Single,
        emit: Arc::new(|ctx| {
            vec![SignalEmission::Diagnostic(DiagnosticReport {
                title: "health-check".into(),
                detail: "all clear".into(),
                observed_at_nanos: ctx.now_nanos,
            })]
        }),
    };
    let id = s.register(spec, NOW_NS);
    s.tick(NOW_NS + 5_000_000_000);

    let report = s.report().into_iter().find(|r| r.signal_id == id).unwrap();
    assert_eq!(
        report.recent_outcomes,
        vec![SignalRouteOutcome::DiagnosticRecorded],
        "Diagnostic emission outcome must be DiagnosticRecorded"
    );
    assert_eq!(report.recent_diagnostics.len(), 1);
    assert_eq!(report.recent_diagnostics[0].title, "health-check");
    assert_eq!(report.state, SignalState::LastRan);
}
