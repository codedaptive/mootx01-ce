// distillation_signal_tests.rs — conformance gate for DistillationSignal
// (DG2). Mirrors DistillationSignalTests.swift.
//
// Asserts:
// 1. Signal name and cadence match the Swift reference.
// 2. default_spec() fires → exactly one diagnostic, title "distillation-sweep.fired".
// 3. spec() with closure returning Ok(3) fires → diagnostic with "3 factoid(s)".
// 4. spec() with closure returning Err(_) fires → "distillation-sweep.error" diagnostic.

use std::sync::Arc;

use genius_locus_kit::{
    DistillationSignal, SchedulerNoopDispatcher, SchedulerSignalReport as SignalReport,
    SchedulerSignalSpec as SignalSpec, SchedulerSignalTrigger as SignalTrigger,
    SerialLaneScheduler,
};
use persistence_kit::inmemory::InMemoryStorage;
use queuekit::{PersistenceKitBackend, QueueBackend, QueueKit};
use substrate_types::hlc::HLCGenerator;

const T0_NANOS: i64 = 1_700_000_000_000_000_000;
const NANOS_PER_SEC: i64 = 1_000_000_000;

fn inmem_signals_queue() -> (QueueKit<Box<dyn QueueBackend>>, HLCGenerator) {
    let store_id = uuid::Uuid::from_u128(0x5348_4544_5545_5245_0000_0000_0000_0004);
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
        "estate-distillation-tests".to_string(),
        SchedulerNoopDispatcher,
        queue,
        None,
        hlc,
    )
}

fn first_fire_nanos(cadence_seconds: u64) -> i64 {
    T0_NANOS + (cadence_seconds as i64 + 1) * NANOS_PER_SEC
}

fn fire(spec: SignalSpec) -> SignalReport {
    let cadence = match &spec.trigger {
        SignalTrigger::Interval { seconds } => seconds.as_secs(),
        _ => panic!("DistillationSignal specs are interval-driven"),
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
fn distillation_signal_name_and_cadence_match_swift_reference() {
    assert_eq!(DistillationSignal::SIGNAL_NAME, "distillation-sweep");
    assert_eq!(DistillationSignal::DEFAULT_CADENCE_SECONDS, 3_600);
}

#[test]
fn default_spec_fires_emits_exactly_one_diagnostic() {
    let report = fire(DistillationSignal::default_spec());
    assert_eq!(report.name, "distillation-sweep");
    assert_eq!(report.emission_count, 1, "defaultSpec fires exactly one diagnostic");
    assert_eq!(report.recent_diagnostics.len(), 1);
    assert_eq!(
        report.recent_diagnostics[0].title,
        "distillation-sweep.fired"
    );
}

#[test]
fn spec_with_closure_returning_three_emits_complete_with_factoid_count() {
    let spec = DistillationSignal::spec(Arc::new(|| Ok(3_i64)));
    let report = fire(spec);
    assert_eq!(report.name, "distillation-sweep");
    assert_eq!(report.emission_count, 1);
    assert_eq!(report.recent_diagnostics.len(), 1);
    assert_eq!(
        report.recent_diagnostics[0].title,
        "distillation-sweep.complete"
    );
    assert!(
        report.recent_diagnostics[0].detail.contains("3 factoid(s)"),
        "diagnostic detail must contain the factoid count; got: {}",
        report.recent_diagnostics[0].detail
    );
}

#[test]
fn spec_with_error_closure_emits_error_diagnostic() {
    let spec = DistillationSignal::spec(Arc::new(|| {
        Err("cluster store unavailable".to_string())
    }));
    let report = fire(spec);
    assert_eq!(report.name, "distillation-sweep");
    assert_eq!(
        report.emission_count, 1,
        "error path surfaces one diagnostic — drain loop must continue"
    );
    assert_eq!(
        report.recent_diagnostics[0].title,
        "distillation-sweep.error"
    );
}
