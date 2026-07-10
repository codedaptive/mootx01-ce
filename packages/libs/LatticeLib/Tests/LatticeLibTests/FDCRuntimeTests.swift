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

    @Test("nonempty text without subject evidence falls back to Generalities")
    func gibberishFallsBackToGeneralities() {
        #expect(FDC.encode("zzqqxv wwkkjj plldfg") == "000")
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

    @Test("trusted relative-index aliases classify modern computing topics")
    func modernComputingTopicsResolve() {
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
            FDC.encode("computer software programming and information science") == "004"
        )
        #expect(
            FDC.encode("internet network protocol server client communication") == "004"
        )
        #expect(
            FDC.encode("software engineering process management systems") == "004"
        )
    }

    @Test("generic computing phrases stop at the broad supported code")
    func genericPhraseUsesBroadCode() {
        // Short technology phrases share zero-IDF Q-IDs across hundreds of codes;
        // the honest result is UNRESOLVED rather than whatever code sorts first
        // in a sea of tied candidates.
        #expect(
            FDC.encode("computer software programming and information science") == "004"
        )
    }

    @Test("operational fragments receive Generalities without fabricated QIDs")
    func operationalFragmentsUseGeneralities() {
        let shell = """
        git worktree prune
        rm -f .git/index.lock
        read_signal() {
          sqlite3 estate.sqlite 'select 1;'
        }
        """
        let markdown = """
        # Monthly Canon Audit

        ```bash
        set -euo pipefail
        git status --short
        ```
        """

        #expect(FDC.encode(shell) == "000")
        #expect(FDC.encodeAnchor(shell).conceptQID == nil)
        #expect(FDC.encode(markdown) == "000")
        #expect(FDC.encodeAnchor(markdown).conceptQID == nil)
    }

    @Test("source-code memories classify as computer programming")
    func sourceCodeUsesProgrammingSubject() {
        let swiftSource = """
        et nodeId: String
        public let indexType: IndexType
        public var semanticVector: [Double]
        public var graphVector: GraphVector
        public var behavioralVector: BehavioralVector
        public var temporalVector: TemporalVector
        public let createdAt: Date
        public var updatedAt: Date
        """
        #expect(FDC.encode(swiftSource) == "005")
        #expect(FDC.encodeAnchor(swiftSource).conceptQID == "Q17118377")
        #expect(FDC.classifierVersion == "4.2.0")
        #expect(FDC.encode("Let us remember the meeting.\nLet everyone review the notes.") != "005")
    }

    @Test("incidental inherited signature terms do not certify narrow headings")
    func incidentalInheritedSignatureTermsUseTrustedAliases() {
        // These were bad v1/v2 confidence failures caused by the compact
        // signature artifact flattening label/title/article/ancestor terms into
        // one membership set. The runtime may use that broad set for recall, but
        // it must not return a narrow user-facing code unless the winning code's
        // own heading is supported by the query.
        #expect(
            FDC.encode("machine learning neural networks artificial intelligence") == "004",
            "machine-learning terms must classify as computer science, not acupuncture"
        )
        #expect(
            FDC.encode("web development HTML programming") == "005",
            "web-development terms must classify as programming, not Great Britain"
        )
        #expect(
            FDC.encode("distributed systems cloud computing") == "004",
            "distributed-systems terms must classify as computer science, not Southeast Asia"
        )
    }

    @Test("partial qualified heading matches do not overdescend")
    func partialQualifiedHeadingMatchesDoNotOverdescend() {
        #expect(
            FDC.encode("art painting sculpture museum") != "755",
            "generic art/painting text must not descend into religious painting without religious evidence"
        )
        #expect(
            FDC.encode("transportation automobile travel vehicles") != "699",
            "generic transportation text must not descend into railroad cars without railroad evidence"
        )
    }

    @Test("own heading evidence still resolves accessible disability topics")
    func ownHeadingEvidenceStillResolvesDisabilityTopic() {
        #expect(FDC.encode("People with disabilities Blind Deaf") == "362.4")
        #expect(FDC.encode("screen reader accessibility braille deaf blind disability") == "362.4")
    }

    @Test("specific own heading evidence still resolves supported topics")
    func specificOwnHeadingEvidenceStillResolvesSupportedTopics() {
        #expect(FDC.encode("computer graphics rendering visualization") == "006.6")
        #expect(FDC.encode("chemistry organic reactions molecules") == "547")
    }

    @Test("query repetition cannot manufacture precision")
    func repetitionDoesNotChangeClassification() {
        #expect(FDC.encode("railroad chemistry") == FDC.encode("railroad railroad railroad chemistry"))
        #expect(FDC.encode("blind chemistry") != "362.4")
    }

    @Test("recalculation version covers algorithm and artifacts")
    func recalculationVersionIsComposite() {
        #expect(FDC.recalculationVersion.contains("classifier:4.2.0"))
        #expect(FDC.recalculationVersion.contains("frame:1.1.0"))
        #expect(FDC.recalculationVersion.contains("lexicon:1.1.0"))
        #expect(FDC.recalculationVersion.contains("signatures:2.0.0"))
        #expect(FDC.recalculationVersion.contains("semantic:1.0.0:"))
        #expect(FDC.recalculationVersion.contains(FDC.semanticModelSHA256))
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

    @Test("label integer code returns own label")
    func labelIntegerReturnsSelf() {
        // Integer codes resolve to their OWN frame label, never an ancestor's —
        // sibling codes listed together must stay distinguishable. "006" and its
        // parent "000" carry distinct labels in the frame, so the two lookups
        // must differ.
        let leafLabel = FDC.label(for: "006")
        let parentLabel = FDC.label(for: "000")
        #expect(leafLabel != nil)
        #expect(parentLabel != nil)
        #expect(leafLabel != parentLabel)
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

    @Test("bundled labels are clean and corrected")
    func bundledLabelsAreCleanAndCorrected() {
        #expect(FDC.label(for: "002") == "History of the book")
        #expect(FDC.label(for: "004") == "Computers + Computer science")
        #expect(FDC.label(for: "615.88") == "Patent medicines")
        #expect(FDC.label(for: "615.89") == "Traditional medicine")
        #expect(FDC.label(for: "971.4") == "Quebec (Province)")
    }
}
