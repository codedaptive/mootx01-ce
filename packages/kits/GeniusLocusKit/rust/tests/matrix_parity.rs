// matrix_parity.rs — Rust-side conformance tests for the matrix tier.
//
// Mission GLK-06. The same canonical vectors that the Swift
// `MatrixTierTests` exercise are used here so the two ports stay
// numerically aligned. Substrate-mathematics §8 and cookbook §6 fix
// the semantics; these tests fix the byte-for-byte expectations.

// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_types::hlc::HLC;

use genius_locus_kit::audit::{
    AuditTier, EntryUUID, UnifiedAuditEntry, UnifiedAuditLog, UnifiedAuditValue,
    UnifiedAuditVerb,
};
use genius_locus_kit::matrix::{
    MatrixCalibrationOutcome, MatrixCalibrationRegistry, MatrixCoOccurKey,
    MatrixFieldCell, MatrixNMF, MatrixPersistenceBackend, MatrixPersistenceMode,
    MatrixTier, MatrixValueCoord, MatrixTemporalKey,
};

fn hlc(p: i64) -> HLC {
    HLC::new(p, 0, 1)
}

fn capture(row: EntryUUID, field: &str, v: UnifiedAuditValue, h: HLC) -> UnifiedAuditEntry {
    UnifiedAuditEntry::new(
        AuditTier::Locus,
        h,
        UnifiedAuditVerb::Capture,
        row,
        field.to_string(),
        UnifiedAuditValue::Null,
        v,
        None,
    )
}

#[test]
fn field_presence_counts_set_bits() {
    let mut tier = MatrixTier::new();
    tier.apply_capture(
        &[("bitmap.adjective".to_string(), 0b1001)],
        &[],
        hlc(10),
        1,
    );
    tier.apply_capture(
        &[("bitmap.adjective".to_string(), 0b1001)],
        &[],
        hlc(11),
        1,
    );
    let bit0 = MatrixFieldCell::new("bitmap.adjective", 0);
    let bit3 = MatrixFieldCell::new("bitmap.adjective", 3);
    let bit1 = MatrixFieldCell::new("bitmap.adjective", 1);
    assert_eq!(tier.field_presence.get(&bit0), Some(&2));
    assert_eq!(tier.field_presence.get(&bit3), Some(&2));
    assert_eq!(tier.field_presence.get(&bit1), None);
    assert_eq!(tier.live_row_count, 2);
    assert!((tier.correlation(&bit0) - 1.0).abs() < 1e-9);
    assert!((tier.correlation(&bit1) - 0.0).abs() < 1e-9);
}

#[test]
fn correlation_derives_from_field_presence() {
    let mut tier = MatrixTier::new();
    tier.apply_capture(&[("bm.x".to_string(), 0b1)], &[], hlc(1), 1);
    tier.apply_capture(&[("bm.x".to_string(), 0b1)], &[], hlc(2), 1);
    tier.apply_capture(&[("bm.x".to_string(), 0b0)], &[], hlc(3), 1);
    let bit0 = MatrixFieldCell::new("bm.x", 0);
    let c = tier.correlation(&bit0);
    assert!((c - 2.0 / 3.0).abs() < 1e-9);
}

#[test]
fn co_occurrence_canonical_symmetric() {
    let mut tier = MatrixTier::new();
    tier.apply_capture(
        &[("bm.a".to_string(), 0b1), ("bm.b".to_string(), 0b10)],
        &[],
        hlc(1),
        1,
    );
    let a = MatrixValueCoord::new("bm.a", UnifiedAuditValue::Bitmap(0b1));
    let b = MatrixValueCoord::new("bm.b", UnifiedAuditValue::Bitmap(0b10));
    let k1 = MatrixCoOccurKey::new(a.clone(), b.clone());
    let k2 = MatrixCoOccurKey::new(b, a);
    assert_eq!(k1, k2);
    assert_eq!(tier.co_occurrence.get(&k1), Some(&1));
    assert_eq!(tier.co_occurrence.len(), 1);
}

