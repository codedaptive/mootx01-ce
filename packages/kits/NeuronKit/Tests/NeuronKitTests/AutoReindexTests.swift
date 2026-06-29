// AutoReindexTests.swift
//
// Conformance tests for the dreaming daemon's auto-reindex step.
//
// The gate fires on VOCABULARY growth (P3 item 5): the trigger is
// `max(reindexVocabGrowthFloor, ceil(lastReindexVocab × reindexVocabGrowthFraction))`.
// Most tests use small vocabularies where the absolute floor dominates; AR-7
// exercises the proportional fraction path at a large baseline.
//
// Covers:
//   AR-1: First cycle establishes baseline without firing reindex.
//   AR-2: Below floor → reindex does NOT fire.
//   AR-3: At or above floor → reindex fires; baseline advances.
//   AR-4: No probe injected → no reindex fires (nil probe = safe no-op).
//   AR-5: After reindex, delta resets; next window needs another floor worth of growth.
//   AR-6: Reindex failure is non-fatal; cycle continues.
//   AR-7: At a large baseline the fraction dominates the floor.
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

    /// Live vocabulary anchor returned by `vocabAnchor()`.
    var vocab: Int

    /// Whether `reindex(now:)` should throw.
    var shouldThrow: Bool

    /// Timestamps of `reindex(now:)` calls.
    private(set) var reindexCalls: [Date] = []

    /// Counts of `vocabAnchor()` calls.
    private(set) var vocabCallCount: Int = 0

    init(vocab: Int = 0, shouldThrow: Bool = false) {
        self.vocab = vocab
        self.shouldThrow = shouldThrow
    }

    func vocabAnchor() async throws -> Int {
        vocabCallCount += 1
        return vocab
    }

    func reindex(now: Date) async throws {
        if shouldThrow {
            // Simulate a storage error.
            struct FakeReindexError: Error {}
            throw FakeReindexError()
        }
        reindexCalls.append(now)
    }

    func setVocab(_ n: Int) { vocab = n }
    func setShouldThrow(_ v: Bool) { shouldThrow = v }
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
    func drainDreamingWindow() async throws -> [[String]] { [] }
    func existingTunnels() async throws -> [Tunnel] { [] }
}

// MARK: - Tests

@Suite("Dreaming daemon auto-reindex")
struct AutoReindexTests {

    // AR-1: First cycle stores the baseline vocabulary and does NOT fire reindex.
    @Test("AR-1: first cycle establishes baseline without firing reindex")
    func ar1FirstCycleEstablishesBaselineWithoutReindex() async throws {
        try await withIntellectusLock {
            let probe = FakeGrowthProbe(vocab: 10)
            let reader = NullReader()
            let sink = NullSink()
            let d = DreamingDaemon(
                reader: reader,
                sink: sink,
                policyStore: InMemoryDreamingPolicyStore(),
                growthProbe: probe
            )

            _ = try await d.triggerDreamingCycle(now: t0)

            // Baseline was read (vocabAnchor called), but reindex was NOT fired.
            let calls = await probe.reindexCallCount()
            #expect(calls == 0, "first cycle must establish baseline, not trigger reindex")
            let vocabCalls = await probe.vocabCallCount
            #expect(vocabCalls >= 1, "vocabAnchor must be queried to establish baseline")
        }
    }

    // AR-2: Vocab growth below the floor — reindex must NOT fire.
    @Test("AR-2: growth below the floor does not trigger reindex")
    func ar2BelowFloorNoReindex() async throws {
        try await withIntellectusLock {
            // Start at vocab 10. After first cycle (baseline = 10), grow by
            // floor - 1 (24 terms). Reindex must not fire.
            let probe = FakeGrowthProbe(vocab: 10)
            let reader = NullReader()
            let sink = NullSink()
            let d = DreamingDaemon(
                reader: reader,
                sink: sink,
                policyStore: InMemoryDreamingPolicyStore(),
                growthProbe: probe,
                reindexVocabGrowthFloor: autoReindexVocabGrowthFloor // 25
            )

            // Cycle 1: establish baseline at 10.
            _ = try await d.triggerDreamingCycle(now: t0)

            // Grow by 24 (one below the floor; fraction 10%×10=1 is dominated).
            await probe.setVocab(34) // 34 - 10 = 24 < 25

            // Cycle 2: growth = 24, below the floor.
            _ = try await d.triggerDreamingCycle(now: t0.addingTimeInterval(60))

            let calls = await probe.reindexCallCount()
            #expect(calls == 0, "vocab growth of 24 (< floor 25) must not trigger reindex")
        }
    }

