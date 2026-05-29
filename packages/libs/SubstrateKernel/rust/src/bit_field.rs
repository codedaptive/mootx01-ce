// bit_field.rs
//
// Parametric bit-field primitives for the substrate's packed-row
// bitmap encoding. Per the F18 atomic-centralization rule (cookbook
// §1 / KIT_INTERFACE_DESIGN / MOOTX01_AND_ARIA_CANON): every kit-level
// bit operation routes through this module. Kits do NOT open-code
// `(bitmap >> shift) & mask` or `(bitmap & !mask) | (value << shift)`.
// They call `bit_field::extract_field(...)` and
// `bit_field::write_field(...)`.
//
// Rationale:
//
//   1. Centralization — when the cookbook bit-layout spec changes,
//      one library changes, every kit follows. M1 (SubstrateLib owns
//      substrate math) in its full strength.
//
//   2. Portability — the substrate is the one hard port. Once
//      SubstrateLib's conformance tests pass on a new platform,
//      every kit works on that platform without per-kit re-verification.
//
//   3. SIMD readiness — bulk operations over packed-row bitmaps
//      want to live in one kernel (cookbook §4.4 / I-19).
//
// Mirror of `BitField.swift`. Function signatures use snake_case
// per Rust convention; semantics, edge cases, and panic messages
// match byte-for-byte where applicable.
//
// All operations are pure functions over i64 (or [i64]); no
// allocation, no side effects, predictable cost.
//
// Bounds: shift in [0, 64), width in [1, 64], shift + width <= 64.
// Violations trigger `panic!` with a message naming the offending
// parameters — bit-position bugs surface immediately at the call
// site rather than silently corrupting adjacent fields.

// MARK: - Field extract/write

/// Extract a `width`-bit unsigned field from `bitmap` starting at
/// `shift`. Returns the field value as a non-negative `i64`
/// (high bits zero).
///
/// # Example
/// ```
/// use substrate_kernel::bit_field;
/// # let adjective: i64 = 0;
/// // Cookbook §2.3: trust at bits 18-23 (6-bit field).
/// let trust_raw = bit_field::extract_field(adjective, 18, 6);
/// // → 0..64
/// ```
///
/// # Panics
/// Panics if `width == 0`, `width > 64`, or `shift + width > 64`.
#[inline]
pub fn extract_field(bitmap: i64, shift: u32, width: u32) -> i64 {
    assert!(width >= 1 && width <= 64 && shift + width <= 64,
            "bit_field::extract_field: invalid shift={} width={}", shift, width);
    let mask: i64 = if width == 64 { -1 } else { (1i64 << width) - 1 };
    (bitmap >> shift) & mask
}

/// Write a `width`-bit field `value` into `bitmap` starting at
/// `shift`. Existing bits in the field are replaced; bits outside
/// the field are preserved. Returns the modified bitmap.
///
/// # Example
/// ```
/// use substrate_kernel::bit_field;
/// # let new_state_raw: i64 = 0;
/// # let prior_bitmap: i64 = 0;
/// // Cookbook §2.3: state at bits 0-5 (6-bit field).
/// let next = bit_field::write_field(new_state_raw, prior_bitmap, 0, 6);
/// ```
///
/// # Panics
/// Panics if `width == 0`, `width > 64`, or `shift + width > 64`.
#[inline]
pub fn write_field(value: i64, into_bitmap: i64, shift: u32, width: u32) -> i64 {
    assert!(width >= 1 && width <= 64 && shift + width <= 64,
            "bit_field::write_field: invalid shift={} width={}", shift, width);
    let mask: i64 = if width == 64 { -1 } else { (1i64 << width) - 1 };
    let cleared = into_bitmap & !(mask << shift);
    cleared | ((value & mask) << shift)
}

// MARK: - Masked equality

