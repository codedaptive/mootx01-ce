// ReleaseDownloader.swift
//
// Online upgrade path for `mootx01 upgrade`. Mirrors scripts/install.sh:
// fetch the latest GitHub release tag, download the platform asset,
// verify SHA-256 via CryptoKit, extract the binary, and delegate
// placement to Installer.placeBinary.
//
// Repo slug is "codedaptive/mootx01-ce", matching install.sh:15.
// Asset naming follows install.sh:136: mootx01-{tag}-{os}-{arch}.tar.gz
// where {tag} is the raw GitHub tag (e.g. "v1.0.0") and {os}/{arch}
// are lowercase strings matching detect_os()/detect_arch() in install.sh.

import CryptoKit
import Foundation

// MARK: - ReleaseDownloader

/// Downloads, verifies, and places a new mootx01 binary from a GitHub release.
///
/// The network fetch function is injectable for unit testing; production
/// callers use the default `URLSession.shared`-backed initializer.
public struct ReleaseDownloader: Sendable {

    /// GitHub repository slug, e.g. "codedaptive/mootx01-ce".
    public let repo: String

    /// Currently installed semver string, e.g. "1.0.0" (no leading v).
    public let currentVersion: String

    // Async data-fetch function injected for tests; defaults to URLSession.shared.
    private let fetchData: @Sendable (URL) async throws -> (Data, URLResponse)

    /// Production initializer — uses URLSession.shared for all network calls.
    public init(repo: String, currentVersion: String) {
        self.repo = repo
        self.currentVersion = currentVersion
        self.fetchData = { url in try await URLSession.shared.data(from: url) }
    }

    /// Test initializer — accepts an injectable fetch function to stub network calls.
    init(
        repo: String,
        currentVersion: String,
        fetchData: @Sendable @escaping (URL) async throws -> (Data, URLResponse)
    ) {
        self.repo = repo
        self.currentVersion = currentVersion
        self.fetchData = fetchData
    }

    // MARK: - Public API

    /// Fetches the latest GitHub release tag and compares it to the current version.
    ///
    /// Hits `https://api.github.com/repos/{repo}/releases/latest`, decodes
    /// `tag_name`, strips the leading `v` for semver comparison, and returns
    /// the raw tag string (e.g. "v1.1.0") if a newer version exists, or `nil`
    /// if the installed version is already current.
    ///
    /// - Returns: raw GitHub tag string if an upgrade is available, nil if current.
    /// - Throws: `UpgradeError.invalidAPIResponse` on JSON decode failure; network
    ///   errors from URLSession propagate as-is.
    public func latestTag() async throws -> String? {
        let apiURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        let (data, _) = try await fetchData(apiURL)

        // Decode tag_name from GitHub's releases/latest JSON response.
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tagName = json["tag_name"] as? String
        else {
            throw UpgradeError.invalidAPIResponse("missing tag_name in GitHub releases/latest response")
        }

        // Strip leading 'v' for numeric semver comparison (e.g. "v1.1.0" → "1.1.0").
        let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

        guard isVersion(remoteVersion, newerThan: currentVersion) else {
            return nil  // already current
        }
        return tagName
    }

    /// Downloads the platform asset for `tag`, verifies SHA-256, extracts the
    /// binary, and returns a URL pointing to the extracted `mootx01` binary.
    ///
    /// The asset name mirrors install.sh:136: `mootx01-{tag}-{os}-{arch}.tar.gz`.
    /// The checksum file `checksums.txt` is downloaded from the same release base
    /// and verified against the tarball using CryptoKit.SHA256. Extraction uses
    /// `/usr/bin/tar -xzf`.
    ///
    /// - Parameter tag: raw GitHub tag string (e.g. "v1.0.0") from `latestTag()`.
    /// - Returns: URL of the extracted binary inside a temporary directory.
    /// - Throws: `UpgradeError.checksumMismatch` if SHA-256 verification fails;
    ///   `UpgradeError.extractionFailed` if tar exits non-zero or binary is absent.
    public func download(tag: String) async throws -> URL {
        let platformOS   = currentPlatformOS()
        let platformArch = currentPlatformArch()
        let tarball  = "mootx01-\(tag)-\(platformOS)-\(platformArch).tar.gz"
        let base     = "https://github.com/\(repo)/releases/download/\(tag)"

        // Isolated temp directory per tag to avoid collisions across invocations.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mootx01-upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let tarballURL   = tmpDir.appendingPathComponent(tarball)
        let checksumsURL = tmpDir.appendingPathComponent("checksums.txt")

        // Download asset and checksums file.
        let assetURL = URL(string: "\(base)/\(tarball)")!
        let (assetData, _) = try await fetchData(assetURL)
        try assetData.write(to: tarballURL)

        let csURL = URL(string: "\(base)/checksums.txt")!
        let (csData, _) = try await fetchData(csURL)
        try csData.write(to: checksumsURL)

        // Verify SHA-256 before extraction — abort on mismatch without touching
        // the install path (mirrors verify_checksum in scripts/install.sh).
        try verifySHA256(tarballURL: tarballURL, checksumsURL: checksumsURL, tarball: tarball)

        // Extract: binary lives at tmpDir/mootx01 after the tarball is unpacked.
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", tarballURL.path, "-C", tmpDir.path]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else {
            throw UpgradeError.extractionFailed("tar exited with status \(tar.terminationStatus)")
        }

