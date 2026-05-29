// PortableKernel-Metal.swift
//
// Metal-backed kernel implementation per Phase 2.β-2(c) of the
// kernel-learned-dispatch protocol. Tests the existing
// glref-metal-hamming_nn.metal compute shader against the
// CPU-side SimdKernel for hammingDistanceBatch.
//
// The shader file header claims: "this kernel becomes preferable
// to AMX/NEON CPU backends at roughly 100K candidate rows."
// Phase 2.β-2(c) tests this empirically at the batch sizes the
// stress-test sweep covers (1..256), then extrapolates the
// slope to predict the crossover.
//
// Cost model per call:
//   - Buffer allocation: anchor (32 B), candidates (32N B),
//     distances (4N B). Uses MTLStorageModeShared which is
//     zero-copy on unified-memory Apple Silicon (M-series).
//   - Encode pass: 32 bytes per candidate. Each Fingerprint256
//     is laid out as two uint4 per the shader convention.
//   - MTLComputeCommandEncoder setup, pipeline state binding,
//     dispatch encoding: ~10-30 µs of fixed cost per call.
//   - GPU execution: linear in N, very high throughput.
//   - waitUntilCompleted: blocks until the GPU finishes.
//   - Decode: read N uint32 distances back. Zero-copy on
//     unified memory.
//
// One-time setup costs are paid at kernel construction:
//   - MTLDevice (the default GPU)
//   - MTLCommandQueue (reusable across calls)
//   - MTLLibrary (compiled from the embedded shader source)
//   - MTLComputePipelineState (compiled from the kernel function)
//
// These are cached in the kernel instance. Each
// hammingDistanceBatch call reuses them; only the per-call
// command-buffer / encoder / buffers are allocated fresh.
//
// Apple-only. The harness skips this kernel on non-Apple
// platforms via the kernel registry's #if predicates.

import Foundation
#if canImport(Metal)
import Metal
import SubstrateTypes
#endif

#if canImport(Metal)

/// Persistent buffer pool for MetalKernel. Allocates anchor,
/// candidate, mask, count, and distance buffers ONCE at
/// construction up to `maxN` candidates; subsequent calls
/// memcpy into these buffers instead of allocating new ones.
///
/// Phase 2.δ-2: cuts per-call dispatch cost by eliminating
/// `MTLDevice.makeBuffer` allocations from the critical path.
/// The Phase 2.β-2(c) measurement showed ~70 µs per call;
/// hypothesis is that buffer allocation is the dominant
/// per-call cost.
///
/// All buffers use `MTLStorageModeShared` which is zero-copy on
/// unified-memory Apple Silicon. The class is reference-type and
/// marked `@unchecked Sendable`: `MetalKernel` holds it by
/// reference and the harness is single-threaded; production
/// callers wrap their own synchronization. The mutable region is
/// the buffer contents during a call; per-call atomicity is
/// enforced by the caller, not by this class.
fileprivate final class MetalBufferPool: @unchecked Sendable {
    let anchorBuf: MTLBuffer
    let candBuf:   MTLBuffer
    let maskBuf:   MTLBuffer
    let countBuf:  MTLBuffer
    let distBuf:   MTLBuffer
    let maxN:      Int

    init?(device: MTLDevice, maxN: Int) {
        let fpSize = MemoryLayout<Fingerprint256>.size  // 32
        precondition(fpSize == 32, "Fingerprint256 must be 32 bytes")
        precondition(maxN > 0, "maxN must be positive")

        guard let a = device.makeBuffer(length: fpSize,
                                        options: .storageModeShared),
              let c = device.makeBuffer(length: fpSize * maxN,
                                        options: .storageModeShared),
              let m = device.makeBuffer(length: MemoryLayout<UInt32>.size,
                                        options: .storageModeShared),
              let n = device.makeBuffer(length: MemoryLayout<UInt32>.size,
                                        options: .storageModeShared),
              let d = device.makeBuffer(length: MemoryLayout<UInt32>.size * maxN,
                                        options: .storageModeShared)
        else {
            return nil
        }
        self.anchorBuf = a
        self.candBuf   = c
        self.maskBuf   = m
        self.countBuf  = n
        self.distBuf   = d
        self.maxN      = maxN

        // One-time mask write: 0xF (all four blocks active).
        let maskPtr = m.contents().assumingMemoryBound(to: UInt32.self)
        maskPtr[0] = 0xF
    }
}

