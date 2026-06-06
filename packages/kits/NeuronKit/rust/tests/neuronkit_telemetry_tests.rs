//! NeuronKit self-report telemetry integration tests — NEURONKIT_REPORT_001.
//!
//! Mirrors the Swift suite in
//! Tests/NeuronKitTests/NeuronKitTelemetryTests.swift.
//! Section numbers correspond to the Swift suites:
//!
//!   §1 Disabled gate: no metric emitted when monitoring is OFF.
//!   §2 hybridRecall rerank math: math is identical regardless of monitoring.
//!   §3 DreamingDaemon cycle emissions: start + complete pair per run_cycle.
//!   §4 bradleyTerry emissions: bt_update + competitor_count per call.
//!   §5 Conformance: math output is identical with monitoring ON and OFF.
//!
//! ISOLATION STRATEGY
//! These tests manipulate the global Intellectus singleton (enabled flag +
//! installed sink). Rust integration tests run in parallel by default.
//!
//! Solution: all tests that touch the singleton acquire GLOBAL_LOCK for
//! their entire duration, using the same pattern as SubstrateKernel's
//! kernel_telemetry_tests.rs — a static OnceLock<Mutex<()>> with
//! poison-error recovery. This is the Rust parallel of the Swift
//! `.serialized` suite trait.
//!
//! Tests that ONLY read math output with monitoring disabled do not
//! need the lock (they do not install a sink or read sink state).

use std::sync::{Arc, Mutex, OnceLock};

use intellectus_lib::{Intellectus, NoOpSink, StatSample, StatsSink};
use neuron_kit::{
    bradley_terry, PairwiseOutcome,
    CoOccurrenceObservation, DreamingDaemon, DreamingPolicy, DreamingProposalSink,
    DreamingSubstrateReader,
    ProposeFrameOut, RecallTraceItem, TunnelLink,
    rerank, DrawerRow, RecallFrameTuning,
};

// Process-wide serialisation lock — same pattern as SubstrateKernel tests.
// Lock poisoning recovered with `into_inner()` so subsequent tests still run.
// Each test restores global state to disabled + NoOpSink before releasing.
static GLOBAL_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

fn global_lock() -> std::sync::MutexGuard<'static, ()> {
    let mutex = GLOBAL_LOCK.get_or_init(|| Mutex::new(()));
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poison) => poison.into_inner(),
    }
}

// MARK: - Helpers: capturing sink

/// Records every received StatSample. Thread-safe via Mutex.
struct CapturingSink {
    samples: Mutex<Vec<StatSample>>,
}

impl CapturingSink {
    fn new() -> Self {
        CapturingSink { samples: Mutex::new(Vec::new()) }
    }

    fn count(&self) -> usize {
        self.samples.lock().unwrap().len()
    }

    /// Count samples with the given metric name.
    fn count_named(&self, name: &str) -> usize {
        self.samples
            .lock()
            .unwrap()
            .iter()
            .filter(|s| {
                if let StatSample::Metric { name: n, .. } = s {
                    n == name
                } else {
                    false
                }
            })
            .count()
    }

    /// Return the first sample with the given metric name.
    fn first_named(&self, name: &str) -> Option<StatSample> {
        self.samples
            .lock()
            .unwrap()
            .iter()
            .find(|s| {
                if let StatSample::Metric { name: n, .. } = s {
                    n == name
                } else {
                    false
                }
            })
            .cloned()
    }

    /// Return all samples with the given metric name.
    fn all_named(&self, name: &str) -> Vec<StatSample> {
        self.samples
            .lock()
            .unwrap()
            .iter()
            .filter(|s| {
                if let StatSample::Metric { name: n, .. } = s {
                    n == name
                } else {
                    false
                }
            })
            .cloned()
            .collect()
    }
}

impl StatsSink for CapturingSink {
    fn receive(&self, sample: StatSample) {
        self.samples.lock().unwrap().push(sample);
    }
}

// MARK: - Fake dreaming infrastructure

struct FakeReader {
    observations: Vec<CoOccurrenceObservation>,
}

