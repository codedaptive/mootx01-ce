import XCTest
@testable import mcp_benchmarker

final class DivergenceTests: XCTestCase {

    // 4. Jaccard: identical sets → 0.0; fully disjoint → 1.0.
    func testJaccardIdenticalAndDisjoint() {
        XCTAssertEqual(jaccardDivergence(expected: ["a", "b", "c"], got: ["a", "b", "c"]),
                       0.0, accuracy: 1e-9)
        XCTAssertEqual(jaccardDivergence(expected: ["a", "b"], got: ["c", "d"]),
                       1.0, accuracy: 1e-9)
    }

    // 5. Jaccard: partial overlap → strictly in (0.0, 1.0).
    func testJaccardPartialOverlap() {
        // intersection {b,c}=2, union {a,b,c,d}=4 → similarity 0.5 → divergence 0.5
        let d = jaccardDivergence(expected: ["a", "b", "c"], got: ["b", "c", "d"])
        XCTAssertGreaterThan(d, 0.0)
        XCTAssertLessThan(d, 1.0)
        XCTAssertEqual(d, 0.5, accuracy: 1e-9)
    }

    // 6. Rank: identical order → 0.0; fully reversed → 1.0.
    func testRankIdenticalAndReversed() {
        XCTAssertEqual(rankDivergence(expected: ["a", "b", "c", "d"], got: ["a", "b", "c", "d"]),
                       0.0, accuracy: 1e-9)
        XCTAssertEqual(rankDivergence(expected: ["a", "b", "c", "d"], got: ["d", "c", "b", "a"]),
                       1.0, accuracy: 1e-9)
    }

    // 7. Rank: IDs present in one ranking only are ignored (shared-ID intersection).
    func testRankIgnoresNonSharedIDs() {
        // shared = {a,b,c}; extras x,y in `got` do not perturb the shared order
        let d = rankDivergence(expected: ["a", "b", "c"], got: ["x", "a", "y", "b", "c"])
        XCTAssertEqual(d, 0.0, accuracy: 1e-9)
        // shared order reversed despite an extra non-shared id
        let d2 = rankDivergence(expected: ["a", "b", "c"], got: ["c", "b", "a", "z"])
        XCTAssertEqual(d2, 1.0, accuracy: 1e-9)
    }
}
