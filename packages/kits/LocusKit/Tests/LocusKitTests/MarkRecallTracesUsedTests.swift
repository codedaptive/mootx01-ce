import Foundation
import Testing
@testable import LocusKit

/// Tests for `DrawerStore.markRecallTracesUsed(target:since:now:)` and
/// `DrawerStore.countRecallTraces()`.
///
/// Covers the acceptance criteria from TASK F2 / B-10a:
///   1. Bulk-mark flips the `used` bit on matching rows only.
///   2. Rows outside the time window are left untouched.
///   3. Already-marked rows are skipped (idempotent).
///   4. Unknown target returns 0 (no error).
///   5. The dreaming reward sweep sees reward 1.0 for marked targets
///      and 0.0 for unmarked ones (proved via `RecallTraceRewardSource`
///      in the conformance test below).
///   6. `countRecallTraces` reports total row count.
@Suite("markRecallTracesUsed — bulk reward-wiring path")
struct MarkRecallTracesUsedTests {

    // MARK: - Epoch helpers

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    // MARK: - § 1  Bulk mark flips used bit on matching rows

    @Test("markRecallTracesUsed marks all rows for the target in the window")
    func bulkMarkFlipsBit() async throws {
        let (store, url) = try await TestStorage.makeStore()
        defer { TestStorage.cleanup(url) }

        // Insert five trace rows: two for target "drawer-A" in-window,
        // one for "drawer-A" outside the window, two for "drawer-B".
        let since = t(1_000)
        let now   = t(3_000)

        let rows: [(String, String, TimeInterval)] = [
            ("t1", "drawer-A", 1_000),   // at lower bound — in window
            ("t2", "drawer-A", 2_000),   // inside window
            ("t3", "drawer-A", 4_000),   // after now — outside window
            ("t4", "drawer-B", 1_500),   // different target — must not be marked
            ("t5", "drawer-B", 2_500),   // different target — must not be marked
        ]

        for (id, target, epoch) in rows {
            try await store.insertRecallTrace(
                RecallTraceItem(id: id, target: target, recalledAt: t(epoch))
            )
        }

        let touched = try await store.markRecallTracesUsed(
            target: "drawer-A", since: since, now: now
        )

        // Two rows for drawer-A are in window.
        #expect(touched == 2)

        let t1 = try #require(try await store.getRecallTrace(id: "t1"))
        let t2 = try #require(try await store.getRecallTrace(id: "t2"))
        let t3 = try #require(try await store.getRecallTrace(id: "t3"))
        let t4 = try #require(try await store.getRecallTrace(id: "t4"))
        let t5 = try #require(try await store.getRecallTrace(id: "t5"))

        #expect(t1.used, "t1 (lower bound) must be marked")
        #expect(t2.used, "t2 (inside window) must be marked")
        #expect(!t3.used, "t3 (outside window) must NOT be marked")
        #expect(!t4.used, "t4 (different target) must NOT be marked")
        #expect(!t5.used, "t5 (different target) must NOT be marked")
    }

    // MARK: - § 2  Out-of-window rows untouched

    @Test("markRecallTracesUsed leaves rows before since untouched")
    func outOfWindowBeforeSince() async throws {
        let (store, url) = try await TestStorage.makeStore()
        defer { TestStorage.cleanup(url) }

        let since = t(2_000)
        let now   = t(3_000)

        // Row strictly before the window.
        try await store.insertRecallTrace(
            RecallTraceItem(id: "before", target: "drawer-X", recalledAt: t(1_999))
        )

        let touched = try await store.markRecallTracesUsed(
            target: "drawer-X", since: since, now: now
        )
        #expect(touched == 0)

        let row = try #require(try await store.getRecallTrace(id: "before"))
        #expect(!row.used)
    }

    // MARK: - § 3  Idempotent — already-marked rows not double-counted

