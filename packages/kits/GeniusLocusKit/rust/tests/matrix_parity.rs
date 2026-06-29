// matrix_parity.rs — Rust-side conformance tests for the matrix tier.
//
// Mission GLK-06. The same canonical vectors that the Swift
// `MatrixTierTests` exercise are used here so the two legs stay
// numerically aligned. Substrate-mathematics §8 and cookbook §6 fix
// the semantics; these tests fix the byte-for-byte expectations.

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
use substrate_types::hlc::HLC;

use genius_locus_kit::audit::{
    AuditTier, EntryUUID, UnifiedAuditEntry, UnifiedAuditLog, UnifiedAuditValue, UnifiedAuditVerb,
};
use genius_locus_kit::matrix::{
    MatrixCalibrationOutcome, MatrixCalibrationRegistry, MatrixCoOccurKey, MatrixFieldCell,
    MatrixNMF, MatrixPersistenceBackend, MatrixPersistenceMode, MatrixTemporalKey, MatrixTier,
    MatrixValueCoord,
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
    tier.apply_capture(&[("bitmap.adjective".to_string(), 0b1001)], &[], hlc(10), 1);
    tier.apply_capture(&[("bitmap.adjective".to_string(), 0b1001)], &[], hlc(11), 1);
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
    // Type alias for clarity — suppresses the type_complexity lint for this capture bundle.
    #[allow(clippy::type_complexity)]
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

    let backend =
        MatrixPersistenceBackend::new(MatrixPersistenceMode::Snapshotted { file: tmp.clone() });
    let snap1 = backend
        .rebuild(&log, MatrixCalibrationRegistry::new())
        .unwrap();
    let backend2 =
        MatrixPersistenceBackend::new(MatrixPersistenceMode::Snapshotted { file: tmp.clone() });
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
    let snap =
        MatrixPersistenceBackend::new(MatrixPersistenceMode::Snapshotted { file: tmp.clone() });
    let mem_out = mem.rebuild(&log, MatrixCalibrationRegistry::new()).unwrap();
    let snap_out = snap
        .rebuild(&log, MatrixCalibrationRegistry::new())
        .unwrap();
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
    // MatrixNMF delegates to the canonical substrate NMFAlternatingLeastSquares
    // (f32, RMS error). For a perfect rank-1 input the RMS error converges to 0.0.
    // tolerance is f32 (the substrate canonical tolerance type).
    let o: [f64; 9] = [1.0, 2.0, 3.0, 2.0, 4.0, 6.0, 3.0, 6.0, 9.0];
    let f = MatrixNMF::factorize(&o, 3, 3, 1, 0xDEADBEEFCAFEBABE, 200, 1e-9_f32);
    assert!(
        f.reconstruction_error < 1e-3,
        "RMS err {} (canonical f32 substrate NMF)",
        f.reconstruction_error
    );
    assert_eq!(f.loadings_for_row(0).len(), 1);
}

#[test]
fn nmf_deterministic_across_runs() {
    // Two calls with the same seed produce bit-identical f32 W and H
    // via the canonical substrate NMFAlternatingLeastSquares.
    let o: [f64; 4] = [1.0, 2.0, 3.0, 4.0];
    let a = MatrixNMF::factorize(&o, 2, 2, 2, 42, 20, 1e-4_f32);
    let b = MatrixNMF::factorize(&o, 2, 2, 2, 42, 20, 1e-4_f32);
    assert_eq!(a.w, b.w);
    assert_eq!(a.h, b.h);
}

// MARK: - rebuild_temporal conformance
//
// These tests mirror the Swift conformance tests in:
//   StandingSignalsTests.rebuildTemporalPopulatesAndIsIdempotent
//   RecallDirectorTests.rebuildTemporalWiresThroughRecallScoring
//
// The fixture: two captures 5 minutes apart on different fields.
// Expected outcome: one T-matrix cell at lag bucket 8 (5 min → bucket 8),
// and temporal_watermark_hlc advanced past HLC::ZERO.


