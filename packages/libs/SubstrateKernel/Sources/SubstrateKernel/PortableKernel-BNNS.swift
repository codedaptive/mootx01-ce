// PortableKernel-BNNS.swift
//
// BNNS-backed kernel implementation per Phase 2.α-4 of the
// kernel-learned-dispatch protocol. The hypothesis tested here
// is the "1a path" from DECISION_OR_REDUCE_BACKENDS_2026-05-17:
// can AMX-via-BNNS beat NEON for OR-reduce despite the memory
// amplification cost of float-encoding?
//
// The methodology gate originally rejected this on paper. The
// engineering-by-wallet protocol says: implement it anyway,
// measure it, replace the paper rejection with a measured
// rejection (or, if surprised, replace it with a measured
// acceptance).
//
// EMPIRICAL FINDING during implementation (2026-05-18):
//   BNNS reduce-max DOES NOT support integer types on macOS
//   26.5 / Apple Silicon. Calls with .uint8 or .int16 data
//   silently produce all-zero output (no error returned).
//   Only float types are functional for the reduce family.
//
//   This is itself an interesting datum: the bit-as-byte
//   approach the paper analysis assumed (8x memory amp) is
//   API-impossible. To get BNNS reduce semantics for OR-reduce
//   we must use float encoding (32x memory amp).
//
// IMPLEMENTATION (float-encoded)
//
// Each fingerprint bit becomes a Float32 (0.0 = clear, 1.0 =
// set). The cohort becomes an [N, 256] matrix of Float32.
// BNNS reduce-max along the cohort axis produces [256] floats;
// for any bit position, max-across-the-cohort is 1.0 if any
// row had that bit set, else 0.0. Decoding float != 0 back
// to a bit produces OR-reduce semantics.
//
// Cost per call:
//   - Encode: N * 256 float writes (1024 bytes/fingerprint)
//   - BNNS dispatch: AMX kernel runtime + setup overhead
//   - Decode: 256 float reads + bit packing
//   - Memory: 32x amplification (32B fingerprint → 1024B float vector)
//
// Apple-only. The harness skips this kernel on non-Apple
// platforms via the kernel registry's #if predicates.

import Foundation
#if canImport(Accelerate)
import Accelerate
import SubstrateTypes
#endif

#if canImport(Accelerate)

// BNNS single-shot matmul wrapper.
//
// `BNNS.applyMatrixMultiplication` is deprecated as of macOS 15 / iOS 18
// in favor of the BNNSGraph API. Migrating this kernel to BNNSGraph is a
// graph-construct-and-compile rewrite that changes the compute path; this
// kernel is conformance-gated (byte-identical to the scalar reference,
// CI-checked four ways), so swapping the engine requires Newton four-way
// re-validation and is out of scope for a no-behavior-change hygiene
// mission. A dedicated BNNSGraph migration is tracked separately.
//
// The single deprecated reference is isolated to this one wrapper so the
// kernel carries exactly one documented deprecation warning instead of two
// scattered through the hot batch methods. Swift has no per-call
// deprecation suppression; an `@available(deprecated:)` on this wrapper
// would be inert at the current macOS 14 / iOS 17 floor (the floor is
// below the deprecation version, so it neither silences the inner call nor
// warns the callers) and would actively cascade to the protocol-witness
// call sites if the floor were ever raised to macOS 15 — so the wrapper is
// deliberately left un-annotated. This containment stands until the
// BNNSGraph migration clears the call for good.
//
// The shape (inputB transposed, alpha 1.0, no workspace) is identical for
// both callers; each guards correctness with its own scalar fallback.
private func bnnsApplyMatMul(
    a: BNNSNDArrayDescriptor,
    b: BNNSNDArrayDescriptor,
    out: BNNSNDArrayDescriptor
) throws {
    try BNNS.applyMatrixMultiplication(
        inputA: a, transposed: false,
        inputB: b, transposed: true,
        output: out,
        alpha: 1.0,
        workspace: nil)
}

