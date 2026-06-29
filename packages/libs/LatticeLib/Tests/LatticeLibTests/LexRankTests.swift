// LexRankTests.swift — FDC §7.2 article reduction (build-time, deterministic).

import Testing
@testable import LatticeLib

@Suite("LexRank (cookbook §7.2)")
struct LexRankTests {

    @Test("short text (<= n sentences) is returned unchanged")
    func shortPassthrough() {
        let t = "One sentence only here."
        #expect(LexRank.reduce(t, sentences: 10) == t)
    }

    @Test("central sentences (mutually similar) are selected over isolated ones")
    func selectsCentral() {
        // Two sentences share content ("cat") and reinforce each other's
        // centrality; the two unrelated singletons are isolated and rank low.
        let text = "The cat sat on the mat. Quantum chromodynamics is hard. "
                 + "The cat chased the mouse. Bananas are yellow."
        let r = LexRank.reduce(text, sentences: 2)
        #expect(r.contains("cat sat"))
        #expect(r.contains("cat chased"))
        #expect(!r.contains("Quantum"))
    }

    @Test("output preserves original sentence order")
    func preservesOrder() {
        let text = "The cat sat on the mat. Quantum chromodynamics is hard. "
                 + "The cat chased the mouse. Bananas are yellow."
        let r = LexRank.reduce(text, sentences: 2)
        #expect(r.range(of: "cat sat")!.lowerBound < r.range(of: "cat chased")!.lowerBound)
    }

    @Test("deterministic across runs")
    func deterministic() {
        let text = "Alpha beta gamma delta. Beta gamma delta epsilon. "
                 + "Zeta eta theta. Gamma delta beta alpha. Unrelated words here now."
        #expect(LexRank.reduce(text, sentences: 2) == LexRank.reduce(text, sentences: 2))
    }

    @Test("negative sentence count returns text unchanged (no trap)")
    func negativeNReturnsUnchanged() {
        // Before the guard fix, `.prefix(n)` with a negative n was undefined
        // behavior in Swift (Int subscript). The n >= 0 guard in reduce(_:sentences:)
        // now catches this and returns the original text.
        let text = "The cat sat on the mat. Quantum chromodynamics is hard."
        // n = -1 must not trap and must return the original text.
        #expect(LexRank.reduce(text, sentences: -1) == text)
        // n = Int.min is the extreme case.
        #expect(LexRank.reduce(text, sentences: Int.min) == text)
    }
}
