// ResidentHost.swift
//
// The long-lived resident host for moot-mgr (P3, MANAGER_1.0_PLAN.md §4 P3).
//
// A single process that:
//   1. Owns the MootManager (and therefore the ObserverSink stats store) — it
//      reuses the spine's store ownership; it does NOT open a second store.
//   2. Serves the loopback HTTP read-API (HTTPReadAPI, 127.0.0.1 only).
//   3. Exposes the gated control channel over a Unix domain socket (0600).
//   4. Runs the retention loop on the configured cadence.
//
// This is the "two-plane" host from the GUI SPEC §0 / concepts §0: the read
// plane (HTTP) and the admin/control plane (UDS + token-gated HTTP control),
// kept separate by surface and by auth, both fed from the one owned store.
//
// The host is `Sendable`-clean: it composes actors (MootManager, HTTPReadAPI,
// ControlChannel) and holds only value config. The retention loop runs as a
// detached Task; `stop()` cancels it.

import Foundation
import OSLog

// MARK: - ResidentHostConfig

/// Configuration for the resident host: the manager config plus the host's own
/// network surfaces (HTTP port, control token, UDS path).
public struct ResidentHostConfig: Sendable {
    /// The manager (store + retention) configuration.
    public let manager: ManagerConfig
    /// TCP port for the loopback HTTP read-API (0 = OS-assigned, handy for tests).
    public let httpPort: UInt16
    /// Bearer token gating the HTTP control surface. Must be >= 16 chars to be
    /// honoured (see `HTTPReadAPI.isAuthorized`).
    public let controlToken: String
    /// Filesystem path for the gated control UDS (created at 0600).
    public let controlSocketPath: String
    /// Directory under which the admin plane creates SQLite-backed estate stores
    /// (one file per estate). The admin engine (`EstateAdmin`) provisions real
    /// MOOTs here through GLK. Defaults beside the stats store
    /// (<store-dir>/estates). InMemory estates do not touch it.
    public let estatesDirectory: URL
    /// Whether `httpPort` was explicitly requested (env/flag). Explicit means
    /// exact — a busy port fails. When false (the built-in default), `start`
    /// hunts upward from `httpPort` to the first bindable port (spec §3).
    public let httpPortExplicit: Bool
    /// Whether to maintain the §3 `mgr.port` file. True for the production
    /// `fromEnvironment` path; false for memberwise (test/embedded) hosts so
    /// parallel tests never touch the live machine's port file.
    public let writePortFile: Bool
    /// Override for the HTTP concurrency cap. `nil` means use the default
    /// (`MootMgrMaxLoopbackConnections` / env var). Set only in tests that need
    /// precise cap control without mutating the process environment.
    public let httpMaxConnections: Int?

    public init(
        manager: ManagerConfig,
        httpPort: UInt16,
        controlToken: String,
        controlSocketPath: String,
        estatesDirectory: URL,
        httpPortExplicit: Bool = true,
        writePortFile: Bool = false,
        httpMaxConnections: Int? = nil
    ) {
        self.manager = manager
        self.httpPort = httpPort
        self.controlToken = controlToken
        self.controlSocketPath = controlSocketPath
        self.estatesDirectory = estatesDirectory
        self.httpPortExplicit = httpPortExplicit
        self.writePortFile = writePortFile
        self.httpMaxConnections = httpMaxConnections
    }

    // MARK: - Environment variable names / defaults

    /// Env var overriding the loopback HTTP read-API port.
    public static let httpPortEnvKey = "MOOT_MGR_HTTP_PORT"
    /// Env var supplying the bearer token gating the HTTP control surface.
    public static let controlTokenEnvKey = "MOOT_MGR_CONTROL_TOKEN"
    /// Env var overriding the UDS control-socket path.
    public static let controlSocketEnvKey = "MOOT_MGR_CONTROL_SOCKET"
    /// Env var overriding the admin-plane estates directory.
    public static let estatesDirEnvKey = "MOOT_MGR_ESTATES_DIR"

