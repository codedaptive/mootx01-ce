import Foundation

// RawMCPBackend.swift — a raw, verbatim, id-preserving stdio JSON-RPC forwarder
// to one MCP backend.
//
// Carried over (our code) from the proven benchmarker ProxyServer.swift. The
// bridge must preserve the client's exact request ids on the primary path and pass
// arbitrary methods (initialize, tools/list, tools/call, notifications) through
// untouched, so it needs this lower-level forwarder rather than a verb-scoped
// client. The actor serializes calls, so a response is matched to its request by
// ORDERING on the single transport — the bridge issues one request at a time per
// backend.

/// Raw, verbatim, id-preserving stdio JSON-RPC forwarder to one MCP backend.
actor RawMCPBackend {
    let name: String
    private let command: String

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputHandle: FileHandle?
    private var outputBuffer = Data()

    init(name: String, command: String) {
        self.name = name
        self.command = command
    }

    /// Launches the backend process. The command is operator-supplied and
    /// treated at CLI-argument trust level (same boundary as the benchmarker):
    /// it is split on whitespace and run via `/usr/bin/env`, so an env-var prefix
    /// (e.g. `MOOTX01_DATA_DIR=/tmp/... /path/mootx01 serve`) is honored — env
    /// assignments before the program name are consumed by `env` itself.
    func start() throws {
        let parts = command.split(separator: " ").map(String.init)
        guard let program = parts.first else {
            throw MCPError(description: "empty command for backend \(name)")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [program] + parts.dropFirst()
        let input = Pipe()
        let output = Pipe()
        proc.standardInput = input
        proc.standardOutput = output
        try proc.run()
        self.process = proc
        self.inputPipe = input
        self.outputHandle = output.fileHandleForReading
    }

    /// Tears the backend down. Safe to call more than once.
    func stop() {
        inputPipe?.fileHandleForWriting.closeFile()
        process?.terminate()
        process = nil
        inputPipe = nil
        outputHandle = nil
        outputBuffer.removeAll()
    }

    /// Sends one already-encoded JSON-RPC message (a request with an id) and
    /// returns the backend's response bytes verbatim. The actor serializes calls,
    /// so the response is matched to its request by ordering on the single
    /// transport — the bridge issues one request at a time per backend.
    func sendAndReceive(_ message: Data) async throws -> Data {
        guard let input = inputPipe, let output = outputHandle else {
            throw MCPError(description: "backend \(name) not started")
        }
        var line = message
        line.append(0x0A)
        input.fileHandleForWriting.write(line)
        return try await readLine(from: output)
    }

    /// Sends a JSON-RPC notification (no id, no response expected).
    func sendNotification(_ message: Data) throws {
        guard let input = inputPipe else {
            throw MCPError(description: "backend \(name) not started")
        }
        var line = message
        line.append(0x0A)
        input.fileHandleForWriting.write(line)
    }

    /// Reads one newline-delimited message from the backend stdout.
    private func readLine(from handle: FileHandle) async throws -> Data {
        while true {
            if let nl = outputBuffer.firstIndex(of: 0x0A) {
                let lineData = outputBuffer[outputBuffer.startIndex..<nl]
                outputBuffer.removeSubrange(outputBuffer.startIndex...nl)
                if lineData.isEmpty { continue }
                return Data(lineData)
            }
            let chunk = await readAvailableData(from: handle)
            if chunk.isEmpty {
                throw MCPError(description: "backend \(name) closed its stream")
            }
            outputBuffer.append(chunk)
        }
    }

    /// One-shot async read of the next stdout chunk without blocking the actor
    /// executor. Detached-blocking-read pattern: `FileHandle.availableData` is a
    /// synchronous blocking read, so it runs on a detached thread and resumes the
    /// continuation when bytes arrive. The readability-handler source alternative
    /// leaks continuations under repeated reads (the continuation-leak rationale
    /// documented at the benchmarker's MCPClient.swift:288-293), so this one-shot
    /// detached read is used throughout instead.
    private func readAvailableData(from handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let data = handle.availableData
                continuation.resume(returning: data)
            }
        }
    }
}
