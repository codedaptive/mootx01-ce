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

// MARK: - Platform helpers

#if !os(macOS)
/// Locate the `minisign` executable via `which(1)`. Returns the full path when
/// minisign is present in PATH, `nil` when it is absent. Used by tests that
/// require minisign to actually run (as opposed to tests that mock the fetch
/// layer and never reach the subprocess).
private func findMinisignInPath() -> String? {
    // Try which(1) at the two common POSIX locations.
    for whichPath in ["/usr/bin/which", "/bin/which"] {
        guard FileManager.default.isExecutableFile(atPath: whichPath) else { continue }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: whichPath)
        p.arguments = ["minisign"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { continue }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
    return nil
}
#endif

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

    /// A stable release outranks a beta with the same numeric core.
    @Test func latestStableTagOutranksCurrentBeta() async throws {
        let json = #"{"tag_name":"v1.1.0","name":"Release v1.1.0"}"#
        let downloader = ReleaseDownloader(
            repo: testRepo,
            currentVersion: "1.1.0-beta-03",
            fetchData: mockFetch([ok(apiURL, json)]))

        let tag = try await downloader.latestTag()
        #expect(tag == "v1.1.0")
    }

    /// The zero-padded beta sequence remains ordered before the stable release.
    @Test func laterBetaSequenceOutranksEarlierBeta() async throws {
        let json = #"{"tag_name":"1.1.0-beta-04","name":"Beta 04"}"#
        let downloader = ReleaseDownloader(
            repo: testRepo,
            currentVersion: "1.1.0-beta-03",
            fetchData: mockFetch([ok(apiURL, json)]))

        let tag = try await downloader.latestTag()
        #expect(tag == "1.1.0-beta-04")
    }

    /// A three-digit beta counter must sort AFTER a two-digit one.
    ///
    /// SemVer splits prerelease identifiers on "." and not "-", so this
    /// project's `beta-NN` suffix is a single TEXT identifier. Plain string
    /// order puts "beta-100" before "beta-99", which would silently stop
    /// offering upgrades once the candidate counter reached three digits — and
    /// the candidate pipeline explicitly permits `[0-9]{2,}`.
    @Test func threeDigitBetaCounterOutranksTwoDigit() async throws {
        #expect(
            ReleaseDownloader.isVersion("1.1.0-beta-100", newerThan: "1.1.0-beta-99"),
            "beta-100 must be newer than beta-99; plain string order gets this backwards")
        #expect(
            !ReleaseDownloader.isVersion("1.1.0-beta-99", newerThan: "1.1.0-beta-100"),
            "the comparison must be antisymmetric across the digit-count boundary")
        // Ordinary same-width ordering is unaffected.
        #expect(ReleaseDownloader.isVersion("1.1.0-beta-09", newerThan: "1.1.0-beta-08"))
        // A stable release still outranks any beta with the same core.
        #expect(ReleaseDownloader.isVersion("1.1.0", newerThan: "1.1.0-beta-100"))
    }

    /// `latestTagIgnoringOrder` reports what is published without judging
    /// whether it is newer, so the CLI can distinguish "you are current" from
    /// "you are AHEAD of the feed" — the case that told a beta tester
    /// "Already up to date" while the feed sat at an older stable release.
    @Test func latestTagIgnoringOrderReportsOlderRemote() async throws {
        let json = #"{"tag_name":"v1.0.38","name":"Release v1.0.38"}"#
        let downloader = ReleaseDownloader(
            repo: testRepo,
            currentVersion: "1.1.0-beta-08",
            fetchData: mockFetch([ok(apiURL, json)]))

        // The ordering-aware call says "nothing to offer"...
        #expect(try await downloader.latestTag() == nil)
        // ...while the plain read still reports what is actually published.
        #expect(try await downloader.latestTagIgnoringOrder() == "v1.0.38")
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

    /// A matching SHA-256 line is not enough on Linux/POSIX: checksums.txt must
    /// also have a detached minisign signature. This prevents a tampered release
    /// endpoint from supplying a malicious tarball plus a matching checksum file.
    @Test func downloadRequiresMinisignSignatureWhenChecksumMatches() async throws {
        #if !os(macOS)
        let tag = "v1.1.0"

        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let os = "linux"
        let tarball  = "mootx01-\(tag)-\(os)-\(arch).tar.gz"
        let base     = "https://github.com/codedaptive/mootx01-ce/releases/download/\(tag)"

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mootx01-minisig-required-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let contentDir = tmpDir.appendingPathComponent("contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentDir, withIntermediateDirectories: true)
        let fakeBinary = contentDir.appendingPathComponent("mootx01")
        try Data("#!/bin/sh\necho tampered\n".utf8).write(to: fakeBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBinary.path)

        let tarballURL = tmpDir.appendingPathComponent(tarball)
        let pack = Process()
        pack.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        pack.arguments = ["-czf", tarballURL.path, "-C", contentDir.path, "."]
        pack.standardError = Pipe()
        try pack.run()
        pack.waitUntilExit()
        guard pack.terminationStatus == 0 else {
            Issue.record("Test setup: tar -czf exited \(pack.terminationStatus) — cannot continue")
            return
        }

        let tarballData = try Data(contentsOf: tarballURL)
        let digestProcess = Process()
        digestProcess.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        digestProcess.arguments = ["-a", "256", tarballURL.path]
        let digestPipe = Pipe()
        digestProcess.standardOutput = digestPipe
        try digestProcess.run()
        let digestOutput = digestPipe.fileHandleForReading.readDataToEndOfFile()
        digestProcess.waitUntilExit()
        guard digestProcess.terminationStatus == 0,
              let digest = String(decoding: digestOutput, as: UTF8.self).split(separator: " ").first
        else {
            Issue.record("Test setup: shasum -a 256 exited \(digestProcess.terminationStatus)")
            return
        }
        let checksum = "\(digest)  \(tarball)\n"

        let downloader = ReleaseDownloader(
            repo: testRepo,
            currentVersion: "1.0.0",
            fetchData: mockFetch([
                ok("\(base)/\(tarball)", tarballData),
                ok("\(base)/checksums.txt", checksum),
                // No checksums.txt.minisig fixture: the downloader must request
                // it and fail closed rather than extracting the matching-checksum tarball.
            ]))

        do {
            _ = try await downloader.download(tag: tag)
            Issue.record("Expected failure before extraction without checksums.txt.minisig")
        } catch let e as URLError {
            #expect(e.code == .badURL, "mockFetch should fail on the required minisig URL")
        } catch {
            Issue.record("Unexpected error type when minisig is absent: \(error)")
        }
        #endif
    }

        /// A structurally-valid minisign signature made with a key OTHER THAN the
    /// embedded production public key must be rejected. This exercises the actual
    /// signature-validation rejection path: checksum verification passes (the
    /// SHA-256 is correct), the .minisig URL is fetched successfully, but
    /// `minisign -V` exits non-zero because the signature was made with a
    /// throwaway key that the embedded BC4D1E6ABCB5B788 pubkey cannot verify.
    ///
    /// Gated #if !os(macOS): the production verify path skips minisign on macOS
    /// (Gatekeeper / Developer ID handles code-signing there). Also requires
    /// minisign in PATH; returns early when minisign is absent so CI stays green
    /// on runners that do not have it installed — the "minisign unavailable"
    /// rejection is a separate production code path, not what this test covers.
    @Test func downloadRejectsWrongKeyMinisignSignature() async throws {
        #if !os(macOS)
        guard let minisignPath = findMinisignInPath() else { return }

        let tag = "v1.1.0"
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let os = "linux"
        let tarball = "mootx01-\(tag)-\(os)-\(arch).tar.gz"
        let base    = "https://github.com/codedaptive/mootx01-ce/releases/download/\(tag)"

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mootx01-wrong-sig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Build a minimal valid tarball so verifySHA256 has real bytes to hash.
        let contentDir = tmpDir.appendingPathComponent("contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentDir, withIntermediateDirectories: true)
        let fakeBinary = contentDir.appendingPathComponent("mootx01")
        try Data("#!/bin/sh\necho fake\n".utf8).write(to: fakeBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBinary.path)
        let tarballURL = tmpDir.appendingPathComponent(tarball)
        let pack = Process()
        pack.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        pack.arguments = ["-czf", tarballURL.path, "-C", contentDir.path, "."]
        pack.standardError = Pipe()
        try pack.run()
        pack.waitUntilExit()
        guard pack.terminationStatus == 0 else {
            Issue.record("Test setup: tar -czf exited \(pack.terminationStatus)")
            return
        }
        let tarballData = try Data(contentsOf: tarballURL)

        // Compute the correct SHA-256 so verifySHA256 passes and execution
        // reaches verifyMinisignSignature.
        let shasum = Process()
        shasum.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        shasum.arguments = ["-a", "256", tarballURL.path]
        let shasumPipe = Pipe()
        shasum.standardOutput = shasumPipe
        shasum.standardError = Pipe()
        try shasum.run()
        let shasumRaw = shasumPipe.fileHandleForReading.readDataToEndOfFile()
        shasum.waitUntilExit()
        guard shasum.terminationStatus == 0,
              let digest = String(decoding: shasumRaw, as: UTF8.self)
                  .split(separator: " ").first
        else {
            Issue.record("Test setup: shasum -a 256 failed")
            return
        }
        let checksumText = "\(digest)  \(tarball)\n"

        // Write checksums.txt to disk so minisign can sign its content.
        let checksumsFile = tmpDir.appendingPathComponent("checksums.txt")
        try Data(checksumText.utf8).write(to: checksumsFile)

        // Generate a throwaway keypair — NOT the embedded production pubkey.
        // -W skips passphrase so keygen and signing are non-interactive.
        let throwawayPub = tmpDir.appendingPathComponent("throwaway.pub")
        let throwawaySec = tmpDir.appendingPathComponent("throwaway.sec")
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: minisignPath)
        keygen.arguments = ["-G", "-p", throwawayPub.path, "-s", throwawaySec.path, "-W"]
        keygen.standardInput = FileHandle.nullDevice
        keygen.standardOutput = Pipe()
        keygen.standardError = Pipe()
        try keygen.run()
        keygen.waitUntilExit()
        guard keygen.terminationStatus == 0 else {
            Issue.record("Test setup: minisign -G exited \(keygen.terminationStatus)")
            return
        }

        // Sign checksums.txt with the throwaway key. The signature is structurally
        // valid minisign format but was made with a key the embedded pubkey cannot
        // verify — minisign -V will exit non-zero when attempted.
        let minisigFile = tmpDir.appendingPathComponent("checksums.txt.minisig")
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: minisignPath)
        sign.arguments = ["-S", "-s", throwawaySec.path, "-m", checksumsFile.path, "-x", minisigFile.path]
        sign.standardInput = FileHandle.nullDevice
        sign.standardOutput = Pipe()
        sign.standardError = Pipe()
        try sign.run()
        sign.waitUntilExit()
        guard sign.terminationStatus == 0 else {
            Issue.record("Test setup: minisign -S exited \(sign.terminationStatus)")
            return
        }
        let wrongKeySigData = try Data(contentsOf: minisigFile)

        // Wire mock fetch: correct tarball + correct checksum + wrong-key minisig.
        // verifySHA256 passes; verifyMinisignSignature must reject the bad sig.
        let downloader = ReleaseDownloader(
            repo: testRepo,
            currentVersion: "1.0.0",
            fetchData: mockFetch([
                ok("\(base)/\(tarball)", tarballData),
                ok("\(base)/checksums.txt", checksumText),
                ok("\(base)/checksums.txt.minisig", wrongKeySigData),
            ]))

        do {
            _ = try await downloader.download(tag: tag)
            Issue.record("Expected UpgradeError.signatureVerificationFailed — wrong-key minisig should be rejected before extraction")
        } catch let e as UpgradeError {
            if case .signatureVerificationFailed = e { /* expected: minisign rejected the wrong key */ } else {
                Issue.record("Wrong UpgradeError case: expected signatureVerificationFailed, got \(e)")
            }
        } catch {
            Issue.record("Unexpected error type (expected UpgradeError.signatureVerificationFailed): \(error)")
        }
        #endif
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
