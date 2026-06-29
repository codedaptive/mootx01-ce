// PortableKernel-SIMD.swift
//
// SIMD-backed kernel implementation per
// DECISION_OR_REDUCE_BACKENDS_2026-05-17.md (Axis 1, the "1" path)
// and DECISION_HAMMING_BACKENDS_2026-05-17.md (Phase 2.β-1).
//
// Uses Swift's `import simd` library for SIMD lanes. On Apple
// Silicon and other aarch64 targets, the compiler emits NEON
// instructions:
//
//   or_reduce_256:  SIMD4<UInt64> |=  →  `orr.16b`
//   hamming_distance_256:  SIMD4<UInt64> ^  →  `eor.16b`
//                          + lane-wise nonzeroBitCount  →  `cnt.16b`
//
// This is the per-op-optimal path for the bandwidth-bound ops the
// substrate uses, per cookbook § 4.4 ("select the optimal backend
// at runtime") and § 17.5 ("bandwidth-bound, not compute-bound").
//
// SimdKernel provides optimized implementations of the bandwidth-
// bound ops: `orReduce256/Batch` (SIMD4<UInt64>), `hammingDistance256`,
// `hammingDistanceBatch`, `hammingTopK`, and `simhashBlockBatch`
// (vertical SIMD over hyperplanes, Phase 2.γ-1). `simhashCompute`
// retains the scalar reference implementation.
//
// Per the decision records, this kernel strictly dominates
// ScalarKernel for the ops it implements. The dispatcher returns
// SimdKernel unconditionally on aarch64.
//
// Conformance: every method must produce byte-identical output
// to ScalarKernel for the same inputs. The four-way conformance
// gate verifies this when invoked with --kernel=simd.

import Foundation
import simd
import SubstrateTypes

/// SIMD-backed kernel. Wins on aarch64 (NEON) and Apple Silicon.
/// Falls back to scalar for ops not yet SIMD-implemented.
public struct SimdKernel: SubstrateKernel {

    public init() {}

    public var kind: KernelKind { .simd }

    // MARK: - popcount64 (inherited semantics)

    @inlinable
    public func popcount64(_ x: UInt64) -> Int {
        return x.nonzeroBitCount
    }

    // MARK: - Hamming distance via SIMD4<UInt64> XOR + lane-wise popcount (Phase 2.β-1)

    /// Hamming distance between two 256-bit fingerprints via
    /// `SIMD4<UInt64>` XOR (`eor.16b`) and lane-wise
    /// `nonzeroBitCount` (`cnt.16b` + horizontal sum) on aarch64.
    ///
    /// The Swift compiler reliably lowers `nonzeroBitCount` on
    /// `UInt64` to a CNT-based sequence; the surrounding XOR is
    /// already SIMD-friendly via the `^` operator on
    /// `SIMD4<UInt64>`. Per the OR-reduce empirical finding,
    /// Swift's autovectorizer does NOT reliably promote the
    /// indexed-access scalar pattern to SIMD, so the explicit
    /// SIMD shape here matters.
    public func hammingDistance256(_ a: Fingerprint256, _ b: Fingerprint256) -> Int {
        let av = SIMD4<UInt64>(a.block0, a.block1, a.block2, a.block3)
        let bv = SIMD4<UInt64>(b.block0, b.block1, b.block2, b.block3)
        let xv = av ^ bv
        return xv[0].nonzeroBitCount
             + xv[1].nonzeroBitCount
             + xv[2].nonzeroBitCount
             + xv[3].nonzeroBitCount
    }

    /// Batched Hamming distance: one probe against N candidates.
    /// The probe stays in NEON registers across the loop; each
    /// candidate streams through. The `out.reserveCapacity` avoids
    /// array reallocation across the batch.
    public func hammingDistanceBatch(probe: Fingerprint256,
                                     candidates: [Fingerprint256]) -> [Int] {
        let pv = SIMD4<UInt64>(probe.block0, probe.block1,
                               probe.block2, probe.block3)
        var out = [Int]()
        out.reserveCapacity(candidates.count)
        for cand in candidates {
            let cv = SIMD4<UInt64>(cand.block0, cand.block1,
                                   cand.block2, cand.block3)
            let xv = pv ^ cv
            out.append(xv[0].nonzeroBitCount + xv[1].nonzeroBitCount
                     + xv[2].nonzeroBitCount + xv[3].nonzeroBitCount)
        }
        return out
    }

