// ForeignSourcePipelineTests.swift
//
// Verifies Part 3 of LAUNCH-03B:
//   - consent gate blocks the pipeline until consent is recorded
//   - successful run produces the assembled file at liveDestination
//   - unreachable source fails clean — no partial state
//   - digest mismatch fails clean — no partial state
//
// The fetcher closure is the test seam — no real network is used.

import XCTest
@testable import EideticLib

final class ForeignSourcePipelineTests: XCTestCase {

    // The known SHA-256 of the byte string "hello-world" so a
    // canned fetcher can pin a digest the pipeline will accept.
    // Independently verified against `printf 'hello-world' | shasum -a 256`.
    private static let helloDigest =
        "afa27b44d43b02a9fea41d13cedc2e4016cfcf87c5dbf990e593669aa8ce286d"

    /// Returns a fresh empty staging root and live destination,
    /// cleaning up after the test.
    private func makeWorkPaths() -> (staging: URL, live: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnomon-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return (
            staging: root.appendingPathComponent("staging", isDirectory: true),
            live: root.appendingPathComponent("payload.bin")
        )
    }

    func testSHA256AgreesWithKnownVector() {
        // FIPS 180-4 test vector: "abc" -> ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        let digest = ForeignSourcePipeline.sha256Hex(Data("abc".utf8))
        XCTAssertEqual(
            digest,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testPipelineRefusesWithoutConsent() async {
        let consent = ActivationConsent()
        let pipeline = ForeignSourcePipeline(
            consent: consent,
            fetcher: { _ in Data("hello-world".utf8) }
        )
        let paths = makeWorkPaths()
        let source = PinnedSource(
            schemeID: "wikidata",
            url: URL(string: "https://example.invalid/payload")!,
            version: "2026-05-23",
            expectedDigest: Self.helloDigest
        )
        do {
            _ = try await pipeline.assemble(
                source,
                liveDestination: paths.live,
                stagingRoot: paths.staging
            )
            XCTFail("Pipeline should refuse without consent")
        } catch let error as PipelineError {
            guard case .consentMissing(let schemeID) = error else {
                XCTFail("Expected .consentMissing, got \(error)")
                return
            }
            XCTAssertEqual(schemeID, "wikidata")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        // No live file produced.
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.live.path))
    }

    func testSuccessfulAssembly() async throws {
        let consent = ActivationConsent()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = await consent.accept(
            schemeID: "wikidata",
            licenseTextDigest: "license-fingerprint",
            now: now
        )
        let pipeline = ForeignSourcePipeline(
            consent: consent,
            fetcher: { _ in Data("hello-world".utf8) }
        )
        let paths = makeWorkPaths()
        let source = PinnedSource(
            schemeID: "wikidata",
            url: URL(string: "https://example.invalid/payload")!,
            version: "2026-05-23",
            expectedDigest: Self.helloDigest
        )
        let result = try await pipeline.assemble(
            source,
            liveDestination: paths.live,
            stagingRoot: paths.staging
        )
        XCTAssertEqual(result, paths.live)
        let onDisk = try Data(contentsOf: paths.live)
        XCTAssertEqual(onDisk, Data("hello-world".utf8))
    }

    func testUnreachableSourceFailsClean() async {
        let consent = ActivationConsent()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = await consent.accept(
            schemeID: "wikidata",
            licenseTextDigest: "license-fingerprint",
            now: now
        )
        struct Boom: Error {}
        let pipeline = ForeignSourcePipeline(
            consent: consent,
            fetcher: { _ in throw Boom() }
        )
        let paths = makeWorkPaths()
        let source = PinnedSource(
            schemeID: "wikidata",
            url: URL(string: "https://example.invalid/payload")!,
            version: "2026-05-23",
            expectedDigest: Self.helloDigest
        )
        do {
            _ = try await pipeline.assemble(
                source,
                liveDestination: paths.live,
                stagingRoot: paths.staging
            )
            XCTFail("Unreachable source must raise")
        } catch let error as PipelineError {
            guard case .sourceUnreachable = error else {
                XCTFail("Expected .sourceUnreachable, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        // Clean failure: no live file and no leftover staging.
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.live.path))
        if FileManager.default.fileExists(atPath: paths.staging.path) {
            // The staging *root* may exist (we created its parent),
            // but no run-* directory should remain inside it.
            let contents = try? FileManager.default.contentsOfDirectory(
                at: paths.staging,
                includingPropertiesForKeys: nil
            )
            XCTAssertEqual(contents?.count ?? 0, 0,
                "Staging should be cleaned of run directories")
        }
    }

    func testFailedPromoteLeavesNoFile() async {
        // Promote fails when the destination directory is itself a
        // file. The pipeline must clean up staging AND leave no
        // file at liveDestination — confirming the placeholder-free
        // promote path honours the clean-failure invariant in the
        // net-new-file case.
        let consent = ActivationConsent()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = await consent.accept(
            schemeID: "wikidata",
            licenseTextDigest: "license-fingerprint",
            now: now
        )
        let pipeline = ForeignSourcePipeline(
            consent: consent,
            fetcher: { _ in Data("hello-world".utf8) }
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnomon-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        // Plant a regular file where the live directory would go,
        // so createDirectory at that path fails.
        let blockerFile = root.appendingPathComponent("blocker")
        try? Data().write(to: blockerFile)
        let live = blockerFile.appendingPathComponent("payload.bin")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let source = PinnedSource(
            schemeID: "wikidata",
            url: URL(string: "https://example.invalid/payload")!,
            version: "2026-05-23",
            expectedDigest: Self.helloDigest
        )
        do {
            _ = try await pipeline.assemble(
                source,
                liveDestination: live,
                stagingRoot: staging
            )
            XCTFail("Promote into a blocked path must raise")
        } catch let error as PipelineError {
            guard case .assemblyWriteFailed = error else {
                XCTFail("Expected .assemblyWriteFailed, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        // No file at live path; the blocker file is untouched.
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path))
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: blockerFile.path,
            isDirectory: &isDir
        ))
        XCTAssertFalse(isDir.boolValue)
        // Staging directory cleaned up (or never created).
        if FileManager.default.fileExists(atPath: staging.path) {
            let contents = try? FileManager.default.contentsOfDirectory(
                at: staging,
                includingPropertiesForKeys: nil
            )
            XCTAssertEqual(contents?.count ?? 0, 0,
                "Staging should be cleaned of run directories")
        }
    }

    func testDigestMismatchFailsClean() async {
        let consent = ActivationConsent()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = await consent.accept(
            schemeID: "wikidata",
            licenseTextDigest: "license-fingerprint",
            now: now
        )
        let pipeline = ForeignSourcePipeline(
            consent: consent,
            fetcher: { _ in Data("hello-world".utf8) }
        )
        let paths = makeWorkPaths()
        let source = PinnedSource(
            schemeID: "wikidata",
            url: URL(string: "https://example.invalid/payload")!,
            version: "2026-05-23",
            // Pinned digest deliberately wrong — upstream drift.
            expectedDigest: String(repeating: "0", count: 64)
        )
        do {
            _ = try await pipeline.assemble(
                source,
                liveDestination: paths.live,
                stagingRoot: paths.staging
            )
            XCTFail("Digest mismatch must raise")
        } catch let error as PipelineError {
            guard case .digestMismatch(_, let expected, let actual) = error else {
                XCTFail("Expected .digestMismatch, got \(error)")
                return
            }
            XCTAssertEqual(expected, String(repeating: "0", count: 64))
            XCTAssertEqual(actual, Self.helloDigest)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.live.path))
    }
}
