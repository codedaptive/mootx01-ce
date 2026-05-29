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

    /// In-place single-bit setter. `index` in 0..<256.
    public mutating func setBit(at index: Int, to on: Bool = true) {
        precondition((0..<256).contains(index), "fingerprint bit index out of range")
        let block = index / 64
        let mask = UInt64(1) << UInt64(index % 64)
        switch block {
        case 0: self.block0 = on ? (self.block0 | mask) : (self.block0 & ~mask)
        case 1: self.block1 = on ? (self.block1 | mask) : (self.block1 & ~mask)
        case 2: self.block2 = on ? (self.block2 | mask) : (self.block2 & ~mask)
        default: self.block3 = on ? (self.block3 | mask) : (self.block3 & ~mask)
        }
    }

    /// Pairwise bitwise OR. Returns a new fingerprint whose blocks
    /// are `self.block_i | other.block_i`.
    public func bitwiseOR(_ other: Fingerprint256) -> Fingerprint256 {
        return Fingerprint256(
            block0: self.block0 | other.block0,
            block1: self.block1 | other.block1,
            block2: self.block2 | other.block2,
            block3: self.block3 | other.block3
        )
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
