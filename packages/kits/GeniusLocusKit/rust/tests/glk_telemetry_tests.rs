//! GeniusLocusKit self-report telemetry integration tests — GLK_ROLLUPS_001.
//!
//! Mirrors the Swift suite in
//! Tests/GeniusLocusKitTests/GeniusLocusKitTelemetryTests.swift.
//! Section numbers correspond to the Swift suites:
//!
//!   §1 Disabled gate:       no metric emitted when monitoring is OFF.
//!   §2 Mount-state transitions: open emits mounted, close emits unmounted.
//!   §3 Provision:           provision metric with kind tag.
//!   §4 Lifecycle:           quiesce emits quiesced; drain emits draining + quiesced.
//!   §5 Noun count:          open emits noun_count=0 for a fresh estate.
//!   §6 Verb error:          stale handle (close on already-closed) does NOT emit verb_error.
//!   §7 Conformance gate:    estate state identical with monitoring ON vs OFF.
//!
//! ISOLATION STRATEGY
//! These tests manipulate the global Intellectus singleton (enabled flag +
//! installed sink). Rust integration tests run in parallel by default.
//!
//! Solution: all tests that touch the singleton acquire GLOBAL_LOCK for
//! their entire duration, using the same pattern as NeuronKit's
//! neuronkit_telemetry_tests.rs — a static OnceLock<Mutex<()>> with
//! poison-error recovery. This is the Rust parallel of the Swift
//! `.serialized` suite trait + `withIntellectusLock()` pattern.
//!
//! Every test that acquires the lock restores Intellectus to
//! disabled + NoOpSink before releasing, so the singleton is clean
//! for the next test regardless of execution order.

use std::sync::{Arc, Mutex, OnceLock};

use genius_locus_kit::coordinator::{
    EstateCoordinator, EstateKind, EstateMountState, EstateProvisionParams,
    GeniusLocusKitError, SyncMode,
};
use corpus_kit::corpus::EmbeddingModelConfig;
use intellectus_lib::{Intellectus, NoOpSink, StatSample, StatsSink};
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::OwnerCredentials;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::storage::Storage;
use uuid::Uuid;

// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────

// MARK: - Process-wide serialisation lock

/// All tests that touch the Intellectus singleton acquire this lock.
/// Mirrors the Swift `withIntellectusLock()` FIFO actor mutex pattern.
/// Poison-error recovery via `into_inner()` ensures subsequent tests run
/// even if a previous test panicked while holding the lock.
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
/// Mirrors Swift `CapturingSink` in GeniusLocusKitTelemetryTests.swift.
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
        self.samples.lock().unwrap().iter()
            .filter(|s| matches!(s, StatSample::Metric { name: n, .. } if n == name))
            .count()
    }

    /// Return all samples with the given metric name.
    fn all_named(&self, name: &str) -> Vec<StatSample> {
        self.samples.lock().unwrap().iter()
            .filter(|s| matches!(s, StatSample::Metric { name: n, .. } if n == name))
            .cloned()
            .collect()
    }
}

impl StatsSink for CapturingSink {
    fn receive(&self, sample: StatSample) {
        self.samples.lock().unwrap().push(sample);
    }
}

// MARK: - Storage helpers

const NOW: i64 = 1_700_000_000;

/// Create a paired (DrawerStore, Storage) from a single InMemoryStorage so
/// one in-memory instance backs both the LocusKit estate and the sub-stores.
/// Mirrors the Swift `makeStorage()` helper in the test suite.
fn make_stores() -> (Arc<dyn DrawerStore>, Arc<dyn Storage>) {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let store = Arc::new(
        InMemoryDrawerStore::with_storage(Arc::clone(&storage), NOW, None).unwrap(),
    );
    (store as Arc<dyn DrawerStore>, storage as Arc<dyn Storage>)
}

fn test_owner() -> OwnerCredentials {
    OwnerCredentials {
        owner_identifier: "test-owner".to_string(),
    }
}

fn locus_only_params(name: &str) -> EstateProvisionParams {
    EstateProvisionParams {
        estate_name: name.to_string(),
        kind: EstateKind::LocusOnly,
        zoom_window_low: 1,
        zoom_window_high: 10,
        framework_profile: "Test".to_string(),
        sync_mode: SyncMode::None,
    }
}

