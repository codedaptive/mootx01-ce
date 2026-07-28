import Foundation
import Subprocess

// MCPClient.swift — a minimal MCP client over one endpoint.
//
// The client speaks JSON-RPC 2.0, the wire protocol MCP servers use. Two
// transports are supported:
//   - stdio: launch the configured local command and exchange newline-
//     delimited JSON-RPC messages over its stdin/stdout. This is the
//     standard MCP stdio framing — one JSON object per line.
//   - sse / streamable HTTP: POST each JSON-RPC request to the configured
//     URL and read the JSON-RPC response from the HTTP body.
//
// MCP SECURITY BOUNDARY (why this client is deliberately narrow):
//   - Gauntlet runner also calls hard-coded tools (`moot_dream`,
//     `moot_recall_precise`) through this client, in addition to verbMap-
//     named tools. It never enumerates arbitrary tools and never executes
//     shell beyond the one configured stdio command. The command string is
//     treated as trusted operator input.
//   - For a remote (sse) endpoint, the only thing sent over the wire is the
//     JSON-RPC tool call and, if configured, a single auth header to the
//     single configured URL. No corpus content is sent anywhere except to
//     the endpoint that the operator named as the transfer target.
//   - Tool arguments are JSON values built by the tool, never interpolated
//     into a shell or a URL path.
//
// This client is exercised through the transfer/benchmark subcommands
// against live MCP servers, which is an integration concern; most paths
// are integration-tested. The timeout (stdioTimeoutSeconds, default 120 s)
// is unit-testable via a short override + a stub process — see
// MCPClientTimeoutTests.

/// An error raised while talking to an MCP endpoint.
struct MCPError: Error, Sendable, CustomStringConvertible {
    let description: String
}

/// A loosely-typed JSON value, used both to build tool-call arguments and
/// to parse tool results from servers whose result shapes are not known at
/// compile time (the benchmarker is engine-agnostic).
enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// The value at an object key, or nil if not an object / key absent.
    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// The string payload, if this value is a string.
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// The numeric payload, if this value is a number. JSON-RPC ids decode as
    /// numbers; the stdio response matcher compares this against the request id.
    var numericValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }
}

/// One parsed result item: its id (when the server returns one) and its
/// content (the searchable text). Both are optional so a server that returns
/// content without a stable id (MemPalace search) and one that returns an id
/// without inline content both parse into the same shape.
struct MCPResultItem: Sendable, Equatable {
    /// The item's stable id, when the server returns one. Nil for servers
    /// whose search results carry no id (e.g. MemPalace `search`).
    let id: String?
    /// The item's content / searchable text, when present.
    let content: String?
}

/// The parsed result of one tool call: the ordered list of result IDs (for
/// a query/list tool), the parsed result items (id + content, in order), the
/// id a write tool assigned (when the server mints its own), and the raw text
/// blocks the server returned (for diagnostics and for text parsing).
struct MCPToolResult: Sendable {
    /// Result item IDs in the order the server returned them. Empty when the
    /// tool returned no identifiable items (the items may still carry content).
    let orderedIDs: [String]
    /// The parsed result items, in order. Lets a caller read content even when
    /// the server returns no id, and read ids even when content is absent.
    let items: [MCPResultItem]
    /// The id the target assigned to a just-written entry, parsed from a write
    /// response (MOOTx01 `filed memory <UUID>`). Nil for query/list results or
    /// servers that echo the caller's id.
    let writeAssignedID: String?
    /// Raw text content blocks, concatenated in order.
    let textBlocks: [String]
}

