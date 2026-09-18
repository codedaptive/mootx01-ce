// ThroughputRunnerTests.swift — tests for the throughput subcommand output types.
//
// Throughput mode contract:
//   - Output filename: throughput-<lane>-<serial>.json
//   - artifact_type = "throughput" (never an accuracy file)
//   - No recall figures (no any@k, mrr, ndcg, etc.) — timing artifact only
//   - Fields: artifact_type, lane, run_id, window_seconds, parallel_width,
//             queries_completed, queries_per_second, query_latency_p50_seconds,
//             query_latency_p95_seconds, run_identity

import Testing
import Foundation
@testable import mcp_benchmarker

// MARK: - ThroughputReport serialisation

@Suite("ThroughputReport serialisation")
struct ThroughputReportSerialisationTests {

    func makeIdentity() -> IdentityEnvironment {
        IdentityEnvironment(
            mootx01BinarySha256: "sha-tp",
            mootx01Version: "1.1",
            protocolVersion: "v0.1"
        )
    }

    func sampleReport() -> ThroughputReport {
        ThroughputReport(
            artifactType: "throughput",
            lane: "locomo",
            runID: "tp-001",
            windowSeconds: 30,
            parallelWidth: 2,
            queriesCompleted: 14,
            queriesPerSecond: 14.0 / 30.0,
            queryLatencyP50Seconds: 1.8,
            queryLatencyP95Seconds: 3.2,
            runIdentity: makeIdentity()
        )
    }

    @Test("artifact_type is throughput")
    func artifactType() throws {
        let report = sampleReport()
        let data = try JSONEncoder().encode(report)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["artifact_type"] as? String == "throughput")
    }

    @Test("JSON has no recall fields")
    func noRecallFields() throws {
        let report = sampleReport()
        let data = try JSONEncoder().encode(report)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        // Throughput reports MUST NOT carry any accuracy metrics.
        #expect(json["any_at_5"] == nil)
        #expect(json["recall_at_5"] == nil)
        #expect(json["mrr"] == nil)
        #expect(json["ndcg_at_10"] == nil)
        #expect(json["scores"] == nil)
        #expect(json["results"] == nil)
    }

    @Test("all required throughput fields are present")
    func allRequiredFields() throws {
        let report = sampleReport()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["lane"] as? String == "locomo")
        #expect(json["run_id"] as? String == "tp-001")
        #expect(json["window_seconds"] as? Int == 30)
        #expect(json["parallel_width"] as? Int == 2)
        #expect(json["queries_completed"] as? Int == 14)
        #expect(json["queries_per_second"] != nil)
        #expect(json["query_latency_p50_seconds"] as? Double == 1.8)
        #expect(json["query_latency_p95_seconds"] as? Double == 3.2)
        #expect(json["run_identity"] != nil)
    }

    @Test("run_identity carries binary identity fields")
    func runIdentityFields() throws {
        let report = sampleReport()
        let data = try JSONEncoder().encode(report)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let identity = json["run_identity"] as! [String: Any]
        #expect(identity["mootx01_binary_sha256"] as? String == "sha-tp")
        #expect(identity["mootx01_version"] as? String == "1.1")
        #expect(identity["protocol_version"] as? String == "v0.1")
    }

    @Test("queries_per_second is wall-clock ratio")
    func queriesPerSecond() throws {
        let report = ThroughputReport(
            artifactType: "throughput",
            lane: "locomo",
            runID: "tp-002",
            windowSeconds: 60,
            parallelWidth: 1,
            queriesCompleted: 30,
            queriesPerSecond: 0.5,
            queryLatencyP50Seconds: 2.0,
            queryLatencyP95Seconds: 4.0,
            runIdentity: makeIdentity()
        )
        let data = try JSONEncoder().encode(report)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let qps = json["queries_per_second"] as! Double
        #expect(abs(qps - 0.5) < 1e-9)
    }
}

// MARK: - Throughput filename tests

@Suite("throughput filename")
struct ThroughputFilenameTests {

    @Test("filename follows throughput-<lane>-<serial>.json pattern")
    func filename() {
        let name = recordFilename(test: "throughput", arm: "locomo", serial: "tp-001")
        #expect(name == "throughput-locomo-tp-001.json")
    }

    @Test("filename with timestamp serial")
    func filenameTimestamp() {
        let name = recordFilename(test: "throughput", arm: "locomo", serial: "20260820T123456Z")
        #expect(name == "throughput-locomo-20260820T123456Z.json")
    }

    @Test("lane in arm position distinguishes multiple lane runs")
    func laneInArm() {
        let lme = recordFilename(test: "throughput", arm: "longmemeval", serial: "r1")
        let locomo = recordFilename(test: "throughput", arm: "locomo", serial: "r1")
        #expect(lme != locomo)
        #expect(lme.contains("longmemeval"))
        #expect(locomo.contains("locomo"))
    }
}

// MARK: - ThroughputReport round-trip

@Suite("ThroughputReport round-trip")
struct ThroughputReportRoundTripTests {

    func makeIdentity() -> IdentityEnvironment {
        IdentityEnvironment(
            mootx01BinarySha256: "sha-rt",
            mootx01Version: "1.1",
            protocolVersion: "v0.1"
        )
    }

    @Test("encode + decode round-trip preserves all fields")
    func roundTrip() throws {
        let original = ThroughputReport(
            artifactType: "throughput",
            lane: "lmeb",
            runID: "rt-001",
            windowSeconds: 300,
            parallelWidth: 4,
            queriesCompleted: 72,
            queriesPerSecond: 72.0 / 300.0,
            queryLatencyP50Seconds: 2.5,
            queryLatencyP95Seconds: 6.1,
            runIdentity: makeIdentity()
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ThroughputReport.self, from: data)
        #expect(decoded.artifactType == "throughput")
        #expect(decoded.lane == "lmeb")
        #expect(decoded.runID == "rt-001")
        #expect(decoded.windowSeconds == 300)
        #expect(decoded.parallelWidth == 4)
        #expect(decoded.queriesCompleted == 72)
        #expect(abs(decoded.queriesPerSecond - 72.0 / 300.0) < 1e-9)
        #expect(decoded.queryLatencyP50Seconds == 2.5)
        #expect(decoded.queryLatencyP95Seconds == 6.1)
        #expect(decoded.runIdentity.mootx01BinarySha256 == "sha-rt")
    }
}
