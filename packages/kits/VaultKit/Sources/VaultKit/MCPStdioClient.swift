import Foundation

// MCPStdioClient.swift — a minimal MCP client over a local stdio server,
// lifted from the proven mcp-benchmarker MCPClient (our code) and narrowed to
// exactly what the outbound pump needs: launch the server, do the MCP
// `initialize` handshake, call `tools/list`, and call `tools/call`.
//
// Wire protocol: JSON-RPC 2.0, newline-delimited (one JSON object per line) —
// the MCP stdio framing. The server is launched via Process() with an explicit
// program + argv array + env dict — never as a whitespace-split command
// string. Splitting a command string on whitespace causes palace paths
// containing spaces to corrupt the argument list, and concatenating env-var
// prefixes into a single string (e.g. "KEY=val cmd --arg") relies on shell
// interpretation which is both fragile and a shell-injection surface. The
// caller passes the program, arguments, and extra env vars separately so each
// value is delivered byte-for-byte to the child process without any
// shell-metacharacter interpretation.
//
// Concurrency: an actor, so JSON-RPC requests over the single transport are
// serialized — request ids stay monotonic and stdio reads/writes never
// interleave. The blocking stdout read runs on a DETACHED THREAD and hops the
// result back via a continuation: FileHandle.readabilityHandler's dispatch
// source is unreliable for repeated rapid sequential reads (it can leak the
// continuation — "continuation misuse" — and deadlock). A one-shot blocking
// read per call has no such failure mode and matches this request/response
// cadence. This is the exact pattern proven in the benchmarker.

/// An error raised while talking to the MCP server.
public struct MCPClientError: Error, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// One tool result: the raw text content blocks the server returned. The pump
/// parses these with the Palace*Parsing helpers — it never guesses the inner
/// JSON shape here, keeping transport and parsing separate.
public struct MCPCallResult: Sendable, Equatable {
    /// The text payloads from the MCP `content` array, in order.
    public let textBlocks: [String]
    /// The raw `tools/list` (or other) result JSON, for callers that need the
    /// whole structured result rather than just text blocks (drift detection
    /// reads `tools/list` this way).
    public let rawResultJSON: Data

    public init(textBlocks: [String], rawResultJSON: Data) {
        self.textBlocks = textBlocks
        self.rawResultJSON = rawResultJSON
    }
}

