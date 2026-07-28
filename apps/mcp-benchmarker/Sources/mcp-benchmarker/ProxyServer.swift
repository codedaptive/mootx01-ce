import Foundation

// ProxyServer.swift — the `serve` mode + ProxyRunReport (SPEC §4.5).
//
// ProxyRunReport is the live head-to-head artifact emitted on `serve` shutdown:
// per-backend latency series, Jaccard/Kendall divergence summary,
// secondary-failure count, and the worst-diverging tail with both rankings
// retained for inspection.

// MARK: - ProxyRunReport (SPEC §4.5)

/// The consolidated head-to-head report emitted when `serve` shuts down.
/// Assembled from state accumulated in `ProxyServer` over the session; emitted
/// to stderr (and JSON when `--stats-store` is given). This is the live
/// head-to-head artifact — the settled measurement output of the proxy path.
struct ProxyRunReport: Sendable {
    /// Latency samples (seconds) from the primary backend over the session.
    let primaryLatencySeries: [Double]
    /// Latency samples (seconds) from the secondary backend over the session.
    let secondaryLatencySeries: [Double]
    /// Mean Jaccard set divergence across all recall comparisons.
    let jaccardMean: Double
    /// Mean Kendall rank divergence across all recall comparisons.
    let kendallRankMean: Double
    /// Number of recall comparisons that contributed to the divergence means.
    let divergenceSampleCount: Int
    /// Number of secondary-backend calls that failed (threw or returned no data).
    /// These are silently swallowed per the non-fatal secondary-failure rule
    /// (SPEC §4.3), but counted here so the report is honest about data gaps.
    let secondaryFailureCount: Int
    /// The worst-diverging tail sample, retained for inspection. nil when no
    /// divergence samples were recorded.
    let worstDivergingTail: DivergingTail?

    /// A single worst-diverging recall comparison — the sample with the highest
    /// Jaccard divergence, with both full rankings retained for inspection.
    struct DivergingTail: Sendable {
        let jaccardDivergence: Double
        let primaryRanking: [String]
        let secondaryRanking: [String]
    }

    /// Convenience: mean latency (seconds) over the primary samples, or 0.
    var primaryMeanLatency: Double {
        guard !primaryLatencySeries.isEmpty else { return 0 }
        return primaryLatencySeries.reduce(0, +) / Double(primaryLatencySeries.count)
    }

    /// Convenience: mean latency (seconds) over the secondary samples, or 0.
    var secondaryMeanLatency: Double {
        guard !secondaryLatencySeries.isEmpty else { return 0 }
        return secondaryLatencySeries.reduce(0, +) / Double(secondaryLatencySeries.count)
    }

    /// Renders the report as a human-readable block for stderr.
    /// Labelled as "live head-to-head" (SPEC §6b, §10).
    func rendered(primaryName: String, secondaryName: String) -> String {
        var out = "[serve] live head-to-head run report\n"
        out += String(format: "  primary   (%@): n=%d  mean %.2f ms\n",
                      primaryName as NSString, primaryLatencySeries.count,
                      primaryMeanLatency * 1000)
        out += String(format: "  secondary (%@): n=%d  mean %.2f ms\n",
                      secondaryName as NSString, secondaryLatencySeries.count,
                      secondaryMeanLatency * 1000)
        if secondaryFailureCount > 0 {
            out += "  secondary failures (non-fatal): \(secondaryFailureCount)\n"
        }
        if divergenceSampleCount > 0 {
            out += String(format: "  divergence (n=%d):  jaccard set %.4f   kendall rank %.4f\n",
                          divergenceSampleCount, jaccardMean, kendallRankMean)
        }
        if let tail = worstDivergingTail {
            out += String(format: "  worst-diverging tail (jaccard %.4f):\n", tail.jaccardDivergence)
            out += "    primary:   \(tail.primaryRanking.prefix(5).joined(separator: ", "))\n"
            out += "    secondary: \(tail.secondaryRanking.prefix(5).joined(separator: ", "))\n"
        }
        return out
    }
}

// MARK: -

