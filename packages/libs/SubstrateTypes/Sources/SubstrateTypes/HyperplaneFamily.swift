// HyperplaneFamily.swift
//
// 64 random hyperplanes per fingerprint block, manifest-immutable
// per cookbook § 3.7. Four families total (H_0..H_3), one per
// block of the 256-bit fingerprint.
//
// Each hyperplane is a ±1-valued vector of the appropriate length
// (192 for block 0, 64 for blocks 1–3). For binary inputs, the
// dot product reduces to:
//
//   sign(<v, h>) = sign(popcount(v & h.positive) - popcount(v & h.negative))
//
// The hyperplane is stored as two bit-vector masks (`positive_mask`
// and `negative_mask`) covering its ±1 entries. Bits that are
// neither +1 nor −1 are zero in both masks (sparse hyperplane case;
// see OQ-2.1 in the cookbook).
//
// CONSTITUTIONAL: hyperplane seeds are set at estate creation and
// never rotate within an estate version. Rotation requires a new
// estate or a v2 successor architecture migration. This is what
// makes fingerprints stable across captures and what allows
// cross-replica sync (CRDT § 5) to converge.

import Foundation

/// A single ±1-valued hyperplane of arbitrary bit-length, encoded
/// as two bitmasks. `positive_mask` has a 1 wherever the
/// hyperplane has +1; `negative_mask` has a 1 wherever the
/// hyperplane has −1; both have 0 elsewhere.
public struct Hyperplane: Sendable, Codable, Equatable {
    public let positiveMask: [UInt64]
    public let negativeMask: [UInt64]
    public let bitLength: Int

    public init(positiveMask: [UInt64], negativeMask: [UInt64],
                bitLength: Int) {
        precondition(positiveMask.count == negativeMask.count,
                     "positive and negative masks must have equal length")
        precondition(positiveMask.count * 64 >= bitLength,
                     "mask length must cover bitLength")
        self.positiveMask = positiveMask
        self.negativeMask = negativeMask
        self.bitLength = bitLength
    }

    /// Computes `sign(<v, h>)` for binary `v`. Returns true if
    /// the dot product is strictly positive, false otherwise.
    /// Ties (dot product == 0) resolve to false; the manifest's
    /// seed family is chosen so ties are vanishingly rare in
    /// practice (the per-block input has full bit length, well
    /// past the regime where 0 dot products are common).
    @inlinable
    public func sign(over v: [UInt64]) -> Bool {
        precondition(v.count == positiveMask.count,
                     "input must match hyperplane mask length")
        var pos: Int = 0
        var neg: Int = 0
        for i in 0..<v.count {
            pos &+= (v[i] & positiveMask[i]).nonzeroBitCount
            neg &+= (v[i] & negativeMask[i]).nonzeroBitCount
        }
        return pos > neg
    }
}

/// A family of 64 hyperplanes covering one fingerprint block.
/// Lives in the estate manifest under `hyperplane_seeds.H_n`.
public struct HyperplaneFamily: Sendable, Codable, Equatable {
    public let blockIndex: Int          // 0, 1, 2, or 3
    public let inputBitLength: Int      // 192 for block 0, 64 for blocks 1–3
    public let planes: [Hyperplane]     // exactly 64 planes

    public init(blockIndex: Int,
                inputBitLength: Int,
                planes: [Hyperplane]) {
        precondition((0..<4).contains(blockIndex),
                     "block index must be 0..3")
        precondition(planes.count == 64,
                     "hyperplane family requires exactly 64 planes")
        precondition(planes.allSatisfy { $0.bitLength == inputBitLength },
                     "all planes must share input bit length")
        self.blockIndex = blockIndex
        self.inputBitLength = inputBitLength
        self.planes = planes
    }

    /// Deterministic generation from a 32-byte seed. Used at
    /// estate creation to populate the manifest. Two estates with
    /// the same seed produce identical families; two estates with
    /// different seeds produce incompatible fingerprints.
    ///
    /// `density` controls the proportion of non-zero entries in
    /// each plane. 1.0 means dense ±1; 0.5 means roughly half
    /// the bits are 0 (sparse hyperplane case from OQ-2.1).
    public static func generate(seed: [UInt8],
                                blockIndex: Int,
                                inputBitLength: Int,
                                density: Double = 1.0) -> HyperplaneFamily {
        precondition(seed.count == 32, "seed must be 32 bytes")
        precondition(density > 0 && density <= 1.0,
                     "density must be in (0, 1]")
        var rng = HyperplanePRNG(seed: seed)
        let wordCount = (inputBitLength + 63) / 64
        var planes = [Hyperplane]()
        planes.reserveCapacity(64)
        for _ in 0..<64 {
            var pos = [UInt64](repeating: 0, count: wordCount)
            var neg = [UInt64](repeating: 0, count: wordCount)
            for bit in 0..<inputBitLength {
                let r = rng.next()
                // Compute activeThreshold safely. At density = 1.0,
                // Double(UInt64.max) rounds up past UInt64.max and
                // UInt64(...) would trap; treat density >= 1.0 as
                // "every bit active" without going through the
                // floating-point round-trip.
                let isActive: Bool
                if density >= 1.0 {
                    isActive = true
                } else {
                    let activeThreshold = UInt64(Double(UInt64.max) * density)
                    isActive = r < activeThreshold
                }
                if isActive {
                    // Active bit: choose +1 or -1 by another draw
                    let signDraw = rng.next()
                    if signDraw & 1 == 1 {
                        pos[bit / 64] |= (UInt64(1) << (bit % 64))
                    } else {
                        neg[bit / 64] |= (UInt64(1) << (bit % 64))
                    }
                }
            }
            planes.append(Hyperplane(positiveMask: pos,
                                     negativeMask: neg,
                                     bitLength: inputBitLength))
        }
        return HyperplaneFamily(blockIndex: blockIndex,
                                 inputBitLength: inputBitLength,
                                 planes: planes)
    }

