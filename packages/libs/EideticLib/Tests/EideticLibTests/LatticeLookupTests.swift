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

    // 5. No UDC data is loaded: the CC-BY-SA UDCSchedule.json
    //    resource is gone from the bundle.
    func testUDCScheduleResourceIsAbsentFromBundle() {
        let url = Bundle.module.url(
            forResource: "UDCSchedule",
            withExtension: "json"
        )
        XCTAssertNil(
            url,
            "the CC-BY-SA UDCSchedule.json must not ship in the EideticLib bundle"
        )
    }

    // 6. Anchor shape: exposes code and no udcCode. The Rust-port
    //    sibling struct carries the same rename as a documented
    //    follow-up (see TASK_MDCC_03_BLAST_RADIUS.md).
    func testAnchorExposesLatticeCodeAndNoUDCCode() {
        let anchor = EideticLib.lookup("chemistry")
        let mirror = Mirror(reflecting: anchor)
        let labels = mirror.children.compactMap { $0.label }
        XCTAssertTrue(labels.contains("code"), "Anchor must expose code")
        XCTAssertFalse(labels.contains("udcCode"), "Anchor must not expose udcCode")
    }
}

/// Part 3: the licensing boundary. No CC-BY-SA classification data
/// ships in the EideticLib default bundle; the only bundled
/// classification data is the CC0 Wikidata subset, and the
/// classification source (the MDCC canon) is CC0/public-domain and
/// lives in LatticeLib.
final class LicensingBoundaryTests: XCTestCase {

    func testNoCCBYSAResourceShipsInBundle() throws {
        // The CC-BY-SA UDC schedule must be gone from the bundle.
        XCTAssertNil(
            Bundle.module.url(forResource: "UDCSchedule", withExtension: "json"),
            "the CC-BY-SA UDCSchedule.json must not ship"
        )

        // The bundled Wikidata subset must be CC0, not the encumbered
        // CC-BY-SA license the retired UDC schedule carried.
        let subset = try XCTUnwrap(WikidataSubset.loadBundled())
        let note = subset.licenseNote.uppercased()
        XCTAssertTrue(note.contains("CC0"), "bundled subset must be CC0")
        XCTAssertFalse(
            note.contains("CC-BY-SA"),
            "no CC-BY-SA share-alike data may ship in the default bundle"
        )
    }
}
