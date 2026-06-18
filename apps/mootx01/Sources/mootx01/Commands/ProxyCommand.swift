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
// References: ADR-LOOPBACKHTTP-001, ARIA_MCP_SPEC_v0.2 §6 (transport),
// INSTALLER_SPEC_v0.1 §client-wiring.

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
        guard let url = URL(string: http) else {
            proxyStderrLog("mootx01 proxy: invalid daemon URL '\(http)'")
            throw ExitCode.failure
        }
        try await waitForDaemon(url: url)
        let session = URLSession(configuration: .ephemeral)
        var buffer = Data()
        // Read stdin until EOF. Same availableData loop as StdioServer.run —
        // availableData blocks until bytes arrive at the pipe (non-blocking for
        // the buffer-fill, blocking at the OS read level), and returns empty
        // Data on EOF, which ends the loop cleanly.
        while true {
            let chunk = FileHandle.standardInput.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let frame = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                if frame.isEmpty { continue }
                await forward(frame, to: url, session: session)
            }
        }
    }

    /// POST a minimal body to the daemon endpoint to confirm the socket is bound.
    /// The daemon returns a JSON-RPC parseError (the body is not a valid JSON-RPC
    /// frame), which is sufficient to confirm it is accepting connections.
    /// Retries 20 × 250 ms (5 s total) before giving up.
    private func waitForDaemon(url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let probe = URLSession(configuration: .ephemeral)
        for attempt in 1...20 {
            if (try? await probe.data(for: request)) != nil {
                return
            }
            if attempt < 20 {
                try await Task.sleep(nanoseconds: 250_000_000)  // 250 ms between retries
            }
        }
        proxyStderrLog("mootx01 proxy: daemon not responding at \(url.absoluteString) after 5 s — is mootx01 running? (start with: mootx01 serve --http 4242)")
        throw ExitCode.failure
    }

    /// Forward one newline-delimited JSON-RPC frame to the resident daemon
    /// and relay the response to stdout.
    private func forward(_ frame: Data, to url: URL, session: URLSession) async {
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
            var out = data
            if out.last != 0x0A { out.append(0x0A) }  // ensure newline terminator
            try? FileHandle.standardOutput.write(contentsOf: out)
        } catch {
            // Network failure: synthesize a JSON-RPC internal error so the client
            // sees a clean failure instead of a silent hang.
            let msg = error.localizedDescription
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "'")
            let errorJSON = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"proxy: \(msg)\"}}\n"
            try? FileHandle.standardOutput.write(contentsOf: Data(errorJSON.utf8))
        }
    }
}

/// Write a diagnostic line to stderr. stdout is reserved for JSON-RPC frames
/// (ARIA_MCP_SPEC_v0.2 §5), so all ProxyCommand diagnostics go to stderr.
private func proxyStderrLog(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data("\(message)\n".utf8))
}
#endif
