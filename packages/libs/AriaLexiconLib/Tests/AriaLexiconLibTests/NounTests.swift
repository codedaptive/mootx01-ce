// NounTests.swift
//
// Per-type peer suite for `Noun` and its `NounRole`. Mirrors the Rust
// `drawer_is_primary` and `non_drawer_shapes_have_roles` #[test] functions and
// adds the type-local surface the combined conformance suite does not assert:
// the shape count, the full per-case role mapping, the role partition, the
// `NounRole` category set, and rawValue identity (the enums are `String`-backed
// and `Codable`, so their wire identity is part of the contract).

import Testing
@testable import AriaLexiconLib

@Suite("Noun")
struct NounTests {

    @Test("There are exactly eight storage shapes, drawer first")
    func shapeCount() {
        #expect(Noun.allCases.count == 8)
        #expect(Noun.allCases.first == .drawer)
    }

    @Test("The drawer is the one noun of the language")
    func drawerIsPrimary() {
        #expect(Noun.primary == .drawer)
        #expect(Noun.drawer.role == .primary)
        #expect(Noun.allCases.filter { $0.role == .primary } == [.drawer])
    }

    @Test("Every non-drawer shape is a rung, structure, or product")
    func nonDrawerShapesHaveRoles() {
        #expect(Noun.kgFact.role == .rung)
        #expect(Noun.vector.role == .rung)
        #expect(Noun.tunnel.role == .structure)
        #expect(Noun.diaryEntry.role == .structure)
        #expect(Noun.association.role == .structure)
        #expect(Noun.proposal.role == .product)
        #expect(Noun.learnedReference.role == .product)
    }

    @Test("The four roles partition the eight shapes 1/2/3/2")
    func rolePartition() {
        let byRole = Dictionary(grouping: Noun.allCases, by: { $0.role })
        #expect(byRole[.primary]?.count == 1)
        #expect(byRole[.rung]?.count == 2)
        #expect(byRole[.structure]?.count == 3)
        #expect(byRole[.product]?.count == 2)
        let total = NounRole.allCases.reduce(0) { $0 + (byRole[$1]?.count ?? 0) }
        #expect(total == Noun.allCases.count)
    }

    @Test("There are four noun roles")
    func roleCategoryCount() {
        #expect(NounRole.allCases.count == 4)
    }

    @Test("Noun raw values are stable and round-trip")
    func rawValueIdentity() {
        #expect(Noun.drawer.rawValue == "drawer")
        #expect(Noun.kgFact.rawValue == "kgFact")
        #expect(Noun.learnedReference.rawValue == "learnedReference")
        for noun in Noun.allCases {
            #expect(Noun(rawValue: noun.rawValue) == noun)
        }
    }
}
