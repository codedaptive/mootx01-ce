// EideticLibTests.swift
//
// Module-level surface tests for the FDC-backed lookup. The
// detailed FDC lookup contract lives in LatticeLookupTests.swift
// (FDCLookupTests).

import Testing
import Foundation
@testable import EideticLib
import LatticeLib

@Suite("EideticLib module surface")
struct EideticLibTests {

    @Test("module version")
    func moduleVersion() {
        #expect(EideticLib.version == "0.1.0")
    }

    // The honest-classification guard (tie-count) means that single-word
    // lookups for broad terms like "chemistry" or "philosophy" correctly
    // return UNRESOLVED: each maps to a Q-ID in 100–800+ signatures,
    // producing a large tied-winner set. To test the resolving path,
    // use multi-term topical text with distinctive subject vocabulary.
    @Test("lookup resolves topical text to an FDC code")
    func lookupTopicalTextResolvesToCode() {
        // Multi-term biology text with distinctive Q-IDs — resolves to a
        // natural-sciences FDC code. Single words like "chemistry" or
        // "philosophy" are now correctly UNRESOLVED (too many tied candidates).
        let topical = "Biology is the scientific study of life and living organisms, " +
            "including their physical structure, chemical processes, molecular " +
            "interactions, physiological mechanisms, and evolution."
        let anchor = EideticLib.lookup(topical)
        #expect(
            !anchor.code.isEmpty,
            "topical text with distinctive subject vocabulary must resolve to an FDC code"
        )
    }

    @Test("single-word lookup for broad term returns UNRESOLVED (honest guard)")
    func singleWordBroadTermReturnsUnresolved() {
        // "chemistry" maps to Q2329, which appears in 111 signatures →
        // 111 tied codes → tie-count guard fires → UNRESOLVED (empty code).
        // This is the honest result: there is no discriminating signal.
        let anchor = EideticLib.lookup("chemistry")
        #expect(
            anchor.code.isEmpty,
            "broad single-word term with 100+ tied candidates must return UNRESOLVED; got: '\(anchor.code)'"
        )
    }

    @Test("empty string yields empty anchor")
    func lookupEmptyStringYieldsEmptyAnchor() {
        let anchor = EideticLib.lookup("")
        #expect(anchor.code == "")
        #expect(anchor.confidence == 0)
    }

    @Test("lookup carries data version")
    func lookupCarriesDataVersion() {
        // dataVersion records the pinned FDC signatures version.
        // Use any lookup — even UNRESOLVED results carry the version.
        let anchor = EideticLib.lookup("chemistry")
        #expect(anchor.dataVersion == FDC.dataVersion)
        #expect(!anchor.dataVersion.isEmpty)
    }

    @Test("lookup is deterministic")
    func lookupIsDeterministic() {
        let a = EideticLib.lookup("philosophy")
        let b = EideticLib.lookup("philosophy")
        #expect(a == b)
    }

    @Test("anchor round-trips through JSON")
    func anchorRoundTripsThroughJSON() throws {
        let anchor = Anchor(
            code: "503",
            wikidataQID: "Q2329",
            confidence: 48,
            dataVersion: "1.0.0"
        )
        let data = try JSONEncoder().encode(anchor)
        let decoded = try JSONDecoder().decode(Anchor.self, from: data)
        #expect(decoded == anchor)
    }
}
