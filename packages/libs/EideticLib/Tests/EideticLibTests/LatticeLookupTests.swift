// MDCCLookupTests.swift
//
// The MDCC lookup contract (MISSION_MDCC_03). EideticLib.lookup
// resolves a term against the bundled MDCC canon (from LatticeKit),
// returns an MDCC code and the canon entry's Wikidata Q-ID, and
// never falls back to a UDC code. The CC-BY-SA UDC schedule is no
// longer bundled or consulted.

import Testing
import Foundation
@testable import EideticLib
import LatticeKit

@Suite("MDCC lookup contract")
struct MDCCLookupTests {

    // 1. A canon term grounds to a well-formed MDCC code that is
    //    present in the bundled MDCC canon — not a UDC code.
    @Test("lookup returns lattice code present in canon")
    func lookupReturnsLatticeCodePresentInCanon() throws {
        let anchor = EideticLib.lookup("philosophy")
        #expect(
            !anchor.code.isEmpty,
            "philosophy must resolve to an MDCC code"
        )
        #expect(
            Code.isWellFormed(anchor.code),
            "resolved code \(anchor.code) must be a well-formed MDCC code"
        )
        let entry = try #require(
            LatticeKit.entry(for: anchor.code),
            "resolved code \(anchor.code) must exist in the bundled MDCC canon"
        )
        #expect(entry.label == "philosophy")
    }

    // 2. The same lookup carries the canon entry's sourceIdentity
    //    as the Wikidata Q-ID.
    @Test("lookup carries canon source identity as QID")
    func lookupCarriesCanonSourceIdentityAsQID() throws {
        let anchor = EideticLib.lookup("philosophy")
        let entry = try #require(LatticeKit.entry(for: anchor.code))
        #expect(
            anchor.wikidataQID == entry.sourceIdentity,
            "the anchor's Q-ID must be the resolved canon entry's sourceIdentity"
        )
        #expect(
            (anchor.wikidataQID ?? "").hasPrefix("Q"),
            "sourceIdentity is a Wikidata Q-ID"
        )
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

    // 4. A term with no canon match returns an empty MDCC code,
    //    never a UDC fallback.
    @Test("no canon match returns empty code, not UDC fallback")
    func noCanonMatchReturnsEmptyCodeNotUDCFallback() {
        let anchor = EideticLib.lookup("zxcvqwertyasdfgh")
        #expect(
            anchor.code == "",
            "no canon match must yield an empty MDCC code, not a fallback"
        )
        #expect(anchor.wikidataQID == nil)
        #expect(anchor.confidence == 0)
    }

    // 5. No UDC data is loaded: the CC-BY-SA UDCSchedule.json
    //    resource is gone from the bundle.
    @Test("UDC schedule resource is absent from bundle")
    func udcScheduleResourceIsAbsentFromBundle() {
        let url = Bundle.module.url(
            forResource: "UDCSchedule",
            withExtension: "json"
        )
        #expect(
            url == nil,
            "the CC-BY-SA UDCSchedule.json must not ship in the EideticLib bundle"
        )
    }

    // 6. Anchor shape: exposes code and no udcCode. The Rust-port
    //    sibling struct carries the same rename as a documented
    //    follow-up (see TASK_MDCC_03_BLAST_RADIUS.md).
    @Test("anchor exposes lattice code and no udcCode")
    func anchorExposesLatticeCodeAndNoUDCCode() {
        let anchor = EideticLib.lookup("chemistry")
        let mirror = Mirror(reflecting: anchor)
        let labels = mirror.children.compactMap { $0.label }
        #expect(labels.contains("code"), "Anchor must expose code")
        #expect(!labels.contains("udcCode"), "Anchor must not expose udcCode")
    }
}

/// Part 3: the licensing boundary. No CC-BY-SA classification data
/// ships in the EideticLib default bundle; the only bundled
/// classification data is the CC0 Wikidata subset, and the
/// classification source (the MDCC canon) is CC0/public-domain and
/// lives in LatticeKit.
@Suite("Licensing boundary")
struct LicensingBoundaryTests {

    @Test("no CC-BY-SA resource ships in bundle")
    func noCCBYSAResourceShipsInBundle() throws {
        // The CC-BY-SA UDC schedule must be gone from the bundle.
        #expect(
            Bundle.module.url(forResource: "UDCSchedule", withExtension: "json") == nil,
            "the CC-BY-SA UDCSchedule.json must not ship"
        )

        // The bundled Wikidata subset must be CC0, not the encumbered
        // CC-BY-SA license the retired UDC schedule carried.
        let subset = try #require(WikidataSubset.loadBundled())
        let note = subset.licenseNote.uppercased()
        #expect(note.contains("CC0"), "bundled subset must be CC0")
        #expect(
            !note.contains("CC-BY-SA"),
            "no CC-BY-SA share-alike data may ship in the default bundle"
        )
    }
}
