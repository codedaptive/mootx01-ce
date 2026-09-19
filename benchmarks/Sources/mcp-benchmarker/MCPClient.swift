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
//     named tools. It never executes shell beyond the one configured stdio
//     command. The command string is treated as trusted operator input.
//   - Tool enumeration (`listTools`) exists for exactly one caller: the
//     lme-agentic lane, which advertises the surface to an external
//     answering AI. That lane filters the advertised list to a READ-ONLY
//     allowlist and refuses to execute any tool outside it (see
//     LMEAgenticRunner.swift), so enumeration never widens what can run.
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

/// A decoded refusal payload from an ARIA v2 tool-level error or a JSON-RPC
/// -32602 `invalid_argument` error. Carries the catalog-string class code and
/// optional diagnostic fields sourced from `structuredContent.error` (tool
/// level) or `error.data` (protocol level).
///
/// Catalog class codes (from `aria_v2_mission02_vectors.json`):
///   - `"memory_not_found"` — valid-format UUID that does not exist in the estate
///   - `"invalid_argument"` — malformed argument (-32602 carries this in error.data.code)
public struct MCPRefusalInfo: Sendable, Equatable {
    /// Catalog class code string, e.g. `"memory_not_found"` or `"invalid_argument"`.
    public let code: String
    /// Human-readable refusal reason from the server.
    public let message: String
    /// Optional recovery hint emitted by the server (absent for memory_not_found).
    public let recovery: String?
    /// Whether the caller may retry with a different argument (protocol-level hint).
    public let retryable: Bool?
    /// Argument path that failed (from -32602 error.data.path), when available.
    public let path: String?
    /// Allowed values (from -32602 error.data.allowed), when available. The server
    /// returns this as a JSON array of strings, decoded element-by-element.
    public let allowed: [String]?
    /// Correction hint (from -32602 error.data.correction), when available.
    public let correction: String?

    public init(code: String, message: String, recovery: String? = nil,
                retryable: Bool? = nil, path: String? = nil,
                allowed: [String]? = nil, correction: String? = nil) {
        self.code = code
        self.message = message
        self.recovery = recovery
        self.retryable = retryable
        self.path = path
        self.allowed = allowed
        self.correction = correction
    }
}

/// An error raised while talking to an MCP endpoint.
public struct MCPError: Error, Sendable, CustomStringConvertible {
    public let description: String
    /// Decoded refusal payload when the error was a tool-level refusal or a
    /// -32602 invalid_argument. Nil for transport errors and other JSON-RPC
    /// errors that do not carry a structured data payload.
    public let refusal: MCPRefusalInfo?

    public init(description: String, refusal: MCPRefusalInfo? = nil) {
        self.description = description
        self.refusal = refusal
    }
}

/// A loosely-typed JSON value, used both to build tool-call arguments and
/// to parse tool results from servers whose result shapes are not known at
/// compile time (the benchmarker is engine-agnostic).
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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
    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// The string payload, if this value is a string.
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// The numeric payload, if this value is a number. JSON-RPC ids decode as
    /// numbers; the stdio response matcher compares this against the request id.
    public var numericValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }
}

/// One parsed result item: its id (when the server returns one) and its
/// content (the searchable text). Both are optional so a server that returns
/// content without a stable id (e.g. a search-only server) and one that
/// returns an id without inline content both parse into the same shape.
public struct MCPResultItem: Sendable, Equatable {
    /// The item's stable id, when the server returns one. Nil for servers
    /// whose search results carry no stable id.
    public let id: String?
    /// The item's content / searchable text, when present.
    public let content: String?
}

/// One entry from the v2 `moot_drain_status` structured response.
/// Decoded from `structuredContent.data.drains[]`.
/// Each entry carries the lane name, its state word, and the pending work count.
public struct V2DrainEntry: Sendable, Equatable {
    /// Lane identifier, e.g. "corpus_encode", "dreaming", "subject_backfill".
    public let name: String
    /// State word from the server: "idle" or "draining".
    public let state: String
    /// Jobs waiting to start. > 0 means the lane has outstanding work.
    public let pending: Int
}