// ProxyServer.swift — the `serve` mode: a transparent passthrough MCP server.
//
// The client (Claude Code, an agent, anything that speaks MCP) points its
// stdio MCP transport at the benchmarker INSTEAD of at mootx01/MemPalace. The
// benchmarker then:
//
//   1. Forwards every client message to the PRIMARY backend verbatim and
//      returns the primary's response unchanged. Ids are preserved end-to-end,
//      so the client cannot tell it is not talking to the backend directly —
//      this is the "non-invasive" contract: nothing breaks for the client, and
//      no change is made to mootx01 / MemPalace / the client.
//
//   2. Optionally MIRRORS each `tools/call` to a SECONDARY backend (fire and
//      time; the secondary's response is NOT returned to the client). For a
//      query/recall call (the configured query tool on either side) it also
//      computes primary-vs-secondary divergence (Jaccard set + Kendall rank).
//
//   3. Maintains rolling/standing stats (latency per backend per method,
//      counts, divergence) over the whole session, optionally flushing them to
//      the ObserverSink stats store so moot-mgr can dashboard them.
//
// This realizes the spec's "serve mode (production-shadow path)" and the
// migration mirror as a PROXY, not by forking inside ARIA. Example: a MemPalace
// user keeps working (primary=MemPalace) while mootx01 is shadowed and compared
// (secondary=mootx01) — the adoption on-ramp. Reverse the roles to A/B the
// other way.
//
// SAFETY (mirror-write rule): mirroring a `tools/call` re-issues the SAME call
// — including writes — to the secondary. Writing to the secondary is only safe
// when the secondary is a fresh/scratch backend (the on-ramp case: shadow a new
// mootx01 estate). If the secondary is a real DB, the operator must run
// read-only mirroring (`--mirror-reads-only`) so only query/recall calls are
// mirrored and no write ever reaches the real secondary. This is enforced here,
// not left to documentation.

/// Raw, verbatim, id-preserving stdio JSON-RPC forwarder to one MCP backend.
///
/// Distinct from `MCPClient`: that actor reassigns request ids and only knows
/// the verbMap tools. The proxy must preserve the client's exact ids and pass
/// arbitrary methods (initialize, tools/list, tools/call, notifications)
/// through untouched, so it needs this lower-level forwarder.
actor RawMCPBackend {
    let name: String
    private let command: String

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputHandle: FileHandle?
    private var outputBuffer = Data()

    init(name: String, command: String) {
        self.name = name
        self.command = command
    }

    /// Expands a leading `~` (home) and `$VAR` references (from the parent
    /// environment) in a command token, so backend configs can use portable
    /// paths (`~/.mootx01/bin/mootx01`, `$ARIA_BIN`) instead of hardcoded
    /// absolute paths. `/usr/bin/env` performs no such expansion, so we do it.
    static func expandToken(_ token: String, environment: [String: String]) -> String {
        var t = token
        if let re = try? NSRegularExpression(pattern: #"\$([A-Za-z_][A-Za-z0-9_]*)"#) {
            let ns = t as NSString
            var out = ""
            var last = 0
            for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                out += environment[ns.substring(with: m.range(at: 1))] ?? ""
                last = m.range.location + m.range.length
            }
            out += ns.substring(from: last)
            t = out
        }
        if t.hasPrefix("~") { t = (t as NSString).expandingTildeInPath }
        return t
    }

    /// Launches the backend process. The command is operator-supplied and
    /// treated at CLI-argument trust level (same boundary as MCPClient): it is
    /// split on whitespace, each token is `~`/`$VAR`-expanded, and run via
    /// `/usr/bin/env`, so an env-var prefix (e.g. `MOOTX01_DATA_DIR=/tmp/...
    /// ~/.mootx01/bin/mootx01`) is honored.
    func start() throws {
        let env = ProcessInfo.processInfo.environment
        let parts = command.split(separator: " ").map { Self.expandToken(String($0), environment: env) }
        guard let program = parts.first else {
            throw MCPError(description: "empty command for backend \(name)")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [program] + parts.dropFirst()
        let input = Pipe()
        let output = Pipe()
        proc.standardInput = input
        proc.standardOutput = output
        try proc.run()
        self.process = proc
        self.inputPipe = input
        self.outputHandle = output.fileHandleForReading
    }

    /// Tears the backend down. Safe to call more than once.
    func stop() {
        inputPipe?.fileHandleForWriting.closeFile()
        process?.terminate()
        process = nil
        inputPipe = nil
        outputHandle = nil
        outputBuffer.removeAll()
    }

    /// Sends one already-encoded JSON-RPC message (a request with an id) and
    /// returns the backend's response bytes verbatim. The actor serializes
    /// calls, so a response is matched to its request by ordering on the single
    /// transport — the benchmarker proxies one client request at a time.
    func sendAndReceive(_ message: Data) async throws -> Data {
        guard let input = inputPipe, let output = outputHandle else {
            throw MCPError(description: "backend \(name) not started")
        }
        var line = message
        line.append(0x0A)
        input.fileHandleForWriting.write(line)
        return try await readLine(from: output)
    }

    /// Sends a JSON-RPC notification (no id, no response expected).
    func sendNotification(_ message: Data) throws {
        guard let input = inputPipe else {
            throw MCPError(description: "backend \(name) not started")
        }
        var line = message
        line.append(0x0A)
        input.fileHandleForWriting.write(line)
    }

    /// Reads one newline-delimited message from the backend stdout.
    private func readLine(from handle: FileHandle) async throws -> Data {
        while true {
            if let nl = outputBuffer.firstIndex(of: 0x0A) {
                let lineData = outputBuffer[outputBuffer.startIndex..<nl]
                outputBuffer.removeSubrange(outputBuffer.startIndex...nl)
                if lineData.isEmpty { continue }
                return Data(lineData)
            }
            let chunk = await readAvailableData(from: handle)
            if chunk.isEmpty {
                throw MCPError(description: "backend \(name) closed its stream")
            }
            outputBuffer.append(chunk)
        }
    }

    /// One-shot async read of the next stdout chunk without blocking the actor
    /// executor — same detached-blocking-read pattern as MCPClient.readAvailableData
    /// (the readability-handler source leaks continuations under repeated reads).
    private func readAvailableData(from handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let data = handle.availableData
                continuation.resume(returning: data)
            }
        }
    }
}

