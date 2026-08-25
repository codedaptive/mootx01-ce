import Foundation
import AriaMCP

// MARK: - MACD-2c2 — the attended one-use migration grant (Perkins P-c2-3/4/5/6/7)
//
// The grant is how the signed legacy Pro app hands the provider access to the
// sandboxed default estate it alone can reach — WITHOUT path ever becoming
// authority. The app derives the known legacy default URL inside its own
// container, creates URL bookmark data with `options: []` exactly (no
// security-scoped option, no startAccessingSecurityScopedResource), and
// carries the opaque bytes in an envelope that is:
//
//   - PROVENANCE-AUTHENTICATED (P-c2-3): the MAC key is
//     HKDF-SHA256(K_install, salt: SHA-256(challenge transcript),
//     info: "MOOTX01-MIGRATION-GRANT-v1"). Possession of K_install proves
//     team-group membership (the app reads it via the READ-ONLY
//     DataProtectionKeychainRootProvider); the challenge salt binds the
//     envelope to ONE outstanding provider challenge. A nonce never
//     authenticates anything by itself.
//   - ONE-USE (P-c2-4): consumed through the same journal-first durable
//     record as handover leases — the record is fsynced BEFORE the bookmark
//     resolves into any capability, so a crash between record and resolution
//     burns the grant rather than doubling it. No argv or CLI flag can
//     delete a consumption record (c0 F3); cleanup happens only inside the
//     migration state machine after committed success or terminal abort.
//   - CONTAINED (P-c2-5): bookmark bytes exist ONLY inside the envelope file
//     in the App Group. They never appear in logs, receipts (digest only),
//     the descriptor, UserDefaults, the estate, diagnostics, or crash text,
//     and the envelope is size-capped BEFORE any resolution.

/// The provider-issued challenge that licenses ONE grant attempt. Issued only
/// while the migration machine is in `awaitingMigrationGrant`; a single
/// challenge is outstanding at a time, and every envelope is valid only
/// against the exact outstanding challenge (its digest is the MAC salt).
public struct MigrationChallenge: Sendable, Equatable {

    /// Challenge lifetime in seconds. An attended flow that has not produced
    /// a grant within five minutes re-issues rather than holding an open
    /// challenge indefinitely.
    public static let challengeLifetime: UInt64 = 300

    /// The challenge transcript's domain string (distinct from the grant
    /// domain so a challenge digest can never be confused with a grant MAC).
    public static let challengeDomain = "MOOTX01-MIGRATION-CHALLENGE-v1"

    /// This challenge's identity.
    public let challengeIdentifier: UUID
    /// The provider instance that issued it — the only instance that will
    /// consume a grant minted against it.
    public let providerInstance: UUID
    /// The census candidate the grant must target.
    public let candidateClass: EstateCandidateClass
    /// 32 bytes from the provider's injected randomness.
    public let nonce: [UInt8]
    /// Issue time, epoch seconds, injected clock.
    public let issuedAt: UInt64
    /// Expiry, epoch seconds.
    public let expiresAt: UInt64
    /// The provider's CURRENT generations at issue. The minting app copies
    /// these into the envelope, and the challenge digest (the MAC salt)
    /// covers them — so an envelope can only ever verify with the exact
    /// generations the provider challenged with, and a rotation between
    /// challenge and consume burns the grant twice over (salt mismatch AND
    /// the exactly-current credential check).
    public let credentialGeneration: UInt64
    public let providerGeneration: UInt64
    public let descriptorGeneration: UInt64

    public init(
        challengeIdentifier: UUID, providerInstance: UUID,
        candidateClass: EstateCandidateClass, nonce: [UInt8],
        issuedAt: UInt64, expiresAt: UInt64,
        credentialGeneration: UInt64, providerGeneration: UInt64, descriptorGeneration: UInt64
    ) {
        self.challengeIdentifier = challengeIdentifier
        self.providerInstance = providerInstance
        self.candidateClass = candidateClass
        self.nonce = nonce
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.credentialGeneration = credentialGeneration
        self.providerGeneration = providerGeneration
        self.descriptorGeneration = descriptorGeneration
    }

