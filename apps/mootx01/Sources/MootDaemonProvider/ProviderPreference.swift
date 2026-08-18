import Foundation
import AriaMCP

// MARK: - MACD-3B2 — durable provider preference record (dark Wave 1)
//
// The preference record answers one question: which provider kind does the
// user prefer for the next activation? It is written by the app (after
// attended viability check) or by the CLI installer (at bundle-preferred
// first install), and read by the arbiter at authority level 4 — BELOW every
// live lock claim, lease, and recovery state.
//
// Key design decisions (binding, per KONG advisory P2, P3, P4, P5):
//
//   MAC domain:  "MOOTX01-PROVIDER-PREFERENCE-v1" — distinct from the
//     handover-lease domain ("MOOTX01-HANDOVER-LEASE-v1") and the migration-
//     grant domain ("MOOTX01-MIGRATION-GRANT-v1").  Both are zero-salt HKDF
//     derivations from K_install; the domain string IS the separator.
//
//   Zero-salt HKDF rationale (Kong advisory P2):  the preference key must be
//     derivable independently by both the app and the daemon from K_install
//     alone — there is no per-write challenge to bind (contrast
//     MigrationGrantEnvelope.grantKey, which uses the challenge digest as salt
//     to bind to one outstanding challenge).  Zero salt is correct here.
//
//   File location (Kong advisory P3):  `preferenceFile` lives in
//     `supportDirectory` BESIDE the descriptor — the same custody namespace
//     as `migrationGrantFile` and `migrationChallengeFile`.  It is NOT inside
//     `providerDirectory` (mode 0700, daemon-written).  The app is a
//     legitimate writer here; the daemon is a read-only consumer that validates
//     MAC + monotonic generation.
//
//   Fail-closed reads (P3):  any unreadable, malformed, MAC-invalid, or
//     wrong-domain record is treated as NO preference — never a permissive
//     default and never a crash.
//
//   Monotonic generation enforcement (P3):  a write of equal-or-lower
//     generation is refused.  A lower generation detected on disk is a
//     rollback and is refused on read.  Both checks are applied without
//     holding the provider lock — the preference sits below the lock in the
//     authority hierarchy.
//
//   Two legitimate writers (P5):  the app records bundled-preferred after
//     attended viability; the CLI installer writes at bundle-preferred first
//     install.  The CLI does NOT rewrite simply because it ran later.

// MARK: - MAC domain

/// The HKDF domain for the preference MAC key.
///
/// Distinct from `"MOOTX01-HANDOVER-LEASE-v1"` and
/// `"MOOTX01-MIGRATION-GRANT-v1"`.  A MAC computed under this domain cannot be
/// presented as a lease or grant MAC and vice versa — domain separation is the
/// cryptographic boundary.  Committed to the self-report digest so a domain
/// rename is a breaking change caught by the identity assertion.
public let providerPreferenceDomain = "MOOTX01-PROVIDER-PREFERENCE-v1"

// MARK: - ProviderPreference record

/// The durable preference record (P1).
///
/// Exactly five fields.  Deterministic: `now` is injected, never `Date()` inside.
public struct ProviderPreference: Sendable, Equatable {

    // P1: EXACTLY these five fields — no estate key, no installation root,
    // no bearer credential, no capability inventory, no migration bookmark.

    /// Which provider kind the issuer prefers for the next activation.
    public let preferredKind: ProviderKind

    /// Monotonic counter that increases with every preference write.  A
    /// reader that has seen generation N refuses any record with generation ≤ N
    /// as a rollback — the only valid successor is N+1 or higher.
    public let preferenceGeneration: UInt64

    /// The signing identity of the process that wrote this record (team +
    /// bundle + signing class).  Written at issue time so the daemon can verify
    /// that the writer is a known legitimate writer.
    public let issuingIdentity: SigningIdentityDescriptor

    /// Issue time as seconds since the Unix epoch, injected — never `Date()`
    /// inside this type (determinism mandate).
    public let issuedAt: UInt64

    /// The provider generation at the time of the last successfully completed
    /// handover, or zero if no handover has occurred.  Lets the arbiter detect
    /// a preference written before a subsequent handover completed.
    public let lastCompletedHandoverGeneration: UInt64

    /// HMAC-SHA256 over `macInput()` under the preference key.
    public var preferenceMAC: [UInt8]

    public init(
        preferredKind: ProviderKind,
        preferenceGeneration: UInt64,
        issuingIdentity: SigningIdentityDescriptor,
        issuedAt: UInt64,
        lastCompletedHandoverGeneration: UInt64,
        preferenceMAC: [UInt8]
    ) {
        self.preferredKind = preferredKind
        self.preferenceGeneration = preferenceGeneration
        self.issuingIdentity = issuingIdentity
        self.issuedAt = issuedAt
        self.lastCompletedHandoverGeneration = lastCompletedHandoverGeneration
        self.preferenceMAC = preferenceMAC
    }

