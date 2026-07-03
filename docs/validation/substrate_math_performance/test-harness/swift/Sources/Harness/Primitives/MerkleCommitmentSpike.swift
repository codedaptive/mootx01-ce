// MerkleCommitmentSpike.swift
//
// The NT-P0 bakeoff's Merkle/commitment byte contract, RECOVERED from git
// history into the harness as harness-local support code.
//
// Provenance: this contract arrived with the bakeoff (d848a1950,
// "feat(nt-p0): Merkle/commitment contract") as
// SubstrateKernel/MerkleCommitment.swift and was correctly deleted from
// SubstrateKernel (a7ee72763) because the PRODUCTION Merkle implementation
// is SubstrateLib/MerkleHash.swift (NT-F2) — but that removal never chased
// the two harness consumers (MerkleCommitmentPrimitive, NTP0Bakeoff), which
// left this package uncompilable. The Rust harness never had the problem:
// its copy lives inside the harness (rust/src/primitives/merkle_commitment.rs).
// This file mirrors that layout for Swift: the bakeoff contract belongs to
// the bakeoff tooling, not to the substrate.
//
// Changes from the deleted spike (API drift since d848a1950):
//   • MerkleRoot(unchecked:) / ContentHash(unchecked:) → init(bytes:)
//   • MerkleRoot(contentHash:) → MerkleRoot(bytes: hash.bytes)
//   • the spike-era `KeyedCommitment` type (also deleted) is replaced by the
//     local `MerkleKeyedCommitment` below, shaped to what the harness reads
//     (.wireBytes, .keyVersion as UInt32)
//   • spike-era `.wireBytes` spellings on MerkleRoot/ContentHash are kept
//     working via the compatibility extensions at the bottom so the
//     consumer files stay verbatim to their bakeoff-era form.
//
// Hashing uses the in-repo SHA256 primitive; keyed commitments reuse
// GrantHKDF.hmac so there is only one HMAC-SHA256 construction in play.

import Foundation
import SubstrateKernel
import SubstrateTypes

public struct MerkleVectorPayload: Sendable, Hashable {
    public let modelID: String
    public let vectorIndex: UInt32
    public let values: [Float32]

    public init(modelID: String, vectorIndex: UInt32, values: [Float32]) {
        self.modelID = modelID
        self.vectorIndex = vectorIndex
        self.values = values
    }
}

public struct MerkleChild: Sendable, Hashable {
    public let childID: UUID
    public let root: MerkleRoot

    public init(childID: UUID, root: MerkleRoot) {
        self.childID = childID
        self.root = root
    }
}

/// Harness-local stand-in for the spike-era `KeyedCommitment` type (deleted
/// with the spike). Carries exactly what the harness consumers read: the
/// 32-byte HMAC (`wireBytes`) and the producing key version.
public struct MerkleKeyedCommitment: Sendable, Hashable {
    public let wireBytes: [UInt8]
    public let keyVersion: UInt32

    public init(wireBytes: [UInt8], keyVersion: UInt32) {
        precondition(wireBytes.count == 32,
                     "HMAC-SHA256 output must be exactly 32 bytes")
        self.wireBytes = wireBytes
        self.keyVersion = keyVersion
    }
}

public enum MerkleCommitment {
    public enum DomainTag {
        public static let leaf: UInt8 = 0x00
        public static let interior: UInt8 = 0x01
        public static let tombstone: UInt8 = 0x02
        public static let keyedCommitment: UInt8 = 0x03
    }

    /// Named empty-subtree payload. The empty root is SHA256 over
    /// the bare INTERIOR domain tag (a node with zero children).
    public static let emptyRootPayload: [UInt8] = [DomainTag.interior]

    public static let emptyRoot = MerkleRoot(
        bytes: SHA256.hash(emptyRootPayload)
    )

