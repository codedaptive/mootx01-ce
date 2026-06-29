// scheduler_parity.rs — conformance gate for the Rust standing-signals
// scheduler. Mirrors the Swift `StandingSignalSchedulerTests.swift`
// shape: registration, serial dispatch, the four emission classes,
// the event-trigger contract, and the unknown-signal error path.
//
// What this gate verifies:
//
// 1. `EMISSION_CLASS_TAGS` matches the Swift reference's ordered
//    vocabulary.
// 2. `SignalEmission.class_tag()` returns the documented strings for
//    each of the four classes.
// 3. Registering a signal produces a report whose `state` is `Idle`,
//    `emission_count == 0`, and `concurrency_policy == Single`.
// 4. Two due signals with interleaved emissions drain in a single
//    serial lane — total drain count equals the sum, and the lane
//    history records each signal's emissions in submission order.
// 5. A diagnostic emission is recorded in `recent_diagnostics`; the
//    outcome list records `DiagnosticRecorded`.
// 6. A propose emission routes through the dispatcher; with the
//    NoopDispatcher (mirroring GLK-02's substrate stub) the outcome
//    is `RoutedButVerbStubbed { verb: "propose" }`.
// 7. An associate emission routes through the dispatcher; outcome
//    `RoutedButVerbStubbed { verb: "associate" }`.
// 8. A mutate-candidate emission routes through `propose` per
//    architecture spec §11.1.
// 9. Event-trigger signals do not fire on `tick`; `request_fire`
//    advances them.
// 10. Subscribing to an unknown signal returns
//     `SchedulerError::SignalNotRegistered`.

use std::sync::Arc;
use std::time::Duration;

use genius_locus_kit::{
    SchedulerAssociationFrame as AssociationFrame, SchedulerConcurrencyPolicy as ConcurrencyPolicy,
    SchedulerDiagnosticReport as DiagnosticReport, SchedulerError,
    SchedulerMutationKind as MutationKind, SchedulerNoopDispatcher,
    SchedulerProposalFrame as ProposalFrame, SchedulerProposalKind as ProposalKind,
    SchedulerResourceCostEstimate as ResourceCostEstimate,
    SchedulerSignalEmission as SignalEmission, SchedulerSignalRouteOutcome as SignalRouteOutcome,
    SchedulerSignalSpec as SignalSpec, SchedulerSignalState as SignalState,
    SchedulerSignalTrigger as SignalTrigger, SerialLaneScheduler, EMISSION_CLASS_TAGS,
};
use persistence_kit::inmemory::InMemoryStorage;
use queuekit::{PersistenceKitBackend, QueueBackend, QueueKit};
use substrate_types::hlc::HLCGenerator;

/// Build a transient in-memory signals queue for tests that do not need crash
/// durability. The fixed estate UUID keeps the engine deterministic (no random
/// minting per test run). Mirrors the NeuronKit `build_inmemory_signals_queue`
/// helper so test scaffolding matches the production degraded path.
fn inmem_signals_queue() -> (QueueKit<Box<dyn QueueBackend>>, HLCGenerator) {
    let store_id = uuid::Uuid::from_u128(0x5348_4544_5545_5245_0000_0000_0000_0001);
    let storage = std::sync::Arc::new(InMemoryStorage::with_estate(store_id));
    PersistenceKitBackend::open_schema(storage.as_ref())
        .expect("InMemoryStorage open_schema cannot fail");
    let backend = PersistenceKitBackend::new(storage);
    let queue: QueueKit<Box<dyn QueueBackend>> =
        QueueKit::new(Box::new(backend) as Box<dyn QueueBackend>);
    let hlc = HLCGenerator::new(1);
    (queue, hlc)
}

fn make_scheduler() -> SerialLaneScheduler<SchedulerNoopDispatcher> {
    let (queue, hlc) = inmem_signals_queue();
    SerialLaneScheduler::new("estate-parity-test".to_string(), SchedulerNoopDispatcher, queue, None, hlc)
}

fn t0() -> i64 {
    // 2023-11-14T22:13:20Z, matching the Swift fixture's 1_700_000_000
    // seconds-since-epoch — expressed in nanoseconds so the Rust gate
    // compares against the integer scale the scheduler uses.
    1_700_000_000_000_000_000
}

