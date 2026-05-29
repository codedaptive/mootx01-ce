// CollapseRuleTests.swift
//
// The collapse rule is the entire shape of MDCC — it decides which
// parent of a multi-parent Wikidata concept wins. Three tiers in
// order: pinned, lowest spine-class index, lexicographic minimum.

import Testing
@testable import LatticeKit

@Suite("Collapse rule")
struct CollapseRuleTests {

    private func makeResolver(_ map: [String: Int]) -> @Sendable (String) -> MDCCClass? {
        return { id in
            guard let base = map[id] else { return nil }
            return NotationSpine.owningClass(forBase: base)
        }
    }

    @Test("tier 1 — pinned parent wins")
    func pinnedWins() {
        let rule = CollapseRule(
            pins: PinnedParents(["Qchild": "Qpinned"]),
            resolver: makeResolver(["Qpinned": 500, "Qother": 100])
        )
        let pick = rule.selectParent(
            for: "Qchild",
            candidates: ["Qother", "Qpinned"],
            visited: []
        )
        #expect(pick == "Qpinned")
    }

    @Test("tier 2 — lowest class base wins")
    func lowestClassWins() {
        let rule = CollapseRule(
            pins: PinnedParents([:]),
            resolver: makeResolver(["Qhigh": 700, "Qlow": 100])
        )
        let pick = rule.selectParent(
            for: "Qchild",
            candidates: ["Qhigh", "Qlow"],
            visited: []
        )
        #expect(pick == "Qlow")
    }

    @Test("tier 3 — lexicographic minimum breaks remaining ties")
    func lexicographicBackstop() {
        // No resolver hits → falls through to tier 3.
        let rule = CollapseRule(
            pins: PinnedParents([:]),
            resolver: makeResolver([:])
        )
        let pick = rule.selectParent(
            for: "Qchild",
            candidates: ["QB", "QA", "QC"],
            visited: []
        )
        #expect(pick == "QA")
    }

    @Test("cycle: a candidate already in visited is dropped")
    func cycleDropped() {
        let rule = CollapseRule(
            pins: PinnedParents([:]),
            resolver: makeResolver([:])
        )
        let pick = rule.selectParent(
            for: "Qchild",
            candidates: ["Qcycle", "Qok"],
            visited: ["Qcycle"]
        )
        #expect(pick == "Qok")
    }

    @Test("cycle: all candidates cyclic returns nil")
    func allCyclic() {
        let rule = CollapseRule(
            pins: PinnedParents([:]),
            resolver: makeResolver([:])
        )
        let pick = rule.selectParent(
            for: "Qchild",
            candidates: ["Q1", "Q2"],
            visited: ["Q1", "Q2"]
        )
        #expect(pick == nil)
    }

    @Test("pinned parent dropped if it is a cycle")
    func pinnedCycleDropped() {
        let rule = CollapseRule(
            pins: PinnedParents(["Qchild": "Qpinned"]),
            resolver: makeResolver(["Qok": 100])
        )
        // Pinned candidate is in the visited set — falls through.
        let pick = rule.selectParent(
            for: "Qchild",
            candidates: ["Qpinned", "Qok"],
            visited: ["Qpinned"]
        )
        #expect(pick == "Qok")
    }
}
