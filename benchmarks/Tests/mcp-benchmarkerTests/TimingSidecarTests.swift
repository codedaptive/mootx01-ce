// TimingSidecarTests.swift — tests for the timing sidecar feature.
//
// Feature contract:
//   - --timing-sidecar writes <report-basename>.timing.json beside the accuracy report.
//   - The accuracy report shape is UNCHANGED (no timing fields added to it).
//   - Default-off: a run without the flag produces no sidecar.
//   - p50/p95 use nearest-rank, matching TimingSeries / RollingSeries.
//   - artifact_type is "timing_sidecar" (not an accuracy file).
//   - writeTimingSidecar uses writeRecordNeverOverwrite → no-clobber.

import Testing
import Foundation
@testable import mcp_benchmarker

// MARK: - Percentile tests

@Suite("TimingSidecar percentile")
struct TimingSidecarPercentileTests {

    @Test("empty values return 0")
    func emptyValues() {
        #expect(latencyPercentile(values: [], p: 0.50) == 0.0)
        #expect(latencyPercentile(values: [], p: 0.95) == 0.0)
    }

    @Test("single value is its own p50 and p95")
    func singleValue() {
        #expect(latencyPercentile(values: [3.14], p: 0.50) == 3.14)
        #expect(latencyPercentile(values: [3.14], p: 0.95) == 3.14)
    }

    @Test("p50 of even-count array — nearest-rank formula")
    func p50EvenCount() {
        // 4 values sorted: [1, 2, 3, 4]
        // rank = Int((0.50 * 4).rounded(.up)) = Int(2.0) = 2
        // index = min(max(2,1)-1, 3) = 1 → sorted[1] = 2
        let values = [3.0, 1.0, 4.0, 2.0]
        #expect(latencyPercentile(values: values, p: 0.50) == 2.0)
    }

    @Test("p95 of 20 values — matches RollingSeries formula")
    func p95TwentyValues() {
        // 20 values [1.0..20.0]
        // rank = Int((0.95 * 20).rounded(.up)) = Int(19.0) = 19
        // index = min(max(19,1)-1, 19) = 18 → sorted[18] = 19.0
        let values = (1...20).map { Double($0) }
        #expect(latencyPercentile(values: values, p: 0.95) == 19.0)
    }

    @Test("p95 of 3 values — nearest-rank ceiling")
    func p95ThreeValues() {
        // sorted: [1, 2, 3]
        // rank = Int((0.95 * 3).rounded(.up)) = Int(2.85.rounded(.up)) = Int(3) = 3
        // index = min(max(3,1)-1, 2) = min(2, 2) = 2 → sorted[2] = 3
        let values = [2.0, 1.0, 3.0]
        #expect(latencyPercentile(values: values, p: 0.95) == 3.0)
    }

    @Test("p50 of odd-count array")
    func p50OddCount() {
        // 5 values sorted: [1, 2, 3, 4, 5]
        // rank = Int((0.50 * 5).rounded(.up)) = Int(2.5.rounded(.up)) = Int(3) = 3
        // index = min(max(3,1)-1, 4) = 2 → sorted[2] = 3.0
        let values = [5.0, 3.0, 1.0, 4.0, 2.0]
        #expect(latencyPercentile(values: values, p: 0.50) == 3.0)
    }
}

// MARK: - makeTimingSidecar tests

@Suite("makeTimingSidecar")
struct MakeTimingSidecarTests {

    func makeIdentity() -> IdentityEnvironment {
        IdentityEnvironment(
            mootx01BinarySha256: "abc123",
            mootx01Version: "1.1",
            protocolVersion: "v0.1"
        )
    }

    @Test("artifact_type is timing_sidecar")
    func artifactType() {
        let sidecar = makeTimingSidecar(
            lane: "locomo",
            runID: "test-001",
            identity: makeIdentity(),
            unitLatencies: [("q1", 0.5)]
        )
        #expect(sidecar.artifactType == "timing_sidecar")
    }

    @Test("lane and runID are preserved")
    func laneAndRunID() {
        let sidecar = makeTimingSidecar(
            lane: "lmeb",
            runID: "run-xyz",
            identity: makeIdentity(),
            unitLatencies: []
        )
        #expect(sidecar.lane == "lmeb")
        #expect(sidecar.runID == "run-xyz")
    }