    /// How many ports above the default the host will try when the port was
    /// not explicitly requested (spec §3: default hunts upward; explicit is
    /// exact). Mirrors Rust `HUNT_RANGE`.
    public static let huntRange: UInt16 = 100

    /// Default loopback HTTP port for the read-API.
    public static let defaultHTTPPort: UInt16 = 4200

    /// Resolve a resident-host config from the environment, reusing
    /// `ManagerConfig.fromEnvironment()` for the store/retention parts.
    ///
    /// The control socket defaults next to the store file
    /// (<store-dir>/control.sock). The control token has NO default — if the
    /// env var is absent or too short, an empty token is returned, which
    /// disables the HTTP control surface (the UDS, gated by 0600, still works).
    ///
    /// - Parameter environment: The environment map (injectable for tests).
    /// - Returns: A resolved `ResidentHostConfig`.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ResidentHostConfig {
        let manager = ManagerConfig.fromEnvironment(environment)
        let portExplicit = !(environment[httpPortEnvKey] ?? "").isEmpty
        let port = environment[httpPortEnvKey].flatMap { UInt16($0) } ?? defaultHTTPPort
        let token = environment[controlTokenEnvKey] ?? ""
        let socket = environment[controlSocketEnvKey]
            ?? manager.storeURL.deletingLastPathComponent()
                .appendingPathComponent("control.sock", isDirectory: false).path
        // Admin estates default to a sibling "estates" directory of the stats
        // store, so a fresh install provisions estates beside the manager's data.
        let estatesDir = environment[estatesDirEnvKey].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? manager.storeURL.deletingLastPathComponent()
                .appendingPathComponent("estates", isDirectory: true)
        return ResidentHostConfig(
            manager: manager,
            httpPort: port,
            controlToken: token,
            controlSocketPath: socket,
            estatesDirectory: estatesDir,
            httpPortExplicit: portExplicit,
            writePortFile: true
        )
    }
}

// MARK: - ResidentHost