        let binaryURL = tmpDir.appendingPathComponent("mootx01")
        guard FileManager.default.fileExists(atPath: binaryURL.path) else {
            throw UpgradeError.extractionFailed("mootx01 binary not found in extracted archive at \(binaryURL.path)")
        }
        return binaryURL
    }

    /// Places the downloaded binary at the installed path via `Installer.placeBinary`.
    ///
    /// Passes `force: true` so the freshly-downloaded binary always replaces the
    /// installed one, regardless of whether it is currently running.
    ///
    /// - Returns: absolute path of the placed binary.
    @discardableResult
    public func replace(newBinary: URL, homeDirectory: URL) throws -> String {
        try Installer.placeBinary(
            sourcePath: newBinary.path,
            homeDirectory: homeDirectory,
            force: true)
    }

    // MARK: - Private helpers

    /// Verify that the SHA-256 of `tarballURL` matches the entry for `tarball` in
    /// `checksumsURL`. File format mirrors `shasum -a 256` output:
    ///   `<hex>  <filename>`
    private func verifySHA256(tarballURL: URL, checksumsURL: URL, tarball: String) throws {
        let assetData = try Data(contentsOf: tarballURL)
        let actualDigest   = SHA256.hash(data: assetData)
        let actualHex      = actualDigest.map { String(format: "%02x", $0) }.joined()

        let checksumText = try String(contentsOf: checksumsURL, encoding: .utf8)
        let lines = checksumText.components(separatedBy: .newlines)

        guard let matchingLine = lines.first(where: { $0.contains(tarball) }),
              let expected = matchingLine.split(separator: " ", maxSplits: 1).first.map(String.init)
        else {
            throw UpgradeError.checksumMismatch("no checksum entry found for \(tarball) in checksums.txt")
        }

        guard actualHex.lowercased() == expected.lowercased() else {
            throw UpgradeError.checksumMismatch(
                "SHA-256 mismatch for \(tarball)\n  expected: \(expected)\n  actual:   \(actualHex)"
            )
        }
    }

    /// Compare two semver strings (e.g. "1.1.0" vs "1.0.0") component by component.
    /// Returns true if `a` is strictly greater than `b`. Non-numeric components are
    /// treated as 0.
    private func isVersion(_ a: String, newerThan b: String) -> Bool {
        let partsA = a.split(separator: ".").map { Int($0) ?? 0 }
        let partsB = b.split(separator: ".").map { Int($0) ?? 0 }
        let count  = max(partsA.count, partsB.count)
        for i in 0..<count {
            let va = i < partsA.count ? partsA[i] : 0
            let vb = i < partsB.count ? partsB[i] : 0
            if va != vb { return va > vb }
        }
        return false  // equal
    }

    /// Platform OS token matching install.sh detect_os(): "macos" or "linux".
    private func currentPlatformOS() -> String {
        #if os(macOS)
        return "macos"
        #else
        return "linux"
        #endif
    }

    /// Platform arch token matching install.sh detect_arch(): "arm64" or "x86_64".
    private func currentPlatformArch() -> String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}

// MARK: - UpgradeError

/// Errors thrown by the online upgrade path.
public enum UpgradeError: Error, Sendable {
    /// GitHub API returned an unexpected payload (missing or malformed tag_name).
    case invalidAPIResponse(String)
    /// SHA-256 of the downloaded asset does not match checksums.txt.
    case checksumMismatch(String)
    /// tar extraction exited non-zero or the expected binary was absent.
    case extractionFailed(String)
    /// Binary write failed due to insufficient permissions.
    case permissionDenied(String)
}
