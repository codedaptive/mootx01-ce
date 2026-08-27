import AriaMCPWire
import Foundation

// MARK: - MootEstateCalling
//
// The call surface a consumer needs from an estate, satisfied identically by
// the embedded `MootBridge` and the remote `MootCaller`.
//
// `MootToolCalling` (in MootIntentKit) already abstracts the intent layer's
// needs — one method, `callTool`. The app's own surfaces need more than that:
// the rendered `GatewayCall` records the wire-display views show, the raw
// `tools/list` result, and the frame-forwarding path the LAN server drives. Up
// to now those callers named `MootBridge` concretely, which is what tied them
// to a process that opens SQLite.
//
// This protocol is the seam that unties them. It deliberately does NOT include:
//
//   - `estateStorage()` — it vends a live `any Storage`, which has no wire
//     representation. Federation and the CloudKit courier use it and are
//     therefore not consumers of this protocol; moving them is separate work.
//   - `registerSyncEngine` — same reason, and for the same two callers.
//   - `attachSQLite` / `attachInMemory` — construction, and specific to owning
//     an estate rather than calling one.
//
// The omissions are the point. A consumer written against this protocol cannot
// reach storage, so "the GUI never opens SQLite" becomes a property the type
// system carries rather than a rule reviewers have to keep re-checking.

/// The estate call surface shared by the embedded bridge and the remote caller.
public protocol MootEstateCalling: Actor, Sendable {

    /// The MCP server identity on the other end.
    nonisolated var serverName: String { get }

    /// Which estate this surface is attached to, in terms the surface may know.
    nonisolated var estateIdentity: EstateIdentity { get }

    /// Send one JSON-RPC request and return the full rendered call record.
    func call(method: String, params: JSONValue?) async -> GatewayCall

    /// Invoke a named `moot_*` tool and return the full rendered call record.
    func callToolFull(_ name: String, arguments: [String: JSONValue]) async -> GatewayCall

    /// The raw `tools/list` result. Degrades to `{"tools": []}` rather than
    /// taking a surface down with the estate.
    func toolsList() async -> JSONValue

    /// Forward a fully-formed request frame and return the matching response.
    /// `nil` means — and only means — the frame was a notification.
    func handle(_ request: JSONRPCRequest) async -> JSONRPCResponse?
}

extension MootCaller: MootEstateCalling {}
