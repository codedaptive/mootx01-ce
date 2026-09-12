import AriaMCPWire
import Foundation
import GeniusLocusKit
import LocusKit
import OSLog

/// The ARIA_MCP stdio server.
///
/// Two halves: a method dispatcher that maps a JSON-RPC request to a
/// JSON-RPC response (or `nil` for notifications, which the JSON-RPC
/// spec forbids replying to), and a stdio read-write loop that drains
/// stdin line by line, hands each parsed message to the dispatcher,
/// and writes responses to stdout one line each. All logging is
/// routed to stderr via `Logging.stderr`. Per ARIA_MCP_SPEC_v0.2 §5,
/// stdout is reserved for JSON-RPC frames.
///
/// Transport framing follows the de-facto MCP stdio convention:
/// newline-delimited JSON. One JSON object per line, no Content-Length
/// header, no embedded newlines inside a frame (JSONSerialization
/// produces compact JSON by default). This matches what every MCP
/// host implementation (Claude Desktop, Claude Code, MemPalace's own
/// MCP server) expects on the wire.

/// A community-contract tool handler that MootCommunityDaemon injects into
/// ARIA_MCPDispatcher without creating a circular dependency.
///
/// Defined here (in AriaMCP) so conformers in MootCommunityDaemon can import
/// AriaMCP and satisfy the protocol — the dependency direction is correct.
/// MootDaemonProvider is frozen; this protocol lives in AriaMCP which
/// MootCommunityDaemon already imports for Wave A1b.
///
/// Community tools use the `moot_community_` name prefix. The dispatcher calls
/// `isCommunityTool(_:)` before falling through to the `ToolDispatcher`, so
/// community tools are served without a GeniusLocusKit actor.
public protocol CommunityToolHandler: Sendable {
    /// True when `name` is a community tool this handler owns.
    func isCommunityTool(_ name: String) -> Bool
    /// The ProjectedTool entries for tools/list.
    var communityToolList: [ProjectedTool] { get }
    /// Dispatch one community tool call. Throws JSONRPCError on failure.
    func dispatch(name: String, arguments: JSONValue) async throws -> JSONValue
}

/// Dynamic tools contributed by a product attached to the resident daemon.
/// The dispatcher consults this surface only on a successfully authenticated
/// first-party request; the ordinary HTTP lane strips it before dispatch.
public protocol FirstPartyToolHandler: Sendable {
    func isFirstPartyTool(_ name: String) async -> Bool
    var firstPartyToolList: [ProjectedTool] { get async }
    func dispatch(name: String, arguments: JSONValue) async throws -> JSONValue
}

/// A first-party handler that owns resident-process lifecycle.
public protocol FirstPartyToolHost: FirstPartyToolHandler {
    func start() async throws
    func stop() async
}

/// A daemon-owned estate session made available only to a stable first-party
/// provider's executor.  It is never a public MCP parameter or a ProductDock
/// capability.
public struct FirstPartyProviderEstateSession: Sendable {
    public let kit: GeniusLocusKit
    public let handle: EstateHandle

    public init(kit: GeniusLocusKit, handle: EstateHandle) {
        self.kit = kit
        self.handle = handle
    }
}

/// Resolves the daemon-owned estate for a stable first-party provider.  The
/// provider owns its own long-lived executor, including session and ledger
/// state; this context only supplies the current daemon session when that
/// executor needs to refresh after a close/reopen.
public protocol FirstPartyProviderExecutorContext: Sendable {
    func currentEstateSession() async throws -> FirstPartyProviderEstateSession
}

/// Fixed, daemon-installed first-party catalog. This is separate from the
/// frozen Community namespace and dynamic product handlers; an authenticated
/// route may expose all three, while the ordinary public lane exposes none.
public protocol FirstPartyProvider: Sendable {
    func isFirstPartyProviderTool(_ name: String) async -> Bool
    var firstPartyProviderToolList: [ProjectedTool] { get async }
    func dispatchFirstPartyProviderTool(
        name: String,
        arguments: JSONValue,
        context: FirstPartyProviderCallContext
    ) async throws -> JSONValue
}

public enum FirstPartyRecallExportability: Sendable, Equatable {
    /// No exportability restriction. This preserves the existing no-grant behavior.
    case any
    /// Recall may include only material explicitly marked exportable.
    case exportableOnly
}

/// The recall authority applied to one authenticated first-party call.
/// Sensitivity and exportability stay independent: exportability cannot widen
/// the sensitivity ceiling.
public struct FirstPartyRecallPolicy: Sendable, Equatable {
    public let maximumSensitivity: AdjectiveSensitivity
    public let exportability: FirstPartyRecallExportability

