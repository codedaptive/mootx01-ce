// RowAttributeViewTests.swift
//
// Tests for RowAttributeView and its RowAuditEntry factory.

import Foundation
import SubstrateTypes
import Testing
@testable import SubstrateML

// MARK: - Helpers

private func hlc(_ physical: Int64, _ logical: Int32 = 0) -> HLC {
    HLC(physicalTime: physical, logicalCount: logical, nodeID: 0)
}

private func entry(
    rowID: UUID = UUID(),
    tier: String = "locus",
    fieldPath: String,
    physical: Int64 = 1000,
    logical: Int32 = 0,
    value: RowAuditValue
) -> RowAuditEntry {
    RowAuditEntry(
        rowID: rowID,
        tier: tier,
        fieldPath: fieldPath,
        hlc: hlc(physical, logical),
        value: value
    )
}

/// Array-of-tuples equality helper. Swift arrays of tuples are not
/// Equatable (tuples cannot conform to protocols). Use this in
/// `#expect` to compare `(field, value)` lists without a helper struct.
private func attrsMatch(
    _ attrs: [(field: UInt8, value: UInt8)],
    _ expected: [(UInt8, UInt8)]
) -> Bool {
    guard attrs.count == expected.count else { return false }
    return zip(attrs, expected).allSatisfy { $0.field == $1.0 && $0.value == $1.1 }
}

// MARK: - Suite

@Suite("RowAttributeView")
struct RowAttributeViewTests {

    // MARK: Empty input

    @Test("empty entry list produces empty views")
    func emptyInput() {
        let views = RowAttributeView.from(auditEntries: [])
        #expect(views.isEmpty)
    }

    // MARK: Single row

    @Test("single bitmap entry produces one view")
    func singleBitmapEntry() {
        let id = UUID()
        let e = entry(rowID: id, fieldPath: "alpha", value: .bitmap(0b0101)) // bits 0, 2
        let views = RowAttributeView.from(auditEntries: [e])

        #expect(views.count == 1)
        let v = views[0]
        #expect(v.rowID == id)
        #expect(v.tier == "locus")
        // Bit 0 and bit 2 → values 0 and 2 on field 0 ("alpha" is only fieldPath)
        #expect(attrsMatch(v.attributes, [(0, 0), (0, 2)]))
    }

    @Test("single integer entry produces one view")
    func singleIntegerEntry() {
        let id = UUID()
        let e = entry(rowID: id, fieldPath: "beta", value: .integer(42))
        let views = RowAttributeView.from(auditEntries: [e])

        #expect(views.count == 1)
        let v = views[0]
        #expect(v.rowID == id)
        // field 0 ("beta"), value 42
        #expect(attrsMatch(v.attributes, [(0, 42)]))
    }

    @Test("null entry produces no attributes and view is dropped")
    func nullEntryDropped() {
        let e = entry(fieldPath: "gamma", value: .null)
        let views = RowAttributeView.from(auditEntries: [e])
        #expect(views.isEmpty)
    }

    // MARK: Bitmap bit extraction

    @Test("bitmap set-bit extraction matches expected items")
    func bitmapBitExtraction() {
        let id = UUID()
        // bitmap 0b10010001 → bits 0, 4, 7
        let e = entry(rowID: id, fieldPath: "flags", value: .bitmap(0b10010001))
        let views = RowAttributeView.from(auditEntries: [e])

        #expect(views.count == 1)
        // field 0 ("flags"), values 0, 4, 7 (bit positions in ascending order)
        #expect(attrsMatch(views[0].attributes, [(0, 0), (0, 4), (0, 7)]))
    }

    @Test("zero bitmap produces no attributes and view is dropped")
    func zeroBitmapDropped() {
        let e = entry(fieldPath: "empty", value: .bitmap(0))
        let views = RowAttributeView.from(auditEntries: [e])
        #expect(views.isEmpty)
    }

    // MARK: Non-bitmap field-values flow through

    @Test("integer value low-byte flows through")
    func integerLowByte() {
        let id = UUID()
        // Integer 0x1FF → low byte = 0xFF
        let e = entry(rowID: id, fieldPath: "status", value: .integer(0x1FF))
        let views = RowAttributeView.from(auditEntries: [e])

        #expect(views.count == 1)
        #expect(attrsMatch(views[0].attributes, [(0, 0xFF)]))
    }

    // MARK: Bundling by (tier, rowID)