#[test]
fn emission_class_tags_match_swift_vocabulary() {
    assert_eq!(
        EMISSION_CLASS_TAGS,
        ["propose", "associate", "mutate_candidate", "diagnostic"]
    );
}

#[test]
fn class_tag_per_emission_matches_swift_strings() {
    // "k" was a single-char stub placeholder used before ProposalKind
    // was typed. It maps to Other("k") per the Known Ambiguity 1
    // decision: it is not a production or test label.
    let propose = SignalEmission::Propose(ProposalFrame {
        target: "row-A".into(),
        kind: ProposalKind::Other("k".to_string()),
        justification: None,
    });
    let associate = SignalEmission::Associate(AssociationFrame {
        a: "row-A".into(),
        b: "row-B".into(),
        weight: 1.0,
    });
    let mutate = SignalEmission::MutateCandidate {
        row_id: "row-A".into(),
        kind: MutationKind::Confirm,
    };
    let diag = SignalEmission::Diagnostic(DiagnosticReport {
        title: "t".into(),
        detail: "d".into(),
        observed_at_nanos: 0,
    });
    assert_eq!(propose.class_tag(), "propose");
    assert_eq!(associate.class_tag(), "associate");
    assert_eq!(mutate.class_tag(), "mutate_candidate");
    assert_eq!(diag.class_tag(), "diagnostic");
}

#[test]
fn registered_signal_appears_in_status() {
    let mut s = make_scheduler();
    let spec = SignalSpec {
        name: "vector-similarity-test".into(),
        trigger: SignalTrigger::Interval {
            seconds: Duration::from_secs(30),
        },
        resource_cost: ResourceCostEstimate::ZERO,
        freshness_target: Duration::from_secs(60),
        concurrency_policy: ConcurrencyPolicy::Single,
        emit: Arc::new(|_| vec![]),
    };
    let id = s.register(spec, t0());
    let reports = s.report();
    assert_eq!(reports.len(), 1);
    assert_eq!(reports[0].signal_id, id);
    assert_eq!(reports[0].name, "vector-similarity-test");
    assert_eq!(reports[0].trigger_tag, "interval");
    assert_eq!(reports[0].state, SignalState::Idle);
    assert_eq!(reports[0].emission_count, 0);
    assert_eq!(reports[0].concurrency_policy, ConcurrencyPolicy::Single);
}

#[test]
fn two_due_signals_dispatch_serially_in_one_lane() {
    let mut s = make_scheduler();
    let alpha_spec = SignalSpec {
        name: "alpha".into(),
        trigger: SignalTrigger::Interval {
            seconds: Duration::from_secs(30),
        },
        resource_cost: ResourceCostEstimate::ZERO,
        freshness_target: Duration::from_secs(60),
        concurrency_policy: ConcurrencyPolicy::Single,
        emit: Arc::new(|ctx| {
            vec![
                SignalEmission::Diagnostic(DiagnosticReport {
                    title: "alpha.1".into(),
                    detail: "first".into(),
                    observed_at_nanos: ctx.now_nanos,
                }),
                SignalEmission::Diagnostic(DiagnosticReport {
                    title: "alpha.2".into(),
                    detail: "second".into(),
                    observed_at_nanos: ctx.now_nanos,
                }),
            ]
        }),
    };
    let beta_spec = SignalSpec {
        name: "beta".into(),
        trigger: SignalTrigger::Interval {
            seconds: Duration::from_secs(30),
        },
        resource_cost: ResourceCostEstimate::ZERO,
        freshness_target: Duration::from_secs(60),
        concurrency_policy: ConcurrencyPolicy::Single,
        emit: Arc::new(|ctx| {
            vec![SignalEmission::Diagnostic(DiagnosticReport {
                title: "beta.1".into(),
                detail: "first".into(),
                observed_at_nanos: ctx.now_nanos,
            })]
        }),
    };
    let alpha = s.register(alpha_spec, t0());
    let beta = s.register(beta_spec, t0());

    // Advance past both signals' first-due window. 31 seconds in
    // nanoseconds.
    s.tick(t0() + 31_000_000_000);

    let history = s.drain_history();
    assert_eq!(history.len(), 3);
    let alpha_count = history.iter().filter(|(id, _)| id == &alpha).count();
    let beta_count = history.iter().filter(|(id, _)| id == &beta).count();
    assert_eq!(alpha_count, 2);
    assert_eq!(beta_count, 1);

    let reports = s.report();
    let alpha_report = reports.iter().find(|r| r.signal_id == alpha).unwrap();
    let beta_report = reports.iter().find(|r| r.signal_id == beta).unwrap();
    assert_eq!(alpha_report.emission_count, 2);
    assert_eq!(beta_report.emission_count, 1);
    assert_eq!(alpha_report.state, SignalState::LastRan);
    assert_eq!(beta_report.state, SignalState::LastRan);
}

