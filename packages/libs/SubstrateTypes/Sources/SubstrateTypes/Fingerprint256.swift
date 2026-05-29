// Fingerprint256.swift
//
// 256-bit epistemic fingerprint per
// docs/specs/GENIUSLOCUS_ENGINEERING_COOKBOOK_v0.36_2026-05-16.md
// § 3.1.
//
// The fingerprint is the substrate's universal coordinate system
// for STRUCTURAL similarity, distinct from the lattice anchor
// (which is the universal coordinate system for TOPIC similarity).
// Hamming distance over fingerprints is the cognition tier's
// primary structural-similarity primitive.
//
// Four 64-bit blocks, each a SimHash over a different aspect of
// the row:
//
//   block0 (bits 0–63)    Bitmap-LSH      § 3.2
//   block1 (bits 64–127)  Lattice-LSH     § 3.3
//   block2 (bits 128–191) Lineage+Temp    § 3.4
//   block3 (bits 192–255) Channel+Source  § 3.5
//
// Hamming distance over the full fingerprint is the sum of
// per-block Hamming distances. Per-block distance answers a more
// targeted similarity question (e.g. "same topic neighborhood"
// independent of temporal block).
//
// I-17 (cross-noun fingerprint compatibility): every noun type
// produces fingerprints in this same four-block structure under
// the same per-block hyperplane families. Missing fields fill
// with a deterministic null sub-hash so Hamming distance remains
// well-defined across pairs of noun types.

import Foundation

/// 256-bit row fingerprint, four 64-bit blocks.
///
/// `block0` carries Bitmap-LSH, `block1` Lattice-LSH, `block2`
/// Lineage+Temporal, `block3` Channel+Source. See cookbook § 3
/// for block-by-block construction rules.
///
/// Equality, hashing, and codable conformance follow from the
/// four `UInt64` components. The wire format is 32 bytes
/// little-endian by block index.
public struct Fingerprint256: Hashable, Sendable, Codable {
    public var block0: UInt64
    public var block1: UInt64
    public var block2: UInt64
    public var block3: UInt64

    public init(block0: UInt64, block1: UInt64,
                block2: UInt64, block3: UInt64) {
        self.block0 = block0
        self.block1 = block1
        self.block2 = block2
        self.block3 = block3
    }

    /// The all-zeros fingerprint. Used as the OR-reduce identity
    /// and as the null fingerprint for absent blocks.
    public static let zero = Fingerprint256(
        block0: 0, block1: 0, block2: 0, block3: 0)

    /// Adapter for Block 2a/2b code that addresses blocks via a
    /// 4-element `words` array. The canonical access pattern uses
    /// `block0`..`block3`; this property exposes the same data as
    /// an array for callers that prefer indexed access.
    public var words: [UInt64] {
        get { [block0, block1, block2, block3] }
        set {
            precondition(newValue.count == 4, "words must have exactly 4 elements")
            self.block0 = newValue[0]
            self.block1 = newValue[1]
            self.block2 = newValue[2]
            self.block3 = newValue[3]
        }
    }

    /// Single-bit accessor. `index` in 0..<256.
    public func testBit(at index: Int) -> Bool { return self.bit(at: index) }

    /// Returns a copy with the bit at `index` set to `on`.
    /// `index` in 0..<256.
    ///
    /// Phase 4.2 (decision 2026-05-28 §6.4.2): value-semantic
    /// replacement for the prior `mutating func setBit(at:to:)`.
    /// Callers do `fp = fp.with(bit: i)` or
    /// `fp = fp.with(bit: i, set: false)`.
    @inlinable
    public func with(bit index: Int, set on: Bool = true) -> Fingerprint256 {
        precondition((0..<256).contains(index), "fingerprint bit index out of range")
        let mask = UInt64(1) << UInt64(index % 64)
        switch index / 64 {
        case 0:
            return Fingerprint256(
                block0: on ? (block0 | mask) : (block0 & ~mask),
                block1: block1, block2: block2, block3: block3)
        case 1:
            return Fingerprint256(
                block0: block0,
                block1: on ? (block1 | mask) : (block1 & ~mask),
                block2: block2, block3: block3)
        case 2:
            return Fingerprint256(
                block0: block0, block1: block1,
                block2: on ? (block2 | mask) : (block2 & ~mask),
                block3: block3)
        default:
            return Fingerprint256(
                block0: block0, block1: block1, block2: block2,
                block3: on ? (block3 | mask) : (block3 & ~mask))
        }
    }

