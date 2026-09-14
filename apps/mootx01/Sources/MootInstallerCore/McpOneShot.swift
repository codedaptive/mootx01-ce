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

/// A one-shot latch for a `Process` termination callback.
///
/// The termination handler may run before the task reaches its waiter, so the
/// latch retains that signal until the continuation is installed. `NSLock`
/// also keeps the handler's arbitrary Foundation thread separate from Swift
/// task isolation.
private final class ProcessTerminationWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var terminated = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signalTermination() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard !terminated else { return nil }
            terminated = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }

    func waitForTermination() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if terminated {
                    return true
                }
                self.continuation = continuation
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }
}

/// Loopback daemon liveness probing, shared by `query` and `botlink`
/// (BL-1: one probe implementation, two command-layer callers).
public enum McpLoopback {

    /// TCP probe: is the daemon listening on `port`? 250 ms timeout mirrors
    /// `daemon_client::alive` in the Rust vertical — long enough for a live
    /// local listener, short enough that a one-shot invocation with the
    /// daemon down falls through to the serve subprocess without a
    /// noticeable stall.
    ///
    /// - Parameter port: the loopback port to probe. Out-of-range values
    ///   return `false` rather than trapping — see below.
    /// - Returns: `true` when a TCP connection completes within 250 ms.
    public static func daemonAlive(port: Int) -> Bool {
        // Range check BEFORE the UInt16 narrowing below (BL-01, Codex #41).
        // `UInt16(port)` is an unguarded narrowing: it traps with "Not
        // enough bits to represent the passed value" for anything outside
        // 0…65535, which killed the CLI when a `--http` override carried an
        // out-of-range port. `validateLoopbackHTTP` now rejects those with a
        // clean exit 64, so this is defense in depth — it also covers the
        // resolved-default-port path, which never passes through that guard
        // (a corrupt port file would otherwise reach the same trap).
        // No listener can exist on port 0, so false is the honest answer.
        guard port >= 1, port <= 65535 else { return false }

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

        let terminationWaiter = ProcessTerminationWaiter()
        process.terminationHandler = { _ in
            terminationWaiter.signalTermination()
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            throw error
        }

        let inputHandle = stdinPipe.fileHandleForWriting
        let outputHandle = stdoutPipe.fileHandleForReading
        let stdoutRead = Task.detached { @Sendable () -> Data in
            outputHandle.readDataToEndOfFile()
        }
        var stdinClosed = false
        defer {
            if !stdinClosed {
                inputHandle.closeFile()
            }
            if process.isRunning {
                process.terminate()
            }
        }
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
        stdinClosed = true

        await terminationWaiter.waitForTermination()
        let outputData = await stdoutRead.value

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
