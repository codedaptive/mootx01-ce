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
// reachable by name.
//
// Interception is by (table, column) PAIR, never by column name alone. The
// protected names are not unique across the schema: `kg_facts` declares its
// own `subject` column (LocusKitSchema.swift), the subject term of an S-P-O
// knowledge-graph triple. Sealing that by name would break two things at
// once — `kg_facts` has no `keyID` column, so stamping one produces an
// INSERT naming a column that does not exist, and `subject` there is an
// indexed lookup key, so encrypting it under a fresh nonce per write would
// make `idx_kg_facts_subject` index ciphertext that never matches an
// equality probe. The table filter is what keeps protection targeted at the
// rows that need it.
//
// Which (table, column) pairs are intercepted, and the rule that decides
// whether a newly added table joins them, is stated once on
// `rowCryptoProtectedColumnsByTable` below. That declaration is the
// authority; do not restate the membership rule here.
//
// Both the SQLite and PostgreSQL backends call these functions, which is
// what keeps their stored envelopes byte-compatible.

/// The column carrying a row's key identifier. Present on every table that
/// declares protected columns; absent elsewhere, which is precisely why the
/// seam must not stamp it onto an unprotected table.
package let rowCryptoKeyIDColumn = "keyID"

/// The protected text columns, keyed by table.
///
/// ## The inclusion rule — apply it to every table you add to the schema
///
/// A table belongs in this map when BOTH of the following hold. Neither
/// alone is enough, and the second is the one that is easy to miss.
///
/// 1. **It declares a column that holds content, or text DERIVED from
///    content.** Per SPEC_DISTILLATION_STORAGE §2, a representation carries
///    the same row-level protection class as the content it renders — a
///    subject summarises the body it was generated from, so leaving it
///    plaintext on an encrypting estate discloses the substance of a sealed
///    row. A column that records only *how* or *when* a value was produced is
///    not content-derived and stays plaintext: `subject_pipeline_version`,
///    `subject_at`, `distilled_pipeline_version`, `distilled_at`. Nor are the
///    `content_hash` / `content_fingerprint` digests, which are computed over
///    content rather than carrying it, and which index and deduplication
///    read directly.
///
/// 2. **It declares a `keyID` column.** `encryptedForWrite` stamps `keyID`
///    on every row it seals, so listing a table that has no such column
///    produces a write naming a column that does not exist — the write fails
///    outright rather than degrading. A content-bearing table that cannot
///    carry `keyID` is therefore a schema question, not a map entry.
///
/// Today `drawers` is the only table in the schema that satisfies rule 2 at
/// all: it is the sole declarer of `keyID` in either port. That makes this
/// map *maximal*, not merely current — a second entry becomes possible only
/// once some other table gains a `keyID` column, and whoever makes that
/// schema change is the one who must come back here.
///
/// Two shapes are deliberately excluded under rule 2 and must stay excluded:
///
/// - `kg_facts` declares its own `subject` — the subject term of an S-P-O
///   triple, not content-derived — on a table with no `keyID`, and indexes it
///   for equality (`idx_kg_facts_subject`). Sealing it under a fresh nonce per
///   write would make that index match nothing.
/// - Dataset tables (`ds_<uuid>`) take their column names from the caller, so
///   a dataset may legitimately carry a column named `content`. They have no
///   `keyID` column and cannot be enumerated at compile time. Note this is a
///   boundary, not protection: such a column is written in the clear on an
///   encrypting estate. Dataset tables sit wholly outside Mode 2 whatever
///   their columns are named.
///
/// That list is NOT an inventory of every content-bearing column in the
/// estate. `corpus_documents.text` and `.dense_text` hold document body text
/// on the same physical database, written through this same seam, and are
/// content-derived by rule 1 — but the table declares no `keyID`, so rule 2
/// excludes it and the text is at rest in the clear. That is an open gap
/// awaiting a schema change, not a deliberate exemption, and it is queued as
/// its own mission. Do not read "maximal" as "everything content-bearing is
/// either sealed or deliberately spared".
///
/// A table absent from this map is not intercepted in either direction — its
/// values pass through untouched and it never receives a keyID stamp. That
/// absence is load-bearing: it is what keeps both shapes above byte-identical
/// to a pre-seam write.
///
/// Order within a table's list is meaningful only for determinism of
/// iteration; each present column is sealed independently under the same
/// row key.
///
/// Visible at `package` scope so the coverage tests can iterate the map
/// itself rather than restate its contents — a test that restates the map
/// cannot fail when the map gains a wrong entry.
package let rowCryptoProtectedColumnsByTable: [String: [String]] = [
    "drawers": ["content", "distilled", "subject"]
]

/// The protected columns for `table`, or an empty list when the table has
/// none. The match is exact — no prefix rule, no wildcard, no default — so
/// a new content-bearing table joins the protected set only by being added
/// to the map deliberately.
package func rowCryptoProtectedColumns(for table: String) -> [String] {
    rowCryptoProtectedColumnsByTable[table] ?? []
}

