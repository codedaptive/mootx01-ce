import Foundation
import AriaMCP   // JSONValue, JSONRPCRequest

// MARK: - LANRequestGate  (the testable core of MootLANServer)
//
// Everything MootLANServer does to an inbound request EXCEPT the socket:
// parse a minimal HTTP/1.1 POST, enforce bearer auth, and decode the
// JSON-RPC body. Split from the NWListener so the auth and parsing decisions
// are unit-tested without a live connection. The listener feeds raw bytes in
// and writes the response bytes out; every policy decision lives here.
//
// Minimal HTTP on purpose: native MCP-over-HTTP clients POST a JSON-RPC body
// to "/" with a bearer token. We parse exactly that shape and reject anything
// else with a precise status — we are not a general web server.

public enum LANRequestGate {

    /// The outcome of admitting one raw HTTP request.
    public enum Admission: Sendable, Equatable {
        /// Authorized: this JSON-RPC request may go to the dispatcher.
        case authorized(JSONRPCRequest)
        /// Rejected before the dispatcher, with the HTTP status to return.
        case rejected(status: Int, reason: String)

        public static func == (lhs: Admission, rhs: Admission) -> Bool {
            switch (lhs, rhs) {
            case let (.rejected(s1, r1), .rejected(s2, r2)): return s1 == s2 && r1 == r2
            case (.authorized, .authorized): return true
            default: return false
            }
        }
    }

    /// A parsed HTTP request: method, target, headers (lowercased keys), body.
    public struct ParsedRequest: Sendable, Equatable {
        public let method: String
        public let target: String
        public let headers: [String: String]
        public let body: Data
    }

    /// Parse a raw HTTP/1.1 request. Returns nil if the head is malformed or
    /// the full body (per Content-Length) has not arrived yet — the caller
    /// keeps buffering. Header keys are lowercased for case-insensitive lookup.
    public static func parse(_ raw: Data) -> ParsedRequest? {
        // Split head from body at the CRLFCRLF boundary.
        guard let separator = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = raw[raw.startIndex..<separator.lowerBound]
        let bodyStart = separator.upperBound
        guard let headString = String(data: head, encoding: .utf8) else { return nil }

        var lines = headString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let body = Data(raw[bodyStart...])
        // If a Content-Length is declared, require the whole body before parsing.
        if let lengthString = headers["content-length"], let length = Int(lengthString) {
            guard body.count >= length else { return nil }
            return ParsedRequest(method: method, target: target, headers: headers,
                                 body: body.prefix(length))
        }
        return ParsedRequest(method: method, target: target, headers: headers, body: body)
    }

    /// Apply the full admission policy to a parsed request against a credential:
    /// method must be POST, Authorization must carry the matching bearer token,
    /// and the body must be a valid JSON-RPC 2.0 request. Order matters — auth
    /// is checked before the body is even parsed, so an unauthorized caller
    /// learns nothing about payload validity.
    public static func admit(_ request: ParsedRequest, credential: LANCredential) -> Admission {
        guard request.method.uppercased() == "POST" else {
            return .rejected(status: 405, reason: "Only POST is accepted")
        }
        guard let presented = LANCredential.bearerToken(fromAuthorizationHeader: request.headers["authorization"]) else {
            return .rejected(status: 401, reason: "Missing or malformed Authorization: Bearer header")
        }
        guard credential.matches(presented: presented) else {
            return .rejected(status: 401, reason: "Invalid bearer token")
        }
        guard let value = try? JSONValue.parse(request.body),
              let rpc = decodeJSONRPCRequest(value) else {
            return .rejected(status: 400, reason: "Body is not a valid JSON-RPC 2.0 request")
        }
        return .authorized(rpc)
    }

    /// Remote-caller export posture: a LAN client is not the estate owner, so
    /// it may only ever read PUBLIC (exportable) memory — the same §6.2
    /// serve-out gate the callback-URL recall applies. This rewrites a
    /// `tools/call` for `moot_memory_search` to force `filter:exportable`,
    /// overriding any caller-supplied filter (a remote caller cannot ask for
    /// unconfirmed/contained/etc.). Non-recall calls pass through unchanged;
    /// write/mutate tools are refused separately by the write allowlist below.
    public static func enforceRemoteExportPosture(_ request: JSONRPCRequest) -> JSONRPCRequest {
        guard request.method == "tools/call",
              let params = request.params?.objectValue,
              params["name"]?.stringValue == "moot_memory_search" else {
            return request
        }
        var args = params["arguments"]?.objectValue ?? [:]
        args["filter"] = .string("exportable")   // force, do not merge
        var newParams = params
        newParams["arguments"] = .object(args)
        return JSONRPCRequest(id: request.id, method: request.method, params: .object(newParams))
    }

    /// Tools a remote LAN caller may invoke. Read-only surface only: recall,
    /// tools/list, initialize. Every write/mutate/erase verb and every heavy
    /// verb is refused — the LAN server serves memory out, it does not accept
    /// remote mutation of the owner's estate.
    public static func isRemotelyPermitted(_ request: JSONRPCRequest) -> Bool {
        switch request.method {
        case "initialize", "tools/list", "notifications/initialized", "ping":
            return true
        case "tools/call":
            guard let name = request.params?.objectValue?["name"]?.stringValue else { return false }
            // Read-only tools only. Anything that writes is owner-local.
            let readOnly: Set<String> = [
                "moot_memory_search", "moot_memory_get", "moot_memory_list",
                "moot_fact_search", "moot_fact_timeline", "moot_recall_precise",
                "moot_recall_shaped", "moot_recall_distilled", "moot_estate_status",
                "moot_connection_search", "moot_connection_map", "moot_list_lenses",
            ]
            return readOnly.contains(name)
        default:
            return false
        }
    }

    /// Decode a JSON-RPC request from a parsed JSONValue (the client's POST body).
    static func decodeJSONRPCRequest(_ value: JSONValue) -> JSONRPCRequest? {
        guard let object = value.objectValue,
              object["jsonrpc"]?.stringValue == "2.0",
              let method = object["method"]?.stringValue else { return nil }
        return JSONRPCRequest(id: object["id"], method: method, params: object["params"])
    }
}
