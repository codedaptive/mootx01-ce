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
        throw DaemonProviderError.unimplemented("GenerationStore.load")
    }

    /// Create the initial record. Licensed only under the lock, and only when
    /// genuinely absent.
    ///
    /// - Returns: The initial generations (credential 1, provider 1,
    ///   descriptor 0 — the descriptor counter advances at first publication).
    public func initialize(lockProof: ProviderLockProof) throws -> ProviderGenerations {
        throw DaemonProviderError.unimplemented("GenerationStore.initialize")
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
    ///   `.overflow` when a counter cannot advance; `.mismatch`; `.torn`.
    public func advance(
        to next: ProviderGenerations,
        expecting: ProviderGenerations,
        lockProof: ProviderLockProof
    ) throws -> ProviderGenerations {
        throw DaemonProviderError.unimplemented("GenerationStore.advance")
    }
}
