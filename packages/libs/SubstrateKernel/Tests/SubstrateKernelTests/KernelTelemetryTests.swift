// KernelTelemetryTests.swift
//
// Tests for the IntellectusLib telemetry emission added to
// PortableKernel.kernelForCurrentPlatform() in SUBSTRATE_REPORT_001.
//
// Mirrors the core Rust telemetry sections in
// rust/tests/kernel_telemetry_tests.rs, and adds the Swift
// multi-call emission assertion (§5 eachFactoryCallEmitsOneMetric).
//
// §1 Disabled gate: with monitoring OFF, no metric is emitted and
//    the factory still returns the correct kernel.
// §2 Enabled gate: with monitoring ON and a capturing sink, the
//    backend_selected metric arrives with the expected shape.
// §3 Arch tag: the arch tag in the emitted metric matches the
//    compile-time constant PortableKernel.currentArchTag.
// §4 Conformance: the factory's return value is byte-identical to
//    the scalar reference (kernel math is unaffected by telemetry).

import Foundation
import Testing
@testable import SubstrateKernel
import SubstrateTypes
import IntellectusLib

// MARK: - Helper: capturing sink

/// A sink that records every received StatSample. Thread-safe.
private final class CapturingSink: StatsSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _samples: [StatSample] = []

    func receive(_ sample: StatSample) {
        lock.lock()
        _samples.append(sample)
        lock.unlock()
    }

    var samples: [StatSample] {
        lock.lock(); defer { lock.unlock() }
        return _samples
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _samples.count
    }
}

private enum IntellectusTestIsolation {
    private static let lock = NSLock()

    static func run(_ body: () throws -> Void) rethrows {
        lock.lock()
        defer {
            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
            lock.unlock()
        }
        try body()
    }
}

// MARK: - §1 Disabled gate

@Suite("§1 KernelTelemetry — disabled gate")
struct KernelTelemetryDisabledTests {

    /// When monitoring is OFF, kernelForCurrentPlatform() must not
    /// emit a sample. This is the default state — most callers never
    /// install a monitoring sink.
    @Test("no metric emitted when monitoring is disabled")
    func noMetricEmittedWhenDisabled() {
        IntellectusTestIsolation.run {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            // Explicitly disabled — the default state.
            Intellectus.setEnabled(false)

            _ = PortableKernel.kernelForCurrentPlatform()

            #expect(sink.count == 0,
                "kernelForCurrentPlatform() must not emit when monitoring is disabled")
        }
    }

    @Test("factory still returns the correct kernel when disabled")
    func factoryReturnsCorrectKernelWhenDisabled() {
        IntellectusTestIsolation.run {
            Intellectus.setEnabled(false)
            let kernel = PortableKernel.kernelForCurrentPlatform()

            #if arch(arm64)
            // On arm64 the SIMD kernel is selected regardless of monitoring state.
            #expect(kernel.kind == .simd,
                "arm64 must select the SIMD kernel even when monitoring is disabled")
            #else
            #expect(kernel.kind == .scalar,
                "non-arm64 must select the scalar kernel even when monitoring is disabled")
            #endif
        }
    }
}

// MARK: - §2 Enabled gate

@Suite("§2 KernelTelemetry — enabled gate")
struct KernelTelemetryEnabledTests {

    /// When monitoring is ON, exactly one `substrate.kernel.backend_selected`
    /// metric must be received by the sink per factory call.
    @Test("backend_selected metric is emitted when monitoring is enabled")
    func backendSelectedMetricEmittedWhenEnabled() {
        IntellectusTestIsolation.run {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)

            _ = PortableKernel.kernelForCurrentPlatform()

            #expect(sink.count == 1,
                "exactly one metric must be emitted per kernelForCurrentPlatform() call")

            if case let .metric(name, value, tags, _) = sink.samples.first {
                #expect(name == "substrate.kernel.backend_selected")
                #expect(value == 1.0)
                #expect(tags["backend"] != nil, "metric must carry a 'backend' tag")
                #expect(tags["arch"] != nil, "metric must carry an 'arch' tag")
            } else {
                Issue.record("expected a .metric sample; got \(String(describing: sink.samples.first))")
            }
        }
    }

    /// The `backend` tag must match the kind the factory actually
    /// returns. Verified against the KernelKind.rawValue contract.
    @Test("backend tag matches the selected kernel kind")
    func backendTagMatchesSelectedKernelKind() {
        IntellectusTestIsolation.run {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)

            let kernel = PortableKernel.kernelForCurrentPlatform()

            guard let sample = sink.samples.first,
                  case let .metric(_, _, tags, _) = sample else {
                Issue.record("no metric emitted")
                return
            }

            #expect(tags["backend"] == kernel.kind.rawValue,
                "backend tag '\(tags["backend"] ?? "nil")' must equal kernel kind rawValue '\(kernel.kind.rawValue)'")
        }
    }

    /// Multiple factory calls each emit one metric.
    @Test("each factory call emits exactly one metric")
    func eachFactoryCallEmitsOneMetric() {
        IntellectusTestIsolation.run {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)

            _ = PortableKernel.kernelForCurrentPlatform()
            _ = PortableKernel.kernelForCurrentPlatform()
            _ = PortableKernel.kernelForCurrentPlatform()

            #expect(sink.count == 3,
                "3 factory calls must produce 3 metrics; got \(sink.count)")
        }
    }
}

