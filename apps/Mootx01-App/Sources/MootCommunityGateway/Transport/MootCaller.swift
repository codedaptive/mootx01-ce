import AriaMCPWire
import Foundation

// MARK: - MootCaller
//
// The remote twin of `MootBridge`.
//
// `MootBridge` owns an estate: it opens storage, builds a dispatcher, and hands
// requests to it in-process. `MootCaller` owns nothing. It holds a transport to
// a resident daemon that owns the estate, and it presents the identical call
// surface — `call`, `callToolFull`, `toolsList`, `handle`, and
// `MootToolCalling` — so a consumer written against the bridge works unchanged
// against the daemon.
//
// `handle` is the one member of that surface whose remote form is not a
// straight forward: ids chosen by a LAN peer share a connection with this
// actor's own numbering and must be remapped. See the method for the argument.
//
// That symmetry is the point of this file, and it is why the two types share
// `GatewayResponseDecoder` instead of each flattening MCP results their own
// way: the embedded and remote paths must not be able to drift on what
// `isError`, `text`, or `structuredContent` mean.
//
// The one behavior the bridge has no equivalent for is transport failure. The
// dispatcher is in-process and cannot be unreachable; a daemon can. Every such
// failure lands as a `GatewayCall` with `isError == true`, `structured == nil`,
// and the transport condition named in `text`. Nothing here retries, falls back
// to an embedded estate, or degrades to an unauthenticated path — a caller that
// silently substitutes a different estate for the one it was asked about is
// worse than a caller that reports it cannot reach the daemon.
//
// This type performs no authentication of its own. It is handed a transport
// that is already authenticated (`AuthenticatedDaemonTransport`, produced by
// `DaemonReadiness`) and carries whatever authorization the daemon requires via
// `HTTPTransport`'s request-authorization seam.

