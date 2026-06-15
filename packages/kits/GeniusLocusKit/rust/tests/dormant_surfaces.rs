// tests/dormant_surfaces.rs — shared-fixture tests for dormant-surfaces estate reads.
//
// Rust mirror of GLKDormantSurfacesTests.swift (dormant-surfaces mission, Part 5).
//
// Covers:
//   • event_lag_pairs: 5-event fixture with known HLCs and values; asserts
//     entry count, HLC-ascending order, and per-entry field coordinate
//     encoding (bitmap, string, integer, bytes, null).
//   • Calibration round-trip: record outcomes, read back the curve,
//     verify decay is applied at the next write (30-day half-life).
//
// The Swift port carries the same fixture values and produces identical
// results; see GeniusLocusKitTests/GLKDormantSurfacesTests.swift.

use genius_locus_kit::{
    audit::{AuditTier, EntryUUID, UnifiedAuditEntry, UnifiedAuditValue, UnifiedAuditVerb},
    event_lag_pairs,
    matrix::{
        MatrixCalibrationOutcome, MatrixCalibrationRegistry,
    },
};
use substrate_types::HLC;

// ---------------------------------------------------------------------------
// Shared fixture constants (identical to Swift GLKDormantSurfacesTests)
// ---------------------------------------------------------------------------

// Physical times are ms since Unix epoch.
const T_BASE: i64 = 1_000_000_000_000; // t+0 min
const T_PLUS_ONE: i64 = 1_000_000_060_000; // t+1 min
const T_PLUS_THREE: i64 = 1_000_000_180_000; // t+3 min
const T_PLUS_TEN: i64 = 1_000_000_600_000; // t+10 min
const T_PLUS_TWO_HUNDRED: i64 = 1_000_012_000_000; // t+200 min

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn hlc(physical_time: i64) -> HLC {
    HLC::new(physical_time, 0, 1)
}

fn make_entry(
    physical_time: i64,
    verb: UnifiedAuditVerb,
    field: &str,
    value: UnifiedAuditValue,
) -> UnifiedAuditEntry {
    UnifiedAuditEntry::new(
        AuditTier::Locus,
        hlc(physical_time),
        verb,
        EntryUUID([0u8; 16]),
        field,
        UnifiedAuditValue::Null,
        value,
        None,
    )
}

// ---------------------------------------------------------------------------
// event_lag_pairs: five-event fixture
// ---------------------------------------------------------------------------

#[test]
fn lag_pair_five_entry_count() {
    // Five entries covering different value types + 1 recall-verb noise entry.
    let entries = vec![
        make_entry(T_BASE, UnifiedAuditVerb::Capture, "alpha", UnifiedAuditValue::Bitmap(0xAB)),
        make_entry(T_PLUS_ONE, UnifiedAuditVerb::Capture, "beta", UnifiedAuditValue::StringValue("hello".to_string())),
        make_entry(T_PLUS_ONE + 1, UnifiedAuditVerb::Recall, "beta", UnifiedAuditValue::StringValue("hello".to_string())),
        make_entry(T_PLUS_THREE, UnifiedAuditVerb::Capture, "gamma", UnifiedAuditValue::Integer(42)),
        make_entry(T_PLUS_TEN, UnifiedAuditVerb::Expunge, "alpha", UnifiedAuditValue::Bitmap(0xAB)),
        make_entry(T_PLUS_TWO_HUNDRED, UnifiedAuditVerb::Capture, "delta", UnifiedAuditValue::Bytes(vec![1, 2, 3])),
    ];

    let lower_ms = T_BASE;
    let upper_ms = T_PLUS_TWO_HUNDRED + 1_000;
    let result = event_lag_pairs(&entries, lower_ms, upper_ms);

    // All 6 entries fall inside the window (5 capture/expunge + 1 recall).
    assert_eq!(result.len(), 6);
}

