import Testing
import Foundation
@testable import SubstrateTypes

@Suite("MerkleRoot typed 32-byte root hash")
struct MerkleRootTests {

    @Test func roundTripBytes() {
        let bytes = [UInt8](repeating: 0xcd, count: 32)
        let root = MerkleRoot(bytes: bytes)
        #expect(root.bytes == bytes)
    }

    @Test func hexDisplay() {
        let root = MerkleRoot(bytes: [UInt8](repeating: 0, count: 32))
        #expect(root.hexString == String(repeating: "00", count: 32))
    }

    @Test func codableRoundTrip() throws {
        let original = MerkleRoot(bytes: [
            0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
            0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
            0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
            0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MerkleRoot.self, from: data)
        #expect(original == decoded)
    }

    @Test func equality() {
        let a = MerkleRoot(bytes: [UInt8](repeating: 1, count: 32))
        let b = MerkleRoot(bytes: [UInt8](repeating: 1, count: 32))
        let c = MerkleRoot(bytes: [UInt8](repeating: 2, count: 32))
        #expect(a == b)
        #expect(a != c)
    }

    @Test func emptyConstant() {
        // SHA-256 of [0x01] (INTERIOR domain tag)
        let expected: [UInt8] = [
            0x4b, 0xf5, 0x12, 0x2f, 0x34, 0x45, 0x54, 0xc5,
            0x3b, 0xde, 0x2e, 0xbb, 0x8c, 0xd2, 0xb7, 0xe3,
            0xd1, 0x60, 0x0a, 0xd6, 0x31, 0xc3, 0x85, 0xa5,
            0xd7, 0xcc, 0xe2, 0x3c, 0x77, 0x85, 0x45, 0x9a,
        ]
        #expect(MerkleRoot.empty.bytes == expected)
    }

    @Test func emptyHexIsStable() {
        #expect(MerkleRoot.empty.hexString ==
            "4bf5122f344554c53bde2ebb8cd2b7e3d1600ad631c385a5d7cce23c7785459a")
    }

    @Test func contentHashAndMerkleRootAreDistinctTypes() {
        // Compile-time: can't assign ContentHash to MerkleRoot
        // Runtime: sentinel constants have different byte values
        #expect(ContentHash.tombstone.bytes != MerkleRoot.empty.bytes)
    }

    @Test func hashableConformance() {
        let a = MerkleRoot(bytes: [UInt8](repeating: 0x42, count: 32))
        let b = MerkleRoot(bytes: [UInt8](repeating: 0x42, count: 32))
        let set: Set<MerkleRoot> = [a, b]
        #expect(set.count == 1)
    }
}
