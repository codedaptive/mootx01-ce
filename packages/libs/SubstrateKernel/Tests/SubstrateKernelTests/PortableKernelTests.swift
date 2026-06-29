// PortableKernelTests.swift
//
// Swift library-test peer suite for the portable kernel layer:
// PortableKernel.swift (the SubstrateKernel protocol, ScalarKernel
// reference, KernelKind, and the PortableKernel selector) plus the
// backend specializations reachable on the build host —
// PortableKernel-SIMD.swift (SimdKernel), PortableKernel-NEON.swift
// (NeonKernel), PortableKernel-Metal.swift (MetalKernel).
//
// Mirrors the behavior set asserted by the Rust `kernel.rs` (10 tests)
// and `kernel_simd.rs` (2 tests) `#[test]` modules:
//   - dispatcher selection (of_kind / for_current_platform)
//   - dispatcher output matches the scalar reference
//   - count-fold conformance across kernel kinds, and SIMD count-fold
//     across plane-boundary sizes
//   - top-K tie-break, full-sort-prefix equivalence, and degenerate k
//
// It additionally asserts the substrate's core conformance contract
// (cookbook §18.2): every host-reachable backend produces output
// bit-identical to ScalarKernel for hammingDistance256,
// hammingDistanceBatch, hammingTopK, orReduce256, countFold256, and
// simhashBlockBatch. The Rust leg proves this via the four-way
// conformance gate (CRC over committed vectors); on the Swift leg the
// scalar reference is the in-process oracle. This expands coverage
// beyond the Rust unit tests without narrowing any of their assertions.
//
// Backend reachability for the conformance sweep (Known Ambiguity #1):
// NEON behind `canImport(simd)` (per the `reachableKernels()` helper);
// SIMD is always reachable (SimdKernel() is unconditional);
// Metal behind `canImport(Metal)` AND a non-nil default device.
// Kernels the host can't run are simply not exercised; the scalar
// reference is always present.

import Testing
@testable import SubstrateKernel
import SubstrateTypes

// MARK: - Deterministic fixtures (mirror the Rust generators)

/// SplitMix-style cohort, mirroring `kernel.rs`
/// `dispatcher_or_reduce_matches_scalar`: 32 fingerprints from the
/// SplitMix64 multiplier constants.
private func orReduceFixture() -> [Fingerprint256] {
    (0..<32).map { n in
        let i = UInt64(n)
        return Fingerprint256(block0: i,
                              block1: i &* 0x9E3779B97F4A7C15,
                              block2: i &* 0xBF58476D1CE4E5B9,
                              block3: i &* 0x94D049BB133111EB)
    }
}

/// Cohort mirroring `kernel.rs` `count_fold_conformance_across_kernels`:
/// `count` fingerprints, all four blocks from distinct SplitMix64
/// multipliers.
private func countFoldFixture(_ count: Int) -> [Fingerprint256] {
    (0..<count).map { n in
        let i = UInt64(n)
        return Fingerprint256(block0: i &* 0x9E3779B97F4A7C15,
                              block1: i &* 0xBF58476D1CE4E5B9,
                              block2: i &* 0x94D049BB133111EB,
                              block3: i &* 0x2545F4914F6CDD1D)
    }
}

/// Deterministic xorshift64 fingerprints, mirroring the PRNG used by
/// `kernel.rs` `hamming_top_k_equals_full_sort_prefix` and the
/// `kernel_simd.rs` `fingerprints` helper. `initialState` is the seed
/// state (callers pre-apply any seed mixing the Rust helper applies).
private func xorshiftFingerprints(initialState: UInt64, count: Int) -> [Fingerprint256] {
    var state = initialState
    func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    return (0..<count).map { _ in
        Fingerprint256(block0: next(), block1: next(), block2: next(), block3: next())
    }
}

/// Every kernel backend instantiable on the current build host. The
/// scalar reference is always first. SIMD/NEON/Metal are appended only
/// where their platform predicates hold (and Metal only when a system
/// GPU exists), exactly as the production `kernel(of:)` selector gates
/// them.
private func reachableKernels() -> [SubstrateKernel] {
    var kernels: [SubstrateKernel] = [ScalarKernel()]
    #if canImport(simd)
    kernels.append(SimdKernel())
    kernels.append(NeonKernel())
    #endif
    #if canImport(Metal)
    if let metal = MetalKernel() { kernels.append(metal) }
    #endif
    return kernels
}

