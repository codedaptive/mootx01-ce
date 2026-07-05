import Foundation
import AriaMCP
import CognitionKit
import GeniusLocusKit
import NeuronKit
import ObserverSink
import IntellectusLib
import Synchronization

/// The resident-daemon composition layer (see ADR-LOOPBACKHTTP-001).
///
/// Both the product binary (`mootx01 serve`, resident mode) and the dev/reference
/// build (`aria-mcp`) run the SAME resident wiring through this one entry point —
/// so there is a single implementation, not two that drift. It sits ABOVE the
/// telemetry-free JSON-RPC core (`AriaMCP`): `HTTPServer` and `AutonomicGovernor`
/// stay in the core; their *composition with telemetry* lives here. This keeps
/// `AriaMCP` free of ObserverSink/IntellectusLib (the separation established in
/// P3) — the `AriaMCP` target declares no telemetry dependency, so the build
/// itself is the guard (an `import ObserverSink` there would not compile).
///
/// The runner does NOT read the environment and does NOT call `exit()`. Callers
/// resolve storage, open the estate, parse env into a `ResidentConfig` (using the
/// shared parsers below so the knobs behave identically across binaries), and
/// decide process lifecycle. The runner throws on failure.
public enum AriaResident {

    // MARK: - Env parsers (shared so both binaries parse identically)

    /// HTTP request body cap from `MOOTX01_HTTP_MAX_BODY_BYTES` (default 4 MiB).
    /// MCP `tools/call` bodies can exceed LoopbackHTTP's 64 KiB default, which
    /// would silently truncate.
    public static func httpMaxBodyBytes(env: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        guard let raw = env["MOOTX01_HTTP_MAX_BODY_BYTES"], !raw.isEmpty else { return 4 * 1024 * 1024 }
        guard let value = Int(raw), value > 0 else {
            Logging.stderr.log("AriaResident: MOOTX01_HTTP_MAX_BODY_BYTES='\(raw)' invalid; using 4 MiB default")
            return 4 * 1024 * 1024
        }
        return value
    }

    /// Autonomic governor base tick (ms) from `MOOTX01_BRAIN_TICK_MS` (default 5000).
    /// The loop's sampling resolution, not a cadence — each daemon self-gates on
    /// its own (longer) interval. Clamped to a sane ceiling (1 h).
    public static func brainTickMs(env: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        guard let raw = env["MOOTX01_BRAIN_TICK_MS"], !raw.isEmpty else { return 5000 }
        guard let value = Int(raw), value > 0 else {
            Logging.stderr.log("AriaResident: MOOTX01_BRAIN_TICK_MS='\(raw)' invalid; using 5000ms default")
            return 5000
        }
        return min(value, 3_600_000)
    }

    /// Monitoring-gate poll interval (ms) from `MOOTX01_MONITORING_POLL_MS`
    /// (default 5000, clamped to 1 h to guard the nanosecond conversion).
    public static func monitoringPollMs(env: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        guard let raw = env["MOOTX01_MONITORING_POLL_MS"], !raw.isEmpty else { return 5000 }
        guard let value = Int(raw), value > 0 else {
            Logging.stderr.log("AriaResident: MOOTX01_MONITORING_POLL_MS='\(raw)' invalid; using 5000ms default")
            return 5000
        }
        return min(value, 3_600_000)
    }

