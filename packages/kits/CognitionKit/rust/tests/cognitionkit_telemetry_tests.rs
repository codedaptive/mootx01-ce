//! CognitionKit self-report telemetry integration tests — cp-cognitionkit-report P2.
//!
//! Mirrors the Swift suite in
//! Tests/CognitionKitTests/CognitionKitTelemetryTests.swift.
//! Section numbers correspond to the Swift suites:
//!
//!   §1 Disabled gate: no metric emitted when monitoring is OFF.
//!   §2 GroundedSynthesis emissions: start + complete pair per run call.
//!   §3 MigrationBenchmark emissions: start + complete pair per run call.
//!   §4 Conformance: output is identical with monitoring ON and OFF (C-Det).
//!
//! ISOLATION STRATEGY
//! These tests manipulate the global Intellectus singleton (enabled flag +
//! installed sink). Rust integration tests run in parallel by default.
//!
//! Solution: all tests that touch the singleton acquire GLOBAL_LOCK for
//! their entire duration, using the same pattern as NeuronKit's
//! neuronkit_telemetry_tests.rs — a static OnceLock<Mutex<()>> with
//! poison-error recovery. This is the Rust parallel of the Swift
//! `.serialized` suite trait + process-wide CognitionTestMutex.
//!
//! Tests that ONLY test precondition guards (empty plans, duplicate names)
//! do not need the lock because those paths return before any emit occurs.

use std::sync::{Arc, Mutex, OnceLock};

use intellectus_lib::{Intellectus, NoOpSink, StatSample, StatsSink};

use cognition_kit::{
    run_grounded_synthesis, run_migration_benchmark,
    BenchmarkOutcome, CorpusEntry, OriginEntry, PlanInput, RecipeSubstrate,
    SubstrateError,
};
use genius_locus_kit::EstateCoordinator;
use locus_kit::{
    drawer_operational::CaptureChannel,
    drawer_store::DrawerStore,
    drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::{LatticeAnchor, OwnerCredentials},
    filter::{Filter, HydrationLevel, Ordering, RecallFrame},
    frames::CaptureFrame,
};
use neuron_kit::RecallFrameTuning;

// Process-wide serialisation lock — same pattern as NeuronKit telemetry tests.
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
        CapturingSink {
            samples: Mutex::new(Vec::new()),
        }
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

// MARK: - Helpers: estate builder

const NOW: i64 = 1_700_000_000;
const METRIC_RECIPE_RUN: &str = "cognitionkit.recipe.run";

/// Build an in-memory EstateCoordinator with the given contents captured.
/// Called BEFORE Intellectus::set_enabled(true) so estate setup does not
/// emit stray metrics into a capturing sink during tests that want to
/// count only recipe-run emissions.
fn coord_with_rows(contents: &[&str]) -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let h = coord
        .open(store, OwnerCredentials::new("owner"), 0, 100)
        .unwrap();
    for c in contents {
        let frame = CaptureFrame::new(
            *c,
            CaptureChannel::Typed,
            "study",
            LatticeAnchor::udc("0"),
            "alice",
            "test-v1",
        );
        coord.capture(&h, frame, NOW).unwrap();
    }
    (coord, h)
}

fn user_confirmed() -> RecallFrame {
    let mut f = RecallFrame::new(vec![Filter::UserConfirmed]);
    f.hydration_level = HydrationLevel::Structured;
    f.ordering = Ordering::ByCaptureTimeDesc;
    f
}

// MARK: - Helpers: FakeSubstrate for MigrationBenchmark

/// Deterministic in-memory substrate for migration_benchmark tests.
struct FakeSubstrate;

impl RecipeSubstrate for FakeSubstrate {
    fn derive_branch(&mut self, plan_name: &str) -> Result<String, SubstrateError> {
        Ok(format!("branch-{}", plan_name))
    }

    fn capture(
        &mut self,
        branch_id: &str,
        content: &str,
        _room: &str,
        _lattice_code: &str,
        _embedding_model_id: &str,
        _sensitivity: i64,
    ) -> Result<String, SubstrateError> {
        Ok(format!("drawer-{}-{}", branch_id, content.len()))
    }