#[test]
fn temporal_lag_bucketing() {
    assert_eq!(MatrixTier::lag_bucket_for_minutes(1), 1);
    assert_eq!(MatrixTier::lag_bucket_for_minutes(3), 4);
    assert_eq!(MatrixTier::lag_bucket_for_minutes(9), 16);
    assert_eq!(MatrixTier::lag_bucket_for_minutes(128), 128);

    let mut tier = MatrixTier::new();
    let s = MatrixValueCoord::new("f.x", UnifiedAuditValue::Bitmap(1));
    let t = MatrixValueCoord::new("f.y", UnifiedAuditValue::Bitmap(2));
    tier.apply_temporal_event(s.clone(), t.clone(), 5, 1);
    let key = MatrixTemporalKey {
        source: s.clone(),
        target: t.clone(),
        lag_bucket: 8,
    };
    assert_eq!(tier.temporal_causality.get(&key), Some(&1));
    // Out of window — no effect.
    tier.apply_temporal_event(s, t, 1_000, 1);
    assert_eq!(tier.temporal_causality.len(), 1);
}

#[test]
fn rebuild_from_audit_log_equals_incremental() {
    let row_a = EntryUUID([1; 16]);
    let row_b = EntryUUID([2; 16]);
    let captures: Vec<(EntryUUID, Vec<(String, u64)>, HLC)> = vec![
        (
            row_a,
            vec![("bm.alpha".into(), 0b101), ("bm.beta".into(), 0b10)],
            hlc(100),
        ),
        (
            row_b,
            vec![("bm.alpha".into(), 0b100), ("bm.beta".into(), 0b11)],
            hlc(200),
        ),
    ];

    let mut incremental = MatrixTier::new();
    for (_row, fields, h) in &captures {
        incremental.apply_capture(fields, &[], *h, 1);
    }

    let mut log = UnifiedAuditLog::new();
    for (row, fields, h) in &captures {
        for (path, bm) in fields {
            log.add(capture(*row, path, UnifiedAuditValue::Bitmap(*bm), *h));
        }
    }

    let rebuilt = MatrixTier::rebuild(&log);
    assert_eq!(rebuilt.live_row_count, incremental.live_row_count);
    assert_eq!(rebuilt.field_presence, incremental.field_presence);
    assert_eq!(rebuilt.co_occurrence, incremental.co_occurrence);
}

#[test]
fn in_memory_mode_rebuilds_but_does_not_persist() {
    let mut log = UnifiedAuditLog::new();
    log.add(capture(
        EntryUUID([7; 16]),
        "bm.x",
        UnifiedAuditValue::Bitmap(0b11),
        hlc(1),
    ));
    let backend = MatrixPersistenceBackend::new(MatrixPersistenceMode::InMemory);
    let snap = backend
        .rebuild(&log, MatrixCalibrationRegistry::new())
        .unwrap();
    assert_eq!(snap.tier.live_row_count, 1);
    assert!(backend.load().unwrap().is_none());
}

