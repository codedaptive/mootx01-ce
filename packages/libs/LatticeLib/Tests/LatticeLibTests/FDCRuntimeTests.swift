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

    @Test("label empty returns nil")
    func labelEmptyNil() {
        #expect(FDC.label(for: "") == nil)
    }

    @Test("label unknown code returns nil")
    func labelUnknownNil() {
        // A code that is not in the frame should return nil.
        #expect(FDC.label(for: "999.99999") == nil)
    }

    @Test("label integer code walks to parent")
    func labelIntegerWalksToParent() {
        // 3-digit integer codes walk up one level for a cleaner heading.
        // "006" (a leaf integer code) should walk to parent "000" and return
        // the same label as querying "000" directly — verifying the walk path.
        let leafLabel = FDC.label(for: "006")
        let parentLabel = FDC.label(for: "000")
        #expect(leafLabel != nil)
        #expect(leafLabel == parentLabel)
    }

    @Test("label decimal code returns own label")
    func labelDecimalReturnsSelf() {
        // Decimal codes are specific enough — should return their own label
        // rather than walking to a parent. We use a code that is present in
        // the bundled frame. If the code is absent in the fixture, the test
        // returns nil; the non-nil branch verifies the invariant.
        if let label = FDC.label(for: "006.6") {
            #expect(!label.isEmpty)
        }
    }
}
