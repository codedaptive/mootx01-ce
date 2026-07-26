import Foundation
import IntellectusLib
import ObserverSink

// main.swift — CLI entry point.
//
// Hand-rolled argument parsing (swift-subprocess is the only external dep —
// no swift-argument-parser). Eight subcommands:
//
//   mcp-benchmarker transfer  --config c.json --manifest out.json [--limit N] [--no-verify] [--stats-store stats.sqlite]
//   mcp-benchmarker benchmark --config c.json --manifest out.json --report report.json [--compare-source] [--stats-store stats.sqlite]
//   mcp-benchmarker serve     --config c.json [--primary source|target] [--mirror] [--mirror-reads-only] [--report-interval N] [--stats-store stats.sqlite]
//   mcp-benchmarker pressure  --config c.json [--concurrency N] [--duration S] [--stats-store stats.sqlite]
//   mcp-benchmarker quality   --config c.json [--fixtures DIR] [--limit-clusters N]   (DIAGNOSTIC ONLY)
//   mcp-benchmarker report    --report report.json
//
// transfer  : paginate + full-content-fetch the source corpus, write it to the
//             target, verify each entry round-trips, record the manifest.
// benchmark : manifest-replay verification — verify the manifest against the
//             target, score divergence. DegeneracyGuard runs before scoring.
//             Output labelled "manifest-replay, not live head-to-head."
// serve     : PRIMARY measurement path. Run as a transparent passthrough MCP
//             proxy — forward the client to the primary verbatim, optionally
//             mirror+time+compare a shadow. Guard runs before run report.
// pressure  : synthetic 4-way load driver ({read,write}×{mootx01,MemPalace}).
// quality   : DIAGNOSTIC-ONLY corpus scorer. The scratch-ingest publish path
//             has been removed (SPEC §0 delta, FINDINGS-2026-06-07). Labelled
//             recall comes only from the transfer→benchmark path. No --report.
// report    : pretty-print an existing report.json.
//
// --stats-store : when given, the run emits its real metrics (capture
//             throughput + latency, recall latency, divergence) through
//             IntellectusLib into the ObserverSink PersistenceStatsSink at the
//             named SQLite path. The benchmarker is the first real emitter into
//             the shared stats store. The store's monitoring flag is enabled
//             for the duration of the run so samples land.

/// Usage text shown for `--help`, no subcommand, or a bad invocation.
func usageText() -> String {
    """
    mcp-benchmarker — benchmark, proxy, and load-test two MCP memory servers

    USAGE:
      mcp-benchmarker transfer  --config <c.json> --manifest <out.json> [--limit N] [--no-verify]
      mcp-benchmarker benchmark --config <c.json> --manifest <out.json> --report <report.json> [--compare-source]
      mcp-benchmarker serve     --config <c.json> [--primary source|target] [--mirror] [--mirror-reads-only] [--report-interval N]
      mcp-benchmarker pressure  --config <c.json> [--concurrency N] [--duration S]
      mcp-benchmarker quality   --config <c.json> [--fixtures <dir>] [--limit-clusters N]
      mcp-benchmarker gauntlet-corpus --seed <N> --out <dir> [--per-tier N] [--distractors N] [--tiers T1=a,T2=b,…]
      mcp-benchmarker gauntlet  --config <c.json> --corpus <dir> --run-label <label> [--out <dir>] [--k 1,5,10] [--limit N] [--quick] [--moot-only]
      mcp-benchmarker longmemeval --data-dir <dir> --variant s|m|oracle [--mootx01-binary <path>]
                        [--limit N] [--offset K] [--seed S] [--shared-estate] [--out <dir>]
      mcp-benchmarker report    --report <report.json>

      transfer/benchmark/serve/pressure accept --stats-store <stats.sqlite> to
      emit metrics to the ObserverSink stats store for moot-mgr dashboards.

      serve (primary):  run as a transparent passthrough MCP proxy. The client
        points its MCP transport here instead of at the backend directly. The
        primary's response is returned verbatim; the secondary (--mirror) is
        timed and compared. A DegeneracyGuard probe runs before the run report
        is emitted; a non-healthy verdict exits non-zero with a diagnostic and
        suppresses the comparison (SPEC §9).

      benchmark: manifest-replay verification. Issues each manifest entry's
        recall query to the live target, computes divergence. Output is labelled
        "manifest-replay, not live head-to-head." Guard applies.

      quality (DIAGNOSTIC-ONLY — NOT a published comparison): loads a corpus
        into both products and scores retrieval + filtering for internal
        diagnosis. The scratch-ingest publish path has been removed (SPEC §0
        delta); labelled recall comes only from the transfer→benchmark path.
        WRITES to both products — point them at SCRATCH backends only
        (MOOTX01_DATA_DIR=/tmp/..., mempalace --palace /tmp/...).
        --limit-clusters N runs a small slice for quick diagnosis.

      gauntlet --moot-only: run and score only the MOOT backend. MemPalace is
        not started, loaded, guarded, or reported. The corpus, MOOT load/dream,
        query arguments, scorer, and MOOT DegeneracyGuard are unchanged.

      longmemeval: provision a scratch mootx01 estate, ingest LongMemEval
        haystack sessions, and measure session-recall quality. The estate
        lifecycle (provision, teardown) is owned by the runner. The dataset
        must be pre-fetched with scripts/fetch-longmemeval.sh.
        --variant s|m|oracle     which LongMemEval variant file to load
        --data-dir <dir>         directory containing the variant JSON files
        --mootx01-binary <path>  path to the mootx01 binary (auto-discovered if absent)
        --limit N                run only the first N questions
        --offset K               skip the first K questions (default 0)
        --seed S                 seed for deterministic question order (default 20260725)
        --shared-estate          use one estate for all questions (methodology-affecting)
        --out <dir>              write results to <dir> (default: current directory)

    """
}