/// A transport-backed seam onto one resident daemon's estate, projected over
/// the ARIA tool surface.
///
/// An `actor` for the same reason `MootBridge` is: it owns a monotonic JSON-RPC
/// id counter, and pairing a response to its request on the wire requires that
/// no two concurrent calls hand out the same id.
public actor MootCaller {

    /// The wire to the daemon. Already authenticated by the time it gets here.
    private let transport: any GatewayTransport

    /// The MCP server identity this caller expects on the other end, carried so
    /// diagnostics can say which daemon a call was aimed at.
    public nonisolated let serverName: String

    /// Which estate the daemon on the other end owns.
    ///
    /// Supplied from the descriptor rather than discovered, and never a file
    /// URL: a client that could name the estate's location on disk is one
    /// refactor away from opening it, and the single-writer invariant is what
    /// stands between that and a corrupted estate.
    public nonisolated let estateIdentity: EstateIdentity

    /// Monotonic JSON-RPC request id. Every request gets a fresh integer id so
    /// a reader can pair a response to its request on the wire.
    private var nextID: Int64 = 1

    /// Build a caller over an established transport.
    ///
    /// - Parameters:
    ///   - transport: The wire to the daemon.
    ///   - serverName: The MCP server identity expected on the other end.
    ///   - estateIdentity: The estate the daemon owns, from its descriptor.
    public init(
        transport: any GatewayTransport,
        serverName: String,
        estateIdentity: EstateIdentity
    ) {
        self.transport = transport
        self.serverName = serverName
        self.estateIdentity = estateIdentity
    }

    // MARK: JSON-RPC drive

    /// Send one JSON-RPC request to the daemon and return the raw response.
    ///
    /// The unrendered path, for callers that need the result `JSONValue`
    /// itself rather than the flattened `GatewayCall` — `DaemonReadiness` reads
    /// the `initialize` result this way. Transport failures propagate; `nil`
    /// means the daemon answered without a response frame (HTTP 202, the
    /// notification path), which no method this gateway sends should produce.
    ///
    /// - Parameters:
    ///   - method: The JSON-RPC method name.
    ///   - params: The method's params, or nil for parameterless methods.
    /// - Returns: The response frame, or nil if the daemon sent none.
    /// - Throws: The transport's own error when the daemon cannot be reached.
    public func exchange(method: String, params: JSONValue?) async throws -> JSONRPCResponse? {
        let request = nextRequest(method: method, params: params)
        let response = try await transport.send(request)
        // Bind the answer to the question at the caller as well as at the wire.
        // HTTPTransport enforces this for the loopback path, but any transport
        // can be handed to this actor, and a result paired with the wrong call
        // is indistinguishable from a correct one once it leaves here.
        if let response, response.id != request.id {
            throw MootCallerError.responseIdentifierMismatch(method: method)
        }
        return response
    }

    /// Send one JSON-RPC notification — a frame with no `id`, which the JSON-RPC
    /// 2.0 spec forbids the peer to answer.
    ///
    /// Used for MCP lifecycle notifications such as `notifications/initialized`.
    /// No id is consumed from the counter: ids exist to pair a response to its
    /// request, and there is no response to pair.
    ///
    /// - Parameters:
    ///   - method: The notification method name.
    ///   - params: The notification's params, or nil.
    /// - Throws: The transport's own error when the daemon cannot be reached.
    public func notify(method: String, params: JSONValue?) async throws {
        _ = try await transport.send(JSONRPCRequest(id: nil, method: method, params: params))
    }

    /// Forward a fully-formed request frame to the daemon and return the
    /// matching response — the remote twin of `MootBridge.handle(_:)`, and the
    /// path `MootLANServer` drives when it re-projects the estate to a LAN peer.
    ///
    /// Two things differ from the in-process case and neither is cosmetic.
    ///
    /// IDS ARE REMAPPED. The incoming id was chosen by the LAN peer, while this
    /// actor's own `call`/`exchange` traffic is numbering frames from
    /// `nextID` on the same connection. A peer that numbers its frames 1, 2, 3
    /// would collide with them, and a collided pair is indistinguishable from a
    /// correct one once it leaves here. So the frame goes out under an id this
    /// actor owns, the answer is checked against that id, and the peer's own id
    /// is restored before the response is handed back. A notification carries no
    /// id, has no response to pair, and consumes none.
    ///
    /// FAILURE IS A FRAME, NOT `nil`. `nil` already means "the peer treated this
    /// as a notification". Returning it for an unreachable daemon would report a
    /// delivered notification that never happened, so every failure comes back
    /// as an error payload under the peer's id.
    ///
    /// The error message is deliberately fixed and uninformative: this response
    /// travels to a LAN peer, and the transport condition — endpoint, session
    /// state, underlying errno — is diagnostic detail that peer is not entitled
    /// to. Local callers that need the condition use `call`, which renders it.
    ///
    /// - Parameter request: The frame to forward, with the peer's own id.
    /// - Returns: The response under the peer's id, or nil for a notification.
    public func handle(_ request: JSONRPCRequest) async -> JSONRPCResponse? {
        guard let peerID = request.id else {
            // A notification's delivery outcome has no frame to be reported in.
            // JSON-RPC 2.0 forbids answering it, so a send failure is dropped
            // here rather than invented into a response the peer must not get.
            _ = try? await transport.send(request)
            return nil
        }

        let wireID = JSONValue.integer(nextID)
        nextID += 1
        let forwarded = JSONRPCRequest(id: wireID, method: request.method, params: request.params)

        do {
            guard let response = try await transport.send(forwarded) else {
                // The daemon accepted an id-bearing frame as a notification.
                return Self.forwardingFailure(peerID)
            }
            guard response.id == wireID else {
                return Self.forwardingFailure(peerID)
            }
            return JSONRPCResponse(id: peerID, payload: response.payload)
        } catch {
            return Self.forwardingFailure(peerID)
        }
    }

    /// The one failure frame `handle(_:)` returns, under the peer's own id.
    /// Fixed text — see `handle(_:)` on why the condition is withheld.
    private static func forwardingFailure(_ peerID: JSONValue) -> JSONRPCResponse {
        .failure(
            peerID,
            JSONRPCError(
                code: JSONRPCErrorCode.internalError,
                message: "The estate is not reachable"
            )
        )
    }

    /// Send one JSON-RPC request through the transport and return the full call
    /// record. `params` may be nil for parameterless methods like `tools/list`.
    ///
    /// Never throws: an unreachable daemon is reported as a failed call, in the
    /// same shape a refused tool would be, so a consumer has exactly one error
    /// path to handle rather than two.
    ///
    /// - Parameters:
    ///   - method: The JSON-RPC method name.
    ///   - params: The method's params, or nil.
    /// - Returns: The rendered call record.
    public func call(method: String, params: JSONValue?) async -> GatewayCall {
        let request = nextRequest(method: method, params: params)
        do {
            guard let response = try await transport.send(request) else {
                return GatewayResponseDecoder.unanswered(
                    request: request,
                    note: "no response — the daemon accepted the frame as a notification"
                )
            }
            guard response.id == request.id else {
                return GatewayResponseDecoder.transportFailure(
                    request: request,
                    error: MootCallerError.responseIdentifierMismatch(method: method)
                )
            }
            return GatewayResponseDecoder.rendered(request: request, response: response)
        } catch {
            return GatewayResponseDecoder.transportFailure(request: request, error: error)
        }
    }

    /// Convenience for the common `tools/call` path: name + arguments object.
    /// Returns the full GatewayCall (request + response JSON + text + isError).
    ///
    /// - Parameters:
    ///   - name: The `moot_*` tool name.
    ///   - arguments: The tool's arguments object.
    /// - Returns: The rendered call record.
    public func callToolFull(_ name: String, arguments: [String: JSONValue]) async -> GatewayCall {
        await call(method: "tools/call", params: Self.toolCallParams(name: name, arguments: arguments))
    }

    /// The raw `tools/list` result (the `moot_*` tool descriptors the daemon
    /// projects). Never throws — a read used to paint UI degrades to an empty
    /// list rather than taking the surface down with the daemon.
    ///
    /// - Returns: The `tools/list` result, or `{"tools": []}` when the daemon
    ///   is unreachable or answered with an error.
    public func toolsList() async -> JSONValue {
        let empty: JSONValue = .object(["tools": .array([])])
        guard let response = try? await exchange(method: "tools/list", params: nil),
              case .result(let value) = response.payload else {
            return empty
        }
        return value
    }

    // MARK: Request construction

    /// Build the next request frame, consuming one id from the monotonic counter.
    private func nextRequest(method: String, params: JSONValue?) -> JSONRPCRequest {
        let id = JSONValue.integer(nextID)
        nextID += 1
        return JSONRPCRequest(id: id, method: method, params: params)
    }

    /// The `tools/call` params object. Shared by `callToolFull` and the
    /// `MootToolCalling` conformance so the two cannot build different frames
    /// for the same tool invocation.
    private static func toolCallParams(name: String, arguments: [String: JSONValue]) -> JSONValue {
        .object([
            "name": .string(name),
            "arguments": .object(arguments),
        ])
    }
}

/// Failures the caller itself detects, independent of any transport.
public enum MootCallerError: Error, CustomStringConvertible {

    /// The peer answered with a JSON-RPC id other than the one sent. Fails
    /// closed: an unpaired result cannot be attributed to this call.
    case responseIdentifierMismatch(method: String)

    public var description: String {
        switch self {
        case .responseIdentifierMismatch(let method):
            return "The daemon answered \(method) with a JSON-RPC id that does not match the request"
        }
    }
}
