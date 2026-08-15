// BotLink.swift
//
// BL-1: the botLink one-shot MCP transport engine — the explicit AI data
// path for cloud agents whose only channel to this Mac is a permissioned
// one-shot shell (command string in, stdout back on exit).
//
// SECURITY BOUNDARY: the estate never leaves the Mac. botLink is a local
// hop, not a server — it POSTs to the loopback daemon or spawns a local
// serve subprocess, and nothing else. `validateLoopbackHTTP` is the gate:
// any `--http` value that is not 127.0.0.1 / localhost / [::1] over plain
// http, or that addresses anything below the root path, is rejected
// BEFORE any request is constructed (fails CLOSED, exit 64, zero requests
// sent). The host guard is copied from ProxyCommand's inline guard, not
// refactored out of it — ProxyCommand is untouched by BL-1. The root-path
// restriction is BL-01's (Codex #42): the daemon's control plane shares
// this listener, so an unrestricted path let this transport reach
// `POST /api/control/unlock` and grant a sensitivity tier without ever
// meeting the unlock authority.
//
// Engine/wrapper split: this file is the testable engine (MootInstallerCore,
// exercised by BotLinkCommandTests via closure-injected transports). The
// `mootx01` executable target's BotLinkCommand.swift wires real transports
// (URLSession POST / McpOneShot serve subprocess) around it.
//
// stdout contract: exactly ONE JSON value per invocation, no banners, no
// log lines. All diagnostics belong on stderr. Exit codes are normative
// (BL-1, and the parity reference for the Rust twin in BL-2):
//   0  — MCP result with isError false/absent (stdout: the result JSON)
//   2  — tool ran, isError true            (stdout: the result JSON)
//   1  — transport/daemon/parse failure    (stdout: {"ok":false,"error":…})
//   64 — usage / bad argv / non-loopback --http ({"ok":false,"error":…})
// Exit 2 vs 0 is load-bearing: a failed recall must be distinguishable
// from a dead hop without parsing prose.

import Foundation

/// The result of one botLink operation: the single JSON value for stdout
/// (nil = empty stdout, e.g. a notification frame) plus the process exit
/// code from the normative table above.
public struct BotLinkOutcome {
    /// The one JSON value to print to stdout, or `nil` for empty stdout.
    public let stdoutJSON: Any?
    /// Process exit code: 0, 1, 2, or 64 per the table in the file header.
    public let exitCode: Int32

    public init(stdoutJSON: Any?, exitCode: Int32) {
        self.stdoutJSON = stdoutJSON
        self.exitCode = exitCode
    }
}

/// A one-shot MCP transport: sends one JSON-RPC frame, returns the parsed
/// response object (or `nil` for a notification). Production wiring lives
/// in BotLinkCommand (URLSession POST for HTTP, McpOneShot for stdio);
/// tests inject canned closures.
public struct BotLinkTransport {
    /// `"http"` when the resident daemon answers, `"stdio"` when botLink
    /// spawns `serve`. Reported verbatim in `ping` output.
    public let kind: String
    /// The daemon base URL string for the HTTP transport; `nil` for stdio
    /// (ping omits `endpoint` rather than inventing one).
    public let endpoint: String?
    /// Send one frame; `expectID == nil` means notification (no response).
    public let send: (String, Any?) async throws -> [String: Any]?

    public init(
        kind: String,
        endpoint: String?,
        send: @escaping (String, Any?) async throws -> [String: Any]?
    ) {
        self.kind = kind
        self.endpoint = endpoint
        self.send = send
    }
}

/// The botLink engine: pure helpers + the four subcommand operations.
public enum BotLink {

    // MARK: - Loopback guard (security boundary)