    /// Stable 64-bit hash of the family's content, used for audit
    /// trails when a pairing is established or dissolved. FNV-1a
    /// over the canonical wire serialization: blockIndex (1 byte),
    /// inputBitLength (4 bytes BE), then for each of the 64
    /// planes the positiveMask and negativeMask words BE.
    public func canonicalHash() -> UInt64 {
        var h: UInt64 = 0xCBF29CE484222325
        func mix(_ b: UInt8) {
            h ^= UInt64(b)
            h = h &* 0x100000001B3
        }
        mix(UInt8(truncatingIfNeeded: self.blockIndex))
        let len = UInt32(self.inputBitLength)
        for shift in stride(from: 24, through: 0, by: -8) {
            mix(UInt8((len >> shift) & 0xFF))
        }
        for plane in self.planes {
            for w in plane.positiveMask {
                for shift in stride(from: 56, through: 0, by: -8) {
                    mix(UInt8((w >> shift) & 0xFF))
                }
            }
            for w in plane.negativeMask {
                for shift in stride(from: 56, through: 0, by: -8) {
                    mix(UInt8((w >> shift) & 0xFF))
                }
            }
        }
        return h
    }
}

// MARK: - HyperplanePRNG PRNG
//
// Deterministic, fast, well-mixed PRNG suitable for generating
// hyperplane bit patterns from a 32-byte seed. Not cryptographic;
// fine here because the hyperplane content is not secret (the
// manifest is plaintext) — what matters is determinism and good
// statistical distribution.

private struct HyperplanePRNG {
    private var state: UInt64

    init(seed: [UInt8]) {
        precondition(seed.count == 32, "seed must be 32 bytes")
        var s: UInt64 = 0
        for i in 0..<8 {
            s |= UInt64(seed[i]) << (i * 8)
        }
        // Mix in the next 24 bytes so all seed bits influence state.
        for chunk in 1..<4 {
            var w: UInt64 = 0
            for i in 0..<8 {
                w |= UInt64(seed[chunk * 8 + i]) << (i * 8)
            }
            s ^= w &+ 0x9E3779B97F4A7C15
        }
        self.state = s
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - Manifest hookup
//
// In production LocusKit, the four families live as:
//
//   manifest.hyperplane_seeds.H_0 (block 0, 192-bit, 24-byte planes)
//   manifest.hyperplane_seeds.H_1 (block 1, 64-bit,  8-byte planes)
//   manifest.hyperplane_seeds.H_2 (block 2, 64-bit,  8-byte planes)
//   manifest.hyperplane_seeds.H_3 (block 3, 64-bit,  8-byte planes)
//
// Total storage: 24*64 + 8*64*3 = 3072 bytes per estate.
//
// Federation extends with H_shared_household, H_shared_fleet,
// H_shared_company, H_shared_industry, H_shared_msp — same
// generation, different seeds per pairing scope.

// MARK: - Canonical block-family generation
//
// One routine builds the four-block family set, for the estate-local
// families and the shared pairing families alike, so the two cannot
// drift apart. It fixes two faults that the ad hoc shared-family
// generation carried: `generate` does not vary its output on
// `blockIndex`, so a single base seed reused across the four blocks
// collapses them into one projection; and the four blocks have
// different input widths (block 0 is the 192-bit bitmap triple, blocks
// 1 through 3 are 64-bit facet words, cookbook section 3), not a
// uniform 64.

public extension HyperplaneFamily {

    /// Canonical per-block SimHash input widths (cookbook section 3).
    static let canonicalBlockWidths: [Int] = [192, 64, 64, 64]

    /// Generate the canonical four-block family set from one 32-byte
    /// base seed. The base is diversified per block so the four
    /// families are independent, and each block uses its canonical
    /// input width.
    static func blockFamilies(baseSeed: [UInt8], density: Double = 1.0) -> [HyperplaneFamily] {
        precondition(baseSeed.count == 32, "base seed must be 32 bytes")
        return (0..<4).map { block in
            HyperplaneFamily.generate(
                seed: diversifiedSeed(base: baseSeed, blockIndex: block),
                blockIndex: block,
                inputBitLength: canonicalBlockWidths[block],
                density: density)
        }
    }

    /// Mix a block index into a 32-byte base seed and expand the result
    /// back to 32 bytes, giving each block an independent seed.
    /// Deterministic and identical across the Swift and Rust ports.
    static func diversifiedSeed(base: [UInt8], blockIndex: Int) -> [UInt8] {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in base {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01B3
        }
        h ^= UInt64(UInt8(truncatingIfNeeded: blockIndex))
        h = h &* 0x0000_0100_0000_01B3
        return expandSeed64(h)
    }

    /// Expand a 64-bit seed to 32 bytes via four SplitMix64 rounds.
    static func expandSeed64(_ seed: UInt64) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(32)
        var s = seed
        for _ in 0..<4 {
            s = s &+ 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            for j in 0..<8 {
                out.append(UInt8((z >> (j * 8)) & 0xFF))
            }
        }
        return out
    }
}
