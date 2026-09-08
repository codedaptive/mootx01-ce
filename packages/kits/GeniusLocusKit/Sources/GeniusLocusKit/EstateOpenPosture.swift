// EstateOpenPosture.swift
//
// ONE decision, beside the estate catalog, for every process that opens an
// estate: the at-rest posture the estate's file requires and the key that goes
// with it. serve, drain, dream, upgrade, db, the resident daemon and the app
// all route through here, so they cannot drift apart on encryption.
//
// THE RULE — DO NOT FORCE THE FLIP
// An existing plaintext estate must keep opening. Migration to encryption is a
// separate user-initiated step (`mootx01 upgrade`), never implicit. So:
//
//   file absent, manifest declares plaintext → open plaintext, create plaintext
//   file absent, otherwise                    → provision a key, create encrypted
//   file present, ciphertext                  → load the EXISTING key; FAIL CLOSED
//                                               when it is missing
//   file present, plaintext                   → open plaintext, unchanged
//   transient estate (not a catalog record)   → plaintext only; ciphertext with no
//                                               harness key file is refused
//
// The ciphertext branch has teeth. It must NOT mint a key when none is found:
// minting would hand SQLCipher a brand-new wrong key for a file already
// encrypted under a different one, and the open would fail in a way that looks
// like corruption. Worse, a caller that treated that as "no estate" could
// create a fresh plaintext file over the top. So the absent-file branch and the
// ciphertext branch use DIFFERENT key calls, deliberately.
//
// KEY CUSTODY
// Apple platforms hold the key as a Keychain generic-password item under
// `MootProductIdentity.Keychain.estateKeyService`, scoped per estate by hashing
// the estate's standardized path into the account name
// (`KeychainKeyStore.estateAccount`). The item is minted into the shared access
// group (`MootProductIdentity.Keychain.sharedAccessGroup`) so the app and a
// separately spawned server read one item; lookups probe the shared group first
// and then the default group, where estates created before the shared group
// existed keep their key. iOS has no separately spawned peer and no
// shared-group entitlement, so it mints into the default group.
//
// Only a REGISTERED estate (a catalog record) may hold a Keychain key. A
// transient estate never touches the Keychain.
//
// FAIL CLOSED
// Every key path either returns 32 key bytes or throws. Nothing returns nil and
// nothing falls back to plaintext for a file that is not plaintext.
//
// Classification of the file comes from EstateEncryption's header read
// (`detectEstateFileState`): never guess by attempting an encrypted open.

import EstateEncryption
import Foundation
import MootProductIdentity
import OSLog
import PersistenceKit

#if canImport(Security)
import Security
#endif
#if canImport(PersistenceKitSQLite)
import PersistenceKitSQLite
#endif

/// The at-rest open posture of an estate and the custody of its key.
public enum EstateOpenPosture {

    /// Which branch of the rule an open took, so a caller can log it.
    public enum Posture: Equatable, Sendable {
        /// No file yet: a key was provisioned and the estate will be created encrypted.
        case newEncrypted
        /// No file yet and the manifest declares plaintext: created plaintext.
        /// Reversible through `mootx01 upgrade`.
        case newPlaintextDeclared
        /// The file is already encrypted and its existing key was loaded.
        case existingEncrypted
        /// The file is plaintext and stays plaintext.
        case existingPlaintext
    }

    /// Why an estate could not be opened with the posture its file requires,
    /// or why no key could be provided. Every case is fail-closed: the caller
    /// aborts, never creates a new estate, never retries as plaintext.
    public enum Error: Swift.Error, CustomStringConvertible {
        /// The file is ciphertext and no key could be found for it.
        case encryptedEstateKeyMissing(databaseURL: URL, underlying: String)
        /// The Keychain refused the operation; carries the underlying text.
        case keychainUnavailable(String)
        /// The Keychain returned something that is not a usable key.
        case malformedKey(count: Int)
        /// This platform has no Keychain.
        case unsupportedPlatform
        /// The record's backend keeps the database outside the directory
        /// (PostgreSQL), so there is no file whose header decides a posture
        /// and no per-estate key. The caller opens the backend directly.
        case backendHasNoDatabaseFile(name: String, backend: String)

