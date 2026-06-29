// ConceptBagTests.swift
//
// Drives BagBuilder Steps 2–3 (canonicalize + accumulate) deterministically.
// Step 1 (word-class filter via the deterministic HMM tagger) is exercised
// separately by WordClassTaggerTests; these tests keep all word classes to
// isolate Steps 2–3 from tagger behavior.

import Testing
@testable import LatticeLib

@Suite("BagBuilder (cookbook §2–§4)")
struct ConceptBagTests {
    private let lexicon = CanonicalizationLexicon(
        version: "t", language: "en",
        entries: ["cat": "Q146", "dog": "Q144"]
    )

    @Test("lexicon hits map to conceptIDs and counts accumulate")
    func hitsAccumulate() {
        let bag = BagBuilder.bag("cat cat dog", lexicon: lexicon, keep: [.noun, .verb, .other])
        #expect(bag["Q146"] == 2)
        #expect(bag["Q144"] == 1)
    }

    @Test("a lexicon miss keeps the stemmed surface form as its own key")
    func missKeepsSurface() {
        let bag = BagBuilder.bag("zxcvbnm", lexicon: lexicon, keep: [.noun, .verb, .other])
        #expect(bag["zxcvbnm"] == 1)   // not in lexicon -> surface key
        #expect(bag["Q146"] == nil)
    }

    @Test("empty text yields an empty bag")
    func emptyText() {
        #expect(BagBuilder.bag("", lexicon: lexicon, keep: [.noun, .verb, .other]).isEmpty)
    }

    @Test("a Q-ID concept is kept even when no word class is admitted (§3.2 relaxation)")
    func qidOverridesPOS() {
        // keep: [] -> the POS path admits nothing; only the lexicon-Q-ID path can.
        let bag = BagBuilder.bag("cat zxcvbnm", lexicon: lexicon, keep: [])
        #expect(bag["Q146"] == 1)     // "cat" -> Q146 admitted via the Q-ID override
        #expect(bag["zxcvbnm"] == nil) // not noun/verb-kept and not a Q-ID -> dropped
    }
}
