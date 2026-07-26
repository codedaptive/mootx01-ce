import Testing
import Foundation
@testable import mcp_benchmarker

// LongMemEvalRunnerTests — pure unit tests for the LME runner infrastructure.
//
// These tests cover the non-live parts of LongMemEvalRunner.swift:
//   - lmeScratchDir() creates a directory with the /tmp/lme-bench- prefix
//   - lmeGuardedTeardown() accepts /tmp/lme-bench- paths and deletes them
//   - lmeGuardedTeardown() REFUSES paths without the /tmp/lme-bench- prefix
//   - lmeEndpointConfig() builds a valid EndpointConfig that passes assertScratchBackend
//   - assertScratchBackend refuses an endpoint with a non-/tmp data dir
//
// No live MCP calls are made. The GauntletLiveE2ETests.swift covers the live path.

@Suite("LME runner infrastructure")
struct LongMemEvalRunnerTests {

    // MARK: - lmeScratchDir

    @Test("lmeScratchDir creates a directory with the /tmp/lme-bench- prefix")
    func scratchDirHasCorrectPrefix() throws {
        let dir = try lmeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(dir.path.hasPrefix("/tmp/lme-bench-"),
                "scratch dir path should start with /tmp/lme-bench-: \(dir.path)")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
                "scratch dir should exist on disk")
        #expect(isDir.boolValue, "scratch dir should be a directory")
    }

    @Test("lmeScratchDir creates unique directories on successive calls")
    func scratchDirIsUnique() throws {
        let a = try lmeScratchDir()
        let b = try lmeScratchDir()
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        #expect(a.path != b.path, "successive scratch dirs should have distinct paths")
    }

    // MARK: - lmeGuardedTeardown

    @Test("lmeGuardedTeardown removes a valid /tmp/lme-bench- directory")
    func guardedTeardownRemovesDir() throws {
        let dir = try lmeScratchDir()
        // Write a sentinel file so we can verify the directory is fully removed.
        let sentinel = dir.appendingPathComponent("sentinel.txt")
        try "ok".write(to: sentinel, atomically: true, encoding: .utf8)

        try lmeGuardedTeardown(dir)

        #expect(!FileManager.default.fileExists(atPath: dir.path),
                "directory should be removed after guarded teardown")
    }

    @Test("lmeGuardedTeardown refuses a /tmp path WITHOUT the lme-bench prefix")
    func guardedTeardownRefusesNonLMEPath() throws {
        // A generic /tmp path must be refused — the guard exists to prevent
        // accidental deletion of non-LME scratch directories.
        let genericTmpPath = URL(fileURLWithPath: "/tmp/some-other-tool-dir")
        #expect(throws: MCPError.self) {
            try lmeGuardedTeardown(genericTmpPath)
        }
    }

    @Test("lmeGuardedTeardown refuses a path outside /tmp entirely")
    func guardedTeardownRefusesNonTmpPath() throws {
        let homePath = URL(fileURLWithPath: "\(NSHomeDirectory())/lme-bench-should-not-delete")
        #expect(throws: MCPError.self) {
            try lmeGuardedTeardown(homePath)
        }
    }

    @Test("lmeGuardedTeardown refuses the root /tmp path itself")
    func guardedTeardownRefusesTmpRoot() throws {
        // /tmp has no lme-bench- suffix — must be refused.
        #expect(throws: MCPError.self) {
            try lmeGuardedTeardown(URL(fileURLWithPath: "/tmp"))
        }
    }

    @Test("lmeGuardedTeardown does not throw when the directory was already removed")
    func guardedTeardownIsIdempotent() throws {
        // Create, then pre-delete so teardown finds nothing.
        let dir = try lmeScratchDir()
        try FileManager.default.removeItem(at: dir)
        // Should not throw — missing directory is a no-op (logged to stderr).
        try lmeGuardedTeardown(dir)
    }

    // MARK: - lmeEndpointConfig

    @Test("lmeEndpointConfig builds an endpoint that passes assertScratchBackend")
    func endpointConfigPassesScratchAssert() throws {
        let scratch = try lmeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Use a non-existent binary path — the function only builds the config
        // and validates the scratch constraint, it does not probe the binary.
        let fakeBinary = "/tmp/fake-mootx01-binary"
        let endpoint = try lmeEndpointConfig(
            scratchDir: scratch,
            mootBinaryPath: fakeBinary
        )
        // assertScratchBackend is called inside lmeEndpointConfig; if it threw,
        // we would not reach here.
        guard case let .stdio(command) = endpoint.transport else {
            Issue.record("expected stdio transport")
            return
        }
        #expect(command.contains("MOOTX01_DATA_DIR=/tmp/lme-bench-"),
                "command should contain MOOTX01_DATA_DIR=/tmp/lme-bench-: \(command)")
        #expect(command.contains(fakeBinary),
                "command should contain the binary path: \(command)")
    }

    @Test("assertScratchBackend rejects an endpoint with a non-/tmp MOOTX01_DATA_DIR")
    func assertScratchBackendRejectsNonTmpDataDir() {
        // Build an endpoint pointing at a non-tmp path.
        let nonTmpEndpoint = EndpointConfig(
            name: "mootx01-bad",
            transport: .stdio(command: "MOOTX01_DATA_DIR=/Users/bob/real-data /usr/local/bin/mootx01"),
            auth: nil,
            verbMap: lmeMootVerbMap,
            role: .target
        )
        #expect(throws: MCPError.self) {
            try assertScratchBackend(nonTmpEndpoint)
        }
    }

    @Test("assertScratchBackend accepts a valid MOOTX01_DATA_DIR=/tmp/lme-bench- command")
    func assertScratchBackendAcceptsLMEPath() throws {
        let scratch = try lmeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let endpoint = EndpointConfig(
            name: "mootx01-lme",
            transport: .stdio(command: "MOOTX01_DATA_DIR=\(scratch.path) /usr/local/bin/mootx01"),
            auth: nil,
            verbMap: lmeMootVerbMap,
            role: .target
        )
        // Should not throw.
        try assertScratchBackend(endpoint)
    }

    // MARK: - EncodeBarrier

    @Test("LMERunConfig accepts EncodeBarrier.drain as default")
    func lmeRunConfigEncodeBarrierDefault() {
        let config = LMERunConfig(
            mootBinaryPath: "/bin/moot",
            datasetPath: URL(fileURLWithPath: "/tmp/lme.json"),
            variant: "s",
            limit: nil, offset: 0, seed: 42,
            freshPerQuestion: true,
            outDir: nil,
            runLabel: "test",
            arm: .both,
            judgeCmd: nil,
            encodeBarrier: .drain
        )
        #expect(config.encodeBarrier == .drain)
        #expect(config.encodeBarrier.rawValue == "drain")
    }

    @Test("EncodeBarrier raw values match their JSON key names")
    func encodeBarrierRawValues() {
        #expect(EncodeBarrier.drain.rawValue == "drain")
        #expect(EncodeBarrier.impatient.rawValue == "impatient")
        #expect(EncodeBarrier.none.rawValue == "none")
    }

    // MARK: - Twin CLI contract (Defect 4)

    // Verifies that the Swift CLI helper accepts both the Swift-native flag
    // spelling and the Rust twin's spelling, and that --data-dir takes priority
    // when both are present. This mirrors the Rust test `cli_alias_data_dir`.
    @Test("optionValue: --data-dir takes priority over --corpus when both present")
    func dataDirTakesPriorityOverCorpus() {
        let args = ["--corpus", "/corpus-path", "--data-dir", "/datadir-path"]
        let chosen = optionValue("--data-dir", in: args) ?? optionValue("--corpus", in: args)
        #expect(chosen == "/datadir-path", "explicit --data-dir should win over --corpus alias")
    }

    @Test("optionValue: --corpus alias works when --data-dir is absent")
    func corpusAliasWorksForLME() {
        let args = ["--corpus", "/corpus-path", "--variant", "s"]
        let chosen = optionValue("--data-dir", in: args) ?? optionValue("--corpus", in: args)
        #expect(chosen == "/corpus-path", "--corpus alias should be used when --data-dir is absent")
    }

    @Test("optionValue: --data-file takes priority over --corpus for LoCoMo when both present")
    func dataFileTakesPriorityOverCorpus() {
        let args = ["--corpus", "/corpus-path", "--data-file", "/datafile-path"]
        let chosen = optionValue("--data-file", in: args) ?? optionValue("--corpus", in: args)
        #expect(chosen == "/datafile-path", "--data-file should win over --corpus alias")
    }

    @Test("optionValue: --corpus alias works for LoCoMo when --data-file is absent")
    func corpusAliasWorksForLoCoMo() {
        let args = ["--corpus", "/locomo.json"]
        let chosen = optionValue("--data-file", in: args) ?? optionValue("--corpus", in: args)
        #expect(chosen == "/locomo.json", "--corpus alias should work as --data-file substitute")
    }

    @Test("optionValue: --mootx01-binary takes priority over --binary when both present")
    func mootx01BinaryTakesPriorityOverBinary() {
        let args = ["--binary", "/bin/moot-b", "--mootx01-binary", "/bin/moot-a"]
        let chosen = optionValue("--mootx01-binary", in: args) ?? optionValue("--binary", in: args)
        #expect(chosen == "/bin/moot-a", "--mootx01-binary should win over --binary alias")
    }

    @Test("optionValue: --binary alias works when --mootx01-binary is absent")
    func binaryAliasWorks() {
        let args = ["--binary", "/usr/local/bin/mootx01"]
        let chosen = optionValue("--mootx01-binary", in: args) ?? optionValue("--binary", in: args)
        #expect(chosen == "/usr/local/bin/mootx01", "--binary alias should work as --mootx01-binary substitute")
    }

    // MARK: - VerbMap

    @Test("lmeMootVerbMap uses the correct mootx01 tool names")
    func verbMapCorrect() {
        #expect(lmeMootVerbMap.write == "moot_file_memory")
        #expect(lmeMootVerbMap.query == "moot_memory_search")
        #expect(lmeMootVerbMap.constantArgs["location"] == "benchmark/longmemeval")
        // resultFormat must be .mootText (not jsonObjects).
        if case .mootText = lmeMootVerbMap.resultFormat {
            // Correct.
        } else {
            Issue.record("lmeMootVerbMap.resultFormat should be .mootText")
        }
    }
}
