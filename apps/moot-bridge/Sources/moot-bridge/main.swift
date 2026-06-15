import Foundation
import IntellectusLib
import ObserverSink

// main.swift — moot-bridge CLI entry point.
//
// Hand-rolled argument parsing — no swift-argument-parser dependency, to hold
// the zero-external-dependency line.
//
//   moot-bridge --config <c.json> [--stats-store <stats.sqlite>] [--report-interval N]
//
// The AI client launches `moot-bridge --config c.json` as its memory MCP server.
// The bridge:
//   - handshakes BOTH configured backends at startup (initialize),
//   - serves the client over stdin/stdout (one JSON-RPC object per line),
//   - fans every WRITE out to both backends, serves every READ from the primary,
//   - lets the AI flip the primary mid-session via the bridge_set_primary tool,
//   - tracks per-backend latency + secondary-failure stats, flushed periodically
//     to the ObserverSink stats store (--stats-store) and to stderr.
//
// stdout is the client's JSON-RPC channel — NOTHING but JSON-RPC responses ever
// goes there. All logs, stats, and diagnostics go to stderr.

/// Usage text shown for `--help`, no args, or a bad invocation.
func usageText() -> String {
    """
    moot-bridge — a bridging MCP memory server.

    USAGE:
      moot-bridge --config <c.json> [--stats-store <stats.sqlite>] [--report-interval N]

    The AI client launches this as its single memory MCP server. Every WRITE is
    fanned out to BOTH configured backends (e.g. MemPalace AND mootx01); every
    READ is served from whichever backend is currently PRIMARY. The AI flips the
    primary mid-session with the bridge_set_primary tool. bridge_status reports the
    current primary and per-backend stats.

    --stats-store <path>  emit per-backend latency + secondary-failure metrics
                          into the ObserverSink stats store for moot-mgr.
    --report-interval N   seconds between stderr/stats-store flushes (default 30).

    """
}

/// Returns the value following `--name`, or nil if absent / no value follows.
func optionValue(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// A required option, or a usage error.
func requireOption(_ name: String, in args: [String]) throws -> String {
    guard let value = optionValue(name, in: args) else {
        throw MCPError(description: "missing required option \(name)")
    }
    return value
}

// MARK: - Stats-store instrumentation (carried from the benchmarker)

/// Opens the ObserverSink stats store at `path`, installs a `PersistenceStatsSink`
/// into IntellectusLib, and enables monitoring (both the IntellectusLib gate and
/// the store's flag row) so emitted samples land. Returns the opened store so the
/// caller can close it after the run. The dropbox id identifies the bridge's rows.
func installStatsStore(at path: String) async throws -> StatsStore {
    let store = try StatsStore(url: URL(fileURLWithPath: path))
    try await store.open()
    // The bridge is the producer here, so it turns the store flag on for the
    // duration of its own run. In the manager pipeline the manager owns this
    // flag; for a standalone bridge run the tool enables it itself.
    try await store.setMonitoringEnabled(true)
    let sink = PersistenceStatsSink(store: store, dropboxID: "moot-bridge")
    Intellectus.install(sink: sink)
    Intellectus.setEnabled(true)
    return store
}

/// Lets the in-flight async sink Tasks drain before the store is closed.
/// `PersistenceStatsSink.receive(_:)` dispatches each insert to an unstructured
/// Task; a brief yield lets those complete so the rows are visible to a reader.
func drainStatsSink() async {
    try? await Task.sleep(nanoseconds: 300_000_000)  // 300 ms
}

/// Emits a bridge-stats snapshot's per-backend series + secondary-failure count
/// into the stats store via IntellectusLib. No-op when monitoring was never
/// enabled. So moot-mgr can dashboard a live bridge session.
func emitBridgeSnapshot(_ snap: BridgeStatsSnapshot, now: Double) {
    for s in snap.series {
        // The series label (e.g. "mempalace.tools/call", "mootx01.tools/call.mirror")
        // becomes a tag so the dashboard can split the two backends and the
        // primary vs. mirror paths.
        Intellectus.report(.metric(name: "bridge.latency_ms.mean",
                                   value: s.mean * 1000, tags: ["series": s.label], ts: now))
        Intellectus.report(.metric(name: "bridge.latency_ms.p95",
                                   value: s.p95 * 1000, tags: ["series": s.label], ts: now))
        Intellectus.report(.metric(name: "bridge.count",
                                   value: Double(s.totalCount), tags: ["series": s.label], ts: now))
    }
    Intellectus.report(.metric(name: "bridge.secondary_failures",
                               value: Double(snap.secondaryFailureCount), tags: [:], ts: now))
}

// MARK: - Startup handshake

/// The MCP `initialize` request the bridge sends to a backend at startup so the
/// first real tools/call is not rejected for a missing handshake. The id is 0 on
/// the backend's own (disjoint) id space — the bridge never forwards a client id to
/// a backend during startup.
func backendInitializeMessage() throws -> Data {
    let initMsg = JSONValue.object([
        "jsonrpc": .string("2.0"), "id": .number(0),
        "method": .string("initialize"),
        "params": .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("moot-bridge"),
                "version": .string("0.1.0"),
            ]),
        ]),
    ])
    return try JSONEncoder().encode(initMsg)
}

