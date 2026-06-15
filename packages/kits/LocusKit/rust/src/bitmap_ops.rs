//! §2.8 packed-layout field-extraction helpers. Ports the
//! post-purge `BitmapOps.swift`.
//!
//! Substrate math primitives — XOR, AND-with-mask-for-equivalence,
//! popcount/Hamming, OR-reduce, SIMD ballot — live in
//! `substrate_lib` at canonical Fingerprint256 width per anchor
//! mandate M1. The functions below are LocusKit-domain field reads
//! on a SINGLE row's packed-layout bitmap (cookbook §2.8 verification
//! table; spec §7.7's "field equality" / "cluster membership" /
//! "field value" cases). They are NOT cross-row aggregates and NOT
//! cross-bitmap comparisons; those route through `substrate_lib`.
//!
//! When a per-column bit op needs a substrate_lib primitive, pack
//! the i64 column into block 0 of a Fingerprint256 via
//! [`crate::fingerprint256_adapters::fingerprint_from_column`] and
//! unpack via [`crate::fingerprint256_adapters::column_from_fingerprint`].
//!
//! Every function is marked `#[inline]` so the evaluator's hot path
//! compiles to a single instruction sequence per row with no call
//! overhead — same intent as the Swift `@inlinable`.

// ---------------------------------------------------------------------------
// AND-with-mask
// ---------------------------------------------------------------------------

/// Test whether the field at `mask` equals `expected`.
/// Compiles to: `(bitmap & mask) == expected`.
/// Per spec § 7.7: "field equality on contiguous fields, 1 instruction."
///
/// `expected` is already aligned to the field's position (i.e. NOT
/// pre-shifted; the `mask` and `expected` share the same bit range).
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
use substrate_kernel::bit_field;

#[inline]
pub fn and_mask(bitmap: i64, mask: i64, expected: i64) -> bool {
    (bitmap & mask) == expected
}

// ---------------------------------------------------------------------------
// Threshold-compare
// ---------------------------------------------------------------------------

/// Comparison operators used by [`threshold_compare`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ThresholdOp {
    /// Field value is strictly less than `value`. Used for open-upper
    /// cluster boundaries (e.g. `state < 3` for know-now).
    LessThan,
    /// Field value is less than or equal to `value`.
    LessThanOrEqual,
    /// Field value is greater than or equal to `value`. Used for
    /// open-lower cluster boundaries (e.g. `state >= 3` for knew-past).
    GreaterThanOrEqual,
}

/// Test whether a field satisfies a threshold condition. Extracts the
/// field at `mask` / `shift` then compares with `op`. Per spec § 7.7:
/// "cluster membership on gradient-ordered fields, 1 instruction
/// (after AND-mask)."
///
/// `value` is in field-natural units (i.e. after `shift` is applied).
#[inline]
pub fn threshold_compare(bitmap: i64, mask: i64, shift: i32, op: ThresholdOp, value: i64) -> bool {
    // F18 atomic centralization: `mask` is high-aligned; width = popcount(mask).
    // A zero mask yields field 0, preserving the prior `(bitmap & 0) >> s`.
    let field = if mask == 0 {
        0
    } else {
        bit_field::extract_field(bitmap, shift as u32, bit_field::popcount(mask) as u32)
    };
    match op {
        ThresholdOp::LessThan => field < value,
        ThresholdOp::LessThanOrEqual => field <= value,
        ThresholdOp::GreaterThanOrEqual => field >= value,
    }
}

// ---------------------------------------------------------------------------
// Shift-extract
// ---------------------------------------------------------------------------

/// Extract a field value as an integer. Per spec § 7.7: "field value
/// as integer, 1 instruction."
///
/// `shift` aligns the field to bit 0; `mask` is applied AFTER shifting
/// to isolate the field width.
#[inline]
pub fn shift_extract(bitmap: i64, shift: i32, mask: i64) -> i64 {
    // F18 atomic centralization: route through substrate parametric primitive.
    // `mask` is low-aligned; width = popcount(mask). A zero mask is the
    // "no field" degenerate case — the façade defines it as 0.
    if mask == 0 {
        return 0;
    }
    bit_field::extract_field(bitmap, shift as u32, bit_field::popcount(mask) as u32)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn and_mask_matches_field_equality() {
        // bits 0–3 = 5, mask 0xF expects exactly 5.
        assert!(and_mask(0x5, 0xF, 0x5));
        assert!(!and_mask(0x6, 0xF, 0x5));
        // High bits do not leak in.
        assert!(and_mask(0x5 | (1 << 30), 0xF, 0x5));
    }

    #[test]
    fn and_mask_aligned_expected_at_field_position() {
        // bits 4–7 = 3 → bitmap 0x30, mask 0xF0, expected 0x30 (NOT 3).
        assert!(and_mask(0x30, 0xF0, 0x30));
        assert!(!and_mask(0x30, 0xF0, 0x20));
    }

    #[test]
    fn threshold_less_than() {
        // bits 0–3 carries 2, expect `< 3`.
        assert!(threshold_compare(0x2, 0xF, 0, ThresholdOp::LessThan, 3));
        assert!(!threshold_compare(0x3, 0xF, 0, ThresholdOp::LessThan, 3));
    }

    #[test]
    fn threshold_less_than_or_equal() {
        assert!(threshold_compare(
            0x3,
            0xF,
            0,
            ThresholdOp::LessThanOrEqual,
            3
        ));
        assert!(!threshold_compare(
            0x4,
            0xF,
            0,
            ThresholdOp::LessThanOrEqual,
            3
        ));
    }

    #[test]
    fn threshold_greater_than_or_equal() {
        // bits 12–15 carries 4, expect `>= 4`.
        assert!(threshold_compare(
            4_i64 << 12,
            0xF000,
            12,
            ThresholdOp::GreaterThanOrEqual,
            4
        ));
        assert!(!threshold_compare(
            3_i64 << 12,
            0xF000,
            12,
            ThresholdOp::GreaterThanOrEqual,
            4
        ));
    }

    #[test]
    fn shift_extract_isolates_field() {
        // bits 4–7 = 3 → bitmap 0x30, shift 4, mask 0xF → 3.
        assert_eq!(shift_extract(0x30, 4, 0xF), 3);
        // Trailing high bits do not leak in.
        assert_eq!(shift_extract(0x30 | (1 << 30), 4, 0xF), 3);
    }
}
