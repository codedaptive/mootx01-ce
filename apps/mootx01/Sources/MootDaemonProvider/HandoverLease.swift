import Foundation
import AriaMCP

// MARK: - MACD-2c1 — the handover lease (Perkins P9)
//
// The lease is the single-use credential that lets the TARGET provider open
// the estate the SOURCE just closed. It is MACed under a key derived from
// K_install with a NEW domain string — distinct from every MACD-2b domain, so
// no descriptor, handshake, or session MAC can be presented as a lease and
// vice versa. It expires on an injected clock, binds both shells' signing
// identities, the estate identity and schema, both instance UUIDs, all three
// generations, and a nonce; and it is consumed ATOMICALLY through a durable
// journal whose record is written and fsynced BEFORE the lease resolves
// (the c0 journal-first pattern: the one-use record exists before the
// capability is exercised, so a crash between the two burns the lease rather
// than doubling it).

/// The MACed, expiring, single-use handover lease.
public struct HandoverLease: Sendable, Equatable {

    /// The lease MAC's HKDF domain. NEW in this mission and deliberately
    /// distinct from `MOOTX01-DESCRIPTOR-v1`, `MOOTX01-AUTH-v1`,
    /// `MOOTX01-REQUEST-SESSION-v1`, and every proof/MAC domain of MACD-2b
    /// (Perkins P9). Bumping it is a contract change and shows up in the
    /// self-report digest.
    public static let leaseDomain = "MOOTX01-HANDOVER-LEASE-v1"

    /// Lease lifetime in seconds. A handover that cannot finish inside two
    /// minutes has stalled; a stalled handover must re-prepare rather than
    /// hold an open credential.
    public static let leaseLifetime: UInt64 = 120

    /// Single-use identity of this lease.
    public let leaseIdentifier: UUID
    /// The estate being handed over.
    public let estateIdentifier: UUID
    /// The estate's schema version at close.
    public let estateSchemaVersion: UInt64
    /// The source provider's instance UUID.
    public let sourceInstance: UUID
    /// The target provider's instance UUID.
    public let targetInstance: UUID
    /// The source shell's signing identity.
    public let sourceIdentity: SigningIdentityDescriptor
    /// The target shell's signing identity.
    public let targetIdentity: SigningIdentityDescriptor
    /// Credential generation at issue.
    public let credentialGeneration: UInt64
    /// Provider generation at issue (already incremented by quiescence).
    public let providerGeneration: UInt64
    /// Descriptor generation at issue.
    public let descriptorGeneration: UInt64
    /// Issue time, epoch seconds, injected clock.
    public let issuedAt: UInt64
    /// Expiry, epoch seconds: `issuedAt + leaseLifetime`.
    public let expiresAt: UInt64
    /// 32 random bytes from injected randomness.
    public let nonce: [UInt8]
    /// HMAC-SHA256 over `macInput()` under the lease key.
    public var leaseMAC: [UInt8]

    public init(
        leaseIdentifier: UUID, estateIdentifier: UUID, estateSchemaVersion: UInt64,
        sourceInstance: UUID, targetInstance: UUID,
        sourceIdentity: SigningIdentityDescriptor, targetIdentity: SigningIdentityDescriptor,
        credentialGeneration: UInt64, providerGeneration: UInt64, descriptorGeneration: UInt64,
        issuedAt: UInt64, expiresAt: UInt64, nonce: [UInt8], leaseMAC: [UInt8]
    ) {
        self.leaseIdentifier = leaseIdentifier
        self.estateIdentifier = estateIdentifier
        self.estateSchemaVersion = estateSchemaVersion
        self.sourceInstance = sourceInstance
        self.targetInstance = targetInstance
        self.sourceIdentity = sourceIdentity
        self.targetIdentity = targetIdentity
        self.credentialGeneration = credentialGeneration
        self.providerGeneration = providerGeneration
        self.descriptorGeneration = descriptorGeneration
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.nonce = nonce
        self.leaseMAC = leaseMAC
    }

    /// `K_lease = HKDF-SHA256(K_install, salt = 32 zero octets, info = leaseDomain)`.
    ///
    /// The RFC 5869 omitted-salt value, like the descriptor key: the lease
    /// key must be derivable by the target BEFORE it trusts anything the
    /// source wrote. Domain separation, not salt, is what isolates this rung.
    public static func leaseKey(installationRoot: [UInt8]) -> [UInt8] {
        FirstPartyAuthProtocol.hkdfSHA256(
            inputKeyingMaterial: installationRoot,
            salt: [UInt8](repeating: 0, count: 32),
            info: Array(leaseDomain.utf8),
            outputByteCount: FirstPartyAuthProtocol.macByteCount
        )
    }

