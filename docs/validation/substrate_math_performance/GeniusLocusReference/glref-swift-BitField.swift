// BitField.swift
//
// Parametric bit-field primitives for the substrate's packed-row
// bitmap encoding. Per the F18 atomic-centralization rule (cookbook
// §1 / §2.8 / KIT_INTERFACE_DESIGN / MOOTX01_AND_ARIA_CANON): every
// kit-level bit operation routes through this module.
//
// This file is the GeniusLocusReference Swift oracle — byte-identical
// to packages/libs/SubstrateLib/Sources/SubstrateLib/BitField.swift.
// Mirror of glref-rust-bit_field.rs. The conformance harness validates
// production implementations against this reference.
//
// Naming convention:
//   extractField / writeField — multi-bit fields with named width
//   extractFlag  / writeFlag  — single-bit flags
//   maskedEquals              — field-equality predicate (F18.2b)
//   popcount, hammingDistance, xorFold — bulk-friendly atomics
//
// All operations are pure functions over Int64 (or [Int64]); no
// allocation, no side effects, predictable cost.
//
// Bounds: shift ∈ [0, 64), width ∈ [1, 64], shift + width ≤ 64.

import Foundation

/// Parametric bit-field primitives. See file header for rationale.
public enum BitField {

    // MARK: - Field extract/write

    /// Extract a `width`-bit unsigned field from `bitmap` starting at
    /// `shift`. Returns the field value as a non-negative `Int64`.
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
    /// - Precondition: `0 <= shift`, `1 <= width <= 64`, `shift + width <= 64`.
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
    /// Per F18.2b: the gated primitive that kit-level field-equality
    /// checks route through. `LocusKit/BitmapOps.swift`'s `andMask`
    /// becomes a one-line passthrough, mirroring how `thresholdCompare`
    /// and `shiftExtract` already delegate to `extractField` and
    /// `popcount`.
    ///
    /// Semantics: `mask` and `expected` MUST share the same bit range
    /// (caller invariant). If `expected` has bits set outside `mask`,
    /// the result is `false` for every `bitmap` (natural semantics of
    /// `(bitmap & mask) == expected`); preserved so callers can assert
    /// "no extra bits set, field exactly equals X."
    ///
    /// No precondition on the parameter values: any Int64 inputs are
    /// well-defined. Sign-bit behavior is the standard two's-complement
    /// bitwise AND, byte-identical across Swift and Rust.
    @inlinable
    public static func maskedEquals(_ bitmap: Int64,
                                    mask: Int64,
                                    expected: Int64) -> Bool {
        return (bitmap & mask) == expected
    }

    // MARK: - Flag extract/write

    /// Extract a single-bit flag at position `bit`.
    ///
    /// - Precondition: `0 <= bit < 64`.
    @inlinable
    public static func extractFlag(_ bitmap: Int64, bit: Int) -> Bool {
        precondition(bit >= 0 && bit < 64,
                     "BitField.extractFlag: invalid bit=\(bit)")
        return ((bitmap >> bit) & 1) == 1
    }

    /// Write a single-bit flag at position `bit`. Other bits preserved.
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

    /// Hamming weight (population count) of `value`.
    @inlinable
    public static func popcount(_ value: Int64) -> Int {
        return UInt64(bitPattern: value).nonzeroBitCount
    }

    /// Hamming distance between two bitmaps.
    @inlinable
    public static func hammingDistance(_ a: Int64, _ b: Int64) -> Int {
        return popcount(a ^ b)
    }

    /// XOR-fold a sequence of bitmaps.
    @inlinable
    public static func xorFold<S: Sequence>(_ values: S) -> Int64 where S.Element == Int64 {
        return values.reduce(0, ^)
    }
}
