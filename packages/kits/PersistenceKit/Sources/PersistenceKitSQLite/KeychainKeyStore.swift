// KeychainKeyStore.swift
//
// The Apple key source for whole-file (Mode 3 / FullDatabase) estate
// encryption — the Apple analogue of the Rust per-estate `db.key` file.
//
// One 256-bit data key per estate, keyed by the estate's file path (see
// `estateAccount(for:)`), generated once and stored in the Keychain. Every
// process that opens a given estate (the app and the managed server it spawns,
// per ADR-005) derives the same account from the same estate path, loads the
// same key, and passes it to `EstateEncryptionConfig.fullDatabase(key:)`, so
// SQLCipher opens the file with one consistent key. Distinct estates get
// distinct keys, mirroring the Rust port's per-estate `db.key`: a key compromise
// is scoped to one estate, and deleting an estate disposes its key (`deleteKey`).
//
// Key protection (ADR-014):
//   - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — the key is available
//     to the resident process for background work after the first device unlock,
//     never leaves the device, and is not synced to iCloud.
//   - A shared `accessGroup` (the app's keychain-access-group entitlement) lets
//     the app and the managed server read the same item. `nil` uses the app's
//     default access group (single-process / tests).
//
// The raw symmetric key is stored as a generic-password item. Where stronger
// custody is required, the stored bytes can be a Secure-Enclave-wrapped key the
// caller unwraps — the store contract is unchanged (it returns 32 key bytes).

import Foundation
import CryptoKit
import PersistenceKit

#if canImport(Security)
import Security

/// Loads, creates, or disposes one estate's whole-file database key in the
/// Keychain. One key per estate, keyed by the estate's file path.
public struct KeychainKeyStore: Sendable {
    /// Service identifier for the keychain item (the bundle-style data-dir id).
    public let service: String
    /// Account/key name within the service. Per-estate accounts are derived from
    /// the estate file path via `estateAccount(for:)`.
    public let account: String
    /// Shared keychain access group, or `nil` for the app's default group.
    public let accessGroup: String?

    /// The whole-file key length in bytes (AES-256).
    public static let keyByteCount = 32

    public init(service: String, account: String = "estate-db-key", accessGroup: String? = nil) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    /// Per-estate convenience: derive the keychain account from the estate's
    /// file path so each estate gets its own key. The app and the managed server
    /// pass the same estate URL and therefore agree on the account; the
    /// estate-remove path passes the same URL to dispose the key.
    public init(service: String, estateURL: URL, accessGroup: String? = nil) {
        self.init(
            service: service,
            account: Self.estateAccount(for: estateURL),
            accessGroup: accessGroup
        )
    }

    /// Stable per-estate keychain account derived from the estate's file path.
    /// The path is standardized (resolving `.`/`..` and trailing slashes) so two
    /// processes opening the same file derive the same account, then hashed
    /// (SHA-256) to a fixed-length, character-clean account string. The Rust port
    /// achieves the same per-estate scoping by placing `db.key` inside the
    /// estate's own directory.
    public static func estateAccount(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "estate-db-key.\(hex)"
    }

    /// Return the existing key, or generate, store (owner-only, after-first-unlock,
    /// this-device-only), and return a fresh 256-bit key. Idempotent: concurrent
    /// first-callers race on `SecItemAdd`; the loser re-reads the winner's item.
    public func loadOrCreateKey() throws -> Data {
        if let existing = try readKey() {
            return existing
        }
        var key = Data(count: Self.keyByteCount)
        let rc = key.withUnsafeMutableBytes { buf in
            SecRandomCopyBytes(kSecRandomDefault, Self.keyByteCount, buf.baseAddress!)
        }
        guard rc == errSecSuccess else {
            throw StorageError.backendError(underlying: "keychain: SecRandomCopyBytes failed (\(rc))")
        }
        switch addKey(key) {
        case errSecSuccess:
            return key
        case errSecDuplicateItem:
            // Another process created it first; adopt theirs so all callers agree.
            guard let won = try readKey() else {
                throw StorageError.backendError(underlying: "keychain: duplicate add but item absent")
            }
            return won
        case let status:
            throw StorageError.backendError(underlying: "keychain: SecItemAdd failed (\(status))")
        }
    }

    /// Dispose this estate's key from the Keychain. Called by the estate-remove
    /// path so the key never outlives the data it protects (the Apple analogue of
    /// removing the Rust `db.key` with the estate directory). Idempotent: a
    /// missing item is success, not an error.
    public func deleteKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        case let other:
            throw StorageError.backendError(underlying: "keychain: SecItemDelete failed (\(other))")
        }
    }

    // MARK: - Internals

    private func baseQuery() -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            q[kSecAttrAccessGroup as String] = accessGroup
        }
        return q
    }

    private func readKey() throws -> Data? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data, data.count == Self.keyByteCount else {
                throw StorageError.backendError(
                    underlying: "keychain: stored key is malformed (wrong length)")
            }
            return data
        case errSecItemNotFound:
            return nil
        case let other:
            throw StorageError.backendError(underlying: "keychain: SecItemCopyMatching failed (\(other))")
        }
    }

    private func addKey(_ key: Data) -> OSStatus {
        var q = baseQuery()
        q[kSecValueData as String] = key
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil)
    }
}
#endif