#[test]
fn lag_pair_ordering() {
    // Input sorted ascending (ordered_entries guarantees this for callers);
    // output must preserve that order.
    let entries = vec![
        make_entry(T_BASE, UnifiedAuditVerb::Capture, "alpha", UnifiedAuditValue::Bitmap(0xAB)),
        make_entry(T_PLUS_ONE, UnifiedAuditVerb::Capture, "beta", UnifiedAuditValue::StringValue("hello".to_string())),
        make_entry(T_PLUS_TEN, UnifiedAuditVerb::Capture, "gamma", UnifiedAuditValue::Integer(42)),
    ];

    let result = event_lag_pairs(&entries, T_BASE, T_PLUS_TEN + 1_000);

    assert_eq!(result.len(), 3);
    assert_eq!(result[0].hlc.physical_time, T_BASE);
    assert_eq!(result[1].hlc.physical_time, T_PLUS_ONE);
    assert_eq!(result[2].hlc.physical_time, T_PLUS_TEN);
}

#[test]
fn lag_pair_bitmap_coord() {
    // 0xAB = 171 decimal
    let entries = vec![
        make_entry(T_BASE, UnifiedAuditVerb::Capture, "alpha", UnifiedAuditValue::Bitmap(0xAB)),
    ];

    let result = event_lag_pairs(&entries, T_BASE, T_BASE + 1_000);

    assert_eq!(result.len(), 1);
    assert_eq!(result[0].field_coords.len(), 1);
    assert_eq!(result[0].field_coords[0].field_path, "alpha");
    assert_eq!(result[0].field_coords[0].value_repr, "bitmap:171");
}

#[test]
fn lag_pair_string_coord() {
    let entries = vec![
        make_entry(T_BASE, UnifiedAuditVerb::Capture, "beta", UnifiedAuditValue::StringValue("hello".to_string())),
    ];

    let result = event_lag_pairs(&entries, T_BASE, T_BASE + 1_000);

    assert_eq!(result.len(), 1);
    assert_eq!(result[0].field_coords[0].value_repr, "string:hello");
}

#[test]
fn lag_pair_integer_coord() {
    let entries = vec![
        make_entry(T_BASE, UnifiedAuditVerb::Capture, "gamma", UnifiedAuditValue::Integer(42)),
    ];

    let result = event_lag_pairs(&entries, T_BASE, T_BASE + 1_000);

    assert_eq!(result.len(), 1);
    assert_eq!(result[0].field_coords[0].value_repr, "integer:42");
}

#[test]
fn lag_pair_bytes_coord_uses_byte_count() {
    let entries = vec![
        make_entry(T_BASE, UnifiedAuditVerb::Capture, "delta", UnifiedAuditValue::Bytes(vec![1, 2, 3])),
    ];

    let result = event_lag_pairs(&entries, T_BASE, T_BASE + 1_000);

    assert_eq!(result.len(), 1);
    // Byte payloads contribute size-only coord; raw bytes are too high-cardinality.
    assert_eq!(result[0].field_coords[0].value_repr, "bytes:3");
}

#[test]
fn lag_pair_null_after_value_produces_empty_coords() {
    let entries = vec![
        make_entry(T_BASE, UnifiedAuditVerb::Capture, "epsilon", UnifiedAuditValue::Null),
    ];

    let result = event_lag_pairs(&entries, T_BASE, T_BASE + 1_000);

    assert_eq!(result.len(), 1);
    // Null after-value: entry present but no field coordinates.
    assert!(result[0].field_coords.is_empty());
}

#[test]
fn lag_pair_non_capture_verb_produces_empty_coords() {
    let entries = vec![
        make_entry(T_BASE, UnifiedAuditVerb::Recall, "beta", UnifiedAuditValue::StringValue("hello".to_string())),
    ];

    let result = event_lag_pairs(&entries, T_BASE, T_BASE + 1_000);

    // Recall verb is included (watermark advance) but produces no coords.
    assert_eq!(result.len(), 1);
    assert!(result[0].field_coords.is_empty());
}

#[test]
fn lag_pair_window_filter_excludes_out_of_range() {
    let entries = vec![
        make_entry(T_BASE, UnifiedAuditVerb::Capture, "alpha", UnifiedAuditValue::Bitmap(1)),
        make_entry(T_PLUS_TWO_HUNDRED, UnifiedAuditVerb::Capture, "beta", UnifiedAuditValue::Bitmap(2)),
    ];

    // Window that only covers the first entry (upper = T_BASE + 60 000 ms = T_PLUS_ONE).
    let result = event_lag_pairs(&entries, T_BASE, T_PLUS_ONE);

    assert_eq!(result.len(), 1);
    assert_eq!(result[0].field_coords[0].value_repr, "bitmap:1");
}

