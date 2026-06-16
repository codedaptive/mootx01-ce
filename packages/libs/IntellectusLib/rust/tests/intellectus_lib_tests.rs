//! IntellectusLib conformance tests.
//!
//! Mirrors the Swift suite in Tests/IntellectusLibTests/IntellectusLibTests.swift.
//! Section numbers correspond to the Swift suites:
//!
//!   §1 Gating: disabled → closure never evaluated
//!   §2 Gating: enabled → sink receives exact sample
//!   §3 NoOpSink discard is safe
//!   §4 Thread safety — concurrent install and set_enabled
//!   §5 StatSample accessors
//!   §6 EventKind exhaustiveness
//!   §7 Performance gate — off-path cost

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use intellectus_lib::{
    EventKind, IntellectusHolder, NoOpSink, StatSample, StatsSink, report,
    Intellectus,
};

// MARK: - Helper: counting sink

/// Records every sample received. Thread-safe via Mutex.
struct CountingSink {
    received: Mutex<Vec<StatSample>>,
}

impl CountingSink {
    fn new() -> Self {
        CountingSink {
            received: Mutex::new(Vec::new()),
        }
    }

    fn count(&self) -> usize {
        self.received.lock().unwrap().len()
    }

    fn first_clone(&self) -> Option<StatSample> {
        self.received.lock().unwrap().first().cloned()
    }
}

impl StatsSink for CountingSink {
    fn receive(&self, sample: StatSample) {
        self.received.lock().unwrap().push(sample);
    }
}

// MARK: - §1 Gating: disabled → closure never evaluated

#[test]
fn closure_not_evaluated_when_disabled() {
    let holder = IntellectusHolder::new();
    assert!(!holder.is_enabled(), "must start disabled");

    let mut closure_call_count = 0usize;
    holder.report(|| {
        closure_call_count += 1;
        StatSample::metric("test.counter".into(), 1.0, Default::default(), 0.0)
    });
    assert_eq!(closure_call_count, 0,
        "payload closure must NOT be evaluated when disabled");
}

#[test]
fn side_effect_counter_stays_zero_after_many_disabled_reports() {
    let holder = IntellectusHolder::new();
    let mut call_count = 0usize;

    for _ in 0..1_000 {
        holder.report(|| {
            call_count += 1;
            StatSample::metric("test.bulk".into(), call_count as f64,
                Default::default(), 0.0)
        });
    }
    assert_eq!(call_count, 0,
        "1000 disabled reports must never invoke the closure");
}

#[test]
fn report_macro_does_not_evaluate_closure_when_disabled() {
    let sink = Arc::new(CountingSink::new());
    // Use a fresh holder via the global — reset state first.
    Intellectus::set_enabled(false);
    // Install counting sink on the global for this test.
    Intellectus::install(Arc::clone(&sink) as Arc<dyn StatsSink>);

    let mut closure_hits = 0usize;
    report!({
        closure_hits += 1;
        StatSample::metric("test.macro.disabled".into(), 1.0,
            Default::default(), 0.0)
    });

    assert_eq!(closure_hits, 0);
    assert_eq!(sink.count(), 0);

    // Restore default no-op sink so other tests are not polluted.
    Intellectus::install(Arc::new(NoOpSink) as Arc<dyn StatsSink>);
}

// MARK: - §2 Gating: enabled → sink receives exact sample

#[test]
fn sink_receives_exact_metric_when_enabled() {
    let holder = IntellectusHolder::new();
    let sink = Arc::new(CountingSink::new());
    holder.install(Arc::clone(&sink) as Arc<dyn StatsSink>);
    holder.set_enabled(true);

    let mut tags = HashMap::new();
    tags.insert("kit".to_string(), "LocusKit".to_string());

    holder.report(|| StatSample::metric(
        "locus.capture.latency_ms".into(),
        42.5,
        tags.clone(),
        1_000_000.0,
    ));

    assert_eq!(sink.count(), 1);
    if let Some(StatSample::Metric { name, value, tags: rtags, ts }) = sink.first_clone() {
        assert_eq!(name, "locus.capture.latency_ms");
        assert!((value - 42.5).abs() < f64::EPSILON);
        assert_eq!(rtags.get("kit").map(String::as_str), Some("LocusKit"));
        assert!((ts - 1_000_000.0).abs() < f64::EPSILON);
    } else {
        panic!("expected StatSample::Metric");
    }
}

