// PortableKernel.swift
//
// Portable kernel layer per cookbook § 4.4 and paper § 11.3.
//
// The substrate's hot operations (Hamming-NN, OR-reduction,
// bit-sliced field scan, SimHash) route to one of several backends
// depending on the requested KernelKind:
//
//   - simd          (Swift's `import simd` SIMD4<UInt64> — arm64 default)
//   - neon          (direct NEON, available on Apple + aarch64 Linux)
//   - metal         (GPU compute, Apple platforms only)
//   - avx512/avx2   (x86-64 — specialized files; fall through to scalar
//                   in the reference build)
//   - scalar        (portable reference; the conformance gate baseline)
//
// All backends MUST produce bit-identical output for the
// substrate's documented inputs. The four-way conformance gate
// (test-harness/) verifies this by running every cell with the
// same seed and comparing the CRC32 of the resulting state.
//
// This file defines:
//
//   - the SubstrateKernel protocol that every kernel implements
//   - the ScalarKernel reference impl (always available)
//   - the kernelForCurrentPlatform() factory
//
// NEON, AVX-512, and AVX2 specializations live in:
//
//   glref-swift-PortableKernel-NEON.swift   (Apple silicon)
//   glref-swift-PortableKernel-AVX512.swift (Intel/AMD x86-64)
//   glref-swift-PortableKernel-AVX2.swift   (Intel/AMD x86-64)
//
// Each is compiled conditionally with #if canImport(simd) or
// platform predicates and links via the same SubstrateKernel
// protocol.
//
// Used by:
//   § 4.4 cookbook   Portable kernel definition (this file)
//   § 11.3 paper     CPU dispatch strategy
//   § 5 cookbook     Fingerprint operations (consumer)
//   § 8 cookbook     OR-reduction, Hamming-NN (consumers)

import Foundation
import SubstrateTypes
import IntellectusLib

/// All hot-path operations the substrate dispatches to a kernel.
/// Every kernel produces bit-identical output for the same inputs.
public protocol SubstrateKernel: Sendable {
    /// Identify the concrete kernel kind. Useful for runtime
    /// introspection (stress-test reporting, dispatcher tests,
    /// logging). Default returns `.scalar`; every concrete kernel
    /// overrides this.
    var kind: KernelKind { get }

    /// Population count of a single 64-bit word.
    func popcount64(_ x: UInt64) -> Int

    /// Hamming distance between two 256-bit fingerprints.
    func hammingDistance256(_ a: Fingerprint256, _ b: Fingerprint256) -> Int

    /// OR-reduce a slice of fingerprints. Identity element is zero;
    /// associative and commutative.
    func orReduce256(_ fingerprints: [Fingerprint256]) -> Fingerprint256

    /// Top-k Hamming-NN scan: returns the k row indices with
    /// smallest Hamming distance to the probe, ranked by distance
    /// ascending (ties broken by row index ascending).
    func hammingTopK(probe: Fingerprint256,
                     candidates: [Fingerprint256],
                     k: Int) -> [(index: Int, distance: Int)]

    /// SimHash compute: project four 64-bit subhashes through a
    /// hyperplane family, sign-quantize per bit, OR the four
    /// blocks into a single Fingerprint256.
    func simhashCompute(subhashes: [UInt64],
                        families: [HyperplaneFamily]) -> Fingerprint256

    // ----- Batched variants (Phase 1 trait extension per
    //       DECISION_KERNEL_LEARNED_DISPATCH_2026-05-17).
    //
    // Default impls in the extension below are loops over the
    // pair-at-a-time ops above, so trait extensions are non-
    // breaking and every conformer gets correct (if slow) batched
    // behavior for free. Performance backends override these to
    // amortize per-call overhead across a SIMD or GPU dispatch
    // unit.

    /// Hamming distance between `probe` and every candidate. Output
    /// is the same length as `candidates`, indexed identically.
    func hammingDistanceBatch(probe: Fingerprint256,
                              candidates: [Fingerprint256]) -> [Int]