        public var description: String {
            switch self {
            case let .backendHasNoDatabaseFile(name, backend):
                return "estate '\(name)' is on the \(backend) backend, which has no database file to open with a posture"
            case let .encryptedEstateKeyMissing(databaseURL, underlying):
                // The account is derived from the estate PATH, so the likeliest
                // cause is that the estate moved, not that the item was deleted.
                // There is no escrow: a key that cannot be located makes the
                // estate permanently unreadable, so the message must be actionable.
                #if canImport(Security) && canImport(PersistenceKitSQLite)
                let account = KeychainKeyStore.estateAccount(for: databaseURL)
                #else
                let account = "(no Keychain on this platform)"
                #endif
                return """
                    the estate at \(databaseURL.path) is encrypted but its key could not be \
                    loaded (\(underlying)). Refusing to continue: opening it without the \
                    correct key would fail, and creating a new estate would hide the \
                    existing one.

                    The key is looked up by the estate's PATH — Keychain service \
                    "\(MootProductIdentity.Keychain.estateKeyService)", account "\(account)". \
                    If this estate was MOVED, the key is still in the Keychain under the \
                    OLD path's account and this lookup cannot find it. Move the estate \
                    back to its original path and the key resolves again. There is no \
                    escrow copy: do not delete the Keychain item.
                    """
            case let .keychainUnavailable(detail):
                return "estate encryption key unavailable from the Keychain: \(detail)"
            case let .malformedKey(count):
                return "estate encryption key is malformed: expected \(EstateOpenPosture.keyByteCount) bytes, got \(count)"
            case .unsupportedPlatform:
                return "estate encryption key custody is not available on this platform"
            }
        }
    }

    /// Number of key bytes SQLCipher is configured with.
    public static let keyByteCount = 32

    private static let logger = Logger(subsystem: MootProductIdentity.Logging.subsystem, category: "GeniusLocusKit")

    /// True when this platform can hold an estate key at all. Tests that need
    /// the Keychain skip rather than fail where it is unavailable.
    public static var isKeyCustodyAvailable: Bool {
        #if canImport(Security) && canImport(PersistenceKitSQLite)
        return true
        #else
        return false
        #endif
    }

    /// The access group a NEW key is minted into: the shared group on macOS so
    /// the app and a spawned server read one item; the default group on iOS,
    /// which has no spawned peer and no shared-group entitlement.
    static var mintAccessGroup: String? {
        #if os(iOS)
        return nil
        #else
        return MootProductIdentity.Keychain.sharedAccessGroup
        #endif
    }

    /// Lookup order: the shared group first, so a migrated estate keeps using
    /// its shared item, then the default group for estates keyed before the
    /// shared group existed.
    static var lookupAccessGroups: [String?] { [MootProductIdentity.Keychain.sharedAccessGroup, nil] }

    // MARK: - File classification

    /// What a file at a given path is: absent, plaintext SQLite, or ciphertext.
    public typealias FileState = EstateEncryptionMigrator.EstateFileState

    /// The plaintext SQLite file magic, 16 bytes.
    public static var plaintextSQLiteMagic: [UInt8] { EstateEncryptionMigrator.plaintextSQLiteMagic }

    /// Classify the estate file at `url` by its header. Forwards to
    /// EstateEncryption so every port and tool classifies identically.
    public static func fileState(at url: URL) -> FileState {
        EstateEncryptionMigrator.detectEstateFileState(at: url)
    }

    // MARK: - The decision

    /// Resolve the posture for a catalog record. The record's kind decides
    /// whether a Keychain key may exist at all, and its manifest, when present,
    /// carries the plaintext declaration made at create.
    public static func resolve(for record: EstateRecord) throws -> (encryption: EstateEncryptionConfig, posture: Posture) {
        guard case .sqlite = record.backend else {
            throw Error.backendHasNoDatabaseFile(name: record.name, backend: record.backend.kindName)
        }
        let declaresPlaintext = (try? EstateCatalog.readManifest(of: record))?.encryption == .plaintext
        return try resolve(databaseURL: record.databaseURL,
                           registered: record.kind == .registered,
                           declaresPlaintext: declaresPlaintext)
    }

