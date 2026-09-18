import Testing
import Foundation
@testable import mcp_benchmarker

// GauntletSafetyTests — the scratch-backend safety gate (plan rules 1-2) for
// the core (moot-only) lane: the moot endpoint MUST carry `--db /tmp/...`
// (a transient catalog record). The requirement is data (`ScratchRequirement`),
// so the same gate serves any caller-supplied form; an extension package
// tests its own baseline product's form beside its requirement.
// A config that fails the check must throw BEFORE any write. Pure: no live backend.

@Suite("Gauntlet safety gate (core, moot scratch requirement)")
struct GauntletSafetyTests {

    private func mootEndpoint(command: String) -> EndpointConfig {
        EndpointConfig(name: "mootx01",
                       transport: .stdio(command: command),
                       auth: nil,
                       verbMap: EndpointConfig.VerbMap(
                           write: "moot_file_memory", query: "moot_memory_search",
                           list: nil, constantArgs: [:], resultFormat: .mootText),
                       role: .target)
    }

    @Test("mootx01 with --db /tmp passes")
    func mootScratchPasses() throws {
        try assertScratchBackend(
            mootEndpoint(command: "~/.mootx01/bin/mootx01 serve --db /tmp/bench-moot"),
            requirement: mootScratchRequirement)
    }