// MARK: - §1 Disabled gate

/// open emits nothing when monitoring is OFF. Mirrors Swift
/// §1.test_openEmitsNothingWhenDisabled.
#[test]
fn open_emits_nothing_when_disabled() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(false);

    let (store, storage) = make_stores();
    let mut coord = EstateCoordinator::new();
    let _ = coord.provision(
        store, storage, None,
        test_owner(),
        locus_only_params("test"),
        vec![EmbeddingModelConfig::Deterministic],
    );

    assert_eq!(sink.count(), 0,
        "open must not emit when monitoring is disabled");

    Intellectus::install(Arc::new(NoOpSink));
}

/// close emits nothing when monitoring is OFF. Mirrors Swift
/// §1.test_closeEmitsNothingWhenDisabled.
#[test]
fn close_emits_nothing_when_disabled() {
    let _guard = global_lock();
    // First open with monitoring off, then close with monitoring off.
    Intellectus::set_enabled(false);
    let (store, storage) = make_stores();
    let mut coord = EstateCoordinator::new();
    let handle = coord.provision(
        store, storage, None,
        test_owner(),
        locus_only_params("test"),
        vec![EmbeddingModelConfig::Deterministic],
    ).unwrap();

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(false);

    let _ = coord.close(&handle);

    assert_eq!(sink.count(), 0,
        "close must not emit when monitoring is disabled");

    Intellectus::install(Arc::new(NoOpSink));
}

/// provision emits nothing when monitoring is OFF. Mirrors Swift
/// §1.test_provisionEmitsNothingWhenDisabled.
#[test]
fn provision_emits_nothing_when_disabled() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(false);

    let (store, storage) = make_stores();
    let mut coord = EstateCoordinator::new();
    let _ = coord.provision(
        store, storage, None,
        test_owner(),
        locus_only_params("test"),
        vec![EmbeddingModelConfig::Deterministic],
    );

    assert_eq!(sink.count(), 0,
        "provision must not emit when monitoring is disabled");

    Intellectus::install(Arc::new(NoOpSink));
}

/// quiesce emits nothing when monitoring is OFF. Mirrors Swift
/// §1.test_quiesceEmitsNothingWhenDisabled.
#[test]
fn quiesce_emits_nothing_when_disabled() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let (store, storage) = make_stores();
    let mut coord = EstateCoordinator::new();
    let handle = coord.provision(
        store, storage, None,
        test_owner(),
        locus_only_params("test"),
        vec![EmbeddingModelConfig::Deterministic],
    ).unwrap();

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(false);
    let _ = coord.quiesce(&handle);

    assert_eq!(sink.count(), 0,
        "quiesce must not emit when monitoring is disabled");

    Intellectus::install(Arc::new(NoOpSink));
}

// MARK: - §2 Mount-state transitions

/// open emits a mounted transition. Mirrors Swift
/// §2.test_openEmitsMountedTransition.
#[test]
fn open_emits_mounted_transition() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let (store, _storage) = make_stores();
    let mut coord = EstateCoordinator::new();
    let owner = test_owner();
    let _ = coord.open(store, owner, 1, 10);

    let transitions = sink.all_named("geniuslocus.estate.mount_state_transition");
    let mounted = transitions.iter().find(|s| {
        if let StatSample::Metric { tags, .. } = s {
            tags.get("state").map(|v| v.as_str()) == Some("mounted")
        } else { false }
    });
    assert!(mounted.is_some(), "open must emit a mounted transition");

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// close emits an unmounted transition. Mirrors Swift
/// §2.test_closeEmitsUnmountedTransition.
#[test]
fn close_emits_unmounted_transition() {
    let _guard = global_lock();
    // Open with monitoring off so setup metrics don't mix with the close metric.
    Intellectus::set_enabled(false);
    let (store, storage) = make_stores();
    let mut coord = EstateCoordinator::new();
    let handle = coord.provision(
        store, storage, None,
        test_owner(),
        locus_only_params("test"),
        vec![EmbeddingModelConfig::Deterministic],
    ).unwrap();

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);
    let _ = coord.close(&handle);

    let transitions = sink.all_named("geniuslocus.estate.mount_state_transition");
    let unmounted = transitions.iter().find(|s| {
        if let StatSample::Metric { tags, .. } = s {
            tags.get("state").map(|v| v.as_str()) == Some("unmounted")
        } else { false }
    });
    assert!(unmounted.is_some(), "close must emit an unmounted transition");

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