    public init(
        maximumSensitivity: AdjectiveSensitivity,
        exportability: FirstPartyRecallExportability
    ) {
        self.maximumSensitivity = maximumSensitivity
        self.exportability = exportability
    }

    /// Existing ordinary recall: elevated ceiling and no exportability filter.
    public static let noGrant = FirstPartyRecallPolicy(
        maximumSensitivity: .elevated,
        exportability: .any
    )

    func restricted(by other: Self) -> Self {
        Self(
            // Sensitivity grants remain the configured authority's decision.
            // The transport restriction contributes only exportability.
            maximumSensitivity: other.maximumSensitivity,
            exportability: exportability == .exportableOnly || other.exportability == .exportableOnly
                ? .exportableOnly : .any
        )
    }
}

/// Daemon-owned source for the policy attached to a verified provider call.
/// It must not read request arguments, so callers cannot select recall authority.
public protocol FirstPartyRecallPolicyAuthority: Sendable {
    func currentFirstPartyRecallPolicy(
        for caller: FirstPartyProviderCallContext
    ) async -> FirstPartyRecallPolicy
}

/// Default for compositions with no explicit first-party grant authority.
public struct FirstPartyNoGrantRecallPolicyAuthority: FirstPartyRecallPolicyAuthority {
    public init() {}

    public func currentFirstPartyRecallPolicy(
        for caller: FirstPartyProviderCallContext
    ) async -> FirstPartyRecallPolicy {
        caller.recallPolicy
    }
}

/// Verified transport facts bound to one first-party call.  `HTTPServer`
/// constructs this only after the request MAC and replay window succeed; it is
/// never decoded from caller parameters or retained as a global session.
public struct FirstPartyProviderCallContext: Sendable, Equatable {
    public let sessionIdentifier: [UInt8]
    public let sequence: UInt64
    public let instanceIdentifier: UUID
    public let estateIdentifier: UUID
    public let recallPolicy: FirstPartyRecallPolicy

    init(
        authenticated: FirstPartyAuthenticatedRequest,
        identity: FirstPartyServerIdentity,
        recallPolicy: FirstPartyRecallPolicy = .noGrant
    ) {
        self.sessionIdentifier = authenticated.sessionIdentifier
        self.sequence = authenticated.sequence
        self.instanceIdentifier = identity.instanceIdentifier
        self.estateIdentifier = identity.estateIdentifier
        self.recallPolicy = authenticated.restrictsRecallToExportable
            ? FirstPartyRecallPolicy(
                maximumSensitivity: .elevated,
                exportability: .exportableOnly
            )
            : recallPolicy
    }

    func withRecallPolicy(_ recallPolicy: FirstPartyRecallPolicy) -> Self {
        Self(
            sessionIdentifier: sessionIdentifier,
            sequence: sequence,
            instanceIdentifier: instanceIdentifier,
            estateIdentifier: estateIdentifier,
            recallPolicy: recallPolicy
        )
    }

    private init(
        sessionIdentifier: [UInt8],
        sequence: UInt64,
        instanceIdentifier: UUID,
        estateIdentifier: UUID,
        recallPolicy: FirstPartyRecallPolicy
    ) {
        self.sessionIdentifier = sessionIdentifier
        self.sequence = sequence
        self.instanceIdentifier = instanceIdentifier
        self.estateIdentifier = estateIdentifier
        self.recallPolicy = recallPolicy
    }
}

/// Optional provider capability for a future estate-backed executor.  The
/// concrete provider owns the executor and its durable session/ledger state;
/// Community injects only a resolver for its daemon-owned current estate.
public protocol FirstPartyProviderExecutorContextConsumer: FirstPartyProvider {
    func installFirstPartyProviderExecutorContext(
        _ context: any FirstPartyProviderExecutorContext
    ) async
}

/// The method router. Owns the tool registry and the estate
/// dispatcher, calls each on the right inbound method, and converts
/// thrown JSON-RPC errors into response payloads.
public struct ARIA_MCPDispatcher: Sendable {

    /// Server identity surfaced in the `initialize` response. The
    /// MCP spec lets clients display this so users can tell which
    /// server they connected to.
    public struct ServerInfo: Sendable {
        public let name: String
        public let version: String

        public init(name: String, version: String) {
            self.name = name
            self.version = version
        }
    }

    // MARK: - Protocol-version negotiation