/// Returns the value following `--name`, or nil if the flag is absent or has
/// no value after it.
func optionValue(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// True when a bare flag (no value) is present.
func flagPresent(_ name: String, in args: [String]) -> Bool {
    args.contains(name)
}

/// A required option, or a usage error.
func requireOption(_ name: String, in args: [String]) throws -> String {
    guard let value = optionValue(name, in: args) else {
        throw MCPError(description: "missing required option \(name)")
    }
    return value
}

// MARK: - Stats-store instrumentation

/// Opens the ObserverSink stats store at `path`, installs a
/// `PersistenceStatsSink` into IntellectusLib, and enables monitoring (both
/// the IntellectusLib gate and the store's flag row) so emitted samples land.
///
/// Returns the opened store so the caller can close it after the run. The
/// dropbox id identifies the benchmarker's rows in the shared store.
func installStatsStore(at path: String) async throws -> StatsStore {
    let store = try StatsStore(url: URL(fileURLWithPath: path))
    try await store.open()
    // The benchmarker is the producer here, so it turns the store flag on for
    // the duration of its own run. In the manager pipeline the manager owns
    // this flag; for a standalone benchmark run the tool enables it itself.
    try await store.setMonitoringEnabled(true)
    let sink = PersistenceStatsSink(store: store, dropboxID: "mcp-benchmarker")
    Intellectus.install(sink: sink)
    Intellectus.setEnabled(true)
    return store
}

/// Lets the in-flight async sink Tasks drain before the store is closed.
/// `PersistenceStatsSink.receive(_:)` dispatches each insert to an unstructured
/// Task; a brief yield lets those complete so the rows are visible to a reader
/// (and the close below does not race the inserts).
func drainStatsSink() async {
    try? await Task.sleep(nanoseconds: 300_000_000)  // 300 ms
}

/// Emits the transfer's capture metrics into the stats store via IntellectusLib.
/// No-op (off-path, ~1 ns) when monitoring was never enabled.
func emitCaptureMetrics(_ summary: TimingSeries, count: Int, now: Double) {
    Intellectus.report(.metric(name: "benchmarker.capture.count",
                               value: Double(count), tags: [:], ts: now))
    Intellectus.report(.metric(name: "benchmarker.capture.latency_ms.mean",
                               value: summary.mean * 1000, tags: [:], ts: now))
    Intellectus.report(.metric(name: "benchmarker.capture.latency_ms.p95",
                               value: summary.p95 * 1000, tags: [:], ts: now))
    // Throughput: entries per second over the summed capture time.
    let totalSeconds = summary.mean * Double(count)
    let throughput = totalSeconds > 0 ? Double(count) / totalSeconds : 0
    Intellectus.report(.metric(name: "benchmarker.capture.throughput_per_s",
                               value: throughput, tags: [:], ts: now))
}

/// Emits the benchmark report's recall + divergence metrics into the stats
/// store via IntellectusLib. No-op when monitoring was never enabled.
func emitBenchmarkMetrics(_ report: BenchmarkReport, now: Double) {
    Intellectus.report(.metric(name: "benchmarker.recall.latency_ms.mean",
                               value: report.recall.mean * 1000, tags: [:], ts: now))
    Intellectus.report(.metric(name: "benchmarker.recall.latency_ms.p95",
                               value: report.recall.p95 * 1000, tags: [:], ts: now))
    Intellectus.report(.metric(name: "benchmarker.divergence.jaccard_set",
                               value: report.jaccardSetDivergence, tags: [:], ts: now))
    Intellectus.report(.metric(name: "benchmarker.divergence.mean_rank",
                               value: report.meanRankDivergence, tags: [:], ts: now))
    // Source recall latency lands only when --compare-source ran (sampleCount > 0).
    if report.sourceRecall.sampleCount > 0 {
        Intellectus.report(.metric(name: "benchmarker.source_recall.latency_ms.mean",
                                   value: report.sourceRecall.mean * 1000, tags: [:], ts: now))
    }
}

/// Builds and connects a client for one endpoint.
func connectedClient(for endpoint: EndpointConfig) async throws -> MCPClient {
    let client = MCPClient(endpoint: endpoint)
    try await client.connect()
    return client
}

/// transfer subcommand. Paginates + full-content-fetches the source, writes to
/// the target, and verifies each entry round-trips (unless `--no-verify`).
/// `--limit N` caps the transfer at N entries (sampling a large corpus; the cap
/// is reported, never silent).
func runTransfer(_ args: [String]) async throws {
    let configPath = try requireOption("--config", in: args)
    let manifestPath = try requireOption("--manifest", in: args)
    let limit = optionValue("--limit", in: args).flatMap(Int.init)
    let verify = !flagPresent("--no-verify", in: args)

    let config = try BenchmarkerConfig.load(from: URL(fileURLWithPath: configPath))
    let source = try await connectedClient(for: config.source)
    let target = try await connectedClient(for: config.target)
    defer { Task { await source.disconnect(); await target.disconnect() } }

    let engine = TransferEngine(
        source: source,
        target: target,
        sourceVerbs: config.source.verbMap,
        targetVerbs: config.target.verbMap,
        maxEntries: limit,
        verifyRoundTrip: verify
    )
    // Optional stats-store instrumentation: install the sink before the run so
    // capture metrics can be emitted after it.
    var statsStore: StatsStore?
    if let statsStorePath = optionValue("--stats-store", in: args) {
        statsStore = try await installStatsStore(at: statsStorePath)
    }

    let result = try await engine.run()
    let manifest = result.manifest

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(to: URL(fileURLWithPath: manifestPath))

    let captured = result.timing.series(.capture)

    // Emit the capture metrics into the stats store, then drain + close.
    if let statsStore {
        emitCaptureMetrics(captured, count: manifest.entries.count,
                           now: Date().timeIntervalSince1970)
        await drainStatsSink()
        await statsStore.close()
    }

    var summary = String(
        format: "transfer complete: %d entries (%d enumerated%@), capture mean %.2f ms (p95 %.2f ms)\n",
        manifest.entries.count, result.sourceEnumerated,
        (result.cappedBySample ? ", capped by --limit sample" : "") as NSString,
        captured.mean * 1000, captured.p95 * 1000)
    // Round-trip integrity: report every entry that did not come back.
    if verify {
        if result.roundTripFailures.isEmpty {
            summary += "round-trip: all entries verified on the target\n"
        } else {
            // notRecalled means the entry did not appear in the target's top-N
            // recall for its own content — which on a relevance-ranked store
            // can mean the id ranks below the recall depth amid similar
            // entries, NOT necessarily that the write was lost. writeFailed
            // means the write itself failed (the entry never landed).
            summary += String(format: "round-trip: %d entries did NOT recall in the target's top results:\n",
                              result.roundTripFailures.count)
            for f in result.roundTripFailures {
                summary += "  id=\(f.id)  reason=\(f.reason.rawValue)\n"
            }
        }
    }
    summary += "manifest written to \(manifestPath)\n"
    FileHandle.standardOutput.write(Data(summary.utf8))
}

/// benchmark subcommand.
func runBenchmark(_ args: [String]) async throws {
    let configPath = try requireOption("--config", in: args)
    let manifestPath = try requireOption("--manifest", in: args)
    let reportPath = try requireOption("--report", in: args)
    let compareSource = flagPresent("--compare-source", in: args)

    let config = try BenchmarkerConfig.load(from: URL(fileURLWithPath: configPath))
    let manifest = try JSONDecoder().decode(
        Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))

    let source = try await connectedClient(for: config.source)
    let target = try await connectedClient(for: config.target)
    defer { Task { await source.disconnect(); await target.disconnect() } }

    let engine = BenchmarkEngine(
        source: source,
        target: target,
        sourceVerbs: config.source.verbMap,
        targetVerbs: config.target.verbMap,
        compareSourceRanking: compareSource
    )
    // Optional stats-store instrumentation.
    var statsStore: StatsStore?
    if let statsStorePath = optionValue("--stats-store", in: args) {
        statsStore = try await installStatsStore(at: statsStorePath)
    }

    // DegeneracyGuard probe (SPEC §9): probe the target before scoring recall.
    // benchmark is manifest-replay (not live head-to-head); the guard still applies
    // because we are emitting a recall number. Non-healthy verdict exits non-zero.
    let guard_ = DegeneracyGuard()
    let targetRankings = await probeMCPClient(target, verbMap: config.target.verbMap,
                                              name: config.target.name)
    let targetVerdict = guard_.classify(probeRankings: targetRankings)
    enforceGuard(verdict: targetVerdict, backendName: config.target.name)

    let report = try await engine.run(manifest: manifest)
    // Label the output clearly: this is manifest-replay verification, not a live
    // head-to-head proxy session (SPEC §6b).
    let labelledOutput = "[benchmark] manifest-replay, not live head-to-head\n"
        + report.rendered()
    try report.encoded().write(to: URL(fileURLWithPath: reportPath))

    if let statsStore {
        emitBenchmarkMetrics(report, now: Date().timeIntervalSince1970)
        await drainStatsSink()
        await statsStore.close()
    }

    FileHandle.standardOutput.write(Data(labelledOutput.utf8))
}

