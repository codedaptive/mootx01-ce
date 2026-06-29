// NeuronKitTelemetryTests.swift
//
// Tests for NeuronKit self-report telemetry added in NEURONKIT_REPORT_001.
// Mirrors the Rust test module in rust/tests/neuronkit_telemetry_tests.rs.
//
// §1 Disabled gate: with monitoring OFF, no metric is emitted and
//    algorithm results are unchanged.
// §2 hybridRecall emissions: rerank math is unaffected by monitoring state.
// §3 DreamingDaemon emissions: cycle-start and cycle-complete pair
//    per runCycle invocation, drawers_touched and proposals tags correct.
// §4 bradleyTerry emissions: bt_update + competitor_count per call,
//    competitor_count value and tag match actual count.
// §5 Conformance: math output is identical with monitoring ON and OFF.
//
// ISOLATION STRATEGY
// These tests install a capturing sink and flip the global Intellectus
// singleton. Swift Testing runs test functions concurrently by default;
// concurrent tests that manipulate the same global enabled/sink state
// produce phantom extra metric counts in each other's sinks.
//
// Two-layer solution:
//
// Layer 1 — intra-file: The outer NeuronKitTelemetrySuite carries
// `.serialized`, so no two tests in this file run at the same time.
//
// Layer 2 — cross-file: EVERY test function in this suite acquires the
// process-wide intellectusTestMutex (actor-based cooperative mutex defined
// in IntellectusTestLock.swift) for its full duration. Tests in other suites
// (BradleyTerryTests, DreamingDaemonTests, HybridRecallTests, etc.) that
// call telemetry-emitting functions also acquire the same mutex, so they
// cannot run while a telemetry test holds the singleton in a non-default
// state. This directly mirrors the Rust solution: a `Mutex<()>` acquired
// at the top of every test that touches the singleton or calls an
// emitting function, including disabled-path tests (a lock-free disabled
// test can interleave with a lock-held enabled test and corrupt it).
//
// All test functions are declared `async` to use withIntellectusLock
// uniformly. The mutex uses cooperative async suspension (CheckedContinuation
// actor queue) — no thread is blocked, so this is safe under Swift 6
// strict concurrency and the cooperative thread pool.

import Foundation
import Testing
import IntellectusLib
import GeniusLocusKit
@testable import NeuronKit

// MARK: - Capturing sink

/// Records every received StatSample. Thread-safe via NSLock.
private final class CapturingSink: StatsSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _samples: [StatSample] = []

    func receive(_ sample: StatSample) {
        lock.lock(); defer { lock.unlock() }
        _samples.append(sample)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _samples.count
    }

    /// All metric samples with the given name.
    func metrics(named name: String) -> [StatSample] {
        lock.lock(); defer { lock.unlock() }
        return _samples.filter {
            if case let .metric(n, _, _, _) = $0 { return n == name }
            return false
        }
    }
}

// MARK: - Shared cleanup helper

/// Restore global Intellectus state to (disabled, NoOpSink).
/// Called from every test via defer so a throwing test still cleans up.
private func resetIntellectus() {
    Intellectus.setEnabled(false)
    Intellectus.install(sink: NoOpSink.shared)
}

// MARK: - Fake dreaming infrastructure

/// Drain-queue fake for telemetry tests. The `windows` parameter seeds the
/// first (and only) call to drainDreamingWindow(); subsequent calls return
/// [] (drain-once semantics). The convenience init that maps pair count to
/// windows is provided to keep the call sites readable.
private actor FakeDreamingReader: DreamingSubstrateReader {
    /// Window batches to drain. Each element is one call's return value.
    private var batches: [[[String]]]

    /// Seed with explicit window batches (each inner array is one drain event).
    init(batches: [[[String]]] = []) {
        self.batches = batches
    }

    /// Convenience: seed N distinct pairs as N single-window batches so
    /// `candidatesConsidered` equals `pairCount` after one drain call.
    /// Pair IDs are "ep-\(i)-a" / "ep-\(i)-b" for i in 0 ..< pairCount.
    init(pairCount: Int) {
        self.batches = (0 ..< pairCount).map { i in [["ep-\(i)-a", "ep-\(i)-b"]] }
    }

    func recentRecallTraces(since: Date, now: Date) async throws -> [RecallTraceItem] { [] }

    func drainDreamingWindow() async throws -> [[String]] {
        // Flatten all batches into a single return (one call returns everything).
        let all = batches.flatMap { $0 }
        batches = []
        return all
    }

    func existingTunnels() async throws -> [Tunnel] { [] }
}

