// QueryCommand.swift
//
// Issue a single JSON-RPC tools/call to the ARIA MCP server and print the
// result.
//
// Transport selection (mirrors query.rs in the Rust vertical):
//
//   1. Resident HTTP daemon — when no `--db` override is given and the resident
//      daemon is alive (TCP probe on the resolved port), POST the tools/call
//      frame directly. The HTTP endpoint is stateless: one POST, one response.
//      This preserves the single-writer guarantee — we never open a second
//      writer (serve subprocess) while the resident daemon holds the DB.
//
//   2. stdio subprocess — when no daemon is running, or `--db` is given (the
//      named estate is always served via subprocess regardless of what the
//      daemon serves). Spawns a short-lived
//      `mootx01 serve`, performs the MCP handshake (initialize → initialized →
//      tools/call), reads the response, then terminates the subprocess.
//
// Tool name mapping: the user passes the ARIA verb without the `moot_` prefix
// (e.g. `memory_search`) and this command prepends it.
//
// Arguments are passed as `--key value` pairs and decoded as JSON where
// possible (numbers, booleans) or left as strings.

import ArgumentParser
import Foundation
import GeniusLocusKit
import MootInstallerCore

struct QueryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "query",
        abstract: "Issue a single ARIA tool call (resident HTTP when available, stdio subprocess otherwise).",
        discussion: """
        If you are a cloud agent that cannot reach `127.0.0.1` on the user's
        machine and MCP `moot_*` tools are absent, use `mootx01-botLink` on the
        user's computer. Do not use `mootx01 query`. Do not open a remote MCP
        URL. If `moot_*` MCP tools exist (Cursor on the Mac), use those and
        stop.
        """
    )

    @Argument(help: "ARIA verb name without moot_ prefix, e.g. 'drawer_recall'.")
    var verb: String

    @Option(name: .long, help: "Estate to query: a registered name, or <dir>/<name> for a transient estate (forces the subprocess path). Default: the active estate.")
    var db: String?

    @Flag(name: .long, help: "Output raw JSON instead of human-readable text.")
    var json: Bool = false

    @Argument(parsing: .remaining, help: "Tool arguments as --key value pairs.")
    var remaining: [String] = []

    func run() async throws {
        // `--db` is resolved by the catalog here, so a bad value fails in this
        // process with the catalog's message instead of inside the serve child.
        // The value itself is passed to serve unchanged; serve resolves it the
        // same way.
        if let db {
            do { _ = try EstateCatalog.open(selecting: db) } catch {
                fputs("mootx01 query: \(error)\n", stderr)
                throw ExitCode.failure
            }
        }

        let toolName = "moot_\(verb)"
        let arguments = parseArguments(remaining)

        let toolsCall = jsonrpc(id: 2, method: "tools/call", params: [
            "name": toolName,
            "arguments": arguments
        ])

        // Transport select: live daemon (HTTP, stateless per frame) unless --db
        // pins a specific estate — mirroring query.rs transport-select logic.
        let resolvedPort = MootPaths.resolvedResidentPort(dataDir: EstateCatalog.configurationDirectory)
        if db == nil && daemonAlive(port: resolvedPort) {
            // Resident daemon is up: POST the tools/call frame directly.
            // No second writer opened — the daemon already holds the DB.
            let result = try await postToDaemon(toolsCall, port: resolvedPort)
            try render(result)
        } else {
            // No resident daemon (daemon down or --db pins a specific estate the
            // resident doesn't serve). Spawn a short-lived stdio subprocess.
            let result = try await subprocessCall(frame: toolsCall)
            try render(result)
        }
    }

    // MARK: - Resident HTTP path

    /// TCP probe: is the daemon listening on `port`? Delegates to the
    /// shared `McpLoopback.daemonAlive` seam (BL-1) — one probe for query
    /// and botlink, 250 ms timeout mirroring `daemon_client::alive` in the
    /// Rust vertical.
    private func daemonAlive(port: Int) -> Bool {
        McpLoopback.daemonAlive(port: port)
    }

    /// POST one JSON-RPC frame to the resident daemon and return the parsed
    /// response. Uses URLSession for a clean async/await HTTP client — no
    /// external dependencies, Foundation-only. Mirrors `daemon_client::post_frame`
    /// in the Rust vertical.
    ///
    /// - Parameters:
    ///   - frame: the JSON-RPC request string (single line).
    ///   - port: the daemon's loopback port.
    /// - Returns: the parsed JSON-RPC response object.
    private func postToDaemon(_ frame: String, port: Int) async throws -> [String: Any] {
        guard let url = URL(string: "http://127.0.0.1:\(port)/"),
              let body = frame.data(using: .utf8) else {
            fputs("mootx01 query: cannot construct daemon request\n", stderr)
            throw ExitCode.failure
        }

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("close", forHTTPHeaderField: "Connection")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            fputs("mootx01 query: daemon returned HTTP \(http.statusCode)\n", stderr)
            throw ExitCode.failure
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fputs("mootx01 query: daemon returned non-JSON response\n", stderr)
            throw ExitCode.failure
        }
        return obj
    }

    // MARK: - stdio subprocess path

    /// Spawn a short-lived `mootx01 serve [--db name]` subprocess and send one
    /// JSON-RPC frame through `McpOneShot.subprocessCall` (MootInstallerCore) —
    /// the shared handshake + one-frame machinery this method's body was
    /// generalized into for BL-1 so `mootx01 botlink` uses the same seam.
    /// Accepts any JSON-RPC method frame; `query` itself always passes a
    /// `tools/call` frame with id 2. Mirrors `subprocess_call` in query.rs.
    private func subprocessCall(frame: String) async throws -> [String: Any] {
        // Resolve the absolute binary path from the bundle rather than argv[0].
        // CommandLine.arguments.first returns whatever the parent passed as argv[0],
        // which can be a relative path or a bare name controlled by the caller.
        // Bundle.main.executableURL gives the absolute, standardized path of the
        // running binary — immune to argv[0] manipulation (planned hardening).
        guard let execURL = Bundle.main.executableURL?.standardizedFileURL,
              execURL.path.hasPrefix("/") else {
            fputs("mootx01 query: cannot resolve absolute executable path for subprocess\n", stderr)
            throw ExitCode.failure
        }
        var serveArgs = ["serve"]
        if let dbName = db {
            serveArgs.append(contentsOf: ["--db", dbName])
        }

        do {
            guard let obj = try await McpOneShot.subprocessCall(
                binaryPath: execURL.path,
                serveArgs: serveArgs,
                frame: frame,
                expectID: 2,
                clientName: "mootx01-query"
            ) else {
                // Unreachable with a non-nil expectID; kept for exhaustiveness.
                fputs("mootx01 query: no response received from serve subprocess\n", stderr)
                throw ExitCode.failure
            }
            return obj
        } catch is McpOneShotError {
            fputs("mootx01 query: no response received from serve subprocess\n", stderr)
            throw ExitCode.failure
        }
    }

    // MARK: - Render

    /// Print the response. If `--json`, dump the whole object; otherwise
    /// extract `result.content[].text` for human-readable output.
    private func render(_ obj: [String: Any]) throws {
        if let err = obj["error"] {
            fputs("mootx01 query: tool error: \(err)\n", stderr)
            throw ExitCode.failure
        }
        guard let result = obj["result"] else {
            fputs("mootx01 query: no result field in response\n", stderr)
            throw ExitCode.failure
        }

        if json {
            if let data = try? JSONSerialization.data(
                withJSONObject: result,
                options: [.prettyPrinted, .withoutEscapingSlashes]
            ) {
                print(String(decoding: data, as: UTF8.self))
            }
        } else {
            printHuman(result)
        }
    }

    // MARK: - Argument parsing

    /// Parse `["--key", "value", "--key2", "value2"]` into a dictionary.
    /// Values that parse as JSON integers or booleans are decoded as such.
    ///
    /// ## Conformance rules (parity with Rust `parse_kv_args`)
    ///
    /// - A leading bare `--` is skipped (bash-style option terminator). This
    ///   lets `mootx01 query moot_tool -- --key value` work correctly.
    /// - Non-`--` tokens (positional args) are silently skipped.
    /// - Flag-style: `--key` followed by another `--` arg or end-of-args
    ///   sets `key = true`.
    private func parseArguments(_ args: [String]) -> [String: Any] {
        var result: [String: Any] = [:]
        var i = 0
        while i < args.count {
            let arg = args[i]
            guard arg.hasPrefix("--") else { i += 1; continue }
            let key = String(arg.dropFirst(2))
            // Skip a bare "--" separator (bash-style option terminator). Without
            // this guard, `dropFirst(2)` produces an empty key that inserts
            // `result[""] = true`, silently polluting the argument dictionary.
            guard !key.isEmpty else { i += 1; continue }
            if i + 1 < args.count && !args[i + 1].hasPrefix("--") {
                let raw = args[i + 1]
                result[key] = decodeValue(raw)
                i += 2
            } else {
                // Flag-style argument: treat as true.
                result[key] = true
                i += 1
            }
        }
        return result
    }

    private func decodeValue(_ s: String) -> Any {
        if let i = Int(s) { return i }
        if s == "true" { return true }
        if s == "false" { return false }
        return s
    }

    // MARK: - Human-readable output

    private func printHuman(_ result: Any) {
        guard let obj = result as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            print(result)
            return
        }
        for item in content {
            if let text = item["text"] as? String {
                print(text)
            } else if let data = try? JSONSerialization.data(
                withJSONObject: item,
                options: [.prettyPrinted]
            ) {
                print(String(decoding: data, as: UTF8.self))
            }
        }
    }

    // MARK: - JSON-RPC helpers

    /// Frame encoding delegates to the shared `McpOneShot.encodeFrame` seam
    /// (BL-1) — one encoder for query and botlink, no parallel implementations.
    private func jsonrpc(id: Int?, method: String, params: [String: Any]) -> String {
        McpOneShot.encodeFrame(id: id, method: method, params: params)
    }
}