/// Test whether the bit-field selected by `mask` in `bitmap` equals
/// `expected`. Equivalent to `(bitmap & mask) == expected`.
///
/// Per the F18 atomic-centralization rule (cookbook §2.8 / §7.7):
/// kit-level field-equality checks on packed bitmaps route through
/// this primitive. The Swift port's `LocusKit/BitmapOps.swift`'s
/// `andMask` becomes a one-line passthrough, mirroring how
/// `threshold_compare` and `shift_extract` already delegate to
/// `extract_field` and `popcount`.
///
/// Semantics: `mask` and `expected` MUST share the same bit range
/// (caller invariant — `expected` is already aligned to the field's
/// position). If `expected` has bits set outside `mask`, the result
/// is `false` for every `bitmap` (natural semantics of
/// `(bitmap & mask) == expected`); preserved so callers can assert
/// "no extra bits set, field exactly equals X."
///
/// No assertion on the parameter values: any i64 inputs are
/// well-defined. Behavior on the sign bit (negative i64 values) is
/// the standard two's-complement bitwise AND, byte-identical with
/// the Swift port.
///
/// Compiles to two instructions on aarch64: `and` then `cmp`.
///
/// # Example
/// ```
/// use substrate_kernel::bit_field;
/// # let adjective: i64 = 0;
/// // Cookbook §2.8: state field at bits 0-3 (4-bit field), test
/// // whether state == 3 (canonical).
/// if bit_field::masked_equals(adjective, 0xF, 3) { /* ... */ }
/// ```
#[inline]
pub fn masked_equals(bitmap: i64, mask: i64, expected: i64) -> bool {
    (bitmap & mask) == expected
}

// MARK: - Flag extract/write

/// Extract a single-bit flag at position `bit`.
///
/// # Panics
/// Panics if `bit >= 64`.
#[inline]
pub fn extract_flag(bitmap: i64, bit: u32) -> bool {
    assert!(bit < 64, "bit_field::extract_flag: invalid bit={}", bit);
    ((bitmap >> bit) & 1) == 1
}

/// Write a single-bit flag at position `bit`. Other bits in the
/// bitmap are preserved. Returns the modified bitmap.
///
/// # Panics
/// Panics if `bit >= 64`.
#[inline]
pub fn write_flag(flag: bool, into_bitmap: i64, bit: u32) -> i64 {
    assert!(bit < 64, "bit_field::write_flag: invalid bit={}", bit);
    if flag {
        into_bitmap | (1i64 << bit)
    } else {
        into_bitmap & !(1i64 << bit)
    }
}

// MARK: - Bulk-friendly atomics

/// Hamming weight (population count) of `value` — the number of
/// 1-bits. Wraps `i64::count_ones()` and casts the result to `i32`
/// to match the Swift `popcount(_:) -> Int` signature in spirit
/// (the count fits in 7 bits).
#[inline]
pub fn popcount(value: i64) -> i32 {
    value.count_ones() as i32
}

/// Hamming distance between two bitmaps — the number of bit
/// positions where they differ. `hamming_distance(a, b) == popcount(a ^ b)`.
#[inline]
pub fn hamming_distance(a: i64, b: i64) -> i32 {
    popcount(a ^ b)
}

