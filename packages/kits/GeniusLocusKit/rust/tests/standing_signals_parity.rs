// standing_signals_parity.rs — conformance gate for the Rust mirror
// of the nine v1 standing signals (GLK-05 + ADR-018 F1).
//
// Mirrors `StandingSignalsTests.swift`. The gate asserts:
//
// 1. Each signal's stable name and cadence match the Swift reference.
// 2. Each signal's spec produces the expected emission classes when
//    fired through a `SerialLaneScheduler` instance.
// 3. The default-set helper registers all nine in the canonical order.
// 4. VectorSimilaritySignal with an empty VectorStore emits only the
//    scan-summary diagnostic (zero associate emissions) — parity with
//    the Swift empty-store test.
// 5. TrainingSignal fires TrainingDaemon::run_once and emits exactly
//    one diagnostic per tick regardless of gate state (ADR-018 F1).

use std::sync::Arc;

use genius_locus_kit::{
    default_standing_signal_names, default_standing_signal_specs, ByReferenceValiditySignal,
    DecaySweepSignal, DistillationSignal, DreamingSignal, EndOfDayTournamentSignal,
    MaintenanceSignal, SchedulerNoopDispatcher, SchedulerSignalRouteOutcome as SignalRouteOutcome,
    SchedulerSignalTrigger as SignalTrigger, SerialLaneScheduler, TemporalCausalitySignal,
    TrainingSignal, VectorSimilaritySignal,
};
use persistence_kit::inmemory::InMemoryStorage;
use queuekit::{PersistenceKitBackend, QueueBackend, QueueKit};
use substrate_types::hlc::HLCGenerator;
use vectorkit::VectorStore;

const T0_NANOS: i64 = 1_700_000_000_000_000_000;
const NANOS_PER_SEC: i64 = 1_000_000_000;

/// Build a transient in-memory signals queue for tests. See scheduler_parity.rs
/// for the rationale. Fixed store UUID for determinism.
fn inmem_signals_queue() -> (QueueKit<Box<dyn QueueBackend>>, HLCGenerator) {
    let store_id = uuid::Uuid::from_u128(0x5348_4544_5545_5245_0000_0000_0000_0002);
    let storage = std::sync::Arc::new(InMemoryStorage::with_estate(store_id));
    PersistenceKitBackend::open_schema(storage.as_ref())
        .expect("InMemoryStorage open_schema cannot fail");
    let backend = PersistenceKitBackend::new(storage);
    let queue: QueueKit<Box<dyn QueueBackend>> =
        QueueKit::new(Box::new(backend) as Box<dyn QueueBackend>);
    (queue, HLCGenerator::new(1))
}

fn make_scheduler() -> SerialLaneScheduler<SchedulerNoopDispatcher> {
    let (queue, hlc) = inmem_signals_queue();
    SerialLaneScheduler::new(
        "estate-signals-parity".to_string(),
        SchedulerNoopDispatcher,
        queue,
        None,
        hlc,
    )
}

/// Open a fresh in-memory VectorStore for tests that need a VectorStore
/// but do not require pre-populated vectors. Uses VectorStore::open to
/// apply the vectors schema, consistent with rag_wiring_parity.rs.
/// Mirrors Swift's `makeEmptyVectorStore()`.
fn make_empty_vector_store() -> Arc<VectorStore> {
    let storage = Arc::new(InMemoryStorage::with_estate(uuid::Uuid::new_v4()));
    Arc::new(VectorStore::open(storage).expect("VectorStore::open"))
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

    // Signal 7 — added 2026-06-20 per ADR-018 F1 (mirrors DECISION_MATRIXT_HOURLY_CADENCE_2026-06-04).
    assert_eq!(
        TemporalCausalitySignal::SIGNAL_NAME,
        "temporal-causality-fold"
    );
    assert_eq!(TemporalCausalitySignal::DEFAULT_CADENCE_SECONDS, 3_600,
        "temporal-causality-fold runs hourly per design-council 2026-06-04 decision");

    // Signal 8 — added 2026-06-20 per ADR-018 F1.
    assert_eq!(DistillationSignal::SIGNAL_NAME, "distillation-sweep");
    assert_eq!(DistillationSignal::DEFAULT_CADENCE_SECONDS, 3_600,
        "distillation sweep runs hourly per architecture spec §11.2");

    // Signal 9 — wired per ADR-018 F1 (training daemon was an orphan before).
    assert_eq!(TrainingSignal::SIGNAL_NAME, "training-daemon");
    assert_eq!(TrainingSignal::DEFAULT_CADENCE_SECONDS, 3_600,
        "training-daemon runs hourly matching distillation and temporal-causality rhythm");
}

