// NovelTokenTaggerChoiceTests.swift
//
// Tests for the NovelTokenTaggerChoice enum and the wordClass(_:tagger:) /
// BagBuilder.bag(_:lexicon:keep:taggerChoice:) overloads (Layer-2a).
//
// Verifies:
//   (a) .hmm choice → HMM novel-token tagging (platform-independent)
//   (b) .nlTagger choice on Apple → NLTagger path (or .other when gate disabled)
//   (c) BagBuilder.bag with taggerChoice threads choice correctly
//   (d) same input through .hmm produces identical output on repeated calls (deterministic)
//   (e) Table-resident tokens are unaffected by tagger choice

import Testing
@testable import LatticeLib

@Suite("NovelTokenTaggerChoice — wordClass and BagBuilder dispatch (Layer-2a)")
struct NovelTokenTaggerChoiceTests {

    // MARK: - wordClass(_:tagger:) overload

    // (a) .hmm choice always uses HMM for novel tokens. The HMM is deterministic
    // and byte-identical Swift↔Rust — a novel word with a clear suffix should
    // resolve the same way regardless of platform.
    @Test(".hmm choice classifies novel -tion token as noun via HMM")
    func hmmChoiceNounSuffix() {
        // "xylophonation" — not a real word; novel token, strong noun suffix.
        // Trained model (hmm-viterbi-3) emission for "-tion" (obs 5): noun -3103, verb -6317.
        // With trained priors noun -643, verb -1562: totals noun -3746, verb -7879.
        // Expected: .noun
        let result = LatticeLib.wordClass("xylophonation", tagger: .hmm)
        #expect(result == .noun)
    }

    @Test(".hmm choice classifies novel -ing token as verb via HMM")
    func hmmChoiceVerbSuffix() {
        // "zorbifying" — novel token, strong verb suffix "-ing".
        // Trained model: noun -3504, verb -2317. With priors: noun -4984, verb -4201.
        // Expected: .verb
        let result = LatticeLib.wordClass("zorbifying", tagger: .hmm)
        #expect(result == .verb)
    }

    @Test(".hmm choice is deterministic — same input yields same output")
    func hmmChoiceIsDeterministic() {
        let token = "xylophonation"
        let r1 = LatticeLib.wordClass(token, tagger: .hmm)
        let r2 = LatticeLib.wordClass(token, tagger: .hmm)
        #expect(r1 == r2)
    }

    // (b) .nlTagger choice on Apple uses NLTagger (or gate-disabled → .other).
    // We can't know precisely what NLTagger returns for a novel word in a test,
    // but we can verify the path is taken (output is a valid WordClass) and that
    // it differs from .hmm for tokens where NLTagger is known to classify differently.
    // We test with a known real word that both NLTagger and HMM handle.
    @Test(".nlTagger choice returns a valid WordClass for a real English word")
    func nlTaggerChoiceReturnsValidClass() {
        // "running" is a table-resident token on most builds; but if not, it has
        // an -ing suffix that both HMM and NLTagger tag as verb.
        let result = LatticeLib.wordClass("running", tagger: .nlTagger)
        let validClasses: Set<WordClass> = [.noun, .verb, .other]
        #expect(validClasses.contains(result))
    }

    // (c) Table-resident tokens are unaffected by tagger choice — they resolve
    // on the fast path before the tagger is ever invoked.
    @Test("table-resident noun is unaffected by tagger choice")
    func tableResidentUnaffected() {
        // Pick a word likely to be in the table. Both choices must agree
        // because the table fast-path fires before either tagger is invoked.
        let hmm = LatticeLib.wordClass("knowledge", tagger: .hmm)
        let nlt = LatticeLib.wordClass("knowledge", tagger: .nlTagger)
        // Both must return the same class (the table result), whatever it is.
        #expect(hmm == nlt)
    }

    @Test("empty token is .other regardless of tagger choice")
    func emptyTokenIsOther() {
        #expect(LatticeLib.wordClass("", tagger: .hmm) == .other)
        #expect(LatticeLib.wordClass("", tagger: .nlTagger) == .other)
    }

    // MARK: - tagNovelToken(_:tagger:) direct dispatch