    // MARK: Key derivation

    /// Derive the preference MAC key from K_install.
    ///
    /// `K_preference = HKDF-SHA256(K_install, salt = 32 zero octets, info = domain)`
    ///
    /// Zero salt is intentional (Kong advisory P2): both writers derive the key
    /// independently from K_install without per-write binding — there is no
    /// challenge to bind, unlike MigrationGrantEnvelope which uses the
    /// challenge digest as salt.  Domain separation via the info string is
    /// the cryptographic boundary between this key and the lease/grant keys.
    public static func preferenceKey(installationRoot: [UInt8]) -> [UInt8] {
        FirstPartyAuthProtocol.hkdfSHA256(
            inputKeyingMaterial: installationRoot,
            salt: [UInt8](repeating: 0, count: 32),
            info: Array(providerPreferenceDomain.utf8),
            outputByteCount: FirstPartyAuthProtocol.macByteCount
        )
    }

    // MARK: MAC input

    /// The transcript fields, in fixed frozen MAC-input order.
    ///
    /// Order is committed to the self-report digest via the `macTranscriptFields`
    /// constant.  Any reordering is a cryptographic breaking change.
    public static let macTranscriptFields: [String] = [
        "preferredKind",
        "preferenceGeneration",
        "issuedAt",
        "lastCompletedHandoverGeneration",
        "issuingTeamIdentifier",
        "issuingBundleIdentifier",
        "issuingSigningClass",
    ]

    /// Length-prefixed canonical MAC input, covering all five P1 fields.
    ///
    /// All integer fields are encoded as UInt64 little-endian (CanonicalEncoder).
    /// String fields are UTF-8 bytes, length-prefixed.  The MAC covers every
    /// semantic field — no field is implicitly trusted outside the MAC boundary.
    public func macInput() -> [UInt8] {
        var encoder = CanonicalEncoder()
        encoder.appendString(providerPreferenceDomain)  // domain first — MAC boundary label
        encoder.appendString(preferredKind.rawValue)
        encoder.appendUInt64(preferenceGeneration)
        encoder.appendUInt64(issuedAt)
        encoder.appendUInt64(lastCompletedHandoverGeneration)
        encoder.appendString(issuingIdentity.teamIdentifier)
        encoder.appendString(issuingIdentity.bundleIdentifier)
        encoder.appendString(issuingIdentity.signingClass.rawValue)
        return encoder.bytes
    }

    // MARK: MAC operations

    /// Return a copy with `preferenceMAC` computed under `installationRoot`.
    public func signing(installationRoot: [UInt8]) -> ProviderPreference {
        var copy = self
        copy.preferenceMAC = FirstPartyAuthProtocol.hmacSHA256(
            key: Self.preferenceKey(installationRoot: installationRoot),
            message: macInput()
        )
        return copy
    }

    /// Constant-time MAC verification under `installationRoot`.
    ///
    /// Returns `false` for any wrong-length, wrong-domain, or tampered MAC —
    /// never panics, never leaks timing information.
    public func verifyMAC(installationRoot: [UInt8]) -> Bool {
        guard preferenceMAC.count == FirstPartyAuthProtocol.macByteCount else { return false }
        let expected = FirstPartyAuthProtocol.hmacSHA256(
            key: Self.preferenceKey(installationRoot: installationRoot),
            message: macInput()
        )
        return FirstPartyAuthProtocol.constantTimeEquals(expected, preferenceMAC)
    }

    // MARK: Serialisation

    /// The exact key set for on-disk JSON.  `strictJSONObject` enforces this —
    /// any extra key or missing key returns nil (fail-closed).
    private static let recordFields: Set<String> = [
        "preferredKind",
        "preferenceGeneration",
        "issuedAt",
        "lastCompletedHandoverGeneration",
        "issuingTeamIdentifier",
        "issuingBundleIdentifier",
        "issuingSigningClass",
        "preferenceMAC",
    ]

