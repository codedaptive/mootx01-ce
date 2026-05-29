// ForeignSourcePipeline.swift
//
// The opt-in fetch-and-assemble pipeline. From the launch plan:
//
//   "Foreign-licensed data never ships inside the core or the
//    binary; MOOTx01 distributes code and an assembler, not the
//    corpus. ... an unreachable source fails clean with no
//    partial state."
//
// Invariants enforced here:
//
//   1. Consent first. Every run begins with a verifyConsent call
//      against ActivationConsent. No bytes leave the network
//      stack without that returning true.
//
//   2. Pinned, versioned sources. Each PinnedSource carries a URL,
//      a stable schemeID, a version string, and a SHA-256 digest
//      the assembler verifies against the downloaded payload. A
//      drifted upstream fails clean.
//
//   3. Atomic assembly. The pipeline assembles into a staging
//      directory and atomically moves the result on success. On
//      ANY failure — unreachable source, digest mismatch, write
//      error — the staging directory is removed and the live
//      destination is untouched. No half-assembly.
//
// The fetcher is injected as a closure so tests can drive the
// pipeline against fixture data without a real network. The
// production wiring will pass URLSession-backed fetch in.

import Foundation

/// A pinned, versioned foreign source. Everything the pipeline
/// needs to fetch and verify one source in one run.
public struct PinnedSource: Sendable, Hashable, Codable {

    /// Stable identifier matching a ConsentRecord.schemeID. The
    /// pipeline aborts if no consent record exists for this id.
    public let schemeID: String

    /// The exact source URL to fetch. Pinned — a new version is a
    /// new PinnedSource value, not a mutation of an existing one.
    public let url: URL

    /// Source-side version string. Travels with the assembled
    /// derivative so the user's local build can be audited.
    public let version: String

    /// SHA-256 hex digest the assembler will verify against the
    /// downloaded payload. Any mismatch aborts the run cleanly.
    public let expectedDigest: String

    public init(
        schemeID: String,
        url: URL,
        version: String,
        expectedDigest: String
    ) {
        self.schemeID = schemeID
        self.url = url
        self.version = version
        self.expectedDigest = expectedDigest
    }
}

/// Reasons a pipeline run can fail. All variants leave the live
/// destination untouched — that is the "clean failure" invariant.
public enum PipelineError: Error, Sendable, Hashable {

    /// No consent record for the requested schemeID. The gate
    /// blocked the run before any network I/O.
    case consentMissing(schemeID: String)

    /// The fetcher could not reach or could not read the source.
    /// Includes connection failures, 4xx/5xx, and truncated reads.
    case sourceUnreachable(url: URL, reason: String)

    /// The downloaded payload's digest did not match the pinned
    /// PinnedSource.expectedDigest. Upstream drifted, or the
    /// network corrupted the bytes. Either way: do not assemble.
    case digestMismatch(url: URL, expected: String, actual: String)

    /// The pipeline could not write the staging or destination
    /// directory. Disk full, permissions, etc. The staging
    /// directory is removed before this error is raised.
    case assemblyWriteFailed(reason: String)
}

/// The fetcher closure: given a URL, return the downloaded bytes.
/// Throws on unreachable / truncated reads. Injected so tests can
/// avoid the network.
public typealias ForeignSourceFetcher = @Sendable (URL) async throws -> Data

