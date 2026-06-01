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
// project standard (LatticeLib, SubstrateTypes ST-TEST-01 precedent).

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

// MARK: - Swift / Rust library-test parity matrix
//
// Each Swift suite asserts the behavior set its Rust `#[test]` module
// asserts. The Rust leg has 33 `#[test]` functions (31 on stable; the
// 2 `kernel_simd.rs` tests are gated behind the `simd-nightly` Cargo
// feature and run under `cargo +nightly test --features simd-nightly`).
// On the Swift leg those two SIMD count-fold behaviors run
// unconditionally on arm64, since `SimdKernel` is always available via
// `import simd` (no stable/nightly split).
//
//   Rust module (count)      →  Swift suite(s)
//   ───────────────────────────────────────────────────────────────
//   bit_field.rs   (14)      →  BitField                 (14 + maskedEquals)
//   sha256.rs      (5)       →  SHA256                    (5)
//   hamming_nn.rs  (2)       →  HammingNN                 (2)
//   kernel.rs      (10)      →  PortableKernel dispatcher (5)
//                               + count-fold conformance  (countFoldConformanceAcrossKernels)
//                               + PortableKernel top-K     (4)
//   kernel_simd.rs (2)       →  PortableKernel count-fold  (simdCountFold* ×2)
//
// Swift adds, beyond the Rust unit tests (expansion, never narrowing):
//   - BitField.maskedEquals (public API the Rust port ships untested)
//   - PortableKernel cross-kernel bit-identity conformance over every
//     host-reachable backend (the cookbook §18.2 contract the Rust leg
//     proves via the four-way CRC gate).