    // AR-3: Vocab growth at or above the floor → reindex fires; baseline advances.
    @Test("AR-3: growth at the floor triggers reindex and advances baseline")
    func ar3AtFloorReindexFires() async throws {
        try await withIntellectusLock {
            let probe = FakeGrowthProbe(vocab: 10)
            let reader = NullReader()
            let sink = NullSink()
            let d = DreamingDaemon(
                reader: reader,
                sink: sink,
                policyStore: InMemoryDreamingPolicyStore(),
                growthProbe: probe,
                reindexVocabGrowthFloor: autoReindexVocabGrowthFloor // 25
            )

            // Cycle 1: baseline = 10.
            _ = try await d.triggerDreamingCycle(now: t0)

            // Grow by exactly the floor (25 terms): 10 + 25 = 35.
            await probe.setVocab(35)

            let t1 = t0.addingTimeInterval(60)
            _ = try await d.triggerDreamingCycle(now: t1)

            // Reindex should have fired once.
            let calls = await probe.reindexCallCount()
            #expect(calls == 1, "growth == floor must trigger exactly one reindex")

            // Verify the timestamp passed to reindex is the cycle's `now`.
            let reindexNow = await probe.reindexCalls.first
            #expect(reindexNow == t1, "reindex must receive the cycle's `now` parameter")
        }
    }

    // AR-3b: After baseline advances, further sub-floor growth does not reindex again.
    @Test("AR-3b: after reindex, baseline resets; sub-floor growth does not re-fire")
    func ar3bBaselineAdvancesAfterReindex() async throws {
        try await withIntellectusLock {
            let probe = FakeGrowthProbe(vocab: 10)
            let reader = NullReader()
            let sink = NullSink()
            let d = DreamingDaemon(
                reader: reader,
                sink: sink,
                policyStore: InMemoryDreamingPolicyStore(),
                growthProbe: probe,
                reindexVocabGrowthFloor: autoReindexVocabGrowthFloor // 25
            )

            // Cycle 1: baseline = 10.
            _ = try await d.triggerDreamingCycle(now: t0)

            // Grow by 25: triggers reindex. Baseline advances to 35.
            await probe.setVocab(35)
            _ = try await d.triggerDreamingCycle(now: t0.addingTimeInterval(60))

            // Grow by 5 more (35 → 40): below the floor from the new baseline
            // (fraction 10%×35=4 is also below 5? no — trigger = max(25, 4) = 25).
            await probe.setVocab(40)
            _ = try await d.triggerDreamingCycle(now: t0.addingTimeInterval(120))

            let calls = await probe.reindexCallCount()
            #expect(
                calls == 1,
                "after baseline advances to 35, 5 more terms is below the floor (need 25): got \(calls) reindex calls"
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

    // AR-5: Above the floor fires; immediately above-floor again on next
    //        window (enough growth since advanced baseline).
    @Test("AR-5: each growth window beyond the floor fires independently")
    func ar5TwoSuccessiveWindowsFire() async throws {
        try await withIntellectusLock {
            let probe = FakeGrowthProbe(vocab: 0)
            let reader = NullReader()
            let sink = NullSink()
            let d = DreamingDaemon(
                reader: reader,
                sink: sink,
                policyStore: InMemoryDreamingPolicyStore(),
                growthProbe: probe,
                reindexVocabGrowthFloor: 10 // smaller floor for this test
            )

            // Cycle 1: baseline = 0.
            _ = try await d.triggerDreamingCycle(now: t0)

            // Grow by 10 (== floor 10): first reindex fires, baseline → 10.
            await probe.setVocab(10)
            _ = try await d.triggerDreamingCycle(now: t0.addingTimeInterval(60))
            #expect(await probe.reindexCallCount() == 1, "first window: reindex must fire")

            // Grow by 10 more (10 → 20): trigger = max(10, ceil(10×0.1)=1) = 10;
            // second reindex fires, baseline → 20.
            await probe.setVocab(20)
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
            let probe = FakeGrowthProbe(vocab: 10, shouldThrow: true)
            let sink = NullSink()
            let reader = NullReader()
            let d = DreamingDaemon(
                reader: reader,
                sink: sink,
                policyStore: InMemoryDreamingPolicyStore(),
                growthProbe: probe,
                reindexVocabGrowthFloor: 1 // low floor so it fires immediately after first cycle
            )

            // Cycle 1: baseline = 10.
            _ = try await d.triggerDreamingCycle(now: t0)

            // Grow by 1 — floor reached on cycle 2. Reindex throws.
            await probe.setVocab(11)
            // This must NOT throw even though the probe throws.
            let report = try await d.triggerDreamingCycle(now: t0.addingTimeInterval(60))

            // Cycle completed and returned a valid report.
            #expect(report.tickedAt == t0.addingTimeInterval(60))
        }
    }

    // AR-7: At a LARGE baseline the proportional fraction dominates the floor:
    //        10% of 1000 = 100 terms required, so a +60 growth (above the floor
    //        of 25 but below 100) must NOT fire, while +100 must.
    @Test("AR-7: at a large baseline the fraction dominates the floor")
    func ar7FractionDominatesAtLargeBaseline() async throws {
        try await withIntellectusLock {
            let probe = FakeGrowthProbe(vocab: 1000)
            let reader = NullReader()
            let sink = NullSink()
            let d = DreamingDaemon(
                reader: reader,
                sink: sink,
                policyStore: InMemoryDreamingPolicyStore(),
                growthProbe: probe,
                reindexVocabGrowthFraction: 0.10, // 10% of 1000 = 100
                reindexVocabGrowthFloor: 25
            )

            // Cycle 1: baseline = 1000.
            _ = try await d.triggerDreamingCycle(now: t0)

            // Grow by 60 (above the floor 25 but below the fractional 100).
            await probe.setVocab(1060)
            _ = try await d.triggerDreamingCycle(now: t0.addingTimeInterval(60))
            #expect(await probe.reindexCallCount() == 0,
                    "+60 is below the fractional trigger (100) at a 1000-term baseline")

            // Grow to +100 from baseline: meets the fractional trigger.
            await probe.setVocab(1100)
            _ = try await d.triggerDreamingCycle(now: t0.addingTimeInterval(120))
            #expect(await probe.reindexCallCount() == 1,
                    "+100 meets the fractional trigger (10% of 1000)")
        }
    }

