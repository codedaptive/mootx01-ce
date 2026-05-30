// EideticLibTests.swift
//
// Module-level surface tests for the MDCC-backed lookup. The
// detailed MDCC lookup contract lives in MDCCLookupTests.swift.

import XCTest
@testable import EideticLib

final class EideticLibTests: XCTestCase {

    func testModuleVersion() {
        XCTAssertEqual(EideticLib.version, "0.1.0")
    }

    func testLookupChemistryResolvesToCanonCode() {
        let anchor = EideticLib.lookup("chemistry")
        XCTAssertFalse(
            anchor.code.isEmpty,
            "lookup must resolve a canon term to an MDCC code"
        )
    }

    func testLookupEmptyStringYieldsEmptyAnchor() {
        let anchor = EideticLib.lookup("")
        XCTAssertEqual(anchor.code, "")
        XCTAssertEqual(anchor.confidence, 0)
    }

    func testLookupCarriesCanonDataVersion() {
        // dataVersion records the MDCC canon version that produced
        // the answer (LatticeKit canon v1).
        let anchor = EideticLib.lookup("chemistry")
        XCTAssertEqual(anchor.dataVersion, "v1")
    }

    func testLookupIsDeterministic() {
        let a = EideticLib.lookup("philosophy")
        let b = EideticLib.lookup("philosophy")
        XCTAssertEqual(a, b)
    }

    func testAnchorRoundTripsThroughJSON() throws {
        let anchor = Anchor(
            code: "503",
            wikidataQID: "Q2329",
            confidence: 48,
            dataVersion: "v1"
        )
        let data = try JSONEncoder().encode(anchor)
        let decoded = try JSONDecoder().decode(Anchor.self, from: data)
        XCTAssertEqual(decoded, anchor)
    }
}
