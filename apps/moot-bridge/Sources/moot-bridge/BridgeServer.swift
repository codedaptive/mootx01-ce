import Foundation

// BridgeServer.swift — the bridging MCP memory server.
//
// An AI client launches this process as its single memory MCP server, pointing
// its stdio MCP transport here instead of at MemPalace or mootx01 directly. The
// bridge then:
//
//   1. initialize — handshakes BOTH backends at startup (done in main.swift
//      before the loop), so the first write reaches two live, initialized
//      servers.
//
//   2. tools/list — returns the PRIMARY backend's tool list, PLUS two
//      bridge-owned tools injected into the list:
//        - bridge_set_primary { backend: string } — flip which backend is primary
//          (reads + returned response) mid-session, effective immediately.
//        - bridge_status — report the current primary and per-backend health/stats.
//
//   3. WRITE-classified tools/call — forward to the primary verbatim (its
//      response, id-preserving, returns to the client) AND translate the call
//      through the secondary's verbMap and fire it at the secondary. The
//      secondary's response is NOT returned; a secondary FAILURE is counted and
//      swallowed so the client never sees it (backend-failure isolation, carried
//      from ProxyServer.swift:553-559).
//
//   4. READ-classified calls (query) and ANY unclassifiable tool call — go to the
//      PRIMARY only, verbatim, id-preserving. Unclassifiable calls are NOT
//      blind-fanned to the secondary (carried from the classify-then-translate
//      contract): only calls we can classify and translate are mirrored.
//
//   5. bridge-owned calls (bridge_set_primary, bridge_status) — handled entirely inside
//      the bridge; they never touch a backend transport. bridge_set_primary swaps
//      which backend serves reads and whose response is returned, effective on
//      the very next call.
//
//   6. notifications — a VALID JSON-RPC envelope with no id is forwarded to BOTH
//      backends, no response awaited.
//
//   7. unreadable frames — a line that is not valid JSON, or that is valid JSON
//      but not a JSON-RPC envelope, is REJECTED here: the client receives a
//      JSON-RPC error (parseError -32700 / invalidRequest -32600, null id) and
//      NO backend ever sees the line. The bridge is the boundary; a frame it
//      cannot read is a frame the backends should never receive. Forwarding one
//      as a notification would leave the backend's own parseError response
//      unread on its stdout, and the next sendAndReceive would consume that
//      stale error instead of its own result — skewing every response from then
//      on until the process restarts.
//
// SAFETY (dual-write rule): a WRITE fan-out re-issues the write to BOTH backends.
// That is the whole point of the bridge — the AI's memory lands in MemPalace AND
// mootx01 simultaneously. Both backends MUST therefore be writable targets the
// operator intends to populate. For tests this means scratch backends only
// (mempalace --palace /tmp/...; MOOTX01_DATA_DIR=/tmp/...).

/// The classified call type for a tools/call, matched against a backend's
/// verbMap. The bridge recognizes two verbs; everything else is unclassifiable and
/// is served from the primary verbatim without any secondary fan-out.
enum BridgeCallType: Equatable {
    case write
    case query
}

/// What the bridge decides to do with one raw client line, decided BEFORE any
/// backend transport is touched.
///
/// There are THREE outcomes here, not two. Asking only "does it have an id?"
/// collapses a genuine id-less notification together with a frame that could not
/// be read at all, and routes both down the notification path — which is exactly
/// how a single malformed line desynchronizes a whole session.
enum FrameDisposition: Equatable {
    /// A valid JSON-RPC envelope carrying an `id`. Served on the request path
    /// with the client's id preserved. `method` and `id` are carried alongside
    /// the parsed value because the classifier has already proved both present,
    /// so no downstream site needs to re-check or supply a fallback.
    case request(parsed: JSONValue, method: String, id: JSONValue)
    /// A valid JSON-RPC envelope with no `id`: a real notification. Forwarded to
    /// both backends; no response is owed to the client.
    case notification
    /// Unreadable, or readable but not a JSON-RPC envelope. Answered at the
    /// bridge with a JSON-RPC error and forwarded to NO backend.
    case reject(code: Int, message: String)
}