/// The resident multi-plane host process for moot-mgr.
public actor ResidentHost {

    private let config: ResidentHostConfig
    private let manager: MootManager
    private let admin: EstateAdmin
    private var httpAPI: HTTPReadAPI?
    private var control: ControlChannel?
    private var retentionTask: Task<Void, Never>?
    private let startInstant: Date
    private let clock: @Sendable () -> Date

    private let logger = Logger(subsystem: "com.mootx01.kit", category: "ResidentHost")

    /// Create a resident host.
    ///
    /// - Parameters:
    ///   - config:       The host configuration (manager + network surfaces).
    ///   - startInstant: The host start time (uptime base). Defaults to now.
    ///   - clock:        Injected clock (retention loop + uptime). Defaults to `Date()`.
    public init(
        config: ResidentHostConfig,
        startInstant: Date = Date(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.manager = MootManager(config: config.manager)
        self.admin = EstateAdmin(estatesDirectory: config.estatesDirectory)
        self.startInstant = startInstant
        self.clock = clock
    }

    // MARK: - Lifecycle

    /// Start the host: open the store, bring up the read-API and control
    /// channel, and launch the retention loop.
    ///
    /// Port selection (spec §3): an explicitly requested port binds exactly —
    /// busy fails. The built-in default hunts upward from `httpPort` by
    /// retrying the bind on the next candidate (no probe race) up to
    /// `ResidentHostConfig.huntRange` ports. Whatever port binds is written
    /// to the §3 `mgr.port` file (production hosts) and removed on `stop()`.
    ///
    /// - Throws: Any error from opening the store or binding the surfaces.
    public func start() async throws {
        try await manager.start()

        let candidates: [UInt16] = config.httpPortExplicit
            ? [config.httpPort]
            : (0...ResidentHostConfig.huntRange).map { config.httpPort &+ $0 }
        var startedAPI: HTTPReadAPI?
        var lastError: Error?
        for port in candidates {
            let api = HTTPReadAPI(
                manager: manager,
                port: port,
                controlToken: config.controlToken,
                startInstant: startInstant,
                clock: clock,
                admin: admin,
                maxConnections: config.httpMaxConnections
            )
            do {
                try await api.start()
                if port != config.httpPort {
                    logger.info("port \(self.config.httpPort) busy; hunted to \(port)")
                }
                startedAPI = api
                break
            } catch {
                lastError = error
            }
        }
        guard let api = startedAPI else {
            // candidates is never empty, so lastError is always populated here;
            // notStarted is an unreachable fallback to satisfy the type.
            throw lastError ?? ManagerError.notStarted
        }
        self.httpAPI = api

        let control = ControlChannel(api: api, socketPath: config.controlSocketPath)
        try await control.start()
        self.control = control
        // (api.start()/control.start() are synchronous throwing actor methods;
        // `await` here is the actor hop, not an async operation.)

        // §3 port file: record the BOUND port for status/dashboard discovery
        // (production hosts only — see `writePortFile`).
        if config.writePortFile {
            let bound = await api.boundPort()
            let portFile = Self.mgrPortFileURL()
            try? FileManager.default.createDirectory(
                at: portFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            do {
                try "\(bound)\n".write(to: portFile, atomically: true, encoding: .utf8)
            } catch {
                logger.warning("cannot write port file \(portFile.path): \(error) (continuing)")
            }
        }

        startRetentionLoop()
        logger.info("ResidentHost started (HTTP :\(self.config.httpPort), UDS \(self.config.controlSocketPath))")
    }

    /// Stop the host: cancel the retention loop, tear down both surfaces, close
    /// the store. Idempotent.
    public func stop() async {
        retentionTask?.cancel()
        retentionTask = nil
        await control?.stop()
        control = nil
        if httpAPI != nil, config.writePortFile {
            // Clean-shutdown removal of the §3 port file (only when we wrote it).
            try? FileManager.default.removeItem(at: Self.mgrPortFileURL())
        }
        await httpAPI?.stop()
        httpAPI = nil
        await manager.stop()
    }

    /// §3 `mgr.port` location: the mootx01 data dir, honoring
    /// `MOOTX01_DATA_DIR`. macOS default:
    /// `~/Library/Application Support/ai.mootx01.ce/mgr.port`. Mirrors the
    /// Rust `mgr_port_file_path`.
    public static func mgrPortFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["MOOTX01_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("mgr.port", isDirectory: false)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/ai.mootx01.ce", isDirectory: true)
            .appendingPathComponent("mgr.port", isDirectory: false)
    }

    /// The HTTP port actually bound (resolves an OS-assigned port when 0 was given).
    public func boundHTTPPort() async -> UInt16 {
        await httpAPI?.boundPort() ?? config.httpPort
    }

    /// The owned manager, for in-process consumers/tests. `nonisolated` because
    /// `manager` is an immutable `let` (an actor reference is `Sendable`).
    public nonisolated func managerHandle() -> MootManager { manager }

    /// The owned admin engine, for in-process consumers/tests. `nonisolated`
    /// because `admin` is an immutable `let` (an actor reference is `Sendable`).
    /// Production callers reach admin verbs only through the gated control
    /// surface; this handle is for the in-process read reflection and tests.
    public nonisolated func adminHandle() -> EstateAdmin { admin }

    // MARK: - Retention loop

    /// Launch the retention loop: wake every `retentionCadence` seconds and run
    /// one pass. The loop owns the clock boundary (determinism applies to the
    /// store engines, which receive the computed cutoff — not to the host's own
    /// timer). Cancelled by `stop()`.
    private func startRetentionLoop() {
        let cadence = config.manager.retentionCadence
        let clock = self.clock
        let manager = self.manager
        retentionTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(cadence * 1_000_000_000))
                if Task.isCancelled { break }
                _ = try? await manager.runRetention(now: clock())
            }
        }
    }
}