    /// SHA-256 of the canonical challenge transcript — the HKDF salt for the
    /// grant key. Length-prefixed via `CanonicalEncoder` (the same
    /// anti-ambiguity argument as every MACD-2b MAC input).
    public func challengeDigest() -> [UInt8] {
        var encoder = CanonicalEncoder()
        encoder.appendString(Self.challengeDomain)
        encoder.appendUUID(challengeIdentifier)
        encoder.appendUUID(providerInstance)
        encoder.appendString(candidateClass.rawValue)
        encoder.appendBytes(nonce)
        encoder.appendUInt64(issuedAt)
        encoder.appendUInt64(expiresAt)
        encoder.appendUInt64(credentialGeneration)
        encoder.appendUInt64(providerGeneration)
        encoder.appendUInt64(descriptorGeneration)
        return FirstPartyAuthProtocol.sha256(encoder.bytes)
    }

    /// The exact key set of the durable challenge file (the App Group wire
    /// form the attended app reads; ARIA_MCP_SPEC §migration grant).
    private static let recordFields: Set<String> = [
        "challengeIdentifier", "providerInstance", "candidateClass", "nonce",
        "issuedAt", "expiresAt",
        "credentialGeneration", "providerGeneration", "descriptorGeneration",
    ]

    /// Canonical JSON for the App Group challenge file (sorted keys,
    /// base64url nonce, decimal-string integers). Carries no secret: the
    /// nonce is public challenge material; authentication comes from
    /// K_install possession, never from the nonce (P-c2-3).
    public func encoded() -> Data {
        let object: [String: Any] = [
            "challengeIdentifier": challengeIdentifier.uuidString,
            "providerInstance": providerInstance.uuidString,
            "candidateClass": candidateClass.rawValue,
            "nonce": FirstPartyAuthProtocol.base64URLEncode(nonce),
            "issuedAt": ProviderGenerations.wireEncode(issuedAt),
            "expiresAt": ProviderGenerations.wireEncode(expiresAt),
            "credentialGeneration": ProviderGenerations.wireEncode(credentialGeneration),
            "providerGeneration": ProviderGenerations.wireEncode(providerGeneration),
            "descriptorGeneration": ProviderGenerations.wireEncode(descriptorGeneration),
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// Decode a durable challenge file. `nil` for anything malformed.
    public static func decode(_ data: Data) -> MigrationChallenge? {
        guard let object = FirstPartyAuthProtocol.strictJSONObject(
            data, expected: recordFields, maxBytes: 4 * 1024
        ) else { return nil }
        guard
            let challengeRaw = object["challengeIdentifier"] as? String,
            let challengeIdentifier = UUID(uuidString: challengeRaw),
            let instanceRaw = object["providerInstance"] as? String,
            let providerInstance = UUID(uuidString: instanceRaw),
            let classRaw = object["candidateClass"] as? String,
            let candidateClass = EstateCandidateClass(rawValue: classRaw),
            let nonceRaw = object["nonce"] as? String,
            let nonce = FirstPartyAuthProtocol.base64URLDecode(nonceRaw),
            let issuedRaw = object["issuedAt"] as? String,
            let issuedAt = ProviderGenerations.wireDecode(issuedRaw),
            let expiresRaw = object["expiresAt"] as? String,
            let expiresAt = ProviderGenerations.wireDecode(expiresRaw),
            let credentialRaw = object["credentialGeneration"] as? String,
            let credentialGeneration = ProviderGenerations.wireDecode(credentialRaw),
            let providerRaw = object["providerGeneration"] as? String,
            let providerGeneration = ProviderGenerations.wireDecode(providerRaw),
            let descriptorRaw = object["descriptorGeneration"] as? String,
            let descriptorGeneration = ProviderGenerations.wireDecode(descriptorRaw)
        else { return nil }
        return MigrationChallenge(
            challengeIdentifier: challengeIdentifier, providerInstance: providerInstance,
            candidateClass: candidateClass, nonce: nonce,
            issuedAt: issuedAt, expiresAt: expiresAt,
            credentialGeneration: credentialGeneration,
            providerGeneration: providerGeneration,
            descriptorGeneration: descriptorGeneration
        )
    }
}

/// Whether the grant carries an escrow of the legacy estate key.
public enum EscrowMarker: String, Sendable, Equatable {
    /// No key escrow travels with this grant (plaintext source handled by the
    /// user-approved encryption upgrade BEFORE migration, or key already
    /// shared).
    case none
    /// The already-existing legacy estate key was escrowed into the fixed
    /// shared data-protection Keychain account under this grant's challenge.
    case escrowed
}

/// The MACed, expiring, single-use attended migration grant envelope.
public struct MigrationGrantEnvelope: Sendable, Equatable {

    /// The grant MAC's HKDF domain (P-c2-3). NEW in this mission, distinct
    /// from every MACD-2b domain and from the handover-lease domain; part of
    /// the self-report digest.
    public static let grantDomain = "MOOTX01-MIGRATION-GRANT-v1"

    /// Grant lifetime in seconds — the attended window between the app
    /// minting the envelope and the provider consuming it.
    public static let grantLifetime: UInt64 = 300

    /// Envelope byte cap, enforced BEFORE resolution (P-c2-5; the c0
    /// bookmark-size precedent).
    public static let maxEnvelopeBytes = 16384

    /// Single-use identity of this grant.
    public let grantIdentifier: UUID
    /// The provider instance this grant is bound to.
    public let providerInstance: UUID
    /// The census candidate class this grant targets.
    public let candidateClass: EstateCandidateClass
    /// The outstanding challenge this grant answers.
    public let challengeIdentifier: UUID
    /// Credential generation at mint — must be EXACTLY current at consume.
    public let credentialGeneration: UInt64
    /// Provider generation at mint.
    public let providerGeneration: UInt64
    /// Descriptor generation at mint.
    public let descriptorGeneration: UInt64
    /// Mint time, epoch seconds.
    public let issuedAt: UInt64
    /// Expiry, epoch seconds.
    public let expiresAt: UInt64
    /// SHA-256 of the bookmark bytes — bound into the MAC so the carried
    /// bytes cannot be substituted without failing verification.
    public let bookmarkDigestSHA256: [UInt8]
    /// The opaque bookmark bytes (`bookmarkData(options: [])` exactly).
    /// Mutable only so adversarial tests can produce malformed envelopes;
    /// any mutation breaks the digest binding and refuses.
    public var bookmark: [UInt8]
    /// Whether a key escrow travels with this grant.
    public let escrowMarker: EscrowMarker
    /// HMAC-SHA256 over `macInput()` under the challenge-derived grant key.
    public var grantMAC: [UInt8]

    public init(
        grantIdentifier: UUID, providerInstance: UUID,
        candidateClass: EstateCandidateClass, challengeIdentifier: UUID,
        credentialGeneration: UInt64, providerGeneration: UInt64, descriptorGeneration: UInt64,
        issuedAt: UInt64, expiresAt: UInt64,
        bookmarkDigestSHA256: [UInt8], bookmark: [UInt8],
        escrowMarker: EscrowMarker, grantMAC: [UInt8]
    ) {
        self.grantIdentifier = grantIdentifier
        self.providerInstance = providerInstance
        self.candidateClass = candidateClass
        self.challengeIdentifier = challengeIdentifier
        self.credentialGeneration = credentialGeneration
        self.providerGeneration = providerGeneration
        self.descriptorGeneration = descriptorGeneration
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.bookmarkDigestSHA256 = bookmarkDigestSHA256
        self.bookmark = bookmark
        self.escrowMarker = escrowMarker
        self.grantMAC = grantMAC
    }

    /// `K_grant = HKDF-SHA256(K_install, salt: SHA-256(challenge), info: grantDomain)`.
    /// The salt is the CHALLENGE digest — this is what makes every envelope
    /// valid against exactly one outstanding challenge (P-c2-3).
    public static func grantKey(installationRoot: [UInt8], challenge: MigrationChallenge) -> [UInt8] {
        FirstPartyAuthProtocol.hkdfSHA256(
            inputKeyingMaterial: installationRoot,
            salt: challenge.challengeDigest(),
            info: Array(grantDomain.utf8),
            outputByteCount: FirstPartyAuthProtocol.macByteCount
        )
    }

    /// The canonical MAC input: the domain and every field except the MAC and
    /// the raw bookmark BYTES — the bookmark participates through its digest,
    /// so verification never requires holding the bytes and the bytes cannot
    /// be swapped under a valid MAC.
    public func macInput() -> [UInt8] {
        var encoder = CanonicalEncoder()
        encoder.appendString(Self.grantDomain)
        encoder.appendUUID(grantIdentifier)
        encoder.appendUUID(providerInstance)
        encoder.appendString(candidateClass.rawValue)
        encoder.appendUUID(challengeIdentifier)
        encoder.appendUInt64(credentialGeneration)
        encoder.appendUInt64(providerGeneration)
        encoder.appendUInt64(descriptorGeneration)
        encoder.appendUInt64(issuedAt)
        encoder.appendUInt64(expiresAt)
        encoder.appendBytes(bookmarkDigestSHA256)
        encoder.appendString(escrowMarker.rawValue)
        return encoder.bytes
    }

    /// A copy with `grantMAC` computed under the challenge-derived key.
    public func sealed(installationRoot: [UInt8], challenge: MigrationChallenge) -> MigrationGrantEnvelope {
        var copy = self
        copy.grantMAC = FirstPartyAuthProtocol.hmacSHA256(
            key: Self.grantKey(installationRoot: installationRoot, challenge: challenge),
            message: macInput()
        )
        return copy
    }

    /// Constant-time MAC verification against one challenge.
    public func verifyMAC(installationRoot: [UInt8], challenge: MigrationChallenge) -> Bool {
        guard grantMAC.count == FirstPartyAuthProtocol.macByteCount else { return false }
        let expected = FirstPartyAuthProtocol.hmacSHA256(
            key: Self.grantKey(installationRoot: installationRoot, challenge: challenge),
            message: macInput()
        )
        return FirstPartyAuthProtocol.constantTimeEquals(expected, grantMAC)
    }

    /// The exact key set of a durable envelope record.
    private static let recordFields: Set<String> = [
        "grantIdentifier", "providerInstance", "candidateClass", "challengeIdentifier",
        "credentialGeneration", "providerGeneration", "descriptorGeneration",
        "issuedAt", "expiresAt", "bookmarkDigest", "bookmark", "escrowMarker", "grantMAC",
    ]

    /// Canonical JSON for the App Group envelope file (sorted keys, base64url
    /// byte fields, decimal-string integers). The bookmark bytes appear HERE
    /// and nowhere else (P-c2-5).
    public func encoded() -> Data {
        let object: [String: Any] = [
            "grantIdentifier": grantIdentifier.uuidString,
            "providerInstance": providerInstance.uuidString,
            "candidateClass": candidateClass.rawValue,
            "challengeIdentifier": challengeIdentifier.uuidString,
            "credentialGeneration": ProviderGenerations.wireEncode(credentialGeneration),
            "providerGeneration": ProviderGenerations.wireEncode(providerGeneration),
            "descriptorGeneration": ProviderGenerations.wireEncode(descriptorGeneration),
            "issuedAt": ProviderGenerations.wireEncode(issuedAt),
            "expiresAt": ProviderGenerations.wireEncode(expiresAt),
            "bookmarkDigest": FirstPartyAuthProtocol.base64URLEncode(bookmarkDigestSHA256),
            "bookmark": FirstPartyAuthProtocol.base64URLEncode(bookmark),
            "escrowMarker": escrowMarker.rawValue,
            "grantMAC": FirstPartyAuthProtocol.base64URLEncode(grantMAC),
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// Decode a durable envelope. `nil` for anything malformed: wrong key
    /// set, wrong types, non-canonical spellings, or a record over the byte
    /// cap — the cap is judged BEFORE parsing (P-c2-5).
    public static func decode(_ data: Data) -> MigrationGrantEnvelope? {
        guard let object = FirstPartyAuthProtocol.strictJSONObject(
            data, expected: recordFields, maxBytes: maxEnvelopeBytes
        ) else { return nil }
        guard
            let grantRaw = object["grantIdentifier"] as? String,
            let grantIdentifier = UUID(uuidString: grantRaw),
            let instanceRaw = object["providerInstance"] as? String,
            let providerInstance = UUID(uuidString: instanceRaw),
            let classRaw = object["candidateClass"] as? String,
            let candidateClass = EstateCandidateClass(rawValue: classRaw),
            let challengeRaw = object["challengeIdentifier"] as? String,
            let challengeIdentifier = UUID(uuidString: challengeRaw),
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
            let digestRaw = object["bookmarkDigest"] as? String,
            let bookmarkDigest = FirstPartyAuthProtocol.base64URLDecode(digestRaw),
            let bookmarkRaw = object["bookmark"] as? String,
            let bookmark = FirstPartyAuthProtocol.base64URLDecode(bookmarkRaw),
            let escrowRaw = object["escrowMarker"] as? String,
            let escrowMarker = EscrowMarker(rawValue: escrowRaw),
            let macRaw = object["grantMAC"] as? String,
            let grantMAC = FirstPartyAuthProtocol.base64URLDecode(macRaw)
        else { return nil }
        return MigrationGrantEnvelope(
            grantIdentifier: grantIdentifier, providerInstance: providerInstance,
            candidateClass: candidateClass, challengeIdentifier: challengeIdentifier,
            credentialGeneration: credentialGeneration,
            providerGeneration: providerGeneration,
            descriptorGeneration: descriptorGeneration,
            issuedAt: issuedAt, expiresAt: expiresAt,
            bookmarkDigestSHA256: bookmarkDigest, bookmark: bookmark,
            escrowMarker: escrowMarker, grantMAC: grantMAC
        )
    }
}

/// What a successful one-use consumption yields: the opaque bookmark bytes
/// (for immediate resolution and nothing else) and the grant's identifiers.
public struct ConsumedGrant: Sendable, Equatable {
    /// The consumed grant's identity (now durably burnt).
    public let grantIdentifier: UUID
    /// The candidate class the grant targets.
    public let candidateClass: EstateCandidateClass
    /// The opaque bookmark bytes. The caller resolves them ONCE, immediately,
    /// with `.withoutUI`, and never persists them anywhere else (P-c2-5).
    public let bookmark: [UInt8]
    /// Whether a key escrow travels with the grant.
    public let escrowMarker: EscrowMarker

    public init(
        grantIdentifier: UUID, candidateClass: EstateCandidateClass,
        bookmark: [UInt8], escrowMarker: EscrowMarker
    ) {
        self.grantIdentifier = grantIdentifier
        self.candidateClass = candidateClass
        self.bookmark = bookmark
        self.escrowMarker = escrowMarker
    }
}

/// Validates and atomically consumes migration grants (P-c2-4).
public struct MigrationGrantAuthority: Sendable {

    private let journal: LeaseConsumptionJournal
    private let clock: ProviderClock

    /// - Parameters:
    ///   - journal: The grant consumption journal
    ///     (`ProviderRootLayout.grantJournal`) — the same journal-first
    ///     durable one-use record type the handover lease uses.
    ///   - clock: Injected clock (P-c2-12).
    public init(journal: LeaseConsumptionJournal, clock: @escaping ProviderClock) {
        self.journal = journal
        self.clock = clock
    }

    /// Consume a grant ATOMICALLY, in this exact order:
    /// MAC (challenge-derived key) → expiry → binding (instance + candidate +
    /// challenge + bookmark-digest integrity) → credential-generation
    /// exactness → journal replay check → DURABLE journal record → return.
    ///
    /// The durable record precedes the return, so every crash point either
    /// leaves the grant unconsumed (refusal happened first) or burnt
    /// (recorded, never re-consumable). A burnt grant that then fails
    /// downstream requires a FRESH attended grant — never a silent re-mint
    /// (KONG-3b).
    ///
    /// - Throws: `DaemonProviderError.grantInvalid` naming the failed gate.
    public func consume(
        _ envelope: MigrationGrantEnvelope,
        installationRoot: [UInt8],
        challenge: MigrationChallenge,
        currentGenerations: ProviderGenerations
    ) throws -> ConsumedGrant {
        // 1. Authenticity first: an unMACed envelope's fields are attacker
        //    input and must not steer later gates. The challenge-derived key
        //    makes a wrong-challenge envelope fail HERE, as bad-mac.
        guard envelope.verifyMAC(installationRoot: installationRoot, challenge: challenge) else {
            throw DaemonProviderError.grantInvalid(.badMAC)
        }
        // 2. Expiry, on the injected clock (both the envelope's own window
        //    and the challenge's).
        let now = clock()
        guard now <= envelope.expiresAt, now <= challenge.expiresAt else {
            throw DaemonProviderError.grantInvalid(.expired)
        }
        // 3. Binding: only the issuing instance, for the challenged
        //    candidate, against the outstanding challenge. The bookmark bytes
        //    must still match their MAC-bound digest — a swapped payload
        //    refuses even under a valid MAC.
        guard envelope.providerInstance == challenge.providerInstance,
              envelope.candidateClass == challenge.candidateClass,
              envelope.challengeIdentifier == challenge.challengeIdentifier,
              FirstPartyAuthProtocol.constantTimeEquals(
                FirstPartyAuthProtocol.sha256(envelope.bookmark),
                envelope.bookmarkDigestSHA256
              )
        else {
            throw DaemonProviderError.grantInvalid(.bindingMismatch)
        }
        // 4. Credential generation must be EXACTLY current: a rotation burns
        //    every outstanding grant (same rule as leases).
        guard envelope.credentialGeneration == currentGenerations.credential else {
            throw DaemonProviderError.grantInvalid(.staleGeneration)
        }
        // 5. Replay: the durable journal, fail-closed.
        do {
            guard try !journal.contains(envelope.grantIdentifier) else {
                throw DaemonProviderError.grantInvalid(.consumed)
            }
        } catch DaemonProviderError.leaseInvalid(.journalUnavailable) {
            throw DaemonProviderError.grantInvalid(.journalUnavailable)
        }
        // 6. Burn BEFORE resolve (journal-first): once recorded, this grant
        //    can never resolve again — even if we crash on the next
        //    instruction.
        do {
            try journal.recordConsumption(envelope.grantIdentifier)
        } catch DaemonProviderError.leaseInvalid(.journalUnavailable) {
            throw DaemonProviderError.grantInvalid(.journalUnavailable)
        }
        // 7. Resolve.
        return ConsumedGrant(
            grantIdentifier: envelope.grantIdentifier,
            candidateClass: envelope.candidateClass,
            bookmark: envelope.bookmark,
            escrowMarker: envelope.escrowMarker
        )
    }
}

// MARK: - Bookmark-resolution verification (P-c2-6, c0 F4 discipline)

/// F4-disciplined refusal classification for a resolved-bookmark target. The
/// classifier is an EXISTENCE ORACLE and nothing more: EPERM means an
/// existing thing denied us, ENOENT means the path vacated, ELOOP means a
/// symlink — no classification ever carries the foreign path itself.
public enum ResolutionRefusal: String, Sendable, Equatable {
    /// The resolved URL is not byte-equal to the candidate URL the provider
    /// derived INDEPENDENTLY in census. Path from an envelope is never
    /// authority; a mismatch is a terminal refusal.
    case pathMismatch = "path-mismatch"
    /// fd identity or content digest disagrees with the census record.
    case identityMismatch = "identity-mismatch"
    /// The terminal component is a symbolic link (ELOOP under O_NOFOLLOW).
    case symlink
    /// The path no longer exists (ENOENT — the one absence answer).
    case vacated
    /// An existing object denied access (EPERM/EACCES).
    case accessDenied = "access-denied"
}

/// The verdict on one resolved bookmark.
public enum ResolutionVerdict: Sendable, Equatable {
    /// The resolution is accepted; `staleAccepted` records whether the
    /// bookmark reported stale (bound into the migration receipt as a
    /// first-class boolean, P-c2-6d).
    case accepted(staleAccepted: Bool)
    /// Terminal refusal. The consumed grant is burnt; a fresh attended grant
    /// is required (KONG-3b).
    case refused(ResolutionRefusal)
}

/// The production stale policy (P-c2-6). c0's proof-only stale decision
/// (record 01444470) does NOT transfer; this policy re-derives acceptance
/// from scratch:
///
/// A resolution — stale or not — is accepted ONLY when ALL hold:
///   (a) the bookmark was resolved `.withoutUI` (the caller's resolution
///       site enforces the option; this function judges the outcome);
///   (b) the resolved `standardizedFileURL` byte-equals the candidate URL the
///       PROVIDER derived independently in census — never a URL from the
///       envelope;
///   (c) fd identity verification through an `O_NOFOLLOW` open: regular
///       file, owned by the effective uid, device/inode/size AND content
///       digest matching the CENSUS record (the census read is the
///       ground-truth oracle — c0's precomputed-digest role, replaced);
///   (d) the migration receipt then carries `staleAccepted` as a genuine
///       boolean, and verification refuses a flag/receipt mismatch.
///
/// Stale plus ANY mismatch is a terminal refusal: grant burnt, fresh
/// attended grant required.
public enum GrantResolutionPolicy {

    /// Verify one resolved bookmark target against the census ground truth.
    public static func verify(
        resolvedURL: URL,
        providerDerivedCandidateURL: URL,
        censusMain: CensusCandidateRecord.Main,
        bookmarkWasStale: Bool
    ) -> ResolutionVerdict {
        // (b) Path byte-equality against the provider's OWN derivation.
        guard resolvedURL.standardizedFileURL.path == providerDerivedCandidateURL.standardizedFileURL.path else {
            return .refused(.pathMismatch)
        }
        // The census must actually have a record to verify against; a
        // resolution with no census identity is unverifiable and refuses.
        guard case .present(let bytes, let device, let inode, _, let digestHex) = censusMain else {
            // F4: distinguish vacated from other refusals for the record we
            // are ABOUT to open — but with no census record every outcome is
            // an identity mismatch unless the file is genuinely gone.
            var status = stat()
            if lstat(resolvedURL.path, &status) != 0 && errno == ENOENT {
                return .refused(.vacated)
            }
            return .refused(.identityMismatch)
        }
        // (c) fd identity through O_NOFOLLOW, classified with F4 discipline.
        let fd = open(resolvedURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            switch errno {
            case ELOOP: return .refused(.symlink)
            case ENOENT: return .refused(.vacated)
            case EPERM, EACCES: return .refused(.accessDenied)
            default: return .refused(.identityMismatch)
            }
        }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              UInt64(status.st_dev) == device,
              UInt64(status.st_ino) == inode,
              UInt64(status.st_size) == bytes
        else {
            return .refused(.identityMismatch)
        }
        // Content digest against the census oracle — STREAMED (bounded
        // memory: this verifies a whole estate file).
        guard let digest = try? SecureFiles.streamingDigestHex(fd: fd) else {
            return .refused(.identityMismatch)
        }
        guard digest == digestHex else {
            return .refused(.identityMismatch)
        }
        return .accepted(staleAccepted: bookmarkWasStale)
    }
}

// MARK: - Key escrow (P-c2-7)

/// Reads the escrowed legacy estate key. STRUCTURALLY mint-free: the protocol
/// has no add, no update, no delete — mirroring `KeychainItemAuthority`'s
/// deliberate no-update/no-delete posture. Minting over ciphertext is the
/// unopenable-estate bug this seam makes unexpressible.
public protocol KeyEscrowAuthority: Sendable {
    /// Read the escrowed key for `challenge`'s grant, classified with the
    /// provider's fatal-vs-absence matrix (never the CLI's
    /// missing-entitlement-as-absence shortcut).
    func readEscrowedKey(challenge: MigrationChallenge) -> KeychainReadResult
}

/// Why the escrow rules refused.
public enum EscrowRefusal: String, Sendable, Equatable {
    /// The source is ciphertext and no escrowed key exists. Minting a new key
    /// over ciphertext is FORBIDDEN — it can never decrypt the source.
    case keyAbsentForCiphertext = "key-absent-for-ciphertext"
    /// A fatal Keychain classification (missing entitlement, interaction
    /// required, unavailable) — never treated as absence.
    case keychainFatal = "keychain-fatal"
    /// The source is plaintext: the EXISTING user-approved encryption
    /// upgrade must run before any location migration (mission step 3).
    case plaintextRequiresEncryptionUpgrade = "plaintext-requires-encryption-upgrade"
    /// The source's encryption posture could not be read.
    case sourceUnreadable = "source-unreadable"
}

/// The escrow decision for one candidate.
public enum EscrowDecision: Sendable, Equatable {
    /// Use the escrowed key — AFTER proving it opens the source READ-ONLY
    /// (the provider verifies before any copy; P-c2-7).
    case useEscrowedKeyAfterReadOnlyVerify
    /// Refuse, with the classification.
    case refuse(EscrowRefusal)
}

/// The pure escrow rules (P-c2-7): never mint over ciphertext, plaintext
/// upgrades first, fatal is never absence.
public enum EscrowRules {

    /// Judge one candidate's escrow posture.
    public static func judge(
        encryption: EncryptionPosture,
        escrowRead: KeychainReadResult
    ) -> EscrowDecision {
        switch encryption {
        case .plaintext:
            // Location migration of plaintext is forbidden until the
            // user-approved encryption upgrade has produced ciphertext with
            // a stable key — regardless of what the escrow read says.
            return .refuse(.plaintextRequiresEncryptionUpgrade)
        case .unreadable:
            return .refuse(.sourceUnreadable)
        case .encrypted:
            switch escrowRead {
            case .found(let bytes):
                // A found key of the wrong shape is corruption, not a key.
                guard bytes.count == FirstPartyAuthProtocol.rootKeyByteCount else {
                    return .refuse(.keychainFatal)
                }
                return .useEscrowedKeyAfterReadOnlyVerify
            case .notFound:
                return .refuse(.keyAbsentForCiphertext)
            case .missingEntitlement, .interactionRequired, .unavailable:
                return .refuse(.keychainFatal)
            }
        }
    }
}