/// A handle to one configured backend: its live transport, its name, and its
/// verbMap. Bundled so the bridge can swap "primary" by swapping which handle is
/// designated primary, without re-deriving anything.
struct BridgeBackend: Sendable {
    let transport: RawMCPBackend
    let name: String
    let verbMap: VerbMap
}

/// The bridging MCP server. A `final class` (not a struct) because the primary
/// pointer is mutable session state that the bridge_set_primary handler flips in
/// place, and the run loop is the single owner — there is no concurrent mutation
/// of the primary index (the loop reads one client line at a time, fully handles
/// it, then reads the next).
final class BridgeServer {
    /// The two backends, indexed 0 and 1. Fixed for the session; only which one
    /// is `primaryIndex` changes.
    private let backends: [BridgeBackend]
    /// Index into `backends` of the current primary — the backend that serves
    /// reads and whose response is returned to the client. Flipped by
    /// bridge_set_primary. Starts from config.
    private var primaryIndex: Int

    private let stats: BridgeStats

    /// Running counter for fresh secondary-request ids. Starts at 1 and
    /// increments per fan-out so ids on the secondary transport are disjoint from
    /// the client's id space and never collide with a forwarded primary id.
    private var nextSecondaryID: Int = 1

    /// The bridge's own protocol version echoed in bridge-owned responses, matching
    /// the MCP version the backends were initialized with.
    private static let protocolVersion = "2024-11-05"

    init(backends: [BridgeBackend], primaryIndex: Int, stats: BridgeStats) {
        precondition(backends.count == 2, "bridge requires exactly two backends")
        precondition(primaryIndex == 0 || primaryIndex == 1, "primaryIndex must be 0 or 1")
        self.backends = backends
        self.primaryIndex = primaryIndex
        self.stats = stats
    }

    private var primary: BridgeBackend { backends[primaryIndex] }
    private var secondary: BridgeBackend { backends[1 - primaryIndex] }

    // MARK: - Run loop

    /// Runs the bridge until the client closes our stdin (EOF). Reads client
    /// JSON-RPC lines from `clientIn`, handles each, and writes responses to
    /// `clientOut`. Returns when the client disconnects.
    func run(clientIn: FileHandle, clientOut: FileHandle) async throws {
        var buffer = Data()
        while true {
            guard let line = try await Self.nextLine(from: clientIn, buffer: &buffer) else {
                break  // client closed stdin → shut down
            }
            try await handleClientMessage(line, clientOut: clientOut)
        }
    }

    /// Handles one client message end to end.
    ///
    /// The three-way split is the whole point: reject / notify / request. A frame
    /// the bridge cannot read is answered here and forwarded nowhere, so a
    /// backend never has to reply to garbage the bridge would then fail to read
    /// back off its stdout.
    private func handleClientMessage(_ line: Data, clientOut: FileHandle) async throws {
        switch Self.classifyFrame(line) {
        case .reject(let code, let message):
            // Rejected at the boundary: the client gets a JSON-RPC error and NO
            // backend sees the line. Draining a backend's stdout after the fact
            // would race legitimate traffic and would still have let the
            // malformed frame through, so the refusal happens before any write.
            writeProtocolError(code: code, message: message, to: clientOut)

        case .notification:
            // A real notification: valid envelope, no id, so no response is owed.
            // Forward to BOTH backends so a backend that relies on, e.g.,
            // `notifications/initialized` stays in sync.
            let primaryTransport = primary.transport
            let secondaryTransport = secondary.transport
            try? await primaryTransport.sendNotification(line)
            try? await secondaryTransport.sendNotification(line)

        case .request(let parsed, let method, let idValue):
            switch method {
            case "tools/list":
                try await handleToolsList(line: line, clientOut: clientOut)
            case "tools/call":
                let toolName = parsed["params"]?["name"]?.stringValue ?? ""
                if toolName == Self.setPrimaryToolName {
                    try await handleSetPrimary(parsed: parsed, clientID: idValue, clientOut: clientOut)
                } else if toolName == Self.statusToolName {
                    try await handleStatus(clientID: idValue, clientOut: clientOut)
                } else {
                    try await handleToolCall(line: line, parsed: parsed, toolName: toolName,
                                             clientOut: clientOut)
                }
            default:
                // initialize and any other id-bearing method: forward to primary
                // verbatim, return its response. (Both backends are already
                // initialized at startup; re-forwarding initialize to the primary
                // is harmless and keeps the client's view consistent.)
                try await forwardToPrimary(line: line, method: method, clientOut: clientOut)
            }
        }
    }

