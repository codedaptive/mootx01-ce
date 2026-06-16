// ReleaseDownloaderTests.swift
//
// Unit tests for ReleaseDownloader. All network calls are stubbed via the
// internal fetchData closure initializer — no real network access is made.
// The replace() test uses a real temp directory to exercise Installer.placeBinary.

import Foundation
import Testing
@testable import MootInstallerCore

// MARK: - Mock helpers

/// Build a mock fetch function that returns preset responses keyed by absolute URL string.
/// Accepts an array of (key, value) pairs so call sites can use array-literal syntax.
private func mockFetch(
    _ pairs: [(String, Result<(Data, URLResponse), Error>)]
) -> @Sendable (URL) async throws -> (Data, URLResponse) {
    let responses = Dictionary(uniqueKeysWithValues: pairs)
    return { url in
        guard let result = responses[url.absoluteString] else {
            throw URLError(.badURL)
        }
        return try result.get()
    }
}

private func ok(_ url: String, _ body: String) -> (String, Result<(Data, URLResponse), Error>) {
    let u = URL(string: url)!
    let response = HTTPURLResponse(url: u, statusCode: 200, httpVersion: nil, headerFields: nil)!
    return (url, .success((Data(body.utf8), response)))
}

private func ok(_ url: String, _ data: Data) -> (String, Result<(Data, URLResponse), Error>) {
    let u = URL(string: url)!
    let response = HTTPURLResponse(url: u, statusCode: 200, httpVersion: nil, headerFields: nil)!
    return (url, .success((data, response)))
}

// MARK: - Tests

@Suite("ReleaseDownloader")
struct ReleaseDownloaderTests {

    private let testRepo = "codedaptive/mootx01-ce"
    private let apiURL   = "https://api.github.com/repos/codedaptive/mootx01-ce/releases/latest"

    // MARK: latestTag

    /// When the GitHub API returns the same version that is installed, latestTag()
    /// must return nil to signal that no upgrade is needed.
    @Test func latestTagReturnsNilWhenAlreadyCurrent() async throws {
        let json = #"{"tag_name":"v1.0.0","name":"Release v1.0.0"}"#
        let downloader = ReleaseDownloader(
            repo: testRepo,
            currentVersion: "1.0.0",
            fetchData: mockFetch([ok(apiURL, json)]))

        let tag = try await downloader.latestTag()
        #expect(tag == nil, "Should return nil when the remote tag matches currentVersion")
    }

    /// When the GitHub API returns a higher version, latestTag() must return the
    /// raw tag string (including the leading v) so the caller can build the asset URL.
    @Test func latestTagReturnsTagWhenNewerAvailable() async throws {
        let json = #"{"tag_name":"v1.1.0","name":"Release v1.1.0"}"#
        let downloader = ReleaseDownloader(
            repo: testRepo,
            currentVersion: "1.0.0",
            fetchData: mockFetch([ok(apiURL, json)]))

        let tag = try await downloader.latestTag()
        #expect(tag == "v1.1.0", "Should return the raw tag when a newer version exists")
    }

    // MARK: download — checksum verification

    /// When the downloaded asset's SHA-256 does not match checksums.txt, download()
    /// must throw UpgradeError.checksumMismatch before attempting tar extraction.
    @Test func downloadAbortsOnBadChecksum() async throws {
        let tag = "v1.1.0"

        // Build platform-specific asset name matching currentPlatformOS/Arch().
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        #if os(macOS)
        let os = "macos"
        #else
        let os = "linux"
        #endif
        let tarball  = "mootx01-\(tag)-\(os)-\(arch).tar.gz"
        let base     = "https://github.com/codedaptive/mootx01-ce/releases/download/\(tag)"

        // Deliberately wrong checksum — 64 zeros, will never match any real file.
        let badChecksum = "0000000000000000000000000000000000000000000000000000000000000000  \(tarball)\n"
        let fakeAsset   = Data("not a real tarball".utf8)

        let downloader = ReleaseDownloader(
            repo: testRepo,
            currentVersion: "1.0.0",
            fetchData: mockFetch([
                ok("\(base)/\(tarball)", fakeAsset),
                ok("\(base)/checksums.txt", badChecksum),
            ]))

        do {
            _ = try await downloader.download(tag: tag)
            Issue.record("Expected UpgradeError.checksumMismatch — download should have thrown")
        } catch let e as UpgradeError {
            if case .checksumMismatch = e { /* expected */ } else {
                Issue.record("Wrong UpgradeError case thrown: \(e)")
            }
        }
    }

    // MARK: replace

    /// replace() must delegate to Installer.placeBinary(force: true) and return the
    /// path of the placed binary at ~/.mootx01/bin/mootx01.
    @Test func replaceCallsPlaceBinaryWithForceTrue() throws {
        // Create an isolated temp tree: a fake source binary and a fake home directory.
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mootx01-replace-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let fakeHome   = tmpRoot.appendingPathComponent("home", isDirectory: true)
        let fakeBinary = tmpRoot.appendingPathComponent("mootx01-new")
        try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)

        // placeBinary checks isExecutableFile — write a minimal shell script and chmod +x.
        try Data("#!/bin/sh\necho 1.1.0\n".utf8).write(to: fakeBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBinary.path)

        let downloader = ReleaseDownloader(repo: testRepo, currentVersion: "1.0.0")
        let placed = try downloader.replace(newBinary: fakeBinary, homeDirectory: fakeHome)

        let expectedPath = MootPaths.installedBinaryURL(homeDirectory: fakeHome).path
        #expect(placed == expectedPath,
            "replace() must return the canonical installed binary path")
        #expect(FileManager.default.fileExists(atPath: expectedPath),
            "Binary must exist at the installed path after replace()")
    }
}
