import Foundation
import SubstrateTypes
import SubstrateKernel
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateLib

/// Packed-layout field-extraction helpers per cookbook § 2.8.
///
/// LocusKit stores three packed Int64 bitmaps per drawer (adjective,
/// operational, provenance). The recall evaluator reads typed fields
/// out of those packed bitmaps via the three functions below.
///
/// These are NOT math primitives. They are domain-layout accessors:
/// they read named bit fields out of a single Int64 according to the
/// cookbook § 2.8 packing rules. They have no algorithm to prove and
/// no platform optimization to gate — each compiles to one or two
/// Swift instructions and is `@inlinable` so the evaluator's hot path
/// is a single instruction sequence per row.
///
/// The math primitives (XOR, popcount, Hamming, OR-reduction, SimHash,
/// SHA-256, etc.) live in SubstrateLib at Fingerprint256 width, where
/// they participate in the conformance gate and the platform-kernel
/// dispatch (cookbook § 4.4). Earlier revisions of this file also
/// defined `xor`, `isIdentical`, `hammingDistance`, and `simdBallot`
/// as Int64-width local functions; those were redundant restatements
/// of the spec primitive set and were removed in the v0.8 provenance
/// clean (F1). Code needing those operations constructs a
/// Fingerprint256 and calls SubstrateLib.

// MARK: - AND-with-mask

/// Test whether the field at `mask` equals `expected`.
/// Compiles to: `(bitmap & mask) == expected`.
/// Per spec § 7.7: "field equality on contiguous fields, 1 instruction."
///
/// - Parameters:
///   - bitmap: the full Int64 bitmap column value.
///   - mask: bitmask isolating the field (e.g. `0xF` for bits 0–3).
///   - expected: the field's expected value, already aligned to the
///     field's position (i.e. NOT pre-shifted; the mask and expected
///     share the same bit range).
@inlinable
public func andMask(_ bitmap: Int64, mask: Int64, expected: Int64) -> Bool {
    // F18.2b atomic centralization: route through SubstrateLib's gated
    // primitive instead of open-coding the AND+compare. Semantically
    // identical — `(bitmap & mask) == expected` — but the single
    // byte-identical implementation now lives in BitField.maskedEquals
    // (conformance-gated, CRC 0x54f6c65f). This façade preserves the
    // existing `andMask` call sites, mirroring how `thresholdCompare`
    // and `shiftExtract` delegate to `extractField`/`popcount`.
    BitField.maskedEquals(bitmap, mask: mask, expected: expected)
}

// MARK: - Threshold-compare

/// Comparison operators used by `thresholdCompare`.
public enum ThresholdOp: Sendable {
    /// Field value is strictly less than `value`. Used for open-upper
    /// cluster boundaries (e.g. `state < 3` for know-now).
    case lessThan
    /// Field value is less than or equal to `value`.
    case lessThanOrEqual
    /// Field value is greater than or equal to `value`. Used for
    /// open-lower cluster boundaries (e.g. `state >= 3` for knew-past).
    case greaterThanOrEqual
}

/// Test whether a field satisfies a threshold condition.
/// Extracts the field at `mask`/`shift` then compares with `op`.
/// Per spec § 7.7: "cluster membership on gradient-ordered fields,
/// 1 instruction (after AND-mask)."
///
/// - Parameters:
///   - bitmap: the full Int64 bitmap column value.
///   - mask: bitmask isolating the field before shifting.
///   - shift: right-shift to apply after masking, so the field value
///     is in the integer's low bits (e.g. `shift: 12` for trust field).
///   - op: comparison operator.
///   - value: threshold value to compare against (in field-natural units,
///     i.e. after the shift has been applied).
@inlinable
public func thresholdCompare(
    _ bitmap: Int64,
    mask: Int64,
    shift: Int,
    op: ThresholdOp,
    value: Int64
) -> Bool {
    // F18 atomic centralization: `mask` is high-aligned (already shifted
    // into the field's position, e.g. 0x3F << 18 for trust). Field width
    // is popcount(mask); BitField extracts and returns the low-aligned
    // field value, which is the same shape the threshold compares against.
    // A zero mask yields field 0, preserving the prior `(bitmap & 0) >> s`.
    let field = mask == 0 ? 0 : BitField.extractField(bitmap, shift: shift, width: BitField.popcount(mask))
    switch op {
    case .lessThan:            return field < value
    case .lessThanOrEqual:     return field <= value
    case .greaterThanOrEqual:  return field >= value
    }
}

// MARK: - Shift-extract

/// Extract a field value as an integer.
/// Per spec § 7.7: "field value as integer, 1 instruction."
///
/// - Parameters:
///   - bitmap: the full Int64 bitmap column value.
///   - shift: right-shift to align the field to bit 0.
///   - mask: bitmask applied AFTER shifting to isolate the field width.
@inlinable
public func shiftExtract(_ bitmap: Int64, shift: Int, mask: Int64) -> Int64 {
    // F18 atomic centralization: route through SubstrateLib's parametric
    // primitive. `mask` is low-aligned (e.g. 0x3F for a 6-bit field), so
    // the field width is popcount(mask). For constant masks the compiler
    // folds popcount to a literal; runtime cost matches the prior inline.
    // A zero mask is the "no field" degenerate case — the façade defines
    // it as 0 (BitField's primitive rejects width 0 by precondition).
    guard mask != 0 else { return 0 }
    return BitField.extractField(bitmap, shift: shift, width: BitField.popcount(mask))
}

