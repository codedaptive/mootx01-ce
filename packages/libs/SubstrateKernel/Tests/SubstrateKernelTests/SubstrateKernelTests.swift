import XCTest
@testable import SubstrateKernel
import SubstrateTypes

/// SubstrateKernel package-level smoke test. Confirms the kernel
/// protocol is importable and ScalarKernel produces deterministic
/// output. Full bit-identical conformance against vector files
/// lives in docs/validation/substrate_math_performance/.
final class SubstrateKernelTests: XCTestCase {
    func testScalarKernelHammingDistanceMatchesXorPopcount() {
        let a = Fingerprint256(block0: 0xAAAA_AAAA_AAAA_AAAA, block1: 0, block2: 0, block3: 0)
        let b = Fingerprint256(block0: 0x5555_5555_5555_5555, block1: 0, block2: 0, block3: 0)
        // Every bit differs in word 0 → 64 bit differences.
        XCTAssertEqual(ScalarKernel().hammingDistance256(a, b), 64)
    }

    func testScalarKernelOrReduceIsCommutative() {
        let xs = [
            Fingerprint256(block0: 0x1, block1: 0x2, block2: 0x4, block3: 0x8),
            Fingerprint256(block0: 0x10, block1: 0x20, block2: 0x40, block3: 0x80),
            Fingerprint256(block0: 0x100, block1: 0x200, block2: 0x400, block3: 0x800),
        ]
        let forward  = ScalarKernel().orReduce256(xs)
        let reverse  = ScalarKernel().orReduce256(xs.reversed())
        XCTAssertEqual(forward, reverse)
    }
}
