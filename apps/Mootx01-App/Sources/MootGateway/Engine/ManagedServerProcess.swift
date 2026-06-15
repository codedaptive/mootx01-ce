import Foundation
import AriaMCP   // JSONValue, JSONRPCRequest, JSONRPCResponse

// MARK: - ManagedServerProcess  (the "app-managed daemon" — macOS only)
//
// This is the macOS-only "extra" from ADR-005: the app spawns the *real,
// untouched* server binary (aria-mcp / mootx01 serve) as a child process and
// talks to it over stdio JSON-RPC. The server stays the clean, Rust-mirrored
// binary — we add no code to it; we only launch and supervise it. That keeps
// the parity boundary intact (all new code is Apple-side).
//
// Why macOS-only: iOS/iPadOS cannot spawn a persistent subprocess, so the
// managed-daemon and the database "handoff" it enables exist only on the Mac.
// On iOS the engine is always embedded in-process.
//
// Transport shape: stdout carries only newline-delimited JSON-RPC responses
// (the server logs to stderr, per ARIA_MCP_SPEC §5), so a continuous reader
// can split on newlines and fulfill pending requests by id. Requests are
// serialized through this actor.

#if os(macOS)

public actor ManagedServerProcess {

    public enum LaunchError: Error, CustomStringConvertible {
        case binaryNotFound(String)
        case notRunning
        case alreadyRunning
        public var description: String {
            switch self {
            case .binaryNotFound(let p): return "Server binary not found at \(p)"
            case .notRunning: return "Managed server is not running"
            case .alreadyRunning: return "Managed server is already running"
            }
        }
    }

    private let binaryURL: URL
    /// The estate this managed server owns (handed off to it). nil = ephemeral
    /// in-memory estate in the child.
    private let databaseURL: URL?

    private var process: Process?
    private let inPipe = Pipe()
    private let outPipe = Pipe()

    private var nextID: Int64 = 1
    /// Requests awaiting their response line, keyed by JSON-RPC id.
    private var pending: [Int64: CheckedContinuation<JSONRPCResponse, Never>] = [:]
    private var readBuffer = Data()

    public init(binaryURL: URL, databaseURL: URL?) {
        self.binaryURL = binaryURL
        self.databaseURL = databaseURL
    }

    public nonisolated var databasePath: String? { databaseURL?.path }

    public var isRunning: Bool { process?.isRunning ?? false }

    /// Spawn the server. The child owns `databaseURL` (SQLite) if given —
    /// this is where a handed-off estate is "taken over." The parent must
    /// already have released that estate (ADR-005: one host per estate).
    ///
    /// Trust model: this method spawns an arbitrary binary at a
    /// caller-supplied path and hands it the app's full process environment.
    /// In production, the caller SHOULD verify the binary's code-signing
    /// identity (SecStaticCodeCheckValidity) and team ID before calling
    /// start(), to ensure only a known, signed server binary is spawned.
    /// This prototype omits that check to keep the mechanism demonstrable;
    /// a production host must add it.
    public func start() throws {
        guard process == nil else { throw LaunchError.alreadyRunning }
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw LaunchError.binaryNotFound(binaryURL.path)
        }
        let proc = Process()
        proc.executableURL = binaryURL
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        // Leave stderr attached to the parent's so server logs are visible.
        var env = ProcessInfo.processInfo.environment
        if let databaseURL { env["ARIA_MCP_SQLITE_PATH"] = databaseURL.path }
        proc.environment = env

        // Continuous reader: split stdout on newlines, resolve pending requests.
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { await self?.ingest(chunk) }
        }

        try proc.run()
        process = proc
    }

    public func stop() {
        outPipe.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        // Fail any in-flight requests rather than leaking continuations.
        for (_, cont) in pending {
            cont.resume(returning: .failure(.null, JSONRPCError(
                code: JSONRPCErrorCode.internalError, message: "managed server stopped")))
        }
        pending.removeAll()
    }

    /// Send one request to the child and await its response line.
    public func send(method: String, params: JSONValue?) async throws -> JSONRPCResponse {
        guard let process, process.isRunning else { throw LaunchError.notRunning }
        let id = nextID; nextID += 1
        let request = JSONRPCRequest(id: .integer(id), method: method, params: params)
        var line = try request.asRequestJSONValue.encoded()
        line.append(0x0A)
        return await withCheckedContinuation { cont in
            pending[id] = cont
            inPipe.fileHandleForWriting.write(line)
        }
    }

    // MARK: reader

    private func ingest(_ chunk: Data) {
        readBuffer.append(chunk)
        while let nl = readBuffer.firstIndex(of: 0x0A) {
            let lineData = readBuffer.subdata(in: readBuffer.startIndex..<nl)
            readBuffer.removeSubrange(readBuffer.startIndex...nl)
            guard !lineData.isEmpty,
                  let value = try? JSONValue.parse(lineData),
                  let object = value.objectValue,
                  let id = object["id"]?.integerValue else { continue }
            guard let cont = pending.removeValue(forKey: id) else { continue }
            cont.resume(returning: Self.decodeResponse(object, id: .integer(id)))
        }
    }

    private static func decodeResponse(_ object: [String: JSONValue], id: JSONValue) -> JSONRPCResponse {
        if let result = object["result"] {
            return .ok(id, result)
        }
        if let err = object["error"]?.objectValue {
            let code = err["code"]?.integerValue.map(Int.init) ?? JSONRPCErrorCode.internalError
            let message = err["message"]?.stringValue ?? "error"
            return .failure(id, JSONRPCError(code: code, message: message, data: err["data"]))
        }
        return .failure(id, JSONRPCError(code: JSONRPCErrorCode.internalError, message: "malformed response"))
    }
}

#endif
