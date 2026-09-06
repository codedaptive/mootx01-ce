// standing_signals_parity.rs — conformance gate for the Rust mirror
// of the twelve standing signals (GLK-05 + brain-layer governor ownership
// + consolidation-sweep signal 11 + anomaly-flag sweep signal 12
// + span-encode drain signal 13).
//
// Mirrors `StandingSignalsTests.swift`. The gate asserts:
//
// 1. Each signal's stable name and cadence match the Swift reference.
// 2. Each signal's spec produces the expected emission classes when
//    fired through a `SerialLaneScheduler` instance.
// 3. The default-set helper registers all twelve in the canonical order.
// 4. VectorSimilaritySignal with an empty VectorStore emits only the
//    scan-summary diagnostic (zero associate emissions) — parity with
//    the Swift empty-store test.
// 5. TrainingSignal fires TrainingDaemon::run_once and emits exactly
//    one diagnostic per tick regardless of gate state.
// 6. ConsolidationSignal (signal 11): daily cadence, default_spec emits
//    "consolidation-sweep.fired", live spec surfaces sweep report counts.
// 7. AnomalySweepSignal (signal 12, P3a): hourly cadence, default_spec
//    emits "anomaly-flag-sweep.fired", live spec surfaces changed-drawer
//    count in "anomaly-flag-sweep.complete".
// 8. SpanEncodeSignal (signal 13, ENCODER_RERANK_CONTRACT §10): REM-ALPHA
//    (30 s) cadence, default_spec emits "span-encode.fired", live spec
//    surfaces encoded-drawer count in "span-encode.complete".

use std::sync::Arc;

use genius_locus_kit::brain::signals::{AnomalySweepSignal, ContradictionScoutSignal, SpanEncodeSignal};
use genius_locus_kit::{
    default_standing_signal_names, default_standing_signal_specs, ByReferenceValiditySignal,
    ConsolidationSignal, DecaySweepSignal, DreamingSignal,
    EndOfDayTournamentSignal, MaintenanceSignal, SchedulerNoopDispatcher,
    SchedulerSignalRouteOutcome as SignalRouteOutcome, SchedulerSignalTrigger as SignalTrigger,
    SerialLaneScheduler, TemporalCausalitySignal, TrainingSignal, VectorSimilaritySignal,
};
use persistence_kit::inmemory::InMemoryStorage;
use queuekit::{PersistenceKitBackend, QueueBackend, QueueKit};
use substrate_types::hlc::HLCGenerator;
use synapsekit::VectorStore;

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

    assert_eq!(ContradictionScoutSignal::SIGNAL_NAME, "contradiction-scout");
    assert_eq!(ContradictionScoutSignal::DEFAULT_CADENCE_SECONDS, 3_600);

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

    // Signal 7 — added 2026-06-20 (mirrors hourly temporal-matrix scheduling).
    assert_eq!(
        TemporalCausalitySignal::SIGNAL_NAME,
        "temporal-causality-fold"
    );
    assert_eq!(TemporalCausalitySignal::DEFAULT_CADENCE_SECONDS, 3_600,
        "temporal-causality-fold runs hourly per design-council 2026-06-04 decision");

    // Signal 9 — wired (training daemon was an orphan before).
    assert_eq!(TrainingSignal::SIGNAL_NAME, "training-daemon");
    assert_eq!(TrainingSignal::DEFAULT_CADENCE_SECONDS, 3_600,
        "training-daemon runs hourly matching the temporal-causality rhythm");

    // Signal 11 — Wave-2 consolidation sweep (daily, D9 cadence class).
    assert_eq!(ConsolidationSignal::SIGNAL_NAME, "consolidation-sweep");
    assert_eq!(
        ConsolidationSignal::DEFAULT_CADENCE_SECONDS, 86_400,
        "consolidation-sweep runs daily per Wave-2 D9 spec"
    );

    // Signal 12 — P3a anomaly-flag sweep (hourly, same cadence family as
    // distillation and training).
    assert_eq!(AnomalySweepSignal::SIGNAL_NAME, "anomaly-flag-sweep");
    assert_eq!(
        AnomalySweepSignal::DEFAULT_CADENCE_SECONDS, 3_600,
        "anomaly-flag-sweep runs hourly per architecture spec §11.18"
    );

    // Signal 13 — span-encode drain (REM-ALPHA 30 s; replaces hourly adornment pass).
    assert_eq!(SpanEncodeSignal::SIGNAL_NAME, "span-encode");
    assert_eq!(
        SpanEncodeSignal::DEFAULT_CADENCE_SECONDS, 30,
        "span-encode drain runs every 30 s (REM-ALPHA cadence, ENCODER_RERANK_CONTRACT §10)"
    );
}

