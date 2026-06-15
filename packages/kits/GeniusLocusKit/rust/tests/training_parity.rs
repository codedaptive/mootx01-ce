// training_parity.rs — Rust-side conformance tests for the training
// daemon. Mission GLK-07.
//
// The Swift `TrainingDaemonTests` exercise the same vectors; the
// shared expectations encoded here are:
//
//   - The gate counts the five state-changing verbs (capture, mutate,
//     withdraw, expunge, reanchor) and excludes the six read-only /
//     derived verbs.
//   - Dormant decisions short-circuit and produce empty pass results.
//   - Active decisions fold the audit-log tail into the matrix tier;
//     the live row count after the pass equals the number of capture
//     entries the pipeline saw.
//   - The watermark advances incrementally — a second pass over a
//     larger log only considers the tail entries.
//   - The provisional default matches the decision record (500).

use genius_locus_kit::audit::{
    AuditTier, EntryUUID, UnifiedAuditEntry, UnifiedAuditLog, UnifiedAuditValue, UnifiedAuditVerb,
};
use genius_locus_kit::matrix::{MatrixCalibrationRegistry, MatrixTier};
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
use genius_locus_kit::training::{EnrichmentPipeline, TrainingDaemon, TrainingThresholdGate};
use substrate_types::hlc::HLC;

fn hlc(p: i64) -> HLC {
    HLC::new(p, 0, 1)
}

fn capture_entry(row: EntryUUID, bits: u64, h: HLC) -> UnifiedAuditEntry {
    UnifiedAuditEntry::new(
        AuditTier::Locus,
        h,
        UnifiedAuditVerb::Capture,
        row,
        "tag_bits".to_string(),
        UnifiedAuditValue::Null,
        UnifiedAuditValue::Bitmap(bits),
        None,
    )
}

fn capture_log(n: usize, start_millis: i64) -> UnifiedAuditLog {
    let mut log = UnifiedAuditLog::new();
    for i in 0..n {
        let mut bytes = [0u8; 16];
        // Distinct row id per entry. Encode the index into the bytes
        // so different runs of the same size produce different uuids
        // and the matrix tier sees one (row, hlc) bundle per entry.
        bytes[0] = (i & 0xFF) as u8;
        bytes[1] = ((i >> 8) & 0xFF) as u8;
        let row = EntryUUID(bytes);
        let bits = 1u64 << (i % 8);
        log.add(capture_entry(row, bits, hlc(start_millis + i as i64)));
    }
    log
}

#[test]
fn provisional_default_matches_decision_record() {
    assert_eq!(TrainingThresholdGate::PROVISIONAL_DEFAULT, 500);
    let gate = TrainingThresholdGate::default_gate();
    assert_eq!(gate.transition_threshold, 500);
}

#[test]
fn gate_dormant_below_threshold() {
    let gate = TrainingThresholdGate::new(10);
    let log = capture_log(4, 1_000);
    let d = gate.decide_from_log(&log);
    assert!(!d.is_active());
    assert_eq!(d.transition_count(), 4);
    assert_eq!(d.threshold(), 10);
}

#[test]
fn gate_active_at_threshold() {
    let gate = TrainingThresholdGate::new(5);
    let log = capture_log(5, 1_000);
    let d = gate.decide_from_log(&log);
    assert!(d.is_active());
    assert_eq!(d.transition_count(), 5);
}

#[test]
fn gate_ignores_read_only_verbs() {
    let mut log = UnifiedAuditLog::new();
    let row = EntryUUID([1; 16]);
    let mut t: i64 = 1;
    let mut push = |verb: UnifiedAuditVerb, v: UnifiedAuditValue| {
        let h = HLC::new(t, 0, 1);
        t += 1;
        let entry = UnifiedAuditEntry::new(
            AuditTier::Locus,
            h,
            verb,
            row,
            "f".to_string(),
            UnifiedAuditValue::Null,
            v,
            None,
        );
        log.add(entry);
    };
    // 5 state-changing verbs
    push(UnifiedAuditVerb::Capture, UnifiedAuditValue::Bitmap(0x01));
    push(UnifiedAuditVerb::Mutate, UnifiedAuditValue::Bitmap(0x02));
    push(UnifiedAuditVerb::Withdraw, UnifiedAuditValue::Null);
    push(UnifiedAuditVerb::Expunge, UnifiedAuditValue::Null);
    push(
        UnifiedAuditVerb::Reanchor,
        UnifiedAuditValue::StringValue("anchor".to_string()),
    );
    // 6 read/derived verbs
    push(UnifiedAuditVerb::Recall, UnifiedAuditValue::Null);
    push(UnifiedAuditVerb::Propose, UnifiedAuditValue::Null);
    push(UnifiedAuditVerb::Associate, UnifiedAuditValue::Null);
    push(UnifiedAuditVerb::Learn, UnifiedAuditValue::Null);
    push(UnifiedAuditVerb::DreamCompact, UnifiedAuditValue::Null);
    push(UnifiedAuditVerb::Migrate, UnifiedAuditValue::Null);

    assert_eq!(TrainingThresholdGate::transition_count(&log), 5);
    let gate = TrainingThresholdGate::new(5);
    assert!(gate.decide_from_log(&log).is_active());
}

