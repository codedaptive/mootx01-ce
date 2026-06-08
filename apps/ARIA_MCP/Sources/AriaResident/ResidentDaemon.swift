import Foundation
import AriaMCP
import GeniusLocusKit
import ObserverSink
import IntellectusLib

/// The resident-daemon composition layer (see ADR-LOOPBACKHTTP-001).
///
/// Both the product binary (`mootx01 serve`, resident mode) and the dev/reference
/// build (`aria-mcp`) run the SAME resident wiring through this one entry point —
/// so there is a single implementation, not two that drift. It sits ABOVE the
/// telemetry-free JSON-RPC core (`AriaMCP`): `HTTPServer` and `BrainPump` stay in
/// the core; their *composition with telemetry* lives here. This keeps `AriaMCP`
/// free of ObserverSink/IntellectusLib (the separation established in P3) — the
/// `AriaMCP` target declares no telemetry dependency, so the build itself is the
/// guard (an `import ObserverSink` there would not compile).
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

    /// Brain pump base tick (ms) from `MOOTX01_BRAIN_TICK_MS` (default 5000).
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

    // MARK: - Telemetry install (resident-mode, opt-in)

    /// Install the manager-telemetry sink for the given store path, or return nil
    /// when `storePath` is nil/empty (telemetry off — and off is free). Opens the
    /// manager's stats store, installs a `PersistenceStatsSink`, drives the
    /// IntellectusLib gate from the store's monitoring flag, and emits one startup
    /// metric. Best-effort: any failure logs to stderr and returns nil — telemetry
    /// must never affect the server.
    public static func installManagerTelemetry(storePath: String?) async -> StatsStore? {
        guard let storePath, !storePath.isEmpty else { return nil }
        do {
            let store = try StatsStore(url: URL(fileURLWithPath: storePath))
            try await store.open()
            let dropboxID = "mootx01-\(UUID().uuidString.prefix(8))"
            Intellectus.install(sink: PersistenceStatsSink(store: store, dropboxID: dropboxID))
            let monitoringOn = try await store.isMonitoringEnabled()
            Intellectus.setEnabled(monitoringOn)
            Intellectus.report(.metric(
                name: "mootx01.start",
                value: 1.0,
                tags: ["dropbox": dropboxID],
                ts: Date().timeIntervalSince1970
            ))
            Logging.stderr.log("AriaResident telemetry wired (store: \(storePath), dropbox: \(dropboxID), monitoring: \(monitoringOn ? "on" : "off"))")
            return store
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
    /// the exit code); never calls `exit()`.
    public static func runResidentDaemon(
        dispatcher: ARIA_MCPDispatcher,
        kit: GeniusLocusKit,
        handle: EstateHandle,
        config: ResidentConfig
    ) async throws {
        let statsStore = await installManagerTelemetry(storePath: config.statsStorePath)

        let server = HTTPServer(dispatcher: dispatcher, port: config.port, maxBodyBytes: config.maxBodyBytes)
        let brainPump = BrainPump(kit: kit, handle: handle, baseTickMs: config.brainTickMs)
        let pumpTask = Task { await brainPump.run() }

        // Continuous monitoring gate: track the store flag on the
        // running daemon so a moot-mgr on/off flip takes effect without a restart.
        // Only when telemetry is wired; "off is free" preserved.
        let pollMs = config.monitoringPollMs
        let monitoringTask: Task<Void, Never>? = statsStore.map { store in
            Task {
                let pollNs = UInt64(pollMs) * 1_000_000
                var last: Bool? = nil
                while !Task.isCancelled {
                    do {
                        let on = try await store.isMonitoringEnabled()
                        Intellectus.setEnabled(on)
                        if on != last {
                            Logging.stderr.log("AriaResident monitoring gate: \(on ? "on" : "off")")
                            last = on
                        }
                    } catch {
                        Logging.stderr.log("AriaResident monitoring-gate refresh failed: \(error)")
                    }
                    do { try await Task.sleep(nanoseconds: pollNs) } catch { break }
                }
            }
        }

        do {
            try await server.run()   // resident: returns only on bind failure
        } catch {
            pumpTask.cancel()
            monitoringTask?.cancel()
            throw error
        }
        pumpTask.cancel()
        monitoringTask?.cancel()
    }
}
