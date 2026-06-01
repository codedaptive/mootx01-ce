// WikidataResolverTests.swift
//
// Tests for the MDCC-keyed Wikidata Q-ID resolver. The resolver
// surfaces a resolved canon entry's sourceIdentity (its CC0 Q-ID)
// and confirms it against the bundled CC0 subset.

import Testing
@testable import EideticLib
import LatticeLib

@Suite("Wikidata resolver")
struct WikidataResolverTests {

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

    @Test("resolve surfaces entry source identity as QID")
    func resolveSurfacesEntrySourceIdentityAsQID() throws {
        let subset = makeSubset([
            WikidataEntry(
                qid: "Q2329", label: "chemistry",
                aliases: ["chem"], sourceSection: "test"
            )
        ])
        let decision = try #require(
            WikidataResolver.resolve(
                entry: entry(code: "503", qid: "Q2329", label: "chemistry"),
                subset: subset
            )
        )
        #expect(decision.qid == "Q2329")
        #expect(decision.labelHits == 1, "subset label matches canon label")
        #expect(decision.aliasHits == 1)
    }

    @Test("resolve returns QID even when absent from subset")
    func resolveReturnsQIDEvenWhenAbsentFromSubset() throws {
        // A valid canon Q-ID the bundled CC0 subset does not carry is
        // still surfaced — without subset-backed evidence.
        let subset = makeSubset([
            WikidataEntry(
                qid: "Q9999", label: "unrelated",
                aliases: [], sourceSection: "test"
            )
        ])
        let decision = try #require(
            WikidataResolver.resolve(
                entry: entry(code: "100", qid: "Q5891", label: "philosophy"),
                subset: subset
            )
        )
        #expect(decision.qid == "Q5891")
        #expect(decision.labelHits == 0)
        #expect(decision.aliasHits == 0)
    }

    @Test("resolve returns nil when entry has no source identity")
    func resolveReturnsNilWhenEntryHasNoSourceIdentity() {
        let subset = makeSubset([])
        #expect(
            WikidataResolver.resolve(
                entry: entry(code: "503", qid: "", label: "chemistry"),
                subset: subset
            ) == nil
        )
    }

    @Test("resolve is deterministic")
    func resolveIsDeterministic() {
        let subset = makeSubset([
            WikidataEntry(
                qid: "Q2329", label: "chemistry",
                aliases: ["chem"], sourceSection: "test"
            )
        ])
        let e = entry(code: "503", qid: "Q2329", label: "chemistry")
        let a = WikidataResolver.resolve(entry: e, subset: subset)
        let b = WikidataResolver.resolve(entry: e, subset: subset)
        #expect(a == b)
    }

    // MARK: integration via lookup()

    @Test("lookup chemistry returns anchor with QID")
    func lookupChemistryReturnsAnchorWithQid() {
        let anchor = EideticLib.lookup("chemistry")
        #expect(!anchor.code.isEmpty)
        let qid = anchor.wikidataQID
        #expect(qid != nil)
        #expect((qid ?? "").hasPrefix("Q"), "Q-ID must start with Q")
    }

    @Test("lookup nonsense returns anchor with nil QID")
    func lookupNonsenseReturnsAnchorWithNilQid() {
        let anchor = EideticLib.lookup("zxcvqwertyasdfgh")
        #expect(anchor.code == "")
        #expect(anchor.wikidataQID == nil)
    }
}
