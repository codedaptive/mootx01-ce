// KeyedCommitment.swift
//
// Public keyed-commitment API for expunge provenance (ADR-017 §17).
//
// Computes HMAC-SHA256 over the canonical leaf payload bytes (the same
// encoding MerkleHash.leaf uses), keyed by an estate-held secret.
// Domain-separated from the plain leaf hash by the COMMITMENT tag 0x03
// (vs LEAF 0x00). The commitment proves a payload existed without
// retaining a reversible fingerprint of destroyed personal data.
//
// Reuses GrantHKDF.hmac (the existing HMAC-SHA256 from SubstrateKernel)
// — no new HMAC implementation.
//
// Mirror: rust/src/keyed_commitment.rs — conformance-gated byte-identical.

import Foundation
import SubstrateTypes
import SubstrateKernel

/// The output of a keyed commitment: HMAC bytes + key version.
///
/// Carried in the expunge provenance audit entry and in
/// snapshot_attestations.key_version. Past commitments stay bound to
/// their writing version, so key rotation never invalidates prior
/// tamper-evidence.
public struct KeyedCommitmentValue: Hashable, Sendable, Codable {
    /// 32-byte HMAC-SHA256 output.
    public let hmacBytes: [UInt8]
    /// The key version that produced this commitment.
    public let keyVersion: Int

    public init(hmacBytes: [UInt8], keyVersion: Int) {
        precondition(hmacBytes.count == 32,
                     "HMAC-SHA256 output must be exactly 32 bytes")
        self.hmacBytes = hmacBytes
        self.keyVersion = keyVersion
    }

    /// Lowercase hex string of the HMAC bytes.
    public var hexString: String {
        hmacBytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Public keyed-commitment API for expunge provenance.
///
/// Uses GrantHKDF.hmac (the in-repo HMAC-SHA256) over the canonical
/// leaf payload bytes with the COMMITMENT domain tag (0x03).
public enum KeyedCommitment {

    /// Compute a keyed commitment over a drawer's content and vectors.
    ///
    /// The HMAC input is the canonical leaf payload bytes (the same
    /// encoding MerkleHash.leaf uses) but with the COMMITMENT domain
    /// tag 0x03 instead of the LEAF tag 0x00. This domain separation
    /// ensures a commitment and a content hash from the same payload
    /// are always different.
    ///
    /// - Parameters:
    ///   - key: The estate HMAC key bytes.
    ///   - keyVersion: The key version for rotation tracking.
    ///   - drawerId: The drawer's UUID.
    ///   - content: UTF-8 content bytes (caller is responsible for NFC).
    ///   - vectors: Vector inputs for the canonical encoding.
    /// - Returns: A `KeyedCommitmentValue` carrying the HMAC and version.
    public static func commit(
        key: [UInt8],
        keyVersion: Int,
        drawerId: UUID,
        content: [UInt8],
        vectors: [MerkleVectorInput]
    ) -> KeyedCommitmentValue {
        // Build canonical leaf bytes with COMMITMENT domain tag (0x03).
        let payload = MerkleHash.canonicalLeafBytes(
            drawerId: drawerId,
            content: content,
            vectors: vectors,
            domainTag: MerkleDomain.commitment
        )
        let hmac = GrantHKDF.hmac(key: key, data: payload)
        return KeyedCommitmentValue(hmacBytes: hmac, keyVersion: keyVersion)
    }
}
