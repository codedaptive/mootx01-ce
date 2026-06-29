// MerkleHash.swift
//
// Public hash pipeline for the Merkle content-integrity tree (ADR-017 §16).
//
// Three functions: leaf (drawer content + vectors), interior (subtree of
// children), tombstone (expunged payload). All three use SubstrateKernel's
// SHA256.hash — no new hash implementation.
//
// Domain-separated by MerkleDomain tags (0x00 leaf, 0x01 interior,
// 0x02 tombstone) prepended before hashing, so a leaf hash can never
// collide with or be substituted for an interior hash.
//
// The canonical byte encoding for leaf payloads is shared with
// KeyedCommitment (§17): one encoding, two uses — the content hash
// and the keyed commitment are computed from the same byte sequence
// with different domain tags.
//
// Mirror: rust/src/merkle_hash.rs — conformance-gated byte-identical.

import Foundation
import SubstrateTypes
import SubstrateKernel

/// Lightweight vector input for the hash pipeline.
///
/// SubstrateLib cannot import VectorKit (dependency inversion), so this
/// struct captures the fields needed to serialize vectors into the
/// canonical byte format per ADR-017 §16. The caller (a kit that has
/// VectorKit in scope) converts VectorPayload to MerkleVectorInput
/// before calling MerkleHash.leaf.
public struct MerkleVectorInput: Sendable {
    /// The embedding model identifier, used for sort ordering.
    public let modelID: String
    /// Multi-vector index (0 for single-vector models).
    public let vectorIndex: UInt32
    /// IEEE-754 float32 coefficients.
    public let floats: [Float]

    public init(modelID: String, vectorIndex: UInt32, floats: [Float]) {
        self.modelID = modelID
        self.vectorIndex = vectorIndex
        self.floats = floats
    }
}

/// Public hash pipeline for the Merkle content-integrity tree.
///
/// All three functions produce deterministic, byte-identical output
/// across Swift and Rust. The hash function is SubstrateKernel's
/// SHA256 — conformance-gated against NIST FIPS 180-4 vectors.
public enum MerkleHash {

    // MARK: - Leaf hash

    /// Hash a drawer's content and vectors into a ContentHash.
    ///
    /// Canonical byte format per ADR-017 §16 v2:
    /// - MerkleDomain.LEAF (0x00)
    /// - drawer id: 16 bytes big-endian UUID
    /// - content: u64 BE length prefix + UTF-8 bytes
    /// - vectors: u32 BE count prefix, then each vector sorted by
    ///   (modelID ascending, vectorIndex ascending) with per-vector layout:
    ///   u32 BE modelID-length | modelID UTF-8 bytes | u32 BE vectorIndex |
    ///   u32 BE float-count | IEEE-754 LE floats
    ///
    /// The v2 layout writes vector identity (modelID + vectorIndex) into the
    /// preimage before the float payload. v1 used these fields only for sort
    /// order — a binding gap that allowed keyed commitments to accept vector
    /// substitutions without hash mismatch (security finding WS2-F4).
    ///
    /// - Parameters:
    ///   - drawerId: The drawer's UUID.
    ///   - content: UTF-8 content bytes (caller is responsible for NFC).
    ///   - vectors: Vector inputs sorted and serialized per the v2 spec.
    /// - Returns: The SHA-256 content hash.
    public static func leaf(
        drawerId: UUID,
        content: [UInt8],
        vectors: [MerkleVectorInput]
    ) -> ContentHash {
        let payload = canonicalLeafBytes(
            drawerId: drawerId,
            content: content,
            vectors: vectors,
            domainTag: MerkleDomain.leaf
        )
        return ContentHash(bytes: SHA256.hash(payload))
    }

    // MARK: - Interior hash

    /// Hash a node's children into a MerkleRoot.
    ///
    /// Children are sorted by UUID ascending (lexicographic over the
    /// 16-byte big-endian representation) to make the roll-up
    /// independent of write order.
    ///
    /// - Parameter childHashes: Pairs of (child UUID, child ContentHash).
    /// - Returns: The SHA-256 Merkle root. Returns `MerkleRoot.empty`
    ///   when childHashes is empty.
    public static func interior(
        childHashes: [(UUID, ContentHash)]
    ) -> MerkleRoot {
        if childHashes.isEmpty {
            return MerkleRoot.empty
        }

        // Sort by UUID ascending — lexicographic over 16-byte BE.
        let sorted = childHashes.sorted { a, b in
            uuidBytes(a.0).lexicographicallyPrecedes(uuidBytes(b.0))
        }

        var payload: [UInt8] = [MerkleDomain.interior]
        for (_, hash) in sorted {
            payload.append(contentsOf: hash.bytes)
        }
        return MerkleRoot(bytes: SHA256.hash(payload))
    }