    fn benchmark(
        &mut self,
        _branch_id: &str,
        corpus: &[CorpusEntry],
    ) -> Result<BenchmarkOutcome, SubstrateError> {
        let total = corpus.len();
        Ok(BenchmarkOutcome {
            recall_overlap: if total == 0 { 0.0 } else { 1.0 },
            mean_reciprocal_rank: if total == 0 { 0.0 } else { 1.0 },
            not_found: vec![],
        })
    }
}

fn plan(name: &str) -> PlanInput {
    PlanInput {
        name: name.to_string(),
        room: "study".to_string(),
        lattice_code: "000".to_string(),
        embedding_model_id: "test-v1".to_string(),
        sensitivity: 0,
    }
}

fn origin(contents: &[&str]) -> Vec<OriginEntry> {
    contents
        .iter()
        .enumerate()
        .map(|(i, c)| OriginEntry {
            id: format!("entry-{}", i),
            content: c.to_string(),
        })
        .collect()
}

// MARK: - §1 Disabled gate

/// With monitoring OFF, run_grounded_synthesis must not emit any metrics.
#[test]
fn grounded_synthesis_emits_nothing_when_disabled() {
    let _guard = global_lock();
    // Build estate BEFORE enabling monitoring so setup emissions don't leak.
    let (coord, h) = coord_with_rows(&["hello world"]);

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(false);

    let _ = run_grounded_synthesis(
        &coord,
        &h,
        user_confirmed(),
        RecallFrameTuning::default(),
        NOW,
    );

    assert_eq!(
        sink.count_named(METRIC_RECIPE_RUN),
        0,
        "run_grounded_synthesis must not emit when monitoring is disabled"
    );

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// With monitoring OFF, run_migration_benchmark must not emit any metrics.
#[test]
fn migration_benchmark_emits_nothing_when_disabled() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(false);

    let mut fake = FakeSubstrate;
    let _ = run_migration_benchmark(&mut fake, &[plan("alpha")], &origin(&["content-a"]));

    assert_eq!(
        sink.count_named(METRIC_RECIPE_RUN),
        0,
        "run_migration_benchmark must not emit when monitoring is disabled"
    );

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

// MARK: - §2 GroundedSynthesis emissions

/// One run call emits exactly two cognitionkit.recipe.run metrics:
/// one with status "start" and one with status "complete".
#[test]
fn grounded_synthesis_emits_start_and_complete() {
    let _guard = global_lock();
    // Build estate BEFORE enabling monitoring so setup emissions don't leak.
    let (coord, h) = coord_with_rows(&["hello world"]);

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let _ = run_grounded_synthesis(
        &coord,
        &h,
        user_confirmed(),
        RecallFrameTuning::default(),
        NOW,
    );

    let metrics = sink.all_named(METRIC_RECIPE_RUN);
    assert_eq!(
        metrics.len(),
        2,
        "run_grounded_synthesis must emit exactly 2 metrics; got {}",
        metrics.len()
    );

    let start = metrics.iter().find(|s| {
        if let StatSample::Metric { tags, .. } = s {
            tags.get("status").map(|v| v.as_str()) == Some("start")
                && tags.get("recipe").map(|v| v.as_str()) == Some("grounded_synthesis")
        } else {
            false
        }
    });
    let complete = metrics.iter().find(|s| {
        if let StatSample::Metric { tags, .. } = s {
            tags.get("status").map(|v| v.as_str()) == Some("complete")
                && tags.get("recipe").map(|v| v.as_str()) == Some("grounded_synthesis")
        } else {
            false
        }
    });

    assert!(start.is_some(), "must emit a 'start' metric tagged recipe=grounded_synthesis");
    assert!(complete.is_some(), "must emit a 'complete' metric tagged recipe=grounded_synthesis");

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// Two run calls emit exactly four cognitionkit.recipe.run metrics.
#[test]
fn two_grounded_synthesis_runs_emit_four_metrics() {
    let _guard = global_lock();
    let (coord, h) = coord_with_rows(&["hello world"]);

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let _ = run_grounded_synthesis(&coord, &h, user_confirmed(), RecallFrameTuning::default(), NOW);
    let _ = run_grounded_synthesis(&coord, &h, user_confirmed(), RecallFrameTuning::default(), NOW);

    assert_eq!(
        sink.count_named(METRIC_RECIPE_RUN),
        4,
        "two run calls must emit 4 cognitionkit.recipe.run metrics; got {}",
        sink.count_named(METRIC_RECIPE_RUN)
    );

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// The step_count tag on the complete metric equals the number of recalled
/// drawers (the drawer_count in the returned GroundedOutput).
#[test]
fn grounded_synthesis_step_count_tag_matches_drawer_count() {
    let _guard = global_lock();
    let (coord, h) = coord_with_rows(&["item-one", "item-two", "item-three"]);

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let out = run_grounded_synthesis(
        &coord,
        &h,
        user_confirmed(),
        RecallFrameTuning::default(),
        NOW,
    )
    .expect("run");

    // The complete metric's step_count tag must equal the returned drawer_count.
    let complete = sink.all_named(METRIC_RECIPE_RUN).into_iter().find(|s| {
        if let StatSample::Metric { tags, .. } = s {
            tags.get("status").map(|v| v.as_str()) == Some("complete")
        } else {
            false
        }
    });
    assert!(complete.is_some(), "must emit a complete metric");
    if let Some(StatSample::Metric { tags, value, .. }) = complete {
        let expected = out.drawer_count.to_string();
        assert_eq!(
            tags.get("step_count").map(|v| v.as_str()),
            Some(expected.as_str()),
            "step_count tag must equal drawer_count"
        );
        assert_eq!(
            value,
            out.drawer_count as f64,
            "metric value must equal drawer_count"
        );
    }

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

// MARK: - §3 MigrationBenchmark emissions

/// One run call emits exactly two cognitionkit.recipe.run metrics:
/// one with status "start" and one with status "complete".
#[test]
fn migration_benchmark_emits_start_and_complete() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let mut fake = FakeSubstrate;
    let _ = run_migration_benchmark(&mut fake, &[plan("alpha")], &origin(&["content-a"]));

    let metrics = sink.all_named(METRIC_RECIPE_RUN);
    assert_eq!(
        metrics.len(),
        2,
        "run_migration_benchmark must emit exactly 2 metrics; got {}",
        metrics.len()
    );

    let start = metrics.iter().find(|s| {
        if let StatSample::Metric { tags, .. } = s {
            tags.get("status").map(|v| v.as_str()) == Some("start")
                && tags.get("recipe").map(|v| v.as_str()) == Some("migration_benchmark")
        } else {
            false
        }
    });
    let complete = metrics.iter().find(|s| {
        if let StatSample::Metric { tags, .. } = s {
            tags.get("status").map(|v| v.as_str()) == Some("complete")
                && tags.get("recipe").map(|v| v.as_str()) == Some("migration_benchmark")
        } else {
            false
        }
    });

    assert!(start.is_some(), "must emit a 'start' metric tagged recipe=migration_benchmark");
    assert!(complete.is_some(), "must emit a 'complete' metric tagged recipe=migration_benchmark");

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// The step_count tag on the complete metric equals the number of plans
/// benchmarked (plans.len()).
#[test]
fn migration_benchmark_step_count_tag_matches_plan_count() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let plans = vec![plan("alpha"), plan("beta")];
    let mut fake = FakeSubstrate;
    let _ = run_migration_benchmark(&mut fake, &plans, &origin(&["content-a"]));

    let complete = sink.all_named(METRIC_RECIPE_RUN).into_iter().find(|s| {
        if let StatSample::Metric { tags, .. } = s {
            tags.get("status").map(|v| v.as_str()) == Some("complete")
        } else {
            false
        }
    });
    assert!(complete.is_some(), "must emit a complete metric");
    if let Some(StatSample::Metric { tags, value, .. }) = complete {
        // Two plans were benchmarked → step_count = "2".
        assert_eq!(
            tags.get("step_count").map(|v| v.as_str()),
            Some("2"),
            "step_count must equal plans.len(); got {:?}", tags.get("step_count")
        );
        assert_eq!(value, 2.0, "metric value must equal plans.len()");
    }

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// Empty plans guard fires before any emit — no metrics when plans is empty.
#[test]
fn migration_benchmark_no_emit_when_empty_plans() {
    // No GLOBAL_LOCK needed: the guard returns before any emit call.
    // This test does not touch the singleton.
    let mut fake = FakeSubstrate;
    let err = run_migration_benchmark(&mut fake, &[], &origin(&["content"]));
    // The error is InsufficientBranches — the function returned before emitting.
    assert!(err.is_err(), "empty plans must return an error");
}

// MARK: - §4 Conformance gate (C-Det)

/// run_grounded_synthesis output is identical whether monitoring is ON or OFF.
/// The return value must NOT depend on whether Intellectus is enabled.
#[test]
fn grounded_synthesis_output_identical_with_and_without_telemetry() {
    let _guard = global_lock();
    let (coord_off, h_off) = coord_with_rows(&["the cat sat on the mat", "a dog barked"]);
    let (coord_on, h_on) = coord_with_rows(&["the cat sat on the mat", "a dog barked"]);

    // OFF path.
    Intellectus::set_enabled(false);
    let out_off = run_grounded_synthesis(
        &coord_off,
        &h_off,
        user_confirmed(),
        RecallFrameTuning::default(),
        NOW,
    )
    .expect("off-path run");

    // ON path.
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);
    let out_on = run_grounded_synthesis(
        &coord_on,
        &h_on,
        user_confirmed(),
        RecallFrameTuning::default(),
        NOW,
    )
    .expect("on-path run");

    // Outputs must be structurally identical.
    assert_eq!(
        out_off.drawer_count, out_on.drawer_count,
        "drawer_count must be identical regardless of monitoring state"
    );
    assert_eq!(
        out_off.context.summary, out_on.context.summary,
        "context.summary must be identical regardless of monitoring state"
    );
    assert_eq!(
        out_off.context.patterns, out_on.context.patterns,
        "context.patterns must be identical regardless of monitoring state"
    );

    // ON path emitted metrics (proves the on-path was active).
    assert!(
        sink.count_named(METRIC_RECIPE_RUN) > 0,
        "monitoring-on path must have emitted metrics"
    );

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// run_migration_benchmark output is identical whether monitoring is ON or OFF.
#[test]
fn migration_benchmark_output_identical_with_and_without_telemetry() {
    let _guard = global_lock();
    let plans_vec = vec![plan("flat"), plan("nested")];
    let origin_vec = origin(&["alpha", "beta", "gamma"]);

    // OFF path.
    Intellectus::set_enabled(false);
    let mut fake_off = FakeSubstrate;
    let out_off =
        run_migration_benchmark(&mut fake_off, &plans_vec, &origin_vec).expect("off-path run");

    // ON path.
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);
    let mut fake_on = FakeSubstrate;
    let out_on =
        run_migration_benchmark(&mut fake_on, &plans_vec, &origin_vec).expect("on-path run");

    // CoreReport fields must be identical.
    assert_eq!(
        out_off.winner, out_on.winner,
        "winner must be identical regardless of monitoring state"
    );
    assert_eq!(
        out_off.rankings.len(),
        out_on.rankings.len(),
        "rankings length must be identical"
    );
    assert_eq!(
        out_off.disqualified.len(),
        out_on.disqualified.len(),
        "disqualified length must be identical"
    );
    assert_eq!(
        out_off.plan_results.len(),
        out_on.plan_results.len(),
        "plan_results length must be identical"
    );

    // ON path emitted metrics.
    assert!(
        sink.count_named(METRIC_RECIPE_RUN) > 0,
        "monitoring-on path must have emitted metrics"
    );

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}