/// Metal-backed kernel candidate for Hamming. Specializes only
/// hammingDistanceBatch (and hammingTopK which delegates to it);
/// inherits scalar for hammingDistance256 since per-pair Metal
/// dispatch is dominated by command-buffer overhead.
public struct MetalKernel: SubstrateKernel {

    // MARK: - Cached Metal state (one-time setup per kernel instance)

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    /// Persistent buffer pool sized for up to `maxN` candidates.
    /// Calls with N > maxN allocate fresh buffers and skip the
    /// pool. Calls with N <= maxN reuse the pool's buffers.
    fileprivate let pool: MetalBufferPool

    /// Default max-N for the persistent buffer pool. Sized for
    /// the dreaming-daemon batch index-build pass at the
    /// medium-estate scale (~100K rows). The pool's RAM cost at
    /// this size is 100K * 32 B (candidates) + 100K * 4 B
    /// (distances) + ~80 B (other) = ~3.6 MB. Trivial overhead
    /// for the kernel instance.
    public static let defaultMaxN: Int = 100_000

    /// Initialize the Metal pipeline. Returns nil if Metal is
    /// unavailable on this system (headless CI without GPU,
    /// virtualized environment, etc.). The kernel registry
    /// checks this and skips registration when nil.
    public init?(maxN: Int = MetalKernel.defaultMaxN) {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            return nil
        }
        guard let q = dev.makeCommandQueue() else {
            return nil
        }
        // Compile the shader from embedded source. Avoids the
        // build-time complexity of shipping a .metallib alongside
        // the harness.
        let lib: MTLLibrary
        do {
            lib = try dev.makeLibrary(source: MetalKernel.shaderSource,
                                      options: nil)
        } catch {
            return nil
        }
        guard let fn = lib.makeFunction(name: "hamming_distance_kernel") else {
            return nil
        }
        do {
            self.pipeline = try dev.makeComputePipelineState(function: fn)
        } catch {
            return nil
        }
        guard let p = MetalBufferPool(device: dev, maxN: maxN) else {
            return nil
        }
        self.device = dev
        self.queue = q
        self.pool = p
    }

    public var kind: KernelKind { .metal }

    // MARK: - popcount64 (inherited semantics)

    @inlinable
    public func popcount64(_ x: UInt64) -> Int {
        return x.nonzeroBitCount
    }

    // MARK: - hammingDistance256 (inherited semantics)
    //
    // Per-pair Metal dispatch would cost ~10-30 µs of overhead
    // for a sub-nanosecond computation. The scalar path runs in
    // ~2 ns. Use scalar.

    public func hammingDistance256(_ a: Fingerprint256, _ b: Fingerprint256) -> Int {
        var total = 0
        for i in 0..<4 {
            total += popcount64(a.words[i] ^ b.words[i])
        }
        return total
    }

    // MARK: - hammingDistanceBatch via Metal compute (Phase 2.β-2(c))

    /// Batched Hamming distance via the
    /// `hamming_distance_kernel` Metal compute shader.
    /// Dispatches one thread per candidate; each thread XORs
    /// its candidate against the anchor and popcounts the
    /// result. On unified-memory Apple Silicon, the result
    /// buffer is readable on CPU with zero copy after
    /// `waitUntilCompleted`.
    ///
    /// On any Metal failure (buffer alloc, command-buffer
    /// creation, encoder setup), falls through to the scalar
    /// pair-at-a-time loop to preserve correctness.
    public func hammingDistanceBatch(probe: Fingerprint256,
                                     candidates: [Fingerprint256]) -> [Int] {
        let n = candidates.count
        if n == 0 { return [] }

        // Path A: N <= maxN, use the persistent buffer pool.
        // Path B: N > maxN, allocate fresh buffers (slow path).
        if n <= pool.maxN {
            return dispatchWithPool(probe: probe, candidates: candidates)
        } else {
            return dispatchWithFreshBuffers(probe: probe, candidates: candidates)
        }
    }

    /// Fast path: persistent buffer pool, no per-call allocation.
    /// Allocates only the command buffer + encoder. Phase 2.δ-2's
    /// hypothesis: this is the path that should cut the ~70 µs
    /// per-call floor measured in Phase 2.β-2(c).
    private func dispatchWithPool(probe: Fingerprint256,
                                  candidates: [Fingerprint256]) -> [Int] {
        let n = candidates.count
        let fpSize = MemoryLayout<Fingerprint256>.size

        // Write anchor.
        var localProbe = probe
        withUnsafeBytes(of: &localProbe) { src in
            pool.anchorBuf.contents().copyMemory(
                from: src.baseAddress!, byteCount: fpSize)
        }

        // Write candidates.
        let candDst = pool.candBuf.contents().assumingMemoryBound(to: Fingerprint256.self)
        for i in 0..<n {
            candDst[i] = candidates[i]
        }

        // Write count.
        let countPtr = pool.countBuf.contents().assumingMemoryBound(to: UInt32.self)
        countPtr[0] = UInt32(n)

        // Note: mask was written once at pool construction (0xF).

        // Encode and dispatch using pooled buffers.
        guard let cmdBuf = queue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder() else {
            return scalarFallback(probe: probe, candidates: candidates)
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(pool.anchorBuf, offset: 0, index: 0)
        encoder.setBuffer(pool.candBuf,   offset: 0, index: 1)
        encoder.setBuffer(pool.maskBuf,   offset: 0, index: 2)
        encoder.setBuffer(pool.countBuf,  offset: 0, index: 3)
        encoder.setBuffer(pool.distBuf,   offset: 0, index: 4)

        let maxTg = pipeline.maxTotalThreadsPerThreadgroup
        let tgWidth = Swift.min(256, maxTg, Swift.max(1, n))
        let grid = MTLSize(width: n, height: 1, depth: 1)
        let tg   = MTLSize(width: tgWidth, height: 1, depth: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: tg)
        encoder.endEncoding()

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        if cmdBuf.error != nil {
            return scalarFallback(probe: probe, candidates: candidates)
        }

        let distSrc = pool.distBuf.contents().assumingMemoryBound(to: UInt32.self)
        var out = [Int]()
        out.reserveCapacity(n)
        for i in 0..<n {
            out.append(Int(distSrc[i]))
        }
        return out
    }

    /// Slow path: candidate count exceeds the persistent pool's
    /// maxN. Allocate fresh buffers for this call. Caller pays
    /// the full ~70 µs dispatch floor measured in Phase 2.β-2(c).
    private func dispatchWithFreshBuffers(probe: Fingerprint256,
                                          candidates: [Fingerprint256]) -> [Int] {
        let n = candidates.count
        let fpSize = MemoryLayout<Fingerprint256>.size

        guard let anchorBuf = device.makeBuffer(length: fpSize,
                                                options: .storageModeShared) else {
            return scalarFallback(probe: probe, candidates: candidates)
        }
        var localProbe = probe
        withUnsafeBytes(of: &localProbe) { src in
            anchorBuf.contents().copyMemory(from: src.baseAddress!, byteCount: fpSize)
        }

        guard let candBuf = device.makeBuffer(length: fpSize * n,
                                              options: .storageModeShared) else {
            return scalarFallback(probe: probe, candidates: candidates)
        }
        let candDst = candBuf.contents().assumingMemoryBound(to: Fingerprint256.self)
        for i in 0..<n {
            candDst[i] = candidates[i]
        }

        var blockMask: UInt32 = 0xF
        guard let maskBuf = device.makeBuffer(bytes: &blockMask,
                                              length: MemoryLayout<UInt32>.size,
                                              options: .storageModeShared) else {
            return scalarFallback(probe: probe, candidates: candidates)
        }

        var candCount = UInt32(n)
        guard let countBuf = device.makeBuffer(bytes: &candCount,
                                               length: MemoryLayout<UInt32>.size,
                                               options: .storageModeShared) else {
            return scalarFallback(probe: probe, candidates: candidates)
        }

        let distSize = MemoryLayout<UInt32>.size * n
        guard let distBuf = device.makeBuffer(length: distSize,
                                              options: .storageModeShared) else {
            return scalarFallback(probe: probe, candidates: candidates)
        }
        memset(distBuf.contents(), 0, distSize)

        guard let cmdBuf = queue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder() else {
            return scalarFallback(probe: probe, candidates: candidates)
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(anchorBuf, offset: 0, index: 0)
        encoder.setBuffer(candBuf,   offset: 0, index: 1)
        encoder.setBuffer(maskBuf,   offset: 0, index: 2)
        encoder.setBuffer(countBuf,  offset: 0, index: 3)
        encoder.setBuffer(distBuf,   offset: 0, index: 4)

        let maxTg = pipeline.maxTotalThreadsPerThreadgroup
        let tgWidth = Swift.min(256, maxTg, Swift.max(1, n))
        let grid = MTLSize(width: n, height: 1, depth: 1)
        let tg   = MTLSize(width: tgWidth, height: 1, depth: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: tg)
        encoder.endEncoding()

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        if cmdBuf.error != nil {
            return scalarFallback(probe: probe, candidates: candidates)
        }

        let distSrc = distBuf.contents().assumingMemoryBound(to: UInt32.self)
        var out = [Int]()
        out.reserveCapacity(n)
        for i in 0..<n {
            out.append(Int(distSrc[i]))
        }
        return out
    }

    /// Top-K via Metal batched distance + CPU sort. For typical
    /// K (10-100) the CPU pass over the result buffer is faster
    /// than a GPU reduction per the shader file's note.
    public func hammingTopK(probe: Fingerprint256,
                            candidates: [Fingerprint256],
                            k: Int) -> [(index: Int, distance: Int)] {
        // Metal-backed: GPU-batched distance computation, then
        // CPU heap-of-K selection. Eliminates the prior
        // allocate-N-then-sort anti-pattern. Output ordering
        // matches ScalarKernel exactly so hamming_nn conformance
        // PASSes.
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

    // MARK: - Inherited: OR-reduce and SimHash use scalar default

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

    // MARK: - Private: scalar fallback for Metal failure modes

    private func scalarFallback(probe: Fingerprint256,
                                candidates: [Fingerprint256]) -> [Int] {
        var out = [Int]()
        out.reserveCapacity(candidates.count)
        for cand in candidates {
            out.append(hammingDistance256(probe, cand))
        }
        return out
    }

    // MARK: - Embedded Metal shader source

    /// The `hamming_distance_kernel` compute function. This is
    /// a verbatim copy of the relevant portion of
    /// `glref-metal-hamming_nn.metal`. Embedded as a string so
    /// the SwiftPM build doesn't need a custom Metal-compilation
    /// step.
    ///
    /// If the canonical .metal file is updated, this string must
    /// be updated to match; the conformance gate
    /// (`validate-vectors --kernel metal`) catches divergence
    /// because the CRC will not match the scalar reference.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    constant uint kBlockMask0 = 0x1;
    constant uint kBlockMask1 = 0x2;
    constant uint kBlockMask2 = 0x4;
    constant uint kBlockMask3 = 0x8;
    constant uint kAllBlocks  = 0xF;

    struct Fingerprint256 {
        uint4 lo;
        uint4 hi;
    };

    inline uint hamming_uint4(uint4 a, uint4 b) {
        uint4 x = a ^ b;
        uint4 c = popcount(x);
        return c.x + c.y + c.z + c.w;
    }

    inline uint hamming_block(uint a_lo, uint a_hi, uint b_lo, uint b_hi) {
        return popcount(a_lo ^ b_lo) + popcount(a_hi ^ b_hi);
    }

    inline uint hamming_distance(Fingerprint256 a, Fingerprint256 b, uint block_mask) {
        if (block_mask == kAllBlocks) {
            return hamming_uint4(a.lo, b.lo) + hamming_uint4(a.hi, b.hi);
        }
        uint d = 0;
        if ((block_mask & kBlockMask0) != 0) {
            d += hamming_block(a.lo.x, a.lo.y, b.lo.x, b.lo.y);
        }
        if ((block_mask & kBlockMask1) != 0) {
            d += hamming_block(a.lo.z, a.lo.w, b.lo.z, b.lo.w);
        }
        if ((block_mask & kBlockMask2) != 0) {
            d += hamming_block(a.hi.x, a.hi.y, b.hi.x, b.hi.y);
        }
        if ((block_mask & kBlockMask3) != 0) {
            d += hamming_block(a.hi.z, a.hi.w, b.hi.z, b.hi.w);
        }
        return d;
    }

    kernel void hamming_distance_kernel(
        constant Fingerprint256 &anchor              [[buffer(0)]],
        constant Fingerprint256 *candidates          [[buffer(1)]],
        constant uint            &block_mask         [[buffer(2)]],
        constant uint            &candidate_count    [[buffer(3)]],
        device   uint            *distances          [[buffer(4)]],
        uint                      gid                [[thread_position_in_grid]])
    {
        if (gid >= candidate_count) {
            return;
        }
        Fingerprint256 cand = candidates[gid];
        distances[gid] = hamming_distance(anchor, cand, block_mask);
    }
    """
}

#endif // canImport(Metal)
