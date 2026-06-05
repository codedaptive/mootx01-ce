// QueryCommand.swift
//
// v1.0 MCP passthrough: issue a single JSON-RPC tools/call to the ARIA
// MCP server and print the result.
//
// If a `mootx01 serve` is running (detected via PID file), this command
// advises the user to use their MCP client directly — stdio is the only
// transport and we cannot attach to a running server's stdin.
//
// If no server is running, spawns a short-lived `mootx01 serve`
// subprocess, performs the MCP handshake, issues the tools/call,
// reads the response, then terminates the subprocess.
//
// Tool name mapping: the user passes the ARIA name without the `moot_`
// prefix (e.g. `drawer_recall`) and this command adds it back, so the
// full wire name is `moot_drawer_recall`.
//
// Arguments are passed as `--key value` pairs and decoded as JSON where
// possible (numbers, booleans) or left as strings.

import ArgumentParser
import Foundation
import MootInstallerCore

struct QueryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "query",
        abstract: "Issue a single ARIA tool call (v1.0: MCP subprocess passthrough)."
    )

    @Argument(help: "ARIA verb name without moot_ prefix, e.g. 'drawer_recall'.")
    var verb: String

    @Option(name: .long, help: "Named estate to query. Default: active estate.")
    var db: String?

    @Flag(name: .long, help: "Output raw JSON instead of human-readable text.")
    var json: Bool = false

    @Argument(parsing: .remaining, help: "Tool arguments as --key value pairs.")
    var remaining: [String] = []

    func run() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        let dataDir = MootPaths.resolveDataDirectory(environment: env, homeDirectory: home)

        // Warn if a serve is already running — we can't piggyback on its stdio.
        let pidURL = dataDir.appendingPathComponent("mootx01.pid", isDirectory: false)
        if let pidStr = try? String(contentsOf: pidURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidStr), kill(pid, 0) == 0 {
            fputs("Note: mootx01 serve is running (PID \(pid)). Using a separate query subprocess.\n", stderr)
        }

        let toolName = "moot_\(verb)"
        let arguments = parseArguments(remaining)

        // Build JSON-RPC request sequence.
        let initRequest = jsonrpc(id: 1, method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "mootx01-query", "version": "1.0.0"]
        ])
        let initializedNotif = jsonrpc(id: nil, method: "initialized", params: [:] as [String: Any])
        let toolsCall = jsonrpc(id: 2, method: "tools/call", params: [
            "name": toolName,
            "arguments": arguments
        ])

        // Spawn a short-lived serve subprocess.
        let binaryPath = CommandLine.arguments.first ?? "mootx01"
        var serveArgs = ["serve"]
        if let dbName = db {
            serveArgs.append(contentsOf: ["--db", dbName])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = serveArgs

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Write JSON-RPC messages to the subprocess stdin.
        let inputHandle = stdinPipe.fileHandleForWriting
        func writeLine(_ msg: String) {
            if let data = (msg + "\n").data(using: .utf8) {
                inputHandle.write(data)
            }
        }

        writeLine(initRequest)
        // Wait briefly for init response before sending initialized + call.
        try await Task.sleep(nanoseconds: 100_000_000) // 100 ms
        writeLine(initializedNotif)
        writeLine(toolsCall)

        // Read responses from stdout. We want the response with id=2.
        try await Task.sleep(nanoseconds: 500_000_000) // 500 ms settle time
        inputHandle.closeFile()

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // Parse newline-delimited JSON-RPC responses.
        let lines = String(decoding: outputData, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)

        var toolResult: Any?
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? Int, id == 2 else { continue }
            if let result = obj["result"] {
                toolResult = result
            } else if let err = obj["error"] {
                fputs("Tool error: \(err)\n", stderr)
                throw ExitCode.failure
            }
        }

        guard let result = toolResult else {
            fputs("No response received. Is the serve command working?\n", stderr)
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
            // Human-readable: extract text content from MCP content array.
            printHuman(result)
        }
    }

    // MARK: - Argument parsing

    /// Parse `["--key", "value", "--key2", "value2"]` into a dictionary.
    /// Values that parse as JSON integers or booleans are decoded as such.
    private func parseArguments(_ args: [String]) -> [String: Any] {
        var result: [String: Any] = [:]
        var i = 0
        while i < args.count {
            let arg = args[i]
            guard arg.hasPrefix("--") else { i += 1; continue }
            let key = String(arg.dropFirst(2))
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

    private func jsonrpc(id: Int?, method: String, params: [String: Any]) -> String {
        var msg: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ]
        if let id { msg["id"] = id }
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
