// FDCMatcherTests.swift — FDC runtime Steps 4–5 (cookbook §5–§6).

import Testing
@testable import LatticeLib

@Suite("FDCMatcher (cookbook §5–§6)")
struct FDCMatcherTests {

    private func matcher() -> FDCMatcher {
        let lexicon = CanonicalizationLexicon(
            version: "t", language: "en", entries: ["cat": "Q146", "dog": "Q144"]
        )
        let frame = FDCFrame(frameVersion: "t", codes: [
            FDCEntry(code: "100", label: "animals"),
            FDCEntry(code: "100.1", label: "cats"),
            FDCEntry(code: "200", label: "unrelated"),
        ])
        let signatures: [String: Set<String>] = [
            "100":   ["Q146", "Q144"],   // animals: cat + dog
            "100.1": ["Q146"],           // cats: cat
            "200":   ["Q999"],           // unrelated concept
        ]
        return FDCMatcher(lexicon: lexicon, frame: frame, signatures: signatures, stopThreshold: 1)
    }

    @Test("matches and descends to the most specific code")
    func descends() {
        // "cat" -> Q146; both 100 and 100.1 score; argmax tie -> "100";
        // descent finds child 100.1 overlapping -> returns the leaf.
        #expect(matcher().encode("cat cat") == "100.1")
    }

    @Test("no overlap -> UNRESOLVED (never guesses)")
    func unresolved() {
        #expect(matcher().encode("zzzqqq wwwvvv") == nil)
    }

    @Test("a top-level match with no qualifying child stays at the parent")
    func staysAtParent() {
        // "dog" -> Q144 is in 100 but not 100.1 -> no child overlap -> stop at 100.
        #expect(matcher().encode("dog dog") == "100")
    }

    @Test("deterministic")
    func deterministic() {
        let m = matcher()
        #expect(m.encode("cat dog") == m.encode("cat dog"))
    }
}