// MARK: - §3 Arch tag

@Suite("§3 KernelTelemetry — arch tag")
struct KernelTelemetryArchTagTests {

    /// The `arch` tag in the emitted metric must equal
    /// PortableKernel.currentArchTag.
    @Test("arch tag matches PortableKernel.currentArchTag")
    func archTagMatchesCurrentArchTag() {
        IntellectusTestIsolation.run {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)

            _ = PortableKernel.kernelForCurrentPlatform()

            guard let sample = sink.samples.first,
                  case let .metric(_, _, tags, _) = sample else {
                Issue.record("no metric emitted")
                return
            }

            #expect(tags["arch"] == PortableKernel.currentArchTag,
                "arch tag must match PortableKernel.currentArchTag")
        }
    }

    /// currentArchTag must be one of the known values — never empty.
    @Test("currentArchTag is a non-empty string")
    func currentArchTagIsNonEmpty() {
        #expect(!PortableKernel.currentArchTag.isEmpty)
    }

    /// Validate the compile-time mapping: on arm64 the tag is "arm64";
    /// on x86_64 the tag is "x86_64". Other arches get "other".
    @Test("currentArchTag compile-time value is correct for this build host")
    func currentArchTagMatchesBuildHost() {
        #if arch(arm64)
        #expect(PortableKernel.currentArchTag == "arm64")
        #elseif arch(x86_64)
        #expect(PortableKernel.currentArchTag == "x86_64")
        #else
        #expect(PortableKernel.currentArchTag == "other")
        #endif
    }
}

// MARK: - §4 Conformance gate

@Suite("§4 KernelTelemetry — conformance (math unaffected by telemetry)")
struct KernelTelemetryConformanceTests {

    /// The factory's return value produces output bit-identical to the
    /// scalar reference — proof that adding telemetry does not affect
    /// the kernel's mathematical behavior.
    @Test("factory kernel produces scalar-identical Hamming distance")
    func factoryKernelHammingDistanceMatchesScalar() {
        IntellectusTestIsolation.run {
            // Monitoring off — no side effects, no clock read.
            Intellectus.setEnabled(false)

            let factory = PortableKernel.kernelForCurrentPlatform()
            let scalar = ScalarKernel()

            let a = Fingerprint256(block0: 0xCAFE_BABE, block1: 0xDEAD_BEEF,
                                   block2: 0x0123_4567_89AB_CDEF, block3: 0xFEDC_BA98_7654_3210)
            let b = Fingerprint256(block0: 0x1234_5678, block1: 0x9ABC_DEF0,
                                   block2: 0x0F0F_0F0F_0F0F_0F0F, block3: 0xF0F0_F0F0_F0F0_F0F0)

            #expect(factory.hammingDistance256(a, b) == scalar.hammingDistance256(a, b),
                "factory kernel must produce scalar-identical Hamming distance")
        }
    }

    /// OR-reduce conformance with telemetry disabled.
    @Test("factory kernel produces scalar-identical OR-reduce")
    func factoryKernelOrReduceMatchesScalar() {
        IntellectusTestIsolation.run {
            Intellectus.setEnabled(false)

            let factory = PortableKernel.kernelForCurrentPlatform()
            let scalar = ScalarKernel()

            let fps: [Fingerprint256] = (0..<32).map { n in
                let i = UInt64(n)
                return Fingerprint256(block0: i,
                                      block1: i &* 0x9E3779B97F4A7C15,
                                      block2: i &* 0xBF58476D1CE4E5B9,
                                      block3: i &* 0x94D049BB133111EB)
            }

            #expect(factory.orReduce256(fps) == scalar.orReduce256(fps),
                "factory kernel must produce scalar-identical OR-reduce")
        }
    }

    /// Telemetry enabled, then conformance check. Proves that even
    /// with monitoring on the math output is unaffected.
    @Test("conformance holds when monitoring is enabled")
    func conformanceHoldsWhenMonitoringEnabled() {
        IntellectusTestIsolation.run {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)

            let factory = PortableKernel.kernelForCurrentPlatform()
            let scalar = ScalarKernel()

            let a = Fingerprint256(block0: 0xDEAD, block1: 0xBEEF, block2: 0xCAFE, block3: 0xBABE)
            let b = Fingerprint256(block0: 0xFACE, block1: 0xFEED, block2: 0xC0DE, block3: 0xD00D)

            // Math output must be identical to scalar.
            #expect(factory.hammingDistance256(a, b) == scalar.hammingDistance256(a, b),
                "math must be unaffected by telemetry being enabled")

            // One metric was emitted (proves the monitoring path ran).
            #expect(sink.count == 1, "telemetry must still emit when enabled during conformance test")
        }
    }
}
