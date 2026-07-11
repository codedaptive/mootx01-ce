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

    @Test("weak Q-ID aliases do not become concept identity")
    func weakQIDAliasesStaySurfaceTerms() {
        let noisy = CanonicalizationLexicon(
            version: "t", language: "en",
            entries: [
                "a": "Q81454",
                "be": "Q569",
                "f": "Q417934",
                "file": "Q82753",
                "for": "Q8913",
                "git": "Q18596004",
                "key": "Q228039",
                "local": "Q1149297",
                "prune": "Q500094",
                "valu": "Q868257",
                "1": "Q420439"
            ]
        )

        let admitted = BagBuilder.bag(
            "a be f file for git key local prune value 1",
            lexicon: noisy,
            keep: [.noun, .verb, .other]
        )

        #expect(!admitted.keys.contains { $0.hasPrefix("Q") })
        #expect(admitted["git"] == 1)
        #expect(admitted["file"] == 1)
        #expect(admitted["valu"] == 1)

        let bypassOnly = BagBuilder.bag(
            "a be f file for git key local prune value 1",
            lexicon: noisy,
            keep: []
        )
        #expect(bypassOnly.isEmpty)
    }
}