#[test]
fn default_standing_signal_names_helper_returns_canonical_order() {
    // Keep this compile-time roster synchronized with the production helper.
    // Signal 11 (consolidation-sweep) appended after training-daemon.
    // Signal 12 (anomaly-flag-sweep, P3a) appended after consolidation-sweep.
    // Signal 13 (span-encode, ENCODER_RERANK_CONTRACT §10) replaces the former
    // adornment-pass. REM-ALPHA (30 s) cadence; appended after anomaly-flag-sweep.
    let names = default_standing_signal_names();
    assert_eq!(
        names,
        [
            "dreaming-daemon",
            "maintenance-daemon",
            "vector-similarity",
            "contradiction-scout",
            "decay-sweep",
            "by-reference-validity",
            "end-of-day-tournament",
            "temporal-causality-fold",
            "training-daemon",
            "consolidation-sweep",
            "anomaly-flag-sweep",
            "span-encode",
        ]
    );
}

#[test]
fn default_standing_signal_specs_returns_twelve_specs_with_interval_triggers() {
    // Twelve specs: signal 13 is SpanEncodeSignal (ENCODER_RERANK_CONTRACT §10,
    // REM-ALPHA 30 s drain; replaces the former AdornmentPassSignal); signal 8's
    // slot is empty (the distilled rendering is computed inline at read time).
    // hunt_cycle, anomaly_cycle, and span_encode_cycle are None → no-op defaults.
    let store = make_empty_vector_store();
    let specs = default_standing_signal_specs(store, "test-model", None, None, None, None);
    assert_eq!(specs.len(), 12);
    for spec in &specs {
        match spec.trigger {
            SignalTrigger::Interval { .. } => {}
            _ => panic!("every standing signal is interval-driven; got {:?}", spec),
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
        VectorSimilaritySignal::DEFAULT_PROBE_LIMIT,
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

/// Pin the default probe limit constant. Resident behavior must remain
/// byte-identical (50 item IDs per pass) when `probe_limit` is not
/// supplied explicitly. Mirrors Swift's
/// `vectorSimilaritySignalDefaultProbeLimitIs50`.
#[test]
fn vector_similarity_signal_default_probe_limit_is_50() {
    assert_eq!(
        VectorSimilaritySignal::DEFAULT_PROBE_LIMIT, 50,
        "DEFAULT_PROBE_LIMIT must be 50; resident behavior is byte-unchanged at this value"
    );
}

/// Verify that a spec built with `probe_limit = 0` reaches the store call
/// with that limit: even a non-empty store produces only the scan-summary
/// diagnostic when the probe window is zero, because no item IDs are
/// sampled and therefore no pairs are found. This distinguishes the wired
/// limit from the empty-store baseline (where the same result occurs for
/// different reasons). Mirrors Swift's
/// `vectorSimilaritySignalProbeLimitZeroEmitsOnlyDiagnosticOnPopulatedStore`.
#[test]
fn vector_similarity_signal_probe_limit_zero_emits_only_diagnostic_on_populated_store() {
    use engram_lib::Engram;

    // Populate the store with two vectors that are within the proximity
    // threshold (identical Engrams, Hamming distance = 0 ≤ 64). With the
    // default probe limit, the signal would find this pair and emit an
    // AssociateFrame. With probe_limit = 0, no item IDs are sampled and
    // the pair is never found — only the scan-summary diagnostic is emitted.
    let store = make_empty_vector_store();
    let identical_engram = Engram::new(
        0xAAAA_AAAA_AAAA_AAAA,
        0xAAAA_AAAA_AAAA_AAAA,
        0xAAAA_AAAA_AAAA_AAAA,
        0xAAAA_AAAA_AAAA_AAAA,
    );
    // filed_at_unix_secs: i64 — mirrors the VectorStore.add_vector Swift Date parameter.
    let t0_unix_secs: i64 = 1_700_000_000;
    store
        .add_vector("item-probe-a", &identical_engram, "test-model", "v1", t0_unix_secs)
        .expect("add_vector item-probe-a");
    store
        .add_vector("item-probe-b", &identical_engram, "test-model", "v1", t0_unix_secs)
        .expect("add_vector item-probe-b");

    // probe_limit = 0: no items sampled → no pairs → only the scan-summary
    // diagnostic. If probe_limit were not threaded to recent_item_ids, the
    // signal would probe both items and emit an AssociateFrame.
    let spec = VectorSimilaritySignal::spec(
        store,
        "test-model".to_string(),
        VectorSimilaritySignal::DEFAULT_PROXIMITY_THRESHOLD,
        0, // probe_limit = 0: zero item IDs sampled
        None,
        None,
    );
    let report = fire(spec);
    assert_eq!(report.name, "vector-similarity");
    assert_eq!(
        report.emission_count, 1,
        "probe_limit=0 on a populated store must produce only the scan-summary diagnostic"
    );
    assert_eq!(report.recent_diagnostics.len(), 1);
    assert_eq!(
        report.recent_diagnostics[0].title,
        "vector_similarity.scan.summary"
    );
    // No associate outcomes: zero item IDs probed → zero candidate pairs.
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
    assert_eq!(
        associate_count, 0,
        "probe_limit=0 must produce no associate emissions even on a populated store"
    );
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
fn registering_all_twelve_default_specs_produces_twelve_reports() {
    // Twelve specs including signal 13 (SpanEncodeSignal, REM-ALPHA 30 s,
    // ENCODER_RERANK_CONTRACT §10; replaces the former AdornmentPassSignal).
    // The "span-encode" name must appear in the report.
    let mut scheduler = make_scheduler();
    let store = make_empty_vector_store();
    // hunt_cycle, anomaly_cycle, and span_encode_cycle are None → no-op defaults.
    for spec in default_standing_signal_specs(store, "test-model", None, None, None, None) {
        scheduler.register(spec, T0_NANOS);
    }
    let reports = scheduler.report();
    assert_eq!(reports.len(), 12);
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

// ─── brain-layer governor ownership: TrainingSignal parity tests ─────────────────────────────────

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

// ─── Signal 11: ConsolidationSignal parity tests ──────────────────────────────

/// Parity with Swift's `ConsolidationSignal.defaultSpec()` no-op emission.
/// The no-op spec fires a "consolidation-sweep.fired" diagnostic on each tick.
#[test]
fn consolidation_signal_default_spec_emits_fired_diagnostic() {
    let spec = ConsolidationSignal::default_spec();
    let report = fire(spec);
    assert_eq!(report.name, "consolidation-sweep");
    assert_eq!(
        report.emission_count, 1,
        "default spec emits one diagnostic per tick"
    );
    assert_eq!(report.recent_diagnostics.len(), 1);
    assert_eq!(
        report.recent_diagnostics[0].title, "consolidation-sweep.fired",
        "no-op spec must emit consolidation-sweep.fired title"
    );
}

/// Parity with Swift `ConsolidationSignal.spec` live path: successful sweep
/// surfaces new_vague_items, fold_ins, and fold_in_rejections counts in the
/// "consolidation-sweep.complete" diagnostic title.
#[test]
fn consolidation_signal_live_spec_emits_complete_diagnostic_on_ok() {
    use genius_locus_kit::brain::consolidation_cycle::ConsolidationSweepReport;
    use std::sync::Arc;

    let spec = ConsolidationSignal::spec(Arc::new(|| {
        Ok(ConsolidationSweepReport {
            new_vague_items: 3,
            fold_ins: 1,
            fold_in_rejections: 0,
            repaired_items: 0,
        })
    }));
    let report = fire(spec);
    assert_eq!(report.name, "consolidation-sweep");
    assert_eq!(
        report.emission_count, 1,
        "live spec emits one diagnostic per tick"
    );
    assert_eq!(report.recent_diagnostics.len(), 1);
    assert_eq!(
        report.recent_diagnostics[0].title, "consolidation-sweep.complete",
        "live spec emits consolidation-sweep.complete on success"
    );
    // The detail string must surface the report counts so the D10 drift
    // policy can be evaluated from recentDiagnostics (mirrors Swift spec).
    let detail = &report.recent_diagnostics[0].detail;
    assert!(detail.contains("new=3"), "detail must include new_vague_items count");
    assert!(detail.contains("foldIns=1"), "detail must include fold_ins count");
    assert!(
        detail.contains("foldInRejections=0"),
        "detail must include fold_in_rejections count"
    );
    assert!(
        detail.contains("repaired=0"),
        "detail must include repaired_items count (§D.6 #4 repair prologue)"
    );
}

/// Live spec with Err(msg) emits "consolidation-sweep.error" diagnostic —
/// the scheduler's drain loop is not interrupted.
#[test]
fn consolidation_signal_live_spec_emits_error_diagnostic_on_err() {
    use std::sync::Arc;

    let spec = ConsolidationSignal::spec(Arc::new(|| {
        Err("estate unavailable during maintenance window".to_string())
    }));
    let report = fire(spec);
    assert_eq!(report.name, "consolidation-sweep");
    assert_eq!(report.emission_count, 1);
    assert_eq!(report.recent_diagnostics.len(), 1);
    assert_eq!(
        report.recent_diagnostics[0].title, "consolidation-sweep.error",
        "error path must emit consolidation-sweep.error title"
    );
    assert!(
        report.recent_diagnostics[0]
            .detail
            .contains("estate unavailable"),
        "error detail must propagate the closure's message"
    );
}

// ─── Signal 12: AnomalySweepSignal parity tests (P3a) ────────────────────────

/// Parity with Swift's `AnomalySweepSignal.defaultSpec()` no-op emission.
/// The no-op spec fires an "anomaly-flag-sweep.fired" diagnostic on each tick.
#[test]
fn anomaly_sweep_signal_default_spec_emits_fired_diagnostic() {
    let spec = AnomalySweepSignal::default_spec();
    let report = fire(spec);
    assert_eq!(report.name, "anomaly-flag-sweep");
    assert_eq!(
        report.emission_count, 1,
        "default spec emits one diagnostic per tick"
    );
    assert_eq!(report.recent_diagnostics.len(), 1);
    assert_eq!(
        report.recent_diagnostics[0].title, "anomaly-flag-sweep.fired",
        "no-op spec must emit anomaly-flag-sweep.fired title"
    );
}

/// Parity with Swift `AnomalySweepSignal.spec` live path: successful sweep
/// surfaces the changed-drawer count in the "anomaly-flag-sweep.complete"
/// diagnostic title. Golden pin: Ok(1) → detail contains "updated 1 drawer(s)".
#[test]
fn anomaly_sweep_signal_live_spec_emits_complete_diagnostic_on_ok() {
    // Golden pin: same closure shape as the Swift spec test. The live sweep
    // returns 1 (one drawer's bit 26 changed). Cross-port golden pin:
    // Swift AnomalyFlagSweepTests uses the same 1-changed count on first run.
    let spec = AnomalySweepSignal::spec(Arc::new(|| Ok(1)));
    let report = fire(spec);
    assert_eq!(report.name, "anomaly-flag-sweep");
    assert_eq!(
        report.emission_count, 1,
        "live spec emits one diagnostic per tick"
    );
    assert_eq!(report.recent_diagnostics.len(), 1);
    assert_eq!(
        report.recent_diagnostics[0].title, "anomaly-flag-sweep.complete",
        "live spec emits anomaly-flag-sweep.complete on success"
    );
    // The detail string must surface the changed-drawer count so
    // application monitoring can observe sweep activity.
    let detail = &report.recent_diagnostics[0].detail;
    assert!(
        detail.contains("updated 1 drawer(s)"),
        "detail must include changed-drawer count; got: {detail}"
    );
}

/// Parity with Swift error path: Err(msg) emits "anomaly-flag-sweep.error"
/// diagnostic — the scheduler's drain loop is not interrupted.
#[test]
fn anomaly_sweep_signal_live_spec_emits_error_diagnostic_on_err() {
    let spec = AnomalySweepSignal::spec(Arc::new(|| {
        Err("estate handle not available for anomaly sweep".to_string())
    }));
    let report = fire(spec);
    assert_eq!(report.name, "anomaly-flag-sweep");
    assert_eq!(report.emission_count, 1);
    assert_eq!(report.recent_diagnostics.len(), 1);
    assert_eq!(
        report.recent_diagnostics[0].title, "anomaly-flag-sweep.error",
        "error path must emit anomaly-flag-sweep.error title"
    );
    assert!(
        report.recent_diagnostics[0]
            .detail
            .contains("estate handle not available"),
        "error detail must propagate the closure's message"
    );
}

/// Idempotence golden pin: second sweep call on unchanged estate returns
/// Ok(0). Mirrors Swift `anomalySweepSignalIdempotence` test.
#[test]
fn anomaly_sweep_signal_idempotence_ok_zero_on_second_run() {
    use std::sync::atomic::{AtomicU32, Ordering};
    // First call returns 1 (bit changed), second returns 0 (no change).
    let call_count = Arc::new(AtomicU32::new(0));
    let call_count_c = call_count.clone();
    let spec = AnomalySweepSignal::spec(Arc::new(move || {
        let n = call_count_c.fetch_add(1, Ordering::SeqCst);
        if n == 0 {
            Ok(1) // first run: one drawer bit changed
        } else {
            Ok(0) // subsequent runs: idempotent, no change
        }
    }));

    // Fire twice through a single scheduler to simulate two hourly ticks.
    let cadence = AnomalySweepSignal::DEFAULT_CADENCE_SECONDS;
    let mut scheduler = make_scheduler();
    let id = scheduler.register(spec, T0_NANOS);

    // First tick: bit changed → Ok(1).
    scheduler.tick(first_fire_nanos(cadence));
    let report_1 = scheduler
        .report()
        .into_iter()
        .find(|r| r.signal_id == id)
        .expect("signal must appear after first tick");
    // recent_diagnostics accumulates across ticks; use last() for the newest entry.
    let diag_1 = report_1
        .recent_diagnostics
        .last()
        .expect("first tick must produce a diagnostic");
    assert_eq!(diag_1.title, "anomaly-flag-sweep.complete");
    assert!(diag_1.detail.contains("updated 1 drawer(s)"));

    // Second tick: idempotent → Ok(0).
    let second_fire = T0_NANOS + (cadence as i64 * 2 + 2) * 1_000_000_000;
    scheduler.tick(second_fire);
    let report_2 = scheduler
        .report()
        .into_iter()
        .find(|r| r.signal_id == id)
        .expect("signal must appear after second tick");
    // After two ticks, recent_diagnostics has two entries; last() is the newest.
    let diag_2 = report_2
        .recent_diagnostics
        .last()
        .expect("second tick must produce a diagnostic");
    assert_eq!(diag_2.title, "anomaly-flag-sweep.complete");
    assert!(
        diag_2.detail.contains("updated 0 drawer(s)"),
        "second run must report zero changed drawers (idempotent); got: {}",
        diag_2.detail
    );
}

// ─── Live-closure injection parity tests ─────────────────────────────────────
//
// These tests run under --features test-seams to confirm that injecting live
// hunt and anomaly closures into default_standing_signal_specs produces
// the "complete" diagnostic titles (not the no-op "fired" titles). This is the
// cross-port parity gate: the Rust resident must reach the same diagnostic
// vocabulary as the Swift resident, where huntCycle and anomalyCycle are wired
// to real EstateCoordinator methods.
//
// The closures here are synthetic (atomic-counter sentinels returning Ok(0)/
// Ok((0,0))) — they verify the spec selection path, not the coordinator
// logic. The coordinator integration is covered by the coordinator tests
// (hunt_contradictions, anomaly_flag_sweep in coordinator.rs).

/// Parity gate: injecting a live hunt closure selects ContradictionScoutSignal::spec
/// instead of default_spec, so the diagnostic title is
/// "contradiction-scout.pass.complete" (live) not "contradiction-scout.fired" (no-op).
/// Golden pin matches Swift's ContradictionScoutSignal.spec live-path test.
#[test]
fn live_hunt_closure_emits_complete_diagnostic_not_noop_fired() {
    use std::sync::atomic::{AtomicBool, Ordering};

    let hunt_called = Arc::new(AtomicBool::new(false));
    let hunt_called_c = hunt_called.clone();

    // Live hunt cycle: returns (0 proposed, 0 borderline) — empty estate.
    // The closure being called (not default_spec) is what this test gates.
    let hunt_cycle: Arc<dyn Fn() -> Result<(usize, usize), String> + Send + Sync> =
        Arc::new(move || {
            hunt_called_c.store(true, Ordering::SeqCst);
            Ok((0, 0))
        });

    let store = make_empty_vector_store();
    let specs = default_standing_signal_specs(
        store, "test-model", None, Some(hunt_cycle), None, None,
    );

    let scout_spec = specs
        .into_iter()
        .find(|s| s.name == ContradictionScoutSignal::SIGNAL_NAME)
        .expect("contradiction-scout must be in the default spec set");
    let report = fire(scout_spec);

    // The live closure was used — not the no-op default_spec.
    assert!(
        hunt_called.load(Ordering::SeqCst),
        "live hunt closure must be called when Some(hunt_cycle) is injected"
    );
    assert_eq!(report.name, "contradiction-scout");
    assert_eq!(report.emission_count, 1, "live spec emits one diagnostic per tick");
    assert_eq!(report.recent_diagnostics.len(), 1);
    // Golden pin (cross-port): Swift's live huntCycle produces
    // "contradiction-scout.pass.complete"; Rust must match.
    assert_eq!(
        report.recent_diagnostics[0].title,
        "contradiction-scout.pass.complete",
        "live hunt closure must emit .pass.complete, not .fired (no-op title)"
    );
    // Golden pin: detail format matches Swift — "proposed 0 contradiction(s), 0 borderline"
    let detail = &report.recent_diagnostics[0].detail;
    assert!(
        detail.contains("proposed 0 contradiction(s)"),
        "detail must contain proposed count; got: {detail}"
    );
    assert!(
        detail.contains("0 borderline candidate(s)"),
        "detail must contain borderline count; got: {detail}"
    );
}

/// Parity gate: injecting a live anomaly closure selects AnomalySweepSignal::spec
/// instead of default_spec, so the diagnostic title is
/// "anomaly-flag-sweep.complete" (live) not "anomaly-flag-sweep.fired" (no-op).
/// Golden pin matches Swift's AnomalySweepSignal.spec live-path test and the
/// ResidentDaemon anomalyCycle wiring.
#[test]
fn live_anomaly_closure_emits_complete_diagnostic_not_noop_fired() {
    use std::sync::atomic::{AtomicBool, Ordering};

    let anomaly_called = Arc::new(AtomicBool::new(false));
    let anomaly_called_c = anomaly_called.clone();

    // Live anomaly cycle: returns 0 changed drawers — empty estate.
    // The closure being called (not default_spec) is what this test gates.
    let anomaly_cycle: Arc<dyn Fn() -> Result<i64, String> + Send + Sync> =
        Arc::new(move || {
            anomaly_called_c.store(true, Ordering::SeqCst);
            Ok(0)
        });

    let store = make_empty_vector_store();
    let specs = default_standing_signal_specs(
        store, "test-model", None, None, Some(anomaly_cycle), None,
    );

    let anomaly_spec = specs
        .into_iter()
        .find(|s| s.name == AnomalySweepSignal::SIGNAL_NAME)
        .expect("anomaly-flag-sweep must be in the default spec set");
    let report = fire(anomaly_spec);

    // The live closure was used — not the no-op default_spec.
    assert!(
        anomaly_called.load(Ordering::SeqCst),
        "live anomaly closure must be called when Some(anomaly_cycle) is injected"
    );
    assert_eq!(report.name, "anomaly-flag-sweep");
    assert_eq!(report.emission_count, 1, "live spec emits one diagnostic per tick");
    assert_eq!(report.recent_diagnostics.len(), 1);
    // Golden pin (cross-port): Swift's live anomalyCycle produces
    // "anomaly-flag-sweep.complete"; Rust must match.
    assert_eq!(
        report.recent_diagnostics[0].title,
        "anomaly-flag-sweep.complete",
        "live anomaly closure must emit .complete, not .fired (no-op title)"
    );
    // Golden pin: detail format "updated N drawer(s)" matches the Swift spec
    // factory's format string and the ResidentDaemon diagnostic surface.
    let detail = &report.recent_diagnostics[0].detail;
    assert!(
        detail.contains("updated 0 drawer(s)"),
        "detail must contain changed-drawer count; got: {detail}"
    );
}

/// Parity gate: injecting a live span-encode closure selects SpanEncodeSignal::spec
/// instead of default_spec, so the diagnostic title is
/// "span-encode.complete" (live) not "span-encode.fired" (no-op).
/// Golden pin matches the SpanEncodeSignal.spec live-path title.
#[test]
fn live_span_encode_closure_emits_complete_diagnostic_not_noop_fired() {
    use std::sync::atomic::{AtomicBool, Ordering};

    let span_encode_called = Arc::new(AtomicBool::new(false));
    let span_encode_called_c = span_encode_called.clone();

    // Live span-encode cycle: returns 0 encoded drawers — no pending work.
    // The closure being called (not default_spec) is what this test gates.
    let span_encode_cycle: Arc<dyn Fn() -> Result<i64, String> + Send + Sync> =
        Arc::new(move || {
            span_encode_called_c.store(true, Ordering::SeqCst);
            Ok(0)
        });

    let store = make_empty_vector_store();
    let specs = default_standing_signal_specs(
        store, "test-model", None, None, None, Some(span_encode_cycle),
    );

    let span_encode_spec = specs
        .into_iter()
        .find(|s| s.name == SpanEncodeSignal::SIGNAL_NAME)
        .expect("span-encode must be in the default spec set");
    let report = fire(span_encode_spec);

    // The live closure was used — not the no-op default_spec.
    assert!(
        span_encode_called.load(Ordering::SeqCst),
        "live span-encode closure must be called when Some(span_encode_cycle) is injected"
    );
    assert_eq!(report.name, "span-encode");
    assert_eq!(report.emission_count, 1, "live spec emits one diagnostic per tick");
    assert_eq!(report.recent_diagnostics.len(), 1);
    // Golden pin (cross-port): Swift's live spanEncodeCycle produces
    // "span-encode.complete"; Rust must match.
    assert_eq!(
        report.recent_diagnostics[0].title,
        "span-encode.complete",
        "live span-encode closure must emit .complete, not .fired (no-op title)"
    );
    // Golden pin: detail format "encoded N drawer(s)" matches the Swift spec
    // factory's format string.
    let detail = &report.recent_diagnostics[0].detail;
    assert!(
        detail.contains("encoded 0 drawer(s)"),
        "detail must contain encoded-drawer count; got: {detail}"
    );
}