    // MARK: - Frame classification (the boundary)

    /// JSON-RPC 2.0 code for a frame that is not valid JSON at all.
    static let parseErrorCode = -32700
    /// JSON-RPC 2.0 code for valid JSON that is not a valid JSON-RPC envelope.
    static let invalidRequestCode = -32600

    /// Classifies one raw client line into the bridge's three frame dispositions.
    ///
    /// The envelope test mirrors `JSONRPCRequest.decode` in AriaMcpKit
    /// (JSONRPC.swift:68-79) exactly — an object, `jsonrpc` equal to the string
    /// `"2.0"`, and a string `method`. Failing the JSON parse is `parseError`;
    /// parsing but failing the envelope test is `invalidRequest`. The backends
    /// draw the same line, so a frame refused here receives the same answer it
    /// would have received had it been forwarded, minus the desynchronization.
    /// Collapsing the two codes into one would tell a client "bad JSON" when the
    /// JSON was fine and only the envelope was wrong.
    ///
    /// `id` is deliberately tested for PRESENCE, not for non-null: JSON-RPC 2.0
    /// permits an id to be a string, a number, or null, and an explicit
    /// `"id": null` is a request, not a notification.
    ///
    /// Exposed as `static` for direct unit testing without a live BridgeServer.
    static func classifyFrame(_ line: Data) -> FrameDisposition {
        guard let parsed = try? JSONDecoder().decode(JSONValue.self, from: line) else {
            return .reject(code: parseErrorCode,
                           message: "Parse error: client frame is not valid JSON")
        }
        // A non-object (bare array, string, number, bool, null) fails every
        // subscript below, but the object test is written out so the envelope
        // contract is legible rather than implied by JSONValue's subscript.
        guard parsed.objectValue != nil,
              parsed["jsonrpc"]?.stringValue == "2.0",
              let method = parsed["method"]?.stringValue else {
            return .reject(code: invalidRequestCode,
                           message: "Invalid Request: malformed JSON-RPC envelope")
        }
        guard let id = parsed["id"] else { return .notification }
        return .request(parsed: parsed, method: method, id: id)
    }

    // MARK: - tools/list (inject bridge-owned tools)

    /// Forwards tools/list to the primary, then injects the two bridge-owned tools
    /// into the returned tool array before relaying to the client. The client
    /// thus sees the primary's real tools PLUS bridge_set_primary and bridge_status.
    ///
    /// The client's id needs no parameter here: the primary's own response
    /// already carries it, and the splice edits only `result.tools`.
    private func handleToolsList(line: Data, clientOut: FileHandle) async throws {
        let primaryBackend = primary
        let start = DispatchTime.now()
        let response = try await primaryBackend.transport.sendAndReceive(line)
        await stats.recordLatency(Self.elapsedSeconds(since: start),
                                  label: "\(primaryBackend.name).tools/list")

        // Decode, splice the bridge tools into result.tools, re-encode. If anything
        // about the shape is unexpected, fall back to relaying the primary's
        // response verbatim so we never break the client's tools/list.
        guard var root = (try? JSONDecoder().decode(JSONValue.self, from: response))?.objectValue,
              let result = root["result"]?.objectValue,
              var tools = result["tools"]?.arrayValue else {
            writeLine(response, to: clientOut)
            return
        }
        tools.append(Self.bridgeSetPrimaryToolSchema())
        tools.append(Self.bridgeStatusToolSchema())
        var newResult = result
        newResult["tools"] = .array(tools)
        root["result"] = .object(newResult)
        let spliced = (try? JSONEncoder().encode(JSONValue.object(root))) ?? response
        writeLine(spliced, to: clientOut)
    }

    // MARK: - tools/call (write fan-out / read passthrough)

