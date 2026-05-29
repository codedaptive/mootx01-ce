// PortableKernel-NEON.swift
//
// Direct-NEON-intrinsics kernel implementation per
// DECISION_HAMMING_BACKENDS_2026-05-17.md Phase 2.β-2 candidate
// expansion. Tests whether expressing the Hamming inner loop at
// the byte-vector level (SIMD32<UInt8>) instead of the four-u64
// level (SIMD4<UInt64>) produces tighter NEON codegen.
//
// The hypothesis: SIMD4<UInt64> + nonzeroBitCount per lane goes
// through four scalar count_ones() reductions before summing.
// SIMD32<UInt8> + nonzeroBitCount per lane should compile to
// cnt.16b (two of them for 32 bytes) plus a single addv reduction
// across the full byte vector, which is what Mula's canonical
// sse-popcount reference recommends.
//
// Whether this actually saves cycles depends on what the Swift
// compiler decides to emit. The methodology gate insists we
// implement and measure rather than assume. This kernel is the
// instrument; the benchmark sweep is the measurement.
//
// Swift-only. The harness skips this kernel on non-Apple
// platforms via the kernel registry's #if predicates (specifically
// the canImport(simd) check, which is reliably available only on
// Darwin platforms).
//
// Conformance: every method must produce byte-identical output
// to ScalarKernel. The conformance gate verifies this when invoked
// with --kernel neon.

import Foundation
import simd
import SubstrateTypes

/// Direct-NEON kernel candidate for Hamming-class ops. Currently
/// specializes hammingDistance256 / hammingDistanceBatch /
/// hammingTopK; inherits scalar for OR-reduce and SimHash since
/// the byte-vector framing helps Hamming specifically (XOR +
/// per-byte popcount + horizontal sum).
public struct NeonKernel: SubstrateKernel {

    public init() {}

    public var kind: KernelKind { .neon }

    // ----- popcount64 (inherited semantics)

    @inlinable
    public func popcount64(_ x: UInt64) -> Int {
        return x.nonzeroBitCount
    }

    // ----- Hamming via SIMD32<UInt8> XOR + per-byte popcount + horizontal sum

    /// Pack a Fingerprint256 into SIMD32<UInt8>. Each of the
    /// four UInt64 blocks contributes 8 bytes in little-endian
    /// order. Matches the on-the-wire layout used elsewhere.
    ///
    /// Implementation note: Fingerprint256 is laid out as four
    /// contiguous UInt64 blocks, exactly the same 32-byte payload
    /// as SIMD32<UInt8>. We `load(as:)` the raw bytes as a single
    /// 256-bit move; previous versions copied byte-by-byte and
    /// the conversion dominated the inner loop cost.
    @inline(__always)
    static func toBytes(_ fp: Fingerprint256) -> SIMD32<UInt8> {
        var local = fp
        return withUnsafeBytes(of: &local) { raw -> SIMD32<UInt8> in
            // Apple Silicon is little-endian; the 32-byte memory
            // image of Fingerprint256 (four contiguous UInt64s)
            // matches the 32-lane UInt8 view byte-for-byte.
            // Bit-popcount of the XOR is identical between the
            // SIMD4<UInt64> view and this view.
            return raw.load(as: SIMD32<UInt8>.self)
        }
    }

    /// Per-byte popcount via SIMD32<UInt8>.
    /// Swift's `import simd` does not expose a vector-wide
    /// popcount primitive; the lane-wise nonzeroBitCount fills
    /// the result vector via 32 scalar ops. Compared to the
    /// SIMD4<UInt64> approach (4 scalar nonzeroBitCount calls
    /// that the compiler lowers to `cnt.16b`), this has 8x more
    /// scalar ops per lane and the compiler does not appear to
    /// re-vectorize them. Phase 2.β-2 measurement quantifies
    /// the gap; if Swift exposes a real vector-popcount primitive
    /// in a future toolchain, this kernel becomes worth
    /// re-measuring.
    @inline(__always)
    static func popcountBytes(_ v: SIMD32<UInt8>) -> SIMD32<UInt8> {
        var out = SIMD32<UInt8>()
        for i in 0..<32 { out[i] = UInt8(v[i].nonzeroBitCount) }
        return out
    }