    /// Bitwise OR with another fingerprint — set-union semantics.
    ///
    /// Phase 4.2 (decision 2026-05-28 §6.4.2): renamed from
    /// `bitwiseOR(_:)` for parity with `EngramLib.union` and to
    /// match the value-semantic naming convention. Internally
    /// delegates to `zip4` with `|`.
    @inlinable
    public func union(_ other: Fingerprint256) -> Fingerprint256 {
        return self.zip4(other, |)
    }

    /// Bit-indexed access. `index` in 0..<256. Bit 0 is the
    /// least-significant bit of `block0`.
    public func bit(at index: Int) -> Bool {
        precondition((0..<256).contains(index),
                     "fingerprint bit index out of range")
        let block: UInt64
        switch index / 64 {
        case 0: block = block0
        case 1: block = block1
        case 2: block = block2
        default: block = block3
        }
        return (block >> (index % 64)) & 1 == 1
    }

    /// Returns the `UInt64` for block `index` in 0..<4.
    public func block(at index: Int) -> UInt64 {
        switch index {
        case 0: return block0
        case 1: return block1
        case 2: return block2
        case 3: return block3
        default:
            preconditionFailure("fingerprint block index out of range")
        }
    }

    /// Constructs a `Fingerprint256` from a 256-bit array of bits.
    /// Bit `n` of input lands at index `n` of the fingerprint.
    public static func fromBits(_ bits: [Bool]) -> Fingerprint256 {
        precondition(bits.count == 256,
                     "fingerprint requires exactly 256 bits")
        var b = [UInt64](repeating: 0, count: 4)
        for i in 0..<256 where bits[i] {
            b[i / 64] |= (UInt64(1) << (i % 64))
        }
        return Fingerprint256(
            block0: b[0], block1: b[1], block2: b[2], block3: b[3])
    }

    /// 32-byte little-endian wire encoding. Block 0 first, byte
    /// order within each block is little-endian.
    public var wireBytes: [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        for word in [block0, block1, block2, block3] {
            for shift in stride(from: 0, through: 56, by: 8) {
                bytes.append(UInt8((word >> shift) & 0xFF))
            }
        }
        return bytes
    }

    /// Inverse of `wireBytes`. Throws on incorrect length.
    public init(wireBytes bytes: [UInt8]) throws {
        guard bytes.count == 32 else {
            throw Fingerprint256Error.invalidWireLength(bytes.count)
        }
        func word(at start: Int) -> UInt64 {
            var w: UInt64 = 0
            for i in 0..<8 {
                w |= UInt64(bytes[start + i]) << (i * 8)
            }
            return w
        }
        self.init(
            block0: word(at: 0),
            block1: word(at: 8),
            block2: word(at: 16),
            block3: word(at: 24))
    }
}

public enum Fingerprint256Error: Error, Sendable {
    case invalidWireLength(Int)
}

extension Fingerprint256 {
    /// Adapter alias for `wireBytes`, used by tier contribution
    /// fingerprint code (§ 12.3) that names the operation
    /// `toBytes()` for symmetry with the Rust port.
    public func toBytes() -> [UInt8] { return self.wireBytes }

    /// Adapter alias for `init(wireBytes:)`, returning nil on
    /// invalid length rather than throwing. Used by code that
    /// prefers an optional return to throws.
    public static func fromBytes(_ bytes: [UInt8]) -> Fingerprint256? {
        return try? Fingerprint256(wireBytes: bytes)
    }
}

// MARK: - Test vectors (cookbook conformance § 18.2)
//
// These are illustrative; the canonical Tier-2 test vectors will
// live in glref-test-vectors-fingerprint.json once the matching
// Rust harness lands.
//
// fingerprint(0, 0, 0, 0)            → wireBytes all zero
// fingerprint(1, 0, 0, 0).bit(at: 0) → true
// fingerprint(0, 1, 0, 0).bit(at: 64) → true
// fingerprint(0x...).hammingDistance(fingerprint(0x...)) — see Hamming.swift

