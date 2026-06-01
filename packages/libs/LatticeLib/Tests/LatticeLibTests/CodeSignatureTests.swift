// CodeSignatureTests.swift — FDC §7.1 merge + ancestor accumulation.

import Testing
@testable import LatticeLib

@Suite("SignatureAssembler (cookbook §7.1)")
struct CodeSignatureTests {

    @Test("source weights are applied per bag (label 3, title 2, article 1)")
    func weightedMerge() {
        let sig = SignatureAssembler.merge(
            label: ["Q1": 1], title: ["Q1": 1, "Q2": 1], article: ["Q2": 1]
        )
        #expect(sig["Q1"] == 3 + 2)   // label*3 + title*2
        #expect(sig["Q2"] == 2 + 1)   // title*2 + article*1
    }

    @Test("a code accumulates each ancestor's own terms once")
    func ancestorAccumulation() {
        let own: [String: [String: Int]] = [
            "0":      ["Qroot": 1],
            "006":    ["Qmid": 1],
            "006.6":  ["Qleaf": 1],
        ]
        // ancestors of 006.6 are 006 and 0
        let sigs = SignatureAssembler.accumulateAncestors(ownTerms: own) { code in
            code == "006.6" ? ["006", "0"] : (code == "006" ? ["0"] : [])
        }
        #expect(sigs["006.6"]?.terms == ["Qleaf": 1, "Qmid": 1, "Qroot": 1])
        #expect(sigs["006"]?.terms == ["Qmid": 1, "Qroot": 1])
        #expect(sigs["0"]?.terms == ["Qroot": 1])
    }
}
