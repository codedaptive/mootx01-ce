// Hamming.swift
//
// Hamming distance over Fingerprint256 per cookbook § 8.2.
//
// Hamming distance is the substrate's primary structural-
// similarity primitive. For two 256-bit fingerprints A and B,
// the distance is the number of bit positions where they differ.
// Implemented as XOR followed by popcount, summed across blocks.
//
// Per-block Hamming answers a more targeted question: limiting
// the distance to specific blocks (the `blocks` parameter) gives
// distance over just the bitmap aspect, just the lattice aspect,
// or any subset. This is what `recall_partial_match` (cookbook
// § 11.10) exploits.

import Foundation

/// Block 2a/2b code uses `HammingDistance.distance(_:_:)` (the
/// explicit-namespace form). Canonical implementation is
/// `Hamming.distance(_:_:)`; this alias re-exports the namespace.
public typealias HammingDistance = Hamming

public enum Hamming {

    /// Hamming distance between two 256-bit fingerprints. Default
    /// uses all four blocks (full 256-bit distance). Restrict via
    /// `blocks` for per-aspect distance.
    ///
    /// Returns an integer in [0, 64 * blocks.blockCount]. For the
    /// full fingerprint that's [0, 256].
    ///
    /// Phase 4.1 (decision 2026-05-28 §6.4.1): the `Set<Int>`
    /// parameter is replaced with `BlockMask: OptionSet<UInt8>`.
    /// Zero allocation, branchless `contains`. Mirrors the Rust
    /// side's existing `u8` block-mask shape.
    @inlinable
    public static func distance(_ a: Fingerprint256,
                                _ b: Fingerprint256,
                                blocks: BlockMask = .all) -> Int {
        // Full-blocks fast path — the common case.
        if blocks == .all {
            return a.zip4(b, ^).popcount()
        }
        var d: Int = 0
        if blocks.contains(.block0) { d &+= (a.block0 ^ b.block0).nonzeroBitCount }
        if blocks.contains(.block1) { d &+= (a.block1 ^ b.block1).nonzeroBitCount }
        if blocks.contains(.block2) { d &+= (a.block2 ^ b.block2).nonzeroBitCount }
        if blocks.contains(.block3) { d &+= (a.block3 ^ b.block3).nonzeroBitCount }
        return d
    }

    /// Hamming similarity in [0, 1]. 1.0 = identical, 0.0 =
    /// maximally distant. Defined as 1 - (distance / max).
    public static func similarity(_ a: Fingerprint256,
                                   _ b: Fingerprint256,
                                   blocks: BlockMask = .all) -> Double {
        let max = 64 * blocks.blockCount
        guard max > 0 else { return 1.0 }
        return 1.0 - Double(distance(a, b, blocks: blocks)) / Double(max)
    }
}

// MARK: - Performance notes
//
// On Apple Silicon, the natural implementation is the loop above
// — four 64-bit XORs and four popcount instructions per pair.
// That's ~5ns per pair on M-series cores; for top-K search over
// 1M rows the bottleneck is memory bandwidth (read 1M × 32 bytes
// = 32 MB) at ~60 GB/s = ~500 µs total. Well within the cookbook
// § 17 budget.
//
// The NeuronKit production implementation wraps this in a kernel
// layer (cookbook § 4.4) that selects AMX, AVX-512, NEON, or
// scalar based on CPU detection. The scalar reference here is
// the authoritative source: every backend MUST produce the same
// integer output for every input pair (validated by CRC against
// the v0.36 reference vectors in conformance/kernel/).

// MARK: - Test vectors (illustrative)
//
//   distance(zero, zero)                            = 0
//   distance(zero, fingerprint(1, 0, 0, 0))         = 1
//   distance(zero, fingerprint(~0, ~0, ~0, ~0))     = 256
//   distance(a, b, blocks: [0]) ∈ [0, 64]
//   similarity(a, a)                                = 1.0
