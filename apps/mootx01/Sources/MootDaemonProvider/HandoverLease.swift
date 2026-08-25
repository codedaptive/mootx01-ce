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

    /// The lease transcript field list, in MAC-input order. Part of the
    /// self-report: two shells that disagree here produce different module
    /// digests, which is the "identical handover transcript format" claim
    /// made checkable.
    public static let transcriptFields: [String] = [
        "leaseIdentifier", "estateIdentifier", "estateSchemaVersion",
        "sourceInstance", "targetInstance", "sourceIdentity", "targetIdentity",
        "credentialGeneration", "providerGeneration", "descriptorGeneration",
        "issuedAt", "expiresAt", "nonce",
    ]

    /// The canonical MAC input: the lease domain and every field except the
    /// MAC itself, in fixed order via `CanonicalEncoder` (length-prefixed —
    /// the same anti-ambiguity argument as every MACD-2b MAC input; a
    /// signing identity is itself three length-prefixed strings, so no two
    /// identities can collide by concatenation).
    public func macInput() -> [UInt8] {
        var encoder = CanonicalEncoder()
        encoder.appendString(Self.leaseDomain)
        encoder.appendUUID(leaseIdentifier)
        encoder.appendUUID(estateIdentifier)
        encoder.appendUInt64(estateSchemaVersion)
        encoder.appendUUID(sourceInstance)
        encoder.appendUUID(targetInstance)
        Self.appendIdentity(sourceIdentity, to: &encoder)
        Self.appendIdentity(targetIdentity, to: &encoder)
        encoder.appendUInt64(credentialGeneration)
        encoder.appendUInt64(providerGeneration)
        encoder.appendUInt64(descriptorGeneration)
        encoder.appendUInt64(issuedAt)
        encoder.appendUInt64(expiresAt)
        encoder.appendBytes(nonce)
        return encoder.bytes
    }

    private static func appendIdentity(
        _ identity: SigningIdentityDescriptor, to encoder: inout CanonicalEncoder
    ) {
        encoder.appendString(identity.teamIdentifier)
        encoder.appendString(identity.bundleIdentifier)
        encoder.appendString(identity.signingClass.rawValue)
    }

    /// A copy with `leaseMAC` computed under `installationRoot`.
    public func sealed(installationRoot: [UInt8]) -> HandoverLease {
        var copy = self
        copy.leaseMAC = FirstPartyAuthProtocol.hmacSHA256(
            key: Self.leaseKey(installationRoot: installationRoot),
            message: macInput()
        )
        return copy
    }

    /// Constant-time MAC verification.
    public func verifyMAC(installationRoot: [UInt8]) -> Bool {
        guard leaseMAC.count == FirstPartyAuthProtocol.macByteCount else { return false }
        let expected = FirstPartyAuthProtocol.hmacSHA256(
            key: Self.leaseKey(installationRoot: installationRoot),
            message: macInput()
        )
        return FirstPartyAuthProtocol.constantTimeEquals(expected, leaseMAC)
    }

    /// The exact key set of a durable lease record.
    private static let recordFields: Set<String> = Set(transcriptFields).union(["leaseMAC"])

    /// Canonical JSON for the durable lease record (sorted keys, base64url
    /// byte fields, decimal-string integers). Carries no secret: the MAC key
    /// never appears, and the MAC itself proves nothing without K_install.
    public func encoded() -> Data {
        let object: [String: Any] = [
            "leaseIdentifier": leaseIdentifier.uuidString,
            "estateIdentifier": estateIdentifier.uuidString,
            "estateSchemaVersion": ProviderGenerations.wireEncode(estateSchemaVersion),
            "sourceInstance": sourceInstance.uuidString,
            "targetInstance": targetInstance.uuidString,
            "sourceIdentity": Self.encodeIdentity(sourceIdentity),
            "targetIdentity": Self.encodeIdentity(targetIdentity),
            "credentialGeneration": ProviderGenerations.wireEncode(credentialGeneration),
            "providerGeneration": ProviderGenerations.wireEncode(providerGeneration),
            "descriptorGeneration": ProviderGenerations.wireEncode(descriptorGeneration),
            "issuedAt": ProviderGenerations.wireEncode(issuedAt),
            "expiresAt": ProviderGenerations.wireEncode(expiresAt),
            "nonce": FirstPartyAuthProtocol.base64URLEncode(nonce),
            "leaseMAC": FirstPartyAuthProtocol.base64URLEncode(leaseMAC),
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    private static func encodeIdentity(_ identity: SigningIdentityDescriptor) -> [String: String] {
        [
            "teamIdentifier": identity.teamIdentifier,
            "bundleIdentifier": identity.bundleIdentifier,
            "signingClass": identity.signingClass.rawValue,
        ]
    }

    private static func decodeIdentity(_ value: Any?) -> SigningIdentityDescriptor? {
        guard let object = value as? [String: String],
              Set(object.keys) == ["teamIdentifier", "bundleIdentifier", "signingClass"],
              let team = object["teamIdentifier"],
              let bundle = object["bundleIdentifier"],
              let classRaw = object["signingClass"],
              let signingClass = SignedProcessIdentity.SigningClass(rawValue: classRaw)
        else { return nil }
        return SigningIdentityDescriptor(
            teamIdentifier: team, bundleIdentifier: bundle, signingClass: signingClass
        )
    }

    /// Decode a durable record. `nil` for anything malformed — wrong key set,
    /// wrong types, non-canonical spellings.
    public static func decode(_ data: Data) -> HandoverLease? {
        guard let object = FirstPartyAuthProtocol.strictJSONObject(
            data, expected: recordFields, maxBytes: 8 * 1024
        ) else { return nil }
        guard
            let leaseRaw = object["leaseIdentifier"] as? String,
            let leaseIdentifier = UUID(uuidString: leaseRaw),
            let estateRaw = object["estateIdentifier"] as? String,
            let estateIdentifier = UUID(uuidString: estateRaw),
            let schemaRaw = object["estateSchemaVersion"] as? String,
            let estateSchemaVersion = ProviderGenerations.wireDecode(schemaRaw),
            let sourceRaw = object["sourceInstance"] as? String,
            let sourceInstance = UUID(uuidString: sourceRaw),
            let targetRaw = object["targetInstance"] as? String,
            let targetInstance = UUID(uuidString: targetRaw),
            let sourceIdentity = decodeIdentity(object["sourceIdentity"]),
            let targetIdentity = decodeIdentity(object["targetIdentity"]),
            let credentialRaw = object["credentialGeneration"] as? String,
            let credentialGeneration = ProviderGenerations.wireDecode(credentialRaw),
            let providerRaw = object["providerGeneration"] as? String,
            let providerGeneration = ProviderGenerations.wireDecode(providerRaw),
            let descriptorRaw = object["descriptorGeneration"] as? String,
            let descriptorGeneration = ProviderGenerations.wireDecode(descriptorRaw),
            let issuedRaw = object["issuedAt"] as? String,
            let issuedAt = ProviderGenerations.wireDecode(issuedRaw),
            let expiresRaw = object["expiresAt"] as? String,
            let expiresAt = ProviderGenerations.wireDecode(expiresRaw),
            let nonceRaw = object["nonce"] as? String,
            let nonce = FirstPartyAuthProtocol.base64URLDecode(nonceRaw),
            let macRaw = object["leaseMAC"] as? String,
            let leaseMAC = FirstPartyAuthProtocol.base64URLDecode(macRaw)
        else { return nil }
        return HandoverLease(
            leaseIdentifier: leaseIdentifier, estateIdentifier: estateIdentifier,
            estateSchemaVersion: estateSchemaVersion,
            sourceInstance: sourceInstance, targetInstance: targetInstance,
            sourceIdentity: sourceIdentity, targetIdentity: targetIdentity,
            credentialGeneration: credentialGeneration,
            providerGeneration: providerGeneration,
            descriptorGeneration: descriptorGeneration,
            issuedAt: issuedAt, expiresAt: expiresAt,
            nonce: nonce, leaseMAC: leaseMAC
        )
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
    /// Fail-closed (the c0 `journalContains` rule): only a genuinely ABSENT
    /// journal answers "not consumed"; a journal that exists but cannot be
    /// opened or read is an unanswerable one-use question, and treating it as
    /// "not consumed" would let an I/O fault license a replay.
    public func contains(_ leaseIdentifier: UUID) throws -> Bool {
        // Full hygiene matrix on the READ (symlink, hard link, FIFO, parent
        // ownership/mode) — a journal that can be aliased or swapped is a
        // journal whose one-use answer can be forged.
        let bytes: [UInt8]
        do {
            guard let fd = try SecureFiles.openValidatedIfExists(fileURL, flags: O_RDONLY) else {
                return false
            }
            defer { close(fd) }
            bytes = try SecureFiles.readAll(fd: fd)
        } catch DaemonProviderError.hygieneViolation {
            throw DaemonProviderError.leaseInvalid(.journalUnavailable)
        }
        let target = Substring(leaseIdentifier.uuidString)
        return String(decoding: bytes, as: UTF8.self)
            .split(separator: "\n")
            .contains { $0 == target }
    }

    /// Durably record consumption: O_APPEND one line, then fsync — ORDERED
    /// BEFORE the lease is resolved into any capability, so a crash between
    /// record and resolution burns the lease rather than doubling it.
    public func recordConsumption(_ leaseIdentifier: UUID) throws {
        // Validated append: the same hygiene matrix as every other state
        // open, plus O_APPEND for the journal-first durable record.
        let fd: Int32
        do {
            fd = try SecureFiles.openValidated(fileURL, flags: O_WRONLY | O_APPEND, create: true)
        } catch DaemonProviderError.hygieneViolation {
            throw DaemonProviderError.leaseInvalid(.journalUnavailable)
        }
        defer { close(fd) }
        let line = [UInt8]((leaseIdentifier.uuidString + "\n").utf8)
        var written = 0
        while written < line.count {
            let result = line.withUnsafeBufferPointer { buffer -> Int in
                write(fd, buffer.baseAddress! + written, line.count - written)
            }
            guard result > 0 else {
                throw DaemonProviderError.leaseInvalid(.journalUnavailable)
            }
            written += result
        }
        guard fsync(fd) == 0 else {
            throw DaemonProviderError.leaseInvalid(.journalUnavailable)
        }
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
    ///
    /// The lease identifier and nonce both come from the INJECTED randomness
    /// (Perkins P13) — an identifier a test cannot pin is an identifier a
    /// test cannot replay on purpose.
    public func issue(
        estate: EstateReadyProof,
        sourceInstance: UUID, targetInstance: UUID,
        sourceIdentity: SigningIdentityDescriptor, targetIdentity: SigningIdentityDescriptor,
        generations: ProviderGenerations,
        installationRoot: [UInt8]
    ) -> HandoverLease {
        let now = clock()
        let identifierBytes = randomBytes(16)
        let lease = HandoverLease(
            leaseIdentifier: Self.uuid(from: identifierBytes),
            estateIdentifier: estate.estateIdentifier,
            estateSchemaVersion: estate.schemaVersion,
            sourceInstance: sourceInstance, targetInstance: targetInstance,
            sourceIdentity: sourceIdentity, targetIdentity: targetIdentity,
            credentialGeneration: generations.credential,
            providerGeneration: generations.provider,
            descriptorGeneration: generations.descriptor,
            issuedAt: now, expiresAt: now + HandoverLease.leaseLifetime,
            nonce: randomBytes(FirstPartyAuthProtocol.nonceByteCount),
            leaseMAC: []
        )
        return lease.sealed(installationRoot: installationRoot)
    }

    /// Build a UUID from 16 injected bytes, tolerating a short injection by
    /// zero-padding (a test seam convenience; production randomness always
    /// yields the requested count).
    private static func uuid(from bytes: [UInt8]) -> UUID {
        var padded = bytes
        if padded.count < 16 { padded += [UInt8](repeating: 0, count: 16 - padded.count) }
        return UUID(uuid: (
            padded[0], padded[1], padded[2], padded[3],
            padded[4], padded[5], padded[6], padded[7],
            padded[8], padded[9], padded[10], padded[11],
            padded[12], padded[13], padded[14], padded[15]
        ))
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
        // 1. Authenticity before anything else: an unMACed lease's fields
        //    are attacker input and must not steer later gates.
        guard lease.verifyMAC(installationRoot: installationRoot) else {
            throw DaemonProviderError.leaseInvalid(.badMAC)
        }
        // 2. Expiry, on the injected clock.
        guard clock() <= lease.expiresAt else {
            throw DaemonProviderError.leaseInvalid(.expired)
        }
        // 3. Binding: only the named target artifact, as the named instance,
        //    may consume.
        guard lease.targetIdentity == targetIdentity,
              lease.targetInstance == targetInstance else {
            throw DaemonProviderError.leaseInvalid(.bindingMismatch)
        }
        // 4. Generation freshness against the DURABLE store: the credential
        //    generation must be exactly current (a rotation revokes every
        //    outstanding lease), and the provider/descriptor generations must
        //    not be older than what the store already records.
        guard lease.credentialGeneration == currentGenerations.credential,
              lease.providerGeneration >= currentGenerations.provider,
              lease.descriptorGeneration >= currentGenerations.descriptor else {
            throw DaemonProviderError.leaseInvalid(.staleGeneration)
        }
        // 5. Replay: the durable journal, fail-closed.
        guard try !journal.contains(lease.leaseIdentifier) else {
            throw DaemonProviderError.leaseInvalid(.consumed)
        }
        // 6. Burn BEFORE resolve (c0 journal-first): once this line returns,
        //    the lease can never resolve again — even if we crash on the
        //    very next instruction.
        try journal.recordConsumption(lease.leaseIdentifier)
        // 7. Resolve.
        return EstateReadyProof(
            estateIdentifier: lease.estateIdentifier,
            schemaVersion: lease.estateSchemaVersion
        )
    }
}
