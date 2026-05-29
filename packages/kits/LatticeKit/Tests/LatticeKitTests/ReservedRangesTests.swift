// ReservedRangesTests.swift
//
// Reserved ranges are design input to v1 and cannot be retrofitted.
// These tests pin the v1 layout so the assembler, the canon, and any
// downstream consumer see a stable reservation table.

import Testing
@testable import LatticeKit

@Suite("Reserved ranges")
struct ReservedRangesTests {

    @Test("each spine class has a community and an annex reservation")
    func twoPerClass() {
        let count = ReservedRanges.table.count
        #expect(count == NotationSpine.classes.count * 2)
    }

    @Test("community range spans NN80-NN99 per class")
    func communityShape() {
        let firstCommunity = ReservedRanges.table.first { $0.kind == .community }
        #expect(firstCommunity?.lowerBound == 80)
        #expect(firstCommunity?.upperBound == 99)

        let science = ReservedRanges.table.first {
            $0.lowerBound == 580 && $0.kind == .community
        }
        #expect(science?.upperBound == 599)
    }

    @Test("annex range spans NN90-NN99 per class")
    func annexShape() {
        let firstAnnex = ReservedRanges.table.first { $0.kind == .annex }
        #expect(firstAnnex?.lowerBound == 90)
        #expect(firstAnnex?.upperBound == 99)
    }

    @Test("reservation(for:) returns the nested annex when both match")
    func annexNestedInsideCommunity() {
        let res = ReservedRanges.reservation(for: "595")
        #expect(res?.kind == .annex)
    }

    @Test("reservation(for:) returns community for a non-annex reserved code")
    func communityWhenNotAnnex() {
        let res = ReservedRanges.reservation(for: "585")
        #expect(res?.kind == .community)
    }

    @Test("isReserved is false for the unreserved part of a class")
    func unreserved() {
        #expect(ReservedRanges.isReserved("500") == false)
        #expect(ReservedRanges.isReserved("540") == false)
        #expect(ReservedRanges.isReserved("579") == false)
    }

    @Test("isReserved is true at the boundary")
    func boundary() {
        #expect(ReservedRanges.isReserved("580") == true)
        #expect(ReservedRanges.isReserved("599") == true)
    }

    @Test("reservation matches independent of decimal extension")
    func decimalExtension() {
        #expect(ReservedRanges.isReserved("585.123") == true)
        #expect(ReservedRanges.isReserved("579.999") == false)
    }
}
