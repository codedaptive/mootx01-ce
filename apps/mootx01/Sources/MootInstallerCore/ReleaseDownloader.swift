// ReleaseDownloader.swift
//
// Online upgrade path for `mootx01 upgrade`. Mirrors scripts/install.sh:
// fetch the latest GitHub release tag, download the platform asset,
// verify SHA-256 via CryptoKit, authenticate checksums.txt with minisign on
// Linux/POSIX (macOS relies on Developer ID + Gatekeeper), extract the binary,
// and delegate placement to Installer.placeBinary.
//
// Repo slug is "codedaptive/mootx01-ee", matching install.sh:15.
// Asset naming follows install.sh:136: mootx01-{tag}-{os}-{arch}.tar.gz
// where {tag} is the raw GitHub tag (e.g. "v1.0.0") and {os}/{arch}
// are lowercase strings matching detect_os()/detect_arch() in install.sh.

import CryptoKit
import Foundation

private let minisignPublicKey = """
untrusted comment: minisign public key BC4D1E6ABCB5B788
RWSIt7W8ah5NvMXMLQ3+T2flXrQ+J6xoDxDrL62I+8iEkR04YIAlXa12
"""

// MARK: - ReleaseDownloader

/// Downloads, verifies, and places a new mootx01 binary from a GitHub release.
///
/// The network fetch function is injectable for unit testing; production
/// callers use the default `URLSession.shared`-backed initializer.
public struct ReleaseDownloader: Sendable {

    /// GitHub repository slug, e.g. "codedaptive/mootx01-ee".
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

    /// Downloads the platform asset for `tag`, verifies SHA-256, verifies the
    /// detached minisign signature for `checksums.txt` on non-macOS platforms,
    /// extracts the binary, and returns a URL pointing to the extracted
    /// `mootx01` binary.
    ///
    /// The asset name mirrors install.sh:136: `mootx01-{tag}-{os}-{arch}.tar.gz`.
    /// The checksum file `checksums.txt` is downloaded from the same release base,
    /// authenticated against the embedded Ed25519 minisign public key on
    /// Linux/POSIX, and verified against the tarball using CryptoKit.SHA256.
    /// Extraction uses `/usr/bin/tar -xzf`.
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
        let minisigURL   = tmpDir.appendingPathComponent("checksums.txt.minisig")

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

        #if !os(macOS)
        // Authenticate checksums.txt against the bundled Ed25519 trust root before
        // extracting or installing anything. Without this, an attacker who can
        // tamper with release assets can ship a malicious tarball plus a matching
        // unauthenticated checksums.txt and satisfy the SHA-256 check.
        let sigURL = URL(string: "\(base)/checksums.txt.minisig")!
        let (sigData, _) = try await fetchData(sigURL)
        try sigData.write(to: minisigURL)
        try verifyMinisignSignature(checksumsURL: checksumsURL, signatureURL: minisigURL)
        #endif

        // Validate all archive members before extraction to prevent zip-slip:
        // an archive member with an absolute path or .. component could escape
        // tmpDir and overwrite arbitrary files (planned hardening — fails CLOSED).
        try validateTarballMembers(tarballURL: tarballURL)

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

