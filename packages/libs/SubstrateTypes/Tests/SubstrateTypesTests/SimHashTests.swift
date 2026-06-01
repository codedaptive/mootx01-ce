// SimHashTests.swift
//
// Per-type suite for SimHash (block construction) and SimHashInput
// (canonical per-block input assembly). Mirrors the Rust `simhash.rs`
// inline #[test] set: determinism, block3_layout_roundtrip.

import Testing
@testable import SubstrateTypes

@Suite("SimHash block + input assembly")
struct SimHashTests {

    @Test("block(over:family:) is deterministic for a fixed family + input")
    func determinism() {
        let seed = [UInt8](repeating: 0x5A, count: 32)
        let h0 = HyperplaneFamily.generate(seed: seed, blockIndex: 0,
                                            inputBitLength: 192, density: 1.0)
        let v: [UInt64] = [0x12345, 0x67890, 0xABCDEF]
        #expect(SimHash.block(over: v, family: h0) == SimHash.block(over: v, family: h0))
    }

    @Test("channelSource lays fields out at the documented bit offsets")
    func block3LayoutRoundtrip() {
        // channel=5 (bits 0–5), sourceType=2 (bits 6–11),
        // sensitivity=32 (bits 18–23).
        let v = SimHashInput.channelSource(channel: 5, sourceType: 2,
                                           captureChannel: 1, sensitivity: 32,
                                           estateUUIDHash: 0xAB,
                                           streamSourceBitset: 0x1234_5678)
        #expect(v[0] & 0x3F == 5)
        #expect((v[0] >> 6) & 0x3F == 2)
        #expect((v[0] >> 18) & 0x3F == 32)
    }

    @Test("fingerprint assembles four blocks from four families")
    func fingerprintAssemblesFourBlocks() {
        let seed = [UInt8](repeating: 0x11, count: 32)
        let families = HyperplaneFamily.blockFamilies(baseSeed: seed)
        let fp = SimHash.fingerprint(
            bitmapInput: [1, 2, 3],
            latticeInput: [4],
            lineageTemporalInput: [5],
            channelSourceInput: [6],
            families: families)
        // Each block is computed by the canonical block(over:family:).
        #expect(fp.block0 == SimHash.block(over: [1, 2, 3], family: families[0]))
        #expect(fp.block1 == SimHash.block(over: [4], family: families[1]))
        #expect(fp.block2 == SimHash.block(over: [5], family: families[2]))
        #expect(fp.block3 == SimHash.block(over: [6], family: families[3]))
    }

    @Test("identical inputs across replicas produce identical fingerprints")
    func crossReplicaDeterminism() {
        // Same seed → same families → bit-identical fingerprint (the
        // CRDT-convergence property, cookbook §3.6 conformance note 1).
        let seed = [UInt8](repeating: 0x3C, count: 32)
        let f1 = HyperplaneFamily.blockFamilies(baseSeed: seed)
        let f2 = HyperplaneFamily.blockFamilies(baseSeed: seed)
        let lattice = SimHashInput.lattice(udcPrefixHash: 0xBEEF,
                                           qidDirectHash: 0xCAFE,
                                           qidClosureHash: 0x1234_5678)
        #expect(SimHash.block(over: lattice, family: f1[1])
                == SimHash.block(over: lattice, family: f2[1]))
    }
}
