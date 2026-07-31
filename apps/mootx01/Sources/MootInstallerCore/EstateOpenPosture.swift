// EstateOpenPosture.swift
//
// ONE decision, shared by every command that opens the live estate, so serve,
// drain, and dream cannot drift apart on at-rest posture.
//
// THE RULE — DO NOT FORCE THE FLIP
// An existing plaintext estate must keep opening. If these commands
// unconditionally required a key, every existing macOS install would break on
// upgrade, including a 98,000-memory estate, because migration is a separate
// user-initiated step (`mootx01 upgrade`, CE-1.0.35-08). So:
//
//   file absent (first run)  → provision a key, open .fullDatabase
//   file present, ciphertext → load the EXISTING key, open .fullDatabase;
//                              FAIL CLOSED if the key is missing
//   file present, plaintext  → open plaintext, behavior unchanged
//
// The ciphertext branch is the one with teeth. It must NOT mint a key when none
// is found: minting would hand SQLCipher a brand-new wrong key for a file
// already encrypted under a different one, and the open would fail in a way that
// looks like corruption. Worse, a caller that treated that as "no estate" could
// create a fresh plaintext file over the top. So the absent-file branch and the
// ciphertext branch use DIFFERENT key calls, deliberately.
//
// Classification comes from EstateKeyProvider.detectEstateFileState, which reads
// the file header. Never guess by attempting an encrypted open and catching the
// error.

import Foundation

#if canImport(Security)
import Security
#endif

#if canImport(PersistenceKit)
import PersistenceKit
#endif

#if canImport(PersistenceKitSQLite)
import PersistenceKitSQLite
#endif

extension EstateKeyProvider {

    /// Why an estate could not be opened with the posture the file requires.
    public enum PostureError: Error, CustomStringConvertible {
        /// The file on disk is encrypted but no key could be found for it. Fail
        /// closed: the caller must abort, NOT create a new estate and NOT retry
        /// as plaintext.
        case encryptedEstateKeyMissing(estateURL: URL, underlying: String)

        public var description: String {
            switch self {
            case let .encryptedEstateKeyMissing(estateURL, underlying):
                // The Keychain account is derived from the estate PATH
                // (KeychainKeyStore.estateAccount), so the overwhelmingly most
                // likely cause of this error is that the estate moved or
                // MOOTX01_DATA_DIR changed — not that the Keychain item was
                // deleted. Say so, and name the account being looked for, so
                // the user can either move the file back or find the item.
                // There is no escrow: a key that cannot be located makes the
                // estate permanently unreadable, which makes an actionable
                // message the difference between a two-second fix and data loss.
                return """
                    the estate at \(estateURL.path) is encrypted but its key could not be \
                    loaded (\(underlying)). Refusing to continue: opening it without the \
                    correct key would fail, and creating a new estate would hide the \
                    existing one.

                    The key is looked up by the estate's PATH — Keychain service \
                    "\(EstateKeyProvider.keychainService)", account \
                    "\(KeychainKeyStore.estateAccount(for: estateURL))". If this estate \
                    was MOVED, or MOOTX01_DATA_DIR changed, the key is still in the \
                    Keychain under the OLD path's account and this lookup cannot find \
                    it. Move the estate back to its original path, or point \
                    MOOTX01_DATA_DIR at it, and the key resolves again. There is no \
                    escrow copy: do not delete the Keychain item.
                    """
            }
        }
    }

    /// The posture chosen for a given estate file, so a caller can log WHICH
    /// branch it took rather than just the outcome.
    public enum OpenPosture: Equatable, Sendable {
        /// No file yet: a key was provisioned and the estate will be created
        /// encrypted.
        case newEncrypted
        /// No file yet, and the user explicitly opted out with `--no-encrypt`.
        /// The estate will be created as plaintext. Reversible with
        /// `mootx01 upgrade`.
        case newPlaintextByOptOut
        /// The file is already encrypted and its existing key was loaded.
        case existingEncrypted
        /// The file is plaintext and stays plaintext. Migration is
        /// `mootx01 upgrade`, never implicit.
        case existingPlaintext
    }

    /// Filename of the per-estate encryption opt-out marker, written beside the
    /// estate file by `install --no-encrypt` and `db create --no-encrypt`.
    ///
    /// WHY A MARKER AND NOT A FLAG ON THE OPENING COMMAND
    /// Neither `install` nor `db create` creates an estate FILE. `install` says
    /// so in its own output ("a fresh estate will be created on first serve"),
    /// and `DatabaseManager.createEstate` only creates the estate DIRECTORY —
    /// the SQLite file is written lazily by the substrate on first open. So the
    /// surface that offers the opt-out is never the surface that creates the
    /// thing being opted out of, and the choice has to survive the gap between
    /// them. A marker file in the estate's own directory does that, is visible to
    /// the user, and travels with the estate.
    ///
    /// It is consulted ONLY on the absent-file branch. An estate that already
    /// exists is never re-postured by it: an existing plaintext estate stays
    /// plaintext because it is plaintext, and an existing encrypted estate is
    /// never downgraded by dropping a file next to it.
    public static let encryptionOptOutMarkerName = "no-encrypt"

