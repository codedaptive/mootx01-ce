import Foundation
import AriaMCP
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
import MootIntentKit

// MARK: - MootBridge
//
// The one substrate-touching file in the gateway. Everything else in
// MootGateway — every App Intent, the URL router, the share sink — reaches
// the MOOT through this bridge, and only through the public ARIA tool
// surface (the 44 `moot_*` tools projected by ARIA_MCP). No shell reaches
// around the dispatcher into GeniusLocusKit directly; that is the whole
// point of the design — every adapter talks to the substrate the exact way
// a remote MCP client (Siri, Claude, a Shortcut) eventually will, just
// in-process and with no transport in between.
//
// Wiring is the same three steps examples/SidecarDemo's `MootSidecar`
// documents — pick a backend, create the estate schema, open the coordinator,
// build the ARIA_MCP dispatcher — inlined here because that file is "the ~50
// lines of glue an app copies into its own source." The bridge then drives
// `dispatcher.handle(JSONRPCRequest)` — the public in-process entry at
// packages/kits/AriaMcpKit/Sources/AriaMCP/Server.swift — so the full JSON-RPC envelope
// (request and response) is available to render. Showing that envelope on
// screen *is* "feel the top-level communication."

/// A single in-process call's full record: the JSON-RPC request and
/// response, plus the flattened text content and error flag pulled out of
/// the MCP `tools/call` result shape for convenient display.
public struct GatewayCall: Sendable {
    /// The verbatim JSON-RPC request frame sent to the dispatcher.
    public let requestJSON: String
    /// The verbatim JSON-RPC response frame returned by the dispatcher.
    public let responseJSON: String
    /// The concatenated text of every `content[].text` block in a
    /// successful `tools/call` result. Empty for non-tool methods.
    public let text: String
    /// The `isError` flag from a `tools/call` result, or a transport-level
    /// JSON-RPC error. True means the substrate (or the surface) said no.
    public let isError: Bool
}