    /// Handles a backend tools/call: forward to the primary (response returned to
    /// the client), and — only for WRITE-classified calls — translate and fan the
    /// call out to the secondary too.
    private func handleToolCall(line: Data, parsed: JSONValue, toolName: String,
                                clientOut: FileHandle) async throws {
        let primaryBackend = primary
        let secondaryBackend = secondary

        // Always forward to the primary verbatim and time it; return its response
        // to the client id-preserving. This covers reads, writes, and any
        // unclassifiable tool the primary exposes.
        let start = DispatchTime.now()
        let response = try await primaryBackend.transport.sendAndReceive(line)
        await stats.recordLatency(Self.elapsedSeconds(since: start),
                                  label: "\(primaryBackend.name).tools/call")
        writeLine(response, to: clientOut)

        // Classify the call against the PRIMARY's verbMap (the primary is the
        // backend the client is actually driving, so its verbMap names the call).
        guard let callType = Self.classifyCall(toolName: toolName,
                                               verbMap: primaryBackend.verbMap) else {
            return  // unclassifiable: primary-only, no secondary fan-out
        }

        // Only WRITE calls fan out to the secondary. A read is served from the
        // primary alone — fanning a read out would do nothing useful (its result
        // is discarded) and would double the read load.
        guard callType == .write else { return }

        // Translate the write through the secondary's verbMap and fire it. A
        // secondary failure is counted and swallowed — it never reaches the
        // client (backend-failure isolation).
        let freshID = nextSecondaryID
        nextSecondaryID += 1
        guard let translated = Self.translateCall(
            clientParsed: parsed,
            callType: callType,
            primaryVerbMap: primaryBackend.verbMap,
            secondaryVerbMap: secondaryBackend.verbMap,
            freshID: freshID
        ) else {
            // Could not extract the content to mirror — count as a failure so the
            // stats stay honest about the data gap, but never surface it.
            await stats.recordSecondaryFailure()
            return
        }

        let mirrorStart = DispatchTime.now()
        do {
            _ = try await secondaryBackend.transport.sendAndReceive(translated)
            await stats.recordLatency(Self.elapsedSeconds(since: mirrorStart),
                                      label: "\(secondaryBackend.name).tools/call.mirror")
        } catch {
            await stats.recordSecondaryFailure()
        }
    }

    /// Forwards an arbitrary id-bearing method (e.g. initialize) to the primary
    /// verbatim and relays its response to the client.
    private func forwardToPrimary(line: Data, method: String, clientOut: FileHandle) async throws {
        let primaryBackend = primary
        let start = DispatchTime.now()
        let response = try await primaryBackend.transport.sendAndReceive(line)
        await stats.recordLatency(Self.elapsedSeconds(since: start),
                                  label: "\(primaryBackend.name).\(method)")
        writeLine(response, to: clientOut)
    }

    // MARK: - Bridge-owned tools

    static let setPrimaryToolName = "bridge_set_primary"
    static let statusToolName = "bridge_status"

    /// Handles bridge_set_primary { backend: string }. Flips which backend is
    /// primary, effective immediately (the next client call reads from the new
    /// primary). Responds with a confirmation result. An unknown backend name is
    /// returned as a tool-result error (isError: true) rather than a JSON-RPC
    /// protocol error, so the client gets a clean, actionable message.
    private func handleSetPrimary(parsed: JSONValue, clientID: JSONValue,
                                  clientOut: FileHandle) async throws {
        let requested = parsed["params"]?["arguments"]?["backend"]?.stringValue
        guard let requested else {
            writeToolError(clientID: clientID,
                           message: "bridge_set_primary requires a `backend` string argument",
                           to: clientOut)
            return
        }
        guard let newIndex = backends.firstIndex(where: { $0.name == requested }) else {
            let names = backends.map(\.name).joined(separator: ", ")
            writeToolError(clientID: clientID,
                           message: "bridge_set_primary: unknown backend \"\(requested)\" — configured backends are: \(names)",
                           to: clientOut)
            return
        }
        let previous = primary.name
        primaryIndex = newIndex
        let confirmation = "primary is now \"\(requested)\" (was \"\(previous)\"); " +
            "reads and returned responses now come from \"\(requested)\", writes still fan out to both"
        writeToolText(clientID: clientID, text: confirmation, to: clientOut)
    }