    /// SimHash block over each input vector, all against the same
    /// hyperplane family. Output is the same length as `inputs`,
    /// indexed identically.
    func simhashBlockBatch(inputs: [[UInt64]],
                           family: HyperplaneFamily) -> [UInt64]

    /// OR-reduce each batch of fingerprints independently. Output
    /// is the same length as `batches`, indexed identically.
    func orReduceBatch(batches: [[Fingerprint256]]) -> [Fingerprint256]

    /// Count-fold a slice of fingerprints into a count-vector: for
    /// each of the 256 bit positions, the number of members with that
    /// bit set, plus the member count. This is the bundle-algebra fold
    /// (DECISION_BUNDLE_ALGEBRA_AND_ERASURE_2026-05-20). The OR-reduce
    /// above is its degenerate case, saturating each count at one. The
    /// default implementation is the scalar reference; performance
    /// backends override with a vectorized vertical counter, gated
    /// against the reference by the kernel conformance harness.
    func countFold256(_ fingerprints: [Fingerprint256]) -> CountVector256

    /// Count-fold each batch independently. Output is the same length
    /// as `batches`, indexed identically.
    func countFoldBatch(batches: [[Fingerprint256]]) -> [CountVector256]

    /// Float-input SimHash projection: sign-quantize the dot product of
    /// `vector` against each of 256 ±1 hyperplanes carried by `planes` into a
    /// `Fingerprint256` (bit k set ⟺ ⟨vector, plane_k⟩ > 0). The float analog
    /// of `simhashCompute`; the dispatch home for `SubstrateML.FloatSimHash`
    /// (SUBSTRATEKERNEL_SPEC § 5.4). The planes are passed in as data — generated
    /// from a seed in SubstrateML — so the kernel does pure signed-sum-and-sign
    /// with no RNG. The default impl is the scalar reference; a SIMD backend
    /// overrides it with the over-hyperplanes vertical pattern, gated bit-for-bit
    /// against the reference (DECISION_SIMHASH_BACKENDS_2026-05-18).
    func floatSimHashProject(vector: [Float], planes: FloatSimHashPlanes) -> Fingerprint256
}

// MARK: - Default implementations for batched ops
//
// Protocol extensions give every conformer correct batched
// behavior via loops over the pair-at-a-time ops. A backend with
// a faster batched path overrides the method directly.

extension SubstrateKernel {
    public var kind: KernelKind { .scalar }

    public func hammingDistanceBatch(probe: Fingerprint256,
                                     candidates: [Fingerprint256]) -> [Int] {
        return candidates.map { hammingDistance256(probe, $0) }
    }

    public func simhashBlockBatch(inputs: [[UInt64]],
                                  family: HyperplaneFamily) -> [UInt64] {
        // The protocol exposes simhashCompute(subhashes:families:),
        // which projects four subhashes against four families. The
        // single-block batched variant is a thin wrapper that
        // dispatches each input through the same one-family
        // projection: caller folds the four-block composition into
        // four calls of this method, one per family.
        return inputs.map { input in
            SimHash.block(over: input, family: family)
        }
    }

    public func orReduceBatch(batches: [[Fingerprint256]]) -> [Fingerprint256] {
        return batches.map { orReduce256($0) }
    }

    /// Reference count-fold. Delegates to `CountVector256.fold`, the
    /// single canonical accumulation. Every backend inherits this and
    /// is therefore correct immediately; a backend with a vectorized
    /// vertical counter overrides this method and is gated against the
    /// reference output bit for bit.
    public func countFold256(_ fingerprints: [Fingerprint256]) -> CountVector256 {
        return CountVector256.fold(fingerprints)
    }

    public func countFoldBatch(batches: [[Fingerprint256]]) -> [CountVector256] {
        return batches.map { countFold256($0) }
    }