private actor FakeDreamingSink: DreamingProposalSink {
    func propose(_ frame: ProposeFrame) async throws {}
    func recordCycleDiary(_ entry: DiaryEntry) async throws {}
    func pruneRecallTraces(olderThan cutoff: Date) async throws -> Int { 0 }
}

private actor FakeDreamingPolicyStore: DreamingPolicyStore {
    func loadPolicy() async throws -> DreamingPolicy? { nil }
    func savePolicy(_ policy: DreamingPolicy) async throws {}
}

// MARK: - Top-level serialised suite

// `.serialized` enforces sequential execution across all child tests and
// nested suites. No test in this file runs concurrently with any other
// WITHIN this suite.
//
// Additionally, every test function acquires the process-wide
// intellectusTestMutex (defined in IntellectusTestLock.swift). This
// prevents races with tests in OTHER suites (BradleyTerryTests,
// DreamingDaemonTests, HybridRecallTests, etc.) that call emitting
// functions and run concurrently in the default parallel runner.
// `.serialized` alone is not sufficient across suite boundaries.
@Suite("NeuronKit Telemetry (NEURONKIT_REPORT_001)", .serialized)
struct NeuronKitTelemetrySuite {

    // MARK: - §1 Disabled gate

    @Suite("§1 NeuronKitTelemetry — disabled gate")
    struct DisabledGateTests {

        /// When monitoring is OFF, bradleyTerry() emits nothing.
        @Test("bradleyTerry emits no metrics when monitoring is disabled")
        func bradleyTerryEmitsNothingWhenDisabled() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(false)
                defer { resetIntellectus() }

                // Strongly connected circular graph so the MLE is finite.
                let outcomes = [
                    PairwiseOutcome(winner: "A", loser: "B", count: 3),
                    PairwiseOutcome(winner: "B", loser: "C", count: 2),
                    PairwiseOutcome(winner: "C", loser: "A", count: 1),
                ]
                _ = try bradleyTerry(outcomes: outcomes)

