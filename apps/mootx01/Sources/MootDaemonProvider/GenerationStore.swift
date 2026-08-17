import Foundation
import AriaMCP

// MARK: - MACD-2c1 — durable monotonic generations (Perkins P6)
//
// This file is the durable watermark MACD-2b explicitly deferred here
// (2B report §Review record, root finding 4: "a durable watermark must live
// beside the provider lock and MACD-2c is the mission that introduces one").
// The three counters — credential, provider, descriptor — live in ONE
// checksummed record beside the lock, are serialized under the lock, survive
// restart/reinstall/handover, and refuse rollback, overflow, torn state, and
// mismatch. Wire encoding for every generation is a DECIMAL STRING
// (ARIA_MCP_SPEC 1.40.0: a JSON number cannot carry UInt64 exactly).

/// The three monotonic provider counters.
public struct ProviderGenerations: Sendable, Equatable {

    /// Bumped by explicit credential rotation; revokes every session and
    /// lease derived under the previous root.
    public var credential: UInt64
    /// Bumped by every provider activation and every handover, so a stale
    /// provider claim is detectable across restarts.
    public var provider: UInt64
    /// Bumped by every descriptor publication, so a stale descriptor cannot
    /// replay as current.
    public var descriptor: UInt64

    public init(credential: UInt64, provider: UInt64, descriptor: UInt64) {
        self.credential = credential
        self.provider = provider
        self.descriptor = descriptor
    }

    /// The canonical decimal-string wire spelling of one counter.
    public static func wireEncode(_ value: UInt64) -> String { String(value) }

    /// A copy with the credential counter advanced by one.
    /// - Throws: `.generationFault(.overflow)` at `UInt64.max` — a counter
    ///   that cannot advance refuses rather than wraps, because a wrapped
    ///   counter would make every stale credential look fresh.
    public func bumpedCredential() throws -> ProviderGenerations {
        guard credential != UInt64.max else { throw DaemonProviderError.generationFault(.overflow) }
        return ProviderGenerations(credential: credential + 1, provider: provider, descriptor: descriptor)
    }

    /// A copy with the provider counter advanced by one. Same overflow rule.
    public func bumpedProvider() throws -> ProviderGenerations {
        guard provider != UInt64.max else { throw DaemonProviderError.generationFault(.overflow) }
        return ProviderGenerations(credential: credential, provider: provider + 1, descriptor: descriptor)
    }

    /// A copy with the descriptor counter advanced by one. Same overflow rule.
    public func bumpedDescriptor() throws -> ProviderGenerations {
        guard descriptor != UInt64.max else { throw DaemonProviderError.generationFault(.overflow) }
        return ProviderGenerations(credential: credential, provider: provider, descriptor: descriptor + 1)
    }

    /// Parse the canonical decimal spelling: digits only, no sign, no
    /// leading zero (except "0" itself), no overflow.
    public static func wireDecode(_ raw: String) -> UInt64? {
        guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        if raw.count > 1 && raw.first == "0" { return nil }
        return UInt64(raw)
    }
}

/// The durable, checksummed, atomically-replaced generation record.
public struct GenerationStore: Sendable {

    /// The record's on-disk format identifier. Bumping the format is a
    /// contract change, so the identifier is part of the self-report.
    public static let formatIdentifier = "mootx01-provider-generations-v1"

    private let fileURL: URL

    /// - Parameter fileURL: `ProviderRootLayout.generationsFile` — beside the
    ///   lock, inside the hygiene-validated provider directory.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Load the durable record.
    ///
    /// - Returns: The stored generations, or `nil` when the record is
    ///   GENUINELY absent (first activation on this install).
    /// - Throws: `DaemonProviderError.generationFault(.torn)` when present
    ///   but failing its checksum or grammar; `.unreadable` when present but
    ///   unopenable. Fail-closed: an unreadable monotonic record refuses, it
    ///   never resets to zero.
    public func load() throws -> ProviderGenerations? {
        // The READ path applies the same full hygiene matrix as every write
        // (O_NOFOLLOW|O_CLOEXEC, parent ownership/mode, regular file, link
        // count 1). Only genuine absence answers "no record"; every other
        // fault — permission, symlink, hard link, FIFO, I/O — refuses.
        let bytes: [UInt8]
        do {
            guard let fd = try SecureFiles.openValidatedIfExists(fileURL, flags: O_RDONLY) else {
                return nil
            }
            defer { close(fd) }
            bytes = try SecureFiles.readAll(fd: fd)
        } catch DaemonProviderError.hygieneViolation {
            throw DaemonProviderError.generationFault(.unreadable)
        }
        return try Self.parse(String(decoding: bytes, as: UTF8.self))
    }