    /// Resolve the posture for an estate file that is not a catalog record (the
    /// resident daemon's and the app container's estates). `registered` says
    /// whether this machine owns it and so may hold its key.
    ///
    /// Never prompts and never migrates: serve runs under launchd with no TTY.
    public static func resolve(databaseURL: URL, registered: Bool, declaresPlaintext: Bool) throws
        -> (encryption: EstateEncryptionConfig, posture: Posture)
    {
        #if MOOTX01_HARNESS_KEYFILE
        // HARNESS BUILDS ONLY — absent from every shipping binary. The benchmark
        // harness serves databases it converted moments earlier and deletes
        // minutes later; a key file beside the databases (the Rust port's own
        // mechanism) is consulted BEFORE the Keychain so a harness run never
        // reaches Keychain custody on any branch.
        if let key = try harnessInstallKey(for: databaseURL) {
            switch fileState(at: databaseURL) {
            case .plaintext: return (.plaintext, .existingPlaintext)
            case .ciphertext: return (.fullDatabase(key: key), .existingEncrypted)
            case .absent: return (.fullDatabase(key: key), .newEncrypted)
            }
        }
        #endif

        if !registered {
            // Transient: plaintext, never a Keychain key. Ciphertext with no
            // harness key file is refused rather than guessed at.
            switch fileState(at: databaseURL) {
            case .absent: return (.plaintext, .newPlaintextDeclared)
            case .plaintext: return (.plaintext, .existingPlaintext)
            case .ciphertext:
                throw Error.encryptedEstateKeyMissing(
                    databaseURL: databaseURL,
                    underlying: "transient estates cannot hold a Keychain key; only a registered estate may be encrypted")
            }
        }

        switch fileState(at: databaseURL) {
        case .absent:
            if declaresPlaintext {
                // The manifest recorded the plaintext choice at install or
                // `db create`; honour it rather than encrypting behind the
                // user's back. Reversible through `mootx01 upgrade`.
                return (.plaintext, .newPlaintextDeclared)
            }
            let key = try provideKey(databaseURL: databaseURL)
            return (.fullDatabase(key: key), .newEncrypted)
        case .ciphertext:
            // Already encrypted: load the EXISTING key only (see the header
            // comment for why minting here would be destructive).
            do {
                let key = try existingKey(databaseURL: databaseURL)
                return (.fullDatabase(key: key), .existingEncrypted)
            } catch {
                throw Error.encryptedEstateKeyMissing(databaseURL: databaseURL, underlying: "\(error)")
            }
        case .plaintext:
            return (.plaintext, .existingPlaintext)
        }
    }

    // MARK: - Key custody

    /// The 32-byte whole-database key for a registered record, created and
    /// stored if none exists. Throws on any Keychain failure; never nil, never
    /// a plaintext fallback.
    public static func provideKey(for record: EstateRecord) throws -> Data {
        try provideKey(databaseURL: record.databaseURL)
    }

    /// `provideKey(for:)` over a database URL, for estates that are not catalog records.
    public static func provideKey(databaseURL: URL) throws -> Data {
        #if canImport(Security) && canImport(PersistenceKitSQLite)
        let account = KeychainKeyStore.estateAccount(for: databaseURL)
        // Read-only probes first, in precedence order. Minting in the shared
        // group before probing the default group would create a second key for
        // an estate whose real key sits in the default group, and the estate
        // would then fail to open with a brand-new wrong key.
        for accessGroup in lookupAccessGroups {
            if let existing = try probeExistingKey(account: account, accessGroup: accessGroup) {
                return existing
            }
        }
        do {
            let key = try KeychainKeyStore(
                service: MootProductIdentity.Keychain.estateKeyService,
                estateURL: databaseURL,
                accessGroup: mintAccessGroup
            ).loadOrCreateKey()
            guard key.count == keyByteCount else { throw Error.malformedKey(count: key.count) }
            return key
        } catch let error as Error {
            throw error
        } catch {
            throw Error.keychainUnavailable("\(error)")
        }
        #else
        throw Error.unsupportedPlatform
        #endif
    }

    /// The key for an estate that ALREADY EXISTS as ciphertext, without creating
    /// one. Distinct from `provideKey` on purpose: `provideKey` mints when
    /// nothing is found, which is right for a new estate and wrong for an
    /// existing encrypted one.
    public static func existingKey(databaseURL: URL) throws -> Data {
        #if canImport(Security) && canImport(PersistenceKitSQLite)
        let account = KeychainKeyStore.estateAccount(for: databaseURL)
        for accessGroup in lookupAccessGroups {
            if let existing = try probeExistingKey(account: account, accessGroup: accessGroup) {
                return existing
            }
        }
        throw Error.keychainUnavailable(
            "no stored key for estate \(databaseURL.lastPathComponent) in either the shared or default access group")
        #else
        throw Error.unsupportedPlatform
        #endif
    }

