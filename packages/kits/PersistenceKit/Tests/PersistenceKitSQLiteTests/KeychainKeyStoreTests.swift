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
}
#endif
