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

    // MARK: unsafeMemberReason — zip-slip path safety predicate

    /// Absolute paths (starting with /) in a tar archive member allow overwriting
    /// files outside the extraction root. ReleaseDownloader must reject them.
    @Test func unsafeMemberReasonRejectsAbsolutePaths() {
        #expect(ReleaseDownloader.unsafeMemberReason("/etc/passwd") != nil,
            "Absolute Unix path must be rejected")
        #expect(ReleaseDownloader.unsafeMemberReason("/absolute/deep/path") != nil,
            "Deep absolute path must be rejected")
    }

    /// A member path containing `..` at any depth allows escaping the extraction
    /// root (zip-slip). ReleaseDownloader must reject all such paths.
    @Test func unsafeMemberReasonRejectsTraversalComponents() {
        #expect(ReleaseDownloader.unsafeMemberReason("../etc/passwd") != nil,
            "Leading .. component must be rejected")
        #expect(ReleaseDownloader.unsafeMemberReason("subdir/../../etc/passwd") != nil,
            "Deep .. traversal must be rejected")
        #expect(ReleaseDownloader.unsafeMemberReason("a/b/../../../etc/evil") != nil,
            "Multi-hop traversal must be rejected")
    }

    /// Normal relative paths (plain filenames and subdirectories) must be accepted.
    @Test func unsafeMemberReasonAcceptsSafePaths() {
        #expect(ReleaseDownloader.unsafeMemberReason("mootx01") == nil,
            "Bare filename must be accepted")
        #expect(ReleaseDownloader.unsafeMemberReason("moot-mgr") == nil,
            "Bare filename with hyphen must be accepted")
        #expect(ReleaseDownloader.unsafeMemberReason("data/subdir/file.txt") == nil,
            "Normal subdirectory path must be accepted")
        // A filename that begins with ".." as characters (but is not the parent-dir
        // component) must be accepted — e.g. "..dotfile" is a valid relative name.
        #expect(ReleaseDownloader.unsafeMemberReason("..dotfile") == nil,
            "Filename starting with '..' but not a traversal component must be accepted")
    }

    /// Windows absolute-path forms that the old hasPrefix("/") check missed.
    /// All must be rejected regardless of the host OS this validator runs on.
    @Test func unsafeMemberReasonRejectsWindowsAbsolutePaths() {
        // Drive-letter with backslash (C:\path) — standard Windows absolute.
        #expect(ReleaseDownloader.unsafeMemberReason("C:\\evil") != nil,
            "C:\\evil (drive + backslash) must be rejected")
        // Drive-letter with forward slash (C:/path) — missed by old leading-/ check.
        #expect(ReleaseDownloader.unsafeMemberReason("C:/evil") != nil,
            "C:/evil (drive + forward slash) must be rejected")
        // Drive-relative path without separator (C:relative) — resolves relative to
        // the current directory of drive C; still unsafe.
        #expect(ReleaseDownloader.unsafeMemberReason("C:relative") != nil,
            "C:relative (drive-relative, no separator) must be rejected")
        // Leading backslash — rooted to the current drive (\path).
        #expect(ReleaseDownloader.unsafeMemberReason("\\evil") != nil,
            "\\evil (leading backslash) must be rejected")
        // UNC path (\\server\share\...) — leading \\ caught by leading \.
        #expect(ReleaseDownloader.unsafeMemberReason("\\\\srv\\share\\evil") != nil,
            "\\\\srv\\share\\evil (UNC path) must be rejected")
        // Windows-style .. traversal with backslash separator — must be caught
        // on macOS/Linux where NSString.pathComponents splits on / only.
        #expect(ReleaseDownloader.unsafeMemberReason("..\\..\\evil") != nil,
            "..\\..\\evil (backslash traversal) must be rejected")
        #expect(ReleaseDownloader.unsafeMemberReason("a\\..\\..\\evil") != nil,
            "a\\..\\..\\evil (nested backslash traversal) must be rejected")
    }

    // MARK: validateTarballMembers — pipe-drain stress test

    /// Verify that validateTarballMembers returns without deadlocking when the
    /// tar -tf listing exceeds the OS pipe buffer (~64 KiB). The fix drains both
    /// stdout and stderr concurrently before waitUntilExit(); without it, this
    /// test would block until the one-minute timeLimit fires (manifesting as a
    /// test failure rather than hanging CI indefinitely).
    ///
    /// Member count and name length: 3000 members × ~25 bytes/line
    /// (./safe_member_NNNNNN.dat\n) ≈ 75 KB — comfortably above the 64 KiB
    /// OS pipe buffer floor on macOS and Linux.
    ///
    /// validateTarballMembers is internal (not private) specifically so this
    /// test can call it directly via @testable import, avoiding the overhead
    /// of synthesising a full GitHub download fixture (checksums.txt, network
    /// stub, platform detection).
    @Test(.timeLimit(.minutes(1)))
    func validateTarballMembersCompletesOnLargeArchive() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mootx01-pipe-stress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create member files in a subdirectory so the tarball is created with
        // -C contentDir, producing listing lines like ./safe_member_000000.dat
        let contentDir = tmpDir.appendingPathComponent("members", isDirectory: true)
        try FileManager.default.createDirectory(at: contentDir, withIntermediateDirectories: true)
        for i in 0..<3000 {
            let name = String(format: "safe_member_%06d.dat", i)
            FileManager.default.createFile(
                atPath: contentDir.appendingPathComponent(name).path,
                contents: nil)
        }

        // Pack into .tar.gz using macOS bsdtar.
        let tarball = tmpDir.appendingPathComponent("stress.tar.gz")
        let pack = Process()
        pack.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        pack.arguments = ["-czf", tarball.path, "-C", contentDir.path, "."]
        pack.standardError = Pipe()  // suppress tar noise from test output
        try pack.run()
        pack.waitUntilExit()
        guard pack.terminationStatus == 0 else {
            Issue.record("Test setup: tar -czf exited \(pack.terminationStatus) — cannot continue")
            return
        }

        // All members are safe relative paths; validateTarballMembers must
        // return normally. A pipe-buffer deadlock regression would block here
        // until the 30-second timeLimit fires, manifesting as a test failure.
        let downloader = ReleaseDownloader(repo: "test/repo", currentVersion: "0.0.0")
        try downloader.validateTarballMembers(tarballURL: tarball)
    }

    /// Verify that validateTarballMembers rejects a tarball containing an
    /// absolute-path member (zip-slip). Uses a small archive so the test is
    /// fast; correctness of unsafeMemberReason is covered separately.
    @Test func validateTarballMembersRejectsZipSlipArchive() throws {
        // Build a .tar.gz with one absolute-path entry using the POSIX
        // --absolute-names flag so bsdtar writes the / prefix verbatim.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mootx01-zipslip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Write a real file at a known absolute path inside tmp, then bundle
        // it with --absolute-names so the archive member carries the full path.
        let victimFile = tmpDir.appendingPathComponent("safe_file.txt")
        try Data("hello".utf8).write(to: victimFile)

        let maliciousTarball = tmpDir.appendingPathComponent("malicious.tar.gz")
        let pack = Process()
        pack.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        // -P (--absolute-paths in bsdtar) preserves the leading / in the archive
        // member name. macOS ships bsdtar; GNU tar uses --absolute-names instead.
        pack.arguments = ["-czPf", maliciousTarball.path, victimFile.path]
        pack.standardError = Pipe()
        try pack.run()
        pack.waitUntilExit()
        guard pack.terminationStatus == 0 else {
            Issue.record("Test setup: tar -czf --absolute-names exited \(pack.terminationStatus) — cannot continue")
            return
        }

        let downloader = ReleaseDownloader(repo: "test/repo", currentVersion: "0.0.0")
        do {
            try downloader.validateTarballMembers(tarballURL: maliciousTarball)
            Issue.record("Expected UpgradeError.extractionFailed for zip-slip archive — no throw")
        } catch let e as UpgradeError {
            if case .extractionFailed = e { /* expected */ } else {
                Issue.record("Wrong UpgradeError case: \(e)")
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