/// The parsed result of one tool call: the ordered list of result IDs (for
/// a query/list tool), the parsed result items (id + content, in order), the
/// id a write tool assigned (when the server mints its own), and the raw text
/// blocks the server returned (for diagnostics and for text parsing).
public struct MCPToolResult: Sendable {
    /// Result item IDs in the order the server returned them. Empty when the
    /// tool returned no identifiable items (the items may still carry content).
    public let orderedIDs: [String]
    /// The parsed result items, in order. Lets a caller read content even when
    /// the server returns no id, and read ids even when content is absent.
    public let items: [MCPResultItem]
    /// The id the target assigned to a just-written entry, parsed from a write
    /// response (MOOTx01 `filed memory <UUID>`). Nil for query/list results or
    /// servers that echo the caller's id.
    public let writeAssignedID: String?
    /// Raw text content blocks, concatenated in order.
    public let textBlocks: [String]
    /// True when the server flagged this result as a TOOL-LEVEL error
    /// (`isError: true` in the tools/call result). Distinct from a JSON-RPC
    /// protocol error, which `callTool` throws. A tool-level error still
    /// carries text blocks (the error message), so a parser that only reads
    /// text sees "zero results" — a measuring caller MUST check this flag or
    /// an invalid arm records zeros instead of failing loud (the fm-probe
    /// rejection test caught exactly that: an unknown shaped preset produced
    /// a recorded all-zero unit with exit 0).
    public let isError: Bool
    /// Decoded refusal payload when `isError` is true and `structuredContent.error`
    /// carried a recognised v2 refusal shape. Nil for non-error results and for
    /// tool-level errors where no structured error envelope was present.
    public let refusal: MCPRefusalInfo?
    /// The `structuredContent.meta.withheldBySensitivity` count, emitted only
    /// when the `report_withheld` global modifier was passed. Nil when absent.
    public let withheldBySensitivity: Int?
    /// Drawer count confirmed by `moot_json_import`, decoded from
    /// `structuredContent.data.drawers_written`. Nil for all other operations.
    /// Use this instead of parsing the text block — the v2 surface embeds
    /// the count in structured data only.
    public let drawersWritten: Int?
    /// Drain lane entries from `moot_drain_status`, decoded from
    /// `structuredContent.data.drains[]`. Nil for all other operations.
    /// Each entry carries name, state ("idle"/"draining"), and pending count.
    public let drainEntries: [V2DrainEntry]?
    /// Operation completion status from `structuredContent.meta.status`.
    /// "completed" means the operation returned a full result. Nil when absent.
    /// moot_dream sets this to "completed" when the dreaming cycle finished.
    public let metaStatus: String?

    public init(orderedIDs: [String], items: [MCPResultItem],
                writeAssignedID: String?, textBlocks: [String],
                isError: Bool = false,
                refusal: MCPRefusalInfo? = nil,
                withheldBySensitivity: Int? = nil,
                drawersWritten: Int? = nil,
                drainEntries: [V2DrainEntry]? = nil,
                metaStatus: String? = nil) {
        self.orderedIDs = orderedIDs
        self.items = items
        self.writeAssignedID = writeAssignedID
        self.textBlocks = textBlocks
        self.isError = isError
        self.refusal = refusal
        self.withheldBySensitivity = withheldBySensitivity
        self.drawersWritten = drawersWritten
        self.drainEntries = drainEntries
        self.metaStatus = metaStatus
    }
}