    /// Top-K Hamming-NN with branchless ladder maintenance
    /// (Phase 2.δ-1, cookbook §11.2).
    ///
    /// Replaces the prior sort-and-truncate strategy: maintains a
    /// K-element sorted (distance, index) ladder during the scan,
    /// avoiding the O(N log N) sort + O(N) intermediate scored
    /// array allocation. Asymptotic cost: O(N) distance work plus
    /// O(N·K) ladder maintenance worst case; in practice the
    /// ladder early-exits on most candidates once it fills.
    ///
    /// Tie-break contract (matches scalar): for equal distances,
    /// the candidate with smaller index wins. Since we scan in
    /// ascending index order, any earlier candidate with the same
    /// distance is already in the ladder, so the strict early-exit
    /// `d >= worst` correctly preserves the tie-break.
    ///
    /// Cookbook §17.1 hot-path budget: K=10 over 1M rows < 100 µs.
    /// Phase 2.δ-1 measures whether this implementation hits that
    /// budget on apple-m5-max.
    public func hammingTopK(probe: Fingerprint256,
                            candidates: [Fingerprint256],
                            k: Int) -> [(index: Int, distance: Int)] {
        if k <= 0 || candidates.isEmpty { return [] }
        let n = candidates.count
        let effectiveK = Swift.min(k, n)

        let pv = SIMD4<UInt64>(probe.block0, probe.block1,
                               probe.block2, probe.block3)

        // Maintained ladder: parallel arrays of distance + index,
        // sorted ascending by distance. Initialize with sentinels
        // (Int.max distance) so the first K candidates always
        // insert. Parallel arrays beat tuple arrays for cache
        // behavior under tight inner loops.
        var topDist = [Int](repeating: Int.max, count: effectiveK)
        var topIdx  = [Int](repeating: -1,       count: effectiveK)

        // Local cached worst-in-ladder for fast early exit. Read
        // path is hot; writing only when the ladder updates.
        var worst = Int.max

        for idx in 0..<n {
            // SIMD Hamming distance. Lowers to eor.16b + cnt.16b
            // + horizontal sum on aarch64.
            let cv = SIMD4<UInt64>(
                candidates[idx].block0, candidates[idx].block1,
                candidates[idx].block2, candidates[idx].block3)
            let xv = pv ^ cv
            let d = xv[0].nonzeroBitCount + xv[1].nonzeroBitCount
                  + xv[2].nonzeroBitCount + xv[3].nonzeroBitCount

            // Early exit: equal distance with an already-present
            // (lower-index) candidate also bypasses ladder update,
            // since we process in ascending index order and the
            // tie-break favors the earlier candidate.
            if d >= worst { continue }

            // Find insertion position: rightmost pos in [0, K)
            // such that all topDist[i < pos] are <= d. Linear
            // scan beats binary search for K <= ~32 because the
            // branch predictor handles short loops well.
            var pos = effectiveK - 1
            while pos > 0 && topDist[pos - 1] > d {
                pos -= 1
            }

            // Shift entries [pos, K-2] one position right to
            // make room. The last entry (was at K-1) is
            // displaced and forgotten.
            var i = effectiveK - 1
            while i > pos {
                topDist[i] = topDist[i - 1]
                topIdx[i]  = topIdx[i - 1]
                i -= 1
            }
            topDist[pos] = d
            topIdx[pos]  = idx

            // Update cached worst.
            worst = topDist[effectiveK - 1]
        }

        // Output: drop unfilled sentinel entries (defensive
        // check; with the current logic, cannot happen because
        // effectiveK <= n and the first K candidates always
        // insert).
        var out: [(index: Int, distance: Int)] = []
        out.reserveCapacity(effectiveK)
        for i in 0..<effectiveK {
            if topDist[i] == Int.max { break }
            out.append((index: topIdx[i], distance: topDist[i]))
        }
        return out
    }

    // MARK: - simhashCompute (inherited semantics; full fingerprint at bs=1
    //         doesn't amortize the packed-family construction)

    public func simhashCompute(subhashes: [UInt64],
                               families: [HyperplaneFamily]) -> Fingerprint256 {
        return SimHash.fingerprint(fromSubhashes: subhashes, hyperplanes: families)
    }

    // MARK: - simhashBlockBatch via vertical SIMD over hyperplanes (Phase 2.γ-1)