// MARK: - §3 Provision

/// provision emits a provision metric with the correct kind tag. Mirrors Swift
/// §3.test_provisionEmitsProvisionMetricWithKindTag.
#[test]
fn provision_emits_provision_metric_with_kind_tag_locus_only() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let (store, storage) = make_stores();
    let mut coord = EstateCoordinator::new();
    let _ = coord.provision(
        store, storage, None,
        test_owner(),
        locus_only_params("test"),
        vec![EmbeddingModelConfig::Deterministic],
    );

    let provision_metrics = sink.all_named("geniuslocus.estate.provision");
    assert_eq!(provision_metrics.len(), 1,
        "provision must emit exactly 1 provision metric; got {}", provision_metrics.len());

    if let Some(StatSample::Metric { tags, .. }) = provision_metrics.first() {
        assert_eq!(tags.get("kind").map(|v| v.as_str()), Some("LocusOnly"),
            "kind tag must be 'LocusOnly'; got {:?}", tags.get("kind"));
    } else {
        panic!("no provision metric emitted");
    }

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// Two provision calls emit two provision metrics. Mirrors Swift
/// §3.test_twoProvisionCallsEmitTwoMetrics.
#[test]
fn two_provision_calls_emit_two_metrics() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let (store1, storage1) = make_stores();
    let (store2, storage2) = make_stores();
    let mut coord = EstateCoordinator::new();
    let _ = coord.provision(
        store1, storage1, None,
        test_owner(),
        locus_only_params("estate-1"),
        vec![EmbeddingModelConfig::Deterministic],
    );
    let _ = coord.provision(
        store2, storage2, None,
        test_owner(),
        locus_only_params("estate-2"),
        vec![EmbeddingModelConfig::Deterministic],
    );

    assert_eq!(sink.count_named("geniuslocus.estate.provision"), 2,
        "two provision calls must emit 2 provision metrics");

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

// MARK: - §4 Lifecycle

/// quiesce emits a quiesced transition. Mirrors Swift
/// §4.test_quiesceEmitsQuiescedTransition.
#[test]
fn quiesce_emits_quiesced_transition() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let (store, storage) = make_stores();
    let mut coord = EstateCoordinator::new();
    let handle = coord.provision(
        store, storage, None,
        test_owner(),
        locus_only_params("test"),
        vec![EmbeddingModelConfig::Deterministic],
    ).unwrap();

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);
    coord.quiesce(&handle).unwrap();

    let transitions = sink.all_named("geniuslocus.estate.mount_state_transition");
    let quiesced = transitions.iter().find(|s| {
        if let StatSample::Metric { tags, .. } = s {
            tags.get("state").map(|v| v.as_str()) == Some("quiesced")
        } else { false }
    });
    assert!(quiesced.is_some(), "quiesce must emit a quiesced transition");

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// drain emits draining then quiesced transitions. Mirrors Swift
/// §4.test_drainEmitsDrainingThenQuiesced.
#[test]
fn drain_emits_draining_then_quiesced_transitions() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let (store, storage) = make_stores();
    let mut coord = EstateCoordinator::new();
    let handle = coord.provision(
        store, storage, None,
        test_owner(),
        locus_only_params("test"),
        vec![EmbeddingModelConfig::Deterministic],
    ).unwrap();

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);
    coord.drain(&handle).unwrap();

    let transitions = sink.all_named("geniuslocus.estate.mount_state_transition");
    let draining = transitions.iter().find(|s| {
        if let StatSample::Metric { tags, .. } = s {
            tags.get("state").map(|v| v.as_str()) == Some("draining")
        } else { false }
    });
    let quiesced = transitions.iter().find(|s| {
        if let StatSample::Metric { tags, .. } = s {
            tags.get("state").map(|v| v.as_str()) == Some("quiesced")
        } else { false }
    });
    assert!(draining.is_some(), "drain must emit a draining transition");
    assert!(quiesced.is_some(), "drain must emit a quiesced transition after draining");
    assert_eq!(transitions.len(), 2,
        "drain must emit exactly 2 mount-state transitions; got {}", transitions.len());

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