    /// Validate a `--http` override as a loopback-only HTTP URL addressing
    /// the MCP JSON-RPC endpoint at the server root.
    ///
    /// Accepts exactly `http://127.0.0.1`, `http://localhost`, and
    /// `http://[::1]` (any port) with no path beyond the root. Everything
    /// else — other hosts, https, non-http schemes, unparseable strings —
    /// returns `nil` and the command layer exits 64 WITHOUT constructing
    /// any request (fails CLOSED).
    ///
    /// ROOT-PATH ONLY (BL-01, Codex #42). botLink is an MCP JSON-RPC
    /// transport and speaks to the dispatcher at `/` — nothing else. The
    /// daemon also serves control-plane routes on the same loopback
    /// listener (`POST /api/control/unlock` grants a sensitivity tier on a
    /// fresh timestamp alone, because authentication is the CLI's job —
    /// see HTTPServer.route). A guard that validated only scheme and host
    /// let `botlink rpc --http http://127.0.0.1:4242/api/control/unlock`
    /// POST a caller-authored body straight to that route, silently
    /// granting the secret tier and bypassing `mootx01 unlock`'s
    /// LocalAuthentication gate. Restricting the path here closes that by
    /// construction and keeps future `/api/control/*` routes unreachable
    /// from this transport without further work.
    ///
    /// A query or fragment is rejected for the same reason: neither has a
    /// legitimate use on the JSON-RPC endpoint, and `url.path` alone does
    /// not capture them.
    ///
    /// - Parameter urlString: the raw `--http` argument.
    /// - Returns: the parsed URL when loopback-valid, else `nil`.
    public static func validateLoopbackHTTP(_ urlString: String) -> URL? {
        guard let url = URL(string: urlString),
              url.scheme == "http",
              let host = url.host,
              host == "127.0.0.1" || host == "localhost" || host == "::1" else {
            return nil
        }
        // Root path only: "" (no trailing slash) and "/" are the two
        // spellings of the JSON-RPC endpoint; anything deeper is a
        // different route and is refused.
        guard url.path.isEmpty || url.path == "/",
              url.query == nil,
              url.fragment == nil else {
            return nil
        }
        return url
    }

    // MARK: - Argument parsing

