// substrate_lib_telemetry_tests.rs
//
// Integration tests for SubstrateLib self-report telemetry.
// Mirrors: Swift/Tests/SubstrateLibTests/SubstrateLibTelemetryTests.swift
//
// ## Test isolation strategy
//
// All tests that touch the `Intellectus` singleton (enabled/disabled gate
// or any emit fn) acquire a process-wide mutex before proceeding. This
// serialises ALL telemetry tests within this binary, preventing race
// conditions on the singleton's global enabled state.
//
// Non-telemetry calls use `ts: 0.0`. Any ts-filtered sink installed in
// one test discards samples with ts != sentinel, so 0.0 emissions from
// parallel non-telemetry test code are silently dropped.
//
// Sentinel ts values match the Swift suite by §:
//   §1 disabled gate  : 100_001.0, 100_002.0
//   §2 enabled gate   : 200_001.0, 200_002.0
//   §3 conformance    : 300_001.0
//   §4 recall         : 400_001.0, 400_002.0
//   §5 mutating verbs : 500_001.0 – 500_004.0
// (§6 audit/write-gate metric-name constants are defined but no
//  §6 telemetry tests exist yet; the helpers have no production callers)
//
// ## Determinism
//
// Timestamps are always caller-supplied. No clock is read inside
// SubstrateLib. Every test that needs telemetry passes a unique
// Double sentinel as `ts`.

use std::sync::{Mutex, OnceLock};

use intellectus_lib::{Intellectus, NoOpSink, StatSample, StatsSink};
use substrate_types::fingerprint256::Fingerprint256;
use substrate_types::hlc::HLC;
use substrate_lib::verbs::{LatticeAnchor, MutationKind, NounType, Substrate};
use substrate_lib::metric;

// ─────────────────────────────────────────────────────────────────
// Process-wide lock (serialises all tests in this binary that touch
// the Intellectus singleton — prevents concurrent enabled/disabled
// writes from racing with sample collection).
// ─────────────────────────────────────────────────────────────────

static GLOBAL_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

fn global_lock() -> &'static Mutex<()> {
    GLOBAL_LOCK.get_or_init(|| Mutex::new(()))
}

// ─────────────────────────────────────────────────────────────────
// Ts-filtered sink: records only samples whose ts == sentinel.
// This discards emissions from parallel non-telemetry verb calls
// (which use ts: 0.0) and from prior test runs still draining.
// ─────────────────────────────────────────────────────────────────

struct TsFilteredSink {
    sentinel: f64,
    samples: Mutex<Vec<StatSample>>,
}

impl TsFilteredSink {
    fn new(sentinel: f64) -> Self {
        TsFilteredSink {
            sentinel,
            samples: Mutex::new(Vec::new()),
        }
    }

    fn drain(&self) -> Vec<StatSample> {
        let mut guard = self.samples.lock().unwrap();
        std::mem::take(&mut *guard)
    }
}

impl StatsSink for TsFilteredSink {
    fn receive(&self, sample: StatSample) {
        if sample.ts() == self.sentinel {
            self.samples.lock().unwrap().push(sample);
        }
    }
}

// ─────────────────────────────────────────────────────────────────
// Test helpers
// ─────────────────────────────────────────────────────────────────

fn fresh_substrate() -> Substrate {
    let estate = 0x1234_5678_9abc_def0_0000_0000_0000_0000u128;
    Substrate::new(estate, HLC::new(0, 0, 1))
}

fn anchor() -> LatticeAnchor {
    LatticeAnchor::new(0x0a0a_0000_0000_0000, 0x1234)
}

fn fp() -> Fingerprint256 {
    Fingerprint256 {
        block0: 0xcafe_babe,
        block1: 0xdead_beef,
        block2: 0,
        block3: 0,
    }
}

// ─────────────────────────────────────────────────────────────────
// § 7 — Metric name constants (no singleton touching)
// ─────────────────────────────────────────────────────────────────