/// A client bound to one MCP endpoint. An actor so that JSON-RPC requests
/// over a single transport are serialized — request ids stay monotonic and
/// stdio reads/writes never interleave.
/// Per-call response deadlines, named by what the call IS rather than by a
/// number at the call site.
///
/// One connection-wide timeout cannot serve every operation: the ceiling that
/// keeps a slow retrain alive is the same ceiling that makes a crashed server
/// indistinguishable from a busy one on a status poll. These tiers exist so a
/// caller states the shape of the work and gets a matching failure time.
public enum MCPDeadline {

    /// Status and liveness calls the server answers from memory —
    /// `moot_drain_status`, `moot_estate_status`, `moot_estate_ping`.
    ///
    /// A live server answers these in milliseconds EVEN WHILE DRAINING, so a
    /// wait of seconds is already pathological. Short by design: this is the
    /// tier that turns "server is gone" into a fast, legible failure instead
    /// of a stall.
    public static let status: TimeInterval = 10

    /// The `initialize` handshake, which covers the server OPENING ITS ESTATE.
    ///
    /// UNBOUNDED, because the only correct answer to "how long should opening an
    /// estate take" is "as long as the estate takes". This was the status tier
    /// (10s) until 2026-08-18, on the premise that a live server answers
    /// immediately — true of a status call on a running server, false at
    /// startup, where the server cannot answer until the estate is open and
    /// its resident arrays are in memory. A 100,000-row landscape blew it, and
    /// raising the number to 1800 only moved the guess.
    ///
    /// LIVENESS COMES FROM THE PROCESS, NOT A CLOCK. The stdio session already
    /// fails every pending caller when the child exits or its pipe closes
    /// (`failAllPending`), so a dead binary still surfaces — as death, which is
    /// what it is. A caller that genuinely wants a ceiling passes a tighter
    /// `responseDeadline`; the `min` at the call site keeps it, which is what
    /// the timeout tests rely on.
    public static let handshake: TimeInterval = .infinity

    /// Ordinary reads and writes — capture, recall, search. Bounded work on a
    /// healthy estate, but genuinely variable with corpus size and load.
    public static let interactive: TimeInterval = 120

    /// The client-wide response ceiling when a call site names none. 120 s by
    /// default; `MOOT_BENCH_MCP_RESPONSE_DEADLINE` (whole seconds, > 0) raises
    /// it for estates whose FIRST search legitimately runs longer — an
    /// aggregate wing with 165,000 vector rows loads its resident arrays on
    /// that call, and the load is a property of the estate, not a fault.
    /// The Rust client has no per-response watchdog (its wait is bounded by
    /// process liveness only), so this override has no Rust twin.
    public static let defaultResponse: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["MOOT_BENCH_MCP_RESPONSE_DEADLINE"],
           let secs = Double(raw), secs > 0 {
            return secs
        }
        return 120
    }()

    /// Whole-corpus operations: `moot_reindex`, `moot_dream`, a large import.
    /// These legitimately run for minutes; a short ceiling here aborts real
    /// work rather than detecting a fault.
    public static let bulk: TimeInterval = 1800

    /// No ceiling: the call waits for the server, however long it takes.
    ///
    /// For work whose duration is a property of the MACHINE rather than of the
    /// protocol — building a landscape, ingesting a corpus — a client-side
    /// ceiling is a guess about disk and CPU speed, and a wrong guess fails a
    /// call whose work has already succeeded. That happened on 2026-08-17: a
    /// 100,000-row import had written every row and finished encoding when the
    /// ceiling fired. Liveness for these calls is the operator's to watch, not
    /// the client's to enforce; the lanes print progress as they go.
    ///
    /// A hung server still surfaces: the stdio session fails every pending
    /// caller when the child exits or the pipe closes.
    public static let unbounded: TimeInterval = .infinity
}