    /// Scalar reference for `floatSimHashProject` — the canonical oracle (I-25).
    /// For each of the 256 hyperplanes, accumulate the signed sum
    /// `Σ_i plane(k,i) * vector[i]` in coordinate order (the fixed reduction
    /// order every backend must reproduce; FP `+` is non-associative, so the
    /// order is part of the contract), and set bit k when the sum is positive.
    /// Empty input projects to the zero fingerprint. A backend with a vectorized
    /// over-hyperplanes path overrides this method and is gated bit-for-bit
    /// against it. Bit-identical to `SubstrateML.FloatSimHash.project` for the
    /// planes that `FloatSimHash.planes(seed:dim:)` materializes.
    public func floatSimHashProject(vector: [Float], planes: FloatSimHashPlanes) -> Fingerprint256 {
        guard !vector.isEmpty else { return .zero }
        let dim = vector.count
        // Invariant: planes must be materialised for exactly this vector
        // dimensionality.  A dim mismatch means the caller built the planes
        // for a different embedding size; the inner loop would index out of
        // bounds on signBits and produce nonsense bits with no other signal.
        // Fail loudly here rather than silently corrupt every downstream
        // conformance result (SUBSTRATEKERNEL_SPEC § 5.4).
        precondition(
            planes.dim == dim,
            "FloatSimHashPlanes.dim (\(planes.dim)) must equal vector.count (\(dim))"
        )
        let expectedWords = (256 * dim + 63) / 64
        precondition(
            planes.signBits.count >= expectedWords,
            "FloatSimHashPlanes.signBits too short: need \(expectedWords) words, got \(planes.signBits.count)"
        )
        var blocks: [UInt64] = [0, 0, 0, 0]
        for k in 0..<256 {
            var sum: Float = 0
            let base = k * dim
            for i in 0..<dim {
                let bitIndex = base + i
                let isPositive = (planes.signBits[bitIndex >> 6] >> UInt64(bitIndex & 63)) & 1 == 1
                let plane: Float = isPositive ? 1 : -1
                sum += plane * vector[i]
            }
            if sum > 0 {
                blocks[k / 64] |= (UInt64(1) << UInt64(k % 64))
            }
        }
        return Fingerprint256(
            block0: blocks[0], block1: blocks[1], block2: blocks[2], block3: blocks[3])
    }
}

// MARK: - Scalar reference implementation

public struct ScalarKernel: SubstrateKernel {

    public init() {}

    public var kind: KernelKind { .scalar }

    @inlinable
    public func popcount64(_ x: UInt64) -> Int {
        return x.nonzeroBitCount
    }

    public func hammingDistance256(_ a: Fingerprint256, _ b: Fingerprint256) -> Int {
        // Phase 2 (decision 2026-05-28 §6.2): one-liner via the
        // Phase 1 combinators. Bit-identical to the prior loop.
        return a.zip4(b, ^).popcount()
    }

    public func orReduce256(_ fingerprints: [Fingerprint256]) -> Fingerprint256 {
        // Phase 2 (decision 2026-05-28 §6.2): one-liner via the
        // Phase 1 combinator. Bit-identical to the prior loop.
        return Fingerprint256.reduce4(fingerprints, |)
    }

    public func hammingTopK(probe: Fingerprint256,
                            candidates: [Fingerprint256],
                            k: Int) -> [(index: Int, distance: Int)] {
        // Phase 3.2 (decision 2026-05-28 §6.3): heap-based top-K.
        // Maintains a max-heap of size k keyed on (distance, index)
        // with the SAME tie-break order as the prior full-sort
        // implementation (row-index ascending among equal distances).
        // O(N log k) instead of O(N log N).
        //
        // Conformance: hamming_nn vectors continue to PASS at CRC
        // 0xb1a25c93 because both algorithms produce the same
        // sorted-ascending top-K result.
        guard k > 0 else { return [] }
        var heap = ScalarKernelMaxHeap()
        for (idx, fp) in candidates.enumerated() {
            let d = hammingDistance256(probe, fp)
            let scored = ScalarKernelScored(distance: d, index: idx)
            if heap.count < k {
                heap.push(scored)
            } else if let top = heap.peek(), scored < top {
                _ = heap.pop()
                heap.push(scored)
            }
        }
        // Drain the heap into a sorted-ascending array.
        var result: [(index: Int, distance: Int)] = []
        result.reserveCapacity(heap.count)
        while let next = heap.pop() {
            result.append((index: next.index, distance: next.distance))
        }
        result.reverse()  // heap drains largest-first; we want smallest-first
        return result
    }

