// RowCrypto.swift
//
// Per-row content-column crypto for at-rest encryption modes 2 and 3
// (Mission ENC-01; DECISION_FEDERATION_SHARING_MODEL_2026-05-21.md
// Appendix A.1). Application-level per-record encryption, deliberately
// NOT whole-file SQLCipher: encrypting per row is what lets a machine
// read exactly the records whose key it holds and makes per-record keying
// fall out of the schema (Appendix A.1).
//
// Algorithm: AES-GCM-256. Key size 256-bit (32 bytes). Nonce 96-bit,
// freshly random per encrypt (never reused under a given key, which GCM
// requires). The 128-bit GCM tag authenticates the ciphertext, so a
// single flipped byte fails decryption rather than yielding garbage.
//
// Stored ciphertext layout: [12-byte nonce][16-byte tag][ciphertext].
// The nonce and tag travel with the payload so decrypt is self-contained
// from the stored bytes alone. (This is a fixed local framing rather than
// CryptoKit's `.combined` ordering, which is nonce‖ciphertext‖tag, so the
// layout matches the mission spec exactly and is decoded by offset below.)
//
// Mode 1 (plaintext) never calls RowCrypto — SQLiteBackend skips the
// crypto seam entirely — so there is no identity path here to maintain.

import Foundation
import CryptoKit
import PersistenceKit

enum RowCrypto {

    /// Header sizes for the stored layout.
    private static let nonceByteCount = 12  // 96-bit AES-GCM nonce
    private static let tagByteCount = 16    // 128-bit AES-GCM authentication tag

    /// Encrypt `plaintext` under `key`, returning
    /// `[nonce][tag][ciphertext]`. A fresh random nonce is generated per
    /// call.
    static func encrypt(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let nonce = AES.GCM.Nonce()  // cryptographically random 96-bit nonce
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        var out = Data()
        out.append(contentsOf: nonce)        // 12 bytes
        out.append(sealed.tag)               // 16 bytes
        out.append(sealed.ciphertext)        // remainder
        return out
    }

    /// Decrypt bytes laid out as `[nonce][tag][ciphertext]` under `key`.
    /// Throws on a malformed envelope or on authentication failure (a
    /// tampered byte or the wrong key).
    static func decrypt(_ ciphertext: Data, key: SymmetricKey) throws -> Data {
        let header = nonceByteCount + tagByteCount
        guard ciphertext.count >= header else {
            throw StorageError.backendError(
                underlying: "RowCrypto: ciphertext shorter than nonce+tag header"
            )
        }
        // Copy into a 0-based Data so subdata offsets are stable regardless
        // of the incoming Data's start index.
        let bytes = Data(ciphertext)
        let nonceData = bytes.subdata(in: 0..<nonceByteCount)
        let tag = bytes.subdata(in: nonceByteCount..<header)
        let payload = bytes.subdata(in: header..<bytes.count)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: payload, tag: tag)
        return try AES.GCM.open(box, using: key)
    }
}
