// SubstrateKernelTests.swift
//
// SubstrateKernel package-level smoke suite. Confirms the kernel
// protocol is importable and ScalarKernel produces deterministic
// output. Per-type behavior coverage lives in the peer suites
// (BitFieldTests, SHA256Tests, HammingNNTests, PortableKernelTests),
// each mirroring the behavior set its Rust `#[test]` module asserts.
// Full bit-identical conformance against the canonical vector files
// lives in docs/validation/substrate_math_performance/ (out of scope
// here).
//
// swift-testing (`import Testing` / `@Test` / `#expect`), per the
// project standard (LatticeKit, SubstrateTypes ST-TEST-01 precedent).

import Testing
@testable import SubstrateKernel
import SubstrateTypes

@Suite("SubstrateKernel package smoke")
struct SubstrateKernelSmokeTests {

    @Test("ScalarKernel Hamming distance equals XOR popcount")
    func scalarKernelHammingDistanceMatchesXorPopcount() {
        let a = Fingerprint256(block0: 0xAAAA_AAAA_AAAA_AAAA, block1: 0, block2: 0, block3: 0)
        let b = Fingerprint256(block0: 0x5555_5555_5555_5555, block1: 0, block2: 0, block3: 0)
        // Every bit differs in word 0 → 64 bit differences.
        #expect(ScalarKernel().hammingDistance256(a, b) == 64)
    }

    @Test("ScalarKernel OR-reduce is commutative")
    func scalarKernelOrReduceIsCommutative() {
        let xs = [
            Fingerprint256(block0: 0x1, block1: 0x2, block2: 0x4, block3: 0x8),
            Fingerprint256(block0: 0x10, block1: 0x20, block2: 0x40, block3: 0x80),
            Fingerprint256(block0: 0x100, block1: 0x200, block2: 0x400, block3: 0x800),
        ]
        let forward = ScalarKernel().orReduce256(xs)
        let reverse = ScalarKernel().orReduce256(xs.reversed())
        #expect(forward == reverse)
    }
}