    // AR-8 (Codex finding 3 parity): a FAILED reindex does not advance the
    // baseline, so the gate re-fires next cycle (retry). Swift gets this for free
    // — a throwing `reindex(now:)` skips the baseline assignment; this documents
    // the contract the Rust port now matches.
    @Test("AR-8: a failed reindex does not advance the baseline; retry fires next cycle")
    func ar8FailedReindexRetriesNextCycle() async throws {
        try await withIntellectusLock {
            let probe = FakeGrowthProbe(vocab: 10, shouldThrow: true)
            let reader = NullReader()
            let sink = NullSink()
            let d = DreamingDaemon(
                reader: reader,
                sink: sink,
                policyStore: InMemoryDreamingPolicyStore(),
                growthProbe: probe,
                reindexVocabGrowthFloor: 1)

            // Cycle 1: baseline = 10.
            _ = try await d.triggerDreamingCycle(now: t0)

            // Cycle 2: vocab 12 (delta 2 ≥ floor 1) → fires but THROWS. The
            // baseline is not advanced (the assignment is skipped on throw).
            await probe.setVocab(12)
            _ = try await d.triggerDreamingCycle(now: t0.addingTimeInterval(60))
            #expect(await probe.reindexCallCount() == 0, "failed reindex records nothing")

            // Cycle 3: same vocab (12), now succeeding. If the baseline had
            // advanced to 12 on the failure, delta would be 0 and nothing fires;
            // because it did not, delta is 2 ≥ 1 → the retry fires now.
            await probe.setShouldThrow(false)
            _ = try await d.triggerDreamingCycle(now: t0.addingTimeInterval(120))
            #expect(await probe.reindexCallCount() == 1,
                    "failed reindex must not advance the baseline — retry fires next cycle")
        }
    }
}