    /// Hamming distance via byte-level NEON. XOR two
    /// fingerprints at the SIMD32<UInt8> level (two eor.16b),
    /// per-byte popcount via lane-wise nonzeroBitCount on UInt8
    /// (32 scalar calls), then horizontal sum via wrappedSum().
    ///
    /// The horizontal sum step is `addv` on NEON (single
    /// instruction over 16 bytes; two issues for 32 bytes). The
    /// per-byte popcount is the bottleneck because Swift does
    /// not vectorize 32 scalar nonzeroBitCount calls into a
    /// single `cnt.16b` issue — see Phase 2.β-2 decision
    /// addendum.
    public func hammingDistance256(_ a: Fingerprint256, _ b: Fingerprint256) -> Int {
        let ab = NeonKernel.toBytes(a)
        let bb = NeonKernel.toBytes(b)
        let xb = ab ^ bb
        return Int(NeonKernel.popcountBytes(xb).wrappedSum())
    }

    /// Batched Hamming distance. Probe vector stays live across
    /// the loop; each candidate is loaded per iteration.
    public func hammingDistanceBatch(probe: Fingerprint256,
                                     candidates: [Fingerprint256]) -> [Int] {
        let pb = NeonKernel.toBytes(probe)
        var out = [Int]()
        out.reserveCapacity(candidates.count)
        for cand in candidates {
            let cb = NeonKernel.toBytes(cand)
            let xb = pb ^ cb
            out.append(Int(NeonKernel.popcountBytes(xb).wrappedSum()))
        }
        return out
    }

    /// Top-K Hamming-NN with the byte-level SIMD distance inner
    /// loop. Sort-and-truncate after the scan.
    public func hammingTopK(probe: Fingerprint256,
                            candidates: [Fingerprint256],
                            k: Int) -> [(index: Int, distance: Int)] {
        // Heap-of-K pattern matching ScalarKernel reference.
        // Eliminates the prior allocate-N-then-sort anti-pattern
        // that made this O(N log N) with a 16 MB allocation at
        // N=1M. Now O(N log K) with O(K) auxiliary storage.
        //
        // Per-element distance compute still uses the NEON byte-
        // level XOR + per-byte popcount path. Output ordering
        // (distance ascending, index ascending on ties) matches
        // ScalarKernel exactly so the hamming_nn conformance
        // vector continues to PASS.
        guard k > 0 else { return [] }
        let pb = NeonKernel.toBytes(probe)
        var heap = ScalarKernelMaxHeap()
        for (idx, cand) in candidates.enumerated() {
            let cb = NeonKernel.toBytes(cand)
            let xb = pb ^ cb
            let dist = Int(NeonKernel.popcountBytes(xb).wrappedSum())
            let scored = ScalarKernelScored(distance: dist, index: idx)
            if heap.count < k {
                heap.push(scored)
            } else if let top = heap.peek(), scored < top {
                _ = heap.pop()
                heap.push(scored)
            }
        }
        var result: [(index: Int, distance: Int)] = []
        result.reserveCapacity(heap.count)
        while let next = heap.pop() {
            result.append((index: next.index, distance: next.distance))
        }
        result.reverse()  // heap drains largest-first; want smallest-first
        return result
    }

    // ----- Inherited: OR-reduce and SimHash use scalar default
    //       (NEON byte-level reframing doesn't help these ops;
    //       the SIMD4<UInt64> path in SimdKernel is the right
    //       choice for OR-reduce, and SimHash is a Phase 2.γ
    //       investigation entirely).

    public func orReduce256(_ fingerprints: [Fingerprint256]) -> Fingerprint256 {
        var acc = Fingerprint256.zero
        for fp in fingerprints {
            acc = Fingerprint256(
                block0: acc.block0 | fp.block0,
                block1: acc.block1 | fp.block1,
                block2: acc.block2 | fp.block2,
                block3: acc.block3 | fp.block3)
        }
        return acc
    }

    public func orReduceBatch(batches: [[Fingerprint256]]) -> [Fingerprint256] {
        return batches.map { orReduce256($0) }
    }

    public func simhashCompute(subhashes: [UInt64],
                               families: [HyperplaneFamily]) -> Fingerprint256 {
        return SimHash.fingerprint(fromSubhashes: subhashes, hyperplanes: families)
    }
}