impl DreamingSubstrateReader for FakeReader {
    fn recent_recall_traces(&self) -> Vec<RecallTraceItem> {
        vec![]
    }
    fn co_occurrence_observations(&self) -> Vec<CoOccurrenceObservation> {
        self.observations.clone()
    }
    fn existing_tunnels(&self) -> Vec<TunnelLink> {
        vec![]
    }
}

#[derive(Default)]
struct RecordingSink {
    proposals: Vec<ProposeFrameOut>,
}

impl DreamingProposalSink for RecordingSink {
    fn propose(&mut self, frame: ProposeFrameOut) {
        self.proposals.push(frame);
    }
    fn record_cycle_diary(&mut self, _entry: neuron_kit::dreaming_cycle::DreamingDiaryEntry) {}
}

// MARK: - Strongly-connected 3-competitor circular graph

/// A→B, B→C, C→A — every vertex reachable from every other.
/// Required for a finite Bradley-Terry MLE. Matches the Swift §4 test fixture.
fn circular_outcomes() -> Vec<PairwiseOutcome> {
    vec![
        PairwiseOutcome::new("A", "B", 3),
        PairwiseOutcome::new("B", "C", 2),
        PairwiseOutcome::new("C", "A", 1),
    ]
}

// MARK: - §1 Disabled gate

/// With monitoring OFF, bradleyTerry must not emit any metrics.
#[test]
fn bradley_terry_emits_nothing_when_disabled() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(false);

    let _ = bradley_terry(&circular_outcomes());

    assert_eq!(sink.count(), 0,
        "bradley_terry must not emit when monitoring is disabled");

    Intellectus::install(Arc::new(NoOpSink));
}

/// With monitoring OFF, algorithm result is correct (conformance preserved).
#[test]
fn bradley_terry_result_correct_when_disabled() {
    // Acquires the global lock even though this test only reads math output.
    // Another test that holds the lock with enabled=true could otherwise
    // receive this test's bradley_terry() call in its sink.
    let _guard = global_lock();
    Intellectus::set_enabled(false);

    let scores = bradley_terry(&circular_outcomes()).unwrap();
    // A wins most (3 wins) in the circular graph.
    assert_eq!(scores.len(), 3);
    assert_eq!(scores[0].competitor_id, "A",
        "A must rank first; got {:?}", scores.iter().map(|s| &s.competitor_id).collect::<Vec<_>>());

    Intellectus::install(Arc::new(NoOpSink));
}

// MARK: - §2 hybridRecall rerank math

/// rerank math output is identical regardless of monitoring state.
#[test]
fn rerank_math_identical_regardless_of_monitoring() {
    let _guard = global_lock();
    let drawers: Vec<DrawerRow> = (0..5).map(|i| DrawerRow {
        id: format!("drawer-{i}"),
        content: format!("content item {i}"),
    }).collect();
    let tuning = RecallFrameTuning::default_tuning();

    Intellectus::set_enabled(false);
    let result_off = rerank(&drawers, &tuning);

    Intellectus::set_enabled(true);
    let result_on = rerank(&drawers, &tuning);

    let ids_off: Vec<_> = result_off.iter().map(|d| d.id.clone()).collect();
    let ids_on: Vec<_> = result_on.iter().map(|d| d.id.clone()).collect();
    assert_eq!(ids_off, ids_on,
        "rerank output must be identical regardless of monitoring state");

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

// MARK: - §3 DreamingDaemon cycle emissions

/// One run_cycle call emits exactly two neuronkit.dream.cycle metrics:
/// one with status "start" and one with status "complete".
#[test]
fn run_cycle_emits_start_and_complete() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    let reader = FakeReader { observations: vec![] };
    let mut recording_sink = RecordingSink::default();
    let _ = daemon.run_cycle(&reader, &neuron_kit::RecallTraceRewardSource, &mut recording_sink);

    let cycle_metrics = sink.all_named("neuronkit.dream.cycle");
    assert_eq!(cycle_metrics.len(), 2,
        "run_cycle must emit exactly 2 neuronkit.dream.cycle metrics; got {}", cycle_metrics.len());

    let start_metric = cycle_metrics.iter().find(|s| {
        if let StatSample::Metric { tags, .. } = s {
            tags.get("status").map(|v| v.as_str()) == Some("start")
        } else { false }
    });
    let complete_metric = cycle_metrics.iter().find(|s| {
        if let StatSample::Metric { tags, .. } = s {
            tags.get("status").map(|v| v.as_str()) == Some("complete")
        } else { false }
    });

    assert!(start_metric.is_some(), "must emit a 'start' metric");
    assert!(complete_metric.is_some(), "must emit a 'complete' metric");

    if let Some(StatSample::Metric { tags, .. }) = complete_metric {
        assert_eq!(tags.get("drawers_touched").map(|v| v.as_str()), Some("0"),
            "with no observations, drawers_touched must be '0'");
        assert_eq!(tags.get("proposals").map(|v| v.as_str()), Some("0"),
            "with no observations, proposals must be '0'");
    }

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// Two run_cycle calls emit exactly four neuronkit.dream.cycle metrics.
#[test]
fn two_run_cycle_calls_emit_four_metrics() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    let reader = FakeReader { observations: vec![] };
    let mut s = RecordingSink::default();
    let _ = daemon.run_cycle(&reader, &neuron_kit::RecallTraceRewardSource, &mut s);
    let _ = daemon.run_cycle(&reader, &neuron_kit::RecallTraceRewardSource, &mut s);

    assert_eq!(sink.all_named("neuronkit.dream.cycle").len(), 4,
        "two run_cycle calls must emit 4 neuronkit.dream.cycle metrics");

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// When monitoring is disabled, run_cycle emits nothing.
#[test]
fn run_cycle_emits_nothing_when_disabled() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(false);

    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    let reader = FakeReader { observations: vec![] };
    let mut s = RecordingSink::default();
    let _ = daemon.run_cycle(&reader, &neuron_kit::RecallTraceRewardSource, &mut s);

    assert_eq!(sink.count(), 0,
        "run_cycle must not emit when monitoring is disabled");

    Intellectus::install(Arc::new(NoOpSink));
}

