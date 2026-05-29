// SchemeTests.swift
//
// Verifies Part 1 of LAUNCH-03B: MDCC is the default scheme and
// resolves offline with no fetch.

import XCTest
@testable import EideticLib

final class SchemeTests: XCTestCase {

    func testDefaultSchemeIsMDCC() {
        XCTAssertEqual(EideticLib.defaultScheme, .mdcc)
        XCTAssertTrue(EideticLib.defaultScheme.isDefault)
    }

    func testForeignSchemeIsNotDefault() {
        XCTAssertFalse(ClassificationScheme.foreign("wikidata").isDefault)
    }

    func testBundledManifestLoadsOffline() {
        let manifest = EideticLib.defaultSchemeManifest()
        XCTAssertNotNil(manifest, "Default scheme manifest must ship in bundle")
        guard let manifest else { return }
        XCTAssertTrue(manifest.offlineResolvable)
        XCTAssertFalse(manifest.canonVersion.isEmpty)
        XCTAssertFalse(manifest.dataVersion.isEmpty)
        XCTAssertFalse(manifest.licenseNote.isEmpty)
    }

    func testManifestCanonVersionMatchesMDCCv1() {
        // The bundled MDCC default scheme manifest pins canon v1.
        // A canon-cut bump will require updating both this test and
        // the bundled JSON, by design.
        let manifest = EideticLib.defaultSchemeManifest()
        XCTAssertEqual(manifest?.canonVersion, "v1")
    }
}
