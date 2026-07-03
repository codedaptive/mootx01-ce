import Foundation
import Testing
@testable import moot_bridge

// BridgeAcceptanceTests.swift — the LIVE end-to-end acceptance proof.
//
// Drives the built `moot-bridge` binary over stdio against two SCRATCH backends
// (MemPalace + mootx01) and asserts the full acceptance sequence from the
// mission:
//   initialize → tools/list (primary's tools + bridge tools present) → write
//   (verify it landed in BOTH backends via each one's own read tool) → read
//   (primary's answer) → bridge_set_primary to the other backend → read again (now
//   the other backend answers) → bridge_status shows the swap.
//
// SAFETY: scratch backends only — temp palace + temp MOOTX01_DATA_DIR under
// /tmp, torn down per run. Never the real palace or real mootx01 data dir.
//
// This suite is SKIPPED (via the `.enabled(if:)` trait — Swift Testing has no
// runtime skip, so a thrown "skip" error records as a FAILURE; that broke the
// first CI `make test` gate) when the `mempalace-mcp` / `mootx01` binaries are
// not on PATH or the moot-bridge binary is not built (e.g. CI without them
// installed), so the pure-logic suites still run everywhere. The mission
// requires it to actually run on the dev machine, where both are installed.

/// Absolute path to the mempalace-mcp binary, or nil when unavailable.
private let mempalaceMCPPath: String? = whichBinary("mempalace-mcp")
/// Absolute path to the mootx01 binary, or nil when unavailable.
private let mootx01BinPath: String? = whichBinary("mootx01")
/// Absolute path to the moot-bridge binary built in this SPM package, or nil
/// when not yet built.  The test runner and the binary land in the same
/// .build/<config>/ directory under SPM, so a bundle-sibling lookup is the
/// canonical strategy; no machine-specific fallback path.
private let mootBridgeBinPath: String? = bridgeBinaryPath()

@Suite(
    "moot-bridge live acceptance",
    .serialized,
    // One trait per probe so a skip names exactly which prerequisite is
    // missing — a combined condition hides the failing probe and turns
    // every unexpected skip into a debugging session.
    .enabled(if: mempalaceMCPPath != nil, "mempalace-mcp not on PATH — live acceptance needs it; pure-logic suites still run"),
    .enabled(if: mootx01BinPath != nil, "mootx01 not on PATH — live acceptance needs it; pure-logic suites still run"),
    .enabled(if: mootBridgeBinPath != nil, "moot-bridge binary not found in the package .build products dir — build it (swift build) before the live acceptance"))
struct BridgeAcceptanceTests {

