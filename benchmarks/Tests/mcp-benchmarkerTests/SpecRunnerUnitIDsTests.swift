import Foundation
import Testing
@testable import mcp_benchmarker

// SpecRunnerUnitIDsTests.swift — discriminating tests for the MOOT_BENCH_UNIT_IDS
// seam in the four spec runners (LMESpec, LoCoMoSpec, LMEBSpec, MemBenchSpec).
//
// Discriminating gate: the filter is applied before the seeded shuffle so that
// a unit-IDs file selects the same questions regardless of --seed/--limit/--offset.
// These tests verify:
//   A. filter file with 2 ids ⇒ filterUnits returns exactly 2 items (fails if
//      the filter is silently dropped and the full corpus passes through).
//   B. env unset (unitIDs: nil) ⇒ filterUnits passes the full corpus unchanged.
//   C. LMESpecReportParams Codable round-trip carries unitIDsPath + selectedCount.
//   D. MemBenchSpecReport Codable round-trip carries unitIDsPath + selectedCount.
//   E. LoCoMoSpecRunConfig + LoCoMoSpecRunMetadata wire the fields through the
//      metadata struct without truncation.
//   F. LMEBSpecRunConfig carries unitIDs + unitIDsPath.
//
// All tests are pure-logic — no live MCP, no estate, no disk I/O beyond a
// temporary id file.

// MARK: - Helper: write a temporary unit-ID file

private func writeTempUnitIDFile(_ ids: [String]) throws -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("unit-ids-\(UUID().uuidString).txt")
    try ids.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    return url.path
}

// MARK: - A: filter file with 2 ids ⇒ exactly 2 questions selected

@Suite("SpecRunnerUnitIDs — filter reduces question count")
struct SpecRunnerUnitIDsFilterTests {

    // Synthetic question IDs for a notional lme-spec corpus.
    private let allIDs = ["q1", "q2", "q3", "q4", "q5"]

    @Test("filter file with 2 ids ⇒ exactly 2 items selected (lme-spec path)")
    func filterProducesExactlyTwoLMESpec() throws {
        let pinned = ["q2", "q4"]
        let path = try writeTempUnitIDFile(pinned)
        let ids = try loadUnitIDs(path)

        // Simulate what runLMESpec does before the shuffle.
        // Elements are strings here; the real code uses LMESpecQuestion keyed on questionID.
        let result = try filterUnits(allIDs, ids: ids, id: { $0 }, lane: "lme-spec")

        #expect(result.count == 2,
                "filter file with 2 ids must produce exactly 2 questions; got \(result.count)")
        #expect(Set(result) == Set(pinned),
                "selected questions must match the pinned id set exactly")
    }

    @Test("filter file with 2 ids ⇒ exactly 2 items selected (locomo-spec path)")
    func filterProducesExactlyTwoLoCoMoSpec() throws {
        let pinned = ["q1", "q5"]
        let path = try writeTempUnitIDFile(pinned)
        let ids = try loadUnitIDs(path)

        let result = try filterUnits(allIDs, ids: ids, id: { $0 }, lane: "locomo-spec")

        #expect(result.count == 2,
                "filter file with 2 ids must produce exactly 2 questions; got \(result.count)")
        #expect(Set(result) == Set(pinned))
    }

    @Test("filter file with 2 ids ⇒ exactly 2 items selected (membench-spec path)")
    func filterProducesExactlyTwoMemBenchSpec() throws {
        let pinned = ["q3", "q4"]
        let path = try writeTempUnitIDFile(pinned)
        let ids = try loadUnitIDs(path)

        let result = try filterUnits(allIDs, ids: ids, id: { $0 }, lane: "membench-spec")

        #expect(result.count == 2,
                "filter file with 2 ids must produce exactly 2 questions; got \(result.count)")
        #expect(Set(result) == Set(pinned))
    }

    @Test("filter file with 2 ids ⇒ exactly 2 items selected (lmeb-spec path)")
    func filterProducesExactlyTwoLMEBSpec() throws {
        let pinned = ["q1", "q3"]
        let path = try writeTempUnitIDFile(pinned)
        let ids = try loadUnitIDs(path)

        let result = try filterUnits(allIDs, ids: ids, id: { $0 }, lane: "lmeb-spec")

        #expect(result.count == 2,
                "filter file with 2 ids must produce exactly 2 questions; got \(result.count)")
        #expect(Set(result) == Set(pinned))
    }
}

// MARK: - B: env unset (nil) ⇒ full corpus passes through

@Suite("SpecRunnerUnitIDs — nil filter passes full corpus")
struct SpecRunnerUnitIDsNilTests {

    private let allIDs = ["q1", "q2", "q3", "q4", "q5"]