    /// Handles bridge_status. Reports the current primary, the secondary, and a
    /// per-backend latency + failure-count summary from the stats actor.
    private func handleStatus(clientID: JSONValue, clientOut: FileHandle) async throws {
        let snap = await stats.snapshot()
        var lines: [String] = []
        lines.append("primary:   \(primary.name)")
        lines.append("secondary: \(secondary.name)")
        lines.append("backends:  \(backends.map(\.name).joined(separator: ", "))")
        if snap.series.isEmpty {
            lines.append("stats:     (no traffic yet)")
        } else {
            lines.append("stats:")
            for s in snap.series {
                lines.append(String(format: "  %@: mean %.2f ms  p95 %.2f ms  n=%d",
                                    s.label, s.mean * 1000, s.p95 * 1000, s.totalCount))
            }
        }
        lines.append("secondary write failures (non-fatal): \(snap.secondaryFailureCount)")
        writeToolText(clientID: clientID, text: lines.joined(separator: "\n"), to: clientOut)
    }

    // MARK: - Classify + translate (carried from ProxyServer)

    /// Classifies a tools/call by tool name against a verbMap. Returns the call
    /// type, or nil when the tool name matches neither verb (unclassifiable → no
    /// secondary fan-out, served from primary alone).
    ///
    /// Exposed as `static` for direct unit testing without a live BridgeServer.
    static func classifyCall(toolName: String, verbMap: VerbMap) -> BridgeCallType? {
        if toolName == verbMap.write { return .write }
        if toolName == verbMap.query { return .query }
        return nil
    }

