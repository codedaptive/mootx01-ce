// ContentHash.swift
//
// Typed 32-byte SHA-256 digest over a leaf payload (drawer
// content + vectors) per ADR-017 §16. ContentHash is semantically
// distinct from MerkleRoot — a content hash summarizes ONE
// payload, a Merkle root summarizes a subtree of children's
// hashes. The type system prevents mixing them.
//
// Shape mirrors Fingerprint256: fixed-size byte storage,
// Codable, Sendable, Equatable, Hashable, hex display,
// init(bytes:), bytes accessor.

import Foundation

/// 32-byte SHA-256 content hash of a leaf payload.
///
/// ContentHash is the substrate's per-drawer integrity
/// fingerprint. It is NOT a Merkle root; see `MerkleRoot`
/// for the subtree-summary type.
public struct ContentHash: Hashable, Sendable, Codable, CustomStringConvertible {

    /// Raw 32-byte storage. Private to enforce fixed size.
    private var storage: [UInt8]

    /// Creates a ContentHash from exactly 32 bytes.
    public init(bytes: [UInt8]) {
        precondition(bytes.count == 32,
                     "ContentHash requires exactly 32 bytes")
        self.storage = bytes
    }

    /// The raw 32 bytes of the hash.
    public var bytes: [UInt8] { storage }

    // MARK: - Named constants

    /// Sentinel hash for a tombstoned (expunged) drawer payload.
    ///
    /// SHA-256 of the bare TOMBSTONE domain tag byte (0x02).
    /// Per ADR-017 §16 and the I-25 layering constraint, this is
    /// a byte literal — SubstrateTypes (layer 1) cannot import
    /// SubstrateKernel (layer 2) to compute it at runtime.
    /// A SubstrateKernel bridge test verifies the literal equals
    /// SHA256.hash([MerkleDomain.tombstone]).
    public static let tombstone = ContentHash(bytes: [
        0xdb, 0xc1, 0xb4, 0xc9, 0x00, 0xff, 0xe4, 0x8d,
        0x57, 0x5b, 0x5d, 0xa5, 0xc6, 0x38, 0x04, 0x01,
        0x25, 0xf6, 0x5d, 0xb0, 0xfe, 0x3e, 0x24, 0x49,
        0x4b, 0x76, 0xea, 0x98, 0x64, 0x57, 0xd9, 0x86,
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
            throw ContentHashError.invalidHexLength(hex.count)
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        var index = hex.startIndex
        for _ in 0..<32 {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                throw ContentHashError.invalidHexCharacter
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

/// Errors for ContentHash construction from external input.
public enum ContentHashError: Error, Sendable {
    case invalidHexLength(Int)
    case invalidHexCharacter
}
