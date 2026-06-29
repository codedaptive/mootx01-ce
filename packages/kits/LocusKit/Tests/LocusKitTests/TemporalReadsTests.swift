// TemporalReadsTests.swift
//
// Tests for DrawerStore.fingerprintsCaptured(in:) and
// DrawerStore.fingerprintBitSeries(bit:bucketSeconds:bucketCount:endingAt:).
//
// Three-row fixture with pinned capture times mirrors the Rust fixture
// in tests/temporal_reads_tests.rs. Any change to the fixture constants
// (epoch offsets, content strings, drawer ids) must be reflected in
// both ports so the shared-expected-values contract holds.
//
// Shared fixture (epoch seconds relative to EPOCH_NOW = 1_700_100_000):
//   d1.eventTime = EPOCH_NOW        (content: temporal-fixture-alpha)
//   d2.eventTime = EPOCH_NOW + 100  (content: temporal-fixture-beta)
//   d3.eventTime = EPOCH_NOW + 200  (content: temporal-fixture-gamma)
//
// Bucket boundary test — endingAt = EPOCH_NOW + 300, bucket = 100 s, 3 buckets:
//   bucket[0] = [EPOCH_NOW,       EPOCH_NOW+100)  → d1 only
//   bucket[1] = [EPOCH_NOW+100,   EPOCH_NOW+200)  → d2 only (d2 is on the edge
//                                                    so it belongs to bucket[1],
//                                                    not bucket[0])
//   bucket[2] = [EPOCH_NOW+200,   EPOCH_NOW+300]  → d3 only (d3 is on the edge
//                                                    so it belongs to bucket[2])

import Foundation
import SubstrateTypes
import Testing
@testable import LocusKit

// Epoch anchor shared with the Rust fixture.
private let EPOCH_NOW: TimeInterval = 1_700_100_000

// Content strings shared with the Rust fixture.
private let CONTENT_A = "temporal-fixture-alpha"
private let CONTENT_B = "temporal-fixture-beta"
private let CONTENT_C = "temporal-fixture-gamma"

@Suite("TemporalReadsTests — fingerprintsCaptured and fingerprintBitSeries")
struct TemporalReadsTests {

