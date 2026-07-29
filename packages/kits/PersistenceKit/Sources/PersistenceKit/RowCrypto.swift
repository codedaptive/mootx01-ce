// RowCrypto.swift
//
// Per-row content-column crypto for the at-rest RowEncryption mode (Mode 2),
// plus the shared write/read seam that wires it into a storage backend.
//
// These types live in PersistenceKit core (not in a single backend module)
// because BOTH the SQLite and PostgreSQL backends apply identical per-row
// content encryption. Sharing one implementation guarantees the two backends
// produce and consume the same `[nonce][tag][ciphertext]` envelope — the
// cross-backend parity the substrate requires. This mirrors the Rust port,
// where the seam lives in `sqlite.rs` and `postgres.rs` imports it.
//
// Application-level per-record encryption, deliberately NOT whole-file
// SQLCipher: encrypting per row lets a machine read exactly the records whose
// key it holds and makes per-record keying fall out of the schema
// (federation disclosure controls Appendix A.1). Mode 3
// (FullDatabase / SQLCipher) is the orthogonal whole-file layer; it has no
// per-row analogue on PostgreSQL because the server owns the schema, so on
// Postgres the content seam is the only at-rest content protection.
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
// and passing a different type to the seam functions — zero changes to
// RowCrypto or any storage call site.
//
// Mode 1 (plaintext) and Mode 3 (FullDatabase) never call RowCrypto — the
// seam functions short-circuit on `usesRowCrypto`, so there is no identity
// path here to maintain.

import Foundation
import CryptoKit

// MARK: - AEAD provider seam

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
package protocol AeadProvider: Sendable {
    /// Encrypt `plaintext` under the 256-bit `key` bytes. Returns
    /// `[nonce][tag][ciphertext]`. A fresh random nonce is generated
    /// per call.
    func encrypt(_ plaintext: Data, key: Data) throws -> Data

    /// Decrypt `ciphertext` (layout `[nonce][tag][ciphertext]`) under
    /// the 256-bit `key` bytes. Throws on authentication failure or a
    /// malformed envelope.
    func decrypt(_ ciphertext: Data, key: Data) throws -> Data
}

