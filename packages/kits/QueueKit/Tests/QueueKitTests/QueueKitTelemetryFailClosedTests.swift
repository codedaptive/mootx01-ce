// QueueKitTelemetryFailClosedTests.swift
//
// P0-5 site 7 (QueueKitTelemetry.reportQueueStats): a pendingCount read
// FAILURE must NOT be reported as `queue.depth = 0`. A fabricated zero is
// indistinguishable from a genuinely empty queue and would tell the observer
// "all drained" when the truth is "could not read the depth".
//
// FORCE-TEST: drive reportQueueStats with a QueueBackend whose pendingCount
// throws, capture the emitted StatSamples via RecentWindowSink, and assert:
//   - NO `queue.depth` metric is emitted (no fabricated floor).
//   - a `queue.depth_unavailable` metric sentinel IS emitted.
//   - the depth-derived `queue.idle_nonempty` metric is suppressed.
// Control: a backend whose pendingCount succeeds emits `queue.depth` and no
// `queue.depth_unavailable`.

import Testing
import Foundation
import SubstrateTypes
import IntellectusLib
@testable import QueueKit

/// A QueueBackend stub whose `pendingCount()` either returns a fixed value or
/// throws `QueueError.backendUnavailable`, depending on `failPending`. All
/// other methods are inert — reportQueueStats only reads `pendingCount`.
private struct PendingFaultBackend: QueueBackend {
    let failPending: Bool
    let pending: Int

    func write(_ job: Job) async throws {}

    func drainAvailable() async throws -> [(job: Job, sessionID: SessionID)] { [] }

    func pendingCount() async throws -> Int {
        if failPending {
            throw QueueError.backendUnavailable(detail: "forced pendingCount fault")
        }
        return pending
    }

    func watch(handler: @escaping @Sendable (Job, SessionID) async throws -> Void) async throws {}

    func complete(_ jobID: JobID, status: ObservationStatus, artifacts: [ArtifactRef]) async throws {}

    func inFlight() async throws -> [Job] { [] }

    func completed(streamID: StreamID?) async throws -> [Job] { [] }
}

@Suite("QueueKitTelemetry fail-closed depth (P0-5 site 7)")
struct QueueKitTelemetryFailClosedTests {

    /// Install a capturing sink, run reportQueueStats, return the emitted
    /// metric names. Restores the no-op sink + disabled gate afterward.
    private func capturedMetricNames(failPending: Bool) async -> [String] {
        let sink = RecentWindowSink(capacity: 64)
        Intellectus.install(sink: sink)
        Intellectus.setEnabled(true)
        defer {
            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
        }

        var window = QueueLatencyWindow(capacity: 16)
        let backend = PendingFaultBackend(failPending: failPending, pending: 3)
        await reportQueueStats(
            backend: backend,
            drained: [],            // nothing drained this cycle
            drainStart: 1000.0,
            now: 1000.5,
            estateTag: "test-estate",
            window: &window
        )

        return sink.snapshot().compactMap { sample in
            if case let .metric(name, _, _, _) = sample { return name }
            return nil
        }
    }

    @Test("pendingCount failure emits depth_unavailable, NOT a fabricated depth=0")
    func pendingFailureDoesNotFabricateZeroDepth() async {
        let names = await capturedMetricNames(failPending: true)
        #expect(
            !names.contains("queue.depth"),
            "a pendingCount fault must NOT emit queue.depth (a fabricated 0); got \(names)"
        )
        #expect(
            names.contains("queue.depth_unavailable"),
            "a pendingCount fault must emit queue.depth_unavailable; got \(names)"
        )
        #expect(
            !names.contains("queue.idle_nonempty"),
            "idle_nonempty cannot be computed without depth and must be suppressed; got \(names)"
        )
    }

    @Test("pendingCount success emits depth, NOT depth_unavailable (control)")
    func pendingSuccessEmitsDepth() async {
        let names = await capturedMetricNames(failPending: false)
        #expect(
            names.contains("queue.depth"),
            "a successful pendingCount must emit queue.depth; got \(names)"
        )
        #expect(
            !names.contains("queue.depth_unavailable"),
            "a successful read must NOT emit queue.depth_unavailable; got \(names)"
        )
    }
}
