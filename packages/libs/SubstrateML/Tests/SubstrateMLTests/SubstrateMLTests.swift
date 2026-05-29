import XCTest
@testable import SubstrateML
import SubstrateKernel
import SubstrateTypes

/// SubstrateML package-level smoke test. Confirms the ML surface
/// is importable. Algorithm-specific tests live in dedicated files
/// (FloatSimHashTests, plus the four-way conformance harness at
/// docs/validation/substrate_math_performance/).
final class SubstrateMLTests: XCTestCase {
    func testFloatSimHashIsDeterministic() {
        // FloatSimHash is one of the 15 ML primitives migrated in
        // Phase 6.9c. Two runs with identical inputs must produce
        // identical output — guards against accidental mutable state
        // or RNG leakage.
        let v: [Float] = (0..<384).map { Float($0) / 384.0 - 0.5 }
        let a = FloatSimHash.project(vector: v, seed: 0xDEAD_BEEF)
        let b = FloatSimHash.project(vector: v, seed: 0xDEAD_BEEF)
        XCTAssertEqual(a, b)
    }
}
