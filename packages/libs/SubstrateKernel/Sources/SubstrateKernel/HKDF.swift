// HKDF.swift
//
// RFC 5869 HKDF-SHA256, built entirely over the in-repo SHA256 primitive.
//
// Purpose: the grant scope-key derivation surface (ScopeKeyVault) requires
// HKDF-SHA256 to bind a scope key to the estate's Ed25519 identity and the
// grant id. By implementing HKDF here instead of depending on CryptoKit's
// `HKDF<SHA256>`, the derivation becomes conformance-gated against the
// in-repo SHA-256 and the Rust port (substrate-kernel::hkdf), so a scope
// key derived on Apple Silicon is byte-identical to the same key derived on
// Linux x86_64. That identity is the whole point of the PAR-4-GL1 mission.
//
// The two-step RFC 5869 construction:
//
//   extract(salt, ikm) → prk
//     HMAC-SHA256(key=salt, data=ikm)
//
//   expand(prk, info, length) → okm
//     T(1) = HMAC-SHA256(key=prk, data=info || 0x01)
//     T(n) = HMAC-SHA256(key=prk, data=T(n-1) || info || n)
//     okm  = T(1) || T(2) || ... truncated to `length` bytes
//
// HMAC-SHA256 is the RFC 2104 construction:
//   HMAC(key, data) = SHA256((key xor opad) || SHA256((key xor ipad) || data))
//   where ipad = 0x36 repeated 64× and opad = 0x5C repeated 64×.
//   Keys longer than 64 bytes are SHA-256-hashed to 32 bytes first.
//
// Mirror: substrate-kernel/rust/src/hkdf.rs. Both legs are conformance-
// gated against the same vectors in the test suites.

import Foundation

/// RFC 5869 HKDF-SHA256. Pure, dependency-free, deterministic.
///
/// Uses the in-repo `SHA256` (FIPS 180-4) for both the HMAC inner and outer
/// hashes. No CryptoKit dependency.
public enum GrantHKDF {

    // MARK: - Public API

    /// Derive `outputByteCount` bytes of key material from `inputKeyMaterial`,
    /// a fixed `salt`, and a context-binding `info` string.
    ///
    /// - Parameters:
    ///   - inputKeyMaterial: the raw input keying material (e.g. Ed25519 raw
    ///     private key bytes). High-entropy; the salt does not need to be secret.
    ///   - salt: a fixed-domain salt string (e.g. "mootx01.grant.scope-key.v1").
    ///     Encoded to UTF-8 bytes; treated as a HMAC key by RFC 5869 §2.2.
    ///   - info: context-binding bytes (e.g. scope|grantID|granteeID). Must be
    ///     unique per derived key; encoded directly as the info parameter in expand.
    ///   - outputByteCount: number of output bytes; must be ≤ 32 × 255 (≤ 8160).
    ///     Typical usage is 32 (AES-256 key width).
    /// - Returns: exactly `outputByteCount` bytes of derived key material.
    public static func deriveKey(
        inputKeyMaterial: [UInt8],
        salt: String,
        info: [UInt8],
        outputByteCount: Int
    ) -> [UInt8] {
        let saltBytes = Array(salt.utf8)
        let prk = extract(salt: saltBytes, ikm: inputKeyMaterial)
        return expand(prk: prk, info: info, length: outputByteCount)
    }

    // MARK: - RFC 5869 internals

    /// RFC 5869 §2.2 Extract step.
    /// `prk = HMAC-SHA256(key=salt, data=ikm)`
    static func extract(salt: [UInt8], ikm: [UInt8]) -> [UInt8] {
        hmac(key: salt, data: ikm)
    }

    /// RFC 5869 §2.3 Expand step.
    /// Generates `length` bytes by chaining HMAC invocations, each appending
    /// the counter byte. `length` must be ≤ 32 × 255.
    static func expand(prk: [UInt8], info: [UInt8], length: Int) -> [UInt8] {
        precondition(length <= 32 * 255, "HKDF-SHA256 can produce at most 8160 bytes")
        var okm: [UInt8] = []
        var t: [UInt8] = []
        var counter: UInt8 = 1
        while okm.count < length {
            // T(n) = HMAC-SHA256(key=prk, data=T(n-1) || info || n)
            var data = t + info + [counter]
            t = hmac(key: prk, data: data)
            okm.append(contentsOf: t)
            counter &+= 1
            // Allow the optimizer to release `data` after this point;
            // it is no longer needed and is out of scope next iteration.
            data.withUnsafeMutableBytes { _ in }
        }
        return Array(okm.prefix(length))
    }

    // MARK: - RFC 2104 HMAC-SHA256

    /// HMAC-SHA256(key, data) per RFC 2104. Uses the in-repo `SHA256`.
    ///
    /// Public so SubstrateLib's KeyedCommitment API can compute HMAC-SHA256
    /// over canonical leaf payload bytes without reimplementing the
    /// construction. All internal callers (extract, expand) continue to work.
    public static func hmac(key: [UInt8], data: [UInt8]) -> [UInt8] {
        // SHA-256 block size is 64 bytes.
        let blockSize = 64

        // Keys longer than the block size are pre-hashed to 32 bytes (RFC 2104 §2).
        var k: [UInt8]
        if key.count > blockSize {
            k = SHA256.hash(key) + [UInt8](repeating: 0, count: blockSize - 32)
        } else {
            k = key + [UInt8](repeating: 0, count: blockSize - key.count)
        }

        // ipad = 0x36 × 64, opad = 0x5C × 64.
        let ipad: [UInt8] = k.map { $0 ^ 0x36 }
        let opad: [UInt8] = k.map { $0 ^ 0x5C }

        // HMAC = SHA256(opad || SHA256(ipad || data))
        let inner = SHA256.hash(ipad + data)
        return SHA256.hash(opad + inner)
    }
}