#[test]
fn metric_names_are_correct() {
    assert_eq!(metric::AUDIT_GATE_ADMIT_COUNT, "substratelib.audit_gate.admit_count");
    assert_eq!(metric::AUDIT_GATE_REJECT_COUNT, "substratelib.audit_gate.reject_count");
    assert_eq!(metric::VERB_CAPTURE_COUNT, "substratelib.verb.capture_count");
    assert_eq!(metric::VERB_MUTATE_COUNT, "substratelib.verb.mutate_count");
    assert_eq!(metric::VERB_WITHDRAW_COUNT, "substratelib.verb.withdraw_count");
    assert_eq!(metric::VERB_EXPUNGE_COUNT, "substratelib.verb.expunge_count");
    assert_eq!(metric::VERB_RECALL_COUNT, "substratelib.verb.recall_count");
    assert_eq!(metric::VERB_REANCHOR_COUNT, "substratelib.verb.reanchor_count");
    assert_eq!(metric::WRITE_GATE_ADMITTED_COUNT, "substratelib.write_gate.admitted_count");
    assert_eq!(metric::WRITE_GATE_REJECTED_COUNT, "substratelib.write_gate.rejected_count");
}

// ─────────────────────────────────────────────────────────────────
// § 1 — Disabled gate: no samples emitted
// ─────────────────────────────────────────────────────────────────

#[test]
fn disabled_gate_no_capture_sample() {
    let _guard = global_lock().lock().unwrap();
    let sentinel = 100_001.0_f64;
    let sink = std::sync::Arc::new(TsFilteredSink::new(sentinel));
    Intellectus::set_enabled(false);
    Intellectus::install(sink.clone());

    let mut s = fresh_substrate();
    s.capture(NounType::Drawer, 0, 0, 0, anchor(), fp(), None, None, "test", sentinel).unwrap();

    let samples = sink.drain();
    Intellectus::set_enabled(false);
    Intellectus::install(std::sync::Arc::new(NoOpSink));

    assert!(
        samples.is_empty(),
        "disabled gate should emit zero samples, got {}",
        samples.len()
    );
}

#[test]
fn disabled_gate_no_reanchor_sample() {
    let _guard = global_lock().lock().unwrap();
    let sentinel = 100_002.0_f64;
    let sink = std::sync::Arc::new(TsFilteredSink::new(sentinel));
    Intellectus::set_enabled(false);
    Intellectus::install(sink.clone());

    let mut s = fresh_substrate();
    let id = s.capture(NounType::Drawer, 0, 0, 0, anchor(), fp(), None, None, "test", 0.0).unwrap();
    s.reanchor(id, anchor(), "test", sentinel).unwrap();

    let samples = sink.drain();
    Intellectus::set_enabled(false);
    Intellectus::install(std::sync::Arc::new(NoOpSink));

    assert!(
        samples.is_empty(),
        "disabled gate should emit zero samples, got {}",
        samples.len()
    );
}

// ─────────────────────────────────────────────────────────────────
// § 2 — Enabled gate: samples emitted with correct content
// ─────────────────────────────────────────────────────────────────

#[test]
fn enabled_gate_capture_emits_one_sample() {
    let _guard = global_lock().lock().unwrap();
    let sentinel = 200_001.0_f64;
    let sink = std::sync::Arc::new(TsFilteredSink::new(sentinel));
    Intellectus::set_enabled(true);
    Intellectus::install(sink.clone());

    let mut s = fresh_substrate();
    s.capture(NounType::Drawer, 0, 0, 0, anchor(), fp(), None, None, "test", sentinel).unwrap();

    let samples = sink.drain();
    Intellectus::set_enabled(false);
    Intellectus::install(std::sync::Arc::new(NoOpSink));

    assert_eq!(samples.len(), 1, "expected 1 capture sample");
    match &samples[0] {
        StatSample::Metric { name, value, ts, .. } => {
            assert_eq!(name, metric::VERB_CAPTURE_COUNT);
            assert_eq!(*value, 1.0);
            assert_eq!(*ts, sentinel);
        }
        other => panic!("expected Metric, got {:?}", other),
    }
}

#[test]
fn enabled_gate_reanchor_emits_one_sample() {
    let _guard = global_lock().lock().unwrap();
    let sentinel = 200_002.0_f64;
    let sink = std::sync::Arc::new(TsFilteredSink::new(sentinel));
    Intellectus::set_enabled(true);
    Intellectus::install(sink.clone());

    let mut s = fresh_substrate();
    let id = s.capture(NounType::Drawer, 0, 0, 0, anchor(), fp(), None, None, "test", 0.0).unwrap();
    s.reanchor(id, anchor(), "test", sentinel).unwrap();

    let samples = sink.drain();
    Intellectus::set_enabled(false);
    Intellectus::install(std::sync::Arc::new(NoOpSink));

    assert_eq!(samples.len(), 1, "expected 1 reanchor sample");
    match &samples[0] {
        StatSample::Metric { name, ts, .. } => {
            assert_eq!(name, metric::VERB_REANCHOR_COUNT);
            assert_eq!(*ts, sentinel);
        }
        other => panic!("expected Metric, got {:?}", other),
    }
}

