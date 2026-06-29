// FormalContextFromRowAttributeViewTests.swift
//
// Tests for FormalContext.from(rowAttributeViews:).
//
// The factory maps each RowAttributeView's (field, value) pair to
// FormalAttribute(namespace:"row", key:String(field), value:String(value)).
// Round-trip semantics: attributes derived from known views must appear
// in the context's universe, and the extent / intent operators must
// correctly identify which rows share which attributes.

import Foundation
import Testing
@testable import SubstrateML

@Suite("FormalContext from RowAttributeView")
struct FormalContextFromRowAttributeViewTests {

    // MARK: - Helpers

    private func makeView(
        _ rowID: UUID,
        tier: String = "locus",
        attrs: [(field: UInt8, value: UInt8)]
    ) -> RowAttributeView {
        RowAttributeView(rowID: rowID, tier: tier, attributes: attrs)
    }

    private func fa(_ field: UInt8, _ value: UInt8) -> FormalAttribute {
        FormalAttribute(namespace: "row", key: String(field), value: String(value))
    }

    // MARK: - Edge cases

    @Test("empty views produce empty context")
    func emptyViewsProduceEmptyContext() {
        let ctx = FormalContext.from(rowAttributeViews: [])
        #expect(ctx.rowCount == 0)
        #expect(ctx.attributes.isEmpty)
    }

    @Test("view with no attributes contributes an empty row")
    func viewWithNoAttributesContributesEmptyRow() {
        let id = UUID()
        let view = RowAttributeView(rowID: id, tier: "locus", attributes: [])
        let ctx = FormalContext.from(rowAttributeViews: [view])
        // One row, no attributes, but the empty-intent extent is all rows.
        #expect(ctx.rowCount == 1)
        #expect(ctx.attributes.isEmpty)
        #expect(ctx.extent(of: []) == [0])
    }

    // MARK: - Round-trip correctness

    @Test("round-trip: two rows sharing one attribute form one concept")
    func roundTripTwoRowsSharedAttribute() {
        let id0 = UUID(), id1 = UUID(), id2 = UUID()
        // Input order is arbitrary; use predictable field/value pairs.
        let views = [
            makeView(id0, attrs: [(field: 0, value: 1), (field: 1, value: 2)]),
            makeView(id1, attrs: [(field: 0, value: 1), (field: 2, value: 3)]),
            makeView(id2, attrs: [(field: 2, value: 3)]),
        ]
        let ctx = FormalContext.from(rowAttributeViews: views)

        // Attribute (field:0, value:1) → FormalAttribute("row","0","1")
        let shared = fa(0, 1)
        let uniqueToRow2 = fa(2, 3)

        // shared attr appears in the universe.
        #expect(ctx.attributes.contains(shared))

        // Extent of [shared] is rows 0 and 1 (indices in the view array order).
        let extShared = ctx.extent(of: [shared])
        #expect(extShared.count == 2)
        #expect(extShared.contains(0))
        #expect(extShared.contains(1))

        // uniqueToRow2 appears in rows 1 and 2.
        let extUnique = ctx.extent(of: [uniqueToRow2])
        #expect(extUnique.count == 2)
        #expect(extUnique.contains(1))
        #expect(extUnique.contains(2))
    }

    @Test("attribute namespace is 'row', key is field string, value is value string")
    func attributeMappingConvention() {
        let id = UUID()
        let view = makeView(id, attrs: [(field: 7, value: 42)])
        let ctx = FormalContext.from(rowAttributeViews: [view])
        let expected = FormalAttribute(namespace: "row", key: "7", value: "42")
        #expect(ctx.attributes == [expected])
    }

    @Test("duplicate (field,value) within a view is collapsed to one attribute")
    func duplicateAttributeIsCollapsed() {
        // RowAttributeView.init sorts and deduplicates are not guaranteed,
        // but FormalContext.init deduplicates within a row.
        let id = UUID()
        let view = makeView(id, attrs: [(field: 1, value: 5), (field: 1, value: 5)])
        let ctx = FormalContext.from(rowAttributeViews: [view])
        // Universe has exactly one attribute despite the duplicate input.
        #expect(ctx.attributes.count == 1)
        #expect(ctx.attributes[0] == fa(1, 5))
    }

    // MARK: - Mining integration

    @Test("mining over RowAttributeView-derived context finds correct concepts")
    func miningOverRAVContext() {
        // Two cohorts in RowAttributeView form:
        //   Group A: field 0 value 1, field 1 value 2  — rows 0,1
        //   Group B: field 0 value 3, field 1 value 4  — rows 2,3
        let id0 = UUID(), id1 = UUID(), id2 = UUID(), id3 = UUID()
        let views = [
            makeView(id0, attrs: [(0,1),(1,2)]),
            makeView(id1, attrs: [(0,1),(1,2)]),
            makeView(id2, attrs: [(0,3),(1,4)]),
            makeView(id3, attrs: [(0,3),(1,4)]),
        ]
        let ctx = FormalContext.from(rowAttributeViews: views)
        let miner = BoundedConceptMiner(minSupport: 2, maxIntentSize: 8, maxConcepts: 8)
        let concepts = miner.mine(context: ctx)

        // Exactly two concepts: group A and group B, each support 2.
        #expect(concepts.count == 2)
        let intents = concepts.map { Set($0.intent) }
        let intentA = Set([fa(0,1), fa(1,2)])
        let intentB = Set([fa(0,3), fa(1,4)])
        #expect(intents.contains(intentA))
        #expect(intents.contains(intentB))
    }
}
