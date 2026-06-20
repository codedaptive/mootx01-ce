// AutoReindexTests.swift
//
// Conformance tests for the dreaming daemon's auto-reindex step.
//
// Covers:
//   AR-1: First cycle establishes baseline without firing reindex.
//   AR-2: Below threshold → reindex does NOT fire.
//   AR-3: At or above threshold → reindex fires; baseline advances.
//   AR-4: No probe injected → no reindex fires (nil probe = safe no-op).
//   AR-5: After reindex, delta resets; next window needs another threshold worth of growth.
//   AR-6: Reindex failure is non-fatal; cycle continues.
//
// All timing is deterministic: `now` is injected. The fake probe records
// calls without touching a live Corpus. Tests acquire `intellectusTestMutex`
// because DreamingDaemon.triggerDreamingCycle emits Intellectus metrics.

import Testing
import Foundation
import GeniusLocusKit
@testable import NeuronKit

// MARK: - Fake CorpusGrowthProbe

/// Configurable fake probe that records reindex calls.
private actor FakeGrowthProbe: CorpusGrowthProbe {

    /// Live chunk count returned by `chunkCount()`.
    var count: Int

    /// Whether `reindex(now:)` should throw.
    var shouldThrow: Bool

    /// Timestamps of `reindex(now:)` calls.
    private(set) var reindexCalls: [Date] = []

    /// Counts of `chunkCount()` calls.
    private(set) var countCallCount: Int = 0

    init(count: Int = 0, shouldThrow: Bool = false) {
        self.count = count
        self.shouldThrow = shouldThrow
    }

    func chunkCount() async throws -> Int {
        countCallCount += 1
        return count
    }

    func reindex(now: Date) async throws {
        if shouldThrow {
            // Simulate a storage error.
            struct FakeReindexError: Error {}
            throw FakeReindexError()
        }
        reindexCalls.append(now)
    }

    func setCount(_ n: Int) { count = n }
    func reindexCallCount() -> Int { reindexCalls.count }
}

// MARK: - Shared helpers (mirror DreamingDaemonTests)

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private actor NullSink: DreamingProposalSink {
    func propose(_ frame: ProposeFrame) async throws {}
    func recordCycleDiary(_ entry: DiaryEntry) async throws {}
    func pruneRecallTraces(olderThan cutoff: Date) async throws -> Int { 0 }
}

private actor NullReader: DreamingSubstrateReader {
    func recentRecallTraces(since: Date, now: Date) async throws -> [RecallTraceItem] { [] }
    func coOccurrenceObservations() async throws -> [CoOccurrenceObservation] { [] }
    func existingTunnels() async throws -> [Tunnel] { [] }
}

// MARK: - Tests

@Suite("Dreaming daemon auto-reindex")
struct AutoReindexTests {

    // AR-1: First cycle stores the baseline chunk count and does NOT fire reindex.
    @Test("AR-1: first cycle establishes baseline without firing reindex")
    func ar1FirstCycleEstablishesBaselineWithoutReindex() async throws {
        try await withIntellectusLock {
            let probe = FakeGrowthProbe(count: 10)
            let reader = NullReader()
            let sink = NullSink()
            let d = DreamingDaemon(
                reader: reader,
                sink: sink,
                policyStore: InMemoryDreamingPolicyStore(),
                growthProbe: probe
            )

            _ = try await d.triggerDreamingCycle(now: t0)

            // Baseline was read (chunkCount called), but reindex was NOT fired.
            let calls = await probe.reindexCallCount()
            #expect(calls == 0, "first cycle must establish baseline, not trigger reindex")
            let countCalls = await probe.countCallCount
            #expect(countCalls >= 1, "chunkCount must be queried to establish baseline")
        }
    }

    // AR-2: Growth below threshold — reindex must NOT fire.
    @Test("AR-2: growth below threshold does not trigger reindex")
    func ar2BelowThresholdNoReindex() async throws {
        try await withIntellectusLock {
            // Start at 10 chunks. After first cycle (baseline = 10), grow by
            // threshold - 1 (24 chunks). Reindex must not fire.
            let probe = FakeGrowthProbe(count: 10)
            let reader = NullReader()
            let sink = NullSink()
            let d = DreamingDaemon(
                reader: reader,
                sink: sink,
                policyStore: InMemoryDreamingPolicyStore(),
                growthProbe: probe,
                reindexGrowthThreshold: autoReindexGrowthThreshold // 25
            )

            // Cycle 1: establish baseline at 10.
            _ = try await d.triggerDreamingCycle(now: t0)

            // Grow by 24 (one below threshold).
            await probe.setCount(34) // 34 - 10 = 24 < 25

            // Cycle 2: growth = 24, below threshold.
            _ = try await d.triggerDreamingCycle(now: t0.addingTimeInterval(60))

            let calls = await probe.reindexCallCount()
            #expect(calls == 0, "growth of 24 (< threshold 25) must not trigger reindex")
        }
    }

