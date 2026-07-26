import XCTest
@testable import mcp_benchmarker

final class ManifestTests: XCTestCase {

    // 8. record + contains: true for a recorded id, false otherwise.
    func testContains() {
        var m = Manifest()
        m.record(ManifestEntry(id: "1", content: "hello",
                               transferredAt: "2026-05-25T00:00:00Z", outcome: .transferred))
        XCTAssertTrue(m.contains(id: "1"))
        XCTAssertFalse(m.contains(id: "2"))
    }

    // 9. One verification query per recorded entry, each naming its rank-1 id.
    func testVerificationQueriesOnePerEntry() {
        var m = Manifest()
        let verbMap = EndpointConfig.VerbMap(write: "capture", query: "recall", list: nil)
        for i in 1...3 {
            m.record(ManifestEntry(id: "\(i)", content: "c\(i)",
                                   transferredAt: "2026-05-25T00:00:0\(i)Z", outcome: .transferred))
        }
        let queries = m.verificationQueries(verbMap: verbMap)
        XCTAssertEqual(queries.count, 3)
        XCTAssertEqual(Set(queries.map(\.expectedRank1ID)), ["1", "2", "3"])
        for q in queries {
            XCTAssertEqual(q.queryTool, "recall")
        }
    }

    // 10. Manifest JSON round-trips: encode then decode yields an equal manifest.
    func testManifestRoundTrips() throws {
        var m = Manifest()
        m.record(ManifestEntry(id: "1", content: "hello",
                               transferredAt: "2026-05-25T00:00:00Z", outcome: .transferred))
        m.record(ManifestEntry(id: "2", content: "world",
                               transferredAt: "2026-05-25T00:00:01Z", outcome: .failed))
        let data = try JSONEncoder().encode(m)
        let decoded = try JSONDecoder().decode(Manifest.self, from: data)
        XCTAssertEqual(m, decoded)
    }
}