    /// Parse a `--args` JSON string into a dictionary.
    ///
    /// Strict: the value must decode as a JSON OBJECT (nested objects and
    /// arrays welcome — this is exactly what the `--key value` parser
    /// cannot express). Non-object JSON (array, scalar) and malformed JSON
    /// both return `nil`; the command layer exits 64 (usage).
    ///
    /// - Parameter s: the raw `--args` argument.
    /// - Returns: the decoded object, or `nil` when invalid.
    public static func parseArgsJSON(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    /// Parse `["--key", "value", …]` pairs — the query parser's semantics
    /// (shared here so `query` and `botlink call` decode identically):
    /// values that parse as JSON integers or booleans are decoded as such,
    /// everything else stays a string; a bare `--` separator is skipped;
    /// non-`--` positional tokens are skipped; a trailing `--flag` with no
    /// value becomes `true`.
    ///
    /// - Parameter args: the raw remaining argv tokens.
    /// - Returns: the decoded key/value dictionary.
    public static func parseKVArguments(_ args: [String]) -> [String: Any] {
        var result: [String: Any] = [:]
        var i = 0
        while i < args.count {
            let arg = args[i]
            guard arg.hasPrefix("--") else { i += 1; continue }
            let key = String(arg.dropFirst(2))
            // Skip a bare "--" separator (bash-style option terminator).
            // Without this guard, dropFirst(2) produces an empty key that
            // inserts result[""] = true, polluting the argument dictionary.
            guard !key.isEmpty else { i += 1; continue }
            if i + 1 < args.count && !args[i + 1].hasPrefix("--") {
                result[key] = decodeValue(args[i + 1])
                i += 2
            } else {
                // Flag-style argument: treat as true.
                result[key] = true
                i += 1
            }
        }
        return result
    }

    private static func decodeValue(_ s: String) -> Any {
        if let i = Int(s) { return i }
        if s == "true" { return true }
        if s == "false" { return false }
        return s
    }

    /// Overlay `--key value` pairs onto a `--args` base object. The KV pair
    /// wins on key collision (`--args` is the base, `--key` is the
    /// override) — normative for the Rust twin.
    ///
    /// - Parameters:
    ///   - base: the decoded `--args` object.
    ///   - overlay: the decoded `--key value` pairs.
    /// - Returns: the merged argument object.
    public static func overlayArguments(
        base: [String: Any], overlay: [String: Any]
    ) -> [String: Any] {
        var merged = base
        for (k, v) in overlay { merged[k] = v }
        return merged
    }

    // MARK: - Ping payload shaping

    /// Parse the `moot_estate_ping` pong payload into its attribution
    /// fields.
    ///
    /// The payload is text-only (verified against the live daemon: no
    /// structuredContent) and is NOT always one line: `runEstatePing`
    /// appends up to two opt-in-and-live advisory lines
    /// (`version_skew: …`, `update_available: …`) to the same text —
    /// routine pings carry them. Field extraction therefore operates on
    /// the HEAD LINE ONLY:
    /// `pong: estate <name> [<uuid>] is live — build <build>`
    /// so no field can ever absorb an advisory. The advisory lines come
    /// back separately in `advisories`; the caller decides their fate
    /// (`ping` forwards them to stderr — they are diagnostics, and stdout
    /// is machine JSON only).
    ///
    /// Every field is optional-by-parse: a field that cannot be extracted
    /// is omitted from ping output, never invented.
    ///
    /// - Parameter text: the pong content text (one line or more).
    /// - Returns: whichever of estate name, estate id, and build parsed
    ///   from the head line, plus any non-empty trailing advisory lines.
    public static func parsePong(
        _ text: String
    ) -> (estate: String?, estateId: String?, build: String?, advisories: [String]) {
        // Split ONCE, up front: every extraction below sees only line 0.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let head = lines.first.map(String.init) ?? ""
        let advisories = lines.dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard head.hasPrefix("pong: estate") else { return (nil, nil, nil, advisories) }

        var estate: String?
        var estateId: String?
        var build: String?

        if let open = head.firstIndex(of: "["), let close = head.firstIndex(of: "]"),
           open < close {
            let id = String(head[head.index(after: open)..<close])
            if !id.isEmpty { estateId = id }
            // The estate name sits between "pong: estate " and " [".
            let nameStart = head.index(head.startIndex, offsetBy: "pong: estate".count)
            let name = String(head[nameStart..<open])
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { estate = name }
        }
        if let range = head.range(of: "build ") {
            let b = String(head[range.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            if !b.isEmpty { build = b }
        }
        return (estate, estateId, build, advisories)
    }

    // MARK: - Subcommand operations

    /// `ping`: liveness + identity. One `tools/call moot_estate_ping` plus
    /// transport attribution. Success stdout is the shaped object
    /// (`ok`/`transport`/`endpoint`/`estate`/`estateId`/`build`); fields
    /// the payload cannot fill are omitted. `toolCount` is omitted because
    /// the ping payload does not carry it (never invent values).
    public static func ping(transport: BotLinkTransport) async -> BotLinkOutcome {
        let frame = McpOneShot.encodeFrame(id: 2, method: "tools/call", params: [
            "name": "moot_estate_ping",
            "arguments": [:] as [String: Any]
        ])
        return await withResponse(transport, frame, expectID: 2) { obj in
            guard let result = obj["result"] as? [String: Any] else {
                return failure("no result field in ping response")
            }
            if isErrorResult(result) {
                // DELIBERATE CHOICE (BL-1, normative for BL-2): estate_ping
                // has reachable isError paths (quiesced/draining estate,
                // unmounted estate). Exit 2 is load-bearing — a failed tool
                // must be distinguishable from a dead hop — and stdout is
                // the RAW result object (parseable, carries the server's own
                // error content), NOT the synthesized `{"ok":true,…}` shape
                // (which only describes a live estate) and NOT
                // `{"ok":false,…}` (which is reserved for transport
                // failures, exit 1). Do not "fix" this into either shape.
                return BotLinkOutcome(stdoutJSON: result, exitCode: 2)
            }
            var payload: [String: Any] = [
                "ok": true,
                "transport": transport.kind,
            ]
            if let endpoint = transport.endpoint { payload["endpoint"] = endpoint }
            if let content = result["content"] as? [[String: Any]],
               let text = content.first?["text"] as? String {
                let parsed = parsePong(text)
                if let estate = parsed.estate { payload["estate"] = estate }
                if let estateId = parsed.estateId { payload["estateId"] = estateId }
                if let build = parsed.build { payload["build"] = build }
                // Advisory lines (version_skew / update_available) are
                // diagnostics: they go to stderr, keeping stdout machine
                // JSON only (non-negotiable 5). Not an `advisories` field —
                // the normative ping shape has no such field and botLink
                // never invents values.
                for advisory in parsed.advisories {
                    FileHandle.standardError.write(Data("mootx01 botlink: \(advisory)\n".utf8))
                }
            }
            return BotLinkOutcome(stdoutJSON: payload, exitCode: 0)
        }
    }

    /// Iteration cap for `list` cursor-following. tools/list pages are
    /// server-controlled; a misbehaving server that loops cursors forever
    /// must not hang the one-shot process. 64 pages × any sane page size
    /// covers every real surface (77 tools today) by orders of magnitude.
    private static let maxListPages = 64

    /// `list`: emit the MCP tools/list RESULT OBJECT — `{"tools":[…]}`.
    /// Follows `nextCursor` internally and prints ONE combined array; the
    /// caller never loops.
    public static func list(transport: BotLinkTransport) async -> BotLinkOutcome {
        var tools: [[String: Any]] = []
        var cursor: String?
        var requestID = 2
        for _ in 0..<maxListPages {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let frame = McpOneShot.encodeFrame(id: requestID, method: "tools/list", params: params)
            let obj: [String: Any]
            do {
                guard let response = try await transport.send(frame, requestID) else {
                    return failure("no response received")
                }
                obj = response
            } catch {
                return failure("\(error)")
            }
            if let err = obj["error"] {
                return failure("tool error: \(err)")
            }
            guard let result = obj["result"] as? [String: Any] else {
                return failure("no result field in tools/list response")
            }
            tools.append(contentsOf: (result["tools"] as? [[String: Any]]) ?? [])
            cursor = result["nextCursor"] as? String
            if cursor == nil || cursor?.isEmpty == true {
                return BotLinkOutcome(stdoutJSON: ["tools": tools], exitCode: 0)
            }
            requestID += 1
        }
        return failure("tools/list did not terminate within \(maxListPages) pages")
    }

    /// `call`: one `tools/call moot_<verb>`. Stdout is the RAW MCP result
    /// object (with `content` and `isError`) — never unwrapped, never
    /// prettified into prose. Exit 0/2 by `isError`.
    public static func call(
        verb: String,
        arguments: [String: Any],
        transport: BotLinkTransport
    ) async -> BotLinkOutcome {
        // Same mapping as query: the caller passes the ARIA verb without
        // the moot_ prefix; botLink prepends it.
        let frame = McpOneShot.encodeFrame(id: 2, method: "tools/call", params: [
            "name": "moot_\(verb)",
            "arguments": arguments
        ])
        return await withResponse(transport, frame, expectID: 2) { obj in
            guard let result = obj["result"] as? [String: Any] else {
                return failure("no result field in tools/call response")
            }
            return BotLinkOutcome(
                stdoutJSON: result,
                exitCode: isErrorResult(result) ? 2 : 0
            )
        }
    }

    /// `rpc`: the escape hatch — one caller-authored JSON-RPC frame in, one
    /// frame out. The frame string is forwarded VERBATIM (no re-encoding of
    /// caller bytes). A notification (no `id`) produces empty stdout, exit
    /// 0. A response frame is printed whole; exit maps 0 / 2 (`result.isError`)
    /// / 1 (JSON-RPC `error` member — the hop worked but the call failed at
    /// the protocol level; stdout is the frame itself, still parseable).
    public static func rpc(frame: String, transport: BotLinkTransport) async -> BotLinkOutcome {
        guard let data = frame.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // A malformed frame is caller usage error, not a transport
            // failure: exit 64.
            return BotLinkOutcome(
                stdoutJSON: ["ok": false, "error": "rpc frame is not a JSON object"],
                exitCode: 64
            )
        }
        let expectID = obj["id"]
        do {
            guard let response = try await transport.send(frame, expectID) else {
                // Notification: no response frame, empty stdout, exit 0.
                return BotLinkOutcome(stdoutJSON: nil, exitCode: 0)
            }
            let exitCode: Int32
            if response["error"] != nil {
                exitCode = 1
            } else if let result = response["result"] as? [String: Any],
                      isErrorResult(result) {
                exitCode = 2
            } else {
                exitCode = 0
            }
            return BotLinkOutcome(stdoutJSON: response, exitCode: exitCode)
        } catch {
            return failure("\(error)")
        }
    }

    // MARK: - Output serialization

    /// Serialize the outcome's JSON value for stdout: one line, sorted keys
    /// (deterministic — normative for BL-2 parity tests), slashes unescaped.
    ///
    /// - Parameter json: the JSON value (object or array).
    /// - Returns: the serialized string, or a shaped serialization-failure
    ///   object as a last resort (never non-JSON stdout).
    public static func serializeStdout(_ json: Any) -> String {
        guard JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(
                withJSONObject: json,
                options: [.sortedKeys, .withoutEscapingSlashes]
              ) else {
            return #"{"error":"internal: stdout value not serializable","ok":false}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Internals

    /// A tools/call result is an error when `isError` is true. Absent or
    /// false both mean success (normative table: "isError false or absent").
    private static func isErrorResult(_ result: [String: Any]) -> Bool {
        (result["isError"] as? Bool) == true
    }

    /// Shape a transport/daemon/parse failure: `{"ok":false,"error":…}`,
    /// exit 1.
    private static func failure(_ message: String) -> BotLinkOutcome {
        BotLinkOutcome(stdoutJSON: ["ok": false, "error": message], exitCode: 1)
    }

    /// Send one frame and hand the response object to `handle`. All thrown
    /// transport errors and protocol-level `error` members collapse to the
    /// shaped exit-1 failure; a missing response does too.
    private static func withResponse(
        _ transport: BotLinkTransport,
        _ frame: String,
        expectID: Int,
        handle: ([String: Any]) -> BotLinkOutcome
    ) async -> BotLinkOutcome {
        do {
            guard let obj = try await transport.send(frame, expectID) else {
                return failure("no response received")
            }
            if let err = obj["error"] {
                return failure("tool error: \(err)")
            }
            return handle(obj)
        } catch {
            return failure("\(error)")
        }
    }

}
