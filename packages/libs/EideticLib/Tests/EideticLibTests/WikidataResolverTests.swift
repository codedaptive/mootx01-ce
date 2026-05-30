// WikidataResolverTests.swift
//
// Tests for the MDCC-keyed Wikidata Q-ID resolver. The resolver
// surfaces a resolved canon entry's sourceIdentity (its CC0 Q-ID)
// and confirms it against the bundled CC0 subset.

import XCTest
@testable import EideticLib
import LatticeKit

final class WikidataResolverTests: XCTestCase {

    // MARK: helpers

    func makeSubset(_ entries: [WikidataEntry]) -> WikidataSubset {
        WikidataSubset(
            schemaVersion: "1",
            dataVersion: "0.1.0-test",
            sourceNotes: "test fixture",
            licenseNote: "test fixture",
            entries: entries
        )
    }

    func entry(code: String, qid: String, label: String) -> LatticeEntry {
        LatticeEntry(code: code, sourceIdentity: qid, label: label, classBase: 5)
    }

    // MARK: resolution

    func testResolveSurfacesEntrySourceIdentityAsQID() throws {
        let subset = makeSubset([
            WikidataEntry(
                qid: "Q2329", label: "chemistry",
                aliases: ["chem"], sourceSection: "test"
            )
        ])
        let decision = try XCTUnwrap(
            WikidataResolver.resolve(
                entry: entry(code: "503", qid: "Q2329", label: "chemistry"),
                subset: subset
            )
        )
        XCTAssertEqual(decision.qid, "Q2329")
        XCTAssertEqual(decision.labelHits, 1, "subset label matches canon label")
        XCTAssertEqual(decision.aliasHits, 1)
    }

    func testResolveReturnsQIDEvenWhenAbsentFromSubset() throws {
        // A valid canon Q-ID the bundled CC0 subset does not carry is
        // still surfaced — without subset-backed evidence.
        let subset = makeSubset([
            WikidataEntry(
                qid: "Q9999", label: "unrelated",
                aliases: [], sourceSection: "test"
            )
        ])
        let decision = try XCTUnwrap(
            WikidataResolver.resolve(
                entry: entry(code: "100", qid: "Q5891", label: "philosophy"),
                subset: subset
            )
        )
        XCTAssertEqual(decision.qid, "Q5891")
        XCTAssertEqual(decision.labelHits, 0)
        XCTAssertEqual(decision.aliasHits, 0)
    }

    func testResolveReturnsNilWhenEntryHasNoSourceIdentity() {
        let subset = makeSubset([])
        XCTAssertNil(
            WikidataResolver.resolve(
                entry: entry(code: "503", qid: "", label: "chemistry"),
                subset: subset
            )
        )
    }

    func testResolveIsDeterministic() {
        let subset = makeSubset([
            WikidataEntry(
                qid: "Q2329", label: "chemistry",
                aliases: ["chem"], sourceSection: "test"
            )
        ])
        let e = entry(code: "503", qid: "Q2329", label: "chemistry")
        let a = WikidataResolver.resolve(entry: e, subset: subset)
        let b = WikidataResolver.resolve(entry: e, subset: subset)
        XCTAssertEqual(a, b)
    }

    // MARK: integration via lookup()

    func testLookupChemistryReturnsAnchorWithQid() {
        let anchor = EideticLib.lookup("chemistry")
        XCTAssertFalse(anchor.code.isEmpty)
        let qid = anchor.wikidataQID
        XCTAssertNotNil(qid)
        XCTAssertTrue((qid ?? "").hasPrefix("Q"), "Q-ID must start with Q")
    }

    func testLookupNonsenseReturnsAnchorWithNilQid() {
        let anchor = EideticLib.lookup("zxcvqwertyasdfgh")
        XCTAssertEqual(anchor.code, "")
        XCTAssertNil(anchor.wikidataQID)
    }
}