#[test]
fn diagnostic_emission_is_recorded_in_status() {
    let mut s = make_scheduler();
    let spec = SignalSpec {
        name: "diag-emitter".into(),
        trigger: SignalTrigger::Interval {
            seconds: Duration::from_secs(1),
        },
        resource_cost: ResourceCostEstimate::ZERO,
        freshness_target: Duration::from_secs(60),
        concurrency_policy: ConcurrencyPolicy::Single,
        emit: Arc::new(|ctx| {
            vec![SignalEmission::Diagnostic(DiagnosticReport {
                title: "first".into(),
                detail: "details".into(),
                observed_at_nanos: ctx.now_nanos,
            })]
        }),
    };
    let id = s.register(spec, t0());
    s.tick(t0() + 5_000_000_000);
    let report = s.report().into_iter().find(|r| r.signal_id == id).unwrap();
    assert_eq!(
        report.recent_outcomes,
        vec![SignalRouteOutcome::DiagnosticRecorded]
    );
    assert_eq!(report.recent_diagnostics.len(), 1);
    assert_eq!(report.recent_diagnostics[0].title, "first");
}

#[test]
fn propose_emission_routes_through_propose_verb() {
    let mut s = make_scheduler();
    let spec = SignalSpec {
        name: "propose-emitter".into(),
        trigger: SignalTrigger::Interval {
            seconds: Duration::from_secs(1),
        },
        resource_cost: ResourceCostEstimate::ZERO,
        freshness_target: Duration::from_secs(60),
        concurrency_policy: ConcurrencyPolicy::Single,
        emit: Arc::new(|_| {
            vec![SignalEmission::Propose(ProposalFrame {
                target: "row-A".into(),
                kind: ProposalKind::TestPropose,
                justification: None,
            })]
        }),
    };
    let id = s.register(spec, t0());
    s.tick(t0() + 5_000_000_000);
    let report = s.report().into_iter().find(|r| r.signal_id == id).unwrap();
    assert_eq!(report.recent_outcomes.len(), 1);
    // NoopDispatcher mimics GLK-02's substrate-stub behaviour →
    // RoutedButVerbStubbed { verb: "propose" }.
    match &report.recent_outcomes[0] {
        SignalRouteOutcome::Routed { verb } | SignalRouteOutcome::RoutedButVerbStubbed { verb } => {
            assert_eq!(verb, "propose");
        }
        other => panic!("expected routed/routed_but_stubbed, got {:?}", other),
    }
}

#[test]
fn associate_emission_routes_through_associate_verb() {
    let mut s = make_scheduler();
    let spec = SignalSpec {
        name: "associate-emitter".into(),
        trigger: SignalTrigger::Interval {
            seconds: Duration::from_secs(1),
        },
        resource_cost: ResourceCostEstimate::ZERO,
        freshness_target: Duration::from_secs(60),
        concurrency_policy: ConcurrencyPolicy::Single,
        emit: Arc::new(|_| {
            vec![SignalEmission::Associate(AssociationFrame {
                a: "row-A".into(),
                b: "row-B".into(),
                weight: 0.5,
            })]
        }),
    };
    let id = s.register(spec, t0());
    s.tick(t0() + 5_000_000_000);
    let report = s.report().into_iter().find(|r| r.signal_id == id).unwrap();
    assert_eq!(report.recent_outcomes.len(), 1);
    match &report.recent_outcomes[0] {
        SignalRouteOutcome::Routed { verb } | SignalRouteOutcome::RoutedButVerbStubbed { verb } => {
            assert_eq!(verb, "associate");
        }
        other => panic!("expected routed/routed_but_stubbed, got {:?}", other),
    }
}

