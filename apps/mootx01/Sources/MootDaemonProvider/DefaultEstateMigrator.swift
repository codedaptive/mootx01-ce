import Foundation
import AriaMCP

// MARK: - MACD-2c2 — closed-database migration to the canonical estate (KONG-3)
//
// The migrator moves ONE quiesced, identity-verified legacy default estate
// into the canonical App Group location, under the held exclusive provider
// lock, with a durable MACed receipt whose ordering is the mission's
// corrected KONG-3 contract:
//
//   quiesce (exclusive open → checkpoint TRUNCATE → positive empty-WAL proof
//   → identity read → close) → immutable backup → copy closed main into the
//   transaction incoming directory (fsync file + directory) → verify (digest,
//   read-only open, integrity, identity) → DURABLE staged receipt (fsynced,
//   full identity set) → ATOMIC RENAME into canonical (fsync parent) →
//   receipt finalized committed.
//
// The staged receipt lands BEFORE the rename — the correction over the
// mission's original step order — so every crash point converges:
//   staged + no canonical      → safe retry (source retained, re-runnable)
//   staged + canonical verifies → verify-and-finalize
//   committed                  → idempotent no-op
// and at no point do two openable authorities exist for the same estate: the
// source is closed before any copy, and the copy is verified before it can
// become canonical.
//
// The source is NEVER deleted, mutated, or checkpoint-raced: the
// `FileMigrationAuthority` seam has no delete primitive at all (structural),
// `-shm` is never copied and a live `-wal` refuses upstream (census +
// empty-WAL proof), and every failure path retains the source and the backup.
//
// SQLite-semantic operations cross the injected `SourceEstateAccess` seam,
// which has NO production conformer in this module (frozen package graph;
// the conformer arrives with MACD-3 estate routing). The machine, ordering,
// receipts, and crash convergence are proven here with adversarial fakes.

/// The migration machine's steps, in order. These are OBSERVABILITY states
/// (self-report + UI vocabulary) — deliberately NOT arbiter states: the
/// twelve `ProviderArbiterState` wire encodings are frozen, and
/// `awaiting-migration-grant` is a migration-machine fact, not a provider
/// arbitration fact.
public enum MigrationStep: Int, Sendable, Equatable, CaseIterable {
    /// Census assembled and judged.
    case census = 0
    /// Exactly one valid candidate elected by the census.
    case exactlyOneCandidate = 1
    /// The provider issued a challenge and awaits the attended grant.
    case awaitingMigrationGrant = 2
    /// The one-use grant was consumed (durably burnt).
    case grantConsumed = 3
    /// The source was exclusively opened, checkpointed, proven WAL-empty,
    /// identity-read, and closed.
    case sourceQuiesced = 4
    /// The closed main was copied into the incoming directory and the staged
    /// receipt is durable (KONG-3: BEFORE the rename).
    case staged = 5
    /// The incoming copy verified (digest, read-only open, identity).
    case verified = 6
    /// The atomic rename into canonical completed and the receipt finalized.
    case committed = 7
    /// The target provider proved authenticated readiness for the same
    /// estate UUID.
    case targetReady = 8
    /// The receipt reached its terminal committed form AND the one-use grant
    /// material was removed with its absence verified (P-c2-5). Reached only
    /// after `committed`; a machine that could not remove the material fails
    /// with `.grantMaterialRetained` rather than claiming this state.
    case receiptFinal = 9
    /// Failure path: the canonical copy was quarantined (renamed aside,
    /// never unlinked).
    case quarantined = 10
    /// Failure path: prior provider/config restored and verified.
    case rolledBack = 11
    /// Failure path: no compatible rollback; operator recovery required.
    case recoveryRequired = 12

    /// The stable wire encoding. Prefixed so no spelling can collide with an
    /// arbiter state (the frozen 12) — `awaiting-migration-grant` carries the
    /// mission's own name.
    public var wireEncoding: String {
        switch self {
        case .census: return "migration-census"
        case .exactlyOneCandidate: return "migration-one-candidate"
        case .awaitingMigrationGrant: return "awaiting-migration-grant"
        case .grantConsumed: return "migration-grant-consumed"
        case .sourceQuiesced: return "migration-source-quiesced"
        case .staged: return "migration-staged"
        case .verified: return "migration-verified"
        case .committed: return "migration-committed"
        case .targetReady: return "migration-target-ready"
        case .receiptFinal: return "migration-receipt-final"
        case .quarantined: return "migration-quarantined"
        case .rolledBack: return "migration-rolled-back"
        case .recoveryRequired: return "migration-recovery-required"
        }
    }

    /// Every wire encoding, in step order — part of the self-report digest.
    public static let allWireEncodings: [String] = MigrationStep.allCases.map { $0.wireEncoding }
}

// MARK: - Injected seams