#[test]
fn negative_threshold_clamps_to_zero_and_always_admits() {
    let gate = TrainingThresholdGate::new(-50);
    assert_eq!(gate.transition_threshold, 0);
    let empty = UnifiedAuditLog::new();
    assert!(gate.decide_from_log(&empty).is_active());
}

#[test]
fn enrichment_updates_matrices_from_audit_log() {
    let log = capture_log(8, 1_000);
    let mut tier = MatrixTier::new();
    let mut calibration = MatrixCalibrationRegistry::default();
    let pipeline = EnrichmentPipeline::new();
    let result = pipeline.run(&log, &mut tier, &mut calibration, HLC::new(0, 0, 0));
    assert_eq!(result.transitions_considered, 8);
    assert!(result.f_cells_touched > 0);
    assert_eq!(tier.live_row_count, 8);
    assert!(!tier.field_presence.is_empty());
}

#[test]
fn enrichment_respects_watermark() {
    let initial = capture_log(4, 1_000);
    let mut tier = MatrixTier::new();
    let mut calibration = MatrixCalibrationRegistry::default();
    let pipeline = EnrichmentPipeline::new();
    let first = pipeline.run(&initial, &mut tier, &mut calibration, HLC::new(0, 0, 0));
    assert_eq!(first.transitions_considered, 4);
    let prior = tier.live_row_count;

    let full = capture_log(8, 1_000);
    let second = pipeline.run(&full, &mut tier, &mut calibration, first.high_water_mark);
    assert_eq!(
        second.transitions_considered, 4,
        "second pass should only see the tail entries"
    );
    assert_eq!(tier.live_row_count, prior + 4);
}

#[test]
fn daemon_dormant_below_threshold_does_no_work() {
    let log = capture_log(3, 1_000);
    let mut tier = MatrixTier::new();
    let mut calibration = MatrixCalibrationRegistry::default();
    let mut daemon = TrainingDaemon::new(TrainingThresholdGate::new(10));
    let tick = daemon.run_once(&log, &mut tier, &mut calibration);
    assert!(!tick.decision.is_active());
    assert_eq!(tick.pass_result.transitions_considered, 0);
    assert!(tier.field_presence.is_empty());
    assert_eq!(tier.live_row_count, 0);
}

#[test]
fn daemon_active_at_threshold_fires_pipeline() {
    let log = capture_log(12, 1_000);
    let mut tier = MatrixTier::new();
    let mut calibration = MatrixCalibrationRegistry::default();
    let mut daemon = TrainingDaemon::new(TrainingThresholdGate::new(10));
    let tick = daemon.run_once(&log, &mut tier, &mut calibration);
    assert!(tick.decision.is_active());
    assert_eq!(tick.pass_result.transitions_considered, 12);
    assert_eq!(tier.live_row_count, 12);
}

#[test]
fn daemon_crosses_threshold_between_ticks() {
    // First tick: log has 6 transitions, threshold is 10 → dormant.
    // Second tick: log grows to 14 → active; daemon picks up the
    // whole backlog because the watermark stayed at zero during the
    // dormant tick.
    let mut tier = MatrixTier::new();
    let mut calibration = MatrixCalibrationRegistry::default();
    let mut daemon = TrainingDaemon::new(TrainingThresholdGate::new(10));

    let log_a = capture_log(6, 1_000);
    let tick_a = daemon.run_once(&log_a, &mut tier, &mut calibration);
    assert!(!tick_a.decision.is_active());
    assert_eq!(tier.live_row_count, 0);
    assert_eq!(daemon.watermark(), HLC::new(0, 0, 0));

    let log_b = capture_log(14, 1_000);
    let tick_b = daemon.run_once(&log_b, &mut tier, &mut calibration);
    assert!(tick_b.decision.is_active());
    assert_eq!(tier.live_row_count, 14);
    assert!(daemon.watermark() > HLC::new(0, 0, 0));
}

#[test]
fn daemon_reset_watermark_restarts_scan() {
    let log = capture_log(10, 1_000);
    let mut tier = MatrixTier::new();
    let mut calibration = MatrixCalibrationRegistry::default();
    let mut daemon = TrainingDaemon::new(TrainingThresholdGate::new(5));

    let first = daemon.run_once(&log, &mut tier, &mut calibration);
    assert_eq!(first.pass_result.transitions_considered, 10);
    assert!(daemon.watermark() > HLC::new(0, 0, 0));

    daemon.reset_watermark();
    assert_eq!(daemon.watermark(), HLC::new(0, 0, 0));
    // After reset a second pass over the same log should re-consider
    // every entry. The matrix tier double-counts because the caller
    // intentionally asked for a re-scan — `reset_watermark` is for
    // re-folding after a snapshot restore, not for tick replay.
    let second = daemon.run_once(&log, &mut tier, &mut calibration);
    assert_eq!(second.pass_result.transitions_considered, 10);
    assert_eq!(tier.live_row_count, 20);
}
