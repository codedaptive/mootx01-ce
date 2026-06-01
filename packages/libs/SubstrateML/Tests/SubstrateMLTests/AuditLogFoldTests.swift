// AuditLogFoldTests.swift
//
// Audit-log fold per cookbook § 5.3 / § 8.15. swift-testing peer
// suite for Sources/SubstrateML/AuditLogFold.swift.
//
// rust/src/audit_log_fold.rs carries NO #[test], so this suite
// asserts the behavior set the file documents in its Properties
// section directly: determinism (events sorted internally, arrival
// order irrelevant), commutativity, as-of truncation, last-writer
// projection, and tombstone-stickiness (I-22).

import Foundation
import Testing
import SubstrateTypes
@testable import SubstrateML

@Suite("AuditLogFold")
struct AuditLogFoldTests {

    private let estate = UUID()

    private func hlc(_ t: Int64) -> HLC { HLC(physicalTime: t, logicalCount: 0, nodeID: 1) }

    /// Build an audit event whose low-6-bit row-state derives from
    /// `adjective`. Tombstone state is raw 33 per the fold.
    private func event(row: UUID, t: Int64,
                       adjective: Int64, operational: Int64 = 0, provenance: Int64 = 0,
                       udc: UInt64 = 1) -> AuditEvent {
        AuditEvent(
            estateUuid: estate, rowId: row, hlc: hlc(t), verb: "mutate",
            beforeBitmaps: nil,
            afterBitmaps: (adjective: adjective, operational: operational, provenance: provenance),
            beforeLatticeAnchor: nil,
            afterLatticeAnchor: LatticeAnchor(udcCode: udc),
            actor: "capture")
    }

    @Test("a row with no events projects to nil")
    func noEventsIsNil() {
        let proj = AuditLogFold.projectCurrentState(rowId: UUID(), nounType: .drawer, events: [])
        #expect(proj == nil)
    }

    @Test("events for other rows are ignored")
    func otherRowsIgnored() {
        let r = UUID()
        let other = UUID()
        let events = [event(row: other, t: 10, adjective: 5)]
        #expect(AuditLogFold.projectCurrentState(rowId: r, nounType: .drawer, events: events) == nil)
    }

    @Test("a single event projects its after-state")
    func singleEvent() {
        let r = UUID()
        let proj = AuditLogFold.projectCurrentState(
            rowId: r, nounType: .drawer,
            events: [event(row: r, t: 10, adjective: 5, operational: 7, provenance: 9, udc: 42)])
        #expect(proj != nil)
        #expect(proj?.adjectiveBitmap == 5)
        #expect(proj?.operationalBitmap == 7)
        #expect(proj?.provenanceBitmap == 9)
        #expect(proj?.stateRaw == 5)
        #expect(proj?.tombstoned == false)
        #expect(proj?.lastEventHLC == hlc(10))
        #expect(proj?.latticeAnchor == LatticeAnchor(udcCode: 42))
    }

    @Test("the projection reflects the last event by HLC (last-writer)")
    func lastWriterWins() {
        let r = UUID()
        let events = [
            event(row: r, t: 10, adjective: 1),
            event(row: r, t: 30, adjective: 3, udc: 99),
            event(row: r, t: 20, adjective: 2),
        ]
        let proj = AuditLogFold.projectCurrentState(rowId: r, nounType: .drawer, events: events)
        #expect(proj?.adjectiveBitmap == 3)
        #expect(proj?.lastEventHLC == hlc(30))
        #expect(proj?.latticeAnchor == LatticeAnchor(udcCode: 99))
    }

    @Test("the fold is deterministic regardless of arrival order")
    func deterministicUnderPermutation() {
        let r = UUID()
        let e1 = event(row: r, t: 10, adjective: 1)
        let e2 = event(row: r, t: 20, adjective: 2)
        let e3 = event(row: r, t: 30, adjective: 3)
        let a = AuditLogFold.projectCurrentState(rowId: r, nounType: .drawer, events: [e1, e2, e3])
        let b = AuditLogFold.projectCurrentState(rowId: r, nounType: .drawer, events: [e3, e1, e2])
        #expect(a == b)
    }

    @Test("as-of projection excludes events later than the cutoff")
    func asOfTruncation() {
        let r = UUID()
        let events = [
            event(row: r, t: 10, adjective: 1),
            event(row: r, t: 20, adjective: 2),
            event(row: r, t: 30, adjective: 3),
        ]
        let at20 = AuditLogFold.projectStateAt(rowId: r, nounType: .drawer, events: events, asOf: hlc(20))
        #expect(at20?.adjectiveBitmap == 2)
        #expect(at20?.lastEventHLC == hlc(20))
        // As-of before the first event yields nil (row not yet captured).
        let at5 = AuditLogFold.projectStateAt(rowId: r, nounType: .drawer, events: events, asOf: hlc(5))
        #expect(at5 == nil)
    }

    @Test("tombstone is sticky once observed (I-22)")
    func tombstoneSticky() {
        let r = UUID()
        // Event at t=20 sets row-state raw 33 (tombstone); a later
        // (illegal-revive) event sets a non-tombstone state. The
        // projection must still record tombstoned == true.
        let events = [
            event(row: r, t: 10, adjective: 5),
            event(row: r, t: 20, adjective: 33),
            event(row: r, t: 30, adjective: 7),
        ]
        let proj = AuditLogFold.projectCurrentState(rowId: r, nounType: .drawer, events: events)
        #expect(proj?.tombstoned == true)
        #expect(proj?.stateRaw == 7) // current state reflects last event…
    }

    @Test("projectAll groups events by row")
    func projectAllGroupsByRow() {
        let r1 = UUID()
        let r2 = UUID()
        let events = [
            event(row: r1, t: 10, adjective: 1),
            event(row: r2, t: 15, adjective: 2),
            event(row: r1, t: 20, adjective: 3),
        ]
        let all = AuditLogFold.projectAll(events: events, nounTypeFor: { _ in .drawer })
        #expect(all.count == 2)
        #expect(all[r1]?.adjectiveBitmap == 3)
        #expect(all[r2]?.adjectiveBitmap == 2)
    }
}