    /// The complete set of MCP protocol versions this server implements.
    ///
    /// Ordered most-recent first. The first entry is returned to any client
    /// that requests an unsupported or absent version.
    ///
    /// Sources:
    /// - "2025-11-25": Claude Desktop's current protocol version; backward-
    ///   compatible wire shape with "2025-03-26". The server responds with
    ///   the same capabilities shape for all three revisions.
    /// - "2025-03-26": the MCP stable revision following 2024-11-05; adds
    ///   elicitation + audio content type; our capabilities shape is unchanged.
    /// - "2024-11-05": the initial stable MCP revision implemented by the
    ///   ARIA_MCP surface (tools, resources, prompts, logging).
    ///
    /// Per the MCP specification §3 (Initialization):
    ///   "If the server does not support the client's requested version, it
    ///    SHOULD respond with its latest supported version. The client MUST
    ///    then decide whether to proceed or abort."
    ///
    /// This means initialize always succeeds at the JSON-RPC level; the
    /// version in the response may differ from the one the client sent. The
    /// client is responsible for deciding whether the returned version is
    /// acceptable. A silent echo of an unsupported version — the previous
    /// v1.0-stub behavior — was wrong because it let clients believe they
    /// had negotiated a contract the server did not honour.
    public static let supportedProtocolVersions: [String] = [
        "2025-11-25",
        "2025-03-26",
        "2024-11-05",
    ]

    /// The version returned to a client that requests an unsupported version.
    /// Always the first element of `supportedProtocolVersions` (the latest).
    public static var latestSupportedProtocolVersion: String {
        supportedProtocolVersions[0]
    }

    public let info: ServerInfo
    /// The effective tool list for tools/list.
    ///
    /// In the full (GLK-backed) dispatcher this is `ToolProjection.tools()`. In
    /// community-only mode it is `communityHandler.communityToolList`. On the HTTP
    /// plain lane (returned by `publicLane`) community tools are stripped so they
    /// do not appear in the third-party client's tool list — `publicLane` filters
    /// this array when it nils out the community handler.
    ///
    /// `private(set)` so `publicLane` can adjust the list without exposing a
    /// general mutation surface. Callers read the list; they never write it.
    public private(set) var tools: [ProjectedTool]
    /// The GeniusLocusKit-backed dispatcher. Optional to support community-only mode
    /// (Wave A1b) where only `moot_community_*` tools are served and no GeniusLocusKit
    /// actor is available. When nil, non-community tool calls return methodNotFound.
    public let tooling: ToolDispatcher?
    /// Community-contract tool handler, or nil.
    ///
    /// When set, community tools are routed here BEFORE falling through to `tooling`.
    /// Defined as an existential so MootCommunityDaemon can inject its conformer
    /// without a circular dependency.
    ///
    /// On the HTTP plain (third-party) lane this is nil — `publicLane` strips it so
    /// the plain lane behaves as if no community handler exists. Direct dispatcher
    /// callers (unit tests, community-only mode via `(info:communityHandler:)`) are
    /// unaffected; they never call `publicLane`.
    ///
    /// `private(set)` so `publicLane` can nil it without exposing a general mutation
    /// surface. Callers read the handler; they never write it.
    public private(set) var communityHandler: (any CommunityToolHandler)?

    /// Dynamic product-tool surface. Nil on the ordinary HTTP lane.
    public private(set) var firstPartyHandler: (any FirstPartyToolHandler)?

    /// Fixed provider surface for authenticated native callers. It is separate
    /// from the selected public catalog and is stripped from the HTTP public
    /// lane with the verified caller context.
    public private(set) var firstPartyProvider: (any FirstPartyProvider)?

    /// The authenticated first-party identity this dispatcher reports, or `nil`
    /// on the ordinary third-party lane.
    ///
    /// **This is NOT a configuration knob and must never be set by a caller.**
    /// It is `internal(set)` and is populated in exactly one place —
    /// `HTTPServer.routeFirstParty`, from the live `FirstPartyAuthServer`'s own
    /// identity, for the duration of one authenticated dispatch.
    ///
    /// It was previously a public initializer parameter, which was a defect:
    /// the identity and the authenticator were two independent knobs that had to
    /// agree, and `HTTPServer` handed the SAME dispatcher to both lanes. Setting
    /// the identity therefore made the UNAUTHENTICATED public lane advertise
    /// `authenticated-first-party` and publish the daemon's instance and estate
    /// identifiers; leaving it unset made the authenticated lane fail to report
    /// them. Deriving it from the authenticator removes the second knob, so the
    /// two can no longer diverge.
    public internal(set) var firstPartyIdentity: FirstPartyServerIdentity?

