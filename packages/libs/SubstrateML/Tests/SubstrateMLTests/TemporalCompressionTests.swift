// TemporalCompressionTests.swift
//
// Hierarchical temporal compression per cookbook § 8.14. swift-testing
// peer suite for Sources/SubstrateML/TemporalCompression.swift.
//
// rust/src/temporal_compression.rs carries NO #[test], so this suite
// asserts the documented behavior set: compress OR-reduces a window's
// fingerprints, rollup is associative/commutative with min-start /
// max-end / summed-count bookkeeping, the empty window is the
// OR-reduction identity, and cascadeRollup buckets finer windows
// into coarser slots by physical time.

import Testing
import SubstrateTypes
@testable import SubstrateML

@Suite("TemporalCompression")
struct TemporalCompressionTests {

    private func hlc(_ tMillis: Int64) -> HLC { HLC(physicalTime: tMillis, logicalCount: 0, nodeID: 1) }
    private func fp(_ b0: UInt64, _ b1: UInt64 = 0, _ b2: UInt64 = 0, _ b3: UInt64 = 0) -> Fingerprint256 {
        Fingerprint256(block0: b0, block1: b1, block2: b2, block3: b3)
    }

    @Test("compressing no fingerprints yields a zero, empty window")
    func compressEmpty() {
        let w = TemporalCompression.compress(rows: [], startHLC: hlc(0), endHLC: hlc(100), level: .hour)
        #expect(w.fingerprint == Fingerprint256.zero)
        #expect(w.rowCount == 0)
        #expect(w.level == .hour)
    }

    @Test("compress OR-reduces the window's fingerprints and counts rows")
    func compressUnions() {
        let w = TemporalCompression.compress(
            rows: [fp(0xFF00), fp(0x00FF), fp(0, 0x1)],
            startHLC: hlc(0), endHLC: hlc(3600_000), level: .hour)
        #expect(w.fingerprint == fp(0xFFFF, 0x1))
        #expect(w.rowCount == 3)
        #expect(w.startHLC == hlc(0))
        #expect(w.endHLC == hlc(3600_000))
    }

    @Test("rolling up no windows yields the empty window for the target level")
    func rollupEmpty() {
        let w = TemporalCompression.rollup(windows: [], to: .day)
        #expect(w == TemporalWindow.empty(level: .day))
    }

    @Test("rollup unions fingerprints, sums counts, spans min-start to max-end")
    func rollupAggregates() {
        let w1 = TemporalCompression.compress(rows: [fp(0xF0)], startHLC: hlc(10), endHLC: hlc(20), level: .hour)
        let w2 = TemporalCompression.compress(rows: [fp(0x0F), fp(0x100)], startHLC: hlc(5), endHLC: hlc(40), level: .hour)
        let rolled = TemporalCompression.rollup(windows: [w1, w2], to: .day)
        #expect(rolled.fingerprint == fp(0x1FF))
        #expect(rolled.rowCount == 3)
        #expect(rolled.startHLC == hlc(5))   // min start
        #expect(rolled.endHLC == hlc(40))    // max end
        #expect(rolled.level == .day)
    }

    @Test("rollup is commutative under input permutation")
    func rollupCommutative() {
        let w1 = TemporalCompression.compress(rows: [fp(0xF0)], startHLC: hlc(10), endHLC: hlc(20), level: .hour)
        let w2 = TemporalCompression.compress(rows: [fp(0x0F)], startHLC: hlc(5), endHLC: hlc(40), level: .hour)
        let w3 = TemporalCompression.compress(rows: [fp(0, 0x1)], startHLC: hlc(50), endHLC: hlc(60), level: .hour)
        let a = TemporalCompression.rollup(windows: [w1, w2, w3], to: .day)
        let b = TemporalCompression.rollup(windows: [w3, w1, w2], to: .day)
        #expect(a == b)
    }

    @Test("cascadeRollup keeps the hour windows and buckets them into a day")
    func cascadeBucketsHoursIntoDay() {
        // Two hour windows within the same calendar day (HLC physical
        // milliseconds 0 and 3,600,000, both within day bucket 0).
        let h1 = TemporalCompression.compress(rows: [fp(0xF0)], startHLC: hlc(0), endHLC: hlc(3000), level: .hour)
        let h2 = TemporalCompression.compress(rows: [fp(0x0F)], startHLC: hlc(3600_000), endHLC: hlc(3700_000), level: .hour)
        let byLevel = TemporalCompression.cascadeRollup(hourWindows: [h1, h2], upTo: .day)
        #expect(byLevel[.hour]?.count == 2)
        let days = byLevel[.day] ?? []
        #expect(days.count == 1)                       // both hours fold into one day
        #expect(days.first?.fingerprint == fp(0xFF))
        #expect(days.first?.rowCount == 2)
    }
}
