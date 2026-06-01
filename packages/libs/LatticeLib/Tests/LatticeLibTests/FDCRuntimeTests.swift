// FDCRuntimeTests.swift — the bundled FDC engine encodes real text end-to-end.

import Testing
@testable import LatticeLib

@Suite("FDC runtime (bundled artifacts)")
struct FDCRuntimeTests {

    @Test("bundled artifacts load")
    func available() {
        #expect(FDC.isAvailable)
    }

    @Test("encodes topical text to a frame code")
    func encodesTopical() {
        // Should resolve to *some* FDC code (not UNRESOLVED) for clearly
        // topical input that overlaps the signatures.
        let code = FDC.encode("computer software programming and information science")
        #expect(code != nil)
        // A returned code is a non-empty decimal string from the frame.
        if let c = code { #expect(!c.isEmpty) }
    }

    @Test("gibberish is UNRESOLVED (never guesses)")
    func gibberishUnresolved() {
        #expect(FDC.encode("zzqqxv wwkkjj plldfg") == nil)
    }

    @Test("deterministic")
    func deterministic() {
        #expect(FDC.encode("chemistry and physics") == FDC.encode("chemistry and physics"))
    }
}