    /// Hash a node's child MerkleRoots into a parent MerkleRoot.
    ///
    /// Used at wing and estate levels where children already carry
    /// MerkleRoots (not ContentHashes). Same domain tag and sort order
    /// as the ContentHash overload — the hash is over the raw 32-byte
    /// values regardless of type wrapper.
    ///
    /// - Parameter childRoots: Pairs of (child UUID, child MerkleRoot).
    /// - Returns: The SHA-256 Merkle root. Returns `MerkleRoot.empty`
    ///   when childRoots is empty.
    public static func interior(
        childRoots: [(UUID, MerkleRoot)]
    ) -> MerkleRoot {
        if childRoots.isEmpty {
            return MerkleRoot.empty
        }

        let sorted = childRoots.sorted { a, b in
            uuidBytes(a.0).lexicographicallyPrecedes(uuidBytes(b.0))
        }

        var payload: [UInt8] = [MerkleDomain.interior]
        for (_, root) in sorted {
            payload.append(contentsOf: root.bytes)
        }
        return MerkleRoot(bytes: SHA256.hash(payload))
    }

    // MARK: - Tombstone hash

    /// Hash a tombstoned drawer into a ContentHash.
    ///
    /// Canonical format: MerkleDomain.TOMBSTONE (0x02) + drawer id 16B BE.
    /// No content, no vectors — they are destroyed by expunge.
    ///
    /// - Parameter drawerId: The drawer's UUID.
    /// - Returns: The SHA-256 tombstone hash for this specific drawer.
    public static func tombstone(drawerId: UUID) -> ContentHash {
        var payload: [UInt8] = [MerkleDomain.tombstone]
        payload.append(contentsOf: uuidBytes(drawerId))
        return ContentHash(bytes: SHA256.hash(payload))
    }

    // MARK: - Canonical byte encoding (shared with KeyedCommitment)

    /// Build the canonical leaf payload bytes per ADR-017 §16 v2.
    ///
    /// Shared between MerkleHash.leaf (domain tag 0x00) and
    /// KeyedCommitment.commit (domain tag 0x03) — one encoding,
    /// two uses. The v2 format writes vector identity (modelID + vectorIndex)
    /// into the preimage before the float payload, binding the vector's
    /// provenance to the hash. This prevents vector substitution attacks
    /// where swapping vectors of the same dimension would not change the
    /// leaf hash (security finding WS2-F4, fixed 2026-06-28).
    ///
    /// Per-vector layout (v2):
    ///   u32 BE modelID-length | modelID UTF-8 bytes | u32 BE vectorIndex |
    ///   u32 BE float-count | IEEE-754 LE floats
    static func canonicalLeafBytes(
        drawerId: UUID,
        content: [UInt8],
        vectors: [MerkleVectorInput],
        domainTag: UInt8
    ) -> [UInt8] {
        var bytes: [UInt8] = [domainTag]

        // Drawer id: 16 bytes big-endian UUID.
        bytes.append(contentsOf: uuidBytes(drawerId))

        // Content: u64 BE length prefix + UTF-8 bytes.
        appendU64BE(&bytes, UInt64(content.count))
        bytes.append(contentsOf: content)

        // Vectors: sorted by (modelID ascending, vectorIndex ascending).
        let sorted = vectors.sorted { a, b in
            if a.modelID != b.modelID { return a.modelID < b.modelID }
            return a.vectorIndex < b.vectorIndex
        }

        // u32 BE count prefix: number of vectors.
        appendU32BE(&bytes, UInt32(sorted.count))

        for vec in sorted {
            // v2 per-vector layout: write identity BEFORE floats so that
            // substituting a different model's embedding changes the hash.
            // modelID: u32 BE length prefix + UTF-8 bytes.
            let modelIDBytes = Array(vec.modelID.utf8)
            appendU32BE(&bytes, UInt32(modelIDBytes.count))
            bytes.append(contentsOf: modelIDBytes)
            // vectorIndex: u32 BE (multi-vector slot; 0 for single-vector models).
            appendU32BE(&bytes, vec.vectorIndex)
            // Float payload: u32 BE float count, then IEEE-754 LE floats.
            appendU32BE(&bytes, UInt32(vec.floats.count))
            for f in vec.floats {
                // IEEE-754 single-precision, little-endian per ADR-017 §16.
                var le = f.bitPattern.littleEndian
                withUnsafeBytes(of: &le) { bytes.append(contentsOf: $0) }
            }
        }

        return bytes
    }

    // MARK: - Helpers

    /// Extract UUID as 16 bytes in big-endian (RFC 4122) order.
    private static func uuidBytes(_ uuid: UUID) -> [UInt8] {
        withUnsafeBytes(of: uuid.uuid) { Array($0) }
    }

    private static func appendU64BE(_ buf: inout [UInt8], _ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            buf.append(UInt8((value >> shift) & 0xFF))
        }
    }

    private static func appendU32BE(_ buf: inout [UInt8], _ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            buf.append(UInt8((value >> shift) & 0xFF))
        }
    }
}