/// report subcommand.
func runReport(_ args: [String]) throws {
    let reportPath = try requireOption("--report", in: args)
    let report = try BenchmarkReport.load(from: URL(fileURLWithPath: reportPath))
    FileHandle.standardOutput.write(Data(report.rendered().utf8))
}

/// Emits a rolling-stats snapshot's series + divergence into the stats store
/// via IntellectusLib. No-op when monitoring was never enabled. Used by both
/// `serve` and `pressure` so the standing stats reach moot-mgr's dashboard.
func emitRollingSnapshot(_ snap: RollingStatsSnapshot, now: Double) {
    for s in snap.series {
        // The series label (e.g. "mootx01.read", "primary.tools/call") becomes
        // a tag so the dashboard can split the four paths / two backends.
        Intellectus.report(.metric(name: "benchmarker.rolling.latency_ms.mean",
                                   value: s.mean * 1000, tags: ["series": s.label], ts: now))
        Intellectus.report(.metric(name: "benchmarker.rolling.latency_ms.p95",
                                   value: s.p95 * 1000, tags: ["series": s.label], ts: now))
        Intellectus.report(.metric(name: "benchmarker.rolling.count",
                                   value: Double(s.totalCount), tags: ["series": s.label], ts: now))
    }
    if snap.divergenceSampleCount > 0 {
        Intellectus.report(.metric(name: "benchmarker.rolling.divergence.jaccard_set",
                                   value: snap.jaccardMean, tags: [:], ts: now))
        Intellectus.report(.metric(name: "benchmarker.rolling.divergence.kendall_rank",
                                   value: snap.kendallRankMean, tags: [:], ts: now))
    }
}