// MARK: - §5 Noun count

/// open emits noun_count=0 for a fresh estate. Mirrors Swift
/// §5.test_openEmitsNounCountZeroForFreshEstate.
#[test]
fn open_emits_noun_count_zero_for_fresh_estate() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let (store, _storage) = make_stores();
    let mut coord = EstateCoordinator::new();
    let _ = coord.open(store, test_owner(), 1, 10);

    let noun_count_metrics = sink.all_named("geniuslocus.estate.noun_count");
    assert_eq!(noun_count_metrics.len(), 1,
        "open must emit exactly 1 noun_count metric; got {}", noun_count_metrics.len());

    if let Some(StatSample::Metric { value, tags, .. }) = noun_count_metrics.first() {
        assert_eq!(*value, 0.0,
            "noun_count must be 0.0 for a fresh estate; got {value}");
        assert!(tags.contains_key("estate_id"),
            "noun_count metric must carry an estate_id tag");
    } else {
        panic!("no noun_count metric emitted");
    }

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

// MARK: - §6 Verb error

/// Closing an already-closed estate raises EstateNotOpen but does NOT emit
/// verb_error (routing error, not a verb-surface error). Mirrors Swift
/// §6.test_staleHandleDoesNotEmitVerbError.
#[test]
fn stale_handle_close_does_not_emit_verb_error() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let (store, storage) = make_stores();
    let mut coord = EstateCoordinator::new();
    let handle = coord.provision(
        store, storage, None,
        test_owner(),
        locus_only_params("test"),
        vec![EmbeddingModelConfig::Deterministic],
    ).unwrap();
    // First close succeeds.
    coord.close(&handle).unwrap();

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    // Second close on the already-closed handle → EstateNotOpen.
    let result = coord.close(&handle);
    assert!(matches!(result, Err(GeniusLocusKitError::EstateNotOpen { .. })),
        "second close must return EstateNotOpen");

    // EstateNotOpen is a routing error, not a verb-surface error.
    // verb_error is only emitted by the verb dispatch path (remap), not
    // by the handle-resolution guard. No metric expected.
    assert_eq!(sink.count_named("geniuslocus.estate.verb_error"), 0,
        "EstateNotOpen from close must NOT emit verb_error; it is a routing error not a verb error");

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

// MARK: - §7 Conformance gate

/// Estate state (open_estate_count, mount_state) is identical whether
/// monitoring is ON or OFF. Mirrors Swift §7.test_estateStateIdenticalWithMonitoringOnVsOff.
#[test]
fn estate_state_identical_with_monitoring_on_vs_off() {
    let _guard = global_lock();

    // OFF path.
    Intellectus::set_enabled(false);
    let (store_off, storage_off) = make_stores();
    let mut coord_off = EstateCoordinator::new();
    let handle_off = coord_off.provision(
        store_off, storage_off, None,
        test_owner(),
        locus_only_params("off-estate"),
        vec![EmbeddingModelConfig::Deterministic],
    ).unwrap();
    let count_off = coord_off.open_estate_count();
    let mount_off = coord_off.mount_state(&handle_off);

    // ON path.
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);
    let (store_on, storage_on) = make_stores();
    let mut coord_on = EstateCoordinator::new();
    let handle_on = coord_on.provision(
        store_on, storage_on, None,
        test_owner(),
        locus_only_params("on-estate"),
        vec![EmbeddingModelConfig::Deterministic],
    ).unwrap();
    let count_on = coord_on.open_estate_count();
    let mount_on = coord_on.mount_state(&handle_on);

    assert_eq!(count_off, count_on,
        "open_estate_count must be identical regardless of monitoring state");
    assert_eq!(mount_off, mount_on,
        "mount_state must be identical regardless of monitoring state");
    assert_eq!(mount_on, Some(EstateMountState::Mounted),
        "freshly provisioned estate must be Mounted");

    // ON path emitted metrics.
    assert!(sink.count() > 0,
        "monitoring-on path must emit at least one metric");

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// After provision + quiesce, estate is Quiesced regardless of monitoring. Mirrors Swift
/// §7.test_provisionThenQuiesceIsQuiescedRegardlessOfMonitoring.
#[test]
fn provision_then_quiesce_is_quiesced_regardless_of_monitoring() {
    let _guard = global_lock();

    // OFF path.
    Intellectus::set_enabled(false);
    let (store_off, storage_off) = make_stores();
    let mut coord_off = EstateCoordinator::new();
    let h_off = coord_off.provision(
        store_off, storage_off, None,
        test_owner(),
        locus_only_params("off-quiesce"),
        vec![EmbeddingModelConfig::Deterministic],
    ).unwrap();
    coord_off.quiesce(&h_off).unwrap();
    let state_off = coord_off.mount_state(&h_off);

    // ON path.
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);
    let (store_on, storage_on) = make_stores();
    let mut coord_on = EstateCoordinator::new();
    let h_on = coord_on.provision(
        store_on, storage_on, None,
        test_owner(),
        locus_only_params("on-quiesce"),
        vec![EmbeddingModelConfig::Deterministic],
    ).unwrap();
    coord_on.quiesce(&h_on).unwrap();
    let state_on = coord_on.mount_state(&h_on);

    assert_eq!(state_off, state_on,
        "mount_state after quiesce must be identical regardless of monitoring");
    assert_eq!(state_on, Some(EstateMountState::Quiesced));

    // ON path emitted metrics.
    assert!(sink.count() > 0,
        "monitoring-on path must emit at least one metric");

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