    /// Batched SimHash block: one family applied to N input
    /// vectors. The family is manifest-immutable; we build a
    /// SoA/packed view of its 64 planes ONCE per batch and reuse
    /// it across every input. Per-input, the inner loop is
    /// vertical SIMD: 16 groups of 4 hyperplanes each, with
    /// SIMD4<UInt64> AND + lane-wise nonzeroBitCount + SIMD4<UInt32>
    /// accumulator.
    ///
    /// The default protocol impl loops over inputs calling
    /// SimHash.block, which does scalar 64x per-plane work per
    /// input. This override reduces inner-loop instruction count
    /// by ~4x at the cost of one packed-family construction.
    ///
    /// Conformance: produces byte-identical output to ScalarKernel.
    public func simhashBlockBatch(inputs: [[UInt64]],
                                  family: HyperplaneFamily) -> [UInt64] {
        // One-time packed layout for this family. Cost is
        // 64 × wordCount × 2 SIMD4<UInt64> writes; amortized
        // across N inputs.
        let packed = SimdKernel.PackedFamily(family: family)
        var out = [UInt64]()
        out.reserveCapacity(inputs.count)
        for input in inputs {
            out.append(SimdKernel.simhashBlockSIMD(input: input, packed: packed))
        }
        return out
    }

    /// Packed SoA layout of one HyperplaneFamily for SIMD
    /// evaluation. Stores the 64 hyperplane positive/negative
    /// masks as 16 groups of 4 lanes each. Per-(group, word)
    /// access is a single SIMD4<UInt64> load instead of four
    /// separate array indirections.
    fileprivate struct PackedFamily {
        let positive: [SIMD4<UInt64>]   // 16 groups × wordCount entries
        let negative: [SIMD4<UInt64>]
        let wordCount: Int

        init(family: HyperplaneFamily) {
            precondition(family.planes.count == 64,
                         "PackedFamily requires exactly 64 planes")
            let wc = family.planes[0].positiveMask.count
            var pos = [SIMD4<UInt64>]()
            var neg = [SIMD4<UInt64>]()
            pos.reserveCapacity(16 * wc)
            neg.reserveCapacity(16 * wc)
            for g in 0..<16 {
                let p0 = family.planes[4*g + 0]
                let p1 = family.planes[4*g + 1]
                let p2 = family.planes[4*g + 2]
                let p3 = family.planes[4*g + 3]
                for i in 0..<wc {
                    pos.append(SIMD4<UInt64>(
                        p0.positiveMask[i],
                        p1.positiveMask[i],
                        p2.positiveMask[i],
                        p3.positiveMask[i]))
                    neg.append(SIMD4<UInt64>(
                        p0.negativeMask[i],
                        p1.negativeMask[i],
                        p2.negativeMask[i],
                        p3.negativeMask[i]))
                }
            }
            self.positive = pos
            self.negative = neg
            self.wordCount = wc
        }
    }

    /// Compute one 64-bit SimHash block via vertical SIMD over
    /// the packed family. Inner loop processes 4 hyperplanes per
    /// SIMD iteration; outer loop covers 16 groups for 64 total.
    /// Final per-lane comparison + bit-set assembles the result.
    @inline(__always)
    fileprivate static func simhashBlockSIMD(input: [UInt64],
                                             packed: PackedFamily) -> UInt64 {
        precondition(input.count == packed.wordCount,
                     "input must match family word count")
        var result: UInt64 = 0
        for g in 0..<16 {
            var pos4 = SIMD4<UInt32>.zero
            var neg4 = SIMD4<UInt32>.zero
            for i in 0..<packed.wordCount {
                let v_i = SIMD4<UInt64>(repeating: input[i])
                let idx = g * packed.wordCount + i
                let posAnd = v_i & packed.positive[idx]
                let negAnd = v_i & packed.negative[idx]
                pos4 &+= SIMD4<UInt32>(
                    UInt32(posAnd[0].nonzeroBitCount),
                    UInt32(posAnd[1].nonzeroBitCount),
                    UInt32(posAnd[2].nonzeroBitCount),
                    UInt32(posAnd[3].nonzeroBitCount))
                neg4 &+= SIMD4<UInt32>(
                    UInt32(negAnd[0].nonzeroBitCount),
                    UInt32(negAnd[1].nonzeroBitCount),
                    UInt32(negAnd[2].nonzeroBitCount),
                    UInt32(negAnd[3].nonzeroBitCount))
            }
            // Lane-wise sign comparison + bit-set. The matching
            // ScalarKernel/Hyperplane.sign contract: strict
            // greater-than (ties resolve to false).
            let base = 4 * g
            if pos4[0] > neg4[0] { result |= UInt64(1) << (base + 0) }
            if pos4[1] > neg4[1] { result |= UInt64(1) << (base + 1) }
            if pos4[2] > neg4[2] { result |= UInt64(1) << (base + 2) }
            if pos4[3] > neg4[3] { result |= UInt64(1) << (base + 3) }
        }
        return result
    }

    // MARK: - OR-reduce via SIMD4<UInt64> |= (Phase 2.α-1)