// MARK: - ProxyReportAccumulator (per-session run-report state)

/// Accumulates the state needed to assemble a `ProxyRunReport` at session end.
///
/// Lives alongside the existing `RollingStats` (which drives the periodic
/// heartbeat snapshots and the stats store). `RollingStats` is left unchanged;
/// this actor carries the three additional fields that `ProxyRunReport` needs
/// but `RollingStats` does not: per-session latency lists (unbounded — a serve
/// session is expected to be short; a long session should use the rolling
/// window in `RollingStats`), the secondary failure count, and the worst-
/// diverging tail (the single sample with the highest Jaccard divergence).
actor ProxyReportAccumulator {
    private var primarySamples: [Double] = []
    private var secondarySamples: [Double] = []
    private var jaccardSum: Double = 0
    private var kendallSum: Double = 0
    private var divergenceCount: Int = 0
    private var failureCount: Int = 0
    private var worstJaccard: Double = -1
    private var worstTailPrimary: [String] = []
    private var worstTailSecondary: [String] = []

    func recordPrimary(_ seconds: Double) { primarySamples.append(seconds) }
    func recordSecondary(_ seconds: Double) { secondarySamples.append(seconds) }
    func recordFailure() { failureCount += 1 }

    func recordDivergence(jaccard: Double, kendall: Double,
                          primaryRanking: [String], secondaryRanking: [String]) {
        jaccardSum += jaccard
        kendallSum += kendall
        divergenceCount += 1
        if jaccard > worstJaccard {
            worstJaccard = jaccard
            worstTailPrimary = primaryRanking
            worstTailSecondary = secondaryRanking
        }
    }

    /// Assembles the immutable `ProxyRunReport` from accumulated state.
    func buildReport() -> ProxyRunReport {
        let n = max(divergenceCount, 1)
        let tail: ProxyRunReport.DivergingTail? = divergenceCount > 0 ? .init(
            jaccardDivergence: worstJaccard,
            primaryRanking: worstTailPrimary,
            secondaryRanking: worstTailSecondary
        ) : nil
        return ProxyRunReport(
            primaryLatencySeries: primarySamples,
            secondaryLatencySeries: secondarySamples,
            jaccardMean: divergenceCount == 0 ? 0 : jaccardSum / Double(n),
            kendallRankMean: divergenceCount == 0 ? 0 : kendallSum / Double(n),
            divergenceSampleCount: divergenceCount,
            secondaryFailureCount: failureCount,
            worstDivergingTail: tail
        )
    }
}

// MARK: - MirrorCallType

/// The classified call type for a tools/call message, matched against a
/// primary's verbMap. Used by the translation layer to route the mirror
/// call to the correct secondary verb and argument keys.
enum MirrorCallType: Equatable {
    case write
    case query
    case list
    case fetch
}

/// The passthrough MCP proxy server.
struct ProxyServer {
    let primary: RawMCPBackend
    let primaryName: String
    let primaryFormat: ResultFormat

