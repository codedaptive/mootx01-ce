// McpOneShot.swift
//
// BL-1: one-shot MCP-over-stdio subprocess machinery, generalized from
// QueryCommand's original tools/call-only `subprocessCall`. Spawns a
// short-lived `mootx01 serve` subprocess, performs the MCP handshake
// (initialize → initialized notification → the one caller-supplied
// frame), reads the matching response, closes stdin so the subprocess
// exits, and returns the parsed response object.
//
// Lives in MootInstallerCore (not the `mootx01` executable target) per
// this app's established split: MootInstallerCore holds testable logic;
// the executable target is a thin CLI wrapper. Both `mootx01 query` and
// `mootx01 botlink` call through this single seam — one implementation,
// two command-layer wrappers, no parallel subprocess paths.
//
// Wire shape note: the Rust vertical sends only `initialize` + the call
// (skipping the `initialized` notification). This Swift path sends all
// three frames. The server accepts both — `initialized` is a no-op
// notification; the extra frame adds no observable latency difference.
// Both are valid MCP.

import Foundation

/// Errors surfaced by `McpOneShot.subprocessCall`.
public enum McpOneShotError: Error, CustomStringConvertible {
    /// The subprocess exited (or closed stdout) without emitting a
    /// response frame whose id matches the request's id.
    case noResponse

    public var description: String {
        switch self {
        case .noResponse:
            return "no response received from serve subprocess"
        }
    }
}

/// One-shot JSON-RPC-over-stdio MCP calls against a spawned subprocess.
public enum McpOneShot {

    /// Encode one newline-free JSON-RPC 2.0 frame.
    ///
    /// - Parameters:
    ///   - id: the request id; `nil` produces a notification (no `id` key).
    ///   - method: the JSON-RPC method (e.g. `"tools/call"`, `"tools/list"`).
    ///   - params: the params object.
    /// - Returns: the encoded frame as a single-line JSON string. Returns an
    ///   empty string only if `params` contains non-JSON-encodable values,
    ///   which no caller in this package constructs.
    public static func encodeFrame(id: Int?, method: String, params: [String: Any]) -> String {
        var msg: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ]
        if let id { msg["id"] = id }
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Spawn `binaryPath serveArgs...`, handshake, send `frame`, and return
    /// the response object whose `id` equals `expectID`.
    ///
    /// - Parameters:
    ///   - binaryPath: absolute path of the binary to spawn. Command layers
    ///     resolve this via `Bundle.main.executableURL` (argv[0] is
    ///     caller-controlled and untrusted); tests point it at a stub script.
    ///   - serveArgs: subprocess arguments (typically `["serve"]` or
    ///     `["serve", "--db", name]`).
    ///   - frame: the one JSON-RPC frame to send after the handshake.
    ///   - expectID: the request frame's id. Matched against response `id`
    ///     via Foundation object equality, so `Int` and `String` ids both
    ///     work (the `rpc` escape hatch forwards caller-authored ids
    ///     verbatim). Pass `nil` for a notification frame: no response is
    ///     awaited and the return value is `nil`.
    ///   - clientName: the MCP `clientInfo.name` sent in `initialize`
    ///     (`"mootx01-query"` / `"mootx01-botlink"` — attribution only).
    /// - Returns: the parsed response object, or `nil` when `expectID` is
    ///   `nil` (notification — one frame in, zero frames out).
    /// - Throws: `McpOneShotError.noResponse` when a response was expected
    ///   and no frame with a matching id arrived before stdout EOF;
    ///   `Process.run` errors propagate unchanged.
    public static func subprocessCall(
        binaryPath: String,
        serveArgs: [String],
        frame: String,
        expectID: Any?,
        clientName: String
    ) async throws -> [String: Any]? {
        let initRequest = encodeFrame(id: 1, method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": clientName, "version": "1.0.0"]
        ])
        let initializedNotif = encodeFrame(id: nil, method: "initialized", params: [:] as [String: Any])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = serveArgs

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        // INHERIT the parent's stderr rather than piping it. A captured-but-
        // never-drained stderr pipe deadlocks any tool that writes more than
        // the OS pipe buffer (~64KB) to stderr: the child blocks in fputs()
        // once the buffer fills while the parent blocks in
        // readDataToEndOfFile() on stdout, so neither side progresses.
        // `moot_palace_import` emits a progress line every 10 records (~4,800
        // lines for a 48K-drawer palace), which overflows the buffer and
        // hangs the import. Inheriting forwards the child's live progress
        // straight to the parent's stderr and removes the pipe entirely.
        // For botLink this is also the strict stdout/stderr separation
        // contract: serve banners land on stderr, never in the JSON stdout.
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
        // initialized + the call. 100 ms is sufficient on macOS — the
        // subprocess is local and the estate is already on disk.
        try await Task.sleep(nanoseconds: 100_000_000)
        writeLine(initializedNotif)
        writeLine(frame)

        // Give the server time to process the call, then close stdin to
        // signal end-of-input so it exits cleanly.
        try await Task.sleep(nanoseconds: 500_000_000)
        inputHandle.closeFile()

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // Notification: one frame in, zero frames out. The drain above still
        // ran so the subprocess processed the frame before stdin closed.
        guard let expectID else { return nil }

        let lines = String(decoding: outputData, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"],
                  // Foundation object equality: NSNumber for Int ids,
                  // NSString for String ids — both bridge transparently.
                  (id as? NSObject)?.isEqual(expectID) == true else { continue }
            return obj
        }

        throw McpOneShotError.noResponse
    }
}