/// XOR-fold a sequence of bitmaps — the running XOR over all values,
/// starting from zero. Used by audit-log reconstruction (cookbook
/// §5.5) and fingerprint-builder patterns.
///
/// Empty iterator returns 0 (the XOR identity).
#[inline]
pub fn xor_fold<I: IntoIterator<Item = i64>>(values: I) -> i64 {
    values.into_iter().fold(0i64, |acc, x| acc ^ x)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_field_lsb_6_bits() {
        // Cookbook §2.3 state at bits 0-5.
        assert_eq!(extract_field(0b101010, 0, 6), 0b101010);
        assert_eq!(extract_field(33, 0, 6), 33); // tombstoned
    }

    #[test]
    fn extract_field_middle_field_6_bits() {
        // Cookbook §2.3 trust at bits 18-23. Trust=canonical=3.
        let adj: i64 = 3 << 18;
        assert_eq!(extract_field(adj, 18, 6), 3);
        // Lower bits don't leak into the extraction.
        let adj2: i64 = (3 << 18) | 0x3F;
        assert_eq!(extract_field(adj2, 18, 6), 3);
    }

    #[test]
    fn extract_field_high_bits_dont_pollute() {
        // Cookbook §2.5 enrichment_status at bits 36-41.
        let prov: i64 = 2 << 36;
        assert_eq!(extract_field(prov, 36, 6), 2);
    }

    #[test]
    fn write_field_preserves_other_fields() {
        // Adjective: state=active(0) at bits 0-5, trust=canonical(3) at 18-23.
        let prior: i64 = 3 << 18; // trust=canonical, state=active
        let next = write_field(33, prior, 0, 6); // state -> tombstoned
        assert_eq!(extract_field(next, 0, 6), 33);
        assert_eq!(extract_field(next, 18, 6), 3); // trust preserved
    }

    #[test]
    fn write_field_overwrites_field_cleanly() {
        let prior: i64 = 0x3F << 18; // trust=63 (all bits set in trust field)
        let next = write_field(3, prior, 18, 6); // overwrite with canonical
        assert_eq!(extract_field(next, 18, 6), 3);
    }

    #[test]
    fn write_field_truncates_oversize_value() {
        // value=0x7F (7 bits) into a 6-bit field truncates to 0x3F.
        let next = write_field(0x7F, 0, 0, 6);
        assert_eq!(extract_field(next, 0, 6), 0x3F);
    }

    #[test]
    fn extract_flag_returns_bool() {
        assert_eq!(extract_flag(0, 26), false);
        assert_eq!(extract_flag(1i64 << 26, 26), true);
        // Bit 27 set doesn't bleed into bit 26's read.
        assert_eq!(extract_flag(1i64 << 27, 26), false);
    }

    #[test]
    fn write_flag_preserves_other_bits() {
        let prior: i64 = (1 << 24) | (1 << 25); // state_extension + lineage_clustering
        let next = write_flag(true, prior, 26); // set dreaming_recalc_required
        assert_eq!(extract_flag(next, 24), true);
        assert_eq!(extract_flag(next, 25), true);
        assert_eq!(extract_flag(next, 26), true);
    }

    #[test]
    fn write_flag_can_clear() {
        let prior: i64 = 0xFF;
        let next = write_flag(false, prior, 3);
        assert_eq!(next, 0xF7); // bit 3 cleared
    }

    #[test]
    fn popcount_matches_set_bits() {
        assert_eq!(popcount(0), 0);
        assert_eq!(popcount(1), 1);
        assert_eq!(popcount(0xFF), 8);
        assert_eq!(popcount(-1), 64); // all bits set in two's complement
    }

    #[test]
    fn hamming_distance_symmetric() {
        assert_eq!(hamming_distance(0b1100, 0b0011), 4);
        assert_eq!(hamming_distance(0b0011, 0b1100), 4);
        assert_eq!(hamming_distance(42, 42), 0);
    }

    #[test]
    fn xor_fold_empty_is_zero() {
        let empty: Vec<i64> = vec![];
        assert_eq!(xor_fold(empty), 0);
    }

    #[test]
    fn xor_fold_self_cancels() {
        // a ^ a = 0; pair of identical values cancels.
        assert_eq!(xor_fold(vec![0x1234_5678i64, 0x1234_5678]), 0);
        // a ^ b ^ a = b.
        assert_eq!(xor_fold(vec![0xAA, 0xBB, 0xAA]), 0xBB);
    }

    #[test]
    fn round_trip_cookbook_2_3_layout() {
        // Build cookbook §2.3 layout from scratch: state, sensitivity,
        // exportability, trust, three flags. Round-trip every field.
        let mut adj: i64 = 0;
        adj = write_field(2, adj, 0, 6);   // state=contested
        adj = write_field(16, adj, 6, 6);  // sensitivity=elevated
        adj = write_field(0, adj, 12, 6);  // exportability=private
        adj = write_field(3, adj, 18, 6);  // trust=canonical
        adj = write_flag(true, adj, 24);   // state_extension
        adj = write_flag(false, adj, 25);  // lineage_clustering
        adj = write_flag(true, adj, 26);   // dreaming_recalc_required

        assert_eq!(extract_field(adj, 0, 6), 2);
        assert_eq!(extract_field(adj, 6, 6), 16);
        assert_eq!(extract_field(adj, 12, 6), 0);
        assert_eq!(extract_field(adj, 18, 6), 3);
        assert_eq!(extract_flag(adj, 24), true);
        assert_eq!(extract_flag(adj, 25), false);
        assert_eq!(extract_flag(adj, 26), true);
    }
}
