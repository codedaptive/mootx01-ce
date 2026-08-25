import Foundation

// MARK: - Injected authority seams (MACD-2c1 base, MACD-2c2 convergence)
//
// The provider substrate NEVER constructs a production estate, installer,
// process supervisor, or Keychain path on its own. Every side-effectful
// capability arrives through one of the protocols in this file (and the
// census/grant/migration seams in DefaultEstateCensus.swift,
// LegacyMigrationGrant.swift, and DefaultEstateMigrator.swift), injected at
// construction. The SQLite-semantic seams have NO production conformer in
// this module by design: the estate stack sits above this package's frozen
// dependency graph, so the production conformers arrive with MACD-3 estate
// routing, and until then every conformer is an adversarial counting fake in
// the test target or a journaling fake in the proof shell. This is the
// production-darkness boundary expressed as a type-system fact rather than a
// convention.
//
// Determinism (Perkins P13/P-c2-12): clocks and randomness are injected
// everywhere a security decision is taken. No engine below ever calls Date()
// or SecRandomCopyBytes directly; the composition roots in ProviderShell are
// the only license (ProductionRandomness there is the one production CSPRNG).

/// Why a provider operation was refused.
///
/// One case per distinct gate, with classification payloads that are safe to
/// log: no case ever carries key material, lease bytes, or a filesystem path
/// (Perkins P10/F4 — refusals are classifications, never existence oracles
/// for foreign paths).
public enum DaemonProviderError: Error, Equatable, Sendable {

    /// The shell failed signed-eligibility judgment. Raised BEFORE the lock is
    /// touched; an ineligible shell performs zero side effects (Perkins P1).
    case ineligible(IneligibilityReason)

    /// The App Group container could not be resolved through the injected
    /// resolver. There is no fallback root — argv, environment, cwd, and
    /// descriptor-derived roots are forbidden (Perkins P2).
    case rootUnresolvable

    /// A filesystem hygiene invariant failed on the provider root, lock, or
    /// state file (Perkins P3). The payload names the violated invariant only.
    case hygieneViolation(HygieneViolation)

    /// The exclusive provider lock is held elsewhere. The caller is the race
    /// LOSER and must exit without invoking any Keychain, estate, bind, or
    /// publish callback (Perkins P4).
    case lockUnavailable

    /// A fatal Keychain condition (Perkins P5). Never raised for genuine
    /// absence — absence is the one condition that licenses a mint, and only
    /// for the eligible lock owner.
    case keychainFatal(KeychainFault)

    /// A durable-generation invariant failed (Perkins P6).
    case generationFault(GenerationFault)

    /// A descriptor publication precondition was not proven (Perkins P8).
    case publishPreconditionFailed(PublishPrecondition)

    /// A handover lease failed validation or single-use consumption
    /// (Perkins P9).
    case leaseInvalid(LeaseFault)

    /// A handover callback was requested out of order. The offending authority
    /// call was NOT made; sequencing violations refuse before side effects.
    /// A handover that fails TERMINALLY is not an error case here — it is the
    /// `HandoverFailureDisposition` the coordinator's `fail` step returns.
    case handoverSequenceViolation(expected: HandoverStep, requested: HandoverStep)

    /// A migration grant failed validation or one-use consumption
    /// (MACD-2c2, Perkins P-c2-3/4/5).
    case grantInvalid(GrantFault)

    /// A default-estate migration invariant failed (MACD-2c2, KONG-3).
    case migrationFault(MigrationFault)
}

/// A migration-grant fault (Perkins P-c2-3/4/5). The grant reuses the lease's
/// fail-closed one-use discipline; the classifications mirror `LeaseFault`
/// deliberately so operators read one vocabulary.
public enum GrantFault: String, Sendable, Equatable {
    /// The envelope MAC did not verify under the challenge-derived key.
    case badMAC = "bad-mac"
    /// The grant is past its expiry (injected clock).
    case expired
    /// The grant identifier is already in the consumption journal.
    case consumed
    /// A binding field (provider instance, candidate class, challenge)
    /// disagrees with the outstanding challenge or this provider.
    case bindingMismatch = "binding-mismatch"
    /// The grant's credential generation is not exactly current.
    case staleGeneration = "stale-generation"
    /// The durable record cannot be decoded (wrong key set, oversize, or
    /// non-canonical spellings).
    case malformed
    /// The consumption journal cannot answer or record. Fail-closed: an
    /// unanswerable one-use question refuses, it never passes (c0 pattern).
    case journalUnavailable = "journal-unavailable"
}