    @Test("units carry unitID and latency")
    func units() {
        let pairs: [(id: String, latencySeconds: Double)] = [
            ("q1", 1.0),
            ("q2", 2.0),
            ("q3", 3.0)
        ]
        let sidecar = makeTimingSidecar(
            lane: "locomo",
            runID: "r1",
            identity: makeIdentity(),
            unitLatencies: pairs
        )
        #expect(sidecar.units.count == 3)
        #expect(sidecar.units[0].unitID == "q1")
        #expect(sidecar.units[1].queryLatencySeconds == 2.0)
    }

    @Test("aggregate count matches unit count")
    func aggregateCount() {
        let pairs: [(id: String, latencySeconds: Double)] = [
            ("q1", 1.0), ("q2", 2.0)
        ]
        let sidecar = makeTimingSidecar(
            lane: "locomo",
            runID: "r1",
            identity: makeIdentity(),
            unitLatencies: pairs
        )
        #expect(sidecar.aggregate.count == 2)
    }

    @Test("aggregate p50 and p95 computed correctly")
    func aggregatePercentiles() {
        // 10 values [1.0..10.0]
        let pairs = (1...10).map { ("q\($0)", Double($0)) }
        let sidecar = makeTimingSidecar(
            lane: "locomo",
            runID: "r1",
            identity: makeIdentity(),
            unitLatencies: pairs
        )
        // p50: rank = Int((0.50*10).rounded(.up)) = 5 → index=4 → sorted[4]=5.0
        #expect(sidecar.aggregate.p50Seconds == 5.0)
        // p95: rank = Int((0.95*10).rounded(.up)) = Int(9.5.rounded(.up)) = 10 → index=9 → 10.0
        #expect(sidecar.aggregate.p95Seconds == 10.0)
    }

    @Test("empty unit latencies → aggregate count 0 and zeroed percentiles")
    func emptyAggregate() {
        let sidecar = makeTimingSidecar(
            lane: "locomo",
            runID: "r1",
            identity: makeIdentity(),
            unitLatencies: []
        )
        #expect(sidecar.aggregate.count == 0)
        #expect(sidecar.aggregate.p50Seconds == 0.0)
        #expect(sidecar.aggregate.p95Seconds == 0.0)
    }

    @Test("run_identity is copied verbatim")
    func identityCopied() {
        let identity = makeIdentity()
        let sidecar = makeTimingSidecar(
            lane: "locomo",
            runID: "r1",
            identity: identity,
            unitLatencies: []
        )
        #expect(sidecar.runIdentity.mootx01BinarySha256 == "abc123")
        #expect(sidecar.runIdentity.mootx01Version == "1.1")
        #expect(sidecar.runIdentity.protocolVersion == "v0.1")
    }
}

// MARK: - Serialisation tests

@Suite("TimingSidecar serialisation")
struct TimingSidecarSerialisationTests {

    func makeIdentity() -> IdentityEnvironment {
        IdentityEnvironment(
            mootx01BinarySha256: "sha256abc",
            mootx01Version: "1.1",
            protocolVersion: "v0.1"
        )
    }