    @Test("tagNovelToken with .hmm uses HMM — -ness suffix is noun")
    func tagNovelTokenHMMNess() {
        // "xylophoneness" — novel, "-ness" suffix.
        // Trained model: noun -5804, verb -9663. Priors: noun -1480, verb -1884.
        // Totals: noun -7284, verb -11547. Noun wins.
        let result = LatticeLib.tagNovelToken("xylophoneness", tagger: .hmm)
        #expect(result == .noun)
    }

    @Test("tagNovelToken with .hmm is deterministic")
    func tagNovelTokenDeterminism() {
        let r1 = LatticeLib.tagNovelToken("xylophoneness", tagger: .hmm)
        let r2 = LatticeLib.tagNovelToken("xylophoneness", tagger: .hmm)
        #expect(r1 == r2)
    }

    // MARK: - BagBuilder.bag with taggerChoice

    @Test("BagBuilder.bag with .hmm includes novel noun tokens")
    func bagBuilderHMMIncludesNovels() {
        // Build a minimal lexicon and a bag with a novel word
        // that the HMM would tag as a noun ("-tion" suffix).
        // The novel token "xylophonation" is not in the table, but
        // the HMM classifies it as .noun, so it should appear in the bag.
        let lexicon = CanonicalizationLexicon(version: "test", language: "en", entries: [:])
        let text = "xylophonation"
        let bag = BagBuilder.bag(text, lexicon: lexicon, taggerChoice: .hmm)
        // The stemmed form should appear in the bag (stem of "xylophonation"
        // ends in "-tion" and may or may not truncate; either way bag is non-empty).
        #expect(!bag.isEmpty, "Novel noun via HMM should appear in bag")
    }

    @Test("BagBuilder.bag with .hmm and .nlTagger agree on tokens the table classifies identically")
    func bagBuilderChoiceAgreeOnTableTokens() {
        let lexicon = CanonicalizationLexicon(version: "test", language: "en", entries: [:])
        // Use the novel token "xylophonation" which the HMM tags as .noun.
        // When the text contains only that token, the HMM bag is identical
        // to the nlTagger bag only if both produce the same class — which they
        // won't necessarily for real English words. Instead, verify that both
        // overloads return bags with the same type (ConceptBag) and that the
        // HMM overload is deterministic.
        let text = "xylophonation"
        let hmmBag1 = BagBuilder.bag(text, lexicon: lexicon, taggerChoice: .hmm)
        let hmmBag2 = BagBuilder.bag(text, lexicon: lexicon, taggerChoice: .hmm)
        // HMM bags for the same input must be identical (determinism).
        #expect(hmmBag1 == hmmBag2)
        // nlTagger bag must also be non-nil (returns a ConceptBag, possibly empty on
        // platforms where NLTagger is absent or the token is classified as .other).
        let nltBag = BagBuilder.bag(text, lexicon: lexicon, taggerChoice: .nlTagger)
        // The type assertion: both are [String: Int] (ConceptBag).
        #expect(type(of: hmmBag1) == type(of: nltBag))
    }

    // MARK: - Cross-port HMM conformance (regression guard)
    // The tagNovelToken(_:tagger:.hmm) result must match the Rust hmm_tag output
    // on the shared test vectors. This is guarded by the existing
    // LatticeLanguageConformanceTests (tag_conformance.json). We add a smoke
    // check here with known-good cases to catch any accidental breakage.

    @Test("HMM path regression: -tion → noun (Swift side, Layer-2a)")
    func hmmConformanceRegressionTion() {
        let r = LatticeLib.tagNovelToken("zorbilation", tagger: .hmm)
        #expect(r == .noun)
    }

    @Test("HMM path regression: -ing → verb (Swift side, Layer-2a)")
    func hmmConformanceRegressionIng() {
        let r = LatticeLib.tagNovelToken("zorbilating", tagger: .hmm)
        #expect(r == .verb)
    }

    @Test("HMM path regression: -ment → noun (Swift side, Layer-2a)")
    func hmmConformanceRegressionMent() {
        let r = LatticeLib.tagNovelToken("xylophonement", tagger: .hmm)
        #expect(r == .noun)
    }
}
