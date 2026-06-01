// AuditEventTests.swift
//
// Per-type suite for AuditEvent (a single audit row, cookbook §5.1).
// The Rust `audit_event.rs` module carries no inline tests; this suite
// asserts the contract from source: auto-generated unique eventID,
// field storage, and the optional before-state (nil at capture).

import Foundation
import Testing
@testable import SubstrateTypes

@Suite("AuditEvent row")
struct AuditEventTests {

    private func makeEvent(before: (adjective: Int64, operational: Int64, provenance: Int64)?,
                           eventID: UUID? = nil) -> AuditEvent {
        let after = (adjective: Int64(1), operational: Int64(2), provenance: Int64(3))
        if let eventID {
            return AuditEvent(eventID: eventID,
                              estateUuid: UUID(), rowId: UUID(),
                              hlc: HLC(physicalTime: 1000, logicalCount: 0, nodeID: 1),
                              verb: "capture",
                              beforeBitmaps: before, afterBitmaps: after,
                              beforeLatticeAnchor: nil,
                              afterLatticeAnchor: LatticeAnchor(udcCode: 42),
                              actor: "capture")
        }
        return AuditEvent(estateUuid: UUID(), rowId: UUID(),
                          hlc: HLC(physicalTime: 1000, logicalCount: 0, nodeID: 1),
                          verb: "capture",
                          beforeBitmaps: before, afterBitmaps: after,
                          beforeLatticeAnchor: nil,
                          afterLatticeAnchor: LatticeAnchor(udcCode: 42),
                          actor: "capture")
    }

    @Test("eventID defaults to a freshly generated, unique UUID")
    func eventIDDefaultsUnique() {
        let a = makeEvent(before: nil)
        let b = makeEvent(before: nil)
        #expect(a.eventID != b.eventID)
    }

    @Test("an explicit eventID is preserved")
    func explicitEventIDPreserved() {
        let id = UUID()
        #expect(makeEvent(before: nil, eventID: id).eventID == id)
    }

    @Test("capture has no before-bitmaps; the after-state is stored")
    func captureHasNoBefore() {
        let e = makeEvent(before: nil)
        #expect(e.beforeBitmaps == nil)
        #expect(e.afterBitmaps.adjective == 1)
        #expect(e.afterBitmaps.operational == 2)
        #expect(e.afterBitmaps.provenance == 3)
        #expect(e.verb == "capture")
        #expect(e.actor == "capture")
        #expect(e.afterLatticeAnchor.udcCode == 42)
        #expect(e.beforeLatticeAnchor == nil)
    }

    @Test("a mutate carries the before-bitmaps")
    func mutateCarriesBefore() {
        let e = makeEvent(before: (adjective: 9, operational: 8, provenance: 7))
        let before = try! #require(e.beforeBitmaps)
        #expect(before.adjective == 9)
        #expect(before.operational == 8)
        #expect(before.provenance == 7)
    }
}
