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
import MootInstallerCore

struct QueryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "query",
        abstract: "Issue a single ARIA tool call (resident HTTP when available, stdio subprocess otherwise)."
    )

    @Argument(help: "ARIA verb name without moot_ prefix, e.g. 'drawer_recall'.")
    var verb: String

    @Option(name: .long, help: "Named estate to query. Default: active estate (forces subprocess path).")
    var db: String?

    @Flag(name: .long, help: "Output raw JSON instead of human-readable text.")
    var json: Bool = false

    @Argument(parsing: .remaining, help: "Tool arguments as --key value pairs.")
    var remaining: [String] = []

    func run() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        let dataDir = MootPaths.resolveDataDirectory(environment: env, homeDirectory: home)

        let toolName = "moot_\(verb)"
        let arguments = parseArguments(remaining)

        let toolsCall = jsonrpc(id: 2, method: "tools/call", params: [
            "name": toolName,
            "arguments": arguments
        ])

        // Transport select: live daemon (HTTP, stateless per frame) unless --db
        // pins a specific estate — mirroring query.rs transport-select logic.
        let resolvedPort = MootPaths.resolvedResidentPort(dataDir: dataDir)
        if db == nil && daemonAlive(port: resolvedPort) {
            // Resident daemon is up: POST the tools/call frame directly.
            // No second writer opened — the daemon already holds the DB.
            let result = try await postToDaemon(toolsCall, port: resolvedPort)
            try render(result)
        } else {
            // No resident daemon (daemon down or --db pins a specific estate the
            // resident doesn't serve). Spawn a short-lived stdio subprocess.
            let result = try await subprocessCall(toolsCall: toolsCall)
            try render(result)
        }
    }

    // MARK: - Resident HTTP path

    /// TCP probe: is the daemon listening on `port`? 250 ms timeout mirrors
    /// `daemon_client::alive` in the Rust vertical.
    private func daemonAlive(port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        // Non-blocking connect with poll for 250 ms.
        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = 0x0100007F // 127.0.0.1 as little-endian host-byte-order (0x7F000001 in big-endian/network order)

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if connectResult == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&pfd, 1, 250) // 250 ms
        guard ready > 0 else { return false }

        // Confirm the connection completed without error.
        var sockErr: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(sock, SOL_SOCKET, SO_ERROR, &sockErr, &len)
        return sockErr == 0
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

    /// Spawn a short-lived `mootx01 serve [--db name]` subprocess, send the
    /// MCP handshake (initialize → initialized notification → tools/call), and
    /// return the id=2 response object. Mirrors `subprocess_call` in query.rs.
    ///
    /// Wire shape note: the Rust vertical sends only `initialize` + `tools/call`
    /// (skipping the `initialized` notification). This Swift path sends all three
    /// frames. The server accepts both — `initialized` is a no-op notification;
    /// the extra frame adds no observable latency difference. Both are valid MCP.
    private func subprocessCall(toolsCall: String) async throws -> [String: Any] {
        let initRequest = jsonrpc(id: 1, method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "mootx01-query", "version": "1.0.0"]
        ])
        let initializedNotif = jsonrpc(id: nil, method: "initialized", params: [:] as [String: Any])

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
        let binaryPath = execURL.path
        var serveArgs = ["serve"]
        if let dbName = db {
            serveArgs.append(contentsOf: ["--db", dbName])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = serveArgs

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        // INHERIT the parent's stderr rather than piping it. A captured-but-never-
        // drained stderr pipe deadlocks any tool that writes more than the OS pipe
        // buffer (~64KB) to stderr: the child blocks in fputs() once the buffer
        // fills while the parent blocks in readDataToEndOfFile() on stdout, so
        // neither side progresses. `moot_palace_import` emits a progress line every
        // 10 records (~4,800 lines for a 48K-drawer palace), which overflows the
        // buffer and hangs the import. Inheriting forwards the child's live
        // progress straight to the user's terminal and removes the pipe entirely.
        process.standardError = FileHandle.standardError

        try process.run()

        let inputHandle = stdinPipe.fileHandleForWriting
        func writeLine(_ msg: String) {
            if let data = (msg + "\n").data(using: .utf8) {
                inputHandle.write(data)
            }
        }

        writeLine(initRequest)
        // Brief settle: allow the server to process initialize before sending
        // initialized + call. 100 ms is sufficient on macOS — the subprocess
        // is local and the estate is already on disk.
        try await Task.sleep(nanoseconds: 100_000_000)
        writeLine(initializedNotif)
        writeLine(toolsCall)

        // Give the server time to process the call, then close stdin to signal
        // end-of-input so it exits cleanly.
        try await Task.sleep(nanoseconds: 500_000_000)
        inputHandle.closeFile()

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let lines = String(decoding: outputData, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? Int, id == 2 else { continue }
            return obj
        }

        fputs("mootx01 query: no response received from serve subprocess\n", stderr)
        throw ExitCode.failure
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