    /// The full scripted live session. One test so the ordered sequence (write
    /// then read then swap then read) runs against one shared pair of scratch
    /// backends, exactly as a real client would drive it.
    @Test func fullBridgeSession() async throws {
        // --- Scratch backends + config -------------------------------------
        let tmp = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let mpDir = tmp.appendingPathComponent("mp").path
        let mootDir = tmp.appendingPathComponent("moot").path
        try FileManager.default.createDirectory(atPath: mpDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: mootDir, withIntermediateDirectories: true)

        let statsPath = tmp.appendingPathComponent("stats.sqlite").path
        let configPath = tmp.appendingPathComponent("config.json").path
        try writeConfig(mpDir: mpDir, mootDir: mootDir).write(
            toFile: configPath, atomically: true, encoding: .utf8)

        let token = "ACC_TOKEN_\(UUID().uuidString.prefix(8))"

        // --- Drive the bridge over stdio -------------------------------------
        // The scripted client requests, one JSON-RPC object per line.
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"acc","version":"0"}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#,
            // write (MemPalace is primary) → fans out to mootx01 too
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"mempalace_add_drawer","arguments":{"wing":"scratch","room":"notes","content":"\#(token) the quick brown fox"}}}"#,
            // read from primary (MemPalace)
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"mempalace_search","arguments":{"query":"\#(token)"}}}"#,
            // flip primary to mootx01
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"bridge_set_primary","arguments":{"backend":"mootx01"}}}"#,
            // read again — now answered by mootx01 (its own search tool)
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"moot_memory_search","arguments":{"query":"\#(token)"}}}"#,
            // status reflects the swap
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"bridge_status","arguments":{}}}"#,
        ]
        let responses = try runBridgeBinary(configPath: configPath, statsPath: statsPath,
                                          requests: requests)
        let byID = indexByID(responses)

        // --- id2: tools/list carries primary's tools + the two bridge tools ---
        let toolNames = try toolListNames(byID[2])
        #expect(toolNames.contains("mempalace_search"))     // a primary tool
        #expect(toolNames.contains("mempalace_add_drawer")) // a primary tool
        #expect(toolNames.contains("bridge_set_primary"))     // bridge-owned
        #expect(toolNames.contains("bridge_status"))          // bridge-owned

        // --- id3: write succeeded on the primary ---------------------------
        let writeText = try resultText(byID[3])
        #expect(writeText.contains("drawer_id"))            // MemPalace write result

        // --- id4: read from primary (MemPalace) finds the token ------------
        let primaryReadText = try resultText(byID[4])
        #expect(primaryReadText.contains(token))
        // MemPalace shape leaks through (the jsonObjects `results` envelope).
        #expect(primaryReadText.contains("results"))

        // --- id5: bridge_set_primary confirms the swap -----------------------
        let swapText = try resultText(byID[5])
        #expect(swapText.contains("mootx01"))

        // --- id6: read AFTER swap is answered by mootx01 -------------------
        let secondaryReadText = try resultText(byID[6])
        #expect(secondaryReadText.contains(token))
        // mootText shape proves mootx01 answered (not MemPalace JSON).
        #expect(secondaryReadText.contains("found"))
        #expect(secondaryReadText.contains("[scratch/notes]"))

        // --- id7: bridge_status reflects the swap ----------------------------
        let statusText = try resultText(byID[7])
        #expect(statusText.contains("primary:   mootx01"))
        #expect(statusText.contains("secondary: mempalace"))

        // --- The write landed in BOTH backends (each via its own read) -----
        let inMemPalace = try directMemPalaceHasToken(token, palaceDir: mpDir)
        #expect(inMemPalace, "write must have landed in MemPalace")
        let inMootx01 = try directMootx01HasToken(token, dataDir: mootDir)
        #expect(inMootx01, "write must have fanned out to mootx01")

        // --- The stats store contains BOTH backends' series ----------------
        let series = try statsStoreSeries(at: statsPath)
        #expect(series.contains(where: { $0.hasPrefix("mempalace.") }),
                "stats store must contain MemPalace series")
        #expect(series.contains(where: { $0.hasPrefix("mootx01.") }),
                "stats store must contain mootx01 series (incl. the .mirror fan-out)")
    }

    // MARK: - Harness

    /// Builds the acceptance config JSON pinned to the given scratch dirs.
    private func writeConfig(mpDir: String, mootDir: String) -> String {
        """
        {
          "backendA": {
            "name": "mempalace",
            "command": "mempalace-mcp --palace \(mpDir)",
            "verbMap": {
              "write": "mempalace_add_drawer",
              "query": "mempalace_search",
              "constantArgs": { "wing": "scratch", "room": "notes" },
              "resultFormat": { "kind": "jsonObjects", "contentKey": "text" }
            }
          },
          "backendB": {
            "name": "mootx01",
            "command": "MOOTX01_DATA_DIR=\(mootDir) mootx01 serve",
            "verbMap": {
              "write": "moot_file_memory",
              "query": "moot_memory_search",
              "constantArgs": { "location": "scratch/notes" },
              "resultFormat": { "kind": "mootText" }
            }
          },
          "primary": "mempalace"
        }
        """
    }

    /// Runs the built moot-bridge binary, pipes `requests` to its stdin, and
    /// returns the response lines parsed as JSONValue.
    private func runBridgeBinary(configPath: String, statsPath: String,
                               requests: [String]) throws -> [JSONValue] {
        let bin = try #require(mootBridgeBinPath)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["--config", configPath, "--stats-store", statsPath]
        // Ensure the backend launch commands resolve mempalace-mcp / mootx01.
        // Prepend the user's local bin dir (derived from HOME, not hard-wired)
        // so binaries installed via standard packaging helpers are found without
        // a machine-specific absolute path.
        var env = ProcessInfo.processInfo.environment
        let localBin = (env["HOME"] ?? "") + "/.local/bin"
        env["PATH"] = localBin + ":" + (env["PATH"] ?? "")
        proc.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()

        // Feed all requests, then close stdin so the bridge shuts down at EOF.
        let payload = (requests.joined(separator: "\n") + "\n").data(using: .utf8)!
        inPipe.fileHandleForWriting.write(payload)
        // Brief settle so the async mirror fan-out completes before EOF teardown.
        Thread.sleep(forTimeInterval: 0.8)
        inPipe.fileHandleForWriting.closeFile()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        _ = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        return outData.split(separator: 0x0A).compactMap { lineSlice in
            try? JSONDecoder().decode(JSONValue.self, from: Data(lineSlice))
        }
    }

    private func indexByID(_ responses: [JSONValue]) -> [Int: JSONValue] {
        var out: [Int: JSONValue] = [:]
        for r in responses {
            if case let .number(n)? = r["id"] { out[Int(n)] = r }
        }
        return out
    }

    /// Extracts the tool names from a tools/list response.
    private func toolListNames(_ response: JSONValue?) throws -> [String] {
        let tools = try #require(response?["result"]?["tools"]?.arrayValue)
        return tools.compactMap { $0["name"]?.stringValue }
    }

    /// Extracts the concatenated text of a tools/call result's content blocks.
    private func resultText(_ response: JSONValue?) throws -> String {
        let content = try #require(response?["result"]?["content"]?.arrayValue)
        return content.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
    }

    // MARK: - Direct backend verification

    /// Queries MemPalace directly (not through the bridge) for the token.
    private func directMemPalaceHasToken(_ token: String, palaceDir: String) throws -> Bool {
        let out = try driveBackend(
            command: mempalaceMCPPath!,
            args: ["--palace", palaceDir],
            env: nil,
            queryTool: "mempalace_search",
            args2: ["query": token])
        return out.contains(token)
    }

    /// Queries mootx01 directly (not through the bridge) for the token.
    private func directMootx01HasToken(_ token: String, dataDir: String) throws -> Bool {
        let out = try driveBackend(
            command: mootx01BinPath!,
            args: ["serve"],
            env: ["MOOTX01_DATA_DIR": dataDir],
            queryTool: "moot_memory_search",
            args2: ["query": token])
        return out.contains(token)
    }

    /// Drives a backend directly: initialize + one search tools/call; returns the
    /// concatenated stdout text. Used to verify a write landed independently of
    /// the bridge.
    private func driveBackend(command: String, args: [String], env: [String: String]?,
                              queryTool: String, args2: [String: String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: command)
        proc.arguments = args
        if let env {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in env { merged[k] = v }
            proc.environment = merged
        }
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()

        let argsJSON = args2.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"v","version":"0"}}}"#,
            "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"\(queryTool)\",\"arguments\":{\(argsJSON)}}}",
        ]
        inPipe.fileHandleForWriting.write((lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.5)
        inPipe.fileHandleForWriting.closeFile()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        _ = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: out, encoding: .utf8) ?? ""
    }

    // MARK: - Stats store read

    /// Returns the distinct `series` tag values among the bridge's latency rows.
    private func statsStoreSeries(at path: String) throws -> [String] {
        // Read the stats store via the sqlite3 CLI to avoid coupling the test to
        // ObserverSink's internal schema/API. The bridge emits one row per series
        // tag under name='bridge.latency_ms.mean'.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        proc.arguments = [
            path,
            "SELECT DISTINCT json_extract(tags,'$.series') FROM metric_samples WHERE name='bridge.latency_ms.mean';",
        ]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        try proc.run()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (String(data: out, encoding: .utf8) ?? "")
            .split(separator: "\n").map(String.init)
    }

    // MARK: - Utilities

    private func makeScratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moot-bridge-acc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

}