    public func simhashCompute(subhashes: [UInt64],
                               families: [HyperplaneFamily]) -> Fingerprint256 {
        return SimHash.fingerprint(fromSubhashes: subhashes, hyperplanes: families)
    }
}

// MARK: - Kernel selection

public enum KernelKind: String, Sendable {
    case scalar  = "scalar"
    case simd    = "simd"
    case neon    = "neon"
    case metal   = "metal"
    case avx512  = "avx512"
    case avx2    = "avx2"
}

public enum PortableKernel {

    /// Select the best kernel for the current platform. Resolution
    /// order: on aarch64 (Apple silicon and ARM64 Linux), return
    /// `SimdKernel` (portable SIMD via `import simd`, compiles to
    /// NEON `orr.16b` for or_reduce per DECISION_OR_REDUCE_BACKENDS_2026-05-17).
    /// On x86_64 with AVX-512 or AVX2, future overlays may return
    /// specialized kernels; the reference build falls back to scalar.
    /// Substrate ALWAYS provides the scalar reference; the platform-
    /// specific kernels are opt-in via build flags.
    ///
    /// Telemetry: emits `substrate.kernel.backend_selected` via
    /// IntellectusLib when monitoring is enabled. When monitoring is
    /// OFF (the default), the emission is a short-circuited no-op —
    /// the payload autoclosure is never evaluated and no clock is
    /// read. The selection itself is compile-time-static per arch;
    /// no runtime fallback exists in this factory, so no
    /// `substrate.kernel.fallback` metric is emitted (MANAGER_1.0_PLAN §2).
    public static func kernelForCurrentPlatform() -> SubstrateKernel {
        #if arch(arm64)
        // SimdKernel strictly dominates ScalarKernel on aarch64 for
        // the SIMD-implemented ops; inherited scalar impls are
        // identical for the others. No threshold to learn.
        let selected = SimdKernel()
        #else
        // Other platforms: the reference dispatch returns scalar.
        // Platform-specific overlays compile in a
        // kernelForCurrentPlatform override that returns AVX-512 /
        // AVX2 implementations.
        let selected = ScalarKernel()
        #endif

        // Emit backend_selected telemetry. The ts is caller-supplied
        // epoch seconds per IntellectusLib's determinism contract: the
        // math engines never call a clock; this factory-level side-effect
        // does. Monitoring is off by default, so the autoclosure below
        // is never evaluated in normal (non-observer) runs and no clock
        // is called in tests.
        //
        // The arch tag uses a compile-time string matching the Swift
        // conditional (#if arch(arm64)). This is stable — the tag never
        // changes at runtime for a given binary.
        Intellectus.report(.metric(
            name: "substrate.kernel.backend_selected",
            value: 1.0,
            tags: [
                "backend": selected.kind.rawValue,
                "arch": PortableKernel.currentArchTag,
            ],
            ts: Date().timeIntervalSince1970
        ))

        return selected
    }

    // MARK: - Internal helpers

    /// Compile-time-constant architecture tag for telemetry. Matches
    /// the Swift conditional that drives the kernel selection above.
    /// "arm64" on Apple Silicon and aarch64 Linux; "x86_64" elsewhere.
    static let currentArchTag: String = {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "other"
        #endif
    }()

