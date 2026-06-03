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

    @Test("lookup resolves a topical term to an FDC code")
    func lookupChemistryResolvesToCode() {
        let anchor = EideticLib.lookup("chemistry")
        #expect(
            !anchor.code.isEmpty,
            "lookup must resolve a topical term to an FDC code"
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
        // dataVersion records the pinned FDC signatures version that
        // produced the answer (LatticeLib's bundled artifacts).
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
