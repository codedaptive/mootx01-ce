// TimingDerivationTests.swift — C3+A6 derivation engine (benchmark reset
// 2026-08-13). Synthetic-event tests; the Rust twin
// (timing_derivation.rs) carries the same five cases so the ports'
// pairing semantics cannot drift silently.

import Foundation
import Testing
@testable import NeuronKit

@Suite("TimingDerivation")
struct TimingDerivationTests {

    private func ev(_ verb: String, _ t: Int64, _ row: UUID, _ reason: String? = nil) -> TimingAuditEvent {
        TimingAuditEvent(verb: verb, physicalTimeMs: t, rowID: row, reason: reason)
    }

    private let r1 = UUID()
    private let r2 = UUID()
    private let estate = UUID()

    /// Single-row unit: exact INGEST sample, tier 2 == INGEST, watermark at
    /// the last event.
    @Test func singleRowUnitExactIngest() {
        let d = deriveTimings(events: [
            ev("capture", 1000, r1),
            ev("encodeComplete", 1040, r1, "session=s1 rows=1"),
        ], sinceExclusiveMs: 0)
        #expect(d.ingestExactMs == [40])
        #expect(d.cycleVectorMs == [40])
        #expect(d.ingestBulk.isEmpty)
        #expect(d.watermarkMs == 1040)
    }

    /// Bulk unit (rows>1): a throughput sample against the ANCHOR row's
    /// capture, never an exact per-row sample (M9/M10).
    @Test func bulkUnitIsThroughputNotExact() {
        let d = deriveTimings(events: [
            ev("capture", 1000, r1),
            ev("capture", 1001, r2),
            ev("encodeComplete", 1500, r1, "session=s1 rows=2"),
        ], sinceExclusiveMs: 0)
        #expect(d.ingestExactMs.isEmpty)
        #expect(d.ingestBulk.count == 1)
        #expect(d.ingestBulk[0].rows == 2)
        #expect(d.ingestBulk[0].wallMs == 500)
    }

    /// Tier 3/4 pair each capture with the FIRST estate marker at-or-after
    /// it; rows with none are counted unbounded (P1), never dropped.
    @Test func cycleTiersAndUnboundedCounts() {
        let d = deriveTimings(events: [
            ev("capture", 1000, r1),
            ev("reindexComplete", 1200, estate, "session=x rows=5"),
            ev("capture", 1300, r2),
            ev("dreamEnd", 1400, estate),
        ], sinceExclusiveMs: 0)
        #expect(d.cycleNovelMs == [200])
        #expect(d.cycleNovelUnbounded == 1)
        #expect(d.cycleDreamtMs == [100, 400])
        #expect(d.cycleDreamtUnbounded == 0)
    }

    /// Watermark: captures at or before it are NOT re-measured, but the
    /// window's markers still advance the returned watermark — the
    /// exactly-once contract across successive scans (A6).
    @Test func watermarkExcludesPriorCaptures() {
        let r0 = UUID()
        let d = deriveTimings(events: [
            ev("capture", 900, r0),
            ev("capture", 1100, r1),
            ev("encodeComplete", 1150, r0, "session=s rows=1"),
            ev("encodeComplete", 1160, r1, "session=s rows=1"),
        ], sinceExclusiveMs: 1000)
        #expect(d.ingestExactMs == [60])
        #expect(d.watermarkMs == 1160)
    }

    /// Same-millisecond marker pairs with delta 0 (in-memory estates are
    /// genuinely sub-millisecond), and a missing rows= field defaults to 1.
    @Test func sameMsPairsAndReasonDefault() {
        let d = deriveTimings(events: [
            ev("capture", 500, r1),
            ev("encodeComplete", 500, r1),
        ], sinceExclusiveMs: 0)
        #expect(d.ingestExactMs == [0])
        #expect(markerRows("session=abc rows=17") == 17)
        #expect(markerRows("session=abc") == nil)
        #expect(markerRows(nil) == nil)
    }
}
