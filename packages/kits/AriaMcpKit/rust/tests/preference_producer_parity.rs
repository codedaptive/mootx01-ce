// preference_producer_parity.rs
//
// Conformance + behaviour coverage for the preference PRODUCER — the Rust mirror
// of Swift `PreferenceProducerTests.swift`. The producer is the cadence wrapper
// (governor duty `preference_duty`) that takes the recall `preference` score
// column from DARK to LIVE: nothing previously fitted per-drawer Bradley-Terry
// preference strengths and registered the PreferenceStore the matrixAware/
// unionBest recall reads. It is the SIBLING of the graph-centrality producer.
//
// Proofs (mirroring the Swift suite case-for-case):
//   - faithful-wrapper: preference_outcomes + compute_preference_scores equal a
//     DIRECT neuron_kit::learned_preference call on the same records;
//   - structure sanity: an endorsed drawer outranks a dismissed one;
//   - outcome shaping: surfaced+used → endorsement, surfaced+passed → dismissal;
//   - C-16 totality: an estate with no recall traces yields an empty store;
//   - cadence: the producer fires on the first tick and respects its interval;
//   - end-to-end: after a tick, a unionBest+matrixAware recall reads a non-zero
//     `preference` column for an endorsed drawer (dark→live, proving registration
//     on the coord).

use std::sync::Arc;
use std::time::{Duration, UNIX_EPOCH};

use aria_mcp::autonomic_governor::AutonomicGovernor;
use aria_mcp::estate_registry::EstateRegistry;
use aria_mcp::preference_producer::{
    compute_preference_scores, preference_outcomes, PreferenceCache, PreferenceRecord,
};
use genius_locus_kit::recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallScoring, PreferenceStore,
};
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::estate_types::LatticeAnchor;
use locus_kit::filter::{Filter, RecallFrame};
use locus_kit::frames::CaptureFrame;
use locus_kit::recall_trace_item::RecallTraceItem;

const NOW: i64 = 1_700_000_000;
// ISO8601 instant of NOW (2023-11-14T22:13:20Z) and the epoch-floor `since`,
// matching the governor's epoch_secs_to_iso8601 output and the duty's window.
const NOW_ISO: &str = "2023-11-14T22:13:20Z";
const SINCE_FLOOR: &str = "0000-01-01T00:00:00Z";

// ── Harness ────────────────────────────────────────────────────────────────────

fn cap_frame(content: &str) -> CaptureFrame {
    CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "preference",
        LatticeAnchor::udc("0"),
        "preference-tests",
        "test-embed-v1",
    )
}

/// Capture a drawer through the coordinator and return its generated id.
fn capture(registry: &EstateRegistry, content: &str) -> String {
    let coord = registry.coord.lock().unwrap();
    coord
        .capture(&registry.default.handle, cap_frame(content), NOW)
        .expect("capture")
        .id
}

/// Run an EXTERNAL recall with a trace budget so the surfaced drawers get
/// recall-trace rows written (the reward-cycle input the producer reads). All
/// trace rows start unused.
fn recall_writing_traces(registry: &EstateRegistry, trace_limit: usize) {
    let coord = registry.coord.lock().unwrap();
    let h = &registry.default.handle;
    let req = GLKRecallRequest::new(RecallFrame::new(vec![Filter::Unconfirmed]))
        .with_mode(GLKRecallMode::UnionBest)
        .with_scoring(GLKRecallScoring::MatrixAware)
        .with_limit(50)
        .external()
        .with_trace_limit(trace_limit);
    coord.recall_scored(h, req, NOW).expect("recall writing traces");
}

/// Mark the picked drawer's trace rows used (the user's pick).
fn mark_used(registry: &EstateRegistry, target: &str) {
    let coord = registry.coord.lock().unwrap();
    coord
        .mark_recall_used(&registry.default.handle, target, SINCE_FLOOR, NOW_ISO)
        .expect("mark_recall_used");
}

