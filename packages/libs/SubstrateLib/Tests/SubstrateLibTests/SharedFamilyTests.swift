import XCTest
@testable import SubstrateLib

/// Tests for the shared and local hyperplane family generation. They
/// pin the fix to generateSharedFamily, which had reused one base seed
/// across all four blocks (collapsing them) and a uniform 64-bit input
/// width. The family set is now built through the canonical
/// blockFamilies routine, per-block diversified seeds and the widths
/// [192, 64, 64, 64], the same routine the estate-local families use.
final class SharedFamilyTests: XCTestCase {

    private let estateA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let estateB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func nonce() -> PairingNonce {
        PairingNonce(bytes: (0..<32).map { UInt8($0) })
    }

    func testSharedFamilyHasCanonicalWidths() {
        let fams = PairingHandshake.generateSharedFamily(
            nonce: nonce(), estateA: estateA, estateB: estateB)
        XCTAssertEqual(fams.map { $0.inputBitLength }, [192, 64, 64, 64])
    }

    func testSharedFamilyBlocksAreDistinct() {
        let fams = PairingHandshake.generateSharedFamily(
            nonce: nonce(), estateA: estateA, estateB: estateB)
        let hashes = Set(fams.map { $0.canonicalHash() })
        XCTAssertEqual(hashes.count, 4, "the four shared families must be distinct")
    }

    func testSharedFamilyIsOrderIndependentAndDeterministic() {
        let ab = PairingHandshake.generateSharedFamily(
            nonce: nonce(), estateA: estateA, estateB: estateB)
        let ba = PairingHandshake.generateSharedFamily(
            nonce: nonce(), estateA: estateB, estateB: estateA)
        XCTAssertEqual(ab.map { $0.canonicalHash() }, ba.map { $0.canonicalHash() })
    }

    func testSharedFamilyMatchesCanonicalRoutine() {
        let n = nonce()
        let base = HyperplaneFamily.expandSeed64(
            n.seedWith(estateA: estateA, estateB: estateB))
        let direct = HyperplaneFamily.blockFamilies(baseSeed: base)
        let shared = PairingHandshake.generateSharedFamily(
            nonce: n, estateA: estateA, estateB: estateB)
        XCTAssertEqual(shared.map { $0.canonicalHash() }, direct.map { $0.canonicalHash() })
    }

    func testBlockFamiliesDiversifiesSeedsPerBlock() {
        let base = [UInt8](repeating: 7, count: 32)
        let seeds = (0..<4).map { HyperplaneFamily.diversifiedSeed(base: base, blockIndex: $0) }
        XCTAssertEqual(Set(seeds).count, 4, "each block must get a distinct seed")
        XCTAssertTrue(seeds.allSatisfy { $0.count == 32 })
    }
}
