// BotLinkCommand.swift
//
// BL-1: `mootx01 botlink` — the explicit AI data path for cloud agents.
// Also reachable as the `mootx01-botLink` argv0 symlink (ArgvDispatch
// prepends `botlink`). Thin ArgumentParser wrapper around the testable
// engine in MootInstallerCore/BotLink.swift, per this app's established
// split (see ArgvDispatch.swift's header).
//
// Transport select copies `query`, not `proxy`: 250 ms TCP probe of the
// resolved loopback port → POST one stateless JSON-RPC frame (no
// initialize, no Origin header, no session id); daemon down or `--db`
// pinned → spawn a `mootx01 serve` subprocess via the shared McpOneShot
// seam and exit when the one response arrives. No daemon is left behind,
// no session file is written.
//
// SECURITY BOUNDARY: `--http` accepts loopback URLs ONLY
// (http://127.0.0.1:*, http://localhost:*, http://[::1]:*), and only at
// the JSON-RPC root path — no deeper route, no query, no fragment. A
// rejected URL exits 64 before any URLRequest is constructed — the estate
// never leaves the Mac; botLink is a local hop, not a server. The
// root-path rule (BL-01, Codex #42) keeps this transport off the daemon's
// control plane, which shares the same loopback listener and grants
// sensitivity tiers to whoever POSTs a fresh timestamp.

import ArgumentParser
import Foundation
import GeniusLocusKit
import MootInstallerCore

/// Transport-layer failures surfaced by the real HTTP/stdio wiring. The
/// engine shapes these into `{"ok":false,"error":…}` with exit 1.
private enum BotLinkTransportError: Error, CustomStringConvertible {
    /// The daemon answered with a non-2xx HTTP status.
    case httpStatus(Int)
    /// The daemon's response body was not a JSON object.
    case nonJSONResponse
    /// `Bundle.main.executableURL` could not be resolved to an absolute
    /// path for the serve subprocess.
    case cannotResolveBinary

    var description: String {
        switch self {
        case .httpStatus(let code): return "daemon returned HTTP \(code)"
        case .nonJSONResponse: return "daemon returned non-JSON response"
        case .cannotResolveBinary:
            return "cannot resolve absolute executable path for subprocess"
        }
    }
}

/// Shared options for every botlink subcommand.
struct BotLinkOptions: ParsableArguments {
    @Option(name: .long, help: "Resident daemon base URL override (dev only; loopback required).")
    var http: String?

    @Option(name: .long, help: "Named estate; forces the serve-subprocess path.")
    var db: String?
}

/// Shared wiring: transport resolution and outcome emission.
enum BotLinkWiring {

    /// Print the outcome's single JSON value (if any) to stdout and exit
    /// with its code. stdout is machine JSON only — diagnostics stay on
    /// stderr (the serve subprocess inherits stderr through McpOneShot, so
    /// its banners can never contaminate stdout).
    static func emit(_ outcome: BotLinkOutcome) throws {
        if let json = outcome.stdoutJSON {
            print(BotLink.serializeStdout(json))
        }
        if outcome.exitCode != 0 {
            throw ExitCode(outcome.exitCode)
        }
    }

    /// Resolve the transport per the BL-1 transport-select rules.
    ///
    /// 1. `--http` (when present) is loopback-validated FIRST; a rejected
    ///    URL prints `{"ok":false,"error":…}` and exits 64 without any
    ///    request being constructed (fails CLOSED).
    /// 2. `--db` absent + 250 ms probe finds the daemon → stateless HTTP.
    /// 3. Otherwise → serve subprocess via McpOneShot.
    static func transport(options: BotLinkOptions) throws -> BotLinkTransport {
        var overrideURL: URL?
        if let http = options.http {
            guard let url = BotLink.validateLoopbackHTTP(http) else {
                // Copy of the ProxyCommand guard semantics with botLink's
                // exit code: usage error 64, and no POST ever happens for a
                // rejected URL.
                try emit(BotLinkOutcome(
                    stdoutJSON: [
                        "ok": false,
                        "error": "'--http' must be a loopback HTTP URL (e.g. http://127.0.0.1:4242), got '\(http)'",
                    ],
                    exitCode: 64
                ))
                // emit always throws for a non-zero exit; this is unreachable.
                throw ExitCode(64)
            }
            overrideURL = url
        }

        if options.db == nil {
            let url = overrideURL
                ?? URL(string: "http://127.0.0.1:\(MootPaths.resolvedResidentPort(dataDir: EstateCatalog.configurationDirectory))/")!
            // Probe the resolved port (default 4242, or the --http override's
            // port); 250 ms then fall through to the subprocess immediately —
            // no proxy-style multi-minute wait.
            if McpLoopback.daemonAlive(port: url.port ?? MootPaths.defaultResidentPort) {
                return httpTransport(url: url)
            }
        }
        return stdioTransport(db: options.db)
    }

    /// The stateless loopback HTTP transport: POST one frame, parse one
    /// response object.
    private static func httpTransport(url: URL) -> BotLinkTransport {
        // Long tool calls are legitimate: lens/synthesis operations on a
        // large estate run for minutes. URLSession's DEFAULT 60 s request
        // timeout would kill them mid-flight (copy of the proxy's 3600 s
        // rationale) — the cloud agent owns its own timeout policy; this
        // hop must not impose a shorter one.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3600
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config)

