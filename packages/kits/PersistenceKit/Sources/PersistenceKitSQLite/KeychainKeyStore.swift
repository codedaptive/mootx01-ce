// KeychainKeyStore.swift
//
// The Apple key source for whole-file (Mode 3 / FullDatabase) estate
// encryption — the Apple analogue of the Rust per-install `db.key` file.
//
// A single 256-bit data key is generated once and stored in the Keychain. Every
// process that opens an estate (the app and the managed server it spawns, per
// ADR-005) loads the same key and passes it to
// `EstateEncryptionConfig.fullDatabase(key:)`, so SQLCipher opens the file with
// one consistent key.
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
import PersistenceKit

#if canImport(Security)
import Security

/// Loads or creates the per-install whole-file database key in the Keychain.
public struct KeychainKeyStore: Sendable {
    /// Service identifier for the keychain item (the bundle-style data-dir id).
    public let service: String
    /// Account/key name within the service.
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