    /// Resolve the manager stats-store path for telemetry wiring.
    ///
    /// ## Enable path
    ///
    /// Telemetry is opt-in for the stdio transport (short-lived per-client
    /// processes). For the resident HTTP daemon (`MOOTX01_HTTP_PORT` set), a
    /// default path is computed so telemetry is live out-of-the-box without
    /// any manual configuration.
    ///
    /// Resolution order:
    ///
    /// 1. `ARIA_MCP_STATS_STORE` set and non-empty → use that exact path.
    /// 2. `useDefault` is `true` (resident HTTP mode) → fall back to the
    ///    platform default:
    ///    `<app-support>/com.mootx01.ce/moot-mgr/stats.sqlite`
    ///    This is the same file the `moot-mgr` manager process owns; the resident
    ///    daemon writes its dropbox rows here and the manager reads them. On macOS
    ///    the app-support root is `~/Library/Application Support`; on Linux Swift
    ///    it is `~/.local/share`.
    /// 3. `useDefault` is `false` (stdio mode) → return `nil` (telemetry off).
    ///    Short-lived stdio processes get startup-once install only (no continuous
    ///    monitoring gate), and without an explicit path the caller opts out.
    ///
    /// The store file and its parent directories are created by `StatsStore.open()`
    /// (via SQLiteStorage) — the caller does not need to pre-create them.
    ///
    /// - Parameters:
    ///   - env:        Environment variable map (injectable for tests).
    ///   - useDefault: When `true` and the env var is absent, compute the
    ///                 platform-default path. Pass `true` for resident HTTP mode;
    ///                 `false` for stdio mode.
    /// - Returns: A path string, or `nil` when telemetry should be off.
    public static func statsStorePathFromEnv(
        env: [String: String] = ProcessInfo.processInfo.environment,
        useDefault: Bool = false
    ) -> String? {
        // Explicit env override takes precedence over everything.
        if let raw = env["ARIA_MCP_STATS_STORE"], !raw.isEmpty {
            return raw
        }
        guard useDefault else {
            // stdio mode: no default — telemetry off unless explicitly configured.
            return nil
        }
        // Resident HTTP mode: compute the moot-mgr default path so the daemon
        // self-reports without any manual operator configuration.
        //
        // Path: <app-support>/com.mootx01.ce/moot-mgr/stats.sqlite
        //   - com.mootx01.ce is the shared data-dir bundle convention
        //   - moot-mgr/ is the manager's subdirectory (matches ManagerConfig.storeSubdirectory)
        //   - stats.sqlite is the manager's store file (matches ManagerConfig.storeFileName)
        //
        // macOS: ~/Library/Application Support/com.mootx01.ce/moot-mgr/stats.sqlite
        // Linux: ~/.local/share/com.mootx01.ce/moot-mgr/stats.sqlite
        // Fallback (app-support unavailable, e.g. headless CI): <tmp>/com.mootx01.ce/moot-mgr/stats.sqlite
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? FileManager.default.temporaryDirectory
        let path = base
            .appendingPathComponent("com.mootx01.ce", isDirectory: true)
            .appendingPathComponent("moot-mgr", isDirectory: true)
            .appendingPathComponent("stats.sqlite", isDirectory: false)
            .path
        return path
    }

    // MARK: - Telemetry install (resident-mode, opt-in)

    /// What `installManagerTelemetry` returns when telemetry is wired: the durable
    /// store (for topology snapshot read/write and the monitoring gate) and the
    /// observer program (for its bounded recent window). Nil overall means
    /// telemetry is off — and off is free.
    public struct TelemetryWiring: Sendable {
        /// The durable stats store. Owns the persisted monitoring flag and the
        /// topology_snapshots table.
        public let store: StatsStore
        /// The resident observer program: installed window + enable decision.
        public let observer: Observer
    }

