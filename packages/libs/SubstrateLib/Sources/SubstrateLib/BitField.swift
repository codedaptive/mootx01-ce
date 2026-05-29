// BitField.swift
//
// Parametric bit-field primitives for the substrate's packed-row
// bitmap encoding. Per the F18 atomic-centralization rule (cookbook
// §1 / KIT_INTERFACE_DESIGN / MOOTX01_AND_ARIA_CANON): every kit-level
// bit operation routes through this module. Kits do NOT open-code
// `(bitmap >> shift) & mask` or `(bitmap & ~mask) | (value << shift)`.
// They call `BitField.extractField(...)` and `BitField.writeField(...)`.
//
// Rationale:
//
//   1. Centralization — when the cookbook bit-layout spec changes,
//      one library changes, every kit follows. M1 (SubstrateLib owns
//      substrate math) in its full strength: not just "the math is
//      documented here" but "the math is executed here."
//
//   2. Portability — the substrate is the one hard port. Once
//      SubstrateLib's conformance tests pass on a new platform, every
//      kit works on that platform without per-kit re-verification.
//
//   3. SIMD readiness — bulk operations over packed-row bitmaps
//      (OR-reduce, hamming-batch, popcount-batch) want to live in one
//      kernel. Centralizing the single-row primitives is the
//      prerequisite for ever lifting the bulk paths into a portable
//      kernel (cookbook §4.4 / I-19).
//
// Naming convention:
//
//   extractField / writeField — multi-bit fields with named width
//   extractFlag  / writeFlag  — single-bit flags
//   popcount, hammingDistance, xorFold — bulk-friendly atomics
//
// All operations are pure functions over Int64 (or [Int64]); no
// allocation, no side effects, predictable cost.
//
// Bounds: shift ∈ [0, 64), width ∈ [1, 64], shift + width ≤ 64.
// Violations trigger preconditionFailure with a message naming the
// offending parameters — bit-position bugs surface immediately at
// the call site rather than silently corrupting adjacent fields.

import Foundation

/// Parametric bit-field primitives. See file header for the
/// architectural rationale.
public enum BitField {

    // MARK: - Field extract/write

    /// Extract a `width`-bit unsigned field from `bitmap` starting at
    /// `shift`. Returns the field value as a non-negative `Int64`
    /// (high bits zero).
    ///
    /// Example:
    /// ```
    /// // Cookbook §2.3: trust at bits 18–23 (6-bit field).
    /// let trustRaw = BitField.extractField(adjective, shift: 18, width: 6)
    /// // → 0..<64
    /// ```
    ///
    /// - Precondition: `0 <= shift`, `1 <= width <= 64`, `shift + width <= 64`.
    @inlinable
    public static func extractField(_ bitmap: Int64, shift: Int, width: Int) -> Int64 {
        precondition(shift >= 0 && width >= 1 && width <= 64 && shift + width <= 64,
                     "BitField.extractField: invalid shift=\(shift) width=\(width)")
        let mask: Int64 = width == 64 ? -1 : ((Int64(1) << width) - 1)
        return (bitmap >> shift) & mask
    }

    /// Write a `width`-bit field `value` into `bitmap` starting at
    /// `shift`. Existing bits in the field are replaced; bits outside
    /// the field are preserved. Returns the modified bitmap.
    ///
    /// Example:
    /// ```
    /// // Cookbook §2.3: state at bits 0–5 (6-bit field).
    /// let next = BitField.writeField(Int64(newState.rawValue),
    ///                                into: priorBitmap,
    ///                                shift: 0, width: 6)
    /// ```
    ///
    /// - Precondition: `0 <= shift`, `1 <= width <= 64`, `shift + width <= 64`.
    /// - Note: bits in `value` outside the low `width` bits are
    ///   silently truncated. This matches packed-row semantics where
    ///   the field's value space is defined by its width.
    @inlinable
    public static func writeField(_ value: Int64, into bitmap: Int64,
                                  shift: Int, width: Int) -> Int64 {
        precondition(shift >= 0 && width >= 1 && width <= 64 && shift + width <= 64,
                     "BitField.writeField: invalid shift=\(shift) width=\(width)")
        let mask: Int64 = width == 64 ? -1 : ((Int64(1) << width) - 1)
        let cleared = bitmap & ~(mask << shift)
        return cleared | ((value & mask) << shift)
    }

    // MARK: - Masked equality