public actor MCPClient {
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
    /// endpoint and the request id. The default is `MCPDeadline.defaultResponse`
    /// (120 s unless MOOT_BENCH_MCP_RESPONSE_DEADLINE raises it); pass a shorter
    /// value during testing. The watchdog runs
    /// as a concurrent Task inside the actor, so it is safe under Swift 6 strict
    /// concurrency — the actor serialises all mutation of `pending` and
    /// `watchdogs`.
    let responseDeadline: TimeInterval

    public init(endpoint: EndpointConfig, urlSession: URLSession = .shared,
         responseDeadline: TimeInterval = MCPDeadline.defaultResponse) {
        self.endpoint = endpoint
        self.urlSession = urlSession
        self.responseDeadline = responseDeadline
    }

    /// Brings the transport up. For stdio this launches the process and
    /// performs the MCP `initialize` handshake; for sse it is a no-op
    /// because each POST is independent.
    public func connect() async throws {
        switch endpoint.transport {
        case .stdio(let command):
            try startStdioSession(command: command)
            // MCP requires an initialize call before tool calls. We send it
            // and ignore the capabilities payload — the benchmarker only
            // needs the verbMap tools, not capability negotiation.
            // Handshake: this ceiling covers the server opening its estate,
            // which scales with the estate rather than being immediate (see
            // MCPDeadline.handshake). It also decides how long a completely
            // dead binary takes to report, and those two pull in opposite
            // directions; the tier comment states which way the trade went.
            //
            // `min` with the client's own deadline, never a bare tier: a caller
            // that asked for a TIGHTER ceiling must keep it. The timeout tests
            // construct clients at 2s precisely so they do not sit for the
            // default, and a hardcoded tier here would silently overrule them.
            _ = try await sendRequest(method: "initialize", params: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("mcp-benchmarker"),
                    "version": .string("0.1.0"),
                ]),
            ]), deadline: min(MCPDeadline.handshake, responseDeadline))
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
    public func disconnect() {
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
    /// - Parameter deadline: how long to wait for THIS call before declaring
    ///   the server unresponsive. Defaults to the client's `responseDeadline`.
    ///
    ///   A per-call deadline exists because one number cannot serve every
    ///   operation. `moot_drain_status` is answered by a live server in
    ///   milliseconds even mid-drain, so waiting two minutes for it means a
    ///   crashed server looks like a busy one — that is exactly how a SynapseKit
    ///   SIGTRAP read as a ten-minute stall (2026-08-15). A `moot_reindex` over
    ///   100k rows legitimately takes minutes, so it cannot share that ceiling.
    ///   The LME lane already had to build clients at `responseDeadline: 1800`
    ///   to survive its slowest call, which made every status poll on that
    ///   client wait up to thirty minutes before reporting a dead server.
    ///
    ///   The knob belongs to the CALL, not the connection. `MCPDeadline` names
    ///   the tiers so call sites state intent rather than a magic number.
    public func callTool(_ name: String,
                  arguments: [String: JSONValue],
                  format: ResultFormat,
                  deadline: TimeInterval? = nil) async throws -> MCPToolResult {
        let params = JSONValue.object([
            "name": .string(name),
            "arguments": .object(arguments),
        ])
        let result = try await sendRequest(method: "tools/call", params: params, deadline: deadline)
        return Self.parseToolResult(result, format: format)
    }

    /// Lists the tools the server advertises (`tools/list`).
    ///
    /// Returns the raw JSON-RPC `result` value — standard MCP shape
    /// `{"tools":[{"name":…,"description":…,"inputSchema":…},…]}` — rather
    /// than a parsed struct, because the one consumer (the lme-agentic lane)
    /// forwards the entries VERBATIM to an external answering AI; a lossy
    /// intermediate struct would strip schema fields the AI needs.
    ///
    /// Security boundary: enumeration does not widen execution. The caller
    /// filters this list to a read-only allowlist before advertising it and
    /// refuses to execute anything outside that allowlist (see the file
    /// header and LMEAgenticRunner.swift).
    ///
    /// - Parameter deadline: response ceiling; defaults to the client's
    ///   `responseDeadline`. A live server answers `tools/list` from memory,
    ///   so `MCPDeadline.status` is the appropriate tier at call sites.
    public func listTools(deadline: TimeInterval? = nil) async throws -> JSONValue {
        try await sendRequest(method: "tools/list", params: .object([:]), deadline: deadline)
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
    public func pipelinedCallTools(_ calls: [(name: String, arguments: [String: JSONValue])],
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
    private func sendRequest(method: String,
                             params: JSONValue,
                             deadline: TimeInterval? = nil) async throws -> JSONValue {
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
            response = try await awaitResponse(id: id, deadline: deadline)
        case .sse(let url):
            let responseData = try await sendHTTP(requestData, to: url)
            response = try JSONDecoder().decode(JSONValue.self, from: responseData)
        }

        if let error = response["error"] {
            let message = error["message"]?.stringValue ?? "unknown JSON-RPC error"
            // Attempt to decode -32602 (invalid_argument) structured data from
            // error.data per the ARIA v2 catalog shared_vectors.invalid_argument_jsonrpc
            // shape: { code, message, path (opt), allowed (opt), correction (opt) }.
            // The refusal code and extended fields are attached to the thrown MCPError
            // so the caller can surface the class instead of a flat string.
            var refusal: MCPRefusalInfo?
            if let code = error["code"]?.numericValue.map(Int.init),
               code == -32602,
               let data = error["data"] {
                let refusalCode = data["code"]?.stringValue ?? "invalid_argument"
                let refusalMessage = data["message"]?.stringValue ?? message
                // `allowed` arrives as a JSON array of strings on the wire (not a plain string).
                // Extract each element via stringValue; a non-array or absent field yields nil.
                let allowedValues: [String]? = {
                    guard case .array(let arr) = data["allowed"] else { return nil }
                    let strings = arr.compactMap { $0.stringValue }
                    return strings.isEmpty ? nil : strings
                }()
                refusal = MCPRefusalInfo(
                    code: refusalCode,
                    message: refusalMessage,
                    path: data["path"]?.stringValue,
                    allowed: allowedValues,
                    correction: data["correction"]?.stringValue)
            }
            let classTag = refusal.map { " [class=\($0.code)]" } ?? ""
            throw MCPError(
                description: "JSON-RPC error from \(endpoint.name)\(classTag): \(message)",
                refusal: refusal)
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
    /// `VAR=value` token in the command sets that variable for the child (the
    /// product's feature switches such as `MOOTX01_VAULT=1`); the estate itself
    /// is selected by the `--db <scratch>` argument. Operator-supplied;
    /// CLI-argument trust level.
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
                    // The server's stderr is where it says why it could not
                    // start. Discarding it turned every server-side failure —
                    // a key it cannot find, an estate it cannot open — into an
                    // unexplained handshake timeout, with the cause visible
                    // only by running the same command by hand.
                    error: .fileDescriptor(.standardError, closeAfterSpawningProcess: false)
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
    private func awaitResponse(id: Int, deadline overrideDeadline: TimeInterval? = nil) async throws -> JSONValue {
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
            let deadline = overrideDeadline ?? responseDeadline
            // An unbounded (or non-positive) deadline arms no watchdog at all:
            // the caller waits for the server or for the session to fail.
            guard deadline.isFinite, deadline > 0 else { return }
            let endpointName = endpoint.name
            let watchdog = Task { [self] in
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                // If cancelled (response arrived), Task.isCancelled is true and
                // we skip the timeout path entirely.
                guard !Task.isCancelled else { return }
                self.timeoutPending(id: id, endpointName: endpointName)
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
    ///     content from `contentKey`. Used by external paginating servers that
    ///     return item arrays with named id and content fields.
    ///   - `.mootText`: MOOTx01 plain text. A search result is `found N`
    ///     followed by `<UUID>  [location]  <content>` per ranked line; a write
    ///     result is `filed memory <UUID>` (the target-assigned id).
    ///
    /// Text blocks are always returned for diagnostics regardless of format.
    public static func parseToolResult(_ result: JSONValue, format: ResultFormat) -> MCPToolResult {
        var textBlocks: [String] = []
        if case .array(let blocks) = result["content"] {
            for block in blocks {
                if block["type"]?.stringValue == "text", let text = block["text"]?.stringValue {
                    textBlocks.append(text)
                }
            }
        }

        // Tool-level error flag (MCP tools/call `isError`). Preserved on the
        // parsed result so measuring callers can fail loud — see MCPToolResult.
        var isError = false
        if case .bool(let flag) = result["isError"] { isError = flag }

        // Decode structuredContent.error when isError is true — ARIA v2 tool-level
        // refusals carry { code, message, recovery (opt), retryable (opt) }.
        // Catalog shapes: memory_not_found (no recovery), invalid_argument (with fields).
        var refusal: MCPRefusalInfo?
        if isError, let sc = result["structuredContent"], let err = sc["error"] {
            if let code = err["code"]?.stringValue {
                refusal = MCPRefusalInfo(
                    code: code,
                    message: err["message"]?.stringValue ?? code,
                    recovery: err["recovery"]?.stringValue,
                    retryable: {
                        if case .bool(let b) = err["retryable"] { return b }
                        return nil
                    }())
            }
        }

        let parsed: MCPToolResult
        switch format {
        case let .jsonObjects(idKey, contentKey):
            parsed = parseJSONObjects(result: result, textBlocks: textBlocks,
                                      idKey: idKey, contentKey: contentKey)
        case .mootText:
            parsed = parseMootText(textBlocks: textBlocks)
        case .mootV2:
            parsed = parseMootV2(result: result, textBlocks: textBlocks)
        }
        guard isError else { return parsed }
        return MCPToolResult(orderedIDs: parsed.orderedIDs, items: parsed.items,
                             writeAssignedID: parsed.writeAssignedID,
                             textBlocks: parsed.textBlocks, isError: true,
                             refusal: refusal,
                             withheldBySensitivity: parsed.withheldBySensitivity,
                             drawersWritten: parsed.drawersWritten,
                             drainEntries: parsed.drainEntries,
                             metaStatus: parsed.metaStatus)
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
    /// array-valued key (e.g. a `results` / `drawers` / `items` wrapper). An
    /// object is kept when it carries the id key (if one is named) or the
    /// content key — so a server that returns content without ids still parses.
    /// Returns nil when no qualifying array is found.
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
        // wrappers like `drawers`/`results`); if none qualifies, treat the
        // object ITSELF as a single record when it carries the id or content
        // key. The single-record case is a `fetch` result (a per-id endpoint
        // returns one bare object with full content, not an array), which a
        // faithful transfer must read.
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

    // MARK: - ARIA v2 structured result parser

    /// Parses MOOTx01 ARIA v2 structured tool results from `structuredContent`.
    ///
    /// The v2 surface wraps every response in:
    ///   `{ surface_version, tool, data, meta }` inside `structuredContent`.
    ///
    /// Handled response shapes (by operation category):
    ///
    ///   moot_memory_search, moot_synthesize, moot_recall_*:
    ///     data.results[] — each item carries `memory_id` or `id` as the
    ///     stable identifier and `excerpt` or `bestSpan` as the scorable text.
    ///     `memory_id` takes priority over `id` when both are present.
    ///
    ///   moot_file_memory (write receipt):
    ///     data.memory_id — the UUID assigned by the server; becomes
    ///     `writeAssignedID`.
    ///
    ///   moot_memory_get, moot_memory_list (batched fetches):
    ///     data.memories[] — each item carries `memory_id` as id and
    ///     `content` as the full body text.
    ///
    /// Text blocks from the `content` array are always returned alongside
    /// the structured result so runners that read `textBlocks` for diagnostic
    /// text (e.g. `discrimination: low` signals) continue to work unchanged.
    ///
    /// When no recognised `structuredContent` shape is found, returns empty
    /// items with the text blocks — letting the caller fall back to text-based
    /// scoring if needed.
    private static func parseMootV2(result: JSONValue, textBlocks: [String]) -> MCPToolResult {
        // v2 envelope: structuredContent must be present; data may be absent for
        // some operations (e.g. purely meta-only responses).
        guard let structured = result["structuredContent"] else {
            return MCPToolResult(orderedIDs: [], items: [], writeAssignedID: nil, textBlocks: textBlocks)
        }

        // structuredContent.meta fields — decoded before the data guard so they
        // are available on the data-absent early return path.
        //
        // withheldBySensitivity: emitted only when report_withheld is passed.
        let withheld: Int? = {
            guard let meta = structured["meta"],
                  case .number(let n) = meta["withheldBySensitivity"] else { return nil }
            return Int(n)
        }()
        // meta.status: operation completion signal ("completed" when the op finished).
        // moot_dream sets this; other write ops may set it too.
        let metaStatus: String? = structured["meta"]?["status"]?.stringValue

        guard let data = structured["data"] else {
            return MCPToolResult(orderedIDs: [], items: [], writeAssignedID: nil,
                                 textBlocks: textBlocks, withheldBySensitivity: withheld,
                                 metaStatus: metaStatus)
        }

        // moot_json_import write receipt: data.drawers_written is the confirmed count.
        // The v2 surface puts the count in structured data only — not in text.
        let drawersWritten: Int? = {
            guard case .number(let n) = data["drawers_written"] else { return nil }
            return Int(n)
        }()

        // moot_drain_status: data.drains[] carries per-lane drain state.
        // Each entry: { name: String, state: "idle"|"draining", pending: Int }.
        let drainEntries: [V2DrainEntry]? = {
            guard case .array(let arr) = data["drains"] else { return nil }
            let entries = arr.compactMap { entry -> V2DrainEntry? in
                guard let name = entry["name"]?.stringValue,
                      let state = entry["state"]?.stringValue else { return nil }
                let pending: Int = {
                    guard case .number(let n) = entry["pending"] else { return 0 }
                    return Int(n)
                }()
                return V2DrainEntry(name: name, state: state, pending: pending)
            }
            // Return nil (not empty array) only when key is absent; an empty
            // array is a valid "no lanes registered" structured response.
            return entries
        }()

        // moot_file_memory write receipt: data.memory_id is the assigned UUID.
        if case .string(let uuid) = data["memory_id"],
           UUID(uuidString: uuid) != nil {
            // A scalar memory_id at the data root is the write-receipt shape,
            // not a search result — distinguish it from data.results items.
            // Double check: if data also has "results" or "memories", this is
            // NOT a bare write receipt, so fall through to array handling.
            if data["results"] == nil && data["memories"] == nil {
                return MCPToolResult(orderedIDs: [], items: [],
                                     writeAssignedID: uuid, textBlocks: textBlocks,
                                     withheldBySensitivity: withheld,
                                     drawersWritten: drawersWritten,
                                     drainEntries: drainEntries,
                                     metaStatus: metaStatus)
            }
        }

        // moot_memory_search / moot_recall_*: data.results[]
        if case .array(let results) = data["results"] {
            let items: [MCPResultItem] = results.map { item in
                // memory_id (search) takes priority over id (recall lenses).
                let id = item["memory_id"]?.stringValue ?? item["id"]?.stringValue
                // excerpt (search) preferred; bestSpan (recall) as fallback; then subject.
                let content = item["excerpt"]?.stringValue
                    ?? item["bestSpan"]?.stringValue
                    ?? item["subject"]?.stringValue
                return MCPResultItem(id: id, content: content)
            }
            return MCPToolResult(
                orderedIDs: items.compactMap(\.id),
                items: items,
                writeAssignedID: nil,
                textBlocks: textBlocks,
                withheldBySensitivity: withheld,
                drawersWritten: drawersWritten,
                drainEntries: drainEntries,
                metaStatus: metaStatus)
        }

        // moot_memory_get / moot_memory_list: data.memories[]
        if case .array(let memories) = data["memories"] {
            let items: [MCPResultItem] = memories.map { item in
                let id = item["memory_id"]?.stringValue
                let content = item["content"]?.stringValue
                    ?? item["subject"]?.stringValue
                return MCPResultItem(id: id, content: content)
            }
            return MCPToolResult(
                orderedIDs: items.compactMap(\.id),
                items: items,
                writeAssignedID: nil,
                textBlocks: textBlocks,
                withheldBySensitivity: withheld,
                drawersWritten: drawersWritten,
                drainEntries: drainEntries,
                metaStatus: metaStatus)
        }

        // Unrecognised or multi-purpose data shape (e.g. moot_json_import,
        // moot_drain_status, moot_dream) — return text blocks for diagnostics
        // alongside whichever structured fields were decoded above.
        return MCPToolResult(orderedIDs: [], items: [], writeAssignedID: nil,
                             textBlocks: textBlocks, withheldBySensitivity: withheld,
                             drawersWritten: drawersWritten,
                             drainEntries: drainEntries,
                             metaStatus: metaStatus)
    }

    /// Parses MOOTx01's plain-text results. Each line beginning with a UUID
    /// token is one item: a 2.0.0 dense row
    /// (`<UUID> · <subject> · <bestSpan> · <sscFacts> · <eventTime> · <score>`)
    /// or the single-record shape (`<UUID>  [location] <content>`) for a search hit,
    /// and `filed memory <UUID>` for a write. The first UUID found in a write
    /// response becomes `writeAssignedID`; search-hit UUIDs become ordered ids
    /// with their content (subject col only, not the metadata tail).
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
                // Search hit: a line that starts with a UUID token.
                guard let uuid = leadingUUID(of: line) else { continue }
                items.append(MCPResultItem(id: uuid, content: mootTextContent(of: line, uuid: uuid)))
            }
        }

        return MCPToolResult(orderedIDs: items.compactMap(\.id),
                             items: items,
                             writeAssignedID: writeAssignedID,
                             textBlocks: textBlocks)
    }

    /// The content of one MOOTx01 search-hit line.
    ///
    /// A search reply arrives in the 2.0.0 dense-row shape
    /// `<UUID> · <subject> · <bestSpan> · <sscFacts> · <eventTime> · <score>`,
    /// where the SUBJECT (col 2) carries the record's text and the fields after
    /// it are metadata. Only the subject is content for scoring purposes.
    /// Returning the whole remainder made every gauntlet figure read zero on
    /// 2026-08-17: the product returned the needle at rank 1, and the scorer —
    /// which identifies a hit by comparing content — was handed the full
    /// metadata tail as well, so it matched nothing.
    ///
    /// A line with no dense-row separator is the single-record shape, whose
    /// content follows the `[location]` bracket when one is present.
    ///
    /// The subject sentinels follow the dense-row format sentinel conventions.
    private static func mootTextContent(of line: String, uuid: String) -> String? {
        let separator = " \u{00B7} "  // space · space (U+00B7 MIDDLE DOT)
        let parts = line.components(separatedBy: separator)
        if parts.count > 1 {
            let subject = parts[1].trimmingCharacters(in: .whitespaces)
            return (subject == "(no subject)" || subject == "-" || subject.isEmpty) ? nil : subject
        }
        let afterUUID = line.dropFirst(uuid.count).trimmingCharacters(in: .whitespaces)
        if let close = afterUUID.firstIndex(of: "]") {
            return String(afterUUID[afterUUID.index(after: close)...])
                .trimmingCharacters(in: .whitespaces)
        }
        return afterUUID
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