/// The store the producer WOULD register, built from the same reads + outcome
/// shaping + fitter the duty uses. Used by the pure proofs.
fn produced_store(registry: &EstateRegistry) -> (PreferenceCache, Vec<PreferenceRecord>) {
    let coord = registry.coord.lock().unwrap();
    let traces = coord
        .recent_recall_traces(&registry.default.handle, SINCE_FLOOR, NOW_ISO)
        .expect("recent_recall_traces");
    let records = preference_outcomes(&traces);
    let scores = compute_preference_scores(&records).expect("learned_preference");
    (PreferenceCache::new(scores), records)
}

// ── Faithful wrapper (the conformance proof) ────────────────────────────────────

/// The producer's store MUST equal a direct neuron_kit::learned_preference call
/// on the producer's own records — bit-identical f32. Proves the producer is a
/// faithful cadence wrapper of the gated Bradley-Terry fitter and reinvents no
/// math (I-17). Also the cross-port contract: the Swift producer fits the same
/// strengths from the same records.
#[test]
fn producer_equals_direct_learned_preference() {
    let registry = EstateRegistry::new_inmemory();
    let picked = capture(&registry, "picked memory");
    let _ = capture(&registry, "passed over one");
    let _ = capture(&registry, "passed over two");
    recall_writing_traces(&registry, 50);
    mark_used(&registry, &picked);

    let (store, records) = produced_store(&registry);
    assert!(!records.is_empty(), "trace history must yield curation records");

    // Direct oracle call on the producer's records.
    let tuples: Vec<(String, i64, i64)> = records
        .iter()
        .map(|r| (r.label.clone(), r.endorsements, r.dismissals))
        .collect();
    let strengths = neuron_kit::learned_preference(&tuples).expect("direct learned_preference");
    let mut expected = std::collections::HashMap::new();
    for s in strengths {
        expected.insert(s.label, s.strength as f32);
    }

    for record in &records {
        let exp = expected.get(&record.label).copied().unwrap_or(0.0);
        assert_eq!(
            store.preference_score(&record.label),
            exp,
            "stored strength for {} must equal the direct learned_preference strength",
            record.label
        );
    }
}

// ── Structure sanity ────────────────────────────────────────────────────────────

/// A drawer surfaced AND used (endorsed) outranks a drawer surfaced and passed
/// over (dismissed) — the Bradley-Terry behaviour the fitter guarantees,
/// surfaced through the producer.
#[test]
fn endorsed_outscores_dismissed() {
    let registry = EstateRegistry::new_inmemory();
    let endorsed = capture(&registry, "the drawer the user picks");
    let dismissed = capture(&registry, "the drawer the user ignores");
    recall_writing_traces(&registry, 50);
    mark_used(&registry, &endorsed);

    let (store, _) = produced_store(&registry);
    assert!(
        store.preference_score(&endorsed) > store.preference_score(&dismissed),
        "the endorsed drawer must carry a higher preference strength than the dismissed one"
    );
}

// ── Outcome shaping ─────────────────────────────────────────────────────────────

/// preference_outcomes maps surfaced+used → endorsement and surfaced+passed →
/// dismissal, one record per distinct target, sorted ascending by label. The
/// implicit relevance signal (C-15): what the user picked vs ignored.
#[test]
fn outcome_shaping_counts_correctly() {
    let traces = vec![
        RecallTraceItem::new("t1", "A", NOW_ISO, None, RecallTraceItem::FLAG_USED),
        RecallTraceItem::new("t2", "A", NOW_ISO, None, RecallTraceItem::FLAG_USED),
        RecallTraceItem::new("t3", "A", NOW_ISO, None, 0),
        RecallTraceItem::new("t4", "B", NOW_ISO, None, 0),
    ];
    let records = preference_outcomes(&traces);
    assert_eq!(
        records,
        vec![
            PreferenceRecord { label: "A".into(), endorsements: 2, dismissals: 1 },
            PreferenceRecord { label: "B".into(), endorsements: 0, dismissals: 1 },
        ]
    );
}

