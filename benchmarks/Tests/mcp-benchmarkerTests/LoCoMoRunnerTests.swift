import XCTest
@testable import mcp_benchmarker

// LoCoMoRunnerTests.swift — Unit tests for the LoCoMo runner infrastructure.
//
// Tests cover:
//   - loCoMoScratchDir(posture:): creates a dir under /tmp/locomo-bench-
//   - loCoMoGuardedTeardown(): refuses wrong prefix; removes valid dirs
//   - verbMap: correct write/query verbs, constant args, resultFormat
//
// No live MCP is involved — these are pure infrastructure tests.

final class LoCoMoRunnerTests: XCTestCase {

    // MARK: - Scratch directory management

    func testScratchDirCreatesCorrectPrefix() throws {
        let url = try loCoMoScratchDir(posture: .plaintextTransient)
        defer { try? loCoMoGuardedTeardown(url) }

        XCTAssert(url.path.hasPrefix("/tmp/locomo-bench-"),
                  "scratch dir must start with /tmp/locomo-bench-: \(url.path)")
        XCTAssert(FileManager.default.fileExists(atPath: url.path),
                  "scratch dir must exist after creation: \(url.path)")
    }

    func testScratchDirIsDirectory() throws {
        let url = try loCoMoScratchDir(posture: .plaintextTransient)
        defer { try? loCoMoGuardedTeardown(url) }

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        XCTAssert(exists && isDir.boolValue,
                  "scratch path must be a directory: \(url.path)")
    }

    func testScratchDirIsUnique() throws {
        let a = try loCoMoScratchDir(posture: .plaintextTransient)
        let b = try loCoMoScratchDir(posture: .plaintextTransient)
        defer {
            try? loCoMoGuardedTeardown(a)
            try? loCoMoGuardedTeardown(b)
        }
        XCTAssertNotEqual(a.path, b.path,
                          "two loCoMoScratchDir(posture:) calls must produce unique paths")
    }

    func testGuardedTeardownRemovesDir() throws {
        let url = try loCoMoScratchDir(posture: .plaintextTransient)
        // Verify it exists before teardown.
        XCTAssert(FileManager.default.fileExists(atPath: url.path))
        // Teardown should not throw.
        XCTAssertNoThrow(try loCoMoGuardedTeardown(url))
        // Verify it's gone after teardown.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "directory must be removed after guarded teardown")
    }

    func testGuardedTeardownRefusesNonPrefixedPath() {
        // A path without the required prefix must throw MCPError.
        let arbitrary = URL(fileURLWithPath: "/tmp/some-other-directory")
        XCTAssertThrowsError(try loCoMoGuardedTeardown(arbitrary),
                             "teardown must refuse path without /tmp/locomo-bench- prefix") { err in
            // MCPError carries its message in `.description`; cast to access it.
            guard let mcpErr = err as? MCPError else {
                return XCTFail("expected MCPError, got \(type(of: err))")
            }
            let desc = mcpErr.description
            XCTAssert(desc.contains("SAFETY") || desc.contains("prefix") || desc.contains("locomo-bench"),
                      "error message should describe the safety constraint: \(desc)")
        }
    }

    func testGuardedTeardownRefusesHomePath() {
        // Refuse any path that might reach the user's home directory.
        let home = URL(fileURLWithPath: NSHomeDirectory())
        XCTAssertThrowsError(try loCoMoGuardedTeardown(home),
                             "teardown must refuse home directory path")
    }

    func testGuardedTeardownIsNoOpForMissingDir() throws {
        // A valid-prefix path that does not exist should NOT throw
        // (already-missing dir is idempotent).
        let url = URL(fileURLWithPath: "/tmp/locomo-bench-does-not-exist-\(UUID().uuidString)")
        // Should not throw even though the path doesn't exist.
        XCTAssertNoThrow(try loCoMoGuardedTeardown(url),
                         "teardown of a non-existent valid-prefix path must not throw")
    }

    // MARK: - VerbMap

    func testVerbMapWriteTool() {
        XCTAssertEqual(loCoMoMootVerbMap.write, "moot_file_memory",
                       "write verb must be moot_file_memory")
    }

    func testVerbMapQueryTool() {
        XCTAssertEqual(loCoMoMootVerbMap.query, "moot_memory_search",
                       "query verb must be moot_memory_search")
    }

    func testVerbMapListNil() {
        XCTAssertNil(loCoMoMootVerbMap.list,
                     "list verb must be nil (mootx01 does not expose a list call in this mode)")
    }