#[test]
fn sink_receives_exact_event_when_enabled() {
    let holder = IntellectusHolder::new();
    let sink = Arc::new(CountingSink::new());
    holder.install(Arc::clone(&sink) as Arc<dyn StatsSink>);
    holder.set_enabled(true);

    holder.report(|| StatSample::event(
        EventKind::Capture,
        7,
        "ABCD-1234".to_string(),
        "test-estate".to_string(),
        2_000_000.0,
    ));

    assert_eq!(sink.count(), 1);
    if let Some(StatSample::Event { kind, noun_type, row_id, estate, ts }) = sink.first_clone() {
        assert_eq!(kind, EventKind::Capture);
        assert_eq!(noun_type, 7);
        assert_eq!(row_id, "ABCD-1234");
        assert_eq!(estate, "test-estate");
        assert!((ts - 2_000_000.0).abs() < f64::EPSILON);
    } else {
        panic!("expected StatSample::Event");
    }
}

#[test]
fn closure_is_evaluated_when_enabled() {
    let holder = IntellectusHolder::new();
    let sink = Arc::new(CountingSink::new());
    holder.install(Arc::clone(&sink) as Arc<dyn StatsSink>);
    holder.set_enabled(true);

    let mut closure_call_count = 0usize;
    holder.report(|| {
        closure_call_count += 1;
        StatSample::metric("test.closure.eval".into(), 1.0, Default::default(), 0.0)
    });

    assert_eq!(closure_call_count, 1,
        "payload closure MUST be evaluated exactly once when enabled");
    assert_eq!(sink.count(), 1);
}

#[test]
fn toggle_disabled_after_enabled_stops_emission() {
    let holder = IntellectusHolder::new();
    let sink = Arc::new(CountingSink::new());
    holder.install(Arc::clone(&sink) as Arc<dyn StatsSink>);
    holder.set_enabled(true);

    holder.report(|| StatSample::metric(
        "before.disable".into(), 1.0, Default::default(), 0.0));
    assert_eq!(sink.count(), 1);

    holder.set_enabled(false);
    let mut closure_hits = 0usize;
    holder.report(|| {
        closure_hits += 1;
        StatSample::metric("after.disable".into(), 2.0, Default::default(), 0.0)
    });

    assert_eq!(closure_hits, 0, "closure must not run after disable");
    assert_eq!(sink.count(), 1, "sink count must not increment after disable");
}

// MARK: - §3 NoOpSink discard is safe

#[test]
fn noop_sink_is_callable() {
    let sink = NoOpSink;
    let sample = StatSample::metric(
        "noop.test".into(), 0.0, Default::default(), 0.0);
    // Must not panic or do anything observable.
    sink.receive(sample);
}

#[test]
fn default_installed_sink_is_noop() {
    // Fresh holder — the default must be NoOpSink-equivalent.
    let holder = IntellectusHolder::new();
    holder.set_enabled(true);
    // Enabled + no counting sink = report must not panic.
    holder.report(|| StatSample::metric(
        "default.noop".into(), 1.0, Default::default(), 0.0));
    // Reaching here without panic is the assertion.
}

// MARK: - §4 Thread safety