                #expect(sink.count == 0,
                    "bradleyTerry() must not emit when monitoring is disabled")
            }
        }

        /// Results are correct when monitoring is disabled.
        @Test("bradleyTerry result is correct when monitoring is disabled")
        func bradleyTerryResultCorrectWhenDisabled() async throws {
            try await withIntellectusLock {
                Intellectus.setEnabled(false)
                defer { resetIntellectus() }

                // Circular graph so MLE is finite; A wins most.
                let outcomes = [
                    PairwiseOutcome(winner: "A", loser: "B", count: 5),
                    PairwiseOutcome(winner: "B", loser: "C", count: 3),
                    PairwiseOutcome(winner: "C", loser: "A", count: 1),
                ]
                let scores = try bradleyTerry(outcomes: outcomes)

                #expect(scores.count == 3)
                #expect(scores[0].competitorID == "A",
                    "A wins most; expected A first; got \(scores.map(\.competitorID))")
            }
        }
    }

    // MARK: - §2 hybridRecall emissions (rerank engine math)

    @Suite("§2 NeuronKitTelemetry — hybridRecall rerank math")
    struct HybridRecallMathTests {

        /// HybridRecallEngine.rerank math is identical regardless of monitoring.
        @Test("rerank math is identical regardless of monitoring state")
        func rerankMathIdenticalRegardlessOfMonitoring() async throws {
            try await withIntellectusLock {
                let drawers = (0..<5).map { i in
                    Drawer.makeForTest(content: "content item \(i)")
                }
                let tuning = RecallFrameTuning.default
                defer { resetIntellectus() }

                Intellectus.setEnabled(false)
                let resultOff = HybridRecallEngine.rerank(drawers: drawers, tuning: tuning)

                Intellectus.setEnabled(true)
                let resultOn = HybridRecallEngine.rerank(drawers: drawers, tuning: tuning)

                #expect(resultOff.map(\.id) == resultOn.map(\.id),
                    "rerank output must be identical regardless of monitoring state")
            }
        }
    }

    // MARK: - §3 DreamingDaemon emissions

    @Suite("§3 NeuronKitTelemetry — DreamingDaemon cycle emissions")
    struct DreamingTests {

        /// One triggerDreamingCycle call emits exactly two neuronkit.dream.cycle
        /// metrics: one with status "start" and one with status "complete".
        @Test("triggerDreamingCycle emits start and complete when monitoring is enabled")
        func triggerCycleEmitsStartAndComplete() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                let daemon = DreamingDaemon(
                    reader: FakeDreamingReader(),
                    sink: FakeDreamingSink(),
                    policyStore: FakeDreamingPolicyStore()
                )
                let now = Date(timeIntervalSince1970: 1_000_000)
                _ = try await daemon.triggerDreamingCycle(now: now)

                let cycleMetrics = sink.metrics(named: "neuronkit.dream.cycle")
                #expect(cycleMetrics.count == 2,
                    "triggerDreamingCycle must emit exactly 2 neuronkit.dream.cycle metrics; got \(cycleMetrics.count)")

                var startTags: [String: String]? = nil
                var completeTags: [String: String]? = nil
                for sample in cycleMetrics {
                    if case let .metric(_, _, tags, _) = sample {
                        if tags["status"] == "start" { startTags = tags }
                        if tags["status"] == "complete" { completeTags = tags }
                    }
                }
                #expect(startTags != nil, "must have a 'start' metric")
                #expect(completeTags != nil, "must have a 'complete' metric")
                #expect(completeTags?["drawers_touched"] == "0",
                    "with no observations, drawers_touched must be '0'")
                #expect(completeTags?["proposals"] == "0",
                    "with no observations, proposals must be '0'")
            }
        }

        /// Two cycle calls emit exactly four neuronkit.dream.cycle metrics total.
        @Test("two cycle calls emit four neuronkit.dream.cycle metrics")
        func twoCycleCallsEmitFourMetrics() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                let daemon = DreamingDaemon(
                    reader: FakeDreamingReader(),
                    sink: FakeDreamingSink(),
                    policyStore: FakeDreamingPolicyStore()
                )
                let now1 = Date(timeIntervalSince1970: 1_000_000)
                let now2 = Date(timeIntervalSince1970: 1_000_100)
                _ = try await daemon.triggerDreamingCycle(now: now1)
                _ = try await daemon.triggerDreamingCycle(now: now2)

                let cycleMetrics = sink.metrics(named: "neuronkit.dream.cycle")
                #expect(cycleMetrics.count == 4,
                    "two cycle calls must emit 4 neuronkit.dream.cycle metrics; got \(cycleMetrics.count)")
            }
        }

        /// When monitoring is disabled, no dreaming metrics are emitted but
        /// the cycle completes normally (conformance preserved).
        @Test("cycle emits nothing when monitoring is disabled")
        func cycleEmitsNothingWhenDisabled() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(false)
                defer { resetIntellectus() }

                let daemon = DreamingDaemon(
                    reader: FakeDreamingReader(),
                    sink: FakeDreamingSink(),
                    policyStore: FakeDreamingPolicyStore()
                )
                let now = Date(timeIntervalSince1970: 1_000_000)
                let report = try await daemon.triggerDreamingCycle(now: now)

                #expect(sink.count == 0,
                    "dreaming cycle must not emit when monitoring is disabled")
                // The cycle report is still complete — telemetry is additive.
                #expect(report.tickedAt == now)
                #expect(report.candidatesConsidered == 0)
            }
        }

        /// Distinct pair count from the drain is reflected in the drawers_touched tag.
        /// Two distinct drain windows — one for pair (a,b) and one for (c,d) — yield
        /// candidatesConsidered == 2, which maps to drawers_touched == "2".
        @Test("drawers_touched tag matches drained pair count")
        func drawersTouchedTagMatchesObservationCount() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                // Two distinct pairs from one drain call → candidatesConsidered = 2.
                let daemon = DreamingDaemon(
                    reader: FakeDreamingReader(batches: [[["a", "b"], ["c", "d"]]]),
                    sink: FakeDreamingSink(),
                    policyStore: FakeDreamingPolicyStore()
                )
                _ = try await daemon.triggerDreamingCycle(now: Date(timeIntervalSince1970: 1_000_000))

                let complete = sink.metrics(named: "neuronkit.dream.cycle").first {
                    if case let .metric(_, _, tags, _) = $0 { return tags["status"] == "complete" }
                    return false
                }
                guard let complete else {
                    Issue.record("no complete metric emitted"); return
                }
                if case let .metric(_, _, tags, _) = complete {
                    #expect(tags["drawers_touched"] == "2",
                        "drawers_touched must equal distinct pair count; got \(tags["drawers_touched"] ?? "nil")")
                }
            }
        }
    }

    // MARK: - §4 bradleyTerry emissions

    @Suite("§4 NeuronKitTelemetry — bradleyTerry emissions")
    struct BradleyTerryTests {

        // Strongly connected 3-competitor cycle: every vertex reachable from
        // every other. Required for a finite MLE (disconnected graph throws).
        private static let circularOutcomes = [
            PairwiseOutcome(winner: "A", loser: "B", count: 3),
            PairwiseOutcome(winner: "B", loser: "C", count: 2),
            PairwiseOutcome(winner: "C", loser: "A", count: 1),
        ]

        /// bradleyTerry emits bt_update + competitor_count when monitoring is on.
        @Test("bradleyTerry emits bt_update and competitor_count when monitoring is enabled")
        func bradleyTerryEmitsBothMetrics() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                _ = try bradleyTerry(outcomes: Self.circularOutcomes)

                #expect(sink.metrics(named: "neuronkit.tournament.bt_update").count == 1,
                    "bradleyTerry must emit exactly 1 bt_update metric; got \(sink.metrics(named: "neuronkit.tournament.bt_update").count)")
                #expect(sink.metrics(named: "neuronkit.tournament.competitor_count").count == 1,
                    "bradleyTerry must emit exactly 1 competitor_count metric; got \(sink.metrics(named: "neuronkit.tournament.competitor_count").count)")
            }
        }

        /// The competitor_count metric value matches the actual competitor count.
        @Test("competitor_count metric value equals number of competitors")
        func competitorCountMetricMatchesActual() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                let scores = try bradleyTerry(outcomes: Self.circularOutcomes)

                guard let sample = sink.metrics(named: "neuronkit.tournament.competitor_count").first,
                      case let .metric(_, value, _, _) = sample else {
                    Issue.record("no competitor_count metric emitted")
                    return
                }
                #expect(value == Double(scores.count),
                    "competitor_count metric value must equal actual score count; got \(value)")
            }
        }

        /// The bt_update tag carries the competitor count string.
        @Test("bt_update tag carries competitor_count string")
        func btUpdateTagCarriesCompetitorCount() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                // Different circular 3-competitor set.
                let outcomes = [
                    PairwiseOutcome(winner: "X", loser: "Y", count: 2),
                    PairwiseOutcome(winner: "Y", loser: "Z", count: 2),
                    PairwiseOutcome(winner: "Z", loser: "X", count: 1),
                ]
                _ = try bradleyTerry(outcomes: outcomes)

                guard let sample = sink.metrics(named: "neuronkit.tournament.bt_update").first,
                      case let .metric(_, _, tags, _) = sample else {
                    Issue.record("no bt_update metric emitted")
                    return
                }
                #expect(tags["competitor_count"] == "3",
                    "bt_update must tag competitor_count '3'; got \(tags["competitor_count"] ?? "nil")")
            }
        }

        /// Two bradleyTerry calls each emit their own pair of metrics.
        @Test("each bradleyTerry call emits its own pair of metrics")
        func eachCallEmitsOwnPair() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                defer { resetIntellectus() }

                _ = try bradleyTerry(outcomes: Self.circularOutcomes)
                _ = try bradleyTerry(outcomes: Self.circularOutcomes)

                #expect(sink.metrics(named: "neuronkit.tournament.bt_update").count == 2,
                    "two calls must produce 2 bt_update metrics; got \(sink.metrics(named: "neuronkit.tournament.bt_update").count)")
                #expect(sink.metrics(named: "neuronkit.tournament.competitor_count").count == 2,
                    "two calls must produce 2 competitor_count metrics")
            }
        }

        /// When monitoring is disabled, bradleyTerry emits nothing.
        @Test("bradleyTerry emits no metrics when monitoring is disabled")
        func bradleyTerryEmitsNothingWhenDisabled() async throws {
            try await withIntellectusLock {
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(false)
                defer { resetIntellectus() }

                _ = try bradleyTerry(outcomes: Self.circularOutcomes)

                #expect(sink.count == 0,
                    "bradleyTerry() must not emit when monitoring is disabled")
            }
        }
    }

    // MARK: - §5 Conformance gate

    @Suite("§5 NeuronKitTelemetry — conformance (math unaffected by telemetry)")
    struct ConformanceTests {

        // Strongly connected 4-competitor mixed graph.
        private static let richOutcomes = [
            PairwiseOutcome(winner: "A", loser: "B", count: 5),
            PairwiseOutcome(winner: "B", loser: "C", count: 3),
            PairwiseOutcome(winner: "C", loser: "D", count: 2),
            PairwiseOutcome(winner: "D", loser: "A", count: 1),
            PairwiseOutcome(winner: "A", loser: "C", count: 4),
            PairwiseOutcome(winner: "B", loser: "D", count: 1),
        ]

        /// bradleyTerry result is identical whether monitoring is on or off.
        @Test("bradleyTerry result identical with monitoring on vs off")
        func bradleyTerryResultIdenticalWithAndWithoutTelemetry() async throws {
            try await withIntellectusLock {
                // OFF path.
                Intellectus.setEnabled(false)
                let offResult = try bradleyTerry(outcomes: Self.richOutcomes)

                // ON path.
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                let onResult = try bradleyTerry(outcomes: Self.richOutcomes)
                defer { resetIntellectus() }

                // IDs and strengths must be bit-identical.
                #expect(offResult.map(\.competitorID) == onResult.map(\.competitorID),
                    "rank order must be identical regardless of monitoring state")
                for (off, on) in zip(offResult, onResult) {
                    #expect(off.strength == on.strength,
                        "strength for \(off.competitorID) must be identical regardless of monitoring state")
                }
                // ON path emitted metrics (proves the on-path was active).
                #expect(sink.count > 0, "monitoring-on path must emit at least one metric")
            }
        }

        /// DreamingDaemon cycle report is identical regardless of monitoring.
        @Test("dreaming cycle report identical with monitoring on vs off")
        func dreamingCycleReportIdentical() async throws {
            try await withIntellectusLock {
                // One pair (ep-a, ep-b) drained from one window.
                // Each daemon gets its own reader so the drain queue is
                // independent — the actor's queue is consumed per drain call.
                let now = Date(timeIntervalSince1970: 1_000_000)

                // OFF path.
                Intellectus.setEnabled(false)
                let daemonOff = DreamingDaemon(
                    reader: FakeDreamingReader(batches: [[["ep-a", "ep-b"]]]),
                    sink: FakeDreamingSink(),
                    policyStore: FakeDreamingPolicyStore()
                )
                let reportOff = try await daemonOff.triggerDreamingCycle(now: now)

                // ON path.
                let sink = CapturingSink()
                Intellectus.install(sink: sink)
                Intellectus.setEnabled(true)
                let daemonOn = DreamingDaemon(
                    reader: FakeDreamingReader(batches: [[["ep-a", "ep-b"]]]),
                    sink: FakeDreamingSink(),
                    policyStore: FakeDreamingPolicyStore()
                )
                let reportOn = try await daemonOn.triggerDreamingCycle(now: now)
                defer { resetIntellectus() }

                // Cycle outcomes must be identical.
                #expect(reportOff.tickedAt == reportOn.tickedAt)
                #expect(reportOff.candidatesConsidered == reportOn.candidatesConsidered)
                #expect(reportOff.proposalsEmitted.count == reportOn.proposalsEmitted.count)
                #expect(reportOff.suppressedDuplicates == reportOn.suppressedDuplicates)
                #expect(reportOff.belowThreshold == reportOn.belowThreshold)
                // ON path emitted metrics.
                #expect(sink.count > 0, "telemetry must emit when enabled during conformance test")
            }
        }
    }
}

// MARK: - Test helper — Drawer.makeForTest

private extension Drawer {
    /// Minimal Drawer for test-only rerank-math validation.
    /// Uses the same init parameters as HybridRecallTests.makeDrawer.
    static func makeForTest(content: String) -> Drawer {
        Drawer(
            id: "test-\(abs(content.hashValue))",
            content: content,
            parentNodeId: "test-room-node",
            addedBy: "test",
            filedAt: Date(timeIntervalSince1970: 0),
            embeddingModelID: "test-embed-v1",
            provenance: 0,
            adjectiveBitmap: 0,
            operationalBitmap: 0
        )
    }
}
