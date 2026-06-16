import Foundation
import AriaMCP   // JSONRPCRequest, JSONRPCResponse, JSONValue

// MARK: - GatewayTransport  (A2 — transport seam)
//
// Every adapter in this app drives the dispatcher in-process. A real LAN
// surface (Siri reaching the MOOT over the network, Claude Desktop via
// mcp-remote) needs a transport between the client and the dispatcher. This
// file defines:
//   - GatewayTransport: the one-send protocol both transports conform to.
//   - InProcessTransport: the embedded path (no wire, direct dispatcher call).
//   - HTTPTransport: the real loopback-HTTP transport to a running resident daemon
//     (ARIA_MCP_SPEC §5): URLSession POST of a JSON-RPC 2.0 frame to the daemon's
//     127.0.0.1 endpoint, decode the JSON-RPC response from the body.
//
// The server half (HTTPServer in ARIA_MCP) and this client half speak
// byte-identical JSON-RPC frames — only the framing differs (HTTP body vs
// newline-delimited stdio). The wire contract is:
//   - POST to the configured loopback endpoint (default path "/")
//   - Body: JSON-RPC 2.0 object {"jsonrpc":"2.0","id":<id>,"method":<m>,"params":<p>}
//   - Content-Type: application/json
//   - No Origin header (native MCP clients send none; the server allows absent origins)
//   - Response: HTTP 200 with a JSON-RPC response body for tool calls;
//               HTTP 202 with empty body for notifications (no id → no reply)
//   - Error responses (non-2xx) name the transport condition, not a JSON-RPC one

/// A transport carries one JSON-RPC request to a dispatcher and returns the
/// response. The dispatcher is identical across transports (ARIA_MCP_SPEC §5:
/// "only JSON-RPC crosses the wire … the handlers do not change with the
/// transport").
public protocol GatewayTransport: Sendable {
    func send(_ request: JSONRPCRequest) async throws -> JSONRPCResponse?
}

/// The transport this app uses for the embedded (A1) path: no wire at all.
/// The request is handed straight to the in-process dispatcher via the bridge,
/// keeping the same call shape a networked transport would present.
public struct InProcessTransport: GatewayTransport {
    private let bridge: MootBridge
    public init(bridge: MootBridge) { self.bridge = bridge }

    public func send(_ request: JSONRPCRequest) async throws -> JSONRPCResponse? {
        // The bridge owns the dispatcher; hand the request straight to it and
        // return the real response. This is the faithful in-process shape a
        // networked transport would present, minus the wire.
        await bridge.handle(request)
    }
}

/// The HTTP transport to a running MOOT resident daemon (ARIA_MCP_SPEC §5).
///
/// Sends one JSON-RPC 2.0 frame as an HTTP POST body to the daemon's loopback
/// endpoint, decodes the JSON-RPC response from the HTTP body. The server
/// (HTTPServer in ARIA_MCP) speaks byte-identical JSON-RPC; the dispatcher is
/// transport-neutral and does not change when the transport changes.
///
/// Wire contract:
///   - POST to `endpoint` (127.0.0.1:<port>, default path "/")
///   - Body: compact JSON-RPC 2.0 object, Content-Type: application/json
///   - No Origin header (native MCP clients send none; the server allows absent origins)
///   - HTTP 200 → JSON-RPC response in the body (tool calls and errors both 200)
///   - HTTP 202 → notification (no `id`); returns nil per JSON-RPC 2.0 spec
///   - Non-2xx → GatewayTransportError.unexpectedHTTPStatus
///   - Connection refused or unreachable → GatewayTransportError.connectionRefused
///   - Request timeout → GatewayTransportError.timeout
///   - Malformed JSON or missing JSON-RPC fields → GatewayTransportError.malformedResponse
///
/// Security: loopback-only (CE). The daemon binds 127.0.0.1 and enforces a
/// DNS-rebinding guard on the server side (absent/loopback Origin allowed, any
/// other Origin rejected 403). This client sends no Origin, which is the correct
/// native-client posture. Enterprise OAuth (EE) composes above this transport
/// in v2 — this type does not handle tokens.
///
/// Bonjour advertisement and LAN/Local Network entitlement (NSBonjourServices,
/// NSLocalNetworkUsageDescription) are not part of this transport. This type is
/// loopback-only: it connects to 127.0.0.1 and does not discover or contact
/// remote hosts. LAN discovery is a future surface beyond loopback CE.
public struct HTTPTransport: GatewayTransport, Sendable {