/// The gateway's single seam onto one MOOT, projected over the ARIA tool
/// surface. An `actor` because it owns a monotonic JSON-RPC id counter and
/// serializes calls; the underlying `GeniusLocusKit` is itself an actor, so
/// concurrent verb work is already serialized one layer down.
public actor MootBridge {

    /// The ARIA_MCP method router built over this estate's tool dispatcher.
    /// Driving `dispatcher.handle(_:)` is the entire substrate seam.
    private let dispatcher: ARIA_MCPDispatcher

    /// The MCP server identity this bridge advertises, so a client can tell
    /// it apart from a vanilla `aria-mcp`.
    public nonisolated let serverName: String

    /// Monotonic JSON-RPC request id. Every request gets a fresh integer id
    /// so a reader can pair a response to its request on the wire.
    private var nextID: Int64 = 1

    /// Absolute path of the backing store, surfaced in the Edges tab so the
    /// operator can point a real `aria-mcp` at the same estate. `nil` for an
    /// in-memory estate (nothing on disk to share).
    public nonisolated let databasePath: String?

    private init(dispatcher: ARIA_MCPDispatcher, serverName: String, databasePath: String?) {
        self.dispatcher = dispatcher
        self.serverName = serverName
        self.databasePath = databasePath
    }

    // MARK: Attachment

    /// The three-step wiring (schema → coordinator → dispatcher) over an
    /// already-constructed storage backend. Mirrors `MootSidecar.attach`.
    private static func makeDispatcher(
        storage: some Storage,
        owner: OwnerCredentials,
        serverName: String
    ) async throws -> ARIA_MCPDispatcher {
        let kit = GeniusLocusKit()
        // Schema first (Estate.create installs it), then the coordinator
        // handle that drives every verb. `open` without `create` fails — the
        // backend would have no schema. The created estate is discarded; the
        // schema side-effect on the backend is the point.
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        let info = ARIA_MCPDispatcher.ServerInfo(name: serverName, version: "0.1.0")
        // Forward serverName as the host identity so facts/memories filed
        // through this bridge are stamped with the correct source.
        let tooling = ToolDispatcher(kit: kit, handle: handle, serverIdentity: serverName)
        return ARIA_MCPDispatcher(info: info, tooling: tooling)
    }

    /// Attach an ephemeral in-memory MOOT. Used by tests and by the App
    /// Intent shells when the system instantiates them without a prior
    /// app launch (no app bundle has configured a durable estate).
    public static func attachInMemory(serverName: String = "Gateway") async throws -> MootBridge {
        let owner = OwnerCredentials(ownerIdentifier: "gateway-owner")
        let configuration = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: configuration)
        let dispatcher = try await makeDispatcher(storage: storage, owner: owner, serverName: serverName)
        return MootBridge(dispatcher: dispatcher, serverName: serverName, databasePath: nil)
    }

    /// Attach a durable SQLite-backed MOOT at `url`. The cross-process edge
    /// demo works because an external `aria-mcp` pointed at the same file
    /// (`ARIA_MCP_SQLITE_PATH=<url>`) sees the same drawers.
    public static func attachSQLite(at url: URL, serverName: String = "Gateway") async throws -> MootBridge {
        // Parent-directory creation mirrors AriaMCPMain: the caller should
        // not have to pre-create ~/.mootx01 by hand.
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let owner = OwnerCredentials(ownerIdentifier: "gateway-owner")
        // Whole-file encryption: load this estate's per-estate key from
        // the Keychain (keyed by the estate file path) and open the estate as
        // FullDatabase, so the file — schema and content — is SQLCipher-encrypted
        // at rest. A separately-spawned managed server pointed at the same file
        // derives the same account and loads the same key; sharing it across
        // processes needs a shared keychain access group + entitlement, verified
        // on a signed build.
        // Shared access group (#94): both the app and the managed server
        // must read the same Keychain item for the same SQLCipher estate.
        let key = try KeychainKeyStore(
            service: "com.codedaptive.mootx01",
            estateURL: url,
            accessGroup: "com.codedaptive.mootx01.shared"
        ).loadOrCreateKey()
        let configuration = EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url, busyTimeout: 5.0),
            encryptionConfig: .fullDatabase(key: key)
        )
        let storage = try SQLiteStorage(configuration: configuration)
        let dispatcher = try await makeDispatcher(storage: storage, owner: owner, serverName: serverName)
        return MootBridge(dispatcher: dispatcher, serverName: serverName, databasePath: url.path)
    }

    // MARK: JSON-RPC drive

    /// Send one JSON-RPC request through the in-process dispatcher and
    /// return the full call record. `params` may be nil for parameterless
    /// methods like `tools/list`.
    public func call(method: String, params: JSONValue?) async -> GatewayCall {
        let id = JSONValue.integer(nextID)
        nextID += 1
        let request = JSONRPCRequest(id: id, method: method, params: params)

        let requestJSON = Self.pretty(request.asRequestJSONValue)
        // The dispatcher returns nil only for notifications; every method we
        // send carries an id, so a nil response here is a surface bug, not a
        // protocol case. Surface it honestly rather than masking it.
        guard let response = await dispatcher.handle(request) else {
            return GatewayCall(
                requestJSON: requestJSON,
                responseJSON: "(no response — dispatcher treated request as a notification)",
                text: "",
                isError: true
            )
        }

        let responseJSON = Self.pretty(response.asJSONValue)
        let (text, isError) = Self.flatten(response)
        return GatewayCall(
            requestJSON: requestJSON,
            responseJSON: responseJSON,
            text: text,
            isError: isError
        )
    }

    /// Pass a fully-formed request straight to the dispatcher and return the
    /// raw response. The transport seam (`InProcessTransport`) uses this;
    /// `call` is the rendered path that also captures request/response JSON.
    public func handle(_ request: JSONRPCRequest) async -> JSONRPCResponse? {
        await dispatcher.handle(request)
    }

    /// Convenience for the common `tools/call` path: name + arguments object.
    /// Returns the full GatewayCall (request + response JSON + text + isError).
    /// This is the display-oriented path used by the app's wire-display views.
    /// See the `MootToolCalling` conformance below for the protocol-oriented path
    /// that returns the leaner `IntentCallResult` the intent kit uses.
    public func callToolFull(_ name: String, arguments: [String: JSONValue]) async -> GatewayCall {
        let params: JSONValue = .object([
            "name": .string(name),
            "arguments": .object(arguments),
        ])
        return await call(method: "tools/call", params: params)
    }

    /// The raw `tools/list` result (the 44 `moot_*` tool descriptors). Used
    /// by the "The Top" tab to render the live ARIA contract. Never throws —
    /// a read used to paint UI degrades to an empty list.
    public func toolsList() async -> JSONValue {
        let id = JSONValue.integer(nextID)
        nextID += 1
        let request = JSONRPCRequest(id: id, method: "tools/list", params: nil)
        guard let response = await dispatcher.handle(request),
              case .result(let value) = response.payload else {
            return .object(["tools": .array([])])
        }
        return value
    }

    // MARK: Result flattening

    /// Pull `(text, isError)` out of a JSON-RPC response. For a `tools/call`
    /// result this reads the MCP `{ content: [{type:"text",text:…}], isError }`
    /// shape; for a transport-level JSON-RPC error it reports the message.
    private static func flatten(_ response: JSONRPCResponse) -> (String, Bool) {
        switch response.payload {
        case .error(let error):
            return ("JSON-RPC error \(error.code): \(error.message)", true)
        case .result(let value):
            guard let object = value.objectValue else {
                return (pretty(value), false)
            }
            let isError = object["isError"]?.boolValue ?? false
            guard let content = object["content"]?.arrayValue else {
                return (pretty(value), isError)
            }
            let text = content.compactMap { block -> String? in
                block.objectValue?["text"]?.stringValue
            }.joined(separator: "\n")
            return (text.isEmpty ? pretty(value) : text, isError)
        }
    }

    // MARK: Pretty-printing

    /// Stable, human-readable JSON for on-screen display. Sorted keys so the
    /// same request renders identically every time (no key-order jitter).
    public static func pretty(_ value: JSONValue) -> String {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: value.foundationObject,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            return String(decoding: data, as: UTF8.self)
        } catch {
            return "(unrenderable JSON: \(error))"
        }
    }
}