#[test]
fn concurrent_install_and_set_enabled_do_not_crash_or_race() {
    use std::thread;
    let holder = Arc::new(IntellectusHolder::new());
    let sink = Arc::new(CountingSink::new());
    let mut handles = Vec::new();

    for i in 0..16 {
        let h = Arc::clone(&holder);
        let s = Arc::clone(&sink);
        let handle = thread::spawn(move || {
            for _ in 0..100 {
                if i % 2 == 0 {
                    h.install(Arc::clone(&s) as Arc<dyn StatsSink>);
                } else {
                    h.set_enabled(i % 4 == 1);
                }
                h.report(|| StatSample::metric(
                    "stress.metric".into(),
                    i as f64,
                    Default::default(),
                    0.0,
                ));
            }
        });
        handles.push(handle);
    }

    for h in handles {
        h.join().expect("thread panicked");
    }
    // No assertion on specific count — the test is "did not panic or deadlock."
    // count() returns usize so it is always non-negative; the _ binding
    // suppresses the unused-comparisons lint while documenting intent.
    let _ = sink.count();
}

// MARK: - §5 StatSample accessors

#[test]
fn metric_ts_accessor_returns_correct_value() {
    let s = StatSample::metric("ts.test".into(), 0.0, Default::default(), 999.0);
    assert!((s.ts() - 999.0).abs() < f64::EPSILON);
}

#[test]
fn event_ts_accessor_returns_correct_value() {
    let s = StatSample::event(
        EventKind::Think, 0, "x".into(), "e".into(), 42.0);
    assert!((s.ts() - 42.0).abs() < f64::EPSILON);
}

#[test]
fn metric_with_empty_tags_is_valid() {
    let s = StatSample::metric(
        "empty.tags".into(), 0.0, HashMap::new(), 0.0);
    if let StatSample::Metric { tags, .. } = s {
        assert!(tags.is_empty());
    } else {
        panic!("expected Metric");
    }
}

#[test]
fn metric_with_populated_tags_is_valid() {
    let mut tags = HashMap::new();
    tags.insert("a".to_string(), "1".to_string());
    tags.insert("b".to_string(), "2".to_string());
    let s = StatSample::metric("tagged".into(), 1.0, tags, 0.0);
    if let StatSample::Metric { tags, .. } = s {
        assert_eq!(tags.len(), 2);
        assert_eq!(tags.get("a").map(String::as_str), Some("1"));
        assert_eq!(tags.get("b").map(String::as_str), Some("2"));
    } else {
        panic!("expected Metric");
    }
}

// MARK: - §6 EventKind

#[test]
fn event_kind_as_str_matches_swift_raw_values() {
    // Parity: Swift rawValue "capture" / "think" must match Rust as_str().
    assert_eq!(EventKind::Capture.as_str(), "capture");
    assert_eq!(EventKind::Think.as_str(), "think");
}

#[test]
fn event_kind_equality() {
    assert_eq!(EventKind::Capture, EventKind::Capture);
    assert_eq!(EventKind::Think, EventKind::Think);
    assert_ne!(EventKind::Capture, EventKind::Think);
}

// MARK: - §7 Performance gate

#[test]
fn disabled_report_throughput() {
    let holder = IntellectusHolder::new();
    // Monitoring disabled — the default.

    let start = std::time::Instant::now();
    for i in 0..10_000usize {
        holder.report(|| StatSample::metric(
            "perf.gate".into(),
            i as f64,
            Default::default(),
            0.0,
        ));
    }
    let elapsed = start.elapsed();

    // 10 ms is a generous budget for 10 000 disabled reports.
    // Each should be sub-microsecond; this gate catches gross regressions.
    assert!(
        elapsed.as_millis() < 10,
        "10 000 disabled reports took {} ms — expected < 10 ms",
        elapsed.as_millis()
    );
}

// MARK: - §8 RecentWindowSink — bounded recent window
//
// Mirrors the Swift §8 RecentWindowSink suite.

use intellectus_lib::RecentWindowSink;
use std::sync::atomic::{AtomicUsize, Ordering};

/// A sink that just counts every receive — for forward-sink fidelity tests.
struct CounterSink {
    n: AtomicUsize,
}
impl CounterSink {
    fn new() -> Self {
        CounterSink { n: AtomicUsize::new(0) }
    }
    fn count(&self) -> usize {
        self.n.load(Ordering::SeqCst)
    }
}
impl StatsSink for CounterSink {
    fn receive(&self, _sample: StatSample) {
        self.n.fetch_add(1, Ordering::SeqCst);
    }
}

