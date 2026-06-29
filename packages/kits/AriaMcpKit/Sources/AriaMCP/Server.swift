import Foundation
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
    public let tools: [ProjectedTool]
    public let tooling: ToolDispatcher

    public init(info: ServerInfo, tooling: ToolDispatcher) {
        self.info = info
        self.tools = ToolProjection.tools()
        self.tooling = tooling
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
            return toolsList()
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
        let result: JSONValue = .object([
            "protocolVersion": .string(negotiated),
            "capabilities": .object([
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
            ]),
            "serverInfo": .object([
                "name": .string(info.name),
                "version": .string(info.version),
            ]),
        ])
        return result
    }

    // MARK: - tools/list

    private func toolsList() -> JSONValue {
        let entries: [JSONValue] = tools.map { tool in
            .object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "inputSchema": tool.inputSchema,
            ])
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
