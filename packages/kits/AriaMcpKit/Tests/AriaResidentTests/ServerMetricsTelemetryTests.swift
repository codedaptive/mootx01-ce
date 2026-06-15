import Testing
import Foundation
import IntellectusLib
import Synchronization
@testable import AriaMCP
@testable import AriaResident

/// Tests for server-metrics telemetry wiring introduced in TELEMETRY-SM.
///
/// `reportServerMetrics` coverage: the off-path gate suppresses all emission
/// when monitoring is off; when on, emits server.rss_mb > 0 on macOS and all
/// named server/substrate metrics at the expected values — including the new
/// hardening counters (connections HWM, 4xx/5xx/shed, latency buckets).
///
/// `globalRPCCounter` coverage: the counter is an Atomic<Int> and increments
/// correctly (the HTTP serve path drives the same increment path).
@Suite("ServerMetricsTelemetry", .serialized)
struct ServerMetricsTelemetryTests {

    // MARK: - Helpers

    /// A spy StatsSink that captures metric names → values from the most recent
    /// reportServerMetrics call. Not thread-safe — only used inside the
    /// .serialized suite.
    private final class CaptureSink: StatsSink {
        // nonisolated(unsafe): accessed only from the .serialized suite's
        // single test at a time; the send path is synchronous through Intellectus.
        nonisolated(unsafe) var metrics: [String: Double] = [:]
        func receive(_ sample: StatSample) {
            if case .metric(let name, let value, _, _) = sample {
                metrics[name] = value
            }
        }
    }

    /// Helper that calls `reportServerMetrics` with all counters defaulted to
    /// zero. Individual tests override only the parameters they care about.
    private func callReport(
        rpcCount: Int = 0,
        activeConnections: Int = 0,
        connectionsHWM: Int = 0,
        count4xx: Int = 0,
        count5xx: Int = 0,
        shedCount: Int = 0,
        latencyNsTotal: Int = 0,
        latencyFast: Int = 0,
        latencyMid: Int = 0,
        latencySlow: Int = 0,
        protoVersion: String = "2025-11-25",
        kernelKind: String = "simd",
        now: Double = 1_000_000.0
    ) {
        reportServerMetrics(
            rpcCount: rpcCount,
            activeConnections: activeConnections,
            connectionsHWM: connectionsHWM,
            count4xx: count4xx,
            count5xx: count5xx,
            shedCount: shedCount,
            latencyNsTotal: latencyNsTotal,
            latencyFast: latencyFast,
            latencyMid: latencyMid,
            latencySlow: latencySlow,
            protoVersion: protoVersion,
            kernelKind: kernelKind,
            now: now
        )
    }

    // MARK: - Off-path gate

    @Test("reportServerMetrics: gate suppresses all emission when monitoring is off")
    func reportServerMetricsGateSuppressesWhenDisabled() async throws {
        try await intellectusGlobalGate.withLock {
            let spy = CaptureSink()
            Intellectus.install(sink: spy)
            Intellectus.setEnabled(false)
            defer { Intellectus.setEnabled(false) }

            callReport(rpcCount: 5, activeConnections: 3)
            #expect(spy.metrics.isEmpty, "gate must suppress all emission when Intellectus.isEnabled is false")
        }
    }

    // MARK: - Metric emission

    @Test("reportServerMetrics: emits expected metrics when monitoring is on")
    func reportServerMetricsEmitsWhenEnabled() async throws {
        try await intellectusGlobalGate.withLock {
            let spy = CaptureSink()
            Intellectus.install(sink: spy)
            Intellectus.setEnabled(true)
            defer { Intellectus.setEnabled(false) }

            callReport(
                rpcCount: 42,
                activeConnections: 7,
                connectionsHWM: 15,
                count4xx: 3,
                count5xx: 1,
                shedCount: 2,
                latencyNsTotal: 10_000_000,
                latencyFast: 30,
                latencyMid: 10,
                latencySlow: 2,
                now: 2_000_000.0
            )

            // rss_mb must be positive on macOS — the process occupies real memory.
            #if os(macOS) || os(iOS)
            let rss = try #require(spy.metrics["server.rss_mb"])
            #expect(rss > 0.0, "resident set size must be positive")
            #endif

            let rpcVal = try #require(spy.metrics["server.rpc_count"])
            #expect(rpcVal == 42.0)

            let connVal = try #require(spy.metrics["server.connections"])
            #expect(connVal == 7.0)

            let hwmVal = try #require(spy.metrics["server.connections_hwm"])
            #expect(hwmVal == 15.0)

            let c4xx = try #require(spy.metrics["server.4xx_count"])
            #expect(c4xx == 3.0)

            let c5xx = try #require(spy.metrics["server.5xx_count"])
            #expect(c5xx == 1.0)

            let shed = try #require(spy.metrics["server.shed_count"])
            #expect(shed == 2.0)

            let latTotal = try #require(spy.metrics["server.latency_ns_total"])
            #expect(latTotal == 10_000_000.0)

            let latFast = try #require(spy.metrics["server.latency_fast_count"])
            #expect(latFast == 30.0)

            let latMid = try #require(spy.metrics["server.latency_mid_count"])
            #expect(latMid == 10.0)

            let latSlow = try #require(spy.metrics["server.latency_slow_count"])
            #expect(latSlow == 2.0)

            // Protocol version emitted as 1.0 presence metric.
            let protoVal = try #require(spy.metrics["server.proto_version"])
            #expect(protoVal == 1.0)

            // Kernel backend emitted as 1.0 presence metric.
            let kernelVal = try #require(spy.metrics["substrate.kernel.backend_selected"])
            #expect(kernelVal == 1.0)
        }
    }

    // MARK: - globalRPCCounter

    @Test("globalRPCCounter: add increments the counter atomically")
    func globalRPCCounterIncrements() {
        // Snapshot before so the test is insensitive to the process-global counter
        // state from prior test runs or real HTTP activity.
        let before = globalRPCCounter.load(ordering: .relaxed)
        globalRPCCounter.add(1, ordering: .relaxed)
        globalRPCCounter.add(1, ordering: .relaxed)
        let after = globalRPCCounter.load(ordering: .relaxed)
        #expect(after == before + 2)
    }
}