    /// Move an estate's key to the account of a new path. The account is a
    /// hash of the estate file's path, so a capsule that moves the file must
    /// move the key first or the moved estate fails closed on its next open.
    ///
    /// Idempotent and crash-safe in either order: a key already at the new
    /// path returns false and touches nothing (a run interrupted after the
    /// copy resumes here); no key at either path returns false (a plaintext
    /// estate, or one never keyed). Otherwise the key found at the old path
    /// (shared group first, then default) is stored under the new account in
    /// the group new keys are minted into, and only then deleted from the old
    /// account. Returns true when a key moved.
    @discardableResult
    public static func relocateKey(from oldDatabaseURL: URL, to newDatabaseURL: URL) throws -> Bool {
        #if canImport(Security) && canImport(PersistenceKitSQLite)
        let newAccount = KeychainKeyStore.estateAccount(for: newDatabaseURL)
        for accessGroup in lookupAccessGroups {
            if try probeExistingKey(account: newAccount, accessGroup: accessGroup) != nil { return false }
        }
        let oldAccount = KeychainKeyStore.estateAccount(for: oldDatabaseURL)
        var found: Data?
        for accessGroup in lookupAccessGroups {
            if let key = try probeExistingKey(account: oldAccount, accessGroup: accessGroup) { found = key; break }
        }
        guard let key = found else { return false }
        do {
            try KeychainKeyStore(
                service: MootProductIdentity.Keychain.estateKeyService,
                account: newAccount,
                accessGroup: mintAccessGroup
            ).storeKey(key)
        } catch {
            throw Error.keychainUnavailable("relocating the estate key: \(error)")
        }
        // The copy is in place; the old item is now surplus. A failure here
        // leaves two items for one key, which the next relocation call sees as
        // "already at the new path" — harmless, and disposal removes both.
        for failure in disposeKey(databaseURL: oldDatabaseURL) {
            logger.error("estate key relocated but the old item could not be removed: \(String(describing: failure), privacy: .public)")
        }
        return true
        #else
        throw Error.unsupportedPlatform
        #endif
    }

    /// Dispose the estate's key from both access groups so it never outlives
    /// the data it protected. Best effort: a missing item is not an error, and
    /// Keychain failures are returned for the caller to log rather than thrown,
    /// because by the time this runs the data is gone and a Keychain error must
    /// not stop the teardown.
    @discardableResult
    public static func disposeKey(databaseURL: URL) -> [Swift.Error] {
        #if canImport(Security) && canImport(PersistenceKitSQLite)
        var failures: [Swift.Error] = []
        for accessGroup in lookupAccessGroups {
            do {
                try KeychainKeyStore(
                    service: MootProductIdentity.Keychain.estateKeyService,
                    estateURL: databaseURL,
                    accessGroup: accessGroup
                ).deleteKey()
            } catch {
                failures.append(error)
            }
        }
        return failures
        #else
        return []
        #endif
    }

    #if MOOTX01_HARNESS_KEYFILE
    /// HARNESS ONLY: the key file beside the databases (EstateEncryption's
    /// install key), or nil when none is present.
    public static func harnessInstallKey(for databaseURL: URL) throws -> Data? {
        let directory = databaseURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(
            atPath: EstateEncryptionMigrator.installKeyURL(inDirectory: directory).path)
        else { return nil }
        return try EstateEncryptionMigrator.loadOrCreateInstallKey(inDirectory: directory)
    }
    #endif

    #if canImport(Security) && canImport(PersistenceKitSQLite)
    /// Read an existing key without creating one. nil when the item is absent;
    /// throws when the Keychain itself fails, so a locked or broken Keychain is
    /// never mistaken for "no key yet" (which would mint a second key over a
    /// real one). Uses the same query shape KeychainKeyStore uses; the account
    /// comes from KeychainKeyStore.estateAccount so the derivation is never
    /// duplicated.
    static func probeExistingKey(account: String, accessGroup: String?) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: MootProductIdentity.Keychain.estateKeyService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data else { throw Error.malformedKey(count: 0) }
            guard data.count == keyByteCount else { throw Error.malformedKey(count: data.count) }
            return data
        case errSecItemNotFound:
            return nil
        case errSecMissingEntitlement:
            // An unsigned or wrongly entitled build cannot see the shared access
            // group. Absent for THIS group, so the default-group probe and the
            // mint path can still run; a genuinely unavailable Keychain surfaces
            // from loadOrCreateKey instead.
            return nil
        case let other:
            throw Error.keychainUnavailable(
                "SecItemCopyMatching failed (\(other)) for access group \(accessGroup ?? "default")")
        }
    }
    #endif
}
