// BlockMaskTests.swift
//
// Per-type suite for BlockMask, the OptionSet<UInt8> over the four
// Fingerprint256 blocks. The Rust side carries the equivalent as the
// u8 constants BLOCK_0..BLOCK_3 / ALL_BLOCKS exercised through
// hamming.rs::block_restricted_distance; this suite asserts the typed
// mask directly (raw values, .all/.none, blockCount, contains, Codable).

import Foundation
import Testing
@testable import SubstrateTypes

@Suite("BlockMask option set")
struct BlockMaskTests {

    @Test("single-block raw values are the four low bits")
    func singleBlockRawValues() {
        #expect(BlockMask.block0.rawValue == 0b0001)
        #expect(BlockMask.block1.rawValue == 0b0010)
        #expect(BlockMask.block2.rawValue == 0b0100)
        #expect(BlockMask.block3.rawValue == 0b1000)
    }

    @Test(".all selects every block; .none selects none")
    func allAndNone() {
        #expect(BlockMask.all.rawValue == 0b1111)
        #expect(BlockMask.none.rawValue == 0)
        #expect(BlockMask.all == [.block0, .block1, .block2, .block3])
    }

    @Test("blockCount is the population count of the mask")
    func blockCountIsPopcount() {
        #expect(BlockMask.none.blockCount == 0)
        #expect(BlockMask.block0.blockCount == 1)
        #expect(([.block0, .block2] as BlockMask).blockCount == 2)
        #expect(BlockMask.all.blockCount == 4)
    }

    @Test("contains reflects set membership")
    func containsMembership() {
        let m: BlockMask = [.block1, .block3]
        #expect(m.contains(.block1))
        #expect(m.contains(.block3))
        #expect(!m.contains(.block0))
        #expect(!m.contains(.block2))
    }

    @Test("Codable round-trips through its raw value")
    func codableRoundTrip() throws {
        let m: BlockMask = [.block0, .block2, .block3]
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(BlockMask.self, from: data)
        #expect(back == m)
    }
}