    @Test("unitIDs nil ⇒ full corpus unchanged (lme-spec)")
    func nilPassesThroughLMESpec() throws {
        let result = try filterUnits(allIDs, ids: nil, id: { $0 }, lane: "lme-spec")
        #expect(result == allIDs,
                "nil unitIDs must pass the full corpus through unchanged")
    }

    @Test("unitIDs nil ⇒ full corpus unchanged (locomo-spec)")
    func nilPassesThroughLoCoMoSpec() throws {
        let result = try filterUnits(allIDs, ids: nil, id: { $0 }, lane: "locomo-spec")
        #expect(result == allIDs)
    }

    @Test("unitIDs nil ⇒ full corpus unchanged (membench-spec)")
    func nilPassesThroughMemBenchSpec() throws {
        let result = try filterUnits(allIDs, ids: nil, id: { $0 }, lane: "membench-spec")
        #expect(result == allIDs)
    }

    @Test("unitIDs nil ⇒ full corpus unchanged (lmeb-spec)")
    func nilPassesThroughLMEBSpec() throws {
        let result = try filterUnits(allIDs, ids: nil, id: { $0 }, lane: "lmeb-spec")
        #expect(result == allIDs)
    }
}

// MARK: - C: LMESpecReportParams Codable round-trip (unitIDsPath + selectedCount)

@Suite("SpecRunnerUnitIDs — LMESpecReportParams Codable")
struct LMESpecReportParamsUnitIDsTests {

    private func makeSampleParams(unitIDsPath: String?, selectedCount: Int) -> LMESpecReportParams {
        var p = LMESpecReportParams(
            variant: "m",
            seed: 42,
            limit: nil,
            offset: 0,
            judgeModel: "gpt-4o-2024-08-06",
            judgeCmdSet: false,
            dumpJudgeInputsSet: false)
        p.unitIDsPath = unitIDsPath
        p.selectedCount = selectedCount
        return p
    }

    @Test("unitIDsPath and selectedCount round-trip through JSON when set")
    func roundTripWithFilter() throws {
        let path = "/tmp/some-ids.txt"
        let params = makeSampleParams(unitIDsPath: path, selectedCount: 2)

        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(params)
        let decoded = try JSONDecoder().decode(LMESpecReportParams.self, from: data)

        #expect(decoded.unitIDsPath == path,
                "unit_ids_path must survive JSON round-trip")
        #expect(decoded.selectedCount == 2,
                "selected_count must survive JSON round-trip")
    }

    @Test("unitIDsPath nil round-trips as absent JSON key")
    func roundTripWithoutFilter() throws {
        let params = makeSampleParams(unitIDsPath: nil, selectedCount: 500)

        let enc = JSONEncoder()
        let data = try enc.encode(params)
        // Verify the key is absent when nil (not encoded as null).
        let obj = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["unit_ids_path"] == nil,
                "unit_ids_path key must be absent when no filter was applied")

        let decoded = try JSONDecoder().decode(LMESpecReportParams.self, from: data)
        #expect(decoded.unitIDsPath == nil)
        #expect(decoded.selectedCount == 500)
    }
}

// MARK: - D: MemBenchSpecReport Codable round-trip (unitIDsPath + selectedCount)

@Suite("SpecRunnerUnitIDs — MemBenchSpecReport Codable")
struct MemBenchSpecReportUnitIDsTests {

    @Test("unitIDsPath and selectedCount round-trip when filter applied")
    func roundTripWithFilter() throws {
        // Build a minimal MemBenchSpecReport with the new fields set.
        let emptyEff = MemBenchSpecEfficiencyStats(
            count: 0, mean: 0, p50: 0, p95: 0)
        let emptySlice = MemBenchSpecAggregateSlice(
            label: "overall", count: 0, accuracy: 0.0, meanRecall: 0.0)

        var report = MemBenchSpecReport(
            runLabel: "membench-spec-FirstAgent-seed42",
            port: "swift",
            agent: "FirstAgent",
            seed: 42,
            estateMode: "artifact-unit",
            targetScale: "unit",
            protocolMode: "standard",
            overall: emptySlice,
            byCategory: [],
            byPerspective: [],
            answeredCount: 0,
            writeEfficiency: emptyEff,
            readEfficiency: emptyEff,
            capacitySamples: nil,
            capacityBuckets: nil,
            itemCount: 2)
        report.unitIDsPath = "/tmp/pinned-ids.txt"
        report.selectedCount = 2

        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(report)
        let decoded = try JSONDecoder().decode(MemBenchSpecReport.self, from: data)

        #expect(decoded.unitIDsPath == "/tmp/pinned-ids.txt",
                "unit_ids_path must survive JSON round-trip in MemBenchSpecReport")
        #expect(decoded.selectedCount == 2,
                "selected_count must survive JSON round-trip in MemBenchSpecReport")
    }

    @Test("unitIDsPath nil round-trips as absent key")
    func roundTripWithoutFilter() throws {
        let emptyEff = MemBenchSpecEfficiencyStats(
            count: 0, mean: 0, p50: 0, p95: 0)
        let emptySlice = MemBenchSpecAggregateSlice(
            label: "overall", count: 0, accuracy: 0.0, meanRecall: 0.0)

        let report = MemBenchSpecReport(
            runLabel: "r",
            port: "swift",
            agent: "FirstAgent",
            seed: 0,
            estateMode: "artifact-unit",
            targetScale: "unit",
            protocolMode: "standard",
            overall: emptySlice,
            byCategory: [],
            byPerspective: [],
            answeredCount: 0,
            writeEfficiency: emptyEff,
            readEfficiency: emptyEff,
            capacitySamples: nil,
            capacityBuckets: nil,
            itemCount: 100)
        // unitIDsPath defaults to nil, selectedCount defaults to 0.

        let enc = JSONEncoder()
        let data = try enc.encode(report)
        let obj = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["unit_ids_path"] == nil,
                "unit_ids_path must be absent from the JSON when no filter was applied")
    }
}

