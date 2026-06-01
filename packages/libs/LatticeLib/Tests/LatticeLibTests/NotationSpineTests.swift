// NotationSpineTests.swift
//
// The top-of-tree spine is editorial input: the structure of MDCC.
// These tests pin the shape of v1 so accidental edits to NotationSpine.swift
// surface as test failures rather than silent canon shifts.

import Testing
@testable import LatticeLib

@Suite("Notation spine")
struct NotationSpineTests {

    @Test("v1 spine has exactly ten classes")
    func tenClasses() {
        #expect(NotationSpine.classes.count == 10)
    }

    @Test("class bases are 000, 100, ... 900 in order")
    func basesInOrder() {
        let bases = NotationSpine.classes.map(\.base)
        #expect(bases == [0, 100, 200, 300, 400, 500, 600, 700, 800, 900])
    }

    @Test("renderedBase produces three-digit form")
    func rendering() {
        #expect(NotationSpine.classes[0].renderedBase == "000")
        #expect(NotationSpine.classes[1].renderedBase == "100")
        #expect(NotationSpine.classes[9].renderedBase == "900")
    }

    @Test("owningClass(forBase:) maps integer base to class")
    func ownershipByBase() {
        let cls = NotationSpine.owningClass(forBase: 500)
        #expect(cls?.name == "Natural sciences and mathematics")
    }

    @Test("owningClass(for:) parses a code and finds the class")
    func ownershipByCode() {
        #expect(NotationSpine.owningClass(for: "540.137")?.base == 500)
        #expect(NotationSpine.owningClass(for: "000")?.base == 0)
        #expect(NotationSpine.owningClass(for: "999")?.base == 900)
    }

    @Test("owningClass(for:) rejects malformed codes")
    func malformedRejected() {
        #expect(NotationSpine.owningClass(for: "abc") == nil)
        #expect(NotationSpine.owningClass(for: "1000") == nil)
    }
}
