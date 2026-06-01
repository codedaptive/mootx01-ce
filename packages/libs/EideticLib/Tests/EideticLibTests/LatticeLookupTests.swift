// LatticeLookupTests.swift
//
// The FDC lookup contract. EideticLib.lookup delegates to LatticeLib's
// FDC encoder: it resolves a term to a well-formed FDC code, carries
// the dominant concept's Wikidata Q-ID, and never guesses (UNRESOLVED
// terms return an empty code). No UDC schedule is bundled or consulted.

import XCTest
@testable import EideticLib
import LatticeLib

final class FDCLookupTests: XCTestCase {

    // 1. A topical term grounds to a well-formed FDC code, never a
    //    guess. (Which specific code — exact-match accuracy — is
    //    governed by STOP_THRESHOLD tuning, not this contract test.)
    func testLookupResolvesToWellFormedCode() throws {
        let anchor = EideticLib.lookup("philosophy")
        XCTAssertFalse(
            anchor.code.isEmpty,
            "philosophy must resolve to an FDC code"
        )
        XCTAssertTrue(
            Code.isWellFormed(anchor.code),
            "resolved code \(anchor.code) must be a well-formed FDC code"
        )
    }

    // 2. The lookup carries the dominant concept's Wikidata Q-ID
    //    (the highest-weighted Q-ID in the term's concept bag).
    func testLookupCarriesDominantConceptQID() throws {
        let anchor = EideticLib.lookup("philosophy")
        let qid = try XCTUnwrap(
            anchor.wikidataQID,
            "a topical term must carry a dominant concept Q-ID"
        )
        XCTAssertTrue(qid.hasPrefix("Q"), "the concept identity is a Wikidata Q-ID")
    }

    // 3. A well-formed code absent from the canon is pending — the
    //    valid-but-unknown contract — and round-trips intact.
    func testWellFormedCodeAbsentFromCanonIsPendingAndRoundTrips() throws {
        // "999.99" is well-formed grammar but not in the v1 canon.
        let knownCodes: Set<String> = ["100"]
        let state = EideticLib.classifyLatticeCode("999.99", knownCodes: knownCodes)
        XCTAssertEqual(state, .pending("999.99"))
        XCTAssertTrue(state.isWellFormed)

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(LatticeCodeState.self, from: data)
        XCTAssertEqual(decoded, state, "pending code must round-trip intact")
        XCTAssertEqual(decoded.rawCode, "999.99")
    }

    // 4. An UNRESOLVED term (no signature overlap) returns an empty
    //    code, nil Q-ID, zero confidence — never a guess.
    func testUnresolvedTermReturnsEmptyAnchor() {
        let anchor = EideticLib.lookup("zxcvqwertyasdfgh")
        XCTAssertEqual(
            anchor.code, "",
            "an unresolved term must yield an empty code, not a fallback"
        )
        XCTAssertNil(anchor.wikidataQID)
        XCTAssertEqual(anchor.confidence, 0)
    }

    // 5. Anchor shape: exposes code and no udcCode.
    func testAnchorExposesLatticeCodeAndNoUDCCode() {
        let anchor = EideticLib.lookup("chemistry")
        let mirror = Mirror(reflecting: anchor)
        let labels = mirror.children.compactMap { $0.label }
        XCTAssertTrue(labels.contains("code"), "Anchor must expose code")
        XCTAssertFalse(labels.contains("udcCode"), "Anchor must not expose udcCode")
    }
}