/// True when an explicit column projection of `table` reads a protected
/// column but omits `keyID`.
///
/// `decryptedForRead` cannot open a sealed value without the row's key
/// identifier, so such a projection would hand back ciphertext bytes where
/// the caller expects text — and silently, because `.blob` is a legal
/// `TypedValue` that a decoder reads as an absent string. A backend that
/// supports projection adds `keyID` to the SELECT when this returns true,
/// then removes it from the row it returns, leaving the caller's projection
/// contract unchanged.
///
/// False for a nil or empty projection (both select every column, so
/// `keyID` already rides along) and false on non-encrypting estates, where
/// nothing is sealed in the first place.
package func rowCryptoProjectionNeedsKeyID(
    table: String,
    columns: [String]?,
    config: EstateEncryptionConfig
) -> Bool {
    guard config.usesRowCrypto,
          let columns, !columns.isEmpty,
          !columns.contains(rowCryptoKeyIDColumn) else { return false }
    let protected = Set(rowCryptoProtectedColumns(for: table))
    return columns.contains { protected.contains($0) }
}

/// Encrypt `table`'s protected text columns and stamp the key identifier
/// when the estate uses per-row encryption (Mode 2 / RowEncryption).
/// Returns `values` unchanged for plaintext, for FullDatabase (the whole
/// file is encrypted by SQLCipher, so the per-row seam is a no-op), for a
/// table that declares no protected columns, and for rows carrying no
/// protected text.
///
/// `table` is required and has no default. A defaulted table name would
/// re-create the untargeted by-name interception this seam exists to
/// remove; making the compiler enumerate the call sites is the control that
/// keeps a new backend from silently sealing the wrong table.
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
    table: String,
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
    for column in rowCryptoProtectedColumns(for: table) {
        guard case .text(let plaintext)? = values[column], !plaintext.isEmpty else { continue }
        out[column] = .blob(try RowCrypto.encrypt(Data(plaintext.utf8), key: key, provider: provider))
        sealedAny = true
    }
    if sealedAny {
        out[rowCryptoKeyIDColumn] = .text(keyID)
    }
    return out
}

/// Decrypt `table`'s protected text columns when the row carries a non-null
/// keyID (an encrypted row) and the estate holds the key. Returns `values`
/// unchanged for Mode 1, for a table that declares no protected columns,
/// for plaintext rows (null keyID), or when a column is not stored as
/// ciphertext bytes.
///
/// `table` is required and has no default, for the same reason it is on
/// `encryptedForWrite`: read and write must agree on which columns are
/// sealed, and only an explicit table name can guarantee that.
///
/// A plaintext value in a protected column passes through untouched — the
/// `.blob` guard below skips it. That is what lets an estate written before
/// a column joined the protected set keep reading correctly alongside newly
/// sealed rows.
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
    table: String,
    config: EstateEncryptionConfig,
    provider: any AeadProvider = CryptoKitAeadProvider()
) throws -> [String: TypedValue] {
    guard config.usesRowCrypto,
          let key = config.key,
          case .text(let keyID)? = values[rowCryptoKeyIDColumn], !keyID.isEmpty,
          keyID == config.keyIdentifier else {
        return values
    }
    var out = values
    for column in rowCryptoProtectedColumns(for: table) {
        guard case .blob(let cipher)? = values[column] else { continue }
        out[column] = .text(String(decoding: try RowCrypto.decrypt(cipher, key: key, provider: provider), as: UTF8.self))
    }
    return out
}

/// Structural enforcement of the content/keyID invariant (FUP-D, E-1).
///
/// On an encrypting estate (Mode 2), a content-bearing row must be stored as
/// ciphertext. `encryptedForWrite` produces exactly that — `.blob` content
/// plus a non-empty keyID — so a correct encrypting write passes this guard
/// untouched. A `.text` value in a protected column reaching the write
/// boundary means the encryption seam did not run (a migration, or a new
/// store method that skipped it); persisting it would leave plaintext at
/// rest. Refuse the write rather than let convention be the only safeguard.
/// Mode 1 (plaintext) and Mode 3 (FullDatabase) return immediately, so the
/// path is byte-identical to before this guard existed.
///
/// `table` selects which columns the guard covers. It is not decoration on
/// the error message: a table with no protected columns cannot violate the
/// invariant, and firing on one would reject legitimate writes to tables
/// that merely reuse a protected column's name — `kg_facts.subject` being
/// the case that forced the filter.
package func assertContentKeyIDInvariant(
    _ values: [String: TypedValue],
    table: String,
    config: EstateEncryptionConfig
) throws {
    guard config.usesRowCrypto else { return }
    // The guard covers exactly the columns protected for THIS table.
    // Exempt empty-string text (#76): expunge/zeroization writes
    // content = "" to erase the blob — there is nothing to encrypt.
    // Only non-empty plaintext without a keyID is the invariant violation.
    let plaintextColumn = rowCryptoProtectedColumns(for: table).first { column in
        if case .text(let text)? = values[column], !text.isEmpty { return true }
        return false
    }
    guard let violating = plaintextColumn else { return }
    // The test is on the VALUE'S TYPE, never on the presence of a sibling
    // keyID. Ciphertext is `.blob`, so non-empty `.text` in a protected column
    // IS the unencrypted write — an accompanying keyID proves nothing about
    // it. That pairing is exactly what a decrypt-then-copy path produces:
    // `decryptedForRead` hands back plaintext while retaining the source row's
    // keyID, and a snapshot replication writes the pair straight through.
    // Treating the keyID as proof of ciphertext is what let plaintext reach an
    // encrypting estate's disk with no attacker involved.
    throw StorageError.constraintViolation(detail:
        "content/keyID invariant: table '\(table)' on an encrypting estate received plaintext '\(violating)'; ciphertext is stored as a blob, so text in a protected column means the encryption seam did not run")
}
