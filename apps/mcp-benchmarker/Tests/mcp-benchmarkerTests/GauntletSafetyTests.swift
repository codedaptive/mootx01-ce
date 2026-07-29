import Testing
import Foundation
@testable import mcp_benchmarker

// GauntletSafetyTests — the scratch-backend safety gate (plan rules 1-2). These
// pin the contamination-bug guard: contender MUST use the --contender-dir FLAG to a /tmp
// path; mootx01 MUST set MOOTX01_DATA_DIR=/tmp or ARIA_MCP_SQLITE_PATH=/tmp.
// A config that fails any of these must throw BEFORE any write. Pure: no live backend.

@Suite("Gauntlet safety gate")
struct GauntletSafetyTests {

    private func contenderEndpoint(command: String) -> EndpointConfig {
        EndpointConfig(name: "contender",
                       transport: .stdio(command: command),
                       auth: nil,
                       verbMap: EndpointConfig.VerbMap(
                           write: "contender_add_drawer", query: "contender_search",
                           list: nil, resultFormat: .jsonObjects(idKey: nil, contentKey: "text")),
                       role: .source)
    }

    private func mootEndpoint(command: String) -> EndpointConfig {
        EndpointConfig(name: "mootx01",
                       transport: .stdio(command: command),
                       auth: nil,
                       verbMap: EndpointConfig.VerbMap(
                           write: "moot_file_memory", query: "moot_memory_search",
                           list: nil, constantArgs: [:], resultFormat: .mootText),
                       role: .target)
    }

    @Test("contender with the --contender-dir /tmp FLAG passes")
    func contenderFlagPasses() throws {
        try assertScratchBackend(contenderEndpoint(command: "contender-mcp --contender-dir /tmp/bench-contender"))
    }

    @Test("contender WITHOUT --contender-dir is refused (the bare-call contamination bug)")
    func contenderBareCallRefused() {
        // The exact bug the plan calls out: a call without --contender-dir leaves the
        // data dir at the real path. Only the FLAG form is accepted; this must throw.
        #expect(throws: MCPError.self) {
            try assertScratchBackend(contenderEndpoint(command: "contender-mcp"))
        }
    }

    @Test("contender --contender-dir pointing outside /tmp is refused")
    func contenderNonTmpRefused() {
        #expect(throws: MCPError.self) {
            try assertScratchBackend(contenderEndpoint(command: "contender-mcp --contender-dir ~/.contender"))
        }
    }

    @Test("mootx01 with MOOTX01_DATA_DIR=/tmp passes")
    func mootScratchPasses() throws {
        try assertScratchBackend(mootEndpoint(command: "MOOTX01_DATA_DIR=/tmp/bench-moot ~/.mootx01/bin/mootx01"))
    }

    @Test("mootx01 without a /tmp data dir is refused")
    func mootRealDataDirRefused() {
        #expect(throws: MCPError.self) {
            try assertScratchBackend(mootEndpoint(command: "~/.mootx01/bin/mootx01"))
        }
    }

    @Test("aria-mcp with ARIA_MCP_SQLITE_PATH=/tmp passes (durable-estate scratch form)")
    func ariaMcpSqlitePathScratchPasses() throws {
        // The aria-mcp binary selects an explicit on-disk estate (and lights up
        // semantic recall) via ARIA_MCP_SQLITE_PATH. A /tmp target is a valid
        // scratch form for the gauntlet, on par with MOOTX01_DATA_DIR=/tmp.
        try assertScratchBackend(mootEndpoint(
            command: "ARIA_MCP_SQLITE_PATH=/tmp/gauntlet-moot/estate.sqlite3 /tmp/aria-mcp"))
    }

    @Test("aria-mcp ARIA_MCP_SQLITE_PATH pointing outside /tmp is refused")
    func ariaMcpSqlitePathNonTmpRefused() {
        // The /tmp prefix is the contamination guard — a real on-disk estate path
        // must still be refused even with the new env-var form.
        #expect(throws: MCPError.self) {
            try assertScratchBackend(mootEndpoint(
                command: "ARIA_MCP_SQLITE_PATH=~/.mootx01/estate.sqlite3 /tmp/aria-mcp"))
        }
    }

    @Test("classifyEndpoints identifies contender and moot by write-verb prefix regardless of role")
    func classify() throws {
        let config = BenchmarkerConfig(
            source: contenderEndpoint(command: "contender-mcp --contender-dir /tmp/p"),
            target: mootEndpoint(command: "MOOTX01_DATA_DIR=/tmp/m ~/.mootx01/bin/mootx01"))
        let (contender, moot) = try classifyEndpoints(config)
        #expect(contender.name == "contender")
        #expect(moot.name == "mootx01")
    }
}