    /// The loopback endpoint of the resident daemon (e.g. `http://127.0.0.1:4242`).
    public let endpoint: URL

    /// Request timeout. The daemon is local — 30 s covers any plausible tool call
    /// including expensive search and dreaming operations.
    public let timeout: TimeInterval

    public init(endpoint: URL, timeout: TimeInterval = 30.0) {
        self.endpoint = endpoint
        self.timeout = timeout
    }

    /// POST one JSON-RPC 2.0 frame to the daemon and return the decoded response.
    ///
    /// Returns `nil` for HTTP 202 (the server's notification path: the request
    /// carried no `id`, so the JSON-RPC spec forbids a reply and the server sends
    /// an empty 202). All other outcomes either return a `JSONRPCResponse` or
    /// throw a named `GatewayTransportError`.
    public func send(_ request: JSONRPCRequest) async throws -> JSONRPCResponse? {
        // Build the JSON-RPC request body. JSONValue.encoded() matches the server's
        // serializer exactly (same Foundation JSONSerialization path), so the bytes
        // are round-trip identical to what StdioServer and HTTPServer produce.
        let requestValue = buildRequestValue(request)
        let body: Data
        do {
            body = try requestValue.encoded()
        } catch {
            throw GatewayTransportError.malformedResponse("Failed to encode outbound JSON-RPC request: \(error)")
        }

        var urlRequest = URLRequest(url: endpoint, timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        // Content-Type: application/json — the server requires this for POST routing.
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // No Origin header: native MCP clients (Claude Code, Claude Desktop, this app)
        // do not set Origin. The server's CSRF guard allows absent Origins. Sending a
        // synthetic Origin would require it to be loopback or the server would 403.

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch let urlError as URLError {
            // Map URLError codes to named GatewayTransportError cases.
            switch urlError.code {
            case .cannotConnectToHost, .networkConnectionLost,
                 .notConnectedToInternet:
                throw GatewayTransportError.connectionRefused(endpoint: endpoint)
            case .timedOut:
                throw GatewayTransportError.timeout(endpoint: endpoint, after: timeout)
            default:
                throw GatewayTransportError.connectionRefused(endpoint: endpoint)
            }
        } catch {
            // Any other transport-level failure (DNS, TLS, etc.) maps to connection refused
            // because this is a loopback endpoint — the only expected failure is the daemon
            // not running. TLS is not used on loopback CE.
            throw GatewayTransportError.connectionRefused(endpoint: endpoint)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GatewayTransportError.malformedResponse("Non-HTTP response from loopback endpoint \(endpoint)")
        }

        // HTTP 202: notification path. The request had no `id`; the server sent an
        // empty 202 Accepted body. Return nil per JSON-RPC 2.0 (no reply for notifications).
        if httpResponse.statusCode == 202 {
            return nil
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw GatewayTransportError.unexpectedHTTPStatus(
                endpoint: endpoint,
                status: httpResponse.statusCode
            )
        }

        // Parse the response body as a JSON-RPC frame using the server's own
        // decoding path (JSONValue.parse → JSONRPCResponse.decode).
        let parsed: JSONValue
        do {
            parsed = try JSONValue.parse(data)
        } catch {
            throw GatewayTransportError.malformedResponse(
                "Response body from \(endpoint) is not valid JSON: \(error)"
            )
        }

        guard let rpcResponse = JSONRPCResponse.decode(parsed) else {
            throw GatewayTransportError.malformedResponse(
                "Response body from \(endpoint) is not a valid JSON-RPC 2.0 response"
            )
        }

        return rpcResponse
    }

    /// Build the JSON-RPC 2.0 request as a JSONValue so `encoded()` serializes it
    /// with the same path the server uses for responses — keeping round-trip
    /// byte-identity between the two JSON-RPC directions.
    private func buildRequestValue(_ request: JSONRPCRequest) -> JSONValue {
        var obj: [String: JSONValue] = [
            "jsonrpc": .string(request.jsonrpc),
            "method":  .string(request.method),
        ]
        if let id = request.id {
            obj["id"] = id
        }
        if let params = request.params {
            obj["params"] = params
        }
        return .object(obj)
    }
}

/// Decode a JSON-RPC 2.0 response from the server's serialized JSONValue format.
///
/// The server serializes responses as
/// `{"jsonrpc":"2.0","id":<id>,"result":<v>}` or
/// `{"jsonrpc":"2.0","id":<id>,"error":{"code":<n>,"message":<s>}}`.
/// This mirrors `JSONRPCRequest.decode` — the same structural guard that the
/// server uses on inbound requests, applied to inbound responses on the client.
private extension JSONRPCResponse {
    static func decode(_ value: JSONValue) -> JSONRPCResponse? {
        guard let object = value.objectValue else { return nil }
        guard let jsonrpc = object["jsonrpc"]?.stringValue, jsonrpc == "2.0" else { return nil }
        guard let id = object["id"] else { return nil }
        if let result = object["result"] {
            return .ok(id, result)
        }
        if let errObj = object["error"]?.objectValue,
           let code = errObj["code"]?.intValue,
           let message = errObj["message"]?.stringValue {
            return .failure(id, JSONRPCError(code: Int(code), message: message, data: errObj["data"]))
        }
        return nil
    }
}

private extension JSONValue {
    /// Convenience: integer value from .integer case (Int64 → Int).
    var intValue: Int64? {
        if case .integer(let n) = self { return n }
        return nil
    }
}

/// Transport-level errors for `HTTPTransport`. Each case names the real condition
/// (connection refused, timeout, non-2xx, malformed response) so callers can react
/// to the specific failure mode without inspecting raw error strings.
public enum GatewayTransportError: Error, CustomStringConvertible {