/// Builds a raw passthrough backend from one endpoint's stdio command. The
/// proxy needs the raw command string (not the verb-scoped MCPClient), so it
/// rejects an sse endpoint — passthrough proxying is stdio-only for now.
func rawBackend(for endpoint: EndpointConfig) throws -> RawMCPBackend {
    guard case let .stdio(command) = endpoint.transport else {
        throw MCPError(description: "serve passthrough requires a stdio endpoint for \(endpoint.name)")
    }
    return RawMCPBackend(name: endpoint.name, command: command)
}

// MARK: - DegeneracyGuard probe helpers (SPEC §9)

/// The three distinct probe queries used for the guard's query-invariance check.
/// They are deliberately broad and varied so a well-functioning backend should
/// return meaningfully different result sets for each.
private let guardProbeQueries = [
    "memory recall search recent",
    "project task planning notes",
    "important decision context background",
]

/// Issues ≥3 distinct probe queries to a `RawMCPBackend` and returns the
/// ordered rankings (normalized content order) for each probe. Used by the
/// serve path's guard check where the backend is a raw stdio process.
///
/// Failures on individual probes are swallowed (a probe failure returns an
/// empty ranking for that slot — if the backend is consistently failing, the
/// guard will see uniform empty rankings and classify as query-invariant).
func probeRawBackend(_ backend: RawMCPBackend, verbMap: EndpointConfig.VerbMap,
                     name: String) async -> [[String]] {
    var rankings: [[String]] = []
    for query in guardProbeQueries {
        // Build the JSON-RPC query call using the endpoint's configured query tool.
        var args: [String: JSONValue] = [verbMap.queryArg: .string(query)]
        // Merge constant args (e.g. location for mootx01).
        for (k, v) in verbMap.constantArgs { args[k] = .string(v) }
        let rpcID = Int.random(in: 100_000...999_999)
        let msg = JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .number(Double(rpcID)),
            "method": .string("tools/call"),
            "params": .object([
                "name": .string(verbMap.query),
                "arguments": .object(args),
            ]),
        ])
        guard let encoded = try? JSONEncoder().encode(msg) else { continue }
        do {
            let response = try await backend.sendAndReceive(encoded)
            if let value = try? JSONDecoder().decode(JSONValue.self, from: response),
               let result = value["result"] {
                let items = MCPClient.parseToolResult(result, format: verbMap.resultFormat).items
                let order = BenchmarkEngine.normalizedContentOrder(items)
                rankings.append(order)
            } else {
                rankings.append([])
            }
        } catch {
            rankings.append([])
        }
    }
    return rankings
}

/// Issues ≥3 distinct probe queries to a connected `MCPClient` and returns
/// the normalized-content rankings for each probe. Used by the benchmark path.
func probeMCPClient(_ client: MCPClient, verbMap: EndpointConfig.VerbMap,
                    name: String) async -> [[String]] {
    var rankings: [[String]] = []
    for query in guardProbeQueries {
        var args: [String: JSONValue] = [verbMap.queryArg: .string(query)]
        for (k, v) in verbMap.constantArgs { args[k] = .string(v) }
        do {
            let result = try await client.callTool(verbMap.query, arguments: args,
                                                   format: verbMap.resultFormat)
            let order = BenchmarkEngine.normalizedContentOrder(result.items)
            rankings.append(order)
        } catch {
            rankings.append([])
        }
    }
    return rankings
}