/// The default `AeadProvider` backed by Apple CryptoKit's AES-GCM
/// implementation. This is the concrete type used on all Apple platforms
/// in the absence of an injected alternative.
///
/// A FedRAMP/FIPS-validated replacement drops in by supplying a different
/// `AeadProvider` conformer to the seam functions. The ciphertext layout
/// ([nonce][tag][ciphertext]) is identical so existing persisted rows
/// remain decryptable after a provider swap.
package struct CryptoKitAeadProvider: AeadProvider {

    package init() {}

    // The nonce and tag sizes are fixed by the AES-GCM-256 algorithm and
    // must match what the RowCrypto decode path expects.
    private static let nonceByteCount = 12  // 96-bit AES-GCM nonce
    private static let tagByteCount   = 16  // 128-bit GCM authentication tag

    /// Encrypt `plaintext` under `key` (32 raw bytes). Generates a fresh
    /// cryptographically random 96-bit nonce per call. Returns
    /// `[12-byte nonce][16-byte tag][ciphertext]`.
    ///
    /// Never logs `key` or intermediate material.
    package func encrypt(_ plaintext: Data, key keyBytes: Data) throws -> Data {
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
    package func decrypt(_ ciphertext: Data, key keyBytes: Data) throws -> Data {
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
/// `CryptoKitAeadProvider`, so call sites that omit it behave identically
/// to the default Apple-platform configuration.
///
/// The `SymmetricKey`-bearing overloads exist so that a backend holding
/// `EstateEncryptionConfig.key` as a `SymmetricKey?` does not need to change
/// its key representation. The key is converted to raw bytes internally — it
/// is never logged.
package enum RowCrypto {

    // MARK: Encrypt

    /// Encrypt `plaintext` under `key`, returning `[nonce][tag][ciphertext]`.
    /// A fresh random nonce is generated per call. Uses `CryptoKitAeadProvider`
    /// by default; pass an alternate conformer to swap the AEAD algorithm.
    package static func encrypt(
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
    package static func decrypt(
        _ ciphertext: Data,
        key: SymmetricKey,
        provider: any AeadProvider = CryptoKitAeadProvider()
    ) throws -> Data {
        let keyBytes = key.withUnsafeBytes { Data($0) }
        return try provider.decrypt(ciphertext, key: keyBytes)
    }
}

// MARK: - Shared write/read seam (Mission ENC-01)
//
// Per-row content-column crypto wires in at the column-aware backend layer
// where rows are `[String: TypedValue]` and the protected columns are
// reachable by name. Interception is by column name — "content" and
// "distilled" — which in the LocusKit schema belong to drawers alone, the
// sole content-bearing table, so stamping the keyID column on write is
// always valid. `distilled` is protected because it is content-DERIVED text
// (SPEC_DISTILLATION_STORAGE §2: a representation carries the same
// row-level protection class as the content it renders). Both the SQLite
// and PostgreSQL backends call these functions, which is what keeps their
// stored envelopes byte-compatible.

/// The text columns the per-row seam protects. Order is meaningful only
/// for determinism of iteration; each present column is sealed
/// independently under the same row key.
private let rowCryptoProtectedColumns: [String] = ["content", "distilled"]

/// Encrypt the protected text columns ("content", "distilled") and stamp
/// the key identifier when the estate uses per-row encryption (Mode 2 /
/// RowEncryption). Returns `values` unchanged for plaintext, for
/// FullDatabase (the whole file is encrypted by SQLCipher, so the per-row
/// seam is a no-op), and for rows carrying no protected text.
///
/// Empty-string text is passed through unsealed: the only empty-text write
/// in the schema is the expunge/zeroization scrub (`content = ""`), which
/// must stay a plaintext-empty erasure marker — the same exemption
/// `assertContentKeyIDInvariant` documents (#76). A representation-only
/// UPDATE (a value map with "distilled" but no "content") is sealed and
/// keyID-stamped exactly like a content write, so the distillation write
/// path never persists plaintext derived text on an encrypting estate.
package func encryptedForWrite(
    _ values: [String: TypedValue],
    config: EstateEncryptionConfig,
    provider: any AeadProvider = CryptoKitAeadProvider()
) throws -> [String: TypedValue] {
    guard config.usesRowCrypto,
          let key = config.key,
          let keyID = config.keyIdentifier else {
        return values
    }
    var out = values
    var sealedAny = false
    for column in rowCryptoProtectedColumns {
        guard case .text(let plaintext)? = values[column], !plaintext.isEmpty else { continue }
        out[column] = .blob(try RowCrypto.encrypt(Data(plaintext.utf8), key: key, provider: provider))
        sealedAny = true
    }
    if sealedAny {
        out["keyID"] = .text(keyID)
    }
    return out
}

/// Decrypt the protected text columns ("content", "distilled") when the row
/// carries a non-null keyID (an encrypted row) and the estate holds the
/// key. Returns `values` unchanged for Mode 1, for plaintext rows (null
/// keyID), or when a column is not stored as ciphertext bytes.
///
/// The row's keyID must match this estate's key identifier. In the
/// single-key model of Mode 2 that is the only key the estate holds,
/// so a mismatch means the row was sealed under a different key we
/// cannot open — pass it through unchanged (still ciphertext) rather
/// than attempt a decrypt that AES-GCM would only reject as an auth
/// failure. This makes the single-key path correct by construction and
/// keeps the seam ready for a future multi-key registry lookup.
package func decryptedForRead(
    _ values: [String: TypedValue],
    config: EstateEncryptionConfig,
    provider: any AeadProvider = CryptoKitAeadProvider()
) throws -> [String: TypedValue] {
    guard config.usesRowCrypto,
          let key = config.key,
          case .text(let keyID)? = values["keyID"], !keyID.isEmpty,
          keyID == config.keyIdentifier else {
        return values
    }
    var out = values
    for column in rowCryptoProtectedColumns {
        guard case .blob(let cipher)? = values[column] else { continue }
        out[column] = .text(String(decoding: try RowCrypto.decrypt(cipher, key: key, provider: provider), as: UTF8.self))
    }
    return out
}

/// Structural enforcement of the content/keyID invariant (FUP-D, E-1).
///
/// On an encrypting estate (Mode 2), a content-bearing row must be stored as
/// ciphertext under a keyID. `encryptedForWrite` produces exactly that —
/// `.blob` content plus a non-empty keyID — so a correct encrypting write
/// passes this guard untouched. A `.text` `content` value reaching the write
/// boundary on an encrypting estate means the encryption seam did not run
/// (e.g. a raw `upsert`, a migration, or a new store method); persisting it
/// would leave plaintext content with a null keyID — a row `decryptedForRead`
/// cannot resolve. Refuse the write rather than let convention be the only
/// safeguard. Mode 1 (plaintext) and Mode 3 (FullDatabase) return immediately,
/// so the path is byte-identical to before this guard existed.
package func assertContentKeyIDInvariant(
    _ values: [String: TypedValue],
    table: String,
    config: EstateEncryptionConfig
) throws {
    guard config.usesRowCrypto else { return }
    // The guard covers every protected text column ("content" and the
    // content-derived "distilled" — SPEC_DISTILLATION_STORAGE §2).
    // Exempt empty-string text (#76): expunge/zeroization writes
    // content = "" to erase the blob — there is nothing to encrypt.
    // Only non-empty plaintext without a keyID is the invariant violation.
    let plaintextColumn = rowCryptoProtectedColumns.first { column in
        if case .text(let text)? = values[column], !text.isEmpty { return true }
        return false
    }
    guard let violating = plaintextColumn else { return }
    // A keyID is present only when the protected text is ciphertext; .text
    // with no keyID is the unsafe, unencrypted write.
    if case .text(let keyID)? = values["keyID"], !keyID.isEmpty { return }
    throw StorageError.constraintViolation(detail:
        "content/keyID invariant: table '\(table)' on an encrypting estate received plaintext '\(violating)' with no keyID; the encryption seam did not run, so this row would be unreadable")
}