    /// Test whether the bit-field selected by `mask` in `bitmap`
    /// equals `expected`. Equivalent to `(bitmap & mask) == expected`.
    ///
    /// Per the F18 atomic-centralization rule (cookbook §2.8 / §7.7):
    /// kit-level field-equality checks on packed bitmaps route through
    /// this primitive. `LocusKit/BitmapOps.swift`'s `andMask` becomes a
    /// one-line passthrough, mirroring how `thresholdCompare` and
    /// `shiftExtract` already delegate to `extractField` and `popcount`.
    ///
    /// Semantics: `mask` and `expected` MUST share the same bit range
    /// (caller invariant — `expected` is already shifted into the
    /// field's position). If `expected` has bits set outside `mask`,
    /// the result is `false` for every `bitmap` (natural semantics of
    /// `(bitmap & mask) == expected`); preserved so callers can assert
    /// "no extra bits set, field exactly equals X."
    ///
    /// No precondition on the parameter values: any Int64 inputs are
    /// well-defined. Behavior on the sign bit (negative Int64 values)
    /// is the standard two's-complement bitwise AND, byte-identical
    /// across Swift and Rust.
    ///
    /// Compiles to two instructions on aarch64: `and` then `cmp`. The
    /// primitive's runtime cost matches the prior inline AND+compare.
    ///
    /// - Parameters:
    ///   - bitmap: the full Int64 bitmap.
    ///   - mask: bitmask isolating the field.
    ///   - expected: expected post-mask value, aligned to the field's
    ///     position (not pre-shifted; `mask` and `expected` share the
    ///     same bit range).
    ///
    /// Example:
    /// ```
    /// // Cookbook §2.8: state field at bits 0–3 (4-bit field), test
    /// // whether state == 3 (canonical).
    /// if BitField.maskedEquals(adjective, mask: 0xF, expected: 3) { ... }
    /// ```
    @inlinable
    public static func maskedEquals(_ bitmap: Int64,
                                    mask: Int64,
                                    expected: Int64) -> Bool {
        return (bitmap & mask) == expected
    }

    // MARK: - Flag extract/write

    /// Extract a single-bit flag at position `bit`.
    ///
    /// Example:
    /// ```
    /// // Cookbook §2.3 bit 26: dreaming_recalc_required flag.
    /// if BitField.extractFlag(adjective, bit: 26) { ... }
    /// ```
    ///
    /// - Precondition: `0 <= bit < 64`.
    @inlinable
    public static func extractFlag(_ bitmap: Int64, bit: Int) -> Bool {
        precondition(bit >= 0 && bit < 64,
                     "BitField.extractFlag: invalid bit=\(bit)")
        return ((bitmap >> bit) & 1) == 1
    }

    /// Write a single-bit flag at position `bit`. Other bits in the
    /// bitmap are preserved. Returns the modified bitmap.
    ///
    /// - Precondition: `0 <= bit < 64`.
    @inlinable
    public static func writeFlag(_ flag: Bool, into bitmap: Int64, bit: Int) -> Int64 {
        precondition(bit >= 0 && bit < 64,
                     "BitField.writeFlag: invalid bit=\(bit)")
        if flag {
            return bitmap | (Int64(1) << bit)
        } else {
            return bitmap & ~(Int64(1) << bit)
        }
    }

    // MARK: - Bulk-friendly atomics

    /// Hamming weight (population count) of `value` — the number of
    /// 1-bits. Wraps Swift's `nonzeroBitCount` for the unsigned bit
    /// pattern so behavior on negative `Int64` values is well-defined
    /// (counts all 64 bit positions including the sign bit).
    @inlinable
    public static func popcount(_ value: Int64) -> Int {
        return UInt64(bitPattern: value).nonzeroBitCount
    }

    /// Hamming distance between two bitmaps — the number of bit
    /// positions where they differ. `hammingDistance(a, b) == popcount(a ^ b)`.
    @inlinable
    public static func hammingDistance(_ a: Int64, _ b: Int64) -> Int {
        return popcount(a ^ b)
    }

    /// XOR-fold a sequence of bitmaps — the running XOR over all
    /// values, starting from zero. Used by audit-log reconstruction
    /// (cookbook §5.5) where the row's current bitmap is the XOR of
    /// every delta applied since capture, and by fingerprint-builder
    /// patterns that compose bit patterns by alternating set/unset.
    ///
    /// Empty sequence returns 0 (the XOR identity).
    @inlinable
    public static func xorFold<S: Sequence>(_ values: S) -> Int64 where S.Element == Int64 {
        return values.reduce(0, ^)
    }
}
