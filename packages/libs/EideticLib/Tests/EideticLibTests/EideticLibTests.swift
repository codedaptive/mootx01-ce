// EideticLibTests.swift
//
// Module-level surface tests for the MDCC-backed lookup. The
// detailed MDCC lookup contract lives in MDCCLookupTests.swift.

import Testing
import Foundation
@testable import EideticLib

@Suite("EideticLib module surface")
struct EideticLibTests {

    @Test("module version")
    func moduleVersion() {
        #expect(EideticLib.version == "0.1.0")
    }

    @Test("lookup chemistry resolves to canon code")
    func lookupChemistryResolvesToCanonCode() {
        let anchor = EideticLib.lookup("chemistry")
        #expect(
            !anchor.code.isEmpty,
            "lookup must resolve a canon term to an MDCC code"
        )
    }

    @Test("lookup empty string yields empty anchor")
    func lookupEmptyStringYieldsEmptyAnchor() {
        let anchor = EideticLib.lookup("")
        #expect(anchor.code == "")
        #expect(anchor.confidence == 0)
    }

    @Test("lookup carries canon data version")
    func lookupCarriesCanonDataVersion() {
        // dataVersion records the MDCC canon version that produced
        // the answer (LatticeLib canon v1).
        let anchor = EideticLib.lookup("chemistry")
        #expect(anchor.dataVersion == "v1")
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
            dataVersion: "v1"
        )
        let data = try JSONEncoder().encode(anchor)
        let decoded = try JSONDecoder().decode(Anchor.self, from: data)
        #expect(decoded == anchor)
    }
}