/// Mirrors Swift StandingSignalsTests.rebuildTemporalPopulatesAndIsIdempotent.
///
/// Two captures on different fields, 5 minutes apart (300_000 ms).
/// After rebuild_temporal:
///   - temporal_causality must be non-empty (the pair was within window).
///   - temporal_watermark_hlc must be the HLC of the later entry.
///   - A second rebuild_temporal on the same log must produce bit-identical
///     temporal_causality and the same watermark (idempotent).
#[test]
fn rebuild_temporal_populates_t_and_is_idempotent() {
    let h0 = HLC::new(0, 0, 1);
    let h1 = HLC::new(300_000, 0, 1); // 5 minutes = 300_000 ms

    let row_a = EntryUUID([0xAA; 16]);
    let row_b = EntryUUID([0xBB; 16]);

    let mut log = UnifiedAuditLog::new();
    // Entry 0: capture on field "f.src" with bitmap value 1 at t=0.
    log.add(capture(row_a, "f.src", UnifiedAuditValue::Bitmap(1), h0));
    // Entry 1: capture on field "f.tgt" with bitmap value 2 at t+5min.
    log.add(capture(row_b, "f.tgt", UnifiedAuditValue::Bitmap(2), h1));

    let tier1 = MatrixTier::rebuild_temporal(&log);

    // temporal_watermark_hlc must advance past HLC::ZERO.
    assert!(
        tier1.temporal_watermark_hlc > HLC::ZERO,
        "rebuild_temporal must advance temporal_watermark_hlc past ZERO; got {:?}",
        tier1.temporal_watermark_hlc
    );
    // Watermark is the HLC of the last entry processed.
    assert_eq!(
        tier1.temporal_watermark_hlc, h1,
        "temporal_watermark_hlc must equal HLC of last entry"
    );

    // T must be non-empty: the two captures are within the 256-minute window.
    assert!(
        !tier1.temporal_causality.is_empty(),
        "temporal_causality must be non-empty for entries within window"
    );

    // 5 minutes → lag bucket 8 (smallest bucket >= 5 in {1,2,4,8,...}).
    let src = MatrixValueCoord::new("f.src", UnifiedAuditValue::Bitmap(1));
    let tgt = MatrixValueCoord::new("f.tgt", UnifiedAuditValue::Bitmap(2));
    let key = MatrixTemporalKey {
        source: src,
        target: tgt,
        lag_bucket: 8,
    };
    assert_eq!(
        tier1.temporal_causality.get(&key),
        Some(&1),
        "T cell (f.src→f.tgt, bucket=8) must equal 1"
    );

    // Idempotence: rebuilding from the same log twice gives identical T cells
    // and the same watermark.
    let tier2 = MatrixTier::rebuild_temporal(&log);
    assert_eq!(
        tier2.temporal_watermark_hlc, tier1.temporal_watermark_hlc,
        "rebuild_temporal is deterministic: watermark must match on second rebuild"
    );
    assert_eq!(
        tier2.temporal_causality, tier1.temporal_causality,
        "rebuild_temporal is deterministic: T cells must be bit-identical on second rebuild"
    );
}

/// Mirrors the out-of-window case in StandingSignalsTests and the fold
/// unit tests: two captures > 256 minutes apart produce no T pairs.
#[test]
fn rebuild_temporal_ignores_entries_outside_window() {
    let h0 = HLC::new(0, 0, 1);
    // 257 minutes = 257 * 60_000 ms = 15_420_000 ms — past the 256-minute cap.
    let h1 = HLC::new(257 * 60_000, 0, 1);

    let row_a = EntryUUID([0xCC; 16]);
    let row_b = EntryUUID([0xDD; 16]);

    let mut log = UnifiedAuditLog::new();
    log.add(capture(row_a, "f.src", UnifiedAuditValue::Bitmap(1), h0));
    log.add(capture(row_b, "f.tgt", UnifiedAuditValue::Bitmap(2), h1));

    let tier = MatrixTier::rebuild_temporal(&log);

    // Watermark still advances (the entries were processed, just produced no pairs).
    assert_eq!(tier.temporal_watermark_hlc, h1);
    // T is empty — no pair within window.
    assert!(
        tier.temporal_causality.is_empty(),
        "temporal_causality must be empty when entries are outside the window"
    );
}

/// Null after-value contributes no coordinate per the Swift reference comment:
/// "Null after-value contributes no coordinate; the entry advances the
/// watermark but generates no T pairs."
#[test]
fn rebuild_temporal_null_value_advances_watermark_but_generates_no_pairs() {
    let h0 = HLC::new(0, 0, 1);
    let h1 = HLC::new(60_000, 0, 1); // 1 minute apart

    let row_a = EntryUUID([0xEE; 16]);
    let row_b = EntryUUID([0xFF; 16]);

    let mut log = UnifiedAuditLog::new();
    // First entry has null after-value — contributes no coord.
    log.add(UnifiedAuditEntry::new(
        AuditTier::Locus,
        h0,
        UnifiedAuditVerb::Capture,
        row_a,
        "f.src".to_string(),
        UnifiedAuditValue::Null,
        UnifiedAuditValue::Null,
        None,
    ));
    // Second entry has a real value.
    log.add(capture(row_b, "f.tgt", UnifiedAuditValue::Bitmap(3), h1));

    let tier = MatrixTier::rebuild_temporal(&log);

    // Watermark advances to the last entry.
    assert_eq!(tier.temporal_watermark_hlc, h1);
    // No pairs because the first entry had null after-value → no coord → no source.
    assert!(
        tier.temporal_causality.is_empty(),
        "null after-value must not generate T pairs"
    );
}

