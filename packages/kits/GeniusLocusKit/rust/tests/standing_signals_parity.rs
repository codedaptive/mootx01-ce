// standing_signals_parity.rs — conformance gate for the Rust mirror
// of the six v1 standing signals (GLK-05).
//
// Mirrors `StandingSignalsTests.swift`. The gate asserts:
//
// 1. Each signal's stable name and cadence match the Swift reference.
// 2. Each signal's default spec produces the expected emission
//    classes when fired through a `SerialLaneScheduler` instance.
// 3. The default-set helper registers all six in the canonical order.

use genius_locus_kit::{
    default_standing_signal_names, default_standing_signal_specs, ByReferenceValiditySignal,
    DecaySweepSignal, DreamingSignal, EndOfDayTournamentSignal, MaintenanceSignal,
    SchedulerNoopDispatcher, SchedulerSignalRouteOutcome as SignalRouteOutcome,
    SchedulerSignalTrigger as SignalTrigger, SerialLaneScheduler, VectorSimilaritySignal,
};

const T0_NANOS: i64 = 1_700_000_000_000_000_000;
const NANOS_PER_SEC: i64 = 1_000_000_000;

fn make_scheduler() -> SerialLaneScheduler<SchedulerNoopDispatcher> {
    SerialLaneScheduler::new("estate-signals-parity".to_string(), SchedulerNoopDispatcher)
}

/// Tick a hair past `cadence + t0` so the interval trigger is
/// unambiguously due. Mirrors Swift's `firstFireTime(after:)`.
fn first_fire_nanos(cadence_seconds: u64) -> i64 {
    T0_NANOS + (cadence_seconds as i64 + 1) * NANOS_PER_SEC
}

#[test]
fn default_signal_names_and_cadences_match_swift_reference() {
    assert_eq!(DreamingSignal::SIGNAL_NAME, "dreaming-daemon");
    assert_eq!(DreamingSignal::DEFAULT_CADENCE_SECONDS, 604_800);

    assert_eq!(MaintenanceSignal::SIGNAL_NAME, "maintenance-daemon");
    assert_eq!(MaintenanceSignal::DEFAULT_CADENCE_SECONDS, 3_600);

    assert_eq!(VectorSimilaritySignal::SIGNAL_NAME, "vector-similarity");
    assert_eq!(VectorSimilaritySignal::DEFAULT_CADENCE_SECONDS, 300);

    assert_eq!(DecaySweepSignal::SIGNAL_NAME, "decay-sweep");
    assert_eq!(DecaySweepSignal::DEFAULT_CADENCE_SECONDS, 86_400);

    assert_eq!(
        ByReferenceValiditySignal::SIGNAL_NAME,
        "by-reference-validity"
    );
    assert_eq!(ByReferenceValiditySignal::DEFAULT_CADENCE_SECONDS, 604_800);

    assert_eq!(
        EndOfDayTournamentSignal::SIGNAL_NAME,
        "end-of-day-tournament"
    );
    assert_eq!(EndOfDayTournamentSignal::DEFAULT_CADENCE_SECONDS, 86_400);
}

#[test]
fn default_standing_signal_names_helper_returns_canonical_order() {
    let names = default_standing_signal_names();
    assert_eq!(
        names,
        [
            "dreaming-daemon",
            "maintenance-daemon",
            "vector-similarity",
            "decay-sweep",
            "by-reference-validity",
            "end-of-day-tournament",
        ]
    );
}

#[test]
fn default_standing_signal_specs_returns_six_specs_with_interval_triggers() {
    let specs = default_standing_signal_specs();
    assert_eq!(specs.len(), 6);
    for spec in &specs {
        match spec.trigger {
            SignalTrigger::Interval { .. } => {}
            _ => panic!("every v1 signal is interval-driven; got {:?}", spec),
        }
    }
}

/// Register one signal, tick past its cadence, and return its
/// resulting `SignalReport`. Mirrors the `registerAndFire` helper in
/// `StandingSignalsTests.swift`.
fn fire(spec: genius_locus_kit::SchedulerSignalSpec) -> genius_locus_kit::SchedulerSignalReport {
    let cadence = match &spec.trigger {
        SignalTrigger::Interval { seconds } => seconds.as_secs(),
        _ => panic!("default specs are interval-driven"),
    };
    let mut scheduler = make_scheduler();
    let id = scheduler.register(spec, T0_NANOS);
    scheduler.tick(first_fire_nanos(cadence));
    scheduler
        .report()
        .into_iter()
        .find(|r| r.signal_id == id)
        .expect("registered signal appears in the report")
}