/// SQLite-semantic access to the SOURCE estate (and read-only verification of
/// the copied destination). No production conformer exists in this module —
/// the estate stack sits above the frozen package graph and the conformer
/// arrives with MACD-3. Tests inject adversarial counting/crashing fakes.
public protocol SourceEstateAccess: Sendable {
    /// Open the source EXCLUSIVELY (no other connection may exist).
    func openExclusive() async throws
    /// `PRAGMA wal_checkpoint(TRUNCATE)`.
    func checkpointTruncate() async throws
    /// POSITIVE proof the WAL is empty after the truncating checkpoint —
    /// absence of error is not proof; this call must verify emptiness.
    func verifyEmptyWAL() async throws
    /// Read the estate's identity (UUID, schema, anchor counts) read-only.
    func readIdentity() async throws -> CensusIdentity
    /// Close the source. After this, no open authority exists for it.
    func close() async throws
    /// Open the COPIED database at `destination` read-only (SQLCipher, stable
    /// key account), run integrity verification, and return its identity.
    func verifyReadOnlyOpen(destination: URL) async throws -> CensusIdentity
}

/// File-semantic migration operations. DELIBERATELY has no delete primitive:
/// source deletion is unexpressible through this seam (mission hard stop).
/// The default production conformer is `SecureFileMigration` below.
public protocol FileMigrationAuthority: Sendable {
    /// Copy the CLOSED main database file into the incoming directory;
    /// fsync the file and its directory; return the copy's SHA-256 hex.
    /// Only the main file — never `-wal`, never `-shm`.
    func copyMainToIncoming(source: URL, incoming: URL) async throws -> String
    /// SHA-256 hex of the file at `url`.
    func digestOf(url: URL) async throws -> String
    /// `rename(2)` the incoming copy into the canonical location; fsync the
    /// canonical parent directory.
    func atomicRenameIntoCanonical(incoming: URL, canonical: URL) async throws
    /// Move the canonical file aside into the transaction-named quarantine
    /// directory. A RENAME — never an unlink (KONG-3c).
    func quarantineCanonical(canonical: URL, quarantineDirectory: URL) async throws
    /// Copy the source into the immutable backup directory (source retained;
    /// the backup is the recoverable artifact the mission mandates).
    func preserveBackup(source: URL, backupDirectory: URL) async throws
}

/// The production file-semantic conformer, built on `SecureFiles`' durable
/// primitives. Bytes move through validated descriptors in FIXED-SIZE CHUNKS
/// (an estate is gigabytes — nothing here is ever resident whole); every write
/// is fsynced; the rename is `SecureFiles`-shaped (rename + parent fsync).
public struct SecureFileMigration: FileMigrationAuthority {

    public init() {}

