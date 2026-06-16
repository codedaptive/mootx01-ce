// TemporalCausalityFoldTests.swift
//
// Conformance tests for TemporalCausalityFold (cookbook §6.4 engine).
//
// Coverage:
//   1. empty entries → no deltas, watermark unchanged
//   2. single entry → no pairs (nothing to pair against)
//   3. two entries within window → one delta pair
//   4. two entries outside window → no deltas (buffer eviction)
//   5. watermark respected — entry at or before watermark serves as
//      source for a later new entry but is not itself a "new" entry
//   6–13. each of the 8 lag bucket boundaries
//   14. watermark advances correctly through multiple new entries
//   15. determinism — same input, same output across two calls

import Testing
@testable import SubstrateML
import SubstrateTypes

// MARK: - Test helpers

private func hlc(_ physicalMs: Int64) -> HLC {
    HLC(physicalTime: physicalMs, logicalCount: 0, nodeID: 0)
}

private func coord(_ fieldPath: String, _ valueRepr: String) -> TemporalFieldCoord {
    TemporalFieldCoord(fieldPath: fieldPath, valueRepr: valueRepr)
}

private func entry(_ ms: Int64, _ coords: [TemporalFieldCoord]) -> TemporalAuditEntry {
    TemporalAuditEntry(hlc: hlc(ms), fieldCoords: coords)
}

// MARK: - Tests

@Suite("TemporalCausalityFold engine")
struct TemporalCausalityFoldTests {

    // MARK: - 1. Empty entries

    @Test("empty entry list returns no deltas and unchanged watermark")
    func emptyEntries() {
        let wm = hlc(1_000)
        let result = TemporalCausalityFold.fold(
            entries: [],
            windowMinutes: 256,
            startWatermark: wm)
        #expect(result.deltas.isEmpty)
        #expect(result.newWatermark == wm)
    }

    // MARK: - 2. Single entry

    @Test("single entry produces no pairs")
    func singleEntry() {
        let wm = HLC.zero
        let entries = [entry(60_000, [coord("f", "bitmap:1")])]
        let result = TemporalCausalityFold.fold(
            entries: entries,
            windowMinutes: 256,
            startWatermark: wm)
        #expect(result.deltas.isEmpty, "no older entry to pair with — T is unchanged")
        #expect(result.newWatermark == hlc(60_000))
    }

    // MARK: - 3. Two entries within window

    @Test("two entries 1 minute apart produce one pair in bucket 1")
    func twoEntriesWithinWindow() throws {
        let wm = HLC.zero
        let entries = [
            entry(0, [coord("field-a", "bitmap:10")]),
            entry(60_000, [coord("field-b", "bitmap:20")]),  // 1 minute later
        ]
        let result = TemporalCausalityFold.fold(
            entries: entries,
            windowMinutes: 256,
            startWatermark: wm)
        #expect(result.deltas.count == 1)
        let (key, count) = try #require(result.deltas.first)
        #expect(key.source == coord("field-a", "bitmap:10"))
        #expect(key.target == coord("field-b", "bitmap:20"))
        #expect(key.lagBucket == 1)
        #expect(count == 1)
        #expect(result.newWatermark == hlc(60_000))
    }

    // MARK: - 4. Two entries outside window

    @Test("two entries beyond windowMinutes produce no deltas")
    func twoEntriesOutsideWindow() {
        let wm = HLC.zero
        // 257 minutes apart — just beyond the 256-minute cap.
        let outsideMs: Int64 = 257 * 60_000
        let entries = [
            entry(0, [coord("f", "bitmap:1")]),
            entry(outsideMs, [coord("g", "bitmap:2")]),
        ]
        let result = TemporalCausalityFold.fold(
            entries: entries,
            windowMinutes: 256,
            startWatermark: wm)
        #expect(result.deltas.isEmpty, "257-minute delta evicts the earlier entry from buffer")
        #expect(result.newWatermark == hlc(outsideMs))
    }

    // MARK: - 5. Watermark is respected

    @Test("entry at or before watermark serves as source but is not new")
    func watermarkBoundary() {
        // Entry at t=0 is before the watermark (t=30 s). It serves as a
        // source for the new entry at t=60 s but does not itself advance
        // the watermark.
        let wm = hlc(30_000) // between the two entries
        let entries = [
            entry(0, [coord("src", "bitmap:1")]),     // ≤ watermark
            entry(60_000, [coord("tgt", "bitmap:2")]), // > watermark → new
        ]
        let result = TemporalCausalityFold.fold(
            entries: entries,
            windowMinutes: 256,
            startWatermark: wm)
        #expect(result.deltas.count == 1, "source-before-watermark still pairs with a new target")
        #expect(result.newWatermark == hlc(60_000))
    }

    // MARK: - 6–13. Lag bucket boundaries

    @Test("1-minute delta → bucket 1")
    func bucket1() {
        let (key, _) = twoEntryFold(separationMinutes: 1)
        #expect(key.lagBucket == 1)
    }

    @Test("2-minute delta → bucket 2")
    func bucket2() {
        let (key, _) = twoEntryFold(separationMinutes: 2)
        #expect(key.lagBucket == 2)
    }