/// The drawers_touched tag reflects the observation count.
#[test]
fn drawers_touched_tag_matches_observation_count() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let obs = vec![
        CoOccurrenceObservation {
            endpoint_a: "a".to_string(),
            endpoint_b: "b".to_string(),
            attempts: 2,
            evidence_targets: vec![],
        },
        CoOccurrenceObservation {
            endpoint_a: "c".to_string(),
            endpoint_b: "d".to_string(),
            attempts: 1,
            evidence_targets: vec![],
        },
    ];
    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    let reader = FakeReader { observations: obs };
    let mut s = RecordingSink::default();
    let _ = daemon.run_cycle(&reader, &neuron_kit::RecallTraceRewardSource, &mut s);

    let complete_metric = sink.all_named("neuronkit.dream.cycle").into_iter().find(|s| {
        if let StatSample::Metric { tags, .. } = s {
            tags.get("status").map(|v| v.as_str()) == Some("complete")
        } else { false }
    });
    assert!(complete_metric.is_some(), "must emit a complete metric");
    if let Some(StatSample::Metric { tags, .. }) = complete_metric {
        assert_eq!(tags.get("drawers_touched").map(|v| v.as_str()), Some("2"),
            "drawers_touched must equal observation count; got {:?}", tags.get("drawers_touched"));
    }

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

// MARK: - §4 bradleyTerry emissions