// MARK: - Dispatcher selection + scalar-equivalence (kernel.rs 1–4, 6)

@Suite("PortableKernel dispatcher")
struct PortableKernelDispatcherTests {

    @Test("of_kind(.scalar) returns a scalar kernel")
    func ofKindScalarReturnsScalar() {
        #expect(PortableKernel.kernel(of: .scalar).kind == .scalar)
    }

    @Test("of_kind(.simd) returns a SIMD kernel where import simd is available")
    func ofKindSimdReturnsSimd() {
        // Swift has no stable/nightly split: `import simd` is available
        // on Apple platforms and aarch64 Linux, so the SIMD kernel is
        // always selectable here. The Rust counterpart gates this on the
        // `simd-nightly` feature.
        #if canImport(simd)
        #expect(PortableKernel.kernel(of: .simd).kind == .simd)
        #else
        #expect(PortableKernel.kernel(of: .simd).kind == .scalar)
        #endif
    }

    @Test("for_current_platform picks SIMD on arm64, scalar elsewhere")
    func forCurrentPlatformPicksSimdOnArm64() {
        #if arch(arm64)
        #expect(PortableKernel.kernelForCurrentPlatform().kind == .simd)
        #else
        #expect(PortableKernel.kernelForCurrentPlatform().kind == .scalar)
        #endif
    }

    @Test("dispatcher OR-reduce matches the scalar reference")
    func dispatcherOrReduceMatchesScalar() {
        let fps = orReduceFixture()
        let s = ScalarKernel().orReduce256(fps)
        let d = PortableKernel.kernelForCurrentPlatform().orReduce256(fps)
        #expect(s == d)
    }

    @Test("dispatcher Hamming distance matches the scalar reference")
    func dispatcherHammingDistanceMatchesScalar() {
        let a = Fingerprint256(block0: 0xCAFE_BABE, block1: 0xDEAD_BEEF,
                               block2: 0x0123_4567_89AB_CDEF, block3: 0xFEDC_BA98_7654_3210)
        let b = Fingerprint256(block0: 0x1234_5678, block1: 0x9ABC_DEF0,
                               block2: 0x0F0F_0F0F_0F0F_0F0F, block3: 0xF0F0_F0F0_F0F0_F0F0)
        let s = ScalarKernel().hammingDistance256(a, b)
        let d = PortableKernel.kernelForCurrentPlatform().hammingDistance256(a, b)
        #expect(s == d)
    }
}

// MARK: - Count-fold conformance (kernel.rs 5 + kernel_simd.rs 1–2)

@Suite("PortableKernel count-fold conformance")
struct PortableKernelCountFoldTests {

    /// Every KernelKind selectable through `kernel(of:)`. Kinds without
    /// a `countFold256` override inherit the scalar reference and pass
    /// trivially; the gate becomes load-bearing the moment a vectorized
    /// override lands (SimdKernel already has one).
    private let allKinds: [KernelKind] = [.scalar, .simd, .neon, .metal, .avx512, .avx2]

    @Test("count-fold is byte-identical to the scalar reference across all kernel kinds")
    func countFoldConformanceAcrossKernels() {
        let fps = countFoldFixture(257)
        let reference = ScalarKernel().countFold256(fps)
        for kind in allKinds {
            let k = PortableKernel.kernel(of: kind)
            #expect(k.countFold256(fps) == reference,
                    "kernel \(kind.rawValue) diverged from the scalar count-fold reference")
        }
    }

    @Test("SIMD count-fold matches scalar across sizes that cross plane boundaries")
    func simdCountFoldMatchesScalarAcrossSizes() {
        #if canImport(simd)
        let scalar = ScalarKernel()
        let simd = SimdKernel()
        for n in [1, 2, 3, 4, 7, 8, 15, 16, 31, 255, 256, 257, 1000, 4096] {
            // Mirror kernel_simd.rs: seed = n * FNV_prime, then the
            // helper mixes in the SplitMix64 increment.
            let seed = (UInt64(n) &* 0x0000_0100_0000_01B3) &+ 0x9E3779B97F4A7C15
            let fps = xorshiftFingerprints(initialState: seed, count: n)
            let reference = scalar.countFold256(fps)
            let got = simd.countFold256(fps)
            #expect(got == reference, "SIMD count-fold diverged from scalar at n=\(n)")
            #expect(got.n == UInt32(n))
        }
        #endif
    }

    @Test("SIMD count-fold of an empty cohort is the empty count-vector")
    func simdCountFoldEmpty() {
        #if canImport(simd)
        #expect(SimdKernel().countFold256([]) == CountVector256())
        #endif
    }
}