#[test]
fn lag_pair_expunge_verb_contributes_coords() {
    let entries = vec![
        make_entry(T_BASE, UnifiedAuditVerb::Expunge, "alpha", UnifiedAuditValue::Bitmap(0xAB)),
    ];

    let result = event_lag_pairs(&entries, T_BASE, T_BASE + 1_000);

    assert_eq!(result.len(), 1);
    // Expunge verb contributes field coords like Capture.
    assert_eq!(result[0].field_coords[0].value_repr, "bitmap:171");
}

// ---------------------------------------------------------------------------
// Calibration round-trip
// ---------------------------------------------------------------------------

#[test]
fn calibration_record_and_read_back_single_success_bucket_14() {
    let mut registry = MatrixCalibrationRegistry::new();

    // confidence 0.7 → idx = floor(0.7 * 20) = 14
    let t0_unix_secs: f64 = 0.0;
    registry.record_with_decay("test-model", 0.7, MatrixCalibrationOutcome::Success, t0_unix_secs, 30.0);

    let curve = registry.curves.get("test-model").expect("curve must exist");
    let bucket = &curve.buckets[14];
    assert_eq!(bucket.count, 1);
    assert!((bucket.success_rate - 1.0_f32).abs() < 0.001);
}

#[test]
fn calibration_unknown_model_returns_none() {
    let registry = MatrixCalibrationRegistry::new();
    assert!(registry.curves.get("no-such-model").is_none());
}

#[test]
fn calibration_30_day_decay_halves_bucket_count_at_next_write() {
    let mut registry = MatrixCalibrationRegistry::new();
    let model_id = "decay-test-model";
    let t0_unix_secs: f64 = 0.0;

    // Record 10 successes at t=0.
    for _ in 0..10 {
        registry.record_with_decay(model_id, 0.7, MatrixCalibrationOutcome::Success, t0_unix_secs, 30.0);
    }

    // Verify 10 successes landed in bucket 14.
    {
        let curve = registry.curves.get(model_id).expect("curve must exist");
        let b14 = &curve.buckets[14];
        assert_eq!(b14.count, 10);
        assert!((b14.success_rate - 1.0_f32).abs() < 0.001);
    }

    // 30 days later: decay factor = 0.5^(30/30) = 0.5
    // count = round(10 * 0.5) = round(5.0) = 5
    // Then record 1 failure: count = 6, rate = (1.0*5 + 0.0)/6 = 5/6 ≈ 0.8333
    let t30_unix_secs: f64 = 30.0 * 24.0 * 3_600.0;
    registry.record_with_decay(model_id, 0.7, MatrixCalibrationOutcome::Failure, t30_unix_secs, 30.0);

    let curve = registry.curves.get(model_id).expect("curve must exist");
    let b14 = &curve.buckets[14];
    // Count: 5 (decayed from 10) + 1 new = 6.
    assert_eq!(b14.count, 6);
    // Success rate: (1.0 * 5 + 0.0) / 6 ≈ 0.8333
    assert!((b14.success_rate - (5.0_f32 / 6.0_f32)).abs() < 0.001);
}

#[test]
fn calibration_sub_day_elapsed_skips_decay() {
    let mut registry = MatrixCalibrationRegistry::new();
    let model_id = "no-decay-model";

    // Record 10 successes at t=0.
    let t0: f64 = 0.0;
    for _ in 0..10 {
        registry.record_with_decay(model_id, 0.7, MatrixCalibrationOutcome::Success, t0, 30.0);
    }

    // Record 1 more success just 1 hour later — sub-day, no decay applied.
    let t1h: f64 = 3_600.0; // 1 hour in seconds
    registry.record_with_decay(model_id, 0.7, MatrixCalibrationOutcome::Success, t1h, 30.0);

    let curve = registry.curves.get(model_id).expect("curve must exist");
    let b14 = &curve.buckets[14];
    // No decay: 10 + 1 = 11 observations, all successes.
    assert_eq!(b14.count, 11);
}