    /// Canonical leaf bytes:
    ///
    /// 1. leaf domain tag
    /// 2. drawer UUID raw 16-byte big-endian form
    /// 3. u64 big-endian byte length + NFC UTF-8 content bytes
    /// 4. u32 big-endian vector record count
    /// 5. vector records sorted by (modelID UTF-8 bytes, vectorIndex)
    ///
    /// Each vector record encodes modelID length+bytes, vectorIndex,
    /// value count, then each Float32 as IEEE-754 little-endian bytes.
    public static func canonicalLeafPayload(
        drawerID: UUID,
        content: String,
        vectors: [MerkleVectorPayload]
    ) -> [UInt8] {
        let nfc = content.precomposedStringWithCanonicalMapping
        return canonicalLeafPayload(
            drawerIDBytes: uuidBytes(drawerID),
            contentNFCUTF8: Array(nfc.utf8),
            vectors: vectors
        )
    }

    public static func canonicalLeafPayload(
        drawerIDBytes: [UInt8],
        contentNFCUTF8: [UInt8],
        vectors: [MerkleVectorPayload]
    ) -> [UInt8] {
        precondition(drawerIDBytes.count == 16, "drawerIDBytes must be 16 bytes")
        precondition(vectors.count <= Int(UInt32.max),
                     "too many vector records for u32 length prefix")

        var bytes = [UInt8]()
        bytes.reserveCapacity(1 + 16 + 8 + contentNFCUTF8.count + 4)
        bytes.append(DomainTag.leaf)
        bytes.append(contentsOf: drawerIDBytes)
        appendBigEndian(UInt64(contentNFCUTF8.count), to: &bytes)
        bytes.append(contentsOf: contentNFCUTF8)

        let ordered = vectors.sorted { lhs, rhs in
            let l = Array(lhs.modelID.utf8)
            let r = Array(rhs.modelID.utf8)
            if l != r { return lexicographicallyPrecedes(l, r) }
            return lhs.vectorIndex < rhs.vectorIndex
        }
        appendBigEndian(UInt32(ordered.count), to: &bytes)
        for vector in ordered {
            let modelBytes = Array(vector.modelID.utf8)
            precondition(modelBytes.count <= Int(UInt32.max),
                         "modelID too large for u32 length prefix")
            precondition(vector.values.count <= Int(UInt32.max),
                         "vector too large for u32 value count")
            appendBigEndian(UInt32(modelBytes.count), to: &bytes)
            bytes.append(contentsOf: modelBytes)
            appendBigEndian(vector.vectorIndex, to: &bytes)
            appendBigEndian(UInt32(vector.values.count), to: &bytes)
            for value in vector.values {
                appendLittleEndian(value.bitPattern, to: &bytes)
            }
        }
        return bytes
    }

    public static func leafHash(
        drawerID: UUID,
        content: String,
        vectors: [MerkleVectorPayload] = []
    ) -> ContentHash {
        let payload = canonicalLeafPayload(drawerID: drawerID, content: content, vectors: vectors)
        return ContentHash(bytes: SHA256.hash(payload))
    }

    public static func leafRoot(
        drawerID: UUID,
        content: String,
        vectors: [MerkleVectorPayload] = []
    ) -> MerkleRoot {
        MerkleRoot(bytes: leafHash(drawerID: drawerID, content: content, vectors: vectors).bytes)
    }

    public static func hashLeafPayload(_ payload: [UInt8]) -> ContentHash {
        precondition(payload.first == DomainTag.leaf,
                     "leaf payload must start with the leaf domain tag")
        return ContentHash(bytes: SHA256.hash(payload))
    }

    public static func rootForLeafPayload(_ payload: [UInt8]) -> MerkleRoot {
        MerkleRoot(bytes: hashLeafPayload(payload).bytes)
    }