    /// Verify the detached minisign signature over checksums.txt using the
    /// repository's embedded public key. Mirrors install.sh and the Rust vertical:
    /// fail closed if the key is a placeholder, minisign is unavailable, or the
    /// signature does not validate.
    private func verifyMinisignSignature(checksumsURL: URL, signatureURL: URL) throws {
        if minisignPublicKey.contains("PLACEHOLDER") {
            throw UpgradeError.signatureVerificationFailed(
                "minisign public key is a PLACEHOLDER — signature verification not yet active"
            )
        }

        let keyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mootx01-minisign-pub-\(UUID().uuidString).pub")
        try minisignPublicKey.write(to: keyURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: keyURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "minisign", "-V",
            "-p", keyURL.path,
            "-m", checksumsURL.path,
            "-x", signatureURL.path,
        ]
        let errPipe = Pipe()
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw UpgradeError.signatureVerificationFailed(
                "minisign is required for release signature verification but was not found. "
                + "Install minisign and retry; do not bypass this check."
            )
        }
        let stderr = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail = String(decoding: stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpgradeError.signatureVerificationFailed(
                "minisign signature verification FAILED for checksums.txt"
                + (detail.isEmpty ? "" : ": \(detail)")
            )
        }
    }

    /// Check whether a single archive member path (one line from `tar -tf`) is safe
    /// to extract into a destination directory. Returns a non-nil reason string when
    /// the member is unsafe — an absolute/rooted path or any `..` component — and
    /// `nil` when the member is safe.
    ///
    /// Checks both Unix and Windows absolute-path forms explicitly at the string
    /// level, because this validator mirrors the Rust port which runs on Windows
    /// (bsdtar member names may carry Windows-style paths):
    ///   - leading `/`  — Unix absolute
    ///   - leading `\`  — Windows rooted-to-current-drive (including UNC `\\server`)
    ///   - leading `[A-Za-z]:` — Windows drive-letter prefix (C:\, C:/, C:relative)
    ///
    /// `..` traversal splits on BOTH `/` and `\` so Windows-style `a\..\..` paths
    /// are caught. `NSString.pathComponents` splits on `/` only and would miss
    /// backslash-separated traversal on non-Windows hosts.
    ///
    /// Separated from `validateTarballMembers` so the path-safety logic can be
    /// unit-tested without requiring a real tar archive on disk.
    internal static func unsafeMemberReason(_ memberPath: String) -> String? {
        // Reject absolute or rooted paths. Check raw string forms explicitly:
        //   - leading / or \ catches Unix absolute and Windows rooted paths
        //     (including UNC \\server\share whose first char is \)
        //   - leading [A-Za-z]: catches all Windows drive-letter forms:
        //     C:\path, C:/path, C:relative (drive-relative, still unsafe)
        let scalars = memberPath.unicodeScalars
        if let first = scalars.first {
            if first == "/" || first == "\\" {
                return "absolute/rooted path in archive member: \(memberPath.debugDescription)"
            }
        }
        // Drive-letter prefix: two or more chars, first is ASCII letter, second is ':'.
        if memberPath.count >= 2 {
            let idx0 = memberPath.unicodeScalars.startIndex
            let idx1 = memberPath.unicodeScalars.index(after: idx0)
            let c0 = memberPath.unicodeScalars[idx0]
            let c1 = memberPath.unicodeScalars[idx1]
            if c1 == ":" && ((c0 >= "A" && c0 <= "Z") || (c0 >= "a" && c0 <= "z")) {
                return "absolute/rooted path in archive member: \(memberPath.debugDescription)"
            }
        }
        // Reject any `..` path component at any depth — `foo/../../etc/passwd`
        // is a traversal even though it does not start with `..`. Split on both
        // `/` and `\` so Windows-style `a\..\..` paths are caught (NSString
        // pathComponents splits on `/` only and misses backslash separators).
        let segments = memberPath.components(separatedBy: CharacterSet(charactersIn: "/\\"))
        if segments.contains("..") {
            return "directory traversal component '..' in archive member: \(memberPath.debugDescription)"
        }
        return nil
    }

    /// Run `tar -tf` to list all members and reject the archive when any member
    /// has an absolute path or `..` traversal component. Called between checksum
    /// verification and `tar -xzf` so a malformed archive is refused before any
    /// bytes land on the filesystem.
    ///
    /// **Pipe-drain deadlock prevention:** Both stdout and stderr pipes are drained
    /// to EOF on concurrent queues BEFORE `waitUntilExit()` is called. Without this,
    /// a tar listing large enough to fill the OS pipe buffer (~64 KiB) causes a
    /// deadlock: tar blocks in write(2) while the parent blocks in waitUntilExit(),
    /// and neither can proceed. Archive sizes are caller-influenced — any valid
    /// archive that passes checksum verification can trigger the overflow. This is
    /// the Swift equivalent of Rust's `Command::output()`, which drains both streams
    /// concurrently and is structurally deadlock-free.
    ///
    /// Visibility is `internal` (not `private`) so `ReleaseDownloaderTests` can
    /// drive the pipe-buffer stress test directly via `@testable import`, avoiding
    /// the need to synthesize a full GitHub download fixture.
    internal func validateTarballMembers(tarballURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-tf", tarballURL.path]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError  = errPipe

        try process.run()

        // Drain both pipes concurrently before waiting for process exit.
        //
        // _ErrTransport is @unchecked Sendable because the DispatchSemaphore
        // provides the happens-before relationship: errDone.wait() completes before
        // any read of `captured`, so there is no data race despite the cross-thread
        // write followed by a cross-thread read.
        final class _ErrTransport: @unchecked Sendable { var captured = Data() }
        let errTransport = _ErrTransport()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            errTransport.captured = errPipe.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }

        // Read stdout to EOF on the current thread while the background queue
        // drains stderr. readDataToEndOfFile() returns once tar closes the write
        // end of the pipe (on process exit), so neither pipe ever fills.
        let outputData = outPipe.fileHandleForReading.readDataToEndOfFile()

        // Join stderr drain, then wait for process exit. Order is critical:
        // drain BOTH pipes first, then waitUntilExit() — never the reverse.
        errDone.wait()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrText = String(decoding: errTransport.captured, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpgradeError.extractionFailed(
                "tar -tf failed for \(tarballURL.lastPathComponent) (status \(process.terminationStatus))"
                + (stderrText.isEmpty ? "" : ": \(stderrText)")
            )
        }

        let listing = String(decoding: outputData, as: UTF8.self)
        for member in listing.components(separatedBy: .newlines) where !member.isEmpty {
            if let reason = ReleaseDownloader.unsafeMemberReason(member) {
                throw UpgradeError.extractionFailed(
                    "archive \(tarballURL.lastPathComponent): \(reason)"
                )
            }
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
    /// Detached minisign verification of checksums.txt failed or could not run.
    case signatureVerificationFailed(String)
    /// tar extraction exited non-zero or the expected binary was absent.
    case extractionFailed(String)
    /// Binary write failed due to insufficient permissions.
    case permissionDenied(String)
}
