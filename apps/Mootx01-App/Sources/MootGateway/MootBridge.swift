import Foundation
import AriaMCP
import ConvergenceKit
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
    /// The `structuredContent` block of a `tools/call` result, verbatim, when
    /// the tool emitted one (the recall family does; most tools do not).
    /// Typed consumers (DrawerEntity construction) read THIS, never `text`.
    public let structured: JSONValue?
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

    /// The estate's live Storage — the SAME instance the ARIA verbs read and
    /// write through. Retained so ConvergenceKit's SyncEngine can observe the
    /// exact rows the estate mutates (opening a second SQLiteStorage on the
    /// same file would give a distinct observer that never sees those writes).
    private let storage: any Storage

    /// The open GeniusLocusKit coordinator for this estate.
    ///
    /// Retained here (alongside the ToolDispatcher that also holds it) so that
    /// `registerSyncEngine(_:backendName:)` can forward to
    /// `GeniusLocusKit.registerSyncEngine(_:backendName:for:)` for
    /// `moot_estate_status sync:` reporting. Without this handle, MootBridge
    /// callers would need direct GeniusLocusKit access, breaking the abstraction.
    private let kit: GeniusLocusKit

    /// The estate handle for this bridge's open estate.
    ///
    /// Stored so `registerSyncEngine` can forward to the correct per-handle slot
    /// in GeniusLocusKit's registry without the caller knowing the estate UUID.
    private let handle: EstateHandle

    private init(
        dispatcher: ARIA_MCPDispatcher,
        storage: any Storage,
        kit: GeniusLocusKit,
        handle: EstateHandle,
        serverName: String,
        databasePath: String?
    ) {
        self.dispatcher = dispatcher
        self.storage = storage
        self.kit = kit
        self.handle = handle
        self.serverName = serverName
        self.databasePath = databasePath
    }

    /// The estate's live Storage, for wiring a ConvergenceKit SyncEngine
    /// (`engine.enable(manifest:storage:)`). Same instance the verbs use.
    public func estateStorage() -> any Storage { storage }

    /// Register a sync engine with GeniusLocusKit for `moot_estate_status sync:` reporting.
    ///
    /// Forwards to `GeniusLocusKit.registerSyncEngine(_:backendName:for:)` using this
    /// bridge's open estate handle. Must be called AFTER `engine.enable()` so the engine
    /// carries a valid state. SyncController.enable() calls this automatically — callers
    /// do not call it directly.
    ///
    /// - Parameters:
    ///   - engine: The same engine passed to `engine.enable()`.
    ///   - backendName: Human-readable label: "cloudkit", "none", or "federation".
    public func registerSyncEngine(_ engine: some SyncEngine, backendName: String) async throws {
        try await kit.registerSyncEngine(engine, backendName: backendName, for: handle)
    }

    // MARK: Attachment

    // MARK: - Bridge components container

    /// Components produced by the three-step wiring (schema → coordinator → dispatcher).
    ///
    /// Returned as a named struct so both `attachInMemory` and `attachSQLite` can
    /// extract `kit` and `handle` without duplicating the wiring logic. Both are
    /// stored in the resulting MootBridge for `registerSyncEngine` support.
    private struct BridgeComponents {
        let dispatcher: ARIA_MCPDispatcher
        let kit: GeniusLocusKit
        let handle: EstateHandle
    }

    /// The three-step wiring (schema → coordinator → dispatcher) over an
    /// already-constructed storage backend. Mirrors `MootSidecar.attach`.
    ///
    /// Returns `BridgeComponents` so the caller can store `kit` and `handle`
    /// for status-reporting operations (e.g. `registerSyncEngine`).
    private static func makeComponents(
        storage: any Storage,
        owner: OwnerCredentials,
        serverName: String
    ) async throws -> BridgeComponents {
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
        let dispatcher = ARIA_MCPDispatcher(info: info, tooling: tooling)
        return BridgeComponents(dispatcher: dispatcher, kit: kit, handle: handle)
    }

    /// Attach an ephemeral in-memory MOOT. Test-only callers select this
    /// explicitly; production App Intents always resolve the durable estate.
    public static func attachInMemory(serverName: String = "Gateway") async throws -> MootBridge {
        let owner = OwnerCredentials(ownerIdentifier: "gateway-owner")
        let configuration = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: configuration)
        let components = try await makeComponents(storage: storage, owner: owner, serverName: serverName)
        return MootBridge(
            dispatcher: components.dispatcher,
            storage: storage,
            kit: components.kit,
            handle: components.handle,
            serverName: serverName,
            databasePath: nil
        )
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
        #if os(iOS)
        // iOS has no managed subprocess peer. Using the app's default access
        // group keeps the encrypted estate available to cold App Intents
        // without requiring a nonexistent shared-keychain entitlement.
        let keychainAccessGroup: String? = nil
        #else
        let keychainAccessGroup: String? = "com.codedaptive.mootx01.shared"
        #endif
        let key = try KeychainKeyStore(
            service: "com.codedaptive.mootx01",
            estateURL: url,
            accessGroup: keychainAccessGroup
        ).loadOrCreateKey()
        let configuration = EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url, busyTimeout: 5.0),
            encryptionConfig: .fullDatabase(key: key)
        )
        let storage = try SQLiteStorage(configuration: configuration)
        let components = try await makeComponents(storage: storage, owner: owner, serverName: serverName)
        return MootBridge(
            dispatcher: components.dispatcher,
            storage: storage,
            kit: components.kit,
            handle: components.handle,
            serverName: serverName,
            databasePath: url.path
        )
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
                structured: nil,
                isError: true
            )
        }

        let responseJSON = Self.pretty(response.asJSONValue)
        let (text, structured, isError) = Self.flatten(response)
        return GatewayCall(
            requestJSON: requestJSON,
            responseJSON: responseJSON,
            text: text,
            structured: structured,
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

    /// Pull `(text, structuredContent, isError)` out of a JSON-RPC response.
    /// For a `tools/call` result this reads the MCP
    /// `{ content: [{type:"text",text:…}], structuredContent?, isError }`
    /// shape; for a transport-level JSON-RPC error it reports the message.
    private static func flatten(_ response: JSONRPCResponse) -> (String, JSONValue?, Bool) {
        switch response.payload {
        case .error(let error):
            return ("JSON-RPC error \(error.code): \(error.message)", nil, true)
        case .result(let value):
            guard let object = value.objectValue else {
                return (pretty(value), nil, false)
            }
            let isError = object["isError"]?.boolValue ?? false
            // structuredContent rides beside the text block on tools that
            // declare an outputSchema (the recall family). Absent elsewhere.
            // Refusals yield NO structured data at the seam (Perkins MXE-DG
            // A1): consumers must never decode entities from an error
            // result, and enforcing that here makes it a structural
            // guarantee instead of a per-consumer discipline.
            let structured = isError ? nil : object["structuredContent"]
            guard let content = object["content"]?.arrayValue else {
                return (pretty(value), structured, isError)
            }
            let text = content.compactMap { block -> String? in
                block.objectValue?["text"]?.stringValue
            }.joined(separator: "\n")
            return (text.isEmpty ? pretty(value) : text, structured, isError)
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
        return IntentCallResult(
            text: gatewayCall.text,
            structured: gatewayCall.structured,
            isError: gatewayCall.isError
        )
    }
}