    /// Canonical interior bytes: INTERIOR tag plus child roots in
    /// ascending child-id byte order.
    public static func canonicalInteriorPayload(children: [MerkleChild]) -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(1 + children.count * 32)
        bytes.append(DomainTag.interior)
        let ordered = children.sorted {
            lexicographicallyPrecedes(uuidBytes($0.childID), uuidBytes($1.childID))
        }
        for child in ordered {
            bytes.append(contentsOf: child.root.bytes)
        }
        return bytes
    }

    public static func interiorRoot(children: [MerkleChild]) -> MerkleRoot {
        MerkleRoot(bytes: SHA256.hash(canonicalInteriorPayload(children: children)))
    }

    public static func canonicalTombstonePayload(drawerID: UUID) -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(17)
        bytes.append(DomainTag.tombstone)
        bytes.append(contentsOf: uuidBytes(drawerID))
        return bytes
    }

    public static func tombstoneHash(drawerID: UUID) -> ContentHash {
        ContentHash(bytes: SHA256.hash(canonicalTombstonePayload(drawerID: drawerID)))
    }

    public static func tombstoneRoot(drawerID: UUID) -> MerkleRoot {
        MerkleRoot(bytes: tombstoneHash(drawerID: drawerID).bytes)
    }

    public static func keyedCommitment(
        drawerID: UUID,
        content: String,
        vectors: [MerkleVectorPayload] = [],
        key: [UInt8],
        keyVersion: UInt32
    ) -> MerkleKeyedCommitment {
        let payload = canonicalLeafPayload(drawerID: drawerID, content: content, vectors: vectors)
        return keyedCommitment(forCanonicalLeafPayload: payload, key: key, keyVersion: keyVersion)
    }

    public static func keyedCommitment(
        forCanonicalLeafPayload payload: [UInt8],
        key: [UInt8],
        keyVersion: UInt32
    ) -> MerkleKeyedCommitment {
        precondition(payload.first == DomainTag.leaf,
                     "keyed commitment input must be a canonical leaf payload")
        var committed = [UInt8]()
        committed.reserveCapacity(1 + payload.count)
        committed.append(DomainTag.keyedCommitment)
        committed.append(contentsOf: payload)
        let mac = GrantHKDF.hmac(key: key, data: committed)
        return MerkleKeyedCommitment(wireBytes: mac, keyVersion: keyVersion)
    }

    // MARK: - Encoding helpers

    public static func uuidBytes(_ uuid: UUID) -> [UInt8] {
        let u = uuid.uuid
        return [
            u.0, u.1, u.2, u.3,
            u.4, u.5, u.6, u.7,
            u.8, u.9, u.10, u.11,
            u.12, u.13, u.14, u.15,
        ]
    }

    private static func appendBigEndian(_ value: UInt64, to bytes: inout [UInt8]) {
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((value >> shift) & 0xFF))
        }
    }

    private static func appendBigEndian(_ value: UInt32, to bytes: inout [UInt8]) {
        for shift in stride(from: 24, through: 0, by: -8) {
            bytes.append(UInt8((value >> shift) & 0xFF))
        }
    }

    private static func appendLittleEndian(_ value: UInt32, to bytes: inout [UInt8]) {
        for shift in stride(from: 0, through: 24, by: 8) {
            bytes.append(UInt8((value >> shift) & 0xFF))
        }
    }

    private static func lexicographicallyPrecedes(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        for i in 0..<min(lhs.count, rhs.count) {
            if lhs[i] != rhs[i] { return lhs[i] < rhs[i] }
        }
        return lhs.count < rhs.count
    }
}

// MARK: - Spike-era spelling compatibility

/// The bakeoff-era consumer files (MerkleCommitmentPrimitive, NTP0Bakeoff)
/// call `.wireBytes` and `init(unchecked:)` on MerkleRoot and ContentHash;
/// the production types (post-NT-F2) spell them `.bytes` / `init(bytes:)`.
/// Harness-local aliases keep those files verbatim to their recorded
/// bakeoff form; the `unchecked:` spelling forwards to the validating
/// production init, so nothing is actually unchecked anymore.
extension MerkleRoot {
    public var wireBytes: [UInt8] { bytes }
    public init(unchecked bytes: [UInt8]) { self.init(bytes: bytes) }
}

extension ContentHash {
    public var wireBytes: [UInt8] { bytes }
    public init(unchecked bytes: [UInt8]) { self.init(bytes: bytes) }
}
