// RowTests.swift
//
// Per-type suite for Row (a substrate row at its current state,
// cookbook §2.1) and the RowId typealias. The Rust `row.rs` module
// carries no inline tests; this suite asserts the contract from source:
// field storage, the RowId == UUID lockstep contract, and the optional
// lineage/content defaults.

import Foundation
import Testing
@testable import SubstrateTypes

@Suite("Row substrate row")
struct RowTests {

    private func makeRow(lineageId: UUID? = nil, content: Data? = nil) -> Row {
        Row(id: UUID(), nounType: .drawer, state: .active,
            adjectiveBitmap: 0x11, operationalBitmap: 0x22, provenanceBitmap: 0x33,
            fingerprint: Fingerprint256(block0: 1, block1: 2, block2: 3, block3: 4),
            latticeAnchor: LatticeAnchor(udcCode: 99),
            lineageId: lineageId, content: content)
    }

    @Test("RowId is a UUID typealias (16-byte wire-identical newtype)")
    func rowIdIsUUID() {
        let id: RowId = UUID()
        #expect(MemoryLayout.size(ofValue: id) == 16)
    }

    @Test("a row stores its fields verbatim")
    func storesFields() {
        let r = makeRow()
        #expect(r.nounType == .drawer)
        #expect(r.state == .active)
        #expect(r.adjectiveBitmap == 0x11)
        #expect(r.operationalBitmap == 0x22)
        #expect(r.provenanceBitmap == 0x33)
        #expect(r.fingerprint.block3 == 4)
        #expect(r.latticeAnchor.udcCode == 99)
    }

    @Test("lineageId and content default to nil")
    func lineageAndContentDefaultNil() {
        let r = makeRow()
        #expect(r.lineageId == nil)
        #expect(r.content == nil)
    }

    @Test("lineageId and content are stored when supplied")
    func lineageAndContentStored() {
        let lineage = UUID()
        let payload = Data([1, 2, 3])
        let r = makeRow(lineageId: lineage, content: payload)
        #expect(r.lineageId == lineage)
        #expect(r.content == payload)
    }

    @Test("row state is mutable in place (value semantics)")
    func stateIsMutable() {
        var r = makeRow()
        r.state = .superseded
        #expect(r.state == .superseded)
    }
}