/// Non-capture/expunge verbs (e.g. Recall, Mutate) are ignored by rebuild_temporal.
/// This mirrors the Swift filter: `.filter { $0.verb == .capture || $0.verb == .expunge }`.
#[test]
fn rebuild_temporal_ignores_non_capture_expunge_verbs() {
    let h0 = HLC::new(0, 0, 1);
    let h1 = HLC::new(60_000, 0, 1);

    let row_a = EntryUUID([0x11; 16]);
    let row_b = EntryUUID([0x22; 16]);

    let mut log = UnifiedAuditLog::new();
    // A Recall verb — should be ignored by rebuild_temporal.
    log.add(UnifiedAuditEntry::new(
        AuditTier::Locus,
        h0,
        UnifiedAuditVerb::Recall,
        row_a,
        "f.src".to_string(),
        UnifiedAuditValue::Null,
        UnifiedAuditValue::Bitmap(1),
        None,
    ));
    // A Capture verb — should be processed.
    log.add(capture(row_b, "f.tgt", UnifiedAuditValue::Bitmap(2), h1));

    let tier = MatrixTier::rebuild_temporal(&log);

    // The Recall entry is ignored — no source coord — so no T pairs.
    assert!(
        tier.temporal_causality.is_empty(),
        "non-capture/expunge verbs must not contribute to T"
    );
    // Watermark advances to last capture entry.
    assert_eq!(tier.temporal_watermark_hlc, h1);
}

// MARK: - temporal_watermark_hlc snapshot persistence (t3-temporal-watermark)
//
// These two tests enforce the conformance fix: the Rust MatrixSnapshot now
// saves and restores temporal_watermark_hlc, mirroring Swift's Codable path
// which uses `decodeIfPresent ?? .zero`.

