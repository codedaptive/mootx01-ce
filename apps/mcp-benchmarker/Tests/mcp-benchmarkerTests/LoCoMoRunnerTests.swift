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
        let url = try loCoMoScratchDir(posture: .plaintextOptOut)
        defer { try? loCoMoGuardedTeardown(url) }

        XCTAssert(url.path.hasPrefix("/tmp/locomo-bench-"),
                  "scratch dir must start with /tmp/locomo-bench-: \(url.path)")
        XCTAssert(FileManager.default.fileExists(atPath: url.path),
                  "scratch dir must exist after creation: \(url.path)")
    }

    func testScratchDirIsDirectory() throws {
        let url = try loCoMoScratchDir(posture: .plaintextOptOut)
        defer { try? loCoMoGuardedTeardown(url) }

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        XCTAssert(exists && isDir.boolValue,
                  "scratch path must be a directory: \(url.path)")
    }

    func testScratchDirIsUnique() throws {
        let a = try loCoMoScratchDir(posture: .plaintextOptOut)
        let b = try loCoMoScratchDir(posture: .plaintextOptOut)
        defer {
            try? loCoMoGuardedTeardown(a)
            try? loCoMoGuardedTeardown(b)
        }
        XCTAssertNotEqual(a.path, b.path,
                          "two loCoMoScratchDir(posture:) calls must produce unique paths")
    }

    func testGuardedTeardownRemovesDir() throws {
        let url = try loCoMoScratchDir(posture: .plaintextOptOut)
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
        XCTAssertEqual(loc, "benchmark/locomo",
                       "constant args must set location=benchmark/locomo")
    }

    func testVerbMapResultFormat() {
        if case .mootText = loCoMoMootVerbMap.resultFormat {
            // Pass
        } else {
            XCTFail("resultFormat must be .mootText, got \(loCoMoMootVerbMap.resultFormat)")
        }
    }
}
