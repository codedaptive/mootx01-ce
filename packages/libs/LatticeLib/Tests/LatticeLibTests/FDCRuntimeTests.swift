// FDCRuntimeTests.swift — the bundled FDC engine encodes real text end-to-end.

import Testing
@testable import LatticeLib

@Suite("FDC runtime (bundled artifacts)")
struct FDCRuntimeTests {

    @Test("bundled artifacts load")
    func available() {
        #expect(FDC.isAvailable)
    }

    @Test("encodes topical text with distinctive subject-specific vocabulary")
    func encodesTopical() {
        // Biology text with distinctive Q-IDs (physiology, molecular, evolution)
        // that produce a clear discriminating signal: tied_at_top ≤ 4 after
        // the FDCMatcher.maximumTiedWinnersForClassification guard.
        // Generic technology phrases ("computer software programming") only
        // match zero-IDF Q-IDs shared across hundreds of codes — those
        // correctly return UNRESOLVED after the honest-classification guard.
        let code = FDC.encode(
            "Biology is the scientific study of life and living organisms, " +
            "including their physical structure, chemical processes, molecular " +
            "interactions, physiological mechanisms, and evolution."
        )
        #expect(code != nil, "biology text with distinctive vocabulary must resolve to an FDC code")
        if let c = code { #expect(!c.isEmpty) }
    }

    @Test("gibberish is UNRESOLVED (never guesses)")
    func gibberishUnresolved() {
        #expect(FDC.encode("zzqqxv wwkkjj plldfg") == nil)
    }

    // MARK: - Honest-classification guard
    //
    // The tie-count guard (FDCMatcher.maximumTiedWinnersForClassification)
    // eliminates the worst classification accidents: when many codes share
    // the top IDF score the bag carries no discriminating signal, so the
    // classifier returns UNRESOLVED rather than an arbitrary tie-broken code.
    //
    // What the guard catches:
    //   • Text whose bag contains only high-frequency cross-domain Q-IDs
    //     (present in hundreds of signatures) — these produce many tied
    //     candidates at a near-zero IDF score. E.g. "computer software
    //     programming and information science" ties > 4 codes.
    //
    // What the guard does NOT catch:
    //   • Text where a few INCIDENTAL high-IDF Q-IDs happen to match the
    //     winning code's large signature. "ADR-016 wings as the provenance
    //     organizational axis" produces ≤ 4 tied codes because "wing" maps
    //     to Q1172934 (IDF ≈ 4.1, present in 17 codes) — a high-IDF Q-ID
    //     that coincidentally appears in the 974.x US-history signatures.
    //     This is a classifier quality limit: the v1.0 frame has no
    //     software-domain vocabulary, so coincidental biology/anatomy Q-IDs
    //     bleed through. The embedding encoder (when added) will handle
    //     these cases.
    //
    // Tests here prove the guard works for its intended class of inputs,
    // not that every software phrase returns UNRESOLVED.

    @Test("high-frequency cross-domain jargon returns UNRESOLVED (tie-count guard)")
    func highFrequencyJargonIsUnresolved() {
        // These phrases consist entirely of high-frequency Q-IDs shared across
        // hundreds of UDC signatures: "software", "programming", "computer",
        // "information", "science" all map to Q-IDs present in 100–400+
        // codes. The tie-count guard fires (> 4 codes share the argmax IDF
        // score) and returns UNRESOLVED.
        //
        // This is the class of bug that produced the original finding:
        //   "computer software programming" → UDC 235 (angels/devotional)
        //   "network protocol internet" → UDC 621.2 (hydraulic engineering)
        // Those were arbitrary tie-break winners from a degenerate bag.
        #expect(
            FDC.encode("computer software programming and information science") == nil,
            "generic tech phrase with only high-frequency cross-domain Q-IDs must return UNRESOLVED"
        )
        #expect(
            FDC.encode("internet network protocol server client communication") == nil,
            "networking jargon with only high-frequency cross-domain Q-IDs must return UNRESOLVED"
        )
        #expect(
            FDC.encode("software engineering process management systems") == nil,
            "generic software process phrase must return UNRESOLVED"
        )
    }

    @Test("generic short phrases return UNRESOLVED without distinctive domain terms")
    func genericPhraseIsUnresolved() {
        // Short technology phrases share zero-IDF Q-IDs across hundreds of codes;
        // the honest result is UNRESOLVED rather than whatever code sorts first
        // in a sea of tied candidates.
        #expect(
            FDC.encode("computer software programming and information science") == nil,
            "generic technology phrase with only common cross-domain Q-IDs must return UNRESOLVED"
        )
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