    /// The daemon is not running or the port is wrong. Loopback-only: if the
    /// process is local, ECONNREFUSED means the daemon is not listening.
    case connectionRefused(endpoint: URL)

    /// The request timed out waiting for the daemon to respond. `after` is the
    /// configured `URLRequest.timeoutInterval`.
    case timeout(endpoint: URL, after: TimeInterval)

    /// The server responded with an HTTP status code outside 2xx. The status
    /// is included so the caller can distinguish 403 (CSRF guard fired, wrong
    /// Origin) from 503 (gate shed the connection) from 4xx/5xx tool routing
    /// errors. JSON-RPC-level failures (method errors, invalid params) always
    /// return HTTP 200 with a JSON-RPC error payload — they never reach here.
    case unexpectedHTTPStatus(endpoint: URL, status: Int)

    /// The response body could not be decoded as a valid JSON-RPC 2.0 frame.
    /// Includes a diagnostic reason string naming which structural check failed.
    case malformedResponse(_ reason: String)

    public var description: String {
        switch self {
        case .connectionRefused(let endpoint):
            return "Cannot connect to resident daemon at \(endpoint) — is mootx01 running on that port?"
        case .timeout(let endpoint, let after):
            return "Request to resident daemon at \(endpoint) timed out after \(after) s"
        case .unexpectedHTTPStatus(let endpoint, let status):
            return "Resident daemon at \(endpoint) returned HTTP \(status) (expected 200 or 202)"
        case .malformedResponse(let reason):
            return "Malformed JSON-RPC response from resident daemon: \(reason)"
        }
    }
}