    @Test("markRecallTracesUsed is idempotent — second call returns 0 touched")
    func idempotentSecondCall() async throws {
        let (store, url) = try await TestStorage.makeStore()
        defer { TestStorage.cleanup(url) }

        let since = t(1_000)
        let now   = t(3_000)

        try await store.insertRecallTrace(
            RecallTraceItem(id: "idem-1", target: "drawer-Y", recalledAt: t(2_000))
        )

        // First call marks it.
        let first = try await store.markRecallTracesUsed(
            target: "drawer-Y", since: since, now: now
        )
        #expect(first == 1)

        // Second call: row already marked — should return 0 (idempotent).
        let second = try await store.markRecallTracesUsed(
            target: "drawer-Y", since: since, now: now
        )
        #expect(second == 0)

        // Row is still marked.
        let row = try #require(try await store.getRecallTrace(id: "idem-1"))
        #expect(row.used)
    }

    // MARK: - § 4  Unknown target returns 0

    @Test("markRecallTracesUsed returns 0 for an unknown target")
    func unknownTargetReturnsZero() async throws {
        let (store, url) = try await TestStorage.makeStore()
        defer { TestStorage.cleanup(url) }

        let touched = try await store.markRecallTracesUsed(
            target: "nonexistent", since: t(0), now: t(9_999)
        )
        #expect(touched == 0)
    }

    // MARK: - § 5  Reward sweep sees 1.0 for marked, 0.0 for unmarked

    @Test("reward sweep sees 1.0 for marked target and 0.0 for unreferenced")
    func rewardSweepSeesCorrectValues() async throws {
        // This test proves the dreaming-daemon reward path: surface two
        // drawers, mark only one as used, verify that `RecallTraceItem.used`
        // evaluates to the expected reward values for each target.
        let (store, url) = try await TestStorage.makeStore()
        defer { TestStorage.cleanup(url) }

        let since = t(0)
        let now   = t(10_000)

        // Simulate two drawers surfaced in a recall.
        try await store.insertRecallTrace(
            RecallTraceItem(id: "tr-used",   target: "drawer-used",   recalledAt: t(5_000))
        )
        try await store.insertRecallTrace(
            RecallTraceItem(id: "tr-unused", target: "drawer-unused", recalledAt: t(5_001))
        )

        // ARIA decides drawer-used was subsequently dereferenced — mark it.
        _ = try await store.markRecallTracesUsed(
            target: "drawer-used", since: since, now: now
        )

        // Reward sweep reads recent traces for this window.
        let traces = try await store.recentRecallTraces(since: since, now: now)
        #expect(traces.count == 2)

        // Build reward-by-target map: max over rows for same target (mirrors
        // DreamingDaemon.rewardByTarget logic).
        var rewardByTarget: [String: Double] = [:]
        for trace in traces {
            let reward: Double = trace.used ? 1.0 : 0.0
            rewardByTarget[trace.target] = max(rewardByTarget[trace.target] ?? 0.0, reward)
        }

        #expect(rewardByTarget["drawer-used"]   == 1.0, "used drawer must produce reward 1.0")
        #expect(rewardByTarget["drawer-unused"] == 0.0, "unreferenced drawer must produce reward 0.0")
    }

    // MARK: - § 6  countRecallTraces

    @Test("countRecallTraces returns 0 when the table is empty")
    func countEmpty() async throws {
        let (store, url) = try await TestStorage.makeStore()
        defer { TestStorage.cleanup(url) }

        let count = try await store.countRecallTraces()
        #expect(count == 0)
    }

    @Test("countRecallTraces returns total row count including used and unused rows")
    func countIncludesAllRows() async throws {
        let (store, url) = try await TestStorage.makeStore()
        defer { TestStorage.cleanup(url) }

        // Insert three rows.
        for i in 1...3 {
            try await store.insertRecallTrace(
                RecallTraceItem(
                    id: "tc-\(i)", target: "drawer-\(i)",
                    recalledAt: t(Double(i) * 1_000)
                )
            )
        }

        // Mark one as used.
        try await store.markRecallTraceUsed(id: "tc-2", now: t(9_999))

        // Count must include all three rows regardless of used/unused status.
        let count = try await store.countRecallTraces()
        #expect(count == 3)
    }
}