/// Runs the DegeneracyGuard against the probe rankings and emits a diagnostic
/// + exits non-zero if the verdict is not `.healthy`. Returns normally on a
/// `.healthy` verdict. Call BEFORE emitting any recall/quality number.
func enforceGuard(verdict: DegeneracyGuard.Verdict, backendName: String) {
    switch verdict {
    case .healthy:
        return
    default:
        let msg = "[DegeneracyGuard] REFUSED to publish comparison for '\(backendName)': "
            + verdict.diagnostic + "\n"
        FileHandle.standardError.write(Data(msg.utf8))
        exit(1)
    }
}

/// serve subcommand — the passthrough MCP proxy.
///
///   mcp-benchmarker serve --config c.json [--primary source|target]
///       [--mirror] [--mirror-reads-only] [--stats-store s.sqlite]
///       [--report-interval N]
///
/// The PRIMARY backend (default: source) is forwarded verbatim and its response
/// returned to the client. With `--mirror`, the OTHER endpoint becomes the
/// secondary shadow: each tools/call is mirrored (timed; not returned), and
/// recall calls are divergence-scored. `--mirror-reads-only` mirrors only
/// query/recall calls (mandatory when the shadow is a real DB so no write
/// reaches it). Rolling stats flush to the stats store every `--report-interval`
/// seconds when `--stats-store` is given (default 30s).
func runServe(_ args: [String]) async throws {
    let configPath = try requireOption("--config", in: args)
    let config = try BenchmarkerConfig.load(from: URL(fileURLWithPath: configPath))

    // Primary selection: which configured endpoint the client really talks to.
    let primaryIsSource = (optionValue("--primary", in: args) ?? "source") == "source"
    let primaryEndpoint = primaryIsSource ? config.source : config.target
    let secondaryEndpoint = primaryIsSource ? config.target : config.source

    let primary = try rawBackend(for: primaryEndpoint)
    try await primary.start()

    let mirror = flagPresent("--mirror", in: args)
    let mirrorReadsOnly = flagPresent("--mirror-reads-only", in: args)
    var secondary: RawMCPBackend?
    if mirror {
        let s = try rawBackend(for: secondaryEndpoint)
        try await s.start()
        // Bring the shadow up to a usable state with its own initialize so the
        // first mirrored tools/call is not rejected for missing handshake.
        let initMsg = JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .number(0),
            "method": .string("initialize"),
            "params": .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("mcp-benchmarker-shadow"),
                    "version": .string("0.1.0"),
                ]),
            ]),
        ])
        _ = try? await s.sendAndReceive(try JSONEncoder().encode(initMsg))
        secondary = s
    }

    let stats = RollingStats()

    var statsStore: StatsStore?
    if let statsStorePath = optionValue("--stats-store", in: args) {
        statsStore = try await installStatsStore(at: statsStorePath)
    }
    // Periodic flush of the rolling snapshot to the stats store + stderr, so a
    // long-running proxy reports standing stats over time without stopping.
    let interval = optionValue("--report-interval", in: args).flatMap(Double.init) ?? 30
    let flushTask = Task {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if Task.isCancelled { break }
            let snap = await stats.snapshot()
            if statsStore != nil {
                emitRollingSnapshot(snap, now: Date().timeIntervalSince1970)
            }
            // Standing stats go to stderr so they never corrupt the stdout
            // JSON-RPC channel the client is reading.
            FileHandle.standardError.write(Data(snap.rendered(title: "[serve] rolling stats").utf8))
        }
    }

    let reportAccumulator = ProxyReportAccumulator()
    var proxy = ProxyServer(
        primary: primary,
        primaryName: primaryEndpoint.name,
        primaryFormat: primaryEndpoint.verbMap.resultFormat,
        secondary: secondary,
        secondaryName: mirror ? secondaryEndpoint.name : nil,
        secondaryFormat: mirror ? secondaryEndpoint.verbMap.resultFormat : nil,
        mirrorReadsOnly: mirrorReadsOnly,
        primaryVerbMap: primaryEndpoint.verbMap,
        secondaryVerbMap: mirror ? secondaryEndpoint.verbMap : nil,
        stats: stats,
        reportAccumulator: reportAccumulator)

    // Run until the client closes stdin; returns the ProxyRunReport for the session.
    let runReport = try await proxy.run(clientIn: FileHandle.standardInput,
                                        clientOut: FileHandle.standardOutput)

    // DegeneracyGuard probe (SPEC §9): before emitting any recall/quality number,
    // issue ≥3 distinct probes to each backend whose recall is scored and classify.
    // A non-healthy verdict prints a diagnostic and exits non-zero — the comparison
    // is suppressed (a refused result is deliberate, not a zero).
    //
    // The guard runs while the backends are still alive (before stop()) so the
    // probes reach the real processes.
    if mirror {
        let guard_ = DegeneracyGuard()
        let primaryRankings = await probeRawBackend(primary,
                                                     verbMap: primaryEndpoint.verbMap,
                                                     name: primaryEndpoint.name)
        let pVerdict = guard_.classify(probeRankings: primaryRankings)
        enforceGuard(verdict: pVerdict, backendName: primaryEndpoint.name)

        let secondaryRankings = await probeRawBackend(secondary!,
                                                      verbMap: secondaryEndpoint.verbMap,
                                                      name: secondaryEndpoint.name)
        let sVerdict = guard_.classify(probeRankings: secondaryRankings)
        enforceGuard(verdict: sVerdict, backendName: secondaryEndpoint.name)
    }

    // Final snapshot + teardown.
    flushTask.cancel()
    let finalSnap = await stats.snapshot()
    if let statsStore {
        emitRollingSnapshot(finalSnap, now: Date().timeIntervalSince1970)
        await drainStatsSink()
        await statsStore.close()
    }
    FileHandle.standardError.write(Data(finalSnap.rendered(title: "[serve] final rolling stats").utf8))
    // Emit the consolidated proxy run report (SPEC §4.5). This is the live
    // head-to-head artifact: per-backend latency series + divergence summary +
    // secondary-failure count + worst-diverging tail. Goes to stderr so it never
    // corrupts the stdout MCP channel the client reads.
    FileHandle.standardError.write(Data(runReport.rendered(
        primaryName: primaryEndpoint.name,
        secondaryName: mirror ? secondaryEndpoint.name : "(no secondary)").utf8))
    await primary.stop()
    await secondary?.stop()
}