// ─────────────────────────────────────────────────────────────────
// § 3 — Conformance: disabled→enabled→disabled produces 0→1→0 samples
// ─────────────────────────────────────────────────────────────────

#[test]
fn conformance_gate_three_phase() {
    let _guard = global_lock().lock().unwrap();
    let sentinel = 300_001.0_f64;
    let sink = std::sync::Arc::new(TsFilteredSink::new(sentinel));

    // Phase A: disabled — no sample
    Intellectus::set_enabled(false);
    Intellectus::install(sink.clone());
    let mut s = fresh_substrate();
    s.capture(NounType::Drawer, 0, 0, 0, anchor(), fp(), None, None, "a", sentinel).unwrap();
    let phase_a = sink.drain();

    // Phase B: enabled — one sample
    Intellectus::set_enabled(true);
    let mut s2 = fresh_substrate();
    s2.capture(NounType::Drawer, 0, 0, 0, anchor(), fp(), None, None, "b", sentinel).unwrap();
    let phase_b = sink.drain();

    // Phase C: disabled again — no sample
    Intellectus::set_enabled(false);
    let mut s3 = fresh_substrate();
    s3.capture(NounType::Drawer, 0, 0, 0, anchor(), fp(), None, None, "c", sentinel).unwrap();
    let phase_c = sink.drain();

    Intellectus::install(std::sync::Arc::new(NoOpSink));

    assert!(phase_a.is_empty(), "phase A (disabled) should emit 0 samples");
    assert_eq!(phase_b.len(), 1, "phase B (enabled) should emit 1 sample");
    assert!(phase_c.is_empty(), "phase C (disabled) should emit 0 samples");
}

// ─────────────────────────────────────────────────────────────────
// § 4 — Recall telemetry
// ─────────────────────────────────────────────────────────────────

#[test]
fn recall_emits_result_count_tag() {
    let _guard = global_lock().lock().unwrap();
    let sentinel = 400_001.0_f64;
    let sink = std::sync::Arc::new(TsFilteredSink::new(sentinel));
    Intellectus::set_enabled(true);
    Intellectus::install(sink.clone());

    let mut s = fresh_substrate();
    s.capture(NounType::Drawer, 0, 0, 0, anchor(), fp(), None, None, "a", 0.0).unwrap();
    s.capture(NounType::Drawer, 0, 0, 0, anchor(), fp(), None, None, "a", 0.0).unwrap();
    let results = s.recall(|r| r.noun_type == NounType::Drawer, None, sentinel);

    let samples = sink.drain();
    Intellectus::set_enabled(false);
    Intellectus::install(std::sync::Arc::new(NoOpSink));

    assert_eq!(results.len(), 2);
    assert_eq!(samples.len(), 1, "expected 1 recall sample");
    match &samples[0] {
        StatSample::Metric { name, tags, ts, .. } => {
            assert_eq!(name, metric::VERB_RECALL_COUNT);
            assert_eq!(*ts, sentinel);
            assert_eq!(tags.get("result_count"), Some(&"2".to_string()));
        }
        other => panic!("expected Metric, got {:?}", other),
    }
}

#[test]
fn recall_disabled_no_sample() {
    let _guard = global_lock().lock().unwrap();
    let sentinel = 400_002.0_f64;
    let sink = std::sync::Arc::new(TsFilteredSink::new(sentinel));
    Intellectus::set_enabled(false);
    Intellectus::install(sink.clone());

    let mut s = fresh_substrate();
    s.capture(NounType::Drawer, 0, 0, 0, anchor(), fp(), None, None, "a", 0.0).unwrap();
    let _ = s.recall(|r| r.noun_type == NounType::Drawer, None, sentinel);

    let samples = sink.drain();
    Intellectus::set_enabled(false);
    Intellectus::install(std::sync::Arc::new(NoOpSink));

    assert!(samples.is_empty(), "disabled gate should emit 0 recall samples");
}

// ─────────────────────────────────────────────────────────────────
// § 5 — Mutating verb telemetry
// ─────────────────────────────────────────────────────────────────

