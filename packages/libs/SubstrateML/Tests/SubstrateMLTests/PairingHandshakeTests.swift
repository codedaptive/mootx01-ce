// PairingHandshakeTests.swift
//
// Pairing handshake per cookbook § 12.2 / paper § 9.2. swift-testing
// peer suite for Sources/SubstrateML/PairingHandshake.swift, mirroring
// rust/src/pairing.rs. Rust's estate ids are [u8; 16]; the Swift
// surface keys on UUID, so the [0x11; 16] / [0x22; 16] estates map to
// the corresponding all-0x11 / all-0x22 UUIDs.
//
// Parity note: the Rust `diversified_seeds_differ_per_block` test
// calls `HyperplaneFamily::diversified_seed` directly — that is a
// SubstrateTypes internal, not part of SubstrateML's public surface,
// so its direct unit test belongs to the SubstrateTypes test leg.
// The underlying property (distinct per-block seeds) is exercised
// here through the public surface by `sharedFamilyBlocksAreDistinct`:
// distinct block hashes can only arise from distinct block seeds.

import Foundation
import Testing
import SubstrateTypes
@testable import SubstrateML

@Suite("PairingHandshake shared family")
struct PairingHandshakeTests {

    private func nonce() -> PairingNonce {
        PairingNonce(bytes: (0..<32).map { UInt8($0) })
    }
    private func estateA() -> UUID { UUID(uuid: (0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11,
                                                 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11)) }
    private func estateB() -> UUID { UUID(uuid: (0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22,
                                                 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22)) }

    @Test("the shared family has the canonical block widths [192, 64, 64, 64]")
    func sharedFamilyHasCanonicalWidths() {
        let fams = PairingHandshake.generateSharedFamily(
            nonce: nonce(), estateA: estateA(), estateB: estateB(), density: 1.0)
        #expect(fams.map { $0.inputBitLength } == [192, 64, 64, 64])
    }

    @Test("the four shared families are distinct")
    func sharedFamilyBlocksAreDistinct() {
        let fams = PairingHandshake.generateSharedFamily(
            nonce: nonce(), estateA: estateA(), estateB: estateB(), density: 1.0)
        let distinct = Set(fams.map { $0.canonicalHash() })
        #expect(distinct.count == 4)
    }

    @Test("the shared family is independent of estate argument order")
    func sharedFamilyIsOrderIndependent() {
        let ab = PairingHandshake.generateSharedFamily(
            nonce: nonce(), estateA: estateA(), estateB: estateB(), density: 1.0)
        let ba = PairingHandshake.generateSharedFamily(
            nonce: nonce(), estateA: estateB(), estateB: estateA(), density: 1.0)
        #expect(ab.map { $0.canonicalHash() } == ba.map { $0.canonicalHash() })
    }
}
