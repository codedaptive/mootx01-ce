// LatticeLookupTests.swift
//
// The FDC lookup contract. EideticLib.lookup delegates to LatticeLib's
// FDC encoder: it resolves a term to a well-formed FDC code, carries
// the dominant concept's Wikidata Q-ID, and never guesses (UNRESOLVED
// terms return an empty code). No UDC schedule is bundled or consulted.

import Testing
import Foundation
@testable import EideticLib
import LatticeLib

@Suite("FDC lookup contract")
struct FDCLookupTests {

    // 1. A topical term grounds to a well-formed FDC code, never a
    //    guess. (Which specific code — exact-match accuracy — is
    //    governed by STOP_THRESHOLD tuning, not this contract test.)
    @Test("lookup resolves to a well-formed code")
    func lookupResolvesToWellFormedCode() throws {
        let anchor = EideticLib.lookup("philosophy")
        #expect(
            !anchor.code.isEmpty,
            "philosophy must resolve to an FDC code"
        )
        #expect(
            Code.isWellFormed(anchor.code),
            "resolved code \(anchor.code) must be a well-formed FDC code"
        )
    }

    // 2. The lookup carries the dominant concept's Wikidata Q-ID
    //    (the highest-weighted Q-ID in the term's concept bag).
    @Test("lookup carries dominant concept QID")
    func lookupCarriesDominantConceptQID() throws {
        let anchor = EideticLib.lookup("philosophy")
        let qid = try #require(
            anchor.wikidataQID,
            "a topical term must carry a dominant concept Q-ID"
        )
        #expect(qid.hasPrefix("Q"), "the concept identity is a Wikidata Q-ID")
    }

    // 3. A well-formed code absent from the canon is pending — the
    //    valid-but-unknown contract — and round-trips intact.
    @Test("well-formed code absent from canon is pending and round-trips")
    func wellFormedCodeAbsentFromCanonIsPendingAndRoundTrips() throws {
        // "999.99" is well-formed grammar but not in the v1 canon.
        let knownCodes: Set<String> = ["100"]
        let state = EideticLib.classifyLatticeCode("999.99", knownCodes: knownCodes)
        #expect(state == .pending("999.99"))
        #expect(state.isWellFormed)

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(LatticeCodeState.self, from: data)
        #expect(decoded == state, "pending code must round-trip intact")
        #expect(decoded.rawCode == "999.99")
    }

    // 4. An UNRESOLVED term (no signature overlap) returns an empty
    //    code, nil Q-ID, zero confidence — never a guess.
    @Test("unresolved term returns empty anchor")
    func unresolvedTermReturnsEmptyAnchor() {
        let anchor = EideticLib.lookup("zxcvqwertyasdfgh")
        #expect(
            anchor.code == "",
            "an unresolved term must yield an empty code, not a fallback"
        )
        #expect(anchor.wikidataQID == nil)
        #expect(anchor.confidence == 0)
    }

    // 5. Anchor shape: exposes code and no udcCode.
    @Test("anchor exposes lattice code and no UDC code")
    func anchorExposesLatticeCodeAndNoUDCCode() {
        let anchor = EideticLib.lookup("chemistry")
        let mirror = Mirror(reflecting: anchor)
        let labels = mirror.children.compactMap { $0.label }
        #expect(labels.contains("code"), "Anchor must expose code")
        #expect(!labels.contains("udcCode"), "Anchor must not expose udcCode")
    }
}