    /// Verified per-request facts. This is populated only by the authenticated
    /// HTTP router and is never decoded from a tool argument.
    private var firstPartyProviderCallContext: FirstPartyProviderCallContext?

    /// Daemon authority resolved after transport verification, before a stable
    /// provider call. It cannot be selected by an MCP client.
    private let firstPartyRecallPolicyAuthority: any FirstPartyRecallPolicyAuthority

    /// Full-mode initializer: GeniusLocusKit-backed dispatcher, no community handler.
    /// This is the existing production path; the `tooling` parameter is non-optional
    /// here to preserve every existing call site unchanged.
    public init(
        info: ServerInfo,
        tooling: ToolDispatcher,
        firstPartyRecallPolicyAuthority: any FirstPartyRecallPolicyAuthority = FirstPartyNoGrantRecallPolicyAuthority()
    ) {
        self.info = info
        self.tools = ToolProjection.tools()
        self.tooling = tooling
        self.communityHandler = nil
        self.firstPartyHandler = nil
        self.firstPartyProvider = nil
        self.firstPartyIdentity = nil
        self.firstPartyProviderCallContext = nil
        self.firstPartyRecallPolicyAuthority = firstPartyRecallPolicyAuthority
    }

    /// Community-only initializer (Wave A1b): no GeniusLocusKit actor required.
    /// Community tools become reachable only when the first-party HTTP router
    /// attaches a verified request. A direct instance still advertises no tools.
    public init(
        info: ServerInfo,
        communityHandler: any CommunityToolHandler,
        firstPartyHandler: (any FirstPartyToolHandler)? = nil,
        firstPartyProvider: (any FirstPartyProvider)? = nil,
        firstPartyRecallPolicyAuthority: any FirstPartyRecallPolicyAuthority = FirstPartyNoGrantRecallPolicyAuthority()
    ) {
        self.info = info
        self.tools = []
        self.tooling = nil
        self.communityHandler = communityHandler
        self.firstPartyHandler = firstPartyHandler
        self.firstPartyProvider = firstPartyProvider
        self.firstPartyIdentity = nil
        self.firstPartyProviderCallContext = nil
        self.firstPartyRecallPolicyAuthority = firstPartyRecallPolicyAuthority
    }

    /// This dispatcher, carrying a first-party identity, for one authenticated
    /// dispatch.
    ///
    /// `internal` on purpose: only the first-party router may call it, and only
    /// with an identity taken from the `FirstPartyAuthServer` that just
    /// authenticated the request. Value copy preserves `communityHandler`.
    func withFirstPartyIdentity(_ identity: FirstPartyServerIdentity) -> ARIA_MCPDispatcher {
        var copy = self
        copy.firstPartyIdentity = identity
        copy.firstPartyProviderCallContext = nil
        return copy
    }

    /// Attach facts that were verified by the first-party HTTP router. This is
    /// internal so product composition cannot manufacture a trusted caller.
    func withVerifiedFirstPartyRequest(
        _ authenticated: FirstPartyAuthenticatedRequest,
        identity: FirstPartyServerIdentity
    ) -> ARIA_MCPDispatcher {
        var copy = self
        copy.firstPartyIdentity = identity
        copy.firstPartyProviderCallContext = FirstPartyProviderCallContext(
            authenticated: authenticated,
            identity: identity
        )
        return copy
    }

    /// This dispatcher as the HTTP plain (third-party) lane sees it.
    ///
    /// Two changes from `self`:
    ///   1. `firstPartyIdentity` is stripped unconditionally so the public lane
    ///      cannot advertise `authenticated-first-party` or leak the daemon's
    ///      instance and estate identifiers even if `self` carries an identity.
    ///   2. `communityHandler` is set to nil and community tools are removed from
    ///      `tools` (F1 fix). Community tools are an authenticated-first-party-only
    ///      surface; a plain-lane client that reads tools/list must never see them,
    ///      and a plain-lane tools/call for a community tool name must receive
    ///      methodNotFound. Stripping the handler here — rather than gating inside
    ///      toolsCall() — keeps dispatch logic simple: nil communityHandler means
    ///      "no community surface", regardless of which lane is active.
    ///
    /// A direct community-only dispatcher also has no protected surface until
    /// the internal first-party router attaches a verified request. `publicLane`
    /// is called only from `HTTPServer.route()` for the plain HTTP lane.
    ///
    /// Cheap: `ARIA_MCPDispatcher` is a value type; the copy is stack-allocated.
    var publicLane: ARIA_MCPDispatcher {
        var copy = self
        copy.firstPartyIdentity = nil
        copy.firstPartyProviderCallContext = nil
        // Strip community tools from the plain lane (F1).  The tools array is
        // filtered rather than set to empty so non-community GLK tools remain
        // visible on the plain lane. In community-only mode (tooling == nil) all
        // tools have the "moot_community_" prefix, so this produces an empty list
        // — correct: no tools are advertised to unauthenticated third-party clients.
        if copy.communityHandler != nil {
            copy.communityHandler = nil
            copy.tools = copy.tools.filter { !$0.name.hasPrefix("moot_community_") }
        }
        copy.firstPartyHandler = nil
        copy.firstPartyProvider = nil
        return copy
    }