    /// The shadow backend, or nil for a pure passthrough run (no mirroring).
    let secondary: RawMCPBackend?
    let secondaryName: String?
    let secondaryFormat: ResultFormat?

    /// When true, only query/recall `tools/call`s are mirrored to the secondary
    /// — never writes. Required when the secondary is a real DB so a mirrored
    /// write cannot mutate it.
    let mirrorReadsOnly: Bool

    /// The primary endpoint's verbMap — used to classify incoming client calls
    /// by call type and to extract variable arguments.
    let primaryVerbMap: EndpointConfig.VerbMap
    /// The secondary endpoint's verbMap — used to build the translated
    /// tools/call that goes to the secondary (secondary tool name + arg keys +
    /// constantArgs). Nil when no secondary is configured.
    let secondaryVerbMap: EndpointConfig.VerbMap?

    let stats: RollingStats
    /// Accumulates the per-session state for the consolidated `ProxyRunReport`
    /// emitted on shutdown. Tracks primary/secondary latency series, secondary
    /// failure count, and worst-diverging tail — fields `RollingStats` (which
    /// uses a capped sliding window for the heartbeat path) does not carry.
    let reportAccumulator: ProxyReportAccumulator

    /// Running counter for fresh secondary-request ids. Starts at 1 and
    /// increments per mirrored call so ids on the secondary transport are
    /// distinct and never reuse the client's id. Mutable because `run` is
    /// the only call site and it is called on a `var`.
    var nextSecondaryID: Int = 1

    init(primary: RawMCPBackend,
         primaryName: String,
         primaryFormat: ResultFormat,
         secondary: RawMCPBackend?,
         secondaryName: String?,
         secondaryFormat: ResultFormat?,
         mirrorReadsOnly: Bool,
         primaryVerbMap: EndpointConfig.VerbMap,
         secondaryVerbMap: EndpointConfig.VerbMap?,
         stats: RollingStats,
         reportAccumulator: ProxyReportAccumulator) {
        self.primary = primary
        self.primaryName = primaryName
        self.primaryFormat = primaryFormat
        self.secondary = secondary
        self.secondaryName = secondaryName
        self.secondaryFormat = secondaryFormat
        self.mirrorReadsOnly = mirrorReadsOnly
        self.primaryVerbMap = primaryVerbMap
        self.secondaryVerbMap = secondaryVerbMap
        self.stats = stats
        self.reportAccumulator = reportAccumulator
        self.nextSecondaryID = 1
    }

    /// Runs the proxy until the client closes our stdin (EOF). Reads client
    /// JSON-RPC lines from `clientIn`, forwards to the primary, writes the
    /// primary's response to `clientOut`, and mirrors `tools/call`s to the
    /// secondary when configured.
    ///
    /// Returns the assembled `ProxyRunReport` for the session.
    @discardableResult
    mutating func run(clientIn: FileHandle, clientOut: FileHandle) async throws -> ProxyRunReport {
        var buffer = Data()
        while true {
            // Read one client line.
            guard let line = try await Self.nextLine(from: clientIn, buffer: &buffer) else {
                break  // client closed stdin → shut down
            }
            try await handleClientMessage(line, clientOut: clientOut)
        }
        return await reportAccumulator.buildReport()
    }