/// A default-estate migration fault (KONG-3). Classifications only — no case
/// carries a path, key, or bookmark byte (Perkins P-c2-11).
public enum MigrationFault: String, Sendable, Equatable {
    /// An injected authority failed (or crash injection fired, in tests).
    case injectedFailure = "injected-failure"
    /// The durable receipt exists but cannot be read or fails its MAC.
    /// Fail-closed: an unreadable receipt refuses, it never resets.
    case receiptUnreadable = "receipt-unreadable"
    /// The staged receipt disagrees with this transaction's identity set.
    case receiptMismatch = "receipt-mismatch"
    /// A digest comparison failed (copy verification or resume re-verify).
    case digestMismatch = "digest-mismatch"
    /// The source or destination estate identity disagreed with the census.
    case identityMismatch = "identity-mismatch"
    /// The WAL was not provably empty after checkpoint(TRUNCATE).
    case walNotEmpty = "wal-not-empty"
    /// A migration step was requested out of order.
    case sequenceViolation = "sequence-violation"
    /// The escrow rules refused (never mint over ciphertext, P-c2-7).
    case escrowRefused = "escrow-refused"
    /// The one-use grant material could not be removed (or was still present
    /// after removal) once the receipt committed. Opaque bookmark bytes
    /// outliving their single use is a containment failure (P-c2-5), so the
    /// machine reports it instead of claiming a clean terminal state.
    case grantMaterialRetained = "grant-material-retained"
}

/// Marker for the PRODUCTION Keychain authority (Perkins P-c2-1). The mint
/// license in `InstallationRootAuthority.ensureRoot` — and the activation
/// guard in `DaemonProvider` — refuse to pair a conformer of this marker with
/// anything but a production-layout lock proof and a nil proof context, so a
/// proof-directory lock plus the real data-protection Keychain fails closed
/// BEFORE `SecItemAdd` is reachable. Test fakes must NOT conform unless the
/// test is deliberately proving this refusal.
public protocol ProductionCredentialAuthority {}

/// The four ineligible signing classes (Perkins P1). A shell in any of these
/// classes exits before the lock with zero side effects.
public enum IneligibilityReason: String, CaseIterable, Sendable {
    /// No code signature at all.
    case unsigned
    /// Ad-hoc signed: a signature with no team identity behind it.
    case adHocSigned = "ad-hoc"
    /// Signed by a team that does not own the shared Keychain group.
    case wrongTeam = "wrong-team"
    /// Signed, but the required App Group or team Keychain group entitlement
    /// is absent.
    case wrongGroup = "wrong-group"
}

/// A violated filesystem hygiene invariant (Perkins P3).
public enum HygieneViolation: String, Sendable, Equatable {
    /// A path component resolved to a symbolic link (`O_NOFOLLOW` refused it).
    case symlink
    /// The opened file has more than one hard link.
    case hardLink = "hard-link"
    /// The opened descriptor is not a regular file.
    case notRegularFile = "not-regular-file"
    /// A parent directory is not owned by the effective uid.
    case foreignOwner = "foreign-owner"
    /// A parent directory is group- or other-writable.
    case permissiveMode = "permissive-mode"
    /// The file could not be opened or created at all.
    case unopenable
}

/// A fatal Keychain condition (Perkins P5).
public enum KeychainFault: String, Sendable, Equatable {
    /// `errSecMissingEntitlement` — the process may not see the item. NEVER
    /// treated as absence: an unentitled reader told "no such item" that then
    /// mints is how a second competing root is born.
    case missingEntitlement = "missing-entitlement"
    /// The item exists but is not exactly 32 bytes.
    case corrupted
    /// The Keychain is locked or requires interaction.
    case interactionRequired = "interaction-required"
    /// Any other Keychain error.
    case unavailable
    /// A freshly minted or re-read item disagrees with what was written.
    case disagreement
    /// A PRODUCTION credential authority was paired with a proof-layout (or
    /// unspecified) lock proof, or a non-nil proof context (Perkins P-c2-1).
    /// Refused before any Keychain call is made.
    case proofContextRefused = "proof-context-refused"
}

/// A violated durable-generation invariant (Perkins P6).
public enum GenerationFault: String, Sendable, Equatable {
    /// A stored counter would move backwards.
    case rollback
    /// A counter is at `UInt64.max` and cannot advance.
    case overflow
    /// The durable record is present but fails its integrity check.
    case torn
    /// The caller's expected generations disagree with the stored record.
    case mismatch
    /// The record exists but cannot be read. Fail-closed: an unreadable
    /// monotonic record refuses, it never resets.
    case unreadable
}

