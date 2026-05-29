import XCTest
@testable import SubstrateTypes

/// SubstrateTypes package-level smoke test. Confirms the public
/// surface is importable and the type system links up correctly.
/// Algorithm-specific tests live in dedicated files
/// (Fingerprint256CombinatorsTests, etc.) or in the conformance
/// harness at docs/validation/substrate_math_performance/.
final class SubstrateTypesTests: XCTestCase {
    func testFingerprint256ZeroIsCanonical() {
        let zero = Fingerprint256.zero
        XCTAssertEqual(zero.words, [0, 0, 0, 0])
        XCTAssertEqual(zero.popcount(), 0)
    }

    func testHLCOrderingIsTotal() {
        let a = HLC(physicalTime: 1000, logicalCount: 0, nodeID: 1)
        let b = HLC(physicalTime: 1000, logicalCount: 1, nodeID: 1)
        let c = HLC(physicalTime: 1001, logicalCount: 0, nodeID: 1)
        XCTAssertLessThan(a, b)
        XCTAssertLessThan(b, c)
        XCTAssertLessThan(a, c)
    }

    func testRowIdIsUUIDTypealias() {
        // Lockstep contract (Swift leads): the Rust port has
        // pub struct RowId(pub u128); Swift has typealias RowId = UUID;
        // both are byte-identical at the wire level.
        let id: RowId = UUID()
        XCTAssertEqual(MemoryLayout.size(ofValue: id), 16)
    }
}