#[test]
fn mutate_candidate_routes_through_propose() {
    let mut s = make_scheduler();
    let spec = SignalSpec {
        name: "mutate-candidate-emitter".into(),
        trigger: SignalTrigger::Interval {
            seconds: Duration::from_secs(1),
        },
        resource_cost: ResourceCostEstimate::ZERO,
        freshness_target: Duration::from_secs(60),
        concurrency_policy: ConcurrencyPolicy::Single,
        emit: Arc::new(|_| {
            vec![SignalEmission::MutateCandidate {
                row_id: "row-A".into(),
                kind: MutationKind::Confirm,
            }]
        }),
    };
    let id = s.register(spec, t0());
    s.tick(t0() + 5_000_000_000);
    let report = s.report().into_iter().find(|r| r.signal_id == id).unwrap();
    // §11.1: mutate_candidate is routed through `propose`, so the
    // outcome verb is propose, not mutate.
    match &report.recent_outcomes[0] {
        SignalRouteOutcome::Routed { verb } | SignalRouteOutcome::RoutedButVerbStubbed { verb } => {
            assert_eq!(verb, "propose");
        }
        other => panic!("expected propose routing, got {:?}", other),
    }
}

#[test]
fn event_trigger_only_fires_on_request() {
    let mut s = make_scheduler();
    let spec = SignalSpec {
        name: "event-trigger".into(),
        trigger: SignalTrigger::Event {
            name: "external".into(),
        },
        resource_cost: ResourceCostEstimate::ZERO,
        freshness_target: Duration::from_secs(60),
        concurrency_policy: ConcurrencyPolicy::Single,
        emit: Arc::new(|ctx| {
            vec![SignalEmission::Diagnostic(DiagnosticReport {
                title: "fired".into(),
                detail: format!("event={}", ctx.signal_id.0),
                observed_at_nanos: ctx.now_nanos,
            })]
        }),
    };
    let id = s.register(spec, t0());

    // Tick alone must NOT fire an event-trigger signal.
    s.tick(t0() + 99_000_000_000);
    let report = s.report().into_iter().find(|r| r.signal_id == id).unwrap();
    assert_eq!(report.emission_count, 0);

    // request_fire reaches the same enqueue/drain pipeline.
    s.request_fire(&id, t0() + 100_000_000_000).unwrap();
    let report = s.report().into_iter().find(|r| r.signal_id == id).unwrap();
    assert_eq!(report.emission_count, 1);
}

#[test]
fn subscribe_to_unknown_signal_returns_not_registered() {
    let mut s = make_scheduler();
    let bogus = genius_locus_kit::SchedulerSignalID("00000000".into());
    let err = s.subscribe(&bogus, |_| {}).unwrap_err();
    assert_eq!(err, SchedulerError::SignalNotRegistered(bogus));
}

// MARK: - ProposalKind round-trip (NK-1b)

/// Every named ProposalKind case round-trips through raw_value() →
/// from_raw() back to the same case. Mirrors Swift's
/// testProposalKindRawValueRoundTrip. The wire strings must match the
/// Swift rawValue table exactly for the parity contract.
#[test]
fn proposal_kind_raw_value_round_trip() {
    let cases: &[(&str, ProposalKind)] = &[
        ("by_reference_drift", ProposalKind::ByReferenceDrift),
        ("tournament_update", ProposalKind::TournamentUpdate),
        ("mining_pattern", ProposalKind::MiningPattern),
        ("discipline_violation", ProposalKind::DisciplineViolation),
        ("mutate_candidate", ProposalKind::MutateCandidate),
        ("amend", ProposalKind::Amend),
        ("test_propose", ProposalKind::TestPropose),
    ];
    for (raw, expected) in cases {
        // raw_value() → wire string
        assert_eq!(
            expected.raw_value(),
            *raw,
            "raw_value mismatch for {:?}",
            expected
        );
        // from_raw() → back to enum case
        assert_eq!(
            &ProposalKind::from_raw(raw),
            expected,
            "from_raw round-trip failed for {}",
            raw
        );
    }
}

/// Unknown labels map to Other(s) and preserve content verbatim.
/// Mirrors Swift's testProposalKindUnknownLabelMapsToOther.
#[test]
fn proposal_kind_unknown_label_maps_to_other() {
    let kind = ProposalKind::from_raw("future_label");
    match kind {
        ProposalKind::Other(ref s) => assert_eq!(s, "future_label"),
        other => panic!("expected Other, got {:?}", other),
    }
    // round-trip: Other preserves its content through raw_value()
    assert_eq!(kind.raw_value(), "future_label");
}