/// A descriptor publication precondition that was not proven (Perkins P8).
public enum PublishPrecondition: String, Sendable, Equatable {
    /// The exact loopback bind readback did not match the contracted endpoint.
    case bindMismatch = "bind-mismatch"
    /// The injected estate-ready proof was absent or disagreed with the
    /// descriptor's estate identity.
    case estateNotReady = "estate-not-ready"
    /// The authenticator readiness proof was incomplete or its capabilities
    /// disagree with the descriptor.
    case authenticatorIncomplete = "authenticator-incomplete"
    /// The descriptor itself is malformed (schema, endpoint, identity, or MAC
    /// width) and has no canonical publication.
    case descriptorMalformed = "descriptor-malformed"
}

/// A handover-lease fault (Perkins P9).
public enum LeaseFault: String, Sendable, Equatable {
    /// The lease MAC did not verify.
    case badMAC = "bad-mac"
    /// The lease is past its expiry.
    case expired
    /// The lease identifier is already in the consumption journal.
    case consumed
    /// A binding field (identity, instance, estate, schema) disagrees with the
    /// consumer.
    case bindingMismatch = "binding-mismatch"
    /// The lease's generations are stale against the durable store.
    case staleGeneration = "stale-generation"
    /// The record cannot be decoded.
    case malformed
    /// The consumption journal cannot answer or record. Fail-closed: an
    /// unanswerable one-use question refuses, it never passes (c0 pattern).
    case journalUnavailable = "journal-unavailable"
}

/// The ordered steps of the two-phase handover (Kong decision 3; mission's
/// eight-step contract). `rawValue` order IS the legal order.
public enum HandoverStep: Int, Sendable, Equatable, CaseIterable {
    /// Nothing has happened yet.
    case idle = 0
    /// 1 — target installed disabled.
    case targetPrepared = 1
    /// 2 — source authenticated.
    case sourceAuthenticated = 2
    /// 3 — source stopped writes, drained, checkpointed, closed the estate,
    /// and generations were incremented.
    case estateClosed = 3
    /// 4 — the MACed single-use lease was issued.
    case leaseIssued = 4
    /// 5 — source process exit and lock release verified.
    case sourceExited = 5
    /// 6 — target consumed the lease, locked, opened, bound, and published.
    case targetReady = 6
    /// 7 — the injected installer removed the source.
    case sourceRemoved = 7
    /// 8a — failure path: compatible rollback performed.
    case rolledBack = 8
    /// 8b — failure path: no compatible rollback; operator recovery required.
    case recoveryRequired = 9
}

// MARK: - Injected clocks and randomness

/// Seconds since the Unix epoch, injected (Perkins P13).
public typealias ProviderClock = @Sendable () -> UInt64

/// Cryptographic randomness, injected (Perkins P13).
public typealias ProviderRandomness = @Sendable (_ byteCount: Int) -> [UInt8]

// MARK: - Proof records
//
// The provider trusts nothing it did not verify. Each of these records is a
// PROOF handed across a seam: it can only be produced by the authority that
// performed the underlying act, and the publisher re-judges its content
// rather than its existence.

/// Proof that an injected estate authority opened (or reports ready) the
/// estate the descriptor will describe. Carries identifiers only — never a
/// path or key.
public struct EstateReadyProof: Sendable, Equatable {
    /// The estate's identity.
    public let estateIdentifier: UUID
    /// The estate's schema version, bound into handover leases.
    public let schemaVersion: UInt64

    public init(estateIdentifier: UUID, schemaVersion: UInt64) {
        self.estateIdentifier = estateIdentifier
        self.schemaVersion = schemaVersion
    }
}

/// Bind readback proof: what `getsockname(2)` reported AFTER the listener was
/// bound. Publication compares this against the exact contracted endpoint;
/// intent to bind is not a bind (Perkins P8).
public struct BindProof: Sendable, Equatable {
    /// The literal bound host, e.g. `"127.0.0.1"`.
    public let host: String
    /// The bound port.
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

/// Proof that a complete first-party authenticator is in force: root
/// validated, session store bounded, MAC middleware wired. Carries the
/// capability wire spellings the authenticated lane will actually advertise.
public struct AuthenticatorReadiness: Sendable, Equatable {
    /// Advertised capability wire spellings, sorted.
    public let capabilities: [String]