#[test]
fn default_standing_signal_names_helper_returns_canonical_order() {
    // ADR-018 F1 added signals 7–9: TemporalCausalitySignal, DistillationSignal,
    // TrainingSignal. Any future addition must update this assertion and
    // extend default_standing_signal_names() in default_set.rs.
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
            "temporal-causality-fold",
            "distillation-sweep",
            "training-daemon",
        ]
    );
}

#[test]
fn default_standing_signal_specs_returns_nine_specs_with_interval_triggers() {
    let store = make_empty_vector_store();
    let specs = default_standing_signal_specs(store, "test-model", None);
    // ADR-018 F1 added signals 7–9; any future addition must update this count.
    assert_eq!(specs.len(), 9);
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

// Parity with Swift's dreamingSignalEmitsRealProposalsFromDaemonCycle:
// a synthetic daemon cycle returning one non-sentinel proposal.
#[test]
fn dreaming_signal_emits_real_proposals_from_daemon_cycle() {
    use genius_locus_kit::SchedulerProposalKind;
    let spec = DreamingSignal::spec(Arc::new(|| {
        vec![genius_locus_kit::SchedulerProposalFrame {
            target: "row-dreaming-test-a".to_string(),
            kind: SchedulerProposalKind::MiningPattern,
            justification: Some("synthetic daemon cycle for test".to_string()),
        }]
    }));
    let report = fire(spec);
    assert_eq!(report.name, "dreaming-daemon");
    // One real proposal; no sentinel associate emission.
    assert_eq!(report.emission_count, 1);
    let verbs: Vec<&str> = report
        .recent_outcomes
        .iter()
        .filter_map(|o| match o {
            SignalRouteOutcome::Routed { verb }
            | SignalRouteOutcome::RoutedButVerbStubbed { verb } => Some(verb.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(verbs, vec!["propose"]);
}

// Parity with Swift's dreamingSignalEmitsZeroProposalsForEmptyEstate:
// empty daemon cycle returns zero emissions.
#[test]
fn dreaming_signal_emits_zero_proposals_for_empty_estate() {
    let spec = DreamingSignal::spec(Arc::new(|| vec![]));
    let report = fire(spec);
    assert_eq!(report.name, "dreaming-daemon");
    assert_eq!(report.emission_count, 0);
    assert!(report.recent_outcomes.is_empty());
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
fn vector_similarity_signal_emits_only_diagnostic_when_store_is_empty() {
    // Empty VectorStore: zero pairs found → only the scan-summary
    // diagnostic. Mirrors Swift's
    // vectorSimilaritySignalEmitsDiagnosticWhenStoreIsEmpty.
    let store = make_empty_vector_store();
    let spec = VectorSimilaritySignal::spec(
        store,
        "test-model".to_string(),
        VectorSimilaritySignal::DEFAULT_PROXIMITY_THRESHOLD,
        None,
        None, // edge_checker: None for this parity test
    );
    let report = fire(spec);
    assert_eq!(report.name, "vector-similarity");
    // Empty store: 0 AssociateFrames + 1 scan-summary diagnostic.
    assert_eq!(
        report.emission_count, 1,
        "empty VectorStore produces only the scan-summary diagnostic"
    );
    assert_eq!(report.recent_diagnostics.len(), 1);
    assert_eq!(
        report.recent_diagnostics[0].title,
        "vector_similarity.scan.summary"
    );
    // No associate outcomes since no pairs were found.
    let associate_count = report
        .recent_outcomes
        .iter()
        .filter(|o| {
            matches!(
                o,
                SignalRouteOutcome::Routed { verb }
                | SignalRouteOutcome::RoutedButVerbStubbed { verb }
                if verb == "associate"
            )
        })
        .count();
    assert_eq!(associate_count, 0, "no pairs in empty store → no associate emissions");
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
fn registering_all_nine_default_specs_produces_nine_reports() {
    // ADR-018 F1: nine signals now. Any future addition must update this count.
    let mut scheduler = make_scheduler();
    let store = make_empty_vector_store();
    for spec in default_standing_signal_specs(store, "test-model", None) {
        scheduler.register(spec, T0_NANOS);
    }
    let reports = scheduler.report();
    assert_eq!(reports.len(), 9);
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

// ─── ADR-018 F1: TrainingSignal parity tests ─────────────────────────────────

/// Parity with Swift's `trainingSignalFiresTrainingDaemonRunOnce`.
/// The training signal's live spec must invoke `TrainingDaemon::run_once`
/// on each fire and emit exactly one diagnostic per tick regardless of
/// the gate state (dormant or active).
#[test]
fn training_signal_fires_training_daemon_run_once() {
    use genius_locus_kit::audit::{AuditTier, EntryUUID, UnifiedAuditEntry, UnifiedAuditLog, UnifiedAuditValue, UnifiedAuditVerb};
    use genius_locus_kit::matrix::{MatrixCalibrationRegistry, MatrixTier};
    use genius_locus_kit::training::{TrainingDaemon, TrainingThresholdGate};
    use std::sync::Mutex;
    use substrate_types::hlc::HLC;

    // Build a 12-entry capture log so the pipeline has work to do.
    let mut log = UnifiedAuditLog::new();
    for i in 0usize..12 {
        let mut bytes = [0u8; 16];
        bytes[0] = (i & 0xFF) as u8;
        log.add(UnifiedAuditEntry::new(
            AuditTier::Locus,
            HLC::new(1_000 + i as i64, 0, 1),
            UnifiedAuditVerb::Capture,
            EntryUUID(bytes),
            "tag_bits".to_string(),
            UnifiedAuditValue::Null,
            UnifiedAuditValue::Bitmap(1u64 << (i % 8)),
            None,
        ));
    }

    // Shared mutable state wrapped in Mutex for the Fn closure.
    // Zero threshold so the gate is always open and the pipeline runs.
    let daemon = Arc::new(Mutex::new(
        TrainingDaemon::new(TrainingThresholdGate::new(0))
    ));
    let tier = Arc::new(Mutex::new(MatrixTier::new()));
    let calibration = Arc::new(Mutex::new(MatrixCalibrationRegistry::default()));
    let audit_log = Arc::new(log);

    let daemon_c = daemon.clone();
    let tier_c = tier.clone();
    let calibration_c = calibration.clone();
    let log_c = audit_log.clone();

    let spec = TrainingSignal::spec(Arc::new(move || {
        let mut d = daemon_c.lock().unwrap();
        let mut t = tier_c.lock().unwrap();
        let mut cal = calibration_c.lock().unwrap();
        let tick = d.run_once(&log_c, &mut t, &mut cal);
        Ok(format!(
            "active={} transitions={} considered={}",
            tick.decision.is_active(),
            tick.decision.transition_count(),
            tick.pass_result.transitions_considered
        ))
    }));

    let cadence = TrainingSignal::DEFAULT_CADENCE_SECONDS;
    let mut scheduler = make_scheduler();
    let id = scheduler.register(spec, T0_NANOS);
    scheduler.tick(first_fire_nanos(cadence));

    let report = scheduler
        .report()
        .into_iter()
        .find(|r| r.signal_id == id)
        .expect("training-daemon signal must appear in the report");

    assert_eq!(report.name, "training-daemon");
    assert_eq!(
        report.emission_count, 1,
        "training signal emits one diagnostic per tick regardless of gate state"
    );
    assert_eq!(report.recent_diagnostics.len(), 1);
    assert_eq!(
        report.recent_diagnostics[0].title, "training-daemon.tick",
        "live spec must emit training-daemon.tick title on every fire"
    );

    // Gate was zero-threshold → pipeline ran. Primary correctness assertion:
    // run_once was invoked, not no-op'd.
    let live_row_count = tier.lock().unwrap().live_row_count;
    assert_eq!(
        live_row_count, 12,
        "training daemon must enrich when gate is open (threshold=0, 12 captures)"
    );
}

/// Parity with Swift's `TrainingSignal.defaultSpec()` diagnostic emission.
/// The no-op spec fires a "training-daemon.fired" diagnostic on each tick.
#[test]
fn training_signal_default_spec_emits_fired_diagnostic() {
    let spec = TrainingSignal::default_spec();
    let report = fire(spec);
    assert_eq!(report.name, "training-daemon");
    assert_eq!(report.emission_count, 1,
        "default spec emits one diagnostic per tick");
    assert_eq!(report.recent_diagnostics.len(), 1);
    assert_eq!(
        report.recent_diagnostics[0].title, "training-daemon.fired",
        "no-op spec must emit training-daemon.fired title"
    );
}

/// Parity with the TemporalCausalitySignal diagnostic-only default spec.
#[test]
fn temporal_causality_signal_default_spec_emits_fired_diagnostic() {
    let spec = TemporalCausalitySignal::default_spec();
    let report = fire(spec);
    assert_eq!(report.name, "temporal-causality-fold");
    assert_eq!(report.emission_count, 1,
        "default spec emits one diagnostic per tick");
    assert_eq!(report.recent_diagnostics.len(), 1);
    assert_eq!(
        report.recent_diagnostics[0].title, "temporal-causality-fold.fired",
        "no-op spec must emit temporal-causality-fold.fired title"
    );
}