    /// Parse and integrity-check one record line.
    private static func parse(_ raw: String) throws -> ProviderGenerations {
        let line = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
        // Grammar: "<format> credential=<d> provider=<d> descriptor=<d> sha256=<hex>"
        guard let checksumRange = line.range(of: " sha256=", options: .backwards) else {
            throw DaemonProviderError.generationFault(.torn)
        }
        let payload = String(line[line.startIndex..<checksumRange.lowerBound])
        let checksum = String(line[checksumRange.upperBound...])
        guard Self.checksumHex(of: payload) == checksum else {
            throw DaemonProviderError.generationFault(.torn)
        }
        let fields = payload.split(separator: " ").map(String.init)
        guard fields.count == 4, fields[0] == Self.formatIdentifier,
              fields[1].hasPrefix("credential="),
              fields[2].hasPrefix("provider="),
              fields[3].hasPrefix("descriptor="),
              let credential = ProviderGenerations.wireDecode(String(fields[1].dropFirst("credential=".count))),
              let provider = ProviderGenerations.wireDecode(String(fields[2].dropFirst("provider=".count))),
              let descriptor = ProviderGenerations.wireDecode(String(fields[3].dropFirst("descriptor=".count)))
        else {
            throw DaemonProviderError.generationFault(.torn)
        }
        return ProviderGenerations(credential: credential, provider: provider, descriptor: descriptor)
    }

    /// SHA-256 hex over the record payload — the torn-write detector. A
    /// partially persisted line cannot carry a matching digest.
    private static func checksumHex(of payload: String) -> String {
        FirstPartyAuthProtocol.sha256(Array(payload.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// The canonical serialized record for `generations`.
    private static func serialize(_ generations: ProviderGenerations) -> Data {
        let payload = "\(formatIdentifier)"
            + " credential=\(ProviderGenerations.wireEncode(generations.credential))"
            + " provider=\(ProviderGenerations.wireEncode(generations.provider))"
            + " descriptor=\(ProviderGenerations.wireEncode(generations.descriptor))"
        return Data((payload + " sha256=\(checksumHex(of: payload))\n").utf8)
    }

    /// Create the initial record. Licensed only under the lock, and only when
    /// genuinely absent.
    ///
    /// - Returns: The initial generations (credential 1, provider 1,
    ///   descriptor 0 — the descriptor counter advances at first publication).
    public func initialize(lockProof: ProviderLockProof) throws -> ProviderGenerations {
        // A stale proof (its handle released) must never serialize anything.
        try lockProof.validate()
        guard try load() == nil else {
            // Initializing over an existing record would be a reset; a reset
            // of a monotonic counter is a rollback by another name.
            throw DaemonProviderError.generationFault(.mismatch)
        }
        let initial = ProviderGenerations(credential: 1, provider: 1, descriptor: 0)
        try SecureFiles.atomicReplace(Self.serialize(initial), at: fileURL)
        return initial
    }

    /// Persist `next`, enforcing monotonicity against the CURRENT durable
    /// record under the lock.
    ///
    /// - Parameters:
    ///   - next: The desired new counters.
    ///   - expecting: What the caller believes is currently stored. A
    ///     disagreement is `.mismatch` — the caller's world is stale and it
    ///     must re-load rather than blindly overwrite.
    ///   - lockProof: Serialization proof (Perkins P6: serialized under lock).
    /// - Throws: `.rollback` when any counter would move backwards;
    ///   `.mismatch` when `expecting` is stale; `.torn`/`.unreadable` from
    ///   the underlying load.
    public func advance(
        to next: ProviderGenerations,
        expecting: ProviderGenerations,
        lockProof: ProviderLockProof
    ) throws -> ProviderGenerations {
        // A stale proof (its handle released) must never serialize anything.
        try lockProof.validate()
        guard let current = try load() else {
            // Advancing a record that does not exist: the caller's world is
            // wrong about the store's state.
            throw DaemonProviderError.generationFault(.mismatch)
        }
        guard current == expecting else {
            throw DaemonProviderError.generationFault(.mismatch)
        }
        guard next.credential >= current.credential,
              next.provider >= current.provider,
              next.descriptor >= current.descriptor else {
            throw DaemonProviderError.generationFault(.rollback)
        }
        try SecureFiles.atomicReplace(Self.serialize(next), at: fileURL)
        return next
    }
}
