import Foundation
import AriaMCP   // JSONRPCRequest, JSONRPCResponse, JSONValue

// MARK: - GatewayTransport  (A2 — transport seam)
//
// Every adapter in this app drives the dispatcher in-process. A real LAN
// surface (Siri reaching the MOOT over the network, Claude Desktop via
// mcp-remote) needs a transport between the client and the dispatcher. This
// file is the *seam* for that: one protocol, one real conforming transport
// (in-process), and one explicit, non-building-it stub for HTTP.
//
// The HTTP/Streamable-HTTP transport is NOT built here. Per ARIA_MCP_SPEC §5
// it is the resident daemon's v1.0 primary transport, implemented in a
// separate transport workstream. The stub exists so the shape is visible and
// the hand-off is documented, not so it runs.

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

/// The HTTP transport seam — NOT implemented here. Documents exactly what the
/// resident daemon supplies so the gateway can point at it post-WWDC (or when
/// Apple Intelligence dials out as an MCP client, §7).
///
/// What lands here when the loopback-HTTP transport (planned) ships:
///   - bind loopback 127.0.0.1:<port>, JSON-RPC 2.0 over HTTP POST
///   - SSE for server→client streaming (MCP "Streamable HTTP")
///   - Bonjour advertisement for LAN discovery (foreground-only on iOS)
///   - Local Network permission (NSLocalNetworkUsageDescription / NSBonjourServices)
///   - auth: loopback owner-by-default (CE); OAuth/scoped tokens are EE-only
public struct HTTPTransportSeam: Sendable {
    /// The loopback endpoint the resident daemon would expose. Stored as
    /// documentation of the contract; this type performs no I/O.
    public let endpoint: URL
    public init(endpoint: URL) { self.endpoint = endpoint }

    /// Intentionally unimplemented. Calling it is a programmer error that
    /// names where the real work lives, rather than silently no-op'ing.
    public func send(_ request: JSONRPCRequest) async throws -> JSONRPCResponse? {
        throw GatewayTransportError.httpTransportNotInThisBranch(endpoint: endpoint)
    }
}

public enum GatewayTransportError: Error, CustomStringConvertible {
    case httpTransportNotInThisBranch(endpoint: URL)

    public var description: String {
        switch self {
        case .httpTransportNotInThisBranch(let endpoint):
            return "HTTP transport (\(endpoint)) is the loopback-HTTP transport (ARIA_MCP_SPEC §5), not yet available in this build. Use InProcessTransport here."
        }
    }
}