    @Test("bundling groups by (tier, rowID) — different rowIDs produce separate views")
    func bundlingByRowID() {
        let id1 = UUID()
        let id2 = UUID()
        let entries = [
            entry(rowID: id1, fieldPath: "x", value: .integer(1)),
            entry(rowID: id2, fieldPath: "x", value: .integer(2)),
        ]
        let views = RowAttributeView.from(auditEntries: entries)
        #expect(views.count == 2)
        let rowIDs = Set(views.map { $0.rowID })
        #expect(rowIDs.contains(id1))
        #expect(rowIDs.contains(id2))
    }

    @Test("bundling groups by (tier, rowID) — different tiers produce separate views")
    func bundlingByTier() {
        let id = UUID()
        let entries = [
            entry(rowID: id, tier: "locus", fieldPath: "x", value: .integer(1)),
            entry(rowID: id, tier: "rag",   fieldPath: "x", value: .integer(2)),
        ]
        let views = RowAttributeView.from(auditEntries: entries)
        #expect(views.count == 2)
        let tiers = Set(views.map { $0.tier })
        #expect(tiers == ["locus", "rag"])
    }

    @Test("same (tier, rowID) merges into one view")
    func sameRowMerged() {
        let id = UUID()
        // Two fields for the same row
        let entries = [
            entry(rowID: id, fieldPath: "a", value: .integer(1)),
            entry(rowID: id, fieldPath: "b", value: .integer(2)),
        ]
        let views = RowAttributeView.from(auditEntries: entries)
        #expect(views.count == 1)
        // vocabulary: ["a", "b"] → field 0, 1
        #expect(attrsMatch(views[0].attributes, [(0, 1), (1, 2)]))
    }

    // MARK: Latest-HLC deduplication

    @Test("latest HLC entry wins per fieldPath")
    func latestHLCWins() {
        let id = UUID()
        let entries = [
            RowAuditEntry(rowID: id, tier: "locus", fieldPath: "x",
                          hlc: hlc(100), value: .integer(10)),
            RowAuditEntry(rowID: id, tier: "locus", fieldPath: "x",
                          hlc: hlc(200), value: .integer(20)), // newer wins
            RowAuditEntry(rowID: id, tier: "locus", fieldPath: "x",
                          hlc: hlc(150), value: .integer(15)),
        ]
        let views = RowAttributeView.from(auditEntries: entries)
        #expect(views.count == 1)
        // hlc(200) wins → value 20
        #expect(attrsMatch(views[0].attributes, [(0, 20)]))
    }

    // MARK: Vocabulary ordering

    @Test("fieldPath vocabulary is alphabetical — assigns lower indices to lexicographically earlier paths")
    func vocabularyOrdering() {
        let id = UUID()
        let entries = [
            entry(rowID: id, fieldPath: "zzz", value: .integer(3)),
            entry(rowID: id, fieldPath: "aaa", value: .integer(1)),
            entry(rowID: id, fieldPath: "mmm", value: .integer(2)),
        ]
        let views = RowAttributeView.from(auditEntries: entries)
        #expect(views.count == 1)
        // vocab: ["aaa"=0, "mmm"=1, "zzz"=2] → attrs (0,1), (1,2), (2,3)
        #expect(attrsMatch(views[0].attributes, [(0, 1), (1, 2), (2, 3)]))
    }

    // MARK: Output ordering

    @Test("output sorted by (tier, rowID) deterministically")
    func outputOrdering() {
        let idA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let idB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let entries = [
            entry(rowID: idB, tier: "locus", fieldPath: "x", value: .integer(2)),
            entry(rowID: idA, tier: "rag",   fieldPath: "x", value: .integer(4)),
            entry(rowID: idA, tier: "locus", fieldPath: "x", value: .integer(1)),
        ]
        let views = RowAttributeView.from(auditEntries: entries)
        #expect(views.count == 3)
        // Sort: tier "locus" < "rag"; within "locus", idA < idB
        #expect(views[0].rowID == idA && views[0].tier == "locus")
        #expect(views[1].rowID == idB && views[1].tier == "locus")
        #expect(views[2].rowID == idA && views[2].tier == "rag")
    }

    // MARK: Multiple fields + mixed types

    @Test("row with bitmap and integer fields produces combined attributes")
    func mixedFieldTypes() {
        let id = UUID()
        let entries = [
            entry(rowID: id, fieldPath: "flags",  value: .bitmap(0b0011)), // bits 0, 1
            entry(rowID: id, fieldPath: "status", value: .integer(7)),
        ]
        let views = RowAttributeView.from(auditEntries: entries)
        #expect(views.count == 1)
        // vocab: ["flags"=0, "status"=1]
        // flags → (0,0), (0,1); status → (1,7)
        #expect(attrsMatch(views[0].attributes, [(0, 0), (0, 1), (1, 7)]))
    }
}