    /// URL of the opt-out marker for an estate at `estateURL`.
    public static func encryptionOptOutMarkerURL(forEstateAt estateURL: URL) -> URL {
        estateURL.deletingLastPathComponent()
            .appendingPathComponent(encryptionOptOutMarkerName)
    }

    /// True when the estate at `estateURL` carries the opt-out marker.
    public static func hasEncryptionOptOut(forEstateAt estateURL: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: encryptionOptOutMarkerURL(forEstateAt: estateURL).path)
    }

    /// Record the opt-out for the estate that will be created at `estateURL`.
    /// Idempotent. Creates the estate directory if needed, because the marker has
    /// to exist before the estate file does.
    public static func writeEncryptionOptOut(forEstateAt estateURL: URL) throws {
        let marker = encryptionOptOutMarkerURL(forEstateAt: estateURL)
        try FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        try Data("""
            This estate was created with --no-encrypt and is NOT encrypted at rest.
            Run `mootx01 upgrade` to encrypt it. Deleting this file does not encrypt
            an estate that already exists; it only affects an estate that has not
            been created yet.

            """.utf8).write(to: marker, options: .atomic)
    }

    /// Remove a recorded opt-out for the estate at `estateURL`, if present.
    /// Returns true when a marker existed and was removed.
    ///
    /// The marker records a choice about an estate that does not exist yet.
    /// When a NEW estate is requested with encryption (the default), a marker
    /// left over from an earlier estate at the same path — a prior
    /// `--no-encrypt` install, or a `--replace-db` that trashed the database
    /// but not the marker — must not survive to downgrade the estate the
    /// current invocation promised would be encrypted.
    @discardableResult
    public static func removeEncryptionOptOut(forEstateAt estateURL: URL) throws -> Bool {
        let marker = encryptionOptOutMarkerURL(forEstateAt: estateURL)
        guard FileManager.default.fileExists(atPath: marker.path) else { return false }
        try FileManager.default.removeItem(at: marker)
        return true
    }

    #if canImport(PersistenceKit)
    /// Resolve the at-rest posture for the estate at `estateURL`.
    ///
    /// This is THE shared decision referenced by ServeCommand, DrainCommand, and
    /// DreamCommand. It never prompts and never migrates, which is a hard
    /// requirement: serve runs under launchd with no TTY.
    ///
    /// - Returns: the encryption config to hand `EstateConfiguration`, plus which
    ///   branch was taken.
    /// - Throws: `PostureError.encryptedEstateKeyMissing` when the file is
    ///   ciphertext and no key can be loaded, or a `KeyProviderError` when a new
    ///   estate's key cannot be provisioned. Both are fail-closed outcomes: the
    ///   caller aborts.
    public static func resolveOpenPosture(
        for estateURL: URL
    ) throws -> (encryption: EstateEncryptionConfig, posture: OpenPosture) {
        switch detectEstateFileState(at: estateURL) {
        case .absent:
            // Explicit opt-out recorded at install or `db create` time. The user
            // chose plaintext; honor it rather than encrypting behind their back.
            // Reversible through `mootx01 upgrade`.
            if hasEncryptionOptOut(forEstateAt: estateURL) {
                return (.plaintext, .newPlaintextByOptOut)
            }
            // First run. Provision (creating if needed) and open encrypted, which
            // is what brings macOS to parity with the Rust serve path.
            let key = try provideKey(for: estateURL)
            return (.fullDatabase(key: key), .newEncrypted)

        case .ciphertext:
            // Already encrypted. Load the EXISTING key only — see the file
            // header comment for why minting here would be destructive.
            do {
                let key = try existingKey(for: estateURL)
                return (.fullDatabase(key: key), .existingEncrypted)
            } catch {
                throw PostureError.encryptedEstateKeyMissing(
                    estateURL: estateURL, underlying: "\(error)")
            }

        case .plaintext:
            // Unchanged behavior. This is the branch that keeps every existing
            // macOS install working across the upgrade.
            return (.plaintext, .existingPlaintext)
        }
    }
    #endif

    /// Load the key for an estate that ALREADY EXISTS as ciphertext, without
    /// creating one.
    ///
    /// Distinct from `provideKey(for:)` on purpose. `provideKey` mints when
    /// nothing is found, which is correct for a new estate and wrong for an
    /// existing encrypted one. Probes the shared access group first, then the
    /// legacy default group (estates created before #94), same precedence as
    /// `provideKey`.
    public static func existingKey(for estateURL: URL) throws -> Data {
        #if canImport(Security) && canImport(PersistenceKitSQLite)
        let account = KeychainKeyStore.estateAccount(for: estateURL)
        for accessGroup in [sharedAccessGroup, nil] as [String?] {
            if let existing = try probeExistingKey(account: account, accessGroup: accessGroup) {
                return existing
            }
        }
        throw KeyProviderError.keychainUnavailable(
            "no stored key for estate \(estateURL.lastPathComponent) in either the shared or default access group")
        #else
        throw KeyProviderError.unsupportedPlatform
        #endif
    }
}