    /// The canonical MAC input: the lease domain and every field except the
    /// MAC itself, in fixed order via `CanonicalEncoder` (length-prefixed —
    /// the same anti-ambiguity argument as every MACD-2b MAC input).
    public func macInput() -> [UInt8] {
        [] // RED placeholder.
    }

    /// A copy with `leaseMAC` computed under `installationRoot`.
    public func sealed(installationRoot: [UInt8]) -> HandoverLease {
        self // RED placeholder.
    }

    /// Constant-time MAC verification.
    public func verifyMAC(installationRoot: [UInt8]) -> Bool {
        false // RED placeholder.
    }

    /// Canonical JSON for the durable lease record (sorted keys, base64url
    /// byte fields, decimal-string generations). Carries no secret: the MAC
    /// key never appears, and the MAC itself proves nothing without
    /// K_install.
    public func encoded() -> Data {
        Data() // RED placeholder.
    }

    /// Decode a durable record. `nil` for anything malformed.
    public static func decode(_ data: Data) -> HandoverLease? {
        nil // RED placeholder.
    }
}

/// The durable single-use consumption journal (c0 journal-first pattern).
public struct LeaseConsumptionJournal: Sendable {

    private let fileURL: URL

    /// - Parameter fileURL: `ProviderRootLayout.leaseJournal`.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Whether `leaseIdentifier` is already recorded as consumed.
    ///
    /// Fail-closed: only a genuinely ABSENT journal answers "not consumed";
    /// an unreadable journal throws `.leaseInvalid(.journalUnavailable)`.
    public func contains(_ leaseIdentifier: UUID) throws -> Bool {
        throw DaemonProviderError.unimplemented("LeaseConsumptionJournal.contains")
    }

    /// Durably record consumption: O_APPEND one line, then fsync — ORDERED
    /// BEFORE the lease is resolved into any capability.
    public func recordConsumption(_ leaseIdentifier: UUID) throws {
        throw DaemonProviderError.unimplemented("LeaseConsumptionJournal.recordConsumption")
    }
}

/// Issues and consumes leases.
public struct LeaseAuthority: Sendable {

    private let journal: LeaseConsumptionJournal
    private let clock: ProviderClock
    private let randomBytes: ProviderRandomness

    public init(
        journal: LeaseConsumptionJournal,
        clock: @escaping ProviderClock,
        randomBytes: @escaping ProviderRandomness
    ) {
        self.journal = journal
        self.clock = clock
        self.randomBytes = randomBytes
    }

    /// Issue a sealed lease binding source, target, estate, and generations.
    public func issue(
        estate: EstateReadyProof,
        sourceInstance: UUID, targetInstance: UUID,
        sourceIdentity: SigningIdentityDescriptor, targetIdentity: SigningIdentityDescriptor,
        generations: ProviderGenerations,
        installationRoot: [UInt8]
    ) -> HandoverLease {
        HandoverLease(
            leaseIdentifier: UUID(), estateIdentifier: estate.estateIdentifier,
            estateSchemaVersion: estate.schemaVersion,
            sourceInstance: sourceInstance, targetInstance: targetInstance,
            sourceIdentity: sourceIdentity, targetIdentity: targetIdentity,
            credentialGeneration: generations.credential,
            providerGeneration: generations.provider,
            descriptorGeneration: generations.descriptor,
            issuedAt: 0, expiresAt: 0, nonce: [], leaseMAC: []
        ) // RED placeholder.
    }

    /// Consume a lease ATOMICALLY, in this exact order:
    /// MAC → expiry → binding (target identity + instance) → generation
    /// freshness → journal replay check → DURABLE journal record → return.
    ///
    /// The durable record precedes the return, so every crash point either
    /// leaves the lease unconsumed (refusal happened first) or burnt
    /// (recorded, never re-consumable) — there is no interleaving in which it
    /// resolves twice.
    ///
    /// - Throws: `DaemonProviderError.leaseInvalid` naming the failed gate.
    public func consume(
        _ lease: HandoverLease,
        installationRoot: [UInt8],
        asTarget targetIdentity: SigningIdentityDescriptor,
        targetInstance: UUID,
        currentGenerations: ProviderGenerations
    ) throws -> EstateReadyProof {
        throw DaemonProviderError.unimplemented("LeaseAuthority.consume")
    }
}