    /// Handle one parsed inbound request. Returns the response or `nil`
    /// if the request is a notification (in which case the server must
    /// stay silent on the wire per JSON-RPC 2.0).
    public func handle(_ request: JSONRPCRequest) async -> JSONRPCResponse? {
        // For notifications, we run the side-effect (none today) and
        // swallow any reply. The JSON-RPC spec is explicit: a server
        // MUST NOT reply to a notification.
        if request.isNotification {
            await handleNotification(request)
            return nil
        }
        // From here on, every request must produce a response. If the
        // id is missing despite the request not being a notification,
        // the request was malformed — answer with invalidRequest using
        // a null id, as the spec instructs.
        let id = request.id ?? .null
        do {
            let result = try await route(request)
            return .ok(id, result)
        } catch let error as JSONRPCError {
            return .failure(id, error)
        } catch {
            return .failure(
                id,
                JSONRPCError(
                    code: JSONRPCErrorCode.internalError,
                    message: "Internal error: \(error)"
                )
            )
        }
    }

    /// Route one already-validated request to the method handler. The
    /// caller has confirmed `request.id` is present, so this method
    /// only needs to know about the method name and params.
    private func route(_ request: JSONRPCRequest) async throws -> JSONValue {
        // Local-owner credential seam (ARIA_MCP_SPEC_v0.2 §8). Present-but-trivial
        // in v1.0: the connection is a process the machine owner launched against
        // a configured instance; allow-all. The seam is the chokepoint: v1.1 drops
        // in token/OAuth validation here without changing anything else.
        try checkCredentials(request: request)
        switch request.method {
        case "initialize":
            return try initialize(params: request.params)
        case "ping":
            // MCP's ping has empty params and an empty-object result.
            // The keep-alive shape is fixed by the spec.
            return .object([:])
        case "tools/list":
            return await toolsList()
        case "tools/call":
            return try await toolsCall(params: request.params)
        case "resources/list":
            // Resources are advertised in v1.0 capabilities; the list is empty
            // until v1.1 implements subscriptions and resource surfacing.
            return .object(["resources": .array([])])
        case "prompts/list":
            // Prompts are advertised in v1.0 capabilities; the list is empty
            // until v1.1 implements recipe-prompt surfacing.
            return .object(["prompts": .array([])])
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.methodNotFound,
                message: "Method not found: \(request.method)"
            )
        }
    }

    /// Notifications carry one-way information from the client
    /// (initialized, cancellations). The server logs every notification
    /// to stderr and sends no JSON-RPC reply — per spec, notifications
    /// never receive a response.
    private func handleNotification(_ request: JSONRPCRequest) async {
        Logging.stderr.log("notification: \(request.method)")
    }

    // MARK: - initialize

    private func initialize(params: JSONValue?) throws -> JSONValue {
        // MCP spec §3 (Initialization) — explicit protocol-version negotiation.
        //
        // Rule: if the client requests a version this server supports, echo it
        // back exactly. If the client requests an unsupported version, respond
        // with the server's latest supported version; the client then decides
        // whether to proceed or abort.
        //
        // This replaces the previous v1.0-stub that echoed any version
        // unconditionally, which silently claimed support for contracts the
        // server did not implement.
        //
        // If the client omits protocolVersion entirely (non-conforming client),
        // we default to the latest supported version so the handshake still
        // completes — the client will see a clear version in the response and
        // can reject if needed.
        let requested = params?.objectValue?["protocolVersion"]?.stringValue
        let negotiated: String
        if let v = requested, Self.supportedProtocolVersions.contains(v) {
            // Client requested a version we implement — echo it exactly.
            negotiated = v
        } else {
            // Client requested an unknown/unsupported version, or omitted the
            // field. Respond with our latest per the MCP spec §3 mandate.
            negotiated = Self.latestSupportedProtocolVersion
        }
        // First-party lane only: the identity the client will compare against
        // the descriptor it already verified. Every value is drawn from that
        // same verified descriptor, so a truthful serverInfo and a verified
        // descriptor cannot disagree — if they could, the client would have no
        // way to tell which was lying.
        //
        // On the third-party lane `firstPartyIdentity` is nil, no extra key is
        // emitted, and the response bytes are exactly what they were before this
        // capability existed.
        var serverInfoFields: [String: JSONValue] = [
            "name": .string(info.name),
            "version": .string(info.version),
        ]
        var capabilityFields: [String: JSONValue] = [:]
        if let identity = firstPartyIdentity {
            serverInfoFields["name"] = .string(identity.name)
            serverInfoFields["version"] = .string(identity.binaryVersion)
            serverInfoFields["instanceIdentifier"] = .string(identity.instanceIdentifier.uuidString)
            serverInfoFields["estateIdentifier"] = .string(identity.estateIdentifier.uuidString)
            // Generations are UInt64 and are emitted as DECIMAL STRINGS.
            //
            // `Int64(someUInt64)` traps above `Int64.max`, and those are legal
            // generation values — a monotonic counter has no business being
            // capped by the signed range of a JSON encoder. JSON numbers cannot
            // carry them either: `.integer` is `Int64`, and even a double-typed
            // JSON number loses exactness above 2^53, so any numeric encoding is
            // lossy or trapping at the top of the range. A decimal string is
            // exact for every `UInt64` and never traps.
            serverInfoFields["descriptorGeneration"] = .string(String(identity.descriptorGeneration))
            serverInfoFields["credentialGeneration"] = .string(String(identity.credentialGeneration))
            // `contractRevision` is an `Int` and small by contract, so it stays
            // a JSON number; `Int64(_:)` from `Int` is total on 64-bit.
            serverInfoFields["contractRevision"] = .integer(Int64(identity.contractRevision))
            serverInfoFields["mcpProtocolVersion"] = .string(identity.mcpProtocolVersion)
            // Advertised only here, and only because reaching this branch means
            // a validated root, an active descriptor, a bounded session store,
            // and the request/response MAC middleware are all present — the
            // `FirstPartyAuthServer` that supplied this identity is what proves
            // each of them exists.
            capabilityFields["authenticated-first-party"] = .object([:])
            if firstPartyProvider != nil {
                // This discovery record describes the fixed native-provider
                // contract. It is deliberately independent of the public v2
                // selected-release registry.
                serverInfoFields["first_party_provider"] = FirstPartyProviderCatalog.discovery.jsonValue
            }
        }

        let result: JSONValue = .object([
            "protocolVersion": .string(negotiated),
            "capabilities": .object(capabilityFields.merging([
                "tools": .object([:]),
                // Resources and prompts are advertised (v1.0 conformance per
                // ARIA_MCP_SPEC_v0.2 §9). Lists are empty until v1.1 implements
                // subscriptions and recipe-prompt surfacing. Advertising now
                // signals capability to clients so they light up those surfaces
                // when content arrives, and degrade cleanly to tools-only today.
                "resources": .object([
                    "subscribe": .bool(false),
                    "listChanged": .bool(false),
                ]),
                "prompts": .object(["listChanged": .bool(false)]),
                // Logging is advertised; the server logs to stderr per §5.
                "logging": .object([:]),
            ]) { current, _ in current }),
            "serverInfo": .object(serverInfoFields),
        ])
        return result
    }

    // MARK: - tools/list

    private func toolsList() async -> JSONValue {
        // The authenticated HTTP lane composes two independent namespaces.
        // The stable provider remains its fixed 26-operation agreement and the
        // Community contract remains its frozen 35-operation agreement; neither
        // falls through to the public selected-v2 dispatcher. Requiring the
        // verified request context keeps an identity-only value copy from
        // advertising either protected namespace.
        if firstPartyIdentity != nil, firstPartyProviderCallContext != nil {
            var authenticatedTools: [ProjectedTool] = []
            if let firstPartyProvider {
                authenticatedTools.append(contentsOf: await firstPartyProvider.firstPartyProviderToolList)
            }
            if let communityHandler {
                authenticatedTools.append(contentsOf: communityHandler.communityToolList)
            }
            return toolsListEntries(authenticatedTools)
        }
        // The public selected release remains the complete public v2 surface.
        // Community and provider additions are not wired into selected v2 lanes.
        return toolsListEntries(tools)
    }

    private func toolsListEntries(_ effectiveTools: [ProjectedTool]) -> JSONValue {
        let entries: [JSONValue] = effectiveTools.map { tool in
            var entry: [String: JSONValue] = [
                "name": .string(tool.name),
                "description": .string(tool.description),
                "inputSchema": tool.inputSchema,
            ]
            // MCP structured results: only tools that declare a schema get
            // the key — text-only tool entries stay byte-identical.
            if let outputSchema = tool.outputSchema {
                entry["outputSchema"] = outputSchema
            }
            if let annotations = tool.annotations {
                entry["annotations"] = annotations
            }
            return .object(entry)
        }
        return .object(["tools": .array(entries)])
    }

    // MARK: - tools/call

    private func toolsCall(params: JSONValue?) async throws -> JSONValue {
        guard let object = params?.objectValue,
              let name = object["name"]?.stringValue else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "tools/call requires a 'name' parameter"
            )
        }
        // Schema version gate (ARIA_MCP_SPEC_v0.2 §8). Optional field: if present
        // and mismatched, reject with a typed error. If absent, pass through
        // (backward compatibility — clients that don't send schema_version work
        // unchanged). The gate is the single chokepoint: real version enforcement
        // drops in here in v1.1 without rework.
        if let schemaVersion = object["schema_version"]?.stringValue {
            guard Self.isSchemaVersionAccepted(schemaVersion) else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "schema_version '\(schemaVersion)' not accepted by this server"
                )
            }
        }
        let arguments = object["arguments"] ?? .object([:])
        if firstPartyIdentity != nil {
            guard let verifiedContext = firstPartyProviderCallContext else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.methodNotFound,
                    message: "Method not found: \(name)"
                )
            }

            // Community is a separate authenticated namespace. Its frozen
            // transport grammar does not carry the stable provider tuple.
            if let communityHandler, communityHandler.isCommunityTool(name) {
                return try await communityHandler.dispatch(name: name, arguments: arguments)
            }

            if let firstPartyProvider, await firstPartyProvider.isFirstPartyProviderTool(name) {
                let contractVersion = try Self.validateFirstPartyProviderCompatibility(object)
                if contractVersion == FirstPartyProviderCatalog.legacyContractVersion {
                    guard let stableArguments = arguments.objectValue else {
                        throw JSONRPCError(
                            code: JSONRPCErrorCode.invalidParams,
                            message: "tools/call arguments must be an object"
                        )
                    }
                    try FirstPartyProviderCatalog.validateArguments(
                        name: name,
                        arguments: stableArguments,
                        contractVersion: contractVersion
                    )
                }
                let authorityPolicy = await firstPartyRecallPolicyAuthority
                    .currentFirstPartyRecallPolicy(for: verifiedContext)
                let context = verifiedContext.withRecallPolicy(
                    verifiedContext.recallPolicy.restricted(by: authorityPolicy)
                )
                return try await firstPartyProvider.dispatchFirstPartyProviderTool(
                    name: name,
                    arguments: arguments,
                    context: context
                )
            }

            // An authenticated name never falls through to a public selected
            // operation. The namespaces are disjoint and unknown names deny.
            throw JSONRPCError(
                code: JSONRPCErrorCode.methodNotFound,
                message: "Method not found: \(name)"
            )
        }
        guard let tooling else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.methodNotFound,
                message: "Method not found: \(name)"
            )
        }
        return try await tooling.dispatch(name: name, arguments: arguments)
    }

    // MARK: - Credential seam

    /// Local-owner credential check (ARIA_MCP_SPEC_v0.2 §8). Allow-all in v1.0:
    /// the connection is a process the machine owner launched; no credential
    /// is needed. The seam is the chokepoint — v1.1 drops in token or OAuth
    /// validation here without changing the call site in route().
    private func checkCredentials(request: JSONRPCRequest) throws {
        // v1.0: allow all. v1.1 expansion point.
    }

    // MARK: - Schema version helpers

    /// Returns true if `version` conforms to the `geniuslocus.<verb>.<major>`
    /// format the ARIA_MCP spec defines (ARIA_MCP_SPEC_v0.2 §8).
    ///
    /// The tool-schema version space is separate from the MCP protocol version
    /// space. This validator checks format only: three dot-separated components
    /// where the first must be "geniuslocus". A specific version table will gate
    /// individual tool schema revisions when the spec's version catalog is
    /// finalized; until then, any correctly-formatted string passes.
    static func isSchemaVersionAccepted(_ version: String) -> Bool {
        // Format: geniuslocus.<verb>.<major> — three dot-separated components
        // where the first must be "geniuslocus".
        let parts = version.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "geniuslocus" else { return false }
        return true
    }

    /// Stable provider calls pin the exact discovery tuple observed during
    /// authenticated initialization. A mismatch is rejected before it reaches
    /// executor state or an estate mutation.
    private static func validateFirstPartyProviderCompatibility(_ params: [String: JSONValue]) throws -> String {
        guard let compatibility = params["first_party_provider"]?.objectValue,
              let version = FirstPartyProviderCatalog.admittedContractVersion(compatibility) else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "stable FirstPartyProvider calls require a matching first_party_provider compatibility record"
            )
        }
        return version
    }
}