    /// Install the manager-telemetry pipeline for the given store path, or return
    /// nil when `storePath` is nil/empty (telemetry off — and off is free).
    ///
    /// Opens the manager's stats store, builds the resident `Observer` (a
    /// `RecentWindowSink` forwarding to a `PersistenceStatsSink`), installs it as
    /// the global Intellectus sink, drives the gate from the observer's enable
    /// decision (env `ARIA_MCP_OBSERVER` OR the persisted store flag), and emits
    /// one startup metric. Best-effort: any failure logs to stderr and returns
    /// nil — telemetry must never affect the server.
    ///
    /// - Parameters:
    ///   - storePath: Stats-store file path; nil/empty → telemetry off.
    ///   - env:       Environment map (injectable for tests).
    public static func installManagerTelemetry(
        storePath: String?,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) async -> TelemetryWiring? {
        guard let storePath, !storePath.isEmpty else { return nil }
        do {
            let store = try StatsStore(url: URL(fileURLWithPath: storePath))
            try await store.open()
            let dropboxID = "mootx01-\(UUID().uuidString.prefix(8))"
            // The observer's window forwards to the durable persistence sink, so
            // a single installed sink both retains a bounded recent window AND
            // persists. The window is the in-process liveness proof; the store is
            // the durable record moot-mgr reads.
            let observer = Observer(forward: PersistenceStatsSink(store: store, dropboxID: dropboxID))
            observer.install()
            let storeFlag = try await store.isMonitoringEnabled()
            let enabled = Observer.shouldEnable(env: env, storeFlag: storeFlag)
            observer.setEnabled(enabled)
            Intellectus.report(.metric(
                name: "mootx01.start",
                value: 1.0,
                tags: ["dropbox": dropboxID],
                ts: Date().timeIntervalSince1970
            ))
            Logging.stderr.log("AriaResident observer wired (store: \(storePath), dropbox: \(dropboxID), window: \(observer.window.capacity), monitoring: \(enabled ? "on" : "off"))")
            return TelemetryWiring(store: store, observer: observer)
        } catch {
            Logging.stderr.log("AriaResident telemetry wiring skipped (error: \(error))")
            return nil
        }
    }

    // MARK: - The resident runner

    /// Resident-daemon configuration (resolved by the caller; the runner reads no
    /// environment itself).
    public struct ResidentConfig: Sendable {
        public var port: UInt16
        public var maxBodyBytes: Int
        public var brainTickMs: Int
        public var monitoringPollMs: Int
        /// Manager stats-store path; nil/empty → telemetry off.
        public var statsStorePath: String?

        public init(
            port: UInt16,
            maxBodyBytes: Int,
            brainTickMs: Int,
            monitoringPollMs: Int,
            statsStorePath: String?
        ) {
            self.port = port
            self.maxBodyBytes = maxBodyBytes
            self.brainTickMs = brainTickMs
            self.monitoringPollMs = monitoringPollMs
            self.statsStorePath = statsStorePath
        }
    }

    /// Run the resident daemon: install telemetry (if configured), spawn the Brain
    /// pump and the continuous monitoring gate, and serve the HTTP MCP transport
    /// until the process is terminated. Throws on bind failure (the caller decides
    // MARK: - MonitoringControl concrete implementation (ADR-025 wave 8.2)

    /// Concrete `MonitoringControl` backed by the resident `StatsStore`.
    ///
    /// Defined here because `AriaResident` is the only module that imports BOTH
    /// `AriaMCP` (for the `MonitoringControl` protocol) AND `ObserverSink` (for
    /// `StatsStore`). Keeping it `fileprivate` within the `ResidentDaemon` type
    /// prevents it from leaking into the public surface — it is an implementation
    /// detail of the injection seam.
    ///
    /// `read()` and `set(_:)` are best-effort: errors are logged to stderr and
    /// swallowed so a transient store fault never surfaces as a tool error. The
    /// tool runner maps `nil` from `read()` to "unavailable" rather than "disabled".
    fileprivate struct StatsStoreMonitoringControl: MonitoringControl {
        let store: StatsStore

        func read() async -> Bool? {
            try? await store.isMonitoringEnabled()
        }

        func set(_ enabled: Bool) async {
            do {
                try await store.setMonitoringEnabled(enabled)
            } catch {
                Logging.stderr.log("AriaResident MonitoringControl set failed: \(error)")
            }
        }
    }

