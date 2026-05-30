// MDCCLookupTests.swift
//
// The MDCC lookup contract (MISSION_MDCC_03). EideticLib.lookup
// resolves a term against the bundled MDCC canon (from LatticeKit),
// returns an MDCC code and the canon entry's Wikidata Q-ID, and
// never falls back to a UDC code. The CC-BY-SA UDC schedule is no
// longer bundled or consulted.

import XCTest
@testable import EideticLib
import LatticeKit

final class MDCCLookupTests: XCTestCase {

    // 1. A canon term grounds to a well-formed MDCC code that is
    //    present in the bundled MDCC canon — not a UDC code.
    func testLookupReturnsLatticeCodePresentInCanon() throws {
        let anchor = EideticLib.lookup("philosophy")
        XCTAssertFalse(
            anchor.code.isEmpty,
            "philosophy must resolve to an MDCC code"
        )
        XCTAssertTrue(
            Code.isWellFormed(anchor.code),
            "resolved code \(anchor.code) must be a well-formed MDCC code"
        )
        let entry = try XCTUnwrap(
            LatticeKit.entry(for: anchor.code),
            "resolved code \(anchor.code) must exist in the bundled MDCC canon"
        )
        XCTAssertEqual(entry.label, "philosophy")
    }

    // 2. The same lookup carries the canon entry's sourceIdentity
    //    as the Wikidata Q-ID.
    func testLookupCarriesCanonSourceIdentityAsQID() throws {
        let anchor = EideticLib.lookup("philosophy")
        let entry = try XCTUnwrap(LatticeKit.entry(for: anchor.code))
        XCTAssertEqual(
            anchor.wikidataQID,
            entry.sourceIdentity,
            "the anchor's Q-ID must be the resolved canon entry's sourceIdentity"
        )
        XCTAssertTrue(
            (anchor.wikidataQID ?? "").hasPrefix("Q"),
            "sourceIdentity is a Wikidata Q-ID"
        )
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

    // 4. A term with no canon match returns an empty MDCC code,
    //    never a UDC fallback.
    func testNoCanonMatchReturnsEmptyCodeNotUDCFallback() {
        let anchor = EideticLib.lookup("zxcvqwertyasdfgh")
        XCTAssertEqual(
            anchor.code, "",
            "no canon match must yield an empty MDCC code, not a fallback"
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
/// lives in LatticeKit.
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
