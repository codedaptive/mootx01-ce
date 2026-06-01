// SchemeTests.swift
//
// Verifies Part 1 of LAUNCH-03B: MDCC is the default scheme and
// resolves offline with no fetch.

import Testing
@testable import EideticLib

@Suite("Classification scheme")
struct SchemeTests {

    @Test("default scheme is MDCC")
    func defaultSchemeIsMDCC() {
        #expect(EideticLib.defaultScheme == .mdcc)
        #expect(EideticLib.defaultScheme.isDefault)
    }

    @Test("foreign scheme is not default")
    func foreignSchemeIsNotDefault() {
        #expect(!ClassificationScheme.foreign("wikidata").isDefault)
    }

    @Test("bundled manifest loads offline")
    func bundledManifestLoadsOffline() {
        let manifest = EideticLib.defaultSchemeManifest()
        #expect(manifest != nil, "Default scheme manifest must ship in bundle")
        guard let manifest else { return }
        #expect(manifest.offlineResolvable)
        #expect(!manifest.canonVersion.isEmpty)
        #expect(!manifest.dataVersion.isEmpty)
        #expect(!manifest.licenseNote.isEmpty)
    }

    @Test("manifest canon version matches MDCC v1")
    func manifestCanonVersionMatchesMDCCv1() {
        // The bundled MDCC default scheme manifest pins canon v1.
        // A canon-cut bump will require updating both this test and
        // the bundled JSON, by design.
        let manifest = EideticLib.defaultSchemeManifest()
        #expect(manifest?.canonVersion == "v1")
    }
}