// MARK: - E: LoCoMoSpecRunConfig and LoCoMoSpecRunMetadata carry the fields

@Suite("SpecRunnerUnitIDs — LoCoMoSpec config and metadata fields")
struct LoCoMoSpecUnitIDsFieldTests {

    @Test("LoCoMoSpecRunConfig defaults unitIDs to nil and unitIDsPath to nil")
    func configDefaultsNil() {
        let cfg = LoCoMoSpecRunConfig(
            mootBinaryPath: "/usr/bin/moot",
            datasetPath: URL(fileURLWithPath: "/tmp/locomo10.json"))
        #expect(cfg.unitIDs == nil)
        #expect(cfg.unitIDsPath == nil)
    }

    @Test("LoCoMoSpecRunConfig stores unitIDs when set")
    func configStoresFilter() throws {
        let pinned = Set(["conv0_q1", "conv1_q0"])
        var cfg = LoCoMoSpecRunConfig(
            mootBinaryPath: "/usr/bin/moot",
            datasetPath: URL(fileURLWithPath: "/tmp/locomo10.json"))
        cfg.unitIDs = pinned
        cfg.unitIDsPath = "/tmp/locomo-ids.txt"

        #expect(cfg.unitIDs == pinned)
        #expect(cfg.unitIDsPath == "/tmp/locomo-ids.txt")
    }

    @Test("LoCoMoSpecRunMetadata carries unitIDsPath and selectedCount")
    func metadataCarriesFields() {
        let meta = LoCoMoSpecRunMetadata(
            port: "swift",
            seed: 42,
            estateMode: "artifact-unit",
            targetScale: "unit",
            parallelUnits: 1,
            corpusDigest: "abc123",
            totalQuestions: 2,
            conversationsUsed: 1,
            runLabel: "locomo-spec-seed42",
            categoryCounts: [1: 1, 2: 1],
            unitIDsPath: "/tmp/locomo-ids.txt",
            selectedCount: 2)

        #expect(meta.unitIDsPath == "/tmp/locomo-ids.txt")
        #expect(meta.selectedCount == 2)
    }
}

// MARK: - F: LMEBSpecRunConfig carries unitIDs + unitIDsPath

@Suite("SpecRunnerUnitIDs — LMEBSpecRunConfig fields")
struct LMEBSpecRunConfigUnitIDsTests {

    @Test("LMEBSpecRunConfig defaults unitIDs to nil and unitIDsPath to nil")
    func configDefaultsNil() {
        let cfg = LMEBSpecRunConfig(
            mootBinaryPath: "/usr/bin/moot",
            dataDir: URL(fileURLWithPath: "/tmp/lmeb"),
            evidenceTypes: ["user_evidence"],
            limit: nil,
            offset: 0,
            seed: 42,
            outDir: nil,
            runLabel: "lmeb-spec-seed42")
        #expect(cfg.unitIDs == nil)
        #expect(cfg.unitIDsPath == nil)
    }

    @Test("LMEBSpecRunConfig stores unitIDs when set")
    func configStoresFilter() {
        var cfg = LMEBSpecRunConfig(
            mootBinaryPath: "/usr/bin/moot",
            dataDir: URL(fileURLWithPath: "/tmp/lmeb"),
            evidenceTypes: ["user_evidence"],
            limit: nil,
            offset: 0,
            seed: 42,
            outDir: nil,
            runLabel: "lmeb-spec-seed42")
        cfg.unitIDs = Set(["user_evidence__q1", "user_evidence__q2"])
        cfg.unitIDsPath = "/tmp/lmeb-ids.txt"

        #expect(cfg.unitIDs?.count == 2)
        #expect(cfg.unitIDsPath == "/tmp/lmeb-ids.txt")
    }
}