// ── C-16 totality ───────────────────────────────────────────────────────────────

/// An estate with no recall traces yields an empty store; every score is 0.0.
#[test]
fn empty_trace_estate_registers_zero_store() {
    let registry = EstateRegistry::new_inmemory();
    let (store, records) = produced_store(&registry);
    assert!(records.is_empty());
    assert_eq!(store.preference_score("nonexistent"), 0.0);
    assert_eq!(store.count(), 0);
}

// ── Cadence ─────────────────────────────────────────────────────────────────────

/// The producer fires on the first tick (last-fired marker is None).
#[test]
fn fires_on_first_tick() {
    let registry = EstateRegistry::new_inmemory();
    let mut governor = AutonomicGovernor::new(
        Arc::clone(&registry.coord),
        registry.default.handle,
        Arc::clone(&registry.default.store),
    );
    governor.set_preference_cadence_ms(0); // every tick
    let report = governor.tick(UNIX_EPOCH);
    assert!(report.preference_fired, "must fire on the first tick");
}

/// The producer respects its cadence: first fires, before-interval skips,
/// at-boundary fires. Default cadence is 600 s (10 min).
#[test]
fn respects_cadence() {
    let registry = EstateRegistry::new_inmemory();
    let mut governor = AutonomicGovernor::new(
        Arc::clone(&registry.coord),
        registry.default.handle,
        Arc::clone(&registry.default.store),
    );
    let first = governor.tick(UNIX_EPOCH);
    assert!(first.preference_fired, "first tick fires");
    let early = governor.tick(UNIX_EPOCH + Duration::from_secs(1));
    assert!(!early.preference_fired, "1 s < 600 s → skip");
    let due = governor.tick(UNIX_EPOCH + Duration::from_secs(600));
    assert!(due.preference_fired, "600 s elapsed → fires");
}

// ── End-to-end: dark → live (proves registration) ───────────────────────────────

/// After the producer tick scans an estate with recall-trace reward history, a
/// unionBest+matrixAware recall reads a NON-ZERO `preference` column for an
/// endorsed drawer. Closes the dark-column gap and proves the duty REGISTERED the
/// store on the coordinator (the recall path reads `preference_store(handle)`).
#[test]
fn recall_reads_live_preference_column() {
    let registry = EstateRegistry::new_inmemory();
    let endorsed = capture(&registry, "endorsed hub memory");
    let _ = capture(&registry, "dismissed spoke one");
    let _ = capture(&registry, "dismissed spoke two");
    // Seed reward history: surface all, the user picks the endorsed drawer.
    recall_writing_traces(&registry, 50);
    mark_used(&registry, &endorsed);

    // Drive the producer via a governor tick (cadence 0 → fires now).
    let mut governor = AutonomicGovernor::new(
        Arc::clone(&registry.coord),
        registry.default.handle,
        Arc::clone(&registry.default.store),
    );
    governor.set_preference_cadence_ms(0);
    let report = governor.tick(UNIX_EPOCH + Duration::from_secs(NOW as u64));
    assert!(report.preference_fired, "producer must fire");

    // The producer registered the store on the shared coordinator — recall it.
    let coord = registry.coord.lock().unwrap();
    let h = &registry.default.handle;
    let req = GLKRecallRequest::new(RecallFrame::new(vec![Filter::Unconfirmed]))
        .with_mode(GLKRecallMode::UnionBest)
        .with_scoring(GLKRecallScoring::MatrixAware)
        .with_limit(50);
    let result = coord.recall_scored(h, req, NOW + 10).expect("recall");

    let endorsed_hit = result
        .hits
        .iter()
        .find(|hit| hit.id == endorsed)
        .expect("the endorsed drawer must be recalled");
    assert!(
        endorsed_hit.score.preference > 0.0,
        "the preference column must be live (non-zero) for the endorsed drawer after the producer ran"
    );
}
