import Testing
import Foundation
@testable import mcp_benchmarker

// LoCoMoStrategyTests.swift — unit tests for the LoCoMo SHAPED/PRECISE strategy
// cells added by PR-08 Deliverable 1.
//
// No live MCP involved. Tests cover:
//   - LoCoMoRecallStrategy raw values match the CLI flag strings
//   - Default invocations (.search) remain byte-stable: run label unchanged
//   - .shaped and .precise strategy names appear in run labels
//   - recallStrategy and recallShape carry through to LoCoMoReport
//
// All tests are pure-computation — no estate, no binary, no filesystem.

@Suite("LoCoMo recall strategy cells")
struct LoCoMoStrategyTests {

    // MARK: - Enum raw values

    @Test("search raw value is 'search'")
    func searchRawValue() {
        #expect(LoCoMoRecallStrategy.search.rawValue == "search")
    }

    @Test("shaped raw value is 'shaped'")
    func shapedRawValue() {
        #expect(LoCoMoRecallStrategy.shaped.rawValue == "shaped")
    }

    @Test("precise raw value is 'precise'")
    func preciseRawValue() {
        #expect(LoCoMoRecallStrategy.precise.rawValue == "precise")
    }

    // MARK: - Run label byte-stability for default (.search)

    // The default strategy (.search) must produce the same run label format as
    // all prior LoCoMo runs ("locomo-seed<N>"), so that existing result files
    // are not invalidated when users upgrade the harness.
    @Test("default search strategy produces legacy-compatible run label (no strategy suffix)")
    func searchRunLabelIsUnchanged() {
        let label = makeLoCoMoRunLabel(seed: 20260725, strategy: .search, recallShape: nil)
        #expect(label == "locomo-seed20260725")
    }

    @Test("default search strategy with explicit seed produces consistent label")
    func searchRunLabelWithSeed() {
        let label = makeLoCoMoRunLabel(seed: 42, strategy: .search, recallShape: nil)
        #expect(label == "locomo-seed42")
    }

    // MARK: - Strategy suffix for non-default strategies

    @Test("shaped strategy appends strategy name to run label")
    func shapedRunLabelHasStrategyName() {
        let label = makeLoCoMoRunLabel(seed: 20260725, strategy: .shaped, recallShape: nil)
        #expect(label == "locomo-seed20260725-shaped")
    }

    @Test("shaped strategy with preset appends both strategy name and preset")
    func shapedRunLabelWithPreset() {
        let label = makeLoCoMoRunLabel(seed: 20260725, strategy: .shaped, recallShape: "temporal")
        #expect(label == "locomo-seed20260725-shaped-temporal")
    }

    @Test("precise strategy appends strategy name to run label")
    func preciseRunLabelHasStrategyName() {
        let label = makeLoCoMoRunLabel(seed: 20260725, strategy: .precise, recallShape: nil)
        #expect(label == "locomo-seed20260725-precise")
    }

    // MARK: - LoCoMoReport carries strategy fields

    @Test("LoCoMoReport carries recall_strategy and recall_shape from config")
    func reportCarriesStrategyFields() {
        // Build a minimal LoCoMoReport to verify the strategy fields round-trip
        // through Codable. The scorer's buildLoCoMoReport fills these from config.
        let report = makeMiniLoCoMoReport(strategy: "shaped", recallShape: "balanced")
        #expect(report.recallStrategy == "shaped")
        #expect(report.recallShape == "balanced")
    }

    @Test("LoCoMoReport with search strategy has nil recallShape")
    func reportSearchStrategyHasNilShape() {
        let report = makeMiniLoCoMoReport(strategy: "search", recallShape: nil)
        #expect(report.recallStrategy == "search")
        #expect(report.recallShape == nil)
    }

    @Test("LoCoMoReport recall fields survive JSON round-trip")
    func reportRoundTrip() throws {
        let report = makeMiniLoCoMoReport(strategy: "precise", recallShape: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        let decoded = try JSONDecoder().decode(LoCoMoReport.self, from: data)
        #expect(decoded.recallStrategy == "precise")
        #expect(decoded.recallShape == nil)
    }

    @Test("LoCoMoReport shaped with preset survives JSON round-trip")
    func reportShapedWithPresetRoundTrip() throws {
        let report = makeMiniLoCoMoReport(strategy: "shaped", recallShape: "knowledge")
        let encoder = JSONEncoder()
        let data = try encoder.encode(report)
        let decoded = try JSONDecoder().decode(LoCoMoReport.self, from: data)
        #expect(decoded.recallStrategy == "shaped")
        #expect(decoded.recallShape == "knowledge")
    }

    // MARK: - CodingKeys alias

    @Test("recall_strategy CodingKey alias is present in JSON output")
    func recallStrategyCodingKeyAlias() throws {
        let report = makeMiniLoCoMoReport(strategy: "search", recallShape: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try String(decoding: encoder.encode(report), as: UTF8.self)
        #expect(json.contains("\"recall_strategy\""), "JSON must contain snake_case key")
        #expect(!json.contains("\"recallStrategy\""), "JSON must not contain camelCase key")
    }
}

// MARK: - Test helpers

/// Replicates the run-label logic from CLI.swift's `runLoCoMo` function for
/// unit testing without needing to parse CLI args.
private func makeLoCoMoRunLabel(
    seed: UInt64,
    strategy: LoCoMoRecallStrategy,
    recallShape: String?
) -> String {
    if strategy == .search {
        return "locomo-seed\(seed)"
    }
    var label = "locomo-seed\(seed)-\(strategy.rawValue)"
    if let shape = recallShape { label += "-\(shape)" }
    return label
}

/// Builds a minimal LoCoMoReport with just the strategy fields populated.
/// Other fields carry neutral/empty values — this fixture tests the scoring
/// plumbing only, not the recall math.
private func makeMiniLoCoMoReport(strategy: String, recallShape: String?) -> LoCoMoReport {
    LoCoMoReport(
        runID: UUID().uuidString,
        runLabel: "test-run",
        generatedAt: "2026-01-01T00:00:00Z",
        corpusStats: LoCoMoReportCorpusStats(
            questionsLoaded: 0, adversarialExcluded: 0,
            questionsRun: 0, guardExcluded: 0),
        aggregate: LoCoMoReportAggregate(
            queryCount: 0,
            recallAnyAt1: 0, recallAnyAt5: 0, recallAnyAt10: 0,
            recallAllAt1: 0, recallAllAt5: 0, recallAllAt10: 0, mrr: 0),
        categoryBreakdown: [],
        latency: LoCoMoReportLatency(
            queryP50Seconds: 0, queryP95Seconds: 0,
            queryMeanSeconds: 0, writeMeanSeconds: 0),
        perQuestion: [],
        encodeBarrier: "drain",
        guardSampling: "once",
        provenanceSummary: nil,
        estateCache: "off",
        cacheHits: 0,
        cacheMisses: 0,
        estateEncryption: "plaintext-optout",
        granularity: "turn",
        recallStrategy: strategy,
        recallShape: recallShape,
        rerankCmdSet: false,
        rerankFailures: nil,
        identityEnvironment: nil,
        shape: "disk",
        parallelUnits: 1,
        timingReport: nil,
        timingSampling: "once-per-leg",
        // C10: default per-conversation mode (no deviation labels).
        estateShape: "per-conversation",
        protocolDeviation: false)
}
