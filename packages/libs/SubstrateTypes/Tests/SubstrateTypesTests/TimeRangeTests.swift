// TimeRangeTests.swift
//
// Per-type suite for TimeRange (closed HLC interval [start, end]).
// The Rust `time_range.rs` module carries no inline tests; this suite
// asserts the contract from source: inclusive containment at both
// boundaries and exclusion outside the interval.

import Testing
@testable import SubstrateTypes

@Suite("TimeRange closed HLC interval")
struct TimeRangeTests {

    private func hlc(_ t: Int64) -> HLC {
        HLC(physicalTime: t, logicalCount: 0, nodeID: 0)
    }

    @Test("contains is inclusive at both endpoints")
    func containsInclusiveEndpoints() {
        let r = TimeRange(start: hlc(100), end: hlc(200))
        #expect(r.contains(hlc(100)))   // start, inclusive
        #expect(r.contains(hlc(200)))   // end, inclusive
        #expect(r.contains(hlc(150)))   // interior
    }

    @Test("contains excludes points outside the interval")
    func excludesOutside() {
        let r = TimeRange(start: hlc(100), end: hlc(200))
        #expect(!r.contains(hlc(99)))
        #expect(!r.contains(hlc(201)))
    }

    @Test("a degenerate range [t, t] contains exactly t")
    func degenerateRange() {
        let r = TimeRange(start: hlc(100), end: hlc(100))
        #expect(r.contains(hlc(100)))
        #expect(!r.contains(hlc(101)))
        #expect(!r.contains(hlc(99)))
    }

    @Test("containment respects the full HLC ordering, not just physical time")
    func respectsLogicalComponent() {
        let start = HLC(physicalTime: 100, logicalCount: 5, nodeID: 0)
        let end = HLC(physicalTime: 100, logicalCount: 9, nodeID: 0)
        let r = TimeRange(start: start, end: end)
        #expect(r.contains(HLC(physicalTime: 100, logicalCount: 7, nodeID: 0)))
        #expect(!r.contains(HLC(physicalTime: 100, logicalCount: 4, nodeID: 0)))
    }
}
