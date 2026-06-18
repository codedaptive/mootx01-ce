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
}
#endif
