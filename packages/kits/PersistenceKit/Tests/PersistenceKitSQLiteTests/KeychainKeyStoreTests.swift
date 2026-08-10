// KeychainKeyStoreTests.swift
//
// Round-trip + idempotency for the Apple whole-file key source.

import Testing
import Foundation
import PersistenceKit
import PersistenceKitSQLite

#if canImport(Security)
import Security

struct KeychainKeyStoreTests {

    /// loadOrCreateKey returns a 32-byte key and is idempotent: a second call
    /// returns the identical key (so the app and the managed server agree).
    @Test func loadOrCreateIsIdempotentAndCorrectLength() throws {
        let service = "ai.mootx01.test.\(UUID().uuidString)"
        let store = KeychainKeyStore(service: service)
        defer {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ]
            SecItemDelete(q as CFDictionary)
        }

        let k1 = try store.loadOrCreateKey()
        #expect(k1.count == KeychainKeyStore.keyByteCount)
        let k2 = try store.loadOrCreateKey()
        #expect(k2 == k1, "loadOrCreateKey must return the same key on repeat")
    }

    /// The per-estate account is stable for one estate path and distinct across
    /// estates, and is invariant to lexical path differences (so the opener and
    /// the disposer agree even if one passes an unnormalized path).
    @Test func estateAccountIsStableAndPerEstate() {
        let a = URL(fileURLWithPath: "/tmp/m/databases/work/estate.sqlite")
        let b = URL(fileURLWithPath: "/tmp/m/databases/play/estate.sqlite")
        #expect(KeychainKeyStore.estateAccount(for: a) == KeychainKeyStore.estateAccount(for: a))
        #expect(KeychainKeyStore.estateAccount(for: a) != KeychainKeyStore.estateAccount(for: b),
                "distinct estates derive distinct accounts")
        let aUnnormalized = URL(fileURLWithPath: "/tmp/m/databases/work/../work/estate.sqlite")
        #expect(KeychainKeyStore.estateAccount(for: aUnnormalized) == KeychainKeyStore.estateAccount(for: a),
                "standardized path → same account regardless of lexical form")
    }

    /// loadExistingKey returns nil for a key that has never been minted, and
    /// leaves the Keychain item count unchanged — the no-mint contract.
    /// Probe uses a `keychainItemCount` helper that returns nil on Keychain
    /// unavailability so the count assertion skips instead of failing in
    /// restricted environments.
    @Test func loadExistingKeyReturnsNilAndDoesNotMint() throws {
        let service = "ai.mootx01.test.\(UUID().uuidString)"
        let store = KeychainKeyStore(service: service)

        let before = keychainItemCount(service: service)
        let result = try store.loadExistingKey()
        let after = keychainItemCount(service: service)

        #expect(result == nil, "loadExistingKey must return nil for an absent key")
        if let before, let after {
            #expect(after == before, "loadExistingKey must not create a Keychain item")
        }
    }

    /// loadExistingKey returns the identical key that loadOrCreateKey minted.
    @Test func loadExistingKeyReturnsKeyAfterMint() throws {
        let service = "ai.mootx01.test.\(UUID().uuidString)"
        let store = KeychainKeyStore(service: service)
        defer {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ]
            SecItemDelete(q as CFDictionary)
        }

        let minted = try store.loadOrCreateKey()
        let loaded = try store.loadExistingKey()
        #expect(loaded == minted, "loadExistingKey must return the existing key after mint")
    }

    /// Per-estate keys are independent, stable, and disposable: each estate gets
    /// its own key; disposing one leaves the other intact; and a disposed estate
    /// mints a fresh key on next open (the key never outlives the data).
    @Test func perEstateKeysAreIndependentAndDisposable() throws {
        let service = "ai.mootx01.test.\(UUID().uuidString)"
        let estateA = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)/databases/a/estate.sqlite")
        let estateB = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)/databases/b/estate.sqlite")
        let storeA = KeychainKeyStore(service: service, estateURL: estateA)
        let storeB = KeychainKeyStore(service: service, estateURL: estateB)
        defer {
            try? storeA.deleteKey()
            try? storeB.deleteKey()
        }

        let a1 = try storeA.loadOrCreateKey()
        let b1 = try storeB.loadOrCreateKey()
        #expect(a1.count == KeychainKeyStore.keyByteCount)
        #expect(a1 != b1, "distinct estates get distinct keys")
        #expect(try storeA.loadOrCreateKey() == a1, "a given estate's key is stable across opens")

        // Disposing A removes only A's key; B is untouched.
        try storeA.deleteKey()
        #expect(try storeB.loadOrCreateKey() == b1, "deleting one estate's key leaves another's intact")
        // deleteKey is idempotent: deleting an absent key is success.
        try storeA.deleteKey()
        // A regenerates a fresh, different key after disposal.
        let a2 = try storeA.loadOrCreateKey()
        #expect(a2 != a1, "after disposal, a new key is generated — the old key did not survive")
    }

    // Count generic-password items for `service`. Returns nil when the probe
    // itself fails so callers can skip the assertion in restricted environments.
    private func keychainItemCount(service: String) -> Int? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var out: CFTypeRef?
        switch SecItemCopyMatching(q as CFDictionary, &out) {
        case errSecItemNotFound: return 0
        case errSecSuccess: return (out as? [Any])?.count ?? 0
        default: return nil
        }
    }
}
#endif
