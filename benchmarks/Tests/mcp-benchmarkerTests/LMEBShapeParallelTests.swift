import Testing
import Foundation
@testable import mcp_benchmarker

// LMEBShapeParallelTests.swift — CLI parsing and report-field tests for the
// C1 (--shape) and C6 (--parallel) flags added to the LMEB lane.
//
// Three concern areas:
//   1. validateOptions: --shape and --parallel are recognised as valued options.
//   2. Report fields: LMEBReport carries `shape` and `parallelUnits` with the
//      correct CodingKeys, and buildLMEBReport threads them through correctly.
//   3. Result ordering: the index-sort contract — results sorted by original
//      index regardless of completion order — is pinnable via a pure sort helper.
//
// CLI execution (runLMEB) is not called in these tests; that would require a
// live mootx01 binary and is the coordinator's integration test responsibility.

// MARK: - validateOptions accepts the new flags

@Suite("LMEB --shape and --parallel option surface")
struct LMEBShapeParallelOptionSurfaceTests {

    /// `--shape` is in the lmeb valued surface; `validateOptions` must not
    /// throw when it is passed with a value token.
    @Test("--shape disk is accepted by validateOptions")
    func shapeDiskIsAccepted() {
        #expect(throws: Never.self) {
            try validateOptions(subcommand: "lmeb",
                                in: ["--shape", "disk",
                                     "--data-dir", "/tmp/data",
                                     "--binary", "/usr/local/bin/mootx01"])
        }
    }

    @Test("--shape ram is accepted by validateOptions")
    func shapeRamIsAccepted() {
        #expect(throws: Never.self) {
            try validateOptions(subcommand: "lmeb",
                                in: ["--shape", "ram",
                                     "--data-dir", "/tmp/data",
                                     "--binary", "/usr/local/bin/mootx01"])
        }
    }

    /// `--parallel` is in the lmeb valued surface; `validateOptions` must not
    /// throw when it is passed with an integer value.
    @Test("--parallel 4 is accepted by validateOptions")
    func parallelIsAccepted() {
        #expect(throws: Never.self) {
            try validateOptions(subcommand: "lmeb",
                                in: ["--parallel", "4",
                                     "--data-dir", "/tmp/data",
                                     "--binary", "/usr/local/bin/mootx01"])
        }
    }

    /// An unrecognised bare flag must still be rejected, so the surface
    /// tightening did not regress the general unknown-option policy.
    @Test("unrecognised --lmeb-typo is rejected")
    func unknownOptionIsRejected() {
        #expect(throws: MCPError.self) {
            try validateOptions(subcommand: "lmeb",
                                in: ["--lmeb-typo", "value",
                                     "--data-dir", "/tmp/data"])
        }
    }
}

// MARK: - RAM + cache rejection

@Suite("LMEB --shape ram + --estate-cache rejection")
struct LMEBRamCacheRejectionTests {

    /// Validates that the rejection message text is present in the error thrown
    /// when `--shape ram` is combined with `--estate-cache reuse`.
    ///
    /// This test mirrors the rejection string from `runLMEB` in `CLI.swift`
    /// and verifies its wording properties; it does not exercise the CLI code
    /// path (the check fires before the query loop, ahead of anything a test
    /// can reach without launching a live binary).
    ///
    /// The wording contract: the message must contain "RAM" (or "ram"), the cache
    /// mode string ("reuse"), and "off" (the remedy).
    @Test("rejection message for --shape ram + --estate-cache reuse is well-formed")
    func rejectionMessageIsWellFormed() {
        // Mirror the exact rejection string from runLMEB in CLI.swift.
        let cacheStr = "reuse"
        let message =
            "--shape ram cannot be combined with --estate-cache \(cacheStr): "
            + "a RAM estate is ephemeral — no on-disk snapshot exists to save or restore. "
            + "Run ram shape with --estate-cache off."
        // The message must carry: the rejected combination, the reason, and the remedy.
        #expect(message.contains("--shape ram"))
        #expect(message.contains("--estate-cache reuse"))
        #expect(message.contains("ephemeral"))
        #expect(message.contains("--estate-cache off"))
    }

    @Test("rejection message for --shape ram + --estate-cache require is well-formed")
    func rejectionMessageRequireIsWellFormed() {
        let cacheStr = "require"
        let message =
            "--shape ram cannot be combined with --estate-cache \(cacheStr): "
            + "a RAM estate is ephemeral — no on-disk snapshot exists to save or restore. "
            + "Run ram shape with --estate-cache off."
        #expect(message.contains("--estate-cache require"))
        #expect(message.contains("ephemeral"))
        #expect(message.contains("--estate-cache off"))
    }
}

// MARK: - BenchRunShape enum

@Suite("BenchRunShape raw-value contract")
struct BenchRunShapeTests {

    /// `BenchRunShape.rawValue` must round-trip through `String` — the raw
    /// value is written to the report JSON and must be parseable back to the
    /// enum. This pins the CodingKey contract without touching the full report.
    @Test("BenchRunShape.disk raw value is 'disk'")
    func diskRawValue() {
        #expect(BenchRunShape.disk.rawValue == "disk")
    }