/// Pre-encoded ±1/0 Float32 matrix derived from one
/// HyperplaneFamily. Layout is row-major [64, inputBits]:
/// row k is the k-th hyperplane, column i is bit i of the
/// input vector. Per the BNN inference identity:
///   M[k][i] = +1.0 if positive_mask[k] has bit i set
///   M[k][i] = -1.0 if negative_mask[k] has bit i set
///   M[k][i] =  0.0 otherwise (sparse case from OQ-2.1)
///
/// Stored as `[Float]` so the BNNS matmul receives a stable
/// pointer over the matrix's lifetime; the cache holds the
/// matrix strongly so its buffer survives across calls.
fileprivate final class EncodedHyperplaneMatrix {
    var buffer: [Float]
    let inputBits: Int

    init(family: HyperplaneFamily) {
        let bits = family.inputBitLength
        var buf = [Float](repeating: 0, count: 64 * bits)
        for k in 0..<64 {
            let plane = family.planes[k]
            let rowBase = k * bits
            for wordIdx in 0..<plane.positiveMask.count {
                let pos = plane.positiveMask[wordIdx]
                let neg = plane.negativeMask[wordIdx]
                let bitBase = wordIdx * 64
                let bitLimit = min(64, bits - bitBase)
                for bitIdx in 0..<bitLimit {
                    if ((pos >> bitIdx) & 1) != 0 {
                        buf[rowBase + bitBase + bitIdx] = 1.0
                    } else if ((neg >> bitIdx) & 1) != 0 {
                        buf[rowBase + bitBase + bitIdx] = -1.0
                    }
                }
            }
        }
        self.buffer = buf
        self.inputBits = bits
    }
}

/// Cache of pre-encoded hyperplane matrices, keyed on
/// `HyperplaneFamily.canonicalHash()`. Reference-type so multiple
/// `BnnsKernel` copies share state and so the cache persists
/// across stress-test sweep iterations where the same family is
/// supplied to every batch-size invocation.
///
/// Thread safety: guarded by `os_unfair_lock`. The lock is held
/// for the lookup-or-insert critical section only; the returned
/// matrix is then accessed without the lock since its `buffer`
/// is never mutated after construction. Marked `@unchecked
/// Sendable` to satisfy `SubstrateKernel: Sendable` while
/// retaining reference semantics for the cache.
fileprivate final class SimhashMatrixCache: @unchecked Sendable {
    private var entries: [UInt64: EncodedHyperplaneMatrix] = [:]
    private var lock = os_unfair_lock()

    func matrix(for family: HyperplaneFamily) -> EncodedHyperplaneMatrix? {
        let key = family.canonicalHash()
        os_unfair_lock_lock(&lock)
        if let hit = entries[key] {
            os_unfair_lock_unlock(&lock)
            return hit
        }
        os_unfair_lock_unlock(&lock)
        // Build outside the lock; the build does scalar work
        // proportional to 64 × inputBits and we don't need to
        // hold the lock through it. A racing builder may produce
        // a duplicate matrix; the last insert wins, which is fine
        // because the content is determined entirely by the
        // family (and the family hashes to the same key).
        let built = EncodedHyperplaneMatrix(family: family)
        os_unfair_lock_lock(&lock)
        if let raced = entries[key] {
            os_unfair_lock_unlock(&lock)
            return raced
        }
        entries[key] = built
        os_unfair_lock_unlock(&lock)
        return built
    }
}

/// BNNS-backed kernel. Implements `orReduce256` via the
/// float-encoded BNNS reduce-max approach documented above.
/// Inherits scalar for the other ops since BNNS does not
/// natively express bitwise XOR + popcount (the Hamming case
/// is handled by a different candidate, the BNNS float-encoded
/// path for Hamming, in Phase 2.β-2).
public struct BnnsKernel: SubstrateKernel {

    /// Cache of pre-encoded hyperplane matrices keyed by
    /// `HyperplaneFamily.canonicalHash()`. Held by reference so
    /// `BnnsKernel` copies share state, and so the cache persists
    /// across stress-test sweep iterations where the same family
    /// is supplied to multiple batch-size invocations.
    fileprivate let cache: SimhashMatrixCache

    public init() {
        self.cache = SimhashMatrixCache()
    }

    public var kind: KernelKind { .bnns }

    // ----- Inherited semantics from ScalarKernel for ops with
    //       no plausible BNNS specialization at Phase 2.α-4.

    @inlinable
    public func popcount64(_ x: UInt64) -> Int {
        return x.nonzeroBitCount
    }

    public func hammingDistance256(_ a: Fingerprint256, _ b: Fingerprint256) -> Int {
        var total = 0
        for i in 0..<4 {
            total += popcount64(a.words[i] ^ b.words[i])
        }
        return total
    }