    @Test("3-minute delta → bucket 4 (smallest boundary ≥ 3)")
    func bucket4Coarse() {
        let (key, _) = twoEntryFold(separationMinutes: 3)
        #expect(key.lagBucket == 4)
    }

    @Test("4-minute delta → bucket 4")
    func bucket4Exact() {
        let (key, _) = twoEntryFold(separationMinutes: 4)
        #expect(key.lagBucket == 4)
    }

    @Test("8-minute delta → bucket 8")
    func bucket8() {
        let (key, _) = twoEntryFold(separationMinutes: 8)
        #expect(key.lagBucket == 8)
    }

    @Test("16-minute delta → bucket 16")
    func bucket16() {
        let (key, _) = twoEntryFold(separationMinutes: 16)
        #expect(key.lagBucket == 16)
    }

    @Test("32-minute delta → bucket 32")
    func bucket32() {
        let (key, _) = twoEntryFold(separationMinutes: 32)
        #expect(key.lagBucket == 32)
    }

    @Test("64-minute delta → bucket 64")
    func bucket64() {
        let (key, _) = twoEntryFold(separationMinutes: 64)
        #expect(key.lagBucket == 64)
    }

    @Test("128-minute delta → bucket 128")
    func bucket128() {
        let (key, _) = twoEntryFold(separationMinutes: 128)
        #expect(key.lagBucket == 128)
    }

    // MARK: - 14. Watermark advances through multiple new entries

    @Test("watermark advances to last new entry's HLC")
    func watermarkAdvances() {
        let wm = HLC.zero
        let entries = [
            entry(0,         [coord("a", "bitmap:1")]),
            entry(60_000,    [coord("b", "bitmap:2")]),
            entry(120_000,   [coord("c", "bitmap:3")]),
        ]
        let result = TemporalCausalityFold.fold(
            entries: entries,
            windowMinutes: 256,
            startWatermark: wm)
        #expect(result.newWatermark == hlc(120_000), "watermark must reach the last new entry")
    }

    // MARK: - 15. Determinism

    @Test("same input produces identical output across two calls")
    func determinism() {
        let wm = HLC.zero
        let entries = [
            entry(0,       [coord("f1", "bitmap:1"), coord("f2", "string:x")]),
            entry(120_000, [coord("g1", "bitmap:5")]),
            entry(240_000, [coord("h1", "integer:99")]),
        ]
        let r1 = TemporalCausalityFold.fold(
            entries: entries, windowMinutes: 256, startWatermark: wm)
        let r2 = TemporalCausalityFold.fold(
            entries: entries, windowMinutes: 256, startWatermark: wm)
        #expect(r1.newWatermark == r2.newWatermark)
        #expect(r1.deltas.count == r2.deltas.count)
        for (i, ((k1, c1), (k2, c2))) in zip(r1.deltas, r2.deltas).enumerated() {
            #expect(k1 == k2, "key at position \(i) must be identical across calls")
            #expect(c1 == c2, "count at position \(i) must be identical across calls")
        }
    }

    // MARK: - 16. Multiple field coords per entry

    @Test("cross-product of field coords produces correct delta count")
    func crossProductDeltaCount() {
        let wm = HLC.zero
        let earlier = entry(0, [
            coord("field-a", "bitmap:1"),
            coord("field-b", "bitmap:2"),
        ])
        let newer = entry(60_000, [
            coord("field-c", "bitmap:3"),
            coord("field-d", "bitmap:4"),
        ])
        let result = TemporalCausalityFold.fold(
            entries: [earlier, newer],
            windowMinutes: 256,
            startWatermark: wm)
        // Cross-product: 2 sources × 2 targets = 4 pairs.
        #expect(result.deltas.count == 4, "2×2 cross-product must yield 4 unique keys")
        let allCounts = result.deltas.map { $0.1 }
        #expect(allCounts.allSatisfy { $0 == 1 })
    }

    // MARK: - 17. lagBucket function

    @Test("lagBucket is canonical and mirrors MatrixTier.lagBuckets")
    func lagBucketCanonical() {
        // The boundaries list must be exactly as specified in cookbook §6.4.
        #expect(TemporalCausalityFold.lagBuckets == [1, 2, 4, 8, 16, 32, 64, 128])
        // Spot-check a few values.
        #expect(TemporalCausalityFold.lagBucket(forMinutes: 1) == 1)
        #expect(TemporalCausalityFold.lagBucket(forMinutes: 128) == 128)
        #expect(TemporalCausalityFold.lagBucket(forMinutes: 129) == 128) // clamp
    }

    // MARK: - Helpers

    /// Run a fold with two entries separated by `separationMinutes` and
    /// return the first (and only expected) delta key and count.
    private func twoEntryFold(separationMinutes: Int) -> (TemporalCausalityKey, Int64) {
        let wm = HLC.zero
        let ms = Int64(separationMinutes) * 60_000
        let entries = [
            entry(0,  [coord("src", "bitmap:1")]),
            entry(ms, [coord("tgt", "bitmap:2")]),
        ]
        let result = TemporalCausalityFold.fold(
            entries: entries,
            windowMinutes: 256,
            startWatermark: wm)
        precondition(result.deltas.count == 1,
            "twoEntryFold helper expects exactly 1 delta; got \(result.deltas.count)")
        return result.deltas[0]
    }
}