/// A client bound to one local stdio MCP server. Launch with ``connect()``,
/// then call ``listTools()`` / ``callTool(_:arguments:)``, then
/// ``disconnect()``.
///
/// The server is spawned directly (no shell) with the supplied `program`,
/// `args`, and extra `env` entries. Values are delivered byte-for-byte to the
/// child — no whitespace splitting, no shell interpretation.
public actor MCPStdioClient {

    /// The MCP server binary path or name (resolved via PATH by Process).
    private let program: String
    /// Positional arguments to pass to the server (e.g. ["--palace", "/tmp/p"]).
    private let args: [String]
    /// Extra environment variables injected into the child process in addition
    /// to the inherited environment. Use this for keys such as
    /// `MEMPALACE_PALACE_PATH` instead of embedding them in a command string.
    private let extraEnv: [String: String]

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputHandle: FileHandle?
    private var outputBuffer = Data()
    private var nextRequestID = 1

    /// - Parameters:
    ///   - program: the MCP server binary (e.g. `"mempalace-mcp"`).
    ///   - args: positional arguments (e.g. `["--palace", "/tmp/p"]`).
    ///   - env: extra environment variables for the child process (e.g.
    ///     `["MEMPALACE_PALACE_PATH": "/tmp/p"]`). Merged over the inherited
    ///     environment; the caller is responsible for not overriding critical
    ///     keys such as `PATH`.
    public init(program: String, args: [String] = [], env: [String: String] = [:]) {
        self.program = program
        self.args = args
        self.extraEnv = env
    }

    /// Launch the server and perform the MCP `initialize` handshake
    /// (protocolVersion 2024-11-05). Must be called before any tool call.
    public func connect() async throws {
        try launch()
        _ = try await sendRequest(method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:],
            "clientInfo": ["name": "mootx01-pump", "version": "1.0.0"],
        ])
    }

    /// Terminate the server process. Safe to call more than once.
    public func disconnect() {
        inputPipe?.fileHandleForWriting.closeFile()
        process?.terminate()
        process = nil
        inputPipe = nil
        outputHandle = nil
        outputBuffer.removeAll()
    }

    /// Call `tools/list` and return the raw result JSON (drift detection
    /// parses the `tools` array from it).
    public func listTools() async throws -> Data {
        let result = try await sendRequest(method: "tools/list", params: [:])
        return try JSONSerialization.data(withJSONObject: result)
    }

    /// Call one tool by name with the given arguments. Returns the text
    /// blocks from the MCP `content` array plus the raw result JSON.
    ///
    /// - Parameters:
    ///   - name: the MCP tool name.
    ///   - arguments: the tool arguments as a JSON-object dictionary.
    public func callTool(_ name: String, arguments: [String: Any]) async throws -> MCPCallResult {
        let result = try await sendRequest(method: "tools/call", params: [
            "name": name,
            "arguments": arguments,
        ])
        var textBlocks: [String] = []
        if let object = result as? [String: Any],
           let content = object["content"] as? [[String: Any]] {
            for block in content where (block["type"] as? String) == "text" {
                if let text = block["text"] as? String { textBlocks.append(text) }
            }
        }
        let raw = try JSONSerialization.data(withJSONObject: result)
        return MCPCallResult(textBlocks: textBlocks, rawResultJSON: raw)
    }

    // MARK: - JSON-RPC core

    /// Send one JSON-RPC request and return its `result` value (as a
    /// Foundation JSON object). Throws on a JSON-RPC `error` or transport
    /// failure.
    private func sendRequest(method: String, params: [String: Any]) async throws -> Any {
        let id = nextRequestID
        nextRequestID += 1
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]
        let requestData = try JSONSerialization.data(withJSONObject: envelope)
        let responseData = try await sendLine(requestData)

        guard let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw MCPClientError("malformed JSON-RPC response (not an object)")
        }
        if let error = response["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "unknown JSON-RPC error"
            throw MCPClientError("JSON-RPC error: \(message)")
        }
        guard let result = response["result"] else {
            throw MCPClientError("JSON-RPC response had no result")
        }
        return result
    }

    // MARK: - stdio transport

    private func launch() throws {
        // Resolve the program through /usr/bin/env so plain binary names like
        // "mempalace-mcp" are found via PATH, matching the behaviour callers
        // expect. The argv array is passed intact — no whitespace splitting, no
        // shell. Extra env vars from `extraEnv` are merged over the inherited
        // environment so each key=value pair is delivered to the child
        // byte-for-byte without any shell-metacharacter interpretation.
        guard !program.isEmpty else {
            throw MCPClientError("empty program name")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // /usr/bin/env receives [program, arg1, arg2, ...]; it resolves
        // `program` via PATH and exec's it with the remaining args.
        proc.arguments = [program] + args
        if !extraEnv.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in extraEnv { env[k] = v }
            proc.environment = env
        }
        let input = Pipe()
        let output = Pipe()
        proc.standardInput = input
        proc.standardOutput = output
        try proc.run()
        self.process = proc
        self.inputPipe = input
        self.outputHandle = output.fileHandleForReading
    }

    /// Write one newline-delimited JSON-RPC message and read one line back.
    private func sendLine(_ requestData: Data) async throws -> Data {
        guard let input = inputPipe, let output = outputHandle else {
            throw MCPClientError("stdio transport not connected")
        }
        var line = requestData
        line.append(0x0A)  // '\n' — MCP stdio framing is one object per line.
        input.fileHandleForWriting.write(line)
        return try await readLine(from: output)
    }

    /// Read bytes from stdout until a newline delimits one complete JSON-RPC
    /// message; return that message's bytes.
    private func readLine(from handle: FileHandle) async throws -> Data {
        while true {
            if let newlineIndex = outputBuffer.firstIndex(of: 0x0A) {
                let lineData = outputBuffer[outputBuffer.startIndex..<newlineIndex]
                outputBuffer.removeSubrange(outputBuffer.startIndex...newlineIndex)
                if lineData.isEmpty { continue }  // skip blank lines
                return Data(lineData)
            }
            let chunk = await readAvailableData(from: handle)
            if chunk.isEmpty {
                throw MCPClientError("stdio stream closed before a full message")
            }
            outputBuffer.append(chunk)
        }
    }

    /// Await the next stdout chunk without blocking the actor's executor: the
    /// blocking `availableData` read runs on a detached thread and the result
    /// hops back via the continuation. Empty chunk = EOF. (See file header for
    /// why this is preferred over readabilityHandler.)
    private func readAvailableData(from handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let data = handle.availableData
                continuation.resume(returning: data)
            }
        }
    }
}