    /// Explicit kernel selector for the conformance test harness.
    /// The harness runs every kernel against the same inputs and
    /// compares output bit-for-bit.
    public static func kernel(of kind: KernelKind) -> SubstrateKernel {
        switch kind {
        case .scalar: return ScalarKernel()
        case .simd:   return SimdKernel()
        case .neon:
            // NeonKernel uses Swift's `import simd` directly (no
            // arm_neon.h bridge). Available wherever the simd
            // module imports successfully, which is Apple platforms
            // and aarch64 Linux. On unsupported targets, fall
            // through to scalar.
            #if canImport(simd)
            return NeonKernel()
            #else
            return ScalarKernel()
            #endif
        case .metal:
            // MetalKernel requires Metal framework + a default
            // GPU. The MetalKernel? initializer returns nil if
            // MTLCreateSystemDefaultDevice() returns nil (CI
            // without GPU, virtualization). Fall through to
            // scalar in that case.
            #if canImport(Metal)
            if let k = MetalKernel() { return k }
            return ScalarKernel()
            #else
            return ScalarKernel()
            #endif
        case .avx512, .avx2:
            // Specialized direct-intrinsic kernels are conditional-compile
            // in their own files; the reference build falls through to scalar.
            // `.simd` (above) is the portable SIMD path via `import simd` /
            // `std::simd` and is the recommended kernel on aarch64 today.
            return ScalarKernel()
        }
    }

    /// Bit-identical output assertion. Used by the conformance
    /// harness to verify every kernel produces the same result.
    public static func assertEqual(_ lhs: SubstrateKernel,
                                   _ rhs: SubstrateKernel,
                                   probe: Fingerprint256,
                                   candidates: [Fingerprint256],
                                   k: Int) -> Bool {
        let l = lhs.hammingTopK(probe: probe, candidates: candidates, k: k)
        let r = rhs.hammingTopK(probe: probe, candidates: candidates, k: k)
        guard l.count == r.count else { return false }
        for i in 0..<l.count {
            if l[i].index != r[i].index { return false }
            if l[i].distance != r[i].distance { return false }
        }
        return true
    }
}


// MARK: - ScalarKernel heap helpers (Phase 3.2)
//
// Private to the module. A small binary max-heap of
// `(distance, index)` tuples with tuple-lex ordering: a candidate
// with a SMALLER (distance, index) wins admission to the top-K.
// The heap's TOP is the worst (largest) admitted candidate; we
// evict it on every successful insertion when at capacity.

internal struct ScalarKernelScored: Comparable {
    let distance: Int
    let index: Int

    static func < (lhs: ScalarKernelScored, rhs: ScalarKernelScored) -> Bool {
        if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
        return lhs.index < rhs.index
    }
}

internal struct ScalarKernelMaxHeap {
    private var storage: [ScalarKernelScored] = []

    var count: Int { storage.count }

    func peek() -> ScalarKernelScored? { storage.first }

    mutating func push(_ x: ScalarKernelScored) {
        storage.append(x)
        siftUp(storage.count - 1)
    }

    mutating func pop() -> ScalarKernelScored? {
        guard !storage.isEmpty else { return nil }
        storage.swapAt(0, storage.count - 1)
        let max = storage.removeLast()
        if !storage.isEmpty { siftDown(0) }
        return max
    }

    private mutating func siftUp(_ start: Int) {
        var i = start
        while i > 0 {
            let parent = (i - 1) / 2
            if storage[i] > storage[parent] {
                storage.swapAt(i, parent)
                i = parent
            } else {
                return
            }
        }
    }

    private mutating func siftDown(_ start: Int) {
        var i = start
        let n = storage.count
        while true {
            let l = 2 * i + 1
            let r = 2 * i + 2
            var largest = i
            if l < n && storage[l] > storage[largest] { largest = l }
            if r < n && storage[r] > storage[largest] { largest = r }
            if largest == i { return }
            storage.swapAt(i, largest)
            i = largest
        }
    }
}
