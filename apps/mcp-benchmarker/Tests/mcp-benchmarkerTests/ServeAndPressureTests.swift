import Testing
import Foundation
@testable import mcp_benchmarker

// ServeAndPressureTests.swift — Swift Testing coverage for the serve-proxy,
// pressure-driver, and faithful-importer logic added for the 4-way benchmarker:
// rolling/standing stats, the single-record fetch parse (full-content
// importer), and the extended verbMap config fields. The live behavior of the
// proxy/pressure loops is covered by the LIVE smokes; these unit-test the pure
// pieces those loops are built from, with no live server needed.

// MARK: - RollingStats (standing stats for serve + pressure)

struct RollingStatsTests {

    @Test("RollingSeries mean and nearest-rank p95 match the one-shot series")
    func seriesMeanP95() {
        var s = RollingSeries()
        for v in [0.010, 0.020, 0.030, 0.040, 0.100] { s.record(v) }
        #expect(s.totalCount == 5)
        #expect(abs(s.mean - 0.040) < 1e-9)
        // nearest-rank p95 of 5 samples → ceil(0.95*5)=5th → the max, 0.100.
        #expect(abs(s.p95 - 0.100) < 1e-9)
    }

    @Test("RollingSeries window slides but totalCount keeps the true count")
    func seriesWindowSlides() {
        var s = RollingSeries(cap: 3)
        for v in [1.0, 2.0, 3.0, 4.0, 5.0] { s.record(v) }
        // Window holds only the last 3 samples (3,4,5) → mean 4.0 …
        #expect(abs(s.mean - 4.0) < 1e-9)
        // … but totalCount reflects all 5 recorded.
        #expect(s.totalCount == 5)
    }

    @Test("RollingStats snapshot aggregates labelled series and divergence")
    func snapshotAggregates() async {
        let stats = RollingStats()
        await stats.recordLatency(0.010, label: "mootx01.read")
        await stats.recordLatency(0.030, label: "mootx01.read")
        await stats.recordLatency(0.050, label: "contender.read")
        await stats.recordDivergence(jaccard: 0.2, kendallRank: 0.0)
        await stats.recordDivergence(jaccard: 0.4, kendallRank: 1.0)

        let snap = await stats.snapshot()
        // Series are emitted in sorted-label order.
        #expect(snap.series.map(\.label) == ["contender.read", "mootx01.read"])
        let mootRead = snap.series.first { $0.label == "mootx01.read" }!
        #expect(abs(mootRead.mean - 0.020) < 1e-9)
        #expect(mootRead.totalCount == 2)
        // Divergence means: (0.2+0.4)/2 = 0.3 ; (0.0+1.0)/2 = 0.5.
        #expect(snap.divergenceSampleCount == 2)
        #expect(abs(snap.jaccardMean - 0.3) < 1e-9)
        #expect(abs(snap.kendallRankMean - 0.5) < 1e-9)
    }

    @Test("RollingStats snapshot is zero-safe before any divergence sample")
    func snapshotZeroSafe() async {
        let stats = RollingStats()
        await stats.recordLatency(0.01, label: "x")
        let snap = await stats.snapshot()
        #expect(snap.divergenceSampleCount == 0)
        #expect(snap.jaccardMean == 0.0)
        #expect(snap.kendallRankMean == 0.0)
    }
}

// MARK: - Single-record fetch parse (faithful full-content importer)

struct FetchParseTests {

    /// MCP text-block envelope, the shape parseToolResult receives.
    private func textResult(_ text: String) -> JSONValue {
        .object(["content": .array([
            .object(["type": .string("text"), "text": .string(text)])
        ])])
    }

