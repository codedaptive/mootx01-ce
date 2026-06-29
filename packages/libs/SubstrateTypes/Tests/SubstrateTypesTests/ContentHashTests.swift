import Testing
import Foundation
@testable import SubstrateTypes

@Suite("ContentHash typed 32-byte digest")
struct ContentHashTests {

    @Test func roundTripBytes() {
        let bytes = [UInt8](repeating: 0xab, count: 32)
        let hash = ContentHash(bytes: bytes)
        #expect(hash.bytes == bytes)
    }

    @Test func hexDisplay() {
        let hash = ContentHash(bytes: [UInt8](repeating: 0, count: 32))
        #expect(hash.hexString == String(repeating: "00", count: 32))
    }

    @Test func codableRoundTrip() throws {
        let original = ContentHash(bytes: [
            0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
            0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
            0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
            0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ContentHash.self, from: data)
        #expect(original == decoded)
    }

    @Test func equality() {
        let a = ContentHash(bytes: [UInt8](repeating: 1, count: 32))
        let b = ContentHash(bytes: [UInt8](repeating: 1, count: 32))
        let c = ContentHash(bytes: [UInt8](repeating: 2, count: 32))
        #expect(a == b)
        #expect(a != c)
    }

    @Test func tombstoneConstant() {
        // SHA-256 of [0x02] (TOMBSTONE domain tag)
        let expected: [UInt8] = [
            0xdb, 0xc1, 0xb4, 0xc9, 0x00, 0xff, 0xe4, 0x8d,
            0x57, 0x5b, 0x5d, 0xa5, 0xc6, 0x38, 0x04, 0x01,
            0x25, 0xf6, 0x5d, 0xb0, 0xfe, 0x3e, 0x24, 0x49,
            0x4b, 0x76, 0xea, 0x98, 0x64, 0x57, 0xd9, 0x86,
        ]
        #expect(ContentHash.tombstone.bytes == expected)
    }

    @Test func tombstoneHexIsStable() {
        #expect(ContentHash.tombstone.hexString ==
            "dbc1b4c900ffe48d575b5da5c638040125f65db0fe3e24494b76ea986457d986")
    }

    @Test func hashableConformance() {
        let a = ContentHash(bytes: [UInt8](repeating: 0x42, count: 32))
        let b = ContentHash(bytes: [UInt8](repeating: 0x42, count: 32))
        let set: Set<ContentHash> = [a, b]
        #expect(set.count == 1)
    }

    @Test func descriptionIsHex() {
        let hash = ContentHash(bytes: [UInt8](repeating: 0xff, count: 32))
        #expect(hash.description == String(repeating: "ff", count: 32))
    }
}