/// pressure subcommand — the synthetic 4-way load driver.
///
///   mcp-benchmarker pressure --config c.json [--concurrency N] [--duration S]
///       [--stats-store s.sqlite]
///
/// Exercises {read, write} × {mootx01, MemPalace} (source=MemPalace,
/// target=mootx01 in the config) for `--duration` seconds with `--concurrency`
/// workers per path, reporting throughput + latency per path. WRITE paths
/// mutate their backend — point them at SCRATCH backends (see CONFIG.md).
func runPressure(_ args: [String]) async throws {
    let configPath = try requireOption("--config", in: args)
    let config = try BenchmarkerConfig.load(from: URL(fileURLWithPath: configPath))
    let concurrency = optionValue("--concurrency", in: args).flatMap(Int.init) ?? 4
    let duration = optionValue("--duration", in: args).flatMap(Double.init) ?? 10

    let memory = try await connectedClient(for: config.source)
    let moot = try await connectedClient(for: config.target)
    defer { Task { await memory.disconnect(); await moot.disconnect() } }

    var statsStore: StatsStore?
    var rolling: RollingStats?
    if let statsStorePath = optionValue("--stats-store", in: args) {
        statsStore = try await installStatsStore(at: statsStorePath)
        rolling = RollingStats()
    }

    let engine = PressureEngine(
        memory: memory,
        memoryVerbs: config.source.verbMap,
        moot: moot,
        mootVerbs: config.target.verbMap,
        concurrencyPerPath: max(concurrency, 1),
        durationSeconds: max(duration, 0.1),
        stats: rolling)

    let report = try await engine.run()

    if let statsStore, let rolling {
        emitRollingSnapshot(await rolling.snapshot(), now: Date().timeIntervalSince1970)
        await drainStatsSink()
        await statsStore.close()
    }
    FileHandle.standardOutput.write(Data(report.rendered().utf8))
}