    /// Canonical sorted-key JSON for the durable record.
    ///
    /// Integer fields are decimal strings (UInt64 JSON number cannot be exact).
    /// `preferenceMAC` is base64url.  Sorted keys are required so the MAC
    /// covers a canonical representation.
    public func encoded() -> Data {
        let object: [String: Any] = [
            "preferredKind": preferredKind.rawValue,
            "preferenceGeneration": ProviderGenerations.wireEncode(preferenceGeneration),
            "issuedAt": ProviderGenerations.wireEncode(issuedAt),
            "lastCompletedHandoverGeneration": ProviderGenerations.wireEncode(
                lastCompletedHandoverGeneration),
            "issuingTeamIdentifier": issuingIdentity.teamIdentifier,
            "issuingBundleIdentifier": issuingIdentity.bundleIdentifier,
            "issuingSigningClass": issuingIdentity.signingClass.rawValue,
            "preferenceMAC": FirstPartyAuthProtocol.base64URLEncode(preferenceMAC),
        ]
        return (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data()
    }

    /// Decode a durable preference record.
    ///
    /// Returns `nil` for any malformed input — wrong key set, wrong types,
    /// non-UUID `preferredKind`, or non-decimal generation strings.  This is
    /// the outer decode; MAC verification is a separate step performed by the
    /// store (fail-closed: unverified bytes are decoded to check the domain
    /// before they are accepted as a preference).
    public static func decode(_ data: Data) -> ProviderPreference? {
        guard let object = FirstPartyAuthProtocol.strictJSONObject(
            data, expected: recordFields, maxBytes: 4 * 1024
        ) else { return nil }
        guard
            let kindRaw = object["preferredKind"] as? String,
            let preferredKind = ProviderKind(rawValue: kindRaw),
            let genRaw = object["preferenceGeneration"] as? String,
            let preferenceGeneration = ProviderGenerations.wireDecode(genRaw),
            let issuedRaw = object["issuedAt"] as? String,
            let issuedAt = ProviderGenerations.wireDecode(issuedRaw),
            let lastRaw = object["lastCompletedHandoverGeneration"] as? String,
            let lastCompleted = ProviderGenerations.wireDecode(lastRaw),
            let team = object["issuingTeamIdentifier"] as? String,
            let bundle = object["issuingBundleIdentifier"] as? String,
            let classRaw = object["issuingSigningClass"] as? String,
            let signingClass = SignedProcessIdentity.SigningClass(rawValue: classRaw),
            let macRaw = object["preferenceMAC"] as? String,
            let mac = FirstPartyAuthProtocol.base64URLDecode(macRaw)
        else { return nil }
        let identity = SigningIdentityDescriptor(
            teamIdentifier: team,
            bundleIdentifier: bundle,
            signingClass: signingClass
        )
        return ProviderPreference(
            preferredKind: preferredKind,
            preferenceGeneration: preferenceGeneration,
            issuingIdentity: identity,
            issuedAt: issuedAt,
            lastCompletedHandoverGeneration: lastCompleted,
            preferenceMAC: mac
        )
    }
}

// MARK: - ProviderPreferenceObservation

/// The arbiter-facing summary of the preference record (P4).
///
/// Carries only the fields the arbiter needs — never raw MAC bytes.  The
/// disposition field records whether the on-disk record passed MAC verification
/// so the arbiter can apply the preference ONLY when the MAC is confirmed valid.
public enum ProviderPreferenceObservation: Sendable, Equatable {

    /// No preference file on disk, or disk read failed — treated identically.
    case none

    /// A preference record was read and MAC-verified successfully.
    case verified(
        preferredKind: ProviderKind,
        preferenceGeneration: UInt64
    )

    /// A preference record was present but failed MAC verification, was
    /// malformed, or had a monotonic-generation rollback.  The arbiter
    /// treats this exactly like `.none` (fail-closed), but the distinction
    /// lets callers surface a diagnostic without trusting the bytes.
    case invalid
}

// MARK: - ProviderPreferenceStore

/// Durable preference store (P3).
///
/// Writes atomically via `SecureFiles.atomicReplace`.  Reads fail-closed on
/// any error (unreadable, malformed, MAC-invalid, rollback) — the store never
/// returns a permissive default.  The write path does NOT require the provider
/// lock; conflict detection is via monotonic generation + MAC + atomic rename.
///
/// The store is intentionally stateless between reads/writes — it has no
/// in-memory cache of the last-seen generation.  The arbiter's monotonic
/// check is the guard against rollback on read.  The write-side monotonic
/// check is enforced by reading the current record before every write and
/// refusing if the on-disk generation is ≥ the proposed generation.
public struct ProviderPreferenceStore: Sendable {

    /// The URL of the preference file.  Must be `ProviderRootLayout.preferenceFile`
    /// (in `supportDirectory`, beside the descriptor, NOT inside `providerDirectory`).
    public let fileURL: URL

    /// The K_install bytes used for MAC derivation.  Never stored to disk.
    public let installationRoot: [UInt8]

    public init(fileURL: URL, installationRoot: [UInt8]) {
        self.fileURL = fileURL
        self.installationRoot = installationRoot
    }

    // MARK: Read

