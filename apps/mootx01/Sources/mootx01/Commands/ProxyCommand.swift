// ProxyCommand.swift
//
// Native stdio→HTTP bridge for Claude Desktop.
//
// Claude Desktop cannot use a native HTTP URL entry in its config; it must
// launch a subprocess over stdio. This command reads newline-delimited
// JSON-RPC frames from stdin, POSTs each to the resident daemon over loopback
// HTTP, and writes the response back to stdout. Desktop's calls then execute
// inside the daemon process: telemetry fires, one writer holds the estate,
// moot-mgr sees everything.
//
// URLSession sends no Origin header, so HTTPServer.isOriginAllowed(nil)
// passes unchanged. No server code is touched.
//
// The installer writes ["command": binaryPath, "args": ["proxy"]]
// into Claude Desktop's config (instead of the bare serve entry) when the
// client has useProxyBridge: true — see ClientConfig.swift and Installer.swift.
//
// The proxy owns transport adaptation only; the installer owns client wiring.

#if os(macOS)
import Foundation
import ArgumentParser

struct ProxyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "proxy",
        abstract: "Proxy stdin JSON-RPC frames to the resident daemon over loopback HTTP (for Claude Desktop)."
    )

    /// Resident daemon base URL. Default matches MootPaths.residentEndpointURL
    /// (http://127.0.0.1:4242 — MootPaths.defaultResidentPort is the single source
    /// for port 4242). Override via --http for dev/testing.
    @Option(name: .long, help: "Resident daemon base URL. Default: http://127.0.0.1:4242.")
    var http: String = "http://127.0.0.1:4242"

    func run() async throws {
        // Planned hardening: validate that --http is a loopback HTTP URL before
        // forwarding any frames. A non-loopback URL would proxy the stdio bridge
        // to a remote server, violating the loopback-only contract (fails CLOSED).
        guard let url = URL(string: http),
              url.scheme == "http",
              let host = url.host,
              host == "127.0.0.1" || host == "localhost" || host == "::1" else {
            proxyStderrLog(
                "mootx01 proxy: '--http' must be a loopback HTTP URL (e.g. http://127.0.0.1:4242), got '\(http)'"
            )
            throw ExitCode.failure
        }
        try await waitForDaemon(url: url)
        // Long tool calls are legitimate: lens/synthesis operations on a large
        // estate run for minutes. URLSession's DEFAULT 60 s request timeout was
        // killing them mid-flight — the client (Claude Desktop) owns the
        // timeout policy and cancels via notifications/cancelled; the proxy
        // must not impose a shorter one of its own.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3600
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config)
        let writer = FrameWriter()
        var buffer = Data()
        // Read stdin until EOF. Same availableData loop as StdioServer.run —
        // availableData blocks until bytes arrive at the pipe (non-blocking for
        // the buffer-fill, blocking at the OS read level), and returns empty
        // Data on EOF, which ends the loop cleanly.
        //
        // Frames forward CONCURRENTLY (task per frame): awaiting each response
        // serially meant one slow tool call blocked every frame behind it —
        // pings, cancellations, parallel calls — and Claude Desktop read the
        // stall as a dead server. Responses may interleave out of order; that
        // is legal JSON-RPC (the client correlates by id).
        await withDiscardingTaskGroup { group in
            while true {
                let chunk = FileHandle.standardInput.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let frame = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                    buffer.removeSubrange(buffer.startIndex...newlineIndex)
                    if frame.isEmpty { continue }
                    group.addTask {
                        await Self.forward(frame, to: url, session: session, writer: writer)
                    }
                }
            }
        }
    }

    /// POST a minimal body to the daemon endpoint to confirm the socket is bound.
    /// The daemon returns a JSON-RPC parseError (the body is not a valid JSON-RPC
    /// frame), which is sufficient to confirm it is accepting connections.
    ///
    /// Retries 240 × 500 ms (2 min total): on a large estate the daemon takes
    /// ~30 s of startup work before it binds the port (measured live on a
    /// 50k-memory estate), and launchd may still be relaunching it after an
    /// upgrade. The old 5 s window meant Claude Desktop connecting right after
    /// any daemon restart always failed ("Server disconnected").
    private func waitForDaemon(url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let probe = URLSession(configuration: .ephemeral)
        for attempt in 1...240 {
            if (try? await probe.data(for: request)) != nil {
                return
            }
            if attempt == 10 {
                // One early stderr note so a human tailing the log sees why
                // the bridge is quiet; keep waiting.
                proxyStderrLog("mootx01 proxy: daemon not up yet at \(url.absoluteString) — waiting (large estates take ~30 s to start)")
            }
            if attempt < 240 {
                try await Task.sleep(nanoseconds: 500_000_000)  // 500 ms between retries
            }
        }
        proxyStderrLog("mootx01 proxy: daemon not responding at \(url.absoluteString) after 2 min — is mootx01 running? (start with: mootx01 serve --http 4242)")
        throw ExitCode.failure
    }

    /// Forward one newline-delimited JSON-RPC frame to the resident daemon
    /// and relay the response to stdout.
    private static func forward(_ frame: Data, to url: URL, session: URLSession, writer: FrameWriter) async {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = frame

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return }
            // HTTP 202: notification acknowledged — the daemon has no JSON-RPC reply
            // to send (per MCP spec, servers must not reply to notifications).
            if httpResponse.statusCode == 202 { return }
            // Any other status: relay the response body to stdout so the client
            // receives a valid JSON-RPC frame.
            await writer.write(data)
        } catch {
            // Network failure. Only synthesize an error for a REQUEST (a frame
            // with an id) — notifications get no reply per spec. The error MUST
            // echo the request's id: Claude Desktop's MCP client rejects
            // `id: null` frames at the schema level, and the resulting parse
            // error poisoned the whole stream ("Server disconnected").
            guard let requestID = Self.requestID(of: frame) else { return }
            let msg = error.localizedDescription
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "'")
            let errorJSON = "{\"jsonrpc\":\"2.0\",\"id\":\(requestID),\"error\":{\"code\":-32603,\"message\":\"proxy: \(msg)\"}}\n"
            await writer.write(Data(errorJSON.utf8))
        }
    }

    /// Extract the JSON-RPC `id` of a request frame, re-encoded as a JSON
    /// literal (quoted string or bare number). Returns nil for notifications
    /// (no id) and unparseable frames — both get no synthesized reply.
    private static func requestID(of frame: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
              let id = obj["id"] else { return nil }
        if let s = id as? String {
            let escaped = s
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        if let n = id as? NSNumber { return "\(n)" }
        return nil
    }
}

/// Serializes stdout writes: frames forward concurrently, but stdout is one
/// stream and an interleaved write would corrupt both frames.
private actor FrameWriter {
    func write(_ data: Data) {
        var out = data
        if out.last != 0x0A { out.append(0x0A) }  // ensure newline terminator
        try? FileHandle.standardOutput.write(contentsOf: out)
    }
}

/// Write a diagnostic line to stderr. stdout is reserved for JSON-RPC frames
/// (ARIA_MCP_SPEC_v0.2 §5), so all ProxyCommand diagnostics go to stderr.
private func proxyStderrLog(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data("\(message)\n".utf8))
}
#endif