    @Test("mootx01 without a /tmp data dir is refused")
    func mootRealDataDirRefused() {
        #expect(throws: MCPError.self) {
            try assertScratchBackend(mootEndpoint(command: "~/.mootx01/bin/mootx01"),
                                     requirement: mootScratchRequirement)
        }
    }

    @Test("aria-mcp with --db /tmp passes (the same catalog selector as mootx01)")
    func ariaMcpScratchPasses() throws {
        // aria-mcp selects its estate through the catalog with the same --db
        // flag; a /tmp directory attaches a transient record there.
        try assertScratchBackend(mootEndpoint(
            command: "/tmp/aria-mcp --db /tmp/gauntlet-moot"),
            requirement: mootScratchRequirement)
    }

    @Test("aria-mcp --db pointing outside /tmp is refused")
    func ariaMcpNonTmpRefused() {
        // The /tmp prefix is the contamination guard — a real estate directory
        // must be refused whichever binary names it.
        #expect(throws: MCPError.self) {
            try assertScratchBackend(mootEndpoint(
                command: "/tmp/aria-mcp --db ~/.mootx01/estates/default"),
                requirement: mootScratchRequirement)
        }
    }

    @Test("a /tmp-prefix look-alike path (/tmp.evil) is refused")
    func tmpPrefixLookAlikeRefused() {
        // The env-var value is parsed and checked independently, so a path like
        // /tmp.evil/estates (where "/tmp" is a string prefix but not the
        // directory) must be refused.
        #expect(throws: MCPError.self) {
            try assertScratchBackend(mootEndpoint(
                command: "~/.mootx01/bin/mootx01 serve --db /tmp.evil/estates"),
                requirement: mootScratchRequirement)
        }
    }

    @Test("non-stdio endpoint is refused regardless of requirement")
    func nonStdioRefused() {
        let endpoint = EndpointConfig(
            name: "remote",
            transport: .sse(url: URL(string: "https://example.invalid/mcp")!),
            auth: nil,
            verbMap: EndpointConfig.VerbMap(
                write: "moot_file_memory", query: "moot_memory_search",
                list: nil, constantArgs: [:], resultFormat: .mootText),
            role: .target)
        #expect(throws: MCPError.self) {
            try assertScratchBackend(endpoint, requirement: mootScratchRequirement)
        }
    }

    @Test("mootServeCommand throws ScratchPostureError not traps — CLI path exits 1 not 101")
    func serveCommandErrorPropagatesAsThrownNotTrap() throws {
        // W4: mootServeCommand throws(ScratchPostureError) rather than trapping.
        // The CLI path: benchmarkerMain in CLI.swift catches any thrown Error and
        // calls exit(1). This test verifies the error path for whitespace-in-path
        // is a thrown error, not a preconditionFailure / fatalError (which would
        // produce exit code 134 or 132). Twin of the Rust
        // endpoint_config_error_propagates_as_err_not_panic test.
        let spaceyPath = URL(fileURLWithPath: "/tmp/path with spaces")
        let noSpaceConfig = URL(fileURLWithPath: "/tmp/no-space-config-w4")
        #expect(throws: ScratchPostureError.self) {
            try mootServeCommand(
                binary: "/tmp/mootx01", scratchDir: spaceyPath,
                productConfigDir: noSpaceConfig)
        }
        do {
            _ = try mootServeCommand(
                binary: "/tmp/mootx01", scratchDir: spaceyPath,
                productConfigDir: noSpaceConfig)
        } catch ScratchPostureError.whitespaceInPath {
            // Correct: thrown error (not a trap) means the CLI can catch it and exit 1
        } catch {
            Issue.record("expected .whitespaceInPath but got: \(error)")
        }
    }

    @Test("mootEndpoint(in:) selects the moot endpoint by write-verb prefix regardless of role")
    func mootSelection() throws {
        let other = EndpointConfig(
            name: "other",
            transport: .stdio(command: "other-mcp --data /tmp/x"),
            auth: nil,
            verbMap: EndpointConfig.VerbMap(
                write: "other_write", query: "other_search",
                list: nil, resultFormat: .jsonObjects(idKey: nil, contentKey: "text")),
            role: .source)
        let config = BenchmarkerConfig(
            source: other,
            target: mootEndpoint(command: "~/.mootx01/bin/mootx01 serve --db /tmp/m"))
        let moot = try mcp_benchmarker.mootEndpoint(in: config)
        #expect(moot.name == "mootx01")
    }

    @Test("mcp-benchmarker exits 1 (not 101) on configuration refusal — CLI boundary (X4)")
    func cliExits1NotTrapOnConfigRefusal() throws {
        // X4 CLI boundary test: run the built binary with an estate directory containing
        // a space. `payload-economics --estate-dir '/tmp/bilby x4 estate'`
        // reaches mootServeCommand(scratchDir:) whose first guard is the whitespace
        // check (ScratchPosture.swift). Swift's benchmarkerMain catches any thrown Error
        // and calls exit(1); a panic or preconditionFailure would produce exit 101.
        //
        // Port asymmetry (residual): Swift's mootServeCommand guards only scratchDir.path
        // for whitespace; Rust's moot_serve_command guards both the binary path and the
        // scratch path. Both ports correctly abort to exit 1 on a whitespace refusal.
        //
        // Fixture layout: minimal files that let the runner pass questions/corpus
        // loading and reach the serve launch, where the whitespace guard fires.
        // estate.sqlite is written as an empty file; id-map.json is an empty object.
        //
        // Three hops up from this source file lands on the suite root, where SPM
        // places the binary under .build/out/Products/Debug/.
        let binaryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // mcp-benchmarkerTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // the suite root (benchmarks/)
            .appendingPathComponent(".build/out/Products/Debug/mcp-benchmarker")
        guard FileManager.default.fileExists(atPath: binaryURL.path) else {
            Issue.record("Binary not found at \(binaryURL.path); build with `swift build` first")
            return
        }

        // Build minimal fixture tree under /tmp/bilby x4 * to reach the serve launch.
        let fm = FileManager.default
        // The estate directory carries a space: mootServeCommand(scratchDir:) refuses it.
        let estateDir = "/tmp/bilby x4 estate"
        let dataDir   = "/tmp/bilby-x4-data"
        let questionsPath = "/tmp/bilby-x4-q.jsonl"

        try? fm.createDirectory(atPath: estateDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: dataDir,   withIntermediateDirectories: true)

        // Empty SQLite file — sqlite3_open_v2 succeeds.
        fm.createFile(atPath: "\(estateDir)/estate.sqlite", contents: nil)
        // id-map.json is read before the serve launches.
        let idMap = "{}".data(using: .utf8)!
        fm.createFile(atPath: "\(estateDir)/id-map.json", contents: idMap)

        // One well-formed question for the s-variant corpus.
        let corpusJSON = """
        [{"question_id":"q001","question_type":"single_session","question":"What did the user say?",\
        "answer":"hello","question_date":"2024-01-01","haystack_dates":["2024-01-01"],\
        "haystack_session_ids":["S1"],"haystack_sessions":[[{"role":"user","content":"hello"}]],\
        "answer_session_ids":["S1"]}]
        """.data(using: .utf8)!
        fm.createFile(atPath: "\(dataDir)/longmemeval_s_cleaned.json", contents: corpusJSON)

        // One matching question line for the JSONL input.
        let qLine = #"{"question_id":"q001","question":"What did the user say?","answer_session_ids":["S1"]}"#
        fm.createFile(atPath: questionsPath, contents: (qLine + "\n").data(using: .utf8)!)

        let proc = Process()
        proc.executableURL = binaryURL
        // The estate directory carries a space; mootServeCommand's whitespace
        // guard fires and propagates through benchmarkerMain → exit(1).
        proc.arguments = [
            "payload-economics",
            "--estate-dir",      estateDir,
            "--questions",       questionsPath,
            "--data-dir",        dataDir,
            "--binary",          "/usr/bin/true",
        ]
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        #expect(proc.terminationStatus == 1,
            "whitespace refusal must exit 1 (not 101/134): got \(proc.terminationStatus), stderr=\(stderr)")
        #expect(!stderr.contains("panicked at"),
            "exit must come from thrown error, not a trap: stderr=\(stderr)")
        #expect(stderr.contains("whitespace"),
            "stderr must name the whitespace refusal: stderr=\(stderr)")
    }
}
