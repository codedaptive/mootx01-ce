// DispatcherTests.swift
//
// Dispatcher selection tests for PortableKernel. These assert
// that PortableKernel.kernelForCurrentPlatform() and
// PortableKernel.kernel(of:) return the kernel they claim to
// return. Without these tests, a misconfigured #if gate could
// silently route everything to ScalarKernel while the
// conformance gate still passes (because scalar and simd
// produce identical output). The tests fail loudly if the
// dispatcher routes wrong.
//
// Mirror of the Rust dispatcher tests in
// glref-rust-kernel.rs::tests.

import Testing
@testable import Harness
import GeniusLocusReference

@Suite("PortableKernel dispatcher selection")
struct DispatcherTests {

    // MARK: - Explicit selector

    @Test("kernel(of: .scalar) returns a ScalarKernel")
    func ofKindScalarReturnsScalar() {
        let k = PortableKernel.kernel(of: .scalar)
        #expect(k.kind == .scalar,
                "kernel(of: .scalar) must return a ScalarKernel")
    }

    @Test("kernel(of: .simd) returns a SimdKernel")
    func ofKindSimdReturnsSimd() {
        let k = PortableKernel.kernel(of: .simd)
        #expect(k.kind == .simd,
                "kernel(of: .simd) must return a SimdKernel")
    }

    @Test("kernel(of: .bnns) returns BnnsKernel on Apple, else falls through")
    func ofKindBnnsReturnsBnns() {
        let k = PortableKernel.kernel(of: .bnns)
        #if canImport(Accelerate)
        #expect(k.kind == .bnns,
                "on Apple platforms, kernel(of: .bnns) must return a BnnsKernel; got \(k.kind)")
        #else
        #expect(k.kind == .scalar,
                "on non-Apple platforms, kernel(of: .bnns) must fall through to ScalarKernel; got \(k.kind)")
        #endif
    }

    @Test("kernel(of: .neon) returns NeonKernel where simd is available, else falls through")
    func ofKindNeonReturnsNeon() {
        let k = PortableKernel.kernel(of: .neon)
        #if canImport(simd)
        #expect(k.kind == .neon,
                "on platforms where `import simd` is available, kernel(of: .neon) must return a NeonKernel; got \(k.kind)")
        #else
        #expect(k.kind == .scalar,
                "on platforms without simd, kernel(of: .neon) must fall through to ScalarKernel; got \(k.kind)")
        #endif
    }

    @Test("kernel(of: .metal) returns MetalKernel or falls through to scalar")
    func ofKindMetalReturnsMetalOrFallsThrough() {
        let k = PortableKernel.kernel(of: .metal)
        #if canImport(Metal)
        // On hosts with a usable GPU, kernel(of: .metal) must
        // return a MetalKernel. On headless / virtualized hosts
        // it falls through to scalar. Either is acceptable; the
        // test asserts the dispatcher does NOT return some
        // unrelated kind.
        #expect(k.kind == .metal || k.kind == .scalar,
                "kernel(of: .metal) must return .metal or .scalar; got \(k.kind)")
        #else
        #expect(k.kind == .scalar,
                "on platforms without Metal, kernel(of: .metal) must fall through to ScalarKernel; got \(k.kind)")
        #endif
    }

    // MARK: - Auto-selector (current platform)

    @Test("kernelForCurrentPlatform picks SimdKernel on aarch64")
    func forCurrentPlatformPicksSimdOnAarch64() {
        let k = PortableKernel.kernelForCurrentPlatform()
        #if arch(arm64)
        #expect(k.kind == .simd,
                "on aarch64, kernelForCurrentPlatform must return SimdKernel; got \(k.kind)")
        #else
        #expect(k.kind == .scalar,
                "off aarch64, kernelForCurrentPlatform must return ScalarKernel; got \(k.kind)")
        #endif
    }

    // MARK: - Behavioral conformance
    //
    // If the dispatcher silently routed wrong (e.g., a SimdKernel
    // with a buggy override), these tests catch it independent of
    // the type assertion above.

    @Test("dispatcher orReduce256 matches the scalar reference")
    func dispatcherOrReduceMatchesScalar() {
        let scalar = ScalarKernel()
        let dispatched = PortableKernel.kernelForCurrentPlatform()
        let fingerprints: [Fingerprint256] = (0..<32).map { i in
            let u = UInt64(i)
            return Fingerprint256(block0: u,
                                  block1: u &* 0x9E3779B97F4A7C15,
                                  block2: u &* 0xBF58476D1CE4E5B9,
                                  block3: u &* 0x94D049BB133111EB)
        }
        let s = scalar.orReduce256(fingerprints)
        let d = dispatched.orReduce256(fingerprints)
        #expect(s == d,
                "dispatcher's orReduce256 must produce scalar-identical output; scalar=\(s) dispatched=\(d) kind=\(dispatched.kind)")
    }

    @Test("dispatcher hammingDistance256 matches the scalar reference")
    func dispatcherHammingDistanceMatchesScalar() {
        let scalar = ScalarKernel()
        let dispatched = PortableKernel.kernelForCurrentPlatform()
        let a = Fingerprint256(block0: 0xCAFEBABE,
                               block1: 0xDEADBEEF,
                               block2: 0x0123456789ABCDEF,
                               block3: 0xFEDCBA9876543210)
        let b = Fingerprint256(block0: 0x12345678,
                               block1: 0x9ABCDEF0,
                               block2: 0x0F0F0F0F0F0F0F0F,
                               block3: 0xF0F0F0F0F0F0F0F0)
        #expect(scalar.hammingDistance256(a, b)
                == dispatched.hammingDistance256(a, b))
    }
}
