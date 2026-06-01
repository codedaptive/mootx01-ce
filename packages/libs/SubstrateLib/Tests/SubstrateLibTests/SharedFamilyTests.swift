import Foundation
import Testing
@testable import SubstrateLib
import SubstrateML
import SubstrateKernel
import SubstrateTypes

/// Tests for the shared and local hyperplane family generation. They
/// pin the fix to generateSharedFamily, which had reused one base seed
/// across all four blocks (collapsing them) and a uniform 64-bit input
/// width. The family set is now built through the canonical
/// blockFamilies routine, per-block diversified seeds and the widths
/// [192, 64, 64, 64], the same routine the estate-local families use.
@Suite("Shared + local hyperplane family generation")
struct SharedFamilyTests {

    private let estateA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let estateB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func nonce() -> PairingNonce {
        PairingNonce(bytes: (0..<32).map { UInt8($0) })
    }

    @Test func testSharedFamilyHasCanonicalWidths() {
        let fams = PairingHandshake.generateSharedFamily(
            nonce: nonce(), estateA: estateA, estateB: estateB)
        #expect(fams.map { $0.inputBitLength } == [192, 64, 64, 64])
    }

    @Test func testSharedFamilyBlocksAreDistinct() {
        let fams = PairingHandshake.generateSharedFamily(
            nonce: nonce(), estateA: estateA, estateB: estateB)
        let hashes = Set(fams.map { $0.canonicalHash() })
        #expect(hashes.count == 4, "the four shared families must be distinct")
    }

    @Test func testSharedFamilyIsOrderIndependentAndDeterministic() {
        let ab = PairingHandshake.generateSharedFamily(
            nonce: nonce(), estateA: estateA, estateB: estateB)
        let ba = PairingHandshake.generateSharedFamily(
            nonce: nonce(), estateA: estateB, estateB: estateA)
        #expect(ab.map { $0.canonicalHash() } == ba.map { $0.canonicalHash() })
    }

    @Test func testSharedFamilyMatchesCanonicalRoutine() {
        let n = nonce()
        let base = HyperplaneFamily.expandSeed64(
            n.seedWith(estateA: estateA, estateB: estateB))
        let direct = HyperplaneFamily.blockFamilies(baseSeed: base)
        let shared = PairingHandshake.generateSharedFamily(
            nonce: n, estateA: estateA, estateB: estateB)
        #expect(shared.map { $0.canonicalHash() } == direct.map { $0.canonicalHash() })
    }

    @Test func testBlockFamiliesDiversifiesSeedsPerBlock() {
        let base = [UInt8](repeating: 7, count: 32)
        let seeds = (0..<4).map { HyperplaneFamily.diversifiedSeed(base: base, blockIndex: $0) }
        #expect(Set(seeds).count == 4, "each block must get a distinct seed")
        #expect(seeds.allSatisfy { $0.count == 32 })
    }
}
