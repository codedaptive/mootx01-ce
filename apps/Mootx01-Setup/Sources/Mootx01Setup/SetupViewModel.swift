// SetupViewModel.swift
//
// Drives the setup assistant: detects installed MCP clients, tracks
// user selection, runs wiring, and reports results. All detection and
// wiring delegates to MootInstallerCore — this class is a thin
// @Observable wrapper that bridges the library to SwiftUI.

import Foundation
import MootInstallerCore

/// The phases the setup assistant walks through.
enum SetupPhase: Equatable {
    case detecting
    case selecting
    case installing
    case complete
    case error(String)
}

/// One row in the client list — wraps MCPClient with selection state.
struct ClientItem: Identifiable {
    let client: MCPClient
    var isSelected: Bool
    let isDetected: Bool
    let isAlreadyWired: Bool

    var id: String { client.id }
}

@Observable
final class SetupViewModel {

    // MARK: - Published state

    var phase: SetupPhase = .detecting
    var clients: [ClientItem] = []
    var results: [String] = []
    var skipped: [String] = []

    // MARK: - Derived

    /// At least one client is selected and not yet wired.
    var canInstall: Bool {
        clients.contains { $0.isSelected }
    }

    var detectedCount: Int {
        clients.filter(\.isDetected).count
    }

    // MARK: - Private

    private let home: URL
    private let binaryPath: String
    private let daemonURL: String

    // MARK: - Init

    init() {
        self.home = FileManager.default.homeDirectoryForCurrentUser

        // Resolve the placed binary path. The .pkg postinstall script
        // places the binary before launching the setup assistant, so it
        // should be at the standard location.
        let placed = MootPaths.installedBinaryURL(homeDirectory: home)
        if FileManager.default.fileExists(atPath: placed.path) {
            self.binaryPath = placed.path
        } else {
            // Fallback: maybe running from a dev build — use the running
            // executable's own path.
            self.binaryPath = Bundle.main.executablePath ?? placed.path
        }

        // Resolve the daemon URL from the port file (if daemon is running)
        // or fall back to the default.
        let dataDir = MootPaths.resolveDataDirectory(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: home
        )
        let port = MootPaths.resolvedResidentPort(dataDir: dataDir)
        self.daemonURL = "http://127.0.0.1:\(port)"
    }

    // MARK: - Actions

    /// Scan for installed MCP clients. Called on appear.
    func detect() {
        phase = .detecting
        let supported = MCPClients.supported
        clients = supported.map { client in
            let detected = client.isPresent(homeDirectory: home)
            let wired = client.wired(homeDirectory: home)
            return ClientItem(
                client: client,
                // Pre-select detected clients that aren't already wired.
                isSelected: detected && !wired,
                isDetected: detected,
                isAlreadyWired: wired
            )
        }
        phase = .selecting
    }

    /// Toggle selection for a client.
    func toggle(_ id: String) {
        guard let idx = clients.firstIndex(where: { $0.id == id }) else { return }
        clients[idx].isSelected.toggle()
    }

    /// Select all detected clients.
    func selectAll() {
        for i in clients.indices where clients[i].isDetected {
            clients[i].isSelected = true
        }
    }

    /// Wire the selected clients.
    func install() {
        phase = .installing
        results = []
        skipped = []

        let selected = clients.filter(\.isSelected)
        let workingDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        for item in selected {
            do {
                try Installer.install(
                    client: item.client,
                    binaryPath: binaryPath,
                    daemonURL: daemonURL,
                    homeDirectory: home,
                    workingDirectory: workingDir,
                    local: false
                )
                results.append(item.client.displayName)
            } catch {
                skipped.append("\(item.client.displayName): \(error.localizedDescription)")
            }
        }

        // Apply integration depth (default = plugin) for wired clients.
        for name in results {
            if let client = selected.first(where: { $0.client.displayName == name }) {
                _ = try? DepthInstaller.apply(
                    clientID: client.client.id,
                    depth: .default,
                    homeDirectory: home,
                    binaryPath: binaryPath
                )
            }
        }

        // Register the background services. WITHOUT this the wired clients point
        // at http://127.0.0.1:4242 with nothing behind it — the .pkg install
        // used to wire clients but never start the daemon, so every client hit
        // ConnectionRefused. This mirrors the CLI `mootx01 install`, which is
        // what the setup assistant is meant to be a GUI projection of.
        #if os(macOS)
        registerBackgroundServices()
        #endif

        phase = .complete
    }

    #if os(macOS)
    /// Register + start the resident daemon and the management console as
    /// launchd LaunchAgents — the same two services `mootx01 install` sets up
    /// (InstallCommand). Failures are surfaced in `skipped` rather than thrown:
    /// client wiring already succeeded, and the user can start a service by
    /// hand, but the install must not silently omit the daemon the clients need.
    private func registerBackgroundServices() {
        // Management console (moot-mgr → dashboard on 4200). Its binary ships
        // beside mootx01 in the install dir.
        let mgrSource = URL(fileURLWithPath: binaryPath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent("moot-mgr")
            .path
        if let mgrPath = try? Installer.placeMgrBinary(sourceMgrPath: mgrSource, homeDirectory: home) {
            switch LaunchAgent.install(mgrBinaryPath: mgrPath, homeDirectory: home) {
            case .installed:               results.append("Management console (moot-mgr)")
            case let .launchctlFailed(m):  skipped.append("Management console: \(m)")
            case .binaryNotFound:          skipped.append("Management console: binary missing")
            }
        }

        // Resident MCP daemon (HTTP server on 4242) — the endpoint the wired
        // clients connect to. Same environment the CLI sets on the LaunchAgent.
        let dataDir = MootPaths.resolveDataDirectory(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: home
        )
        let daemonEnv = [
            "MOOTX01_HTTP_PORT": String(MootPaths.defaultResidentPort),
            "MOOTX01_DATA_DIR": dataDir.path,
            "ARIA_MCP_STATS_STORE": MootPaths.daemonStatsStorePath(dataDir: dataDir),
            "MOOTX01_VAULT": "1",   // vault-on default (ADR-015 §1)
        ]
        switch LaunchAgent.installDaemon(binaryPath: binaryPath, homeDirectory: home, environment: daemonEnv) {
        case .installed:               results.append("Resident MCP daemon (127.0.0.1:4242)")
        case let .launchctlFailed(m):  skipped.append("Resident daemon: \(m)")
        case .binaryNotFound:          skipped.append("Resident daemon: binary missing")
        }
    }
    #endif
}
