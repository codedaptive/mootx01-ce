import Foundation
import PersistenceKit
import Testing
@testable import LocusKit

/// Tests for RecallTraceItem noun and recall_trace persistence.
///
/// Covers the four behaviours specified by NK-1b Part 2:
///   1. `used` computed property backed by operationalBitmap bit 0
///   2. insert + fetch round-trip via DrawerStore
///   3. `markRecallTraceUsed` flips bit 0 and persists
///   4. `markRecallTraceUsed` on a missing id throws `recallTraceItemNotFound`
///   5. `recallTraceSince` returns rows at or after the given timestamp
///
/// All timestamps are deterministic (no `Date()` calls in the tested
/// code paths; tests inject concrete dates). The bitmap flag
/// `flagUsed` == `1 << 0` is asserted explicitly so future bit
/// reassignments fail visibly here before corrupting on-disk data.
@Suite("RecallTraceItem — noun, bitmap, and DrawerStore persistence")
struct RecallTraceItemTests {

    // MARK: - Epoch helpers

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    // MARK: - § 1  Bitmap constant and computed accessor

    @Test("flagUsed is bit 0 (value 1)")
    func flagUsedIsBitZero() {
        #expect(RecallTraceItem.flagUsed == 1)
    }

    @Test("used is false when operationalBitmap is zero")
    func usedFalseWhenBitmapZero() {
        let item = RecallTraceItem(
            target: "drawer-1",
            recalledAt: t(1_700_000_000),
            operationalBitmap: 0
        )
        #expect(!item.used)
    }

    @Test("used is true when operationalBitmap has bit 0 set")
    func usedTrueWhenBitZeroSet() {
        let item = RecallTraceItem(
            target: "drawer-1",
            recalledAt: t(1_700_000_000),
            operationalBitmap: RecallTraceItem.flagUsed
        )
        #expect(item.used)
    }

    @Test("used is false when bits 1..63 are set but bit 0 is clear")
    func usedFalseWhenOnlyHigherBitsSet() {
        // bit 1 only — used must remain false
        let item = RecallTraceItem(
            target: "drawer-1",
            recalledAt: t(1_700_000_000),
            operationalBitmap: 2
        )
        #expect(!item.used)
    }