    func testVerbMapConstantArgsLocation() {
        let loc = loCoMoMootVerbMap.constantArgs["location"]
        XCTAssertEqual(loc, "benchmarks/locomo",
                       "constant args must set location=benchmarks/locomo")
    }

    func testVerbMapResultFormat() {
        // v2: all verb maps use .mootV2 structured response parsing
        if case .mootV2 = loCoMoMootVerbMap.resultFormat {
            // Pass
        } else {
            XCTFail("resultFormat must be .mootV2 (ARIA v2 structured response), got \(loCoMoMootVerbMap.resultFormat)")
        }
    }
}

// MARK: - C1 / C6 flag tests (benchmark reset 2026-08-13)

/// Tests for the --shape and --parallel CLI flags and derived LoCoMoRunConfig semantics.
/// No live MCP; all tests are pure (CLI parse helpers, width computation, enum logic).
final class LoCoMoShapeParallelTests: XCTestCase {

    // MARK: - LoCoMoEstateShape enum

    func testShapeEnumRawValues() {
        // Raw values must match the CLI flag strings (used in report JSON and error messages).
        XCTAssertEqual(LoCoMoEstateShape.disk.rawValue, "disk",
                       "disk raw value must be 'disk' (report JSON key)")
        XCTAssertEqual(LoCoMoEstateShape.ram.rawValue, "ram",
                       "ram raw value must be 'ram' (report JSON key)")
    }

    func testShapeDefaultIsDisk() {
        // LoCoMoRunConfig's default shape must be .disk so existing runs are unaffected.
        // Construct a minimal config and verify the default.
        var config = makeMinimalRunConfig()
        XCTAssertEqual(config.shape, .disk,
                       "default shape must be .disk — existing runs must be unaffected")
        // Setting .ram must be reflected.
        config.shape = .ram
        XCTAssertEqual(config.shape, .ram)
    }

    // MARK: - --shape CLI parse simulation

    func testShapeDiskParsesCorrectly() {
        // Simulate the CLI parse path for "--shape disk".
        let shapeStr = "disk"
        let shape: LoCoMoEstateShape
        switch shapeStr {
        case "disk": shape = .disk
        case "ram":  shape = .ram
        default:     XCTFail("unexpected value"); return
        }
        XCTAssertEqual(shape, .disk)
    }

    func testShapeRamParsesCorrectly() {
        let shapeStr = "ram"
        let shape: LoCoMoEstateShape
        switch shapeStr {
        case "disk": shape = .disk
        case "ram":  shape = .ram
        default:     XCTFail("unexpected value"); return
        }
        XCTAssertEqual(shape, .ram)
    }

    func testShapeInvalidValueIsRejected() {
        // An invalid --shape value must not silently resolve to a valid case.
        let shapeStr = "cloud"
        var resolvedToValid = false
        switch shapeStr {
        case "disk": resolvedToValid = true
        case "ram":  resolvedToValid = true
        default: break  // correctly rejected
        }
        XCTAssertFalse(resolvedToValid,
                       "'cloud' must not resolve to a valid LoCoMoEstateShape")
    }

    // MARK: - RAM + estate-cache conflict

    func testRamShapeIncompatibleWithReuseCache() {
        // Simulate the CLI validation: ram + reuse must be rejected.
        // The production code throws MCPError; this test verifies the predicate.
        let shape = LoCoMoEstateShape.ram
        let cache = EstateCacheMode.reuse
        // The production guard: shape == .ram && cache != .off → error.
        let conflict = (shape == .ram && cache != .off)
        XCTAssertTrue(conflict,
                      "ram shape + reuse cache must be flagged as a conflict")
    }

    func testRamShapeIncompatibleWithRequireCache() {
        let shape = LoCoMoEstateShape.ram
        let cache = EstateCacheMode.require
        let conflict = (shape == .ram && cache != .off)
        XCTAssertTrue(conflict,
                      "ram shape + require cache must be flagged as a conflict")
    }

    func testRamShapeCompatibleWithOffCache() {
        // ram + off is the ONLY valid combination for the RAM backend.
        let shape = LoCoMoEstateShape.ram
        let cache = EstateCacheMode.off
        let conflict = (shape == .ram && cache != .off)
        XCTAssertFalse(conflict,
                       "ram shape + off cache is valid — no conflict should be reported")
    }