/// The stdio loop. Hands each parsed inbound frame to the dispatcher
/// and writes each outbound frame to stdout terminated by a single
/// newline.
public struct StdioServer {

    public let dispatcher: ARIA_MCPDispatcher

    public init(dispatcher: ARIA_MCPDispatcher) {
        self.dispatcher = dispatcher
    }

    /// Run the loop until stdin is closed. Reads bytes from stdin,
    /// splits on newline, parses each line as JSON, dispatches, and
    /// writes responses to stdout. Malformed lines emit a parseError
    /// response with a null id; that lets a client recover by sending
    /// the next well-formed request without restarting the server.
    ///
    /// Frame size cap (CAND-051 hardening): if the in-memory buffer grows
    /// beyond `maxFrameBytes` without a newline the peer is writing a
    /// frame that has no valid end; the loop breaks and stdin is abandoned.
    /// Default cap is 4 MiB — large enough for any legitimate MCP payload
    /// (the largest tool argument body accepted by HTTP is also 4 MiB).
    public func run(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        maxFrameBytes: Int = 4 * 1024 * 1024
    ) async {
        // Read in chunks rather than line-by-line through Foundation's
        // streamed-strings convenience because FileHandle's reader is
        // the most reliable cross-platform path that does not depend
        // on a Sendable async sequence over stdin.
        var buffer = Data()
        while true {
            // availableData returns as soon as bytes are present at the
            // pipe (when the client sends a line), rather than blocking
            // to fill a fixed-size buffer. read(upToCount:) stalled the
            // initialize handshake on a persistent stdio connection (the
            // client holds stdin open and waits for the reply), tripping
            // the MCP client's 30s connection timeout. availableData
            // returns empty Data on EOF, which ends the loop cleanly.
            let chunk = input.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let frame = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                if frame.isEmpty { continue }
                await handleFrame(frame, output: output)
            }
            // Frame size cap: if no newline arrived and the buffer already
            // exceeds the cap, the peer is either misbehaving or writing a
            // frame too large for any legitimate MCP use case. Break the
            // loop — attempting to serve further frames from a runaway peer
            // would exhaust process memory (local DoS). The peer will see
            // stdin close and can reconnect.
            if buffer.count > maxFrameBytes {
                Logging.stderr.log("aria-mcp stdio: frame size cap exceeded (\(buffer.count) > \(maxFrameBytes)), closing input")
                break
            }
        }
    }

    /// Parse one frame, dispatch, write the response (if any).
    public func handleFrame(
        _ frame: Data,
        output: FileHandle
    ) async {
        let parsed: JSONValue
        do {
            parsed = try JSONValue.parse(frame)
        } catch {
            // Parse failures land here; the spec says the server
            // should reply with a parseError carrying a null id, since
            // the request was unreadable.
            let response = JSONRPCResponse.failure(
                .null,
                JSONRPCError(
                    code: JSONRPCErrorCode.parseError,
                    message: "Parse error: \(error)"
                )
            )
            write(response, to: output)
            return
        }
        guard let request = JSONRPCRequest.decode(parsed) else {
            let response = JSONRPCResponse.failure(
                .null,
                JSONRPCError(
                    code: JSONRPCErrorCode.invalidRequest,
                    message: "Invalid Request: malformed JSON-RPC envelope"
                )
            )
            write(response, to: output)
            return
        }
        guard let response = await dispatcher.handle(request) else {
            return
        }
        write(response, to: output)
    }

    /// Serialize a response and write it to `output` terminated by a
    /// single newline. Errors during serialization are logged to
    /// stderr; we cannot recover them onto the wire because we no
    /// longer have a valid response to send.
    public func write(_ response: JSONRPCResponse, to output: FileHandle) {
        do {
            var data = try response.asJSONValue.encoded()
            data.append(0x0A)
            try output.write(contentsOf: data)
        } catch {
            Logging.stderr.log("stdout write failed: \(error)")
        }
    }
}