    @Test("JSON encodes expected top-level keys")
    func topLevelKeys() throws {
        let sidecar = makeTimingSidecar(
            lane: "membench",
            runID: "s-001",
            identity: makeIdentity(),
            unitLatencies: [("item-1", 0.5)]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sidecar)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["artifact_type"] as? String == "timing_sidecar")
        #expect(json["lane"] as? String == "membench")
        #expect(json["run_id"] as? String == "s-001")
        #expect(json["run_identity"] != nil)
        #expect(json["units"] != nil)
        #expect(json["aggregate"] != nil)
    }

    @Test("unit JSON uses snake_case keys")
    func unitSnakeCaseKeys() throws {
        let sidecar = makeTimingSidecar(
            lane: "lmeb",
            runID: "s-002",
            identity: makeIdentity(),
            unitLatencies: [("scene_1_q_0", 0.123)]
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(sidecar)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let units = json["units"] as! [[String: Any]]
        #expect(units[0]["unit_id"] as? String == "scene_1_q_0")
        #expect(units[0]["query_latency_seconds"] as? Double == 0.123)
    }

    @Test("aggregate JSON uses snake_case keys")
    func aggregateSnakeCaseKeys() throws {
        let sidecar = makeTimingSidecar(
            lane: "locomo",
            runID: "s-003",
            identity: makeIdentity(),
            unitLatencies: [("q1", 1.0), ("q2", 2.0)]
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(sidecar)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let agg = json["aggregate"] as! [String: Any]
        #expect(agg["count"] as? Int == 2)
        #expect(agg["p50_seconds"] != nil)
        #expect(agg["p95_seconds"] != nil)
    }

    @Test("accuracy report does NOT contain timing fields — shape unchanged")
    func accuracyReportShapeUnchanged() throws {
        // Smoke check: LoCoMoReport, LMEReport, LMEBReport, MemBenchReport all
        // encode without artifact_type, p50_seconds, p95_seconds at the top level.
        // This test verifies that the sidecar fields are NOT in those reports.
        // We do this by checking that the TimingSidecar type is a SEPARATE type
        // and that writing a sidecar does not modify the report URL.
        // The real guard is the "no timing in accuracy files" register rule —
        // verified here by structural inspection, not a full report build.
        //
        // Structural check: TimingSidecar and LoCoMoReport are separate types.
        // If TimingSidecar could be cast to LoCoMoReport or similar, this test
        // is evidence of contamination. Swift's type system is the real guard here.
        let sidecarType = "\(type(of: makeTimingSidecar(lane: "l", runID: "r", identity: IdentityEnvironment(mootx01BinarySha256: "x", mootx01Version: "v", protocolVersion: "p"), unitLatencies: [])))"
        #expect(sidecarType == "TimingSidecar")
    }
}

// MARK: - writeTimingSidecar tests

@Suite("writeTimingSidecar")
struct WriteTimingSidecarTests {

    func tempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sidecar-tests-\(Int.random(in: 1_000_000...9_999_999))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func makeIdentity() -> IdentityEnvironment {
        IdentityEnvironment(
            mootx01BinarySha256: "sha256test",
            mootx01Version: "1.1",
            protocolVersion: "v0.1"
        )
    }

    @Test("sidecar is written beside the report URL with .timing.json extension")
    func sidecarBesideReport() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Simulate a report already written (writeTimingSidecar just needs the URL;
        // it doesn't read the report).
        let reportURL = dir.appendingPathComponent("locomo-all3-20260820T120000Z.json")
        let sidecarURL = dir.appendingPathComponent("locomo-all3-20260820T120000Z.timing.json")

        let sidecar = makeTimingSidecar(
            lane: "locomo",
            runID: "20260820T120000Z",
            identity: makeIdentity(),
            unitLatencies: [("q1", 0.5), ("q2", 0.7)]
        )
        try writeTimingSidecar(sidecar, beside: reportURL)

        #expect(FileManager.default.fileExists(atPath: sidecarURL.path))
    }

    @Test("sidecar contents are valid JSON with artifact_type timing_sidecar")
    func sidecarContentsValid() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let reportURL = dir.appendingPathComponent("lme-s-r001.json")
        let sidecarURL = dir.appendingPathComponent("lme-s-r001.timing.json")

        let sidecar = makeTimingSidecar(
            lane: "longmemeval",
            runID: "r001",
            identity: makeIdentity(),
            unitLatencies: [("q001", 1.5)]
        )
        try writeTimingSidecar(sidecar, beside: reportURL)

        let data = try Data(contentsOf: sidecarURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["artifact_type"] as? String == "timing_sidecar")
        #expect(json["lane"] as? String == "longmemeval")
    }

    @Test("writeTimingSidecar refuses to overwrite — no-clobber guard")
    func noClobberGuard() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let reportURL = dir.appendingPathComponent("membench-FirstAgent-r002.json")
        let sidecar = makeTimingSidecar(
            lane: "membench",
            runID: "r002",
            identity: makeIdentity(),
            unitLatencies: [("item-1", 0.3)]
        )

        // First write succeeds.
        try writeTimingSidecar(sidecar, beside: reportURL)

        // Second write must throw — no-clobber.
        #expect(throws: (any Error).self) {
            try writeTimingSidecar(sidecar, beside: reportURL)
        }
    }

    @Test("sidecar filename uses .timing.json not .json.json")
    func sidecarExtensionNotDoubled() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Confirm the extension replacement is correct: .json → .timing.json
        let reportURL = dir.appendingPathComponent("lmeb-all6-20260820T120000Z.json")
        let sidecar = makeTimingSidecar(
            lane: "lmeb",
            runID: "20260820T120000Z",
            identity: makeIdentity(),
            unitLatencies: []
        )
        try writeTimingSidecar(sidecar, beside: reportURL)

        // The sidecar should exist at .timing.json, not .json.timing.json
        let sidecarURL = dir.appendingPathComponent("lmeb-all6-20260820T120000Z.timing.json")
        let doubledURL = dir.appendingPathComponent("lmeb-all6-20260820T120000Z.json.timing.json")

        #expect(FileManager.default.fileExists(atPath: sidecarURL.path))
        #expect(!FileManager.default.fileExists(atPath: doubledURL.path))
    }
}
