// RowCryptoTests.swift
//
// Mission ENC-01 — AES-GCM-256 per-row content crypto.
// RowCrypto is internal to PersistenceKitSQLite, so this test target uses
// @testable import. Tests cover the four properties the mission names:
// round-trip, key isolation, tamper detection, and the stored format.

import Testing
import Foundation
import CryptoKit
@testable import PersistenceKitSQLite

struct RowCryptoTests {

    private let key = SymmetricKey(size: .bits256)

    /// Encrypt then decrypt returns the original bytes, and the ciphertext
    /// is not equal to the plaintext.
    @Test func encryptDecryptRoundTrip() throws {
        let plaintext = Data("the secret note".utf8)
        let ciphertext = try RowCrypto.encrypt(plaintext, key: key)
        #expect(ciphertext != plaintext)
        let recovered = try RowCrypto.decrypt(ciphertext, key: key)
        #expect(recovered == plaintext)
    }

    /// A ciphertext sealed under one key cannot be opened by another key:
    /// AES-GCM authentication fails and decrypt throws.
    @Test func keyIsolationWrongKeyFails() throws {
        let plaintext = Data("isolate me".utf8)
        let ciphertext = try RowCrypto.encrypt(plaintext, key: key)
        let otherKey = SymmetricKey(size: .bits256)
        #expect(throws: (any Error).self) {
            try RowCrypto.decrypt(ciphertext, key: otherKey)
        }
    }

    /// Flipping a single byte of the ciphertext breaks the GCM tag and
    /// decrypt throws rather than returning corrupted plaintext.
    @Test func tamperDetectionThrows() throws {
        let plaintext = Data("tamper-evident".utf8)
        var ciphertext = try RowCrypto.encrypt(plaintext, key: key)
        // Flip a byte inside the ciphertext payload (past the nonce+tag header).
        let flipIndex = ciphertext.count - 1
        ciphertext[flipIndex] ^= 0xFF
        #expect(throws: (any Error).self) {
            try RowCrypto.decrypt(ciphertext, key: key)
        }
    }

    /// Stored format is [12-byte nonce][16-byte tag][ciphertext], so the
    /// envelope is exactly 28 bytes longer than the plaintext and the
    /// payload differs from the plaintext.
    @Test func storedFormatNonceTagCiphertext() throws {
        let plaintext = Data("format check".utf8)
        let ciphertext = try RowCrypto.encrypt(plaintext, key: key)
        #expect(ciphertext.count == plaintext.count + 12 + 16)
        #expect(ciphertext.suffix(plaintext.count) != plaintext)
    }
}