    /// Load and MAC-verify the on-disk preference.
    ///
    /// Returns `.none` for genuine absence, read failure, malformed JSON, or
    /// MAC failure — every non-success path is `.none`, never a permissive
    /// default.  Returns `.invalid` for records that decode but fail MAC
    /// verification, so callers can distinguish "no record" from "tampered
    /// record" for diagnostics — neither is trusted.
    ///
    /// Rollback detection:  if `minimumExpectedGeneration` is provided and the
    /// on-disk record's generation is strictly less than it, the record is
    /// refused as a rollback and `.invalid` is returned.
    public func load(
        minimumExpectedGeneration: UInt64 = 0
    ) -> ProviderPreferenceObservation {
        // Open and read the file.  ENOENT is genuine absence (.none); any
        // other failure is also .none (fail-closed — an unreadable record is
        // not a permissive grant).
        //
        // openValidatedIfExists returns Int32? (nil for genuine ENOENT) and
        // throws for all other failures.  try? flattens throws→Optional, so
        // the result is Int32?? — the outer layer covers the throw path, the
        // inner covers ENOENT.  Flatten via flatMap before guard-letting so
        // both absence paths (ENOENT → .none(inner), throw → .none(outer))
        // resolve to .none correctly.
        let fdOpt: Int32? = (try? SecureFiles.openValidatedIfExists(fileURL, flags: O_RDONLY)).flatMap { $0 }
        guard let descriptor = fdOpt else {
            return .none
        }
        defer { close(descriptor) }

        guard let bytes = try? SecureFiles.readAll(fd: descriptor) else {
            return .none
        }
        let data = Data(bytes)

        // Decode structure — wrong key set or wrong types → nil → .none.
        guard let record = ProviderPreference.decode(data) else {
            return .none
        }

        // Rollback detection: refuse a generation that retreated from what
        // we last confirmed.  A lower generation on disk than expected is a
        // rollback (crash after rename, or active tampering); treated as
        // .invalid so the caller can surface a diagnostic.
        guard record.preferenceGeneration >= minimumExpectedGeneration else {
            return .invalid
        }

        // MAC verification — constant-time, fail-closed.  A wrong-domain or
        // wrong-key MAC is indistinguishable from a tampered record here
        // (by design: we do not reveal which check failed).
        guard record.verifyMAC(installationRoot: installationRoot) else {
            return .invalid
        }

        return .verified(
            preferredKind: record.preferredKind,
            preferenceGeneration: record.preferenceGeneration
        )
    }

    // MARK: Write

    /// Write a preference record atomically.
    ///
    /// Before writing, reads the current on-disk record to enforce the
    /// monotonic generation constraint: a write whose `preferenceGeneration`
    /// is ≤ the on-disk generation is refused with
    /// `DaemonProviderError.generationFault(.overflow)` (reusing the existing
    /// generation-fault vocabulary — "overflow" covers the "cannot advance"
    /// case; a dedicated case would require a wire-encoding change).
    ///
    /// The write does NOT require the provider lock.  The atomic rename +
    /// monotonic check is the conflict-detection mechanism (P5).
    ///
    /// - Parameters:
    ///   - preference: The record to write.  Must carry a valid MAC (computed
    ///     by `ProviderPreference.signing(installationRoot:)` before calling
    ///     this method).
    /// - Throws: `DaemonProviderError.generationFault` when the proposed
    ///   generation is not a strict advance over the on-disk generation.
    ///   `DaemonProviderError.hygieneViolation` on any I/O failure.
    public func write(_ preference: ProviderPreference) throws {
        // Read the existing record to enforce the monotonic constraint.
        // If there is no existing record, generation 0 is the floor —
        // any positive generation is a valid first write.  We do not use
        // load() here because we need the raw generation before MAC
        // verification (a tampered record must still block generation
        // rollback even if its MAC is wrong).
        let onDiskGeneration = onDiskGenerationRaw()

        guard preference.preferenceGeneration > onDiskGeneration else {
            // Equal-or-lower generation: refuse.  This covers both a
            // duplicate write (same generation) and a rollback (lower).
            throw DaemonProviderError.generationFault(.overflow)
        }

        let data = preference.encoded()
        try SecureFiles.atomicReplace(data, at: fileURL)
    }

    // MARK: Private helpers

    /// Read the raw preference generation from disk without MAC verification.
    ///
    /// Used only by the write-side monotonic check.  Returns 0 for genuine
    /// absence, read failure, or unparseable generation — fail-safe: a
    /// corrupted generation defaults to 0, so a valid new write (generation ≥ 1)
    /// always advances past it.
    private func onDiskGenerationRaw() -> UInt64 {
        // We intentionally bypass SecureFiles.openValidatedIfExists here to
        // be resilient to marginal hygiene states that should not block a
        // legitimate preference write.  The MAC check (which does use the
        // hygiene path) is the security gate; this helper is only the
        // monotonic floor.
        guard let data = try? Data(contentsOf: fileURL),
              let record = ProviderPreference.decode(data)
        else { return 0 }
        return record.preferenceGeneration
    }
}