    /// the exit code); never calls `exit()`.
    public static func runResidentDaemon(
        dispatcher: ARIA_MCPDispatcher,
        kit: GeniusLocusKit,
        handle: EstateHandle,
        config: ResidentConfig
    ) async throws {
        let wiring = await installManagerTelemetry(storePath: config.statsStorePath)
        let statsStore = wiring?.store
        let observer = wiring?.observer

        // Topology snapshot wiring: the governor writes via topologyHandler;
        // the HTTP server reads via topologyReader. Both closures capture the
        // same StatsStore reference — AriaMCP never imports ObserverSink.
        // The handler's 4th argument is the stable topology-inputs fingerprint
        // (F5): persisting it lets a restarting governor skip the full
        // drawer/tunnel/fact read when inputs are unchanged.
        let topologyHandler: (@Sendable (String, Date, Data, String) async -> Void)? = statsStore.map { store in
            { @Sendable estate, generatedAt, payload, fingerprint in
                do {
                    try await store.writeTopologySnapshot(
                        estate: estate,
                        generatedAt: generatedAt,
                        payload: payload,
                        fingerprint: fingerprint
                    )
                } catch {
                    Logging.stderr.log("AriaResident topology snapshot write failed: \(error)")
                }
            }
        }
        // F5: one-shot fingerprint loader. The governor calls this once on its
        // first topology duty to learn the persisted fingerprint, so it can skip
        // the full topology read when nothing changed since the last run.
        let topologyFingerprintLoader: (@Sendable () async -> String?)? = statsStore.map { store in
            { @Sendable in
                try? await store.loadTopologyFingerprint(estate: handle.estateUUID.uuidString)
            }
        }
        let topologyReader: (@Sendable (String?) async -> Data?)? = statsStore.map { store in
            { @Sendable estateParam in
                // Use the provided estate string or the canonical handle UUID.
                let estateKey = estateParam ?? handle.estateUUID.uuidString
                return try? await store.latestTopologySnapshot(estate: estateKey)
            }
        }
        // Monitoring gate for the topology duty: read the LIVE store flag at
        // each due cadence, so flipping monitoring off in moot-mgr stops the
        // recompute at the next interval (and back on resumes it) without a
        // daemon restart. Store-read failures fail OPEN (run the duty) — a
        // transient store error must not silently freeze topology.
        let topologyGate: (@Sendable () async -> Bool)? = statsStore.map { store in
            { @Sendable in (try? await store.isMonitoringEnabled()) ?? true }
        }

        // ADR-025 wave 8.2: inject the monitoring control into the dispatcher
        // so moot_monitoring_status can read/write the stats store without
        // AriaMcpKit importing ObserverSink. The concrete type lives here because
        // AriaResident is the only module that imports both AriaMCP (for the
        // protocol) and ObserverSink (for StatsStore). In stdio mode and
        // provision-less contexts, statsStore is nil, so monitoringControl is nil
        // and the tool reports "unavailable" — never fabricating state.
        let monitoringControl: (any MonitoringControl)? = statsStore.map { store in
            StatsStoreMonitoringControl(store: store)
        }
        let residentDispatcher: ARIA_MCPDispatcher
        if let monitoringControl {
            // Re-wrap the dispatcher with the monitoring seam wired. ToolDispatcher
            // is a value type, so this copies all fields and overwrites only
            // monitoringControl. ARIA_MCPDispatcher.init re-invokes ToolProjection
            // to regenerate the projected-tool list — idempotent and cheap.
            let updatedTooling = dispatcher.tooling.withMonitoringControl(monitoringControl)
            residentDispatcher = ARIA_MCPDispatcher(info: dispatcher.info, tooling: updatedTooling)
        } else {
            residentDispatcher = dispatcher
        }
        let server = HTTPServer(dispatcher: residentDispatcher, port: config.port, maxBodyBytes: config.maxBodyBytes, topologyReader: topologyReader)

        // Graph-analytics handler: inject the CognitionKit-based Keystones +
        // ConstellationLens scan into NeuronKit.AutonomicGovernor as a closure.
        // The governor runs this handler on its 10-minute cadence per wing.
        //
        // Injection seam: the governor (AutonomicGovernor) lives in NeuronKit.
        // CognitionKit depends on NeuronKit (not the reverse), so NeuronKit cannot import CognitionKit
        // directly. The handler closure is the boundary: AriaResident (which may
        // freely import both NeuronKit and CognitionKit) provides the concrete
        // implementation; NeuronKit stores and calls only an opaque typed closure.
        //
        // Per-wing: Keystones ranks load-bearing drawers by eigenvalue centrality
        // over the tunnel graph (Lens 1, Structure). ConstellationLens recovers
        // emergent communities via Louvain community detection (Lens 2, Structure).
        // Running both per wing on the governor's cadence keeps structural signals
        // current for the recall matrix without requiring any manual trigger.
        let graphAnalyticsHandler: (@Sendable (GeniusLocusKit, EstateHandle, Date) async throws -> Void)? = { kit, handle, now in
            let drawers = try await kit.allDrawers(in: handle)
            // Resolve parentNodeIds to display names for per-wing iteration.
            // Drawer no longer carries stored wing/room after ADR-017.
            let estate = try await kit.estate(for: handle)
            let activeDrawers = drawers.filter { $0.tombstonedAt == nil }
            let nodeNames = try await estate.resolveNodeNames(
                parentNodeIds: activeDrawers.map(\.parentNodeId))
            let wings = Set(activeDrawers.compactMap { nodeNames[$0.parentNodeId]?.wing }).sorted()
            for wing in wings {
                _ = try await Keystones.run(kit: kit, handle: handle, wing: wing, topK: 100)
                _ = try await ConstellationLens.run(kit: kit, handle: handle, wing: wing)
            }
        }

        let governor = AutonomicGovernor(
            kit: kit,
            handle: handle,
            baseTickMs: config.brainTickMs,
            topologyHandler: topologyHandler,
            topologyFingerprintLoader: topologyFingerprintLoader,
            topologyGate: topologyGate,
            graphAnalyticsHandler: graphAnalyticsHandler
        )

        // Standing-signal bootstrap (the dormant-loop activation). The governor
        // calls `kit.signalTick` every tick, but until a scheduler is registered
        // for the live estate `signalTick` throws `schedulerNotStarted` and
        // benign-skips — so the propose/associate emission loop never runs. We
        // register the architecture-spec §11.2 default standing signals here,
        // ONCE, before the governor loop starts, so the first tick finds a live
        // scheduler and drives real emissions (vector-similarity → associate,
        // decay-sweep, etc.).
        //
        // VectorStore: read back the store `AriaMCPMain` already registered for
        // this estate. Resident HTTP mode always wires semantic recall, so the
        // store is present here; the registration API needs it to build the
        // `VectorSimilaritySignal`. If (defensively) no store is registered, we
        // skip registration and the governor keeps benign-skipping `signalTick`
        // exactly as before activation — no fallback store is fabricated (that
        // would register a vector signal scanning an empty throwaway estate).
        //
        // dreamingCycle: left as the DEFAULT no-op. The heavy dreaming cycle is
        // already driven by THIS governor's own `dreaming.pump` on its 30 s
        // cadence; the scheduler's weekly `DreamingSignal` must NOT double-drive
        // it. The signal is registered (so its status is reportable) but its
        // cycle is the no-op — dreaming has exactly one driver, the governor pump.
        //
        // Best-effort: a registration failure logs and the governor still runs
        // (signalTick keeps benign-skipping, the pre-activation behaviour) — a
        // standing-signal wiring error must never stop the daemon from serving.
        if let vectorStore = await kit.registeredVectorStore(for: handle) {
            do {
                _ = try await kit.registerDefaultStandingSignals(
                    in: handle,
                    vectorStore: vectorStore,
                    now: Date()
                )
                Logging.stderr.log("AriaResident standing signals registered (\(GeniusLocusKit.defaultStandingSignalNames.count) defaults)")
            } catch {
                Logging.stderr.log("AriaResident standing-signal registration failed (governor will benign-skip signalTick): \(error)")
            }
        } else {
            Logging.stderr.log("AriaResident standing signals NOT registered (no VectorStore for estate; governor signalTick will benign-skip)")
        }

        let pumpTask = Task { await governor.run() }

        // Continuous monitoring gate: the observer program re-decides its enable
        // state on each poll from the live store flag (OR the ARIA_MCP_OBSERVER
        // env opt-in), so a moot-mgr on/off flip takes effect without a restart.
        // Only when telemetry is wired; "off is free" preserved. When the gate is
        // on, the observer's bounded recent window count is logged on transition
        // so the operator can confirm samples are flowing (the liveness signal).
        let pollMs = config.monitoringPollMs
        let monitoringTask: Task<Void, Never>? = (statsStore.flatMap { store in observer.map { (store, $0) } }).map { (store, obs) in
            Task {
                let pollNs = UInt64(pollMs) * 1_000_000
                var last: Bool? = nil
                while !Task.isCancelled {
                    do {
                        let storeFlag = try await store.isMonitoringEnabled()
                        let on = Observer.shouldEnable(storeFlag: storeFlag)
                        obs.setEnabled(on)
                        if on != last {
                            Logging.stderr.log("AriaResident monitoring gate: \(on ? "on" : "off") (window: \(obs.window.count)/\(obs.window.capacity), totalReceived: \(obs.window.totalReceived))")
                            last = on
                        }
                    } catch {
                        Logging.stderr.log("AriaResident monitoring-gate refresh failed: \(error)")
                    }
                    do { try await Task.sleep(nanoseconds: pollNs) } catch { break }
                }
            }
        }

        // Periodic server-metrics task: emit process RSS, CPU, RPC count, and
        // connections every 30 seconds when monitoring is on. Only wired when
        // telemetry is active (statsStore non-nil); "off is free" preserved.
        //
        // kernelKind uses the same compile-time arch conditional as
        // PortableKernel.kernelForCurrentPlatform() to avoid importing SubstrateKernel
        // in the resident composition layer. arm64 → "simd"; all others → "scalar".
        #if arch(arm64)
        let kernelKind = "simd"
        #else
        let kernelKind = "scalar"
        #endif
        let protoVersion = "2025-11-25"  // MCP protocol version constant
        let serverMetricsTask: Task<Void, Never>? = statsStore.map { _ in
            Task {
                let intervalNs: UInt64 = 30_000_000_000  // 30 seconds
                while !Task.isCancelled {
                    if Intellectus.isEnabled {
                        let now = Date().timeIntervalSince1970
                        // Snapshot all transport counters atomically (each is a
                        // separate relaxed load; the values are a consistent snapshot
                        // at the 30-second granularity, not a transactional snapshot).
                        reportServerMetrics(
                            rpcCount: globalRPCCounter.load(ordering: .relaxed),
                            activeConnections: globalInflightCounter.load(ordering: .relaxed),
                            connectionsHWM: globalInflightHighWater.load(ordering: .relaxed),
                            count4xx: global4xxCounter.load(ordering: .relaxed),
                            count5xx: global5xxCounter.load(ordering: .relaxed),
                            shedCount: globalShedCounter.load(ordering: .relaxed),
                            latencyNsTotal: globalLatencyNsTotal.load(ordering: .relaxed),
                            latencyFast: globalLatencyBucketFast.load(ordering: .relaxed),
                            latencyMid: globalLatencyBucketMid.load(ordering: .relaxed),
                            latencySlow: globalLatencyBucketSlow.load(ordering: .relaxed),
                            protoVersion: protoVersion,
                            kernelKind: kernelKind,
                            now: now
                        )
                    }
                    do { try await Task.sleep(nanoseconds: intervalNs) } catch { break }
                }
            }
        }

        do {
            try await server.run()   // resident: returns only on bind failure
        } catch {
            pumpTask.cancel()
            monitoringTask?.cancel()
            serverMetricsTask?.cancel()
            throw error
        }
        pumpTask.cancel()
        monitoringTask?.cancel()
        serverMetricsTask?.cancel()
    }
}