        return BotLinkTransport(
            kind: "http",
            // Attribution shows the base URL without a trailing path.
            endpoint: url.absoluteString.hasSuffix("/")
                ? String(url.absoluteString.dropLast())
                : url.absoluteString
        ) { frame, expectID in
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = frame.data(using: .utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("close", forHTTPHeaderField: "Connection")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw BotLinkTransportError.nonJSONResponse
            }
            if expectID == nil {
                // Notification: the daemon acks with an empty 202; there is
                // no response frame to parse.
                return nil
            }
            guard (200...299).contains(http.statusCode) else {
                throw BotLinkTransportError.httpStatus(http.statusCode)
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw BotLinkTransportError.nonJSONResponse
            }
            return obj
        }
    }

    /// The serve-subprocess transport, through the same McpOneShot seam
    /// `query` uses.
    private static func stdioTransport(db: String?) -> BotLinkTransport {
        var serveArgs = ["serve"]
        if let db {
            serveArgs.append(contentsOf: ["--db", db])
        }
        return BotLinkTransport(kind: "stdio", endpoint: nil) { frame, expectID in
            // Resolve the absolute binary path from the bundle rather than
            // argv[0]: argv[0] is caller-controlled (and under the
            // mootx01-botLink symlink it isn't even the binary's name).
            guard let execURL = Bundle.main.executableURL?.standardizedFileURL,
                  execURL.path.hasPrefix("/") else {
                throw BotLinkTransportError.cannotResolveBinary
            }
            return try await McpOneShot.subprocessCall(
                binaryPath: execURL.path,
                serveArgs: serveArgs,
                frame: frame,
                expectID: expectID,
                clientName: "mootx01-botlink"
            )
        }
    }
}

/// `mootx01 botlink` — one-shot MCP transport for cloud agents.
struct BotLinkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "botlink",
        abstract: "One-shot MCP transport for cloud agents (machine JSON stdout, loopback only).",
        discussion: """
        The explicit AI data path for a cloud agent whose only channel to
        this Mac is a permissioned one-shot shell. One invocation performs
        one MCP operation against the local estate and exits. stdout is
        exactly one JSON value — no banners, no log lines; diagnostics go
        to stderr. Exit codes: 0 success, 2 tool error (isError true),
        1 transport failure, 64 usage / non-loopback --http.
        The estate never leaves this Mac: botLink talks to the loopback
        daemon or spawns a local serve subprocess, nothing else.
        """,
        subcommands: [Ping.self, List.self, Call.self, Rpc.self]
    )

    /// `botlink ping` — liveness + identity with transport attribution.
    struct Ping: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "ping",
            abstract: "Liveness + identity: moot_estate_ping plus transport attribution."
        )

        @OptionGroup var options: BotLinkOptions

        func run() async throws {
            let transport = try BotLinkWiring.transport(options: options)
            try BotLinkWiring.emit(await BotLink.ping(transport: transport))
        }
    }

    /// `botlink list` — the combined MCP tools/list result object.
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "Emit the MCP tools/list result object; cursors are followed internally."
        )

        @OptionGroup var options: BotLinkOptions

        func run() async throws {
            let transport = try BotLinkWiring.transport(options: options)
            try BotLinkWiring.emit(await BotLink.list(transport: transport))
        }
    }

    /// `botlink call <verb>` — one tools/call, raw result object out.
    struct Call: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "call",
            abstract: "Issue one ARIA tool call; stdout is the raw MCP result object."
        )

        @OptionGroup var options: BotLinkOptions

        @Argument(help: "ARIA verb name without moot_ prefix, e.g. 'memory_search'.")
        var verb: String

        @Option(name: .long, help: "Tool arguments as a JSON object (nested objects/arrays supported).")
        var args: String?

        @Argument(parsing: .allUnrecognized,
                  help: "Additional tool arguments as --key value pairs (overlay onto --args).")
        var remaining: [String] = []

        func run() async throws {
            // --args is the base, --key pairs overlay (KV wins on collision).
            var base: [String: Any] = [:]
            if let args {
                guard let parsed = BotLink.parseArgsJSON(args) else {
                    try BotLinkWiring.emit(BotLinkOutcome(
                        stdoutJSON: ["ok": false, "error": "--args must be a JSON object"],
                        exitCode: 64
                    ))
                    return
                }
                base = parsed
            }
            let merged = BotLink.overlayArguments(
                base: base,
                overlay: BotLink.parseKVArguments(remaining)
            )
            let transport = try BotLinkWiring.transport(options: options)
            try BotLinkWiring.emit(
                await BotLink.call(verb: verb, arguments: merged, transport: transport))
        }
    }

    /// `botlink rpc` — the escape hatch: one JSON-RPC frame in, one out.
    struct Rpc: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rpc",
            abstract: "Forward one raw JSON-RPC frame (argument or stdin) and print the response frame."
        )

        @OptionGroup var options: BotLinkOptions

        @Argument(help: "The JSON-RPC frame. Omitted: the frame is read from stdin to EOF.")
        var frame: String?

        func run() async throws {
            let rawFrame: String
            if let frame {
                rawFrame = frame
            } else {
                // Read stdin under a hard byte cap (BL-01, Codex #47) — the
                // cloud agent pipes the frame in, and an unbounded read lets
                // a large or never-terminating producer exhaust local
                // memory. The bounded read lives in the engine so it is
                // testable; nil means the producer went over the cap.
                guard let bounded = try BotLink.readBoundedFrame(
                    from: FileHandle.standardInput
                ) else {
                    try BotLinkWiring.emit(BotLinkOutcome(
                        stdoutJSON: [
                            "ok": false,
                            "error": "rpc frame from stdin exceeds the \(BotLink.maxStdinFrameBytes) byte limit",
                        ],
                        exitCode: 64
                    ))
                    return
                }
                rawFrame = bounded
            }
            let transport = try BotLinkWiring.transport(options: options)
            try BotLinkWiring.emit(await BotLink.rpc(frame: rawFrame, transport: transport))
        }
    }
}