/// Round-trip: a MatrixTier with a known non-zero temporal_watermark_hlc
/// must survive a snapshot save→load cycle with the watermark intact.
///
/// This test FAILS before the fix (temporal_watermark_hlc resets to ZERO
/// after load) and PASSES after (encode_snapshot writes the trailer;
/// decode_snapshot reads it back).
#[test]
fn snapshot_persists_temporal_watermark_hlc_round_trip() {
    let tmp = std::env::temp_dir().join(format!(
        "matrix-twm-rt-{}.bin",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let _cleanup = scopeguard_remove(tmp.clone());

    // Build a log and run rebuild_temporal so temporal_watermark_hlc
    // is set to a known non-zero value (the HLC of the later entry).
    let h0 = HLC::new(0, 0, 1);
    let h1 = HLC::new(300_000, 0, 1); // 5 minutes = 300_000 ms
    let row_a = EntryUUID([0xA1; 16]);
    let row_b = EntryUUID([0xB1; 16]);

    let mut log = UnifiedAuditLog::new();
    log.add(capture(row_a, "f.src", UnifiedAuditValue::Bitmap(1), h0));
    log.add(capture(row_b, "f.tgt", UnifiedAuditValue::Bitmap(2), h1));

    // Use rebuild_temporal to populate temporal_watermark_hlc on the tier.
    let t_tier = MatrixTier::rebuild_temporal(&log);
    assert!(
        t_tier.temporal_watermark_hlc > HLC::ZERO,
        "precondition: rebuild_temporal must set a non-zero watermark"
    );
    let known_watermark = t_tier.temporal_watermark_hlc;

    // Build a full MatrixSnapshot carrying this tier.
    let backend =
        MatrixPersistenceBackend::new(MatrixPersistenceMode::Snapshotted { file: tmp.clone() });
    // Construct the snapshot via a custom save so we control the tier directly.
    use genius_locus_kit::matrix::{MatrixSnapshot};
    let snap_to_save = MatrixSnapshot::new(t_tier, MatrixCalibrationRegistry::new(), h1);
    backend.save(&snap_to_save).expect("save must succeed");

    // Load it back and verify temporal_watermark_hlc is preserved.
    let backend2 =
        MatrixPersistenceBackend::new(MatrixPersistenceMode::Snapshotted { file: tmp.clone() });
    let loaded = backend2.load().expect("load must succeed").expect("snapshot must be present");

    assert_eq!(
        loaded.tier.temporal_watermark_hlc, known_watermark,
        "temporal_watermark_hlc must survive snapshot round-trip; \
         got {:?}, want {:?}",
        loaded.tier.temporal_watermark_hlc, known_watermark
    );
}

/// The Snapshotted file backend rejects schema_version=1 (old format) via a
/// SchemaVersionMismatch error, not by silently accepting it. This documents
/// the correct gate: the file backend requires CURRENT_SCHEMA_VERSION (2).
/// Legacy v1 decode behavior (HLC::ZERO fallback) is tested at the unit level
/// in matrix/persistence.rs::v2_truncation_tests::v1_blob_decodes_ok_with_zero_watermark_and_empty_timestamps.
#[test]
fn snapshot_file_backend_rejects_v1_schema_version() {
    let tmp = std::env::temp_dir().join(format!(
        "matrix-twm-bc-{}.bin",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let _cleanup = scopeguard_remove(tmp.clone());

    let h1 = HLC::new(300_000, 0, 1);
    use genius_locus_kit::matrix::MatrixSnapshot;
    let snap = MatrixSnapshot::new(MatrixTier::new(), MatrixCalibrationRegistry::new(), h1);
    let backend =
        MatrixPersistenceBackend::new(MatrixPersistenceMode::Snapshotted { file: tmp.clone() });
    backend.save(&snap).expect("save must succeed");

    // Patch schema_version byte (first 4 LE bytes) to 1 to simulate an old-format file.
    let mut bytes = std::fs::read(&tmp).expect("read back saved bytes");
    bytes[0] = 1; bytes[1] = 0; bytes[2] = 0; bytes[3] = 0;
    // Strip the 20-byte tail so the blob is also well-formed as schema_version=1 content.
    let tail_len = 20;
    if bytes.len() >= tail_len {
        bytes.truncate(bytes.len() - tail_len);
    }
    std::fs::write(&tmp, &bytes).expect("write patched bytes");

    // The file backend's schema version gate rejects v1 blobs via SchemaVersionMismatch.
    // MatrixSnapshotStore.load() (the SQLite path) converts this to Ok(None) → full rebuild.
    let backend2 =
        MatrixPersistenceBackend::new(MatrixPersistenceMode::Snapshotted { file: tmp.clone() });
    let result = backend2.load();
    assert!(
        result.is_err(),
        "file backend must reject schema_version=1 blob, got Ok"
    );
}

/// Corruption gate (v2 format): a schema_version=2 snapshot truncated before
/// the temporal_watermark_hlc section must be REJECTED (not silently accepted
/// with HLC::ZERO). MatrixSnapshotStore.load() treats a decode error as None,
/// so the caller falls back to a full rebuild — the safe behavior.
///
/// Without this guard, a truncated v2 blob with a reset watermark could cause
/// incremental_update to replay temporal deltas over already-loaded state.
#[test]
fn snapshot_truncated_v2_before_watermark_is_rejected() {
    let tmp = std::env::temp_dir().join(format!(
        "matrix-twm-trunc-{}.bin",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let _cleanup = scopeguard_remove(tmp.clone());

    let h1 = HLC::new(300_000, 0, 1);
    use genius_locus_kit::matrix::MatrixSnapshot;
    let snap = MatrixSnapshot::new(MatrixTier::new(), MatrixCalibrationRegistry::new(), h1);
    // schema_version must be 2 (the current version) for this test to be meaningful.
    assert_eq!(snap.schema_version, 2, "test requires a v2 snapshot");
    let backend =
        MatrixPersistenceBackend::new(MatrixPersistenceMode::Snapshotted { file: tmp.clone() });
    backend.save(&snap).expect("save must succeed");

    let mut bytes = std::fs::read(&tmp).expect("read back saved bytes");
    let original_len = bytes.len();
    // Strip the 20-byte v2 tail (watermark + ts count) — leaves schema_version=2
    // in the header but no temporal_watermark tail. This is the corrupt truncated-v2 case.
    let tail_len = 20;
    assert!(original_len >= tail_len, "saved snapshot must be at least {tail_len} bytes");
    bytes.truncate(original_len - tail_len);
    std::fs::write(&tmp, &bytes).expect("write truncated bytes");

    // Load the truncated v2 snapshot. The Snapshotted backend propagates
    // SnapshotDecodeFailed for a truncated blob — callers (MatrixSnapshotStore.load)
    // then treat the error as None → full rebuild (the safe behavior contract).
    // Here we verify the error IS returned rather than silently accepting
    // the truncated blob as Ok(Some(snapshot_with_reset_watermark)).
    let backend2 =
        MatrixPersistenceBackend::new(MatrixPersistenceMode::Snapshotted { file: tmp.clone() });
    let result = backend2.load();
    assert!(
        result.is_err(),
        "truncated v2 snapshot must return Err (decode failure), got Ok"
    );
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

// MARK: - Incremental hydration conformance (persist + load-forward)

// Helpers for the incremental conformance test — mirror the Swift
// `incrementalUpdateMatchesFullRebuildAtEverySplit` cap/exp/wdr helpers.
fn cap_e(row: EntryUUID, field: &str, bm: u64, h: HLC) -> UnifiedAuditEntry {
    UnifiedAuditEntry::new(
        AuditTier::Locus, h, UnifiedAuditVerb::Capture, row, field.to_string(),
        UnifiedAuditValue::Null, UnifiedAuditValue::Bitmap(bm), None,
    )
}
fn exp_e(row: EntryUUID, field: &str, bm: u64, h: HLC) -> UnifiedAuditEntry {
    UnifiedAuditEntry::new(
        AuditTier::Locus, h, UnifiedAuditVerb::Expunge, row, field.to_string(),
        UnifiedAuditValue::Bitmap(bm), UnifiedAuditValue::Bitmap(bm), None,
    )
}
fn wdr_e(row: EntryUUID, h: HLC) -> UnifiedAuditEntry {
    UnifiedAuditEntry::new(
        AuditTier::Locus, h, UnifiedAuditVerb::Withdraw, row, "bm.a".to_string(),
        UnifiedAuditValue::Null, UnifiedAuditValue::Null, None,
    )
}

/// For EVERY whole-HLC split point, a snapshot `full_rebuild(prefix)` then
/// `incremental_update(full_log)` must equal `full_rebuild(full_log)` cell-for-
/// cell — F, O, T, live_row_count, and both HLC cursors. Mirrors Swift
/// `incrementalUpdateMatchesFullRebuildAtEverySplit`. Exercises a cross-cursor
/// expunge and a withdraw — the cases a naive delta-rebuild-then-merge corrupts.
///
/// Splits are whole-HLC only: a row's multi-field capture is one atomic
/// transaction sharing one HLC, and a snapshot is taken over committed state, so
/// the cursor never lands mid-row.
#[test]
fn incremental_update_matches_full_rebuild_at_every_split() {
    let row_a = EntryUUID([1u8; 16]);
    let row_b = EntryUUID([2u8; 16]);
    let row_c = EntryUUID([3u8; 16]);
    let row_d = EntryUUID([4u8; 16]);

    let entries: Vec<UnifiedAuditEntry> = vec![
        cap_e(row_a, "bm.a", 0b101, hlc(1_000)),
        cap_e(row_b, "bm.a", 0b001, hlc(2_000)),
        cap_e(row_b, "bm.b", 0b010, hlc(2_000)),
        cap_e(row_c, "bm.a", 0b111, hlc(3_000)),
        exp_e(row_a, "bm.a", 0b101, hlc(4_000)), // cross-cursor expunge of row_a
        wdr_e(row_b, hlc(5_000)),                // withdraw row_b
        cap_e(row_d, "bm.a", 0b011, hlc(6_000)),
        cap_e(row_d, "bm.b", 0b100, hlc(6_000)),
    ];

    let mut full_log = UnifiedAuditLog::new();
    for e in &entries {
        full_log.add(e.clone());
    }
    let full = MatrixTier::full_rebuild(&full_log);

    let n = entries.len();
    for k in 1..=n {
        // Whole-HLC boundary only: skip a split that would cut a same-HLC row.
        if k != n && entries[k - 1].hlc == entries[k].hlc {
            continue;
        }
        let mut prefix_log = UnifiedAuditLog::new();
        for e in entries.iter().take(k) {
            prefix_log.add(e.clone());
        }
        let mut snapshot = MatrixTier::full_rebuild(&prefix_log); // persisted state
        snapshot.incremental_update(&full_log); // load-forward

        assert_eq!(snapshot.field_presence, full.field_presence, "F differs at split {k}");
        assert_eq!(snapshot.co_occurrence, full.co_occurrence, "O differs at split {k}");
        assert_eq!(snapshot.temporal_causality, full.temporal_causality, "T differs at split {k}");
        assert_eq!(snapshot.live_row_count, full.live_row_count, "live_row_count differs at split {k}");
        assert_eq!(snapshot.last_hlc, full.last_hlc, "last_hlc differs at split {k}");
        assert_eq!(
            snapshot.temporal_watermark_hlc, full.temporal_watermark_hlc,
            "temporal_watermark differs at split {k}"
        );
    }
}
