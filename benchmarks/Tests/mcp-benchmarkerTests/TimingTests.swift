import XCTest
@testable import mcp_benchmarker

final class TimingTests: XCTestCase {

    // 11. A series reports mean and p95 correctly over a known sample set.
    func testMeanAndP95() {
        var s = TimingSeries()
        for v in 1...10 { s.record(Double(v)) }
        XCTAssertEqual(s.count, 10)
        // mean of 1...10 = 5.5
        XCTAssertEqual(s.mean, 5.5, accuracy: 1e-9)
        // p95 (nearest-rank): ceil(0.95 * 10) = 10th sample = 10.0
        XCTAssertEqual(s.p95, 10.0, accuracy: 1e-9)
    }

    // 12. The three named series are tracked independently.
    func testThreeSeriesIndependent() {
        var c = TimingCollection()
        c.record(1.0, into: .capture)
        c.record(2.0, into: .capture)
        c.record(5.0, into: .recall)
        XCTAssertEqual(c.series(.capture).count, 2)
        XCTAssertEqual(c.series(.recall).count, 1)
        XCTAssertEqual(c.series(.verification).count, 0)
        XCTAssertEqual(c.series(.capture).mean, 1.5, accuracy: 1e-9)
    }
}