// MARK: - §D6-counters: storeError dark counters (gate-2 chain sentence)

/// The dense-lane storeError chain COUNTER half (status + COUNTER + no fake
/// evidence). Lives in THIS binary — not recall_scored_parity — because the
/// global Intellectus enable would crosstalk with that binary's parallel
/// tests and weaken the force-proof; here the global_lock serializes and the
/// sink captures only this test's emissions.
#[test]
fn dense_store_error_emits_dark_and_store_error_counters() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(Arc::clone(&sink) as Arc<dyn StatsSink>);
    Intellectus::set_enabled(true);

    use genius_locus_kit::recall::{GLKRecallMode, GLKRecallRequest, GLKRecallScoring};
    use locus_kit::filter::{Filter, RecallFrame};
    use locus_kit::frames::CaptureFrame;
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::estate_types::LatticeAnchor;
    use corpus_kit::Corpus;

    let (store, storage) = make_stores();
    let mut coord = EstateCoordinator::new();
    let h = coord.provision(
        store, storage, None,
        test_owner(),
        locus_only_params("d6-counters"),
        vec![EmbeddingModelConfig::Deterministic],
    ).unwrap();

    let drawer = coord.capture(
        &h,
        CaptureFrame::new(
            "store error counter chain photosynthesis",
            CaptureChannel::Typed,
            "d6-counter-room",
            LatticeAnchor::udc("0"),
            "test-agent",
            "test-embed-v1",
        ),
        1_700_000_000,
    ).expect("capture");

    let corpus = {
        use persistence_kit::inmemory::InMemoryStorage;
        use persistence_kit::{BackendConfiguration, EstateConfiguration, Storage};
        let cfg = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
        let st: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(cfg));
        Arc::new(Corpus::open(st, EmbeddingModelConfig::Deterministic).expect("Corpus::open"))
    };
    corpus.ingest(&drawer.content, &drawer.id, 1_700_000_000).expect("ingest");
    coord.register_corpus(&h, Arc::clone(&corpus));

    // Force storeError on the next float_nearest (single-use test seam).
    *corpus.forced_float_error.lock().unwrap() = Some("forced-d6-counter".to_string());

    let req = GLKRecallRequest::new(RecallFrame::new(vec![Filter::Unconfirmed]))
        .with_mode(GLKRecallMode::UnionBest)
        .with_scoring(GLKRecallScoring::Rrf)
        .with_query_text("photosynthesis store error counter chain")
        .with_limit(5);
    let result = coord.recall_scored(&h, req, 1_700_000_001).expect("recall survives");

    assert_eq!(result.dense_lane_status.as_deref(), Some("dark:storeError"));
    assert!(sink.count_named("glk.recall.dense_lane_dark") >= 1,
        "glk.recall.dense_lane_dark must emit on storeError");
    assert!(sink.count_named("corpus.float_lane.store_error") >= 1,
        "corpus.float_lane.store_error must emit on forced store error");

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}