    @Test("no Bool stored property — operationalBitmap is the canonical store")
    func noBoolStoredProperty() {
        // Mirror-walk the struct's stored properties; none may be named
        // "used" (the computed property is not reflected). This test
        // enforces the schema invariant mechanically.
        let mirror = Mirror(reflecting: RecallTraceItem(
            target: "x", recalledAt: t(0)))
        let storedNames = mirror.children.compactMap(\.label)
        #expect(!storedNames.contains("used"),
                "Bool stored property 'used' found — schema violation")
    }

    // MARK: - § 2  Insert + fetch round-trip

    @Test("insertRecallTrace + getRecallTrace round-trips all fields")
    func insertAndFetchRoundTrip() async throws {
        let (store, url) = try await TestStorage.makeStore()
        defer { TestStorage.cleanup(url) }

        let item = RecallTraceItem(
            id: "trace-001",
            target: "drawer-abc",
            recalledAt: t(1_700_000_000),
            score: 0.875,
            operationalBitmap: 0
        )

        try await store.insertRecallTrace(item)

        let fetched = try await store.getRecallTrace(id: "trace-001")
        let got = try #require(fetched, "expected item in store, got nil")

        #expect(got.id == item.id)
        #expect(got.target == item.target)
        // Timestamp stored as TEXT ISO8601; round-trip within 1-second
        // tolerance to accommodate sub-second truncation in the codec.
        #expect(abs(got.recalledAt.timeIntervalSince(item.recalledAt)) < 1.0)
        #expect(got.score == item.score)
        #expect(got.operationalBitmap == item.operationalBitmap)
        #expect(!got.used)
    }

    @Test("getRecallTrace returns nil for unknown id")
    func fetchUnknownIdReturnsNil() async throws {
        let (store, url) = try await TestStorage.makeStore()
        defer { TestStorage.cleanup(url) }

        let result = try await store.getRecallTrace(id: "no-such-id")
        #expect(result == nil)
    }

    @Test("insertRecallTrace persists score as nil when not provided")
    func insertWithNilScoreRoundTrips() async throws {
        let (store, url) = try await TestStorage.makeStore()
        defer { TestStorage.cleanup(url) }

        let item = RecallTraceItem(
            id: "trace-nil-score",
            target: "drawer-xyz",
            recalledAt: t(1_700_100_000),
            score: nil,
            operationalBitmap: 0
        )
        try await store.insertRecallTrace(item)

        let fetched = try await store.getRecallTrace(id: "trace-nil-score")
        let got = try #require(fetched)
        #expect(got.score == nil)
    }

    // MARK: - § 3  markRecallTraceUsed

    @Test("markRecallTraceUsed sets bit 0 and persists")
    func markUsedFlipsBitZero() async throws {
        let (store, url) = try await TestStorage.makeStore()
        defer { TestStorage.cleanup(url) }

        let item = RecallTraceItem(
            id: "trace-mark",
            target: "drawer-abc",
            recalledAt: t(1_700_000_000),
            operationalBitmap: 0
        )
        try await store.insertRecallTrace(item)
        #expect(!(try await store.getRecallTrace(id: "trace-mark"))!.used)

        try await store.markRecallTraceUsed(id: "trace-mark", now: t(1_700_001_000))

        let marked = try await store.getRecallTrace(id: "trace-mark")
        let got = try #require(marked)
        #expect(got.used)
        #expect(got.operationalBitmap & RecallTraceItem.flagUsed != 0)
    }

    @Test("markRecallTraceUsed preserves bits other than bit 0")
    func markUsedPreservesOtherBits() async throws {
        let (store, url) = try await TestStorage.makeStore()
        defer { TestStorage.cleanup(url) }

        // Bit 2 pre-set; mark used; bit 2 must survive.
        let item = RecallTraceItem(
            id: "trace-bits",
            target: "drawer-abc",
            recalledAt: t(1_700_000_000),
            operationalBitmap: 0b100  // bit 2
        )
        try await store.insertRecallTrace(item)
        try await store.markRecallTraceUsed(id: "trace-bits", now: t(1_700_001_000))

        let got = try #require(try await store.getRecallTrace(id: "trace-bits"))
        #expect(got.used)
        #expect(got.operationalBitmap & 0b100 != 0, "bit 2 must survive markUsed")
    }

    @Test("markRecallTraceUsed is idempotent — second call does not throw")
    func markUsedIsIdempotent() async throws {
        let (store, url) = try await TestStorage.makeStore()
        defer { TestStorage.cleanup(url) }

        let item = RecallTraceItem(
            id: "trace-idem",
            target: "drawer-abc",
            recalledAt: t(1_700_000_000)
        )
        try await store.insertRecallTrace(item)
        try await store.markRecallTraceUsed(id: "trace-idem", now: t(1_700_001_000))
        // Second call on already-marked row must not throw.
        try await store.markRecallTraceUsed(id: "trace-idem", now: t(1_700_002_000))

        let got = try #require(try await store.getRecallTrace(id: "trace-idem"))
        #expect(got.used)
    }

    // MARK: - § 4  markRecallTraceUsed — missing id

    @Test("markRecallTraceUsed throws recallTraceItemNotFound for unknown id")
    func markUsedMissingIdThrows() async throws {
        let (store, url) = try await TestStorage.makeStore()
        defer { TestStorage.cleanup(url) }

        await #expect(throws: LocusKitError.recallTraceItemNotFound(id: "ghost")) {
            try await store.markRecallTraceUsed(id: "ghost", now: t(1_700_001_000))
        }
    }

    // MARK: - § 5  recallTraceSince

    @Test("recallTraceSince returns rows at-or-after the given timestamp")
    func recallTraceSinceFilters() async throws {
        let (store, url) = try await TestStorage.makeStore()
        defer { TestStorage.cleanup(url) }

        // Insert three rows with distinct timestamps.
        let early  = t(1_000)
        let mid    = t(2_000)
        let late   = t(3_000)

        for (idx, ts) in [(1, early), (2, mid), (3, late)] {
            let item = RecallTraceItem(
                id: "trace-\(idx)",
                target: "drawer-\(idx)",
                recalledAt: ts
            )
            try await store.insertRecallTrace(item)
        }

        // Query from mid onwards — should return trace-2 and trace-3.
        let results = try await store.recallTraceSince(mid)
        #expect(results.count == 2)
        let ids = Set(results.map(\.id))
        #expect(ids.contains("trace-2"))
        #expect(ids.contains("trace-3"))
        #expect(!ids.contains("trace-1"))
    }

    @Test("recallTraceSince returns rows in ascending recalledAt order")
    func recallTraceSinceAscendingOrder() async throws {
        let (store, url) = try await TestStorage.makeStore()
        defer { TestStorage.cleanup(url) }

        // Insert in reverse order to exercise the ORDER BY.
        for epoch in [3_000.0, 1_000.0, 2_000.0] {
            let item = RecallTraceItem(
                id: "trace-\(Int(epoch))",
                target: "drawer-x",
                recalledAt: t(epoch)
            )
            try await store.insertRecallTrace(item)
        }

        let results = try await store.recallTraceSince(t(0))
        #expect(results.count == 3)
        // Each successive row must not be earlier than the one before.
        for i in 0..<(results.count - 1) {
            #expect(results[i].recalledAt <= results[i + 1].recalledAt)
        }
    }

    @Test("recallTraceSince returns empty array when no rows match")
    func recallTraceSinceEmptyResult() async throws {
        let (store, url) = try await TestStorage.makeStore()
        defer { TestStorage.cleanup(url) }

        let item = RecallTraceItem(
            id: "trace-old",
            target: "drawer-x",
            recalledAt: t(1_000)
        )
        try await store.insertRecallTrace(item)

        // Query from the far future — should find nothing.
        let results = try await store.recallTraceSince(t(9_999_999_999))
        #expect(results.isEmpty)
    }

    // MARK: - § 6  recentRecallTraces(since:now:)

    @Test("recentRecallTraces returns rows within the [since, now] window")
    func recentRecallTracesWindowFilter() async throws {
        let (store, url) = try await TestStorage.makeStore()
        defer { TestStorage.cleanup(url) }

        // Four rows: before window, at lower bound, inside, at upper bound.
        let before = t(500)
        let since  = t(1_000)
        let inside = t(2_000)
        let now    = t(3_000)
        let after  = t(4_000)   // not inserted, just to confirm no phantom rows

        for (id, ts) in [("r-before", before), ("r-since", since), ("r-inside", inside), ("r-now", now)] {
            try await store.insertRecallTrace(RecallTraceItem(id: id, target: "d-\(id)", recalledAt: ts))
        }
        _ = after  // silence unused warning

        let results = try await store.recentRecallTraces(since: since, now: now)
        let ids = Set(results.map(\.id))

        // Lower and upper bounds are inclusive.
        #expect(ids.contains("r-since"))
        #expect(ids.contains("r-inside"))
        #expect(ids.contains("r-now"))
        // Row before the window must be excluded.
        #expect(!ids.contains("r-before"))
    }

    @Test("recentRecallTraces excludes rows strictly after now")
    func recentRecallTracesExcludesFutureRows() async throws {
        let (store, url) = try await TestStorage.makeStore()
        defer { TestStorage.cleanup(url) }

        let now   = t(2_000)
        let future = t(3_000)

        try await store.insertRecallTrace(RecallTraceItem(id: "r-now",    target: "d1", recalledAt: now))
        try await store.insertRecallTrace(RecallTraceItem(id: "r-future", target: "d2", recalledAt: future))

        let results = try await store.recentRecallTraces(since: t(0), now: now)
        let ids = Set(results.map(\.id))
        #expect(ids.contains("r-now"))
        #expect(!ids.contains("r-future"))
    }

    @Test("recentRecallTraces returns rows in ascending recalledAt order")
    func recentRecallTracesAscendingOrder() async throws {
        let (store, url) = try await TestStorage.makeStore()
        defer { TestStorage.cleanup(url) }

        // Insert in reverse timestamp order.
        for epoch in [3_000.0, 1_000.0, 2_000.0] {
            try await store.insertRecallTrace(
                RecallTraceItem(id: "r-\(Int(epoch))", target: "d", recalledAt: t(epoch)))
        }

        let results = try await store.recentRecallTraces(since: t(0), now: t(9_999))
        #expect(results.count == 3)
        for i in 0..<(results.count - 1) {
            #expect(results[i].recalledAt <= results[i + 1].recalledAt)
        }
    }

    @Test("recentRecallTraces returns empty array when window contains no rows")
    func recentRecallTracesEmptyWindow() async throws {
        let (store, url) = try await TestStorage.makeStore()
        defer { TestStorage.cleanup(url) }

        // Only row is outside the window.
        try await store.insertRecallTrace(
            RecallTraceItem(id: "r-old", target: "d1", recalledAt: t(100)))

        let results = try await store.recentRecallTraces(since: t(1_000), now: t(2_000))
        #expect(results.isEmpty)
    }
}