#[test]
fn mutate_emits_mutation_kind_tag() {
    let _guard = global_lock().lock().unwrap();
    let sentinel = 500_001.0_f64;
    let sink = std::sync::Arc::new(TsFilteredSink::new(sentinel));
    Intellectus::set_enabled(true);
    Intellectus::install(sink.clone());

    let mut s = fresh_substrate();
    // pending → accepted requires trust != verbatim (0)
    let adj_pending: i64 = 1 | (2 << 18); // state=pending, trust=imported
    let id = s.capture(NounType::Proposal, adj_pending, 0, 0, anchor(), fp(), None, None, "a", 0.0).unwrap();
    let adj_accepted: i64 = 3 | (2 << 18); // state=accepted, trust=imported
    s.mutate(id, MutationKind::Confirm, adj_accepted, None, None, "a", sentinel).unwrap();

    let samples = sink.drain();
    Intellectus::set_enabled(false);
    Intellectus::install(std::sync::Arc::new(NoOpSink));

    assert_eq!(samples.len(), 1, "expected 1 mutate sample");
    match &samples[0] {
        StatSample::Metric { name, tags, ts, .. } => {
            assert_eq!(name, metric::VERB_MUTATE_COUNT);
            assert_eq!(*ts, sentinel);
            assert_eq!(tags.get("mutation_kind"), Some(&"confirm".to_string()));
        }
        other => panic!("expected Metric, got {:?}", other),
    }
}

#[test]
fn withdraw_emits_sample() {
    let _guard = global_lock().lock().unwrap();
    let sentinel = 500_002.0_f64;
    let sink = std::sync::Arc::new(TsFilteredSink::new(sentinel));
    Intellectus::set_enabled(true);
    Intellectus::install(sink.clone());

    let mut s = fresh_substrate();
    let id = s.capture(NounType::Drawer, 0, 0, 0, anchor(), fp(), None, None, "a", 0.0).unwrap();
    s.withdraw(id, "a", sentinel).unwrap();

    let samples = sink.drain();
    Intellectus::set_enabled(false);
    Intellectus::install(std::sync::Arc::new(NoOpSink));

    assert_eq!(samples.len(), 1, "expected 1 withdraw sample");
    match &samples[0] {
        StatSample::Metric { name, ts, .. } => {
            assert_eq!(name, metric::VERB_WITHDRAW_COUNT);
            assert_eq!(*ts, sentinel);
        }
        other => panic!("expected Metric, got {:?}", other),
    }
}

#[test]
fn expunge_emits_sample() {
    let _guard = global_lock().lock().unwrap();
    let sentinel = 500_003.0_f64;
    let sink = std::sync::Arc::new(TsFilteredSink::new(sentinel));
    Intellectus::set_enabled(true);
    Intellectus::install(sink.clone());

    let mut s = fresh_substrate();
    let id = s.capture(NounType::Drawer, 0, 0, 0, anchor(), fp(), None, None, "a", 0.0).unwrap();
    s.expunge(id, "test-reason", "a", sentinel).unwrap();

    let samples = sink.drain();
    Intellectus::set_enabled(false);
    Intellectus::install(std::sync::Arc::new(NoOpSink));

    assert_eq!(samples.len(), 1, "expected 1 expunge sample");
    match &samples[0] {
        StatSample::Metric { name, ts, .. } => {
            assert_eq!(name, metric::VERB_EXPUNGE_COUNT);
            assert_eq!(*ts, sentinel);
        }
        other => panic!("expected Metric, got {:?}", other),
    }
}

#[test]
fn reanchor_emits_sample() {
    let _guard = global_lock().lock().unwrap();
    let sentinel = 500_004.0_f64;
    let sink = std::sync::Arc::new(TsFilteredSink::new(sentinel));
    Intellectus::set_enabled(true);
    Intellectus::install(sink.clone());

    let mut s = fresh_substrate();
    let id = s.capture(NounType::Drawer, 0, 0, 0, anchor(), fp(), None, None, "a", 0.0).unwrap();
    let new_anchor = LatticeAnchor::new(0x0b0b_0000_0000_0000, 0x5678);
    s.reanchor(id, new_anchor, "a", sentinel).unwrap();

    let samples = sink.drain();
    Intellectus::set_enabled(false);
    Intellectus::install(std::sync::Arc::new(NoOpSink));

    assert_eq!(samples.len(), 1, "expected 1 reanchor sample");
    match &samples[0] {
        StatSample::Metric { name, ts, .. } => {
            assert_eq!(name, metric::VERB_REANCHOR_COUNT);
            assert_eq!(*ts, sentinel);
        }
        other => panic!("expected Metric, got {:?}", other),
    }
}