/// Builds and starts a live transport for one backend, performs its initialize
/// handshake, and returns the ready `BridgeBackend` handle.
func startBackend(_ config: BackendConfig) async throws -> BridgeBackend {
    let transport = RawMCPBackend(name: config.name, command: config.command)
    try await transport.start()
    // Handshake so the first real tools/call lands on an initialized server.
    _ = try? await transport.sendAndReceive(try backendInitializeMessage())
    return BridgeBackend(transport: transport, name: config.name, verbMap: config.verbMap)
}

// MARK: - Entry

/// The serve loop: load config, start + handshake both backends, run the bridge
/// until the client disconnects, then flush final stats and tear down.
func runBridge(_ args: [String]) async throws {
    let configPath = try requireOption("--config", in: args)
    let config = try BridgeConfig.load(from: URL(fileURLWithPath: configPath))

    // Start + handshake both backends. backends[0] = backendA, backends[1] =
    // backendB; primaryIndex picks whichever `config.primary` names.
    let backendA = try await startBackend(config.backendA)
    let backendB = try await startBackend(config.backendB)
    let backends = [backendA, backendB]
    let primaryIndex = (config.primary == config.backendA.name) ? 0 : 1

    let stats = BridgeStats()

    // Optional stats-store instrumentation.
    var statsStore: StatsStore?
    if let statsStorePath = optionValue("--stats-store", in: args) {
        statsStore = try await installStatsStore(at: statsStorePath)
    }

    // Periodic flush of the standing stats to the store + stderr, so a long-lived
    // bridge reports over time without the client disconnecting. stderr only —
    // never stdout (the client's JSON-RPC channel).
    let interval = optionValue("--report-interval", in: args).flatMap(Double.init) ?? 30
    let flushTask = Task {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if Task.isCancelled { break }
            let snap = await stats.snapshot()
            if statsStore != nil {
                emitBridgeSnapshot(snap, now: Date().timeIntervalSince1970)
            }
            FileHandle.standardError.write(Data(snap.rendered(title: "[bridge] rolling stats").utf8))
        }
    }

    let server = BridgeServer(backends: backends, primaryIndex: primaryIndex, stats: stats)

    // Announce readiness on stderr so an operator/harness knows the bridge is up.
    FileHandle.standardError.write(Data(
        "[bridge] ready: backends [\(backendA.name), \(backendB.name)], primary=\(config.primary)\n".utf8))

    // Run until the client closes stdin.
    try await server.run(clientIn: FileHandle.standardInput,
                         clientOut: FileHandle.standardOutput)

    // Final snapshot + teardown.
    flushTask.cancel()
    let finalSnap = await stats.snapshot()
    if let statsStore {
        emitBridgeSnapshot(finalSnap, now: Date().timeIntervalSince1970)
        await drainStatsSink()
        await statsStore.close()
    }
    FileHandle.standardError.write(Data(finalSnap.rendered(title: "[bridge] final stats").utf8))
    await backendA.transport.stop()
    await backendB.transport.stop()
}

// MARK: - main

let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args.contains("--help") || args.contains("-h") {
    FileHandle.standardError.write(Data(usageText().utf8))
    exit(args.isEmpty ? 1 : 0)
}

do {
    try await runBridge(args)
} catch {
    // All errors go to stderr — stdout is reserved for the JSON-RPC channel.
    FileHandle.standardError.write(Data("moot-bridge error: \(error)\n".utf8))
    exit(1)
}