#[test]
fn window_records_and_snapshots_oldest_first() {
    let window = RecentWindowSink::new(4, None);
    window.receive(StatSample::metric("a".into(), 1.0, HashMap::new(), 1.0));
    window.receive(StatSample::metric("b".into(), 2.0, HashMap::new(), 2.0));
    assert_eq!(window.count(), 2);
    assert_eq!(window.total_received(), 2);
    let snap = window.snapshot();
    assert_eq!(snap.len(), 2);
    assert_eq!(snap[0].ts(), 1.0);
    assert_eq!(snap[1].ts(), 2.0);
}

#[test]
fn bounded_window_evicts_oldest_on_overflow() {
    let window = RecentWindowSink::new(3, None);
    // Push 5 into a 3-slot window: 0 and 1 must be evicted.
    for i in 0..5 {
        window.receive(StatSample::metric("m".into(), i as f64, HashMap::new(), i as f64));
    }
    // Bound holds: never more than capacity retained.
    assert_eq!(window.count(), 3);
    // total_received counts every sample, ignoring eviction.
    assert_eq!(window.total_received(), 5);
    let snap = window.snapshot();
    assert_eq!(snap.len(), 3);
    assert_eq!(snap.first().unwrap().ts(), 2.0); // oldest retained
    assert_eq!(snap.last().unwrap().ts(), 4.0);  // newest
}

#[test]
fn capacity_clamps_to_one() {
    let window = RecentWindowSink::new(0, None);
    assert_eq!(window.capacity(), 1);
    window.receive(StatSample::metric("x".into(), 1.0, HashMap::new(), 1.0));
    window.receive(StatSample::metric("y".into(), 2.0, HashMap::new(), 2.0));
    assert_eq!(window.count(), 1);
    assert_eq!(window.snapshot().first().unwrap().ts(), 2.0);
}

#[test]
fn forward_sink_receives_every_sample() {
    let downstream = Arc::new(CounterSink::new());
    let window = RecentWindowSink::new(2, Some(downstream.clone()));
    // Overflow the window — the forward sink still sees ALL samples.
    for i in 0..5 {
        window.receive(StatSample::metric("f".into(), i as f64, HashMap::new(), i as f64));
    }
    assert_eq!(window.count(), 2);          // bounded
    assert_eq!(downstream.count(), 5);      // all forwarded
}

#[test]
fn empty_window_is_empty() {
    let window = RecentWindowSink::new(8, None);
    assert_eq!(window.count(), 0);
    assert_eq!(window.total_received(), 0);
    assert!(window.snapshot().is_empty());
}

#[test]
fn window_via_gate_enabled_records_disabled_does_not() {
    // Use a fresh holder for deterministic gate state (the global singleton is
    // shared across tests; the per-instance holder isolates this assertion).
    let holder = IntellectusHolder::new();
    let window = Arc::new(RecentWindowSink::new(16, None));
    holder.install(window.clone());

    // FORCE: disabled → no sample recorded.
    holder.set_enabled(false);
    holder.report(|| StatSample::metric("off".into(), 1.0, HashMap::new(), 0.0));
    assert_eq!(window.count(), 0);

    // FORCE: enabled → sample recorded.
    holder.set_enabled(true);
    holder.report(|| StatSample::metric("on".into(), 1.0, HashMap::new(), 1.0));
    assert_eq!(window.count(), 1);
    assert_eq!(window.snapshot().first().unwrap().ts(), 1.0);
}

#[test]
fn concurrent_receive_is_bounded() {
    let window = Arc::new(RecentWindowSink::new(32, None));
    let mut handles = Vec::new();
    for t in 0..8 {
        let w = window.clone();
        handles.push(std::thread::spawn(move || {
            for i in 0..100 {
                w.receive(StatSample::metric(
                    "c".into(), (t * 100 + i) as f64, HashMap::new(), 0.0));
            }
        }));
    }
    for h in handles {
        h.join().unwrap();
    }
    assert_eq!(window.count(), 32);          // bound holds under concurrency
    assert_eq!(window.total_received(), 800);
}