    /// Handles one client message: forward to primary, return its response,
    /// mirror tools/call to secondary (with verbMap translation).
    private mutating func handleClientMessage(_ line: Data, clientOut: FileHandle) async throws {
        // Parse just enough to classify: method, id presence, tool name.
        let parsed = try? JSONDecoder().decode(JSONValue.self, from: line)
        let method = parsed?["method"]?.stringValue
        let hasID = parsed?["id"] != nil

        // A notification (no id) gets no response; forward to primary and,
        // when relevant, mirror — but never wait on a reply.
        guard hasID else {
            try? await primary.sendNotification(line)
            return
        }

        // Forward to primary and time it; return the response verbatim.
        let primaryStart = DispatchTime.now()
        let response = try await primary.sendAndReceive(line)
        let primaryElapsed = Self.elapsedSeconds(since: primaryStart)
        await stats.recordLatency(primaryElapsed,
                                  label: "\(primaryName).\(method ?? "?")")
        // Also accumulate into the run-report series (separate from the rolling
        // sliding-window in stats — this series is unbounded for the session).
        if method == "tools/call" {
            await reportAccumulator.recordPrimary(primaryElapsed)
        }
        var outLine = response
        outLine.append(0x0A)
        clientOut.write(outLine)

        // Mirror only tools/call to the secondary (initialize is handled once
        // at startup; tools/list etc. need not hit the shadow).
        guard method == "tools/call", let secondary, let secondaryVerbMap else { return }

        let toolName = parsed?["params"]?["name"]?.stringValue ?? ""

        // Classify the call against the primary verbMap. Unclassifiable calls
        // (non-memory tools) are NOT blind-forwarded — skip the mirror entirely.
        guard let callType = Self.classifyMirrorCall(toolName: toolName,
                                                     primaryVerbMap: primaryVerbMap) else {
            return  // unclassifiable: skip, no failure recorded
        }

        // Assign a fresh id for the secondary (never reuse the client's id).
        let freshID = nextSecondaryID
        nextSecondaryID += 1

        // Translate the call through the secondary's verbMap. Returns nil when
        // the call should be skipped (e.g. mirrorReadsOnly + write call).
        guard let translatedLine = Self.translateMirrorCall(
            clientLine: line,
            callType: callType,
            primaryVerbMap: primaryVerbMap,
            secondaryVerbMap: secondaryVerbMap,
            mirrorReadsOnly: mirrorReadsOnly,
            freshID: freshID
        ) else { return }

        let isRecall = callType == .query
        let secondaryName = self.secondaryName ?? secondary.name
        await mirrorToSecondary(line: translatedLine, method: method,
                                isRecall: isRecall, secondary: secondary,
                                secondaryName: secondaryName,
                                primaryResponse: response)
    }

    /// Classifies a tools/call by tool name against the primary verbMap.
    /// Returns the call type, or nil when the tool name matches none of the
    /// primary's known verbs (unclassifiable → do not blind-forward).
    ///
    /// Exposed as `static` for direct unit testing without a live ProxyServer.
    static func classifyMirrorCall(toolName: String,
                                   primaryVerbMap: EndpointConfig.VerbMap) -> MirrorCallType? {
        if toolName == primaryVerbMap.write  { return .write }
        if toolName == primaryVerbMap.query  { return .query }
        if let list = primaryVerbMap.list, toolName == list { return .list }
        if let fetch = primaryVerbMap.fetch, toolName == fetch { return .fetch }
        return nil
    }

