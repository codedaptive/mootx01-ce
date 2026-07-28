import XCTest
@testable import mcp_benchmarker

// ScratchPostureTests.swift — Unit tests for the scratch-estate encryption
// posture (FIX-HARNESS-20260727).
//
// Contract under test (verified against the product's EstateOpenPosture.swift):
//   - marker filename is exactly "no-encrypt"
//   - the marker lives directly inside the scratch data dir (the default
//     estate's file is <scratchDir>/estate.sqlite, so the estate file's parent
//     IS the scratch dir)
//   - plaintextOptOut writes the marker at scratch-dir creation, BEFORE any
//     serve launch; encryptedDefault writes nothing
//
// All three runners' scratch creators are exercised so a future runner-local
// regression (one creator forgetting applyScratchPosture) is caught here.

final class ScratchPostureTests: XCTestCase {

    // MARK: - Marker contract

    func testMarkerFilenameMatchesProductContract() {
        // EstateKeyProvider.encryptionOptOutMarkerName in MootInstallerCore.
        // If the product renames the marker, this test names the contract that
        // broke rather than letting benchmarks silently create encrypted estates.
        XCTAssertEqual(mootEncryptionOptOutMarkerName, "no-encrypt")
    }

    func testMarkerURLIsDirectlyInsideScratchDir() {
        let dir = URL(fileURLWithPath: "/tmp/lme-bench-posturetest")
        let marker = scratchOptOutMarkerURL(in: dir)
        XCTAssertEqual(marker.path, "/tmp/lme-bench-posturetest/no-encrypt")
    }

    // MARK: - Creators write the marker (plaintextOptOut, the default)

    func testLMEScratchDirPlaintextWritesMarker() throws {
        let url = try lmeScratchDir(posture: .plaintextOptOut)
        defer { try? lmeGuardedTeardown(url) }
        XCTAssert(scratchHasOptOutMarker(in: url),
                  "plaintextOptOut must write the no-encrypt marker before serve launch")
    }

    func testLoCoMoScratchDirPlaintextWritesMarker() throws {
        let url = try loCoMoScratchDir(posture: .plaintextOptOut)
        defer { try? loCoMoGuardedTeardown(url) }
        XCTAssert(scratchHasOptOutMarker(in: url))
    }

    func testLMEBScratchDirPlaintextWritesMarker() throws {
        let url = try lmebScratchDir(posture: .plaintextOptOut)
        defer { try? lmebGuardedTeardown(url) }
        XCTAssert(scratchHasOptOutMarker(in: url))
    }

    // MARK: - Creators write NO marker (encryptedDefault)

    func testLMEScratchDirEncryptedWritesNoMarker() throws {
        let url = try lmeScratchDir(posture: .encryptedDefault)
        defer { try? lmeGuardedTeardown(url) }
        XCTAssertFalse(scratchHasOptOutMarker(in: url),
                       "encryptedDefault must not write the opt-out marker")
    }

    func testLoCoMoScratchDirEncryptedWritesNoMarker() throws {
        let url = try loCoMoScratchDir(posture: .encryptedDefault)
        defer { try? loCoMoGuardedTeardown(url) }
        XCTAssertFalse(scratchHasOptOutMarker(in: url))
    }

    func testLMEBScratchDirEncryptedWritesNoMarker() throws {
        let url = try lmebScratchDir(posture: .encryptedDefault)
        defer { try? lmebGuardedTeardown(url) }
        XCTAssertFalse(scratchHasOptOutMarker(in: url))
    }

    // MARK: - applyScratchPosture

    func testApplyIsIdempotent() throws {
        let url = try lmeScratchDir(posture: .plaintextOptOut)
        defer { try? lmeGuardedTeardown(url) }
        // Second application must not throw and must leave the marker present.
        XCTAssertNoThrow(try applyScratchPosture(.plaintextOptOut, to: url))
        XCTAssert(scratchHasOptOutMarker(in: url))
    }

    func testRawValuesAreTheReportVocabulary() {
        // These strings are the report JSON "estate_encryption" values;
        // downstream analysis scripts key on them.
        XCTAssertEqual(ScratchEstatePosture.plaintextOptOut.rawValue, "plaintext-optout")
        XCTAssertEqual(ScratchEstatePosture.encryptedDefault.rawValue, "encrypted-default")
    }
}