// MARK: - Top-K behavior (kernel.rs 7–10)

@Suite("PortableKernel top-K")
struct PortableKernelTopKTests {

    @Test("top-K ties break by ascending index")
    func hammingTopKTiesBreakByIndexAscending() {
        let probe = Fingerprint256.zero
        let candidates = [
            Fingerprint256(block0: 0b0001, block1: 0, block2: 0, block3: 0),  // idx 0, d=1
            Fingerprint256(block0: 0b0011, block1: 0, block2: 0, block3: 0),  // idx 1, d=2 (tie)
            Fingerprint256(block0: 0b0111, block1: 0, block2: 0, block3: 0),  // idx 2, d=3
            Fingerprint256(block0: 0, block1: 0b0001, block2: 0, block3: 0),  // idx 3, d=1 (tie)
            Fingerprint256(block0: 0, block1: 0b0011, block2: 0, block3: 0),  // idx 4, d=2 (tie)
            Fingerprint256(block0: 0b1111, block1: 0, block2: 0, block3: 0),  // idx 5, d=4
            Fingerprint256(block0: 0, block1: 0, block2: 0b0001, block3: 0),  // idx 6, d=1 (tie)
            Fingerprint256(block0: 0, block1: 0, block2: 0b0011, block3: 0),  // idx 7, d=2 (tie)
        ]
        let top = ScalarKernel().hammingTopK(probe: probe, candidates: candidates, k: 5)
        #expect(top.count == 5)
        #expect(top[0].index == 0 && top[0].distance == 1)
        #expect(top[1].index == 3 && top[1].distance == 1)
        #expect(top[2].index == 6 && top[2].distance == 1)
        #expect(top[3].index == 1 && top[3].distance == 2)
        #expect(top[4].index == 4 && top[4].distance == 2)
    }

    @Test("heap top-K equals the full-sort prefix")
    func hammingTopKEqualsFullSortPrefix() {
        let kernel = ScalarKernel()
        let candidates = xorshiftFingerprints(initialState: 0xCAFE_BABE_DEAD_BEEF, count: 200)
        let probe = Fingerprint256(block0: 0x123, block1: 0x456, block2: 0x789, block3: 0xABC)

        let viaHeap = kernel.hammingTopK(probe: probe, candidates: candidates, k: 13)

        var scored = candidates.enumerated().map { (idx, fp) in
            (idx, kernel.hammingDistance256(probe, fp))
        }
        scored.sort { a, b in a.1 != b.1 ? a.1 < b.1 : a.0 < b.0 }
        let viaFullSort = Array(scored.prefix(13))

        #expect(viaHeap.map { [$0.index, $0.distance] } == viaFullSort.map { [$0.0, $0.1] },
                "heap diverged from full-sort prefix")
    }

    @Test("top-K with k = 0 returns empty")
    func hammingTopKKZeroReturnsEmpty() {
        let probe = Fingerprint256.zero
        let candidates = [Fingerprint256(block0: 1, block1: 2, block2: 3, block3: 4)]
        #expect(ScalarKernel().hammingTopK(probe: probe, candidates: candidates, k: 0).isEmpty)
    }

    @Test("top-K with k larger than the candidate count returns all candidates")
    func hammingTopKKLargerThanCandidatesReturnsAll() {
        let probe = Fingerprint256.zero
        let candidates = [
            Fingerprint256(block0: 1, block1: 0, block2: 0, block3: 0),
            Fingerprint256(block0: 0, block1: 0, block2: 0, block3: 1),
        ]
        #expect(ScalarKernel().hammingTopK(probe: probe, candidates: candidates, k: 10).count == 2)
    }
}