    /// Translates a primary-side tools/call into a secondary-side tools/call
    /// by extracting the variable argument(s) from the client's call under the
    /// primary's arg-role keys, then rebuilding the call with the secondary's
    /// tool name, arg keys, and constantArgs.
    ///
    /// Returns nil when the call should be skipped:
    ///   - `mirrorReadsOnly` is true and `callType` is `.write` or `.list`
    ///     (only query/recall calls are mirrored in read-only mode).
    ///   - The client line cannot be decoded as a valid JSON-RPC message.
    ///
    /// The returned Data is a complete newline-free JSON-RPC tools/call ready
    /// to hand to `RawMCPBackend.sendAndReceive`. The `freshID` becomes the
    /// JSON-RPC id — never the client's original id — so the secondary
    /// transport's id space stays disjoint from the client's.
    ///
    /// Exposed as `static` for direct unit testing without a live ProxyServer.
    static func translateMirrorCall(clientLine: Data,
                                    callType: MirrorCallType,
                                    primaryVerbMap: EndpointConfig.VerbMap,
                                    secondaryVerbMap: EndpointConfig.VerbMap,
                                    mirrorReadsOnly: Bool,
                                    freshID: Int) -> Data? {
        // Read-only mirror fence: skip writes and list calls (mutation paths).
        if mirrorReadsOnly && (callType == .write || callType == .list) { return nil }

        // Decode the client line to extract the arguments.
        guard let parsed = try? JSONDecoder().decode(JSONValue.self, from: clientLine),
              case .object(let clientArgs) = parsed["params"]?["arguments"] ?? .object([:]) else {
            return nil
        }

        // Build the secondary's argument dict:
        //   1. Start with the secondary's constantArgs (the fixed context it needs).
        //   2. Map the variable arg(s) from the primary's arg-role key to the
        //      secondary's arg-role key.
        var secondaryArgs: [String: JSONValue] = Dictionary(
            uniqueKeysWithValues: secondaryVerbMap.constantArgs.map { ($0.key, JSONValue.string($0.value)) }
        )

        switch callType {
        case .write:
            // Extract content under the primary's contentArg; inject under secondary's.
            if let value = clientArgs[primaryVerbMap.contentArg] {
                secondaryArgs[secondaryVerbMap.contentArg] = value
            }
        case .query:
            // Extract query text under the primary's queryArg; inject under secondary's.
            if let value = clientArgs[primaryVerbMap.queryArg] {
                secondaryArgs[secondaryVerbMap.queryArg] = value
            }
        case .list:
            // List calls carry pagination args; forward limit and offset if present.
            if let value = clientArgs[primaryVerbMap.listLimitArg] {
                secondaryArgs[secondaryVerbMap.listLimitArg] = value
            }
            if let value = clientArgs[primaryVerbMap.listOffsetArg] {
                secondaryArgs[secondaryVerbMap.listOffsetArg] = value
            }
        case .fetch:
            // Fetch calls carry an item id; forward it under the secondary's fetchIDArg.
            if let value = clientArgs[primaryVerbMap.fetchIDArg] {
                secondaryArgs[secondaryVerbMap.fetchIDArg] = value
            }
        }

        // Determine the secondary tool name for this call type.
        let secondaryTool: String
        switch callType {
        case .write:  secondaryTool = secondaryVerbMap.write
        case .query:  secondaryTool = secondaryVerbMap.query
        case .list:   secondaryTool = secondaryVerbMap.list ?? secondaryVerbMap.query
        case .fetch:  secondaryTool = secondaryVerbMap.fetch ?? secondaryVerbMap.query
        }

        // Assemble the translated JSON-RPC envelope with the fresh id.
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

    /// Sends the translated tools/call to the secondary, times it, and (for a
    /// query/recall call) scores divergence between the primary and secondary
    /// result orderings.
    private func mirrorToSecondary(line: Data,
                                   method: String?,
                                   isRecall: Bool,
                                   secondary: RawMCPBackend,
                                   secondaryName: String,
                                   primaryResponse: Data) async {
        let start = DispatchTime.now()
        let secondaryResponse: Data
        do {
            secondaryResponse = try await secondary.sendAndReceive(line)
        } catch {
            // A shadow failure must never affect the client; record nothing and
            // increment the failure count so the run report is honest about it.
            await reportAccumulator.recordFailure()
            return
        }
        let elapsed = Self.elapsedSeconds(since: start)
        await stats.recordLatency(elapsed, label: "\(secondaryName).\(method ?? "?")")
        await reportAccumulator.recordSecondary(elapsed)

        guard isRecall else { return }
        // Parse both responses' result payloads and score divergence. The two
        // servers mint ids in disjoint spaces, so divergence is computed over
        // normalized recall CONTENT order (the only shared identity), the same
        // basis BenchmarkEngine uses for the head-to-head.
        let primaryItems = Self.resultItems(from: primaryResponse, format: primaryFormat)
        let secondaryItems = Self.resultItems(
            from: secondaryResponse, format: secondaryFormat ?? primaryFormat)
        let pOrder = BenchmarkEngine.normalizedContentOrder(primaryItems)
        let sOrder = BenchmarkEngine.normalizedContentOrder(secondaryItems)
        let jaccard = jaccardDivergence(expected: Set(pOrder), got: Set(sOrder))
        let kendall = rankDivergence(expected: pOrder, got: sOrder)
        await stats.recordDivergence(jaccard: jaccard, kendallRank: kendall)
        await reportAccumulator.recordDivergence(jaccard: jaccard, kendall: kendall,
                                                 primaryRanking: pOrder,
                                                 secondaryRanking: sOrder)
    }

    /// Pulls the parsed result items out of a raw JSON-RPC response by reusing
    /// MCPClient's format-driven parser on the response's `result` value.
    private static func resultItems(from response: Data, format: ResultFormat) -> [MCPResultItem] {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: response),
              let result = value["result"] else { return [] }
        return MCPClient.parseToolResult(result, format: format).items
    }

    /// Monotonic elapsed seconds since a start mark.
    private static func elapsedSeconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    /// Reads one newline-delimited line from a FileHandle, buffering partial
    /// reads across calls. Returns nil at EOF (client closed stdin).
    static func nextLine(from handle: FileHandle, buffer: inout Data) async throws -> Data? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if lineData.isEmpty { continue }
                return Data(lineData)
            }
            let chunk = await Self.readChunk(from: handle)
            if chunk.isEmpty {
                // EOF. Return any trailing partial line, else nil.
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