/// The default fixtures root, relative to this source file, so `quality` finds
/// the in-repo wiki-quality fixture without a flag. `#filePath` is this file
/// (apps/mcp-benchmarker/Sources/mcp-benchmarker/main.swift); CE has no
/// swift-bench/ wrapper — 3 levels up reaches apps/mcp-benchmarker/fixtures/.
/// `--fixtures DIR` overrides it.
func defaultFixturesRoot() -> URL {
    URL(fileURLWithPath: #filePath)            // apps/mcp-benchmarker/Sources/mcp-benchmarker/main.swift
        .deletingLastPathComponent()           // apps/mcp-benchmarker/Sources/mcp-benchmarker
        .deletingLastPathComponent()           // apps/mcp-benchmarker/Sources
        .deletingLastPathComponent()           // apps/mcp-benchmarker
        .appendingPathComponent("fixtures")
        .appendingPathComponent("wiki-quality")
}

/// quality subcommand — DIAGNOSTIC-ONLY corpus quality scorer.
///
///   mcp-benchmarker quality --config c.json [--fixtures <dir>] [--limit-clusters N]
///
/// IMPORTANT: The scratch-ingest publish path has been removed (SPEC §0 delta,
/// FINDINGS-2026-06-07). This subcommand is now a DIAGNOSTIC-ONLY tool; it does
/// NOT publish a recall comparison. Labelled absolute recall comes only from the
/// transfer → benchmark live path against the transfer manifest (SPEC §5.4).
///
/// Config convention (same as pressure): source = MemPalace, target = mootx01.
/// The engine WRITES the corpus to both products, so both MUST be configured
/// against SCRATCH backends (MOOTX01_DATA_DIR=/tmp/..., mempalace --palace
/// /tmp/...); never the real palace. `--limit-clusters N` runs only the first N
/// clusters for a quick diagnostic pass.
func runQuality(_ args: [String]) async throws {
    let configPath = try requireOption("--config", in: args)
    let fixturesDir = optionValue("--fixtures", in: args).map { URL(fileURLWithPath: $0) }
        ?? defaultFixturesRoot()
    let limitClusters = optionValue("--limit-clusters", in: args).flatMap(Int.init)

    let config = try BenchmarkerConfig.load(from: URL(fileURLWithPath: configPath))

    var fixture = try QualityFixture.load(root: fixturesDir)
    if let n = limitClusters {
        fixture = fixture.limited(toClusters: n)
    }

    // Print the diagnostic-only header BEFORE the run so the caller knows
    // this is not a published comparison even if the run is interrupted.
    FileHandle.standardError.write(Data("""
    [quality] DIAGNOSTIC-ONLY run — NOT a published comparison.
    The scratch-ingest publish path has been removed (SPEC §0 delta).
    Labelled recall requires the transfer → benchmark path. See CONFIG.md.

    """.utf8))

    // source = MemPalace, target = mootx01 (the config convention shared with
    // the pressure mode). The engine writes to BOTH — scratch backends only.
    let mempalace = try await connectedClient(for: config.source)
    let moot = try await connectedClient(for: config.target)
    defer { Task { await mempalace.disconnect(); await moot.disconnect() } }

    let engine = QualityEngine(
        moot: moot,
        mootVerbs: config.target.verbMap,
        mempalace: mempalace,
        mempalaceVerbs: config.source.verbMap,
        fixture: fixture,
        limitedToClusters: limitClusters)

    let report = try await engine.run()
    // The scratch-ingest PUBLISH path is removed: no report.encoded().write()
    // to a file. The diagnostic output goes to stderr only.
    // No selection/comparison/publish. The scoring math is retained for internal
    // validation; see QualityEngine and QualityScoring for the math.
    FileHandle.standardError.write(Data(("[quality] diagnostic results (not published):\n"
        + report.rendered()).utf8))
}

/// longmemeval subcommand — LongMemEval session-recall harness.
///
///   mcp-benchmarker longmemeval --data-dir <dir> --variant s|m|oracle
///       [--mootx01-binary <path>] [--limit N] [--offset K] [--seed S]
///       [--shared-estate] [--out <dir>]
///
/// Provisions a fresh scratch estate per question (default) under /tmp/lme-bench-,
/// ingests haystack sessions via live MCP write, queries via MCP query, and
/// reports Recall-any@k / MRR / latency. Dataset must be pre-fetched with
/// scripts/fetch-longmemeval.sh.
func runLongMemEval(_ args: [String]) async throws {
    let variant = try requireOption("--variant", in: args)
    guard ["s", "m", "oracle"].contains(variant) else {
        throw MCPError(description: "--variant must be 's', 'm', or 'oracle'; got '\(variant)'")
    }
    let dataDirStr = try requireOption("--data-dir", in: args)
    // Resolve variant filename from the variant flag.
    let variantFilename: String
    switch variant {
    case "s":      variantFilename = "longmemeval_s_cleaned.json"
    case "m":      variantFilename = "longmemeval_m_cleaned.json"
    case "oracle": variantFilename = "longmemeval_oracle.json"
    default: fatalError("unreachable")
    }
    let datasetPath = URL(fileURLWithPath: dataDirStr)
        .appendingPathComponent(variantFilename)

    guard FileManager.default.fileExists(atPath: datasetPath.path) else {
        throw MCPError(description:
            "dataset file not found at \(datasetPath.path). "
            + "Run scripts/fetch-longmemeval.sh to download the dataset.")
    }

    // mootx01 binary: explicit flag takes priority over auto-discovery.
    let mootBinary: String
    if let explicit = optionValue("--mootx01-binary", in: args) {
        mootBinary = explicit
    } else if let discovered = discoverMootBinary() {
        mootBinary = discovered
        FileHandle.standardError.write(Data(
            "[longmemeval] auto-discovered mootx01 at: \(mootBinary)\n".utf8))
    } else {
        throw MCPError(description:
            "mootx01 binary not found. Build with `swift build --package-path apps/mootx01` "
            + "or pass --mootx01-binary <path>.")
    }
    guard FileManager.default.isExecutableFile(atPath: mootBinary) else {
        throw MCPError(description:
            "mootx01 binary not executable at '\(mootBinary)'. "
            + "Build with `swift build --package-path apps/mootx01`.")
    }

    let limit = optionValue("--limit", in: args).flatMap(Int.init)
    let offset = optionValue("--offset", in: args).flatMap(Int.init) ?? 0
    let seed = optionValue("--seed", in: args).flatMap(UInt64.init) ?? 20_260_725
    // --arm exact|dense|both (default: both). Controls which recall paths are exercised.
    //   exact: moot_memory_search only (LME-01 baseline path)
    //   dense: moot_recall_distilled only (requires moot_consolidate after ingest)
    //   both:  both arms per question for the two-arm token-efficiency comparison
    let armStr = optionValue("--arm", in: args) ?? "both"
    let arm: LMEArm
    switch armStr {
    case "exact": arm = .exact
    case "dense": arm = .dense
    case "both":  arm = .both
    default:
        throw MCPError(description: "--arm must be 'exact', 'dense', or 'both'; got '\(armStr)'")
    }
    let sharedEstate = flagPresent("--shared-estate", in: args)
    let outDirStr = optionValue("--out", in: args)
    let outDir = outDirStr.map { URL(fileURLWithPath: $0) }

    // Warn on shared-estate: methodology-affecting (haystack contamination).
    if sharedEstate {
        let warn = "[longmemeval] WARNING: --shared-estate is methodology-affecting. "
            + "Prior sessions' content can influence recall for later questions.\n"
        FileHandle.standardError.write(Data(warn.utf8))
    }

    let loadMsg = "[longmemeval] loading corpus from \(datasetPath.path)\n"
    FileHandle.standardOutput.write(Data(loadMsg.utf8))

    let corpus = try loadLMECorpus(from: datasetPath)
    let loadedMsg = "[longmemeval] loaded \(corpus.questions.count) questions "
        + "(\(corpus.abstentionCount) abstentions excluded)\n"
    FileHandle.standardOutput.write(Data(loadedMsg.utf8))

    let runConfig = LMERunConfig(
        mootBinaryPath: mootBinary,
        datasetPath: datasetPath,
        variant: variant,
        limit: limit,
        offset: offset,
        seed: seed,
        freshPerQuestion: !sharedEstate,
        outDir: outDir,
        runLabel: "lme-\(variant)-seed\(seed)-arm\(armStr)",
        arm: arm
    )

    let results = try await runLMEQuestions(questions: corpus.questions, config: runConfig)

    // Score the results (LongMemEvalScorer.swift). Guard-excluded questions are
    // counted but excluded from aggregate recall/MRR per the contract §1.2 guarantee 1.
    let scores = results.map { scoreLMEQuestion($0) }

    // Build and write the report.
    let report = buildLMEReport(config: runConfig, corpus: corpus, scores: scores)
    let reportFilename = "lme-report-\(report.variant)-seed\(runConfig.seed).json"
    let reportURL = (outDir ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .appendingPathComponent(reportFilename)
    try writeLMEReport(report, to: reportURL)

    // Print scored summary to stdout.
    let guardHealthyCount = scores.filter(\.guardHealthy).count
    let guardRefusals = scores.count - guardHealthyCount
    let totalTurns = results.map(\.turnsIngested).reduce(0, +)
    let (agg, lat) = aggregateLMEScores(scores)

    let summary = """
        [longmemeval] run complete
          questions processed:  \(results.count)
          guard healthy:        \(guardHealthyCount)
          guard refusals:       \(guardRefusals)
          turns ingested total: \(totalTurns)
          recall-any@1:         \(String(format: "%.4f", agg.recallAnyAt1))
          recall-any@5:         \(String(format: "%.4f", agg.recallAnyAt5))
          recall-any@10:        \(String(format: "%.4f", agg.recallAnyAt10))
          recall-all@1:         \(String(format: "%.4f", agg.recallAllAt1))
          recall-all@5:         \(String(format: "%.4f", agg.recallAllAt5))
          recall-all@10:        \(String(format: "%.4f", agg.recallAllAt10))
          mrr:                  \(String(format: "%.4f", agg.mrr))
          query p50:            \(String(format: "%.1f", lat.queryP50Seconds * 1000)) ms
          query p95:            \(String(format: "%.1f", lat.queryP95Seconds * 1000)) ms
          estate strategy:      \(sharedEstate ? "shared" : "fresh-per-question")
          report written to:    \(reportURL.path)

        """
    FileHandle.standardOutput.write(Data(summary.utf8))
}

/// Dispatches one subcommand.
func dispatch(_ arguments: [String]) async throws {
    guard let subcommand = arguments.first else {
        FileHandle.standardOutput.write(Data(usageText().utf8))
        exit(2)
    }
    let rest = Array(arguments.dropFirst())
    switch subcommand {
    case "transfer":       try await runTransfer(rest)
    case "benchmark":      try await runBenchmark(rest)
    case "serve":          try await runServe(rest)
    case "pressure":       try await runPressure(rest)
    case "quality":        try await runQuality(rest)
    case "gauntlet-corpus": try runGauntletCorpus(rest)
    case "gauntlet":       try await runGauntlet(rest)
    case "longmemeval":    try await runLongMemEval(rest)
    case "report":         try runReport(rest)
    case "--help", "-h", "help":
        FileHandle.standardOutput.write(Data(usageText().utf8))
    default:
        FileHandle.standardError.write(Data("unknown subcommand '\(subcommand)'\n".utf8))
        FileHandle.standardOutput.write(Data(usageText().utf8))
        exit(2)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    try await dispatch(arguments)
} catch {
    FileHandle.standardError.write(Data("mcp-benchmarker: \(error)\n".utf8))
    exit(1)
}