/// The opt-in fetch-and-assemble pipeline.
///
/// A pipeline is constructed with the consent gate it must consult
/// and the fetcher it should use. `assemble(_:into:)` runs one
/// foreign source end-to-end: verify consent, fetch, verify digest,
/// write to a staging directory, atomically promote to the live
/// destination. Any failure cleans up staging and leaves the live
/// destination untouched.
public actor ForeignSourcePipeline {

    /// The consent gate every run must pass.
    public let consent: ActivationConsent

    /// The fetcher closure. Injected for testability.
    private let fetcher: ForeignSourceFetcher

    public init(
        consent: ActivationConsent,
        fetcher: @escaping ForeignSourceFetcher
    ) {
        self.consent = consent
        self.fetcher = fetcher
    }

    /// Runs the pipeline for one PinnedSource. Returns the URL of
    /// the assembled file on success. Throws `PipelineError` on any
    /// failure — and on failure, the staging directory is removed
    /// and the live destination at `liveDestination` is unchanged.
    ///
    /// `liveDestination` is the final file path the assembled
    /// payload is moved into. `stagingRoot` is the directory the
    /// pipeline owns for in-flight assembly; it is created if
    /// missing and removed if the run fails.
    public func assemble(
        _ source: PinnedSource,
        liveDestination: URL,
        stagingRoot: URL
    ) async throws -> URL {

        // 1. Consent gate. No I/O before this.
        let granted = await consent.verifyConsent(forScheme: source.schemeID)
        guard granted else {
            throw PipelineError.consentMissing(schemeID: source.schemeID)
        }

        // 2. Prepare staging. Created fresh per run so the cleanup
        //    path doesn't surprise unrelated files.
        let runStaging = stagingRoot.appendingPathComponent(
            "run-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: runStaging,
                withIntermediateDirectories: true
            )
        } catch {
            throw PipelineError.assemblyWriteFailed(
                reason: "create staging: \(error.localizedDescription)"
            )
        }

        // Cleanup helper used by every failure path below.
        func cleanupStaging() {
            try? FileManager.default.removeItem(at: runStaging)
        }

        // 3. Fetch. Any throw from the injected fetcher is treated
        //    as unreachable — we do not distinguish network vs read
        //    error at this layer; the caller wraps semantics.
        let payload: Data
        do {
            payload = try await fetcher(source.url)
        } catch {
            cleanupStaging()
            throw PipelineError.sourceUnreachable(
                url: source.url,
                reason: error.localizedDescription
            )
        }

        // 4. Verify pinned digest. Any drift aborts cleanly.
        let actualDigest = Self.sha256Hex(payload)
        guard actualDigest == source.expectedDigest else {
            cleanupStaging()
            throw PipelineError.digestMismatch(
                url: source.url,
                expected: source.expectedDigest,
                actual: actualDigest
            )
        }

        // 5. Write to staging. Atomic option preserves the
        //    no-partial-file invariant even if the process dies.
        let stagingFile = runStaging.appendingPathComponent(
            source.url.lastPathComponent.isEmpty
                ? "payload"
                : source.url.lastPathComponent
        )
        do {
            try payload.write(to: stagingFile, options: [.atomic])
        } catch {
            cleanupStaging()
            throw PipelineError.assemblyWriteFailed(
                reason: "stage write: \(error.localizedDescription)"
            )
        }

        // 6. Promote to live destination. Ensure the destination
        //    directory exists; replace any prior live file.
        let liveDir = liveDestination.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: liveDir,
                withIntermediateDirectories: true
            )
        } catch {
            cleanupStaging()
            throw PipelineError.assemblyWriteFailed(
                reason: "create live dir: \(error.localizedDescription)"
            )
        }

        // Promote the staging file to the live path. Two branches
        // because FileManager.replaceItemAt requires the destination
        // to exist for its atomic-swap path. The clean-failure
        // invariant — "liveDestination is untouched on failure" —
        // forbids writing a placeholder there, because a failure
        // after the placeholder write would leave a zero-byte file
        // behind. Instead: if there is no prior file, do a direct
        // move; if there is one, replace it. Either path leaves the
        // live destination either the new payload (success) or the
        // exact prior state, including non-existence (failure).
        let livePreexisted = FileManager.default.fileExists(
            atPath: liveDestination.path
        )
        do {
            if livePreexisted {
                _ = try FileManager.default.replaceItemAt(
                    liveDestination,
                    withItemAt: stagingFile
                )
            } else {
                try FileManager.default.moveItem(
                    at: stagingFile,
                    to: liveDestination
                )
            }
        } catch {
            cleanupStaging()
            throw PipelineError.assemblyWriteFailed(
                reason: "promote: \(error.localizedDescription)"
            )
        }

        // 7. Remove staging — payload has been promoted.
        cleanupStaging()
        return liveDestination
    }

    /// SHA-256 hex digest of a byte payload. Implemented without
    /// importing CryptoKit to keep the kit's zero-external-dep
    /// invariant intact for the Linux/Rust port — Foundation's
    /// `Data` is available everywhere. Conformance with CryptoKit
    /// is checked by tests against canonical vectors.
    static func sha256Hex(_ data: Data) -> String {
        var hash = SHA256Core()
        hash.update(data)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - SHA-256

/// Pure-Swift SHA-256 implementation. Kept internal so the public
/// surface of EideticLib is unchanged. Conformance tests in
/// ForeignSourcePipelineTests verify the implementation against
/// FIPS 180-4 vectors so this hand-rolled hash agrees with the
/// platform implementation byte-for-byte.
struct SHA256Core {

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]
    private var buffer: [UInt8] = []
    private var totalLength: UInt64 = 0

    mutating func update(_ data: Data) {
        buffer.append(contentsOf: data)
        totalLength &+= UInt64(data.count) &* 8
        while buffer.count >= 64 {
            let block = Array(buffer.prefix(64))
            compress(block)
            buffer.removeFirst(64)
        }
    }

    mutating func finalize() -> [UInt8] {
        let bitLength = totalLength
        buffer.append(0x80)
        while buffer.count % 64 != 56 {
            buffer.append(0x00)
        }
        for i in (0..<8).reversed() {
            buffer.append(UInt8((bitLength >> (i * 8)) & 0xff))
        }
        while buffer.count >= 64 {
            let block = Array(buffer.prefix(64))
            compress(block)
            buffer.removeFirst(64)
        }
        var out: [UInt8] = []
        for word in state {
            out.append(UInt8((word >> 24) & 0xff))
            out.append(UInt8((word >> 16) & 0xff))
            out.append(UInt8((word >> 8) & 0xff))
            out.append(UInt8(word & 0xff))
        }
        return out
    }

    private mutating func compress(_ block: [UInt8]) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            let j = i * 4
            w[i] =
                (UInt32(block[j]) << 24) |
                (UInt32(block[j + 1]) << 16) |
                (UInt32(block[j + 2]) << 8) |
                UInt32(block[j + 3])
        }
        for i in 16..<64 {
            let s0 = w[i - 15].rotr(7) ^ w[i - 15].rotr(18) ^ (w[i - 15] >> 3)
            let s1 = w[i - 2].rotr(17) ^ w[i - 2].rotr(19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = state[0]
        var b = state[1]
        var c = state[2]
        var d = state[3]
        var e = state[4]
        var f = state[5]
        var g = state[6]
        var h = state[7]
        for i in 0..<64 {
            let s1 = e.rotr(6) ^ e.rotr(11) ^ e.rotr(25)
            let ch = (e & f) ^ (~e & g)
            let t1 = h &+ s1 &+ ch &+ Self.k[i] &+ w[i]
            let s0 = a.rotr(2) ^ a.rotr(13) ^ a.rotr(22)
            let mj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ mj
            h = g
            g = f
            f = e
            e = d &+ t1
            d = c
            c = b
            b = a
            a = t1 &+ t2
        }
        state[0] &+= a
        state[1] &+= b
        state[2] &+= c
        state[3] &+= d
        state[4] &+= e
        state[5] &+= f
        state[6] &+= g
        state[7] &+= h
    }
}

private extension UInt32 {
    func rotr(_ n: UInt32) -> UInt32 {
        (self >> n) | (self << (32 - n))
    }
}