#[test]
fn snapshotted_mode_round_trips_exactly() {
    let tmp = std::env::temp_dir().join(format!(
        "matrix-snap-{}.bin",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let _cleanup = scopeguard_remove(tmp.clone());

    let mut log = UnifiedAuditLog::new();
    log.add(capture(
        EntryUUID([1; 16]),
        "bm.a",
        UnifiedAuditValue::Bitmap(0b1011),
        hlc(10),
    ));
    log.add(capture(
        EntryUUID([2; 16]),
        "bm.a",
        UnifiedAuditValue::Bitmap(0b0011),
        hlc(20),
    ));
    log.add(capture(
        EntryUUID([2; 16]),
        "bm.b",
        UnifiedAuditValue::Bitmap(0b1100),
        hlc(20),
    ));

    let backend = MatrixPersistenceBackend::new(
        MatrixPersistenceMode::Snapshotted { file: tmp.clone() },
    );
    let snap1 = backend
        .rebuild(&log, MatrixCalibrationRegistry::new())
        .unwrap();
    let backend2 = MatrixPersistenceBackend::new(
        MatrixPersistenceMode::Snapshotted { file: tmp.clone() },
    );
    let loaded = backend2.load().unwrap().expect("snapshot present");
    assert_eq!(loaded.tier, snap1.tier);
    assert_eq!(loaded.calibration, snap1.calibration);
    assert_eq!(loaded.hlc_watermark, snap1.hlc_watermark);
}

#[test]
fn persistence_modes_agree_on_tier() {
    let tmp = std::env::temp_dir().join(format!(
        "matrix-eq-{}.bin",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let _cleanup = scopeguard_remove(tmp.clone());

    let mut log = UnifiedAuditLog::new();
    log.add(capture(
        EntryUUID([1; 16]),
        "bm.x",
        UnifiedAuditValue::Bitmap(0b1),
        hlc(1),
    ));
    log.add(capture(
        EntryUUID([2; 16]),
        "bm.x",
        UnifiedAuditValue::Bitmap(0b1),
        hlc(2),
    ));
    log.add(capture(
        EntryUUID([2; 16]),
        "bm.y",
        UnifiedAuditValue::Bitmap(0b10),
        hlc(2),
    ));

    let mem = MatrixPersistenceBackend::new(MatrixPersistenceMode::InMemory);
    let snap = MatrixPersistenceBackend::new(
        MatrixPersistenceMode::Snapshotted { file: tmp.clone() },
    );
    let mem_out = mem.rebuild(&log, MatrixCalibrationRegistry::new()).unwrap();
    let snap_out = snap.rebuild(&log, MatrixCalibrationRegistry::new()).unwrap();
    assert_eq!(mem_out.tier, snap_out.tier);
}

#[test]
fn calibration_deflates_overconfidence() {
    let mut registry = MatrixCalibrationRegistry::new();
    for _ in 0..4 {
        registry.record("test.model", 0.82, MatrixCalibrationOutcome::Failure);
    }
    registry.record("test.model", 0.82, MatrixCalibrationOutcome::Success);
    let cal = registry.calibrate("test.model", 0.82);
    assert!((cal - 0.2).abs() < 1e-5, "got {cal}");
    let pass_through = registry.calibrate("unknown", 0.5);
    assert!((pass_through - 0.5).abs() < 1e-9);
}

#[test]
fn nmf_approximates_input_matrix() {
    let o: [f64; 9] = [1.0, 2.0, 3.0, 2.0, 4.0, 6.0, 3.0, 6.0, 9.0];
    let f = MatrixNMF::factorize(&o, 3, 3, 1, 0xC0FFEE_BABE_BEEF, 200, 1e-9);
    assert!(f.reconstruction_error < 1e-3, "err {}", f.reconstruction_error);
    assert_eq!(f.loadings_for_row(0).len(), 1);
}

#[test]
fn nmf_deterministic_across_runs() {
    let o: [f64; 4] = [1.0, 2.0, 3.0, 4.0];
    let a = MatrixNMF::factorize(&o, 2, 2, 2, 42, 20, 1e-9);
    let b = MatrixNMF::factorize(&o, 2, 2, 2, 42, 20, 1e-9);
    assert_eq!(a.w, b.w);
    assert_eq!(a.h, b.h);
}

// Small RAII helper — pulls a path out at drop time without bringing
// in the `scopeguard` crate.
struct ScopeguardRemove(std::path::PathBuf);
impl Drop for ScopeguardRemove {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}
fn scopeguard_remove(p: std::path::PathBuf) -> ScopeguardRemove {
    ScopeguardRemove(p)
}