    public func copyMainToIncoming(source: URL, incoming: URL) async throws -> String {
        try FileManager.default.createDirectory(
            at: incoming.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Single-pass streaming copy: the returned digest describes exactly
        // the bytes written, so no second read can be raced against the copy.
        return try SecureFiles.streamingCopyDigestHex(from: source, to: incoming)
    }

    public func digestOf(url: URL) async throws -> String {
        try SecureFiles.streamingDigestHex(of: url)
    }

    public func atomicRenameIntoCanonical(incoming: URL, canonical: URL) async throws {
        try FileManager.default.createDirectory(
            at: canonical.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard rename(incoming.path, canonical.path) == 0 else {
            throw DaemonProviderError.hygieneViolation(.unopenable)
        }
        // THE most durability-load-bearing fsync in the mission: this is the
        // rename that makes an estate canonical, and KONG-3's crash matrix
        // assumes it is durable before the receipt is finalized. Checked, so a
        // parent that cannot be synced fails the migration instead of leaving
        // a canonical estate that may not survive a power loss.
        try SecureFiles.fsyncParentDirectory(of: canonical)
    }

    public func quarantineCanonical(canonical: URL, quarantineDirectory: URL) async throws {
        try FileManager.default.createDirectory(
            at: quarantineDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = quarantineDirectory.appendingPathComponent(canonical.lastPathComponent)
        guard rename(canonical.path, destination.path) == 0 else {
            throw DaemonProviderError.hygieneViolation(.unopenable)
        }
        // Quarantine is a recovery artifact: if its directory entry is not
        // durable, a power loss can lose the very copy an operator was told to
        // inspect. Both parents are synced — the destination's (the new entry)
        // and the source's (the removed entry).
        try SecureFiles.fsyncParentDirectory(of: destination)
        try SecureFiles.fsyncParentDirectory(of: canonical)
    }

    public func preserveBackup(source: URL, backupDirectory: URL) async throws {
        try FileManager.default.createDirectory(
            at: backupDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = backupDirectory.appendingPathComponent(source.lastPathComponent)
        // O_EXCL inside the streaming copy: a backup that already exists is
        // NOT overwritten — the immutable-backup contract means a second
        // attempt refuses rather than replacing recoverable material.
        _ = try SecureFiles.streamingCopyDigestHex(from: source, to: destination)
    }
}

// MARK: - The durable receipt

/// How the estate key transitioned in this migration.
public enum KeyTransition: String, Sendable, Equatable {
    /// The already-existing legacy key was escrowed and adopted for the
    /// stable default-estate account (never a mint).
    case escrowedExistingKey = "escrowed-existing-key"
    /// The key was already shared under the stable account; no transition.
    case sharedExisting = "shared-existing"

    /// Derive the transition from the grant's escrow marker and the escrow
    /// rules' decision (Adams MAJOR-6: the receipt must record what actually
    /// happened, never a hard-coded assumption).
    ///
    /// - Parameters:
    ///   - marker: The consumed grant's escrow marker.
    ///   - decision: The `EscrowRules` verdict for the source. Only the
    ///     use-the-escrowed-key verdict can produce an escrow transition; any
    ///     refusal means no migration proceeds at all, so the caller must not
    ///     build a transaction from it.
    /// - Returns: The transition to bind into the receipt, or `nil` when the
    ///   escrow rules refused (no transaction is legal).
    public static func derive(
        marker: EscrowMarker, decision: EscrowDecision
    ) -> KeyTransition? {
        guard decision == .useEscrowedKeyAfterReadOnlyVerify else { return nil }
        switch marker {
        case .escrowed:
            return .escrowedExistingKey
        case .none:
            // No escrow travelled with the grant: the key was already
            // reachable under the stable shared account.
            return .sharedExisting
        }
    }
}

/// The MACed, idempotent migration receipt (KONG-3 corrected ordering:
/// written `staged` BEFORE the atomic rename, finalized `committed` after).
/// Carries digests and identifiers ONLY — never a path, key, or bookmark
/// byte (P-c2-5/P-c2-11); the grant participates as its digest.
public struct MigrationReceipt: Sendable, Equatable {

    /// The receipt MAC's HKDF domain. Distinct from every other domain.
    public static let receiptDomain = "MOOTX01-MIGRATION-RECEIPT-v1"

    /// Receipt lifecycle states.
    public enum State: String, Sendable, Equatable {
        /// Intent durable; the rename may or may not have happened yet.
        case staged
        /// The rename completed and verified.
        case committed
        /// The canonical copy was quarantined after a failure.
        case quarantined
        /// The prior provider/config was restored.
        case rolledBack = "rolled-back"
        /// Operator recovery required.
        case recoveryRequired = "recovery-required"
    }

    /// The migration transaction's identity.
    public let transactionIdentifier: UUID
    /// Lifecycle state.
    public var state: State
    /// The source candidate's class label (never its path).
    public let sourceClass: EstateCandidateClass
    /// SHA-256 hex of the closed source main file.
    public let sourceDigestHex: String
    /// SHA-256 hex of the verified destination copy.
    public let destinationDigestHex: String
    /// The estate's identity.
    public let estateIdentifier: UUID
    /// The estate's schema version.
    public let schemaVersion: UInt64
    /// How the key transitioned.
    public let keyTransition: KeyTransition
    /// Generations at staging.
    public let credentialGeneration: UInt64
    public let providerGeneration: UInt64
    public let descriptorGeneration: UInt64
    /// SHA-256 hex of the consumed grant envelope (bookmark NEVER appears).
    public let grantDigestHex: String
    /// SHA-256 hex of the immutable backup copy.
    public let backupDigestHex: String
    /// Whether a stale bookmark resolution was accepted (P-c2-6d) — a
    /// FIRST-CLASS boolean, bound into the MAC; verification refuses a
    /// flag/receipt mismatch. Mutable only so adversarial tests can prove
    /// that flipping it breaks the MAC.
    public var staleAccepted: Bool
    /// Staging time, epoch seconds, injected clock.
    public let stagedAt: UInt64
    /// Finalization time (0 while staged).
    public var finalizedAt: UInt64
    /// HMAC-SHA256 over `macInput()` under the receipt key.
    public var receiptMAC: [UInt8]

    public init(
        transactionIdentifier: UUID, state: State, sourceClass: EstateCandidateClass,
        sourceDigestHex: String, destinationDigestHex: String,
        estateIdentifier: UUID, schemaVersion: UInt64,
        keyTransition: KeyTransition,
        credentialGeneration: UInt64, providerGeneration: UInt64, descriptorGeneration: UInt64,
        grantDigestHex: String, backupDigestHex: String,
        staleAccepted: Bool, stagedAt: UInt64, finalizedAt: UInt64,
        receiptMAC: [UInt8]
    ) {
        self.transactionIdentifier = transactionIdentifier
        self.state = state
        self.sourceClass = sourceClass
        self.sourceDigestHex = sourceDigestHex
        self.destinationDigestHex = destinationDigestHex
        self.estateIdentifier = estateIdentifier
        self.schemaVersion = schemaVersion
        self.keyTransition = keyTransition
        self.credentialGeneration = credentialGeneration
        self.providerGeneration = providerGeneration
        self.descriptorGeneration = descriptorGeneration
        self.grantDigestHex = grantDigestHex
        self.backupDigestHex = backupDigestHex
        self.staleAccepted = staleAccepted
        self.stagedAt = stagedAt
        self.finalizedAt = finalizedAt
        self.receiptMAC = receiptMAC
    }

    /// `K_receipt = HKDF-SHA256(K_install, salt: 32 zero octets, info: receiptDomain)`.
    public static func receiptKey(installationRoot: [UInt8]) -> [UInt8] {
        FirstPartyAuthProtocol.hkdfSHA256(
            inputKeyingMaterial: installationRoot,
            salt: [UInt8](repeating: 0, count: 32),
            info: Array(receiptDomain.utf8),
            outputByteCount: FirstPartyAuthProtocol.macByteCount
        )
    }

    /// The canonical MAC input: domain and every field except the MAC.
    /// `staleAccepted` participates as 0/1 — flipping the flag without
    /// resealing fails verification (P-c2-6d).
    public func macInput() -> [UInt8] {
        var encoder = CanonicalEncoder()
        encoder.appendString(Self.receiptDomain)
        encoder.appendUUID(transactionIdentifier)
        encoder.appendString(state.rawValue)
        encoder.appendString(sourceClass.rawValue)
        encoder.appendString(sourceDigestHex)
        encoder.appendString(destinationDigestHex)
        encoder.appendUUID(estateIdentifier)
        encoder.appendUInt64(schemaVersion)
        encoder.appendString(keyTransition.rawValue)
        encoder.appendUInt64(credentialGeneration)
        encoder.appendUInt64(providerGeneration)
        encoder.appendUInt64(descriptorGeneration)
        encoder.appendString(grantDigestHex)
        encoder.appendString(backupDigestHex)
        encoder.appendUInt64(staleAccepted ? 1 : 0)
        encoder.appendUInt64(stagedAt)
        encoder.appendUInt64(finalizedAt)
        return encoder.bytes
    }

    /// A copy with `receiptMAC` computed under `installationRoot`.
    public func sealed(installationRoot: [UInt8]) -> MigrationReceipt {
        var copy = self
        copy.receiptMAC = FirstPartyAuthProtocol.hmacSHA256(
            key: Self.receiptKey(installationRoot: installationRoot),
            message: macInput()
        )
        return copy
    }

    /// Constant-time MAC verification.
    public func verifyMAC(installationRoot: [UInt8]) -> Bool {
        guard receiptMAC.count == FirstPartyAuthProtocol.macByteCount else { return false }
        let expected = FirstPartyAuthProtocol.hmacSHA256(
            key: Self.receiptKey(installationRoot: installationRoot),
            message: macInput()
        )
        return FirstPartyAuthProtocol.constantTimeEquals(expected, receiptMAC)
    }

    /// The exact key set of a durable receipt record.
    private static let recordFields: Set<String> = [
        "transactionIdentifier", "state", "sourceClass",
        "sourceDigest", "destinationDigest", "estateIdentifier", "schemaVersion",
        "keyTransition", "credentialGeneration", "providerGeneration",
        "descriptorGeneration", "grantDigest", "backupDigest",
        "staleAccepted", "stagedAt", "finalizedAt", "receiptMAC",
    ]

    /// Canonical JSON. `staleAccepted` is a GENUINE JSON boolean (P-c2-6d).
    public func encoded() -> Data {
        let object: [String: Any] = [
            "transactionIdentifier": transactionIdentifier.uuidString,
            "state": state.rawValue,
            "sourceClass": sourceClass.rawValue,
            "sourceDigest": sourceDigestHex,
            "destinationDigest": destinationDigestHex,
            "estateIdentifier": estateIdentifier.uuidString,
            "schemaVersion": ProviderGenerations.wireEncode(schemaVersion),
            "keyTransition": keyTransition.rawValue,
            "credentialGeneration": ProviderGenerations.wireEncode(credentialGeneration),
            "providerGeneration": ProviderGenerations.wireEncode(providerGeneration),
            "descriptorGeneration": ProviderGenerations.wireEncode(descriptorGeneration),
            "grantDigest": grantDigestHex,
            "backupDigest": backupDigestHex,
            "staleAccepted": staleAccepted,
            "stagedAt": ProviderGenerations.wireEncode(stagedAt),
            "finalizedAt": ProviderGenerations.wireEncode(finalizedAt),
            "receiptMAC": FirstPartyAuthProtocol.base64URLEncode(receiptMAC),
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// Decode a durable receipt. `nil` for anything malformed.
    public static func decode(_ data: Data) -> MigrationReceipt? {
        guard let object = FirstPartyAuthProtocol.strictJSONObject(
            data, expected: recordFields, maxBytes: 8 * 1024
        ) else { return nil }
        guard
            let transactionRaw = object["transactionIdentifier"] as? String,
            let transactionIdentifier = UUID(uuidString: transactionRaw),
            let stateRaw = object["state"] as? String,
            let state = State(rawValue: stateRaw),
            let classRaw = object["sourceClass"] as? String,
            let sourceClass = EstateCandidateClass(rawValue: classRaw),
            let sourceDigest = object["sourceDigest"] as? String,
            let destinationDigest = object["destinationDigest"] as? String,
            let estateRaw = object["estateIdentifier"] as? String,
            let estateIdentifier = UUID(uuidString: estateRaw),
            let schemaRaw = object["schemaVersion"] as? String,
            let schemaVersion = ProviderGenerations.wireDecode(schemaRaw),
            let keyRaw = object["keyTransition"] as? String,
            let keyTransition = KeyTransition(rawValue: keyRaw),
            let credentialRaw = object["credentialGeneration"] as? String,
            let credentialGeneration = ProviderGenerations.wireDecode(credentialRaw),
            let providerRaw = object["providerGeneration"] as? String,
            let providerGeneration = ProviderGenerations.wireDecode(providerRaw),
            let descriptorRaw = object["descriptorGeneration"] as? String,
            let descriptorGeneration = ProviderGenerations.wireDecode(descriptorRaw),
            let grantDigest = object["grantDigest"] as? String,
            let backupDigest = object["backupDigest"] as? String,
            let staleAccepted = object["staleAccepted"] as? Bool,
            let stagedRaw = object["stagedAt"] as? String,
            let stagedAt = ProviderGenerations.wireDecode(stagedRaw),
            let finalizedRaw = object["finalizedAt"] as? String,
            let finalizedAt = ProviderGenerations.wireDecode(finalizedRaw),
            let macRaw = object["receiptMAC"] as? String,
            let receiptMAC = FirstPartyAuthProtocol.base64URLDecode(macRaw)
        else { return nil }
        return MigrationReceipt(
            transactionIdentifier: transactionIdentifier, state: state,
            sourceClass: sourceClass,
            sourceDigestHex: sourceDigest, destinationDigestHex: destinationDigest,
            estateIdentifier: estateIdentifier, schemaVersion: schemaVersion,
            keyTransition: keyTransition,
            credentialGeneration: credentialGeneration,
            providerGeneration: providerGeneration,
            descriptorGeneration: descriptorGeneration,
            grantDigestHex: grantDigest, backupDigestHex: backupDigest,
            staleAccepted: staleAccepted, stagedAt: stagedAt, finalizedAt: finalizedAt,
            receiptMAC: receiptMAC
        )
    }
}

/// The durable receipt persistence seam. The migrator depends on this
/// protocol, not the concrete store, for two reasons: the receipt IS an
/// authority (its ordering is the crash-safety contract, KONG-3), and every
/// durable boundary must be independently fault-injectable — including the
/// FINALIZE write that lands after the atomic rename, which no filesystem
/// fake can reach.
public protocol MigrationReceiptPersisting: Sendable {
    /// Load the durable receipt, or `nil` when genuinely absent. Fail-closed
    /// on any other fault.
    func load() throws -> MigrationReceipt?
    /// Durably persist `receipt`, serialized under the held provider lock.
    func write(_ receipt: MigrationReceipt, lockProof: ProviderLockProof) throws
}

/// The durable receipt store: atomic, fsynced writes under the lock; reads
/// through the full hygiene matrix, fail-closed.
public struct MigrationReceiptStore: MigrationReceiptPersisting, Sendable {

    private let fileURL: URL

    /// - Parameter fileURL: `ProviderRootLayout.migrationReceiptFile`.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Load the durable receipt.
    ///
    /// - Returns: The receipt, or `nil` when GENUINELY absent.
    /// - Throws: `.migrationFault(.receiptUnreadable)` when present but
    ///   unreadable or undecodable — fail-closed: an unreadable receipt
    ///   refuses, it never resets a migration's history.
    public func load() throws -> MigrationReceipt? {
        let bytes: [UInt8]
        do {
            guard let fd = try SecureFiles.openValidatedIfExists(fileURL, flags: O_RDONLY) else {
                return nil
            }
            defer { close(fd) }
            bytes = try SecureFiles.readAll(fd: fd)
        } catch DaemonProviderError.hygieneViolation {
            throw DaemonProviderError.migrationFault(.receiptUnreadable)
        }
        guard let receipt = MigrationReceipt.decode(Data(bytes)) else {
            throw DaemonProviderError.migrationFault(.receiptUnreadable)
        }
        return receipt
    }

    /// Durably write `receipt` (atomic replace + fsync file and directory),
    /// serialized under the held provider lock.
    public func write(_ receipt: MigrationReceipt, lockProof: ProviderLockProof) throws {
        try lockProof.validate()
        let encoded = receipt.encoded()
        guard !encoded.isEmpty else {
            throw DaemonProviderError.migrationFault(.receiptUnreadable)
        }
        try SecureFiles.atomicReplace(encoded, at: fileURL)
    }
}

// MARK: - The migrator

/// The identity set of one migration transaction, assembled by the caller
/// from the census election, the consumed grant, and the layout.
public struct MigrationTransaction: Sendable, Equatable {
    /// The transaction's identity (from injected randomness).
    public let transactionIdentifier: UUID
    /// The elected source candidate's class.
    public let sourceClass: EstateCandidateClass
    /// The source main file (provider-derived; verified against census by
    /// the grant-resolution policy before this transaction is built).
    public let sourceURL: URL
    /// The canonical destination.
    public let canonicalURL: URL
    /// The transaction incoming directory.
    public let incomingDirectory: URL
    /// The transaction quarantine directory.
    public let quarantineDirectory: URL
    /// The immutable backup directory.
    public let backupDirectory: URL
    /// SHA-256 hex of the consumed grant envelope.
    public let grantDigestHex: String
    /// Generations at staging.
    public let generations: ProviderGenerations
    /// Whether the grant's bookmark resolution was accepted stale (P-c2-6d).
    public let staleAccepted: Bool
    /// How the estate key transitioned — DERIVED by the caller from the
    /// consumed grant's escrow marker and the `EscrowRules` decision
    /// (`KeyTransition.derive`), never assumed by the migrator.
    public let keyTransition: KeyTransition
    /// The one-use grant envelope's location
    /// (`ProviderRootLayout.migrationGrantFile`), or `nil` when this
    /// transaction consumed no envelope (no sandboxed grant was required).
    /// The machine removes it after committed success or terminal abort and
    /// VERIFIES its absence (P-c2-5).
    public let grantMaterialURL: URL?

    public init(
        transactionIdentifier: UUID, sourceClass: EstateCandidateClass,
        sourceURL: URL, canonicalURL: URL,
        incomingDirectory: URL, quarantineDirectory: URL, backupDirectory: URL,
        grantDigestHex: String, generations: ProviderGenerations, staleAccepted: Bool,
        keyTransition: KeyTransition, grantMaterialURL: URL? = nil
    ) {
        self.transactionIdentifier = transactionIdentifier
        self.sourceClass = sourceClass
        self.sourceURL = sourceURL
        self.canonicalURL = canonicalURL
        self.incomingDirectory = incomingDirectory
        self.quarantineDirectory = quarantineDirectory
        self.backupDirectory = backupDirectory
        self.grantDigestHex = grantDigestHex
        self.generations = generations
        self.staleAccepted = staleAccepted
        self.keyTransition = keyTransition
        self.grantMaterialURL = grantMaterialURL
    }
}

/// Outcome of a successful run.
public enum MigrationOutcome: String, Sendable, Equatable {
    /// This run performed (or completed) the migration.
    case committed
    /// A committed receipt already covered this transaction — no-op.
    case alreadyCommitted = "already-committed"
}

/// Terminal disposition of a failed run handled by `runExpectingFailure`.
public enum MigrationFailureDisposition: String, Sendable, Equatable {
    /// The canonical copy was quarantined (renamed aside).
    case quarantined
    /// The prior configuration was restored.
    case rolledBack = "rolled-back"
    /// Operator recovery required. Source and backup retained.
    case recoveryRequired = "recovery-required"
}

/// The closed-database migrator. An actor: one migration at a time per
/// provider, always under the HELD exclusive lock (hold-then-verify —
/// `ProviderLockProof.validate()` runs at entry and before every durable
/// write, KONG-3a).
public actor DefaultEstateMigrator {

    private let source: any SourceEstateAccess
    private let files: any FileMigrationAuthority
    private let receipts: any MigrationReceiptPersisting
    private let lockProof: ProviderLockProof
    private let installationRoot: [UInt8]
    private let transaction: MigrationTransaction
    private let clock: ProviderClock

    /// The machine's position, for observability (self-report / UI).
    public private(set) var step: MigrationStep = .census

    public init(
        source: any SourceEstateAccess,
        files: any FileMigrationAuthority,
        receipts: any MigrationReceiptPersisting,
        lockProof: ProviderLockProof,
        installationRoot: [UInt8],
        transaction: MigrationTransaction,
        clock: @escaping ProviderClock
    ) {
        self.source = source
        self.files = files
        self.receipts = receipts
        self.lockProof = lockProof
        self.installationRoot = installationRoot
        self.transaction = transaction
        self.clock = clock
    }

    /// The incoming copy's location for this transaction.
    private var incomingURL: URL {
        transaction.incomingDirectory
            .appendingPathComponent(transaction.transactionIdentifier.uuidString, isDirectory: true)
            .appendingPathComponent(transaction.canonicalURL.lastPathComponent, isDirectory: false)
    }

    /// Run the migration to completion, resuming idempotently from any
    /// durable crash point (KONG-3 convergence):
    ///
    ///   committed receipt      → `.alreadyCommitted`, zero side effects.
    ///   staged + canonical     → verify-and-finalize.
    ///   staged + no canonical  → safe retry from quiescence (source retained).
    ///   no receipt             → fresh run.
    ///
    /// - Throws: `DaemonProviderError` on any refusal; the source and backup
    ///   are retained on EVERY failure path.
    public func run() async throws -> MigrationOutcome {
        // Hold-then-verify: the worker HOLDS the lock; a stale proof refuses
        // before any side effect.
        try lockProof.validate()

        if let existing = try receipts.load() {
            // A receipt this transaction did not write, or one that fails
            // its MAC, is not ours to act on.
            guard existing.verifyMAC(installationRoot: installationRoot) else {
                throw DaemonProviderError.migrationFault(.receiptUnreadable)
            }
            guard existing.transactionIdentifier == transaction.transactionIdentifier else {
                throw DaemonProviderError.migrationFault(.receiptMismatch)
            }
            switch existing.state {
            case .committed:
                // Idempotent tail: a committed receipt whose grant material
                // still exists (crash between finalize and removal) gets the
                // removal completed here rather than left behind.
                try removeGrantMaterial()
                step = .receiptFinal
                return .alreadyCommitted
            case .staged:
                return try await resumeFromStaged(existing)
            case .quarantined, .rolledBack, .recoveryRequired:
                // Terminal failure states require operator action — a re-run
                // must not silently restart them.
                throw DaemonProviderError.migrationFault(.sequenceViolation)
            }
        }
        return try await freshRun()
    }

    /// Run, converting a migration FAULT into its terminal disposition:
    /// quarantine a canonical this run created (rename aside, never unlink),
    /// durably record the disposition, remove the burnt grant material, and
    /// return the disposition. The source is never touched on any path.
    ///
    /// This is the recovery entry point a supervisor calls when it wants the
    /// disposition rather than the fault. A run that SUCCEEDS here is a
    /// caller-sequencing error — the caller asked for failure handling on a
    /// machine that had nothing to fail — and refuses with
    /// `.sequenceViolation`; callers that may succeed use `run()`.
    ///
    /// NOTE (explicit deferral): `.rolledBack` has no producer in this
    /// mission. Restoring a prior provider/configuration requires the
    /// installer + resident authorities whose production conformers arrive
    /// with MACD-3; until then every non-quarantinable failure lands in
    /// `.recoveryRequired`, which retains the source and the backup and asks
    /// for an operator. A rollback across an unsupported schema/auth
    /// downgrade is the one outcome worse than a stalled migration, so
    /// synthesizing one here would be the wrong kind of completeness.
    public func runExpectingFailure() async throws -> MigrationFailureDisposition {
        do {
            _ = try await run()
            // Nothing failed: the caller's expectation, not the machine, is
            // out of sequence.
            throw DaemonProviderError.migrationFault(.sequenceViolation)
        } catch let error as DaemonProviderError {
            guard case .migrationFault = error else { throw error }
            // Quarantine only what THIS machine created: a canonical that
            // exists while our receipt is staged is our unverified copy.
            let canonicalExists = FileManager.default.fileExists(atPath: transaction.canonicalURL.path)
            let staged = try? receipts.load()
            if canonicalExists, staged?.state == .staged {
                try await files.quarantineCanonical(
                    canonical: transaction.canonicalURL,
                    quarantineDirectory: transaction.quarantineDirectory
                )
                if var receipt = staged {
                    receipt.state = .quarantined
                    try receipts.write(receipt.sealed(installationRoot: installationRoot), lockProof: lockProof)
                }
                // Terminal abort: the burnt grant's material goes too.
                try removeGrantMaterial()
                step = .quarantined
                return .quarantined
            }
            if var receipt = staged, receipt.state == .staged {
                receipt.state = .recoveryRequired
                try receipts.write(receipt.sealed(installationRoot: installationRoot), lockProof: lockProof)
            }
            // Terminal abort: the burnt grant's material goes too.
            try removeGrantMaterial()
            step = .recoveryRequired
            return .recoveryRequired
        }
    }

    // MARK: Fresh run

    private func freshRun() async throws -> MigrationOutcome {
        // 1. Quiesce the source in the mandated order. Exclusive open →
        //    checkpoint(TRUNCATE) → POSITIVE empty-WAL proof → identity →
        //    close. Only the closed main file is ever copied; -wal is proven
        //    empty and -shm never travels.
        step = .sourceQuiesced
        try await source.openExclusive()
        try await source.checkpointTruncate()
        try await source.verifyEmptyWAL()
        let identity = try await source.readIdentity()
        try await source.close()

        // 2. Immutable recoverable backup, BEFORE anything else moves.
        try await files.preserveBackup(
            source: transaction.sourceURL, backupDirectory: transaction.backupDirectory
        )
        let backupDigest = try await files.digestOf(
            url: transaction.backupDirectory.appendingPathComponent(transaction.sourceURL.lastPathComponent)
        )

        // 3. Copy the closed main into the transaction incoming directory
        //    (fsynced file + directory inside the authority).
        let sourceDigest = try await files.copyMainToIncoming(
            source: transaction.sourceURL, incoming: incomingURL
        )

        // 4. Verify the copy: byte digest, then read-only open + integrity +
        //    identity through the SQLite seam.
        step = .verified
        let copyDigest = try await files.digestOf(url: incomingURL)
        guard copyDigest == sourceDigest else {
            throw DaemonProviderError.migrationFault(.digestMismatch)
        }
        let destinationIdentity = try await source.verifyReadOnlyOpen(destination: incomingURL)
        guard destinationIdentity == identity else {
            throw DaemonProviderError.migrationFault(.identityMismatch)
        }

        // 5. KONG-3: the DURABLE staged receipt lands BEFORE the rename, so
        //    a canonical estate can never exist without lineage.
        step = .staged
        try lockProof.validate()
        let staged = MigrationReceipt(
            transactionIdentifier: transaction.transactionIdentifier,
            state: .staged,
            sourceClass: transaction.sourceClass,
            sourceDigestHex: sourceDigest,
            destinationDigestHex: copyDigest,
            estateIdentifier: identity.estateIdentifier,
            schemaVersion: identity.schemaVersion,
            keyTransition: transaction.keyTransition,
            credentialGeneration: transaction.generations.credential,
            providerGeneration: transaction.generations.provider,
            descriptorGeneration: transaction.generations.descriptor,
            grantDigestHex: transaction.grantDigestHex,
            backupDigestHex: backupDigest,
            staleAccepted: transaction.staleAccepted,
            stagedAt: clock(),
            finalizedAt: 0,
            receiptMAC: []
        ).sealed(installationRoot: installationRoot)
        try receipts.write(staged, lockProof: lockProof)

        // 6. The atomic rename into canonical (+ parent fsync).
        try await files.atomicRenameIntoCanonical(
            incoming: incomingURL, canonical: transaction.canonicalURL
        )

        // 7. Finalize: committed.
        step = .committed
        var committed = staged
        committed.state = .committed
        committed.finalizedAt = clock()
        try receipts.write(committed.sealed(installationRoot: installationRoot), lockProof: lockProof)
        // 8. The one-use grant material is removed ONLY after the receipt is
        //    committed, and its absence is verified (P-c2-5). Ordering
        //    matters: removing earlier would destroy the audit link before
        //    the lineage was durable.
        try removeGrantMaterial()
        step = .receiptFinal
        return .committed
    }

    /// Remove the consumed grant envelope and VERIFY its absence (P-c2-5:
    /// "removed after committed success or terminal abort, absence verified").
    ///
    /// A no-op when the transaction consumed no envelope. Genuine absence is
    /// success — the material may already have been removed by a previous
    /// attempt of an idempotent resume. Anything still present after the
    /// unlink is `.grantMaterialRetained`: opaque bookmark bytes outliving
    /// their one use is precisely the containment failure the rule forbids,
    /// so the machine reports it rather than claiming `receiptFinal`.
    private func removeGrantMaterial() throws {
        guard let url = transaction.grantMaterialURL else { return }
        if unlink(url.path) != 0, errno != ENOENT {
            throw DaemonProviderError.migrationFault(.grantMaterialRetained)
        }
        var status = stat()
        guard lstat(url.path, &status) != 0, errno == ENOENT else {
            throw DaemonProviderError.migrationFault(.grantMaterialRetained)
        }
    }

    // MARK: Resume

    private func resumeFromStaged(_ receipt: MigrationReceipt) async throws -> MigrationOutcome {
        if FileManager.default.fileExists(atPath: transaction.canonicalURL.path) {
            // staged + canonical: the crash landed between rename and
            // finalize. Verify the canonical IS the staged copy, then
            // finalize — never re-copy over it.
            step = .verified
            let canonicalDigest = try await files.digestOf(url: transaction.canonicalURL)
            guard canonicalDigest == receipt.destinationDigestHex else {
                throw DaemonProviderError.migrationFault(.digestMismatch)
            }
            let identity = try await source.verifyReadOnlyOpen(destination: transaction.canonicalURL)
            guard identity.estateIdentifier == receipt.estateIdentifier else {
                throw DaemonProviderError.migrationFault(.identityMismatch)
            }
            step = .committed
            var committed = receipt
            committed.state = .committed
            committed.finalizedAt = clock()
            try receipts.write(committed.sealed(installationRoot: installationRoot), lockProof: lockProof)
            try removeGrantMaterial()
            step = .receiptFinal
            return .committed
        }
        // staged + no canonical: the crash landed before the rename. The
        // source is retained and closed; re-run the whole pipeline (safe
        // retry — every step is idempotent against the retained source).
        return try await freshRun()
    }
}
