// AeadProvider.swift
//
// Swappable AEAD seam for at-rest row encryption (PAR-4-PK).
//
// Why a seam here: the encryption algorithm is an operational detail,
// not a protocol contract. A future FedRAMP/FIPS-validated hand-rolled
// AEAD must drop in by conforming to AeadProvider with ZERO changes to
// RowCrypto or any SQLite-layer call site. CryptoKit (Swift) is the
// default provider — an alternative provider supplies a different
// conforming type and injects it at SQLiteBackend construction time.
//
// Key representation: raw Data (32 bytes for AES-GCM-256) rather than
// CryptoKit's SymmetricKey, so a non-CryptoKit provider can conform
// without importing CryptoKit at all. CryptoKitAeadProvider converts
// internally.
//
// Stored ciphertext layout this seam contracts: [nonce][tag][ciphertext].
// The nonce length and tag length are provider-specific but must be
// self-describing in the output — CryptoKitAeadProvider uses 12-byte
// nonce (96-bit AES-GCM) and 16-byte tag (128-bit GCM auth tag), which
// is the only layout RowCrypto decodes. An alternate provider MUST
// produce and consume the same layout.

import Foundation

/// Abstract AEAD provider. A concrete type conforming to this protocol
/// is the single extension point for swapping the at-rest encryption
/// algorithm without changing any RowCrypto or storage call site.
///
/// Implementors MUST:
/// - Generate a fresh random nonce on every `encrypt` call (never reuse
///   a nonce under a given key — this is the fundamental GCM safety rule).
/// - Return `[nonce][tag][ciphertext]` in that order (12-byte nonce,
///   16-byte GCM tag for the default 96/128 GCM configuration). An
///   alternate layout is permitted only if the same provider's `decrypt`
///   consumes it.
/// - Throw on authentication failure — never return garbage plaintext
///   on a corrupt or tampered input.
/// - Never log the key or intermediate key material.
protocol AeadProvider: Sendable {
    /// Encrypt `plaintext` under the 256-bit `key` bytes. Returns
    /// `[nonce][tag][ciphertext]`. A fresh random nonce is generated
    /// per call.
    func encrypt(_ plaintext: Data, key: Data) throws -> Data

    /// Decrypt `ciphertext` (layout `[nonce][tag][ciphertext]`) under
    /// the 256-bit `key` bytes. Throws on authentication failure or a
    /// malformed envelope.
    func decrypt(_ ciphertext: Data, key: Data) throws -> Data
}