    /// OR-reduce a cohort of fingerprints via SIMD4<UInt64>.
    ///
    /// On Apple Silicon this compiles to a tight loop of
    /// `ldp` (load pair) + `orr.16b` NEON instructions. The
    /// accumulator stays in NEON registers across iterations.
    ///
    /// For an empty cohort, returns Fingerprint256.zero (the
    /// OR identity), matching ScalarKernel semantics.
    public func orReduce256(_ fingerprints: [Fingerprint256]) -> Fingerprint256 {
        var acc: SIMD4<UInt64> = .zero
        for fp in fingerprints {
            acc |= SIMD4<UInt64>(fp.block0, fp.block1, fp.block2, fp.block3)
        }
        return Fingerprint256(
            block0: acc[0], block1: acc[1], block2: acc[2], block3: acc[3])
    }

    /// Batched OR-reduce. Each cohort produces one reduced
    /// fingerprint. Order-preserving: output[i] is the reduction
    /// of batches[i].
    ///
    /// The batched method is overridden (rather than inheriting
    /// the protocol extension's default loop) so that the SIMD
    /// accumulator can stay in register across each inner cohort
    /// without the array-allocation overhead of `.map`. For very
    /// short cohorts this is mostly a wash; for cohort sizes
    /// above ~8 it's a measurable win because the inner loop is
    /// not interrupted by allocator calls.
    public func orReduceBatch(batches: [[Fingerprint256]]) -> [Fingerprint256] {
        var out = [Fingerprint256]()
        out.reserveCapacity(batches.count)
        for cohort in batches {
            var acc: SIMD4<UInt64> = .zero
            for fp in cohort {
                acc |= SIMD4<UInt64>(fp.block0, fp.block1, fp.block2, fp.block3)
            }
            out.append(Fingerprint256(
                block0: acc[0], block1: acc[1], block2: acc[2], block3: acc[3]))
        }
        return out
    }

    // MARK: - Count-fold via a bit-sliced carry-save vertical counter

    /// Count-fold a cohort into a `CountVector256`. The vectorized
    /// shape is a bit-sliced vertical counter (the Harley-Seal idea
    /// applied per column): `planes[b]` is a 256-bit value holding
    /// bit `b` of every column's running count, carried in
    /// `SIMD4<UInt64>` lanes. Each fingerprint is a 0-or-1-per-column
    /// vector, and folding it in is a ripple-carry add across the
    /// planes: the sum bit is `plane XOR carry`, the carry out is
    /// `plane AND carry`. The carry dies after about two planes on
    /// average (the amortized cost of a binary counter increment), so
    /// the per-fingerprint cost is a couple of `eor.16b` / `and.16b`
    /// pairs rather than the reference's set-bit-by-set-bit walk. The
    /// per-column counts are read out of the bit-sliced planes once at
    /// the end.
    ///
    /// Conformance: produces a `CountVector256` byte-identical to
    /// `ScalarKernel.countFold256` (equivalently the
    /// `CountVector256.fold` reference), gated by the kernel
    /// conformance test. The OR-reduce above is the degenerate case
    /// of this fold where the counter saturates at a single plane.
    public func countFold256(_ fingerprints: [Fingerprint256]) -> CountVector256 {
        if fingerprints.isEmpty { return CountVector256() }

        // Bit-sliced running counter. `planes[b]` carries bit b of the
        // per-column count; the plane count grows as the maximum
        // column count needs more bits (ceil(log2(n+1)) planes).
        var planes: [SIMD4<UInt64>] = []
        let zero = SIMD4<UInt64>.zero

        for fp in fingerprints {
            var carry = SIMD4<UInt64>(fp.block0, fp.block1, fp.block2, fp.block3)
            var b = 0
            while carry != zero {
                if b == planes.count {
                    planes.append(carry)
                    break
                }
                let plane = planes[b]
                planes[b] = plane ^ carry      // sum bit at this weight
                carry = plane & carry          // carry to the next weight
                b += 1
            }
        }

        // Read per-column counts out of the bit-sliced planes: column
        // j's count is the sum over planes of bit_b(j) << b.
        var counts = [UInt32](repeating: 0, count: 256)
        for b in 0..<planes.count {
            let plane = planes[b]
            let weight = UInt32(1) << UInt32(b)
            for lane in 0..<4 {
                var word = plane[lane]
                let base = lane * 64
                while word != 0 {
                    let bit = word.trailingZeroBitCount
                    counts[base + bit] &+= weight
                    word &= word &- 1
                }
            }
        }
        return CountVector256(counts: counts, n: UInt32(fingerprints.count))
    }
}
