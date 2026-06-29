// MerkleRoot.swift
//
// Typed 32-byte root hash of an interior node's children per
// ADR-017 §16. MerkleRoot is semantically distinct from
// ContentHash — a root summarizes a subtree of children's
// hashes, a content hash summarizes one leaf payload. The type
// system prevents substituting one for the other.

import Foundation

/// 32-byte Merkle root hash of a subtree (room, wing, or estate).
///
/// MerkleRoot is the substrate's per-node integrity summary.
/// It is NOT a content hash; see `ContentHash` for the leaf
/// payload digest.
public struct MerkleRoot: Hashable, Sendable, Codable, CustomStringConvertible {

    /// Raw 32-byte storage. Private to enforce fixed size.
    private var storage: [UInt8]

    /// Creates a MerkleRoot from exactly 32 bytes.
    public init(bytes: [UInt8]) {
        precondition(bytes.count == 32,
                     "MerkleRoot requires exactly 32 bytes")
        self.storage = bytes
    }

    /// The raw 32 bytes of the root hash.
    public var bytes: [UInt8] { storage }

    // MARK: - Named constants

    /// Root hash of an empty subtree (a node with no live children).
    ///
    /// SHA-256 of the bare INTERIOR domain tag byte (0x01).
    /// Per the I-25 layering constraint, this is a byte literal —
    /// SubstrateTypes (layer 1) cannot import SubstrateKernel
    /// (layer 2) to compute it at runtime. A SubstrateKernel
    /// bridge test verifies the literal equals
    /// SHA256.hash([MerkleDomain.interior]).
    public static let empty = MerkleRoot(bytes: [
        0x4b, 0xf5, 0x12, 0x2f, 0x34, 0x45, 0x54, 0xc5,
        0x3b, 0xde, 0x2e, 0xbb, 0x8c, 0xd2, 0xb7, 0xe3,
        0xd1, 0x60, 0x0a, 0xd6, 0x31, 0xc3, 0x85, 0xa5,
        0xd7, 0xcc, 0xe2, 0x3c, 0x77, 0x85, 0x45, 0x9a,
    ])

    // MARK: - Hex display

    /// Lowercase hex string representation of the 32 bytes.
    public var hexString: String {
        storage.map { String(format: "%02x", $0) }.joined()
    }

    public var description: String { hexString }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hex = try container.decode(String.self)
        guard hex.count == 64 else {
            throw MerkleRootError.invalidHexLength(hex.count)
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        var index = hex.startIndex
        for _ in 0..<32 {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                throw MerkleRootError.invalidHexCharacter
            }
            bytes.append(byte)
            index = nextIndex
        }
        self.storage = bytes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexString)
    }
}

/// Errors for MerkleRoot construction from external input.
public enum MerkleRootError: Error, Sendable {
    case invalidHexLength(Int)
    case invalidHexCharacter
}
