// RowCrypto.swift
//
// Per-row content-column crypto for at-rest encryption modes 2 and 3.
// Application-level per-record encryption, deliberately NOT whole-file
// SQLCipher: encrypting per row lets a machine read exactly the records
// whose key it holds and makes per-record keying fall out of the schema
// (DECISION_FEDERATION_SHARING_MODEL_2026-05-21 Appendix A.1).
//
// Algorithm: AES-GCM-256 (PAR-4-PK / PAR-5-PK seam design).
// Key size: 256-bit (32 bytes). Nonce: 96-bit, freshly random per
// encrypt (never reused under a given key — the fundamental GCM safety
// requirement). The 128-bit GCM tag authenticates the ciphertext, so a
// single flipped byte fails decryption rather than yielding garbage.
//
// Stored ciphertext layout: [12-byte nonce][16-byte tag][ciphertext].
// The nonce and tag travel with the payload so decrypt is self-contained
// from the stored bytes alone.
//
// Swappable seam (PAR-4-PK): RowCrypto delegates ALL cryptographic
// operations to an AeadProvider. The default provider is
// CryptoKitAeadProvider (backed by CryptoKit AES.GCM). A future
// FedRAMP/FIPS-validated provider drops in by conforming to AeadProvider
// and passing a different type at SQLiteBackend construction time — zero
// changes to RowCrypto or any storage call site.
//
// Mode 1 (plaintext) never calls RowCrypto — SQLiteBackend skips the
// crypto seam entirely — so there is no identity path here to maintain.

import Foundation
import CryptoKit
import PersistenceKit

// MARK: - Default AEAD provider: CryptoKit AES-GCM-256

/// The default `AeadProvider` backed by Apple CryptoKit's AES-GCM
/// implementation. This is the concrete type used on all Apple platforms
/// in the absence of an injected alternative.
///
/// A FedRAMP/FIPS-validated replacement drops in by supplying a different
/// `AeadProvider` conformer at `SQLiteBackend` initialisation time. The
/// ciphertext layout ([nonce][tag][ciphertext]) is identical so existing
/// persisted rows remain decryptable after a provider swap.
struct CryptoKitAeadProvider: AeadProvider {

    // The nonce and tag sizes are fixed by the AES-GCM-256 algorithm and
    // must match what the RowCrypto decode path expects.
    private static let nonceByteCount = 12  // 96-bit AES-GCM nonce
    private static let tagByteCount   = 16  // 128-bit GCM authentication tag

    /// Encrypt `plaintext` under `key` (32 raw bytes). Generates a fresh
    /// cryptographically random 96-bit nonce per call. Returns
    /// `[12-byte nonce][16-byte tag][ciphertext]`.
    ///
    /// Never logs `key` or intermediate material.
    func encrypt(_ plaintext: Data, key keyBytes: Data) throws -> Data {
        let symKey = SymmetricKey(data: keyBytes)
        // CryptoKit generates a cryptographically random nonce when called
        // with no arguments — this is the fresh-per-encrypt requirement.
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: symKey, nonce: nonce)
        var out = Data()
        out.append(contentsOf: nonce)   // 12 bytes
        out.append(sealed.tag)          // 16 bytes
        out.append(sealed.ciphertext)   // variable length
        return out
    }

    /// Decrypt `ciphertext` (layout `[12-byte nonce][16-byte tag][payload]`)
    /// under `key` (32 raw bytes). Throws `StorageError.backendError` for a
    /// truncated envelope and `CryptoKitError` for an authentication failure.
    ///
    /// Never logs `key` or intermediate material.
    func decrypt(_ ciphertext: Data, key keyBytes: Data) throws -> Data {
        let header = Self.nonceByteCount + Self.tagByteCount
        guard ciphertext.count >= header else {
            throw StorageError.backendError(
                underlying: "RowCrypto: ciphertext shorter than nonce+tag header"
            )
        }
        // Copy into 0-based Data so subdata offsets are stable regardless
        // of the incoming Data's start index.
        let bytes = Data(ciphertext)
        let nonceData = bytes.subdata(in: 0..<Self.nonceByteCount)
        let tag      = bytes.subdata(in: Self.nonceByteCount..<header)
        let payload  = bytes.subdata(in: header..<bytes.count)
        let symKey = SymmetricKey(data: keyBytes)
        let nonce  = try AES.GCM.Nonce(data: nonceData)
        let box    = try AES.GCM.SealedBox(nonce: nonce, ciphertext: payload, tag: tag)
        return try AES.GCM.open(box, using: symKey)
    }
}

// MARK: - RowCrypto

/// Per-row AES-GCM-256 encrypt/decrypt, delegating to the injected
/// `AeadProvider`. The `provider` parameter defaults to
/// `CryptoKitAeadProvider`, so existing call sites (`RowCrypto.encrypt(_:key:)`)
/// compile and behave identically to before the seam was introduced.
///
/// The `SymmetricKey`-bearing overloads exist so that the SQLiteBackend
/// (which holds `EstateEncryptionConfig.key` as a `SymmetricKey?`) does
/// not need to change its key representation. The key is converted to
/// raw bytes internally — it is never logged.
enum RowCrypto {

    // MARK: Encrypt

    /// Encrypt `plaintext` under `key`, returning `[nonce][tag][ciphertext]`.
    /// A fresh random nonce is generated per call. Uses `CryptoKitAeadProvider`
    /// by default; pass an alternate conformer to swap the AEAD algorithm.
    static func encrypt(
        _ plaintext: Data,
        key: SymmetricKey,
        provider: any AeadProvider = CryptoKitAeadProvider()
    ) throws -> Data {
        // Extract raw key bytes for the provider interface. The key material
        // is held in a temporary local Data and goes out of scope immediately
        // after the provider call — it is never stored or logged.
        let keyBytes = key.withUnsafeBytes { Data($0) }
        return try provider.encrypt(plaintext, key: keyBytes)
    }

    // MARK: Decrypt

    /// Decrypt bytes laid out as `[nonce][tag][ciphertext]` under `key`.
    /// Throws on a malformed envelope or on authentication failure. Uses
    /// `CryptoKitAeadProvider` by default.
    static func decrypt(
        _ ciphertext: Data,
        key: SymmetricKey,
        provider: any AeadProvider = CryptoKitAeadProvider()
    ) throws -> Data {
        let keyBytes = key.withUnsafeBytes { Data($0) }
        return try provider.decrypt(ciphertext, key: keyBytes)
    }
}