    public func hammingTopK(probe: Fingerprint256,
                            candidates: [Fingerprint256],
                            k: Int) -> [(index: Int, distance: Int)] {
        // BNNS-backed: reuse hammingDistanceBatch for the
        // distance computation (its actual fast path), then
        // select top-K via the same heap pattern ScalarKernel
        // uses. Eliminates the prior allocate-N-then-sort
        // anti-pattern. Output ordering matches ScalarKernel
        // exactly so the hamming_nn conformance vector PASSes.
        guard k > 0 else { return [] }
        let distances = hammingDistanceBatch(probe: probe, candidates: candidates)
        var heap = ScalarKernelMaxHeap()
        for (idx, dist) in distances.enumerated() {
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
        result.reverse()
        return result
    }

    // ----- BNNS-backed hammingDistanceBatch (Phase 2.β-2(b) candidate)

    /// Batched Hamming distance via BNNS ±1-float matrix
    /// multiply.
    ///
    /// The math (BNN inference identity): encode each fingerprint
    /// bit as Float32 of `+1.0` (bit set) or `-1.0` (bit cleared).
    /// With this encoding, for two fingerprints a and b:
    ///
    ///     dot(a_floats, b_floats) = (# matching bits) - (# differing bits)
    ///                              = 256 - 2 * hamming(a, b)
    ///
    /// So `hamming(a, b) = (256 - dot) / 2`. Probe-against-N
    /// candidates becomes a single matrix-vector product where
    /// the probe is a 1×256 row vector and the candidates form a
    /// 256×N matrix. The output is a 1×N vector of dot products
    /// which we decode lane-wise.
    ///
    /// Cost per call:
    ///   - Encode probe: 256 float writes
    ///   - Encode candidates: N × 256 float writes (32x memory
    ///     amplification per fingerprint)
    ///   - BNNS matmul dispatch: AMX kernel runtime + setup overhead
    ///   - Decode: N float reads + (256 - x) / 2 conversion
    ///
    /// Per Phase 2.α-4 findings on BNNS reduce, the encode pass
    /// alone can dominate cost at small batches. The matmul
    /// kernel itself is AMX-fast but trivial relative to setup
    /// for N < ~256 fingerprints.
    ///
    /// On BNNS failure, falls through to the inherited scalar
    /// pair-at-a-time loop to preserve correctness.
    public func hammingDistanceBatch(probe: Fingerprint256,
                                     candidates: [Fingerprint256]) -> [Int] {
        let n = candidates.count
        if n == 0 { return [] }

        // Step 1: heap-allocate buffers so Swift's exclusivity
        // tracker doesn't trip on BNNS's internal accesses.
        let probePtr = UnsafeMutablePointer<Float>.allocate(capacity: 256)
        let candPtr = UnsafeMutablePointer<Float>.allocate(capacity: n * 256)
        let outPtr = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer {
            probePtr.deallocate()
            candPtr.deallocate()
            outPtr.deallocate()
        }

        // Step 2: encode probe and candidates as ±1.0 floats.
        // Bit i set → +1.0, clear → -1.0.
        let probeBlocks: [UInt64] = [probe.block0, probe.block1,
                                     probe.block2, probe.block3]
        for blockIdx in 0..<4 {
            let block = probeBlocks[blockIdx]
            for bitIdx in 0..<64 {
                let floatIdx = blockIdx * 64 + bitIdx
                probePtr[floatIdx] = ((block >> bitIdx) & 1) != 0 ? 1.0 : -1.0
            }
        }
        for (candIdx, cand) in candidates.enumerated() {
            let base = candIdx * 256
            let blocks: [UInt64] = [cand.block0, cand.block1,
                                    cand.block2, cand.block3]
            for blockIdx in 0..<4 {
                let block = blocks[blockIdx]
                for bitIdx in 0..<64 {
                    let floatIdx = base + blockIdx * 64 + bitIdx
                    candPtr[floatIdx] = ((block >> bitIdx) & 1) != 0 ? 1.0 : -1.0
                }
            }
        }
        for i in 0..<n { outPtr[i] = 0 }

        // Step 3: BNNS matrix multiplication.
        // Shape convention: matrixRowMajor(cols, rows).
        //   probe:      (cols=256, rows=1)     row vector
        //   candidates: (cols=256, rows=n)     n stacked row vectors
        //   output:     (cols=n,   rows=1)     row of n dot products
        // With transposeB=true, BNNS treats candidates as
        // logically 256×n so the multiply produces 1×n.
        // Each output[0, j] = dot(probe, candidates[j]).
        let probeRaw = UnsafeMutableRawBufferPointer(
            start: probePtr, count: 256 * MemoryLayout<Float>.size)
        let candRaw = UnsafeMutableRawBufferPointer(
            start: candPtr, count: n * 256 * MemoryLayout<Float>.size)
        let outRaw = UnsafeMutableRawBufferPointer(
            start: outPtr, count: n * MemoryLayout<Float>.size)

        let success: Bool = {
            guard let aDesc = BNNSNDArrayDescriptor(
                data: probeRaw, scalarType: Float.self,
                shape: .matrixRowMajor(256, 1)) else { return false }
            guard let bDesc = BNNSNDArrayDescriptor(
                data: candRaw, scalarType: Float.self,
                shape: .matrixRowMajor(256, n)) else { return false }
            guard let outDesc = BNNSNDArrayDescriptor(
                data: outRaw, scalarType: Float.self,
                shape: .matrixRowMajor(n, 1)) else { return false }
            do {
                try bnnsApplyMatMul(a: aDesc, b: bDesc, out: outDesc)
                return true
            } catch {
                return false
            }
        }()

        if !success {
            // Fallback: scalar batch using inherited semantics.
            var fallback = [Int]()
            fallback.reserveCapacity(n)
            for cand in candidates {
                fallback.append(hammingDistance256(probe, cand))
            }
            return fallback
        }

        // Step 4: decode dot products to Hamming distances.
        // dot ∈ [-256, +256], integer when inputs are exactly ±1.
        // hamming = (256 - dot) / 2. The +0.5 rounding absorbs
        // any tiny FP error from the BNNS pipeline; the true
        // result is always integer.
        var out = [Int]()
        out.reserveCapacity(n)
        for i in 0..<n {
            let dot = outPtr[i]
            let dist = Int((256.0 - dot) / 2.0 + 0.5)
            out.append(dist)
        }
        return out
    }

    public func simhashCompute(subhashes: [UInt64],
                               families: [HyperplaneFamily]) -> Fingerprint256 {
        return SimHash.fingerprint(fromSubhashes: subhashes, hyperplanes: families)
    }

    // ----- BNNS-backed simhashBlockBatch (Phase 2.γ-2 candidate)

    /// Batched SimHash block via BNNS float matrix multiply.
    ///
    /// Math (matches scalar Hyperplane.sign semantics):
    ///   - Encode each hyperplane k as a vector of inputBits
    ///     Float32:
    ///       M[k][i] = +1.0 if positive_mask[k] has bit i set
    ///       M[k][i] = -1.0 if negative_mask[k] has bit i set
    ///       M[k][i] =  0.0 otherwise (sparse case)
    ///   - Encode each input vector as inputBits Float32 of 0/1
    ///     (bit i set → 1.0, clear → 0.0)
    ///   - The dot product (M @ v)[k] is exactly
    ///       popcount(v & positive_mask[k]) - popcount(v & negative_mask[k])
    ///     which is the scalar `pos - neg` quantity.
    ///   - Bit k of the SimHash block is 1 iff (M @ v)[k] > 0.
    ///
    /// For N input vectors, stack them as an [N, inputBits]
    /// matrix. The full computation is a single BNNS matmul:
    ///   output[N, 64] = inputs[N, inputBits] @ M[64, inputBits]^T
    /// One BNNS dispatch handles the entire batch.
    ///
    /// Hyperplane-matrix encoding is amortized: BnnsKernel caches
    /// the encoded M keyed on family.canonicalHash() so repeated
    /// calls with the same manifest-immutable family pay the
    /// encoding cost ONCE. This is the structural property that
    /// distinguishes the SimHash BNNS path from the Hamming BNNS
    /// path; for Hamming, the candidate matrix is per-call and
    /// the encode dominates (Phase 2.β-2(b) measured 68x slower
    /// than SimdKernel). For SimHash, the matrix is constant.
    ///
    /// On BNNS failure, falls through to the scalar inherited
    /// loop to preserve correctness.
    public func simhashBlockBatch(inputs: [[UInt64]],
                                  family: HyperplaneFamily) -> [UInt64] {
        let n = inputs.count
        if n == 0 { return [] }

        let inputBits = family.inputBitLength
        let wordCount = (inputBits + 63) / 64

        // Step 1: get or build the pre-encoded hyperplane matrix.
        // Cached on family.canonicalHash(); manifest-immutable
        // so safe to amortize across all calls with this family.
        guard let encodedMatrix = cache.matrix(for: family) else {
            return scalarFallback(inputs: inputs, family: family)
        }

        // Step 2: encode N inputs as [N, inputBits] floats.
        // Each input vector is wordCount UInt64s; expand to
        // inputBits Float32s.
        let inputsPtr = UnsafeMutablePointer<Float>.allocate(capacity: n * inputBits)
        let outputPtr = UnsafeMutablePointer<Float>.allocate(capacity: n * 64)
        defer {
            inputsPtr.deallocate()
            outputPtr.deallocate()
        }

        for (rowIdx, input) in inputs.enumerated() {
            precondition(input.count == wordCount,
                         "simhashBlockBatch: input word count must match family")
            let rowBase = rowIdx * inputBits
            for wordIdx in 0..<wordCount {
                let word = input[wordIdx]
                let bitBase = wordIdx * 64
                let bitLimit = min(64, inputBits - bitBase)
                for bitIdx in 0..<bitLimit {
                    let floatIdx = rowBase + bitBase + bitIdx
                    inputsPtr[floatIdx] = ((word >> bitIdx) & 1) != 0 ? 1.0 : 0.0
                }
            }
        }
        for i in 0..<(n * 64) { outputPtr[i] = 0 }

        // Step 3: BNNS matmul.
        //   A = inputs   shape matrixRowMajor(inputBits, n)
        //   B = matrix   shape matrixRowMajor(inputBits, 64)
        //   out         shape matrixRowMajor(64, n)
        // With transposeB=true, BNNS treats B as logically
        // [inputBits, 64] -> the multiply produces [n, 64].
        let inputsRaw = UnsafeMutableRawBufferPointer(
            start: inputsPtr,
            count: n * inputBits * MemoryLayout<Float>.size)
        let outRaw = UnsafeMutableRawBufferPointer(
            start: outputPtr,
            count: n * 64 * MemoryLayout<Float>.size)

        let success: Bool = encodedMatrix.buffer.withUnsafeMutableBufferPointer { matBuf in
            let matRaw = UnsafeMutableRawBufferPointer(
                start: matBuf.baseAddress,
                count: 64 * inputBits * MemoryLayout<Float>.size)
            guard let aDesc = BNNSNDArrayDescriptor(
                data: inputsRaw, scalarType: Float.self,
                shape: .matrixRowMajor(inputBits, n)) else { return false }
            guard let bDesc = BNNSNDArrayDescriptor(
                data: matRaw, scalarType: Float.self,
                shape: .matrixRowMajor(inputBits, 64)) else { return false }
            guard let outDesc = BNNSNDArrayDescriptor(
                data: outRaw, scalarType: Float.self,
                shape: .matrixRowMajor(64, n)) else { return false }
            do {
                try bnnsApplyMatMul(a: aDesc, b: bDesc, out: outDesc)
                return true
            } catch {
                return false
            }
        }

        if !success {
            return scalarFallback(inputs: inputs, family: family)
        }

        // Step 4: decode. For each row, scan its 64 output
        // floats; bit k is set iff output > 0 (strict, to match
        // scalar Hyperplane.sign tie-break).
        var out = [UInt64]()
        out.reserveCapacity(n)
        for rowIdx in 0..<n {
            let rowBase = rowIdx * 64
            var blockBits: UInt64 = 0
            for bitIdx in 0..<64 {
                if outputPtr[rowBase + bitIdx] > 0 {
                    blockBits |= UInt64(1) << bitIdx
                }
            }
            out.append(blockBits)
        }
        return out
    }

    /// Scalar fallback for the BNNS SimHash path. Used when
    /// BNNS descriptor creation or matmul fails; preserves
    /// byte-identical output by delegating to the canonical
    /// reference.
    private func scalarFallback(inputs: [[UInt64]],
                                family: HyperplaneFamily) -> [UInt64] {
        return inputs.map { SimHash.block(over: $0, family: family) }
    }

    // ----- BNNS-backed orReduce256 (the Phase 2.α-4 candidate)

    /// OR-reduce a cohort of fingerprints via BNNS reduce-max
    /// over a float-encoded tensor.
    ///
    /// Encoding: each Fingerprint256 (32 bytes, 256 bits) is
    /// expanded to 256 Float32s; bit i becomes float i with
    /// value 1.0 if the bit is set, 0.0 otherwise. The cohort
    /// becomes a [N, 256] matrix of Float32.
    ///
    /// Reduce: BNNS.applyReduction(.max, ...) reduces along
    /// the cohort axis. Output is a [256] vector where each
    /// float is 1.0 if any cohort row had that bit set, else
    /// 0.0. BNNS shape convention is matrixRowMajor(cols,
    /// rows) — confirmed empirically during implementation.
    ///
    /// Decode: 256 output floats → 4 UInt64 blocks, packing
    /// each non-zero float as a set bit.
    ///
    /// On BNNS failure, falls through to the scalar reference
    /// to preserve correctness.
    public func orReduce256(_ fingerprints: [Fingerprint256]) -> Fingerprint256 {
        let n = fingerprints.count
        if n == 0 { return Fingerprint256.zero }

        // Step 1: encode bits as floats. Heap-allocated so
        // Swift's exclusivity tracker doesn't trip on the
        // nested buffer accesses BNNS makes internally.
        let inputCount = n * 256
        let inputPtr = UnsafeMutablePointer<Float>.allocate(capacity: inputCount)
        let outputPtr = UnsafeMutablePointer<Float>.allocate(capacity: 256)
        defer { inputPtr.deallocate(); outputPtr.deallocate() }

        for (i, fp) in fingerprints.enumerated() {
            let base = i * 256
            let blocks: [UInt64] = [fp.block0, fp.block1, fp.block2, fp.block3]
            for blockIdx in 0..<4 {
                let block = blocks[blockIdx]
                for bitIdx in 0..<64 {
                    let floatIdx = base + blockIdx * 64 + bitIdx
                    inputPtr[floatIdx] = ((block >> bitIdx) & 1) != 0 ? 1.0 : 0.0
                }
            }
        }
        for i in 0..<256 { outputPtr[i] = 0 }

        // Step 2: BNNS dispatch.
        // matrixRowMajor(cols=256, rows=n) input → matrixRowMajor(cols=256, rows=1) output
        // reduces along the row axis (N rows collapse to 1).
        let inRaw = UnsafeMutableRawBufferPointer(
            start: inputPtr,
            count: inputCount * MemoryLayout<Float>.size)
        let outRaw = UnsafeMutableRawBufferPointer(
            start: outputPtr,
            count: 256 * MemoryLayout<Float>.size)

        let success: Bool = {
            guard let inDesc = BNNSNDArrayDescriptor(
                data: inRaw, scalarType: Float.self,
                shape: .matrixRowMajor(256, n)) else { return false }
            guard let outDesc = BNNSNDArrayDescriptor(
                data: outRaw, scalarType: Float.self,
                shape: .matrixRowMajor(256, 1)) else { return false }
            do {
                try BNNS.applyReduction(.max, input: inDesc, output: outDesc, weights: nil)
                return true
            } catch {
                return false
            }
        }()

        if !success {
            // Fallback: scalar OR-reduce. Preserves correctness
            // when BNNS rejects our descriptor for whatever
            // reason (older OS, unsupported shape combination).
            return ScalarKernel().orReduce256(fingerprints)
        }

        // Step 3: decode 256 output floats → 4 UInt64 blocks.
        var b0: UInt64 = 0
        var b1: UInt64 = 0
        var b2: UInt64 = 0
        var b3: UInt64 = 0
        for bitIdx in 0..<64 {
            if outputPtr[bitIdx] != 0 { b0 |= UInt64(1) << bitIdx }
            if outputPtr[64 + bitIdx] != 0 { b1 |= UInt64(1) << bitIdx }
            if outputPtr[128 + bitIdx] != 0 { b2 |= UInt64(1) << bitIdx }
            if outputPtr[192 + bitIdx] != 0 { b3 |= UInt64(1) << bitIdx }
        }
        return Fingerprint256(block0: b0, block1: b1, block2: b2, block3: b3)
    }

    /// Batched OR-reduce. Calls `orReduce256` on each cohort.
    /// A future optimization would batch the BNNS dispatches
    /// across cohorts (one BNNS call producing K output rows
    /// instead of one); for Phase 2.α-4 the per-cohort
    /// dispatch is what the methodology gate is testing.
    public func orReduceBatch(batches: [[Fingerprint256]]) -> [Fingerprint256] {
        return batches.map { orReduce256($0) }
    }
}

#endif // canImport(Accelerate)