// MARK: - Phase 1 combinator layer
//
// Per DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md §6 Phase 1
// (Clojure convergent A; APL convergent A; Cursor convergent D; ML
// convergent D). The four-block unroll that appears in 7+ files
// (`ORReduce.reduce`, `ORReduce.merge`, `BitwiseArithmetic.intersect`,
// `BitwiseArithmetic.difference`, `Hamming.distance`,
// `ScalarKernel.hammingDistance256`, `ScalarKernel.orReduce256`) is
// one expression in APL. These combinators express it once and let
// the higher-level reductions (Phase 2) collapse to one-liners.
//
// All operations are pure on the four `UInt64` blocks. No kernel
// dispatch; backends can override Phase-2-rewritten consumers if
// they need hardware acceleration.
//
// Conformance impact: zero. Output bit-identical to existing
// per-call unrolls.

extension Fingerprint256 {

    /// Apply a binary block operation pairwise across two
    /// fingerprints. The operator is invoked on each of the four
    /// `(self.blockN, other.blockN)` pairs.
    ///
    /// Used by Phase 2 to express intersect, difference, and the
    /// XOR step of Hamming distance as one-liners.
    @inlinable
    public func zip4(_ other: Fingerprint256,
                     _ op: (UInt64, UInt64) -> UInt64) -> Fingerprint256 {
        return Fingerprint256(
            block0: op(self.block0, other.block0),
            block1: op(self.block1, other.block1),
            block2: op(self.block2, other.block2),
            block3: op(self.block3, other.block3)
        )
    }

    /// Reduce a sequence of fingerprints with a binary block
    /// operator. The starting accumulator is `Fingerprint256.zero`,
    /// which is the identity for `|` and `^`. For operators whose
    /// identity is not zero (e.g. `&`), the caller is responsible
    /// for non-empty inputs.
    ///
    /// Replaces `ORReduce.reduce` in Phase 2.
    @inlinable
    public static func reduce4<S: Sequence>(
        _ xs: S,
        _ op: (UInt64, UInt64) -> UInt64
    ) -> Fingerprint256 where S.Element == Fingerprint256 {
        return xs.reduce(Fingerprint256.zero) { acc, x in acc.zip4(x, op) }
    }

    /// Apply a unary block operation to each of the four blocks.
    /// Used by Phase 2 for negation, shifting, and complement
    /// patterns.
    @inlinable
    public func map4(_ op: (UInt64) -> UInt64) -> Fingerprint256 {
        return Fingerprint256(
            block0: op(self.block0),
            block1: op(self.block1),
            block2: op(self.block2),
            block3: op(self.block3)
        )
    }

    /// Population count over all 256 bits.
    ///
    /// Replaces the inlined `nonzeroBitCount` sum in
    /// `Hamming.distance` (after Phase 2's `a.zip4(b, ^).popcount()`
    /// rewrite).
    @inlinable
    public func popcount() -> Int {
        return self.block0.nonzeroBitCount
             + self.block1.nonzeroBitCount
             + self.block2.nonzeroBitCount
             + self.block3.nonzeroBitCount
    }

    // MARK: - Batch siblings
    //
    // The grain ML inference and Cursor retrieval needs (decision
    // doc Cursor convergent D + ML convergent D). Vectorize across
    // rows rather than across blocks.

    /// Pairwise zip4 across two equal-length arrays of fingerprints.
    /// Returns `[]` when the arrays differ in length (caller-defensive;
    /// in debug builds this asserts).
    @inlinable
    public static func zip4Batch(
        _ a: [Fingerprint256],
        _ b: [Fingerprint256],
        _ op: (UInt64, UInt64) -> UInt64
    ) -> [Fingerprint256] {
        assert(a.count == b.count,
               "Fingerprint256.zip4Batch requires equal-length inputs")
        guard a.count == b.count else { return [] }
        var out = [Fingerprint256]()
        out.reserveCapacity(a.count)
        for i in 0..<a.count {
            out.append(a[i].zip4(b[i], op))
        }
        return out
    }

    /// map4 across an array of fingerprints.
    @inlinable
    public static func map4Batch(
        _ xs: [Fingerprint256],
        _ op: (UInt64) -> UInt64
    ) -> [Fingerprint256] {
        var out = [Fingerprint256]()
        out.reserveCapacity(xs.count)
        for x in xs {
            out.append(x.map4(op))
        }
        return out
    }
}