    public init(capabilities: [String]) {
        self.capabilities = capabilities.sorted()
    }
}

// MARK: - Injected authorities (no production estate conformer in this module)

/// Estate lifecycle operations, injected. This module has NO production
/// implementation of this protocol — the estate stack sits above this
/// package's frozen dependency graph, so the production conformer arrives
/// with MACD-3 estate routing. Tests inject adversarial counting fakes.
public protocol EstateLifecycleAuthority: Sendable {
    /// Refuse new writes. Handover step 3 begins here.
    func stopWrites() async throws
    /// Drain in-flight work after writes stop.
    func drain() async throws
    /// Checkpoint the WAL after draining.
    func checkpoint() async throws
    /// Close the estate after checkpointing.
    func closeEstate() async throws
    /// Open the SAME estate on the target side (handover step 6) or at
    /// provider activation, returning proof of identity and schema.
    func openEstate() async throws -> EstateReadyProof
}

/// Installer operations, injected. The installer-parity artifacts (daemon
/// bundle, disabled LaunchAgent) live in MootInstallerCore; a production
/// conformer of THIS handover seam is composed only when live handover is
/// authorized (MACD-3). Tests inject counting fakes.
public protocol InstallerAuthority: Sendable {
    /// Handover step 1: install the target, disabled.
    func prepareTargetDisabled() async throws
    /// Handover step 7: remove the source — legal ONLY after target readiness.
    func removeSource() async throws
    /// Handover step 8a: restore the still-installed source configuration.
    func rollbackToSource() async throws
}

/// Process/launch supervision, injected. Verifies (never assumes) that the
/// source provider exited and its lock was released (handover step 5).
public protocol ProcessExitAuthority: Sendable {
    /// Throws unless the source PID is gone.
    func verifySourceExited() async throws
    /// Throws unless the provider lock is observably released.
    func verifyLockReleased() async throws
}

/// Authenticates the SOURCE provider before quiescence (handover step 2),
/// returning its signing identity for lease binding.
public protocol SourceAuthenticationAuthority: Sendable {
    /// Authenticate the source and return its signing identity descriptor.
    func authenticateSource() async throws -> SigningIdentityDescriptor
}

/// Revokes every live first-party session. The production conformer is
/// AriaMCP's `FirstPartyAuthServer` (`revokeAllSessions()`), consumed through
/// its existing public API; tests inject counting fakes.
public protocol SessionRevocationAuthority: Sendable {
    /// Drop every session and outstanding challenge.
    func revokeAllSessions() async
}

/// Binds the loopback listener and reads the bound address back. Tests
/// inject fakes; the real conformer belongs to the resident service, which
/// activates with MACD-3 (the daemon bundle installs disabled until then).
public protocol BindAuthority: Sendable {
    /// Bind and return the `getsockname(2)` readback.
    func bindLoopback() async throws -> BindProof
}

/// Reads and writes exactly one Keychain item shape — the installation root.
/// Injected so tests can drive every fault class without entitlements, and so
/// proof modes can substitute a journaling fake instead of ever touching the
/// production data-protection Keychain.
public protocol KeychainItemAuthority: Sendable {
    /// Read the item.
    func copyItem(service: String, account: String, accessGroup: String) -> KeychainReadResult
    /// Add the item. Only `InstallationRootAuthority` may call this, and only
    /// while holding the provider lock.
    func addItem(service: String, account: String, accessGroup: String, data: [UInt8]) -> KeychainWriteStatus
}

/// Outcome of a Keychain read, classified (Perkins P5).
public enum KeychainReadResult: Sendable, Equatable {
    /// The item's bytes.
    case found([UInt8])
    /// Genuine `errSecItemNotFound` — the ONLY result that can license a mint.
    case notFound
    /// `errSecMissingEntitlement` — fatal, never absence.
    case missingEntitlement
    /// The Keychain is locked / requires interaction — fatal.
    case interactionRequired
    /// Any other error — fatal.
    case unavailable
}

/// Outcome of a Keychain add, classified.
public enum KeychainWriteStatus: Sendable, Equatable {
    /// The item was created.
    case added
    /// `errSecDuplicateItem` — someone created it first; re-read and compare.
    case duplicate
    /// `errSecMissingEntitlement` — fatal.
    case missingEntitlement
    /// Any other error — fatal.
    case unavailable
}
