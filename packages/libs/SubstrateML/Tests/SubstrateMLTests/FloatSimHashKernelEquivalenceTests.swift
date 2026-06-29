// FloatSimHashKernelEquivalenceTests.swift
//
// Step-1 (M4) proof: the SubstrateKernel dispatch op `floatSimHashProject`
// (scalar reference) reproduces the SubstrateML `FloatSimHash.project` oracle
// EXACTLY, for the same seed + vector, via planes materialized by
// `FloatSimHash.planes`. This is the bit-identity gate for the relocation of
// the float projection into the kernel dispatch (SUBSTRATEKERNEL_SPEC § 5.4):
// the new generate-then-apply path must equal today's inline-RNG path.
//
// Cross-port: the Rust port carries the equivalent test. Because
// `FloatSimHash.project` is already cross-port bit-identical (its existing
// conformance), new == oracle in each port ⟹ the new path is cross-port
// bit-identical transitively.

import Testing
import SubstrateTypes
import SubstrateKernel
@testable import SubstrateML

@Suite struct FloatSimHashKernelEquivalenceTests {

    /// For a spread of seeds and dimensions, the scalar kernel op fed
    /// `FloatSimHash.planes(seed:dim:)` produces the identical `Fingerprint256`
    /// as `FloatSimHash.project(vector:seed:)`. Vectors are sign-mixed so the
    /// per-hyperplane sums land near zero — the exact regime where a reordered
    /// reduction would flip a bit, so an accidental non-faithful relocation
    /// would be caught here.
    @Test func scalarKernelMatchesOracle() {
        let kernel = ScalarKernel()
        let seeds: [UInt64] = [0, 1, 0x4644_435F_5631_5F50, 0xDEAD_BEEF_CAFE_F00D]
        let dims = [1, 8, 256, 384, 768]
        for seed in seeds {
            for dim in dims {
                let v = (0..<dim).map { i -> Float in Float((i * 31) % 13) - 6.0 }
                let expected = FloatSimHash.project(vector: v, seed: seed)
                let planes = FloatSimHash.planes(seed: seed, dim: dim)
                let got = kernel.floatSimHashProject(vector: v, planes: planes)
                #expect(got == expected, "mismatch at seed=\(seed) dim=\(dim)")
            }
        }
    }

    /// Empty input projects to the zero fingerprint on both paths.
    @Test func emptyVectorProjectsToZero() {
        let kernel = ScalarKernel()
        let planes = FloatSimHash.planes(seed: 1, dim: 0)
        let got = kernel.floatSimHashProject(vector: [], planes: planes)
        #expect(got == FloatSimHash.project(vector: [], seed: 1))
        #expect(got == .zero)
    }
}