/// bradleyTerry emits bt_update and competitor_count when monitoring is on.
#[test]
fn bradley_terry_emits_both_metrics_when_enabled() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let _ = bradley_terry(&circular_outcomes());

    assert_eq!(sink.count_named("neuronkit.tournament.bt_update"), 1,
        "bradleyTerry must emit exactly 1 bt_update metric");
    assert_eq!(sink.count_named("neuronkit.tournament.competitor_count"), 1,
        "bradleyTerry must emit exactly 1 competitor_count metric");

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// The competitor_count metric value matches the actual competitor count.
#[test]
fn competitor_count_metric_value_matches_actual() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let scores = bradley_terry(&circular_outcomes()).unwrap();

    let sample = sink.first_named("neuronkit.tournament.competitor_count");
    if let Some(StatSample::Metric { value, .. }) = sample {
        assert_eq!(value, scores.len() as f64,
            "competitor_count metric value must equal actual score count");
    } else {
        panic!("no competitor_count metric emitted");
    }

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// The bt_update tag carries the competitor_count string.
#[test]
fn bt_update_tag_carries_competitor_count() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    // Different 3-competitor circular set.
    let outcomes = vec![
        PairwiseOutcome::new("X", "Y", 2),
        PairwiseOutcome::new("Y", "Z", 2),
        PairwiseOutcome::new("Z", "X", 1),
    ];
    let _ = bradley_terry(&outcomes);

    let sample = sink.first_named("neuronkit.tournament.bt_update");
    if let Some(StatSample::Metric { tags, .. }) = sample {
        assert_eq!(tags.get("competitor_count").map(|v| v.as_str()), Some("3"),
            "bt_update must tag competitor_count '3'; got {:?}", tags.get("competitor_count"));
    } else {
        panic!("no bt_update metric emitted");
    }

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// Two bradleyTerry calls emit their own pairs of metrics.
#[test]
fn each_bradley_terry_call_emits_own_pair() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let _ = bradley_terry(&circular_outcomes());
    let _ = bradley_terry(&circular_outcomes());

    assert_eq!(sink.count_named("neuronkit.tournament.bt_update"), 2,
        "two calls must produce 2 bt_update metrics; got {}", sink.count_named("neuronkit.tournament.bt_update"));
    assert_eq!(sink.count_named("neuronkit.tournament.competitor_count"), 2,
        "two calls must produce 2 competitor_count metrics");

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

// MARK: - §5 Conformance gate

/// bradleyTerry result is identical whether monitoring is ON or OFF.
#[test]
fn bradley_terry_result_identical_with_and_without_telemetry() {
    let _guard = global_lock();

    // OFF path.
    Intellectus::set_enabled(false);
    let off_result = bradley_terry(&circular_outcomes()).unwrap();

    // ON path.
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);
    let on_result = bradley_terry(&circular_outcomes()).unwrap();

    // IDs and strengths must be bit-identical.
    let off_ids: Vec<_> = off_result.iter().map(|s| s.competitor_id.clone()).collect();
    let on_ids: Vec<_> = on_result.iter().map(|s| s.competitor_id.clone()).collect();
    assert_eq!(off_ids, on_ids,
        "rank order must be identical regardless of monitoring state");

    for (off, on) in off_result.iter().zip(on_result.iter()) {
        assert_eq!(off.strength, on.strength,
            "strength for {} must be identical regardless of monitoring state", off.competitor_id);
    }

    // ON path emitted metrics (proves the on-path was active).
    assert!(sink.count() > 0, "monitoring-on path must emit at least one metric");

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// dreaming cycle report is identical regardless of monitoring.
#[test]
fn dreaming_cycle_report_identical_with_and_without_telemetry() {
    let _guard = global_lock();
    let obs = vec![
        CoOccurrenceObservation {
            endpoint_a: "ep-a".to_string(),
            endpoint_b: "ep-b".to_string(),
            attempts: 2,
            evidence_targets: vec![],
        },
    ];

    // OFF path.
    Intellectus::set_enabled(false);
    let mut daemon_off = DreamingDaemon::new(DreamingPolicy::default());
    let reader_off = FakeReader { observations: obs.clone() };
    let mut sink_off = RecordingSink::default();
    let report_off = daemon_off.run_cycle(&reader_off, &neuron_kit::RecallTraceRewardSource, &mut sink_off);

    // ON path.
    let capture_sink = Arc::new(CapturingSink::new());
    Intellectus::install(capture_sink.clone());
    Intellectus::set_enabled(true);
    let mut daemon_on = DreamingDaemon::new(DreamingPolicy::default());
    let reader_on = FakeReader { observations: obs.clone() };
    let mut sink_on = RecordingSink::default();
    let report_on = daemon_on.run_cycle(&reader_on, &neuron_kit::RecallTraceRewardSource, &mut sink_on);

    // Cycle outcomes must be identical.
    assert_eq!(report_off.candidates_considered, report_on.candidates_considered);
    assert_eq!(report_off.proposals_emitted.len(), report_on.proposals_emitted.len());
    assert_eq!(report_off.suppressed_duplicates, report_on.suppressed_duplicates);
    assert_eq!(report_off.below_threshold, report_on.below_threshold);

    // ON path emitted metrics.
    assert!(capture_sink.count() > 0,
        "telemetry must emit when enabled during conformance test");

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}
