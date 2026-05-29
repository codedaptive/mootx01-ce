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
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.methodNotFound,
                message: "Method not found: \(request.method)"
            )
        }
    }

    /// Notifications carry one-way information from the client
    /// (initialized, cancellations). Today we accept any notification
    /// and do nothing — the server has no async client work to cancel
    /// and the initialized handshake is purely informational on the
    /// MemPalace pattern.
    private func handleNotification(_ request: JSONRPCRequest) async {
        Logging.stderr.log("notification: \(request.method)")
    }

    // MARK: - initialize

    private func initialize(params: JSONValue?) throws -> JSONValue {
        // MCP's initialize echoes the client's protocol version and
        // advertises server capabilities. The spec encourages clients
        // to fall back to a version they support; we name the version
        // our wire shape conforms to and let the client adapt.
        let protocolVersion = params?.objectValue?["protocolVersion"]?.stringValue
            ?? "2024-11-05"
        let result: JSONValue = .object([
            "protocolVersion": .string(protocolVersion),
            "capabilities": .object([
                // tools/list and tools/call are the only primitives
                // this server implements per § 9 v1.0 of the spec.
                // Resources, prompts, sampling, elicitation, and
                // tasks are v1.1+ and are not advertised here.
                "tools": .object([:]),
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
        let arguments = object["arguments"] ?? .object([:])
        return try await tooling.dispatch(name: name, arguments: arguments)
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
    public func run(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) async {
        // Read in chunks rather than line-by-line through Foundation's
        // streamed-strings convenience because FileHandle's reader is
        // the most reliable cross-platform path that does not depend
        // on a Sendable async sequence over stdin.
        var buffer = Data()
        while true {
            let chunk: Data
            do {
                guard let next = try input.read(upToCount: 4096), !next.isEmpty else {
                    break
                }
                chunk = next
            } catch {
                Logging.stderr.log("stdin read failed: \(error)")
                break
            }
            buffer.append(chunk)
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let frame = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                if frame.isEmpty { continue }
                await handleFrame(frame, output: output)
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