/// Locates the built moot-bridge binary in this package's .build products
/// directory, or returns nil when it has not been built.
///
/// Resolution is `#filePath`-anchored: this source file sits at
/// `<pkg>/Tests/moot-bridgeTests/`, so the package root is two levels up and
/// the executable lands in `<pkg>/.build/<config>/moot-bridge`. Bundle-based
/// lookups do NOT work under the swift-testing runner: `Bundle.main` is the
/// swiftpm-testing-helper in the TOOLCHAIN directory, and the dlopened
/// .xctest bundle does not appear in `Bundle.allBundles` — both silently
/// resolve nowhere, the probe returns nil, and the suite skips everywhere,
/// which defeats the live acceptance. `#filePath` is compile-time and always
/// points at the package checkout that `swift test` is building from.
/// No machine-specific absolute path — the suite's `.enabled(if:)` trait
/// skips gracefully when nil (e.g. CI without the backends).
private func bridgeBinaryPath() -> String? {
    let pkgRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // moot-bridgeTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // package root
    for config in ["debug", "release"] {
        let candidate = pkgRoot
            .appendingPathComponent(".build/\(config)/moot-bridge").path
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

/// Resolves a binary on PATH (plus the standard local bin dir derived from
/// HOME), or nil.  HOME-relative expansion avoids machine-specific absolute
/// paths while still finding binaries installed by standard packaging helpers
/// (brew install --user, pip install --user, etc.). File-scope so the
/// suite-availability globals above can evaluate it for the `.enabled(if:)`
/// trait.
private func whichBinary(_ name: String) -> String? {
    let env = ProcessInfo.processInfo.environment
    let localBin = (env["HOME"] ?? "") + "/.local/bin"
    let dirs = ([localBin] + (env["PATH"]?.split(separator: ":").map(String.init) ?? []))
    for d in dirs {
        let p = d + "/" + name
        if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return nil
}