// MARK: - JSONRPCRequest rendering helper

extension JSONRPCRequest {
    /// Reconstruct the on-the-wire request object for display. `JSONRPCRequest`
    /// has no encoder of its own (the stdio loop only ever decodes inbound
    /// requests), so the gateway builds the object here to show what it sent.
    var asRequestJSONValue: JSONValue {
        var object: [String: JSONValue] = [
            "jsonrpc": .string(jsonrpc),
            "method": .string(method),
        ]
        if let id { object["id"] = id }
        if let params { object["params"] = params }
        return .object(object)
    }
}

// MARK: - MootToolCalling conformance

// MootBridge conforms to MootIntentKit's MootToolCalling protocol. This is the
// seam that lets the intent kit use MootBridge without importing substrate kits
// directly.
//
// The existing `callTool(_:arguments:) -> GatewayCall` returns the full
// GatewayCall (request + response JSON + text + isError). The protocol requires
// `callTool(_:arguments:) -> IntentCallResult`. Swift does not allow two methods
// with identical signatures differing only in return type, so we implement the
// protocol requirement via `call(method:params:)` directly — the same call
// path the GatewayCall overload uses — and map to IntentCallResult.
extension MootBridge: MootToolCalling {
    /// Protocol requirement from MootToolCalling. Drives `tools/call` through
    /// the dispatcher and returns only the fields the intent layer needs.
    public func callTool(_ name: String, arguments: [String: JSONValue]) async -> IntentCallResult {
        // Build the same params object callTool(_:arguments:)->GatewayCall uses.
        let params: JSONValue = .object([
            "name": .string(name),
            "arguments": .object(arguments),
        ])
        let gatewayCall = await call(method: "tools/call", params: params)
        return IntentCallResult(text: gatewayCall.text, isError: gatewayCall.isError)
    }
}