    /// Translates a primary-side tools/call into a secondary-side tools/call by
    /// extracting the variable argument from the client's call under the primary's
    /// arg-role key, then rebuilding the call with the secondary's tool name, arg
    /// key, and constantArgs. Returns nil when the content/query cannot be
    /// extracted (the call is then counted as a secondary failure, never sent).
    ///
    /// The `freshID` becomes the JSON-RPC id — never the client's original id —
    /// so the secondary transport's id space stays disjoint. The returned Data is
    /// a complete newline-free JSON-RPC tools/call ready for
    /// `RawMCPBackend.sendAndReceive`.
    ///
    /// Exposed as `static` for direct unit testing without a live BridgeServer.
    static func translateCall(clientParsed: JSONValue?,
                              callType: BridgeCallType,
                              primaryVerbMap: VerbMap,
                              secondaryVerbMap: VerbMap,
                              freshID: Int) -> Data? {
        guard let clientArgs = clientParsed?["params"]?["arguments"]?.objectValue else {
            return nil
        }

        // Start with the secondary's constantArgs (its fixed write context, e.g.
        // mootx01's `location` or MemPalace's `wing`+`room`).
        var secondaryArgs: [String: JSONValue] = Dictionary(
            uniqueKeysWithValues: secondaryVerbMap.constantArgs.map { ($0.key, JSONValue.string($0.value)) }
        )

        let secondaryTool: String
        switch callType {
        case .write:
            // Extract content under the primary's contentArg; inject under the
            // secondary's. Without content there is nothing to mirror → nil.
            guard let value = clientArgs[primaryVerbMap.contentArg] else { return nil }
            secondaryArgs[secondaryVerbMap.contentArg] = value
            secondaryTool = secondaryVerbMap.write
        case .query:
            // Queries are not fanned out in normal operation (reads are
            // primary-only), but the translation is defined for completeness and
            // unit-testability. Map query text from primary key to secondary key.
            guard let value = clientArgs[primaryVerbMap.queryArg] else { return nil }
            secondaryArgs[secondaryVerbMap.queryArg] = value
            secondaryTool = secondaryVerbMap.query
        }

        let envelope = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id":      .number(Double(freshID)),
            "method":  .string("tools/call"),
            "params":  .object([
                "name":      .string(secondaryTool),
                "arguments": .object(secondaryArgs),
            ]),
        ])
        return try? JSONEncoder().encode(envelope)
    }

    // MARK: - Bridge tool schemas

    /// The JSON schema object for the bridge_set_primary tool, as it appears in
    /// tools/list. Mirrors the MCP tool-descriptor shape
    /// (`{ name, description, inputSchema }`).
    static func bridgeSetPrimaryToolSchema() -> JSONValue {
        .object([
            "name": .string(setPrimaryToolName),
            "description": .string(
                "Switch which memory backend is PRIMARY (serves reads and returns its response to you). " +
                "Writes always fan out to BOTH backends regardless. Effective immediately, mid-session."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "backend": .object([
                        "type": .string("string"),
                        "description": .string("The name of the backend to make primary."),
                    ]),
                ]),
                "required": .array([.string("backend")]),
            ]),
        ])
    }

    /// The JSON schema object for the bridge_status tool, as it appears in
    /// tools/list.
    static func bridgeStatusToolSchema() -> JSONValue {
        .object([
            "name": .string(statusToolName),
            "description": .string(
                "Report the current primary backend and a per-backend latency + failure-count summary."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([:]),
            ]),
        ])
    }

    // MARK: - Response writers

    /// Writes a successful tool result whose single text block is `text`.
    private func writeToolText(clientID: JSONValue, text: String, to clientOut: FileHandle) {
        let envelope = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": clientID,
            "result": .object([
                "content": .array([
                    .object(["type": .string("text"), "text": .string(text)]),
                ]),
                "isError": .bool(false),
            ]),
        ])
        if let data = try? JSONEncoder().encode(envelope) { writeLine(data, to: clientOut) }
    }

    /// Writes a tool result flagged `isError: true` with the given message. Used
    /// for bridge-tool misuse (bad/unknown backend name) so the client gets a clean
    /// actionable message rather than a JSON-RPC protocol error.
    private func writeToolError(clientID: JSONValue, message: String, to clientOut: FileHandle) {
        let envelope = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": clientID,
            "result": .object([
                "content": .array([
                    .object(["type": .string("text"), "text": .string(message)]),
                ]),
                "isError": .bool(true),
            ]),
        ])
        if let data = try? JSONEncoder().encode(envelope) { writeLine(data, to: clientOut) }
    }

    /// Writes a JSON-RPC PROTOCOL error to the client — an `error` member, not an
    /// `isError` tool result. Used only for frames the bridge refuses at the
    /// boundary; nothing is sent to any backend on this path.
    ///
    /// The id is null because a refused frame has no id the bridge can trust: it
    /// either failed to parse, or failed the envelope test, so any `id` bytes
    /// inside it are not a JSON-RPC id. JSON-RPC 2.0 prescribes a null id for
    /// exactly this case, and AriaMcpKit's StdioServer answers the same way
    /// (Server.swift:349-379) — the bridge and the backends must give a client
    /// the same answer, or the client sees two different protocols depending on
    /// how far its frame happened to travel.
    ///
    /// This is distinct from `writeToolError`, which reports bridge-TOOL misuse
    /// as a successful call carrying `isError: true`. A frame that is not a valid
    /// JSON-RPC message never reached a tool, so it cannot be reported as one.
    private func writeProtocolError(code: Int, message: String, to clientOut: FileHandle) {
        let envelope = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .null,
            "error": .object([
                "code": .number(Double(code)),
                "message": .string(message),
            ]),
        ])
        if let data = try? JSONEncoder().encode(envelope) { writeLine(data, to: clientOut) }
    }

    /// Writes one response line (appending the newline framing) to the client.
    private func writeLine(_ data: Data, to clientOut: FileHandle) {
        var out = data
        out.append(0x0A)
        clientOut.write(out)
    }

    // MARK: - Line framing + timing (carried from ProxyServer)

    /// Monotonic elapsed seconds since a start mark.
    static func elapsedSeconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    /// Reads one newline-delimited line from a FileHandle, buffering partial reads
    /// across calls. Returns nil at EOF (client closed stdin).
    static func nextLine(from handle: FileHandle, buffer: inout Data) async throws -> Data? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if lineData.isEmpty { continue }
                return Data(lineData)
            }
            let chunk = await readChunk(from: handle)
            if chunk.isEmpty {
                if buffer.isEmpty { return nil }
                let rest = Data(buffer)
                buffer.removeAll()
                return rest
            }
            buffer.append(chunk)
        }
    }

    private static func readChunk(from handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let data = handle.availableData
                continuation.resume(returning: data)
            }
        }
    }
}