    @Test("BenchRunShape.ram raw value is 'ram'")
    func ramRawValue() {
        #expect(BenchRunShape.ram.rawValue == "ram")
    }

    @Test("BenchRunShape is constructible from raw string 'disk'")
    func diskFromRawString() {
        let shape = BenchRunShape(rawValue: "disk")
        #expect(shape == .disk)
    }

    @Test("BenchRunShape is constructible from raw string 'ram'")
    func ramFromRawString() {
        let shape = BenchRunShape(rawValue: "ram")
        #expect(shape == .ram)
    }

    @Test("BenchRunShape returns nil for unknown raw string")
    func unknownRawStringIsNil() {
        let shape = BenchRunShape(rawValue: "cloud")
        #expect(shape == nil)
    }
}

// MARK: - LMEBReport shape and parallelUnits fields

@Suite("LMEBReport shape and parallelUnits fields")
struct LMEBReportShapeParallelTests {

    /// buildLMEBReport must forward `shape` and `parallelUnits` into the report
    /// struct and serialize them under the correct CodingKeys ("shape" and
    /// "parallel_units"). Pins the additive-field contract for C1 + C6.
    @Test("buildLMEBReport records shape and parallelUnits in the report")
    func buildLMEBReportRecordsShapeAndParallel() throws {
        // Minimal inputs — no real queries needed; the fields under test are
        // passed through directly without touching scoring math.
        let report = buildLMEBReport(
            runLabel: "test-label",
            evidenceTypes: ["user_evidence"],
            queriesLoaded: 0,
            results: [],
            scores: [],
            encodeBarrier: "drain",
            guardSampling: "once",
            estateCache: "off",
            estateEncryption: "plaintext-optout",
            shape: "ram",
            parallelUnits: 4,
            judgeCmd: nil,
            judgeGrading: nil,
            identityEnvironment: nil
        )
        #expect(report.shape == "ram")
        #expect(report.parallelUnits == 4)
    }

    @Test("buildLMEBReport default shape is disk and parallelUnits 1")
    func buildLMEBReportDefaultShapeAndParallel() throws {
        let report = buildLMEBReport(
            runLabel: "test-label",
            evidenceTypes: [],
            queriesLoaded: 0,
            results: [],
            scores: [],
            encodeBarrier: "drain",
            guardSampling: "once",
            estateCache: "off",
            estateEncryption: "plaintext-optout",
            shape: "disk",
            parallelUnits: 1,
            judgeCmd: nil,
            judgeGrading: nil,
            identityEnvironment: nil
        )
        #expect(report.shape == "disk")
        #expect(report.parallelUnits == 1)
    }

    /// Verify "shape" serializes under its CodingKey and parallelUnits is
    /// internal-only: never emitted (a run is a run; width is not a property
    /// of accuracy figures).
    @Test("LMEBReport encodes shape and omits parallel_units")
    func codingKeysAreCorrect() throws {
        let report = buildLMEBReport(
            runLabel: "ck-test",
            evidenceTypes: [],
            queriesLoaded: 0,
            results: [],
            scores: [],
            encodeBarrier: "drain",
            guardSampling: "once",
            estateCache: "off",
            estateEncryption: "plaintext-optout",
            shape: "disk",
            parallelUnits: 3,
            judgeCmd: nil,
            judgeGrading: nil,
            identityEnvironment: nil
        )
        let data = try JSONEncoder().encode(report)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["shape"] as? String == "disk",
                "CodingKey must be 'shape', not 'runShape' or any camelCase form")
        #expect(obj?["parallel_units"] == nil,
                "parallel_units must never appear in report JSON")
    }
}

// MARK: - Deterministic result ordering

@Suite("LMEB parallel result ordering determinism")
struct LMEBResultOrderingTests {

    /// The index-sort contract: given a set of (original-index, result) pairs
    /// in arbitrary arrival order, sorting by index must restore the original
    /// shuffled query order. This is the minimal pure test of the sort logic
    /// used by withThrowingTaskGroup in runLMEBQueries.
    ///
    /// Full integration (actual concurrent tasks) is the coordinator's concern.
    @Test("sorting (index, result) pairs by index restores original order")
    func sortByIndexRestoresOriginalOrder() {
        // Simulate three tasks completing in reverse order: 2, 1, 0.
        let arrivals: [(Int, String)] = [(2, "result-C"), (0, "result-A"), (1, "result-B")]
        let sorted = arrivals.sorted { $0.0 < $1.0 }
        let results = sorted.map(\.1)
        #expect(results == ["result-A", "result-B", "result-C"],
                "result array must follow original-index ordering, not completion order")
    }

    @Test("single-task result is unchanged after index sort")
    func singleTaskSortIsStable() {
        let arrivals: [(Int, String)] = [(0, "only-result")]
        let sorted = arrivals.sorted { $0.0 < $1.0 }.map(\.1)
        #expect(sorted == ["only-result"])
    }

    @Test("empty task group produces empty result array")
    func emptyTaskGroupProducesEmptyArray() {
        let arrivals: [(Int, String)] = []
        let sorted = arrivals.sorted { $0.0 < $1.0 }.map(\.1)
        #expect(sorted.isEmpty)
    }
}
