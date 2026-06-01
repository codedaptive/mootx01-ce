// EideticLibTests.swift
//
// Module-level surface tests for the FDC-backed lookup. The
// detailed FDC lookup contract lives in LatticeLookupTests.swift
// (FDCLookupTests).

import XCTest
@testable import EideticLib
import LatticeLib

final class EideticLibTests: XCTestCase {

    func testModuleVersion() {
        XCTAssertEqual(EideticLib.version, "0.1.0")
    }

    func testLookupChemistryResolvesToCode() {
        let anchor = EideticLib.lookup("chemistry")
        XCTAssertFalse(
            anchor.code.isEmpty,
            "lookup must resolve a topical term to an FDC code"
        )
    }

    func testLookupEmptyStringYieldsEmptyAnchor() {
        let anchor = EideticLib.lookup("")
        XCTAssertEqual(anchor.code, "")
        XCTAssertEqual(anchor.confidence, 0)
    }

    func testLookupCarriesDataVersion() {
        // dataVersion records the pinned FDC signatures version that
        // produced the answer (LatticeLib's bundled artifacts).
        let anchor = EideticLib.lookup("chemistry")
        XCTAssertEqual(anchor.dataVersion, FDC.dataVersion)
        XCTAssertFalse(anchor.dataVersion.isEmpty)
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
            dataVersion: "1.0.0"
        )
        let data = try JSONEncoder().encode(anchor)
        let decoded = try JSONDecoder().decode(Anchor.self, from: data)
        XCTAssertEqual(decoded, anchor)
    }
}