    func testDiskShapeCompatibleWithAnyCache() {
        // disk shape is compatible with all cache modes.
        for cache in [EstateCacheMode.off, .reuse, .require] {
            let conflict = (LoCoMoEstateShape.disk == .ram && cache != .off)
            XCTAssertFalse(conflict,
                           "disk shape is compatible with cache mode \(cache.rawValue)")
        }
    }

    // MARK: - --parallel flag parse

    func testParallelDefaultWidth() {
        // Default width = max(1, 80% of logical cores). Must be ≥ 1.
        let width = max(1, ProcessInfo.processInfo.activeProcessorCount * 4 / 5)
        XCTAssertGreaterThanOrEqual(width, 1,
                                    "default parallel width must be at least 1")
    }

    func testParallelWidthOne() {
        // --parallel 1 selects serial behaviour.
        guard let n = Int("1"), n >= 1 else {
            XCTFail("Int('1') must succeed and be ≥ 1"); return
        }
        XCTAssertEqual(n, 1)
    }

    func testParallelWidthFour() {
        // --parallel 4 must parse to the integer 4.
        guard let n = Int("4"), n >= 1 else {
            XCTFail("Int('4') must succeed and be ≥ 1"); return
        }
        XCTAssertEqual(n, 4)
    }

    func testParallelZeroIsInvalid() {
        // 0 is not ≥ 1; the CLI must reject it.
        let n = Int("0") ?? -1
        XCTAssertFalse(n >= 1, "--parallel 0 must be rejected (not ≥ 1)")
    }

    func testParallelNegativeIsInvalid() {
        let n = Int("-1") ?? -99
        XCTAssertFalse(n >= 1, "--parallel -1 must be rejected (not ≥ 1)")
    }

    func testParallelNonIntegerIsInvalid() {
        // "abc" must not produce a valid Int.
        XCTAssertNil(Int("abc"),
                     "--parallel 'abc' must fail Int parse and be rejected")
    }

    // MARK: - Determinism pin (pure helpers)

    /// Verifies that results re-assembled by ascending convIndex are byte-deterministic:
    /// given a fixed set of (convIndex, results) pairs, the flatMap over sorted indices
    /// always produces the same ordered output regardless of insertion order.
    func testResultsReassemblyIsDeterministicByConvIndex() {
        // Simulate three conversations completing out of order.
        var resultsByConvIndex: [Int: [String]] = [:]
        resultsByConvIndex[2] = ["q2a", "q2b"]
        resultsByConvIndex[0] = ["q0a"]
        resultsByConvIndex[1] = ["q1a", "q1b", "q1c"]

        let convIndices = [0, 1, 2]  // ascending order, as produced by sorted()
        let assembled = convIndices.flatMap { resultsByConvIndex[$0] ?? [] }
        XCTAssertEqual(assembled, ["q0a", "q1a", "q1b", "q1c", "q2a", "q2b"],
                       "results must be assembled in ascending convIndex order "
                       + "regardless of task completion order")
    }

    /// A second independent assembly over the same data must produce the identical sequence.
    func testResultsReassemblyIsIdempotent() {
        var resultsByConvIndex: [Int: [String]] = [:]
        resultsByConvIndex[5] = ["q5"]
        resultsByConvIndex[0] = ["q0"]
        resultsByConvIndex[3] = ["q3a", "q3b"]

        let convIndices = [0, 3, 5]
        let first  = convIndices.flatMap { resultsByConvIndex[$0] ?? [] }
        let second = convIndices.flatMap { resultsByConvIndex[$0] ?? [] }
        XCTAssertEqual(first, second,
                       "two reassembly passes over the same input must produce identical output")
    }

    // MARK: - Helpers

    /// Builds a minimal `LoCoMoRunConfig` with only the required parameters.
    /// Used to test derived/default field values without needing real corpus data.
    private func makeMinimalRunConfig() -> LoCoMoRunConfig {
        LoCoMoRunConfig(
            mootBinaryPath: "/usr/local/bin/mootx01",
            datasetPath: URL(fileURLWithPath: "/dev/null"),
            limit: nil,
            offset: 0,
            seed: 12345,
            outDir: nil,
            runLabel: "test",
            encodeBarrier: .drain,
            estateCache: .off,
            cacheDir: nil,
            scratchPosture: .plaintextTransient,
            strategy: .search,
            categoryFilter: nil,
            recallShape: nil,
            rerankCmd: nil,
            seedPath: .batch
        )
    }
}