#[test]
fn dreaming_signal_emits_propose_and_associate() {
    let report = fire(DreamingSignal::default_spec());
    assert_eq!(report.name, "dreaming-daemon");
    assert_eq!(report.emission_count, 2);
    let verbs: Vec<&str> = report
        .recent_outcomes
        .iter()
        .filter_map(|o| match o {
            SignalRouteOutcome::Routed { verb }
            | SignalRouteOutcome::RoutedButVerbStubbed { verb } => Some(verb.as_str()),
            _ => None,
        })
        .collect();
    let mut sorted = verbs.clone();
    sorted.sort();
    assert_eq!(sorted, vec!["associate", "propose"]);
}

#[test]
fn maintenance_signal_emits_two_proposes_and_one_diagnostic() {
    let report = fire(MaintenanceSignal::default_spec());
    assert_eq!(report.name, "maintenance-daemon");
    assert_eq!(report.emission_count, 3);
    let propose_count = report
        .recent_outcomes
        .iter()
        .filter(|o| {
            matches!(
                o,
                SignalRouteOutcome::Routed { verb } | SignalRouteOutcome::RoutedButVerbStubbed { verb }
                if verb == "propose"
            )
        })
        .count();
    assert_eq!(propose_count, 2);
    assert_eq!(report.recent_diagnostics.len(), 1);
    assert_eq!(
        report.recent_diagnostics[0].title,
        "maintenance.scan.summary"
    );
}

#[test]
fn vector_similarity_signal_emits_associate_and_diagnostic() {
    let report = fire(VectorSimilaritySignal::default_spec());
    assert_eq!(report.name, "vector-similarity");
    assert_eq!(report.emission_count, 2);
    let associate_count = report
        .recent_outcomes
        .iter()
        .filter(|o| {
            matches!(
                o,
                SignalRouteOutcome::Routed { verb } | SignalRouteOutcome::RoutedButVerbStubbed { verb }
                if verb == "associate"
            )
        })
        .count();
    assert_eq!(associate_count, 1);
    assert_eq!(report.recent_diagnostics.len(), 1);
}

#[test]
fn decay_sweep_signal_routes_through_propose() {
    let report = fire(DecaySweepSignal::default_spec());
    assert_eq!(report.name, "decay-sweep");
    assert_eq!(report.emission_count, 2);
    let propose_count = report
        .recent_outcomes
        .iter()
        .filter(|o| {
            matches!(
                o,
                SignalRouteOutcome::Routed { verb } | SignalRouteOutcome::RoutedButVerbStubbed { verb }
                if verb == "propose"
            )
        })
        .count();
    assert_eq!(propose_count, 1);
    assert_eq!(report.recent_diagnostics.len(), 1);
}

#[test]
fn by_reference_validity_signal_emits_propose_and_diagnostic() {
    let report = fire(ByReferenceValiditySignal::default_spec());
    assert_eq!(report.name, "by-reference-validity");
    assert_eq!(report.emission_count, 2);
    let propose_count = report
        .recent_outcomes
        .iter()
        .filter(|o| {
            matches!(
                o,
                SignalRouteOutcome::Routed { verb } | SignalRouteOutcome::RoutedButVerbStubbed { verb }
                if verb == "propose"
            )
        })
        .count();
    assert_eq!(propose_count, 1);
    assert_eq!(
        report.recent_diagnostics[0].title,
        "by_reference.validation.summary"
    );
}

#[test]
fn end_of_day_tournament_signal_emits_propose_and_diagnostic() {
    let report = fire(EndOfDayTournamentSignal::default_spec());
    assert_eq!(report.name, "end-of-day-tournament");
    assert_eq!(report.emission_count, 2);
    let propose_count = report
        .recent_outcomes
        .iter()
        .filter(|o| {
            matches!(
                o,
                SignalRouteOutcome::Routed { verb } | SignalRouteOutcome::RoutedButVerbStubbed { verb }
                if verb == "propose"
            )
        })
        .count();
    assert_eq!(propose_count, 1);
    assert_eq!(
        report.recent_diagnostics[0].title,
        "tournament.end_of_day.summary"
    );
}

#[test]
fn registering_all_six_default_specs_produces_six_reports() {
    let mut scheduler = make_scheduler();
    for spec in default_standing_signal_specs() {
        scheduler.register(spec, T0_NANOS);
    }
    let reports = scheduler.report();
    assert_eq!(reports.len(), 6);
    let mut names: Vec<String> = reports.iter().map(|r| r.name.clone()).collect();
    names.sort();
    let mut expected: Vec<String> = default_standing_signal_names()
        .iter()
        .map(|s| s.to_string())
        .collect();
    expected.sort();
    assert_eq!(names, expected);
    for r in &reports {
        assert_eq!(r.trigger_tag, "interval");
        assert_eq!(r.emission_count, 0);
    }
}