/// A client bound to one MCP endpoint. An actor so that JSON-RPC requests
/// over a single transport are serialized — request ids stay monotonic and
/// stdio reads/writes never interleave.
actor MCPClient {
    private let endpoint: EndpointConfig
    private let urlSession: URLSession

    // stdio transport state. The child runs for its whole lifetime inside a
    // single session Task (see startStdioSession). Requests are handed to that
    // Task through `requestOut`; responses are routed back to the awaiting
    // caller by JSON-RPC id via `pending` / `received`.
    //
    // Foundation's Process + Pipe + FileHandle path is deliberately NOT used.
    // Its per-call read-wakeup latency (~150-200ms on macOS — a documented
    // FileHandle/pipe pathology, Apple Developer Forums 690310) dwarfed the
    // server's true ~30ms response and falsified every per-call latency the
    // gauntlet measured. Apple's Subprocess streams stdout as an async byte
    // sequence with no such wakeup penalty.
    private var sessionTask: Task<Void, Never>?
    private var requestOut: AsyncStream<String>.Continuation?
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    /// Watchdog tasks that cancel a pending response after `responseDeadline`
    /// seconds. Keyed by the same request id as `pending`; cancelled (and
    /// removed) as soon as `deliver` or `failAllPending` resolves the waiter so
    /// watchdogs never outlive their continuation.
    private var watchdogs: [Int: Task<Void, Never>] = [:]
    private var received: [Int: JSONValue] = [:]
    private var stdioClosed = false

    private var nextRequestID = 1

    /// Per-request deadline in seconds. Any `awaitResponse` that does not
    /// receive a matching frame within this window throws `MCPError` naming the
    /// endpoint and the request id. Default 120 s is generous for the heaviest
    /// moot_dream call; pass a shorter value during testing. The watchdog runs
    /// as a concurrent Task inside the actor, so it is safe under Swift 6 strict
    /// concurrency — the actor serialises all mutation of `pending` and
    /// `watchdogs`.
    let responseDeadline: TimeInterval

    init(endpoint: EndpointConfig, urlSession: URLSession = .shared,
         responseDeadline: TimeInterval = 120) {
        self.endpoint = endpoint
        self.urlSession = urlSession
        self.responseDeadline = responseDeadline
    }

    /// Brings the transport up. For stdio this launches the process and
    /// performs the MCP `initialize` handshake; for sse it is a no-op
    /// because each POST is independent.
    func connect() async throws {
        switch endpoint.transport {
        case .stdio(let command):
            try startStdioSession(command: command)
            // MCP requires an initialize call before tool calls. We send it
            // and ignore the capabilities payload — the benchmarker only
            // needs the verbMap tools, not capability negotiation.
            _ = try await sendRequest(method: "initialize", params: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("mcp-benchmarker"),
                    "version": .string("0.1.0"),
                ]),
            ]))
        case .sse:
            return
        }
    }

    /// Tears down the stdio session, if any. Safe to call more than once.
    /// Finishing `requestOut` ends the writer loop, which closes the child's
    /// stdin; the child sees EOF and exits, winding the session Task down
    /// gracefully. Cancelling the Task is a hard backstop (Subprocess tears the
    /// child down on cancellation) so a server that ignores EOF can never be
    /// orphaned. Cancelling watchdogs here is belt-and-suspenders: failAllPending
    /// already cancels them, but calling both is safe.
    func disconnect() {
        requestOut?.finish()
        requestOut = nil
        failAllPending(MCPError(description: "stdio transport disconnected for \(endpoint.name)"))
        sessionTask?.cancel()
        sessionTask = nil
    }

    /// Calls one tool by name with the given arguments and parses the result
    /// according to `format`. Only verbMap-named tools are ever passed here
    /// (see security boundary). The result format is supplied by the caller
    /// because it is a property of the endpoint's verbMap, not of the wire.
    func callTool(_ name: String,
                  arguments: [String: JSONValue],
                  format: ResultFormat) async throws -> MCPToolResult {
        let params = JSONValue.object([
            "name": .string(name),
            "arguments": .object(arguments),
        ])
        let result = try await sendRequest(method: "tools/call", params: params)
        return Self.parseToolResult(result, format: format)
    }

    /// Calls many tools in one pipelined batch over the stdio transport and
    /// returns their results in request order. Unlike `callTool`, every request
    /// line is queued to the session's stdin up front, then the responses are
    /// drained by id — the server processes the batch at full speed (overlapping
    /// its own compute with the driver's draining) instead of paying one
    /// scheduling round-trip per call. Across the thousands of load+query calls a
    /// full gauntlet issues against one long-lived process, that is the
    /// difference between minutes and hours.
    ///
    /// `deliver` buffers any response that arrives before its `awaitResponse`
    /// call, so draining the ids in order never loses an out-of-order frame and
    /// the writer never has to block (the session Task's stdin writer drains the
    /// queue concurrently with the child's stdout, so neither pipe buffer fills).
    ///
    /// SSE endpoints have no shared stream to pipeline; the batch falls back to
    /// sequential `callTool`s there.
    func pipelinedCallTools(_ calls: [(name: String, arguments: [String: JSONValue])],
                            format: ResultFormat) async throws -> [MCPToolResult] {
        guard case .stdio = endpoint.transport else {
            var results: [MCPToolResult] = []
            results.reserveCapacity(calls.count)
            for call in calls {
                results.append(try await callTool(call.name, arguments: call.arguments, format: format))
            }
            return results
        }
        guard let out = requestOut, !stdioClosed else {
            throw MCPError(description: "stdio transport not connected for \(endpoint.name)")
        }
        guard !calls.isEmpty else { return [] }

        // Assign a contiguous id block and queue every request line first.
        let baseID = nextRequestID
        nextRequestID += calls.count
        var ids: [Int] = []
        ids.reserveCapacity(calls.count)
        for (offset, call) in calls.enumerated() {
            let id = baseID + offset
            ids.append(id)
            let envelope = JSONValue.object([
                "jsonrpc": .string("2.0"),
                "id": .number(Double(id)),
                "method": .string("tools/call"),
                "params": .object([
                    "name": .string(call.name),
                    "arguments": .object(call.arguments),
                ]),
            ])
            let data = try JSONEncoder().encode(envelope)
            out.yield(String(decoding: data, as: UTF8.self))
        }

        // Drain by id, in request order. Out-of-order arrivals are buffered.
        var results: [MCPToolResult] = []
        results.reserveCapacity(calls.count)
        for id in ids {
            let response = try await awaitResponse(id: id)
            if let error = response["error"] {
                let message = error["message"]?.stringValue ?? "unknown JSON-RPC error"
                throw MCPError(description: "JSON-RPC error from \(endpoint.name): \(message)")
            }
            guard let result = response["result"] else {
                throw MCPError(description: "JSON-RPC response from \(endpoint.name) had no result")
            }
            results.append(Self.parseToolResult(result, format: format))
        }
        return results
    }

    // MARK: - JSON-RPC core

    /// Sends one JSON-RPC request and returns its `result` value. Throws on a
    /// JSON-RPC `error` object or a transport failure.
    private func sendRequest(method: String, params: JSONValue) async throws -> JSONValue {
        let id = nextRequestID
        nextRequestID += 1

        let envelope = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params,
        ])
        let requestData = try JSONEncoder().encode(envelope)

        let response: JSONValue
        switch endpoint.transport {
        case .stdio:
            // ID-ROUTED read: the long-lived stdio server is one shared stream
            // across the whole run (one process for all of load + dream + guard
            // probes + every column × every needle). The session reader decodes
            // each stdout frame and routes it to the caller awaiting its id;
            // id-less notifications and stray (non-JSON) log lines are dropped.
            // This keeps the shared stream aligned across the call-volume the
            // full ablation grid generates, regardless of arrival order.
            guard let out = requestOut, !stdioClosed else {
                throw MCPError(description: "stdio transport not connected for \(endpoint.name)")
            }
            out.yield(String(decoding: requestData, as: UTF8.self))
            response = try await awaitResponse(id: id)
        case .sse(let url):
            let responseData = try await sendHTTP(requestData, to: url)
            response = try JSONDecoder().decode(JSONValue.self, from: responseData)
        }

        if let error = response["error"] {
            let message = error["message"]?.stringValue ?? "unknown JSON-RPC error"
            throw MCPError(description: "JSON-RPC error from \(endpoint.name): \(message)")
        }
        guard let result = response["result"] else {
            throw MCPError(description: "JSON-RPC response from \(endpoint.name) had no result")
        }
        return result
    }

    // MARK: - stdio transport (Apple Subprocess)

    /// Launches the stdio MCP server inside a long-lived session Task using
    /// Apple's Subprocess. The Task runs two concurrent loops for the child's
    /// lifetime: a writer loop that drains queued request lines into the child's
    /// stdin, and a reader loop that streams the child's stdout, splits it into
    /// newline-framed JSON-RPC messages, and routes each by id back to the
    /// awaiting caller. The command is launched through `env` so a leading
    /// `VAR=value` token in the command sets that variable for the child —
    /// preserving the existing scratch-estate selection (`ARIA_MCP_SQLITE_PATH=…`,
    /// `MOOTX01_DATA_DIR=…`). Operator-supplied; CLI-argument trust level.
    private func startStdioSession(command: String) throws {
        let parts = command.split(separator: " ").map(String.init)
        guard !parts.isEmpty else {
            throw MCPError(description: "empty stdio command for \(endpoint.name)")
        }
        let (stream, continuation) = AsyncStream<String>.makeStream()
        self.requestOut = continuation
        self.stdioClosed = false
        let name = endpoint.name

        self.sessionTask = Task { [weak self] in
            do {
                _ = try await run(
                    Configuration(executable: .name("env"), arguments: Arguments(parts)),
                    input: .inputWriter,
                    output: .sequence,
                    error: .discarded
                ) { execution in
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        let writer = execution.standardInputWriter
                        let output = execution.standardOutput

                        // Writer: drain queued request lines into the child's
                        // stdin. When `requestOut` finishes (disconnect), the
                        // loop ends and stdin is closed so the child sees EOF.
                        // A write failure means the child's stdin pipe is
                        // broken (the process likely died); any request that
                        // was just written is lost, so we fail all pending
                        // callers immediately rather than leaving them hung
                        // until their timeout fires.
                        group.addTask {
                            for await line in stream {
                                do {
                                    _ = try await writer.write(line + "\n")
                                } catch {
                                    FileHandle.standardError.write(Data(
                                        ("mcp-benchmarker: stdio write failed for "
                                         + "\(name): \(error) — ending session\n").utf8))
                                    // Broken stdin pipe is unrecoverable; bail out
                                    // of the writer. The session Task's catch block
                                    // calls failAllPending after the group throws.
                                    throw error
                                }
                            }
                            try? await writer.finish()
                        }

                        // Reader: stream stdout, frame on newlines, route each
                        // decodable JSON-RPC object to its awaiting caller. Stray
                        // (non-JSON) log lines are skipped.
                        group.addTask {
                            var buf = [UInt8]()
                            for try await chunk in output {
                                chunk.withUnsafeBytes { buf.append(contentsOf: $0) }
                                while let nl = buf.firstIndex(of: 0x0A) {
                                    let lineBytes = Array(buf[..<nl])
                                    buf.removeSubrange(...nl)
                                    if lineBytes.isEmpty { continue }
                                    if let decoded = try? JSONDecoder().decode(
                                        JSONValue.self, from: Data(lineBytes)) {
                                        await self?.deliver(decoded)
                                    }
                                }
                            }
                        }

                        try await group.waitForAll()
                    }
                }
            } catch {
                // Spawn failure or mid-run death — reported below.
            }
            // Session ended: fail any caller still awaiting a response so it
            // cannot hang forever.
            await self?.failAllPending(
                MCPError(description: "stdio session for \(name) closed"))
        }
    }

    /// Routes one decoded stdout frame to the caller awaiting its id. A frame
    /// with no id is a notification and is ignored; a frame whose id has no
    /// waiter yet is buffered until the caller awaits it, which removes any
    /// register-vs-arrive race for pipelined batches. Cancels the watchdog for
    /// the id so it does not fire after delivery.
    private func deliver(_ decoded: JSONValue) {
        guard let responseID = decoded["id"]?.numericValue else { return }
        let id = Int(responseID)
        // Cancel the watchdog before resuming the continuation so there is no
        // window in which both the response and the timeout could fire.
        watchdogs.removeValue(forKey: id)?.cancel()
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(returning: decoded)
        } else {
            received[id] = decoded
        }
    }

    /// Awaits the response frame for `id`, returning immediately if it already
    /// arrived and was buffered by `deliver`. Throws `MCPError` (naming the
    /// endpoint and id) if no matching frame arrives within `responseDeadline`
    /// seconds. The watchdog Task is cancelled on delivery so it never leaks —
    /// it is also cancelled by `failAllPending` on disconnect so a whole-session
    /// teardown does not leave dangling Tasks.
    private func awaitResponse(id: Int) async throws -> JSONValue {
        if let buffered = received.removeValue(forKey: id) { return buffered }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            // Arm a watchdog that fires after responseDeadline. The watchdog
            // captures the actor reference weakly-by-isolation: `[weak self]`
            // is not valid on actors, so we capture `self` strongly but check
            // whether the continuation is still present before resuming it.
            // If `deliver` or `failAllPending` already removed the continuation
            // the watchdog finds nothing and exits cleanly. The watchdog is
            // cancelled (Task.cancel) from both of those paths so in practice
            // it almost never reaches the sleep end.
            let deadline = responseDeadline
            let endpointName = endpoint.name
            let watchdog = Task { [self] in
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                // If cancelled (response arrived), Task.isCancelled is true and
                // we skip the timeout path entirely.
                guard !Task.isCancelled else { return }
                await self.timeoutPending(id: id, endpointName: endpointName)
            }
            watchdogs[id] = watchdog
        }
    }

    /// Called by a watchdog when its deadline fires. Removes the still-pending
    /// continuation (if any) and resumes it with a timeout error. The watchdog
    /// is removed from `watchdogs` first so neither `deliver` nor a double-fire
    /// can touch it again.
    private func timeoutPending(id: Int, endpointName: String) {
        watchdogs.removeValue(forKey: id)
        guard let cont = pending.removeValue(forKey: id) else { return }
        cont.resume(throwing: MCPError(
            description: "response timeout for request id \(id) on endpoint '\(endpointName)'"))
    }

    /// Fails every in-flight caller — used when the session ends or disconnects.
    /// Cancels all watchdogs first so none fires after the continuation has
    /// already been resumed, preventing a double-resume crash.
    private func failAllPending(_ error: Error) {
        stdioClosed = true
        // Cancel watchdogs before resuming continuations. The order matters:
        // a watchdog that fires between the two loops would try to resume a
        // continuation that has already been resumed by the loop below.
        let dogs = watchdogs
        watchdogs.removeAll()
        for (_, dog) in dogs { dog.cancel() }
        let waiters = pending
        pending.removeAll()
        for (_, continuation) in waiters {
            continuation.resume(throwing: error)
        }
    }

    // MARK: - HTTP / SSE transport

    /// POSTs the JSON-RPC request to the endpoint URL and returns the body.
    /// Only the configured auth header (if any) is attached; nothing else
    /// about the local environment is disclosed.
    private func sendHTTP(_ requestData: Data, to url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let auth = endpoint.auth, let token = auth.token {
            // Header name defaults to Authorization: Bearer <token> unless the
            // config names a custom header.
            let headerName = auth.header ?? "Authorization"
            let headerValue = auth.header == nil ? "Bearer \(token)" : token
            request.setValue(headerValue, forHTTPHeaderField: headerName)
        }
        request.httpBody = requestData

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw MCPError(description: "HTTP \(code) from \(endpoint.name)")
        }
        return data
    }

    // MARK: - result parsing

    /// Parses an MCP tool result into ordered items according to `format`.
    ///
    /// MCP tool results carry a `content` array of typed blocks. The shape of
    /// the payload inside is server-specific, so the endpoint's verbMap names
    /// it (`ResultFormat`) rather than the parser guessing:
    ///
    ///   - `.jsonObjects(idKey, contentKey)`: items are JSON objects found in
    ///     `structuredContent` first, else in the first `text` block parsed as
    ///     JSON. Each item's id is read from `idKey` (when non-nil) and its
    ///     content from `contentKey`. Used by MemPalace (`list_drawers` →
    ///     `drawer_id`/`content_preview`; `search` → no id / `text`).
    ///   - `.mootText`: MOOTx01 plain text. A search result is `found N`
    ///     followed by `<UUID>  [location]  <content>` per ranked line; a write
    ///     result is `filed memory <UUID>` (the target-assigned id).
    ///
    /// Text blocks are always returned for diagnostics regardless of format.
    static func parseToolResult(_ result: JSONValue, format: ResultFormat) -> MCPToolResult {
        var textBlocks: [String] = []
        if case .array(let blocks) = result["content"] {
            for block in blocks {
                if block["type"]?.stringValue == "text", let text = block["text"]?.stringValue {
                    textBlocks.append(text)
                }
            }
        }

        switch format {
        case let .jsonObjects(idKey, contentKey):
            return parseJSONObjects(result: result, textBlocks: textBlocks,
                                    idKey: idKey, contentKey: contentKey)
        case .mootText:
            return parseMootText(textBlocks: textBlocks)
        }
    }

    /// Parses the `.jsonObjects` shape. Looks for the item array in
    /// `structuredContent` first (the structured channel), then in the first
    /// `text` block parsed as JSON.
    private static func parseJSONObjects(result: JSONValue,
                                         textBlocks: [String],
                                         idKey: String?,
                                         contentKey: String) -> MCPToolResult {
        func build(_ objects: [JSONValue]) -> MCPToolResult {
            let items = objects.map { obj in
                MCPResultItem(id: idKey.flatMap { obj[$0]?.stringValue },
                              content: obj[contentKey]?.stringValue)
            }
            return MCPToolResult(orderedIDs: items.compactMap(\.id),
                                 items: items,
                                 writeAssignedID: nil,
                                 textBlocks: textBlocks)
        }

        if let structured = result["structuredContent"],
           let objects = objectArray(structured, idKey: idKey, contentKey: contentKey) {
            return build(objects)
        }
        for text in textBlocks {
            if let data = text.data(using: .utf8),
               let parsed = try? JSONDecoder().decode(JSONValue.self, from: data),
               let objects = objectArray(parsed, idKey: idKey, contentKey: contentKey) {
                return build(objects)
            }
        }
        return MCPToolResult(orderedIDs: [], items: [], writeAssignedID: nil, textBlocks: textBlocks)
    }

    /// Pulls the array of result objects out of a value that is either an
    /// array of objects or an object holding such an array under a single
    /// array-valued key (e.g. MemPalace `results` / `drawers`). An object is
    /// kept when it carries the id key (if one is named) or the content key —
    /// so a server that returns content without ids still parses. Returns nil
    /// when no qualifying array is found.
    private static func objectArray(_ value: JSONValue,
                                    idKey: String?,
                                    contentKey: String) -> [JSONValue]? {
        func qualifying(_ array: [JSONValue]) -> [JSONValue]? {
            let kept = array.filter { obj in
                (idKey.flatMap { obj[$0]?.stringValue } != nil) || obj[contentKey]?.stringValue != nil
            }
            return kept.isEmpty ? nil : kept
        }
        if case .array(let array) = value {
            return qualifying(array)
        }
        // Object handling: first look at every array-valued member (server
        // wrappers like MemPalace's `drawers`/`results`); if none qualifies,
        // treat the object ITSELF as a single record when it carries the id or
        // content key. The single-record case is a `fetch` result (MemPalace
        // `get_drawer` returns one bare object with full `content`, not an
        // array), which a faithful transfer must read.
        if case .object(let obj) = value {
            // Deterministic order so the first qualifying array is stable.
            for key in obj.keys.sorted() {
                if case .array(let array)? = obj[key], let kept = qualifying(array) {
                    return kept
                }
            }
            // No qualifying nested array — is the object itself one record?
            if let kept = qualifying([value]) { return kept }
        }
        return nil
    }

    /// Parses MOOTx01's plain-text results. Each line beginning with a UUID
    /// token is one item: `<UUID>  [location]  <content>` for a search hit, or
    /// `filed memory <UUID>` for a write. The first UUID found in a write
    /// response becomes `writeAssignedID`; search-hit UUIDs become ordered ids
    /// with their trailing content.
    private static func parseMootText(textBlocks: [String]) -> MCPToolResult {
        var items: [MCPResultItem] = []
        var writeAssignedID: String?

        for block in textBlocks {
            for rawLine in block.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                // Write response: `filed memory <UUID>`. Capture the first.
                if line.lowercased().hasPrefix("filed memory ") {
                    let token = line.dropFirst("filed memory ".count)
                        .trimmingCharacters(in: .whitespaces)
                    if let uuid = leadingUUID(of: token), writeAssignedID == nil {
                        writeAssignedID = uuid
                    }
                    continue
                }
                // Search hit: a line that starts with a UUID token. Everything
                // after the `[location]` bracket is the content; if no bracket
                // is present, the remainder after the UUID is the content.
                guard let uuid = leadingUUID(of: line) else { continue }
                let afterUUID = line.dropFirst(uuid.count).trimmingCharacters(in: .whitespaces)
                let content: String
                if let close = afterUUID.firstIndex(of: "]") {
                    content = String(afterUUID[afterUUID.index(after: close)...])
                        .trimmingCharacters(in: .whitespaces)
                } else {
                    content = afterUUID
                }
                items.append(MCPResultItem(id: uuid, content: content))
            }
        }

        return MCPToolResult(orderedIDs: items.compactMap(\.id),
                             items: items,
                             writeAssignedID: writeAssignedID,
                             textBlocks: textBlocks)
    }

    /// Returns the leading whitespace-delimited token of `s` if it is a
    /// canonical UUID (8-4-4-4-12 hex), else nil. MOOTx01 emits upper-case
    /// UUIDs; the check is case-insensitive so either case parses.
    private static func leadingUUID(of s: String) -> String? {
        guard let token = s.split(separator: " ", maxSplits: 1).first else { return nil }
        let candidate = String(token)
        // UUID(uuidString:) is the canonical 8-4-4-4-12 validator; reusing it
        // avoids a hand-rolled regex and matches the exact format MOOTx01 emits.
        return UUID(uuidString: candidate) != nil ? candidate : nil
    }
}