// MARK: - Cross-kernel bit-identity conformance (cookbook §18.2, expansion)

@Suite("PortableKernel cross-kernel bit-identity")
struct PortableKernelConformanceTests {

    @Test("every host-reachable backend matches the scalar reference bit-for-bit")
    func backendsMatchScalarReference() {
        let scalar = ScalarKernel()
        let probe = Fingerprint256(block0: 0xCAFE_BABE, block1: 0xDEAD_BEEF,
                                   block2: 0x0123_4567_89AB_CDEF, block3: 0xFEDC_BA98_7654_3210)
        let candidates = xorshiftFingerprints(initialState: 0x0F1E_2D3C_4B5A_6978, count: 128)
        let foldFixture = countFoldFixture(200)

        let refSingle = candidates.map { scalar.hammingDistance256(probe, $0) }
        let refBatch = scalar.hammingDistanceBatch(probe: probe, candidates: candidates)
        let refTopK = scalar.hammingTopK(probe: probe, candidates: candidates, k: 10)
            .map { [$0.index, $0.distance] }
        let refOr = scalar.orReduce256(candidates)
        let refFold = scalar.countFold256(foldFixture)

        for k in reachableKernels() {
            let kind = k.kind.rawValue
            #expect(candidates.map { k.hammingDistance256(probe, $0) } == refSingle,
                    "hammingDistance256 diverged on \(kind)")
            #expect(k.hammingDistanceBatch(probe: probe, candidates: candidates) == refBatch,
                    "hammingDistanceBatch diverged on \(kind)")
            #expect(k.hammingTopK(probe: probe, candidates: candidates, k: 10)
                        .map { [$0.index, $0.distance] } == refTopK,
                    "hammingTopK diverged on \(kind)")
            #expect(k.orReduce256(candidates) == refOr,
                    "orReduce256 diverged on \(kind)")
            #expect(k.countFold256(foldFixture) == refFold,
                    "countFold256 diverged on \(kind)")
        }
    }

    @Test("floatSimHashProject: valid dim input produces deterministic output (guard does not perturb math)")
    func floatSimHashProjectValidDimIsDeterministic() {
        // Constructs a minimal FloatSimHashPlanes for dim=4
        // (256 planes × 4 coords = 1024 bits = 16 UInt64 words) with a
        // known sign-bit pattern and verifies the scalar reference produces
        // the same Fingerprint256 on two calls — the main invariant that
        // Part-6's dim-check guard must not perturb.
        let dim = 4
        let wordCount = (256 * dim + 63) / 64  // = 16
        // Alternating 0xAA / 0x55 gives a deterministic mix of +1/-1 planes.
        var words = [UInt64]()
        words.reserveCapacity(wordCount)
        for i in 0..<wordCount { words.append(i % 2 == 0 ? 0xAAAA_AAAA_AAAA_AAAA : 0x5555_5555_5555_5555) }
        let planes = FloatSimHashPlanes(dim: dim, signBits: words)
        let vector: [Float] = [1.0, -0.5, 0.25, -0.125]

        let scalar = ScalarKernel()
        let fp1 = scalar.floatSimHashProject(vector: vector, planes: planes)
        let fp2 = scalar.floatSimHashProject(vector: vector, planes: planes)
        #expect(fp1 == fp2, "floatSimHashProject must be deterministic for valid dim inputs")
    }

    @Test("batched SimHash backends match the scalar reference")
    func simhashBatchMatchesScalarReference() {
        let scalar = ScalarKernel()
        // A dense block-1 family: 64 planes over a single 64-bit input word.
        let seed = [UInt8](repeating: 0x5A, count: 32)
        let family = HyperplaneFamily.generate(seed: seed, blockIndex: 1,
                                                inputBitLength: 64, density: 1.0)
        let inputs: [[UInt64]] = (0..<16).map { [UInt64($0) &* 0x9E3779B97F4A7C15] }
        let reference = scalar.simhashBlockBatch(inputs: inputs, family: family)

        for k in reachableKernels() {
            #expect(k.simhashBlockBatch(inputs: inputs, family: family) == reference,
                    "simhashBlockBatch diverged on \(k.kind.rawValue)")
        }
    }
}