    private func t(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: EPOCH_NOW + offset)
    }

    private func makeStore() async throws -> (DrawerStore, URL) {
        try await TestStorage.makeStore()
    }

    /// Build a Drawer with a specific eventTime and content string.
    private func drawer(id: String, content: String, eventTime: Date) -> Drawer {
        Drawer(
            id: TestStorage.tid(id),
            content: content,
            parentNodeId: "test-parent",
            addedBy: "bilby",
            filedAt: t(0),
            eventTime: eventTime,
            embeddingModelID: "minilm-v6"
        )
    }

    /// Insert the three-row fixture.  Returns (d1, d2, d3) for reuse in tests.
    @discardableResult
    private func buildFixture(
        store: DrawerStore
    ) async throws -> (d1: Drawer, d2: Drawer, d3: Drawer) {
        let d1 = drawer(id: "tr-d1", content: CONTENT_A, eventTime: t(0))
        let d2 = drawer(id: "tr-d2", content: CONTENT_B, eventTime: t(100))
        let d3 = drawer(id: "tr-d3", content: CONTENT_C, eventTime: t(200))
        try await store.addDrawer(d1, now: t(0))
        try await store.addDrawer(d2, now: t(0))
        try await store.addDrawer(d3, now: t(0))
        return (d1, d2, d3)
    }

    // MARK: - fingerprintsCaptured(in:) tests

    @Test("fingerprintsCaptured: full window [0,+200] returns 3 fingerprints in row-id order")
    func capturedFullWindow() async throws {
        let (store, url) = try await makeStore()
        defer { TestStorage.cleanup(url) }
        let (d1, d2, d3) = try await buildFixture(store: store)

        let result = try await store.fingerprintsCaptured(in: t(0)...t(200))

        #expect(result.count == 3)

        // ORDER BY id ASC sorts by UUID string (lexicographic), not insertion order.
        // Sort the fixture drawers by their UUID string to match SQL ordering.
        let families = EstateFingerprintFamilies(estateUUID: await store.estateUuid.uuidString)
        var sortedDrawers = [d1, d2, d3]
        sortedDrawers.sort { (a: Drawer, b: Drawer) in a.id < b.id }
        let expectedInOrder = sortedDrawers.map { families.fingerprint(of: $0) }
        #expect(result == expectedInOrder)
    }

    @Test("fingerprintsCaptured: narrow window [0,+100] returns 2 fingerprints")
    func capturedNarrowWindow() async throws {
        let (store, url) = try await makeStore()
        defer { TestStorage.cleanup(url) }
        try await buildFixture(store: store)

        let result = try await store.fingerprintsCaptured(in: t(0)...t(100))
        #expect(result.count == 2)
    }

    @Test("fingerprintsCaptured: single-point window returns 1 fingerprint")
    func capturedSinglePoint() async throws {
        let (store, url) = try await makeStore()
        defer { TestStorage.cleanup(url) }
        let (_, d2, _) = try await buildFixture(store: store)

        let result = try await store.fingerprintsCaptured(in: t(100)...t(100))
        #expect(result.count == 1)
        let families = EstateFingerprintFamilies(estateUUID: await store.estateUuid.uuidString)
        #expect(result[0] == families.fingerprint(of: d2))
    }

    @Test("fingerprintsCaptured: window before fixture returns empty")
    func capturedEmptyWindow() async throws {
        let (store, url) = try await makeStore()
        defer { TestStorage.cleanup(url) }
        try await buildFixture(store: store)

        let result = try await store.fingerprintsCaptured(
            in: t(-1000)...t(-1)
        )
        #expect(result.isEmpty)
    }

    // MARK: - fingerprintBitSeries tests

    @Test("fingerprintBitSeries: bucketCount == 0 returns empty array")
    func bitSeriesZeroBuckets() async throws {
        let (store, url) = try await makeStore()
        defer { TestStorage.cleanup(url) }
        try await buildFixture(store: store)

        let result = try await store.fingerprintBitSeries(
            bit: 0, bucketSeconds: 100, bucketCount: 0, endingAt: t(300)
        )
        #expect(result.isEmpty)
    }

    @Test("fingerprintBitSeries: bit 256 throws LocusKitError")
    func bitSeriesOutOfRangeBit() async throws {
        let (store, url) = try await makeStore()
        defer { TestStorage.cleanup(url) }

        await #expect(throws: (any Error).self) {
            _ = try await store.fingerprintBitSeries(
                bit: 256, bucketSeconds: 100, bucketCount: 3, endingAt: t(300)
            )
        }
    }

    @Test("fingerprintBitSeries: bucketSeconds 0 throws LocusKitError")
    func bitSeriesZeroBucketSeconds() async throws {
        let (store, url) = try await makeStore()
        defer { TestStorage.cleanup(url) }

        await #expect(throws: (any Error).self) {
            _ = try await store.fingerprintBitSeries(
                bit: 0, bucketSeconds: 0, bucketCount: 3, endingAt: t(300)
            )
        }
    }

    @Test("fingerprintBitSeries: no drawers in window → all buckets false")
    func bitSeriesEmptyWindow() async throws {
        let (store, url) = try await makeStore()
        defer { TestStorage.cleanup(url) }
        try await buildFixture(store: store)

        // endingAt is 10 000 s before the fixture — no drawers in range.
        let result = try await store.fingerprintBitSeries(
            bit: 0, bucketSeconds: 100, bucketCount: 3, endingAt: t(-10_000)
        )
        #expect(result == [false, false, false])
    }

    @Test("fingerprintBitSeries: bucket-edge capture belongs to the later bucket")
    func bitSeriesBucketEdgeSemantics() async throws {
        let (store, url) = try await makeStore()
        defer { TestStorage.cleanup(url) }
        let (d1, d2, d3) = try await buildFixture(store: store)

        // Compute fingerprints to verify the exact bit-series values.
        let families = EstateFingerprintFamilies(estateUUID: await store.estateUuid.uuidString)
        let fp1 = families.fingerprint(of: d1)
        let fp2 = families.fingerprint(of: d2)
        let fp3 = families.fingerprint(of: d3)

        // 3 buckets × 100 s, endingAt = EPOCH_NOW + 300:
        //   bucket[0] = [EPOCH_NOW,     EPOCH_NOW+100)  → contains d1 only
        //   bucket[1] = [EPOCH_NOW+100, EPOCH_NOW+200)  → contains d2 (edge → later bucket)
        //   bucket[2] = [EPOCH_NOW+200, EPOCH_NOW+300]  → contains d3 (edge → later bucket)
        let endingAt = t(300)

        // Pick a bit set in d1 and verify it appears in bucket[0] only.
        let b1 = findFirstSetBit(fp1)
        let series1 = try await store.fingerprintBitSeries(
            bit: b1, bucketSeconds: 100, bucketCount: 3, endingAt: endingAt
        )
        #expect(series1.count == 3)
        // bucket[0] = true iff b1 is set in fp1 (which it is by construction).
        #expect(series1[0] == isBitSet(fp1, bit: b1))
        // bucket[1] depends on fp2 for that same bit index.
        #expect(series1[1] == isBitSet(fp2, bit: b1))
        // bucket[2] depends on fp3.
        #expect(series1[2] == isBitSet(fp3, bit: b1))

        // Pick a bit set in d2 — it must appear in bucket[1].
        let b2 = findFirstSetBit(fp2)
        let series2 = try await store.fingerprintBitSeries(
            bit: b2, bucketSeconds: 100, bucketCount: 3, endingAt: endingAt
        )
        // d2 is at the boundary EPOCH_NOW+100; it should be in bucket[1], not bucket[0].
        #expect(series2[0] == isBitSet(fp1, bit: b2))
        #expect(series2[1] == isBitSet(fp2, bit: b2))
        #expect(series2[2] == isBitSet(fp3, bit: b2))

        // Pick a bit set in d3 — it must appear in bucket[2].
        let b3 = findFirstSetBit(fp3)
        let series3 = try await store.fingerprintBitSeries(
            bit: b3, bucketSeconds: 100, bucketCount: 3, endingAt: endingAt
        )
        #expect(series3[0] == isBitSet(fp1, bit: b3))
        #expect(series3[1] == isBitSet(fp2, bit: b3))
        #expect(series3[2] == isBitSet(fp3, bit: b3))
    }

    // MARK: - Bit helpers (mirrors Rust temporal_bit_set)

    /// Index (0–255) of the first set bit; returns 0 if all blocks are zero.
    private func findFirstSetBit(_ fp: Fingerprint256) -> Int {
        for b in 0..<64   where (fp.block0 >> UInt64(b)) & 1 != 0 { return b }
        for b in 0..<64   where (fp.block1 >> UInt64(b)) & 1 != 0 { return b + 64 }
        for b in 0..<64   where (fp.block2 >> UInt64(b)) & 1 != 0 { return b + 128 }
        for b in 0..<64   where (fp.block3 >> UInt64(b)) & 1 != 0 { return b + 192 }
        return 0
    }

    /// Returns true when `bit` (0-based, block0 = bits 0–63) is set in `fp`.
    private func isBitSet(_ fp: Fingerprint256, bit: Int) -> Bool {
        switch bit {
        case 0..<64:    return (fp.block0 >> UInt64(bit)) & 1 != 0
        case 64..<128:  return (fp.block1 >> UInt64(bit - 64)) & 1 != 0
        case 128..<192: return (fp.block2 >> UInt64(bit - 128)) & 1 != 0
        default:        return (fp.block3 >> UInt64(bit - 192)) & 1 != 0
        }
    }
}