    @Test("get_drawer single object parses full content under the fetch key")
    func singleRecordFetch() {
        // get_drawer returns ONE bare object (no array wrapper) with
        // full content under `content` (not the truncated `content_preview`).
        let payload = """
        {
          "drawer_id": "d1",
          "content": "the FULL drawer content, much longer than the preview",
          "wing": "w", "room": "r",
          "metadata": "{}"
        }
        """
        let result = MCPClient.parseToolResult(
            textResult(payload),
            format: .jsonObjects(idKey: "drawer_id", contentKey: "content"))
        #expect(result.items.count == 1)
        #expect(result.items.first?.id == "d1")
        #expect(result.items.first?.content == "the FULL drawer content, much longer than the preview")
    }

    @Test("Array result still preferred over the single-object fallback")
    func arrayPreferredOverSingleObject() {
        // An object that wraps an array must parse the array, not itself.
        let payload = """
        { "drawers": [ { "drawer_id": "a", "content_preview": "p1" } ], "count": 1 }
        """
        let result = MCPClient.parseToolResult(
            textResult(payload),
            format: .jsonObjects(idKey: "drawer_id", contentKey: "content_preview"))
        #expect(result.orderedIDs == ["a"])
        #expect(result.items.first?.content == "p1")
    }
}

// MARK: - Extended verbMap config fields (importer + export)

struct ImporterConfigTests {

    private func loadVerbMap(_ verbMapJSON: String) throws -> EndpointConfig.VerbMap {
        let json = """
        {
          "source": {
            "name": "s", "transport": { "stdio": { "command": "x" } },
            "verbMap": \(verbMapJSON), "role": "source"
          },
          "target": {
            "name": "t", "transport": { "stdio": { "command": "y" } },
            "verbMap": { "write": "w", "query": "q", "list": null }, "role": "target"
          }
        }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("im-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try BenchmarkerConfig.load(from: url).source.verbMap
    }

    @Test("New importer fields default for a terse verbMap")
    func importerDefaults() throws {
        let vm = try loadVerbMap(#"{ "write": "w", "query": "q", "list": "l" }"#)
        #expect(vm.fetch == nil)
        #expect(vm.fetchIDArg == "drawer_id")
        #expect(vm.fetchContentKey == "content")
        #expect(vm.listLimitArg == "limit")
        #expect(vm.listOffsetArg == "offset")
        #expect(vm.listPageSize == 100)
    }

    @Test("contender source verbMap decodes fetch + pagination fields")
    func contenderImporterFields() throws {
        let vm = try loadVerbMap("""
        {
          "write": "contender_add_drawer",
          "query": "contender_search",
          "list": "contender_list_drawers",
          "fetch": "contender_get_drawer",
          "fetchIDArg": "drawer_id",
          "fetchContentKey": "content",
          "listPageSize": 100,
          "resultFormat": { "kind": "jsonObjects", "idKey": "drawer_id", "contentKey": "content_preview" }
        }
        """)
        #expect(vm.fetch == "contender_get_drawer")
        #expect(vm.fetchContentKey == "content")
        #expect(vm.listPageSize == 100)
    }
}

// MARK: - PressurePath identity

struct PressurePathTests {

    @Test("All four 4-way paths are present with stable labels")
    func fourPaths() {
        #expect(PressurePath.allCases.count == 4)
        #expect(Set(PressurePath.allCases.map(\.rawValue)) == [
            "mootx01.read", "mootx01.write", "contender.read", "contender.write",
        ])
    }

    @Test("PressurePathResult throughput is ops over wall seconds")
    func throughput() {
        let r = PressurePathResult(path: "mootx01.read", opsCompleted: 100, opsFailed: 0,
                                   wallSeconds: 2.0, meanLatency: 0.01, p95Latency: 0.02)
        #expect(abs(r.throughputPerSecond - 50.0) < 1e-9)
        // Zero wall time must not divide-by-zero.
        let z = PressurePathResult(path: "x", opsCompleted: 5, opsFailed: 0,
                                   wallSeconds: 0, meanLatency: 0, p95Latency: 0)
        #expect(z.throughputPerSecond == 0)
    }
}