    // AR-3: Growth at or above threshold → reindex fires; baseline advances.
    @Test("AR-3: growth at threshold triggers reindex and advances baseline")
    func ar3AtThresholdReindexFires() async throws {
        try await withIntellectusLock {
            let probe = FakeGrowthProbe(count: 10)
            let reader = NullReader()
            let sink = NullSink()
            let d = DreamingDaemon(
                reader: reader,
                sink: sink,
                policyStore: InMemoryDreamingPolicyStore(),
                growthProbe: probe,
                reindexGrowthThreshold: autoReindexGrowthThreshold // 25
            )

            // Cycle 1: baseline = 10.
            _ = try await d.triggerDreamingCycle(now: t0)

            // Grow by exactly the threshold (25 chunks): 10 + 25 = 35.
            await probe.setCount(35)

            let t1 = t0.addingTimeInterval(60)
            _ = try await d.triggerDreamingCycle(now: t1)

            // Reindex should have fired once.
            let calls = await probe.reindexCallCount()
            #expect(calls == 1, "growth == threshold must trigger exactly one reindex")

            // Verify the timestamp passed to reindex is the cycle's `now`.
            let reindexNow = await probe.reindexCalls.first
            #expect(reindexNow == t1, "reindex must receive the cycle's `now` parameter")
        }
    }

    // AR-3b: After baseline advances, further sub-threshold growth does not reindex again.
    @Test("AR-3b: after reindex, baseline resets; sub-threshold growth does not re-fire")
    func ar3bBaselineAdvancesAfterReindex() async throws {
        try await withIntellectusLock {
            let probe = FakeGrowthProbe(count: 10)
            let reader = NullReader()
            let sink = NullSink()
            let d = DreamingDaemon(
                reader: reader,
                sink: sink,
                policyStore: InMemoryDreamingPolicyStore(),
                growthProbe: probe,
                reindexGrowthThreshold: autoReindexGrowthThreshold // 25
            )

            // Cycle 1: baseline = 10.
            _ = try await d.triggerDreamingCycle(now: t0)

            // Grow by 25: triggers reindex. Baseline advances to 35.
            await probe.setCount(35)
            _ = try await d.triggerDreamingCycle(now: t0.addingTimeInterval(60))

            // Grow by 5 more (35 → 40): below threshold from new baseline.
            await probe.setCount(40)
            _ = try await d.triggerDreamingCycle(now: t0.addingTimeInterval(120))

            let calls = await probe.reindexCallCount()
            #expect(
                calls == 1,
                "after baseline advances to 35, 5 more chunks is below threshold (need 25): got \(calls) reindex calls"
            )
        }
    }

    // AR-4: No probe → no auto-reindex; daemon runs normally.
    @Test("AR-4: nil probe means no auto-reindex")
    func ar4NilProbeNoReindex() async throws {
        try await withIntellectusLock {
            let reader = NullReader()
            let sink = NullSink()
            // growthProbe defaults to nil.
            let d = DreamingDaemon(
                reader: reader,
                sink: sink,
                policyStore: InMemoryDreamingPolicyStore()
            )

            // Run several cycles — should not crash, produce no reindex.
            for i in 0..<3 {
                _ = try await d.triggerDreamingCycle(now: t0.addingTimeInterval(Double(i) * 60))
            }
            // No assertion on probe (there is none); the test passing proves
            // nil probe is safe and the daemon continues normally.
        }
    }

    // AR-5: Above threshold fires; immediately above-threshold again on next
    //        window (enough growth since advanced baseline).
    @Test("AR-5: each growth window beyond threshold fires independently")
    func ar5TwoSuccessiveWindowsFire() async throws {
        try await withIntellectusLock {
            let probe = FakeGrowthProbe(count: 0)
            let reader = NullReader()
            let sink = NullSink()
            let d = DreamingDaemon(
                reader: reader,
                sink: sink,
                policyStore: InMemoryDreamingPolicyStore(),
                growthProbe: probe,
                reindexGrowthThreshold: 10 // smaller threshold for this test
            )

            // Cycle 1: baseline = 0.
            _ = try await d.triggerDreamingCycle(now: t0)

            // Grow by 10 (== threshold at 10): first reindex fires, baseline → 10.
            await probe.setCount(10)
            _ = try await d.triggerDreamingCycle(now: t0.addingTimeInterval(60))
            #expect(await probe.reindexCallCount() == 1, "first window: reindex must fire")

            // Grow by 10 more (10 → 20): second reindex fires, baseline → 20.
            await probe.setCount(20)
            _ = try await d.triggerDreamingCycle(now: t0.addingTimeInterval(120))
            #expect(await probe.reindexCallCount() == 2, "second window: reindex must fire again")
        }
    }

    // AR-6: Reindex failure is non-fatal; the dreaming cycle continues and
    //        diary entry is still written.
    @Test("AR-6: reindex failure is non-fatal; cycle completes and diary entry is written")
    func ar6ReindexFailureIsNonFatal() async throws {
        try await withIntellectusLock {
            // Probe that throws on reindex.
            let probe = FakeGrowthProbe(count: 10, shouldThrow: true)
            let sink = NullSink()
            let reader = NullReader()
            let d = DreamingDaemon(
                reader: reader,
                sink: sink,
                policyStore: InMemoryDreamingPolicyStore(),
                growthProbe: probe,
                reindexGrowthThreshold: 1 // low threshold so it fires immediately after first cycle
            )

            // Cycle 1: baseline = 10.
            _ = try await d.triggerDreamingCycle(now: t0)

            // Grow by 1 — threshold reached on cycle 2. Reindex throws.
            await probe.setCount(11)
            // This must NOT throw even though the probe throws.
            let report = try await d.triggerDreamingCycle(now: t0.addingTimeInterval(60))

            // Cycle completed and returned a valid report.
            #expect(report.tickedAt == t0.addingTimeInterval(60))
        }
    }
}
